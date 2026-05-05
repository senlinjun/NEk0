use crate::{Command, TsChannel, TsClient, TsEvent, COMMAND_TX, RUNTIME, STATE};

use futures::prelude::*;
use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tsclientlib::messages::c2s::*;
use tsclientlib::{ChannelId, ClientId};
use tsclientlib::{Connection, DisconnectOptions, OutCommandExt, StreamItem};
use tsproto_packets::packets::{AudioData, CodecType, OutAudio};

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

fn hex_slice(data: &[u8]) -> String {
    data.iter()
        .take(32)
        .map(|b| format!("{:02x}", b))
        .collect::<Vec<_>>()
        .join("")
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
    let clients = book
        .clients
        .values()
        .map(|c| TsClient {
            id: c.id.0 as u32,
            nickname: c.name.clone(),
            channel_id: c.channel.0 as u32,
            away: c.away_message.is_some(),
            input_muted: c.input_muted,
            output_muted: c.output_muted,
            is_talking: false,
        })
        .collect();
    (channels, clients)
}

/// Check for clients who stopped talking (no audio for >1s).
/// Call periodically from the event loop.
fn check_talking_timeout() {
    let mut state = STATE.lock();
    let now = Instant::now();
    let timeout = Duration::from_secs(1);
    let mut stopped = Vec::new();
    state.talking_clients.retain(|&id, last| {
        if now.duration_since(*last) > timeout {
            stopped.push(id);
            false
        } else {
            true
        }
    });
    for cid in stopped {
        state.pending_events.push_back(TsEvent::ClientTalking {
            client_id: cid as u32,
            is_talking: false,
        });
        if let Some(c) = state.clients.iter_mut().find(|c| c.id == cid as u32) {
            c.is_talking = false;
        }
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

    {
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
    }

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

    // Subscribe to all channels
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

    // Create command channel with generation guard
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

    // Store Connection for fallback disconnect (if event loop dies)
    *crate::CONNECTION_STASH.lock() = Some(con);

    // Spawn event loop — it takes Connection from stash, catches panics
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

/// Event loop owns Connection permanently.
/// Polls server events AND processes commands from the command channel.
async fn event_loop(
    mut con: Connection,
    mut cmd_rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    generation: u64,
) {
    eprintln!("event_loop: started gen={}", generation);
    push_diag(&format!("event_loop: started (gen={})", generation));
    crate::EVENT_LOOP_ALIVE.store(true, Ordering::SeqCst);
    let mut _loop_count: u64 = 0;
    loop {
        _loop_count += 1;
        // Check for disconnect request (flag-based, bypasses command channel)
        let do_disconnect = {
            let state = STATE.lock();
            state.disconnect_requested
        };
        // Per-iteration heartbeat (1 of every 50 iterations ≈ every 2.5s)
        // if loop_count % 50 == 1 {
        //     push_diag(&format!("loop #{} alive, disconnect_flag={}", loop_count, do_disconnect));
        // }
        if do_disconnect {
            push_diag("event_loop: disconnect_requested flag set");
            let quit = OutQuitMessage::new();
            match quit.send(&mut con) {
                Ok(_) => push_diag("event_loop: OutQuitMessage sent OK"),
                Err(e) => push_diag(&format!("event_loop: OutQuitMessage FAILED: {}", e)),
            }
            // Wait for server to close connection
            push_diag("event_loop: waiting for server disconnect...");
            for i in 0..15 {
                let result =
                    tokio::time::timeout(Duration::from_millis(200), con.events().next()).await;
                match result {
                    Ok(Some(Ok(_))) => {}
                    Ok(Some(Err(_))) | Ok(None) => {
                        push_diag("event_loop: server closed connection");
                        break;
                    }
                    Err(_) => {
                        if i == 14 {
                            push_diag("event_loop: quit wait timeout, exiting");
                        }
                    }
                }
            }
            let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
            if current_gen == generation {
                push_diag("event_loop: disconnect complete, exiting loop");
                STATE
                    .lock()
                    .pending_events
                    .push_back(TsEvent::Disconnected {
                        reason: "User disconnected".into(),
                    });
                STATE.lock().connected = false;
                STATE.lock().disconnect_requested = false;
                *COMMAND_TX.lock() = None;
            } else {
                push_diag(&format!(
                    "event_loop: stale disconnect skipped (gen mismatch)"
                ));
            }
            return;
        }

        // 1. Process all pending commands (non-blocking)
        while let Ok(cmd) = cmd_rx.try_recv() {
            match &cmd {
                Command::SendAudio { data } => {
                    eprintln!("event_loop: cmd=SendAudio({} samples)", data.len());
                }
                _ => eprintln!("event_loop: cmd={:?}", cmd),
            }
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
                    eprintln!("event_loop: sent message");
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
                    eprintln!(
                        "event_loop: moved client {} to channel {}",
                        client_id, channel_id
                    );
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
                    eprintln!("event_loop: set muted input={} output={}", input, output);
                }
                Command::Disconnect => {
                    push_diag("event_loop: got Disconnect command");
                    eprintln!("event_loop: disconnecting gen={}", generation);
                    let quit = OutQuitMessage::new();
                    match quit.send(&mut con) {
                        Ok(_) => push_diag("event_loop: OutQuitMessage sent OK"),
                        Err(e) => push_diag(&format!("event_loop: OutQuitMessage FAILED: {}", e)),
                    }
                    // Keep the Connection alive so the quit packet transmits.
                    // Wait up to 3s for the server to close the connection.
                    push_diag("event_loop: waiting for server disconnect...");
                    for i in 0..15 {
                        let result =
                            tokio::time::timeout(Duration::from_millis(200), con.events().next())
                                .await;
                        match result {
                            Ok(Some(Ok(_))) => {} // Drain events
                            Ok(Some(Err(_))) | Ok(None) => {
                                push_diag("event_loop: server closed connection");
                                break;
                            }
                            Err(_) => {
                                // Timeout after 200ms
                                if i == 14 {
                                    push_diag("event_loop: quit wait timeout, exiting");
                                }
                            }
                        }
                    }
                    let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                    if current_gen == generation {
                        push_diag("event_loop: disconnect complete, exiting loop");
                        STATE
                            .lock()
                            .pending_events
                            .push_back(TsEvent::Disconnected {
                                reason: "User disconnected".into(),
                            });
                        STATE.lock().connected = false;
                        *COMMAND_TX.lock() = None;
                    } else {
                        push_diag(&format!(
                            "event_loop: stale disconnect skipped (gen mismatch)"
                        ));
                    }
                    return;
                }
                Command::SendAudio { data } => {
                    const FRAME: usize = 960; // 20ms at 48kHz mono
                                              // Buffer incoming PCM
                    {
                        let mut state = STATE.lock();
                        state.pcm_in.extend_from_slice(&data);
                    }
                    // Encode full frames — lock only for buffer+encode, release before send
                    loop {
                        let encode_result = {
                            let mut state = STATE.lock();
                            if state.pcm_in.len() < FRAME {
                                break;
                            }
                            let frame: Vec<f32> = state.pcm_in.drain(..FRAME).collect();
                            // VAD gate with hangover: keep sending for ~200ms after voice drops below threshold
                            const HOLD_FRAMES: u32 = 10; // 200ms at 20ms/frame
                            let vad_drop = if state.vad_enabled {
                                let rms = (frame.iter().map(|s| s * s).sum::<f32>() / FRAME as f32).sqrt();
                                if rms >= state.vad_threshold {
                                    state.vad_hold = HOLD_FRAMES;
                                    false // voice active, don't drop
                                } else if state.vad_hold > 0 {
                                    state.vad_hold -= 1;
                                    false // in hangover, keep sending
                                } else {
                                    true // drop this frame
                                }
                            } else {
                                false
                            };
                            if vad_drop {
                                None
                            } else if let Some(ref mut encoder) = state.audio_encoder {
                                let mut opus_out = vec![0u8; 4000];
                                match encoder.encode(&frame, FRAME, &mut opus_out) {
                                    Ok(len) => {
                                        let seq = state.audio_seq;
                                        state.audio_seq = state.audio_seq.wrapping_add(1);
                                        Some((seq, opus_out[..len].to_vec()))
                                    }
                                    Err(e) => {
                                        eprintln!(
                                            "opus encode ERROR: {} (frame_len={})",
                                            e,
                                            frame.len()
                                        );
                                        None
                                    }
                                }
                            } else {
                                eprintln!("event_loop: no encoder for SendAudio");
                                state.pcm_in.clear();
                                None
                            }
                        }; // lock released before send
                        if let Some((seq, opus_data)) = encode_result {
                            let packet = OutAudio::new(&AudioData::C2S {
                                id: seq,
                                codec: CodecType::OpusVoice,
                                data: &opus_data,
                            });
                            match con.send_audio(packet) {
                                Ok(_) => { STATE.lock().voice_active = true; }
                                Err(e) => eprintln!("event_loop: send_audio error: {}", e),
                            }
                        }
                    }
                }
            }
        }

        // 2. Poll one event with short timeout
        let result = tokio::time::timeout(Duration::from_millis(50), con.events().next()).await;

        match result {
            Ok(Some(Ok(item))) => {
                // Event sync handler (wrapped in catch_unwind for safety)
                let handle_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let mut skip_audio = false;
                    if let StreamItem::Audio(packet) = &item {
                        let audio_data = packet.data().data();
                        let codec = audio_data.codec();
                        if codec != CodecType::OpusVoice && codec != CodecType::OpusMusic {
                            skip_audio = true;
                        }
                        if audio_data.data().len() <= 1 {
                            skip_audio = true;
                        }
                    }
                    match &item {
                        StreamItem::Audio(_) if skip_audio => {}
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
                                        STATE.lock().pending_events.push_back(
                                            TsEvent::TextMessage {
                                                from_client: invoker.name.clone(),
                                                from_client_id: invoker.id.0 as u32,
                                                target_mode,
                                                message: message.clone(),
                                            },
                                        );
                                    }
                                    _ => {
                                        let refreshed =
                                            con.get_state().ok().map(|b| refresh_from_book(&b));
                                        if let Some((ch, cl)) = refreshed {
                                            let mut state = STATE.lock();
                                            state.channels = ch;
                                            state.clients = cl;
                                            // Sync talking status from active talkers map
                                            let talking: std::collections::HashSet<u16> =
                                                state.talking_clients.keys().copied().collect();
                                            for c in &mut state.clients {
                                                c.is_talking = talking.contains(&(c.id as u16));
                                            }
                                            state
                                                .pending_events
                                                .push_back(TsEvent::ChannelsUpdated {});
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
                        StreamItem::Audio(packet) => {
                            let audio_data = packet.data().data();
                            // Track who is talking (extract sender from AudioData)
                            let sender_id: Option<u16> = match audio_data {
                                AudioData::S2C { from, .. } | AudioData::S2CWhisper { from, .. } => Some(*from),
                                _ => None,
                            };
                            eprintln!("audio packet: sender_id={:?} codec={:?}", sender_id, audio_data.codec());
                            let opus_bytes = audio_data.data();
                            let mut state = STATE.lock();
                            if let Some(sid) = sender_id {
                                if sid != state.own_client_id as u16 {
                                    let is_new = !state.talking_clients.contains_key(&sid);
                                    state.talking_clients.insert(sid, Instant::now());
                                    if is_new {
                                        eprintln!("TALKING START: client_id={}", sid);
                                        state.pending_events.push_back(TsEvent::ClientTalking {
                                            client_id: sid as u32,
                                            is_talking: true,
                                        });
                                        if let Some(c) = state.clients.iter_mut().find(|c| c.id == sid as u32) {
                                            c.is_talking = true;
                                        }
                                    }
                                }
                            }
                            let mut decoder = state.audio_decoder.take();
                            // Wrap decode in catch_unwind — opus-rs has off-by-one panics
                            let decode_result = if let Some(ref mut dec) = decoder {
                                let frame_size = 960;
                                let mut pcm_out = vec![0.0f32; frame_size];
                                let r =
                                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                        dec.decode(opus_bytes, frame_size, &mut pcm_out)
                                    }));
                                Some(r.map(|inner| inner.map(|samples| (samples, pcm_out))))
                            } else {
                                None
                            };
                            state.audio_decoder = decoder;
                            match decode_result {
                                Some(Ok(Ok((samples, pcm_out)))) => {
                                    let safe_len = samples.min(pcm_out.len());
                                    let peak = pcm_out[..safe_len]
                                        .iter()
                                        .fold(0.0f32, |m, &s| m.max(s.abs()));
                                    let buf_was = state.audio_out.len();
                                    state.audio_out.extend_from_slice(&pcm_out[..safe_len]);
                                    eprintln!(
                                        "audio: decoded {} samp peak={:.4} buf {}->{}",
                                        safe_len,
                                        peak,
                                        buf_was,
                                        state.audio_out.len()
                                    );
                                    state.audio_decoded_count += 1;
                                    let cnt = state.audio_decoded_count;
                                    let errs = state.audio_error_count;
                                    let buf = state.audio_out.len();
                                    if cnt % 25 == 1 {
                                        state.pending_events.push_back(TsEvent::AudioReceived {
                                            decoded: cnt,
                                            errors: errs,
                                            buf_samples: buf,
                                        });
                                    }
                                }
                                Some(Ok(Err(e))) => {
                                    state.audio_error_count += 1;
                                    eprintln!(
                                        "audio: decode err: {} hex={}",
                                        e,
                                        hex_slice(&opus_bytes[..opus_bytes.len().min(32)])
                                    );
                                }
                                Some(Err(panic_err)) => {
                                    state.audio_error_count += 1;
                                    let msg = if let Some(s) = panic_err.downcast_ref::<&str>() {
                                        s.to_string()
                                    } else {
                                        "unknown".into()
                                    };
                                    push_diag(&format!("opus decoder PANICKED: {}", msg));
                                }
                                None => {}
                            }
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
                    s.pending_events.push_back(TsEvent::Disconnected {
                        reason: "Connection closed by server".into(),
                    });
                    *COMMAND_TX.lock() = None;
                } else {
                    eprintln!(
                        "event_loop: stale stream-end ignored (current={}, my={})",
                        current_gen, generation
                    );
                }
                break;
            }
            Err(_) => {
                // Timeout — continue loop
            }
        }
        // Periodically check for clients who stopped talking
        check_talking_timeout();
    }
    eprintln!("event_loop: exited");
}

