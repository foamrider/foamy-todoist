//! The commands: the state lock, the cache, the Sync exchange and Quick Add.

use std::fs::File;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use foamy_helper::Failure;
use foamy_helper::lock::FileLock;
use serde_json::{Map, Value, json};

use crate::http::{self, Body, Client};
use crate::model::{self, Change, State};
use crate::text::{message, short};
use crate::vault::SecretTool;

/// What the panel reads on every sync.
const RESOURCES: &str =
    r#"["items","projects","sections","labels","collaborators","collaborator_states","user"]"#;
/// How long a command waits for another helper's lock (sign-out waits for a
/// sync in flight). Never past the run budget.
const LOCK_WAIT: Duration = Duration::from_secs(15);
/// The cache holds at most the bounded state; anything bigger isn't ours.
const MAX_CACHE: u64 = 64 << 20;
pub const MAX_COMMANDS: usize = 100;
/// An edited description, in characters (Todoist's limit).
pub const MAX_DESCRIPTION: usize = 16_383;
/// A description `task` reads: longer ones are cut, ending in "…".
pub const MAX_READ_DESCRIPTION: usize = 16_384;
/// Labels an update sets, and each name's length in characters.
pub const MAX_UPDATE_LABELS: usize = 50;
pub const MAX_UPDATE_LABEL: usize = 60;
/// A date in words for Todoist to parse.
pub const MAX_DUE_STRING: usize = 200;
/// `task`'s reply is one task: a description at its longest, every
/// character escaped, stays far below this.
const MAX_TASK_REPLY: u64 = 1 << 20;

fn invalid(text: &str) -> Failure {
    Failure::coded("INVALID_ARGUMENT", text)
}

fn unexpected() -> Failure {
    Failure::coded("HTTP", "Todoist sent an unexpected reply.")
}

fn unknown_outcome() -> Failure {
    Failure::coded(
        "UNKNOWN_OUTCOME",
        "Todoist didn't answer. The task may have been added: check the list before adding it again.",
    )
}

fn not_found() -> Failure {
    Failure::coded("NOT_FOUND", "That task no longer exists in Todoist.")
}

fn signed_out() -> Failure {
    Failure::coded("SIGNED_OUT", "Not signed in to Todoist.")
}

fn invalid_token() -> Failure {
    Failure::coded("INVALID_TOKEN", "Todoist didn't accept the API token.")
}

/// Standard input as one JSON object; empty input is `{}`.
pub fn read_request(limit: u64) -> Result<Map<String, Value>, Failure> {
    let data = foamy_helper::io::read_stdin_limited(limit).map_err(|error| {
        if foamy_helper::io::is_over_limit(&error) {
            invalid("The request is too large.")
        } else {
            invalid("The request can't be read.")
        }
    })?;
    if data.iter().all(u8::is_ascii_whitespace) {
        return Ok(Map::new());
    }
    match serde_json::from_slice(&data) {
        Ok(Value::Object(map)) => Ok(map),
        _ => Err(invalid("The request isn't valid JSON.")),
    }
}

/// Time left of the run budget, at most `cap`.
fn within_budget(cap: Duration) -> Duration {
    foamy_helper::process::run_deadline().map_or(cap, |deadline| {
        cap.min(deadline.saturating_duration_since(Instant::now()))
    })
}

fn lock_unavailable(error: &dyn std::fmt::Display) -> Failure {
    Failure::coded(
        "LOCK_UNAVAILABLE",
        message(
            "Can't use the Todoist lock file (%1).",
            &[&short(&error.to_string(), 120)],
        ),
    )
}

/// Where the state lock lives, from what the kit's `lock::runtime_dir`
/// gave: the runtime directory (`$XDG_RUNTIME_DIR/foamy-todoist`). Its
/// `NotFound` means there is none (it says so for a caller to fall back):
/// then the cache's private directory. Any other refusal of the runtime
/// directory (a symlink, another user's, open to others) is an error with
/// that reason.
pub fn lock_dir(runtime: std::io::Result<PathBuf>) -> Result<PathBuf, Failure> {
    match runtime {
        Ok(dir) => Ok(dir),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            cache_dir().map_err(|error| lock_unavailable(&error))
        }
        Err(error) => Err(lock_unavailable(&error)),
    }
}

/// The exclusive lock every command holds while it reads or writes the
/// keyring or the cache: `state.lock` in the [`lock_dir`].
pub fn state_lock(dir: &Path, wait: Duration) -> Result<FileLock, Failure> {
    match FileLock::exclusive_within(&dir.join("state.lock"), wait) {
        Ok(Some(lock)) => Ok(lock),
        Ok(None) => Err(Failure::coded(
            "BUSY",
            "Another Todoist update is still running. Try again.",
        )),
        Err(error) => Err(lock_unavailable(&error)),
    }
}

fn cache_failure(key: &str, error: &dyn std::fmt::Display) -> Failure {
    Failure::coded("INTERNAL", message(key, &[&short(&error.to_string(), 120)]))
}

/// `$XDG_CACHE_HOME/foamy-todoist` (else `~/.cache/…`), private.
fn cache_dir() -> std::io::Result<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|home| home.is_absolute())
                .map(|home| home.join(".cache"))
        })
        .ok_or_else(|| std::io::Error::new(ErrorKind::NotFound, "no home directory"))?;
    let dir = base.join("foamy-todoist");
    foamy_helper::fs::ensure_private_dir(&dir)?;
    Ok(dir)
}

/// `cache.json` in the [`cache_dir`].
pub fn cache_file() -> Result<PathBuf, Failure> {
    cache_dir()
        .map(|dir| dir.join("cache.json"))
        .map_err(|error| cache_failure("Can't use the Todoist cache (%1).", &error))
}

