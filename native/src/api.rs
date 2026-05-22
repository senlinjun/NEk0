use crate::{
    Command, TsChannel, TsClient, TsEvent, COMMAND_TX, IDENTITY_STASH, RUNTIME, STATE,
    SWIPE_DISCONNECT,
};

use futures::prelude::*;
use opus_rs::OpusDecoder;
use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tsclientlib::messages::c2s::*;
use tsclientlib::{ChannelId, ClientId};
use tsclientlib::{Connection, DisconnectOptions, Identity, OutCommandExt, StreamItem};
use tsproto_packets::packets::{AudioData, CodecType, InAudioBuf, OutAudio};

fn to_c_str(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("null string").unwrap())
        .into_raw()
}

#[no_mangle]
pub extern "C" fn ts_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

fn push_diag(msg: &str) {
    use std::sync::atomic::AtomicU64;
    static DIAG_SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = DIAG_SEQ.fetch_add(1, Ordering::SeqCst);
    STATE.lock().pending_events.push_back(TsEvent::Diag {
        msg: format!("#{} {}", seq, msg),
    });
}

fn refresh_from_book(book: &tsclientlib::data::Connection) -> (Vec<TsChannel>, Vec<TsClient>) {
    let mut count: HashMap<u64, u32> = HashMap::new();
    for c in book.clients.values() {
        *count.entry(c.channel.0).or_insert(0) += 1;
    }
    let channels = book
        .channels
        .values()
        .map(|c| TsChannel {
            id: c.id.0 as u32,
            name: c.name.clone(),
            parent_id: if c.parent.0 == 0 {
                0
            } else {
                c.parent.0 as u32
            },
            topic: c.topic.clone().unwrap_or_default(),
            has_password: c.has_password.unwrap_or(false),
            client_count: *count.get(&c.id.0).unwrap_or(&0),
            order: c.order.0 as u32,
        })
        .collect();
    let clients: Vec<_> = book
        .clients
        .values()
        .map(|c| {
            let uid = c.uid.as_ref().map(|u| u.to_string());
            TsClient {
                id: c.id.0 as u32,
                nickname: c.name.clone(),
                channel_id: c.channel.0 as u32,
                uid,
                away: c.away_message.is_some(),
                input_muted: c.input_muted,
                output_muted: c.output_muted,
                is_talking: {
                    let state = STATE.lock();
                    state.talking_clients.get(&(c.id.0 as u16))
                        .map(|t| t.elapsed().as_millis() < 500)
                        .unwrap_or(false)
                },
                volume: {
                    let state = STATE.lock();
                    state.client_volumes.get(&(c.id.0 as u16)).copied().unwrap_or(1.0)
                },
            }
        })
        .collect();
    (channels, clients)
}

// ─── Identity ───────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_set_identity(json: *const c_char) {
    if json.is_null() {
        return;
    }
    let s = unsafe { std::ffi::CStr::from_ptr(json) }
        .to_string_lossy()
        .into_owned();
    *IDENTITY_STASH.lock() = if s.is_empty() { None } else { Some(s) };
}

#[no_mangle]
pub extern "C" fn ts_get_identity() -> *mut c_char {
    let id = IDENTITY_STASH.lock().clone();
    match id {
        Some(s) => to_c_str(s),
        None => std::ptr::null_mut(),
    }
}