// ─── Disconnect ─────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_disconnect() -> *mut c_char {
    eprintln!("ts_disconnect: called");
    let alive = crate::EVENT_LOOP_ALIVE.load(Ordering::SeqCst);
    push_diag(&format!("ts_disconnect: event_loop_alive={}", alive));

    if alive {
        // Normal path: event loop will pick up the flag
        push_diag("ts_disconnect: setting disconnect_requested flag");
        STATE.lock().disconnect_requested = true;
    } else {
        // Event loop is dead — send quit directly (wrapped in catch_unwind)
        push_diag("ts_disconnect: event loop DEAD, sending quit directly");
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if let Some(mut con) = crate::CONNECTION_STASH.lock().take() {
                match OutQuitMessage::new().send(&mut con) {
                    Ok(_) => push_diag("ts_disconnect: direct quit sent OK"),
                    Err(e) => push_diag(&format!("ts_disconnect: direct quit FAILED: {}", e)),
                }
                for i in 0..10 {
                    let result = RUNTIME.block_on(tokio::time::timeout(
                        Duration::from_millis(200),
                        con.events().next(),
                    ));
                    match result {
                        Ok(Some(Ok(_))) => {}
                        Ok(Some(Err(_))) | Ok(None) => {
                            push_diag("ts_disconnect: server closed after direct quit");
                            break;
                        }
                        Err(_) => {
                            if i == 9 {
                                push_diag("ts_disconnect: direct quit timeout");
                            }
                        }
                    }
                }
            } else {
                push_diag("ts_disconnect: CONNECTION_STASH is empty");
            }
        }));
        if let Err(e) = result {
            let msg = if let Some(s) = e.downcast_ref::<&str>() {
                s.to_string()
            } else {
                "unknown panic".into()
            };
            push_diag(&format!("ts_disconnect PANICKED: {}", msg));
        }
        STATE.lock().connected = false;
        STATE.lock().disconnect_requested = false;
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
    eprintln!("ts_send_channel_message: len={}", msg.len());
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
    eprintln!("ts_move_to_channel: cid={}", cid);
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
    eprintln!("ts_set_muted: inp={} out={}", inp, out);
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

