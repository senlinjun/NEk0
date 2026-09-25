mod api;
mod recording;

use crossbeam::queue::SegQueue;
use crossbeam::atomic::AtomicCell;
use dashmap::DashMap;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, Ordering};
use std::time::Instant;
use tokio::runtime::Runtime;

pub static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    Runtime::new().expect("Failed to create tokio runtime")
});

// ─── Command queue ───────────────────────────────────────────────────

#[derive(Debug)]
pub enum Command {
    SendMessage { target_mode: u8, target_cid: u64, message: String },
    /// Move a client (or ourselves) to another channel. `token: Some(..)`
    /// turns the request into a return-code-tracked operation whose server
    /// answer resolves the caller's `PermOp` future (used when moving OTHER
    /// clients from the permission sheet); `None` keeps the fire-and-forget
    /// behavior used when we move ourselves (channel-password flow).
    MoveChannel {
        client_id: u16,
        channel_id: u64,
        password: Option<String>,
        token: Option<String>,
    },
    SetMuted { input: bool, output: bool },
    SetAway { away: bool },
    SendPoke { client_id: u16, message: String },
    /// Kick a client from the current channel (from_server=false) or from
    /// the whole server (from_server=true). An empty reason is treated as a
    /// no-op by the event loop (protects against accidental kick attempts).
    /// A `token` (Some) upgrades the request to a return-code-tracked
    /// operation whose server answer resolves the caller's `PermOp` future.
    KickClient {
        client_id: u16,
        from_server: bool,
        reason: String,
        token: Option<String>,
    },
    /// Ban a client. `time_seconds == 0` means a permanent ban. A `token`
    /// (Some) upgrades the request to a tracked operation (see KickClient).
    BanClient {
        client_id: u16,
        time_seconds: u32,
        reason: String,
        token: Option<String>,
    },
    /// Create a channel (`channelcreate`). See [ChannelArgs] for the field
    /// semantics; `token` correlates the server's answer (see KickClient).
    ChannelCreate { args: ChannelArgs, token: String },
    /// Edit channel properties (`channeledit`). See [ChannelArgs].
    ChannelEdit { channel_id: u32, args: ChannelArgs, token: String },
    /// Edit server properties (`serveredit`). See [ServerEditArgs]; every
    /// field is optional — absent = leave untouched. `token` correlates the
    /// server's answer (see ChannelCreate).
    ServerEdit { args: ServerEditArgs, token: String },
    /// Delete a channel (`channeldelete`). `force` also removes a channel
    /// that still has clients in it (needs the force-delete permission).
    ChannelDelete {
        channel_id: u32,
        force: bool,
        token: String,
    },
    /// Move a channel to another parent (`channelmove`) — also re-orders
    /// within the same parent. `order` is the sibling id the channel comes
    /// after (0 = first; None = server default, appended at the end).
    ChannelMove {
        channel_id: u32,
        parent_id: u32,
        order: Option<u32>,
        token: String,
    },
    /// Add a client to a server group. `dbid` is the client's database id.
    /// `token` correlates the server's answer with the Dart caller.
    ServerGroupAddClient { sgid: u64, dbid: u64, token: String },
    /// Remove a client from a server group.
    ServerGroupDelClient { sgid: u64, dbid: u64, token: String },
    /// Set a client's channel group in a specific channel.
    /// Sent as a raw `channelgroupaddclient` command (the upstream
    /// tsdeclarations do not declare this message — see Command::ChannelGroupClear).
    ChannelGroupSet { cgid: u64, cid: u64, dbid: u64, token: String },
    /// Clear a client's channel group in a specific channel (raw
    /// `channelgroupdelclient`, also undeclared upstream).
    ChannelGroupClear { cid: u64, dbid: u64, token: String },
    /// Grant a channel-scoped permission to a client (`channelclientaddperm`).
    GrantChannelPerm { cid: u64, dbid: u64, permsid: String, value: i32, token: String },
    /// Revoke a channel-scoped permission from a client (`channelclientdelperm`).
    RevokeChannelPerm { cid: u64, dbid: u64, permsid: String, token: String },
    /// Grant a server-wide permission to a client (`clientaddperm`).
    GrantServerPerm { dbid: u64, permsid: String, value: i32, token: String },
    /// Revoke a server-wide permission from a client (`clientdelperm`).
    RevokeServerPerm { dbid: u64, permsid: String, token: String },
    /// Re-request `servergrouplist`/`channelgrouplist` (used by the group
    /// dialogs' retry when the lists never arrived).
    RefreshGroups,
    /// Request OUR OWN directly-assigned permission list (`clientpermlist`
    /// for our own database id). The answer fills `STATE.own_perms`.
    OwnPermList,
    /// Redeem a privilege key after connecting (`privilegekeyuse token=...`
    /// — the command behind the official client's "Use Privilege Key").
    /// `token` is the privilege key itself; `op_token` correlates the
    /// server's answer with the Dart caller (see KickClient).
    UsePrivilegeKey { token: String, op_token: String },
    Disconnect,
    SendAudio { data: Vec<f32> },
    // File transfer commands (see FtTask / FT_TASKS below). `cid` is the
    // channel whose file storage is addressed; remote paths start with '/',
    // passwords are plaintext (encoded per-command where the protocol needs
    // the hashed cpw form).
    FtList { cid: u64, path: String, password: Option<String>, token: String },
    FtCreateDir { cid: u64, dirname: String, password: Option<String>, token: String },
    FtDelete { cid: u64, names: Vec<String>, password: Option<String>, token: String },
    /// The task was pre-registered by the FFI call (`task_id`); assigning the
    /// protocol transfer id happens here once the request was sent out.
    FtDownload { cid: u64, path: String, password: Option<String>, task_id: u32 },
    FtUpload { cid: u64, path: String, password: Option<String>, task_id: u32 },
    /// Announce our new avatar (clientupdate `client_flag_avatar` = MD5 of the
    /// uploaded file). Queued by the transfer machinery after a successful
    /// avatar upload — the server does not infer the hash from the upload.
    SetAvatarHash { hash: String },
    /// Clear our own avatar: announce an EMPTY `client_flag_avatar` (tracked
    /// via `token` → PermOp so Dart gets the server's real answer) and
    /// best-effort remove the stored `/avatar_<uid>` file from the channel-0
    /// storage.
    DeleteAvatar { path: String, token: String },
}

// ─── File transfers (channel file management) ────────────────────────

/// Kind of an active transfer task (mirrors TransferKind in Dart).
pub const FT_KIND_DOWNLOAD: u8 = 0;
pub const FT_KIND_UPLOAD: u8 = 1;

pub struct FtTask {
    pub kind: u8,
    /// Display name of the transferred file (last path segment).
    pub name: String,
    /// Local absolute path: written for downloads, read for uploads.
    pub local_path: String,
    /// Total size in bytes. For downloads this is filled in when the server
    /// announces the size (FileDownload event); uploads know it upfront.
    pub total: std::sync::atomic::AtomicU64,
    /// Bytes written so far (atomically published for Dart progress).
    pub done: std::sync::atomic::AtomicU64,
    /// Cooperative cancel flag: set by ts_ft_cancel, polled by the worker.
    pub cancel: std::sync::Arc<AtomicBool>,
    /// The client-side transfer id used in ftinit* commands, so a
    /// StreamItem::FiletransferFailed can be attributed back to this task.
    pub client_ft_id: AtomicU16,
    /// For avatar uploads: the MD5 of the file content. Once the transfer is
    /// confirmed, it is announced via Command::SetAvatarHash so the server
    /// broadcasts the new avatar to every client.
    pub avatar_md5: Option<String>,
    /// Last progress event publish time — throttles events.
    pub last_event: Mutex<Option<Instant>>,
}

pub static FT_TASK_SEQ: AtomicU32 = AtomicU32::new(1);
pub static FT_TASKS: Lazy<DashMap<u32, std::sync::Arc<FtTask>>> = Lazy::new(DashMap::new);

/// Client-chosen transfer ids for ftinitdownload/ftinitupload. The vendored
/// library's counter is private, and its generated packets always write a
/// (possibly bare) `cpw` argument — ours must omit it, so we build those
/// packets ourselves. 0x4000+ keeps clear of anything the library assigns.
pub static FT_CLIENT_FT: AtomicU16 = AtomicU16::new(0x4000);

/// Maps the return_code of an ftinitdownload/ftinitupload to its task so a
/// rejection (the plain error frame) fails the task with a real reason.
pub static FT_TASK_BY_RC: Lazy<Mutex<HashMap<u16, u32>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// A pending directory listing: keyed by the return_code assigned when the
/// ftgetfilelist command was sent.
///
/// IMPORTANT: the server answers with the terminal error frame FIRST and
/// streams the notifyfilelist rows afterwards (observed live). The listing
/// is therefore complete only when BOTH the result frame and the
/// notifyfilelistfinished marker were seen.
pub struct PendingFtList {
    pub token: String,
    pub entries: Vec<TsFtEntry>,
    /// Sent time — used to prune requests the server never answered.
    pub created: std::time::Instant,
    /// Address of the listed directory — lets the finished marker (which
    /// carries no return_code) be matched back to this request.
    pub cid: u64,
    pub path: String,
    /// The trailing error frame arrived (result carried in `error`).
    pub result_seen: bool,
    pub result_ok: bool,
    pub result_error: Option<String>,
    /// The notifyfilelistfinished marker arrived.
    pub finished_seen: bool,
    /// Deferred finalize already scheduled (no duplicate timers).
    pub finalize_scheduled: bool,
}

/// An entry awaiting its trailing error frame for ftcreatedir/ftdeletefile.
/// Same contract as FT_LISTS: keyed by the return_code we assigned.
#[allow(dead_code)]
pub struct PendingFtOp {
    pub token: String,
}

pub static FT_OPS: Lazy<Mutex<HashMap<u16, PendingFtOp>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

pub static FT_LISTS: Lazy<Mutex<HashMap<u16, PendingFtList>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsFtEntry {
    pub name: String,
    pub size: u64,
    /// Modification time as unix seconds (-1 when unknown).
    pub datetime: i64,
    pub is_file: bool,
}

/// Publishes a finished/failed/canceled task and removes it from FT_TASKS.
/// No-op when the task is already gone (e.g. resolved by an earlier status).
pub fn finish_ft_task(task_id: u32, ok: bool, error: Option<String>) {
    if let Some((_, task)) = FT_TASKS.remove(&task_id) {
        let transferred = task.done.load(std::sync::atomic::Ordering::Relaxed);
        STATE.lock().pending_events.push_back(TsEvent::FtDone {
            task_id,
            ok,
            transferred,
            error,
        });
    }
}

pub static COMMAND_TX: Lazy<Mutex<Option<tokio::sync::mpsc::UnboundedSender<Command>>>> =
    Lazy::new(|| Mutex::new(None));

