use crate::{
    Command, TsChannel, TsClient, TsEvent, TsFtEntry, TsServerGroup, TsChannelGroup, TsPerm,
    AUDIO_DECODERS, AUDIO_DECODERS_STEREO, AUDIO_STREAM, CB_STATS, CLIENT_BUFFERS,
    COMMAND_TX, FRAME_SIZE, FT_CLIENT_FT, FT_KIND_DOWNLOAD, FT_KIND_UPLOAD, FT_LISTS, FT_OPS,
    FT_TASK_BY_RC, FT_TASKS, FT_TASK_SEQ, IDENTITY_STASH, PERM_OPS, PLAYED_SAMPLES,
    ACTIVE_CLIENT_IDS, RUNTIME, SFX_ARMED, SFX_DEFERRED_TEARDOWN, SFX_QUEUE,
    SFX_SUPPRESS_DISCONNECT, STATE, SWIPE_DISCONNECT, OUTPUT_RESTART_REQUESTED, PendingFtList,
};

use futures::prelude::*;
use base64::prelude::*;
use opus_rs::OpusDecoder;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::io::{Read as _, Write as _};
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tsclientlib::messages::c2s::*;
use tsclientlib::{ChannelId, ClientId};
use tsclientlib::{Connection, DisconnectOptions, Identity, OutCommandExt, StreamItem};
use tsclientlib::messages::OutMessageTrait;
use tsproto_packets::packets::{
    AudioData, CodecType, Direction, Flags, InAudioBuf, OutAudio, OutCommand, PacketType,
};
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

// ─── File transfer helpers ──────────────────────────────────────────