// ─── VAD (Voice Activation Detection) ────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_set_vad_threshold(threshold: f32) {
    STATE.lock().vad_threshold = threshold;
}

#[no_mangle]
pub extern "C" fn ts_set_vad_enabled(enabled: u8) -> u8 {
    STATE.lock().vad_enabled = enabled != 0;
    1
}

/// Returns 1 if audio was sent within the last poll cycle (auto-resets)
#[no_mangle]
pub extern "C" fn ts_is_voice_active() -> u8 {
    let mut state = STATE.lock();
    let active = state.voice_active;
    state.voice_active = false;
    if active { 1 } else { 0 }
}

// ─── Audio ────────────────────────────────────────────────────────────

/// Start audio: create encoder and decoder
#[no_mangle]
pub extern "C" fn ts_start_audio() -> u8 {
    eprintln!("ts_start_audio: called");
    // Encoder: mono, 48kHz, VOIP mode (matches TeamSpeak OpusVoice)
    let encoder = match opus_rs::OpusEncoder::new(48000, 1, opus_rs::Application::Voip) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("ts_start_audio: encoder error: {}", e);
            return 0;
        }
    };
    // Decoder: mono (TeamSpeak OpusVoice is mono; opus-rs requires matching channels)
    let decoder = match opus_rs::OpusDecoder::new(48000, 1) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("ts_start_audio: decoder error: {}", e);
            return 0;
        }
    };
    let mut state = STATE.lock();
    state.audio_encoder = Some(encoder);
    state.audio_decoder = Some(decoder);
    state.audio_out.clear();
    state.pcm_in.clear();
    state.audio_seq = 0;
    eprintln!("ts_start_audio: OK (enc=mono, dec=mono)");
    1
}

