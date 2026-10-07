use crate::{
    Command, TsChannel, TsClient, TsChannelGroup, TsEvent, TsFtEntry, TsPerm, TsServerGroup,
    ACTIVE_CLIENT_IDS, AUDIO_DECODERS, AUDIO_DECODERS_STEREO, AUDIO_LAST_ERROR, AUDIO_STREAM,
    CB_STATS, CLIENT_BUFFERS, CLOCK_REF, COMMAND_TX, FRAME_SIZE, FT_KIND_DOWNLOAD,
    FT_KIND_UPLOAD, FT_TASKS, FT_TASK_SEQ, IDENTITY_STASH, JITTER_STATS, MIC_RESTART_REQUESTED,
    MIN_SURPLUS_FRAMES, OUTPUT_PERIOD_MS, OUTPUT_RATE, OUTPUT_RESTART_REQUESTED, PLAYED_SAMPLES,
    RUNTIME, SFX_ARMED, SFX_DEFERRED_TEARDOWN, SFX_QUEUE, SFX_SUPPRESS_DISCONNECT, STATE,
    SWIPE_DISCONNECT, TALKING_CLIENTS, TARGET_FRAMES_CEIL, TARGET_FRAMES_FLOOR, recording,
    mic_pipeline::MIC_PIPELINE,
    play_time_ms, publish_clock_ref,
};

use futures::FutureExt;
use opus_rs::OpusDecoder;
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::io::{Read as _, Write as _};
use std::os::raw::c_char;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};
use univox_core::connect::{ConnectOptions, InitialChannel};
use univox_core::event::Event as UxEvent;
use univox_core::id::{ChannelId, MemberId};
use univox_core::model::{
    ChannelOptions, ClientMoveReason, DisconnectReason, MemberLeftReason, MessageTarget,
    Permanence,
};
use univox_core::session::Session as _;
use univox_ts3::session::{self_clid, Ts3ConnectOptions, Ts3Session};
use univox_ts3::{FileDownload, FileUpload, SelfUpdate, Ts3Ext as _};
use univox_ts3_proto::{hash_password, Command as Ts3Command, PacketType, RowExt, VoiceData};
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

/// Extracts a human-readable message from a `catch_unwind` panic payload.
fn panic_msg(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".into()
    }
}

/// Runs `f` with panics contained: logs and swallows them so a handler bug
/// cannot unwind into the event loop and kill the session.
fn contain_panic<R>(what: &str, f: impl FnOnce() -> R) -> Option<R> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => Some(v),
        Err(p) => {
            let msg = panic_msg(&p);
            eprintln!("{} PANICKED: {}", what, msg);
            push_diag(&format!("{} PANICKED: {}", what, msg));
            None
        }
    }
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