/// The cached state; a missing, unreadable, oversized or corrupt cache is
/// an empty state (the next sync is a full one and replaces the file).
pub fn load(path: &Path) -> State {
    foamy_helper::fs::read_file_limited(path, MAX_CACHE)
        .ok()
        .and_then(|data| State::from_cache(&data))
        .unwrap_or_else(State::empty)
}

pub fn save(path: &Path, state: &State) -> Result<(), Failure> {
    foamy_helper::fs::write_atomic(path, &state.to_cache(), 0o600)
        .map_err(|error| cache_failure("Can't save the Todoist cache (%1).", &error))
}

fn remove(path: &Path) -> Result<(), Failure> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(cache_failure(
            "Can't remove the Todoist cache (%1).",
            &error,
        )),
    }
}

/// 1–256 printable ASCII characters, no whitespace.
pub fn valid_token(token: &str) -> bool {
    (1..=256).contains(&token.len()) && token.bytes().all(|b| (0x21..=0x7e).contains(&b))
}

/// The stored token, or why there is none.
fn stored_token(vault: &SecretTool) -> Result<String, Failure> {
    match vault.get()? {
        None => Err(signed_out()),
        Some(token) if valid_token(&token) => Ok(token),
        Some(_) => Err(invalid_token()),
    }
}

/// A failed reply as a failure: the token refused, rate limited, or the status.
fn refused(reply: &http::Reply) -> Failure {
    match reply.status {
        401 | 403 => invalid_token(),
        429 => {
            let retry_after = reply.retry_after.or_else(|| {
                reply
                    .body
                    .pointer("/error_extra/retry_after")
                    .and_then(Value::as_u64)
            });
            Failure::coded(
                "RATE_LIMITED",
                match retry_after {
                    Some(seconds) => message(
                        "Todoist is limiting requests. Try again in %1 seconds.",
                        &[&seconds.min(86_400)],
                    ),
                    None => "Todoist is limiting requests. Try again later.".to_string(),
                },
            )
        }
        status => Failure::coded("HTTP", message("Todoist answered HTTP %1.", &[&status])),
    }
}

/// The seconds a `RATE_LIMITED` failure says to wait (its message's detail).
pub fn retry_seconds(failure: &Failure) -> Option<u64> {
    if failure.code != "RATE_LIMITED" {
        return None;
    }
    let (_, detail) = failure.message.split_once(crate::text::SEPARATOR)?;
    detail.parse().ok()
}

/// UUIDs (version 4) for Sync commands, from the kernel's random source.
fn uuids(count: usize) -> Result<Vec<String>, Failure> {
    let mut bytes = vec![0u8; count * 16];
    File::open("/dev/urandom")
        .and_then(|mut random| random.read_exact(&mut bytes))
        .map_err(|error| {
            Failure::coded(
                "INTERNAL",
                message("Can't create a request id (%1).", &[&error]),
            )
        })?;
    Ok(bytes
        .chunks(16)
        .map(|chunk| {
            let mut b = [0u8; 16];
            b.copy_from_slice(chunk);
            b[6] = (b[6] & 0x0f) | 0x40;
            b[8] = (b[8] & 0x3f) | 0x80;
            let hex: String = b.iter().map(|byte| format!("{byte:02x}")).collect();
            format!(
                "{}-{}-{}-{}-{}",
                &hex[0..8],
                &hex[8..12],
                &hex[12..16],
                &hex[16..20],
                &hex[20..32]
            )
        })
        .collect())
}

/// One Sync request: `commands` (if any) and the incremental read, merged
/// into `state`. A 400 for an incremental read means Todoist no longer
/// takes the sync token: one full sync follows (the same command UUIDs, so
/// Todoist runs no command twice). It merges into a candidate (the records
/// dropped, the user kept) that replaces `state` only when it worked, so a
/// failed retry leaves `state` as it was. Returns the reply.
fn exchange(
    client: &Client,
    token: &str,
    state: &mut State,
    commands: &[Value],
) -> Result<Value, Failure> {
    let commands = (!commands.is_empty()).then(|| Value::from(commands.to_vec()).to_string());
    let mut candidate = state.clone();
    loop {
        let mut fields = vec![
            ("sync_token", candidate.sync_token.clone()),
            ("resource_types", RESOURCES.to_string()),
        ];
        if let Some(commands) = &commands {
            fields.push(("commands", commands.clone()));
        }
        let reply = client.post("/sync", token, Body::Form(&fields))?;
        match reply.status {
            200 => {
                candidate
                    .merge(&reply.body, &model::now_rfc3339())
                    .map_err(|()| unexpected())?;
                *state = candidate;
                return Ok(reply.body);
            }
            400 if !candidate.is_full() => candidate.reset(),
            _ => return Err(refused(&reply)),
        }
    }
}

/// A command's result from `sync_status`: "ok" or `{code, error}`.
fn result(reply: &Value, uuid: &str) -> Value {
    match reply.pointer(&format!("/sync_status/{uuid}")) {
        Some(Value::String(ok)) if ok == "ok" => json!("ok"),
        Some(Value::Object(error)) => {
            let code = error
                .get("error_tag")
                .and_then(Value::as_str)
                .filter(|tag| {
                    !tag.is_empty()
                        && tag.len() <= 64
                        && tag.bytes().all(|b| b.is_ascii_uppercase() || b == b'_')
                })
                .unwrap_or("HTTP");
            let detail = error.get("error").and_then(Value::as_str).unwrap_or("");
            json!({
                "code": code,
                "error": message("Todoist didn't accept the change (%1).", &[&short(detail, 120)]),
            })
        }
        _ => json!({"code": "INTERNAL", "error": "Todoist didn't confirm the change."}),
    }
}