/// Stop audio: drop encoder/decoder, clear buffers
#[no_mangle]
pub extern "C" fn ts_stop_audio() {
    eprintln!("ts_stop_audio: called");
    let mut state = STATE.lock();
    state.audio_encoder = None;
    state.audio_decoder = None;
    state.audio_out.clear();
}

/// Get decoded audio samples (f32 mono 48kHz).
/// Flutter calls this at ~20ms intervals.
/// Returns number of f32 samples written to buf.
#[no_mangle]
pub extern "C" fn ts_get_audio(buf: *mut f32, buf_len: u32) -> u32 {
    let mut state = STATE.lock();
    let available = state.audio_out.len().min(buf_len as usize);
    if available == 0 {
        return 0;
    }
    let peak = state.audio_out[..available]
        .iter()
        .fold(0.0f32, |m, &s| m.max(s.abs()));
    unsafe {
        std::ptr::copy_nonoverlapping(state.audio_out.as_ptr(), buf, available);
    }
    state.audio_out.drain(..available);
    eprintln!(
        "ts_get_audio: {} samp peak={:.4} rem={}",
        available,
        peak,
        state.audio_out.len()
    );
    available as u32
}

/// Push mic PCM data (f32 mono 48kHz) for encoding and sending.
#[no_mangle]
pub extern "C" fn ts_send_audio(data: *const f32, data_len: u32) -> u8 {
    if !STATE.lock().connected {
        return 0;
    }
    if data_len == 0 {
        return 0;
    }
    let samples = unsafe { std::slice::from_raw_parts(data, data_len as usize) }.to_vec();
    // Always forward mic data — VAD gate runs on complete 960-sample frames in event loop
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