pub static CONNECTION_GENERATION: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));
pub static EVENT_LOOP_ALIVE: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
pub static SWIPE_DISCONNECT: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
/// Set when the cpal output stream should be rebuilt (device route change,
/// stream error, or explicit restart request from the Android side). The
/// maintenance task performs the rebuild on its 500ms tick.
pub static OUTPUT_RESTART_REQUESTED: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));
pub static CONNECTION_STASH: Lazy<Mutex<Option<tsclientlib::Connection>>> = Lazy::new(|| Mutex::new(None));
pub static IDENTITY_STASH: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// ─── Types for Dart ─────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "type")]
pub enum TsEvent {
    /// `welcome_message` / `hostmessage` are the server's preset texts from
    /// initserver; `hostmessage_mode` mirrors the server's hostmessage
    /// setting (0 = don't display, 1 = log/chat, 2 = modal, 3 = modal +
    /// quit) so Dart can decide whether the host message deserves a line.
    #[serde(rename = "connected")]
    Connected {
        server_name: String,
        client_id: u32,
        ask_for_privilegekey: bool,
        welcome_message: String,
        hostmessage: String,
        hostmessage_mode: u8,
    },
    #[serde(rename = "disconnected")]
    Disconnected { reason: String },
    /// `to_client_id` is the PM target (0 for channel/server messages): our
    /// own id when someone private-messages us, the other party's id for the
    /// server's echo of our own sent PMs — the piece that attributes an echo
    /// to the right conversation on the Dart side.
    #[serde(rename = "text_message")]
    TextMessage {
        from_client: String,
        from_client_id: u32,
        to_client_id: u32,
        target_mode: u8,
        message: String,
    },
    /// The server rejected a text-message send (tracked via return_code,
    /// see `TEXT_SENDS`) — e.g. missing `b_client_server_textmessage_send`.
    #[serde(rename = "send_failed")]
    SendFailed { error: String },
    #[serde(rename = "poke")]
    Poke { from_client: String, from_client_id: u32, message: String },
    #[serde(rename = "client_joined")]
    ClientJoined { client_id: u32, nickname: String, channel_id: u32 },
    #[serde(rename = "client_left")]
    ClientLeft { client_id: u32, nickname: String },
    /// Chat-log notice: a client entered OUR current channel. `reason`:
    /// 0 = connected to the server, 1 = switched in on their own,
    /// 2 = moved in by someone else, 3 = kicked into the channel.
    #[serde(rename = "client_enter_channel")]
    ClientEnterChannel { client_id: u32, nickname: String, reason: u8 },
    /// Chat-log notice: a client left OUR current channel. `kind`:
    /// 0 = left to another channel on their own, 1 = moved away by someone,
    /// 2 = kicked from the channel, 3 = disconnected / left the server,
    /// 4 = kicked from the server, 5 = banned. `invoker` names the admin
    /// for the kinds where one exists ('' otherwise).
    #[serde(rename = "client_leave_channel")]
    ClientLeaveChannel {
        client_id: u32,
        nickname: String,
        kind: u8,
        invoker: String,
    },
    /// Chat-log notice: our own client changed channel. `kind`:
    /// 0 = moved on our own, 1 = moved by someone else, 2 = kicked from
    /// the channel. `invoker` names the mover for kinds 1/2 ('' otherwise).
    #[serde(rename = "self_moved")]
    SelfMoved {
        to_channel_id: u32,
        to_channel_name: String,
        invoker: String,
        kind: u8,
    },
    #[serde(rename = "channels_updated")]
    ChannelsUpdated {},
    #[serde(rename = "diag")]
    Diag { msg: String },
    #[serde(rename = "move_rejected")]
    MoveRejected { channel_id: u32 },
    #[serde(rename = "error")]
    Error { message: String },
    #[serde(rename = "ft_op")]
    FtOp { token: String, ok: bool, error: Option<String> },
    #[serde(rename = "ft_listing")]
    FtListing { token: String, entries: Vec<TsFtEntry>, error: Option<String> },
    #[serde(rename = "ft_started")]
    FtStarted { task_id: u32, kind: u8, name: String, total: u64 },
    #[serde(rename = "ft_progress")]
    FtProgress { task_id: u32, transferred: u64 },
    #[serde(rename = "ft_done")]
    FtDone { task_id: u32, ok: bool, transferred: u64, error: Option<String> },
    /// Result of a permission-management command (server group add/remove,
    /// channel group set/clear, channel perm grant/revoke). Correlates back
    /// to the caller via `token`; `error` carries the server's rejection text.
    #[serde(rename = "perm_op")]
    PermOp { token: String, ok: bool, error: Option<String> },
    /// Recording saved: `files` are the WAVs Rust wrote into the temp
    /// directory (Dart moves them into Downloads). `reason` is "manual" or
    /// "disconnected" (auto-save when a recording was active at teardown).
    #[serde(rename = "recording_saved")]
    RecordingSaved { reason: String, files: Vec<TsRecordingFile> },
    #[serde(rename = "recording_save_failed")]
    RecordingSaveFailed { reason: String, error: String },
    /// Continuous recording started/stopped (also fired on the 4h cap).
    #[serde(rename = "recording_state")]
    RecordingState { recording: bool },
}

/// One WAV file produced by the recorder (see recording.rs).
#[derive(Debug, Clone, serde::Serialize)]
pub struct TsRecordingFile {
    /// Absolute path of the temp file Rust wrote; Dart moves it.
    pub path: String,
    /// Client id the track belongs to; 0 for the mixed file and for our own
    /// microphone track.
    pub client_id: u32,
    pub uid: Option<String>,
    /// Display nickname of the track (empty for the mixed file).
    pub name: String,
    /// true = the single mixed file, false = one per-user track.
    pub mixed: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsChannel {
    pub id: u32,
    pub name: String,
    pub parent_id: u32,
    pub topic: String,
    pub has_password: bool,
    pub client_count: u32,
    pub order: u32,
    /// The server's default channel. A channel kick moves its target here,
    /// so a client already sitting in the default channel can never be
    /// kicked from their channel — the UI hides that action for them.
    pub is_default: bool,
    /// Raw `ChannelPermissionHint` bits (see tsclientlib::ChannelPermissionHint):
    /// JOIN=1, MODIFY=2, FORCE_DELETE=4, DELETE=8, SUBSCRIBE=16,
    /// VIEW_DESCRIPTION=32, FILE_UPLOAD=64, FILE_DOWNLOAD=128, FILE_DELETE=256,
    /// FILE_RENAME=512, FILE_BROWSE=1024, FILE_DIRECTORY_CREATE=2048,
    /// MODIFY_PERMISSIONS=4096. 0 while the server has not sent hints yet.
    pub permission_hints: u64,
    /// i_channel_needed_talk_power (0 when the channel does not restrict talk).
    pub needed_talk_power: i32,
    /// channel_maxclients (-1 when the server reported unlimited/inherited).
    pub max_clients: i32,
    /// channel_flag_permanent / channel_flag_semi_permanent (a channel with
    /// both false is temporary).
    pub is_permanent: bool,
    pub is_semi_permanent: bool,
    /// channel_description ('' until the server tells us — channellist does
    /// not carry descriptions; they arrive via channeledited broadcasts).
    pub description: String,
    /// channel_maxfamilyclients (-1 inherited/unknown, 0 unlimited, >0 limit).
    pub max_family_clients: i32,
    /// channel_delete_delay in whole seconds (0 = delete as soon as empty).
    pub delete_delay: i64,
}

/// Body of the `args_json` parameter of `ts_channel_create` /
/// `ts_channel_edit` (all fields optional except where noted). On edit, an
/// absent field means "leave untouched"; on create it means "server default"
/// (the Dart form always sends the full intended state for create).
#[derive(Debug, Default, serde::Deserialize)]
pub struct ChannelArgs {
    /// Create only: the parent channel (0 = top level).
    #[serde(default)]
    pub parent_id: Option<u32>,
    /// Create: required. Edit: absent = unchanged.
    #[serde(default)]
    pub name: Option<String>,
    /// None = untouched (edit) / none (create); Some("") = clear.
    #[serde(default)]
    pub topic: Option<String>,
    /// None = untouched (edit) / none (create); Some("") = clear.
    #[serde(default)]
    pub password: Option<String>,
    /// Same tri-state as [ChannelArgs::topic].
    #[serde(default)]
    pub description: Option<String>,
    /// -1 inherited, 0 unlimited, >0 limit; None = untouched (edit).
    #[serde(default)]
    pub max_family_clients: Option<i32>,
    /// 0 unlimited, >0 limit; None = untouched (edit).
    #[serde(default)]
    pub max_clients: Option<i32>,
    /// The form always sends these (unchanged values are server-side no-ops).
    #[serde(default)]
    pub is_permanent: Option<bool>,
    #[serde(default)]
    pub is_semi_permanent: Option<bool>,
    #[serde(default)]
    pub is_default: Option<bool>,
    /// Seconds an empty temporary channel lingers before deletion.
    #[serde(default)]
    pub delete_delay: Option<i64>,
    /// Edit only — `channelcreate` rejects channel_needed_talk_power.
    #[serde(default)]
    pub needed_talk_power: Option<i32>,
    /// Edit only: the sibling id this channel comes after (0 = first).
    #[serde(default)]
    pub order: Option<u32>,
}

/// Body of the `args_json` parameter of `ts_server_edit`. Every field is
/// optional: an absent field leaves the server property untouched.
#[derive(Debug, Default, serde::Deserialize)]
pub struct ServerEditArgs {
    #[serde(default)]
    pub name: Option<String>,
    /// None = untouched; Some("") = clear; Some(p) = set (hashed like the
    /// channel password, see [ChannelArgs::password]).
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub max_clients: Option<u16>,
    #[serde(default)]
    pub welcome_message: Option<String>,
}

/// Server property snapshot served by `ts_get_server_info` for the
/// server-settings page prefill (see [TsConnection] fields it is built
/// from). The password itself is never readable — only whether one is set
/// (null while the server has not sent the optional data block).
#[derive(Debug, Clone, serde::Serialize)]
pub struct TsServerInfo {
    pub name: String,
    pub welcome_message: String,
    pub max_clients: Option<u16>,
    pub has_password: Option<bool>,
}

/// A server group (from the book's `server_groups` map, which is populated
/// by `servergrouplist` — requested by us on connect).
#[derive(Debug, Clone, serde::Serialize)]
pub struct TsServerGroup {
    pub id: u64,
    pub name: String,
    pub is_permanent: bool,
    pub needed_member_add_power: i32,
    pub needed_member_remove_power: Option<i32>,
    /// Higher = more privileged group (used by the UI to pick the client's
    /// primary server-group identity). 0 for the default/sorted-lowest groups.
    pub sort_id: i32,
}

/// A channel group (from the book's `channel_groups` map).
#[derive(Debug, Clone, serde::Serialize)]
pub struct TsChannelGroup {
    pub id: u64,
    pub name: String,
    pub is_permanent: bool,
    pub needed_member_add_power: i32,
    pub needed_member_remove_power: Option<i32>,
    /// Group sort priority (server-defined; higher = more privileged).
    pub sort_id: i32,
}

/// One permission entry of OUR OWN client (from a `clientpermlist` request).
/// Only directly-assigned permissions are returned — inherited/group values
/// are NOT included, so this is a low-threshold hint, not an authorization
/// source for individual actions.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TsPerm {
    pub name: String,
    pub value: i32,
    pub negated: bool,
    pub skip: bool,
}