/// Reads a NUL-terminated C string from a raw pointer ("" for NULL).
unsafe fn cstr_to_string(p: *const c_char) -> String {
    unsafe {
        if p.is_null() {
            return String::new();
        }
        std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

/// Parses a TeamSpeak return_code ("12" or "12:5") into its numeric handle.
fn parse_return_code(rc: &str) -> Option<u16> {
    rc.rsplit(':').next()?.parse().ok()
}

/// Normalizes a remote path into the leading-slash form the TS3 file API
/// expects ("/" root, one slash per segment).
fn normalize_remote_path(path: &str) -> String {
    let trimmed = path.trim();
    // Collapse duplicate slashes and drop trailing ones: "//a//b/" → "/a/b".
    // Some file-area commands reject doubled slashes as an unknown path.
    let cleaned = trimmed
        .split('/')
        .filter(|seg| !seg.is_empty())
        .collect::<Vec<_>>()
        .join("/");
    format!("/{}", cleaned)
}

/// Finds the task registered for a client-side transfer id.
fn ft_task_id_by_client_id(client_ft_id: u16) -> Option<u32> {
    FT_TASKS
        .iter()
        .find(|e| e.value().client_ft_id.load(Ordering::Relaxed) == client_ft_id)
        .map(|e| *e.key())
}

/// Publishes a throttled progress event for a task: at most every 256 KiB or
/// 500 ms so a big transfer does not flood the Dart poll channel.
fn maybe_publish_ft_progress(task_id: u32, task: &crate::FtTask, force: bool) {
    let now = Instant::now();
    let should_push = {
        let mut last = task.last_event.lock();
        match *last {
            Some(t) if !force && now.duration_since(t) < Duration::from_millis(500) => false,
            _ => {
                *last = Some(now);
                true
            }
        }
    };
    if should_push {
        STATE.lock().pending_events.push_back(TsEvent::FtProgress {
            task_id,
            transferred: task.done.load(Ordering::Relaxed),
        });
    }
}

/// Downloads the payload of an accepted ftinitdownload onto the local disk.
/// Runs on its own OS thread with blocking IO — the connection event loop is
/// untouched by the (potentially long) transfer.
fn spawn_download_worker(task_id: u32, mut stream: std::net::TcpStream, total: u64) {
    std::thread::spawn(move || {
        let (local_path, cancel_flag) = match FT_TASKS.get(&task_id) {
            Some(t) => (t.local_path.clone(), t.cancel.clone()),
            None => return, // task vanished while starting
        };
        let result = (|| -> std::io::Result<()> {
            if let Some(parent) = std::path::Path::new(&local_path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let mut file = std::fs::File::create(&local_path)?;
            let mut buf = [0u8; 64 * 1024];
            let mut received: u64 = 0;
            loop {
                if cancel_flag.load(Ordering::Relaxed) {
                    // Keep the partial file; Dart reports the cancellation.
                    drop(file);
                    crate::finish_ft_task(task_id, false, Some("canceled".into()));
                    return Ok(());
                }
                match stream.read(&mut buf) {
                    Ok(0) => break, // EOF — server finished sending
                    Ok(n) => {
                        file.write_all(&buf[..n])?;
                        received += n as u64;
                        FT_TASKS.get(&task_id).map(|t| {
                            t.done.store(received, Ordering::Relaxed);
                            maybe_publish_ft_progress(task_id, &t, false)
                        });
                    }
                    Err(e) => return Err(e),
                }
            }
            if total > 0 && received < total {
                // Server closed early — treat as an incomplete transfer.
                crate::finish_ft_task(
                    task_id,
                    false,
                    Some(format!("incomplete transfer ({received}/{total} bytes)")),
                );
                return Ok(());
            }
            FT_TASKS.get(&task_id).map(|t| {
                t.done.store(received, Ordering::Relaxed);
            });
            crate::finish_ft_task(task_id, true, None);
            Ok(())
        })();
        if let Err(e) = result {
            crate::finish_ft_task(task_id, false, Some(format!("{}", e)));
        }
    });
}

/// Uploads a local file into the accepted ftinitupload stream.
fn spawn_upload_worker(task_id: u32, mut stream: std::net::TcpStream, src: String) {
    std::thread::spawn(move || {
        let cancel_flag = match FT_TASKS.get(&task_id) {
            Some(t) => t.cancel.clone(),
            None => return,
        };
        let result = (|| -> std::io::Result<()> {
            let mut file = std::fs::File::open(&src)?;
            let mut buf = [0u8; 64 * 1024];
            loop {
                if cancel_flag.load(Ordering::Relaxed) {
                    drop(stream); // aborts the transfer server-side
                    crate::finish_ft_task(task_id, false, Some("canceled".into()));
                    return Ok(());
                }
                let n = file.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                stream.write_all(&buf[..n])?;
                FT_TASKS.get(&task_id).map(|t| {
                    let done = t
                        .done
                        .fetch_add(n as u64, Ordering::Relaxed)
                        .saturating_add(n as u64);
                    let _ = done;
                    maybe_publish_ft_progress(task_id, &t, false);
                });
            }
            stream.flush()?;
            // All bytes handed to the OS — wait for the final transfer status:
            // either notifystatusfiletransfer arrives first (handled by the
            // event loop, removes the task with ok=true), or nothing comes
            // within the grace period and we declare success ourselves.
            for _ in 0..32 {
                std::thread::sleep(Duration::from_millis(250));
                if !FT_TASKS.contains_key(&task_id) {
                    return Ok(()); // resolved by the status handler meanwhile
                }
                if cancel_flag.load(Ordering::Relaxed) {
                    drop(stream);
                    crate::finish_ft_task(task_id, false, Some("canceled".into()));
                    return Ok(());
                }
            }
            crate::finish_ft_task(task_id, true, None);
            Ok(())
        })();
        if let Err(e) = result {
            crate::finish_ft_task(task_id, false, Some(format!("{}", e)));
        }
    });
}

fn refresh_from_book(book: &tsclientlib::data::Connection) -> (Vec<TsChannel>, Vec<TsClient>) {
    let mut count: HashMap<u64, u32> = HashMap::new();
    for c in book.clients.values() {
        *count.entry(c.channel.0).or_insert(0) += 1;
    }
    // Refresh the group caches from the book (populated by the
    // servergrouplist/channelgrouplist requests we send on connect).
    {
        let mut state = STATE.lock();
        state.server_groups = book
            .server_groups
            .values()
            .map(|g| TsServerGroup {
                id: g.id.0,
                name: g.name.clone(),
                is_permanent: g.is_permanent,
                needed_member_add_power: g.needed_member_add_power,
                needed_member_remove_power: g.needed_member_remove_power,
                sort_id: g.sort_id,
            })
            .collect();
        state.channel_groups = book
            .channel_groups
            .values()
            .map(|g| TsChannelGroup {
                id: g.id.0,
                name: g.name.clone(),
                is_permanent: g.is_permanent,
                needed_member_add_power: g.needed_member_add_power,
                needed_member_remove_power: g.needed_member_remove_power,
                sort_id: g.sort_id,
            })
            .collect();
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
            is_default: c.is_default.unwrap_or(false),
            permission_hints: c.permission_hints.map(|p| p.bits()).unwrap_or(0),
            needed_talk_power: c.needed_talk_power.unwrap_or(0),
            max_clients: match c.max_clients {
                Some(tsclientlib::MaxClients::Limited(n)) => n as i32,
                _ => -1, // unlimited / inherited / not yet reported
            },
            is_permanent: c.channel_type == tsclientlib::ChannelType::Permanent,
            is_semi_permanent: c.channel_type == tsclientlib::ChannelType::SemiPermanent,
            description: c
                .optional_data
                .as_ref()
                .map(|d| d.description.clone())
                .unwrap_or_default(),
            max_family_clients: match c.max_family_clients {
                Some(tsclientlib::MaxClients::Limited(n)) => n as i32,
                Some(tsclientlib::MaxClients::Unlimited) => 0,
                _ => -1, // inherited / not yet reported
            },
            delete_delay: c.delete_delay.map(|d| d.whole_seconds()).unwrap_or(0),
        })
        .collect();
    let clients: Vec<_> = book
        .clients
        .values()
        .map(|c| {
            let uid = c.uid.as_ref().map(|u| u.to_string());
            // What WE may do to this client (raw client-permission-hint bits).
            let database_id = c.database_id.0;
            let permission_hints = c.permission_hints.map(|p| p.bits()).unwrap_or(0);
            let server_groups: Vec<u64> = c.server_groups.iter().map(|g| g.0).collect();
            let server_group_names: Vec<String> = c
                .server_groups
                .iter()
                .filter_map(|g| book.server_groups.get(g).map(|sg| sg.name.clone()))
                .collect();
            let client_type = match c.client_type {
                tsclientlib::ClientType::Normal => 0u8,
                tsclientlib::ClientType::Query { admin: false } => 1u8,
                tsclientlib::ClientType::Query { admin: true } => 2u8,
            };
            TsClient {
                id: c.id.0 as u32,
                nickname: c.name.clone(),
                channel_id: c.channel.0 as u32,
                uid,
                // Empty hash = the server announces no avatar for this client.
                avatar_hash: if c.avatar_hash.is_empty() {
                    None
                } else {
                    Some(c.avatar_hash.clone())
                },
                database_id,
                away: c.away_message.is_some(),
                input_muted: c.input_muted,
                output_muted: c.output_muted,
                client_type,
                is_channel_commander: c.is_channel_commander,
                is_recording: c.is_recording,
                is_priority_speaker: c.is_priority_speaker,
                talk_power_granted: c.talk_power_granted,
                talk_power: c.talk_power,
                permission_hints,
                server_groups,
                server_group_names,
                channel_group: c.channel_group.0 as u32,
                is_talking: {
                    let state = STATE.lock();
                    state.talking_clients.get(&(c.id.0 as u16))
                        .map(|t| t.elapsed().as_millis() < 500)
                        .unwrap_or(false)
                },
                volume: {
                    let cid = c.id.0 as u16;
                    let state = STATE.lock();
                    // Primary source: persisted dB value keyed by the user UID
                    let persisted = c
                        .uid
                        .as_ref()
                        .and_then(|uid| state.client_volumes.get(&uid.to_string()).copied());
                    drop(state);
                    persisted.unwrap_or_else(|| {
                        // Fallback: convert linear gain from jitter buffer → dB
                        crate::CLIENT_BUFFERS
                            .get(&cid)
                            .map(|b| {
                                let gain = f32::from_bits(b.volume.load(Ordering::Relaxed));
                                20.0 * gain.max(1e-10).log10()
                            })
                            .unwrap_or(0.0) // default: 0 dB = unity gain
                    })
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
    // Disarm channel-event SFX until the initial roster sync is fully
    // consumed; the first BookEvents batch processed by the event loop
    // re-arms it (see handle_control_item). Also reset the disconnect
    // suppression and deferred-teardown flags from a previous connection.
    SFX_ARMED.store(false, Ordering::Relaxed);
    SFX_SUPPRESS_DISCONNECT.store(false, Ordering::Relaxed);
    SFX_DEFERRED_TEARDOWN.store(false, Ordering::Relaxed);

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
    // Ask for the group lists so the book's `server_groups`/`channel_groups`
    // maps (used by the permission-management UI) are populated. The book
    // handles these messages itself and fills the maps, so this is
    // fire-and-forget; the first BookEvents batch after the answer refreshes
    // the STATE caches via refresh_from_book.
    {
        let _ =
            tsclientlib::messages::c2s::OutServerGroupListRequestMessage::new().send(&mut con);
        let _ =
            tsclientlib::messages::c2s::OutChannelGroupListRequestMessage::new().send(&mut con);
    }

    // Own the data we need before sending more commands: `get_state()` borrows
    // `con` immutably, and the permission-list request needs `&mut con`.
    let (own_dbid, sname, oid) = {
        let book = con.get_state().map_err(|e| format!("{}", e))?;
        let own_dbid = book
            .clients
            .get(&book.own_client)
            .map(|c| c.database_id.0)
            .unwrap_or(0);
        (own_dbid, book.server.name.clone(), book.own_client.0 as u32)
    };
    // Ask for our own directly-assigned permission list — a low-threshold
    // hint used by the UI to decide whether to offer the permission-
    // management entry (independent of the pushed hints). The answer arrives
    // as a MessageEvent handled below (fills STATE.own_perms).
    if own_dbid != 0 {
        let part = tsclientlib::messages::c2s::OutClientPermListRequestPart {
            client_db_id: tsclientlib::ClientDbId(own_dbid),
        };
        let _ = tsclientlib::messages::c2s::OutClientPermListRequestMessage::new(
            &mut std::iter::once(part),
        )
        .send(&mut con);
    }

    let book = con.get_state().map_err(|e| format!("{}", e))?;
    let (channels, clients) = refresh_from_book(&book);

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
    restart_output_stream();
    // Queue the connected sound after the stream restart — the restart
    // drains the SFX queue, so pushing before it would lose the request.
    push_sfx(SFX_CONNECTED, "connected");

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
    const TARGET_DELAY: u64 = 6; // 120ms jitter buffer (absorbs network blips)
    const REBASE_LEAD: u64 = 4; // reader ≥4 frames (80ms) ahead before realigning

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
        // Inherit persisted volume when creating a new jitter buffer: resolve
        // the client's UID from the roster, then look up the UID-keyed table.
        let state = STATE.lock();
        let persisted_db = state
            .clients
            .iter()
            .find(|c| c.id as u16 == from_id)
            .and_then(|c| c.uid.as_ref())
            .and_then(|uid| state.client_volumes.get(uid.as_str()).copied());
        drop(state);
        if let Some(db) = persisted_db {
            let gain = 10.0_f32.powf(db / 20.0);
            b.volume.store(f32::to_bits(gain), Ordering::Release);
        }
        b
    });

    // Init baseline with compare_exchange on the packed base_pair (prevents
    // races when two packets arrive simultaneously).
    let tmp_global = unwrap_seq(seq_u16, 0);
    if buf.base_pair.load(Ordering::Relaxed) == 0 {
        let now_slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / crate::FRAME_SIZE;
        let init_pair = ((tmp_global as u64) << 32) | (now_slot + TARGET_DELAY);
        if buf.base_pair.compare_exchange(0, init_pair, Ordering::Release, Ordering::Relaxed).is_ok() {
            // Baseline established with this packet.
        }
    }
    // One atomic load: base_seq and base_slot always come from the same mapping.
    let base_pair = buf.base_pair.load(Ordering::Acquire);
    let mut base_seq = (base_pair >> 32) as u32;
    let base_slot = base_pair & 0xFFFF_FFFF;
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

    // Realign only when the reader has genuinely overtaken the writer (drained
    // silence gap, big network blip). Deliberately NOT triggered by a single
    // late/reordered frame (behind < REBASE_LEAD): those are written late and
    // quietly skipped instead of wiping the whole window on every wobble —
    // wiping was what made stutter persist after network fluctuation. `behind`
    // wraps to a huge value when the writer is actually ahead, which the
    // `< 4096` bound (≈82s) excludes.
    {
        let current_slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / crate::FRAME_SIZE;
        let reader_expected = current_slot
            .wrapping_sub(base_slot)
            .wrapping_add(base_seq as u64);
        let behind = reader_expected.wrapping_sub(global_seq as u64);
        if write_seq_before != 0
            && global_seq > write_seq_before
            && behind >= REBASE_LEAD
            && behind < 4096
        {
            let new_base_seq = global_seq;
            let new_base_slot = current_slot + TARGET_DELAY;
            // Non-destructive rebase: re-home frames that are still playable
            // under the new mapping instead of wiping the whole window.
            // Old slot i held the newest frame with seq ≡ old_base + i
            // (mod JITTER_SLOTS); place it at its residue under new_base.
            let mut kept = 0u32;
            let mut freed = 0u32;
            for (i, slot) in buf.slots.iter().enumerate() {
                if let Some(frame) = slot.swap(None) {
                    let dist = base_seq
                        .wrapping_add(i as u32)
                        .wrapping_sub(new_base_seq) as usize;
                    if dist < crate::JITTER_SLOTS {
                        // Still inside the new window — republish at mapped slot.
                        if let Some(old) = buf.slots[dist].swap(None) {
                            buf.frame_pool.push(old);
                        }
                        buf.slots[dist].swap(Some(frame));
                        kept += 1;
                    } else {
                        // seq now before the new base — truly stale.
                        buf.frame_pool.push(frame);
                        freed += 1;
                    }
                }
            }
            buf.base_pair.store(
                ((new_base_seq as u64) << 32) | new_base_slot,
                Ordering::Release,
            );
            eprintln!(
                "[jbuf] rebase client={} old_base={} new_base={} behind={} kept={} freed={}",
                from_id, base_seq, new_base_seq, behind, kept, freed
            );
            base_seq = new_base_seq; // local sync after rebase (base_slot unused below)
        }
    }

    // Write frame to the lock-free jitter buffer
    let slot_idx = (global_seq.wrapping_sub(base_seq)) as usize % crate::JITTER_SLOTS;

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

// ─── Channel-event SFX playback ─────────────────────────────────────

/// SFX kind ids, mirroring the order of `SFX_BUILTIN` in lib.rs. Values are
/// shared with Dart (`lib/services/sfx_service.dart`) and persisted custom
/// samples are stored per kind — do not renumber.
const SFX_CHANNEL_SWITCHED: u8 = 1;
const SFX_NEUTRAL_TO_CURRENT: u8 = 2;
const SFX_NEUTRAL_AWAY_FROM_CURRENT: u8 = 3;
const SFX_YOU_WERE_MOVED: u8 = 4;
const SFX_YOU_KICKED_CHANNEL: u8 = 5;
const SFX_YOU_KICKED_SERVER: u8 = 6;
const SFX_YOU_WERE_BANNED: u8 = 7;
const SFX_YOU_WERE_POKED: u8 = 8;
const SFX_CHAT_INBOUND: u8 = 9;
const SFX_CHAT_OUTBOUND: u8 = 10;
const SFX_CONNECTED: u8 = 11;
const SFX_DISCONNECTED: u8 = 12;
const SFX_CONNECTION_LOST: u8 = 13;
const SFX_ERROR: u8 = 14;
const SFX_MIC_ACTIVATED: u8 = 15;
const SFX_MIC_MUTED: u8 = 16;
const SFX_SOUND_MUTED: u8 = 17;
const SFX_SOUND_RESUMED: u8 = 18;
const SFX_AWAY_ACTIVATED: u8 = 19;
const SFX_AWAY_DEACTIVATED: u8 = 20;
const SFX_CHANNEL_CREATED: u8 = 21;
const SFX_CHANNEL_DELETED: u8 = 22;
const SFX_CHANNEL_EDITED: u8 = 23;
const SFX_CHANNEL_MOVED: u8 = 24;
const SFX_CHANNELGROUP_CHANGED: u8 = 25;
const SFX_NEUTRAL_CONN_CONNECTED: u8 = 26;
const SFX_NEUTRAL_CONN_DISCONNECTED: u8 = 27;
const SFX_NEUTRAL_CONN_LOST: u8 = 28;
const SFX_NEUTRAL_MOVED_TO_CURRENT: u8 = 29;
const SFX_NEUTRAL_MOVED_AWAY: u8 = 30;
const SFX_NEUTRAL_KICKED_CH_TO_CURRENT: u8 = 31;
const SFX_NEUTRAL_KICKED_CH_AWAY: u8 = 32;
const SFX_NEUTRAL_KICKED_SERVER: u8 = 33;
const SFX_NEUTRAL_BANNED_SERVER: u8 = 34;
const SFX_NEUTRAL_RECORDING_STARTED: u8 = 35;
const SFX_NEUTRAL_RECORDING_STOPPED: u8 = 36;
const SFX_NEUTRAL_RECORDING_ACTIVE: u8 = 37;

/// One parallel SFX playback slot owned by the cpal callback closure.
/// `kind` is the SFX request id (1..=37, see the consts above);
/// `kind == 0` means the slot is idle. `pos` is the sample position within
/// the current sample.
#[derive(Clone, Copy, Default)]
struct SfxSlot {
    kind: u8,
    pos: usize,
}

/// Fixed-capacity FIFO of generated 48 kHz mix samples. Decouples the
/// frame-based mixing clock (PLAYED_SAMPLES) from the hardware callback's
/// arbitrary buffer length / sample rate / channel count.
struct OutRing {
    buf: Vec<f32>,
    head: usize,
    len: usize,
}

/// ~340ms at 48 kHz — far above any single callback request.
const OUT_RING_CAP: usize = 16384;

impl OutRing {
    fn new() -> Self {
        Self {
            buf: vec![0.0; OUT_RING_CAP],
            head: 0,
            len: 0,
        }
    }

    fn push(&mut self, s: f32) {
        if self.len == self.buf.len() {
            // Defensive: drop the oldest sample rather than clobber memory.
            // Unreachable with on-demand generation (len peaks ~1 frame + slack).
            self.head = (self.head + 1) % self.buf.len();
            self.len -= 1;
        }
        if self.head + self.len == self.buf.len() {
            self.buf.copy_within(self.head..self.head + self.len, 0);
            self.head = 0;
        }
        self.buf[self.head + self.len] = s;
        self.len += 1;
    }

    fn pop(&mut self) -> f32 {
        let s = self.buf[self.head];
        self.head += 1;
        self.len -= 1;
        if self.len == 0 {
            self.head = 0;
        }
        s
    }
}

/// Generate one 48 kHz mono mix frame (active clients + channel-event SFX)
/// and append it to the output ring. Runs inside the cpal output callback —
/// no allocation (`mix_buf` is a local array, the ring is pre-allocated).
///
/// This IS the mixing clock: PLAYED_SAMPLES advances by FRAME_SIZE per call
/// and the jitter buffers schedule packets against it (base_slot +
/// TARGET_DELAY), so generation must be driven strictly on demand as the
/// output pass drains the ring — never ahead of real time.
fn gen_output_mix_frame(ring: &mut OutRing, sfx_slots: &mut [SfxSlot; 2]) {
    let slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / FRAME_SIZE;
    let mut mix_buf = [0.0f32; FRAME_SIZE as usize];
    let mut active = 0u32;

    // Phase A: collect one frame from each active client via snapshot
    let client_ids = ACTIVE_CLIENT_IDS.load();
    for &client_id in client_ids.iter() {
        if let Some(buf) = CLIENT_BUFFERS.get(&client_id) {
            // One atomic load: base_seq/base_slot are always a consistent pair.
            let base_pair = buf.base_pair.load(Ordering::Acquire);
            // `base_pair == 0` means "uninitialized". Do NOT test base_seq
            // instead: a speaker's very first voice packet has seq 0, which
            // would make their audio silently skipped forever (the rebase
            // path can't fire while they keep talking).
            if base_pair == 0 {
                continue;
            }
            let base_seq = (base_pair >> 32) as u32;
            let base_slot = base_pair & 0xFFFF_FFFF;
            let expected_seq = slot
                .wrapping_sub(base_slot)
                .wrapping_add(base_seq as u64);
            let write_seq = buf.write_seq.load(Ordering::Acquire) as u64;
            if write_seq >= expected_seq {
                let idx = (expected_seq.wrapping_sub(base_seq as u64)) as usize
                    % crate::JITTER_SLOTS;
                if let Some(frame) = buf.slots[idx].swap(None) {
                    let vol = f32::from_bits(buf.volume.load(Ordering::Relaxed));
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

    // Phase C: channel-event SFX — start queued requests in the two parallel
    // slots and mix them on top of the (already attenuated) voice at fixed
    // 0.5 gain.
    {
        loop {
            match SFX_QUEUE.pop() {
                None => break,
                Some(kind) => {
                    if let Some(sfx) = sfx_slots.iter_mut().find(|s| s.kind == 0) {
                        sfx.kind = kind;
                        sfx.pos = 0;
                    } else {
                        // Both slots busy — drop the request rather than let
                        // the queue grow unbounded.
                        eprintln!(
                            "[sfx] dropped request kind={} (both slots busy)",
                            kind
                        );
                    }
                }
            }
        }
        // Load the active sample table only when at least one slot is playing
        // (ArcSwap::load is lock-free, but there is no reason to touch it
        // while every slot is idle).
        if sfx_slots.iter().any(|s| s.kind != 0) {
            let samples = crate::SFX_SAMPLES.load();
            for sfx in sfx_slots.iter_mut() {
                if sfx.kind == 0 {
                    continue;
                }
                let src: &[f32] = match &samples[(sfx.kind - 1) as usize] {
                    Some(s) => s.as_slice(),
                    None => &[],
                };
                if sfx.pos >= src.len() {
                    // Empty/consumed sample: request done.
                    sfx.kind = 0;
                    continue;
                }
                let mut i = 0usize;
                while i < FRAME_SIZE as usize && sfx.pos + i < src.len() {
                    mix_buf[i] += src[sfx.pos + i] * 0.5;
                    i += 1;
                }
                sfx.pos += i;
                if sfx.pos >= src.len() {
                    sfx.kind = 0;
                }
            }
        }
    }
    // Final clamp after SFX mixing (voice was already clamped in Phase B).
    for s in &mut mix_buf {
        *s = s.clamp(-1.0, 1.0);
    }

    for s in mix_buf {
        ring.push(s);
    }
    let old = PLAYED_SAMPLES.fetch_add(FRAME_SIZE, Ordering::Relaxed);
    // Clock-drift diagnostic: consecutive generations must observe perfectly
    // sequential PLAYED_SAMPLES values (FRAME_SIZE apart).
    let expected = CB_STATS.expected_next_played.load(Ordering::Relaxed);
    if expected != 0 && old != expected {
        CB_STATS.played_mismatches.fetch_add(1, Ordering::Relaxed);
    }
    CB_STATS.expected_next_played.store(old + FRAME_SIZE, Ordering::Relaxed);
    CB_STATS.mix_frames.fetch_add(1, Ordering::Relaxed);
}

/// Rebuilds the cpal output stream. The internal mixing clock stays 48 kHz
/// mono at all times; the device-facing stream is negotiated through a
/// fallback chain (48k/mono/Fixed(960) → 48k/mono/Default → device default
/// channel count / sample rate with in-callback linear resampling and mono
/// duplication), so desktop hosts that reject the fixed Android-style config
/// still work.
///
// ─── Audio device selection ─────────────────────────────────────────

/// User-selected audio devices, addressed by name ("" selection = None =
/// system default). Set from Dart via ts_set_audio_*_device and persisted
/// on the Dart side. cpal does not expose endpoint IDs, so names are the
/// persistence keys — on Windows two endpoints sharing a FriendlyName
/// resolve to the first match.
static OUTPUT_DEVICE_NAME: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
static INPUT_DEVICE_NAME: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// Preferred device names when the user has not chosen one (Linux only):
/// the desktop sound server registers these PCM names in /etc/alsa/conf.d.
/// The ALSA "default" PCM does NOT necessarily route through the sound
/// server — recent alsa-lib versions no longer load the directory where
/// distros ship the `99-pipewire-default.conf` snippet, so "default"
/// resolves to a raw dmix/dsnoop plug on the onboard card and bypasses the
/// desktop's chosen sink/source entirely (apparently silent for users on
/// USB/other default devices). WASAPI (Windows) and oboe (Android) don't
/// have this layering problem: their default device IS the routed one.
#[cfg(target_os = "linux")]
const SOUND_SERVER_PCMS: [&str; 2] = ["pipewire", "pulse"];

fn enumerate_devices(host: &cpal::Host, input: bool) -> Vec<cpal::Device> {
    let res = if input {
        host.input_devices()
    } else {
        host.output_devices()
    };
    match res {
        Ok(iter) => iter.collect(),
        Err(e) => {
            eprintln!("audio: device enumeration failed: {}", e);
            Vec::new()
        }
    }
}

/// First device whose name matches one of [names] (in priority order).
fn find_device_by_name(mut devs: Vec<cpal::Device>, names: &[&str]) -> Option<cpal::Device> {
    for want in names {
        if let Some(i) = devs
            .iter()
            .position(|d| d.name().ok().as_deref() == Some(*want))
        {
            return Some(devs.swap_remove(i));
        }
    }
    None
}

/// Resolves the device to open, in priority order:
/// 1. the user's explicit choice (exact name match),
/// 2. Linux only, no explicit choice: the sound server's PCM
///    ("pipewire"/"pulse") — see [SOUND_SERVER_PCMS],
/// 3. the host's default device.
fn pick_device(host: &cpal::Host, input: bool) -> Option<cpal::Device> {
    let kind = if input { "input" } else { "output" };

    let selected = if input {
        INPUT_DEVICE_NAME.lock().unwrap().clone()
    } else {
        OUTPUT_DEVICE_NAME.lock().unwrap().clone()
    };
    if let Some(want) = selected {
        let devs = enumerate_devices(host, input);
        if let Some(dev) = find_device_by_name(devs, &[want.as_str()]) {
            return Some(dev);
        }
        eprintln!(
            "audio: chosen {} device \"{}\" not available, falling back",
            kind, want
        );
    } else {
        #[cfg(target_os = "linux")]
        {
            let devs = enumerate_devices(host, input);
            if let Some(dev) = find_device_by_name(devs, &SOUND_SERVER_PCMS) {
                return Some(dev);
            }
        }
    }
    if input {
        host.default_input_device()
    } else {
        host.default_output_device()
    }
}

/// Resets playback state exactly like `ts_stop_audio` — buffers are cleared
/// and jitter/decoders are rebuilt on the next incoming audio. Called on
/// connect and, from the maintenance task, when `OUTPUT_RESTART_REQUESTED`
/// is set (device route change or stream error).
fn restart_output_stream() {
    // Drop the old stream first so the new one is the only active consumer.
    AUDIO_STREAM.lock().unwrap().0 = None;
    crate::clear_sfx_queue();
    CLIENT_BUFFERS.clear();
    AUDIO_DECODERS.clear();
    AUDIO_DECODERS_STEREO.clear();
    PLAYED_SAMPLES.store(0, Ordering::Relaxed);
    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
    CB_STATS.expected_next_played.store(0, Ordering::Relaxed);

    let host = cpal::default_host();
    let Some(device) = pick_device(&host, false) else {
        eprintln!("cpal: no output device");
        return;
    };
    eprintln!(
        "cpal: output device \"{}\"",
        device.name().unwrap_or_default()
    );

    let mut candidates = vec![
        cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(48000),
            buffer_size: cpal::BufferSize::Fixed(960),
        },
        cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(48000),
            buffer_size: cpal::BufferSize::Default,
        },
    ];
    if let Ok(default) = device.default_output_config() {
        if default.channels() > 1 {
            candidates.push(cpal::StreamConfig {
                channels: default.channels(),
                sample_rate: cpal::SampleRate(48000),
                buffer_size: cpal::BufferSize::Default,
            });
        }
        if default.sample_rate().0 != 48000 {
            candidates.push(cpal::StreamConfig {
                channels: default.channels(),
                sample_rate: default.sample_rate(),
                buffer_size: cpal::BufferSize::Default,
            });
        }
    }

    for config in candidates {
        let channels = config.channels as usize;
        // 48k mix samples consumed per device output sample (interpolation
        // phase advance); 1.0 = passthrough.
        let ratio = 48000.0 / config.sample_rate.0 as f64;
        let stream = device.build_output_stream(
            &config,
            {
                let ring = std::cell::RefCell::new(OutRing::new());
                let sfx_slots = std::cell::RefCell::new([SfxSlot::default(); 2]);
                // Linear-resampler state carried across callbacks: frac is
                // the position between s0 (last consumed 48k sample) and s1
                // (next ring sample). s1 = None until the first callback.
                let rs_frac = std::cell::Cell::new(0.0f64);
                let rs_s0 = std::cell::Cell::new(0.0f32);
                let rs_s1: std::cell::Cell<Option<f32>> = std::cell::Cell::new(None);
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let mut ring = ring.borrow_mut();
                    let mut sfx = sfx_slots.borrow_mut();

                    let n_out = data.len() / channels;
                    let mut frac = rs_frac.get();
                    let mut s0 = rs_s0.get();
                    let mut s1 = rs_s1.take();
                    if s1.is_none() {
                        // First callback: seed the interpolation pair.
                        while ring.len < 2 {
                            gen_output_mix_frame(&mut ring, &mut sfx);
                        }
                        s0 = ring.pop();
                        s1 = Some(ring.pop());
                    }
                    for j in 0..n_out {
                        let s1v = s1.unwrap_or(0.0);
                        let out = s0 + (s1v - s0) * frac as f32;
                        let base = j * channels;
                        data[base] = out;
                        for d in &mut data[base + 1..base + channels] {
                            *d = out;
                        }
                        frac += ratio;
                        while frac >= 1.0 {
                            frac -= 1.0;
                            s0 = s1v;
                            if ring.len == 0 {
                                gen_output_mix_frame(&mut ring, &mut sfx);
                            }
                            s1 = Some(ring.pop());
                        }
                    }
                    rs_frac.set(frac);
                    rs_s0.set(s0);
                    rs_s1.set(s1);

                    CB_STATS.callbacks.fetch_add(1, Ordering::Relaxed);
                    CB_STATS.samples_total.fetch_add(data.len() as u64, Ordering::Relaxed);
                }
            },
            |err| {
                eprintln!("cpal output error: {}", err);
                // A stream error usually means the output device went away
                // (e.g. Bluetooth route change); rebuild on the next
                // maintenance tick.
                OUTPUT_RESTART_REQUESTED.store(true, Ordering::Relaxed);
            },
            None,
        );
        match stream {
            Ok(stream) => match stream.play() {
                Ok(()) => {
                    crate::AUDIO_STREAM.lock().unwrap().0 = Some(stream);
                    eprintln!(
                        "cpal: output stream started ({} Hz, {} ch, mix resample ratio {:.4})",
                        config.sample_rate.0, config.channels, ratio
                    );
                    return;
                }
                Err(e) => eprintln!("cpal: play() failed ({} Hz): {}", config.sample_rate.0, e),
            },
            Err(e) => eprintln!(
                "cpal: build_output_stream failed ({} Hz, {} ch): {}",
                config.sample_rate.0, config.channels, e
            ),
        }
    }
    eprintln!("cpal: all output stream configurations failed");
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

                    // Rebuild the output stream when a restart was requested
                    // (device route change or cpal stream error). Double-check
                    // the connection is still up right before rebuilding.
                    if OUTPUT_RESTART_REQUESTED.load(Ordering::Relaxed)
                        && STATE.lock().connected
                    {
                        eprintln!("[cpal] restarting output stream (device change / stream error)");
                        restart_output_stream();
                        OUTPUT_RESTART_REQUESTED.store(false, Ordering::Relaxed);
                    }
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

/// Push one SFX request into the playback queue with a log line.
fn push_sfx(kind: u8, detail: &str) {
    SFX_QUEUE.push(kind);
    eprintln!("[sfx] kind={} {}", kind, detail);
}

/// Tear down the output stream and all playback state. This is the exact
/// body the disconnect paths used to run inline; it is reused by the
/// deferred teardown task so a disconnect/error sound can finish playing.
fn teardown_output_state() {
    AUDIO_STREAM.lock().unwrap().0 = None;
    crate::clear_sfx_queue();
    CLIENT_BUFFERS.clear();
    AUDIO_DECODERS.clear();
    AUDIO_DECODERS_STEREO.clear();
    PLAYED_SAMPLES.store(0, Ordering::Relaxed);
    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
}

/// Queue a disconnect/error SFX and defer the output-stream teardown until
/// the *active* sample (built-in or custom override) has finished playing,
/// plus a 400ms margin. Custom samples are capped at 2s, so the stream is
/// never held longer than ~2.4s. The deferred task re-checks `connected` so
/// a fast reconnection does not tear down the new connection's buffers.
fn schedule_sfx_teardown(kind: u8) {
    let samples = crate::SFX_SAMPLES.load();
    let len = samples[(kind - 1) as usize]
        .as_ref()
        .map(|s| s.len())
        .unwrap_or(0);
    drop(samples);
    let play_ms = (len as u64 * 1000 / 48_000) + 400;
    SFX_QUEUE.push(kind);
    SFX_DEFERRED_TEARDOWN.store(true, Ordering::Relaxed);
    eprintln!("[sfx] kind={} queued, deferred teardown in {}ms", kind, play_ms);
    RUNTIME.spawn(async move {
        tokio::time::sleep(Duration::from_millis(play_ms)).await;
        SFX_DEFERRED_TEARDOWN.store(false, Ordering::Relaxed);
        if !STATE.lock().connected {
            teardown_output_state();
        }
    });
}

/// A kick/ban sound is playing through the output stream and the server is
/// closing the connection (SFX_SUPPRESS_DISCONNECT is set, so no
/// "disconnected" sound must be queued on top). Keep the stream alive until
/// the active sample finished, then tear it down. Custom samples are capped
/// at 2s and built-in kick/ban samples are shorter, so 2.4s always lets the
/// sound finish while staying bounded.
fn schedule_teardown_after_kick_sfx() {
    const PRESERVE_MS: u64 = 2400;
    SFX_DEFERRED_TEARDOWN.store(true, Ordering::Relaxed);
    eprintln!("[sfx] kick/ban sound playing, deferred teardown in {}ms", PRESERVE_MS);
    RUNTIME.spawn(async move {
        tokio::time::sleep(Duration::from_millis(PRESERVE_MS)).await;
        SFX_DEFERRED_TEARDOWN.store(false, Ordering::Relaxed);
        if !STATE.lock().connected {
            teardown_output_state();
        }
    });
}

/// Event-driven SFX detection: for each `BookEvents` batch we snapshot the
/// book once via `con.get_state()` (it already reflects this batch's
/// changes) and classify every event against our own client and channel.
/// Triggering events push one SFX request each (deduped per batch where a
/// single notify can produce several `PropertyChanged` events), which the
/// cpal callback plays through the two parallel SFX slots.
fn maybe_trigger_sfx(
    ev: &tsclientlib::events::Event,
    own_client: Option<ClientId>,
    own_channel: Option<ChannelId>,
    book: &tsclientlib::data::Connection,
    batch_fired: &mut u32,
    batch_handled: &mut HashSet<ClientId>,
) {
    use tsclientlib::events::{PropertyId, PropertyValue};
    use tsclientlib::{MessageTarget, Reason};

    if !SFX_ARMED.load(Ordering::Relaxed) {
        return;
    }
    let own_client = match own_client {
        Some(id) => id,
        None => return,
    };
    // NOTE: own_channel must stay an Option — when our own client is removed
    // from the view (kicked/banned), the batch snapshot has no entry for us,
    // so book.clients.get(own_client) is None and own_channel is None. The
    // own-client PropertyRemoved branch below still needs to fire the
    // kick/ban sound; only the other-client branches require a channel.
    let own_channel = own_channel;

    // Per-batch dedupe helper: only channel_edited / channel_moved need it
    // (one notify emits several PropertyChanged events).
    let mut dedupe = |kind: u8| -> bool {
        let bit = 1u32 << (kind - 1);
        if *batch_fired & bit != 0 {
            true
        } else {
            *batch_fired |= bit;
            false
        }
    };

    let trigger: Option<(u8, String)> = match ev {
        tsclientlib::events::Event::Message { target, invoker, .. } => match target {
            // A poke is a dedicated Message target (notifyclientpoke).
            MessageTarget::Poke(_) => Some((SFX_YOU_WERE_POKED, invoker.name.clone())),
            // Own messages are echoed back by the server — the outbound
            // sound already played at send time, so skip them here.
            _ if invoker.id != own_client => Some((SFX_CHAT_INBOUND, invoker.name.clone())),
            _ => return,
        },
        tsclientlib::events::Event::PropertyAdded { id, invoker, extra, .. } => match id {
            PropertyId::Client(cid) => {
                // Someone entered our view. Initial subscribe/resync uses the
                // Subscription reason and stays silent; our own client is
                // handled by the roster sync as well.
                if *cid == own_client || extra.reason == Some(Reason::Subscription) {
                    return;
                }
                match book.clients.get(cid) {
                    Some(c) if Some(c.channel) == own_channel => {
                        if !batch_handled.insert(*cid) {
                            return; // movement already accounted for this client
                        }
                        // Official pack: enterview with no reason = the user
                        // connected to the server; Moved/KickChannel = they
                        // were moved/kicked into view.
                        match extra.reason {
                            Some(Reason::None) => {
                                Some((SFX_NEUTRAL_CONN_CONNECTED, c.name.clone()))
                            }
                            Some(Reason::Moved) => {
                                Some((SFX_NEUTRAL_MOVED_TO_CURRENT, c.name.clone()))
                            }
                            Some(Reason::KickChannel) => {
                                Some((SFX_NEUTRAL_KICKED_CH_TO_CURRENT, c.name.clone()))
                            }
                            _ => return,
                        }
                    }
                    _ => return,
                }
            }
            // A new channel appeared. Only a live creation carries an
            // invoker (the creator); the initial channellist and the
            // subscribe-all replay have none and must stay silent — the
            // SFX_ARMED flag alone is not enough because the sync arrives
            // in later BookEvents batches than the one that arms it.
            PropertyId::Channel(_) => match invoker {
                Some(_) => Some((SFX_CHANNEL_CREATED, "".to_string())),
                None => return,
            },
            _ => return,
        },
        tsclientlib::events::Event::PropertyChanged { id, old, invoker, extra, .. } => match id {
            PropertyId::ClientChannel(cid) => {
                let old_channel = match old {
                    PropertyValue::ChannelId(ch) => *ch,
                    _ => return,
                };
                let new_client = match book.clients.get(cid) {
                    Some(c) => c,
                    None => return,
                };
                let new_channel = new_client.channel;
                if old_channel == new_channel {
                    return;
                }
                if *cid == own_client {
                    // Kicked from our channel: the server may deliver the
                    // kick as a clientmove (reasonid=4) instead of a
                    // clientleftview, so handle it here too.
                    if extra.reason == Some(Reason::KickChannel) {
                        Some((SFX_YOU_KICKED_CHANNEL, new_client.name.clone()))
                    } else {
                        let sound = match invoker {
                            // Moved by someone else plays you_were_moved;
                            // a voluntary move plays channel_switched.
                            Some(inv) if inv.id != own_client => SFX_YOU_WERE_MOVED,
                            _ => SFX_CHANNEL_SWITCHED,
                        };
                        // Official CLIENT_RECORDING_IN_CHANNEL: entering a
                        // channel that already has a recorder.
                        if book.clients.values().any(|c| {
                            c.id != own_client && c.channel == new_channel && c.is_recording
                        }) {
                            push_sfx(SFX_NEUTRAL_RECORDING_ACTIVE, "recorder in channel");
                        }
                        Some((sound, new_client.name.clone()))
                    }
                } else {
                    if !batch_handled.insert(*cid) {
                        return; // movement already accounted for this client
                    }
                    // Other client moved between channels: classify by reason
                    // (None = self-switch, Moved = admin-moved, KickChannel =
                    // kicked from channel) against our own channel.
                    if Some(old_channel) == own_channel && Some(new_channel) != own_channel {
                        let sound = match extra.reason {
                            Some(Reason::KickChannel) => SFX_NEUTRAL_KICKED_CH_AWAY,
                            Some(Reason::Moved) => SFX_NEUTRAL_MOVED_AWAY,
                            _ => SFX_NEUTRAL_AWAY_FROM_CURRENT,
                        };
                        Some((sound, new_client.name.clone()))
                    } else if Some(old_channel) != own_channel && Some(new_channel) == own_channel {
                        let sound = match extra.reason {
                            Some(Reason::KickChannel) => SFX_NEUTRAL_KICKED_CH_TO_CURRENT,
                            Some(Reason::Moved) => SFX_NEUTRAL_MOVED_TO_CURRENT,
                            _ => SFX_NEUTRAL_TO_CURRENT,
                        };
                        Some((sound, new_client.name.clone()))
                    } else {
                        return;
                    }
                }
            }
            // Recording state of a client in our channel.
            PropertyId::ClientIsRecording(cid) => {
                let client = match book.clients.get(cid) {
                    Some(c) => c,
                    None => return,
                };
                if *cid == own_client || Some(client.channel) != own_channel {
                    return;
                }
                match old {
                    PropertyValue::Bool(old_rec) => {
                        if client.is_recording == *old_rec {
                            return;
                        }
                        if client.is_recording {
                            Some((SFX_NEUTRAL_RECORDING_STARTED, client.name.clone()))
                        } else {
                            Some((SFX_NEUTRAL_RECORDING_STOPPED, client.name.clone()))
                        }
                    }
                    _ => return,
                }
            }
            // A channel was moved (parent changed). Order-only changes and
            // subscribe/bookkeeping updates are ignored.
            PropertyId::ChannelParent(_) => {
                if dedupe(SFX_CHANNEL_MOVED) {
                    return;
                }
                Some((SFX_CHANNEL_MOVED, "".to_string()))
            }
            PropertyId::ChannelOrder(_)
            | PropertyId::ChannelSubscribed(_)
            | PropertyId::ChannelPermissionHints(_) => return,
            // Anything else on a Channel is an edit (name, topic, codec, ...).
            PropertyId::ChannelName(_)
            | PropertyId::ChannelGuid(_)
            | PropertyId::ChannelTopic(_)
            | PropertyId::ChannelCodec(_)
            | PropertyId::ChannelCodecQuality(_)
            | PropertyId::ChannelMaxClients(_)
            | PropertyId::ChannelMaxFamilyClients(_)
            | PropertyId::ChannelChannelType(_)
            | PropertyId::ChannelIsDefault(_)
            | PropertyId::ChannelHasPassword(_)
            | PropertyId::ChannelCodecLatencyFactor(_)
            | PropertyId::ChannelIsUnencrypted(_)
            | PropertyId::ChannelDeleteDelay(_)
            | PropertyId::ChannelNeededTalkPower(_)
            | PropertyId::ChannelForcedSilence(_)
            | PropertyId::ChannelPhoneticName(_)
            | PropertyId::ChannelIcon(_)
            | PropertyId::ChannelIsPrivate(_)
            | PropertyId::ChannelStorageQuota(_) => {
                if dedupe(SFX_CHANNEL_EDITED) {
                    return;
                }
                Some((SFX_CHANNEL_EDITED, "".to_string()))
            }
            // Own-client state echoed by the server.
            PropertyId::ClientInputMuted(cid) if *cid == own_client => {
                match book.clients.get(cid).map(|c| c.input_muted) {
                    Some(true) => Some((SFX_MIC_MUTED, "".to_string())),
                    Some(false) => Some((SFX_MIC_ACTIVATED, "".to_string())),
                    None => return,
                }
            }
            PropertyId::ClientOutputMuted(cid) if *cid == own_client => {
                match book.clients.get(cid).map(|c| c.output_muted) {
                    Some(true) => Some((SFX_SOUND_MUTED, "".to_string())),
                    Some(false) => Some((SFX_SOUND_RESUMED, "".to_string())),
                    None => return,
                }
            }
            PropertyId::ClientAwayMessage(cid) if *cid == own_client => {
                match book.clients.get(cid).and_then(|c| c.away_message.as_ref()) {
                    Some(_) => Some((SFX_AWAY_ACTIVATED, "".to_string())),
                    None => Some((SFX_AWAY_DEACTIVATED, "".to_string())),
                }
            }
            PropertyId::ClientChannelGroup(cid) if *cid == own_client => {
                // Joining a channel auto-assigns the channel's default
                // channel group; the server broadcasts that as an update
                // (notifyclientupdated with client_channel_group_id) with
                // no real invoker. That is not a real group change — TS3
                // plays this sound only when an admin changes the group —
                // so require a genuine third-party invoker.
                let real_invoker = match invoker {
                    Some(inv) => inv.id != own_client && inv.id != ClientId(0),
                    None => false,
                };
                if !real_invoker {
                    eprintln!(
                        "[sfx] own channel-group update skipped (invoker={:?})",
                        invoker.as_ref().map(|i| (i.id.0, i.name.clone()))
                    );
                    return;
                }
                Some((SFX_CHANNELGROUP_CHANGED, "".to_string()))
            }
            _ => return,
        },
        tsclientlib::events::Event::PropertyRemoved { id, old, extra, .. } => match id {
            PropertyId::Client(cid) => {
                let removed = match old {
                    PropertyValue::Client(c) => c,
                    _ => return,
                };
                if *cid == own_client {
                    // Our own client left the server view. Only kicks and
                    // bans produce a sound; everything else (normal leave,
                    // server shutdown, ...) is covered by the disconnect
                    // sound and must not double-fire. The ban case also
                    // suppresses the upcoming "disconnected" sound.
                    match extra.reason {
                        Some(Reason::KickChannel) => {
                            Some((SFX_YOU_KICKED_CHANNEL, removed.name.clone()))
                        }
                        Some(Reason::KickServer) => {
                            // Server closes the connection right after a
                            // server kick — suppress the "disconnected" sound
                            // so it does not stack on the kick sound.
                            SFX_SUPPRESS_DISCONNECT.store(true, Ordering::Relaxed);
                            Some((SFX_YOU_KICKED_SERVER, removed.name.clone()))
                        }
                        Some(Reason::KickServerBan) => {
                            SFX_SUPPRESS_DISCONNECT.store(true, Ordering::Relaxed);
                            Some((SFX_YOU_WERE_BANNED, removed.name.clone()))
                        }
                        _ => return,
                    }
                } else if Some(removed.channel) != own_channel {
                    // Not in our channel — no sound.
                    return;
                } else {
                    if !batch_handled.insert(*cid) {
                        return; // movement already accounted for this client
                    }
                    // Someone in our channel left the server (reasonid 0 =
                    // normal quit, 3 = timeout, 4/5/6 = kicked/banned,
                    // 1 = moved away).
                    match extra.reason {
                        Some(Reason::LostConnection) => {
                            Some((SFX_NEUTRAL_CONN_LOST, removed.name.clone()))
                        }
                        Some(Reason::KickChannel) => {
                            Some((SFX_NEUTRAL_KICKED_CH_AWAY, removed.name.clone()))
                        }
                        Some(Reason::KickServer) => {
                            Some((SFX_NEUTRAL_KICKED_SERVER, removed.name.clone()))
                        }
                        Some(Reason::KickServerBan) => {
                            Some((SFX_NEUTRAL_BANNED_SERVER, removed.name.clone()))
                        }
                        Some(Reason::Moved) => {
                            Some((SFX_NEUTRAL_MOVED_AWAY, removed.name.clone()))
                        }
                        Some(Reason::None) | Some(Reason::Clientdisconnect) => {
                            Some((SFX_NEUTRAL_CONN_DISCONNECTED, removed.name.clone()))
                        }
                        // Subscription / Channelupdate / Channeledit /
                        // Serverstop / ClientdisconnectServerShutdown: not a
                        // real leave, stay quiet.
                        _ => return,
                    }
                }
            }
            PropertyId::Channel(_) => Some((SFX_CHANNEL_DELETED, "".to_string())),
            _ => return,
        },
    };

    if let Some((kind, detail)) = trigger {
        push_sfx(kind, &detail);
    }
}

/// Lets a hand-built packet ride the normal `send_with_result` path so
/// return_code bookkeeping (and the MessageResult it produces) stays in one
/// place. We serialize `cpw` exactly like the official client: present for
/// every ft command, empty (bare key) when the channel has no password.
struct RawCmd(OutCommand);

impl OutMessageTrait for RawCmd {
    fn to_packet(self) -> OutCommand {
        self.0
    }
}

/// Registers a permission-management command's return_code so the
/// `MessageResult` handler can resolve it into a `PermOp` event; on a send
/// failure, pushes the failing event immediately.
fn perm_op_send(
    result: std::result::Result<tsclientlib::MessageHandle, tsclientlib::Error>,
    token: &str,
) {
    match result {
        Ok(handle) => {
            crate::PERM_OPS.lock().insert(handle.0, token.to_string());
            push_diag(&format!("perm op {}: sent (rc={})", token, handle.0));
        }
        Err(e) => {
            push_diag(&format!("perm op {}: send failed: {}", token, e));
            STATE.lock().pending_events.push_back(TsEvent::PermOp {
                token: token.to_string(),
                ok: false,
                error: Some(format!("{}", e)),
            });
        }
    }
}

/// The own client id for self-protection guards. Prefers the live book value:
/// the cached `STATE.own_client_id` is only written at connect and goes stale
/// after a temporary-disconnect reconnect (the server may reassign our clid).
/// Refreshes the cache when the live value differs.
fn own_client_id_or_cache(con: &tsclientlib::Connection) -> u32 {
    if let Ok(book) = con.get_state() {
        let own = book.own_client.0 as u32;
        if own != 0 {
            let mut state = STATE.lock();
            if state.own_client_id != own {
                state.own_client_id = own;
            }
        }
        return own;
    }
    STATE.lock().own_client_id
}

/// The ft commands REQUIRE the `cpw` argument to be present even for
/// unlocked channels (omitting it fails with 0x0603 "parameter not found").
/// Empty is encoded as the bare key (write_arg drops a valueless `=`),
/// matching the official client's wire format.
fn encoded_cpw(password: &Option<String>) -> String {
    password
        .as_deref()
        .map(|p| tsproto_types::crypto::encode_password(p.as_bytes()))
        .unwrap_or_default()
}

/// Schedules the deferred finalize of a listing. The server streams the
/// rows after the result frame, and our event pipeline may surface those
/// rows one or two poll ticks late — so the finalize waits long enough for
/// every straggler to accumulate, then emits everything collected.
fn schedule_ft_list_finish(code: u16) {
    {
        let mut lists = FT_LISTS.lock();
        match lists.get_mut(&code) {
            Some(p) => {
                if p.finalize_scheduled {
                    return;
                }
                p.finalize_scheduled = true;
            }
            None => return,
        }
    }
    crate::RUNTIME.spawn(async move {
        tokio::time::sleep(Duration::from_millis(600)).await;
        let pending = FT_LISTS.lock().remove(&code);
        if let Some(pending) = pending {
            push_diag(&format!(
                "ft list {}: finalize entries={} result={}",
                pending.token,
                pending.entries.len(),
                if pending.result_ok { "ok" } else { "error" }
            ));
            STATE
                .lock()
                .pending_events
                .push_back(TsEvent::FtListing {
                    token: pending.token,
                    entries: pending.entries,
                    error: pending.result_error,
                });
        }
    });
}

/// Logs the exact wire form of a request — the fastest way to diff our
/// traffic against what the official client sends.
fn push_wire_diag(tag: &str, packet: &OutCommand) {
    push_diag(&format!(
        "ft req {}: {}",
        tag,
        String::from_utf8_lossy(packet.0.content())
    ));
}

/// Drains the raw incoming-command queue the vendored lib fills (NEK0-DIAG)
/// into the diag channel so the exact server wire order is visible.
fn drain_raw_incoming(con: &mut Connection) {
    // The queue lives on the inner connection state; access it through the
    // unstable raw-client accessor is not available for Connection, so the
    // vendored ConnectedConnection field is reached via get_state-free path:
    // Connection::events already consumed the frames, we only need the raw
    // strings. Use the public accessor added on ConnectionState::Connected.
    if let Ok(raw) = con.raw_incoming() {
        while let Some(line) = raw.lock().unwrap().pop_front() {
            push_diag(&format!("raw in: {}", line));
        }
    }
}

/// Routes one event item: file-transfer payloads carry an owned TcpStream,
/// so they are consumed here by value; everything else delegates to the
/// catch_unwind-wrapped control handler.
fn handle_event_item(item: StreamItem, con: &mut Connection, generation: u64) {
    match item {
        StreamItem::FileDownload(handle, result) => {
            handle_file_download(handle.0, result);
        }
        StreamItem::FileUpload(handle, result) => {
            handle_file_upload(handle.0, result);
        }
        other => handle_control_item(&other, con, generation),
    }
}

/// The server accepted a download request and handed over the raw TCP stream
/// carrying the file bytes; spawn the blocking worker that writes it out.
fn handle_file_download(client_ft_id: u16, result: tsclientlib::FileDownloadResult) {
    let total = result.size;
    match result.stream.into_std() {
        Ok(std_stream) => {
            let _ = std_stream.set_nonblocking(false);
            if let Some(task_id) = ft_task_id_by_client_id(client_ft_id) {
                if let Some(t) = FT_TASKS.get_mut(&task_id) {
                    t.total.store(total, Ordering::Relaxed);
                }
                maybe_publish_ft_progress(task_id, &FT_TASKS.get(&task_id).unwrap(), true);
                spawn_download_worker(task_id, std_stream, total);
            }
        }
        Err(e) => {
            if let Some(task_id) = ft_task_id_by_client_id(client_ft_id) {
                crate::finish_ft_task(
                    task_id,
                    false,
                    Some(format!("transfer stream failed: {}", e)),
                );
            }
        }
    }
}

/// Our upload slot was accepted; stream the local file into it.
fn handle_file_upload(client_ft_id: u16, result: tsclientlib::FileUploadResult) {
    match result.stream.into_std() {
        Ok(std_stream) => {
            let _ = std_stream.set_nonblocking(false);
            if let Some(task_id) = ft_task_id_by_client_id(client_ft_id) {
                let src = FT_TASKS.get(&task_id).map(|t| t.local_path.clone());
                if let Some(src) = src {
                    spawn_upload_worker(task_id, std_stream, src);
                }
            }
        }
        Err(e) => {
            if let Some(task_id) = ft_task_id_by_client_id(client_ft_id) {
                crate::finish_ft_task(
                    task_id,
                    false,
                    Some(format!("transfer stream failed: {}", e)),
                );
            }
        }
    }
}

fn handle_control_item(item: &StreamItem, con: &mut Connection, _generation: u64) {
    let handle_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match item {
            StreamItem::Audio(_) => {} // handled upstream
            StreamItem::BookEvents(events) => {
                // Snapshot the book once per batch — it already includes this
                // batch's changes, so each event can be evaluated against the
                // state that results from it.
                let book = con.get_state().ok();
                let own_client = book.as_ref().map(|b| b.own_client);
                let own_channel = book
                    .as_ref()
                    .and_then(|b| b.clients.get(&b.own_client))
                    .map(|c| c.channel);
                // Per-batch dedupe mask for channel_edited / channel_moved,
                // and per-client set so a kicked client (leftview + moved in
                // the same batch) only ever produces one sound.
                let mut batch_fired: u32 = 0;
                let mut batch_handled: HashSet<ClientId> = HashSet::new();
                for ev in events {
                    match ev {
                        tsclientlib::events::Event::Message {
                            target,
                            invoker,
                            message,
                        } => {
                            // A poke is a dedicated Message target
                            // (notifyclientpoke) and must NOT show up in the
                            // chat — it gets its own event (Dart shows a
                            // system notification). Everything else is a text
                            // message routed by target mode.
                            match target {
                                tsclientlib::MessageTarget::Poke(_) => {
                                    STATE.lock().pending_events.push_back(TsEvent::Poke {
                                        from_client: invoker.name.clone(),
                                        from_client_id: invoker.id.0 as u32,
                                        message: message.clone(),
                                    });
                                }
                                tsclientlib::MessageTarget::Server => {
                                    STATE.lock().pending_events.push_back(TsEvent::TextMessage {
                                        from_client: invoker.name.clone(),
                                        from_client_id: invoker.id.0 as u32,
                                        target_mode: 3u8,
                                        message: message.clone(),
                                    });
                                }
                                tsclientlib::MessageTarget::Channel => {
                                    STATE.lock().pending_events.push_back(TsEvent::TextMessage {
                                        from_client: invoker.name.clone(),
                                        from_client_id: invoker.id.0 as u32,
                                        target_mode: 2u8,
                                        message: message.clone(),
                                    });
                                }
                                tsclientlib::MessageTarget::Client(_) => {
                                    STATE.lock().pending_events.push_back(TsEvent::TextMessage {
                                        from_client: invoker.name.clone(),
                                        from_client_id: invoker.id.0 as u32,
                                        target_mode: 1u8,
                                        message: message.clone(),
                                    });
                                }
                            }
                            if let Some(b) = book.as_ref() {
                                maybe_trigger_sfx(ev, own_client, own_channel, b, &mut batch_fired, &mut batch_handled);
                            }
                        }
                        _ => {
                            if let Some(b) = book.as_ref() {
                                let (ch, cl) = refresh_from_book(b);
                                let mut state = STATE.lock();
                                state.channels = ch;
                                state.clients = cl;
                                state.pending_events.push_back(TsEvent::ChannelsUpdated {});
                                drop(state);
                                maybe_trigger_sfx(ev, own_client, own_channel, b, &mut batch_fired, &mut batch_handled);
                            }
                        }
                    }
                }
                // The first BookEvents batch processed by the event loop may
                // still be the tail of the initial roster sync (and on a
                // temporary-disconnect reconnect it is the full resync), so it
                // is consumed silently; everything after it is real activity.
                SFX_ARMED.store(true, Ordering::Relaxed);
            }
            StreamItem::MessageEvent(msg) => {
                use tsclientlib::messages::s2c::InMessage;
                if let InMessage::FileList(fl) = msg {
                    // Directory listing frames of an ftgetfilelist request:
                    // accumulate entries keyed by the echoed return_code; a
                    // trailing error frame resolves as MessageResult below.
                    if let Some(code) = fl.return_code.as_deref().and_then(parse_return_code) {
                        let mut lists = FT_LISTS.lock();
                        if let Some(pending) = lists.get_mut(&code) {
                            let incoming = fl.iter().count();
                            for part in fl.iter() {
                                pending.entries.push(TsFtEntry {
                                    name: part.name.clone(),
                                    size: part.size,
                                    datetime: part.date_time.unix_timestamp(),
                                    is_file: part.is_file,
                                });
                            }
                            push_diag(&format!(
                                "ft list {}: frame +{} (total {})",
                                pending.token,
                                incoming,
                                pending.entries.len()
                            ));
                        } else {
                            push_diag("ft list frame for unknown return code");
                        }
                    }
                } else if let InMessage::FileListFinished(fin) = msg {
                    // Rows are streamed AFTER the result frame (observed
                    // live); this marker says "no more rows for this
                    // directory". It carries no return_code, so match via
                    // the directory address, then finalize.
                    let to_finalize: Vec<u16> = {
                        let mut lists = FT_LISTS.lock();
                        let mut found: Vec<u16> = Vec::new();
                        for part in fin.iter() {
                            for (code, p) in lists.iter_mut() {
                                if p.cid == part.channel_id.0
                                    && p.path == part.path
                                    && !p.finished_seen
                                {
                                    p.finished_seen = true;
                                    found.push(*code);
                                }
                            }
                        }
                        found
                    };
                    // Finalize OUTSIDE the lock: schedule_ft_list_finish
                    // locks FT_LISTS itself, and parking_lot mutexes are
                    // not reentrant — calling it under the lock freezes
                    // the connection event loop for good.
                    for code in to_finalize {
                        schedule_ft_list_finish(code);
                    }
                } else if let InMessage::TextMessage(txt) = msg {
                    for p in txt.iter() {
                        STATE.lock().pending_events.push_back(TsEvent::TextMessage {
                            from_client: p.invoker_name.clone(),
                            from_client_id: p.invoker_id.0 as u32,
                            target_mode: p.target as u8,
                            message: p.message.clone(),
                        });
                    }
                } else if let InMessage::ClientPermList(pl) = msg {
                    // OUR OWN directly-assigned permission list, requested on
                    // connect. Store it for the UI (permission-management
                    // entry visibility). Only directly-assigned perms are
                    // listed, so treat it as a hint, not authorization.
                    let list: Vec<TsPerm> = pl
                        .iter()
                        .map(|p| TsPerm {
                            name: p.permission_name_id.clone().unwrap_or_default(),
                            value: p.permission_value,
                            negated: p.permission_negated,
                            skip: p.permission_skip,
                        })
                        .collect();
                    STATE.lock().own_perms = list;
                    push_diag(&format!(
                        "own clientpermlist: {} entries",
                        STATE.lock().own_perms.len()
                    ));
                } else if let InMessage::CommandError(err) = msg {
                    // Our commands carry no return_code, so server rejections
                    // arrive here as bare error messages instead of results.
                    // Attribute an invalid-channel-password rejection to the
                    // most recent clientmove within a short time window; all
                    // other errors are logged as diagnostics.
                    for entry in err.iter() {
                        if entry.id == tsclientlib::TsError::ChannelInvalidPassword {
                            const MOVE_WINDOW: Duration = Duration::from_secs(5);
                            // Take the pending move as an owned value FIRST so
                            // the STATE guard is dropped before pushing the
                            // event below. A match whose scrutinee held the
                            // guard must never re-lock STATE in its arms —
                            // parking_lot would self-deadlock the connection
                            // loop (and freeze the UI thread polling events).
                            let pending = STATE.lock().pending_move.take();
                            match pending {
                                Some((cid, at)) if at.elapsed() <= MOVE_WINDOW => {
                                    STATE.lock().pending_events.push_back(TsEvent::MoveRejected {
                                        channel_id: cid as u32,
                                    });
                                }
                                Some(_) => {
                                    push_diag("channel-password rejection is stale, dropped");
                                }
                                None => {
                                    push_diag(
                                        "server rejected a command: invalid channel password",
                                    );
                                }
                            }
                        } else {
                            push_diag(&format!("server rejected command: {:?}", entry.id));
                        }
                    }
                }
            }
            StreamItem::MessageResult(handle, res) => {
                // A command answer carrying one of OUR return_codes. Resolves
                // both pending directory listings and mkdir/delete acks; the
                // final error frame is what ends either kind of exchange.
                let err_text = res
                    .as_ref()
                    .err()
                    .map(|e| format!("{:?} ({:#06x})", e.error, e.error as i32));
                // Permission-management commands (group add/remove, channel
                // perm grant/revoke) resolve through PERM_OPS.
                if let Some(token) = PERM_OPS.lock().remove(&handle.0) {
                    push_diag(&format!(
                        "perm op {}: server said ok={} {}",
                        token,
                        res.is_ok(),
                        err_text.as_deref().unwrap_or("")
                    ));
                    STATE.lock().pending_events.push_back(TsEvent::PermOp {
                        token,
                        ok: res.is_ok(),
                        error: err_text.clone(),
                    });
                }
                if let Some(op) = FT_OPS.lock().remove(&handle.0) {
                    push_diag(&format!(
                        "ft op {}: server said ok={} {}",
                        op.token,
                        res.is_ok(),
                        err_text.as_deref().unwrap_or("")
                    ));
                    STATE.lock().pending_events.push_back(TsEvent::FtOp {
                        token: op.token,
                        ok: res.is_ok(),
                        error: err_text.clone(),
                    });
                }
                // A rejected ftinitdownload/ftinitupload answers with a plain
                // error frame; map it back to its task so the job fails with
                // the server's real reason instead of hanging.
                if let Some(task_id) = FT_TASK_BY_RC.lock().remove(&handle.0) {
                    if let Some(e) = res.as_ref().err() {
                        push_diag(&format!("ft task {} rejected: {:?}", task_id, e.error));
                        crate::finish_ft_task(
                            task_id,
                            false,
                            Some(format!("{:?} ({:#06x})", e.error, e.error as i32)),
                        );
                    }
                }
                // Record the result on the pending listing — but do NOT
                // complete it here: the server streams the rows AFTER this
                // frame (observed live), so wait for the finished marker.
                let list_finalize_now = {
                    let mut lists = FT_LISTS.lock();
                    match lists.get_mut(&handle.0) {
                        Some(pending) => {
                            // Known TS3 server quirk: listing a channel whose
                            // file storage row does not exist yet answers with
                            // the database-empty-result-set error instead of an
                            // empty-but-ok list (official clients render that as
                            // an empty folder). Scope the tolerance to listings
                            // only: mkdir, delete and transfers keep surfacing
                            // this error.
                            let empty_result_quirk = err_text
                                .as_deref()
                                .is_some_and(|e| {
                                    e.to_ascii_lowercase().contains("databaseemptyresult")
                                });
                            pending.result_seen = true;
                            pending.result_ok = res.is_ok() || empty_result_quirk;
                            pending.result_error = if empty_result_quirk {
                                None
                            } else {
                                err_text.clone()
                            };
                            // A rejected request never streams rows — the
                            // exchange is over without a finished marker.
                            !res.is_ok()
                        }
                        None => false,
                    }
                };
                // Finalize OUTSIDE the lock: schedule_ft_list_finish locks
                // FT_LISTS itself, and parking_lot mutexes are not
                // reentrant — calling it under the lock freezes the
                // connection event loop for good.
                if list_finalize_now {
                    schedule_ft_list_finish(handle.0);
                }
            }
            StreamItem::FiletransferFailed(handle, err) => {
                // Carries the transfer status from notifystatusfiletransfer.
                // Status Ok confirms an upload; any other status (or a TCP
                // level failure) fails the matching task. Downloads decide
                // their own outcome in the worker — ignore Ok there so an
                // early status cannot remove a task still transferring.
                let ok_status = matches!(
                    err,
                    tsclientlib::Error::CommandError(ce)
                        if ce.error == tsclientlib::TsError::Ok
                );
                let desc = match err {
                    tsclientlib::Error::CommandError(ce) => {
                        format!("{:?} ({:#06x})", ce.error, ce.error as i32)
                    }
                    other => format!("{}", other),
                };
                if let Some(task_id) = ft_task_id_by_client_id(handle.0) {
                    let kind = FT_TASKS.get(&task_id).map(|t| t.kind);
                    match kind {
                        Some(k) if k == FT_KIND_UPLOAD && ok_status => {
                            crate::finish_ft_task(task_id, true, None);
                        }
                        _ => {
                            let canceled = FT_TASKS
                                .get(&task_id)
                                .map(|t| t.cancel.load(Ordering::Relaxed))
                                .unwrap_or(false);
                            crate::finish_ft_task(
                                task_id,
                                false,
                                Some(if canceled { "canceled".into() } else { desc }),
                            );
                        }
                    }
                }
            }
            StreamItem::DisconnectedTemporarily(r) => {
                // On reconnect the library replays the whole roster as fresh
                // additions; disarm so that resync stays silent.
                SFX_ARMED.store(false, Ordering::Relaxed);
                // Pending directory listings will never be answered now.
                FT_LISTS.lock().clear();
                // Same for perm-op return codes: the server forgot them, so
                // the awaiting UI would otherwise run into its timeout. The
                // tokens are drained FIRST (dropping the PERM_OPS guard
                // before locking STATE — the MessageResult arm locks in that
                // order too), then answered with a failure.
                let stale_perm_tokens: Vec<String> =
                    PERM_OPS.lock().drain().map(|(_, t)| t).collect();
                for token in stale_perm_tokens {
                    STATE.lock().pending_events.push_back(TsEvent::PermOp {
                        token,
                        ok: false,
                        error: Some("connection lost".into()),
                    });
                }
                // The output stream stays up during a temporary disconnect
                // (the library reconnects on its own), so the connection_lost
                // sound plays through it normally.
                push_sfx(SFX_CONNECTION_LOST, "temp disconnect");
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
            // Queue the disconnected sound BEFORE the disconnect handshake:
            // the library waits for the server's reply (disconnect ack /
            // notifyclientleftview, up to 5s) before its events stream ends,
            // so scheduling after the wait would delay — or on a dead link
            // nearly lose — the sound. The deferred teardown task still
            // tears the stream down once the sound finished playing.
            schedule_sfx_teardown(SFX_DISCONNECTED);
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
                // File transfer bookkeeping dies with the connection: pending directory
            // listings are gone, and active workers notice via their sockets.
            FT_LISTS.lock().clear();
            FT_OPS.lock().clear();
            PERM_OPS.lock().clear();
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
                    let result =
                        OutSendTextMessageMessage::new(&mut std::iter::once(part)).send(&mut con);
                    if result.is_ok() {
                        // Outbound chat sound (the server echoes the message
                        // back; the inbound sound skips our own echoes).
                        push_sfx(SFX_CHAT_OUTBOUND, "message sent");
                    }
                }
                Command::MoveChannel {
                    client_id,
                    channel_id,
                    password,
                    token,
                } => {
                    // Mark the move so a server rejection (which arrives
                    // without a return_code) can be attributed back to this
                    // request — see the CommandError handling below. Only
                    // remember moves of our own client: moving somebody else
                    // must not arm the password-error attribution.
                    if client_id as u32 == own_client_id_or_cache(&con) {
                        STATE.lock().pending_move = Some((channel_id, Instant::now()));
                    }
                    // TS3 expects cpw as base64(sha1(password)); never send
                    // plaintext over the wire.
                    let channel_password = password
                        .as_deref()
                        .map(|p| tsproto_types::crypto::encode_password(p.as_bytes()))
                        .map(Cow::Owned);
                    let part = OutClientMovePart {
                        client_id: ClientId(client_id),
                        channel_id: ChannelId(channel_id),
                        channel_password,
                    };
                    // A token means "report back": ride the return_code path
                    // so the sheet gets the server's real answer (success /
                    // insufficient permission). Without a token this stays the
                    // legacy fire-and-forget move (used by the channel-entry
                    // password flow for ourselves, which is already reported
                    // through MoveRejected).
                    let result =
                        OutClientMoveMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con);
                    match token {
                        Some(t) => perm_op_send(result, &t),
                        None => {
                            if result.is_err() {
                                push_diag(&format!(
                                    "move client {}: send failed",
                                    client_id
                                ));
                            }
                        }
                    }
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
                Command::SetAway { away } => {
                    let part = OutClientUpdatePart {
                        name: None,
                        input_muted: None,
                        output_muted: None,
                        is_away: Some(away),
                        away_message: if away {
                            Some(Cow::Borrowed("Away"))
                        } else {
                            None
                        },
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
                Command::SendPoke { client_id, message } => {
                    // Poke is a dedicated clientpoke request message.
                    let part = OutClientPokeRequestPart {
                        client_id: ClientId(client_id),
                        message: message.into(),
                    };
                    let _ =
                        OutClientPokeRequestMessage::new(&mut std::iter::once(part)).send(&mut con);
                }
                Command::KickClient {
                    client_id,
                    from_server,
                    reason,
                    token,
                } => {
                    let own_client_id = own_client_id_or_cache(&con);
                    if client_id as u32 == own_client_id {
                        // Self-protection: never kick ourselves even if the
                        // UI somehow offered the action. (Dialog dismissal is
                        // handled in the UI layer and never reaches us; an
                        // empty reason is a deliberate no-reason kick.)
                        push_diag("kick client: skipped (cannot kick self)");
                        if let Some(t) = token {
                            STATE.lock().pending_events.push_back(TsEvent::PermOp {
                                token: t,
                                ok: false,
                                error: Some("cannot kick yourself".into()),
                            });
                        }
                    } else {
                        // reasonmsg is optional on the wire — an empty reason
                        // is sent as a kick without a reason message.
                        let part = OutClientKickPart {
                            client_id: ClientId(client_id),
                            reason: if from_server {
                                tsclientlib::Reason::KickServer
                            } else {
                                tsclientlib::Reason::KickChannel
                            },
                            reason_message: if reason.is_empty() {
                                None
                            } else {
                                Some(Cow::Owned(reason))
                            },
                        };
                        push_diag(&format!(
                            "kick client {} (from_server={}): sent",
                            client_id, from_server
                        ));
                        let result =
                            OutClientKickMessage::new(&mut std::iter::once(part))
                                .send_with_result(&mut con);
                        match token {
                            Some(t) => perm_op_send(result, &t),
                            None => {
                                if result.is_err() {
                                    push_diag(&format!(
                                        "kick client {}: send failed",
                                        client_id
                                    ));
                                }
                            }
                        }
                    }
                }
                Command::BanClient {
                    client_id,
                    time_seconds,
                    reason,
                    token,
                } => {
                    let own_client_id = own_client_id_or_cache(&con);
                    if reason.is_empty() && time_seconds == 0 {
                        push_diag("ban client: skipped (no reason / permanent-by-accident)");
                        if let Some(t) = token {
                            STATE.lock().pending_events.push_back(TsEvent::PermOp {
                                token: t,
                                ok: false,
                                error: Some("skip: empty reason (permanent ban)".into()),
                            });
                        }
                    } else if client_id as u32 == own_client_id {
                        push_diag("ban client: skipped (cannot ban self)");
                        if let Some(t) = token {
                            STATE.lock().pending_events.push_back(TsEvent::PermOp {
                                token: t,
                                ok: false,
                                error: Some("cannot ban yourself".into()),
                            });
                        }
                    } else {
                        let part = OutBanClientPart {
                            client_id: ClientId(client_id),
                            time: if time_seconds > 0 {
                                Some(time::Duration::seconds(time_seconds as i64))
                            } else {
                                None // permanent ban
                            },
                            ban_reason: Some(Cow::Owned(reason)),
                        };
                        push_diag(&format!(
                            "ban client {} ({}s): sent",
                            client_id, time_seconds
                        ));
                        let result =
                            OutBanClientMessage::new(&mut std::iter::once(part))
                                .send_with_result(&mut con);
                        match token {
                            Some(t) => perm_op_send(result, &t),
                            None => {
                                if result.is_err() {
                                    push_diag(&format!(
                                        "ban client {}: send failed",
                                        client_id
                                    ));
                                }
                            }
                        }
                    }
                }
                // ── Channel management ───────────────────────────────────
                Command::ChannelCreate { args, token } => {
                    // channelcreate takes the hashed cpw form (like the move
                    // and ft commands), never the plaintext.
                    let hashed_password = args
                        .password
                        .as_deref()
                        .map(|p| tsproto_types::crypto::encode_password(p.as_bytes()))
                        .map(Cow::Owned);
                    let (family_value, family_unlimited, family_inherited) =
                        family_limits(args.max_family_clients);
                    let part = OutChannelCreatePart {
                        parent_id: Some(ChannelId(args.parent_id.unwrap_or(0) as u64)),
                        name: Cow::Owned(args.name.clone().unwrap_or_default()),
                        topic: args.topic.filter(|t| !t.is_empty()).map(Cow::Owned),
                        description: args
                            .description
                            .filter(|d| !d.is_empty())
                            .map(Cow::Owned),
                        password: hashed_password,
                        codec: None,
                        codec_quality: None,
                        max_clients: match args.max_clients {
                            Some(n) if n > 0 => Some(n),
                            _ => None,
                        },
                        max_family_clients: family_value,
                        order: None,
                        has_password: Some(args.password.is_some()),
                        is_unencrypted: None,
                        delete_delay: args.delete_delay.map(time::Duration::seconds),
                        is_max_clients_unlimited: Some(!matches!(
                            args.max_clients,
                            Some(n) if n > 0
                        )),
                        is_max_family_clients_unlimited: family_unlimited,
                        inherits_max_family_clients: family_inherited,
                        phonetic_name: None,
                        is_permanent: Some(args.is_permanent.unwrap_or(false)),
                        is_semi_permanent: Some(args.is_semi_permanent.unwrap_or(false)),
                        is_default: Some(args.is_default.unwrap_or(false)),
                    };
                    push_diag(&format!(
                        "channel create under {}: sent",
                        args.parent_id.unwrap_or(0)
                    ));
                    let result = OutChannelCreateMessage::new(&mut std::iter::once(part))
                        .send_with_result(&mut con);
                    perm_op_send(result, &token);
                }
                Command::ChannelEdit { channel_id, args, token } => {
                    // password: None = untouched, Some("") = clear,
                    // Some(p) = set (hashed, see ChannelCreate).
                    let (has_password, hashed_password) = match args.password {
                        None => (None, None),
                        Some(ref p) if p.is_empty() => (Some(false), None),
                        Some(ref p) => (
                            Some(true),
                            Some(Cow::Owned(
                                tsproto_types::crypto::encode_password(p.as_bytes()),
                            )),
                        ),
                    };
                    let (family_value, family_unlimited, family_inherited) =
                        family_limits(args.max_family_clients);
                    let part = OutChannelEditPart {
                        channel_id: ChannelId(channel_id as u64),
                        order: args.order.map(|id| ChannelId(id as u64)),
                        name: args.name.map(Cow::Owned),
                        topic: args.topic.map(Cow::Owned),
                        is_default: args.is_default,
                        has_password,
                        password: hashed_password,
                        is_permanent: args.is_permanent,
                        is_semi_permanent: args.is_semi_permanent,
                        codec: None,
                        codec_quality: None,
                        needed_talk_power: args.needed_talk_power,
                        max_clients: match args.max_clients {
                            Some(n) if n > 0 => Some(n),
                            _ => None,
                        },
                        max_family_clients: family_value,
                        codec_latency_factor: None,
                        is_unencrypted: None,
                        delete_delay: args.delete_delay.map(time::Duration::seconds),
                        is_max_clients_unlimited: match args.max_clients {
                            Some(0) => Some(true),
                            Some(_) => Some(false),
                            None => None,
                        },
                        is_max_family_clients_unlimited: family_unlimited,
                        inherits_max_family_clients: family_inherited,
                        phonetic_name: None,
                        description: args.description.map(Cow::Owned),
                    };
                    push_diag(&format!("channel edit {}: sent", channel_id));
                    let result = OutChannelEditMessage::new(&mut std::iter::once(part))
                        .send_with_result(&mut con);
                    perm_op_send(result, &token);
                }
                Command::ChannelDelete {
                    channel_id,
                    force,
                    token,
                } => {
                    let part = OutChannelDeletePart {
                        channel_id: ChannelId(channel_id as u64),
                        force,
                    };
                    push_diag(&format!("channel delete {} (force={}): sent", channel_id, force));
                    let result = OutChannelDeleteMessage::new(&mut std::iter::once(part))
                        .send_with_result(&mut con);
                    perm_op_send(result, &token);
                }
                Command::ChannelMove {
                    channel_id,
                    parent_id,
                    order,
                    token,
                } => {
                    let part = OutChannelMovePart {
                        channel_id: ChannelId(channel_id as u64),
                        parent_id: ChannelId(parent_id as u64),
                        order: order.map(|id| ChannelId(id as u64)),
                    };
                    push_diag(&format!(
                        "channel move {} -> {} (order {:?}): sent",
                        channel_id, parent_id, order
                    ));
                    let result = OutChannelMoveMessage::new(&mut std::iter::once(part))
                        .send_with_result(&mut con);
                    perm_op_send(result, &token);
                }
                // ── Permission management ────────────────────────────────
                Command::ServerGroupAddClient { sgid, dbid, token } => {
                    let part = OutServerGroupAddClientPart {
                        server_group_id: tsclientlib::ServerGroupId(sgid),
                        client_db_id: tsclientlib::ClientDbId(dbid),
                    };
                    perm_op_send(
                        OutServerGroupAddClientMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con),
                        &token,
                    );
                }
                Command::ServerGroupDelClient { sgid, dbid, token } => {
                    let part = OutServerGroupDelClientPart {
                        server_group_id: tsclientlib::ServerGroupId(sgid),
                        client_db_id: tsclientlib::ClientDbId(dbid),
                    };
                    perm_op_send(
                        OutServerGroupDelClientMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con),
                        &token,
                    );
                }
                Command::ChannelGroupSet { cgid, cid, dbid, token } => {
                    // `channelgroupaddclient` is not declared in the vendored
                    // tsdeclarations — build the packet by hand (same pattern
                    // as the ft commands).
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "channelgroupaddclient",
                    );
                    packet.write_arg("cgid", &cgid);
                    packet.write_arg("cid", &cid);
                    packet.write_arg("cldbid", &dbid);
                    perm_op_send(RawCmd(packet).send_with_result(&mut con), &token);
                }
                Command::ChannelGroupClear { cid, dbid, token } => {
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "channelgroupdelclient",
                    );
                    packet.write_arg("cid", &cid);
                    packet.write_arg("cldbid", &dbid);
                    perm_op_send(RawCmd(packet).send_with_result(&mut con), &token);
                }
                Command::GrantChannelPerm { cid, dbid, permsid, value, token } => {
                    let part = OutChannelClientAddPermPart {
                        channel_id: tsclientlib::ChannelId(cid as u64),
                        client_db_id: tsclientlib::ClientDbId(dbid),
                        permission_id: None,
                        permission_name_id: Some(Cow::Owned(permsid)),
                        permission_value: value,
                    };
                    perm_op_send(
                        OutChannelClientAddPermMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con),
                        &token,
                    );
                }
                Command::RevokeChannelPerm { cid, dbid, permsid, token } => {
                    let part = OutChannelClientDelPermPart {
                        channel_id: tsclientlib::ChannelId(cid as u64),
                        client_db_id: tsclientlib::ClientDbId(dbid),
                        permission_id: None,
                        permission_name_id: Some(Cow::Owned(permsid)),
                    };
                    perm_op_send(
                        OutChannelClientDelPermMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con),
                        &token,
                    );
                }
                Command::GrantServerPerm { dbid, permsid, value, token } => {
                    // Server-wide permission (`clientaddperm`): applies to the
                    // client everywhere, not just one channel.
                    let part = OutClientAddPermPart {
                        client_db_id: tsclientlib::ClientDbId(dbid),
                        permission_id: None,
                        permission_name_id: Some(Cow::Owned(permsid)),
                        permission_value: value,
                        permission_skip: false,
                    };
                    perm_op_send(
                        OutClientAddPermMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con),
                        &token,
                    );
                }
                Command::RevokeServerPerm { dbid, permsid, token } => {
                    let part = OutClientDelPermPart {
                        client_db_id: tsclientlib::ClientDbId(dbid),
                        permission_id: None,
                        permission_name_id: Some(Cow::Owned(permsid)),
                    };
                    perm_op_send(
                        OutClientDelPermMessage::new(&mut std::iter::once(part))
                            .send_with_result(&mut con),
                        &token,
                    );
                }
                Command::RefreshGroups => {
                    let _ = OutServerGroupListRequestMessage::new().send(&mut con);
                    let _ = OutChannelGroupListRequestMessage::new().send(&mut con);
                    push_diag("perm: re-requested server/channel group lists");
                }
                Command::OwnPermList => {
                    // (Re-)request our own directly-assigned permissions.
                    let (own_id, own_dbid) = {
                        let state = STATE.lock();
                        let own_dbid = state
                            .clients
                            .iter()
                            .find(|c| c.id as u32 == state.own_client_id)
                            .map(|c| c.database_id)
                            .unwrap_or(0);
                        (state.own_client_id, own_dbid)
                    };
                    if own_dbid == 0 {
                        push_diag(&format!(
                            "own clientpermlist: database id unknown yet (own_id={})",
                            own_id
                        ));
                    } else {
                        let part = OutClientPermListRequestPart {
                            client_db_id: tsclientlib::ClientDbId(own_dbid),
                        };
                        let _ = OutClientPermListRequestMessage::new(&mut std::iter::once(part))
                            .send(&mut con);
                        push_diag("own clientpermlist: requested");
                    }
                }
                Command::FtList { cid, path, password, token } => {
                    // Hand-built so `cpw` is omitted for unlocked channels
                    // (see RawCmd above).
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "ftgetfilelist",
                    );
                    packet.write_arg("cid", &cid);
                    packet.write_arg("cpw", &encoded_cpw(&password));
                    packet.write_arg("path", &path);
                    push_diag(&format!("ft list {}: request cid={} path={}", token, cid, path));
                    push_wire_diag(&format!("list {}", token), &packet);
                    match RawCmd(packet).send_with_result(&mut con) {
                        Ok(handle) => {
                            // Marks the point after the send: if the next
                            // log line is missing, the loop died inside the
                            // send itself rather than in the reply handling.
                            push_diag(&format!(
                                "ft list {}: sent (rc={})",
                                token, handle.0
                            ));
                            let mut lists = FT_LISTS.lock();
                            lists.insert(
                                handle.0,
                                PendingFtList {
                                    token,
                                    entries: Vec::new(),
                                    created: Instant::now(),
                                    cid,
                                    path,
                                    result_seen: false,
                                    result_ok: false,
                                    result_error: None,
                                    finished_seen: false,
                                    finalize_scheduled: false,
                                },
                            );
                            // Safety valve: drop unanswered pendings after
                            // half a minute (normally every request gets its
                            // trailing error frame).
                            let stale: Vec<u16> = lists
                                .iter()
                                .filter(|(_, p)| p.created.elapsed() > Duration::from_secs(30))
                                .map(|(k, _)| *k)
                                .collect();
                            for k in stale {
                                lists.remove(&k);
                            }
                        }
                        Err(e) => {
                            push_diag(&format!("ft list {}: send failed: {}", token, e));
                            STATE
                                .lock()
                                .pending_events
                                .push_back(TsEvent::FtListing {
                                    token,
                                    entries: vec![],
                                    error: Some(format!("{}", e)),
                                });
                        }
                    }
                }
                Command::FtCreateDir { cid, dirname, password, token } => {
                    push_diag(&format!("ft mkdir {}: dirname={}", token, dirname));
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "ftcreatedir",
                    );
                    packet.write_arg("cid", &cid);
                    packet.write_arg("cpw", &encoded_cpw(&password));
                    packet.write_arg("dirname", &dirname);
                    push_wire_diag(&format!("mkdir {}", token), &packet);
                    match RawCmd(packet).send_with_result(&mut con) {
                        Ok(handle) => {
                            FT_OPS.lock().insert(handle.0, crate::PendingFtOp { token });
                        }
                        Err(e) => {
                            push_diag(&format!("ft mkdir {}: send failed: {}", token, e));
                            STATE.lock().pending_events.push_back(TsEvent::FtOp {
                                token,
                                ok: false,
                                error: Some(format!("{}", e)),
                            });
                        }
                    }
                }
                Command::FtDelete { cid, names, password, token } => {
                    push_diag(&format!("ft delete {}: {} path(s)", token, names.len()));
                    // Every deleted entry is one part of a single ftdeletefile.
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "ftdeletefile",
                    );
                    let cpw = encoded_cpw(&password);
                    for (i, name) in names.iter().enumerate() {
                        if i > 0 {
                            packet.start_new_part();
                        }
                        packet.write_arg("cid", &cid);
                        packet.write_arg("cpw", &cpw);
                        packet.write_arg("name", name);
                    }
                    push_wire_diag(&format!("delete {}", token), &packet);
                    match RawCmd(packet).send_with_result(&mut con) {
                        Ok(handle) => {
                            FT_OPS.lock().insert(handle.0, crate::PendingFtOp { token });
                        }
                        Err(e) => {
                            push_diag(&format!("ft delete {}: send failed: {}", token, e));
                            STATE.lock().pending_events.push_back(TsEvent::FtOp {
                                token,
                                ok: false,
                                error: Some(format!("{}", e)),
                            });
                        }
                    }
                }
                Command::FtDownload { cid, path, password, task_id } => {
                    push_diag(&format!(
                        "ft download task={} cid={} path={}",
                        task_id, cid, path
                    ));
                    // Hand-built ftinitdownload (cpw omitted when absent, own
                    // transfer id — see FT_CLIENT_FT).
                    let ftid = FT_CLIENT_FT.fetch_add(1, Ordering::SeqCst);
                    if let Some(t) = FT_TASKS.get_mut(&task_id) {
                        t.client_ft_id.store(ftid, Ordering::Relaxed);
                    }
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "ftinitdownload",
                    );
                    packet.write_arg("clientftfid", &ftid);
                    packet.write_arg("name", &path);
                    packet.write_arg("cid", &cid);
                    packet.write_arg("cpw", &encoded_cpw(&password));
                    packet.write_arg("seekpos", &0u64);
                    packet.write_arg("proto", &1u8);
                    push_wire_diag(&format!("download task={}", task_id), &packet);
                    match RawCmd(packet).send_with_result(&mut con) {
                        Ok(handle) => {
                            FT_TASK_BY_RC.lock().insert(handle.0, task_id);
                        }
                        Err(e) => {
                            crate::finish_ft_task(task_id, false, Some(format!("{}", e)));
                        }
                    }
                }
                Command::FtUpload { cid, path, password, task_id } => {
                    push_diag(&format!(
                        "ft upload task={} cid={} path={}",
                        task_id, cid, path
                    ));
                    let total = FT_TASKS
                        .get(&task_id)
                        .map(|t| t.total.load(std::sync::atomic::Ordering::Relaxed))
                        .unwrap_or(0);
                    let ftid = FT_CLIENT_FT.fetch_add(1, Ordering::SeqCst);
                    if let Some(t) = FT_TASKS.get_mut(&task_id) {
                        t.client_ft_id.store(ftid, Ordering::Relaxed);
                    }
                    let mut packet = OutCommand::new(
                        Direction::C2S,
                        Flags::empty(),
                        PacketType::Command,
                        "ftinitupload",
                    );
                    packet.write_arg("clientftfid", &ftid);
                    packet.write_arg("name", &path);
                    packet.write_arg("cid", &cid);
                    packet.write_arg("cpw", &encoded_cpw(&password));
                    packet.write_arg("size", &total);
                    packet.write_arg("overwrite", &1u8);
                    packet.write_arg("resume", &0u8);
                    packet.write_arg("proto", &1u8);
                    push_wire_diag(&format!("upload task={}", task_id), &packet);
                    match RawCmd(packet).send_with_result(&mut con) {
                        Ok(handle) => {
                            FT_TASK_BY_RC.lock().insert(handle.0, task_id);
                        }
                        Err(e) => {
                            crate::finish_ft_task(task_id, false, Some(format!("{}", e)));
                        }
                    }
                }
                Command::Disconnect => {
                    // Queue the disconnected sound BEFORE the disconnect
                    // handshake (see do_disconnect above: the library waits
                    // for the server's disconnect ack before its events
                    // stream ends). The deferred teardown task still tears
                    // the stream down once the sound finished playing.
                    schedule_sfx_teardown(SFX_DISCONNECTED);
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
                        // File transfer bookkeeping dies with the connection: pending directory
            // listings are gone, and active workers notice via their sockets.
            FT_LISTS.lock().clear();
            FT_OPS.lock().clear();
            PERM_OPS.lock().clear();
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
                    // End the session visibly (Dart ignores `error` events
                    // once connected) and let the error sound finish before
                    // tearing the stream down.
                    STATE.lock().connected = false;
                    STATE.lock().pending_events.push_back(TsEvent::Disconnected {
                        reason: format!("Connection error: {}", e),
                    });
                    schedule_sfx_teardown(SFX_ERROR);
                    // File transfer bookkeeping dies with the connection: pending directory
            // listings are gone, and active workers notice via their sockets.
            FT_LISTS.lock().clear();
            FT_OPS.lock().clear();
            PERM_OPS.lock().clear();
            *COMMAND_TX.lock() = None;
                }
                // The stream errored out (same termination as Ok(None)):
                // return directly instead of falling into 2b, which would
                // poll again and could play an extra sound.
                return;
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
                    if SFX_SUPPRESS_DISCONNECT.load(Ordering::Relaxed) {
                        // Kicked/banned: the kick/ban sound just played — keep
                        // the stream alive until it finished; do NOT play any
                        // extra sound on top of it.
                        SFX_SUPPRESS_DISCONNECT.store(false, Ordering::Relaxed);
                        schedule_teardown_after_kick_sfx();
                    } else {
                        // Passive disconnect (server closed / network lost):
                        // play the connection_lost sound, not disconnected
                        // (disconnected is reserved for explicit user exit).
                        schedule_sfx_teardown(SFX_CONNECTION_LOST);
                    }
                    // File transfer bookkeeping dies with the connection: pending directory
            // listings are gone, and active workers notice via their sockets.
            FT_LISTS.lock().clear();
            FT_OPS.lock().clear();
            PERM_OPS.lock().clear();
            *COMMAND_TX.lock() = None;
                }
                // The stream is truly over — do not fall through to the
                // drain loop (2b), which would poll the finished stream again
                // and re-enter this branch with SUPPRESS already cleared,
                // producing a second sound.
                return;
            }
            Err(_) => {} // 20ms timeout — continue
        }

        // 2b. Drain remaining already-available events (1ms timeout)
        let mut deferred_events: Vec<StreamItem> = Vec::new();
        // Set when the events stream ends cleanly (Ok(None)). The actual
        // finalization (sound decision, Disconnected event, teardown) runs
        // AFTER 2c below, outside the `con.events()` borrow — the kicked/
        // banned BookEvents must be processed first so SFX_SUPPRESS_DISCONNECT
        // is up to date before we decide which sound (if any) to play.
        let mut stream_ended = false;
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
                        STATE.lock().connected = false;
                        STATE.lock().pending_events.push_back(TsEvent::Disconnected {
                            reason: format!("Connection error: {}", e),
                        });
                        schedule_sfx_teardown(SFX_ERROR);
                        // File transfer bookkeeping dies with the connection: pending directory
            // listings are gone, and active workers notice via their sockets.
            FT_LISTS.lock().clear();
            FT_OPS.lock().clear();
            PERM_OPS.lock().clear();
            *COMMAND_TX.lock() = None;
                    }
                    // The stream errored out — return immediately instead of
                    // looping, so no extra sound is queued on top of the
                    // error sound.
                    return;
                }
                Ok(None) => {
                    stream_ended = true;
                    break;
                }
                Err(_) => break,
            }
        }

        // 2c. Process deferred non-audio events. This runs after 2b so the
        // `con.events()` borrow has been released.
        for item in deferred_events {
            handle_event_item(item, &mut con, generation);
        }
        if let Some(item) = deferred {
            handle_event_item(item, &mut con, generation);
        }

        // NEK0-DIAG: surface raw incoming commands for ft debugging.
        drain_raw_incoming(&mut con);

        // Stream ended cleanly: finalize. The deferred events above were
        // already processed, so a kick/ban has set SFX_SUPPRESS_DISCONNECT
        // and queued its own sound — play connection_lost only for a true
        // passive disconnect (server closed / network lost).
        if stream_ended {
            let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
            if current_gen == generation {
                let mut s = STATE.lock();
                s.connected = false;
                s.pending_events.push_back(TsEvent::Disconnected {
                    reason: "Connection closed by server".into(),
                });
                drop(s);
                if SFX_SUPPRESS_DISCONNECT.load(Ordering::Relaxed) {
                    // Kicked/banned: keep the stream so the kick/ban sound
                    // finishes; no extra sound on top.
                    SFX_SUPPRESS_DISCONNECT.store(false, Ordering::Relaxed);
                    schedule_teardown_after_kick_sfx();
                } else {
                    // Passive disconnect → connection_lost, not disconnected
                    // (disconnected is reserved for explicit user exit).
                    schedule_sfx_teardown(SFX_CONNECTION_LOST);
                }
                // File transfer bookkeeping dies with the connection: pending directory
            // listings are gone, and active workers notice via their sockets.
            FT_LISTS.lock().clear();
            FT_OPS.lock().clear();
            PERM_OPS.lock().clear();
            *COMMAND_TX.lock() = None;
            }
            return;
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
/// Android-only: other platforms disconnect through ts_disconnect.
#[cfg(target_os = "android")]
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

/// Request the output stream to be rebuilt on the current default device.
/// Only sets a flag — the maintenance task performs the rebuild within
/// 500ms, which naturally coalesces multiple requests in the same window.
#[no_mangle]
pub extern "C" fn ts_restart_audio_output() {
    if STATE.lock().connected {
        OUTPUT_RESTART_REQUESTED.store(true, Ordering::Relaxed);
        eprintln!("ts_restart_audio_output: restart requested");
    } else {
        eprintln!("ts_restart_audio_output: ignored (not connected)");
    }
}

/// JNI entry used by KeepAliveService's AudioDeviceCallback when the output
/// route changes (Bluetooth/wired/USB device added or removed).
/// Android-only: other platforms rely on the cpal stream-error rebuild path.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_senlinjun_nek0_KeepAliveService_tsRestartAudioOutput(
    _env: *mut std::ffi::c_void,
    _class: *mut std::ffi::c_void,
) {
    ts_restart_audio_output();
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
    // Refresh per-client volumes from the UID-keyed persistent store before
    // serializing. Snapshot the map first to avoid a borrow conflict with the
    // mutable clients iteration (the MutexGuard deref can't split field borrows).
    let volume_snapshot: Vec<(String, f32)> = state
        .client_volumes
        .iter()
        .map(|(k, &v)| (k.clone(), v))
        .collect();
    for c in &mut state.clients {
        if let Some(uid) = &c.uid {
            if let Some((_uid, db)) = volume_snapshot.iter().find(|(u, _)| u == uid) {
                c.volume = *db;
            }
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
pub extern "C" fn ts_move_to_channel(cid: u32, password: *const c_char) -> u8 {
    let own_id = STATE.lock().own_client_id;
    if !STATE.lock().connected {
        return 0;
    }
    // Empty string (or NULL) means "no password"; only non-empty input is
    // forwarded. Dart always passes a valid pointer.
    let password = if password.is_null() {
        None
    } else {
        let s = unsafe { std::ffi::CStr::from_ptr(password) }
            .to_string_lossy()
            .into_owned();
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    };
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::MoveChannel {
                client_id: own_id as u16,
                channel_id: cid as u64,
                password,
                token: None,
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
/// The numeric `client_id` is a session-scoped handle: the value is persisted
/// under the client's user UID so it survives reconnects and client ID reuse.
/// If the client's UID is not known yet (e.g. brand-new client within the
/// roster refresh window), the volume is only applied to the live buffer and
/// not persisted.
#[no_mangle]
pub extern "C" fn ts_set_client_volume(client_id: u16, volume_db: f32) {
    let vol_db = volume_db.clamp(-20.0, 20.0);
    let gain = 10.0_f32.powf(vol_db / 20.0);

    // Persist dB to STATE keyed by the user UID — source of truth, survives disconnect
    let mut state = STATE.lock();
    let uid = state
        .clients
        .iter()
        .find(|c| c.id as u16 == client_id)
        .and_then(|c| c.uid.as_ref())
        .cloned();
    if let Some(uid) = uid {
        state.client_volumes.insert(uid, vol_db);
    }
    drop(state);

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
    let disconnect_pending = state.disconnect_requested;
    drop(state);
    if disconnect_pending || SFX_DEFERRED_TEARDOWN.load(Ordering::Relaxed) {
        // A disconnect is in flight (ts_disconnect set the flag before the
        // event loop queued the sfx) or a disconnect/error sound is still
        // playing through the output stream (Dart calls this on the
        // `disconnected` event, which fires right when the sound is queued).
        // Leave the stream alone — the deferred teardown task drops it once
        // the sample finished.
        eprintln!("ts_stop_audio: teardown deferred (disconnect pending / sfx playing), keeping stream");
        return;
    }
    teardown_output_state();
}

/// Routes raw mic samples into the encode/send pipeline — the shared path
/// used by both ts_send_audio (Dart push, Android) and the cpal input
/// callback (desktop capture). VAD, mic gain and Opus encoding happen
/// downstream in the event loop's Command::SendAudio handler. No-op when not
/// connected.
fn queue_mic_samples(samples: Vec<f32>) -> bool {
    if samples.is_empty() || !STATE.lock().connected {
        return false;
    }
    let tx = COMMAND_TX.lock();
    match tx.as_ref() {
        Some(tx) => tx.send(Command::SendAudio { data: samples }).is_ok(),
        None => false,
    }
}

#[no_mangle]
pub extern "C" fn ts_send_audio(data: *const f32, data_len: u32) -> u8 {
    if data.is_null() || data_len == 0 {
        return 0;
    }
    let raw = unsafe { std::slice::from_raw_parts(data, data_len as usize) };
    let samples: Vec<f32> = raw.to_vec(); // raw samples — gain applied after VAD
    queue_mic_samples(samples) as u8
}

// ─── Mic capture (desktop; Android uses the Kotlin EventChannel path) ──

/// Per-stream mic resampler: device input (interleaved f32) → 48 kHz mono.
/// Streaming linear interpolation with state carried across callbacks.
struct MicResampler {
    /// Input samples per one 48 kHz output sample (device_rate / 48000).
    ratio: f64,
    channels: usize,
    /// Interpolation phase between `prev` and the next input sample, [0,1).
    phase: f64,
    prev: f32,
    started: bool,
    /// Reused scratch buffers (no allocation in the audio callback).
    mono: Vec<f32>,
    out: Vec<f32>,
}

impl MicResampler {
    fn new(channels: usize, rate: u32) -> Self {
        Self {
            ratio: rate as f64 / 48000.0,
            channels,
            phase: 0.0,
            prev: 0.0,
            started: false,
            mono: Vec::with_capacity(4096),
            out: Vec::with_capacity(4096),
        }
    }

    /// Consumes one input callback chunk and appends 48 kHz mono samples to
    /// `self.out`.
    fn process(&mut self, data: &[f32]) {
        let frames = data.len() / self.channels;
        self.mono.clear();
        if self.channels == 1 {
            self.mono.extend_from_slice(data);
        } else {
            for f in 0..frames {
                let base = f * self.channels;
                let sum: f32 = data[base..base + self.channels].iter().sum();
                self.mono.push(sum / self.channels as f32);
            }
        }
        if self.ratio == 1.0 {
            self.out.extend_from_slice(&self.mono);
            return;
        }
        let n = self.mono.len();
        let mut i = 0usize;
        if !self.started {
            if n == 0 {
                return;
            }
            // Output sample 0 IS the first input sample; the next output
            // lands at input position `ratio`.
            self.prev = self.mono[0];
            self.started = true;
            i = 1;
            self.phase = self.ratio;
            self.out.push(self.prev);
        }
        while i < n {
            let x = self.mono[i];
            while self.phase < 1.0 {
                let s = self.prev + (x - self.prev) * self.phase as f32;
                self.out.push(s);
                self.phase += self.ratio;
            }
            self.phase -= 1.0;
            self.prev = x;
            i += 1;
        }
    }
}

/// Starts the cpal microphone input stream (desktop capture). Requests
/// 48 kHz mono first, falling back to the device's default input
/// sample rate and channel count (downmixed + resampled to 48 kHz mono in
/// the callback). Idempotent: true when a capture stream already runs.
pub fn start_mic_capture() -> bool {
    if crate::MIC_STREAM.lock().unwrap().0.is_some() {
        return true;
    }
    let host = cpal::default_host();
    let Some(device) = pick_device(&host, true) else {
        eprintln!("cpal mic: no input device");
        return false;
    };
    eprintln!(
        "cpal mic: input device \"{}\"",
        device.name().unwrap_or_default()
    );
    let mut candidates = vec![cpal::StreamConfig {
        channels: 1,
        sample_rate: cpal::SampleRate(48000),
        buffer_size: cpal::BufferSize::Default,
    }];
    if let Ok(default) = device.default_input_config() {
        if default.sample_rate().0 != 48000 {
            candidates.push(cpal::StreamConfig {
                channels: 1,
                sample_rate: default.sample_rate(),
                buffer_size: cpal::BufferSize::Default,
            });
        }
        if default.channels() > 1 {
            candidates.push(cpal::StreamConfig {
                channels: default.channels(),
                sample_rate: default.sample_rate(),
                buffer_size: cpal::BufferSize::Default,
            });
        }
    }

    for config in candidates {
        let mut resampler = MicResampler::new(config.channels as usize, config.sample_rate.0);
        let stream = device.build_input_stream(
            &config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                resampler.process(data);
                if resampler.out.is_empty() {
                    return;
                }
                // Publish the block RMS for the UI level meter.
                let sum_sq: f64 = resampler.out.iter().map(|s| (*s * *s) as f64).sum();
                let rms = (sum_sq / resampler.out.len() as f64).sqrt() as f32;
                crate::MIC_RMS.store(f32::to_bits(rms), Ordering::Relaxed);
                queue_mic_samples(std::mem::take(&mut resampler.out));
            },
            |err| eprintln!("cpal mic input error: {}", err),
            None,
        );
        match stream {
            Ok(stream) => {
                crate::MIC_STREAM.lock().unwrap().0 = Some(stream);
                eprintln!(
                    "cpal mic: input stream started ({} Hz, {} ch)",
                    config.sample_rate.0, config.channels
                );
                return true;
            }
            Err(e) => eprintln!(
                "cpal mic: build_input_stream failed ({} Hz, {} ch): {}",
                config.sample_rate.0, config.channels, e
            ),
        }
    }
    eprintln!("cpal mic: all input configurations failed");
    false
}

/// Stops the microphone input stream (Dart-driven lifecycle).
pub fn stop_mic_capture() {
    let mut guard = crate::MIC_STREAM.lock().unwrap();
    if guard.0.take().is_some() {
        eprintln!("cpal mic: input stream stopped");
    }
    drop(guard);
    crate::MIC_RMS.store(0, Ordering::Relaxed);
}

/// Desktop mic capture toggle. Returns 1 on success (or when already in the
/// requested state), 0 when the input stream could not be built.
#[no_mangle]
pub extern "C" fn ts_set_mic_capture(enable: u8) -> u8 {
    if enable != 0 {
        start_mic_capture() as u8
    } else {
        stop_mic_capture();
        1
    }
}

/// RMS of the most recent native-capture mic block (0..1). Android reports
/// levels from its own Dart-side EventChannel path instead.
#[no_mangle]
pub extern "C" fn ts_get_mic_rms() -> f32 {
    f32::from_bits(crate::MIC_RMS.load(Ordering::Relaxed))
}

// ─── Audio device enumeration / selection (desktop picker UI) ───────

#[derive(serde::Serialize)]
struct AudioDeviceInfo {
    name: String,
    is_default: bool,
}

/// Lists host output/input devices for the picker UI as JSON:
/// `{"outputs":[{"name","is_default"}],"inputs":[...]}`. The host default
/// is marked; on Linux sound-server PCMs and hw devices sort first (alsa
/// exposes many alias PCMs — de-duplicated here). Platforms without
/// enumeration support (Android/oboe) return empty arrays.
fn list_audio_devices(host: &cpal::Host, input: bool) -> Vec<AudioDeviceInfo> {
    let default_name = if input {
        host.default_input_device()
    } else {
        host.default_output_device()
    }
    .and_then(|d| d.name().ok());
    let mut seen = HashSet::new();
    let mut out: Vec<AudioDeviceInfo> = Vec::new();
    for d in enumerate_devices(host, input) {
        if let Ok(name) = d.name() {
            if seen.insert(name.clone()) {
                out.push(AudioDeviceInfo {
                    is_default: default_name.as_deref() == Some(name.as_str()),
                    name,
                });
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        let rank = |n: &str| {
            if SOUND_SERVER_PCMS.contains(&n) {
                0
            } else if n.starts_with("hw:") {
                1
            } else {
                2
            }
        };
        out.sort_by(|a, b| {
            rank(&a.name)
                .cmp(&rank(&b.name))
                .then_with(|| a.name.cmp(&b.name))
        });
    }
    out
}

/// Desktop audio device list (see list_audio_devices for the JSON shape).
#[no_mangle]
pub extern "C" fn ts_get_audio_devices() -> *mut c_char {
    let host = cpal::default_host();
    let doc = serde_json::json!({
        "outputs": list_audio_devices(&host, false),
        "inputs": list_audio_devices(&host, true),
    });
    to_c_str(doc.to_string())
}

/// Selects the output device by name ("" = system default). While
/// connected the output stream is rebuilt by the maintenance task within
/// 500ms; when disconnected the choice applies at the next connect.
#[no_mangle]
pub extern "C" fn ts_set_audio_output_device(name: *const c_char) -> u8 {
    let name = unsafe { cstr_to_string(name) };
    *OUTPUT_DEVICE_NAME.lock().unwrap() = if name.is_empty() { None } else { Some(name) };
    if STATE.lock().connected {
        OUTPUT_RESTART_REQUESTED.store(true, Ordering::Relaxed);
    }
    1
}

/// Selects the input (mic) device by name ("" = system default). A running
/// capture stream is restarted on the new device immediately; returns 0
/// when that restart failed.
#[no_mangle]
pub extern "C" fn ts_set_audio_input_device(name: *const c_char) -> u8 {
    let name = unsafe { cstr_to_string(name) };
    let was_running = crate::MIC_STREAM.lock().unwrap().0.is_some();
    *INPUT_DEVICE_NAME.lock().unwrap() = if name.is_empty() { None } else { Some(name) };
    if was_running {
        stop_mic_capture();
        if !start_mic_capture() {
            return 0;
        }
    }
    1
}

// ─── SFX (custom samples / preview / local triggers) ─────────────────

/// Set our own away state. The server echoes the change back, which drives
/// the away_activated/away_deactivated sounds via the event loop.
/// Returns 1 when the command was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_set_away(away: u8) -> u8 {
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::SetAway { away: away != 0 })
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

/// Poke another client (sends a notifyclientpoke request). Returns 1 when
/// the command was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_send_poke(client_id: u16, msg: *const c_char) -> u8 {
    let message = if msg.is_null() {
        String::new()
    } else {
        unsafe { std::ffi::CStr::from_ptr(msg) }
            .to_string_lossy()
            .into_owned()
    };
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::SendPoke {
                client_id,
                message,
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

/// Kick a client from the current channel (from_server=0) or from the whole
/// server (from_server=1). `reason` is optional (an empty reason cancels the
/// kick — the event loop treats it as a no-op). `token` is optional: when
/// non-empty the server's answer resolves the matching `PermOp` event.
/// Returns 1 when the command was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_kick_client(
    client_id: u16,
    from_server: u8,
    reason: *const c_char,
    token: *const c_char,
) -> u8 {
    let reason = if reason.is_null() {
        String::new()
    } else {
        unsafe { std::ffi::CStr::from_ptr(reason) }
            .to_string_lossy()
            .into_owned()
    };
    let token = unsafe { read_cstr(token) };
    let token = if token.is_empty() { None } else { Some(token) };
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::KickClient {
                client_id,
                from_server: from_server != 0,
                reason,
                token,
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

/// Ban a client. `time_seconds == 0` means an indefinite (permanent) ban.
/// `reason` is optional. `token` is optional (see `ts_kick_client`).
/// Returns 1 when the command was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_ban_client(
    client_id: u16,
    time_seconds: u32,
    reason: *const c_char,
    token: *const c_char,
) -> u8 {
    let reason = if reason.is_null() {
        String::new()
    } else {
        unsafe { std::ffi::CStr::from_ptr(reason) }
            .to_string_lossy()
            .into_owned()
    };
    let token = unsafe { read_cstr(token) };
    let token = if token.is_empty() { None } else { Some(token) };
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::BanClient {
                client_id,
                time_seconds,
                reason,
                token,
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

/// Creates a channel. `args_json` is a `ChannelArgs` object (see lib.rs):
/// parent_id (0 = top level), name (required), topic, password, description,
/// max_clients, max_family_clients (-1 inherited / 0 unlimited / >0 limit),
/// is_permanent / is_semi_permanent / is_default, delete_delay (seconds).
/// `token` is required — the server's answer resolves the caller's `PermOp`
/// future. Returns 1 when the command was queued, 0 when invalid / not
/// connected.
#[no_mangle]
pub extern "C" fn ts_channel_create(args_json: *const c_char, token: *const c_char) -> u8 {
    if args_json.is_null() || token.is_null() {
        return 0;
    }
    unsafe {
        let token = cstr_to_string(token);
        if token.is_empty() {
            return 0;
        }
        let args: crate::ChannelArgs = match serde_json::from_str(&cstr_to_string(args_json)) {
            Ok(a) => a,
            Err(_) => return 0,
        };
        if args.name.as_deref().map(str::trim).unwrap_or("").is_empty() {
            return 0;
        }
        try_send_cmd(Command::ChannelCreate { args, token }) as u8
    }
}

/// Edits channel properties. `args_json` is a `ChannelArgs` object (see
/// lib.rs); absent fields are left untouched, empty strings clear
/// topic/description/password, `order` (sibling id, 0 = first) repositions
/// the channel, and `needed_talk_power` >= 0 sets the talk-power gate.
/// Returns 1 when queued, 0 when invalid / not connected.
#[no_mangle]
pub extern "C" fn ts_channel_edit(
    channel_id: u32,
    args_json: *const c_char,
    token: *const c_char,
) -> u8 {
    if args_json.is_null() || token.is_null() {
        return 0;
    }
    unsafe {
        let token = cstr_to_string(token);
        if token.is_empty() {
            return 0;
        }
        let args: crate::ChannelArgs = match serde_json::from_str(&cstr_to_string(args_json)) {
            Ok(a) => a,
            Err(_) => return 0,
        };
        try_send_cmd(Command::ChannelEdit {
            channel_id,
            args,
            token,
        }) as u8
    }
}

/// Deletes a channel. `force != 0` also removes a channel that still has
/// clients in it (they are moved to the default channel; requires the
/// force-delete permission). Returns 1 when queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_channel_delete(
    channel_id: u32,
    force: u8,
    token: *const c_char,
) -> u8 {
    if token.is_null() {
        return 0;
    }
    unsafe {
        if cstr_to_string(token).is_empty() {
            return 0;
        }
        let deleted = try_send_cmd(Command::ChannelDelete {
            channel_id,
            force: force != 0,
            token: cstr_to_string(token),
        });
        deleted as u8
    }
}

/// Moves a channel to another parent (`channelmove`) — also re-orders within
/// the same parent. `order` is the sibling id the channel comes after
/// (0 = first, -1 = server default / append at the end). `token` is
/// required — the server's answer resolves the caller's `PermOp` future.
/// Returns 1 when the command was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_channel_move(
    channel_id: u32,
    parent_id: u32,
    order: i64,
    token: *const c_char,
) -> u8 {
    if token.is_null() {
        return 0;
    }
    unsafe {
        if cstr_to_string(token).is_empty() {
            return 0;
        }
        let moved = try_send_cmd(Command::ChannelMove {
            channel_id,
            parent_id,
            order: if order < 0 {
                None
            } else {
                Some(order as u32)
            },
            token: cstr_to_string(token),
        });
        moved as u8
    }
}

/// Move a client (or ourselves) to another channel. `password` is the
/// channel password when the target channel is locked. `token` is optional
/// (see `ts_kick_client`); when non-empty the caller gets a `PermOp` answer.
/// Returns 1 when the command was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_move_client(
    client_id: u16,
    channel_id: u32,
    password: *const c_char,
    token: *const c_char,
) -> u8 {
    let password = if password.is_null() {
        None
    } else {
        let s = unsafe { std::ffi::CStr::from_ptr(password) }
            .to_string_lossy()
            .into_owned();
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    };
    let token = unsafe { read_cstr(token) };
    let token = if token.is_empty() { None } else { Some(token) };
    if !STATE.lock().connected {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::MoveChannel {
                client_id,
                channel_id: channel_id as u64,
                password,
                token,
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

// ─── Permission management ──────────────────────────────────────────

/// Read a NUL-terminated C string as an owned String ("" for NULL).
unsafe fn read_cstr(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { std::ffi::CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }
}

/// Maps the Dart form's max-family-clients sentinel onto the wire's three
/// fields: None = don't send (leave untouched), -1 = inherited, 0 = unlimited,
/// >0 = limited to that many clients.
fn family_limits(v: Option<i32>) -> (Option<i32>, Option<bool>, Option<bool>) {
    match v {
        None => (None, None, None),
        Some(-1) => (None, Some(false), Some(true)),
        Some(0) => (None, Some(true), Some(false)),
        Some(n) => (Some(n), Some(false), Some(false)),
    }
}

/// Returns true when a connected command queue exists (drains into `tx`).
fn try_send_cmd(cmd: Command) -> bool {
    if !STATE.lock().connected {
        return false;
    }
    let tx = COMMAND_TX.lock();
    match tx.as_ref() {
        Some(tx) => tx.send(cmd).is_ok(),
        None => false,
    }
}

/// All server groups known to the book (empty until `servergrouplist` was
/// answered). JSON array of `TsServerGroup`.
#[no_mangle]
pub extern "C" fn ts_get_server_groups() -> *mut c_char {
    let state = STATE.lock();
    if !state.connected {
        return to_c_str("[]".to_string());
    }
    to_c_str(serde_json::to_string(&state.server_groups).unwrap_or_else(|_| "[]".into()))
}

/// All channel groups known to the book (empty until `channelgrouplist` was
/// answered). JSON array of `TsChannelGroup`.
#[no_mangle]
pub extern "C" fn ts_get_channel_groups() -> *mut c_char {
    let state = STATE.lock();
    if !state.connected {
        return to_c_str("[]".to_string());
    }
    to_c_str(serde_json::to_string(&state.channel_groups).unwrap_or_else(|_| "[]".into()))
}

/// OUR OWN directly-assigned permissions from `clientpermlist` (requested on
/// connect). JSON array of `TsPerm`; empty until the answer arrived. Note:
/// only directly-assigned perms are listed (inherited/group values are NOT),
/// so this is a low-threshold UI hint, not an authorization source.
#[no_mangle]
pub extern "C" fn ts_get_own_perms() -> *mut c_char {
    let state = STATE.lock();
    if !state.connected {
        return to_c_str("[]".to_string());
    }
    to_c_str(serde_json::to_string(&state.own_perms).unwrap_or_else(|_| "[]".into()))
}

/// Re-request the server/channel group lists (retry after a missed answer).
/// Returns 1 when the request was queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_refresh_groups() -> u8 {
    if try_send_cmd(Command::RefreshGroups) {
        1
    } else {
        0
    }
}

/// Add a client to a server group. The outcome arrives as a `perm_op` event
/// carrying `token`. Returns 1 when queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_server_group_add_client(
    dbid: u64,
    sgid: u64,
    token: *const c_char,
) -> u8 {
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::ServerGroupAddClient { sgid, dbid, token }) {
        1
    } else {
        0
    }
}

/// Remove a client from a server group.
#[no_mangle]
pub extern "C" fn ts_server_group_del_client(
    dbid: u64,
    sgid: u64,
    token: *const c_char,
) -> u8 {
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::ServerGroupDelClient { sgid, dbid, token }) {
        1
    } else {
        0
    }
}

/// Set a client's channel group in a channel.
#[no_mangle]
pub extern "C" fn ts_channel_group_set(
    dbid: u64,
    cid: u32,
    cgid: u64,
    token: *const c_char,
) -> u8 {
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::ChannelGroupSet {
        cgid,
        cid: cid as u64,
        dbid,
        token,
    }) {
        1
    } else {
        0
    }
}

/// Clear a client's channel group in a channel.
#[no_mangle]
pub extern "C" fn ts_channel_group_clear(dbid: u64, cid: u32, token: *const c_char) -> u8 {
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::ChannelGroupClear {
        cid: cid as u64,
        dbid,
        token,
    }) {
        1
    } else {
        0
    }
}

/// Grant a channel-scoped permission (`permsid`, e.g. `i_client_talk_power`)
/// to a client with the given value.
#[no_mangle]
pub extern "C" fn ts_channel_perm_grant(
    dbid: u64,
    cid: u32,
    permsid: *const c_char,
    value: i32,
    token: *const c_char,
) -> u8 {
    let permsid = unsafe { read_cstr(permsid) };
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::GrantChannelPerm {
        cid: cid as u64,
        dbid,
        permsid,
        value,
        token,
    }) {
        1
    } else {
        0
    }
}

/// Revoke a channel-scoped permission from a client.
#[no_mangle]
pub extern "C" fn ts_channel_perm_revoke(
    dbid: u64,
    cid: u32,
    permsid: *const c_char,
    token: *const c_char,
) -> u8 {
    let permsid = unsafe { read_cstr(permsid) };
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::RevokeChannelPerm {
        cid: cid as u64,
        dbid,
        permsid,
        token,
    }) {
        1
    } else {
        0
    }
}