// ─── Connect ────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_connect(
    address: *const c_char,
    nickname: *const c_char,
    channel: *const c_char,
    password: *const c_char,
) -> *mut c_char {
    let address = unsafe { std::ffi::CStr::from_ptr(address) }
        .to_string_lossy()
        .into_owned();
    let nickname = unsafe { std::ffi::CStr::from_ptr(nickname) }
        .to_string_lossy()
        .into_owned();
    let channel = if channel.is_null() {
        None
    } else {
        Some(
            unsafe { std::ffi::CStr::from_ptr(channel) }
                .to_string_lossy()
                .into_owned(),
        )
    };
    let password = if password.is_null() {
        None
    } else {
        Some(
            unsafe { std::ffi::CStr::from_ptr(password) }
                .to_string_lossy()
                .into_owned(),
        )
    };

    eprintln!("ts_connect: address={}", address);

    let mut state = STATE.lock();
    if state.connecting || state.connected {
        return to_c_str(
            serde_json::to_string(&TsEvent::Error {
                message: "Already connecting".into(),
            })
            .unwrap(),
        );
    }
    state.connecting = true;
    state.nickname = nickname.clone();
    // Clear any stale events from a previous connection
    state.pending_events.clear();
    drop(state);

    RUNTIME.spawn(async move {
        if let Err(e) = do_connect(address, nickname, channel, password).await {
            eprintln!("do_connect: ERROR {}", e);
            let mut state = STATE.lock();
            state.connecting = false;
            state.pending_events.push_back(TsEvent::Error {
                message: format!("{}", e),
            });
        }
    });

    to_c_str(r#"{"type":"connecting"}"#.to_string())
}

async fn do_connect(
    address: String,
    nickname: String,
    channel: Option<String>,
    password: Option<String>,
) -> Result<(), String> {
    crate::install_panic_hook();
    let mut opts = Connection::build(address).name(nickname);
    if let Some(id_json) = IDENTITY_STASH.lock().take() {
        if let Ok(id) = serde_json::from_str::<Identity>(&id_json) {
            opts = opts.identity(id);
        }
    }
    if let Some(ch) = channel {
        opts = opts.channel(ch);
    }
    if let Some(pw) = password {
        opts = opts.password(pw);
    }

    let mut con = opts.connect().map_err(|e| format!("{}", e))?;

    let mut ok = false;
    tokio::time::timeout(Duration::from_secs(15), async {
        while let Some(item) = con.events().next().await {
            match item {
                Ok(StreamItem::BookEvents(_)) => {
                    ok = true;
                    break;
                }
                Ok(StreamItem::IdentityLevelIncreasing(l)) => {
                    STATE.lock().pending_events.push_back(TsEvent::Error {
                        message: format!("Identity level {}...", l),
                    });
                }
                Err(e) => return Err(format!("{}", e)),
                _ => {}
            }
        }
        Ok(())
    })
    .await
    .map_err(|_| "Timeout".to_string())??;

    if !ok {
        return Err("No BookEvents".into());
    }

    {
        let sub = OutChannelSubscribeAllMessage::new();
        let _ = sub.send(&mut con);
    }

    let book = con.get_state().map_err(|e| format!("{}", e))?;
    let (channels, clients) = refresh_from_book(&book);
    let sname = book.server.name.clone();
    let oid = book.own_client.0 as u32;

    eprintln!(
        "do_connect: OK, {} channels, {} clients, own_id={}",
        channels.len(),
        clients.len(),
        oid
    );

    let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel();
    let generation = crate::CONNECTION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    *COMMAND_TX.lock() = Some(cmd_tx);

    {
        let mut state = STATE.lock();
        state.connecting = false;
        state.connected = true;
        state.server_name = sname.clone();
        state.own_client_id = oid;
        state.channels = channels;
        state.clients = clients;
        state.pending_events.push_back(TsEvent::Connected {
            server_name: sname,
            client_id: oid,
        });
    }

    if let Some(id) = con.get_options().get_identity() {
        if let Ok(json) = serde_json::to_string(id) {
            *IDENTITY_STASH.lock() = Some(json);
        }
    }

    *crate::CONNECTION_STASH.lock() = Some(con);

    RUNTIME.spawn(async move {
        let con = crate::CONNECTION_STASH
            .lock()
            .take()
            .expect("Connection not in stash");
        let fut = event_loop(con, cmd_rx, generation);
        let result = std::panic::AssertUnwindSafe(fut).catch_unwind().await;
        match result {
            Ok(_) => push_diag("event_loop: exited normally"),
            Err(e) => {
                let msg = if let Some(s) = e.downcast_ref::<&str>() {
                    s.to_string()
                } else if let Some(s) = e.downcast_ref::<String>() {
                    s.clone()
                } else {
                    "unknown panic".into()
                };
                push_diag(&format!("event_loop PANICKED: {}", msg));
            }
        }
        crate::EVENT_LOOP_ALIVE.store(false, Ordering::SeqCst);
    });
    Ok(())
}

// ─── Audio receive helpers ──────────────────────────────────────────

/// Decode an incoming audio packet with a per-client OpusDecoder and mix into the
/// accumulation buffer.  The decoder is created lazily on the first packet from a
/// speaker and keeps its state across frames (required for correct Opus decoding).
fn decode_and_mix(audio_buf: InAudioBuf, mix_buffer: &mut [f32]) {
    // Extract data from the self_cell-wrapped buffer BEFORE locking STATE.
    // InAudioBuf uses a self-referential pattern — we must clone the bytes we need
    // while the borrow is alive, then drop the references.
    let audio = audio_buf.data(); // &InAudio
    let audio_data = audio.data(); // &AudioData

    let (from_id, opus_vec) = match audio_data {
        AudioData::S2C { from, data, .. } => (*from, data.to_vec()),
        AudioData::S2CWhisper { from, data, .. } => (*from, data.to_vec()),
        _ => return,
    };
    drop(audio_data);
    drop(audio);
    drop(audio_buf);

    // Now we own opus_vec — safe to lock STATE.
    let vol;
    let mut state = STATE.lock();
    vol = state.client_volumes.get(&from_id).copied().unwrap_or(1.0);
    // Mark client as talking (used for blue dot indicator in UI)
    state.talking_clients.insert(from_id, std::time::Instant::now());
    let decoder = state
        .audio_decoders
        .entry(from_id)
        .or_insert_with(|| OpusDecoder::new(48000, 1).expect("failed to create Opus decoder"));

    let mut pcm_out = vec![0.0f32; mix_buffer.len()];
    match decoder.decode(&opus_vec, mix_buffer.len(), &mut pcm_out) {
        Ok(decoded_samples) => {
            let n = decoded_samples.min(mix_buffer.len());
            for i in 0..n {
                mix_buffer[i] = (mix_buffer[i] + pcm_out[i] * vol).clamp(-1.0, 1.0);
            }
        }
        Err(e) => {
            eprintln!("opus decode error from client {}: {}", from_id, e);
        }
    }
}

/// Handle a non-audio stream item (book events, messages, disconnects).
fn handle_control_item(item: &StreamItem, con: &mut Connection, _generation: u64) {
    let handle_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match item {
            StreamItem::Audio(_) => {} // handled upstream
            StreamItem::BookEvents(events) => {
                for ev in events {
                    match ev {
                        tsclientlib::events::Event::Message {
                            target,
                            invoker,
                            message,
                        } => {
                            let target_mode = match target {
                                tsclientlib::MessageTarget::Server => 3u8,
                                tsclientlib::MessageTarget::Channel => 2u8,
                                tsclientlib::MessageTarget::Client(_) => 1u8,
                                tsclientlib::MessageTarget::Poke(_) => 0u8,
                            };
                            STATE.lock().pending_events.push_back(TsEvent::TextMessage {
                                from_client: invoker.name.clone(),
                                from_client_id: invoker.id.0 as u32,
                                target_mode,
                                message: message.clone(),
                            });
                        }
                        _ => {
                            let refreshed = con.get_state().ok().map(|b| refresh_from_book(&b));
                            if let Some((ch, cl)) = refreshed {
                                let mut state = STATE.lock();
                                state.channels = ch;
                                state.clients = cl;
                                state.pending_events.push_back(TsEvent::ChannelsUpdated {});
                            }
                        }
                    }
                }
            }
            StreamItem::MessageEvent(msg) => {
                use tsclientlib::messages::s2c::InMessage;
                if let InMessage::TextMessage(txt) = msg {
                    for p in txt.iter() {
                        STATE.lock().pending_events.push_back(TsEvent::TextMessage {
                            from_client: p.invoker_name.clone(),
                            from_client_id: p.invoker_id.0 as u32,
                            target_mode: p.target as u8,
                            message: p.message.clone(),
                        });
                    }
                }
            }
            StreamItem::DisconnectedTemporarily(r) => {
                STATE.lock().pending_events.push_back(TsEvent::Error {
                    message: format!("Temp disconnected: {:?}", r),
                });
            }
            _ => {}
        }
    }));
    if let Err(e) = handle_result {
        let msg = if let Some(s) = e.downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = e.downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".into()
        };
        push_diag(&format!("event handler PANICKED: {}", msg));
    }
}