/// Maps the return_code of a permission-management command to the token the
/// Dart caller supplied, so the `MessageResult` handler can resolve it into a
/// `PermOp` event (same pattern as `FT_OPS`).
pub static PERM_OPS: Lazy<Mutex<HashMap<u16, String>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Return_codes of in-flight text-message sends (`send_with_result`). A
/// matching `MessageResult` with an error resolves into a `SendFailed` event
/// so the UI can tell the user the message was rejected (e.g. missing
/// `b_client_server_textmessage_send`) instead of it silently vanishing.
pub static TEXT_SENDS: Lazy<Mutex<HashSet<u16>>> =
    Lazy::new(|| Mutex::new(HashSet::new()));

#[derive(Debug, Clone, serde::Serialize)]
pub struct TsClient {
    pub id: u32,
    pub nickname: String,
    pub channel_id: u32,
    pub away: bool,
    pub input_muted: bool,
    pub output_muted: bool,
    pub is_talking: bool,
    pub volume: f32,
    pub uid: Option<String>,
    /// MD5 hash of the client's avatar, pushed by the server
    /// (`client_flag_avatar`). `None` = the client has no avatar set. Also
    /// the cache key on the Dart side (content-addressed).
    pub avatar_hash: Option<String>,
    /// The client's database id (cldbid) used by group/permission commands.
    /// 0 while the server has not announced it yet.
    pub database_id: u64,
    /// 0 = normal client, 1 = server query, 2 = server query with admin.
    pub client_type: u8,
    pub is_channel_commander: bool,
    pub is_recording: bool,
    pub is_priority_speaker: bool,
    /// False while the client's talk power is below the channel's
    /// needed-talk-power (the client cannot speak there).
    pub talk_power_granted: bool,
    /// i_client_talk_power of this client.
    pub talk_power: i32,
    /// Raw `ClientPermissionHint` bits (see tsclientlib::ClientPermissionHint):
    /// KICK_SERVER=1, KICK_CHANNEL=2, BAN=4, MOVE_CLIENT=8, PRIVATE_MESSAGE=16,
    /// POKE=32, WHISPER=64, COMPLAIN=128, MODIFY_PERMISSIONS=256.
    /// This is what WE may do to THIS client. 0 while no hints arrived yet.
    pub permission_hints: u64,
    pub server_groups: Vec<u64>,
    /// Names of the client's server groups, resolved from the book (used for
    /// tooltips; may be empty when the group data is unavailable).
    pub server_group_names: Vec<String>,
    pub channel_group: u32,
    /// 2D position relative to us in meters (+x = right, +y = forward).
    /// None = no position set → centered playback.
    pub pos_x: Option<f32>,
    pub pos_y: Option<f32>,
}

// ─── Per-client lock-free jitter buffer ──────────────────────────────

/// Number of ring slots per client jitter buffer. 64 slots = 1.28s window at
/// 20ms/frame. Keep it a power of two: ring index is `seq % JITTER_SLOTS`.
pub const JITTER_SLOTS: usize = 64;

/// Lock-free per-client jitter buffer with 64 slots (1.28s window at 20ms/frame).
/// Writer: the connection event loop (audio packets are decoded inline there).
/// Reader: the cpal output callback.
pub struct ClientJitterBuffer {
    /// Circular array of frame slots. AtomicCell swap provides lock-free read/write.
    pub slots: [AtomicCell<Option<Vec<i16>>>; JITTER_SLOTS],
    /// Sequence number of the most recently written frame (unwrapped to u32 space).
    pub write_seq: AtomicU32,
    /// Packed mapping base: `(base_seq as u64) << 32 | base_slot`. Read and
    /// written as ONE atomic so the reader never observes a mismatched pair
    /// (e.g. a new base_seq with the previous base_slot) during a rebase.
    /// - base_seq (high 32 bits): first sequence number of the current mapping.
    /// - base_slot (low 32 bits): global play slot at which base_seq plays.
    ///   Play slots advance at 50/s; 2^32 slots ≈ 55 years, never exceeded
    ///   within one buffer lifetime (buffers are cleared on stream restart).
    pub base_pair: AtomicU64,
    /// Monotonic timestamp of last received packet. None = never received. Used for cleanup.
    pub last_packet: AtomicCell<Option<Instant>>,
    /// Lock-free frame pool — callback pushes used frames, decoder pops them. No contention.
    pub frame_pool: SegQueue<Vec<i16>>,
    /// Linear gain as f32::to_bits, applied as mixing weight in the audio callback.
    pub volume: AtomicU32,
    /// 2D position of this client relative to us (meters; +x = right,
    /// +y = forward), stored as f32::to_bits. NaN bits = no position set →
    /// centered playback. Written by ts_set_client_position, read by the
    /// audio callback.
    pub pos_x: AtomicU32,
    pub pos_y: AtomicU32,
    /// Mirror of this client's adaptive playout lead in frames (see
    /// [JitterStats]), refreshed on every (re-)anchor. Read by the audio
    /// callback through the lock-free snapshot, so the surplus metric below
    /// never has to touch the JITTER_STATS map from the audio thread.
    pub target_frames: AtomicU32,
}

impl ClientJitterBuffer {
    pub fn new() -> Self {
        const NONE: AtomicCell<Option<Vec<i16>>> =
            AtomicCell::new(None);
        Self {
            slots: [NONE; JITTER_SLOTS],
            write_seq: AtomicU32::new(0),
            base_pair: AtomicU64::new(0),
            last_packet: AtomicCell::new(None),
            frame_pool: SegQueue::new(),
            volume: AtomicU32::new(f32::to_bits(1.0)),
            pos_x: AtomicU32::new(f32::to_bits(f32::NAN)),
            pos_y: AtomicU32::new(f32::to_bits(f32::NAN)),
            target_frames: AtomicU32::new(TARGET_FRAMES_INIT),
        }
    }
}

// ─── Adaptive playout target ────────────────────────────────────────

/// One frame of the internal mix clock: 960 samples at 48 kHz = 20 ms.
pub const FRAME_MS: u64 = 20;

/// Playout lead used for a speaker nothing has been learned about yet. Kept
/// at the historical fixed value: a cold start stays conservative and the
/// stream walks down from here once measurements exist.
pub const TARGET_FRAMES_INIT: u32 = 6; // 120 ms
/// Shallowest lead the adaptation may reach. One frame of lead plus one frame
/// of callback granularity still leaves room for late arrivals, and going
/// below this trades gaps for latency.
pub const TARGET_FRAMES_FLOOR: u32 = 3; // 60 ms
/// Deepest lead the adaptation may reach before it stops reacting to jitter.
pub const TARGET_FRAMES_CEIL: u32 = 12; // 240 ms
/// Master switch: false restores the fixed `TARGET_FRAMES_INIT` behavior.
pub const ADAPTIVE_JITTER: bool = true;
/// Lead kept on top of the shallowest margin ever measured (one frame).
const MARGIN_SAFETY_MS: u64 = FRAME_MS;
/// The measured minimum rises by `MARGIN_DECAY_STEP_MS` every
/// `MARGIN_DECAY_MS` of quiet, so one lucky packet cannot pin the target at
/// the floor; it also keeps a late packet's evidence alive for a while.
const MARGIN_DECAY_MS: u64 = 10_000;
const MARGIN_DECAY_STEP_MS: u32 = 5;
/// Margins beyond this are a stalled clock reference, not network jitter.
const MARGIN_MAX_MS: u32 = 2_000;
/// "No margin measured yet" marker for [JitterStats::min_margin_ms].
pub const MARGIN_NONE: u32 = u32::MAX;
/// Late arrivals within one growth window before the lead is extended.
/// Two in a row is enough evidence; the cooldown keeps a bursty link from
/// ratcheting the lead up frame by frame without pause.
const GROW_LATE_STREAK: u64 = 2;
/// Cooldowns between target changes. Growth must be prompt (a late packet was
/// already dropped); shrinkage waits so a stretch of clean audio has to pass
/// before the buffer is shaved again.
const GROW_COOLDOWN_MS: u64 = 2_000;
const SHRINK_COOLDOWN_MS: u64 = 5_000;

/// Adaptive playout state for one remote speaker.
///
/// The playout lead is a trade: every frame of it is 20 ms of delay, and it
/// buys tolerance for packets that arrive late. It is anchored when a stream
/// starts (first packet of a connection, or of a burst after a gap) and can
/// only be re-anchored at such a moment without cutting audio — during
/// continuous audio a shorter lead would skip frames that are already
/// buffered and about to play.
///
/// Keyed by client id in [JITTER_STATS] and deliberately *not* torn down with
/// the audio buffers after 10 s of silence: the learned profile is what makes
/// the next burst start at the right depth instead of re-learning the network.
pub struct JitterStats {
    /// Current playout lead in frames of 20 ms.
    pub target_frames: AtomicU32,
    /// Decaying minimum of the measured arrival margin, in ms: how long the
    /// worst packet still waited before its play slot. Milliseconds of that
    /// wait that no packet ever needs are lead that buys nothing but delay.
    /// See [JitterStats::observe_margin] for why a late packet pins it to 0.
    pub min_margin_ms: AtomicU32,
    /// Timestamp (ms, [now_ms] epoch) of the last `min_margin_ms` update,
    /// used as the decay anchor.
    pub min_margin_stamp_ms: AtomicU64,
    /// Timestamp of the last target change, per direction.
    pub last_grow_ms: AtomicU64,
    pub last_shrink_ms: AtomicU64,
    /// Late arrivals since the last growth step, and over the lifetime of
    /// this entry (diagnostics).
    pub late_streak: AtomicU64,
    pub late_total: AtomicU64,
    /// Sequence jumps in the arrival stream: packets lost or never sent.
    pub gap_total: AtomicU64,
}

impl Default for JitterStats {
    fn default() -> Self {
        Self {
            target_frames: AtomicU32::new(TARGET_FRAMES_INIT),
            min_margin_ms: AtomicU32::new(MARGIN_NONE),
            min_margin_stamp_ms: AtomicU64::new(0),
            last_grow_ms: AtomicU64::new(0),
            last_shrink_ms: AtomicU64::new(0),
            late_streak: AtomicU64::new(0),
            late_total: AtomicU64::new(0),
            gap_total: AtomicU64::new(0),
        }
    }
}

impl JitterStats {
    /// Current playout lead in frames.
    pub fn target(&self) -> u32 {
        self.target_frames
            .load(Ordering::Relaxed)
            .clamp(TARGET_FRAMES_FLOOR, TARGET_FRAMES_CEIL)
    }