/// The paths and tools a command works with.
pub struct Context {
    pub vault: SecretTool,
    /// The [`lock_dir`], or why there is none.
    pub lock_dir: Result<PathBuf, Failure>,
}

impl Context {
    fn lock(&self) -> Result<FileLock, Failure> {
        let dir = self.lock_dir.as_ref().map_err(Failure::clone)?;
        state_lock(dir, within_budget(LOCK_WAIT))
    }

    fn client() -> Result<Client, Failure> {
        Ok(Client::new(http::base()?, http::TIMEOUT))
    }

    /// `{"ok":true,"state":…,"user":…}`, no network. A stored value that
    /// isn't a token is `INVALID_TOKEN`, as in every other command.
    pub fn status(&self) -> Result<Value, Failure> {
        let _lock = self.lock()?;
        match stored_token(&self.vault) {
            Ok(_) => {}
            Err(failure) if failure.code == "SIGNED_OUT" => {
                return Ok(json!({"ok": true, "state": "signed_out", "user": null}));
            }
            Err(failure) => return Err(failure),
        }
        let state = load(&cache_file()?);
        Ok(json!({"ok": true, "state": "signed_in", "user": state.user}))
    }

    pub fn token_set(&self, request: &Map<String, Value>) -> Result<Value, Failure> {
        let token = request
            .get("token")
            .and_then(Value::as_str)
            .filter(|token| valid_token(token))
            .ok_or_else(|| invalid("Enter the API token: 1 to 256 characters, no spaces."))?;
        let client = Context::client()?;
        let _lock = self.lock()?;
        // Everything that can fail comes before the token is stored: once
        // it is, the reply is signed_in (a cache that can't be written
        // after that is a warning).
        let path = cache_file()?;
        let fields = [
            ("sync_token", "*".to_string()),
            ("resource_types", r#"["user"]"#.to_string()),
        ];
        let reply = client.post("/sync", token, Body::Form(&fields))?;
        if reply.status != 200 {
            return Err(refused(&reply));
        }
        let user = reply
            .body
            .get("user")
            .and_then(model::normalize_user)
            .ok_or_else(unexpected)?;
        // Another account's tasks never show under this one: the old cache
        // goes before the token is stored, so a cache that can't be removed
        // leaves the previous token and its cache together.
        remove(&path)?;
        self.vault.put(token)?;
        let mut state = State::empty();
        state.user = Some(user.clone());
        let mut out = json!({"ok": true, "state": "signed_in", "user": user});
        if let Err(failure) = save(&path, &state) {
            out["warning"] = json!(failure.message);
        }
        Ok(out)
    }

    pub fn token_clear(&self) -> Result<Value, Failure> {
        let _lock = self.lock()?;
        self.vault.delete()?;
        remove(&cache_file()?)?;
        Ok(json!({"ok": true, "state": "signed_out", "user": null}))
    }

    pub fn sync(&self, request: &Map<String, Value>) -> Result<Value, Failure> {
        let client = Context::client()?;
        let _lock = self.lock()?;
        let token = stored_token(&self.vault)?;
        let path = cache_file()?;
        let mut state = load(&path);
        if request.get("full").and_then(Value::as_bool) == Some(true) {
            state.reset();
        }
        exchange(&client, &token, &mut state, &[])?;
        save(&path, &state)?;
        Ok(reply(&state))
    }

    pub fn apply(&self, request: &Map<String, Value>) -> Result<Value, Failure> {
        let changes = parse_changes(request)?;
        let client = Context::client()?;
        let _lock = self.lock()?;
        let token = stored_token(&self.vault)?;
        let path = cache_file()?;
        let mut state = load(&path);
        // Each change is one or two Sync commands (an update and a move);
        // `planned` keeps which UUIDs belong to which task.
        let mut commands = Vec::new();
        let mut planned = Vec::with_capacity(changes.len());
        for change in &changes {
            let parts = change.commands();
            let ids = uuids(parts.len())?;
            for ((kind, args), uuid) in parts.into_iter().zip(&ids) {
                commands.push(json!({"type": kind, "uuid": uuid, "args": args}));
            }
            planned.push((change.id(), ids));
        }
        // Todoist takes at most 100 commands per request; an update with a
        // move is two, so check the expanded count, not the changes.
        if commands.len() > MAX_COMMANDS {
            return Err(invalid(
                "These changes need more than 100 Todoist commands. Send fewer at a time.",
            ));
        }
        let sync_reply = exchange(&client, &token, &mut state, &commands)?;
        // One result per task: its first command that failed, else "ok".
        let mut results = Map::new();
        for (id, ids) in planned {
            let outcome = ids
                .iter()
                .map(|uuid| result(&sync_reply, uuid))
                .find(|outcome| outcome != "ok")
                .unwrap_or_else(|| json!("ok"));
            results.insert(id.to_string(), outcome);
        }
        let mut out = reply(&state);
        out["results"] = Value::Object(results);
        // The changes are made in Todoist: a cache that can't be saved is a
        // warning (the next sync brings them again), not a failure.
        if let Err(failure) = save(&path, &state) {
            out["warning"] = json!(failure.message);
        }
        Ok(out)
    }

    pub fn add(&self, request: &Map<String, Value>) -> Result<Value, Failure> {
        let add = parse_add(request)?;
        let client = Context::client()?;
        let _lock = self.lock()?;
        let token = stored_token(&self.vault)?;
        let path = cache_file()?;
        let mut state = load(&path);
        // Quick Add has no idempotency key: once the request went out, a lost
        // answer means the task may exist. Saying so keeps the panel from
        // adding it twice without the user deciding.
        let reply_body = client
            .post(
                "/tasks/quick",
                &token,
                Body::Json(&json!({"text": add.text})),
            )
            .map_err(|failure| {
                if client.request_sent() {
                    unknown_outcome()
                } else {
                    failure
                }
            })?;
        if !(200..300).contains(&reply_body.status) {
            return Err(refused(&reply_body));
        }
        let created = reply_body.body;
        // A 2xx without a usable task id (empty, not JSON, no id): Todoist
        // accepted the request, so the task may exist; never "failed".
        let id = created
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| model::valid_id(id))
            .ok_or_else(unknown_outcome)?
            .to_string();
        let inbox = state
            .user
            .as_ref()
            .and_then(|user| user.get("inbox_project_id"))
            .and_then(Value::as_str)
            .map(str::to_string);
        let landed = created.get("project_id").and_then(Value::as_str);
        // Quick Add's own #project or date wins; only a task that has none
        // gets the view's project or date.
        let mut commands = Vec::new();
        if let Some(date) = &add.due_date
            && created.get("due").is_none_or(Value::is_null)
        {
            commands.push(("item_update", json!({"id": id, "due": {"date": date}})));
        }
        // Landing in the Inbox may be what the text asked for (`#Inbox`):
        // move only a task whose text names no project.
        if let (Some(project), Some(inbox)) = (&add.project_id, &inbox)
            && project != inbox
            && landed == Some(inbox.as_str())
            && !names_project(&add.text)
        {
            commands.push(("item_move", json!({"id": id, "project_id": project})));
        }
        let ids = uuids(commands.len())?;
        let commands: Vec<Value> = commands
            .into_iter()
            .zip(&ids)
            .map(|((kind, args), uuid)| json!({"type": kind, "uuid": uuid, "args": args}))
            .collect();
        // Set when the follow-up sync failed: the snapshot is the cache plus
        // the new task, not a fresh read.
        let mut follow_up_failed: Option<Failure> = None;
        let mut warning = match exchange(&client, &token, &mut state, &commands) {
            Ok(sync_reply) => ids
                .iter()
                .map(|uuid| result(&sync_reply, uuid))
                .find(|result| result != "ok")
                .and_then(|result| result["error"].as_str().map(str::to_string)),
            // The task exists in Todoist: never report the add as failed
            // (adding again would make a second one). Show the created task
            // and say what didn't follow.
            Err(failure) => {
                if let Change::Keep(key, task) = model::normalize_task(&created) {
                    state.tasks.insert(key, task);
                }
                let message = failure.message.clone();
                follow_up_failed = Some(failure);
                Some(message)
            }
        };
        let mut out = reply(&state);
        out["added"] = json!(id);
        if let Some(failure) = follow_up_failed {
            out["stale"] = json!(true);
            out["warning_code"] = json!(failure.code);
            if let Some(seconds) = retry_seconds(&failure) {
                out["retry_after"] = json!(seconds);
            }
        }
        if let Err(failure) = save(&path, &state) {
            warning.get_or_insert(failure.message);
        }
        if let Some(warning) = warning {
            out["warning"] = json!(warning);
        }
        Ok(out)
    }
}