/// Grant a server-wide permission (`permsid`, e.g. `i_client_talk_power`) to
/// a client with the given value — applies everywhere, not just one channel.
#[no_mangle]
pub extern "C" fn ts_server_perm_grant(
    dbid: u64,
    permsid: *const c_char,
    value: i32,
    token: *const c_char,
) -> u8 {
    let permsid = unsafe { read_cstr(permsid) };
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::GrantServerPerm {
        dbid,
        permsid,
        value,
        token,
    }) {
        1
    } else {
        0
    }
}

/// Revoke a server-wide permission from a client.
#[no_mangle]
pub extern "C" fn ts_server_perm_revoke(
    dbid: u64,
    permsid: *const c_char,
    token: *const c_char,
) -> u8 {
    let permsid = unsafe { read_cstr(permsid) };
    let token = unsafe { read_cstr(token) };
    if try_send_cmd(Command::RevokeServerPerm { dbid, permsid, token }) {
        1
    } else {
        0
    }
}

// ─── File transfers ─────────────────────────────────────────────────

/// Last path segment of a remote path ("/" root maps to itself).
fn remote_basename(path: &str) -> String {
    path.rsplit('/').find(|s| !s.is_empty()).unwrap_or("/").to_string()
}

/// Registers a transfer task so Dart can observe its lifecycle; the protocol
/// transfer id is bound later by the event loop when the request went out.
fn ft_new_task(kind: u8, name: String, local_path: String, total: u64) -> u32 {
    let task_id = FT_TASK_SEQ.fetch_add(1, Ordering::SeqCst);
    FT_TASKS.insert(
        task_id,
        Arc::new(crate::FtTask {
            kind,
            name,
            local_path,
            total: std::sync::atomic::AtomicU64::new(total),
            done: std::sync::atomic::AtomicU64::new(0),
            cancel: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            // Placeholder until the event loop binds the protocol id.
            client_ft_id: std::sync::atomic::AtomicU16::new(u16::MAX),
            last_event: parking_lot::Mutex::new(None),
        }),
    );
    task_id
}