    /// Fold one packet's arrival margin into the adaptive state.
    ///
    /// `margin_ms` is how long the packet waits (in wall-clock terms) before
    /// the slot it plays in. Its running minimum says how much deeper than
    /// necessary the current lead was for this client's network — that much
    /// lead only adds delay. A packet that arrives *after* its slot (negative
    /// margin) is the opposite signal: the buffer was too shallow, the packet
    /// was dropped, and the lead must grow. Such a sample also pins the stored
    /// minimum to 0, which is what stops the target from shrinking again until
    /// the decay has lifted it — the hysteresis between the two directions.
    ///
    /// Returns true when the caller must give this client's stream one more
    /// frame of lead.
    pub fn observe_margin(&self, margin_ms: i64, now_ms: u64) -> bool {
        if !ADAPTIVE_JITTER {
            return false;
        }
        let mut grow = false;
        if margin_ms < 0 {
            self.late_total.fetch_add(1, Ordering::Relaxed);
            let streak = self.late_streak.fetch_add(1, Ordering::Relaxed) + 1;
            if streak >= GROW_LATE_STREAK
                && now_ms.saturating_sub(self.last_grow_ms.load(Ordering::Relaxed))
                    >= GROW_COOLDOWN_MS
            {
                let next = (self.target() + 1).min(TARGET_FRAMES_CEIL);
                self.target_frames.store(next, Ordering::Relaxed);
                self.last_grow_ms.store(now_ms, Ordering::Relaxed);
                self.late_streak.store(0, Ordering::Relaxed);
                grow = true;
            }
        }
        // Decay the stored minimum to `now`, then fold this sample in.
        let stored = self.min_margin_ms.load(Ordering::Relaxed);
        let floor = if stored == MARGIN_NONE {
            MARGIN_NONE
        } else {
            let stamp = self.min_margin_stamp_ms.load(Ordering::Relaxed);
            let steps = now_ms.saturating_sub(stamp) / MARGIN_DECAY_MS;
            (stored as u64 + steps * MARGIN_DECAY_STEP_MS as u64).min(MARGIN_MAX_MS as u64) as u32
        };
        // A late packet contributes 0 slack: enough to block shrinking, not
        // enough to look like a measurement the target can be built on.
        let sample = margin_ms.clamp(0, MARGIN_MAX_MS as i64) as u32;
        if floor == MARGIN_NONE || sample < floor {
            self.min_margin_ms.store(sample, Ordering::Relaxed);
            self.min_margin_stamp_ms.store(now_ms, Ordering::Relaxed);
        } else if floor != stored {
            self.min_margin_ms.store(floor, Ordering::Relaxed);
            self.min_margin_stamp_ms.store(now_ms, Ordering::Relaxed);
        }
        grow
    }

    /// Playout lead to anchor this client's stream with, given the slack the
    /// measured minimum allows. Called only where the buffer holds no frames
    /// that are still going to play, so spending the whole slack at once
    /// cannot cut audio; repeated shrinkage is rate-limited so a lucky window
    /// cannot collapse the lead to the floor in one go.
    pub fn anchor_target(&self, now_ms: u64, period_ms: u64) -> u32 {
        let current = self.target();
        if !ADAPTIVE_JITTER {
            return TARGET_FRAMES_INIT;
        }
        let measured = self.min_margin_ms.load(Ordering::Relaxed);
        if measured == MARGIN_NONE {
            return current;
        }
        // Slack: how much earlier than required the worst packet still
        // arrived. A frame has to be buffered at least one callback period
        // ahead to be present when its slot is generated, hence the pad.
        let pad = MARGIN_SAFETY_MS.max(period_ms);
        let affordable = (measured as u64).saturating_sub(pad) / FRAME_MS;
        let desired = (current as u64)
            .saturating_sub(affordable)
            .max(TARGET_FRAMES_FLOOR as u64) as u32;
        let cooled = now_ms.saturating_sub(self.last_shrink_ms.load(Ordering::Relaxed))
            >= SHRINK_COOLDOWN_MS;
        if desired >= current || !cooled {
            return current;
        }
        self.target_frames.store(desired, Ordering::Relaxed);
        self.last_shrink_ms.store(now_ms, Ordering::Relaxed);
        // The stored minimum belongs to the old, deeper lead: re-measure at
        // the new one instead of shrinking again on stale evidence.
        self.min_margin_ms.store(MARGIN_NONE, Ordering::Relaxed);
        desired
    }
}

// ─── Global State ───────────────────────────────────────────────────

pub struct TsConnection {
    pub connected: bool,
    pub connecting: bool,
    pub server_name: String,
    /// Server property snapshot for the server-settings dialog prefill
    /// (`ts_get_server_info`). Refreshed by `refresh_from_book`, so a
    /// successful `serveredit` shows up on the next book event. The password
    /// is never readable and has no snapshot.
    pub server_max_clients: Option<u16>,
    pub server_welcome_message: String,
    /// From `optional_data` (sent by `notifyserverupdated` — we never request
    /// server variables, so this usually stays null).
    pub server_has_password: Option<bool>,
    pub nickname: String,
    pub own_client_id: u32,
    pub channels: Vec<TsChannel>,
    pub clients: Vec<TsClient>,
    /// All server groups on this server (from `servergrouplist`). Populated
    /// by `refresh_from_book`; empty until the request was answered.
    pub server_groups: Vec<TsServerGroup>,
    /// All channel groups on this server (from `channelgrouplist`).
    pub channel_groups: Vec<TsChannelGroup>,
    /// OUR OWN directly-assigned permissions (from `clientpermlist`).
    /// Inherited/group values are not listed; used only as a low-threshold
    /// hint for UI affordances (e.g. showing the permission-management entry).
    pub own_perms: Vec<TsPerm>,
    pub pending_events: VecDeque<TsEvent>,
    // Audio send state
    pub pcm_in: Vec<f32>,
    pub audio_encoder: Option<opus_rs::OpusEncoder>,
    pub audio_seq: u16,
    pub vad_threshold: f32,
    pub vad_enabled: bool,
    pub vad_hold: u32,
    pub voice_active: bool,
    pub disconnect_requested: bool,
    pub mic_gain: f32,
    // Audio receive state. "Is talking" lives in TALKING_CLIENTS (a global
    // DashMap) instead of here: the receive path updates it per voice packet
    // and must not queue behind the state lock that Dart's polling holds.
    /// Target cid + timestamp of the most recent outgoing clientmove. Server
    /// rejections for our commands arrive without a return_code, so this is
    /// how an invalid-channel-password error gets attributed back to that
    /// move (consumed with a time window in api.rs, see CommandError handling).
    pub pending_move: Option<(u64, Instant)>,
    /// Per-client volume in decibels (dB), keyed by the client's user UID.
    /// Source of truth — NOT cleared on disconnect. The numeric client ID is
    /// only a session-scoped handle; the UID is what survives reconnects and
    /// identifies the same user across servers.
    pub client_volumes: HashMap<String, f32>,
    /// Per-client 2D position (x, y) in meters relative to us (+x = right,
    /// +y = forward), keyed by the client's user UID. Source of truth —
    /// NOT cleared on disconnect. Same lifetime rules as client_volumes.
    pub client_positions: HashMap<String, (f32, f32)>,
}

impl TsConnection {
    fn new() -> Self {
        Self {
            connected: false,
            connecting: false,
            server_name: String::new(),
            server_max_clients: None,
            server_welcome_message: String::new(),
            server_has_password: None,
            nickname: String::new(),
            own_client_id: 0,
            channels: Vec::new(),
            clients: Vec::new(),
            server_groups: Vec::new(),
            channel_groups: Vec::new(),
            own_perms: Vec::new(),
            pending_events: VecDeque::new(),
            pcm_in: Vec::new(),
            audio_encoder: None,
            audio_seq: 0,
            vad_threshold: 0.0,
            vad_enabled: false,
            vad_hold: 0,
            voice_active: false,
            disconnect_requested: false,
            mic_gain: 1.0,
            pending_move: None,
            client_volumes: HashMap::new(),
            client_positions: HashMap::new(),
        }
    }
}

pub static STATE: Lazy<Mutex<TsConnection>> = Lazy::new(|| Mutex::new(TsConnection::new()));
pub static PANIC_LOG: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));

/// cpal stream (Send-safe wrapper). Drop to stop audio playback.
pub struct SendStream(pub Option<cpal::Stream>);
unsafe impl Send for SendStream {}
pub static AUDIO_STREAM: std::sync::Mutex<SendStream> = std::sync::Mutex::new(SendStream(None));
/// cpal microphone input stream (desktop capture path). Android keeps its
/// Kotlin AudioRecord → EventChannel pipeline instead — this stays None
/// there. Dart drives the lifecycle via ts_set_mic_capture.
pub static MIC_STREAM: std::sync::Mutex<SendStream> = std::sync::Mutex::new(SendStream(None));

// ─── Lock-free audio globals ─────────────────────────────────────────

pub static CLIENT_BUFFERS: Lazy<DashMap<u16, ClientJitterBuffer>> = Lazy::new(DashMap::new);
pub static AUDIO_DECODERS: Lazy<DashMap<u16, opus_rs::OpusDecoder>> = Lazy::new(DashMap::new);
pub static AUDIO_DECODERS_STEREO: Lazy<DashMap<u16, opus_rs::OpusDecoder>> = Lazy::new(DashMap::new);
pub const FRAME_SIZE: u64 = 960;
/// Total samples written to the hardware output buffer since stream start.
/// Logical frame number = PLAYED_SAMPLES / FRAME_SIZE.
pub static PLAYED_SAMPLES: Lazy<AtomicU64> = Lazy::new(|| AtomicU64::new(0));
/// Client ID snapshot for the audio callback — avoids iterating DashMap in the callback.
/// Refreshed by the maintenance task every 500ms, and immediately when a
/// client's jitter buffer is created (see `publish_active_client` in api.rs):
/// a speaker who starts talking between two ticks must not have their first
/// syllable dropped just because the snapshot is stale. Lock-free via ArcSwap.
pub static ACTIVE_CLIENT_IDS: Lazy<arc_swap::ArcSwap<Vec<u16>>> =
    Lazy::new(|| arc_swap::ArcSwap::from(std::sync::Arc::new(Vec::new())));
/// RMS of the most recent native-capture mic block (f32::to_bits, 0..1).
/// Published by the cpal input callback (desktop / iOS), read by
/// ts_get_mic_rms for the UI level meter. 0 = silence / capture inactive.
pub static MIC_RMS: AtomicU32 = AtomicU32::new(0);

// ─── Playback clock reference ───────────────────────────────────────

/// Mapping from a play slot to wall-clock time, packed as
/// `(slot << 40) | ms_since(CLOCK_EPOCH)`. Written by the audio callback once
/// per generated mix frame; read by the receive path to measure how long an
/// arriving packet will wait before the slot it plays in is generated. A
/// single atomic store keeps slot and timestamp consistent for the reader.
/// 0 = no reference (no output stream, or the stream was just rebuilt).
pub static CLOCK_REF: AtomicU64 = AtomicU64::new(0);
/// Epoch of the millisecond field of [CLOCK_REF] and of [now_ms].
pub static CLOCK_EPOCH: Lazy<Instant> = Lazy::new(Instant::now);
/// Play slots occupy the top 24 bits of [CLOCK_REF]: 16.7M slots ≈ 93 hours
/// of continuous playback, far beyond one stream's lifetime.
const CLOCK_REF_MS_BITS: u32 = 40;
const CLOCK_REF_MS_MASK: u64 = (1 << CLOCK_REF_MS_BITS) - 1;
/// A reference older than this is treated as "stream not running" — see
/// [play_time_ms]. Generous next to the 20 ms callback period, tight enough
/// that a stopped stream is noticed within one packet.
const CLOCK_REF_MAX_AGE_MS: u64 = 1000;