impl Context {
    /// One task's description, read from Todoist (`GET /tasks/{id}`) when
    /// the editor opens; nothing is cached. The lock is held only while the
    /// token is read: this writes nothing, so a sign-out meanwhile can't be
    /// undone by it.
    pub fn task(&self, request: &Map<String, Value>) -> Result<Value, Failure> {
        let id = request
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| model::valid_id(id))
            .ok_or_else(|| invalid("That isn't a Todoist task id."))?;
        let client = Context::client()?.with_max_bytes(MAX_TASK_REPLY);
        let token = {
            let _lock = self.lock()?;
            stored_token(&self.vault)?
        };
        // The id is letters, digits, `_` and `-` only: safe in the path.
        let reply = client.get(&format!("/tasks/{id}"), &token)?;
        match reply.status {
            200 => {}
            404 => return Err(not_found()),
            _ => return Err(refused(&reply)),
        }
        let body = &reply.body;
        if body.get("id").and_then(Value::as_str) != Some(id) {
            return Err(unexpected());
        }
        // Completed or deleted: gone as far as the panel is concerned.
        let flag = |key: &str| body.get(key).and_then(Value::as_bool) == Some(true);
        if flag("checked") || flag("is_deleted") {
            return Err(not_found());
        }
        let description = match body.get("description") {
            None | Some(Value::Null) => "",
            Some(Value::String(text)) => text.as_str(),
            Some(_) => return Err(unexpected()),
        };
        let truncated = description.chars().count() > MAX_READ_DESCRIPTION;
        Ok(json!({"ok": true, "task": {
            "id": id,
            "description": model::cap(description, MAX_READ_DESCRIPTION),
            "truncated": truncated,
        }}))
    }
}

fn reply(state: &State) -> Value {
    let mut out = state.snapshot();
    out["ok"] = json!(true);
    out
}

/// One change `apply` makes.
#[derive(Debug, PartialEq)]
pub enum Edit {
    Close(String),
    Due(String, String),
    Update(Update),
}

/// An `update`: the `item_update` fields to set, and where to move the task.
#[derive(Debug, PartialEq)]
pub struct Update {
    pub id: String,
    /// `item_update`'s arguments besides `id`, already in Todoist's shape.
    pub fields: Map<String, Value>,
    pub moved: Option<Move>,
}

/// An `item_move` destination: exactly one of these goes to Todoist.
#[derive(Debug, PartialEq)]
pub enum Move {
    /// The project's root (no section).
    Project(String),
    Section(String),
}

