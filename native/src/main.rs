//! foamy-todoist-helper: the Todoist side of the foamy-todoist plugin.
//!
//! The API token lives in the Secret Service keyring (through `secret-tool`,
//! attributes `service foamy-todoist account personal-token`); it is never
//! in argv, a log, an error or a file. Tasks are read with Todoist's Sync
//! endpoint, incrementally, and kept in a private cache between runs. Only
//! `https://api.todoist.com/api/v1` is contacted.
//!
//! ```text
//! foamy-todoist-helper status
//! foamy-todoist-helper token-set    < {"token":"…"}
//! foamy-todoist-helper token-clear
//! foamy-todoist-helper sync         < {} | {"full":true}
//! foamy-todoist-helper apply        < {"commands":[{"op":"close","id":…},{"op":"due","id":…,"date":"YYYY-MM-DD"}]}
//! foamy-todoist-helper add          < {"text":…,"due_date":"YYYY-MM-DD"|null,"project_id":…|null}
//! ```
//!
//! Every command prints one JSON line, also on failure and panic:
//!
//! - `status` (no network): `{"ok":true,"state":"signed_in"|"signed_out","user":{…}|null}`,
//!   the user from the cache (null until a sync or `token-set` brought one).
//! - `token-set` reads at most 4 KiB; the token is 1–256 printable ASCII
//!   characters without whitespace. The cache directory is checked first,
//!   then the token with a Sync request for the user (401/403:
//!   `INVALID_TOKEN`); then it is stored, and the cache is replaced by one
//!   holding only that user. Once stored the reply is `signed_in`, like
//!   `status`, plus `warning` when the new cache can't be written.
//! - `token-clear` removes the keyring item and the cache: `signed_out`.
//!   A locked keyring is `KEYRING_LOCKED` and removes nothing.
//! - `sync`, `apply` and `add` reply with the snapshot:
//!   `{"ok":true,"user":{"id","full_name","email","inbox_project_id","timezone"}|null,
//!   "projects":[{"id","name","color","parent_id","child_order","inbox","shared"}],
//!   "sections":[{"id","project_id","name","section_order"}],
//!   "tasks":[{"id","content","project_id","section_id","parent_id","priority",
//!   "due":{"date","is_recurring","string"}|null,"labels","child_order","day_order",
//!   "responsible_uid"}],
//!   "labels":[{"id","name","color","item_order"}],
//!   "collaborators":[{"id","full_name","email"}],
//!   "project_collaborators":{"<project id>":["<user id>",…]},
//!   "truncated":bool,"synced_at":"<RFC 3339 UTC>"}`: open tasks only, in
//!   projects that are neither archived nor deleted, sections likewise;
//!   `labels` are the personal labels that aren't deleted (shared labels
//!   exist only as names on tasks); `project_collaborators` lists the
//!   people active in each shared project (invited, left or deleted ones
//!   leave); `content` at most 500 characters (cut ending in "…"); at most
//!   20 000 tasks, 2 000 projects, 5 000 sections, 2 000 labels, 2 000
//!   collaborators and 20 000 memberships (`truncated` when one was cut).
//!   `due.date` is Todoist's: `YYYY-MM-DD`, a floating `YYYY-MM-DDTHH:MM:SS`
//!   or a UTC `…Z`.
//! - `sync` merges an incremental Sync (items, projects, sections, labels,
//!   collaborators, collaborator states, user)
//!   into the cache; `{"full":true}` forces a full one. When Todoist refuses
//!   the sync token (HTTP 400 on an incremental request) one full sync
//!   follows; nothing else is retried.
//! - `apply` takes 1–100 changes, at most one per task: `close` is
//!   `item_close` (a recurring task moves to its next date), `due` sets an
//!   all-day date with `item_update`. They go in one Sync request with the
//!   incremental read. The snapshot comes with `"results":{"<task id>":"ok"|{"code":…,"error":…}}`
//!   from Todoist's `sync_status` (`code` its `error_tag`).
//! - `add` creates the task with Quick Add (`POST /tasks/quick`: Todoist
//!   parses dates, #project, @labels and p1–p4 in `text`, 1–500
//!   characters). Then, in one Sync request with the read: `due_date` is set
//!   when the task got no date, and the task moves to `project_id` when it
//!   landed in the Inbox, `project_id` is another project, and the text has
//!   no `#project` token (`#` at the start or after whitespace, followed by
//!   a non-space: "Buy milk #Inbox" stays in the Inbox). The snapshot
//!   comes with `"added":"<id>"`. The task exists once Quick Add answered,
//!   so a failure after that is a `warning` (a catalog key, like `error`)
//!   on a successful reply, never an error: adding again would duplicate it.
//!   When the follow-up Sync failed, the reply also has `"stale":true`
//!   (the snapshot is the cache plus the new task, not a fresh read),
//!   `"warning_code"` and, for `RATE_LIMITED`, `"retry_after"`.
//! - `apply` and `add` also report a cache that can't be saved as `warning`:
//!   the change is made in Todoist and the next sync brings it.
//!
//! Errors: `{"ok":false,"code":…,"error":…}` with code `INVALID_ARGUMENT`,
//! `SIGNED_OUT`, `INVALID_TOKEN`, `KEYRING_UNAVAILABLE`, `KEYRING_LOCKED`,
//! `NETWORK`, `TIMEOUT`, `RATE_LIMITED` (HTTP 429, with `"retry_after"`
//! seconds when Todoist gives them), `HTTP`, `TLS_UNSUPPORTED`, `BUSY`,
//! `LOCK_UNAVAILABLE`, `UNKNOWN_OUTCOME` (`add` only: the Quick Add request
//! went out but no answer came back, a timeout or a lost connection, or a
//! 2xx answer without a usable task id, so the task may exist; a failure before the request went out stays
//! `NETWORK`, `TIMEOUT` or `TLS_UNSUPPORTED`) or `INTERNAL`. Every `error`
//! (and `warning`) is a
//! catalog key of the plugin's `i18n/en.json`; varying details follow it
//! after U+001F separators and fill its `%1`, `%2`… (see `text.rs`).
//!
//! Bounds: the whole run ends within 25 seconds (the panel's `timeout` is
//! 30), each request within 15 (Todoist's own limit); reply bodies are read
//! up to 16 MiB and refused beyond, before parsing; request bodies stay
//! under Todoist's 1 MiB.
//!
//! Every command holds an exclusive lock on
//! `$XDG_RUNTIME_DIR/foamy-todoist/state.lock` while it reads or writes the
//! keyring or the cache, waiting up to 15 seconds (`BUSY`); without a usable
//! runtime directory it is `LOCK_UNAVAILABLE`. A sync reads the token under
//! that lock, so a sign-out can't be undone by a sync in flight.
//!
//! The cache is `$XDG_CACHE_HOME/foamy-todoist/cache.json` (else
//! `~/.cache/foamy-todoist/`), directory 0700, file 0600, written
//! atomically: the sync token and the snapshot (labels included), never the
//! API token. A corrupt or oversized cache is dropped and a full sync done.
//! A cache from before labels, collaborators or assignees (format versions
//! 1 to 3) keeps only its user: the next sync is a full one.
//!
//! `FOAMY_TODOIST_BASE_URL` (a loopback `http://` URL only, else refused)
//! replaces the API base in tests.