async fn event_loop(
    mut con: Connection,
    mut cmd_rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    generation: u64,
) {
    eprintln!("event_loop: started gen={}", generation);
    push_diag(&format!("event_loop: started (gen={})", generation));
    crate::EVENT_LOOP_ALIVE.store(true, Ordering::SeqCst);
    loop {
        // Clean up talking clients that haven't spoken in >2s
        STATE.lock().talking_clients.retain(|_, t| t.elapsed().as_millis() < 2000);

        if SWIPE_DISCONNECT.load(Ordering::SeqCst) {
            STATE.lock().disconnect_requested = true;
            SWIPE_DISCONNECT.store(false, Ordering::SeqCst);
        }
        let do_disconnect = {
            let state = STATE.lock();
            state.disconnect_requested
        };
        if do_disconnect {
            let _ = con.disconnect(DisconnectOptions::new());
            let _ = con.events().for_each(|_| future::ready(())).await;
            let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
            if current_gen == generation {
                STATE
                    .lock()
                    .pending_events
                    .push_back(TsEvent::Disconnected {
                        reason: "User disconnected".into(),
                    });
                STATE.lock().connected = false;
                STATE.lock().disconnect_requested = false;
                STATE.lock().audio_decoders.clear();
                STATE.lock().audio_out.clear();
                *COMMAND_TX.lock() = None;
            }
            return;
        }

        // 1. Process all pending commands (non-blocking)
        while let Ok(cmd) = cmd_rx.try_recv() {
            match cmd {
                Command::SendMessage {
                    target_mode: _,
                    target_cid: _,
                    message,
                } => {
                    let part = OutSendTextMessagePart {
                        target: tsclientlib::TextMessageTargetMode::Channel,
                        target_client_id: None,
                        message: Cow::Owned(message),
                    };
                    let _ =
                        OutSendTextMessageMessage::new(&mut std::iter::once(part)).send(&mut con);
                }
                Command::MoveChannel {
                    client_id,
                    channel_id,
                } => {
                    let part = OutClientMovePart {
                        client_id: ClientId(client_id),
                        channel_id: ChannelId(channel_id),
                        channel_password: None,
                    };
                    let _ = OutClientMoveMessage::new(&mut std::iter::once(part)).send(&mut con);
                }
                Command::SetMuted { input, output } => {
                    let part = OutClientUpdatePart {
                        name: None,
                        input_muted: if input { Some(true) } else { Some(false) },
                        output_muted: if output { Some(true) } else { Some(false) },
                        is_away: None,
                        away_message: None,
                        input_hardware_enabled: None,
                        output_hardware_enabled: None,
                        is_channel_commander: None,
                        avatar_hash: None,
                        phonetic_name: None,
                        talk_power_request: None,
                        talk_power_request_message: None,
                        is_recording: None,
                        badges: None,
                    };
                    let _ = OutClientUpdateMessage::new(&mut std::iter::once(part)).send(&mut con);
                }
                Command::Disconnect => {
                    let _ = con.disconnect(DisconnectOptions::new());
                    let _ = con.events().for_each(|_| future::ready(())).await;
                    let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                    if current_gen == generation {
                        let mut s = STATE.lock();
                        s.pending_events.push_back(TsEvent::Disconnected {
                            reason: "User disconnected".into(),
                        });
                        s.connected = false;
                        s.audio_decoders.clear();
                        s.audio_out.clear();
                        *COMMAND_TX.lock() = None;
                    }
                    return;
                }
                Command::SendAudio { data } => {
                    const FRAME: usize = 960;
                    {
                        let mut state = STATE.lock();
                        state.pcm_in.extend_from_slice(&data);
                    }
                    loop {
                        let encode_result = {
                            let mut state = STATE.lock();
                            if state.pcm_in.len() < FRAME {
                                break;
                            }
                            let frame: Vec<f32> = state.pcm_in.drain(..FRAME).collect();
                            const HOLD_FRAMES: u32 = 10;
                            let vad_drop = if state.vad_enabled {
                                let rms = (frame.iter().map(|s| s * s).sum::<f32>() / FRAME as f32)
                                    .sqrt();
                                if rms >= state.vad_threshold {
                                    state.vad_hold = HOLD_FRAMES;
                                    false
                                } else if state.vad_hold > 0 {
                                    state.vad_hold -= 1;
                                    false
                                } else {
                                    true
                                }
                            } else {
                                false
                            };
                            // Read gain before dropping state (avoid split-borrow conflict)
                            let gain = state.mic_gain;
                            drop(state);
                            if vad_drop {
                                None
                            } else {
                                // Apply mic gain AFTER VAD so VAD sees raw mic level
                                let gained: Vec<f32> = if (gain - 1.0).abs() > 0.001 {
                                    frame.iter().map(|s| (s * gain).clamp(-1.0, 1.0)).collect()
                                } else {
                                    frame
                                };
                                let mut state = STATE.lock();
                                if let Some(ref mut encoder) = state.audio_encoder {
                                    let mut opus_out = vec![0u8; 4000];
                                    match encoder.encode(&gained, FRAME, &mut opus_out) {
                                        Ok(len) => {
                                            let seq = state.audio_seq;
                                            state.audio_seq = state.audio_seq.wrapping_add(1);
                                            Some((seq, opus_out[..len].to_vec()))
                                        }
                                        Err(e) => {
                                            eprintln!(
                                                "opus encode ERROR: {} (frame_len={})",
                                                e,
                                                gained.len()
                                            );
                                            None
                                        }
                                    }
                                } else {
                                    state.pcm_in.clear();
                                    None
                                }
                            }
                        };
                        if let Some((seq, opus_data)) = encode_result {
                            let packet = OutAudio::new(&AudioData::C2S {
                                id: seq,
                                codec: CodecType::OpusVoice,
                                data: &opus_data,
                            });
                            match con.send_audio(packet) {
                                Ok(_) => {
                                    STATE.lock().voice_active = true;
                                }
                                Err(e) => eprintln!("event_loop: send_audio error: {}", e),
                            }
                        }
                    }
                }
            }
        }

        // 2. Poll events — drain all available audio, handle control events.
        //    Batch all audio packets into ONE mixed 960-sample frame per iteration,
        //    so production rate = 50 Hz × 960 = 48k samples/sec regardless of speaker count.
        const FRAME: usize = 960;
        let mut mix_buffer: Vec<f32> = vec![0.0f32; FRAME];
        let mut had_audio = false;

        // 2a. First event — up to 20ms timeout (keeps commands responsive)
        let first = tokio::time::timeout(Duration::from_millis(20), con.events().next()).await;
        let mut deferred: Option<StreamItem> = None;

        match first {
            Ok(Some(Ok(StreamItem::Audio(audio_buf)))) => {
                decode_and_mix(audio_buf, &mut mix_buffer);
                had_audio = true;
            }
            Ok(Some(Ok(item))) => {
                deferred = Some(item);
            }
            Ok(Some(Err(e))) => {
                eprintln!("event_loop: stream error: {} (gen={})", e, generation);
                let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                if current_gen == generation {
                    STATE.lock().pending_events.push_back(TsEvent::Error {
                        message: format!("{}", e),
                    });
                }
                break;
            }
            Ok(None) => {
                eprintln!(
                    "event_loop: stream ended (server disconnect, gen={})",
                    generation
                );
                let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                if current_gen == generation {
                    let mut s = STATE.lock();
                    s.connected = false;
                    s.audio_decoders.clear();
                    s.audio_out.clear();
                    s.pending_events.push_back(TsEvent::Disconnected {
                        reason: "Connection closed by server".into(),
                    });
                    *COMMAND_TX.lock() = None;
                }
                break;
            }
            Err(_) => {} // 20ms timeout — continue
        }

        // 2b. Drain remaining already-available events (1ms timeout, non-blocking).
        //     Non-audio events are collected and processed after the drain to avoid
        //     conflicting mutable borrows on `con` (the stream borrows con via events()).
        let mut deferred_events: Vec<StreamItem> = Vec::new();
        loop {
            match tokio::time::timeout(Duration::from_millis(1), con.events().next()).await {
                Ok(Some(Ok(StreamItem::Audio(audio_buf)))) => {
                    decode_and_mix(audio_buf, &mut mix_buffer);
                    had_audio = true;
                }
                Ok(Some(Ok(item))) => {
                    deferred_events.push(item);
                }
                Ok(Some(Err(e))) => {
                    eprintln!("event_loop: stream error: {} (gen={})", e, generation);
                    let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                    if current_gen == generation {
                        STATE.lock().pending_events.push_back(TsEvent::Error {
                            message: format!("{}", e),
                        });
                    }
                    break;
                }
                Ok(None) => {
                    let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                    if current_gen == generation {
                        let mut s = STATE.lock();
                        s.connected = false;
                        s.audio_decoders.clear();
                        s.audio_out.clear();
                        s.pending_events.push_back(TsEvent::Disconnected {
                            reason: "Connection closed by server".into(),
                        });
                        *COMMAND_TX.lock() = None;
                    }
                    break;
                }
                Err(_) => break, // 1ms timeout — no more events
            }
        }

        // 2c. Process deferred non-audio events (stream borrow released)
        for item in deferred_events {
            handle_control_item(&item, &mut con, generation);
        }
        if let Some(item) = deferred {
            handle_control_item(&item, &mut con, generation);
        }

        // 2d. Flush ONE mixed output frame to audio_out
        if had_audio {
            let mut state = STATE.lock();
            for &sample in &mix_buffer {
                let clamped = sample.clamp(-1.0, 1.0);
                state.audio_out.push_back((clamped * 32767.0) as i16);
            }
            // Cap output buffer — safety backstop for Dart-side jitter
            while state.audio_out.len() > 15360 {
                state.audio_out.pop_front();
            }
        }
    }
}