/// Pushes the initial ft_started event for a freshly registered task.
fn ft_push_started(task_id: u32) {
    if let Some(t) = FT_TASKS.get(&task_id) {
        let event = TsEvent::FtStarted {
            task_id,
            kind: t.kind,
            name: t.name.clone(),
            total: t.total.load(Ordering::Relaxed),
        };
        STATE.lock().pending_events.push_back(event);
    }
}

/// True while a live connection with a running event loop exists — a
/// prerequisite for queueing any file transfer command.
fn ft_ready() -> bool {
    STATE.lock().connected && crate::EVENT_LOOP_ALIVE.load(Ordering::SeqCst)
}

/// The plaintext password carried by ft commands (None when empty).
fn ft_password(pw: *const c_char) -> Option<String> {
    let s = unsafe { cstr_to_string(pw) };
    if s.is_empty() { None } else { Some(s) }
}

#[no_mangle]
pub extern "C" fn ts_ft_list(
    cid: u32,
    path: *const c_char,
    pw: *const c_char,
    token: *const c_char,
) -> u8 {
    if !ft_ready() || token.is_null() {
        return 0;
    }
    let path = normalize_remote_path(&unsafe { cstr_to_string(path) });
    if !valid_remote_path(&path) {
        return 0;
    }
    let token = unsafe { cstr_to_string(token) };
    if token.is_empty() {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    match tx.as_ref().map(|tx| {
        tx.send(Command::FtList {
            cid: cid as u64,
            path,
            password: ft_password(pw),
            token,
        })
    }) {
        Some(Ok(())) => 1,
        _ => 0,
    }
}

/// Remote paths are rooted at "/" and must not escape via ".." segments.
/// The bare root "/" is a valid address (channel storage top level).
fn valid_remote_path(path: &str) -> bool {
    if path == "/" {
        return true;
    }
    path.starts_with('/')
        && !path.contains('\0')
        && !path.split('/').any(|seg| seg == "..")
}

#[no_mangle]
pub extern "C" fn ts_ft_mkdir(
    cid: u32,
    path: *const c_char,
    pw: *const c_char,
    token: *const c_char,
) -> u8 {
    if !ft_ready() || token.is_null() {
        return 0;
    }
    // The full remote directory address (".../newname"), never a bare name.
    let dirname = normalize_remote_path(&unsafe { cstr_to_string(path) });
    if !valid_remote_path(&dirname) {
        return 0;
    }
    let token = unsafe { cstr_to_string(token) };
    if token.is_empty() {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    match tx.as_ref().map(|tx| {
        tx.send(Command::FtCreateDir {
            cid: cid as u64,
            dirname,
            password: ft_password(pw),
            token,
        })
    }) {
        Some(Ok(())) => 1,
        _ => 0,
    }
}

/// Deletes one or more entries in one ftdeletefile command. `names_json` is
/// a JSON array of COMPLETE remote paths, e.g. `["\/dir\/a.txt","\/old"]`.
/// Directories are removed recursively by the server.
#[no_mangle]
pub extern "C" fn ts_ft_delete(
    cid: u32,
    names_json: *const c_char,
    pw: *const c_char,
    token: *const c_char,
) -> u8 {
    if !ft_ready() || token.is_null() {
        return 0;
    }
    let names_raw = unsafe { cstr_to_string(names_json) };
    let raw: Vec<String> = match serde_json::from_str(&names_raw) {
        Ok(v) => v,
        Err(_) => return 0,
    };
    if raw.is_empty() {
        return 0;
    }
    let names: Vec<String> = raw
        .iter()
        .map(|n| normalize_remote_path(n))
        .filter(|n| valid_remote_path(n))
        .collect();
    if names.is_empty() {
        return 0;
    }
    let token = unsafe { cstr_to_string(token) };
    if token.is_empty() {
        return 0;
    }
    let tx = COMMAND_TX.lock();
    match tx.as_ref().map(|tx| {
        tx.send(Command::FtDelete {
            cid: cid as u64,
            names,
            password: ft_password(pw),
            token,
        })
    }) {
        Some(Ok(())) => 1,
        _ => 0,
    }
}

/// Starts downloading a remote file into `dest` (local absolute path).
/// Returns the task id (>0) for progress/cancel tracking, 0 when not queued.
#[no_mangle]
pub extern "C" fn ts_ft_download(
    cid: u32,
    path: *const c_char,
    dest: *const c_char,
    pw: *const c_char,
) -> u32 {
    if !ft_ready() || dest.is_null() {
        return 0;
    }
    let path = normalize_remote_path(&unsafe { cstr_to_string(path) });
    if !valid_remote_path(&path) {
        return 0;
    }
    let dest = unsafe { cstr_to_string(dest) };
    if dest.is_empty() {
        return 0;
    }
    let name = remote_basename(&path);
    let task_id = ft_new_task(FT_KIND_DOWNLOAD, name.clone(), dest, 0);
    ft_push_started(task_id);
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::FtDownload {
                cid: cid as u64,
                path,
                password: ft_password(pw),
                task_id,
            })
            .is_ok()
        {
            return task_id;
        }
    }
    // Event loop unreachable — fail the task immediately so no job hangs.
    crate::finish_ft_task(task_id, false, Some("event loop unavailable".into()));
    task_id
}

