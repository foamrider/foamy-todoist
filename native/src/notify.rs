//! `notify`: a desktop notification about an add the launcher made, sent
//! with `omarchy-notification-send`. No network, no lock, no keyring. The
//! caller passes every shown text already translated (the helper has no
//! translations).

use std::io::ErrorKind;
use std::time::Duration;

use foamy_helper::Failure;
use foamy_helper::child::Bounded;
use serde_json::{Map, Value, json};

use crate::model;
use crate::text::{message, short};

const SENDER: &str = "omarchy-notification-send";
/// The sender only hands the card to the notification daemon over D-Bus;
/// a sender that hangs must not hold the launcher's add flow.
const SENDER_TIMEOUT: Duration = Duration::from_secs(2);
/// The sender prints nothing we read; more than this is not the sender.
const MAX_SENDER_OUTPUT: usize = 64 << 10;
const MAX_TITLE: usize = 200;
const MAX_DETAIL: usize = 1000;
const MAX_OPEN_LABEL: usize = 100;
const MAX_PROJECT: usize = 200;
const MAX_DUE: usize = 200;
const MAX_LABEL: usize = 100;
const MAX_LABELS: usize = 50;

fn invalid(field: &str) -> Failure {
    Failure::coded(
        "INVALID_ARGUMENT",
        message("The notification's %1 isn't valid.", &[&field]),
    )
}

/// The added task, as the notification shows it.
#[derive(Debug, PartialEq)]
pub struct Task {
    pub id: String,
    pub content: String,
    pub project: String,
    pub due: String,
    pub labels: Vec<String>,
}

#[derive(Debug, PartialEq)]
pub enum Kind {
    Added(Task),
    Failed,
    Unknown,
}

/// A checked request; every text without control characters, not yet
/// markup-escaped.
#[derive(Debug, PartialEq)]
pub struct Notice {
    pub kind: Kind,
    pub title: String,
    pub detail: String,
    pub open_label: String,
    pub text: String,
}

/// `value` without control characters (C0, DEL, C1): they would break
/// the card's lines or reach the daemon as raw bytes. A tab or line break
/// becomes a space, so the words around it stay apart.
fn clean(value: &str) -> String {
    value
        .chars()
        .filter_map(|c| match c {
            c if c.is_control() && c.is_whitespace() => Some(' '),
            c if c.is_control() => None,
            c => Some(c),
        })
        .collect()
}

/// `&`, `<` and `>` as entities: the body is markup for the daemon.
fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// A string of `min`–`max` characters, cleaned; with `min` 1 it must keep
/// something besides spaces. A missing optional field is "".
fn text(object: &Map<String, Value>, key: &str, min: usize, max: usize) -> Result<String, Failure> {
    let value = match object.get(key) {
        None if min == 0 => return Ok(String::new()),
        Some(Value::String(value)) => value,
        _ => return Err(invalid(key)),
    };
    let count = value.chars().count();
    let value = clean(value);
    if count < min || count > max || (min > 0 && value.trim().is_empty()) {
        return Err(invalid(key));
    }
    Ok(value)
}

/// A text the sender reads in a position where a leading `-` could be
/// taken for one of its options (the headline; the body when it starts
/// with `detail`). Translated texts never start with one.
fn no_option(value: String, key: &str) -> Result<String, Failure> {
    if value.trim_start().starts_with('-') {
        return Err(invalid(key));
    }
    Ok(value)
}

fn parse_task(value: Option<&Value>) -> Result<Task, Failure> {
    let task = value
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("task"))?;
    let id = task
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| model::valid_id(id))
        .ok_or_else(|| invalid("task.id"))?
        .to_string();
    let labels = task
        .get("labels")
        .and_then(Value::as_array)
        .filter(|list| list.len() <= MAX_LABELS)
        .ok_or_else(|| invalid("task.labels"))?;
    let labels = labels
        .iter()
        .map(|label| match label {
            Value::String(name)
                if (1..=MAX_LABEL).contains(&name.chars().count())
                    && !clean(name).trim().is_empty() =>
            {
                Ok(clean(name))
            }
            _ => Err(invalid("task.labels")),
        })
        .collect::<Result<_, _>>()?;
    let required = |key: &str, min: usize, max: usize| {
        if !task.contains_key(key) {
            return Err(invalid(&format!("task.{key}")));
        }
        text(task, key, min, max).map_err(|_| invalid(&format!("task.{key}")))
    };
    Ok(Task {
        id,
        content: required("content", 1, model::MAX_CONTENT)?,
        project: required("project", 0, MAX_PROJECT)?,
        due: required("due", 0, MAX_DUE)?,
        labels,
    })
}

/// `{"kind","title","detail"?,"open_label","text"?,"task"}`: see main.rs.
pub fn parse(request: &Map<String, Value>) -> Result<Notice, Failure> {
    let kind = match request.get("kind").and_then(Value::as_str) {
        Some("added") => Kind::Added(parse_task(request.get("task"))?),
        Some("failed") => Kind::Failed,
        Some("unknown") => Kind::Unknown,
        _ => return Err(invalid("kind")),
    };
    Ok(Notice {
        kind,
        title: no_option(text(request, "title", 1, MAX_TITLE)?, "title")?,
        detail: no_option(text(request, "detail", 0, MAX_DETAIL)?, "detail")?,
        open_label: text(request, "open_label", 1, MAX_OPEN_LABEL)?,
        text: text(request, "text", 0, model::MAX_CONTENT)?,
    })
}