// ─── Disconnect ─────────────────────────────────────────────────────

/// Called from KeepAliveService.onTaskRemoved when app is swiped from recents.
/// Sets the disconnect flag directly on STATE (one less hop than SWIPE_DISCONNECT),
/// pushes a Disconnect command into the channel if possible, and falls back to
/// taking Connection from CONNECTION_STASH for a sync disconnect if the event
/// loop is already dead.  This is needed because in release builds Android kills
/// the process almost immediately after onTaskRemoved returns — the event loop
/// may not get another iteration to check the flag.
#[no_mangle]
pub extern "system" fn Java_com_senlinjun_nek0_KeepAliveService_tsDisconnect(
    _env: *mut std::ffi::c_void,
    _class: *mut std::ffi::c_void,
) {
    // Fast path: set the flag directly so the event loop sees it on next iter
    STATE.lock().disconnect_requested = true;
    SWIPE_DISCONNECT.store(true, Ordering::SeqCst);

    // Try to push a Disconnect command — the event loop drains commands
    // synchronously before each poll, so this takes effect immediately.
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        let _ = tx.send(crate::Command::Disconnect);
    }
    drop(tx);

    // Fallback: if the event loop is dead, take the Connection from stash
    // and do a synchronous block_on disconnect directly.
    if let Some(mut con) = crate::CONNECTION_STASH.lock().take() {
        let _ = con.disconnect(DisconnectOptions::new());
        let _ = RUNTIME.block_on(con.events().for_each(|_| future::ready(())));
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
    }
}