impl Edit {
    fn id(&self) -> &str {
        match self {
            Edit::Close(id) | Edit::Due(id, _) => id,
            Edit::Update(update) => &update.id,
        }
    }

    /// The Sync commands (type, args) this change needs: one or two.
    fn commands(&self) -> Vec<(&'static str, Value)> {
        match self {
            Edit::Close(id) => vec![("item_close", json!({"id": id}))],
            Edit::Due(id, date) => {
                vec![("item_update", json!({"id": id, "due": {"date": date}}))]
            }
            Edit::Update(update) => {
                let mut out = Vec::new();
                if !update.fields.is_empty() {
                    let mut args = update.fields.clone();
                    args.insert("id".into(), json!(update.id));
                    out.push(("item_update", Value::Object(args)));
                }
                if let Some(moved) = &update.moved {
                    let (key, target) = match moved {
                        Move::Project(project) => ("project_id", project),
                        Move::Section(section) => ("section_id", section),
                    };
                    out.push(("item_move", json!({"id": update.id, key: target})));
                }
                out
            }
        }
    }
}

/// `{"commands":[…]}`: 1–100 changes, at most one per task. `close`
/// `{"op","id"}`, `due` `{"op","id","date":"YYYY-MM-DD"}`, `update` (see
/// [`parse_update`]).
pub fn parse_changes(request: &Map<String, Value>) -> Result<Vec<Edit>, Failure> {
    let list = request
        .get("commands")
        .and_then(Value::as_array)
        .filter(|list| (1..=MAX_COMMANDS).contains(&list.len()))
        .ok_or_else(|| invalid("Send 1 to 100 changes at a time."))?;
    let mut edits: Vec<Edit> = Vec::with_capacity(list.len());
    for entry in list {
        let id = entry
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| model::valid_id(id))
            .ok_or_else(|| invalid("That isn't a Todoist task id."))?
            .to_string();
        if edits.iter().any(|edit| edit.id() == id) {
            return Err(invalid("The same task is changed twice."));
        }
        edits.push(match entry.get("op").and_then(Value::as_str) {
            Some("close") => Edit::Close(id),
            Some("due") => {
                let date = entry
                    .get("date")
                    .and_then(Value::as_str)
                    .filter(|date| model::valid_date(date))
                    .ok_or_else(|| invalid("Enter a date as YYYY-MM-DD."))?;
                Edit::Due(id, date.to_string())
            }
            Some("update") => Edit::Update(parse_update(id, entry)?),
            _ => return Err(invalid("Unknown change.")),
        });
    }
    Ok(edits)
}

const UPDATE_KEYS: [&str; 10] = [
    "id",
    "op",
    "content",
    "description",
    "priority",
    "labels",
    "due_string",
    "deadline",
    "project_id",
    "section_id",
];

// The update's refusals that more than one check gives (catalog keys).
fn no_content() -> Failure {
    invalid("Enter a task.")
}

fn bad_project() -> Failure {
    invalid("That isn't a Todoist project id.")
}

fn bad_section() -> Failure {
    invalid("That isn't a Todoist section id.")
}

fn long_description() -> Failure {
    invalid("A description can have at most 16383 characters.")
}

fn bad_labels() -> Failure {
    invalid("Give at most 50 labels of 1 to 60 characters each, without control characters.")
}

fn bad_due_string() -> Failure {
    invalid("Enter the date in words, at most 200 characters.")
}

fn bad_deadline() -> Failure {
    invalid("Enter a deadline as YYYY-MM-DD.")
}

/// Text without control characters; `keep` lists the ones allowed.
fn plain(text: &str, keep: &[char]) -> bool {
    !text.chars().any(|c| c.is_control() && !keep.contains(&c))
}

