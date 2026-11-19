//! The open tasks, projects, sections and personal labels the panel shows, kept between runs
//! in the cache and merged with every Sync reply.
//!
//! Every record from Todoist (or from the cache, which holds the same
//! shape) goes through a normalizer that keeps only the fields the panel
//! uses, checks their types and caps their lengths. A record that doesn't
//! fit is dropped (an older copy with its id too, so nothing stale stays).
//! Closed or deleted tasks, archived or deleted projects and sections, and
//! deleted labels leave the state; at most [`MAX_TASKS`], [`MAX_PROJECTS`],
//! [`MAX_SECTIONS`] and [`MAX_LABEL_RECORDS`] are kept, and `truncated`
//! says when one was cut. The
//! user object Todoist sends also holds the API token: only the five fields
//! in [`normalize_user`] are kept.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

pub const MAX_TASKS: usize = 20_000;
pub const MAX_PROJECTS: usize = 2_000;
pub const MAX_SECTIONS: usize = 5_000;
pub const MAX_LABEL_RECORDS: usize = 2_000;
pub const MAX_COLLABORATORS: usize = 2_000;
/// Active "user in shared project" pairs kept.
pub const MAX_MEMBERSHIPS: usize = 20_000;
/// Task content longer than this (in characters) is cut, ending in "…".
pub const MAX_CONTENT: usize = 500;
const MAX_NAME: usize = 200;
const MAX_LABEL: usize = 100;
const MAX_LABELS: usize = 50;
const MAX_DUE_STRING: usize = 200;
/// 2: labels; 3: collaborators and shared projects; 4: tasks' assignees
/// (`responsible_uid`). An older cache keeps only its user, so the next
/// sync is a full one that brings them.
const CACHE_VERSION: u64 = 4;

/// A Todoist id: 1–64 ASCII letters, digits, `_` or `-`.
pub fn valid_id(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 64
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (year.is_multiple_of(4) && !year.is_multiple_of(100)) || year.is_multiple_of(400) => {
            29
        }
        2 => 28,
        _ => 0,
    }
}

/// A calendar date `YYYY-MM-DD` that exists.
pub fn valid_date(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    let number = |range: std::ops::Range<usize>| -> Option<u32> {
        let part = &text[range];
        part.bytes()
            .all(|b| b.is_ascii_digit())
            .then(|| part.parse().ok())
            .flatten()
    };
    match (number(0..4), number(5..7), number(8..10)) {
        (Some(year), Some(month), Some(day)) => {
            year >= 1 && day >= 1 && day <= days_in_month(year, month)
        }
        _ => false,
    }
}

/// A due `date`: `YYYY-MM-DD`, optionally followed by a time
/// (`THH:MM:SS`, fractions, `Z` for a fixed zone). Only its shape is
/// checked here; the panel parses it.
fn valid_due_date(text: &str) -> bool {
    if text.len() > 40 || !valid_date(text.get(..10).unwrap_or("")) {
        return false;
    }
    let rest = &text[10..];
    rest.is_empty()
        || (rest.starts_with('T')
            && rest.len() >= 9
            && rest[1..]
                .bytes()
                .all(|b| b.is_ascii_digit() || matches!(b, b':' | b'.' | b'Z')))
}

/// `text` cut to `max` characters, the last one "…" when cut.
pub fn cap(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max - 1).collect();
    out.push('…');
    out
}

fn string<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

fn id_field(record: &Value, key: &str) -> Option<String> {
    string(record, key)
        .filter(|id| valid_id(id))
        .map(str::to_string)
}

/// An optional id: absent, null or "" is none; anything else must be valid.
fn optional_id(record: &Value, key: &str) -> Result<Value, ()> {
    match record.get(key) {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(Value::String(id)) if id.is_empty() => Ok(Value::Null),
        Some(Value::String(id)) if valid_id(id) => Ok(json!(id)),
        _ => Err(()),
    }
}