#[no_mangle]
pub extern "C" fn ts_disconnect() -> *mut c_char {
    eprintln!("ts_disconnect: called");
    let alive = crate::EVENT_LOOP_ALIVE.load(Ordering::SeqCst);
    push_diag(&format!("ts_disconnect: event_loop_alive={}", alive));

    if alive {
        STATE.lock().disconnect_requested = true;
    } else if let Some(mut con) = crate::CONNECTION_STASH.lock().take() {
        let _ = con.disconnect(DisconnectOptions::new());
        let _ = RUNTIME.block_on(con.events().for_each(|_| future::ready(())));
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
        s.audio_decoders.clear();
        s.audio_out.clear();
    }
    to_c_str(r#"{"type":"disconnected","reason":"User disconnected"}"#.to_string())
}

// ─── Poll / Getters ─────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_poll_events() -> *mut c_char {
    crate::flush_panic_log();
    let mut state = STATE.lock();
    let evts: Vec<TsEvent> = state.pending_events.drain(..).collect();
    to_c_str(serde_json::to_string(&evts).unwrap_or_else(|_| "[]".into()))
}

#[no_mangle]
pub extern "C" fn ts_get_channels() -> *mut c_char {
    let state = STATE.lock();
    if !state.connected {
        return to_c_str("[]".to_string());
    }
    to_c_str(serde_json::to_string(&state.channels).unwrap_or_else(|_| "[]".into()))
}

