mod api;

use crossbeam::queue::SegQueue;
use crossbeam::atomic::AtomicCell;
use dashmap::DashMap;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64};
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
    #[serde(rename = "connected")]
    Connected { server_name: String, client_id: u32, ask_for_privilegekey: bool },
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
/// Writer: decoding thread (one per client). Reader: cpal audio callback.
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
        }
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
    // Audio receive state
    pub talking_clients: HashMap<u16, Instant>, // last audio timestamp per client (monotonic Instant)
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
            talking_clients: HashMap::new(),
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
/// Refreshed by the maintenance task every 500ms. Lock-free via ArcSwap.
pub static ACTIVE_CLIENT_IDS: Lazy<arc_swap::ArcSwap<Vec<u16>>> =
    Lazy::new(|| arc_swap::ArcSwap::from(std::sync::Arc::new(Vec::new())));
/// RMS of the most recent native-capture mic block (f32::to_bits, 0..1).
/// Published by the cpal input callback (desktop / iOS), read by
/// ts_get_mic_rms for the UI level meter. 0 = silence / capture inactive.
pub static MIC_RMS: AtomicU32 = AtomicU32::new(0);

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
/// Rejects non-RIFF/WAVE input, other encodings, files without audio data,
/// and files longer than 2 seconds.
pub(crate) fn parse_wav_pcm(data: &[u8]) -> Result<Vec<f32>, String> {
    const MAX_SECONDS: f64 = 2.0;
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
    fn rejects_too_long() {
        // 48000 Hz * 2.1 s = 100_800 frames > 2 s limit.
        let samples = vec![0i16; 100_800];
        let wav = wav_pcm16(48_000, 1, &samples);
        let err = parse_wav_pcm(&wav).expect_err(">2s WAV should be rejected");
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
}