fn integer(record: &Value, key: &str) -> i64 {
    record.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn flag(record: &Value, key: &str) -> bool {
    record.get(key).and_then(Value::as_bool) == Some(true)
}

/// What one record from Todoist does to the state.
#[derive(Debug, PartialEq)]
pub enum Change {
    /// Add or replace the record with this id.
    Keep(String, Value),
    /// Remove the record with this id (closed, deleted, archived, or broken).
    Drop(String),
    /// No usable id: ignore it.
    Skip,
}

fn due(record: &Value) -> Result<Value, ()> {
    match record.get("due") {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(due) => {
            let date = string(due, "date")
                .filter(|date| valid_due_date(date))
                .ok_or(())?;
            Ok(json!({
                "date": date,
                "is_recurring": flag(due, "is_recurring"),
                "string": cap(string(due, "string").unwrap_or(""), MAX_DUE_STRING),
            }))
        }
    }
}

fn labels(record: &Value) -> Vec<String> {
    record
        .get("labels")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(Value::as_str)
                .filter(|label| !label.is_empty())
                .take(MAX_LABELS)
                .map(|label| cap(label, MAX_LABEL))
                .collect()
        })
        .unwrap_or_default()
}

pub fn normalize_task(record: &Value) -> Change {
    let Some(id) = id_field(record, "id") else {
        return Change::Skip;
    };
    if flag(record, "checked") || flag(record, "is_deleted") {
        return Change::Drop(id);
    }
    let build = || -> Result<Value, ()> {
        let priority = record.get("priority").and_then(Value::as_i64).unwrap_or(1);
        Ok(json!({
            "id": id,
            "content": cap(string(record, "content").ok_or(())?, MAX_CONTENT),
            "project_id": id_field(record, "project_id").ok_or(())?,
            "section_id": optional_id(record, "section_id")?,
            "parent_id": optional_id(record, "parent_id")?,
            "priority": if (1..=4).contains(&priority) { priority } else { 1 },
            "due": due(record)?,
            "labels": labels(record),
            "child_order": integer(record, "child_order"),
            "day_order": integer(record, "day_order"),
            // Who the task is assigned to (shared projects); anything that
            // isn't an id is no one, never a reason to drop the task.
            "responsible_uid": optional_id(record, "responsible_uid").unwrap_or(Value::Null),
        }))
    };
    match build() {
        Ok(task) => Change::Keep(id, task),
        Err(()) => Change::Drop(id),
    }
}

pub fn normalize_project(record: &Value) -> Change {
    let Some(id) = id_field(record, "id") else {
        return Change::Skip;
    };
    if flag(record, "is_deleted") || flag(record, "is_archived") {
        return Change::Drop(id);
    }
    let build = || -> Result<Value, ()> {
        Ok(json!({
            "id": id,
            "name": cap(string(record, "name").ok_or(())?, MAX_NAME),
            "color": cap(string(record, "color").unwrap_or("charcoal"), 32),
            "parent_id": optional_id(record, "parent_id")?,
            "child_order": integer(record, "child_order"),
            // Todoist's field is `inbox_project`; the cache keeps `inbox`.
            "inbox": flag(record, "inbox_project") || flag(record, "inbox"),
            "shared": flag(record, "shared"),
        }))
    };
    match build() {
        Ok(project) => Change::Keep(id, project),
        Err(()) => Change::Drop(id),
    }
}

pub fn normalize_section(record: &Value) -> Change {
    let Some(id) = id_field(record, "id") else {
        return Change::Skip;
    };
    if flag(record, "is_deleted") || flag(record, "is_archived") {
        return Change::Drop(id);
    }
    let build = || -> Result<Value, ()> {
        Ok(json!({
            "id": id,
            "project_id": id_field(record, "project_id").ok_or(())?,
            "name": cap(string(record, "name").ok_or(())?, MAX_NAME),
            "section_order": integer(record, "section_order"),
        }))
    };
    match build() {
        Ok(section) => Change::Keep(id, section),
        Err(()) => Change::Drop(id),
    }
}

/// A personal label (shared labels are only names on tasks).
pub fn normalize_label(record: &Value) -> Change {
    let Some(id) = id_field(record, "id") else {
        return Change::Skip;
    };
    if flag(record, "is_deleted") {
        return Change::Drop(id);
    }
    match string(record, "name").filter(|name| !name.is_empty()) {
        Some(name) => Change::Keep(
            id.clone(),
            json!({
                "id": id,
                "name": cap(name, MAX_LABEL),
                "color": cap(string(record, "color").unwrap_or("charcoal"), 32),
                "item_order": integer(record, "item_order"),
            }),
        ),
        None => Change::Drop(id),
    }
}

/// A collaborator: who can be assigned in a shared project.
pub fn normalize_collaborator(record: &Value) -> Change {
    let Some(id) = id_field(record, "id") else {
        return Change::Skip;
    };
    match string(record, "full_name").filter(|name| !name.is_empty()) {
        Some(name) => Change::Keep(
            id.clone(),
            json!({
                "id": id,
                "full_name": cap(name, MAX_NAME),
                "email": cap(string(record, "email").unwrap_or(""), 254),
            }),
        ),
        None => Change::Drop(id),
    }
}