/// The card's body: markup, every interpolated text escaped.
fn body(notice: &Notice) -> String {
    let mut lines = Vec::new();
    match &notice.kind {
        Kind::Added(task) => {
            lines.push(format!("<b>{}</b>", escape(&task.content)));
            let labels: Vec<String> = task
                .labels
                .iter()
                .map(|label| format!("@{}", escape(label)))
                .collect();
            let parts: Vec<String> = [
                (!task.project.is_empty()).then(|| format!("#{}", escape(&task.project))),
                (!task.due.is_empty()).then(|| escape(&task.due)),
                (!labels.is_empty()).then(|| labels.join(" ")),
            ]
            .into_iter()
            .flatten()
            .collect();
            if !parts.is_empty() {
                lines.push(parts.join(" · "));
            }
        }
        Kind::Failed | Kind::Unknown => {
            if !notice.text.is_empty() {
                lines.push(format!("<b>{}</b>", escape(&notice.text)));
            }
            if !notice.detail.is_empty() {
                lines.push(escape(&notice.detail));
            }
        }
    }
    lines.join("\n")
}

/// The sender's argv (without the program). Options first, then the
/// headline and the body as its two positionals, then one action: its
/// words are fixed, and the only request value in them, the validated task
/// id, goes after `--with` (the sender's slot for caller data).
pub fn argv(notice: &Notice) -> Vec<String> {
    let mut out: Vec<String> = ["--app-name", "Todoist"].map(String::from).to_vec();
    out.push(notice.title.clone());
    out.push(body(notice));
    out.push("--action".into());
    out.push(notice.open_label.clone());
    out.extend(["omarchy-shell", "foamy.todoist"].map(String::from));
    match &notice.kind {
        Kind::Added(task) => {
            out.extend(["openTask", "--with"].map(String::from));
            out.push(task.id.clone());
        }
        Kind::Failed | Kind::Unknown => out.push("openInbox".into()),
    }
    out
}

fn failed(text: String) -> Failure {
    Failure::coded("NOTIFY_FAILED", text)
}