/// Streams an accepted download onto the local disk. Runs on the tokio
/// runtime — `FileDownload::next_chunk` is async — and polls the
/// cooperative cancel flag between chunks. Dropping the handle mid-transfer
/// closes the TCP stream, which aborts the transfer server-side.
fn spawn_download_task(task_id: u32, mut dl: FileDownload) {
    RUNTIME.spawn(async move {
        let (local_path, cancel_flag) = match FT_TASKS.get(&task_id) {
            Some(t) => (t.local_path.clone(), t.cancel.clone()),
            None => return, // task vanished while starting
        };
        let total = dl.size();
        if let Some(t) = FT_TASKS.get(&task_id) {
            t.total.store(total, Ordering::Relaxed);
        }
        if let Some(t) = FT_TASKS.get(&task_id) {
            maybe_publish_ft_progress(task_id, &t, true);
        }
        let result: Result<(), String> = async {
            if let Some(parent) = std::path::Path::new(&local_path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let mut file = std::fs::File::create(&local_path).map_err(|e| format!("{e}"))?;
            let mut received: u64 = 0;
            loop {
                if cancel_flag.load(Ordering::Relaxed) {
                    // Keep the partial file; Dart reports the cancellation.
                    drop(file);
                    drop(dl);
                    crate::finish_ft_task(task_id, false, Some("canceled".into()));
                    return Ok(());
                }
                match dl.next_chunk().await {
                    Ok(Some(chunk)) => {
                        file.write_all(&chunk).map_err(|e| format!("{e}"))?;
                        received += chunk.len() as u64;
                        FT_TASKS.get(&task_id).map(|t| {
                            t.done.store(received, Ordering::Relaxed);
                            maybe_publish_ft_progress(task_id, &t, false)
                        });
                    }
                    Ok(None) => break, // EOF — server finished sending
                    Err(e) => return Err(format!("{}", e)),
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
            // Graceful stop: tells the server the transfer is over and
            // collects its final status.
            dl.finish()
                .await
                .map_err(|e| format!("transfer status: {}", e))?;
            FT_TASKS.get(&task_id).map(|t| {
                t.done.store(received, Ordering::Relaxed);
            });
            crate::finish_ft_task(task_id, true, None);
            Ok(())
        }
        .await;
        if let Err(e) = result {
            crate::finish_ft_task(task_id, false, Some(e));
        }
    });
}

/// Streams a local file into an accepted upload slot. `FileUpload::finish`
/// verifies the byte count and commits the file server-side; `abort`
/// deletes the partial file.
fn spawn_upload_task(task_id: u32, mut up: FileUpload, src: String) {
    RUNTIME.spawn(async move {
        let cancel_flag = match FT_TASKS.get(&task_id) {
            Some(t) => t.cancel.clone(),
            None => return,
        };
        let result: Result<(), String> = async {
            let mut file = std::fs::File::open(&src).map_err(|e| format!("{e}"))?;
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                if cancel_flag.load(Ordering::Relaxed) {
                    up.abort().await.ok();
                    crate::finish_ft_task(task_id, false, Some("canceled".into()));
                    return Ok(());
                }
                let n = file.read(&mut buf).map_err(|e| format!("{e}"))?;
                if n == 0 {
                    break;
                }
                up.write_chunk(&buf[..n])
                    .await
                    .map_err(|e| format!("{}", e))?;
                FT_TASKS.get(&task_id).map(|t| {
                    t.done.fetch_add(n as u64, Ordering::Relaxed);
                    maybe_publish_ft_progress(task_id, &t, false);
                });
            }
            // Commit: verifies the byte count and waits for the server's
            // final status (notifystatusfiletransfer is consumed inside).
            up.finish().await.map_err(|e| format!("{}", e))?;
            crate::finish_ft_task(task_id, true, None);
            Ok(())
        }
        .await;
        if let Err(e) = result {
            crate::finish_ft_task(task_id, false, Some(e));
        }
    });
}

// ─── Permission hints (best effort) ─────────────────────────────────

/// Best-effort permission-hint bits derived from OUR OWN directly-assigned
/// permission list. tsclientlib computed these hints inside its bookkeeping
/// layer; univox does not model them, so the same bits are approximated from
/// the permsids we hold: a listed, non-negated, non-zero permission lights
/// its bit. Channel-scoped grants are not considered — treat the result as
/// the low-threshold UI hint it always was.
const CLIENT_HINT_TABLE: &[(u64, &str)] = &[
    (1, "i_client_kick_from_server_power"), // KICK_SERVER
    (2, "i_client_kick_from_channel_power"), // KICK_CHANNEL
    (4, "i_client_ban_power"),              // BAN
    (8, "i_client_move_power"),             // MOVE_CLIENT
    (16, "b_client_private_textmessage_send"), // PRIVATE_MESSAGE
    (32, "i_client_poke_power"),            // POKE
    (64, "i_client_whisper_power"),         // WHISPER
    (128, "i_client_complain_power"),       // COMPLAIN
    (256, "i_client_permission_modify_power"), // MODIFY_PERMISSIONS
];

const CHANNEL_HINT_TABLE: &[(u64, &str)] = &[
    (1, "i_channel_join_power"),            // JOIN
    (2, "i_channel_modify_power"),          // MODIFY
    (4, "b_channel_delete_flag_force"),     // FORCE_DELETE
    (8, "b_channel_delete_permanent"),      // DELETE (any permanence kind)
    (8, "b_channel_delete_semi_permanent"),
    (8, "b_channel_delete_temporary"),
    (16, "i_channel_subscribe_power"),      // SUBSCRIBE
    (64, "i_ft_file_upload_power"),         // FILE_UPLOAD
    (128, "i_ft_file_download_power"),      // FILE_DOWNLOAD
    (256, "i_ft_file_delete_power"),        // FILE_DELETE
    (512, "i_ft_file_rename_power"),        // FILE_RENAME
    (1024, "i_ft_file_browse_power"),       // FILE_BROWSE
    (2048, "i_ft_directory_create_power"),  // FILE_DIRECTORY_CREATE
    (2048, "i_ft_file_upload_power"),       // (upload power covers dirs)
    (4096, "i_channel_permission_modify_power"), // MODIFY_PERMISSIONS
];

fn hints_from_perms(own_perms: &[TsPerm], table: &[(u64, &str)]) -> u64 {
    let mut bits = 0u64;
    for (bit, permsid) in table {
        let granted = own_perms.iter().any(|p| {
            &p.name == permsid && !p.negated && p.value != 0
        });
        if granted {
            bits |= bit;
        }
    }
    bits
}

/// Rebuilds the roster JSON (channels + clients) from the univox book mirror.
/// Field-for-field compatible with the previous tsclientlib-backed version:
/// ts_ffi.dart parses these structs with hand-written fromJson code, so the
/// JSON keys are API. TS3-specific values (uid, database id, avatar hash,
/// groups, talk power, limits) arrive inside `extra` as their raw wire keys.
fn refresh_from_book(book: &univox_core::Book) -> (Vec<TsChannel>, Vec<TsClient>) {
    // One consistent read of the mirror: server + channels + members with
    // their runtime states.
    let Some((server, channels_raw, members_raw)) = book.with(|b| {
        (
            b.server.clone().unwrap_or_default(),
            b.channels.values().cloned().collect::<Vec<_>>(),
            b.members
                .values()
                .map(|m| {
                    (
                        m.clone(),
                        b.member_states.get(&m.id).cloned().unwrap_or_default(),
                    )
                })
                .collect::<Vec<_>>(),
        )
    }) else {
        return (Vec::new(), Vec::new());
    };

    // Per-channel client counts.
    let mut count: HashMap<u64, u32> = HashMap::new();
    for (m, _) in &members_raw {
        if let Some(cid) = m.channel_id.as_ref().and_then(|c| c.as_u64()) {
            *count.entry(cid).or_insert(0) += 1;
        }
    }

    // Group caches are maintained by the servergrouplist/channelgrouplist
    // execs (see refresh_group_lists), not by the book.
    let cached_groups = STATE.lock().server_groups.clone();

    {
        let mut state = STATE.lock();
        // Server property snapshot for the server-settings dialog prefill;
        // a successful serveredit lands here on the next book event batch.
        state.server_name = server.name.clone();
        state.server_max_clients = if server.member_limit > 0 {
            Some(server.member_limit as u16)
        } else {
            None
        };
        // univox maps virtualserver_welcomemessage into Server.host_message
        // (with the host message as fallback); the raw keys are preserved in
        // extra — prefer them.
        state.server_welcome_message = server
            .extra
            .get("virtualserver_welcomemessage")
            .or_else(|| server.extra.get("virtualserver_hostmessage"))
            .cloned()
            .or_else(|| server.host_message.clone())
            .unwrap_or_default();
        state.server_has_password = server
            .extra
            .get("virtualserver_flag_password")
            .map(|v| v == "1");
    }

    let own_perms = STATE.lock().own_perms.clone();
    let client_hints = hints_from_perms(&own_perms, &CLIENT_HINT_TABLE);
    let channel_hints = hints_from_perms(&own_perms, &CHANNEL_HINT_TABLE);

    let channels = channels_raw
        .iter()
        .map(|c| {
            let ex = |k: &str| c.extra.get(k).map(|s| s.as_str());
            let cid = c.id.as_u64().unwrap_or(0);
            TsChannel {
                id: cid as u32,
                name: c.name.clone(),
                parent_id: c.parent_id.as_ref().and_then(|p| p.as_u64()).unwrap_or(0) as u32,
                topic: c.topic.clone().unwrap_or_default(),
                has_password: c.password_protected,
                client_count: *count.get(&cid).unwrap_or(&0),
                order: c.order as u32,
                is_default: c.is_default,
                permission_hints: channel_hints,
                needed_talk_power: ex("channel_needed_talk_power")
                    .and_then(|v| v.parse::<i64>().ok())
                    .unwrap_or(0) as i32,
                // -1 = unlimited / inherited / not yet reported.
                max_clients: if ex("channel_flag_maxclients_unlimited") == Some("1") {
                    -1
                } else if c.user_limit > 0 {
                    c.user_limit as i32
                } else {
                    -1
                },
                is_permanent: c.permanence == Permanence::Permanent,
                is_semi_permanent: c.permanence == Permanence::SemiPermanent,
                description: c.description.clone().unwrap_or_default(),
                // -1 inherited, 0 unlimited, >0 limit.
                max_family_clients: if ex("channel_flag_maxfamilyclients_unlimited") == Some("1") {
                    0
                } else if ex("channel_flag_inherited_maxfamilyclients") == Some("1") {
                    -1
                } else {
                    ex("channel_maxfamilyclients")
                        .and_then(|v| v.parse::<i64>().ok())
                        .map(|v| v as i32)
                        .filter(|v| *v > 0)
                        .unwrap_or(-1)
                },
                delete_delay: ex("channel_delete_delay")
                    .and_then(|v| v.parse::<i64>().ok())
                    .unwrap_or(0),
            }
        })
        .collect();
    let clients: Vec<_> = members_raw
        .iter()
        .map(|(m, st)| {
            let ex = |k: &str| m.extra.get(k).map(|s| s.as_str());
            let id = m.id.as_u64().unwrap_or(0);
            let uid = ex("client_unique_identifier").filter(|s| !s.is_empty()).map(String::from);
            let cid = id as u16;
            // What WE may do to this client (raw client-permission-hint bits).
            let permission_hints = client_hints;
            let server_groups: Vec<u64> = ex("client_servergroups")
                .unwrap_or("")
                .split(',')
                .filter(|s| !s.is_empty())
                .filter_map(|s| s.parse::<u64>().ok())
                .collect();
            let server_group_names: Vec<String> = server_groups
                .iter()
                .filter_map(|g| cached_groups.iter().find(|sg| sg.id == *g).map(|sg| sg.name.clone()))
                .collect();
            // 0 = normal client, 1 = server query (the query-admin variant
            // tsclientlib derived is not carried by univox's mirror).
            let client_type = match ex("client_type") {
                Some("1") => 1u8,
                _ => 0u8,
            };
            // Volume + 2D position — one STATE lock for both (both keyed by UID).
            let (volume, pos) = {
                let state = STATE.lock();
                // Primary source: persisted dB value keyed by the user UID
                let persisted = uid
                    .as_ref()
                    .and_then(|uid| state.client_volumes.get(uid.as_str()).copied());
                let volume = persisted.unwrap_or_else(|| {
                    // Fallback: convert linear gain from jitter buffer → dB
                    crate::CLIENT_BUFFERS
                        .get(&cid)
                        .map(|b| {
                            let gain = f32::from_bits(b.volume.load(Ordering::Relaxed));
                            20.0 * gain.max(1e-10).log10()
                        })
                        .unwrap_or(0.0) // default: 0 dB = unity gain
                });
                let pos = uid
                    .as_ref()
                    .and_then(|uid| state.client_positions.get(uid.as_str()).copied());
                (volume, pos)
            };
            TsClient {
                id: id as u32,
                nickname: m.nickname.clone(),
                channel_id: m.channel_id.as_ref().and_then(|c| c.as_u64()).unwrap_or(0) as u32,
                uid,
                // Empty hash = the server announces no avatar for this client.
                avatar_hash: ex("client_flag_avatar")
                    .filter(|s| !s.is_empty())
                    .map(String::from),
                database_id: ex("client_database_id")
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0),
                away: st.away_message.is_some(),
                input_muted: st.input_muted,
                output_muted: st.output_muted,
                client_type,
                is_channel_commander: st.channel_commander,
                is_recording: st.recording,
                is_priority_speaker: st.priority_speaker,
                // client_is_talker: missing on incremental rows — assume
                // granted rather than flashing a "cannot talk" state.
                talk_power_granted: ex("client_is_talker").map(|v| v == "1").unwrap_or(true),
                talk_power: st.talk_power as i32,
                permission_hints,
                server_groups,
                server_group_names,
                channel_group: ex("client_channel_group_id")
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0) as u32,
                is_talking: TALKING_CLIENTS
                    .get(&cid)
                    .map(|t| t.elapsed().as_millis() < 500)
                    .unwrap_or(false),
                volume,
                pos_x: pos.map(|p| p.0),
                pos_y: pos.map(|p| p.1),
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
    token: *const c_char,
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
    // Privilege key for the first login; empty means "no token".
    let token = if token.is_null() {
        None
    } else {
        let t = unsafe { std::ffi::CStr::from_ptr(token) }
            .to_string_lossy()
            .into_owned();
        if t.is_empty() { None } else { Some(t) }
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
        if let Err(e) = do_connect(address, nickname, channel, password, token).await {
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

/// Re-fetches the server/channel group lists into STATE. The typed
/// `Ts3Ext::server_groups` helpers don't carry the power/sort fields the UI
/// renders, so the raw rows are parsed here.
async fn refresh_group_lists(session: &Arc<Ts3Session>) {
    if let Ok(rows) = session.exec(Ts3Command::new("servergrouplist")).await {
        let groups: Vec<TsServerGroup> = rows
            .iter()
            .map(|r| TsServerGroup {
                id: r.get("sgid").and_then(|v| v.parse().ok()).unwrap_or(0),
                name: r.get("name").unwrap_or("").to_string(),
                is_permanent: r.get("savedb").map(|v| v == "1").unwrap_or(true),
                needed_member_add_power: r
                    .get("n_member_addp")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
                needed_member_remove_power: r
                    .get("n_member_removep")
                    .and_then(|v| v.parse().ok()),
                sort_id: r.get("sortid").and_then(|v| v.parse().ok()).unwrap_or(0),
            })
            .collect();
        STATE.lock().server_groups = groups;
    }
    if let Ok(rows) = session.exec(Ts3Command::new("channelgrouplist")).await {
        let groups: Vec<TsChannelGroup> = rows
            .iter()
            .map(|r| TsChannelGroup {
                id: r.get("cgid").and_then(|v| v.parse().ok()).unwrap_or(0),
                name: r.get("name").unwrap_or("").to_string(),
                is_permanent: r.get("savedb").map(|v| v == "1").unwrap_or(true),
                needed_member_add_power: r
                    .get("n_member_addp")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
                needed_member_remove_power: r
                    .get("n_member_removep")
                    .and_then(|v| v.parse().ok()),
                sort_id: r.get("sortid").and_then(|v| v.parse().ok()).unwrap_or(0),
            })
            .collect();
        STATE.lock().channel_groups = groups;
    }
}

/// Re-requests OUR OWN directly-assigned permission list (`clientpermlist`)
/// and stores it in STATE — the low-threshold UI hint. Resolves our own
/// database id first (the client protocol has no `whoami`).
async fn refresh_own_perms(session: &Arc<Ts3Session>) {
    let Ok(uid) = session.own_uid().await else {
        return;
    };
    let Ok(Some(dbid)) = session.dbid_from_uid(&uid).await else {
        return;
    };
    let Ok(rows) = session
        .exec(
            Ts3Command::new("clientpermlist")
                .param("cldbid", dbid.as_u64().unwrap_or(0))
                .opt("permsid"),
        )
        .await
    else {
        return;
    };
    let list: Vec<TsPerm> = rows
        .iter()
        .map(|r| TsPerm {
            name: r.get("permsid").unwrap_or("").to_string(),
            value: r.get("permvalue").and_then(|v| v.parse().ok()).unwrap_or(0),
            negated: r.get("permnegated").map(|v| v == "1").unwrap_or(false),
            skip: r.get("permskip").map(|v| v == "1").unwrap_or(false),
        })
        .collect();
    push_diag(&format!("own clientpermlist: {} entries", list.len()));
    STATE.lock().own_perms = list;
}

async fn do_connect(
    address: String,
    nickname: String,
    channel: Option<String>,
    password: Option<String>,
    token: Option<String>,
) -> Result<(), String> {
    crate::install_panic_hook();

    // Address prelude (same as the univox driver): parse invite links and
    // host[:port], resolve the port via TSDNS for bare hosts.
    let parsed = univox_ts3::address::parse(&address)
        .map_err(|e| format!("bad address {address}: {e}"))?;
    let port = if parsed.port_explicit {
        parsed.port
    } else {
        univox_ts3::address::resolve_port(
            &parsed.host,
            parsed.channel.as_deref().unwrap_or(""),
            univox_ts3::address::DEFAULT_TSDNS_PORT,
        )
        .await
        .map_err(|e| format!("port resolve failed: {e}"))?
    };

    // The Dart side persists the identity in the tsclientlib/tsproto JSON
    // shape ({key, counter, max_counter}); univox parses and re-serializes
    // that exact format, so the stored string round-trips unchanged.
    let identity_json = IDENTITY_STASH.lock().take();
    let identity = match identity_json.as_deref().filter(|s| !s.is_empty()) {
        Some(json) => univox_ts3_proto::Identity::from_tsclientlib_json(json)
            .map_err(|e| format!("bad stored identity: {e}"))?,
        None => univox_ts3_proto::Identity::create(),
    };

    let mut opts = ConnectOptions::new(format!("{}:{}", parsed.host, port))
        .nickname(nickname.clone());
    if let Some(ch) = channel.as_deref().filter(|c| !c.is_empty()) {
        opts = opts.initial_channel(InitialChannel::Path(ch.to_string()));
    }
    opts = opts.with_extension(Ts3ConnectOptions {
        server_password: password.clone().filter(|p| !p.is_empty()),
        privilege_key: token.clone().filter(|t| !t.is_empty()),
        upgrade_identity_to: Some(24),
        ..Default::default()
    });

    // Disarm channel-event SFX until the connect-time roster burst has flown
    // by; also reset the disconnect suppression and deferred-teardown flags
    // from a previous connection.
    SFX_ARMED.store(false, Ordering::Relaxed);
    SFX_SUPPRESS_DISCONNECT.store(false, Ordering::Relaxed);
    SFX_DEFERRED_TEARDOWN.store(false, Ordering::Relaxed);

    let session = Ts3Session::connect(opts, identity)
        .await
        .map_err(|e| format!("{e}"))?;

    let own_id = self_clid(&session) as u32;

    // Subscribe to every channel so roster updates stream in, then fill the
    // group caches and our own permission list (both are plain execs whose
    // answers are parsed and stored directly — no event-driven collection).
    if let Err(e) = session.subscribe_all().await {
        // Permission-restricted servers deny bulk subscribe — the roster
        // then only grows with own-channel occupants. Make it visible.
        eprintln!("subscribe_all failed: {e}");
        push_diag(&format!("subscribe_all failed: {}", error_text(&e)));
    }
    refresh_group_lists(&session).await;
    refresh_own_perms(&session).await;

    let book = session.book();
    let (channels, clients) = refresh_from_book(&book);

    eprintln!(
        "do_connect: OK, {} channels, {} clients, own_id={}",
        channels.len(),
        clients.len(),
        own_id
    );
    // Ground truth for roster issues: where the mirror thinks we are.
    eprintln!(
        "do_connect: own roster entry: {:?}",
        clients
            .iter()
            .find(|c| c.id as u64 == own_id as u64)
            .map(|c| (c.nickname.clone(), c.channel_id))
    );

    // Server texts from initserver. The raw virtualserver_* keys are
    // preserved in Server.extra (see the univox bookkeeping pump).
    let server = book.server().unwrap_or_default();
    let ex = |k: &str| server.extra.get(k).cloned().unwrap_or_default();
    let welcome_message = ex("virtualserver_welcomemessage");
    let hostmessage = ex("virtualserver_hostmessage");
    let hostmessage_mode = ex("virtualserver_hostmessage_mode")
        .parse::<u8>()
        .unwrap_or(0);
    let ask_for_privilegekey = ex("virtualserver_ask_for_privilegekey") == "1";

    let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel();
    let generation = crate::CONNECTION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    *COMMAND_TX.lock() = Some(cmd_tx);

    {
        let mut state = STATE.lock();
        state.connecting = false;
        state.connected = true;
        state.server_name = server.name.clone();
        state.own_client_id = own_id;
        // A fresh connection starts unmuted and present (no initial_state is
        // requested) — stale values from a previous session must not leak.
        state.self_input_muted = false;
        state.self_output_muted = false;
        state.self_away = false;
        state.channels = channels;
        state.clients = clients;
        state.pending_events.push_back(TsEvent::Connected {
            server_name: server.name.clone(),
            client_id: own_id,
            ask_for_privilegekey,
            welcome_message,
            hostmessage,
            hostmessage_mode,
        });
    }

    // Persist the identity actually used: the hash-cash upgrade ran before
    // the handshake and its counter/max_counter must reach Dart's storage,
    // or the next session resumes from a stale counter.
    *IDENTITY_STASH.lock() = Some(session.identity().to_tsclientlib_json());

    *crate::CONNECTION_STASH.lock() = Some(session.clone());

    // --- Push-mode audio output (cpal) with sample-driven mixing ---
    spawn_maintenance_task();
    restart_output_stream();
    // Queue the connected sound after the stream restart — the restart
    // drains the SFX queue, so pushing before it would lose the request.
    push_sfx(SFX_CONNECTED, "connected");

    // Arm channel-event SFX after the connect-time burst (the subscribe-all
    // enterview wave) has flown by; everything before that must stay silent.
    let settle_session = session.clone();
    RUNTIME.spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        if STATE.lock().connected {
            SFX_ARMED.store(true, Ordering::Relaxed);
            push_diag("sfx armed after connect settle");
            // Late roster catch-up: the clientlist dump can be denied
            // (plain-user permission) and the enterview wave can land
            // before Dart's event subscription — without this re-push a
            // quiet server never re-publishes the roster, leaving the own
            // channel unknown in the UI until the first move.
            let book = settle_session.book();
            refresh_roster(&book);
        }
    });

    let loop_session = session.clone();
    RUNTIME.spawn(async move {
        let handle = RUNTIME.spawn(event_loop(loop_session, cmd_rx, generation));
        let result = handle.catch_unwind().await;
        match result {
            Ok(_) => push_diag("event_loop: exited normally"),
            Err(e) => {
                let msg = panic_msg(&e);
                eprintln!("event_loop PANICKED: {} (gen={})", msg, generation);
                push_diag(&format!("event_loop PANICKED: {}", msg));
                // The loop died without running any of its teardown paths.
                // Leave a clean "disconnected" state behind — otherwise the
                // UI stays stuck on a ghost connection (no audio, disconnect
                // dead, reconnect blocked by connected=true).
                let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
                if current_gen == generation {
                    let mut s = STATE.lock();
                    s.connected = false;
                    s.disconnect_requested = false;
                    s.pending_events.push_back(TsEvent::Disconnected {
                        reason: format!("Internal error: {}", msg),
                    });
                    drop(s);
                    schedule_sfx_teardown(SFX_CONNECTION_LOST);
                    *COMMAND_TX.lock() = None;
                }
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
///
/// The playout lead of the stream this packet belongs to is anchored here and
/// adapted from the arrival margins measured here (see [crate::JitterStats]).
/// The payload arrives as the raw fields of univox's `VoiceData::S2C` /
/// `S2CWhisper` — same shape the tsclientlib audio packets carried (speaker
/// client id, voice sequence number, raw Opus bytes).
fn decode_to_client_buffer(from_id: u16, seq_id: u16, opus_vec: Vec<u8>) {
    const FRAME: usize = 960;
    const REBASE_LEAD: u64 = 4; // reader ≥4 frames (80ms) ahead before realigning

    let seq_u16 = seq_id;

    // Parse the Opus TOC byte: the top 5 bits are the config, bit 2 is the
    // stereo flag, the low 2 bits the frame-count code. Decode with the
    // matching channel count and keep the result stereo end-to-end — stereo
    // sources (e.g. music bots) must reach the mixer as L/R so they can be
    // positioned; never downmixed here. The frame stored in the jitter buffer
    // carries 960 (mono) or 1920 (stereo interleaved) samples.
    let stereo_packet = !opus_vec.is_empty() && (opus_vec[0] >> 2) & 1 == 1;
    let out_len = if stereo_packet { FRAME * 2 } else { FRAME };
    let mut pcm_out = vec![0.0f32; out_len];
    // A panic here (malformed packet, decoder bug) must not unwind into the
    // event loop and kill the session: drop the packet, evict the possibly
    // corrupt decoder so the next one starts fresh, keep the connection up.
    let decode_res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if stereo_packet {
            let mut decoder = AUDIO_DECODERS_STEREO.entry(from_id)
                .or_insert_with(|| OpusDecoder::new(48000, 2).expect("stereo decoder"));
            decoder.decode(&opus_vec, FRAME, &mut pcm_out)
        } else {
            let mut decoder = AUDIO_DECODERS.entry(from_id)
                .or_insert_with(|| OpusDecoder::new(48000, 1).expect("mono decoder"));
            decoder.decode(&opus_vec, FRAME, &mut pcm_out)
        }
    }));
    let ok = match decode_res {
        Ok(Ok(_)) => true,
        Ok(Err(e)) => {
            eprintln!("opus decode error from client {}: {}", from_id, e);
            false
        }
        Err(panic) => {
            let msg = panic_msg(&panic);
            eprintln!("opus decode panicked for client {}: {}", from_id, msg);
            push_diag(&format!("opus decode panicked (client {}): {}", from_id, msg));
            AUDIO_DECODERS_STEREO.remove(&from_id);
            AUDIO_DECODERS.remove(&from_id);
            false
        }
    };

    if !ok { return; }

    // Convert f32 → i16 (no volume post-gain — volume is applied as mixing weight in callback)
    let mut frame = vec![0i16; out_len];
    for (i, &s) in pcm_out.iter().enumerate() {
        frame[i] = (s.clamp(-1.0, 1.0) * 32767.0).clamp(-32768.0, 32767.0) as i16;
    }

    // Get or create the per-client jitter buffer — DashMap, no STATE lock.
    // A freshly created buffer is published to the audio-callback snapshot
    // immediately: the snapshot is otherwise only refreshed by the 500ms
    // maintenance tick, and a client who starts talking in between would have
    // the start of their burst skipped by the mixer.
    let mut created = false;
    if !CLIENT_BUFFERS.contains_key(&from_id) {
        CLIENT_BUFFERS.insert(from_id, crate::ClientJitterBuffer::new());
        created = true;
    }
    let Some(buf) = CLIENT_BUFFERS.get(&from_id) else {
        return;
    };
    if created {
        inherit_client_settings(&buf, from_id);
        publish_active_client(from_id);
    }
    // Adaptive playout state for this speaker. Held for the rest of the packet
    // so the anchor, the re-anchor and the margin fold share one lookup (this
    // is the same thread that owns the packet; nothing else writes it).
    let stats = JITTER_STATS.entry(from_id).or_default();
    let now = crate::now_ms();
    let period_ms = OUTPUT_PERIOD_MS.load(Ordering::Relaxed) as u64;

    // Init baseline with compare_exchange on the packed base_pair (prevents
    // races when two packets arrive simultaneously).
    let tmp_global = unwrap_seq(seq_u16, 0);
    if buf.base_pair.load(Ordering::Relaxed) == 0 {
        // Lead learned for this client on earlier bursts; TARGET_FRAMES_INIT
        // (the historical fixed 120ms) until anything has been measured.
        let lead = stats.anchor_target(now, period_ms);
        buf.target_frames.store(lead, Ordering::Relaxed);
        let now_slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / crate::FRAME_SIZE;
        let init_pair = ((tmp_global as u64) << 32) | (now_slot + lead as u64);
        if buf.base_pair.compare_exchange(0, init_pair, Ordering::Release, Ordering::Relaxed).is_ok() {
            // Baseline established with this packet.
        }
    }
    // One atomic load: base_seq and base_slot always come from the same mapping.
    let base_pair = buf.base_pair.load(Ordering::Acquire);
    let mut base_seq = (base_pair >> 32) as u32;
    let mut base_slot = base_pair & 0xFFFF_FFFF;
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
        // A forward jump (not a reordered packet, which wraps `forward` to a
        // huge value) = one or more packets never arrived.
        if forward > 1 && forward <= 1000 {
            stats.gap_total.fetch_add(1, Ordering::Relaxed);
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
            // `behind >= REBASE_LEAD` means the mixing clock is already past
            // every frame still in the ring (the reader is further ahead than
            // the frames in flight), so none of them is going to play: this is
            // the one moment where the playout lead can be *shortened* without
            // cutting audio, which is why the adaptive target is applied here
            // and never mid-stream.
            let lead = stats.anchor_target(now, period_ms);
            buf.target_frames.store(lead, Ordering::Relaxed);
            let new_base_seq = global_seq;
            let new_base_slot = current_slot + lead as u64;
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
                "[jbuf] rebase client={} old_base={} new_base={} behind={} lead={} kept={} freed={}",
                from_id, base_seq, new_base_seq, behind, lead, kept, freed
            );
            base_seq = new_base_seq; // local sync after rebase
            base_slot = new_base_slot; // recording tap maps seq → slot below
        }
    }

    // Fold this packet's arrival margin into the adaptive state: the time it
    // waits before the slot it belongs to is mixed. A packet that arrived too
    // late to make its own slot makes `observe_margin` ask for one more frame
    // of lead, which is applied by pushing the whole mapping one slot later —
    // the reader then expects one sequence number earlier than it has already
    // drained, so the mixer inserts a frame of silence and no packet is cut.
    let play_slot = base_slot.wrapping_add(global_seq.wrapping_sub(base_seq) as u64);
    if let Some(play_ms) = play_time_ms(play_slot) {
        if stats.observe_margin(play_ms - now as i64, now) {
            base_slot = base_slot.wrapping_add(1);
            buf.base_pair.store(
                ((base_seq as u64) << 32) | base_slot,
                Ordering::Release,
            );
        }
    }

    // Recording tap: file the raw Opus packet at its playback slot so the
    // per-user tracks stay aligned with the mix clock (see recording.rs).
    recording::push_remote(
        from_id,
        base_slot.wrapping_add(global_seq.wrapping_sub(base_seq) as u64),
        &opus_vec,
    );

    // Write frame to the lock-free jitter buffer
    let slot_idx = (global_seq.wrapping_sub(base_seq)) as usize % crate::JITTER_SLOTS;

    // Evict old frame if overwriting a slot
    if let Some(old) = buf.slots[slot_idx].swap(None) {
        buf.frame_pool.push(old);
    }

    // Get frame buffer from pool or allocate. Pool vecs come in both mono
    // (960) and stereo (1920) lengths — resize to this frame before storing
    // (capacity is reused either way).
    let mut write_frame = buf.frame_pool.pop().unwrap_or_else(|| frame.clone());
    write_frame.clear();
    write_frame.extend_from_slice(&frame);
    buf.slots[slot_idx].swap(Some(write_frame));
    buf.write_seq.store(global_seq, Ordering::Release);
    buf.last_packet.store(Some(Instant::now()));

    // UI "is talking" heartbeat — a lock-free map, not STATE: this runs for
    // every voice packet and must never queue behind Dart's polling calls.
    TALKING_CLIENTS.insert(from_id, Instant::now());
}

/// Inherit the persisted per-UID settings (volume + 2D position survive
/// reconnects) into a freshly created jitter buffer.
fn inherit_client_settings(buf: &crate::ClientJitterBuffer, from_id: u16) {
    let state = STATE.lock();
    let uid = state
        .clients
        .iter()
        .find(|c| c.id as u16 == from_id)
        .and_then(|c| c.uid.as_ref());
    if let Some(db) = uid.and_then(|uid| state.client_volumes.get(uid.as_str()).copied()) {
        let gain = 10.0_f32.powf(db / 20.0);
        buf.volume.store(f32::to_bits(gain), Ordering::Release);
    }
    if let Some(pos) = uid.and_then(|uid| state.client_positions.get(uid.as_str()).copied()) {
        buf.pos_x.store(f32::to_bits(pos.0), Ordering::Release);
        buf.pos_y.store(f32::to_bits(pos.1), Ordering::Release);
    }
}

/// Add one client id to the audio-callback snapshot without waiting for the
/// next maintenance tick. Copy-on-write of a list that holds a handful of
/// entries, and only on the first packet of a speaker — the cost is nothing
/// next to losing the first syllable of their burst.
fn publish_active_client(id: u16) {
    let current = ACTIVE_CLIENT_IDS.load();
    if current.contains(&id) {
        return;
    }
    let mut ids = current.as_ref().clone();
    ids.push(id);
    ACTIVE_CLIENT_IDS.store(Arc::new(ids));
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
// Kind 14 is still reserved in the Dart-side numbering (do not renumber);
// the stream-error paths that used it are now handled by the Closed event.
#[allow(dead_code)]
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

/// Per-client mixing gains from the client's 2D position relative to us
/// (meters; +x = right, +y = forward), multiplied by the user-set linear
/// volume. A NaN position (never set) plays centered at `vol` — identical to
/// the pre-positional behavior. Distance attenuation 1/(1+(d/REF)²) is smooth
/// with no hard cutoff; pan uses an equal-gain center law so the centered
/// loudness matches the unpositioned one and neither side exceeds it (plain
/// stereo cannot place front vs back — the distance carries that).
const POS_ATTEN_REF: f32 = 3.0; // meters: atten is 0.5 at this distance
const POS_PAN_RANGE: f32 = 2.0; // meters: x where the pan reaches fully left/right

fn positional_gains(vol: f32, x: f32, y: f32) -> (f32, f32) {
    if x.is_nan() || y.is_nan() {
        return (vol, vol);
    }
    let d = (x * x + y * y).sqrt();
    let atten = vol / (1.0 + (d / POS_ATTEN_REF).powi(2));
    let pan = (x / POS_PAN_RANGE).clamp(-1.0, 1.0);
    let l = atten * if pan <= 0.0 { 1.0 } else { 1.0 - pan };
    let r = atten * if pan >= 0.0 { 1.0 + pan } else { 1.0 };
    (l, r)
}

/// Fixed-capacity FIFO of generated 48 kHz mix positions, each holding an
/// interleaved [left, right] pair. Decouples the frame-based mixing clock
/// (PLAYED_SAMPLES) from the hardware callback's arbitrary buffer length /
/// sample rate / channel count.
struct OutRing {
    buf: Vec<[f32; 2]>,
    head: usize,
    len: usize,
}

/// ~170ms at 48 kHz (positions) — far above any single callback request.
const OUT_RING_CAP: usize = 8192;

impl OutRing {
    fn new() -> Self {
        Self {
            buf: vec![[0.0, 0.0]; OUT_RING_CAP],
            head: 0,
            len: 0,
        }
    }

    fn push(&mut self, lr: [f32; 2]) {
        if self.len == self.buf.len() {
            // Defensive: drop the oldest position rather than clobber memory.
            // Unreachable with on-demand generation (len peaks ~1 frame + slack).
            self.head = (self.head + 1) % self.buf.len();
            self.len -= 1;
        }
        if self.head + self.len == self.buf.len() {
            self.buf.copy_within(self.head..self.head + self.len, 0);
            self.head = 0;
        }
        self.buf[self.head + self.len] = lr;
        self.len += 1;
    }

    fn pop(&mut self) -> [f32; 2] {
        let lr = self.buf[self.head];
        self.head += 1;
        self.len -= 1;
        if self.len == 0 {
            self.head = 0;
        }
        lr
    }
}

/// Generate one 48 kHz mix position (active clients with positional L/R
/// gains + channel-event SFX) and append the [left, right] pair to the
/// output ring. Runs inside the cpal output callback — no allocation
/// (`mix_l`/`mix_r` are local arrays, the ring is pre-allocated).
///
/// This IS the mixing clock: PLAYED_SAMPLES advances by FRAME_SIZE (per-
/// channel samples — the logical frame number PLAYED_SAMPLES / FRAME_SIZE
/// advances at 50/s regardless of the output channel count; the resampling
/// loop may nudge that rate by up to 1% to drain a backlog). The jitter
/// buffers schedule packets against it (`base_slot` plus the speaker's
/// adaptive playout lead), so generation must be driven strictly on demand as
/// the output pass drains the ring — never ahead of real time.
fn gen_output_mix_frame(ring: &mut OutRing, sfx_slots: &mut [SfxSlot; 2]) {
    let slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / FRAME_SIZE;
    let mut mix_l = [0.0f32; FRAME_SIZE as usize];
    let mut mix_r = [0.0f32; FRAME_SIZE as usize];
    let mut active = 0u32;

    // Phase A: collect one frame from each active client via snapshot.
    // Also track the smallest surplus (frames buffered ahead of the one being
    // mixed, minus the speaker's own playout target) for the clock compression
    // control loop at the end of this function.
    let mut surplus_min = u32::MAX;
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
                // Frames buffered ahead of the one playing now, over and above
                // what this speaker's adaptive lead asks for.
                let target = buf
                    .target_frames
                    .load(Ordering::Relaxed)
                    .clamp(TARGET_FRAMES_FLOOR, TARGET_FRAMES_CEIL) as u64;
                surplus_min = surplus_min.min(
                    (write_seq - expected_seq).saturating_sub(target) as u32,
                );
                let idx = (expected_seq.wrapping_sub(base_seq as u64)) as usize
                    % crate::JITTER_SLOTS;
                if let Some(frame) = buf.slots[idx].swap(None) {
                    let vol = f32::from_bits(buf.volume.load(Ordering::Relaxed));
                    // Positional L/R gains (NaN position = centered).
                    let px = f32::from_bits(buf.pos_x.load(Ordering::Relaxed));
                    let py = f32::from_bits(buf.pos_y.load(Ordering::Relaxed));
                    let (l_gain, r_gain) = positional_gains(vol, px, py);
                    // Frame length tells the channel count: 960 mono
                    // (duplicated into both mix channels) or 1920 stereo
                    // interleaved (L/R kept separate end-to-end).
                    match frame.len() {
                        1920 => {
                            for i in 0..FRAME_SIZE as usize {
                                mix_l[i] += frame[i * 2] as f32 * l_gain;
                                mix_r[i] += frame[i * 2 + 1] as f32 * r_gain;
                            }
                        }
                        _ => {
                            for i in 0..FRAME_SIZE as usize {
                                mix_l[i] += frame[i] as f32 * l_gain;
                                mix_r[i] += frame[i] as f32 * r_gain;
                            }
                        }
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
    for i in 0..FRAME_SIZE as usize {
        mix_l[i] = (mix_l[i] * atten).clamp(-32768.0, 32767.0) / 32768.0;
        mix_r[i] = (mix_r[i] * atten).clamp(-32768.0, 32767.0) / 32768.0;
    }

    // Phase C: channel-event SFX — start queued requests in the two parallel
    // slots and mix them on top of the (already attenuated) voice at fixed
    // 0.5 gain. Samples are mono and play centered on both channels.
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
                    let s = src[sfx.pos + i] * 0.5;
                    mix_l[i] += s;
                    mix_r[i] += s;
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
    for s in &mut mix_l {
        *s = s.clamp(-1.0, 1.0);
    }
    for s in &mut mix_r {
        *s = s.clamp(-1.0, 1.0);
    }

    for i in 0..FRAME_SIZE as usize {
        ring.push([mix_l[i], mix_r[i]]);
    }
    // Publish the slot just generated together with the wall-clock time it was
    // generated at. The receive path turns this into "how long will an
    // arriving packet wait before it plays", which is what the adaptive
    // playout lead is built from.
    publish_clock_ref(slot);
    // Smallest surplus across the speakers mixed above (0 when nobody has
    // audio in flight) — the caller's clock compression is driven by this.
    MIN_SURPLUS_FRAMES.store(
        if surplus_min == u32::MAX { 0 } else { surplus_min },
        Ordering::Relaxed,
    );
    // Recording tap: capture the exact playback mix (positional gains, per-
    // client volumes, SFX). The recorder thread encodes it to Opus.
    recording::push_mix(slot, &mix_l, &mix_r);
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

/// Extra speed applied to the mixing clock, as a fraction (0.0 = none).
///
/// Driven by the smallest surplus across active speakers — compressing only
/// while *everyone* has slack cannot pull anyone below their own playout
/// target. 0.2% per surplus frame, capped at 1%: about 17 cents of pitch,
/// inaudible on speech, and enough to shed a 120ms backlog in ~10s.
fn compression_eps(min_surplus_frames: u32) -> f64 {
    const EPS_PER_FRAME: f64 = 0.002;
    const EPS_MAX: f64 = 0.01;
    (min_surplus_frames.saturating_sub(1) as f64 * EPS_PER_FRAME).min(EPS_MAX)
}

/// Diagnostic snapshot for the 5s stats line:
/// (min/max frames buffered ahead of the mix clock, largest playout target,
/// late arrivals, sequence gaps) over the speakers currently being mixed.
fn jitter_snapshot() -> (u64, u64, u64, u64, u64) {
    let slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / FRAME_SIZE;
    let mut depth_min = u64::MAX;
    let mut depth_max = 0u64;
    let mut target = 0u64;
    for entry in CLIENT_BUFFERS.iter() {
        let buf = entry.value();
        let base_pair = buf.base_pair.load(Ordering::Acquire);
        if base_pair == 0 {
            continue;
        }
        let base_seq = (base_pair >> 32) as u32;
        let base_slot = base_pair & 0xFFFF_FFFF;
        let expected = slot.wrapping_sub(base_slot).wrapping_add(base_seq as u64);
        let write = buf.write_seq.load(Ordering::Acquire) as u64;
        if write < expected {
            continue; // silent speaker, nothing in flight
        }
        depth_min = depth_min.min(write - expected);
        depth_max = depth_max.max(write - expected);
        target = target.max(
            buf.target_frames
                .load(Ordering::Relaxed)
                .clamp(TARGET_FRAMES_FLOOR, TARGET_FRAMES_CEIL) as u64,
        );
    }
    let mut late = 0u64;
    let mut gaps = 0u64;
    for entry in JITTER_STATS.iter() {
        late += entry.value().late_total.load(Ordering::Relaxed);
        gaps += entry.value().gap_total.load(Ordering::Relaxed);
    }
    if depth_min == u64::MAX {
        depth_min = 0;
    }
    (depth_min, depth_max, target, late, gaps)
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

/// Resolves the device to open without consulting the user's stored choice:
/// 1. Linux only: the sound server's PCM ("pipewire"/"pulse") — see
///    [SOUND_SERVER_PCMS],
/// 2. the host's default device.
///
/// Used as the fallback when no choice is made, when the stored choice is no
/// longer enumerable, and when the chosen device fails to open (input falls
/// back in [ts_set_audio_input_device], output in restart_output_stream_inner).
fn pick_device_fallback(host: &cpal::Host, input: bool) -> Option<cpal::Device> {
    #[cfg(target_os = "linux")]
    {
        let devs = enumerate_devices(host, input);
        if let Some(dev) = find_device_by_name(devs, &SOUND_SERVER_PCMS) {
            return Some(dev);
        }
    }
    if input {
        host.default_input_device()
    } else {
        host.default_output_device()
    }
}

/// Resolves the device to open, in priority order:
/// 1. the user's explicit choice (exact name match),
/// 2. [pick_device_fallback] (sound-server PCM, then host default).
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
        if input {
            // A successful start clears this again; if the fallback also
            // fails, its own error overwrites this one.
            record_mic_error(format!(
                "chosen input device \"{}\" not available, using default",
                want
            ));
        }
    }
    pick_device_fallback(host, input)
}

/// Rebuilds the cpal output stream on the selected device (see pick_device).
/// The internal mixing clock stays 48 kHz stereo at all times; the
/// device-facing stream is negotiated through a fallback chain (48k stereo
/// Fixed(960) → 48k stereo Default → 48k mono → device default sample rate
/// with in-callback linear resampling), so desktop hosts that reject the
/// fixed Android-style config still work. Stereo is preferred because
/// panning/positional audio needs distinct L/R.
///
/// Resets playback state exactly like `ts_stop_audio` — buffers are cleared
/// and jitter/decoders are rebuilt on the next incoming audio. Called on
/// connect and, from the maintenance task, when `OUTPUT_RESTART_REQUESTED`
/// is set (device route change or stream error).
///
/// The rebuild runs inside `catch_unwind`: cpal's Android backend touches
/// JNI-dependent paths (device probing, buffer-size queries), and a panic
/// here must degrade to "no audio" instead of killing the enclosing task —
/// on the connect path that task also owns the event loop, so its death
/// would leave the UI without the channel tree. The panic hook still records
/// the message (flushed to Dart as a Diag event).
fn restart_output_stream() {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        restart_output_stream_inner();
    }));
    if result.is_err() {
        eprintln!("cpal: output stream rebuild panicked; audio stays off until the next restart");
    }
}

fn restart_output_stream_inner() {
    // Drop the old stream first so the new one is the only active consumer.
    AUDIO_STREAM.lock().unwrap().0 = None;
    crate::clear_sfx_queue();
    CLIENT_BUFFERS.clear();
    AUDIO_DECODERS.clear();
    AUDIO_DECODERS_STEREO.clear();
    PLAYED_SAMPLES.store(0, Ordering::Relaxed);
    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
    CB_STATS.expected_next_played.store(0, Ordering::Relaxed);
    // Nothing may be scheduled against the old stream's clock, and every
    // speaker is anchored anew below — so the learned profiles stay valid, but
    // the callbacks must not measure a margin across the restart.
    CLOCK_REF.store(0, Ordering::Relaxed);
    MIN_SURPLUS_FRAMES.store(0, Ordering::Relaxed);

    let host = cpal::default_host();
    // Try the user's chosen device first; if it can't be opened or
    // configured (e.g. an ALSA hw PCM the sound server currently holds),
    // retry once on the system-default route so playback survives — mirrors
    // the input side's fallback in ts_set_audio_input_device. The stored
    // choice itself is kept for future reconnects.
    match pick_device(&host, false) {
        Some(device) => {
            eprintln!("cpal: output device \"{}\"", device.name().unwrap_or_default());
            if try_start_output(device) {
                return;
            }
        }
        None => eprintln!("cpal: no output device"),
    }
    if OUTPUT_DEVICE_NAME.lock().unwrap().is_some() {
        eprintln!("audio: chosen output device failed, trying the system default");
        if let Some(device) = pick_device_fallback(&host, false) {
            try_start_output(device);
        }
    }
}

/// Builds and starts the output stream on `device` through the config
/// fallback chain. Stores the stream in AUDIO_STREAM and the device rate in
/// OUTPUT_RATE on success; returns false when every configuration failed.
fn try_start_output(device: cpal::Device) -> bool {
    // Stereo is preferred — panning/positional audio needs distinct L/R;
    // mono output plays the centered (L+R)/2 downmix. The fallback chain
    // negotiates buffer size, channel count and finally the device's own
    // sample rate (with in-callback linear resampling), so desktop hosts
    // that reject the fixed Android-style config still work.
    let mut candidates = vec![
        cpal::StreamConfig {
            channels: 2,
            sample_rate: cpal::SampleRate(48000),
            buffer_size: cpal::BufferSize::Fixed(960),
        },
        cpal::StreamConfig {
            channels: 2,
            sample_rate: cpal::SampleRate(48000),
            buffer_size: cpal::BufferSize::Default,
        },
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
        // 48k mix positions consumed per device output position (interpolation
        // phase advance); 1.0 = passthrough.
        let ratio = 48000.0 / config.sample_rate.0 as f64;
        let stream = device.build_output_stream(
            &config,
            {
                let ring = std::cell::RefCell::new(OutRing::new());
                let sfx_slots = std::cell::RefCell::new([SfxSlot::default(); 2]);
                // Linear-resampler state carried across callbacks: frac is the
                // position between s0 (last consumed 48k mix position) and s1
                // (the next ring position). s1 = None until the first callback.
                let rs_frac = std::cell::Cell::new(0.0f64);
                let rs_s0 = std::cell::Cell::new([0.0f32, 0.0f32]);
                let rs_s1: std::cell::Cell<Option<[f32; 2]>> = std::cell::Cell::new(None);
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    // Callback interval: the rate the mixing clock actually
                    // advances at, i.e. the granularity a frame has to be
                    // buffered ahead by (published as OUTPUT_PERIOD_MS).
                    let entry_ns = crate::now_ns();
                    let prev_ns = CB_STATS
                        .last_cb_entry_ns
                        .swap(entry_ns, Ordering::Relaxed);
                    if prev_ns != 0 && entry_ns > prev_ns {
                        CB_STATS
                            .last_interval_us
                            .store((entry_ns - prev_ns) / 1_000, Ordering::Relaxed);
                    }

                    let mut ring = ring.borrow_mut();
                    let mut sfx = sfx_slots.borrow_mut();

                    let n_out = data.len() / channels;
                    // Clock compression: while every active speaker has audio
                    // buffered beyond what their own playout target needs, the
                    // mix clock is advanced slightly faster than the device
                    // clock (≤1%) until that surplus is gone. This is what
                    // stops a slow sender/device clock mismatch from becoming
                    // ever-growing delay, and it is the only lever that can
                    // shorten a stream mid-audio: a shrink at an anchor cannot
                    // cut audio, a mid-stream one would.
                    let step = ratio
                        * (1.0 + compression_eps(MIN_SURPLUS_FRAMES.load(Ordering::Relaxed)));
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
                        let s1v = s1.unwrap_or([0.0, 0.0]);
                        let l = s0[0] + (s1v[0] - s0[0]) * frac as f32;
                        let r = s0[1] + (s1v[1] - s0[1]) * frac as f32;
                        let base = j * channels;
                        if channels == 2 {
                            data[base] = l;
                            data[base + 1] = r;
                        } else {
                            data[base] = (l + r) * 0.5;
                        }
                        frac += step;
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
                    // PLAYED_SAMPLES counts PER-CHANNEL samples (see the
                    // gen_output_mix_frame doc).
                    CB_STATS
                        .samples_total
                        .fetch_add((data.len() / channels) as u64, Ordering::Relaxed);
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
                    OUTPUT_RATE.store(config.sample_rate.0, Ordering::Relaxed);
                    eprintln!(
                        "cpal: output stream started ({} Hz, {} ch, mix resample ratio {:.4}, requested buffer {:?})",
                        config.sample_rate.0, config.channels, ratio, config.buffer_size
                    );
                    return true;
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
    false
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

                    // "Is talking" heartbeats: this used to run once per event
                    // loop iteration (i.e. per voice packet), where the map scan
                    // sat directly in the audio receive path. The consumers all
                    // filter on a 500ms window anyway, so a coarse sweep is
                    // enough.
                    TALKING_CLIENTS.retain(|_, t| t.elapsed().as_millis() < 10_000);

                    // Drop learned network profiles for clients that are gone
                    // from the roster, so a recycled client id cannot inherit
                    // another speaker's jitter history.
                    let roster: HashSet<u16> = STATE
                        .lock()
                        .clients
                        .iter()
                        .map(|c| c.id as u16)
                        .collect();
                    if !roster.is_empty() {
                        JITTER_STATS.retain(|id, _| roster.contains(id));
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

                    // Same for the capture stream: rebuild it after an input
                    // error killed it (device replug, WASAPI glitch). A
                    // user-driven stop clears the flag in stop_mic_capture,
                    // so only genuinely dead streams restart here.
                    if MIC_RESTART_REQUESTED.swap(false, Ordering::Relaxed)
                        && crate::MIC_STREAM.lock().unwrap().0.is_none()
                    {
                        eprintln!("[cpal] restarting mic capture stream (stream error)");
                        start_mic_capture();
                    }
                }
                _ = stats_tick.tick() => {
                    let cbs = CB_STATS.callbacks.swap(0, Ordering::Relaxed);
                    let samps = CB_STATS.samples_total.swap(0, Ordering::Relaxed);
                    let mixes = CB_STATS.mix_frames.swap(0, Ordering::Relaxed);
                    let mism = CB_STATS.played_mismatches.swap(0, Ordering::Relaxed);
                    // A gauge, not a counter: swapping would report 0 for any
                    // window in which the stream stopped again.
                    let intv_us = CB_STATS.last_interval_us.load(Ordering::Relaxed);
                    // Device period: samples handed to the driver per callback.
                    // It is the mixing clock's granularity and the floor under
                    // any playout slack — a host that grants a much larger
                    // period than the requested 960 frames is worth seeing.
                    if cbs > 0 && samps > 0 {
                        let rate = OUTPUT_RATE.load(Ordering::Relaxed).max(1) as u64;
                        let period_ms = ((samps / cbs).saturating_mul(1000) / rate).max(1);
                        OUTPUT_PERIOD_MS.store(period_ms as u32, Ordering::Relaxed);
                    }
                    if cbs > 0 {
                        let (d_min, d_max, target, late, gaps) = jitter_snapshot();
                        eprintln!(
                            "[cpal-stats] callbacks={} samples={} mix_frames={} interval_us={} mismatches={} period_ms={} depth_ms={}..{} target_ms={} late={} gaps={}",
                            cbs, samps, mixes, intv_us, mism,
                            OUTPUT_PERIOD_MS.load(Ordering::Relaxed),
                            d_min * crate::FRAME_MS, d_max * crate::FRAME_MS,
                            target * crate::FRAME_MS, late, gaps
                        );
                    }
                    // Uplink VAD/AGC state next to the playback stats, same
                    // 5 s cadence — one glance shows why the gate is (not)
                    // transmitting.
                    let vs = MIC_PIPELINE.lock().status.clone();
                    eprintln!(
                        "[vad] mode={:?} speaking={} level={:.1} noise={:.1} open={:.1} prob={:.2} agc={:+.1} clipped={} enabled={}",
                        vs.mode, vs.speaking, vs.level_db, vs.noise_db, vs.open_db,
                        vs.prob, vs.agc_gain_db, vs.clipped, vs.enabled
                    );
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
    recording::on_disconnect();
    AUDIO_STREAM.lock().unwrap().0 = None;
    crate::clear_sfx_queue();
    CLIENT_BUFFERS.clear();
    AUDIO_DECODERS.clear();
    AUDIO_DECODERS_STEREO.clear();
    PLAYED_SAMPLES.store(0, Ordering::Relaxed);
    ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
    // The clock reference and the learned playout profiles belong to the
    // connection that just ended — client ids are only unique within it.
    CLOCK_REF.store(0, Ordering::Relaxed);
    JITTER_STATS.clear();
    TALKING_CLIENTS.clear();
    MIN_SURPLUS_FRAMES.store(0, Ordering::Relaxed);
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

// ─── Univox event handling ──────────────────────────────────────────

/// Deduplication across the univox event stream. One channel transition
/// surfaces as up to three events (clientmoved + leftview + enterview can
/// describe the same move), so per-client timestamps keep sounds and chat
/// notices to one per movement within a short window. Sounds and notices
/// use separate maps on purpose — a notice must never suppress a sound or
/// vice versa.
struct RecentClients {
    sfx: HashMap<u64, Instant>,
    chat: HashMap<u64, Instant>,
}

impl RecentClients {
    fn new() -> Self {
        Self {
            sfx: HashMap::new(),
            chat: HashMap::new(),
        }
    }

    fn seen(map: &mut HashMap<u64, Instant>, id: u64) -> bool {
        let now = Instant::now();
        map.retain(|_, t| now.duration_since(*t) < Duration::from_secs(2));
        map.insert(id, now).is_some()
    }

    /// True when this client already produced a movement sound in the window.
    fn sfx_dedupe(&mut self, id: u64) -> bool {
        Self::seen(&mut self.sfx, id)
    }

    /// True when this client already produced a chat notice in the window.
    fn chat_dedupe(&mut self, id: u64) -> bool {
        Self::seen(&mut self.chat, id)
    }

    /// Non-registering check (e.g. to suppress the auto channel-group sound
    /// right after our own channel move).
    fn sfx_is_recent(&self, id: u64) -> bool {
        self.sfx
            .get(&id)
            .is_some_and(|t| t.elapsed() < Duration::from_secs(2))
    }
}

/// `client_leave_channel.kind` codes from a structured leave reason:
/// 0 = left on their own, 1 = moved away by someone, 2 = kicked from the
/// channel, 3 = disconnected / left the server, 4 = kicked from the server,
/// 5 = banned. `None` = not a real leave (subscription reshuffles, server
/// shutdown ...).
fn leave_kind(reason: &MemberLeftReason) -> Option<u8> {
    match reason {
        MemberLeftReason::Moved { .. } => Some(1),
        MemberLeftReason::ChannelKicked { .. } => Some(2),
        MemberLeftReason::Left | MemberLeftReason::Timeout | MemberLeftReason::Quit => Some(3),
        MemberLeftReason::ServerKicked { .. } => Some(4),
        MemberLeftReason::Banned { .. } => Some(5),
        MemberLeftReason::Unsubscribed | MemberLeftReason::ServerStop
        | MemberLeftReason::Other(_) => None,
    }
}

/// Channel-event sound for a real leave from our channel.
fn leave_sfx(reason: &MemberLeftReason) -> Option<u8> {
    match reason {
        MemberLeftReason::Timeout => Some(SFX_NEUTRAL_CONN_LOST),
        MemberLeftReason::Left | MemberLeftReason::Quit => {
            Some(SFX_NEUTRAL_CONN_DISCONNECTED)
        }
        MemberLeftReason::ChannelKicked { .. } => Some(SFX_NEUTRAL_KICKED_CH_AWAY),
        MemberLeftReason::ServerKicked { .. } => Some(SFX_NEUTRAL_KICKED_SERVER),
        MemberLeftReason::Banned { .. } => Some(SFX_NEUTRAL_BANNED_SERVER),
        MemberLeftReason::Moved { .. } => Some(SFX_NEUTRAL_MOVED_AWAY),
        _ => None,
    }
}

/// `client_enter_channel.reason` for an enterview row: 0 = connected to the
/// server, 2 = moved in by someone, 3 = kicked into the channel. The wire
/// `reasonid` rides in the member's extra map. `None` = not chat-worthy
/// (subscription resync and friends).
fn enter_view_reason(member: &univox_core::model::Member) -> Option<u8> {
    match member.extra.get("reasonid").map(|s| s.as_str()) {
        Some("0") => Some(0),
        Some("1") => Some(2), // Moved
        Some("4") => Some(3), // KickChannel
        _ => None,
    }
}

/// The invoker's nickname for the leave kinds that have one ('' otherwise),
/// resolved from the book — the kicker usually stays in view.
fn invoker_name(book: &univox_core::Book, reason: &MemberLeftReason) -> String {
    let by = match reason {
        MemberLeftReason::Moved { by }
        | MemberLeftReason::ChannelKicked { by, .. }
        | MemberLeftReason::ServerKicked { by, .. }
        | MemberLeftReason::Banned { by, .. } => by,
        _ => return String::new(),
    };
    book.member(by.as_ref().unwrap_or(&MemberId::from_u64(0)))
        .map(|m| m.nickname)
        .unwrap_or_default()
}

/// Invoker name for SelfMoved/leave notices by raw id; only the moved/kicked
/// kinds carry one.
fn invoker_name_by_id(
    book: &univox_core::Book,
    invoker_id: Option<u64>,
    kind: u8,
) -> String {
    match kind {
        1 | 2 | 4 | 5 => invoker_id
            .map(MemberId::from_u64)
            .and_then(|id| book.member(&id))
            .map(|m| m.nickname)
            .unwrap_or_default(),
        _ => String::new(),
    }
}

fn book_channel_name(book: &univox_core::Book, id: u64) -> String {
    book.channel(&ChannelId::from_u64(id))
        .map(|c| c.name)
        .unwrap_or_default()
}

/// True when a client other than `exclude` sits in `channel` and is
/// recording (official CLIENT_RECORDING_IN_CHANNEL hint).
fn channel_has_recorder(book: &univox_core::Book, channel: u64, exclude: u64) -> bool {
    book.with(|b| {
        b.members.values().any(|m| {
            m.id.as_u64() != Some(exclude)
                && m.channel_id.as_ref().and_then(|c| c.as_u64()) == Some(channel)
                && b.member_states.get(&m.id).map(|s| s.recording).unwrap_or(false)
        })
    })
    .unwrap_or(false)
}

fn disconnect_reason_text(reason: &DisconnectReason) -> String {
    match reason {
        DisconnectReason::Requested { message } => {
            message.clone().unwrap_or_else(|| "User disconnected".into())
        }
        DisconnectReason::Timeout => "Connection timeout".into(),
        DisconnectReason::ServerStop => "Server stopped".into(),
        DisconnectReason::Kicked { message, .. } => {
            message.clone().unwrap_or_else(|| "Kicked from server".into())
        }
        DisconnectReason::Banned { message, .. } => {
            message.clone().unwrap_or_else(|| "Banned from server".into())
        }
        DisconnectReason::ServerDeleted => "Server deleted".into(),
        DisconnectReason::Network(m) | DisconnectReason::Auth(m) | DisconnectReason::Other(m) => {
            m.clone()
        }
    }
}

/// TS3 wire error id of a unified platform error (None for local errors).
fn ts3_error_code(e: &univox_core::error::Error) -> Option<i32> {
    match e {
        univox_core::error::Error::Platform { code, .. } => Some(*code),
        _ => None,
    }
}

/// 0x030d — the clientmove rejection for a wrong channel password.
const TS3_ERR_CHANNEL_INVALID_PASSWORD: i32 = 0x030d;

/// Human-readable text for a failed session call (PermOp / SendFailed).
fn error_text(e: &univox_core::error::Error) -> String {
    match e {
        univox_core::error::Error::Permission { missing } => {
            format!("missing permission {missing}")
        }
        univox_core::error::Error::Platform { code, message, .. } => {
            format!("{message} (0x{code:04x})")
        }
        other => format!("{other}"),
    }
}

/// Publishes a PermOp answer for a tracked management command.
fn push_perm_op(token: &str, ok: bool, error: Option<String>) {
    push_diag(&format!(
        "perm op {}: ok={} {}",
        token,
        ok,
        error.as_deref().unwrap_or("")
    ));
    STATE.lock().pending_events.push_back(TsEvent::PermOp {
        token: token.to_string(),
        ok,
        error,
    });
}

/// Rebuilds STATE's roster from the book mirror and tells Dart. One event =
/// one refresh; Dart's 200 ms poll coalesces the churn.
fn refresh_roster(book: &univox_core::Book) {
    let (ch, cl) = refresh_from_book(book);
    let mut state = STATE.lock();
    state.channels = ch;
    state.clients = cl;
    state.pending_events.push_back(TsEvent::ChannelsUpdated {});
}

/// Voice packets from univox's raw sink: S2C (+ whisper, decoded like
/// normal voice) are decoded per speaker; C2S echoes are ignored.
fn on_voice_data(vd: VoiceData) {
    match vd {
        VoiceData::S2C { id, from, data, .. } | VoiceData::S2CWhisper { id, from, data, .. } => {
            contain_panic("voice decode", || {
                decode_to_client_buffer(from, id, data)
            });
        }
        _ => {}
    }
}

/// Central per-event handler: refreshes the roster from the book mirror,
/// pushes the Dart-facing events (chat / poke / notices) and classifies the
/// channel-event sounds. Returns true when the voice-sink subscription must
/// be renewed (the supervisor swapped the connection on a reconnect).
async fn handle_univox_event(
    ev: UxEvent,
    session: &Arc<Ts3Session>,
    recent: &mut RecentClients,
    generation: u64,
) -> bool {
    if !STATE.lock().connected {
        return false;
    }
    let own_client = self_clid(session);
    let own_channel = {
        let state = STATE.lock();
        state
            .clients
            .iter()
            .find(|c| c.id as u64 == own_client)
            .map(|c| c.channel_id as u64)
    };
    let book = session.book();
    let armed = SFX_ARMED.load(Ordering::Relaxed);

    match ev {
        // A poke is a dedicated message target (notifyclientpoke) and must
        // NOT show up in the chat — it gets its own event (Dart shows a
        // system notification). Everything else is a text message routed by
        // target mode; our own echoes skip the inbound sound.
        UxEvent::MessageCreated { message } => {
            let author = message.author.as_ref().and_then(|a| a.as_u64()).unwrap_or(0);
            let name = message.author_name.clone();
            let inbound = armed && author != own_client;
            match message.target {
                Some(MessageTarget::Poke(_)) => {
                    STATE.lock().pending_events.push_back(TsEvent::Poke {
                        from_client: name.clone(),
                        from_client_id: author as u32,
                        message: message.content.clone(),
                    });
                    if armed {
                        push_sfx(SFX_YOU_WERE_POKED, &name);
                    }
                }
                Some(MessageTarget::Server) => {
                    STATE
                        .lock()
                        .pending_events
                        .push_back(TsEvent::TextMessage {
                            from_client: name.clone(),
                            from_client_id: author as u32,
                            to_client_id: 0,
                            target_mode: 3u8,
                            message: message.content.clone(),
                        });
                    if inbound {
                        push_sfx(SFX_CHAT_INBOUND, &name);
                    }
                }
                Some(MessageTarget::Direct(tid)) => {
                    STATE
                        .lock()
                        .pending_events
                        .push_back(TsEvent::TextMessage {
                            from_client: name.clone(),
                            from_client_id: author as u32,
                            // The echo of our own sent PM carries the OTHER
                            // party here — that is what lets Dart file the
                            // message under the right conversation.
                            to_client_id: tid.as_u64().unwrap_or(0) as u32,
                            target_mode: 1u8,
                            message: message.content.clone(),
                        });
                    if inbound {
                        push_sfx(SFX_CHAT_INBOUND, &name);
                    }
                }
                Some(MessageTarget::Channel(_)) => {
                    STATE
                        .lock()
                        .pending_events
                        .push_back(TsEvent::TextMessage {
                            from_client: name.clone(),
                            from_client_id: author as u32,
                            to_client_id: 0,
                            target_mode: 2u8,
                            message: message.content.clone(),
                        });
                    if inbound {
                        push_sfx(SFX_CHAT_INBOUND, &name);
                    }
                }
                _ => {}
            }
        }
        // Someone entered the view. Initial dumps are silent (they never
        // produce events); our own entry is covered by the connected event.
        UxEvent::MemberJoined { member } => {
            let mid = member.id.as_u64().unwrap_or(0);
            let entered_own =
                member.channel_id.as_ref().and_then(|c| c.as_u64()) == own_channel;
            let reason = enter_view_reason(&member);
            refresh_roster(&book);
            if mid == own_client || !armed {
                return false;
            }
            if entered_own {
                if let Some(r) = reason {
                    if !recent.sfx_dedupe(mid) {
                        match r {
                            0 => push_sfx(SFX_NEUTRAL_CONN_CONNECTED, &member.nickname),
                            2 => push_sfx(SFX_NEUTRAL_MOVED_TO_CURRENT, &member.nickname),
                            3 => push_sfx(SFX_NEUTRAL_KICKED_CH_TO_CURRENT, &member.nickname),
                            _ => {}
                        }
                    }
                    if !recent.chat_dedupe(mid) {
                        STATE
                            .lock()
                            .pending_events
                            .push_back(TsEvent::ClientEnterChannel {
                                client_id: mid as u32,
                                nickname: member.nickname.clone(),
                                reason: r,
                            });
                    }
                }
            }
        }
        UxEvent::MemberLeft { id, reason } => {
            let mid = id.as_u64().unwrap_or(0);
            // The book already dropped the member; the previous roster holds
            // the nickname and their channel.
            let (nickname, was_channel) = {
                let state = STATE.lock();
                match state.clients.iter().find(|c| c.id as u64 == mid) {
                    Some(c) => (c.nickname.clone(), Some(c.channel_id as u64)),
                    None => (String::new(), None),
                }
            };
            if mid == own_client {
                // Our own removal: only kicks and bans produce a sound — the
                // server closes the connection right after, and the
                // "disconnected" sound must not stack on top.
                match &reason {
                    MemberLeftReason::ChannelKicked { .. } => {
                        // The same kick can also arrive as ClientMoved —
                        // the window dedupes the double report.
                        if !recent.sfx_dedupe(mid) {
                            push_sfx(SFX_YOU_KICKED_CHANNEL, &nickname);
                        }
                    }
                    MemberLeftReason::ServerKicked { .. } => {
                        SFX_SUPPRESS_DISCONNECT.store(true, Ordering::Relaxed);
                        push_sfx(SFX_YOU_KICKED_SERVER, &nickname);
                    }
                    MemberLeftReason::Banned { .. } => {
                        SFX_SUPPRESS_DISCONNECT.store(true, Ordering::Relaxed);
                        push_sfx(SFX_YOU_WERE_BANNED, &nickname);
                    }
                    _ => {}
                }
            } else if was_channel == own_channel && armed {
                if let Some(kind) = leave_kind(&reason) {
                    if !recent.chat_dedupe(mid) {
                        let invoker = invoker_name(&book, &reason);
                        STATE
                            .lock()
                            .pending_events
                            .push_back(TsEvent::ClientLeaveChannel {
                                client_id: mid as u32,
                                nickname: nickname.clone(),
                                kind,
                                invoker,
                            });
                    }
                }
                if let Some(sound) = leave_sfx(&reason) {
                    if !recent.sfx_dedupe(mid) {
                        push_sfx(sound, &nickname);
                    }
                }
            }
            refresh_roster(&book);
        }
        // Incremental client updates (mute/away/recording/talk-power
        // echoes). The row carries only the changed fields.
        UxEvent::MemberUpdated { member } => {
            let mid = member.id.as_u64().unwrap_or(0);
            let in_own =
                member.channel_id.as_ref().and_then(|c| c.as_u64()) == own_channel;
            refresh_roster(&book);
            if !armed {
                return false;
            }
            if mid == own_client {
                if let Some(v) = member.extra.get("client_input_muted") {
                    push_sfx(
                        if v == "1" { SFX_MIC_MUTED } else { SFX_MIC_ACTIVATED },
                        "input muted",
                    );
                }
                if let Some(v) = member.extra.get("client_output_muted") {
                    push_sfx(
                        if v == "1" { SFX_SOUND_MUTED } else { SFX_SOUND_RESUMED },
                        "output muted",
                    );
                }
                if member.extra.contains_key("client_away_message")
                    || member.extra.contains_key("client_away")
                {
                    let away = member
                        .extra
                        .get("client_away")
                        .map(|v| v == "1")
                        .unwrap_or_else(|| {
                            member
                                .extra
                                .get("client_away_message")
                                .map(|v| !v.is_empty())
                                .unwrap_or(false)
                        });
                    push_sfx(
                        if away { SFX_AWAY_ACTIVATED } else { SFX_AWAY_DEACTIVATED },
                        "away",
                    );
                }
                // Joining a channel auto-assigns its default channel group;
                // the server broadcasts that as an update right after our
                // own move — not a real group change, so require that no
                // recent movement of ours is in flight.
                if member.extra.contains_key("client_channel_group_id")
                    && !recent.sfx_is_recent(own_client)
                {
                    push_sfx(SFX_CHANNELGROUP_CHANGED, "channel group");
                }
            } else if in_own {
                if let Some(v) = member.extra.get("client_is_recording") {
                    // Incremental row: the key's presence implies a change.
                    if !recent.sfx_dedupe(mid) {
                        push_sfx(
                            if v == "1" {
                                SFX_NEUTRAL_RECORDING_STARTED
                            } else {
                                SFX_NEUTRAL_RECORDING_STOPPED
                            },
                            &member.nickname,
                        );
                    }
                }
            }
        }
        UxEvent::ClientMoved { member, channel, invoker, reason } => {
            let mid = member.as_u64().unwrap_or(0);
            let to_channel = channel.as_u64().unwrap_or(0);
            let invoker_id = invoker.as_ref().and_then(|i| i.as_u64());
            let kicked = matches!(reason, ClientMoveReason::ChannelKicked { .. });
            let third_party = matches!(invoker_id, Some(inv) if inv != mid && inv != 0);
            let (from_channel, nickname) = {
                let state = STATE.lock();
                match state.clients.iter().find(|c| c.id as u64 == mid) {
                    Some(c) => (Some(c.channel_id as u64), c.nickname.clone()),
                    None => (None, String::new()),
                }
            };
            refresh_roster(&book);
            if mid == own_client {
                // Self move: voluntary, forced by an admin, or a channel
                // kick — live captures show reasonid 4 arriving on this very
                // notification (reasonmsg + invoker attached).
                let kind = if kicked {
                    2
                } else if third_party {
                    1
                } else {
                    0
                };
                let inv = invoker_name_by_id(&book, invoker_id, kind);
                STATE
                    .lock()
                    .pending_events
                    .push_back(TsEvent::SelfMoved {
                        to_channel_id: to_channel as u32,
                        to_channel_name: book_channel_name(&book, to_channel),
                        invoker: inv,
                        kind,
                    });
                if armed {
                    if kicked {
                        // A server may deliver the same kick as a leftview
                        // too — MemberLeft plays the sound there, the
                        // window dedupes the double report.
                        if !recent.sfx_dedupe(mid) {
                            push_sfx(SFX_YOU_KICKED_CHANNEL, "");
                        }
                    } else {
                        push_sfx(
                            if third_party { SFX_YOU_WERE_MOVED } else { SFX_CHANNEL_SWITCHED },
                            "",
                        );
                    }
                    // Official CLIENT_RECORDING_IN_CHANNEL: entering a
                    // channel that already has a recorder.
                    if channel_has_recorder(&book, to_channel, own_client) {
                        push_sfx(SFX_NEUTRAL_RECORDING_ACTIVE, "recorder in channel");
                    }
                }
            } else if armed {
                let was_own = from_channel == own_channel;
                let now_own = Some(to_channel) == own_channel;
                if was_own && !now_own {
                    // Left our channel: moved by an admin, on their own, or
                    // kicked out of it (a kick can also surface as leftview
                    // → MemberLeft; the dedupe windows swallow the double
                    // report).
                    let sound = if kicked {
                        SFX_NEUTRAL_KICKED_CH_AWAY
                    } else if third_party {
                        SFX_NEUTRAL_MOVED_AWAY
                    } else {
                        SFX_NEUTRAL_AWAY_FROM_CURRENT
                    };
                    if !recent.sfx_dedupe(mid) {
                        push_sfx(sound, &nickname);
                    }
                    let kind = if kicked {
                        2
                    } else if third_party {
                        1
                    } else {
                        0
                    };
                    if !recent.chat_dedupe(mid) {
                        let inv = invoker_name_by_id(&book, invoker_id, kind);
                        STATE
                            .lock()
                            .pending_events
                            .push_back(TsEvent::ClientLeaveChannel {
                                client_id: mid as u32,
                                nickname: nickname.clone(),
                                kind,
                                invoker: inv,
                            });
                    }
                } else if !was_own && now_own {
                    // 1 = joined on their own, 2 = moved in, 3 = kicked in.
                    let reason = if kicked {
                        3
                    } else if third_party {
                        2
                    } else {
                        1
                    };
                    if !recent.chat_dedupe(mid) {
                        STATE
                            .lock()
                            .pending_events
                            .push_back(TsEvent::ClientEnterChannel {
                                client_id: mid as u32,
                                nickname: nickname.clone(),
                                reason,
                            });
                    }
                    if !recent.sfx_dedupe(mid) {
                        push_sfx(
                            if kicked {
                                SFX_NEUTRAL_KICKED_CH_TO_CURRENT
                            } else if third_party {
                                SFX_NEUTRAL_MOVED_TO_CURRENT
                            } else {
                                SFX_NEUTRAL_TO_CURRENT
                            },
                            &nickname,
                        );
                    }
                }
            }
        }
        UxEvent::ChannelCreated { .. } => {
            // Only live creations land here — the initial channellist and
            // the subscribe-all replay never emit events.
            if armed {
                push_sfx(SFX_CHANNEL_CREATED, "");
            }
            refresh_roster(&book);
        }
        UxEvent::ChannelUpdated { .. } => {
            if armed {
                push_sfx(SFX_CHANNEL_EDITED, "");
            }
            refresh_roster(&book);
        }
        UxEvent::ChannelMoved { id, parent, .. } => {
            // Order-only moves are silent (previous behavior).
            let cid = id.as_u64().unwrap_or(0);
            let new_parent = parent.as_ref().and_then(|p| p.as_u64()).unwrap_or(0);
            let prev_parent = {
                let state = STATE.lock();
                state
                    .channels
                    .iter()
                    .find(|c| c.id as u64 == cid)
                    .map(|c| c.parent_id as u64)
            };
            if armed && prev_parent != Some(new_parent) {
                push_sfx(SFX_CHANNEL_MOVED, "");
            }
            refresh_roster(&book);
        }
        UxEvent::ChannelDeleted { .. } => {
            if armed {
                push_sfx(SFX_CHANNEL_DELETED, "");
            }
            refresh_roster(&book);
        }
        UxEvent::ServerUpdated { .. } => {
            refresh_roster(&book);
        }
        UxEvent::TemporarilyDisconnected { reason } => {
            // On reconnect the supervisor re-primes the whole roster as
            // fresh events; disarm so the resync stays silent.
            SFX_ARMED.store(false, Ordering::Relaxed);
            // The output stream stays up during a temporary disconnect (the
            // supervisor reconnects on its own), so the connection_lost
            // sound plays through it normally.
            push_sfx(SFX_CONNECTION_LOST, "temp disconnect");
            STATE.lock().pending_events.push_back(TsEvent::Error {
                message: format!("Temp disconnected: {}", disconnect_reason_text(&reason)),
            });
        }
        UxEvent::Reconnected => {
            // The supervisor re-primed the book already; refresh, track the
            // possibly-new client id and re-arm after the burst.
            let own = self_clid(session) as u32;
            STATE.lock().own_client_id = own;
            refresh_roster(&book);
            // The supervisor replays its last `update_self` record, but that
            // record is replaced wholesale on every call — SetMuted followed
            // by SetAway leaves only the away fields in it. Re-apply the full
            // triple from our own tracking (no-op when everything is off).
            let (input, output, away) = {
                let s = STATE.lock();
                (s.self_input_muted, s.self_output_muted, s.self_away)
            };
            if input || output || away {
                let session = session.clone();
                RUNTIME.spawn(async move {
                    let _ = session
                        .update_self(SelfUpdate {
                            input_muted: Some(input),
                            output_muted: Some(output),
                            away: Some(away),
                            away_message: if away { Some("Away".into()) } else { None },
                            ..Default::default()
                        })
                        .await;
                });
            }
            RUNTIME.spawn(async move {
                tokio::time::sleep(Duration::from_secs(2)).await;
                if STATE.lock().connected {
                    SFX_ARMED.store(true, Ordering::Relaxed);
                    push_diag("sfx armed after reconnect settle");
                }
            });
            return true; // renew the voice-sink subscription (new connection)
        }
        UxEvent::Closed { reason } => {
            let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
            let user_initiated =
                matches!(reason, DisconnectReason::Requested { .. });
            if current_gen == generation && STATE.lock().connected {
                {
                    let mut s = STATE.lock();
                    s.connected = false;
                    s.pending_events.push_back(TsEvent::Disconnected {
                        reason: disconnect_reason_text(&reason),
                    });
                }
                if SFX_SUPPRESS_DISCONNECT.load(Ordering::Relaxed) {
                    // Kicked/banned: the kick/ban sound just played — keep
                    // the stream alive until it finished; no extra sound.
                    SFX_SUPPRESS_DISCONNECT.store(false, Ordering::Relaxed);
                    schedule_teardown_after_kick_sfx();
                } else if !user_initiated {
                    // Passive disconnect → connection_lost (disconnected is
                    // reserved for explicit user exit).
                    schedule_sfx_teardown(SFX_CONNECTION_LOST);
                }
                *COMMAND_TX.lock() = None;
            }
        }
        UxEvent::IdentityLevelIncreased { level } => {
            push_diag(&format!("identity level increased to {}", level));
        }
        _ => {}
    }
    false
}

/// Terminates the local state after the session ended without a user
/// request (supervisor exhausted / loop died). Sounds follow the kick/ban
/// suppression flag.
fn finalize_passive_disconnect(generation: u64, reason: &str) {
    let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
    if current_gen != generation {
        return;
    }
    let mut s = STATE.lock();
    s.connected = false;
    s.disconnect_requested = false;
    s.pending_events.push_back(TsEvent::Disconnected {
        reason: reason.to_string(),
    });
    drop(s);
    if SFX_SUPPRESS_DISCONNECT.load(Ordering::Relaxed) {
        SFX_SUPPRESS_DISCONNECT.store(false, Ordering::Relaxed);
        schedule_teardown_after_kick_sfx();
    } else {
        schedule_sfx_teardown(SFX_CONNECTION_LOST);
    }
    *COMMAND_TX.lock() = None;
}

/// User-requested disconnect: queue the sound first (the handshake waits
/// for the server's ack), then close the session.
async fn do_disconnect(session: &Arc<Ts3Session>, generation: u64) {
    schedule_sfx_teardown(SFX_DISCONNECTED);
    let _ = session.disconnect(Some("leaving".to_string())).await;
    let current_gen = crate::CONNECTION_GENERATION.load(Ordering::SeqCst);
    if current_gen == generation {
        let mut s = STATE.lock();
        s.pending_events.push_back(TsEvent::Disconnected {
            reason: "User disconnected".into(),
        });
        s.connected = false;
        s.disconnect_requested = false;
        drop(s);
        *COMMAND_TX.lock() = None;
    }
}

async fn event_loop(
    session: Arc<Ts3Session>,
    mut cmd_rx: tokio::sync::mpsc::UnboundedReceiver<Command>,
    generation: u64,
) {
    eprintln!("event_loop: started gen={}", generation);
    push_diag(&format!("event_loop: started (gen={})", generation));
    crate::EVENT_LOOP_ALIVE.store(true, Ordering::SeqCst);
    let mut events = session.events();
    let mut voice_rx = session.conn().voice_sink_handle().subscribe();
    let mut recent = RecentClients::new();
    loop {
        // NOTE: no per-iteration cleanup of the "is talking" heartbeats here.
        // The maintenance task sweeps TALKING_CLIENTS on its 5s tick — this
        // loop runs once per voice packet and must stay cheap.
        if SWIPE_DISCONNECT.load(Ordering::SeqCst) {
            STATE.lock().disconnect_requested = true;
            SWIPE_DISCONNECT.store(false, Ordering::SeqCst);
        }
        let do_disconnect_now = STATE.lock().disconnect_requested;
        if do_disconnect_now {
            do_disconnect(&session, generation).await;
            return;
        }

        tokio::select! {
            ev = events.next() => {
                match ev {
                    Some(ev) => {
                        let ev = (*ev).clone();
                        let fut = handle_univox_event(ev, &session, &mut recent, generation);
                        match std::panic::AssertUnwindSafe(fut).catch_unwind().await {
                            Ok(resubscribe) => {
                                if resubscribe {
                                    // The supervisor swapped the connection
                                    // on a reconnect — the old sink channel
                                    // is closed.
                                    voice_rx = session.conn().voice_sink_handle().subscribe();
                                }
                            }
                            Err(p) => {
                                let msg = panic_msg(&p);
                                eprintln!("event handler PANICKED: {}", msg);
                                push_diag(&format!("event handler PANICKED: {}", msg));
                            }
                        }
                    }
                    None => {
                        // The event stream ended: the supervisor exhausted
                        // its attempts (Closed was delivered) or the session
                        // was dropped.
                        eprintln!(
                            "event_loop: event stream ended (gen={})",
                            generation
                        );
                        finalize_passive_disconnect(generation, "Connection closed by server");
                        return;
                    }
                }
            }
            v = voice_rx.recv() => match v {
                Ok(vd) => on_voice_data(vd),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                    // The connection object was swapped; the Reconnected
                    // event renews the subscription.
                    continue;
                }
            },
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else { return };
                let fut = handle_command(cmd, &session, generation);
                match std::panic::AssertUnwindSafe(fut).catch_unwind().await {
                    Ok(exit) => {
                        if exit {
                            return;
                        }
                    }
                    Err(p) => {
                        let msg = panic_msg(&p);
                        eprintln!("command handler PANICKED: {}", msg);
                        push_diag(&format!("command handler PANICKED: {}", msg));
                    }
                }
            }
        }
    }
}

/// Executes one queued command against the session. Returns true when the
/// event loop should exit (user disconnect).
async fn handle_command(
    cmd: Command,
    session: &Arc<Ts3Session>,
    generation: u64,
) -> bool {
    match cmd {
        Command::SendMessage { target_mode, target_cid, message } => {
            let target = match target_mode {
                1 => MessageTarget::Direct(MemberId::from_u64(target_cid)),
                3 => MessageTarget::Server,
                _ => MessageTarget::Channel(ChannelId::from_u64(0)),
            };
            let result = session
                .send_message(target, &univox_core::message::MessageContent::Plain(message))
                .await;
            match result {
                Ok(_) => {
                    // Outbound chat sound (the server echoes the message
                    // back; the inbound sound skips our own echoes).
                    push_sfx(SFX_CHAT_OUTBOUND, "message sent");
                }
                Err(e) => {
                    // A send the server refused (missing send permission
                    // etc.) — tell Dart instead of dropping it silently.
                    let reason = error_text(&e);
                    push_diag(&format!("text message rejected: {}", reason));
                    STATE
                        .lock()
                        .pending_events
                        .push_back(TsEvent::SendFailed { error: reason });
                }
            }
        }
        Command::MoveChannel { client_id, channel_id, password, token } => {
            let is_own = client_id as u32 == self_clid(session) as u32;
            // TS3 expects cpw as base64(sha1(password)); never send
            // plaintext over the wire.
            let mut command = Ts3Command::new("clientmove")
                .param("clid", client_id)
                .param("cid", channel_id);
            if let Some(pw) = password.as_deref().filter(|p| !p.is_empty()) {
                command = command.param("cpw", hash_password(pw));
            }
            match session.exec(command).await {
                Ok(_) => {
                    if let Some(t) = token.as_deref() {
                        push_perm_op(t, true, None);
                    }
                }
                Err(e) => {
                    if is_own && ts3_error_code(&e) == Some(TS3_ERR_CHANNEL_INVALID_PASSWORD) {
                        STATE
                            .lock()
                            .pending_events
                            .push_back(TsEvent::MoveRejected {
                                channel_id: channel_id as u32,
                            });
                    }
                    if let Some(t) = token.as_deref() {
                        push_perm_op(t, false, Some(error_text(&e)));
                    } else if !is_own {
                        push_diag(&format!(
                            "move client {}: {}",
                            client_id,
                            error_text(&e)
                        ));
                    }
                }
            }
        }
        Command::SetMuted { input, output } => {
            // Record the intent before the send: the Reconnected handler
            // re-applies it, even if this very update was lost.
            let (prev_in, prev_out) = {
                let mut s = STATE.lock();
                let prev = (s.self_input_muted, s.self_output_muted);
                s.self_input_muted = input;
                s.self_output_muted = output;
                prev
            };
            // Only the changed half goes into the clientupdate: the server
            // echoes every included key and the MemberUpdated handler plays
            // one sound per echoed key — sending both toggles both sounds.
            let in_changed = input != prev_in;
            let out_changed = output != prev_out;
            if in_changed || out_changed {
                let _ = session
                    .update_self(SelfUpdate {
                        input_muted: in_changed.then_some(input),
                        output_muted: out_changed.then_some(output),
                        ..Default::default()
                    })
                    .await;
            }
        }
        Command::SetAway { away } => {
            STATE.lock().self_away = away;
            let _ = session
                .update_self(SelfUpdate {
                    away: Some(away),
                    away_message: if away { Some("Away".into()) } else { None },
                    ..Default::default()
                })
                .await;
        }
        Command::SendPoke { client_id, message } => {
            if let Err(e) = session
                .poke(&MemberId::from_u64(client_id as u64), &message)
                .await
            {
                push_diag(&format!("poke client {}: {}", client_id, error_text(&e)));
            }
        }
        Command::KickClient { client_id, from_server, reason, token } => {
            if client_id as u32 == self_clid(session) as u32 {
                // Self-protection: never kick ourselves even if the UI
                // somehow offered the action.
                push_diag("kick client: skipped (cannot kick self)");
                if let Some(t) = token {
                    push_perm_op(&t, false, Some("cannot kick yourself".into()));
                }
            } else {
                push_diag(&format!(
                    "kick client {} (from_server={}): sent",
                    client_id, from_server
                ));
                let result = session
                    .kick_member(
                        &MemberId::from_u64(client_id as u64),
                        !from_server,
                        if reason.is_empty() { None } else { Some(reason.as_str()) },
                    )
                    .await;
                let ok = result.is_ok();
                let err = result.as_ref().err().map(error_text);
                match token {
                    Some(t) => push_perm_op(&t, ok, err),
                    None => {
                        if let Some(e) = err {
                            push_diag(&format!("kick client {}: {}", client_id, e));
                        }
                    }
                }
            }
        }
        Command::BanClient { client_id, time_seconds, reason, token } => {
            if reason.is_empty() && time_seconds == 0 {
                push_diag("ban client: skipped (no reason / permanent-by-accident)");
                if let Some(t) = token {
                    push_perm_op(&t, false, Some("skip: empty reason (permanent ban)".into()));
                }
            } else if client_id as u32 == self_clid(session) as u32 {
                push_diag("ban client: skipped (cannot ban self)");
                if let Some(t) = token {
                    push_perm_op(&t, false, Some("cannot ban yourself".into()));
                }
            } else {
                push_diag(&format!("ban client {} ({}s): sent", client_id, time_seconds));
                let result = session
                    .ban_member(
                        &MemberId::from_u64(client_id as u64),
                        if time_seconds > 0 {
                            Some(Duration::from_secs(time_seconds as u64))
                        } else {
                            None // permanent ban
                        },
                        Some(reason.as_str()),
                    )
                    .await;
                let ok = result.is_ok();
                let err = result.as_ref().err().map(error_text);
                match token {
                    Some(t) => push_perm_op(&t, ok, err),
                    None => {
                        if let Some(e) = err {
                            push_diag(&format!("ban client {}: {}", client_id, e));
                        }
                    }
                }
            }
        }
        // ── Channel management ───────────────────────────────────────
        Command::ChannelCreate { args, token } => {
            let mut extra: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();
            // Family limits: -1 inherited, 0 unlimited, >0 limit — mapped to
            // the wire flags.
            match args.max_family_clients {
                Some(0) => {
                    extra.insert(
                        "channel_flag_maxfamilyclients_unlimited".into(),
                        "1".into(),
                    );
                }
                Some(f) if f < 0 => {
                    extra.insert(
                        "channel_flag_inherited_maxfamilyclients".into(),
                        "1".into(),
                    );
                }
                Some(f) => {
                    extra.insert("channel_maxfamilyclients".into(), f.to_string());
                }
                None => {}
            }
            if args.max_clients == Some(0) {
                extra.insert("channel_flag_maxclients_unlimited".into(), "1".into());
            }
            let permanence = if args.is_permanent.unwrap_or(false) {
                Permanence::Permanent
            } else if args.is_semi_permanent.unwrap_or(false) {
                Permanence::SemiPermanent
            } else {
                Permanence::Temporary
            };
            let options = ChannelOptions {
                kind: univox_core::model::ChannelKind::Voice,
                name: args.name.clone().unwrap_or_default(),
                parent: Some(ChannelId::from_u64(args.parent_id.unwrap_or(0) as u64)),
                topic: args.topic.clone().filter(|t| !t.is_empty()),
                description: args.description.clone().filter(|d| !d.is_empty()),
                password: args.password.clone().filter(|p| !p.is_empty()),
                user_limit: args.max_clients.filter(|n| *n > 0).map(|n| n as u64),
                default_channel: args.is_default.unwrap_or(false),
                permanence,
                delete_delay: args.delete_delay.map(|v| Duration::from_secs(v as u64)),
                extra,
            };
            push_diag(&format!(
                "channel create under {}: sent",
                args.parent_id.unwrap_or(0)
            ));
            let result = session.create_channel(options).await;
            match result {
                Ok(_) => push_perm_op(&token, true, None),
                Err(e) => push_perm_op(&token, false, Some(error_text(&e))),
            }
        }
        Command::ChannelEdit { channel_id, args, token } => {
            let mut extra: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();
            match args.max_family_clients {
                Some(0) => {
                    extra.insert(
                        "channel_flag_maxfamilyclients_unlimited".into(),
                        "1".into(),
                    );
                }
                Some(f) if f < 0 => {
                    extra.insert(
                        "channel_flag_inherited_maxfamilyclients".into(),
                        "1".into(),
                    );
                }
                Some(f) => {
                    extra.insert("channel_maxfamilyclients".into(), f.to_string());
                }
                None => {}
            }
            match args.max_clients {
                Some(0) => {
                    extra.insert("channel_flag_maxclients_unlimited".into(), "1".into());
                }
                Some(n) if n > 0 => {
                    extra.insert("channel_maxclients".into(), n.to_string());
                }
                _ => {}
            }
            // password: None = untouched, Some("") = clear, Some(p) = set.
            match &args.password {
                Some(p) if p.is_empty() => {
                    extra.insert("channel_flag_password".into(), "0".into());
                }
                Some(p) => {
                    extra.insert("channel_flag_password".into(), "1".into());
                    extra.insert("channel_password".into(), p.clone());
                }
                None => {}
            }
            if let Some(v) = args.is_permanent {
                extra.insert("channel_flag_permanent".into(), u8::from(v).to_string());
            }
            if let Some(v) = args.is_semi_permanent {
                extra.insert(
                    "channel_flag_semi_permanent".into(),
                    u8::from(v).to_string(),
                );
            }
            if let Some(v) = args.is_default {
                extra.insert("channel_flag_default".into(), u8::from(v).to_string());
            }
            if let Some(v) = args.delete_delay {
                extra.insert("channel_delete_delay".into(), v.to_string());
            }
            // Edit-only knobs ride the extra passthrough (channeledit).
            if let Some(v) = args.needed_talk_power {
                extra.insert("channel_needed_talk_power".into(), v.to_string());
            }
            if let Some(v) = args.order {
                extra.insert("channel_order".into(), v.to_string());
            }
            let options = ChannelOptions {
                kind: univox_core::model::ChannelKind::Voice,
                name: args.name.clone().unwrap_or_default(),
                topic: args.topic.clone(),
                description: args.description.clone(),
                ..Default::default()
            };
            push_diag(&format!("channel edit {}: sent", channel_id));
            let result = session
                .edit_channel(&ChannelId::from_u64(channel_id as u64), options)
                .await;
            match result {
                Ok(_) => push_perm_op(&token, true, None),
                Err(e) => push_perm_op(&token, false, Some(error_text(&e))),
            }
        }
        Command::ServerEdit { args, token } => {
            let mut command = Ts3Command::new("serveredit");
            if let Some(v) = &args.name {
                command = command.param("virtualserver_name", v);
            }
            // None = untouched, Some("") = clear, Some(p) = set (the server
            // hashes plaintext passwords on serveredit).
            if let Some(p) = &args.password {
                command = command.param("virtualserver_password", p);
            }
            if let Some(v) = args.max_clients {
                command = command.param("virtualserver_maxclients", v);
            }
            if let Some(v) = &args.welcome_message {
                command = command.param("virtualserver_welcomemessage", v);
            }
            push_diag("server edit: sent");
            let result = session.exec(command).await;
            match result {
                Ok(_) => push_perm_op(&token, true, None),
                Err(e) => push_perm_op(&token, false, Some(error_text(&e))),
            }
        }
        Command::ChannelDelete { channel_id, force, token } => {
            push_diag(&format!(
                "channel delete {} (force={}): sent",
                channel_id, force
            ));
            let result = session
                .delete_channel(&ChannelId::from_u64(channel_id as u64), force)
                .await;
            match result {
                Ok(_) => push_perm_op(&token, true, None),
                Err(e) => push_perm_op(&token, false, Some(error_text(&e))),
            }
        }
        Command::ChannelMove { channel_id, parent_id, order, token } => {
            push_diag(&format!(
                "channel move {} -> {} (order {:?}): sent",
                channel_id, parent_id, order
            ));
            // Omitting `order` appends the channel at the end (server
            // default) — the reason this is an exec instead of the typed
            // move_channel (which always sends order=0).
            let mut command = Ts3Command::new("channelmove")
                .param("cid", channel_id as u64)
                .param("cpid", parent_id as u64);
            if let Some(o) = order {
                command = command.param("order", o as u64);
            }
            match session.exec(command).await {
                Ok(_) => push_perm_op(&token, true, None),
                Err(e) => push_perm_op(&token, false, Some(error_text(&e))),
            }
        }
        // ── Permission management ────────────────────────────────────
        Command::ServerGroupAddClient { sgid, dbid, token } => {
            let result = session
                .assign_role(&MemberId::from_u64(dbid), &univox_core::id::RoleId::from_u64(sgid))
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::ServerGroupDelClient { sgid, dbid, token } => {
            let result = session
                .revoke_role(&MemberId::from_u64(dbid), &univox_core::id::RoleId::from_u64(sgid))
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::ChannelGroupSet { cgid, cid, dbid, token } => {
            let result = session
                .exec(
                    Ts3Command::new("channelgroupaddclient")
                        .param("cgid", cgid)
                        .param("cid", cid)
                        .param("cldbid", dbid),
                )
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::ChannelGroupClear { cid, dbid, token } => {
            let result = session
                .exec(
                    Ts3Command::new("channelgroupdelclient")
                        .param("cid", cid)
                        .param("cldbid", dbid),
                )
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::GrantChannelPerm { cid, dbid, permsid, value, token } => {
            let result = session
                .exec(
                    Ts3Command::new("channelclientaddperm")
                        .param("cid", cid)
                        .param("cldbid", dbid)
                        .param("permsid", &permsid)
                        .param("permvalue", value),
                )
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::RevokeChannelPerm { cid, dbid, permsid, token } => {
            let result = session
                .exec(
                    Ts3Command::new("channelclientdelperm")
                        .param("cid", cid)
                        .param("cldbid", dbid)
                        .param("permsid", &permsid),
                )
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::GrantServerPerm { dbid, permsid, value, token } => {
            let result = session
                .exec(
                    Ts3Command::new("clientaddperm")
                        .param("cldbid", dbid)
                        .param("permsid", &permsid)
                        .param("permvalue", value),
                )
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::RevokeServerPerm { dbid, permsid, token } => {
            let result = session
                .exec(
                    Ts3Command::new("clientdelperm")
                        .param("cldbid", dbid)
                        .param("permsid", &permsid),
                )
                .await;
            push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::RefreshGroups => {
            refresh_group_lists(session).await;
            push_diag("perm: re-requested server/channel group lists");
        }
        Command::UsePrivilegeKey { token, op_token } => {
            // Redeem a privilege key after connecting — the same command the
            // official client sends for "Use Privilege Key".
            let result = session.use_privilege_key(&token).await;
            push_perm_op(
                &op_token,
                result.is_ok(),
                result.as_ref().err().map(error_text),
            );
        }
        Command::OwnPermList => {
            refresh_own_perms(session).await;
        }
        // ── File transfers ───────────────────────────────────────────
        Command::FtList { cid, path, password, token } => {
            push_diag(&format!("ft list {}: request cid={} path={}", token, cid, path));
            let result = session
                .list_files(&ChannelId::from_u64(cid), &path, password.as_deref())
                .await;
            match result {
                Ok(rows) => {
                    let entries: Vec<TsFtEntry> = rows
                        .iter()
                        .map(|r| TsFtEntry {
                            name: r.get("name").unwrap_or("").to_string(),
                            size: r.get("size").and_then(|v| v.parse().ok()).unwrap_or(0),
                            // Unix seconds; -1 when the server sent none.
                            datetime: r
                                .get("datetime")
                                .and_then(|v| v.parse().ok())
                                .unwrap_or(-1),
                            // Wire type: 0 = directory, 1 = file (verified
                            // against a live 3.13.8 server — univox's
                            // create_dir_shows_in_listing test pins it).
                            is_file: r.get("type").map(|t| t == "1").unwrap_or(true),
                        })
                        .collect();
                    STATE
                        .lock()
                        .pending_events
                        .push_back(TsEvent::FtListing {
                            token,
                            entries,
                            error: None,
                        });
                }
                Err(e) => {
                    push_diag(&format!("ft list {}: {}", token, error_text(&e)));
                    STATE
                        .lock()
                        .pending_events
                        .push_back(TsEvent::FtListing {
                            token,
                            entries: vec![],
                            error: Some(error_text(&e)),
                        });
                }
            }
        }
        Command::FtCreateDir { cid, dirname, password, token } => {
            push_diag(&format!("ft mkdir {}: dirname={}", token, dirname));
            let result = session
                .create_dir(&ChannelId::from_u64(cid), &dirname, password.as_deref())
                .await;
            push_perm_op_like_ft(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::FtDelete { cid, names, password, token } => {
            push_diag(&format!("ft delete {}: {} path(s)", token, names.len()));
            // One typed call per entry (univox deletes a single file per
            // command); they run in order and the first failure decides the
            // reported result.
            let mut result: univox_core::error::Result<()> = Ok(());
            for name in &names {
                result = session
                    .delete_file(&ChannelId::from_u64(cid), name, password.as_deref())
                    .await;
                if result.is_err() {
                    break;
                }
            }
            push_perm_op_like_ft(&token, result.is_ok(), result.as_ref().err().map(error_text));
        }
        Command::FtDownload { cid, path, password, task_id } => {
            push_diag(&format!(
                "ft download task={} cid={} path={}",
                task_id, cid, path
            ));
            match session
                .download_file_stream(&ChannelId::from_u64(cid), &path, password.as_deref())
                .await
            {
                Ok(dl) => spawn_download_task(task_id, dl),
                Err(e) => crate::finish_ft_task(task_id, false, Some(error_text(&e))),
            }
        }
        Command::FtUpload { cid, path, password, task_id } => {
            push_diag(&format!(
                "ft upload task={} cid={} path={}",
                task_id, cid, path
            ));
            let total = FT_TASKS
                .get(&task_id)
                .map(|t| t.total.load(Ordering::Relaxed))
                .unwrap_or(0);
            match session
                .upload_file_stream(
                    &ChannelId::from_u64(cid),
                    &path,
                    total,
                    password.as_deref(),
                )
                .await
            {
                Ok(up) => spawn_upload_task(task_id, up, {
                    FT_TASKS
                        .get(&task_id)
                        .map(|t| t.local_path.clone())
                        .unwrap_or_default()
                }),
                Err(e) => crate::finish_ft_task(task_id, false, Some(error_text(&e))),
            }
        }
        Command::Disconnect => {
            do_disconnect(session, generation).await;
            return true;
        }
        Command::SendAudio { data } => {
            // The pipeline decides (VAD), gains (AGC + slider) and encodes;
            // only the network sends happen out here, so the session is
            // never touched under the pipeline lock.
            let bursts = {
                let mut pipe = MIC_PIPELINE.lock();
                pipe.push_samples(&data);
                let mut bursts = Vec::new();
                while let Some(burst) = pipe.next_burst() {
                    let done = burst.packets.is_empty();
                    bursts.push(burst);
                    if done {
                        break;
                    }
                }
                bursts
            };
            let conn = session.conn();
            for burst in bursts {
                let n = burst.packets.len();
                for (i, (_seq, opus)) in burst.packets.into_iter().enumerate() {
                    // Recording tap: our own uplink frames, back-filled so
                    // keys stay strictly ascending across a preroll burst.
                    // Skipped when the back-fill would underflow (the very
                    // first frames of a session).
                    let slot = PLAYED_SAMPLES.load(Ordering::Relaxed) / FRAME_SIZE;
                    let back = (n - 1 - i) as u64;
                    if slot >= back {
                        recording::push_mic(slot - back, &opus);
                    }
                    // Codec byte + opus payload; the connection actor
                    // prepends the voice sequence id.
                    let mut content = Vec::with_capacity(1 + opus.len());
                    content.push(univox_ts3_proto::CODEC_OPUS_VOICE);
                    content.extend_from_slice(&opus);
                    conn.send_voice(content, PacketType::Voice).await;
                    crate::VOICE_ACTIVE.store(true, Ordering::Relaxed);
                }
            }
        }
    }
    false
}

/// FtOp answers share the PermOp shape but are matched by ft_service.dart —
/// same publish path, clearer call sites.
fn push_perm_op_like_ft(token: &str, ok: bool, error: Option<String>) {
    push_diag(&format!(
        "ft op {}: ok={} {}",
        token,
        ok,
        error.as_deref().unwrap_or("")
    ));
    STATE.lock().pending_events.push_back(TsEvent::FtOp {
        token: token.to_string(),
        ok,
        error,
    });
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

    // Fallback: if the event loop is dead, take the session from stash
    // and do a synchronous block_on disconnect directly.
    if let Some(session) = crate::CONNECTION_STASH.lock().take() {
        let _ = RUNTIME.block_on(session.disconnect(Some("leaving".to_string())));
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
    } else if STATE.lock().connected {
        // Zombie state: no live event loop and nothing in the stash (e.g. the
        // event loop panicked without running its teardown). Reset so the UI
        // does not stay stuck on a ghost connection.
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
        s.pending_events.push_back(TsEvent::Disconnected {
            reason: "User disconnected".into(),
        });
        drop(s);
        *COMMAND_TX.lock() = None;
        teardown_output_state();
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
    } else if let Some(session) = crate::CONNECTION_STASH.lock().take() {
        let _ = RUNTIME.block_on(session.disconnect(Some("leaving".to_string())));
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
        drop(s);
        recording::on_disconnect();
        AUDIO_STREAM.lock().unwrap().0 = None;
        CLIENT_BUFFERS.clear();
        AUDIO_DECODERS.clear();
        AUDIO_DECODERS_STEREO.clear();
        PLAYED_SAMPLES.store(0, Ordering::Relaxed);
        ACTIVE_CLIENT_IDS.store(std::sync::Arc::new(Vec::new()));
        // Same as teardown_output_state: the clock reference and the learned
        // playout profiles belong to the connection that just ended.
        CLOCK_REF.store(0, Ordering::Relaxed);
        JITTER_STATS.clear();
        TALKING_CLIENTS.clear();
        MIN_SURPLUS_FRAMES.store(0, Ordering::Relaxed);
    } else if STATE.lock().connected {
        // Zombie state: no live event loop and nothing in the stash (e.g. the
        // event loop panicked without running its teardown). Reset everything
        // so the UI is not stuck on a ghost connection and can reconnect.
        let mut s = STATE.lock();
        s.connected = false;
        s.disconnect_requested = false;
        s.pending_events.push_back(TsEvent::Disconnected {
            reason: "User disconnected".into(),
        });
        drop(s);
        *COMMAND_TX.lock() = None;
        teardown_output_state();
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

/// JNI entry called once from MainActivity.onCreate: hands the JVM and the
/// application context to `ndk-context`, which cpal/oboe consult when they
/// build audio streams on Android (the AudioTrack/AudioRecord buffer-size
/// queries go through JNI). A plain Flutter FFI app has no ndk-glue, so
/// nothing else initializes it — without this the first stream build panics
/// with "android context was not initialized". Android-only.
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_senlinjun_nek0_MainActivity_tsInitAndroid(
    env: jni::JNIEnv,
    _class: jni::objects::JClass,
    context: jni::objects::JObject,
) {
    // initialize_android_context asserts when called twice; the guard also
    // turns repeated MainActivity.onCreate calls (activity recreation) into
    // no-ops.
    static INITIALIZED: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);
    if INITIALIZED.swap(true, Ordering::SeqCst) {
        return;
    }
    let init = || -> Result<(), jni::errors::Error> {
        let vm = env.get_java_vm()?;
        // Leak the global reference on purpose: ndk-context stores the raw
        // jobject for the process lifetime, so the ref must never be freed.
        let gref = env.new_global_ref(&context)?;
        let raw = gref.as_raw();
        std::mem::forget(gref);
        unsafe {
            ndk_context::initialize_android_context(
                vm.get_java_vm_pointer() as *mut std::ffi::c_void,
                raw as *mut std::ffi::c_void,
            );
        }
        Ok(())
    };
    match init() {
        Ok(()) => eprintln!("tsInitAndroid: ndk-context initialized"),
        Err(e) => eprintln!("tsInitAndroid failed: {}", e),
    }
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
    // Recompute is_talking from the live heartbeat map (outside STATE, so the
    // receive path never contends with this call for the state lock).
    let talking: Vec<u16> = TALKING_CLIENTS
        .iter()
        .filter(|e| e.value().elapsed().as_millis() < 500)
        .map(|e| *e.key())
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

#[no_mangle]
pub extern "C" fn ts_send_private_message(client_id: u16, msg: *const c_char) -> u8 {
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
                target_mode: 1,
                target_cid: client_id as u64,
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

#[no_mangle]
pub extern "C" fn ts_send_server_message(msg: *const c_char) -> u8 {
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
                target_mode: 3,
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

/// Partial VAD/AGC/mic-gain config update (JSON, all fields optional —
/// absent fields keep their current value; see
/// mic_pipeline::PipelineConfigPatch for the contract). Returns 1 on a
/// valid parse, 0 otherwise.
#[no_mangle]
pub extern "C" fn ts_set_vad_config(json: *const c_char) -> u8 {
    if json.is_null() {
        return 0;
    }
    let s = unsafe { std::ffi::CStr::from_ptr(json) }.to_string_lossy();
    match MIC_PIPELINE.lock().apply_patch(&s) {
        Ok(()) => 1,
        Err(e) => {
            eprintln!("ts_set_vad_config: {e}");
            0
        }
    }
}

/// Snapshot of the last processed mic frame (level, noise floor, speech
/// probability, AGC gain, gate state) as JSON. Freed via ts_free_string.
#[no_mangle]
pub extern "C" fn ts_get_vad_status() -> *mut c_char {
    let status = MIC_PIPELINE.lock().status.clone();
    to_c_str(serde_json::to_string(&status).unwrap_or_else(|e| {
        format!("{{\"error\":\"{e}\"}}")
    }))
}

/// Drops everything learned about the current environment (noise floor,
/// RNNoise warm-up, AGC gain). Used by the calibration flow.
#[no_mangle]
pub extern "C" fn ts_reset_vad() {
    MIC_PIPELINE.lock().reset_analysis();
}

/// Legacy single-value toggles kept so an older Dart side can still drive a
/// newer .so (and vice versa) without missing-symbol crashes. The full
/// config lives in ts_set_vad_config.
#[no_mangle]
pub extern "C" fn ts_set_vad_threshold(threshold: f32) {
    // Old contract was a linear RMS value; the dB domain is authoritative
    // now, so convert instead of storing an out-of-range raw number.
    let db = crate::vad::rms_to_db(threshold.clamp(1e-6, 1.0));
    let _ = MIC_PIPELINE
        .lock()
        .apply_patch(&format!("{{\"activation_db\":{db}}}"));
}

#[no_mangle]
pub extern "C" fn ts_set_vad_enabled(enabled: u8) -> u8 {
    let _ = MIC_PIPELINE
        .lock()
        .apply_patch(&format!("{{\"enabled\":{}}}", enabled != 0));
    1
}

#[no_mangle]
pub extern "C" fn ts_is_voice_active() -> u8 {
    crate::VOICE_ACTIVE.swap(false, Ordering::Relaxed) as u8
}

// ─── Mic gain ───────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ts_set_mic_gain(gain: f32) {
    let _ = MIC_PIPELINE
        .lock()
        .apply_patch(&format!("{{\"mic_gain\":{}}}", gain.clamp(0.0, 3.0)));
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

/// Set (enabled != 0) or clear (enabled == 0) a remote client's 2D position
/// relative to us, in meters on the horizontal plane (+x = right, +y =
/// forward). The mixer pans and distance-attenuates that client's audio by it.
/// Persisted under the client's user UID like ts_set_client_volume so it
/// survives reconnects; when the UID is not known yet (e.g. brand-new client
/// within the roster refresh window), only the live buffer is updated and not
/// persisted.
#[no_mangle]
pub extern "C" fn ts_set_client_position(client_id: u16, x: f32, y: f32, enabled: u8) {
    let mut state = STATE.lock();
    let uid = state
        .clients
        .iter()
        .find(|c| c.id as u16 == client_id)
        .and_then(|c| c.uid.as_ref())
        .cloned();
    if enabled != 0 {
        if let Some(uid) = uid {
            state.client_positions.insert(uid, (x, y));
        }
    } else if let Some(uid) = uid {
        state.client_positions.remove(&uid);
    }
    drop(state);

    // Also update the live jitter buffer if it exists. NaN bits mean "no
    // position" (centered playback) — the mixer's positional_gains checks for
    // them, so clearing writes NaN rather than (0, 0).
    if let Some(buf) = CLIENT_BUFFERS.get(&client_id) {
        let (px, py) = if enabled != 0 {
            (x, y)
        } else {
            (f32::NAN, f32::NAN)
        };
        buf.pos_x.store(f32::to_bits(px), Ordering::Release);
        buf.pos_y.store(f32::to_bits(py), Ordering::Release);
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
    let mut pipe = MIC_PIPELINE.lock();
    pipe.encoder = Some(encoder);
    pipe.seq = 0;
    // Fresh DSP state for a new session; the AGC gain is re-seeded from the
    // per-device memory so the first sentence is not quiet.
    pipe.session_start();
    1
}

#[no_mangle]
pub extern "C" fn ts_stop_audio() {
    let disconnect_pending = {
        let mut pipe = MIC_PIPELINE.lock();
        pipe.session_stop();
        pipe.encoder = None;
        STATE.lock().disconnect_requested
    };
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
/// callback (desktop capture). Frame VAD/AGC/gain/encode happen downstream
/// in the event loop's Command::SendAudio handler. While NOT connected the
/// samples still feed the pipeline's analysis stage (level meter, noise
/// floor, speech probability) so the settings mic test and calibration work
/// without a server; nothing is encoded or sent in that mode.
fn queue_mic_samples(samples: Vec<f32>) -> bool {
    if samples.is_empty() {
        return false;
    }
    if !STATE.lock().connected {
        MIC_PIPELINE.lock().analyze_only(&samples);
        return true;
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
    let samples: Vec<f32> = raw.to_vec(); // raw samples — VAD/gain happen in the pipeline
    queue_mic_samples(samples) as u8
}

// ─── Mic capture (desktop; Android uses the Kotlin EventChannel path) ──

/// Records a mic-capture failure for the UI: stderr (dev console) plus
/// AUDIO_LAST_ERROR, which ts_get_last_audio_error exposes to Dart. Known
/// WASAPI HRESULTs are mapped to a localized hint on the Dart side, where
/// the l10n strings live.
fn record_mic_error(msg: String) {
    eprintln!("cpal mic: {}", msg);
    *AUDIO_LAST_ERROR.lock().unwrap() = Some(msg);
}

/// Clears the last recorded mic-capture failure (called on successful start
/// and on user-driven stop).
fn clear_mic_error() {
    *AUDIO_LAST_ERROR.lock().unwrap() = None;
}

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

/// Starts the cpal microphone input stream (desktop capture). Tries the
/// device's own default input format first, then 48 kHz mono (both downmixed
/// + resampled to 48 kHz mono in the callback). Idempotent: true when a
/// capture stream already runs — the error callback unregisters dead streams,
/// so a failed device cannot keep satisfying this check.
pub fn start_mic_capture() -> bool {
    if crate::MIC_STREAM.lock().unwrap().0.is_some() {
        return true;
    }
    let host = cpal::default_host();
    let Some(device) = pick_device(&host, true) else {
        record_mic_error("no input device".into());
        return false;
    };
    let dev_name = device.name().unwrap_or_default();
    eprintln!("cpal mic: input device \"{}\"", dev_name);
    // AGC gain memory is keyed per input device: switching devices switches
    // to that device's learned gain.
    *crate::mic_pipeline::MIC_DEVICE_KEY.lock() = dev_name.clone();
    // cpal's WASAPI backend treats every IsFormatSupported S_FALSE as
    // unsupported (no AUTOCONVERTPCM), so the device's own mix format must
    // be the first candidate — 48 kHz mono only succeeds on devices natively
    // running at 48 kHz mono. MicResampler normalizes everything to 48 kHz
    // mono afterwards, so trying the native format first costs nothing.
    let mut candidates: Vec<cpal::StreamConfig> = Vec::new();
    if let Ok(default) = device.default_input_config() {
        candidates.push(cpal::StreamConfig {
            channels: default.channels(),
            sample_rate: default.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        });
        if default.sample_rate().0 != 48000 {
            candidates.push(cpal::StreamConfig {
                channels: 1,
                sample_rate: default.sample_rate(),
                buffer_size: cpal::BufferSize::Default,
            });
        }
    }
    candidates.push(cpal::StreamConfig {
        channels: 1,
        sample_rate: cpal::SampleRate(48000),
        buffer_size: cpal::BufferSize::Default,
    });

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
            |err| {
                record_mic_error(format!("input stream error: {}", err));
                // Unregister the dead stream so ts_set_mic_capture no longer
                // reports success, and ask the maintenance task to rebuild.
                crate::MIC_STREAM.lock().unwrap().0 = None;
                crate::MIC_RESTART_REQUESTED.store(true, Ordering::Relaxed);
            },
            None,
        );
        match stream {
            // cpal only CREATES the stream here — on WASAPI nothing starts
            // until play() posts Command::PlayStream, whose handler calls
            // IAudioClient::Start(). Without it the stream silently never
            // delivers a single callback (no error either) and Windows'
            // mic-in-use indicator stays off; ALSA starts on creation, which
            // is why the missing play() only broke Windows.
            Ok(stream) => match stream.play() {
                Ok(()) => {
                    crate::MIC_STREAM.lock().unwrap().0 = Some(stream);
                    clear_mic_error();
                    eprintln!(
                        "cpal mic: input stream started ({} Hz, {} ch)",
                        config.sample_rate.0, config.channels
                    );
                    return true;
                }
                Err(e) => {
                    // stream drops here: the worker thread terminates and the
                    // loop tries the next candidate format.
                    record_mic_error(format!(
                        "input stream play() failed ({} Hz, {} ch): {}",
                        config.sample_rate.0, config.channels, e
                    ));
                }
            },
            Err(e) => record_mic_error(format!(
                "build_input_stream failed ({} Hz, {} ch): {}",
                config.sample_rate.0, config.channels, e
            )),
        }
    }
    record_mic_error(format!(
        "all input configurations failed for device \"{}\"",
        dev_name
    ));
    false
}

/// Stops the microphone input stream (Dart-driven lifecycle). Also cancels
/// a pending auto-restart — a deliberate stop must win over the maintenance
/// task's rebuild request — and clears the recorded failure.
pub fn stop_mic_capture() {
    crate::MIC_RESTART_REQUESTED.store(false, Ordering::Relaxed);
    let mut guard = crate::MIC_STREAM.lock().unwrap();
    if guard.0.take().is_some() {
        eprintln!("cpal mic: input stream stopped");
    }
    drop(guard);
    crate::MIC_RMS.store(0, Ordering::Relaxed);
    clear_mic_error();
}

/// Last mic-capture failure message (desktop path, see record_mic_error),
/// "" while capture is healthy. Dart maps known WASAPI HRESULTs in the raw
/// cpal error text to a localized hint.
#[no_mangle]
pub extern "C" fn ts_get_last_audio_error() -> *mut c_char {
    let msg = AUDIO_LAST_ERROR.lock().unwrap().clone().unwrap_or_default();
    to_c_str(msg)
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
    /// Human-readable display name; `name` stays the value/persistence key.
    /// Linux fills this from the ALSA hint description (card longname), other
    /// platforms echo `name` (cpal/WASAPI/oboe names are already friendly).
    label: String,
    is_default: bool,
}

/// Lists host output/input devices for the picker UI as JSON:
/// `{"outputs":[{"name","label","is_default"}],"inputs":[...]}`. On Linux the
/// list comes from the stable ALSA name hints (see list_audio_devices_linux);
/// platforms without enumeration support (Android/oboe) return empty arrays.
fn list_audio_devices(host: &cpal::Host, input: bool) -> Vec<AudioDeviceInfo> {
    #[cfg(target_os = "linux")]
    {
        let _ = host; // the hint list does not go through cpal
        return list_audio_devices_linux(input);
    }
    #[cfg(not(target_os = "linux"))]
    {
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
                        label: name.clone(),
                        name,
                    });
                }
            }
        }
        out
    }
}

#[cfg(target_os = "linux")]
mod linux_devices {
    use std::collections::HashSet;

    /// ALSA PCM names that are plugins/converters rather than routable
    /// devices — never a useful mic or speaker choice. `jack`/`oss` fail to
    /// open unless that subsystem is actually running.
    pub(super) const JUNK_PCMS: [&str; 9] = [
        "null", "lavrate", "samplerate", "speexrate", "speex", "upmix", "vdownmix", "jack", "oss",
    ];

    /// Card id embedded in an ALSA PCM alias ("default:CARD=III" → "III",
    /// "hdmi:CARD=NVidia,DEV=1" → "NVidia"), None for plain plugin names.
    pub(super) fn card_of(pcm: &str) -> Option<&str> {
        let rest = &pcm[pcm.find("CARD=")? + "CARD=".len()..];
        Some(&rest[..rest.find(',').unwrap_or(rest.len())])
    }

    /// Whether `name` belongs in the picker for `input`. `cards_with_default`
    /// holds the cards that already have a `default:CARD=` entry, which makes
    /// their `sysdefault:CARD=` twin redundant. `front:`/`surround*:` are
    /// channel-layout aliases of `default:CARD=` (hidden everywhere);
    /// `iec958:`/`hdmi:` are genuinely separate digital outputs (kept for
    /// output only — as capture targets they are useless).
    pub(super) fn visible(name: &str, input: bool, cards_with_default: &HashSet<String>) -> bool {
        if JUNK_PCMS.contains(&name) || name.starts_with("usbstream:") {
            return false;
        }
        if name.starts_with("front:") || name.starts_with("surround") {
            return false;
        }
        if name.starts_with("sysdefault:") {
            if let Some(card) = card_of(name) {
                if cards_with_default.contains(card) {
                    return false;
                }
            }
        }
        if input && (name.starts_with("iec958:") || name.starts_with("hdmi:")) {
            return false;
        }
        true
    }

    /// Display label: friendly names for the sound-server PCMs, else the
    /// hint's DESC (its first line is the card longname, e.g. "HyperX Cloud
    /// III USB"), falling back to the PCM name itself.
    pub(super) fn label(name: &str, desc: Option<&str>) -> String {
        match name {
            "pipewire" => return "PipeWire".to_string(),
            "pulse" => return "PulseAudio".to_string(),
            _ => {}
        }
        desc.and_then(|d| d.lines().next())
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .unwrap_or(name)
            .to_string()
    }
}

/// Linux device list from the stable ALSA name hints (`snd_device_name_hint`,
/// the same source arecord -L shows). Unlike cpal's enumeration — which
/// probe-opens every PCM and silently drops the ones the sound server holds
/// at that moment — the hint list is static config, so entries no longer
/// appear/disappear with PipeWire/WirePlumber activity. Openability is
/// enforced when the device is actually opened (pick_device), with a
/// graceful fallback.
#[cfg(target_os = "linux")]
fn list_audio_devices_linux(input: bool) -> Vec<AudioDeviceInfo> {
    use alsa::device_name::HintIter;

    let hints = match HintIter::new_str(None, "pcm") {
        Ok(it) => it,
        Err(e) => {
            eprintln!("audio: alsa device hint enumeration failed: {}", e);
            return Vec::new();
        }
    };
    let all: Vec<_> = hints
        .filter_map(|h| Some((h.name?, h.desc, h.direction)))
        .collect();
    let cards_with_default: HashSet<String> = all
        .iter()
        .filter_map(|(n, _, _)| linux_devices::card_of(n).filter(|_| n.starts_with("default:")))
        .map(str::to_string)
        .collect();

    let mut out: Vec<AudioDeviceInfo> = Vec::new();
    let mut seen = HashSet::new();
    let mut marked_default = false;
    for (name, desc, direction) in all {
        let wanted = match direction {
            None => true, // IOID absent — the PCM serves both directions
            Some(alsa::Direction::Capture) => input,
            Some(alsa::Direction::Playback) => !input,
        };
        if !wanted || !linux_devices::visible(&name, input, &cards_with_default) {
            continue;
        }
        if seen.insert(name.clone()) {
            // 系统默认 ('' in the UI) resolves to the sound-server PCM via
            // pick_device, so that entry is the effective default.
            let is_default = !marked_default && SOUND_SERVER_PCMS.contains(&name.as_str());
            marked_default |= is_default;
            out.push(AudioDeviceInfo {
                is_default,
                label: linux_devices::label(&name, desc.as_deref()),
                name,
            });
        }
    }
    let rank = |n: &str| {
        if SOUND_SERVER_PCMS.contains(&n) {
            0
        } else {
            1
        }
    };
    out.sort_by(|a, b| {
        rank(&a.name)
            .cmp(&rank(&b.name))
            .then_with(|| a.name.cmp(&b.name))
    });
    out
}

/// Desktop audio device list (see list_audio_devices for the JSON shape;
/// `name` is the selection/persistence key, `label` the display name).
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
/// capture stream is restarted on the new device immediately; if that device
/// refuses to open, the system default is retried so capture stays up
/// instead of dying with the old stream already stopped. Returns 0 only
/// when even the default device failed.
#[no_mangle]
pub extern "C" fn ts_set_audio_input_device(name: *const c_char) -> u8 {
    let name = unsafe { cstr_to_string(name) };
    let was_running = crate::MIC_STREAM.lock().unwrap().0.is_some();
    *INPUT_DEVICE_NAME.lock().unwrap() = if name.is_empty() { None } else { Some(name.clone()) };
    if !was_running {
        return 1;
    }
    stop_mic_capture();
    if start_mic_capture() {
        return 1;
    }
    record_mic_error(format!(
        "input device \"{}\" unavailable; falling back to system default",
        name
    ));
    *INPUT_DEVICE_NAME.lock().unwrap() = None;
    if start_mic_capture() {
        return 1;
    }
    0
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

/// Edits server properties (`serveredit`). `args_json` is a
/// [crate::ServerEditArgs] (absent fields stay untouched, an empty password
/// clears it). The outcome arrives as a `perm_op` event carrying `token`.
/// Returns 1 when queued, 0 when not connected / bad arguments.
#[no_mangle]
pub extern "C" fn ts_server_edit(args_json: *const c_char, token: *const c_char) -> u8 {
    if args_json.is_null() || token.is_null() {
        return 0;
    }
    unsafe {
        let token = cstr_to_string(token);
        if token.is_empty() {
            return 0;
        }
        let args: crate::ServerEditArgs = match serde_json::from_str(&cstr_to_string(args_json)) {
            Ok(a) => a,
            Err(_) => return 0,
        };
        try_send_cmd(Command::ServerEdit { args, token }) as u8
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
#[allow(dead_code)] // superseded by the wire-flag extras in the channel handlers
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

/// Server property snapshot (from InitServer, refreshed on every book event
/// batch — see `refresh_from_book`). JSON `TsServerInfo`; used to prefill
/// the server-settings page. The password is never readable and has no
/// entry — only `has_password` (null while unknown).
#[no_mangle]
pub extern "C" fn ts_get_server_info() -> *mut c_char {
    let state = STATE.lock();
    if !state.connected {
        return to_c_str("{}".to_string());
    }
    let info = crate::TsServerInfo {
        name: state.server_name.clone(),
        welcome_message: state.server_welcome_message.clone(),
        max_clients: state.server_max_clients,
        has_password: state.server_has_password,
    };
    to_c_str(serde_json::to_string(&info).unwrap_or_else(|_| "{}".into()))
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

/// Redeem a privilege key (admin token) on the connected server via
/// `clientupdate client_default_token`. The outcome arrives as a `perm_op`
/// event carrying `op_token`. Returns 1 when queued, 0 when not connected.
#[no_mangle]
pub extern "C" fn ts_use_privilege_key(token: *const c_char, op_token: *const c_char) -> u8 {
    let token = unsafe { read_cstr(token) };
    let op_token = unsafe { read_cstr(op_token) };
    if try_send_cmd(Command::UsePrivilegeKey { token, op_token }) {
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
/// The univox helper resolves the avatar's remote path
/// (`/avatar_<base64HashClientUID>`, channel-0 storage) from the uid
/// internally. Returns the task id (>0) for progress/cancel tracking, 0 when
/// not queued (not connected, malformed uid).
#[no_mangle]
pub extern "C" fn ts_download_avatar(uid: *const c_char, dest: *const c_char) -> u32 {
    if !ft_ready() || dest.is_null() {
        return 0;
    }
    let uid = unsafe { cstr_to_string(uid) };
    if uid.is_empty() {
        return 0;
    }
    let dest = unsafe { cstr_to_string(dest) };
    if dest.is_empty() {
        return 0;
    }
    let task_id = ft_new_task(FT_KIND_DOWNLOAD, "avatar".to_string(), dest.clone(), 0);
    ft_push_started(task_id);
    let Some(session) = crate::CONNECTION_STASH.lock().clone() else {
        crate::finish_ft_task(task_id, false, Some("event loop unavailable".into()));
        return task_id;
    };
    RUNTIME.spawn(async move {
        match session.download_avatar_by_uid(&uid).await {
            Ok(Some(bytes)) => {
                let written = (|| -> std::io::Result<usize> {
                    if let Some(parent) = std::path::Path::new(&dest).parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    std::fs::write(&dest, &bytes)?;
                    Ok(bytes.len())
                })();
                match written {
                    Ok(n) => {
                        if let Some(t) = FT_TASKS.get(&task_id) {
                            t.total.store(n as u64, Ordering::Relaxed);
                            t.done.store(n as u64, Ordering::Relaxed);
                        }
                        crate::finish_ft_task(task_id, true, None);
                    }
                    Err(e) => crate::finish_ft_task(task_id, false, Some(format!("{e}"))),
                }
            }
            Ok(None) => crate::finish_ft_task(task_id, false, Some("no avatar set".into())),
            Err(e) => crate::finish_ft_task(task_id, false, Some(error_text(&e))),
        }
    });
    task_id
}

/// Starts uploading the local file `src` as our own avatar. univox writes
/// the file into the channel-0 storage under `/avatar_<hash>` AND announces
/// the MD5 via clientupdate (`client_flag_avatar`) — without the announce
/// the new avatar never becomes visible to other clients. Returns the task
/// id (>0) for progress/cancel tracking, 0 when not queued (not connected,
/// missing source file).
#[no_mangle]
pub extern "C" fn ts_upload_avatar(uid: *const c_char, src: *const c_char) -> u32 {
    let _ = uid; // univox announces under the session's own identity
    if !ft_ready() || src.is_null() {
        return 0;
    }
    let src = unsafe { cstr_to_string(src) };
    let meta = std::fs::metadata(&src);
    // Only existing local files are accepted.
    if src.is_empty() || meta.as_ref().map(|m| !m.is_file()).unwrap_or(true) {
        return 0;
    }
    let total = meta.map(|m| m.len()).unwrap_or(0);
    let task_id = ft_new_task(FT_KIND_UPLOAD, "avatar".to_string(), src.clone(), total);
    ft_push_started(task_id);
    let Some(session) = crate::CONNECTION_STASH.lock().clone() else {
        crate::finish_ft_task(task_id, false, Some("event loop unavailable".into()));
        return task_id;
    };
    RUNTIME.spawn(async move {
        match std::fs::read(&src) {
            Ok(data) => match session.upload_avatar(&data).await {
                Ok(()) => {
                    if let Some(t) = FT_TASKS.get(&task_id) {
                        t.done.store(data.len() as u64, Ordering::Relaxed);
                    }
                    crate::finish_ft_task(task_id, true, None);
                }
                Err(e) => crate::finish_ft_task(task_id, false, Some(error_text(&e))),
            },
            Err(e) => crate::finish_ft_task(task_id, false, Some(format!("{e}"))),
        }
    });
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

/// Clears our own avatar: announces an EMPTY `client_flag_avatar` (the
/// server broadcasts "no avatar" and every client drops the image) and
/// best-effort removes the stored `/avatar_<hash>` file from the channel-0
/// storage. The Dart caller receives the server's real answer for the
/// announce via the `perm_op` event for `token`; the file removal is not
/// tracked (an orphan is harmless and overwritten by the next upload).
/// Returns 1 when queued, 0 when not connected / malformed uid / token.
#[no_mangle]
pub extern "C" fn ts_delete_avatar(uid: *const c_char, token: *const c_char) -> u8 {
    if !ft_ready() || token.is_null() {
        return 0;
    }
    let uid = unsafe { cstr_to_string(uid) };
    if uid.is_empty() {
        return 0;
    }
    let token = unsafe { cstr_to_string(token) };
    if token.is_empty() {
        return 0;
    }
    let Some(session) = crate::CONNECTION_STASH.lock().clone() else {
        return 0;
    };
    RUNTIME.spawn(async move {
        // Resolve the stored avatar path: uid → database id → clientinfo's
        // base64HashClientUID → /avatar_<hash>.
        let path = (|| async {
            let dbid = session.dbid_from_uid(&uid).await.ok().flatten()?;
            let info = session.client_db_info(&dbid).await.ok()?;
            let hash = info.get("client_base64HashClientUID")?.to_string();
            Some(univox_ts3::avatar_path(&hash))
        })()
        .await;
        let Some(path) = path else {
            push_perm_op(&token, false, Some("cannot resolve avatar path".into()));
            return;
        };
        push_diag(&format!("avatar delete {}: {}", token, path));
        // 1. Announce "no avatar" (tracked so Dart sees the server answer).
        let result = session
            .exec(Ts3Command::new("clientupdate").param("client_flag_avatar", ""))
            .await;
        push_perm_op(&token, result.is_ok(), result.as_ref().err().map(error_text));
        // 2. Best-effort removal — not tracked.
        let _ = session
            .delete_file(&ChannelId::from_u64(0), &path, None)
            .await;
    });
    1
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
/// float32, 1/2 channels — anything else is rejected without touching the
/// currently active sample; only parse_wav_pcm's allocation guard bounds the
/// length, there is no content-duration policy).
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

// ─── Recording (see recording.rs) ───────────────────────────────────

/// Arms the recorder for a new connection and sets the backtrack window.
/// Dart calls this right after `connected`; resets any leftover state.
/// `backtrack_secs` is clamped to 10..=3600.
#[no_mangle]
pub extern "C" fn ts_set_recording_config(backtrack_secs: u32, work_dir: *const c_char) -> u8 {
    let dir = unsafe { cstr_to_string(work_dir) };
    recording::set_config(backtrack_secs, dir);
    1
}

/// Start a continuous recording. With `include_backtrack` != 0 the recording
/// opens with the buffered backtrack window. Returns 1 on success, 0 if
/// already running.
#[no_mangle]
pub extern "C" fn ts_start_recording(include_backtrack: u8) -> u8 {
    recording::start_recording(include_backtrack != 0) as u8
}

/// Stop the continuous recording and pin its buffer until saved/discarded.
/// Returns 1 on success, 0 if nothing was recording.
#[no_mangle]
pub extern "C" fn ts_stop_recording() -> u8 {
    recording::stop_recording() as u8
}

/// Status snapshot for the save dialog as JSON:
/// `{recording, hold, backtrack_secs, available_secs, recording_secs,
///   tracks: [{client_id, uid, name}]}` (client_id 0 = our own mic track).
#[no_mangle]
pub extern "C" fn ts_get_recording_status() -> *mut c_char {
    to_c_str(recording::status_json())
}

/// Save a recording window async. `window_ms == 0` saves the whole stopped
/// recording, otherwise the trailing window. `mode`: 0 = one mixed file,
/// 1 = one file per user. `dir` is the (Dart-created) output directory.
/// Returns 1 when the save job was started, 0 when busy or there is no data;
/// the result arrives as a `recording_saved` / `recording_save_failed` event.
#[no_mangle]
pub extern "C" fn ts_save_recording(window_ms: u32, mode: u8, dir: *const c_char) -> u8 {
    let dir = unsafe { cstr_to_string(dir) };
    recording::request_save(window_ms, mode, dir) as u8
}

/// Drop the pinned recording buffer without saving (dialog cancelled).
#[no_mangle]
pub extern "C" fn ts_discard_recording() -> u8 {
    recording::discard();
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── Linux device list (hint enumeration helpers) ────────────────

    #[cfg(target_os = "linux")]
    mod linux_list {
        use std::collections::HashSet;

        use super::super::linux_devices;

        fn defaults(cards: &[&str]) -> HashSet<String> {
            cards.iter().map(|c| c.to_string()).collect()
        }

        #[test]
        fn card_of_parses_alias_names() {
            assert_eq!(linux_devices::card_of("default:CARD=III"), Some("III"));
            assert_eq!(linux_devices::card_of("sysdefault:CARD=PCH"), Some("PCH"));
            assert_eq!(
                linux_devices::card_of("hdmi:CARD=NVidia,DEV=1"),
                Some("NVidia")
            );
            assert_eq!(linux_devices::card_of("pipewire"), None);
        }

        #[test]
        fn junk_and_converter_plugins_are_hidden() {
            for name in ["null", "lavrate", "samplerate", "speexrate", "jack", "oss"] {
                assert!(
                    !linux_devices::visible(name, true, &defaults(&[])),
                    "{} should be hidden",
                    name
                );
            }
            assert!(!linux_devices::visible("usbstream:CARD=III", false, &defaults(&[])));
        }

        #[test]
        fn sysdefault_hidden_only_when_default_exists_for_same_card() {
            let cards = defaults(&["III"]);
            assert!(!linux_devices::visible("sysdefault:CARD=III", true, &cards));
            assert!(
                linux_devices::visible("sysdefault:CARD=PCH", true, &cards),
                "other cards keep sysdefault when no default:CARD entry exists"
            );
        }

        #[test]
        fn channel_layout_aliases_hidden_but_digital_outputs_kept_for_output() {
            let none = defaults(&[]);
            for name in [
                "front:CARD=PCH,DEV=0",
                "surround51:CARD=PCH,DEV=0",
                "surround71:CARD=PCH,DEV=0",
            ] {
                assert!(!linux_devices::visible(name, true, &none));
                assert!(!linux_devices::visible(name, false, &none));
            }
            assert!(linux_devices::visible("hdmi:CARD=NVidia,DEV=0", false, &none));
            assert!(linux_devices::visible("iec958:CARD=PCH,DEV=0", false, &none));
            assert!(!linux_devices::visible("hdmi:CARD=NVidia,DEV=0", true, &none));
            assert!(!linux_devices::visible("iec958:CARD=PCH,DEV=0", true, &none));
            assert!(linux_devices::visible("default:CARD=III", true, &none));
            assert!(linux_devices::visible("default:CARD=III", false, &none));
        }

        #[test]
        fn label_prefers_desc_first_line_and_names_sound_servers() {
            assert_eq!(linux_devices::label("pipewire", None), "PipeWire");
            assert_eq!(linux_devices::label("pulse", None), "PulseAudio");
            assert_eq!(
                linux_devices::label(
                    "default:CARD=III",
                    Some("HyperX Cloud III USB\nDefault Audio Device")
                ),
                "HyperX Cloud III USB"
            );
            assert_eq!(linux_devices::label("default:CARD=X", None), "default:CARD=X");
            assert_eq!(
                linux_devices::label("default:CARD=X", Some("  \nmore")),
                "default:CARD=X",
                "blank DESC falls back to the PCM name"
            );
        }
    }

    // ─── Mic error record ───────────────────────────────────────────

    #[test]
    fn last_audio_error_roundtrip_via_ffi() {
        clear_mic_error();
        assert_eq!(unsafe { cstr_to_string(ts_get_last_audio_error()) }, "");
        record_mic_error("build_input_stream failed: boom".into());
        assert_eq!(
            unsafe { cstr_to_string(ts_get_last_audio_error()) },
            "build_input_stream failed: boom"
        );
        clear_mic_error();
        assert_eq!(unsafe { cstr_to_string(ts_get_last_audio_error()) }, "");
    }

    #[test]
    fn mic_restart_flag_survives_until_cleared() {
        MIC_RESTART_REQUESTED.store(false, Ordering::Relaxed);
        assert!(!MIC_RESTART_REQUESTED.swap(true, Ordering::Relaxed));
        // The maintenance task's swap(false) must be the only reader that
        // observes the pending request.
        assert!(MIC_RESTART_REQUESTED.swap(false, Ordering::Relaxed));
        assert!(!MIC_RESTART_REQUESTED.load(Ordering::Relaxed));
    }

    // ─── Remote path parsing ────────────────────────────────────────

    #[test]
    fn normalizes_remote_paths() {
        assert_eq!(normalize_remote_path(""), "/");
        assert_eq!(normalize_remote_path("/"), "/");
        assert_eq!(normalize_remote_path("a/b"), "/a/b");
        assert_eq!(normalize_remote_path("//a//b/"), "/a/b");
        assert_eq!(normalize_remote_path("a//b//"), "/a/b");
        assert_eq!(normalize_remote_path("  /a/b/  "), "/a/b");
    }

    // ─── Sequence unwrap ────────────────────────────────────────────

    #[test]
    fn unwrap_seq_tracks_forward_and_wrap() {
        assert_eq!(unwrap_seq(100, 100), 100);
        assert_eq!(unwrap_seq(150, 100), 150);
        // seq just past 0 while base sits near the top of u16: forward wrap.
        assert_eq!(unwrap_seq(1, 65535), 65537);
        assert_eq!(unwrap_seq(0, 65533), 65536);
        // A small backward step is interpreted as a forward wrap too (the
        // 16-bit space rolled over between base and seq).
        assert_eq!(unwrap_seq(50, 100), 65_586);
        // Baseline use (base 0) is the identity for ordinary seqs.
        assert_eq!(unwrap_seq(0, 0), 0);
        assert_eq!(unwrap_seq(65535, 0), 65535);
        assert_eq!(unwrap_seq(40000, 0), 40000);
    }

    #[test]
    fn unwrap_seq_half_window_behind_maps_stale() {
        // seq exactly half a u16 window behind base lands 32768 behind base
        // in u32 space — the >1000-frame sanity check then discards it.
        let stale = unwrap_seq(32868, 100);
        assert_eq!(100u32.wrapping_sub(stale), 32768);
    }

    // ─── Positional gains ───────────────────────────────────────────

    #[test]
    fn nan_position_plays_centered() {
        assert_eq!(positional_gains(0.8, f32::NAN, 0.0), (0.8, 0.8));
        assert_eq!(positional_gains(0.8, 1.0, f32::NAN), (0.8, 0.8));
    }

    #[test]
    fn centered_position_matches_unpositioned_loudness() {
        assert_eq!(positional_gains(0.7, 0.0, 0.0), (0.7, 0.7));
        // Plain stereo cannot place front vs back — only distance matters.
        let front = positional_gains(1.0, 0.0, 3.0);
        let back = positional_gains(1.0, 0.0, -3.0);
        assert_eq!(front, back);
        // At the reference distance straight ahead both sides are halved.
        assert!((front.0 - 0.5).abs() < 1e-6);
        assert!((front.1 - 0.5).abs() < 1e-6);
    }

    #[test]
    fn distance_attenuates_and_pan_clamps() {
        // x = +3 m (the reference distance): full pan right, 0.5 attenuation.
        let (l, r) = positional_gains(1.0, 3.0, 0.0);
        assert!(l.abs() < 1e-6);
        assert!((r - 1.0).abs() < 1e-6);
        // Far right: pan clamps at the ±2 m boundary, attenuation keeps
        // falling with distance.
        let (l, r) = positional_gains(1.0, 10.0, 0.0);
        assert_eq!(l, 0.0);
        let atten = 1.0 / (1.0 + (10.0f32 / 3.0).powi(2));
        assert!((r - 2.0 * atten).abs() < 1e-6);
    }

    // ─── Output ring ────────────────────────────────────────────────

    #[test]
    fn out_ring_is_fifo() {
        let mut ring = OutRing::new();
        for i in 0..5u32 {
            ring.push([i as f32, 100.0 + i as f32]);
        }
        for i in 0..5u32 {
            assert_eq!(ring.pop(), [i as f32, 100.0 + i as f32]);
        }
    }

    #[test]
    fn out_ring_wraps_and_keeps_order() {
        let mut ring = OutRing::new();
        // Alternating push/pop walks head around the whole buffer (through
        // the compacting branch) twice.
        for i in 0..(2 * OUT_RING_CAP as u32) {
            ring.push([i as f32, 0.0]);
            assert_eq!(ring.pop(), [i as f32, 0.0]);
        }
    }

    #[test]
    fn out_ring_drops_oldest_when_full() {
        let mut ring = OutRing::new();
        let extra = 10u32;
        for i in 0..(OUT_RING_CAP as u32 + extra) {
            ring.push([i as f32, 0.0]);
        }
        for i in extra..(OUT_RING_CAP as u32 + extra) {
            assert_eq!(ring.pop(), [i as f32, 0.0]);
        }
    }

    // ─── Clock compression ──────────────────────────────────────────

    #[test]
    fn compression_eps_curve() {
        assert_eq!(compression_eps(0), 0.0);
        // One surplus frame is not enough to compress (that is the target
        // slack itself).
        assert_eq!(compression_eps(1), 0.0);
        assert!((compression_eps(2) - 0.002).abs() < 1e-12);
        // Capped at 1%.
        assert!((compression_eps(6) - 0.01).abs() < 1e-12);
        assert_eq!(compression_eps(1000), 0.01);
        // Monotonic.
        let mut prev = 0.0;
        for n in 0..20u32 {
            let eps = compression_eps(n);
            assert!(eps >= prev, "eps must not decrease at {} frames", n);
            prev = eps;
        }
    }

    // ─── Mic resampler ──────────────────────────────────────────────

    #[test]
    fn mic_resampler_48k_mono_passthrough() {
        let mut r = MicResampler::new(1, 48000);
        r.process(&[0.1, -0.2, 0.3]);
        assert_eq!(r.out, vec![0.1, -0.2, 0.3]);
    }

    #[test]
    fn mic_resampler_downmixes_stereo_at_48k() {
        // Binary-exact values so the average is bit-exact too.
        let mut r = MicResampler::new(2, 48000);
        r.process(&[0.25, 0.5, -0.5, 0.0]);
        assert_eq!(r.out, vec![0.375, -0.25]);
    }

    #[test]
    fn mic_resampler_empty_input_is_noop() {
        let mut r = MicResampler::new(1, 48000);
        r.process(&[]);
        assert!(r.out.is_empty());
        assert!(!r.started);
    }

    #[test]
    fn mic_resampler_44k1_chunked_matches_one_shot() {
        // A ~110 ms ramp at 44.1 kHz.
        let input: Vec<f32> = (0..4800).map(|i| i as f32 / 4800.0).collect();

        let mut one_shot = MicResampler::new(1, 44100);
        one_shot.process(&input);

        // Odd-size chunks force the phase/state carry across callbacks; the
        // arithmetic per sample is identical, so the output must be exactly
        // the same, not just approximately.
        let mut chunked = MicResampler::new(1, 44100);
        for chunk in input.chunks(7) {
            chunked.process(chunk);
        }

        assert_eq!(one_shot.out, chunked.out);
        // The first output sample IS the first input sample.
        assert_eq!(one_shot.out[0], input[0]);
        // Output count lands on n × 48000/44100 (±2 for the phase quantization).
        let expected = input.len() as f64 * 48000.0 / 44100.0;
        assert!(
            (one_shot.out.len() as f64 - expected).abs() <= 2.0,
            "output length {} vs expected {}",
            one_shot.out.len(),
            expected
        );
        // A rising ramp stays rising and inside [0, 1].
        assert!(one_shot.out.iter().all(|&s| (0.0..=1.0).contains(&s)));
        assert!(one_shot.out.windows(2).all(|w| w[0] <= w[1]));
    }

    // ─── Chat-log notice reason/kind mapping ────────────────────────

    /// Builds an enterview member whose extra carries the given raw row
    /// keys (the wire `reasonid` rides in the member's extra map).
    fn member_with_reasonid(reasonid: &str) -> univox_core::model::Member {
        let mut m = univox_core::model::Member::default();
        m.extra.insert("reasonid".into(), reasonid.into());
        m
    }

    #[test]
    fn enter_view_reason_maps_connect_moved_kicked() {
        // Wire reasonid values: 0 = connected, 1 = moved, 4 = kicked in.
        assert_eq!(enter_view_reason(&member_with_reasonid("0")), Some(0));
        assert_eq!(enter_view_reason(&member_with_reasonid("1")), Some(2));
        assert_eq!(enter_view_reason(&member_with_reasonid("4")), Some(3));
        // The initial subscription resync (2) and unknown values stay silent.
        assert_eq!(enter_view_reason(&member_with_reasonid("2")), None);
        assert_eq!(enter_view_reason(&member_with_reasonid("9")), None);
        assert_eq!(enter_view_reason(&univox_core::model::Member::default()), None);
    }

    #[test]
    fn leave_kind_maps_all_real_leaves() {
        use univox_core::model::MemberLeftReason;
        assert_eq!(leave_kind(&MemberLeftReason::Moved { by: None }), Some(1));
        assert_eq!(
            leave_kind(&MemberLeftReason::ChannelKicked { by: None, message: String::new() }),
            Some(2)
        );
        assert_eq!(leave_kind(&MemberLeftReason::Timeout), Some(3));
        assert_eq!(leave_kind(&MemberLeftReason::Left), Some(3));
        assert_eq!(leave_kind(&MemberLeftReason::Quit), Some(3));
        assert_eq!(
            leave_kind(&MemberLeftReason::ServerKicked { by: None, message: String::new() }),
            Some(4)
        );
        assert_eq!(
            leave_kind(&MemberLeftReason::Banned { by: None, message: String::new() }),
            Some(5)
        );
        // Not real leaves.
        assert_eq!(leave_kind(&MemberLeftReason::Unsubscribed), None);
        assert_eq!(leave_kind(&MemberLeftReason::ServerStop), None);
        assert_eq!(leave_kind(&MemberLeftReason::Other("reasonid=9".into())), None);
    }
}