/// A collaborator state: kept (keyed "<project>:<user>") only while
/// `active`; invited, deleted or broken ones leave.
pub fn normalize_membership(record: &Value) -> Change {
    let (Some(project), Some(user)) = (id_field(record, "project_id"), id_field(record, "user_id"))
    else {
        return Change::Skip;
    };
    let key = format!("{project}:{user}");
    if flag(record, "is_deleted") || string(record, "state") != Some("active") {
        return Change::Drop(key);
    }
    Change::Keep(
        key,
        json!({"project_id": project, "user_id": user, "state": "active"}),
    )
}

/// The user fields the panel shows; nothing else (the object Todoist sends
/// holds the API token too).
pub fn normalize_user(record: &Value) -> Option<Value> {
    let id = id_field(record, "id")?;
    let timezone = record
        .get("tz_info")
        .and_then(|info| string(info, "timezone"))
        .or_else(|| string(record, "timezone"))
        .unwrap_or("");
    Some(json!({
        "id": id,
        "full_name": cap(string(record, "full_name").unwrap_or(""), MAX_NAME),
        "email": cap(string(record, "email").unwrap_or(""), 254),
        "inbox_project_id": optional_id(record, "inbox_project_id").ok()?,
        "timezone": cap(timezone, 64),
    }))
}

/// The record lists of one Sync reply (or the cache), each in Todoist's order.
struct Records<'a> {
    projects: &'a [Value],
    sections: &'a [Value],
    tasks: &'a [Value],
    labels: &'a [Value],
    collaborators: &'a [Value],
    memberships: &'a [Value],
}

/// Everything the cache keeps: the sync token, the user and the records.
#[derive(Debug, Clone)]
pub struct State {
    /// `*` until the first sync: the next one is then a full sync.
    pub sync_token: String,
    pub user: Option<Value>,
    pub projects: BTreeMap<String, Value>,
    pub sections: BTreeMap<String, Value>,
    pub tasks: BTreeMap<String, Value>,
    pub labels: BTreeMap<String, Value>,
    pub collaborators: BTreeMap<String, Value>,
    /// Active collaborator states, "<project>:<user>" → the state.
    pub memberships: BTreeMap<String, Value>,
    pub truncated: bool,
    pub synced_at: Option<String>,
}

impl State {
    pub fn empty() -> State {
        State {
            sync_token: "*".into(),
            user: None,
            projects: BTreeMap::new(),
            sections: BTreeMap::new(),
            tasks: BTreeMap::new(),
            labels: BTreeMap::new(),
            collaborators: BTreeMap::new(),
            memberships: BTreeMap::new(),
            truncated: false,
            synced_at: None,
        }
    }

    pub fn is_full(&self) -> bool {
        self.sync_token == "*"
    }

    /// Forget the records and the sync token (the user stays until a sync
    /// brings another): the next sync is a full one.
    pub fn reset(&mut self) {
        let user = self.user.take();
        *self = State::empty();
        self.user = user;
    }