#[no_mangle]
pub extern "C" fn ts_get_clients() -> *mut c_char {
    let state = STATE.lock();
    if !state.connected {
        return to_c_str("[]".to_string());
    }
    to_c_str(serde_json::to_string(&state.clients).unwrap_or_else(|_| "[]".into()))
}

// ─── Send Message ───────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_send_channel_message(_cid: u32, msg: *const c_char) -> u8 {
    let msg = unsafe { std::ffi::CStr::from_ptr(msg) }
        .to_string_lossy()
        .into_owned();
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::SendMessage {
                target_mode: 2,
                target_cid: 0,
                message: msg,
            })
            .is_ok()
        {
            1
        } else {
            0
        }
    } else {
        0
    }
}

// ─── Move ───────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_move_to_channel(cid: u32) -> u8 {
    let own_id = STATE.lock().own_client_id;
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::MoveChannel {
                client_id: own_id as u16,
                channel_id: cid as u64,
            })
            .is_ok()
        {
            1
        } else {
            0
        }
    } else {
        0
    }
}

// ─── Mute ───────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_set_muted(inp: u8, out: u8) -> u8 {
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::SetMuted {
                input: inp != 0,
                output: out != 0,
            })
            .is_ok()
        {
            1
        } else {
            0
        }
    } else {
        0
    }
}

