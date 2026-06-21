use crate::{
    Command, TsChannel, TsClient, TsEvent,
    AUDIO_DECODERS, AUDIO_DECODERS_STEREO, AUDIO_STREAM, CB_STATS, CLIENT_BUFFERS,
    COMMAND_TX, FRAME_SIZE, IDENTITY_STASH, PLAYED_SAMPLES, ACTIVE_CLIENT_IDS,
    RUNTIME, STATE, SWIPE_DISCONNECT,
};

use futures::prelude::*;
use opus_rs::OpusDecoder;
use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tsclientlib::messages::c2s::*;
use tsclientlib::{ChannelId, ClientId};
use tsclientlib::{Connection, DisconnectOptions, Identity, OutCommandExt, StreamItem};
use tsproto_packets::packets::{AudioData, CodecType, InAudioBuf, OutAudio};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

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
                    let cid = c.id.0 as u16;
                    let state = STATE.lock();
                    // Primary source: persisted dB value
                    if let Some(&db) = state.client_volumes.get(&cid) {
                        db
                    } else {
                        // Fallback: convert linear gain from jitter buffer → dB
                        drop(state);
                        crate::CLIENT_BUFFERS.get(&cid)
                            .map(|b| {
                                let gain = f32::from_bits(b.volume.load(Ordering::Relaxed));
                                20.0 * gain.max(1e-10).log10()
                            })
                            .unwrap_or(0.0) // default: 0 dB = unity gain
                    }
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

    // --- Push-mode audio output (cpal) with sample-driven mixing ---
    spawn_maintenance_task();

    let host = cpal::default_host();
    if let Some(device) = host.default_output_device() {
        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(48000),
            buffer_size: cpal::BufferSize::Fixed(960),
        };
        match device.build_output_stream(
            &config,
            {
                let current_mix_slot = std::cell::Cell::new(u64::MAX);
                let current_mix_buf = std::cell::RefCell::new([0.0f32; FRAME_SIZE as usize]);
                let cb_seq = std::cell::Cell::new(0u64);
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    // ── diagnostics: first 3 callbacks print liveness ──────────
                    let seq = cb_seq.get();
                    if seq < 3 {
                        eprintln!("[cpal-stats] cb#{} data.len={} played_before={}",
                            seq, data.len(), PLAYED_SAMPLES.load(Ordering::Relaxed));
                        cb_seq.set(seq + 1);
                    }
                    // ── diagnostics: entry timing ────────────────────────────
                    let cb_entry = std::time::Instant::now();
                    let played = PLAYED_SAMPLES.load(Ordering::Relaxed);
                    let played_before = played;
                    // Consistency: next-callback expects this value
                    let expected = CB_STATS.expected_next_played.load(Ordering::Relaxed);
                    if expected != 0 && played_before != expected {
                        CB_STATS.played_mismatches.fetch_add(1, Ordering::Relaxed);
                    }
                    let cb_elapsed_ns = cb_entry.elapsed().as_nanos() as u64;
                    let last_ns = CB_STATS.last_cb_entry_ns.swap(cb_elapsed_ns, Ordering::Relaxed);
                    if last_ns != 0 {
                        CB_STATS.last_interval_us.store(
                            cb_elapsed_ns.wrapping_sub(last_ns) / 1000, Ordering::Relaxed);
                    }
                    let mut slot = played / FRAME_SIZE;
                    let mut offset = (played % FRAME_SIZE) as usize;
                    let mut data_offset = 0usize;
                    let mut mix_count = 0u64;

                    while data_offset < data.len() {
                        // Generate new mix frame when entering a new logical frame
                        if slot != current_mix_slot.get() {
                            mix_count += 1;
                            let mut mix_buf = [0.0f32; FRAME_SIZE as usize];
                            let mut active = 0u32;

                            // Phase A: collect one frame from each active client via snapshot
                            let client_ids = ACTIVE_CLIENT_IDS.load();
                            for &client_id in client_ids.iter() {
                                if let Some(buf) = CLIENT_BUFFERS.get(&client_id) {
                                    let base_seq = buf.base_seq.load(Ordering::Relaxed);
                                    if base_seq == 0 { continue; }
                                    let base_slot = buf.base_slot.load(Ordering::Relaxed);
                                    let expected_seq = slot.wrapping_sub(base_slot)
                                        .wrapping_add(base_seq as u64);
                                    let write_seq = buf.write_seq.load(Ordering::Acquire) as u64;
                                    if write_seq >= expected_seq {
                                        let idx = (expected_seq.wrapping_sub(base_seq as u64))
                                            as usize % 32;
                                        if let Some(frame) = buf.slots[idx].swap(None) {
                                            let vol = f32::from_bits(
                                                buf.volume.load(Ordering::Relaxed));
                                            for i in 0..FRAME_SIZE as usize {
                                                mix_buf[i] += frame[i] as f32 * vol;
                                            }
                                            active += 1;
                                            buf.frame_pool.push(frame);
                                        }
                                    }
                                }
                            }

                            // Phase B: attenuate
                            let atten = if active > 0 {
                                1.0 / (active as f32).sqrt()
                            } else {
                                1.0
                            };
                            for s in &mut mix_buf {
                                *s = (*s * atten).clamp(-32768.0, 32767.0) / 32768.0;
                            }

                            *current_mix_buf.borrow_mut() = mix_buf;
                            current_mix_slot.set(slot);
                        }

                        // Copy from cached mix buffer to output
                        let mix = current_mix_buf.borrow();
                        let remaining_data = data.len() - data_offset;
                        let remaining_frame = FRAME_SIZE as usize - offset;
                        let copy = remaining_data.min(remaining_frame);

                        data[data_offset..data_offset + copy]
                            .copy_from_slice(&mix[offset..offset + copy]);

                        data_offset += copy;
                        offset += copy;
                        if offset >= FRAME_SIZE as usize {
                            offset = 0;
                            slot += 1;
                        }
                    }

                    // ── diagnostics: record stats ────────────────────────
                    CB_STATS.callbacks.fetch_add(1, Ordering::Relaxed);
                    CB_STATS.samples_total.fetch_add(data.len() as u64, Ordering::Relaxed);
                    CB_STATS.mix_frames.fetch_add(mix_count, Ordering::Relaxed);
                    // PLAYED_SAMPLES consistency: old value must equal played_before
                    let old = PLAYED_SAMPLES.fetch_add(data.len() as u64, Ordering::Relaxed);
                    if old != played_before {
                        CB_STATS.played_mismatches.fetch_add(1, Ordering::Relaxed);
                    }
                    // Store expected value for next callback's entry check
                    CB_STATS.expected_next_played.store(old + data.len() as u64, Ordering::Relaxed);
                }
            },
            |err| eprintln!("cpal output error: {}", err),
            None,
        ) {
            Ok(stream) => {
                if stream.play().is_ok() {
                    crate::AUDIO_STREAM.lock().unwrap().0 = Some(stream);
                    eprintln!("cpal: output stream started (Default buffer, sample-driven)");
                } else {
                    eprintln!("cpal: play() failed");
                }
            }
            Err(e) => eprintln!("cpal: build_output_stream failed: {}", e),
        }
    } else {
        eprintln!("cpal: no output device");
    }

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