/// Starts downloading a client's avatar into `dest` (local absolute path).
/// The remote path follows the TS3 convention: `/avatar_<uid>` where the uid
/// is base64-decoded and hex-encoded with the alphabet [a-p]
/// (`Uid::as_avatar`). Avatars live in the channel-0 file storage without a
/// password. Returns the task id (>0) for progress/cancel tracking, 0 when
/// not queued (not connected, malformed uid).
#[no_mangle]
pub extern "C" fn ts_download_avatar(uid: *const c_char, dest: *const c_char) -> u32 {
    if !ft_ready() || dest.is_null() {
        return 0;
    }
    let uid = unsafe { cstr_to_string(uid) };
    let raw = match BASE64_STANDARD.decode(uid.as_bytes()) {
        Ok(raw) => raw,
        Err(_) => return 0,
    };
    let path = normalize_remote_path(&format!(
        "/avatar_{}",
        tsproto_types::Uid::from_bytes(&raw).as_avatar()
    ));
    if !valid_remote_path(&path) {
        return 0;
    }
    let dest = unsafe { cstr_to_string(dest) };
    if dest.is_empty() {
        return 0;
    }
    let name = remote_basename(&path);
    let task_id = ft_new_task(FT_KIND_DOWNLOAD, name.clone(), dest, 0);
    ft_push_started(task_id);
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::FtDownload {
                cid: 0,
                path,
                password: None,
                task_id,
            })
            .is_ok()
        {
            return task_id;
        }
    }
    // Event loop unreachable — fail the task immediately so no job hangs.
    crate::finish_ft_task(task_id, false, Some("event loop unavailable".into()));
    task_id
}