/// Milliseconds since [CLOCK_EPOCH] (monotonic).
pub fn now_ms() -> u64 {
    CLOCK_EPOCH.elapsed().as_millis() as u64
}

/// Nanoseconds since [CLOCK_EPOCH] (monotonic).
pub fn now_ns() -> u64 {
    CLOCK_EPOCH.elapsed().as_nanos() as u64
}

/// Publish the newest generated play slot together with the time it was
/// generated. Both fields describe the same instant, so the receive path can
/// convert any slot to the wall-clock time it plays at.
pub fn publish_clock_ref(slot: u64) {
    let packed = ((slot & 0xFF_FFFF) << CLOCK_REF_MS_BITS) | (now_ms() & CLOCK_REF_MS_MASK);
    CLOCK_REF.store(packed, Ordering::Relaxed);
}

/// Wall-clock time (ms since [CLOCK_EPOCH]) at which `slot` is mixed, or None
/// when there is no usable reference: none published yet, or the last one is
/// stale — a reference that stopped being refreshed means the output stream is
/// not running (device gone, stream being rebuilt), and its timestamps would
/// read as ever-growing "late" arrivals.
pub fn play_time_ms(slot: u64) -> Option<i64> {
    let packed = CLOCK_REF.load(Ordering::Relaxed);
    if packed == 0 {
        return None;
    }
    let ref_slot = packed >> CLOCK_REF_MS_BITS;
    let ref_ms = packed & CLOCK_REF_MS_MASK;
    if now_ms().saturating_sub(ref_ms) > CLOCK_REF_MAX_AGE_MS {
        return None;
    }
    Some(ref_ms as i64 + (slot as i64 - ref_slot as i64) * FRAME_MS as i64)
}

/// Callback period of the active output stream in ms — the granularity at
/// which the mixing clock advances, as measured by the maintenance task. A
/// frame has to be buffered at least this far ahead to be guaranteed present
/// when its slot is generated, so it is the floor under any playout slack.
pub static OUTPUT_PERIOD_MS: AtomicU32 = AtomicU32::new(FRAME_MS as u32);
/// Device-side sample rate of the active output stream (set when it is built).
/// Paired with CB_STATS::samples_total it yields [OUTPUT_PERIOD_MS].
pub static OUTPUT_RATE: AtomicU32 = AtomicU32::new(48000);

/// Smallest surplus (buffered frames minus the speaker's playout target) seen
/// across the speakers mixed into the last generated frame. Published by
/// `gen_output_mix_frame`, consumed by the resampling loop to decide how hard
/// to compress the mixing clock. Compressing only while *every* speaker has
/// surplus keeps it from pulling anyone below their own target.
pub static MIN_SURPLUS_FRAMES: AtomicU32 = AtomicU32::new(0);

/// Last received audio timestamp per client (drives the UI's "is talking"
/// flag). Deliberately outside STATE: the audio receive path updates this for
/// every voice packet, and taking the global state lock there — the same lock
/// Dart's polling FFI calls hold while serializing the roster — would delay
/// decoding past the packet's play slot.
pub static TALKING_CLIENTS: Lazy<DashMap<u16, Instant>> = Lazy::new(DashMap::new);

/// Adaptive playout state per client (see [JitterStats]). Not torn down with
/// the audio buffers: the learned network profile outlives a silent spell.
pub static JITTER_STATS: Lazy<DashMap<u16, JitterStats>> = Lazy::new(DashMap::new);


// ─── Channel-event SFX (25 built-in sounds) ──────────────────────────

/// SFX request queue consumed by the cpal callback. Values 1..=25 map to
/// the built-in sounds (see `SFX_BUILTIN`); written by the event loop (one
/// request per triggering event), read lock-free by the audio callback.
/// Playback slots are per-stream, so the queue is drained on stream
/// restart/stop.
pub static SFX_QUEUE: Lazy<SegQueue<u8>> = Lazy::new(SegQueue::new);

/// Suppression flag for the initial roster sync. Reset when a connection is
/// established and when a temporary disconnect happens; set once the first
/// `BookEvents` batch has been processed. The connection library replays the
/// whole roster on reconnect, and the first event-loop batch after connect
/// may still carry late-arriving list data — neither should produce sounds.
pub static SFX_ARMED: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

/// Set when our own client was kicked or banned. The server closes the
/// connection right after, and the "disconnected" sound must not play on
/// top of the kick/ban sound. Cleared when a new connection is established.
pub static SFX_SUPPRESS_DISCONNECT: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

/// Set while a disconnect/error sound is still playing through the output
/// stream and its teardown has been deferred (see `schedule_sfx_teardown`
/// in api.rs). `ts_stop_audio` respects this flag and leaves the stream
/// alone so the sound can finish; the deferred task performs the teardown.
pub static SFX_DEFERRED_TEARDOWN: Lazy<AtomicBool> = Lazy::new(|| AtomicBool::new(false));

/// Drop all pending SFX requests (e.g. when the output stream is rebuilt).
pub fn clear_sfx_queue() {
    while SFX_QUEUE.pop().is_some() {}
}

// ─── SFX sample storage (built-in assets + custom overrides) ────────

/// Parse a RIFF/WAVE file into 48 kHz mono f32 samples suitable for SFX
/// playback (the cpal output format).
///
/// Supported: PCM 16-bit and IEEE float32, 1 or 2 channels (stereo is
/// averaged down to mono), any sample rate (linearly resampled to 48 kHz).
/// Rejects non-RIFF/WAVE input, other encodings, and files without audio
/// data. There is deliberately NO content-length policy here — sounds may be
/// as long as they are; the only bound is the allocation guard below.
pub(crate) fn parse_wav_pcm(data: &[u8]) -> Result<Vec<f32>, String> {
    // Pure allocation guard, NOT a content policy: the resample output is
    // duration × 48 kHz samples, so a tiny file claiming a pathological
    // sample rate (e.g. 1 Hz) would otherwise try to allocate gigabytes.
    // ~5 minutes ≈ 57 MB decoded — ~100× the longest real sound (2.53 s);
    // nothing legitimate ever comes near it.
    const MAX_SECONDS: f64 = 300.0;
    const TARGET_RATE: u32 = 48_000;

    if data.len() < 12 || &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_string());
    }

    let mut fmt: Option<(u16, u16, u32, u16)> = None; // (format, channels, rate, bits)
    let mut data_chunks: Vec<&[u8]> = Vec::new();
    let mut off = 12usize;
    while off + 8 <= data.len() {
        let id = &data[off..off + 4];
        let size = u32::from_le_bytes(
            data[off + 4..off + 8]
                .try_into()
                .map_err(|_| "bad chunk size".to_string())?,
        ) as usize;
        let chunk_start = off + 8;
        if size > data.len().saturating_sub(chunk_start) {
            break; // truncated chunk — stop walking, keep what we have
        }
        let chunk = &data[chunk_start..chunk_start + size];
        match id {
            b"fmt " => {
                if chunk.len() < 16 {
                    return Err("fmt chunk too short".to_string());
                }
                let format = u16::from_le_bytes([chunk[0], chunk[1]]);
                let channels = u16::from_le_bytes([chunk[2], chunk[3]]);
                let rate = u32::from_le_bytes(
                    chunk[4..8]
                        .try_into()
                        .map_err(|_| "bad sample rate".to_string())?,
                );
                let bits = u16::from_le_bytes([chunk[14], chunk[15]]);
                fmt = Some((format, channels, rate, bits));
            }
            b"data" => data_chunks.push(chunk),
            _ => {}
        }
        off = chunk_start + size + (size & 1);
    }

    let (format, channels, rate, bits) =
        fmt.ok_or_else(|| "missing fmt chunk".to_string())?;
    if rate == 0 {
        return Err("invalid sample rate 0".to_string());
    }
    if channels != 1 && channels != 2 {
        return Err(format!("unsupported channel count {}", channels));
    }

    let decode = |chunk: &[u8]| -> Result<Vec<f32>, String> {
        match (format, bits) {
            // PCM 16-bit
            (1, 16) => {
                let frame_bytes = channels as usize * 2;
                let frames = chunk.len() / frame_bytes;
                let mut out = Vec::with_capacity(frames);
                for f in 0..frames {
                    let base = f * frame_bytes;
                    let mut sum = 0i64;
                    for ch in 0..channels as usize {
                        let idx = base + ch * 2;
                        let v = i16::from_le_bytes([chunk[idx], chunk[idx + 1]]) as i64;
                        sum += v;
                    }
                    out.push((sum as f32 / channels as f32) / 32768.0);
                }
                Ok(out)
            }
            // IEEE float32
            (3, 32) => {
                let frame_bytes = channels as usize * 4;
                let frames = chunk.len() / frame_bytes;
                let mut out = Vec::with_capacity(frames);
                for f in 0..frames {
                    let base = f * frame_bytes;
                    let mut sum = 0.0f32;
                    for ch in 0..channels as usize {
                        let idx = base + ch * 4;
                        let v = f32::from_le_bytes(
                            chunk[idx..idx + 4]
                                .try_into()
                                .map_err(|_| "bad float sample".to_string())?,
                        );
                        sum += v;
                    }
                    out.push(sum / channels as f32);
                }
                Ok(out)
            }
            _ => Err(format!(
                "unsupported WAV encoding format={} bits={} (expected PCM 16-bit or float32)",
                format, bits
            )),
        }
    };

    let mut pcm: Vec<f32> = Vec::new();
    for chunk in &data_chunks {
        pcm.extend(decode(chunk)?);
    }
    if pcm.is_empty() {
        return Err("no audio data".to_string());
    }

    let seconds = pcm.len() as f64 / rate as f64;
    if seconds > MAX_SECONDS {
        return Err(format!(
            "audio too long ({:.3}s > {:.0}s)",
            seconds, MAX_SECONDS
        ));
    }

    if rate == TARGET_RATE {
        return Ok(pcm);
    }

    // Linear resample to 48 kHz mono.
    let ratio = rate as f64 / TARGET_RATE as f64;
    let out_len = (pcm.len() as f64 * TARGET_RATE as f64 / rate as f64).ceil() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let pos = i as f64 * ratio;
        let idx = pos.floor() as usize;
        let frac = (pos - idx as f64) as f32;
        let a = pcm.get(idx).copied().unwrap_or(0.0);
        let b = pcm.get(idx + 1).copied().unwrap_or(a);
        out.push(a + (b - a) * frac);
    }
    Ok(out)
}