/// Map a u16 packet sequence number to u32 global sequence space,
/// handling the 65536 wrap. Returns a stale-packet value (much smaller
/// than base) when the sequence has moved backward too far.
fn unwrap_seq(seq: u16, base: u16) -> u32 {
    let base_u32 = base as u32;
    let delta = seq.wrapping_sub(base) as i16 as i32;
    if delta >= 0 {
        base_u32.wrapping_add(delta as u32)
    } else if delta > -32768 {
        // Forward wrap: actual forward distance = 65536 + delta (range 32769..65535)
        base_u32.wrapping_add((65536u32).wrapping_add(delta as u32))
    } else {
        // delta <= -32768: stale/backward packet.
        // Returns a value much smaller than base_u32; outer sanity check discards it.
        base_u32.wrapping_add(delta as u32)
    }
}

/// Decode an incoming audio packet with a per-client OpusDecoder and push
/// the decoded frame into that client's lock-free jitter buffer.
/// No STATE lock held — decoders and buffers are in DashMaps.
fn decode_to_client_buffer(audio_buf: InAudioBuf) {
    const FRAME: usize = 960;
    const TARGET_DELAY: u64 = 2; // 40ms jitter buffer

    // Extract data from the self_cell-wrapped buffer
    let audio = audio_buf.data();
    let audio_data = audio.data();

    let (from_id, seq_id, opus_vec) = match audio_data {
        AudioData::S2C { id, from, data, .. } => (*from, *id as u32, data.to_vec()),
        AudioData::S2CWhisper { id, from, data, .. } => (*from, *id as u32, data.to_vec()),
        _ => return,
    };
    let seq_u16 = seq_id as u16;
    // audio_data and audio are references — they get dropped naturally
    drop(audio_buf);

    // Get or create per-client decoder (mono, fallback stereo) — DashMap, no STATE lock
    let mut decoder = AUDIO_DECODERS.entry(from_id)
        .or_insert_with(|| OpusDecoder::new(48000, 1).expect("mono decoder"));
    let mut pcm_out = vec![0.0f32; FRAME];
    let ok = match decoder.decode(&opus_vec, FRAME, &mut pcm_out) {
        Ok(_) => true,
        Err(_) => {
            drop(decoder);
            let mut stereo = AUDIO_DECODERS_STEREO.entry(from_id)
                .or_insert_with(|| OpusDecoder::new(48000, 2).expect("stereo decoder"));
            let mut stereo_out = vec![0.0f32; FRAME * 2];
            match stereo.decode(&opus_vec, FRAME, &mut stereo_out) {
                Ok(decoded) => {
                    let n = decoded.min(FRAME);
                    for i in 0..n {
                        pcm_out[i] = (stereo_out[i * 2] + stereo_out[i * 2 + 1]) * 0.5;
                    }
                    true
                }
                Err(e) => {
                    eprintln!("opus decode error from client {}: {}", from_id, e);
                    false
                }
            }
        }
    };

    if !ok { return; }

    // Convert f32 → i16 (no volume post-gain — volume is applied as mixing weight in callback)
    let mut frame = vec![0i16; FRAME];
    for (i, &s) in pcm_out.iter().enumerate() {
        frame[i] = (s.clamp(-1.0, 1.0) * 32767.0).clamp(-32768.0, 32767.0) as i16;
    }

    // Get or create per-client jitter buffer — DashMap, no STATE lock
    let buf = CLIENT_BUFFERS.entry(from_id).or_insert_with(|| {
        let b = crate::ClientJitterBuffer::new();
        // Inherit persisted volume when creating a new jitter buffer
        if let Some(&db) = STATE.lock().client_volumes.get(&from_id) {
            let gain = 10.0_f32.powf(db / 20.0);
            b.volume.store(f32::to_bits(gain), Ordering::Release);
        }
        b
    });

    // Init baseline with compare_exchange (prevents race when two packets arrive simultaneously)
    let tmp_global = unwrap_seq(seq_u16, 0);
    if buf.base_seq.load(Ordering::Relaxed) == 0 {
        if buf.base_seq.compare_exchange(0, tmp_global, Ordering::Release, Ordering::Relaxed).is_ok() {
            let now_slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / crate::FRAME_SIZE;
            buf.base_slot.store(now_slot + TARGET_DELAY, Ordering::Release);
        }
    }
    let mut base_seq = buf.base_seq.load(Ordering::Relaxed);
    let global_seq = unwrap_seq(seq_u16, base_seq as u16);
    let write_seq_before = buf.write_seq.load(Ordering::Relaxed);

    // Sanity check: discard if >1000 frames from the last accepted frame.
    // Uses wrapping-min to handle both forward jumps and reordered packets.
    if write_seq_before != 0 {
        let forward = global_seq.wrapping_sub(write_seq_before);
        let backward = write_seq_before.wrapping_sub(global_seq);
        let distance = forward.min(backward);
        if distance > 1000 {
            return;
        }
    }

    // If the reader has overrun during a silence gap, rebase to realign.
    // PLAYED_SAMPLES keeps advancing during silence but TS sequence numbers
    // do not — so even a 1-frame reader lead is permanent (both advance at
    // the same rate and the gap never closes).
    {
        let current_slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / crate::FRAME_SIZE;
        let base_slot_before = buf.base_slot.load(Ordering::Relaxed);
        let reader_expected = current_slot
            .wrapping_sub(base_slot_before)
            .wrapping_add(base_seq as u64);
        // Rebase when: not init, frame is forward (not delayed/reordered),
        // and reader has already passed this frame's play position.
        if write_seq_before != 0
            && global_seq > write_seq_before
            && (global_seq as u64) < reader_expected
        {
            buf.base_seq.store(global_seq, Ordering::Release);
            buf.base_slot.store(current_slot + TARGET_DELAY, Ordering::Release);
            // Clear stale slots from old mapping to prevent misreads
            for slot in &buf.slots {
                if let Some(frame) = slot.swap(None) {
                    buf.frame_pool.push(frame);
                }
            }
            base_seq = global_seq; // local sync after rebase
        }
    }

    // Write frame to the lock-free jitter buffer
    let slot_idx = (global_seq.wrapping_sub(base_seq)) as usize % 32;

    // Evict old frame if overwriting a slot
    if let Some(old) = buf.slots[slot_idx].swap(None) {
        buf.frame_pool.push(old);
    }

    // Get frame buffer from pool or allocate
    let mut write_frame = buf.frame_pool.pop().unwrap_or_else(|| vec![0i16; FRAME]);
    write_frame.copy_from_slice(&frame);
    buf.slots[slot_idx].swap(Some(write_frame));
    buf.write_seq.store(global_seq, Ordering::Release);
    buf.last_packet.store(Some(Instant::now()));

    // Briefly lock STATE only for talking_clients update (monotonic Instant)
    STATE.lock().talking_clients.insert(from_id, Instant::now());
}