/// Starts uploading the local file `src` to the remote path. Returns the
/// task id (>0), 0 when not queued (e.g. missing source file).
#[no_mangle]
pub extern "C" fn ts_ft_upload(
    cid: u32,
    path: *const c_char,
    src: *const c_char,
    pw: *const c_char,
) -> u32 {
    if !ft_ready() || src.is_null() {
        return 0;
    }
    let path = normalize_remote_path(&unsafe { cstr_to_string(path) });
    if !valid_remote_path(&path) {
        return 0;
    }
    let src = unsafe { cstr_to_string(src) };
    let meta = std::fs::metadata(&src);
    // Only existing local files are accepted; zero-byte files are fine.
    if src.is_empty() || meta.as_ref().map(|m| !m.is_file()).unwrap_or(true) {
        return 0;
    }
    let total = meta.map(|m| m.len()).unwrap_or(0);
    let name = remote_basename(&path);
    let task_id = ft_new_task(FT_KIND_UPLOAD, name.clone(), src.clone(), total);
    ft_push_started(task_id);
    let tx = COMMAND_TX.lock();
    if let Some(tx) = tx.as_ref() {
        if tx
            .send(Command::FtUpload {
                cid: cid as u64,
                path,
                password: ft_password(pw),
                task_id,
            })
            .is_ok()
        {
            return task_id;
        }
    }
    crate::finish_ft_task(task_id, false, Some("event loop unavailable".into()));
    task_id
}