mod http;
mod model;
mod text;
mod todoist;
mod vault;

use std::ffi::OsString;
use std::process::ExitCode;
use std::time::Duration;

use foamy_helper::{Failure, json};
use serde_json::Value;

/// Under the panel's `timeout --kill-after=2s 30s`.
const RUN_BUDGET: Duration = Duration::from_secs(25);
const MAX_TOKEN_REQUEST: u64 = 4 << 10;
const MAX_ADD_REQUEST: u64 = 16 << 10;
const MAX_APPLY_REQUEST: u64 = 64 << 10;

fn usage() -> Failure {
    Failure::coded(
        "INVALID_ARGUMENT",
        "The Todoist helper was called with the wrong arguments.",
    )
}

fn args() -> Result<Vec<String>, Failure> {
    std::env::args_os()
        .skip(1)
        .map(OsString::into_string)
        .collect::<Result<_, _>>()
        .map_err(|_| usage())
}

fn run(args: &[String]) -> Result<Value, Failure> {
    let [command] = args else {
        return Err(usage());
    };
    let context = todoist::Context {
        vault: vault::SecretTool::new(),
        lock_dir: foamy_helper::lock::runtime_dir("foamy-todoist").ok(),
    };
    match command.as_str() {
        "status" => context.status(),
        "token-set" => context.token_set(&todoist::read_request(MAX_TOKEN_REQUEST)?),
        "token-clear" => context.token_clear(),
        "sync" => context.sync(&todoist::read_request(MAX_TOKEN_REQUEST)?),
        "apply" => context.apply(&todoist::read_request(MAX_APPLY_REQUEST)?),
        "add" => context.add(&todoist::read_request(MAX_ADD_REQUEST)?),
        _ => Err(usage()),
    }
}

/// The kit's error reply, plus `retry_after` for `RATE_LIMITED` (the seconds
/// are the message's detail).
fn render(failure: &Failure) -> Value {
    let mut reply = json::error_reply(failure);
    if let Some(seconds) = todoist::retry_seconds(failure) {
        reply["retry_after"] = seconds.into();
    }
    reply
}

fn main() -> ExitCode {
    foamy_helper::process::set_run_budget(RUN_BUDGET);
    json::run(|| run(&args()?), render)
}