/// Background task: periodically cleans up stale clients and refreshes the
/// client-ID snapshot used by the audio callback.
fn spawn_maintenance_task() {
    eprintln!("[cpal-stats] maintenance task starting (stats every 5s)");
    RUNTIME.spawn(async {
        let mut cleanup_tick = tokio::time::interval(Duration::from_secs(5));
        let mut snapshot_tick = tokio::time::interval(Duration::from_millis(500));
        let mut stats_tick = tokio::time::interval(Duration::from_secs(5));
        loop {
            tokio::select! {
                _ = cleanup_tick.tick() => {
                    let now = Instant::now();

                    // Phase 1: collect candidates (read-only iteration, fast)
                    let mut candidates: Vec<u16> = Vec::new();
                    for entry in CLIENT_BUFFERS.iter() {
                        if let Some(last) = entry.value().last_packet.load() {
                            if now.duration_since(last) > Duration::from_secs(10) {
                                candidates.push(*entry.key());
                            }
                        }
                    }

                    // Phase 2: double-check before removal
                    for id in &candidates {
                        let should_remove = match CLIENT_BUFFERS.get(id) {
                            Some(buf) => match buf.last_packet.load() {
                                Some(last) => now.duration_since(last) > Duration::from_secs(10),
                                None => false, // started talking again, skip
                            },
                            None => false, // already gone
                        };
                        if should_remove {
                            if let Some((_, buf)) = CLIENT_BUFFERS.remove(id) {
                                for slot in &buf.slots {
                                    if let Some(frame) = slot.swap(None) {
                                        buf.frame_pool.push(frame);
                                    }
                                }
                            }
                            AUDIO_DECODERS.remove(id);
                            AUDIO_DECODERS_STEREO.remove(id);
                        }
                    }
                }
                _ = snapshot_tick.tick() => {
                    // Refresh client ID snapshot for the audio callback
                    let ids: Vec<u16> = CLIENT_BUFFERS.iter().map(|e| *e.key()).collect();
                    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(ids));
                }
                _ = stats_tick.tick() => {
                    let cbs = CB_STATS.callbacks.swap(0, Ordering::Relaxed);
                    let samps = CB_STATS.samples_total.swap(0, Ordering::Relaxed);
                    let mixes = CB_STATS.mix_frames.swap(0, Ordering::Relaxed);
                    let mism = CB_STATS.played_mismatches.swap(0, Ordering::Relaxed);
                    let intv_us = CB_STATS.last_interval_us.swap(0, Ordering::Relaxed);
                    if cbs > 0 {
                        eprintln!("[cpal-stats] callbacks={} samples={} mix_frames={} interval_us={} mismatches={}",
                            cbs, samps, mixes, intv_us, mism);
                    }
                }
            }
        }
    });
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
                AUDIO_STREAM.lock().unwrap().0 = None;
                CLIENT_BUFFERS.clear();
                AUDIO_DECODERS.clear();
                AUDIO_DECODERS_STEREO.clear();
                PLAYED_SAMPLES.store(0, Ordering::Relaxed);
                ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
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
                        drop(s);
                        AUDIO_STREAM.lock().unwrap().0 = None;
                        CLIENT_BUFFERS.clear();
                        AUDIO_DECODERS.clear();
                        AUDIO_DECODERS_STEREO.clear();
                        PLAYED_SAMPLES.store(0, Ordering::Relaxed);
                        ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
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

        // 2. Poll events — decode each audio packet to its speaker's own buffer.
        //    Do NOT mix — each speaker's audio is kept separate.
        // 2a. First event — up to 20ms timeout (keeps commands responsive)
        let first = tokio::time::timeout(Duration::from_millis(20), con.events().next()).await;
        let mut deferred: Option<StreamItem> = None;

        match first {
            Ok(Some(Ok(StreamItem::Audio(audio_buf)))) => {
                decode_to_client_buffer(audio_buf);
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
                eprintln!("event_loop: stream ended (server disconnect, gen={})", generation);
                let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                if current_gen == generation {
                    let mut s = STATE.lock();
                    s.connected = false;
                    s.pending_events.push_back(TsEvent::Disconnected {
                        reason: "Connection closed by server".into(),
                    });
                    drop(s);
                    AUDIO_STREAM.lock().unwrap().0 = None;
                    CLIENT_BUFFERS.clear();
                    AUDIO_DECODERS.clear();
                    AUDIO_DECODERS_STEREO.clear();
                    PLAYED_SAMPLES.store(0, Ordering::Relaxed);
                    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
                    *COMMAND_TX.lock() = None;
                }
                break;
            }
            Err(_) => {} // 20ms timeout — continue
        }

        // 2b. Drain remaining already-available events (1ms timeout)
        let mut deferred_events: Vec<StreamItem> = Vec::new();
        loop {
            match tokio::time::timeout(Duration::from_millis(1), con.events().next()).await {
                Ok(Some(Ok(StreamItem::Audio(audio_buf)))) => {
                    decode_to_client_buffer(audio_buf);
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
                        s.pending_events.push_back(TsEvent::Disconnected {
                            reason: "Connection closed by server".into(),
                        });
                        drop(s);
                        AUDIO_STREAM.lock().unwrap().0 = None;
                        CLIENT_BUFFERS.clear();
                        AUDIO_DECODERS.clear();
                        AUDIO_DECODERS_STEREO.clear();
                        PLAYED_SAMPLES.store(0, Ordering::Relaxed);
                        ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
                        *COMMAND_TX.lock() = None;
                    }
                    break;
                }
                Err(_) => break,
            }
        }

        // 2c. Process deferred non-audio events
        for item in deferred_events {
            handle_control_item(&item, &mut con, generation);
        }
        if let Some(item) = deferred {
            handle_control_item(&item, &mut con, generation);
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
        // Also send Command::Disconnect for immediate processing
        let tx = COMMAND_TX.lock();
        if let Some(tx) = tx.as_ref() {
            let _ = tx.send(crate::Command::Disconnect);
        }
    } else if let Some(mut con) = crate::CONNECTION_STASH.lock().take() {
        let _ = con.disconnect(DisconnectOptions::new());
        let _ = RUNTIME.block_on(con.events().for_each(|_| future::ready(())));
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
        drop(s);
        AUDIO_STREAM.lock().unwrap().0 = None;
        CLIENT_BUFFERS.clear();
        AUDIO_DECODERS.clear();
        AUDIO_DECODERS_STEREO.clear();
        PLAYED_SAMPLES.store(0, Ordering::Relaxed);
        ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
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
    let mut state = STATE.lock();
    if !state.connected {
        return to_c_str("[]".to_string());
    }
    // Recompute is_talking from live talking_clients data
    // Collect talking client IDs first to avoid split-borrow conflict
    let talking: Vec<u16> = state
        .talking_clients
        .iter()
        .filter(|(_, t)| t.elapsed().as_millis() < 500)
        .map(|(&id, _)| id)
        .collect();
    for c in &mut state.clients {
        c.is_talking = talking.contains(&(c.id as u16));
    }
    // Refresh per-client volumes from persistent store before serializing
    // Snapshot to avoid borrow conflict with mutable clients iteration
    let volume_snapshot: Vec<(u16, f32)> = state.client_volumes.iter().map(|(&k, &v)| (k, v)).collect();
    for c in &mut state.clients {
        if let Some(&(_id, db)) = volume_snapshot.iter().find(|(id, _)| *id == c.id as u16) {
            c.volume = db;
        }
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

    // Persist dB to STATE — source of truth, survives disconnect
    STATE.lock().client_volumes.insert(client_id, vol_db);

    // Also update the live jitter buffer if it exists
    if let Some(buf) = CLIENT_BUFFERS.get(&client_id) {
        buf.volume.store(f32::to_bits(gain), Ordering::Release);
    }
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
    drop(state);
    AUDIO_STREAM.lock().unwrap().0 = None;
    CLIENT_BUFFERS.clear();
    AUDIO_DECODERS.clear();
    AUDIO_DECODERS_STEREO.clear();
    PLAYED_SAMPLES.store(0, Ordering::Relaxed);
    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
}

#[no_mangle]
pub extern "C" fn ts_send_audio(data: *const f32, data_len: u32) -> u8 {
    let connected = STATE.lock().connected;
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