    /// A cache file's state, or `None` when it isn't one (corrupt, another
    /// version, a sync token that isn't a string).
    pub fn from_cache(data: &[u8]) -> Option<State> {
        let value: Value = serde_json::from_slice(data).ok()?;
        match value.get("version").and_then(Value::as_u64) {
            Some(CACHE_VERSION) => {}
            // Written before labels or collaborators: only the user is
            // kept; a full sync follows.
            Some(1..=3) => {
                let mut state = State::empty();
                state.user = value.get("user").and_then(normalize_user);
                return Some(state);
            }
            _ => return None,
        }
        let token = string(&value, "sync_token").filter(|t| !t.is_empty() && t.len() <= 1024)?;
        let mut state = State::empty();
        state.sync_token = token.to_string();
        state.user = value.get("user").and_then(normalize_user);
        state.synced_at = string(&value, "synced_at").map(|s| cap(s, 40));
        state.truncated = flag(&value, "truncated");
        let list = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        };
        state.apply(Records {
            projects: &list("projects"),
            sections: &list("sections"),
            tasks: &list("tasks"),
            labels: &list("labels"),
            collaborators: &list("collaborators"),
            memberships: &list("memberships"),
        });
        Some(state)
    }

    pub fn to_cache(&self) -> Vec<u8> {
        let mut value = self.snapshot();
        value["version"] = json!(CACHE_VERSION);
        value["memberships"] = json!(self.memberships.values().collect::<Vec<_>>());
        value["sync_token"] = json!(self.sync_token);
        value.to_string().into_bytes()
    }

    /// Apply records in Todoist's order (later ones win).
    fn apply(&mut self, records: Records) {
        let Records {
            projects,
            sections,
            tasks,
            labels,
            collaborators,
            memberships,
        } = records;
        let mut truncated = false;
        let mut merge = |map: &mut BTreeMap<String, Value>,
                         records: &[Value],
                         normalize: fn(&Value) -> Change,
                         max: usize| {
            for record in records {
                match normalize(record) {
                    Change::Keep(id, value) => {
                        if map.len() >= max && !map.contains_key(&id) {
                            truncated = true;
                        } else {
                            map.insert(id, value);
                        }
                    }
                    Change::Drop(id) => {
                        map.remove(&id);
                    }
                    Change::Skip => {}
                }
            }
        };
        merge(
            &mut self.projects,
            projects,
            normalize_project,
            MAX_PROJECTS,
        );
        merge(
            &mut self.sections,
            sections,
            normalize_section,
            MAX_SECTIONS,
        );
        merge(&mut self.tasks, tasks, normalize_task, MAX_TASKS);
        merge(&mut self.labels, labels, normalize_label, MAX_LABEL_RECORDS);
        merge(
            &mut self.collaborators,
            collaborators,
            normalize_collaborator,
            MAX_COLLABORATORS,
        );
        merge(
            &mut self.memberships,
            memberships,
            normalize_membership,
            MAX_MEMBERSHIPS,
        );
        self.truncated |= truncated;
    }

    /// Merge one Sync reply: a full sync replaces everything, an
    /// incremental one updates what it lists. `Err` when the reply has no
    /// new sync token (then nothing changed).
    pub fn merge(&mut self, reply: &Value, now: &str) -> Result<(), ()> {
        let token = string(reply, "sync_token")
            .filter(|t| !t.is_empty() && t.len() <= 1024)
            .ok_or(())?;
        if flag(reply, "full_sync") || self.is_full() {
            self.reset();
        }
        if let Some(user) = reply.get("user").filter(|u| u.is_object()) {
            self.user = normalize_user(user);
        }
        let list = |key: &str| {
            reply
                .get(key)
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[])
        };
        self.apply(Records {
            projects: list("projects"),
            sections: list("sections"),
            tasks: list("items"),
            labels: list("labels"),
            collaborators: list("collaborators"),
            memberships: list("collaborator_states"),
        });
        self.sync_token = token.to_string();
        self.synced_at = Some(now.to_string());
        Ok(())
    }

    /// The tasks a snapshot lists: those of projects it has (not archived,
    /// left, or cut by the bound).
    fn listed_tasks(&self) -> impl Iterator<Item = &Value> {
        self.tasks.values().filter(|task| {
            string(task, "project_id").is_some_and(|project| self.projects.contains_key(project))
        })
    }

    /// The people active in each shared project, `{"<project id>": ["<user id>", …]}`.
    fn project_collaborators(&self) -> Value {
        let mut members = Map::new();
        for state in self.memberships.values() {
            if let (Some(project), Some(user)) =
                (string(state, "project_id"), string(state, "user_id"))
            {
                let list = members
                    .entry(project.to_string())
                    .or_insert_with(|| json!([]));
                if let Some(list) = list.as_array_mut() {
                    list.push(json!(user));
                }
            }
        }
        Value::Object(members)
    }

    /// What the panel gets. Tasks of projects it doesn't have (archived,
    /// left, or cut by the bound) are left out with them.
    pub fn snapshot(&self) -> Value {
        let tasks: Vec<&Value> = self.listed_tasks().collect();
        let mut out = Map::new();
        out.insert("user".into(), self.user.clone().unwrap_or(Value::Null));
        out.insert(
            "projects".into(),
            json!(self.projects.values().collect::<Vec<_>>()),
        );
        out.insert(
            "sections".into(),
            json!(self.sections.values().collect::<Vec<_>>()),
        );
        out.insert("tasks".into(), json!(tasks));
        out.insert(
            "labels".into(),
            json!(self.labels.values().collect::<Vec<_>>()),
        );
        out.insert(
            "collaborators".into(),
            json!(self.collaborators.values().collect::<Vec<_>>()),
        );
        out.insert("project_collaborators".into(), self.project_collaborators());
        out.insert("truncated".into(), json!(self.truncated));
        out.insert("synced_at".into(), json!(self.synced_at));
        Value::Object(out)
    }
}

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// Seconds since the epoch as RFC 3339 UTC, `2026-11-16T09:30:00Z`.
pub fn rfc3339(seconds: i64) -> String {
    let (year, month, day) = civil(seconds.div_euclid(86_400));
    let rest = seconds.rem_euclid(86_400);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

pub fn now_rfc3339() -> String {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    rfc3339(seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: &str, content: &str) -> Value {
        json!({"id": id, "content": content, "project_id": "P1", "priority": 4,
               "due": {"date": "2026-11-16", "is_recurring": false, "string": "today", "lang": "en"},
               "labels": ["home"], "child_order": 1, "day_order": -1,
               "description": "not kept", "checked": false, "is_deleted": false})
    }

    #[test]
    fn ids_and_dates_are_checked() {
        for good in ["6X7rM8997g3RQmvh", "2995104339", "a_b-c"] {
            assert!(valid_id(good), "{good}");
        }
        for bad in ["", "a b", "../x", "é", &"x".repeat(65)] {
            assert!(!valid_id(bad), "{bad}");
        }
        for good in ["2026-11-16", "2028-02-29", "2026-12-31"] {
            assert!(valid_date(good), "{good}");
        }
        for bad in [
            "2026-02-29",
            "2026-13-01",
            "2026-00-10",
            "2026-1-1",
            "26-11-16",
            "2026-11-16T10:00:00",
            "２０２６-11-16",
        ] {
            assert!(!valid_date(bad), "{bad}");
        }
        for good in [
            "2026-11-16",
            "2026-11-16T12:00:00",
            "2026-11-16T12:00:00.000000",
            "2026-11-16T13:00:00Z",
        ] {
            assert!(valid_due_date(good), "{good}");
        }
        for bad in [
            "2026-11-16T",
            "2026-11-16 12:00",
            "tomorrow",
            "2026-11-16T12:00:00+01:00",
        ] {
            assert!(!valid_due_date(bad), "{bad}");
        }
    }

    #[test]
    fn a_task_keeps_only_what_the_panel_uses() {
        let Change::Keep(id, kept) = normalize_task(&task("T1", "Buy milk")) else {
            panic!("dropped")
        };
        assert_eq!(id, "T1");
        assert_eq!(
            kept,
            json!({"id": "T1", "content": "Buy milk", "project_id": "P1", "section_id": null,
                   "parent_id": null, "priority": 4,
                   "due": {"date": "2026-11-16", "is_recurring": false, "string": "today"},
                   "labels": ["home"], "child_order": 1, "day_order": -1, "responsible_uid": null})
        );
        // Normalizing the cached shape again changes nothing.
        assert_eq!(
            normalize_task(&kept),
            Change::Keep("T1".into(), kept.clone())
        );
    }

    #[test]
    fn long_content_is_cut_on_a_character_boundary() {
        let long = "é".repeat(600);
        let Change::Keep(_, kept) = normalize_task(&task("T1", &long)) else {
            panic!("dropped")
        };
        let content = kept["content"].as_str().unwrap();
        assert_eq!(content.chars().count(), MAX_CONTENT);
        assert!(content.ends_with('…'));
        assert_eq!(cap(content, MAX_CONTENT), content);
    }

    #[test]
    fn closed_deleted_and_broken_records_leave() {
        let mut closed = task("T1", "x");
        closed["checked"] = json!(true);
        assert_eq!(normalize_task(&closed), Change::Drop("T1".into()));
        let mut deleted = task("T1", "x");
        deleted["is_deleted"] = json!(true);
        assert_eq!(normalize_task(&deleted), Change::Drop("T1".into()));
        let mut broken = task("T1", "x");
        broken["project_id"] = json!(5);
        assert_eq!(normalize_task(&broken), Change::Drop("T1".into()));
        let mut bad_due = task("T1", "x");
        bad_due["due"] = json!({"date": "soon"});
        assert_eq!(normalize_task(&bad_due), Change::Drop("T1".into()));
        assert_eq!(normalize_task(&json!({"id": "a b"})), Change::Skip);
        assert_eq!(
            normalize_project(&json!({"id": "P1", "name": "x", "is_archived": true})),
            Change::Drop("P1".into())
        );
        assert_eq!(
            normalize_section(
                &json!({"id": "S1", "name": "x", "project_id": "P1", "is_deleted": true})
            ),
            Change::Drop("S1".into())
        );
    }

    #[test]
    fn the_user_never_keeps_the_token() {
        let user = normalize_user(&json!({
            "id": "1", "full_name": "Ada", "email": "ada@example.com", "inbox_project_id": "P0",
            "token": "0123456789abcdef", "tz_info": {"timezone": "Europe/Oslo"}
        }))
        .unwrap();
        assert_eq!(
            user,
            json!({"id": "1", "full_name": "Ada", "email": "ada@example.com",
                   "inbox_project_id": "P0", "timezone": "Europe/Oslo"})
        );
        assert_eq!(normalize_user(&user), Some(user.clone()));
    }

    #[test]
    fn full_then_incremental_merge() {
        let mut state = State::empty();
        let full = json!({
            "sync_token": "A", "full_sync": true,
            "user": {"id": "1", "full_name": "Ada", "inbox_project_id": "P1"},
            "projects": [{"id": "P1", "name": "Inbox", "inbox_project": true, "color": "grey"},
                         {"id": "P2", "name": "Work", "color": "blue"}],
            "sections": [{"id": "S1", "project_id": "P2", "name": "Soon", "section_order": 1}],
            "items": [task("T1", "one"), task("T2", "two"), task("T3", "three")]
        });
        state.merge(&full, "2026-11-16T08:00:00Z").unwrap();
        assert_eq!(state.tasks.len(), 3);
        let mut done = task("T2", "two");
        done["checked"] = json!(true);
        let mut gone = task("T3", "three");
        gone["is_deleted"] = json!(true);
        let incremental = json!({
            "sync_token": "B", "full_sync": false,
            "items": [task("T1", "one, edited"), done, gone, task("T4", "four")],
            "projects": [{"id": "P2", "name": "Work", "is_archived": true}]
        });
        state.merge(&incremental, "2026-11-16T08:05:00Z").unwrap();
        assert_eq!(state.sync_token, "B");
        assert_eq!(state.tasks.keys().collect::<Vec<_>>(), ["T1", "T4"]);
        assert_eq!(state.tasks["T1"]["content"], "one, edited");
        assert_eq!(
            state.user.as_ref().unwrap()["full_name"],
            "Ada",
            "kept: not in the reply"
        );
        // The archived project and the tasks in it are not shown.
        let mut in_work = task("T5", "work");
        in_work["project_id"] = json!("P2");
        state
            .merge(&json!({"sync_token": "C", "items": [in_work]}), "x")
            .unwrap();
        let snapshot = state.snapshot();
        assert_eq!(snapshot["projects"].as_array().unwrap().len(), 1);
        assert_eq!(snapshot["tasks"].as_array().unwrap().len(), 2);
        // A reply without a sync token changes nothing.
        assert!(state.merge(&json!({"items": []}), "x").is_err());
        assert_eq!(state.sync_token, "C");
        // A full sync replaces everything.
        state
            .merge(&json!({"sync_token": "D", "full_sync": true, "projects": [{"id": "P1", "name": "Inbox"}], "items": []}), "y")
            .unwrap();
        assert!(state.tasks.is_empty());
    }

    #[test]
    fn the_cache_round_trips_and_rejects_what_it_is_not() {
        let mut state = State::empty();
        state
            .merge(&json!({"sync_token": "A", "user": {"id": "1"}, "projects": [{"id": "P1", "name": "Inbox"}], "items": [task("T1", "one")]}), "2026-11-16T08:00:00Z")
            .unwrap();
        let back = State::from_cache(&state.to_cache()).unwrap();
        assert_eq!(back.sync_token, "A");
        assert_eq!(back.snapshot(), state.snapshot());
        for bad in [
            &b"{"[..],
            b"[]",
            br#"{"version":5,"sync_token":"A"}"#,
            br#"{"version":0,"sync_token":"A"}"#,
            br#"{"version":4,"sync_token":5}"#,
        ] {
            assert!(
                State::from_cache(bad).is_none(),
                "{}",
                String::from_utf8_lossy(bad)
            );
        }
    }

    #[test]
    fn bounds_cut_and_say_so() {
        let mut state = State::empty();
        let projects: Vec<Value> = (0..MAX_PROJECTS + 5)
            .map(|i| json!({"id": format!("P{i}"), "name": "p"}))
            .collect();
        state
            .merge(&json!({"sync_token": "A", "projects": projects}), "x")
            .unwrap();
        assert_eq!(state.projects.len(), MAX_PROJECTS);
        assert!(state.snapshot()["truncated"].as_bool().unwrap());
        // An update of a kept one still lands.
        state
            .merge(
                &json!({"sync_token": "B", "projects": [{"id": "P1", "name": "renamed"}]}),
                "x",
            )
            .unwrap();
        assert_eq!(state.projects["P1"]["name"], "renamed");
    }

    #[test]
    fn labels_are_added_renamed_and_deleted() {
        let mut state = State::empty();
        let full = json!({"sync_token": "A", "full_sync": true,
            "labels": [{"id": "L1", "name": "Food", "color": "lime_green", "item_order": 2, "is_deleted": false},
                       {"id": "L2", "name": "errand", "color": "nope", "item_order": 1, "order_key": "a1"},
                       {"id": "bad id", "name": "x"}, {"id": "L3"}]});
        state.merge(&full, "x").unwrap();
        let labels = state.snapshot()["labels"].clone();
        assert_eq!(
            labels,
            json!([{"id": "L1", "name": "Food", "color": "lime_green", "item_order": 2},
                   {"id": "L2", "name": "errand", "color": "nope", "item_order": 1}])
        );
        let next = json!({"sync_token": "B",
            "labels": [{"id": "L1", "name": "Groceries", "color": "red", "item_order": 2},
                       {"id": "L2", "name": "errand", "is_deleted": true},
                       {"id": "L4", "name": "Høst 2026", "item_order": 3}]});
        state.merge(&next, "y").unwrap();
        let names: Vec<_> = state.snapshot()["labels"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(names, ["Groceries", "Høst 2026"]);
        // The cache keeps them.
        let back = State::from_cache(&state.to_cache()).unwrap();
        assert_eq!(back.snapshot()["labels"], state.snapshot()["labels"]);
    }

    #[test]
    fn labels_are_bounded() {
        let mut state = State::empty();
        let labels: Vec<Value> = (0..MAX_LABEL_RECORDS + 3)
            .map(|i| json!({"id": format!("L{i}"), "name": format!("l{i}")}))
            .collect();
        state
            .merge(&json!({"sync_token": "A", "labels": labels}), "x")
            .unwrap();
        assert_eq!(state.labels.len(), MAX_LABEL_RECORDS);
        assert!(state.snapshot()["truncated"].as_bool().unwrap());
    }

    #[test]
    fn a_cache_from_before_labels_keeps_the_user_and_syncs_in_full() {
        let old = json!({"version": 1, "sync_token": "OLD", "user": {"id": "1", "full_name": "Ada"},
            "projects": [{"id": "P1", "name": "Inbox"}], "tasks": [task("T1", "one")], "sections": []});
        let state = State::from_cache(old.to_string().as_bytes()).unwrap();
        assert!(state.is_full(), "the next sync is a full one");
        assert_eq!(state.user.as_ref().unwrap()["full_name"], "Ada");
        assert!(state.tasks.is_empty() && state.projects.is_empty());
        assert!(State::from_cache(br#"{"version":5,"sync_token":"A"}"#).is_none());
    }

    #[test]
    fn collaborators_and_their_projects_are_merged_and_removed() {
        let mut state = State::empty();
        let full = json!({"sync_token": "A", "full_sync": true,
            "projects": [{"id": "P1", "name": "Trip", "shared": true}, {"id": "P2", "name": "Solo"}],
            "collaborators": [{"id": "1", "full_name": "Ada Lovelace", "email": "ada@example.com", "timezone": "x", "image_id": null},
                              {"id": "2", "full_name": "Bo Ek", "email": "bo@example.com"},
                              {"id": "3", "full_name": "Cy", "email": "cy@example.com"},
                              {"id": "bad id", "full_name": "x"}],
            "collaborator_states": [
                {"project_id": "P1", "user_id": "1", "state": "active", "is_deleted": false},
                {"project_id": "P1", "user_id": "2", "state": "active"},
                {"project_id": "P1", "user_id": "3", "state": "invited"}]});
        state.merge(&full, "x").unwrap();
        let snapshot = state.snapshot();
        assert_eq!(snapshot["projects"][0]["shared"], true);
        assert_eq!(snapshot["projects"][1]["shared"], false);
        assert_eq!(
            snapshot["collaborators"],
            json!([{"id": "1", "full_name": "Ada Lovelace", "email": "ada@example.com"},
                   {"id": "2", "full_name": "Bo Ek", "email": "bo@example.com"},
                   {"id": "3", "full_name": "Cy", "email": "cy@example.com"}])
        );
        assert_eq!(snapshot["project_collaborators"], json!({"P1": ["1", "2"]}));
        // Incrementally: renamed, one leaves (deleted), an invitee accepts.
        let next = json!({"sync_token": "B",
            "collaborators": [{"id": "2", "full_name": "Bo Ekberg", "email": "bo@example.com"}],
            "collaborator_states": [
                {"project_id": "P1", "user_id": "1", "state": "active", "is_deleted": true},
                {"project_id": "P1", "user_id": "3", "state": "active"}]});
        state.merge(&next, "y").unwrap();
        let snapshot = state.snapshot();
        assert_eq!(snapshot["project_collaborators"], json!({"P1": ["2", "3"]}));
        assert_eq!(snapshot["collaborators"][1]["full_name"], "Bo Ekberg");
        // Back to invited: not active any more.
        state
            .merge(&json!({"sync_token": "C", "collaborator_states": [{"project_id": "P1", "user_id": "3", "state": "invited"}]}), "z")
            .unwrap();
        assert_eq!(
            state.snapshot()["project_collaborators"],
            json!({"P1": ["2"]})
        );
        let back = State::from_cache(&state.to_cache()).unwrap();
        assert_eq!(back.snapshot(), state.snapshot());
    }

    #[test]
    fn collaborators_are_bounded() {
        let mut state = State::empty();
        let people: Vec<Value> = (0..MAX_COLLABORATORS + 2)
            .map(|i| json!({"id": format!("{i}"), "full_name": "x", "email": "x@example.com"}))
            .collect();
        state
            .merge(&json!({"sync_token": "A", "collaborators": people}), "x")
            .unwrap();
        assert_eq!(state.collaborators.len(), MAX_COLLABORATORS);
        assert!(state.snapshot()["truncated"].as_bool().unwrap());
    }

    #[test]
    fn a_cache_from_before_collaborators_keeps_the_user_and_syncs_in_full() {
        for version in [1, 2, 3] {
            let old = json!({"version": version, "sync_token": "OLD", "user": {"id": "1", "full_name": "Ada"},
                "projects": [{"id": "P1", "name": "Inbox"}], "tasks": [task("T1", "one")], "sections": [], "labels": []});
            let state = State::from_cache(old.to_string().as_bytes()).unwrap();
            assert!(
                state.is_full(),
                "version {version}: the next sync is a full one"
            );
            assert_eq!(state.user.as_ref().unwrap()["full_name"], "Ada");
            assert!(state.tasks.is_empty());
        }
    }

    #[test]
    fn a_task_keeps_its_responsible_user() {
        let mut assigned = task("T1", "x");
        assigned["responsible_uid"] = json!("7");
        let Change::Keep(_, kept) = normalize_task(&assigned) else {
            panic!("dropped")
        };
        assert_eq!(kept["responsible_uid"], "7");
        // None, empty or not an id: null, and the task stays.
        for value in [json!(null), json!(""), json!(5), json!("a b")] {
            let mut other = task("T2", "y");
            other["responsible_uid"] = value.clone();
            let Change::Keep(_, kept) = normalize_task(&other) else {
                panic!("dropped for {value}")
            };
            assert_eq!(kept["responsible_uid"], Value::Null, "{value}");
        }
        let Change::Keep(_, kept) = normalize_task(&task("T3", "z")) else {
            panic!("dropped")
        };
        assert_eq!(kept["responsible_uid"], Value::Null);
    }

    #[test]
    fn a_cache_from_before_assignees_syncs_in_full() {
        // Version 3 tasks have no responsible_uid: a full sync brings it.
        let old = json!({"version": 3, "sync_token": "OLD", "user": {"id": "1", "full_name": "Ada"},
            "projects": [{"id": "P1", "name": "Inbox"}], "tasks": [task("T1", "one")], "sections": [],
            "labels": [], "collaborators": [], "memberships": []});
        let state = State::from_cache(old.to_string().as_bytes()).unwrap();
        assert!(state.is_full(), "the next sync is a full one");
        assert!(state.tasks.is_empty());
        assert_eq!(state.user.as_ref().unwrap()["full_name"], "Ada");
    }

    #[test]
    fn rfc3339_formats_utc() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339(1_794_821_400), "2026-11-16T09:30:00Z");
    }
}