/// Requests cancellation of an active transfer (cooperative flag).
#[no_mangle]
pub extern "C" fn ts_ft_cancel(task_id: u32) -> u8 {
    match FT_TASKS.get(&task_id) {
        Some(t) => {
            t.cancel.store(true, Ordering::Relaxed);
            1
        }
        None => 0,
    }
}

/// Install a custom SFX sample. `kind` is 1..=37 (see the SFX_* consts);
/// `data` points to `len` bytes of a RIFF/WAVE file (PCM 16-bit or IEEE
/// float32, 1/2 channels, ≤2s — anything else is rejected without touching
/// the currently active sample).
///
/// Returns 0 on success, 1 for an invalid kind, 2 for an unsupported format,
/// 3 for empty/too-long input.
#[no_mangle]
pub extern "C" fn ts_set_sfx_sample(kind: u8, data: *const u8, len: usize) -> i32 {
    if !(1..=37).contains(&kind) {
        return 1;
    }
    if data.is_null() || len == 0 {
        return 3;
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match crate::parse_wav_pcm(bytes) {
        Ok(samples) => {
            let guard = crate::SFX_SAMPLES.load();
            let mut next = (**guard).clone();
            drop(guard);
            next[(kind - 1) as usize] = Some(std::sync::Arc::new(samples));
            crate::SFX_SAMPLES.store(std::sync::Arc::new(next));
            eprintln!("[sfx] set custom sample kind={}", kind);
            0
        }
        Err(msg) => {
            eprintln!("[sfx] set kind={} rejected: {}", kind, msg);
            if msg.contains("too long") || msg.contains("no audio data") {
                3
            } else {
                2
            }
        }
    }
}

/// Restore the built-in sample for an SFX kind (1..=37). Returns 0 on
/// success, 1 for an invalid kind.
#[no_mangle]
pub extern "C" fn ts_clear_sfx_sample(kind: u8) -> i32 {
    if !(1..=37).contains(&kind) {
        return 1;
    }
    let guard = crate::SFX_SAMPLES.load();
    let mut next = (**guard).clone();
    drop(guard);
    next[(kind - 1) as usize] = crate::SFX_BUILTIN[(kind - 1) as usize]
        .as_ref()
        .map(|s| std::sync::Arc::new(s.clone()));
    crate::SFX_SAMPLES.store(std::sync::Arc::new(next));
    eprintln!("[sfx] restored builtin sample kind={}", kind);
    0
}

/// Play the active sample for an SFX kind immediately (settings-page
/// preview). If no cpal output stream is running, one is started first — the
/// queue push happens after the rebuild so it is not drained by it.
/// Returns 0 on success, 1 for an invalid kind.
#[no_mangle]
pub extern "C" fn ts_play_sfx(kind: u8) -> i32 {
    if !(1..=37).contains(&kind) {
        return 1;
    }
    if AUDIO_STREAM.lock().unwrap().0.is_none() {
        restart_output_stream();
    }
    crate::SFX_QUEUE.push(kind);
    eprintln!("[sfx] manual preview kind={}", kind);
    0
}