/// An `update`: at least one field, each optional, unknown keys refused.
/// `content` 1–500 characters after trimming, one line; `description`
/// 0–16 383, line breaks and tabs allowed ("" clears it); `priority` 1–4
/// (Todoist's: 4 is p1); `labels` 0–100 names of 1–60 characters, each
/// once ignoring case; `due_string` words for Todoist to parse, at most
/// 200 characters ("" removes the date); `deadline` `YYYY-MM-DD` ("" removes
/// it); `project_id` moves the task to that project's root; `section_id`
/// moves it into that section ("" is the root of `project_id`, which it
/// then needs).
pub fn parse_update(id: String, entry: &Value) -> Result<Update, Failure> {
    let Some(map) = entry.as_object() else {
        return Err(invalid("Unknown change."));
    };
    if map.keys().any(|key| !UPDATE_KEYS.contains(&key.as_str())) {
        return Err(invalid("Unknown change."));
    }
    let text = |key: &str, error: fn() -> Failure| -> Result<Option<&str>, Failure> {
        match map.get(key) {
            None => Ok(None),
            Some(Value::String(value)) => Ok(Some(value.as_str())),
            Some(_) => Err(error()),
        }
    };
    let mut fields = Map::new();
    if let Some(content) = text("content", no_content)? {
        let content = content.trim();
        if content.is_empty() {
            return Err(no_content());
        }
        if content.chars().count() > model::MAX_CONTENT {
            return Err(invalid("A task can have at most 500 characters."));
        }
        if !plain(content, &[]) {
            return Err(invalid(
                "A task can't have line breaks or other control characters.",
            ));
        }
        fields.insert("content".into(), json!(content));
    }
    if let Some(description) = text("description", long_description)? {
        if description.chars().count() > MAX_DESCRIPTION {
            return Err(long_description());
        }
        if !plain(description, &['\n', '\r', '\t']) {
            return Err(invalid(
                "A description can't have control characters other than line breaks and tabs.",
            ));
        }
        fields.insert("description".into(), json!(description));
    }
    if let Some(priority) = map.get("priority") {
        let priority = priority
            .as_i64()
            .filter(|priority| (1..=4).contains(priority))
            .ok_or_else(|| invalid("Pick a priority from 1 to 4."))?;
        fields.insert("priority".into(), json!(priority));
    }
    if let Some(labels) = map.get("labels") {
        let list = labels
            .as_array()
            .filter(|list| list.len() <= MAX_UPDATE_LABELS)
            .ok_or_else(bad_labels)?;
        let mut seen = std::collections::BTreeSet::new();
        let mut names = Vec::with_capacity(list.len());
        for label in list {
            let name = label
                .as_str()
                .filter(|name| {
                    !name.trim().is_empty()
                        && name.chars().count() <= MAX_UPDATE_LABEL
                        && plain(name, &[])
                })
                .ok_or_else(bad_labels)?;
            if !seen.insert(name.to_lowercase()) {
                return Err(invalid("A label is given twice."));
            }
            names.push(json!(name));
        }
        fields.insert("labels".into(), Value::Array(names));
    }
    if let Some(due) = text("due_string", bad_due_string)? {
        if due.is_empty() {
            fields.insert("due".into(), Value::Null);
        } else {
            let due = due.trim();
            if due.is_empty() || due.chars().count() > MAX_DUE_STRING || !plain(due, &[]) {
                return Err(bad_due_string());
            }
            fields.insert("due".into(), json!({"string": due}));
        }
    }
    if let Some(deadline) = text("deadline", bad_deadline)? {
        if deadline.is_empty() {
            fields.insert("deadline".into(), Value::Null);
        } else if model::valid_date(deadline) {
            fields.insert("deadline".into(), json!({"date": deadline}));
        } else {
            return Err(bad_deadline());
        }
    }
    let project = text("project_id", bad_project)?;
    if project.is_some_and(|project| !model::valid_id(project)) {
        return Err(bad_project());
    }
    let section = text("section_id", bad_section)?;
    // A section implies its project, so only one destination goes to
    // Todoist, as `item_move` requires.
    let moved = match (project, section) {
        (_, Some(section)) if model::valid_id(section) => Some(Move::Section(section.into())),
        (Some(project), Some("")) | (Some(project), None) => Some(Move::Project(project.into())),
        (None, Some("")) => {
            return Err(invalid(
                "Moving a task out of its section needs the project's id.",
            ));
        }
        (_, Some(_)) => return Err(bad_section()),
        (None, None) => None,
    };
    if fields.is_empty() && moved.is_none() {
        return Err(invalid("The change has nothing to update."));
    }
    Ok(Update { id, fields, moved })
}

/// Whether Quick Add text has a `#project` token: `#` at the start or after
/// whitespace, followed by a non-space (`C#` and `email#1` are not).
pub fn names_project(text: &str) -> bool {
    let mut before = None::<char>;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '#'
            && before.is_none_or(char::is_whitespace)
            && chars.peek().is_some_and(|next| !next.is_whitespace())
        {
            return true;
        }
        before = Some(c);
    }
    false
}

#[derive(Debug, PartialEq)]
pub struct Add {
    pub text: String,
    pub due_date: Option<String>,
    pub project_id: Option<String>,
}