/// Parse a built-in channel-event SFX sample with startup diagnostics:
/// parse failures and silent (all-zero) samples are logged so asset problems
/// are visible in logcat instead of failing silently at playback time.
fn load_builtin_sfx(kind: usize, name: &str) -> Option<Vec<f32>> {
    let data: &[u8] = match kind {
        0 => include_bytes!("../assets/sfx/channel_switched.wav"),
        1 => include_bytes!("../assets/sfx/neutral_switched_tocurrentchannel.wav"),
        2 => include_bytes!("../assets/sfx/neutral_switched_awayfromcurrentchannel.wav"),
        3 => include_bytes!("../assets/sfx/you_were_moved.wav"),
        4 => include_bytes!("../assets/sfx/you_kicked_channel.wav"),
        5 => include_bytes!("../assets/sfx/you_kicked_server.wav"),
        6 => include_bytes!("../assets/sfx/you_were_banned.wav"),
        7 => include_bytes!("../assets/sfx/you_were_poked.wav"),
        8 => include_bytes!("../assets/sfx/chat_message_inbound.wav"),
        9 => include_bytes!("../assets/sfx/chat_message_outbound.wav"),
        10 => include_bytes!("../assets/sfx/connected.wav"),
        11 => include_bytes!("../assets/sfx/disconnected.wav"),
        12 => include_bytes!("../assets/sfx/connection_lost.wav"),
        13 => include_bytes!("../assets/sfx/error.wav"),
        14 => include_bytes!("../assets/sfx/mic_activated.wav"),
        15 => include_bytes!("../assets/sfx/mic_muted.wav"),
        16 => include_bytes!("../assets/sfx/sound_muted.wav"),
        17 => include_bytes!("../assets/sfx/sound_resumed.wav"),
        18 => include_bytes!("../assets/sfx/away_activated.wav"),
        19 => include_bytes!("../assets/sfx/away_deactivated.wav"),
        20 => include_bytes!("../assets/sfx/channel_created.wav"),
        21 => include_bytes!("../assets/sfx/channel_deleted.wav"),
        22 => include_bytes!("../assets/sfx/channel_edited.wav"),
        23 => include_bytes!("../assets/sfx/channel_moved.wav"),
        24 => include_bytes!("../assets/sfx/channelgroup_changed.wav"),
        25 => include_bytes!("../assets/sfx/neutral_connection_connected_currentchannel.wav"),
        26 => include_bytes!("../assets/sfx/neutral_connection_disconnected_currentchannel.wav"),
        27 => include_bytes!("../assets/sfx/neutral_connection_connectionlost_currentchannel.wav"),
        28 => include_bytes!("../assets/sfx/neutral_moved_tocurrentchannel.wav"),
        29 => include_bytes!("../assets/sfx/neutral_moved_awayfromcurrentchannel.wav"),
        30 => include_bytes!("../assets/sfx/neutral_kicked_channel_tocurrentchannel.wav"),
        31 => include_bytes!("../assets/sfx/neutral_kicked_channel_awayfromcurrentchannel.wav"),
        32 => include_bytes!("../assets/sfx/neutral_kicked_server_currentchannel.wav"),
        33 => include_bytes!("../assets/sfx/neutral_banned_server_currentchannel.wav"),
        34 => include_bytes!("../assets/sfx/neutral_recording_started_currentchannel.wav"),
        35 => include_bytes!("../assets/sfx/neutral_recording_stopped_currentchannel.wav"),
        _ => include_bytes!("../assets/sfx/neutral_recording_active_currentchannel.wav"),
    };
    match parse_wav_pcm(data) {
        Ok(samples) => {
            let peak = samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
            if peak < 1e-4 {
                eprintln!(
                    "[sfx] builtin kind={} \"{}\": SILENT sample (peak={:.2e})",
                    kind, name, peak
                );
            } else {
                eprintln!(
                    "[sfx] builtin kind={} \"{}\": {} samples, peak={:.3}",
                    kind,
                    name,
                    samples.len(),
                    peak
                );
            }
            Some(samples)
        }
        Err(msg) => {
            eprintln!("[sfx] builtin kind={} \"{}\": parse failed: {}", kind, name, msg);
            None
        }
    }
}

/// Built-in SFX samples, parsed once at startup from assets embedded with
/// `include_bytes!`. Index 0..37 = kind 1..=37 (see the order in
/// `load_builtin_sfx`): 0 channel_switched, 1 neutral_switched_tocurrent,
/// 2 neutral_switched_away, 3 you_were_moved, 4 you_kicked_channel,
/// 5 you_kicked_server, 6 you_were_banned, 7 you_were_poked,
/// 8 chat_message_inbound, 9 chat_message_outbound, 10 connected,
/// 11 disconnected, 12 connection_lost, 13 error, 14 mic_activated,
/// 15 mic_muted, 16 sound_muted, 17 sound_resumed, 18 away_activated,
/// 19 away_deactivated, 20 channel_created, 21 channel_deleted,
/// 22 channel_edited, 23 channel_moved, 24 channelgroup_changed,
/// 25..36 neutral_* other-user sounds (connection/moved/kicked/banned/
/// recording), 37 neutral_recording_active.
/// A `None` entry means the asset is missing or failed to parse (playback
/// falls back to silence for that kind).
pub static SFX_BUILTIN: Lazy<[Option<Vec<f32>>; 37]> = Lazy::new(|| {
    [
        load_builtin_sfx(0, "channel_switched"),
        load_builtin_sfx(1, "neutral_switched_tocurrentchannel"),
        load_builtin_sfx(2, "neutral_switched_awayfromcurrentchannel"),
        load_builtin_sfx(3, "you_were_moved"),
        load_builtin_sfx(4, "you_kicked_channel"),
        load_builtin_sfx(5, "you_kicked_server"),
        load_builtin_sfx(6, "you_were_banned"),
        load_builtin_sfx(7, "you_were_poked"),
        load_builtin_sfx(8, "chat_message_inbound"),
        load_builtin_sfx(9, "chat_message_outbound"),
        load_builtin_sfx(10, "connected"),
        load_builtin_sfx(11, "disconnected"),
        load_builtin_sfx(12, "connection_lost"),
        load_builtin_sfx(13, "error"),
        load_builtin_sfx(14, "mic_activated"),
        load_builtin_sfx(15, "mic_muted"),
        load_builtin_sfx(16, "sound_muted"),
        load_builtin_sfx(17, "sound_resumed"),
        load_builtin_sfx(18, "away_activated"),
        load_builtin_sfx(19, "away_deactivated"),
        load_builtin_sfx(20, "channel_created"),
        load_builtin_sfx(21, "channel_deleted"),
        load_builtin_sfx(22, "channel_edited"),
        load_builtin_sfx(23, "channel_moved"),
        load_builtin_sfx(24, "channelgroup_changed"),
        load_builtin_sfx(25, "neutral_connection_connected_currentchannel"),
        load_builtin_sfx(26, "neutral_connection_disconnected_currentchannel"),
        load_builtin_sfx(27, "neutral_connection_connectionlost_currentchannel"),
        load_builtin_sfx(28, "neutral_moved_tocurrentchannel"),
        load_builtin_sfx(29, "neutral_moved_awayfromcurrentchannel"),
        load_builtin_sfx(30, "neutral_kicked_channel_tocurrentchannel"),
        load_builtin_sfx(31, "neutral_kicked_channel_awayfromcurrentchannel"),
        load_builtin_sfx(32, "neutral_kicked_server_currentchannel"),
        load_builtin_sfx(33, "neutral_banned_server_currentchannel"),
        load_builtin_sfx(34, "neutral_recording_started_currentchannel"),
        load_builtin_sfx(35, "neutral_recording_stopped_currentchannel"),
        load_builtin_sfx(36, "neutral_recording_active_currentchannel"),
    ]
});

/// The active SFX samples (custom override or built-in fallback) as seen by
/// the cpal audio thread. `ArcSwap` gives lock-free reads, so the callback
/// never blocks while a custom sample is being installed from Dart.
pub static SFX_SAMPLES: Lazy<arc_swap::ArcSwap<[Option<std::sync::Arc<Vec<f32>>>; 37]>> =
    Lazy::new(|| {
        let builtin: [Option<std::sync::Arc<Vec<f32>>>; 37] =
            std::array::from_fn(|i| {
                SFX_BUILTIN[i]
                    .as_ref()
                    .map(|s| std::sync::Arc::new(s.clone()))
            });
        arc_swap::ArcSwap::from(std::sync::Arc::new(builtin))
    });

// ─── Diagnostic callback stats (all atomics, safe to write from audio thread) ──

pub struct CallbackStats {
    /// Total callback invocations since last stats print.
    pub callbacks: AtomicU64,
    /// Sum of data.len() across all callbacks since last print.
    pub samples_total: AtomicU64,
    /// Total mix frames generated (slot changes) since last print.
    pub mix_frames: AtomicU64,
    /// DRIFT CHECK: expected played value at next callback entry. Set at end of
    /// each callback to (PLAYED_SAMPLES after fetch_add). The next callback compares
    /// its played_before against this value; mismatch = audio clock drift.
    pub expected_next_played: AtomicU64,
    /// Total PLAYED_SAMPLES consistency violations.
    pub played_mismatches: AtomicU64,
    /// Microseconds since the previous callback entry (0 if this is first).
    pub last_interval_us: AtomicU64,
    /// Instant::now() at the start of the last callback, in nanoseconds from boot.
    /// Used to compute the interval to the next callback.
    pub last_cb_entry_ns: AtomicU64,
}

pub static CB_STATS: Lazy<CallbackStats> = Lazy::new(|| CallbackStats {
    callbacks: AtomicU64::new(0),
    samples_total: AtomicU64::new(0),
    mix_frames: AtomicU64::new(0),
    expected_next_played: AtomicU64::new(0),
    played_mismatches: AtomicU64::new(0),
    last_interval_us: AtomicU64::new(0),
    last_cb_entry_ns: AtomicU64::new(0),
});

pub fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let location = info.location()
            .map(|l| {
                let file = l.file();
                let short = file.rsplit(&['/', '\\']).next().unwrap_or(file);
                format!("{}:{}:{}", short, l.line(), l.column())
            })
            .unwrap_or_else(|| "unknown location".into());
        let payload = if let Some(s) = info.payload().downcast_ref::<&str>() {
            s.to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".into()
        };
        let msg = format!("PANIC {}: {}", location, payload);
        eprintln!("{}", msg);
        *PANIC_LOG.lock() = msg;
    }));
}