/// Runs the sender (from `PATH`, argv only, never a shell): `{"ok":true}`
/// or `NOTIFY_FAILED`.
pub fn send(request: &Map<String, Value>) -> Result<Value, Failure> {
    let notice = parse(request)?;
    // Its own process group, killed as a whole at the deadline.
    let output = Bounded::new(SENDER)
        .args(argv(&notice))
        .timeout(SENDER_TIMEOUT)
        .max_output(MAX_SENDER_OUTPUT)
        .run()
        .map_err(|error| {
            if error.kind() == ErrorKind::NotFound {
                failed(message("The notification command isn't installed.", &[]))
            } else {
                failed(message(
                    "Can't run the notification command (%1).",
                    &[&short(&error.to_string(), 120)],
                ))
            }
        })?;
    if output.timed_out {
        return Err(failed(message(
            "The notification command didn't finish within %1 seconds.",
            &[&SENDER_TIMEOUT.as_secs()],
        )));
    }
    if !output.success() {
        let status = output
            .status
            .code()
            .map_or_else(|| output.status.to_string(), |code| code.to_string());
        return Err(failed(message(
            "The notification command failed (%1).",
            &[&status],
        )));
    }
    Ok(json!({"ok": true}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    fn added() -> Value {
        json!({"kind": "added", "title": "Added to Todoist", "open_label": "Open in Todoist",
               "task": {"id": "T9", "content": "Buy milk", "project": "Shop", "due": "tomorrow",
                        "labels": ["home", "errand"]}})
    }

    #[test]
    fn an_added_task_shows_its_project_date_and_labels() {
        let notice = parse(&map(added())).unwrap();
        assert_eq!(
            argv(&notice),
            [
                "--app-name",
                "Todoist",
                "Added to Todoist",
                "<b>Buy milk</b>\n#Shop · tomorrow · @home @errand",
                "--action",
                "Open in Todoist",
                "omarchy-shell",
                "foamy.todoist",
                "openTask",
                "--with",
                "T9"
            ]
        );
        let mut bare = added();
        bare["task"]["project"] = json!("");
        bare["task"]["due"] = json!("");
        bare["task"]["labels"] = json!([]);
        assert_eq!(argv(&parse(&map(bare)).unwrap())[3], "<b>Buy milk</b>");
        let mut due_only = added();
        due_only["task"]["project"] = json!("");
        due_only["task"]["labels"] = json!([]);
        assert_eq!(
            argv(&parse(&map(due_only)).unwrap())[3],
            "<b>Buy milk</b>\ntomorrow"
        );
    }

    #[test]
    fn a_failed_or_unknown_add_shows_the_text_and_opens_the_inbox() {
        for kind in ["failed", "unknown"] {
            let request = json!({"kind": kind, "title": "Could not add the task",
                                 "detail": "Can't reach Todoist.", "open_label": "Open Inbox",
                                 "text": "Buy milk #Shop", "task": "ignored"});
            assert_eq!(
                argv(&parse(&map(request)).unwrap()),
                [
                    "--app-name",
                    "Todoist",
                    "Could not add the task",
                    "<b>Buy milk #Shop</b>\nCan't reach Todoist.",
                    "--action",
                    "Open Inbox",
                    "omarchy-shell",
                    "foamy.todoist",
                    "openInbox"
                ],
                "{kind}"
            );
        }
        let only_detail =
            json!({"kind": "failed", "title": "x", "detail": "Why", "open_label": "o"});
        assert_eq!(argv(&parse(&map(only_detail)).unwrap())[3], "Why");
    }

    #[test]
    fn texts_are_escaped_and_lose_control_characters() {
        let mut request = added();
        request["title"] = json!("Added\u{7}\u{1b}[31m <now>");
        request["open_label"] = json!("Open\n& go");
        request["task"]["content"] = json!("<i>a</i> & b\r\n\u{0}c\u{85}d");
        request["task"]["project"] = json!("R&D <x>");
        request["task"]["due"] = json!("every\tday");
        request["task"]["labels"] = json!(["a<b>", "c\u{9f}"]);
        let shown = argv(&parse(&map(request)).unwrap());
        // The headline and the action label are plain text for the daemon.
        assert_eq!(shown[2], "Added[31m <now>");
        assert_eq!(
            shown[3],
            "<b>&lt;i&gt;a&lt;/i&gt; &amp; b  c d</b>\n#R&amp;D &lt;x&gt; · every day · @a&lt;b&gt; @c"
        );
        assert_eq!(shown[5], "Open & go");
        let failed = json!({"kind": "unknown", "title": "t", "open_label": "o",
                            "text": "x</b><img src=y>", "detail": "1 < 2\u{1}"});
        assert_eq!(
            argv(&parse(&map(failed)).unwrap())[3],
            "<b>x&lt;/b&gt;&lt;img src=y&gt;</b>\n1 &lt; 2"
        );
    }

    #[test]
    fn sizes_kinds_and_shapes_are_checked() {
        let ok = |patch: &dyn Fn(&mut Value)| {
            let mut request = added();
            patch(&mut request);
            parse(&map(request))
        };
        // Limits are inclusive.
        assert!(ok(&|r| r["title"] = json!("é".repeat(200))).is_ok());
        assert!(ok(&|r| r["open_label"] = json!("é".repeat(100))).is_ok());
        assert!(ok(&|r| r["detail"] = json!("é".repeat(1000))).is_ok());
        assert!(ok(&|r| r["text"] = json!("é".repeat(500))).is_ok());
        assert!(ok(&|r| r["task"]["content"] = json!("é".repeat(500))).is_ok());
        assert!(ok(&|r| r["task"]["labels"] = json!(vec!["l"; 50])).is_ok());
        type Patch<'a> = &'a dyn Fn(&mut Value);
        let bad: [(&str, Patch); 22] = [
            ("kind", &|r| r["kind"] = json!("deleted")),
            ("kind", &|r| r["kind"] = json!(null)),
            ("title", &|r| r["title"] = json!("é".repeat(201))),
            ("title", &|r| r["title"] = json!("")),
            ("title", &|r| r["title"] = json!(" \u{7} ")),
            ("title", &|r| r["title"] = json!("-p")),
            ("title", &|r| {
                r.as_object_mut().unwrap().remove("title");
            }),
            ("open_label", &|r| r["open_label"] = json!("é".repeat(101))),
            ("open_label", &|r| r["open_label"] = json!(5)),
            ("detail", &|r| r["detail"] = json!("é".repeat(1001))),
            ("detail", &|r| r["detail"] = json!("--exec")),
            ("text", &|r| r["text"] = json!("é".repeat(501))),
            ("task", &|r| r["task"] = json!(null)),
            ("task.id", &|r| r["task"]["id"] = json!("../T9")),
            ("task.id", &|r| r["task"]["id"] = json!("")),
            ("task.content", &|r| r["task"]["content"] = json!("")),
            ("task.content", &|r| {
                r["task"]["content"] = json!("é".repeat(501))
            }),
            ("task.project", &|r| {
                r["task"]["project"] = json!("é".repeat(201))
            }),
            ("task.due", &|r| {
                r["task"].as_object_mut().unwrap().remove("due");
            }),
            ("task.labels", &|r| {
                r["task"]["labels"] = json!(vec!["l"; 51])
            }),
            ("task.labels", &|r| r["task"]["labels"] = json!(["ok", ""])),
            ("task.labels", &|r| {
                r["task"]["labels"] = json!(["é".repeat(101)])
            }),
        ];
        for (field, patch) in bad {
            let failure = ok(patch).unwrap_err();
            assert_eq!(failure.code, "INVALID_ARGUMENT", "{field}");
            assert_eq!(
                failure.message,
                format!("The notification's %1 isn't valid.\u{1f}{field}"),
            );
        }
    }
}