#[no_mangle]
pub extern "C" fn ts_is_connected() -> u8 {
    if STATE.lock().connected {
        1
    } else {
        0
    }
}

// ─── VAD ────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_set_vad_threshold(threshold: f32) {
    STATE.lock().vad_threshold = threshold;
}

#[no_mangle]
pub extern "C" fn ts_set_vad_enabled(enabled: u8) -> u8 {
    STATE.lock().vad_enabled = enabled != 0;
    1
}

#[no_mangle]
pub extern "C" fn ts_is_voice_active() -> u8 {
    let mut state = STATE.lock();
    let active = state.voice_active;
    state.voice_active = false;
    if active {
        1
    } else {
        0
    }
}

// ─── Mic gain ───────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_set_mic_gain(gain: f32) {
    STATE.lock().mic_gain = gain.clamp(0.0, 3.0);
}

// ─── Per-client volume ──────────────────────────────────────────────

/// Set per-client volume in decibels.  Range -20 to +20 dB.
/// Converted to linear gain internally: gain = 10^(dB/20).
#[no_mangle]
pub extern "C" fn ts_set_client_volume(client_id: u16, volume_db: f32) {
    let vol_db = volume_db.clamp(-20.0, 20.0);
    let gain = 10.0_f32.powf(vol_db / 20.0);
    STATE.lock().client_volumes.insert(client_id, gain);
}

// ─── Audio (mic send only, no receive) ──────────────────────────────

#[no_mangle]
pub extern "C" fn ts_start_audio() -> u8 {
    let encoder = match opus_rs::OpusEncoder::new(48000, 1, opus_rs::Application::Voip) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("ts_start_audio: encoder error: {}", e);
            return 0;
        }
    };
    let mut state = STATE.lock();
    state.audio_encoder = Some(encoder);
    state.pcm_in.clear();
    state.audio_seq = 0;
    1
}

#[no_mangle]
pub extern "C" fn ts_stop_audio() {
    let mut state = STATE.lock();
    state.audio_encoder = None;
    state.audio_decoders.clear();
    state.audio_out.clear();
}

/// Drain mixed audio samples from the output buffer.
/// Returns the number of `i16` samples copied to `buf`.
#[no_mangle]
pub extern "C" fn ts_get_audio(buf: *mut i16, buf_len: u32) -> u32 {
    let mut state = STATE.lock();
    let to_copy = (buf_len as usize).min(state.audio_out.len());
    if to_copy == 0 {
        return 0;
    }
    unsafe {
        let slice = std::slice::from_raw_parts_mut(buf, to_copy);
        for (i, dst) in slice.iter_mut().enumerate() {
            *dst = state.audio_out[i];
        }
    }
    state.audio_out.drain(..to_copy);
    to_copy as u32
}

#[no_mangle]
pub extern "C" fn ts_send_audio(data: *const f32, data_len: u32) -> u8 {
    let (connected, mic_gain) = {
        let state = STATE.lock();
        (state.connected, state.mic_gain)
    };
    if !connected {
        return 0;
    }
    if data_len == 0 {
        return 0;
    }
    let raw = unsafe { std::slice::from_raw_parts(data, data_len as usize) };
    let samples: Vec<f32> = raw.to_vec();  // raw samples — gain applied after VAD
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx.send(Command::SendAudio { data: samples }).is_ok() {
            1
        } else {
            0
        }
    } else {
        0
    }
}