pub fn flush_panic_log() {
    let mut log = PANIC_LOG.lock();
    if !log.is_empty() {
        STATE.lock().pending_events.push_back(TsEvent::Diag {
            msg: log.clone(),
        });
        log.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::parse_wav_pcm;

    fn wav_pcm16(rate: u32, channels: u16, samples: &[i16]) -> Vec<u8> {
        let bits: u16 = 16;
        let block_align = channels * bits / 8;
        let byte_rate = rate * block_align as u32;
        let data_len = samples.len() as u32 * (bits as u32 / 8);
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        for &s in samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    fn wav_f32(rate: u32, channels: u16, samples: &[f32]) -> Vec<u8> {
        let bits: u16 = 32;
        let block_align = channels * bits / 8;
        let byte_rate = rate * block_align as u32;
        let data_len = samples.len() as u32 * (bits as u32 / 8);
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + data_len).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&3u16.to_le_bytes()); // IEEE float
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&bits.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&data_len.to_le_bytes());
        for &s in samples {
            out.extend_from_slice(&s.to_le_bytes());
        }
        out
    }

    #[test]
    fn parses_mono_16bit() {
        let wav = wav_pcm16(48_000, 1, &[0, 16_384, 32_767, -32_768, -16_384]);
        let pcm = parse_wav_pcm(&wav).expect("valid mono 16-bit WAV");
        assert_eq!(pcm.len(), 5);
        assert!((pcm[0] - 0.0).abs() < 1e-6);
        assert!((pcm[1] - 0.5).abs() < 1e-4);
        assert!((pcm[2] - 1.0).abs() < 1e-4);
        assert!((pcm[3] + 1.0).abs() < 1e-4);
        assert!((pcm[4] + 0.5).abs() < 1e-4);
    }

    #[test]
    fn downmixes_stereo_to_mono() {
        // Interleaved L/R: each pair cancels to ~0.
        let samples: Vec<i16> = (0..20)
            .flat_map(|_| [10_000i16, -10_000i16])
            .collect();
        let wav = wav_pcm16(48_000, 2, &samples);
        let pcm = parse_wav_pcm(&wav).expect("valid stereo 16-bit WAV");
        assert_eq!(pcm.len(), 20);
        for s in pcm {
            assert!(s.abs() < 1e-6, "stereo pair should cancel, got {}", s);
        }
    }

    #[test]
    fn parses_float32() {
        let wav = wav_f32(48_000, 1, &[0.25, -0.5, 1.0]);
        let pcm = parse_wav_pcm(&wav).expect("valid float32 WAV");
        assert_eq!(pcm.len(), 3);
        assert!((pcm[0] - 0.25).abs() < 1e-6);
        assert!((pcm[1] + 0.5).abs() < 1e-6);
        assert!((pcm[2] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn resamples_44100_to_48000() {
        // 0.1s at 44.1 kHz = 4410 frames → exactly 4800 frames at 48 kHz.
        let samples = vec![0i16; 4410];
        let wav = wav_pcm16(44_100, 1, &samples);
        let pcm = parse_wav_pcm(&wav).expect("valid 44.1 kHz WAV");
        assert_eq!(pcm.len(), 4800);
    }

    #[test]
    fn rejects_non_pcm() {
        // ADPCM (format 2) is not supported.
        let mut wav = wav_pcm16(48_000, 1, &[0, 0]);
        wav[20..22].copy_from_slice(&2u16.to_le_bytes()); // format field
        let err = parse_wav_pcm(&wav).expect_err("ADPCM should be rejected");
        assert!(err.contains("unsupported"), "got: {}", err);
    }

    #[test]
    fn rejects_pathological_expansion() {
        // The only length bound is the allocation guard against resample
        // expansion (output = duration × 48 kHz): a 602-byte file claiming a
        // 1 Hz rate decodes to 301 "seconds" — ~14.4M output samples — and
        // must be rejected instead of allocating ~57 MB.
        let err = parse_wav_pcm(&wav_pcm16(1, 1, &[0; 301]))
            .expect_err("pathological duration should be rejected");
        assert!(err.contains("too long"), "got: {}", err);
    }

    #[test]
    fn rejects_garbage_and_empty() {
        assert!(parse_wav_pcm(b"NOTWAVE............").is_err());
        assert!(parse_wav_pcm(b"").is_err());
        // A WAVE with a fmt chunk but no data chunk.
        let mut wav = wav_pcm16(48_000, 1, &[0]);
        wav.truncate(44);
        let err = parse_wav_pcm(&wav).expect_err("no data chunk should be rejected");
        assert!(err.contains("no audio data"), "got: {}", err);
    }

    // ─── Adaptive playout lead ──────────────────────────────────────
    //
    // The lead is the one latency knob in the receive path, so the rules that
    // move it are pinned here: a cold start is conservative, a clean link
    // walks down to the floor, a late packet grows it and blocks shrinking
    // until the decay lifts the evidence again, and neither direction escapes
    // its bounds.

    use super::{
        JitterStats, MARGIN_NONE, TARGET_FRAMES_CEIL, TARGET_FRAMES_FLOOR, TARGET_FRAMES_INIT,
    };

    /// Margins a perfectly paced sender produces at a given lead: exactly the
    /// lead, with no packet ever late.
    fn clean_margin(lead: u32) -> i64 {
        lead as i64 * super::FRAME_MS as i64
    }

    #[test]
    fn cold_start_uses_initial_lead() {
        let stats = JitterStats::default();
        assert_eq!(stats.target(), TARGET_FRAMES_INIT);
        // Nothing measured yet → the anchor keeps the conservative default.
        assert_eq!(stats.anchor_target(60_000, 20), TARGET_FRAMES_INIT);
        assert_eq!(
            stats.min_margin_ms.load(std::sync::atomic::Ordering::Relaxed),
            MARGIN_NONE
        );
    }

    #[test]
    fn clean_link_shrinks_to_floor_and_stays() {
        let stats = JitterStats::default();
        let mut now = 60_000;
        let mut lead = stats.anchor_target(now, 20);
        assert_eq!(lead, TARGET_FRAMES_INIT);

        // Three burst starts on a link that never delivers a late packet.
        for _ in 0..3 {
            now += 100;
            let margin = clean_margin(lead);
            assert!(!stats.observe_margin(margin, now), "nothing was late");
            now += super::SHRINK_COOLDOWN_MS;
            lead = stats.anchor_target(now, 20);
        }
        assert_eq!(lead, TARGET_FRAMES_FLOOR, "clean link should reach the floor");
    }

    #[test]
    fn late_packets_grow_the_lead_once_per_streak() {
        let stats = JitterStats::default();
        stats.anchor_target(60_000, 20);
        // First late packet: evidence, not yet a decision.
        assert!(!stats.observe_margin(-30, 60_100));
        assert_eq!(stats.target(), TARGET_FRAMES_INIT);
        // Second one crosses the streak threshold and asks for one frame.
        assert!(stats.observe_margin(-30, 60_200));
        assert_eq!(stats.target(), TARGET_FRAMES_INIT + 1);
        // The streak restarted with the growth: another single late packet
        // cannot ratchet the lead again immediately.
        assert!(!stats.observe_margin(-30, 60_300));
        assert_eq!(stats.target(), TARGET_FRAMES_INIT + 1);
    }

    #[test]
    fn late_packet_blocks_shrinking_until_healthy_packets_raise_the_floor() {
        let stats = JitterStats::default();
        stats.anchor_target(60_000, 20);
        stats.observe_margin(clean_margin(TARGET_FRAMES_INIT), 60_100);
        assert!(!stats.observe_margin(-30, 60_200));
        assert_eq!(
            stats.min_margin_ms.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "a late packet is zero slack"
        );
        // Zero slack blocks shrinking, even long past the cooldown.
        assert_eq!(
            stats.anchor_target(600_000, 20),
            TARGET_FRAMES_INIT,
            "zero measured slack must not shorten the lead"
        );

        // The link recovers: packets arrive a full lead early again. The
        // stored minimum then climbs (the sample is above the decayed floor)
        // until a frame of slack is available and the anchor may shorten.
        let mut now = 600_000;
        let mut shortened = None;
        for _ in 0..40 {
            now += super::MARGIN_DECAY_MS;
            stats.observe_margin(clean_margin(TARGET_FRAMES_INIT), now);
            let lead = stats.anchor_target(now + super::SHRINK_COOLDOWN_MS, 20);
            if lead < TARGET_FRAMES_INIT {
                shortened = Some(lead);
                break;
            }
        }
        assert!(
            shortened.is_some(),
            "healthy packets must eventually allow a shorter lead"
        );
        assert_eq!(
            stats.min_margin_ms.load(std::sync::atomic::Ordering::Relaxed),
            MARGIN_NONE,
            "the measurement restarts at the new lead"
        );
    }

    #[test]
    fn lead_stays_within_bounds() {
        let stats = JitterStats::default();
        // Twenty late packets, spaced past the growth cooldown each time.
        for i in 0..20 {
            let now = 60_000 + i * (super::GROW_COOLDOWN_MS + 1);
            stats.observe_margin(-500, now);
            stats.observe_margin(-500, now + 1);
        }
        assert_eq!(stats.target(), TARGET_FRAMES_CEIL, "growth is capped");

        // Now a long clean stretch: the lead walks back down, never below the
        // floor, even though the slack would allow more.
        let mut now = 1_000_000;
        let mut lead = stats.target();
        for _ in 0..20 {
            now += super::SHRINK_COOLDOWN_MS + super::MARGIN_DECAY_MS;
            stats.observe_margin(clean_margin(lead), now);
            lead = stats.anchor_target(now + 1, 20);
        }
        assert_eq!(lead, TARGET_FRAMES_FLOOR, "shrink is capped");
    }

    #[test]
    fn a_longer_device_period_keeps_more_slack() {
        // On a host that grants an 85 ms period the callback itself quantizes
        // the clock, so the same measurement must leave a deeper lead than it
        // would on a 20 ms device.
        let fast = JitterStats::default();
        let slow = JitterStats::default();
        for stats in [&fast, &slow] {
            stats.observe_margin(85, 60_000);
        }
        assert!(
            slow.anchor_target(600_000, 85) >= fast.anchor_target(600_000, 20),
            "a coarser device period must not shorten the lead further"
        );
    }

    #[test]
    fn clock_reference_maps_slots_to_wall_clock() {
        // Publish slot 10_000; a slot 50 frames further on plays one second
        // (50 × 20 ms) later.
        super::publish_clock_ref(10_000);
        let base = super::play_time_ms(10_000).expect("reference just published");
        let later = super::play_time_ms(10_050).expect("reference is fresh");
        assert_eq!(later - base, 50 * super::FRAME_MS as i64);
        assert!(super::now_ms().saturating_sub(base as u64) < 100);

        // Slots live in the top 24 bits: a wrapped slot is masked off, and
        // the wrapped reference still maps nearby slots consistently. (This
        // test owns CLOCK_REF for its whole body — every assertion that
        // stores a crafted value lives here so parallel tests never race.)
        super::publish_clock_ref(0x100_0005);
        let ref_slot =
            super::CLOCK_REF.load(std::sync::atomic::Ordering::Relaxed) >> super::CLOCK_REF_MS_BITS;
        assert_eq!(ref_slot, 5, "slot is masked to 24 bits");
        let t5 = super::play_time_ms(5).expect("fresh reference");
        let t7 = super::play_time_ms(7).expect("fresh reference");
        assert_eq!(t7 - t5, 2 * super::FRAME_MS as i64);

        // A reference whose timestamp stopped being refreshed (stalled
        // output stream) is unusable: its timestamps would read as
        // ever-growing "late" arrivals. Fabricating a stale reference needs
        // the monotonic clock past the max age (tests may run within the
        // first second after the epoch) — wait it out instead of storing a
        // value that only looks stale on a warmed-up clock.
        while super::now_ms() <= super::CLOCK_REF_MAX_AGE_MS {
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        super::CLOCK_REF.store(
            5 << super::CLOCK_REF_MS_BITS, // ms field 0 = published long ago
            std::sync::atomic::Ordering::Relaxed,
        );
        assert_eq!(super::play_time_ms(5), None, "stale reference is rejected");

        // No reference at all (no output stream, or just rebuilt).
        super::CLOCK_REF.store(0, std::sync::atomic::Ordering::Relaxed);
        assert_eq!(super::play_time_ms(5), None, "zero reference is rejected");
    }

    // ─── Dart-facing JSON contract ──────────────────────────────────
    //
    // ts_ffi.dart parses these objects with hand-written fromJson code, so
    // the exact field names and the "type" tag spellings are API, not detail.

    use super::{ChannelArgs, ClientJitterBuffer, SFX_BUILTIN, TsChannel, TsEvent, TsRecordingFile};

    #[test]
    fn ts_event_json_tags_and_fields() {
        let event = TsEvent::TextMessage {
            from_client: "Alice".into(),
            from_client_id: 5,
            to_client_id: 9,
            target_mode: 1,
            message: "hi".into(),
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "text_message");
        assert_eq!(json["from_client"], "Alice");
        assert_eq!(json["from_client_id"], 5);
        assert_eq!(json["to_client_id"], 9);
        assert_eq!(json["target_mode"], 1);
        assert_eq!(json["message"], "hi");

        // Nullable fields stay present as explicit nulls (Dart reads them
        // as null).
        let event = TsEvent::FtDone {
            task_id: 3,
            ok: true,
            transferred: 128,
            error: None,
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "ft_done");
        assert_eq!(json["task_id"], 3);
        assert_eq!(json["transferred"], 128);
        assert!(json["error"].is_null());

        let event = TsEvent::Connected {
            server_name: "The Nest".into(),
            client_id: 1,
            ask_for_privilegekey: false,
            welcome_message: "Welcome!".into(),
            hostmessage: "".into(),
            hostmessage_mode: 1,
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "connected");
        assert_eq!(json["server_name"], "The Nest");
        assert_eq!(json["client_id"], 1);
        assert_eq!(json["ask_for_privilegekey"], false);
        assert_eq!(json["welcome_message"], "Welcome!");
        assert_eq!(json["hostmessage"], "");
        assert_eq!(json["hostmessage_mode"], 1);

        // Chat-log notices carry the classification codes the Dart side
        // turns into localized lines.
        let event = TsEvent::ClientLeaveChannel {
            client_id: 7,
            nickname: "Bob".into(),
            kind: 2,
            invoker: "Admin".into(),
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "client_leave_channel");
        assert_eq!(json["client_id"], 7);
        assert_eq!(json["nickname"], "Bob");
        assert_eq!(json["kind"], 2);
        assert_eq!(json["invoker"], "Admin");

        let event = TsEvent::ClientEnterChannel {
            client_id: 8,
            nickname: "Carol".into(),
            reason: 1,
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "client_enter_channel");
        assert_eq!(json["reason"], 1);

        let event = TsEvent::SelfMoved {
            to_channel_id: 4,
            to_channel_name: "Lobby".into(),
            invoker: "".into(),
            kind: 0,
        };
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["type"], "self_moved");
        assert_eq!(json["to_channel_id"], 4);
        assert_eq!(json["to_channel_name"], "Lobby");
        assert_eq!(json["invoker"], "");
        assert_eq!(json["kind"], 0);
    }

    #[test]
    fn recording_file_json_shape() {
        let file = TsRecordingFile {
            path: "/tmp/a.wav".into(),
            client_id: 12,
            uid: Some("abc=".into()),
            name: "Alice".into(),
            mixed: false,
        };
        let json = serde_json::to_value(&file).unwrap();
        assert_eq!(json["path"], "/tmp/a.wav");
        assert_eq!(json["client_id"], 12);
        assert_eq!(json["uid"], "abc=");
        assert_eq!(json["name"], "Alice");
        assert_eq!(json["mixed"], false);
    }

    #[test]
    fn channel_args_deserialize_from_args_json() {
        // Absent fields stay None = "untouched" on an edit.
        let args: ChannelArgs = serde_json::from_str("{}").unwrap();
        assert!(args.name.is_none());
        assert!(args.parent_id.is_none());

        let args: ChannelArgs = serde_json::from_str(
            r#"{"parent_id": 2, "name": "Lobby", "topic": "", "password": "p",
                "description": "d", "max_family_clients": 0, "max_clients": 10,
                "is_permanent": true, "is_semi_permanent": false,
                "is_default": false, "delete_delay": 30,
                "needed_talk_power": 75, "order": 4}"#,
        )
        .unwrap();
        assert_eq!(args.parent_id, Some(2));
        assert_eq!(args.name.as_deref(), Some("Lobby"));
        // Some("") means "clear" — distinct from None (untouched).
        assert_eq!(args.topic.as_deref(), Some(""));
        assert_eq!(args.password.as_deref(), Some("p"));
        assert_eq!(args.description.as_deref(), Some("d"));
        assert_eq!(args.max_family_clients, Some(0));
        assert_eq!(args.max_clients, Some(10));
        assert_eq!(args.is_permanent, Some(true));
        assert_eq!(args.is_semi_permanent, Some(false));
        assert_eq!(args.is_default, Some(false));
        assert_eq!(args.delete_delay, Some(30));
        assert_eq!(args.needed_talk_power, Some(75));
        assert_eq!(args.order, Some(4));
    }

    #[test]
    fn channel_json_matches_dart_field_names() {
        let channel = TsChannel {
            id: 7,
            name: "Default".into(),
            parent_id: 0,
            topic: String::new(),
            has_password: false,
            client_count: 3,
            order: 0,
            is_default: true,
            permission_hints: 1 | 64 | 128,
            needed_talk_power: 0,
            max_clients: -1,
            is_permanent: true,
            is_semi_permanent: false,
            description: String::new(),
            max_family_clients: -1,
            delete_delay: 0,
        };
        let json = serde_json::to_value(&channel).unwrap();
        for key in [
            "id",
            "name",
            "parent_id",
            "topic",
            "has_password",
            "client_count",
            "order",
            "is_default",
            "permission_hints",
            "needed_talk_power",
            "max_clients",
            "is_permanent",
            "is_semi_permanent",
            "description",
            "max_family_clients",
            "delete_delay",
        ] {
            assert!(json.get(key).is_some(), "missing key {}", key);
        }
        assert_eq!(json["id"], 7);
        assert_eq!(json["client_count"], 3);
        assert_eq!(json["permission_hints"], 1 | 64 | 128);
        assert_eq!(json["max_clients"], -1);
    }

    // ─── Jitter buffer init ─────────────────────────────────────────

    #[test]
    fn jitter_buffer_starts_unconfigured() {
        let buf = ClientJitterBuffer::new();
        assert_eq!(
            buf.base_pair.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "0 = uninitialized mapping"
        );
        assert_eq!(buf.write_seq.load(std::sync::atomic::Ordering::Relaxed), 0);
        assert_eq!(
            buf.target_frames.load(std::sync::atomic::Ordering::Relaxed),
            TARGET_FRAMES_INIT
        );
        // Volume starts at unity; the position is NaN = centered playback.
        assert_eq!(
            f32::from_bits(buf.volume.load(std::sync::atomic::Ordering::Relaxed)),
            1.0
        );
        assert!(f32::from_bits(buf.pos_x.load(std::sync::atomic::Ordering::Relaxed)).is_nan());
        assert!(f32::from_bits(buf.pos_y.load(std::sync::atomic::Ordering::Relaxed)).is_nan());
        // AtomicCell<Option<Vec>> has no Copy load — swap(None) reads the
        // slot (and leaves None in place on a fresh buffer).
        assert!(buf.slots.iter().all(|s| s.swap(None).is_none()));
    }

    // ─── WAV parser edges ───────────────────────────────────────────

    #[test]
    fn skips_odd_sized_chunks_with_padding() {
        let wav = wav_pcm16(48_000, 1, &[100, -100]);
        // Splice a 3-byte JUNK chunk (padded to 4 per RIFF) in front of the
        // data chunk and fix up the RIFF size.
        let data_len = 2u32 * 2;
        let mut out = Vec::new();
        out.extend_from_slice(&wav[..36]);
        out.extend_from_slice(b"JUNK");
        out.extend_from_slice(&3u32.to_le_bytes());
        out.extend_from_slice(b"abc");
        out.push(0); // pad byte
        out.extend_from_slice(&wav[36..]);
        out[4..8].copy_from_slice(&(36u32 + 12 + data_len).to_le_bytes());

        let pcm = parse_wav_pcm(&out).expect("odd chunk must be skipped with its padding");
        assert_eq!(pcm.len(), 2);
    }

    #[test]
    fn rejects_extra_channels_and_zero_rate() {
        let wav = wav_pcm16(48_000, 3, &[0; 6]);
        let err = parse_wav_pcm(&wav).expect_err("3 channels must be rejected");
        assert!(err.contains("channel"), "got: {}", err);

        let wav = wav_pcm16(0, 1, &[0]);
        let err = parse_wav_pcm(&wav).expect_err("rate 0 must be rejected");
        assert!(err.contains("sample rate"), "got: {}", err);
    }

    #[test]
    fn rejects_short_fmt_and_truncated_data() {
        // A fmt chunk declared shorter than the 16 bytes the parser needs.
        let mut wav = wav_pcm16(48_000, 1, &[0]);
        wav[16..20].copy_from_slice(&12u32.to_le_bytes()); // fmt chunk size
        let err = parse_wav_pcm(&wav).expect_err("short fmt must be rejected");
        assert!(err.contains("too short"), "got: {}", err);

        // A data chunk whose size field overruns the file is dropped; with
        // nothing left to decode the parser reports no audio data.
        let mut wav = wav_pcm16(48_000, 1, &[1, 2]);
        wav[40..44].copy_from_slice(&1000u32.to_le_bytes()); // data chunk size
        let err = parse_wav_pcm(&wav).expect_err("truncated data must be rejected");
        assert!(err.contains("no audio data"), "got: {}", err);
    }

    // ─── Built-in SFX assets ────────────────────────────────────────

    #[test]
    fn builtin_sfx_assets_all_parse() {
        assert_eq!(SFX_BUILTIN.len(), 37);
        for (kind, sample) in SFX_BUILTIN.iter().enumerate() {
            let samples = sample
                .as_ref()
                .unwrap_or_else(|| panic!("builtin sfx kind {} failed to parse", kind));
            assert!(!samples.is_empty(), "builtin sfx kind {} is empty", kind);
        }
    }
}