/// `{"text":…,"due_date":"YYYY-MM-DD"|null,"project_id":…|null}`.
pub fn parse_add(request: &Map<String, Value>) -> Result<Add, Failure> {
    let text = request
        .get("text")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty())
        .ok_or_else(|| invalid("Enter a task."))?;
    if text.chars().count() > model::MAX_CONTENT {
        return Err(invalid("A task can have at most 500 characters."));
    }
    let optional =
        |key: &str, valid: fn(&str) -> bool, error: &str| -> Result<Option<String>, Failure> {
            match request.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(value)) if valid(value) => Ok(Some(value.clone())),
                _ => Err(invalid(error)),
            }
        };
    Ok(Add {
        text: text.to_string(),
        due_date: optional("due_date", model::valid_date, "Enter a date as YYYY-MM-DD.")?,
        project_id: optional(
            "project_id",
            model::valid_id,
            "That isn't a Todoist project id.",
        )?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn tokens_are_printable_ascii_without_spaces() {
        assert!(valid_token("0123456789abcdef0123456789abcdef01234567"));
        for bad in ["", "a b", "tab\there", "é", &"x".repeat(257), "line\n"] {
            assert!(!valid_token(bad), "{bad:?}");
        }
    }

    #[test]
    fn changes_are_validated() {
        let ok = parse_changes(&map(json!({"commands": [
            {"op": "close", "id": "T1"}, {"op": "due", "id": "T2", "date": "2026-11-17"}
        ]})))
        .unwrap();
        assert_eq!(
            ok,
            [
                Edit::Close("T1".into()),
                Edit::Due("T2".into(), "2026-11-17".into())
            ]
        );
        let hundred: Vec<Value> = (0..100)
            .map(|i| json!({"op": "close", "id": format!("T{i}")}))
            .collect();
        assert_eq!(
            parse_changes(&map(json!({"commands": hundred})))
                .unwrap()
                .len(),
            100
        );
        let too_many: Vec<Value> = (0..101)
            .map(|i| json!({"op": "close", "id": format!("T{i}")}))
            .collect();
        for (bad, message) in [
            (json!({}), "Send 1 to 100 changes at a time."),
            (json!({"commands": []}), "Send 1 to 100 changes at a time."),
            (
                json!({"commands": too_many}),
                "Send 1 to 100 changes at a time.",
            ),
            (
                json!({"commands": [{"op": "close", "id": "../x"}]}),
                "That isn't a Todoist task id.",
            ),
            (
                json!({"commands": [{"op": "due", "id": "T1", "date": "2026-02-30"}]}),
                "Enter a date as YYYY-MM-DD.",
            ),
            (
                json!({"commands": [{"op": "delete", "id": "T1"}]}),
                "Unknown change.",
            ),
            (
                json!({"commands": [{"op": "close", "id": "T1"}, {"op": "due", "id": "T1", "date": "2026-11-17"}]}),
                "The same task is changed twice.",
            ),
        ] {
            let failure = parse_changes(&map(bad.clone())).unwrap_err();
            assert_eq!(
                (failure.code.as_str(), failure.message.as_str()),
                ("INVALID_ARGUMENT", message),
                "{bad}"
            );
        }
    }

    fn update(fields: Value) -> Result<Update, Failure> {
        let mut entry = fields;
        entry["op"] = json!("update");
        entry["id"] = json!("T1");
        match parse_changes(&map(json!({"commands": [entry]})))?.pop() {
            Some(Edit::Update(update)) => Ok(update),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn update_fields_take_todoists_shape() {
        let all = update(json!({
            "content": "  Call Bob  ", "description": "line 1\nline 2\ttab", "priority": 4,
            "labels": ["home", "Høst 2026"], "due_string": " every monday 9am ",
            "deadline": "2026-12-01"
        }))
        .unwrap();
        assert_eq!(
            Value::Object(all.fields),
            json!({"content": "Call Bob", "description": "line 1\nline 2\ttab", "priority": 4,
                   "labels": ["home", "Høst 2026"], "due": {"string": "every monday 9am"},
                   "deadline": {"date": "2026-12-01"}})
        );
        assert_eq!(all.moved, None);
        // "" clears: the description to "", the date and the deadline to null.
        let cleared =
            update(json!({"description": "", "due_string": "", "deadline": "", "labels": []}))
                .unwrap();
        assert_eq!(
            Value::Object(cleared.fields),
            json!({"description": "", "due": null, "deadline": null, "labels": []})
        );
        // Bounds, at the limit.
        let longest = update(json!({
            "content": "é".repeat(500), "description": "é".repeat(MAX_DESCRIPTION),
            "labels": (0..MAX_UPDATE_LABELS).map(|n| format!("{n:0>60}")).collect::<Vec<_>>(),
            "due_string": "x".repeat(200), "priority": 1
        }));
        assert!(longest.is_ok(), "{longest:?}");
    }

    #[test]
    fn update_shapes_are_refused_with_their_message() {
        for (bad, message) in [
            (json!({}), "The change has nothing to update."),
            (json!({"title": "x"}), "Unknown change."),
            (
                json!({"content": "x", "date": "2026-11-17"}),
                "Unknown change.",
            ),
            (json!({"content": "   "}), "Enter a task."),
            (json!({"content": 5}), "Enter a task."),
            (
                json!({"content": "é".repeat(501)}),
                "A task can have at most 500 characters.",
            ),
            (
                json!({"content": "a\nb"}),
                "A task can't have line breaks or other control characters.",
            ),
            (
                json!({"content": "a\u{0}b"}),
                "A task can't have line breaks or other control characters.",
            ),
            (
                json!({"content": "a\u{85}b"}),
                "A task can't have line breaks or other control characters.",
            ),
            (
                json!({"description": "x".repeat(MAX_DESCRIPTION + 1)}),
                "A description can have at most 16383 characters.",
            ),
            (
                json!({"description": null}),
                "A description can have at most 16383 characters.",
            ),
            (
                json!({"description": "a\u{1b}[31m"}),
                "A description can't have control characters other than line breaks and tabs.",
            ),
            (json!({"priority": 0}), "Pick a priority from 1 to 4."),
            (json!({"priority": 5}), "Pick a priority from 1 to 4."),
            (json!({"priority": 2.5}), "Pick a priority from 1 to 4."),
            (json!({"priority": "4"}), "Pick a priority from 1 to 4."),
            (
                json!({"labels": "home"}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": (0..=MAX_UPDATE_LABELS).map(|n| format!("l{n}")).collect::<Vec<_>>()}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": [""]}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": ["  "]}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": ["x".repeat(61)]}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": ["a\tb"]}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": [5]}),
                "Give at most 50 labels of 1 to 60 characters each, without control characters.",
            ),
            (
                json!({"labels": ["Home", "home"]}),
                "A label is given twice.",
            ),
            (
                json!({"due_string": "   "}),
                "Enter the date in words, at most 200 characters.",
            ),
            (
                json!({"due_string": "x".repeat(201)}),
                "Enter the date in words, at most 200 characters.",
            ),
            (
                json!({"due_string": "tomorrow\n9am"}),
                "Enter the date in words, at most 200 characters.",
            ),
            (
                json!({"due_string": null}),
                "Enter the date in words, at most 200 characters.",
            ),
            (
                json!({"deadline": "2026-02-30"}),
                "Enter a deadline as YYYY-MM-DD.",
            ),
            (
                json!({"deadline": "tomorrow"}),
                "Enter a deadline as YYYY-MM-DD.",
            ),
            (json!({"deadline": null}), "Enter a deadline as YYYY-MM-DD."),
            (
                json!({"project_id": ""}),
                "That isn't a Todoist project id.",
            ),
            (
                json!({"project_id": "../P"}),
                "That isn't a Todoist project id.",
            ),
            (json!({"project_id": 2}), "That isn't a Todoist project id."),
            (
                json!({"section_id": "a b"}),
                "That isn't a Todoist section id.",
            ),
            (
                json!({"section_id": null}),
                "That isn't a Todoist section id.",
            ),
            (
                json!({"section_id": ""}),
                "Moving a task out of its section needs the project's id.",
            ),
        ] {
            let failure = update(bad.clone()).unwrap_err();
            assert_eq!(
                (failure.code.as_str(), failure.message.as_str()),
                ("INVALID_ARGUMENT", message),
                "{bad}"
            );
        }
    }

    #[test]
    fn an_update_is_an_item_update_and_a_move() {
        let edit = |id: &str, fields: Value| {
            let mut entry = fields;
            entry["op"] = json!("update");
            entry["id"] = json!(id);
            parse_changes(&map(json!({"commands": [entry]})))
                .unwrap()
                .pop()
                .unwrap()
        };
        assert_eq!(
            edit("T1", json!({"content": "x", "project_id": "P2"})).commands(),
            [
                ("item_update", json!({"id": "T1", "content": "x"})),
                ("item_move", json!({"id": "T1", "project_id": "P2"}))
            ]
        );
        assert_eq!(
            edit("T1", json!({"section_id": "S1"})).commands(),
            [("item_move", json!({"id": "T1", "section_id": "S1"}))]
        );
        assert_eq!(
            edit("T1", json!({"priority": 2})).commands(),
            [("item_update", json!({"id": "T1", "priority": 2}))]
        );
        // Out of the section to the project's root.
        assert_eq!(
            edit("T2", json!({"project_id": "P2", "section_id": ""})).commands(),
            [("item_move", json!({"id": "T2", "project_id": "P2"}))]
        );
        // A requested place is sent even when the cache says the task is
        // there already: the cache may be stale.
        assert_eq!(
            edit("T2", json!({"project_id": "P2", "section_id": "S1"})).commands(),
            [("item_move", json!({"id": "T2", "section_id": "S1"}))]
        );
    }

    #[test]
    fn an_add_is_validated() {
        assert_eq!(
            parse_add(&map(json!({"text": "Milk #Shop", "due_date": null}))).unwrap(),
            Add {
                text: "Milk #Shop".into(),
                due_date: None,
                project_id: None,
            }
        );
        let full = parse_add(&map(
            json!({"text": "é".repeat(500), "due_date": "2026-11-17", "project_id": "P2"}),
        ))
        .unwrap();
        assert_eq!(full.due_date.as_deref(), Some("2026-11-17"));
        for (bad, message) in [
            (json!({}), "Enter a task."),
            (json!({"text": "   "}), "Enter a task."),
            (
                json!({"text": "é".repeat(501)}),
                "A task can have at most 500 characters.",
            ),
            (
                json!({"text": "x", "due_date": "tomorrow"}),
                "Enter a date as YYYY-MM-DD.",
            ),
            (
                json!({"text": "x", "due_date": "2026-02-30"}),
                "Enter a date as YYYY-MM-DD.",
            ),
            (
                json!({"text": "x", "project_id": 5}),
                "That isn't a Todoist project id.",
            ),
            (
                json!({"text": "x", "project_id": "../P"}),
                "That isn't a Todoist project id.",
            ),
        ] {
            let failure = parse_add(&map(bad.clone())).unwrap_err();
            assert_eq!(
                (failure.code.as_str(), failure.message.as_str()),
                ("INVALID_ARGUMENT", message),
                "{bad}"
            );
        }
    }

    #[test]
    fn a_project_token_is_a_hash_starting_a_word() {
        for yes in ["#Inbox", "Buy milk #Inbox", "a\t#b", "x\n#Work now", "#é"] {
            assert!(names_project(yes), "{yes:?}");
        }
        for no in [
            "",
            "#",
            "a # b",
            "C# books",
            "email#1",
            "trailing #",
            "no hash",
        ] {
            assert!(!names_project(no), "{no:?}");
        }
    }

    #[test]
    fn command_ids_are_version_4_uuids() {
        let ids = uuids(3).unwrap();
        assert_eq!(ids.len(), 3);
        assert_ne!(ids[0], ids[1]);
        for id in ids {
            assert_eq!(id.len(), 36);
            assert_eq!(&id[14..15], "4");
            assert!("89ab".contains(&id[19..20]), "{id}");
        }
    }

    #[test]
    fn command_results_are_read_from_sync_status() {
        let reply = json!({"sync_status": {
            "a": "ok",
            "b": {"error_tag": "ITEM_NOT_FOUND", "error_code": 22, "error": "Task not found", "http_code": 404},
            "c": {"error_tag": "bad tag!", "error": "x"}
        }});
        assert_eq!(result(&reply, "a"), "ok");
        assert_eq!(
            result(&reply, "b"),
            json!({"code": "ITEM_NOT_FOUND", "error": "Todoist didn't accept the change (%1).\u{1f}Task not found"})
        );
        assert_eq!(result(&reply, "c")["code"], "HTTP");
        assert_eq!(result(&reply, "missing")["code"], "INTERNAL");
    }

    #[test]
    fn a_held_lock_is_busy_and_a_missing_dir_unavailable() {
        let dir = std::env::temp_dir().join(format!("foamy-todoist-lock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let held = state_lock(&dir, Duration::ZERO).unwrap();
        let started = Instant::now();
        let busy = state_lock(&dir, Duration::from_millis(100)).unwrap_err();
        assert_eq!(busy.code, "BUSY");
        assert!(started.elapsed() >= Duration::from_millis(100));
        drop(held);
        assert!(state_lock(&dir, Duration::ZERO).is_ok());
        assert_eq!(
            state_lock(&dir.join("missing"), Duration::ZERO)
                .unwrap_err()
                .code,
            "LOCK_UNAVAILABLE"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
