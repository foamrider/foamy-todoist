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

/// The exclusive lock every command holds while it reads or writes the
/// keyring or the cache: `$XDG_RUNTIME_DIR/foamy-todoist/state.lock`.
pub fn state_lock(dir: Option<&Path>, wait: Duration) -> Result<FileLock, Failure> {
    let dir = dir.ok_or_else(|| {
        Failure::coded(
            "LOCK_UNAVAILABLE",
            message(
                "Can't use the Todoist lock file (%1).",
                &[&"no XDG_RUNTIME_DIR"],
            ),
        )
    })?;
    match FileLock::exclusive_within(&dir.join("state.lock"), wait) {
        Ok(Some(lock)) => Ok(lock),
        Ok(None) => Err(Failure::coded(
            "BUSY",
            "Another Todoist update is still running. Try again.",
        )),
        Err(error) => Err(Failure::coded(
            "LOCK_UNAVAILABLE",
            message(
                "Can't use the Todoist lock file (%1).",
                &[&short(&error.to_string(), 120)],
            ),
        )),
    }
}

fn cache_failure(key: &str, error: &dyn std::fmt::Display) -> Failure {
    Failure::coded("INTERNAL", message(key, &[&short(&error.to_string(), 120)]))
}

/// `$XDG_CACHE_HOME/foamy-todoist/cache.json` (else `~/.cache/…`), its
/// directory private.
pub fn cache_file() -> Result<PathBuf, Failure> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|home| home.is_absolute())
                .map(|home| home.join(".cache"))
        })
        .ok_or_else(|| cache_failure("Can't use the Todoist cache (%1).", &"no home directory"))?;
    let dir = base.join("foamy-todoist");
    foamy_helper::fs::ensure_private_dir(&dir)
        .map_err(|error| cache_failure("Can't use the Todoist cache (%1).", &error))?;
    Ok(dir.join("cache.json"))
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
    pub lock_dir: Option<PathBuf>,
}

impl Context {
    fn lock(&self) -> Result<FileLock, Failure> {
        state_lock(self.lock_dir.as_deref(), within_budget(LOCK_WAIT))
    }

    fn client() -> Result<Client, Failure> {
        Ok(Client::new(http::base()?, http::TIMEOUT))
    }

    /// `{"ok":true,"state":…,"user":…}`, no network.
    pub fn status(&self) -> Result<Value, Failure> {
        let _lock = self.lock()?;
        if self.vault.get()?.is_none() {
            return Ok(json!({"ok": true, "state": "signed_out", "user": null}));
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
        self.vault.put(token)?;
        // Another account's tasks never show under this one: a new cache.
        let mut state = State::empty();
        state.user = Some(user.clone());
        let mut out = json!({"ok": true, "state": "signed_in", "user": user});
        if let Err(failure) = remove(&path).and_then(|()| save(&path, &state)) {
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
        let ids = uuids(changes.len())?;
        let commands: Vec<Value> = changes
            .iter()
            .zip(&ids)
            .map(|(change, uuid)| change.command(uuid))
            .collect();
        let path = cache_file()?;
        let mut state = load(&path);
        let sync_reply = exchange(&client, &token, &mut state, &commands)?;
        let mut results = Map::new();
        for (change, uuid) in changes.iter().zip(&ids) {
            results.insert(change.id().to_string(), result(&sync_reply, uuid));
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
}

impl Edit {
    fn id(&self) -> &str {
        match self {
            Edit::Close(id) | Edit::Due(id, _) => id,
        }
    }

    fn command(&self, uuid: &str) -> Value {
        match self {
            Edit::Close(id) => json!({"type": "item_close", "uuid": uuid, "args": {"id": id}}),
            Edit::Due(id, date) => json!({
                "type": "item_update", "uuid": uuid, "args": {"id": id, "due": {"date": date}}
            }),
        }
    }
}

/// `{"commands":[{"op":"close","id":…},{"op":"due","id":…,"date":"YYYY-MM-DD"}]}`:
/// 1–100 changes, at most one per task.
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
            _ => return Err(invalid("Unknown change.")),
        });
    }
    Ok(edits)
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
        let too_many: Vec<Value> = (0..101)
            .map(|i| json!({"op": "close", "id": format!("T{i}")}))
            .collect();
        for bad in [
            json!({}),
            json!({"commands": []}),
            json!({"commands": too_many}),
            json!({"commands": [{"op": "close", "id": "../x"}]}),
            json!({"commands": [{"op": "due", "id": "T1", "date": "2026-02-30"}]}),
            json!({"commands": [{"op": "delete", "id": "T1"}]}),
            json!({"commands": [{"op": "close", "id": "T1"}, {"op": "due", "id": "T1", "date": "2026-11-17"}]}),
        ] {
            assert_eq!(
                parse_changes(&map(bad.clone())).unwrap_err().code,
                "INVALID_ARGUMENT",
                "{bad}"
            );
        }
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
        for bad in [
            json!({}),
            json!({"text": "   "}),
            json!({"text": "é".repeat(501)}),
            json!({"text": "x", "due_date": "tomorrow"}),
            json!({"text": "x", "project_id": 5}),
        ] {
            assert_eq!(
                parse_add(&map(bad.clone())).unwrap_err().code,
                "INVALID_ARGUMENT",
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
        let held = state_lock(Some(&dir), Duration::ZERO).unwrap();
        let started = Instant::now();
        let busy = state_lock(Some(&dir), Duration::from_millis(100)).unwrap_err();
        assert_eq!(busy.code, "BUSY");
        assert!(started.elapsed() >= Duration::from_millis(100));
        drop(held);
        assert!(state_lock(Some(&dir), Duration::ZERO).is_ok());
        assert_eq!(
            state_lock(None, Duration::ZERO).unwrap_err().code,
            "LOCK_UNAVAILABLE"
        );
        assert_eq!(
            state_lock(Some(&dir.join("missing")), Duration::ZERO)
                .unwrap_err()
                .code,
            "LOCK_UNAVAILABLE"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
