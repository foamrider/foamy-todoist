//! The helper as the panel runs it: the real binary, a fake `secret-tool`
//! on `PATH` (fake-secret-tool.sh), temporary HOME and XDG directories, and
//! Todoist replaced by a loopback fixture server (FOAMY_TODOIST_BASE_URL).
//! Nothing leaves the machine, and the real keyring is never touched.

use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde_json::{Value, json};

const HELPER: &str = env!("CARGO_BIN_EXE_foamy-todoist-helper");
const TOKEN: &str = "0123456789abcdef0123456789abcdef01234567";

/// A request the fixture server received.
#[derive(Debug, Clone)]
struct Seen {
    method: String,
    path: String,
    authorization: String,
    /// The body; form fields decoded.
    body: String,
}

impl Seen {
    fn field(&self, name: &str) -> Option<String> {
        self.body.split('&').find_map(|pair| {
            let (key, value) = pair.split_once('=')?;
            (key == name).then(|| decode(value))
        })
    }
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            out.push(u8::from_str_radix(&text[i + 1..i + 3], 16).unwrap());
            i += 3;
        } else {
            out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
            i += 1;
        }
    }
    String::from_utf8(out).unwrap()
}

/// What the server answers: status, extra headers, body. A request with
/// another bearer token than [`TOKEN`] (or `accept`) gets 401.
#[derive(Clone)]
struct Answer {
    status: u16,
    headers: String,
    body: String,
}

fn ok(body: Value) -> Answer {
    Answer {
        status: 200,
        headers: String::new(),
        body: body.to_string(),
    }
}

fn status(status: u16, body: &str) -> Answer {
    Answer {
        status,
        headers: String::new(),
        body: body.to_string(),
    }
}

/// A Todoist stand-in: answers in order, records every request.
struct Server {
    base: String,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Server {
    fn start(answers: Vec<Answer>, accept: &'static str) -> Server {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let mut answers: VecDeque<Answer> = answers.into();
        std::thread::spawn(move || {
            while let Some(answer) = answers.pop_front() {
                let Ok((stream, _)) = listener.accept() else {
                    return;
                };
                let request = read_request(&stream);
                let refused = request.authorization != format!("Bearer {accept}");
                log.lock().unwrap().push(request);
                let answer = if refused {
                    status(401, r#"{"error":"Unauthorized"}"#)
                } else {
                    answer
                };
                respond(stream, &answer);
            }
        });
        Server { base, seen }
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

fn read_request(stream: &TcpStream) -> Seen {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let method = line.split(' ').next().unwrap_or("").to_string();
    let path = line.split(' ').nth(1).unwrap_or("").to_string();
    let mut length = 0;
    let mut authorization = String::new();
    loop {
        let mut header = String::new();
        reader.read_line(&mut header).unwrap();
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        let (name, value) = header.split_once(':').unwrap();
        match name.to_ascii_lowercase().as_str() {
            "content-length" => length = value.trim().parse().unwrap(),
            "authorization" => authorization = value.trim().to_string(),
            _ => {}
        }
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).unwrap();
    Seen {
        method,
        path,
        authorization,
        body: String::from_utf8(body).unwrap(),
    }
}

fn respond(mut stream: TcpStream, answer: &Answer) {
    let _ = write!(
        stream,
        "HTTP/1.1 {} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{}\r\n{}",
        answer.status,
        answer.body.len(),
        answer.headers,
        answer.body
    );
}

/// A private temporary home, runtime dir and a bin dir with the fake
/// secret-tool; removed when dropped.
struct Home(PathBuf);

impl Home {
    fn new(tag: &str) -> Home {
        let path = std::env::temp_dir().join(format!("ftd-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        for sub in ["home", "run", "bin", "cache"] {
            fs::create_dir_all(path.join(sub)).unwrap();
        }
        fs::set_permissions(path.join("run"), fs::Permissions::from_mode(0o700)).unwrap();
        let tool = path.join("bin/secret-tool");
        fs::write(&tool, include_str!("fake-secret-tool.sh")).unwrap();
        fs::set_permissions(&tool, fs::Permissions::from_mode(0o700)).unwrap();
        Home(path)
    }

    fn signed_in(tag: &str) -> Home {
        let home = Home::new(tag);
        fs::write(home.0.join("bin/item"), TOKEN).unwrap();
        home
    }

    fn bin(&self) -> PathBuf {
        self.0.join("bin")
    }

    fn cache(&self) -> PathBuf {
        self.0.join("cache/foamy-todoist/cache.json")
    }

    fn run(&self, command: &str, input: &str, base: &str) -> (Value, Output) {
        let mut helper = Command::new(HELPER);
        helper
            .arg(command)
            .env_clear()
            .env("PATH", format!("{}:/usr/bin:/bin", self.bin().display()))
            .env("HOME", self.0.join("home"))
            .env("XDG_RUNTIME_DIR", self.0.join("run"))
            .env("XDG_CACHE_HOME", self.0.join("cache"))
            .env("FOAMY_TODOIST_BASE_URL", base)
            .env("LANG", "C")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = helper.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        let text = String::from_utf8_lossy(&output.stdout).to_string();
        assert_eq!(
            text.lines().count(),
            1,
            "one reply line: {text:?} {}",
            String::from_utf8_lossy(&output.stderr)
        );
        // The token never reaches what the helper prints.
        assert!(!text.contains(TOKEN), "token in the reply: {text}");
        assert!(
            !String::from_utf8_lossy(&output.stderr).contains(TOKEN),
            "token on stderr"
        );
        (serde_json::from_str(&text).unwrap(), output)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A loopback URL nothing listens on.
fn closed() -> String {
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    format!("http://127.0.0.1:{port}")
}

fn task(id: &str, content: &str) -> Value {
    json!({"id": id, "content": content, "project_id": "P1", "priority": 1, "due": null,
           "labels": [], "child_order": 1, "day_order": 0, "checked": false, "is_deleted": false})
}

fn user() -> Value {
    json!({"id": "1", "full_name": "Ada Lovelace", "email": "ada@example.com",
           "inbox_project_id": "P1", "token": TOKEN, "tz_info": {"timezone": "Europe/Oslo"}})
}

fn full_sync() -> Value {
    json!({
        "sync_token": "S1", "full_sync": true, "user": user(),
        "projects": [{"id": "P1", "name": "Inbox", "inbox_project": true, "color": "charcoal"},
                     {"id": "P2", "name": "Work", "color": "blue"}],
        "sections": [],
        "items": [task("T1", "one"), task("T2", "two"), task("T3", "three")]
    })
}

fn ids(reply: &Value) -> Vec<String> {
    let mut ids: Vec<String> = reply["tasks"]
        .as_array()
        .unwrap_or_else(|| panic!("no task list in the reply: {reply}"))
        .iter()
        .map(|task| task["id"].as_str().unwrap().to_string())
        .collect();
    ids.sort();
    ids
}

fn decoded_commands(seen: &Seen) -> Vec<Value> {
    serde_json::from_str(&seen.field("commands").unwrap()).unwrap()
}

#[test]
fn token_set_verifies_stores_and_never_leaks() {
    let home = Home::new("token");
    let server = Server::start(vec![ok(json!({"sync_token": "X", "user": user()}))], TOKEN);
    let (reply, _) = home.run(
        "token-set",
        &json!({"token": TOKEN}).to_string(),
        &server.base,
    );
    assert_eq!(reply["state"], "signed_in", "{reply}");
    assert_eq!(reply["user"]["full_name"], "Ada Lovelace");
    assert!(reply["user"].get("token").is_none());
    let seen = server.seen();
    assert_eq!(seen[0].path, "/sync");
    assert_eq!(seen[0].field("sync_token").as_deref(), Some("*"));
    assert_eq!(
        seen[0].field("resource_types").as_deref(),
        Some(r#"["user"]"#)
    );
    // Stored on stdin, never in argv; the cache holds no token.
    assert_eq!(fs::read_to_string(home.bin().join("item")).unwrap(), TOKEN);
    let log = fs::read_to_string(home.bin().join("log")).unwrap();
    assert!(!log.contains(TOKEN), "{log}");
    let cache = fs::read_to_string(home.cache()).unwrap();
    assert!(!cache.contains(TOKEN), "{cache}");
    let mode = fs::metadata(home.cache()).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let dir_mode = fs::metadata(home.cache().parent().unwrap())
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(dir_mode, 0o700);
    let (status, _) = home.run("status", "", &closed());
    assert_eq!(status["state"], "signed_in");
    assert_eq!(status["user"]["email"], "ada@example.com");
}

#[test]
fn a_refused_or_malformed_token_is_not_stored() {
    let home = Home::new("refused");
    let server = Server::start(vec![ok(json!({}))], "another-token");
    let (reply, _) = home.run(
        "token-set",
        &json!({"token": TOKEN}).to_string(),
        &server.base,
    );
    assert_eq!(reply["code"], "INVALID_TOKEN", "{reply}");
    assert_eq!(server.seen().len(), 1);
    assert!(!home.bin().join("item").exists());
    for bad in [
        json!({"token": "has space"}),
        json!({"token": ""}),
        json!({}),
        json!({"token": "x".repeat(257)}),
    ] {
        let (reply, _) = home.run("token-set", &bad.to_string(), &closed());
        assert_eq!(reply["code"], "INVALID_ARGUMENT", "{bad}");
    }
    let (reply, _) = home.run("token-set", &"x".repeat(5000), &closed());
    assert_eq!(reply["code"], "INVALID_ARGUMENT");
    assert_eq!(reply["error"], "The request is too large.");
    let (status, _) = home.run("status", "", &closed());
    assert_eq!(status["state"], "signed_out");
}

#[test]
fn full_then_incremental_merge() {
    let home = Home::signed_in("merge");
    let mut done = task("T2", "two");
    done["checked"] = json!(true);
    let mut deleted = task("T3", "three");
    deleted["is_deleted"] = json!(true);
    let mut full = full_sync();
    full["collaborators"] = json!([{"id": "1", "full_name": "Ada", "email": "ada@example.com"}]);
    full["collaborator_states"] = json!([{"project_id": "P2", "user_id": "1", "state": "active"}]);
    let server = Server::start(
        vec![
            ok(full),
            ok(json!({"sync_token": "S2", "full_sync": false,
                      "items": [task("T1", "one, edited"), done, deleted, task("T4", "four")]})),
        ],
        TOKEN,
    );
    let (first, _) = home.run("sync", "", &server.base);
    assert_eq!(ids(&first), ["T1", "T2", "T3"], "{first}");
    assert_eq!(first["user"]["inbox_project_id"], "P1");
    assert!(first["synced_at"].as_str().unwrap().ends_with('Z'));
    // The panel shows a shared project's people from this map.
    assert_eq!(
        first["project_collaborators"],
        json!({"P2": ["1"]}),
        "{first}"
    );
    let (second, _) = home.run("sync", "{}", &server.base);
    assert_eq!(ids(&second), ["T1", "T4"], "{second}");
    let edited = second["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == "T1")
        .unwrap();
    assert_eq!(edited["content"], "one, edited");
    assert_eq!(
        second["projects"].as_array().unwrap().len(),
        2,
        "projects kept"
    );
    let seen = server.seen();
    assert_eq!(seen[0].field("sync_token").as_deref(), Some("*"));
    assert_eq!(seen[1].field("sync_token").as_deref(), Some("S1"));
    // The full sync and the next one ask for every kind the panel shows.
    for request in &seen[..2] {
        assert_eq!(
            request.field("resource_types").as_deref(),
            Some(
                r#"["items","projects","sections","labels","collaborators","collaborator_states","user"]"#
            )
        );
    }
    assert_eq!(seen[1].authorization, format!("Bearer {TOKEN}"));
}

#[test]
fn an_invalid_sync_token_falls_back_to_one_full_sync() {
    let home = Home::signed_in("fallback");
    let server = Server::start(
        vec![
            ok(full_sync()),
            status(
                400,
                r#"{"error":"Invalid sync token","error_tag":"INVALID_SYNC_TOKEN"}"#,
            ),
            ok(
                json!({"sync_token": "S9", "full_sync": true, "user": user(),
                      "projects": [{"id": "P1", "name": "Inbox", "inbox_project": true}],
                      "items": [task("T7", "seven")]}),
            ),
        ],
        TOKEN,
    );
    home.run("sync", "", &server.base);
    // A change rides on the refused request: the full sync that follows
    // sends the same commands, UUIDs included, so Todoist runs it once.
    let (reply, _) = home.run(
        "apply",
        r#"{"commands":[{"op":"close","id":"T1"}]}"#,
        &server.base,
    );
    assert_eq!(ids(&reply), ["T7"], "{reply}");
    let seen = server.seen();
    assert_eq!(seen.len(), 3);
    assert_eq!(seen[1].field("sync_token").as_deref(), Some("S1"));
    assert_eq!(seen[2].field("sync_token").as_deref(), Some("*"));
    assert_eq!(decoded_commands(&seen[1])[0]["type"], "item_close");
    assert_eq!(
        seen[2].field("commands"),
        seen[1].field("commands"),
        "the retry must send the same command UUIDs"
    );
    // A full sync that is refused too is reported, not retried.
    let again = Server::start(vec![status(400, "{}")], TOKEN);
    let (reply, _) = home.run("sync", r#"{"full":true}"#, &again.base);
    assert_eq!(reply["code"], "HTTP", "{reply}");
    assert_eq!(reply["error"], "Todoist answered HTTP %1.\u{1f}400");
    assert_eq!(again.seen().len(), 1);
}

#[test]
fn refused_rate_limited_and_malformed_replies() {
    let home = Home::signed_in("errors");
    // The server refuses every token: 401.
    let server = Server::start(vec![ok(json!({}))], "nobody");
    let (reply, _) = home.run("sync", "", &server.base);
    assert_eq!(reply["code"], "INVALID_TOKEN", "{reply}");
    assert_eq!(server.seen().len(), 1);

    let limited = Answer {
        status: 429,
        headers: "Retry-After: 42\r\n".into(),
        body: "{}".into(),
    };
    let server = Server::start(vec![limited], TOKEN);
    let (reply, _) = home.run("sync", "", &server.base);
    assert_eq!(reply["code"], "RATE_LIMITED", "{reply}");
    assert_eq!(reply["retry_after"], 42);
    assert_eq!(
        reply["error"],
        "Todoist is limiting requests. Try again in %1 seconds.\u{1f}42"
    );
    let server = Server::start(
        vec![status(429, r#"{"error_extra":{"retry_after":7}}"#)],
        TOKEN,
    );
    assert_eq!(home.run("sync", "", &server.base).0["retry_after"], 7);
    let server = Server::start(vec![status(429, "")], TOKEN);
    let (reply, _) = home.run("sync", "", &server.base);
    assert!(reply.get("retry_after").is_none(), "{reply}");

    for body in ["not json", "[]", r#"{"items":[]}"#] {
        let server = Server::start(vec![status(200, body)], TOKEN);
        let (reply, _) = home.run("sync", "", &server.base);
        assert_eq!(reply["code"], "HTTP", "{body}: {reply}");
        assert_eq!(reply["error"], "Todoist sent an unexpected reply.");
    }
    let (reply, _) = home.run("sync", "", &closed());
    assert_eq!(reply["code"], "NETWORK");
    // Only loopback test servers are accepted.
    let (reply, _) = home.run("sync", "", "http://example.com:80");
    assert_eq!(reply["code"], "INVALID_ARGUMENT");
    // A failed sync keeps the cache as it was: nothing written.
    assert!(!home.cache().exists());
}

#[test]
fn a_corrupt_cache_is_dropped_for_a_full_sync() {
    let home = Home::signed_in("corrupt");
    fs::create_dir_all(home.cache().parent().unwrap()).unwrap();
    fs::set_permissions(
        home.cache().parent().unwrap(),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    fs::write(home.cache(), "{ not json").unwrap();
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    let (reply, _) = home.run("sync", "", &server.base);
    assert_eq!(ids(&reply), ["T1", "T2", "T3"]);
    assert_eq!(server.seen()[0].field("sync_token").as_deref(), Some("*"));
    let cache: Value = serde_json::from_str(&fs::read_to_string(home.cache()).unwrap()).unwrap();
    assert_eq!(cache["sync_token"], "S1");
}

#[test]
fn apply_sends_one_request_and_reports_each_change() {
    let home = Home::signed_in("apply");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    // The answer's sync_status keys are the command UUIDs, which the
    // helper makes: the fixture answers by position instead.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let seen = Arc::new(Mutex::new(None));
    let log = seen.clone();
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let request = read_request(&stream);
        let commands = decoded_commands(&request);
        let mut done = task("T1", "one");
        done["checked"] = json!(true);
        let body = json!({
            "sync_token": "S2",
            "sync_status": {
                commands[0]["uuid"].as_str().unwrap(): "ok",
                commands[1]["uuid"].as_str().unwrap(): {"error_tag": "ITEM_NOT_FOUND", "error": "Task not found", "http_code": 404}
            },
            "items": [done]
        });
        *log.lock().unwrap() = Some(request);
        respond(stream, &ok(body));
    });
    let input = json!({"commands": [
        {"op": "close", "id": "T1"},
        {"op": "due", "id": "T9", "date": "2026-11-17T14:00:00"}
    ]});
    let (reply, _) = home.run("apply", &input.to_string(), &base);
    thread.join().unwrap();
    assert_eq!(reply["results"]["T1"], "ok", "{reply}");
    assert_eq!(reply["results"]["T9"]["code"], "ITEM_NOT_FOUND");
    assert_eq!(
        reply["results"]["T9"]["error"],
        "Todoist didn't accept the change (%1).\u{1f}Task not found"
    );
    assert_eq!(ids(&reply), ["T2", "T3"]);
    let request = seen.lock().unwrap().clone().unwrap();
    assert_eq!(request.field("sync_token").as_deref(), Some("S1"));
    let commands = decoded_commands(&request);
    assert_eq!(commands[0]["type"], "item_close");
    assert_eq!(commands[0]["args"], json!({"id": "T1"}));
    assert_eq!(commands[1]["type"], "item_update");
    assert_eq!(
        commands[1]["args"],
        json!({"id": "T9", "due": {"date": "2026-11-17T14:00:00"}}),
        "a move keeps its time"
    );
    assert_ne!(commands[0]["uuid"], commands[1]["uuid"]);
    // Invalid changes never reach Todoist.
    let (reply, _) = home.run(
        "apply",
        r#"{"commands":[{"op":"close","id":"a/b"}]}"#,
        &closed(),
    );
    assert_eq!(reply["code"], "INVALID_ARGUMENT");
}

/// A server for `add`: Quick Add answers `created`, then the Sync request
/// is answered `ok` for every command. Returns what it saw.
fn add_server(created: Value, sync: Value) -> (String, JoinHandle<Vec<Seen>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let thread = std::thread::spawn(move || {
        let mut seen = Vec::new();
        let (stream, _) = listener.accept().unwrap();
        seen.push(read_request(&stream));
        respond(stream, &ok(created));
        let (stream, _) = listener.accept().unwrap();
        let request = read_request(&stream);
        let mut body = sync;
        let statuses: serde_json::Map<String, Value> = request
            .field("commands")
            .map(|text| serde_json::from_str::<Vec<Value>>(&text).unwrap())
            .unwrap_or_default()
            .iter()
            .map(|command| (command["uuid"].as_str().unwrap().to_string(), json!("ok")))
            .collect();
        body["sync_status"] = Value::Object(statuses);
        seen.push(request);
        respond(stream, &ok(body));
        seen
    });
    (base, thread)
}

#[test]
fn add_follows_up_with_the_views_date_and_project() {
    let home = Home::signed_in("add");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    let mut created = task("T5", "Call Bob");
    created["project_id"] = json!("P1");
    let mut moved = created.clone();
    moved["project_id"] = json!("P2");
    moved["due"] = json!({"date": "2026-11-17", "is_recurring": false, "string": "17 Nov"});
    let (base, thread) = add_server(created, json!({"sync_token": "S2", "items": [moved]}));
    let input = json!({"text": "Call Bob", "due_date": "2026-11-17", "project_id": "P2"});
    let (reply, _) = home.run("add", &input.to_string(), &base);
    let seen = thread.join().unwrap();
    assert_eq!(reply["added"], "T5", "{reply}");
    assert!(reply.get("warning").is_none(), "{reply}");
    assert_eq!(seen[0].path, "/tasks/quick");
    assert_eq!(
        serde_json::from_str::<Value>(&seen[0].body).unwrap(),
        json!({"text": "Call Bob"})
    );
    let commands = decoded_commands(&seen[1]);
    assert_eq!(commands.len(), 2);
    assert_eq!(commands[0]["type"], "item_update");
    assert_eq!(
        commands[0]["args"],
        json!({"id": "T5", "due": {"date": "2026-11-17"}})
    );
    assert_eq!(commands[1]["type"], "item_move");
    assert_eq!(commands[1]["args"], json!({"id": "T5", "project_id": "P2"}));
    let added = reply["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == "T5")
        .unwrap();
    assert_eq!(added["project_id"], "P2");

    // Quick Add's own date and #project win: no follow-up commands.
    let mut parsed = task("T6", "Dentist");
    parsed["project_id"] = json!("P2");
    parsed["due"] = json!({"date": "2026-11-20", "is_recurring": false, "string": "fri"});
    let (base, thread) = add_server(
        parsed.clone(),
        json!({"sync_token": "S3", "items": [parsed]}),
    );
    let input = json!({"text": "Dentist fri #Work", "due_date": "2026-11-17", "project_id": "P1"});
    let (reply, _) = home.run("add", &input.to_string(), &base);
    let seen = thread.join().unwrap();
    assert_eq!(reply["added"], "T6");
    assert!(seen[1].field("commands").is_none(), "{:?}", seen[1]);
}

#[test]
fn an_add_whose_follow_up_fails_is_still_added() {
    let home = Home::signed_in("add-warn");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    let server = Server::start(vec![ok(task("T5", "Call Bob")), status(503, "")], TOKEN);
    let (reply, _) = home.run(
        "add",
        r#"{"text":"Call Bob","due_date":"2026-11-17"}"#,
        &server.base,
    );
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["added"], "T5");
    assert_eq!(reply["warning"], "Todoist answered HTTP %1.\u{1f}503");
    assert!(ids(&reply).contains(&"T5".to_string()));
    assert_eq!(server.seen().len(), 2);
    // Not a fresh read: the panel must not treat it as one.
    assert_eq!(reply["stale"], true, "{reply}");
    assert_eq!(reply["warning_code"], "HTTP");
    assert!(reply.get("retry_after").is_none(), "{reply}");
    // A rate-limited follow-up carries Todoist's wait to the panel.
    let limited = Answer {
        status: 429,
        headers: "Retry-After: 30\r\n".into(),
        body: "{}".into(),
    };
    let server = Server::start(vec![ok(task("T7", "Milk")), limited], TOKEN);
    let (reply, _) = home.run("add", r#"{"text":"Milk"}"#, &server.base);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["added"], "T7");
    assert_eq!(reply["stale"], true);
    assert_eq!(reply["warning_code"], "RATE_LIMITED");
    assert_eq!(reply["retry_after"], 30);
    // A refused Quick Add is an error and adds nothing.
    let server = Server::start(vec![status(400, r#"{"error":"bad"}"#)], TOKEN);
    let (reply, _) = home.run("add", r#"{"text":"x"}"#, &server.base);
    assert_eq!(reply["code"], "HTTP");
}

#[test]
fn signed_out_and_locked_keyrings() {
    let home = Home::new("locked");
    let (reply, _) = home.run("sync", "", &closed());
    assert_eq!(reply["code"], "SIGNED_OUT");
    let (reply, _) = home.run("status", "", &closed());
    assert_eq!(
        reply,
        json!({"ok": true, "state": "signed_out", "user": null})
    );

    // Signed in with cached tasks, then the keyring locks.
    fs::write(home.bin().join("item"), TOKEN).unwrap();
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    assert!(home.cache().exists());
    fs::write(home.bin().join("locked"), "").unwrap();
    for command in ["status", "sync", "token-clear"] {
        let (reply, _) = home.run(command, "", &closed());
        assert_eq!(reply["code"], "KEYRING_LOCKED", "{command}: {reply}");
    }
    // A locked keyring is not a sign-out: the token stays, so the account
    // is still signed in once it is unlocked. The cache went first: it
    // never holds the token, and the next sync writes it again.
    assert!(home.bin().join("item").exists(), "the token was removed");
    assert!(!home.cache().exists(), "the cache stayed");
    fs::remove_file(home.bin().join("locked")).unwrap();
    let (reply, _) = home.run("status", "", &closed());
    assert_eq!(
        reply,
        json!({"ok": true, "state": "signed_in", "user": null})
    );
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    assert!(home.cache().exists(), "the sync wrote no cache");
    // Unlocked, sign-out removes the item and the cache.
    let (reply, _) = home.run("token-clear", "", &closed());
    assert_eq!(reply["state"], "signed_out", "{reply}");
    assert!(!home.bin().join("item").exists());
    assert!(!home.cache().exists());
}

#[test]
fn a_stored_value_that_is_not_a_token_is_refused_by_every_command() {
    let home = Home::new("bad-item");
    // Something other than this helper stored the item.
    for stored in ["not a token", ""] {
        fs::write(home.bin().join("item"), stored).unwrap();
        for (command, input) in [
            ("status", ""),
            ("sync", ""),
            ("apply", r#"{"commands":[{"op":"close","id":"T1"}]}"#),
            ("add", r#"{"text":"Milk"}"#),
            ("task", r#"{"id":"T1"}"#),
        ] {
            let (reply, _) = home.run(command, input, &closed());
            assert_eq!(
                (reply["code"].as_str(), reply["error"].as_str()),
                (
                    Some("INVALID_TOKEN"),
                    Some("Todoist didn't accept the API token.")
                ),
                "{command} with {stored:?}: {reply}"
            );
        }
    }
    // Sign-out still removes it.
    let (reply, _) = home.run("token-clear", "", &closed());
    assert_eq!(reply["state"], "signed_out", "{reply}");
    assert!(!home.bin().join("item").exists());
}

#[test]
fn a_held_lock_is_busy_and_no_runtime_dir_is_unavailable() {
    let home = Home::signed_in("busy");
    let lock_dir = home.0.join("run/foamy-todoist");
    fs::create_dir_all(&lock_dir).unwrap();
    fs::set_permissions(&lock_dir, fs::Permissions::from_mode(0o700)).unwrap();
    let file = fs::File::create(lock_dir.join("state.lock")).unwrap();
    file.lock().unwrap();
    let started = std::time::Instant::now();
    let (reply, _) = home.run("status", "", &closed());
    assert_eq!(reply["code"], "BUSY", "{reply}");
    assert!(started.elapsed() >= std::time::Duration::from_secs(14));
    drop(file);
    let mut helper = Command::new(HELPER);
    helper
        .arg("status")
        .env_clear()
        .env("PATH", format!("{}:/usr/bin:/bin", home.bin().display()))
        .env("HOME", home.0.join("home"))
        .env("XDG_CACHE_HOME", home.0.join("cache"))
        .stdin(Stdio::null());
    let reply: Value = serde_json::from_slice(&helper.output().unwrap().stdout).unwrap();
    assert_eq!(reply["code"], "LOCK_UNAVAILABLE", "{reply}");
}

#[test]
fn a_refused_runtime_dir_says_why() {
    let home = Home::signed_in("refused-run");
    let dir = home.0.join("run/foamy-todoist");
    let elsewhere = home.0.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    set_mode(&elsewhere, 0o700);
    // Either could be another user's doing: neither holds the lock.
    let open = || {
        fs::create_dir(&dir).unwrap();
        set_mode(&dir, 0o755);
    };
    let link = || std::os::unix::fs::symlink(&elsewhere, &dir).unwrap();
    let cases: [(&str, &dyn Fn(), &str); 2] = [
        ("open to others", &open, "is accessible to other users"),
        ("a symlink", &link, "is a symlink or not a directory"),
    ];
    for (case, make, reason) in cases {
        make();
        let (reply, _) = home.run("status", "", &closed());
        let error = reply["error"].as_str().unwrap_or("");
        assert_eq!(reply["code"], "LOCK_UNAVAILABLE", "{case}: {reply}");
        assert!(
            error.starts_with("Can't use the Todoist lock file (%1).\u{1f}")
                && error.contains(reason),
            "{case}: the reason is missing: {reply}"
        );
        // Nothing is read without the lock.
        assert!(!home.bin().join("log").exists(), "{case}: secret-tool ran");
        if dir.is_symlink() {
            fs::remove_file(&dir).unwrap();
        } else {
            fs::remove_dir(&dir).unwrap();
        }
    }
}

#[test]
fn wrong_arguments_are_refused() {
    let home = Home::new("args");
    for args in [vec![], vec!["sync", "extra"], vec!["delete"]] {
        let output = Command::new(HELPER)
            .args(&args)
            .env_clear()
            .env("XDG_RUNTIME_DIR", home.0.join("run"))
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(reply["code"], "INVALID_ARGUMENT", "{args:?}");
        assert_eq!(
            reply["error"], "The Todoist helper was called with the wrong arguments.",
            "{args:?}"
        );
        assert_ne!(output.status.code(), Some(0));
    }
}

#[test]
fn a_request_that_is_not_one_json_object_is_refused() {
    let home = Home::signed_in("request");
    let cut_token = format!(r#"{{"token":"{TOKEN}""#);
    for (command, input) in [
        ("apply", "[]"),
        ("apply", "{"),
        ("sync", "{} {}"),
        ("token-set", cut_token.as_str()),
    ] {
        let (reply, _) = home.run(command, input, &closed());
        assert_eq!(
            (reply["code"].as_str(), reply["error"].as_str()),
            (
                Some("INVALID_ARGUMENT"),
                Some("The request isn't valid JSON.")
            ),
            "{command} {input}"
        );
    }
    // Refused before the keyring: the fake secret-tool never ran.
    assert!(!home.bin().join("log").exists(), "secret-tool was called");
}

#[test]
fn an_unusable_cache_is_found_before_the_token_is_stored() {
    let home = Home::new("cache-first");
    // A cache directory others can read: ensure_private_dir refuses it.
    let dir = home.cache().parent().unwrap().to_path_buf();
    fs::create_dir_all(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    let server = Server::start(vec![ok(json!({"sync_token": "X", "user": user()}))], TOKEN);
    let (reply, _) = home.run(
        "token-set",
        &json!({"token": TOKEN}).to_string(),
        &server.base,
    );
    assert_eq!(reply["code"], "INTERNAL", "{reply}");
    assert!(
        !home.bin().join("item").exists(),
        "stored although the reply is an error"
    );
    assert!(server.seen().is_empty(), "nothing asked of Todoist");
}

/// A second account's token and user, for a change of account.
const OTHER: &str = "fedcba9876543210fedcba9876543210fedcba98";

fn other_user() -> Value {
    json!({"id": "2", "full_name": "Grace Hopper", "email": "grace@example.com",
           "inbox_project_id": "P9", "tz_info": {"timezone": "UTC"}})
}

fn set_mode(path: &std::path::Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[test]
fn a_cache_that_cannot_be_removed_stores_no_token() {
    // cache.json is a directory: it can't be removed.
    let home = Home::new("cache-dir");
    fs::create_dir_all(home.cache()).unwrap();
    set_mode(home.cache().parent().unwrap(), 0o700);
    let server = Server::start(vec![ok(json!({"sync_token": "X", "user": user()}))], TOKEN);
    let (reply, _) = home.run(
        "token-set",
        &json!({"token": TOKEN}).to_string(),
        &server.base,
    );
    assert_eq!(reply["code"], "INTERNAL", "{reply}");
    assert!(
        reply["error"]
            .as_str()
            .unwrap()
            .starts_with("Can't remove the Todoist cache (%1).\u{1f}"),
        "{reply}"
    );
    assert!(
        !home.bin().join("item").exists(),
        "stored with a failed reply"
    );
    let (status, _) = home.run("status", "", &closed());
    assert_eq!(status["state"], "signed_out", "{status}");

    // The previous account's cache in a directory that can be read but not
    // changed: the new account's token is refused, the old one stays with
    // its own cache.
    let home = synced("cache-readonly");
    let dir = home.cache().parent().unwrap().to_path_buf();
    set_mode(&dir, 0o500);
    let server = Server::start(
        vec![ok(json!({"sync_token": "X", "user": other_user()}))],
        OTHER,
    );
    let (reply, _) = home.run(
        "token-set",
        &json!({"token": OTHER}).to_string(),
        &server.base,
    );
    let (status, _) = home.run("status", "", &closed());
    // Writable again before any assertion, so the home can be removed.
    set_mode(&dir, 0o700);
    assert_eq!(reply["code"], "INTERNAL", "{reply}");
    assert!(
        reply["error"]
            .as_str()
            .unwrap()
            .starts_with("Can't remove the Todoist cache (%1).\u{1f}"),
        "{reply}"
    );
    assert_eq!(fs::read_to_string(home.bin().join("item")).unwrap(), TOKEN);
    assert_eq!(status["user"]["full_name"], "Ada Lovelace", "{status}");
}

#[test]
fn a_sign_out_that_cannot_remove_the_cache_keeps_the_token() {
    // Nothing is removed: the token stays with its cache, still signed in,
    // so Sign out can run again once the folder is fixed, and no cache is
    // left without its token to block the next token-set.
    let kept = |home: &Home, case: &str, key: &str| {
        let (reply, _) = home.run("token-clear", "", &closed());
        assert_eq!(reply["code"], "INTERNAL", "{case}: {reply}");
        assert!(
            reply["error"]
                .as_str()
                .unwrap_or("")
                .starts_with(&format!("{key}\u{1f}")),
            "{case}: {reply}"
        );
        assert_eq!(
            fs::read_to_string(home.bin().join("item")).unwrap_or_default(),
            TOKEN,
            "{case}: the token went without its cache"
        );
        assert!(home.cache().exists(), "{case}: the cache went");
    };

    // cache.json is a directory: it can't be removed.
    let home = Home::signed_in("clear-cache-dir");
    fs::create_dir_all(home.cache()).unwrap();
    set_mode(home.cache().parent().unwrap(), 0o700);
    kept(
        &home,
        "cache.json is a directory",
        "Can't remove the Todoist cache (%1).",
    );

    // A cache folder open to others: cache_file() refuses it, also before
    // the keyring.
    let home = Home::signed_in("clear-cache-open");
    let dir = home.cache().parent().unwrap().to_path_buf();
    fs::create_dir_all(&dir).unwrap();
    fs::write(home.cache(), "{}").unwrap();
    set_mode(&dir, 0o755);
    kept(
        &home,
        "the cache folder is open to others",
        "Can't use the Todoist cache (%1).",
    );
}

#[test]
fn a_cache_that_cannot_be_written_after_storing_is_a_warning() {
    // The previous account's cache is removed, then the directory turns
    // read-only once the new token is stored: the new cache can't be written.
    let home = synced("cache-warn");
    let dir = home.cache().parent().unwrap().to_path_buf();
    fs::write(
        home.bin().join("readonly-after-store"),
        dir.to_str().unwrap(),
    )
    .unwrap();
    let server = Server::start(
        vec![ok(json!({"sync_token": "X", "user": other_user()}))],
        OTHER,
    );
    let (reply, _) = home.run(
        "token-set",
        &json!({"token": OTHER}).to_string(),
        &server.base,
    );
    let (status, _) = home.run("status", "", &closed());
    // Writable again before any assertion, so the home can be removed.
    set_mode(&dir, 0o700);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["state"], "signed_in");
    assert_eq!(reply["user"]["full_name"], "Grace Hopper");
    assert!(
        reply["warning"]
            .as_str()
            .unwrap()
            .starts_with("Can't save the Todoist cache (%1).\u{1f}"),
        "{reply}"
    );
    assert_eq!(fs::read_to_string(home.bin().join("item")).unwrap(), OTHER);
    // Nothing of the previous account shows under the new token.
    assert!(
        !home.cache().exists(),
        "the previous account's cache stayed"
    );
    assert_eq!(
        status,
        json!({"ok": true, "state": "signed_in", "user": null})
    );
}

#[test]
fn an_explicit_inbox_in_the_text_is_kept() {
    let home = Home::signed_in("add-inbox");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    let created = task("T5", "Buy milk");
    let (base, thread) = add_server(
        created.clone(),
        json!({"sync_token": "S2", "items": [created]}),
    );
    let input = json!({"text": "Buy milk #Inbox", "due_date": null, "project_id": "P2"});
    let (reply, _) = home.run("add", &input.to_string(), &base);
    let seen = thread.join().unwrap();
    assert_eq!(reply["added"], "T5", "{reply}");
    assert!(
        seen[1].field("commands").is_none(),
        "moved out of the Inbox it named: {:?}",
        seen[1]
    );
    // Without a #project the task still goes to the view's project.
    let (base, thread) = add_server(
        task("T6", "Buy milk"),
        json!({"sync_token": "S3", "items": []}),
    );
    let input = json!({"text": "Buy milk, email#1 and C# books", "project_id": "P2"});
    home.run("add", &input.to_string(), &base);
    let seen = thread.join().unwrap();
    assert_eq!(decoded_commands(&seen[1])[0]["type"], "item_move");
}

#[test]
fn a_cache_from_before_labels_gets_one_full_sync() {
    let home = Home::signed_in("old-cache");
    let dir = home.cache().parent().unwrap().to_path_buf();
    fs::create_dir_all(&dir).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let old = json!({"version": 1, "sync_token": "OLD", "user": {"id": "1", "full_name": "Ada Lovelace"},
        "projects": [{"id": "P1", "name": "Inbox", "inbox": true}], "sections": [], "tasks": [task("T0", "old")]});
    fs::write(home.cache(), old.to_string()).unwrap();
    fs::set_permissions(home.cache(), fs::Permissions::from_mode(0o600)).unwrap();
    // The name still shows before the sync.
    let (status, _) = home.run("status", "", &closed());
    assert_eq!(status["user"]["full_name"], "Ada Lovelace", "{status}");
    let mut full = full_sync();
    full["labels"] = json!([{"id": "L1", "name": "Food", "color": "lime_green", "item_order": 1}]);
    let server = Server::start(
        vec![
            ok(full),
            ok(json!({"sync_token": "S2", "full_sync": false})),
        ],
        TOKEN,
    );
    let (first, _) = home.run("sync", "", &server.base);
    assert_eq!(first["labels"][0]["name"], "Food", "{first}");
    assert!(!ids(&first).contains(&"T0".to_string()));
    home.run("sync", "", &server.base);
    let seen = server.seen();
    assert_eq!(seen[0].field("sync_token").as_deref(), Some("*"));
    assert_eq!(
        seen[1].field("sync_token").as_deref(),
        Some("S1"),
        "only one full sync"
    );
}

#[test]
fn a_failed_full_sync_retry_keeps_the_previous_state() {
    let home = Home::signed_in("retry-keeps");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    // Quick Add works; the follow-up read gets 400 (the sync token refused),
    // and the full sync that follows fails too.
    let server = Server::start(
        vec![
            ok(task("T5", "Call Bob")),
            status(400, "{}"),
            status(503, ""),
        ],
        TOKEN,
    );
    let (reply, _) = home.run("add", r#"{"text":"Call Bob"}"#, &server.base);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["stale"], true, "{reply}");
    assert_eq!(ids(&reply), ["T1", "T2", "T3", "T5"], "{reply}");
    let seen = server.seen();
    assert_eq!(seen.len(), 3);
    assert_eq!(seen[2].field("sync_token").as_deref(), Some("*"));
    // The cache still holds the old sync token: the next sync tries it again.
    let cache: Value = serde_json::from_str(&fs::read_to_string(home.cache()).unwrap()).unwrap();
    assert_eq!(cache["sync_token"], "S1");
}

#[test]
fn a_quick_add_without_an_answer_has_an_unknown_outcome() {
    let home = Home::signed_in("unknown-outcome");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    // The server reads the whole request, then closes without answering:
    // Todoist may have created the task.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let request = read_request(&stream);
        drop(stream);
        request
    });
    let (reply, _) = home.run("add", r#"{"text":"Call Bob"}"#, &base);
    let request = thread.join().unwrap();
    assert_eq!(request.path, "/tasks/quick");
    assert_eq!(reply["code"], "UNKNOWN_OUTCOME", "{reply}");
    assert_eq!(
        reply["error"],
        "Todoist didn't answer. The task may have been added: check the list before adding it again."
    );
    // Nothing reached Todoist: an ordinary network error.
    let (reply, _) = home.run("add", r#"{"text":"Call Bob"}"#, &closed());
    assert_eq!(reply["code"], "NETWORK", "{reply}");
}

#[test]
fn a_quick_add_answer_without_a_task_id_has_an_unknown_outcome() {
    let home = Home::signed_in("unknown-2xx");
    let server = Server::start(vec![ok(full_sync())], TOKEN);
    home.run("sync", "", &server.base);
    // Todoist said yes, but what it sent doesn't name the task: it may exist.
    for body in ["", "{}", "not json", r#"{"id": "a b"}"#] {
        let server = Server::start(vec![status(200, body)], TOKEN);
        let (reply, _) = home.run("add", r#"{"text":"Call Bob"}"#, &server.base);
        assert_eq!(reply["code"], "UNKNOWN_OUTCOME", "{body:?}: {reply}");
        assert_eq!(server.seen().len(), 1, "no follow-up for {body:?}");
    }
}

/// A Sync server for `apply`: answers each command with `status(command)`
/// (keyed by the UUIDs the helper made) and the incremental `items`.
fn apply_server(status: fn(&Value) -> Value, items: Value) -> (String, JoinHandle<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let request = read_request(&stream);
        let statuses: serde_json::Map<String, Value> = decoded_commands(&request)
            .iter()
            .map(|command| {
                (
                    command["uuid"].as_str().unwrap().to_string(),
                    status(command),
                )
            })
            .collect();
        respond(
            stream,
            &ok(json!({"sync_token": "S2", "sync_status": statuses, "items": items})),
        );
        request
    });
    (base, thread)
}

fn synced(tag: &str) -> Home {
    let home = Home::signed_in(tag);
    let mut sync = full_sync();
    sync["sections"] =
        json!([{"id": "S1", "project_id": "P2", "name": "Doing", "section_order": 1}]);
    sync["items"][2]["project_id"] = json!("P2");
    sync["items"][2]["section_id"] = json!("S1");
    let server = Server::start(vec![ok(sync)], TOKEN);
    home.run("sync", "", &server.base);
    assert_eq!(server.seen().len(), 1);
    home
}

#[test]
fn an_update_and_its_move_go_in_one_sync_with_one_result_per_task() {
    let home = synced("update");
    let mut edited = task("T1", "Call Bob");
    edited["project_id"] = json!("P2");
    edited["priority"] = json!(4);
    edited["deadline"] = json!({"date": "2026-12-01", "lang": "en"});
    // T2's update works but its move is refused: T2's result is the refusal.
    let (base, thread) = apply_server(
        |command| {
            if command["type"] == "item_move" && command["args"]["id"] == "T2" {
                json!({"error_tag": "INVALID_ARGUMENT_VALUE", "error": "Invalid argument value", "http_code": 400})
            } else {
                json!("ok")
            }
        },
        json!([edited]),
    );
    let input = json!({"commands": [
        {"op": "update", "id": "T1", "content": " Call Bob ", "priority": 4, "labels": ["phone"],
         "due_string": "tomorrow 9am", "deadline": "2026-12-01", "description": "Ask about\nthe trip",
         "project_id": "P2"},
        {"op": "update", "id": "T2", "deadline": "", "due_string": "", "section_id": "S1"},
        // T3's cached place is S1, but the cache may be stale: the move goes too.
        {"op": "update", "id": "T3", "content": "three!", "project_id": "P2", "section_id": "S1"},
        {"op": "close", "id": "T9"}
    ]});
    let (reply, _) = home.run("apply", &input.to_string(), &base);
    let request = thread.join().unwrap();
    assert_eq!(request.path, "/sync");
    let commands = decoded_commands(&request);
    let shapes: Vec<(&str, &Value)> = commands
        .iter()
        .map(|c| (c["type"].as_str().unwrap(), &c["args"]))
        .collect();
    assert_eq!(
        shapes,
        [
            (
                "item_update",
                &json!({"id": "T1", "content": "Call Bob", "priority": 4, "labels": ["phone"],
                                    "due": {"string": "tomorrow 9am"}, "deadline": {"date": "2026-12-01"},
                                    "description": "Ask about\nthe trip"})
            ),
            ("item_move", &json!({"id": "T1", "project_id": "P2"})),
            (
                "item_update",
                &json!({"id": "T2", "due": null, "deadline": null})
            ),
            ("item_move", &json!({"id": "T2", "section_id": "S1"})),
            ("item_update", &json!({"id": "T3", "content": "three!"})),
            ("item_move", &json!({"id": "T3", "section_id": "S1"})),
            ("item_close", &json!({"id": "T9"})),
        ]
    );
    let uuids: std::collections::BTreeSet<&str> = commands
        .iter()
        .map(|c| c["uuid"].as_str().unwrap())
        .collect();
    assert_eq!(uuids.len(), commands.len(), "a UUID per command");
    assert_eq!(request.field("sync_token").as_deref(), Some("S1"));
    assert_eq!(
        reply["results"],
        json!({"T1": "ok", "T3": "ok", "T9": "ok",
               "T2": {"code": "INVALID_ARGUMENT_VALUE",
                      "error": "Todoist didn't accept the change (%1).\u{1f}Invalid argument value"}}),
        "{reply}"
    );
    // The snapshot has the edit and its deadline.
    let t1 = reply["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == "T1")
        .unwrap();
    assert_eq!(t1["deadline"], "2026-12-01");
    assert_eq!(t1["project_id"], "P2");
    assert!(t1.get("description").is_none(), "descriptions aren't kept");
    let t2 = reply["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["id"] == "T2")
        .unwrap();
    assert_eq!(t2["deadline"], Value::Null);
    let cache = fs::read_to_string(home.cache()).unwrap();
    assert!(
        !cache.contains("Ask about"),
        "the description reached the cache"
    );
}

#[test]
fn an_invalid_update_never_reaches_todoist() {
    let home = synced("update-bad");
    for (input, message) in [
        (
            json!({"commands": [{"op": "update", "id": "T1"}]}),
            "The change has nothing to update.",
        ),
        (
            json!({"commands": [{"op": "update", "id": "T1", "priority": 9}]}),
            "Pick a priority from 1 to 4.",
        ),
        (
            json!({"commands": [{"op": "update", "id": "T1", "section_id": ""}]}),
            "Moving a task out of its section needs the project's id.",
        ),
        (
            json!({"commands": [{"op": "update", "id": "T1", "content": "x"},
                             {"op": "close", "id": "T1"}]}),
            "The same task is changed twice.",
        ),
        (
            // 51 changes are allowed, but each is two Sync commands.
            json!({"commands": (0..51).map(|n| json!({"op": "update", "id": format!("T{n}"),
                "content": "x", "project_id": "P2"})).collect::<Vec<_>>()}),
            "These changes need more than 100 Todoist commands. Send fewer at a time.",
        ),
    ] {
        let (reply, _) = home.run("apply", &input.to_string(), &closed());
        assert_eq!(
            (reply["code"].as_str(), reply["error"].as_str()),
            (Some("INVALID_ARGUMENT"), Some(message)),
            "{input}"
        );
    }
    // The longest single update fits the request limit and goes out.
    let longest = json!({"commands": [{"op": "update", "id": "T1",
        "description": "\u{1F600}".repeat(16_383),
        "labels": (0..50).map(|n| format!("{n:\u{1F600}>60}")).collect::<Vec<_>>()}]});
    let (base, thread) = apply_server(|_| json!("ok"), json!([]));
    let (reply, _) = home.run("apply", &longest.to_string(), &base);
    thread.join().unwrap();
    assert_eq!(reply["results"]["T1"], "ok", "{reply}");
}

#[test]
fn task_reads_one_description_and_writes_nothing() {
    let home = synced("task");
    let before = fs::read(home.cache()).unwrap();
    let mut found = task("T1", "one");
    found["description"] = json!("Line 1\nLine 2");
    let server = Server::start(vec![ok(found.clone())], TOKEN);
    let (reply, _) = home.run("task", r#"{"id":"T1"}"#, &server.base);
    assert_eq!(
        reply,
        json!({"ok": true, "task": {"id": "T1", "description": "Line 1\nLine 2", "truncated": false}})
    );
    let seen = server.seen();
    assert_eq!(
        (seen[0].method.as_str(), seen[0].path.as_str()),
        ("GET", "/tasks/T1")
    );
    assert_eq!(seen[0].authorization, format!("Bearer {TOKEN}"));
    assert_eq!(fs::read(home.cache()).unwrap(), before, "the cache changed");
    // No description, or null: "".
    let server = Server::start(vec![ok(task("T1", "one"))], TOKEN);
    assert_eq!(
        home.run("task", r#"{"id":"T1"}"#, &server.base).0["task"]["description"],
        ""
    );
    // Longer than 16 384 characters: cut, and said so.
    let mut long = task("T1", "one");
    long["description"] = json!("é".repeat(20_000));
    let server = Server::start(vec![ok(long)], TOKEN);
    let (reply, _) = home.run("task", r#"{"id":"T1"}"#, &server.base);
    let text = reply["task"]["description"].as_str().unwrap();
    assert_eq!(text.chars().count(), 16_384);
    assert!(text.ends_with('…'));
    assert_eq!(reply["task"]["truncated"], true);
}

#[test]
fn task_reports_a_missing_oversized_or_wrong_task() {
    let home = synced("task-bad");
    let gone = "That task no longer exists in Todoist.";
    let server = Server::start(vec![status(404, r#"{"error":"Task not found"}"#)], TOKEN);
    let (reply, _) = home.run("task", r#"{"id":"T1"}"#, &server.base);
    assert_eq!(
        (reply["code"].as_str(), reply["error"].as_str()),
        (Some("NOT_FOUND"), Some(gone)),
        "{reply}"
    );
    for flag in ["checked", "is_deleted"] {
        let mut done = task("T1", "one");
        done[flag] = json!(true);
        let server = Server::start(vec![ok(done)], TOKEN);
        let (reply, _) = home.run("task", r#"{"id":"T1"}"#, &server.base);
        assert_eq!(reply["code"], "NOT_FOUND", "{flag}: {reply}");
    }
    // Over 1 MiB: refused while it is read.
    let mut huge = task("T1", "one");
    huge["description"] = json!("x".repeat(1 << 20));
    let server = Server::start(vec![ok(huge)], TOKEN);
    let (reply, _) = home.run("task", r#"{"id":"T1"}"#, &server.base);
    assert_eq!(
        reply["error"], "Todoist sent an oversized reply.",
        "{reply}"
    );
    // Another task, not JSON, or a description that isn't text.
    let mut wrong_type = task("T1", "one");
    wrong_type["description"] = json!(["x"]);
    for body in [task("T2", "two"), json!("nope"), wrong_type] {
        let server = Server::start(vec![ok(body.clone())], TOKEN);
        let (reply, _) = home.run("task", r#"{"id":"T1"}"#, &server.base);
        assert_eq!(
            reply["error"], "Todoist sent an unexpected reply.",
            "{body}: {reply}"
        );
    }
    let server = Server::start(vec![ok(json!({}))], "another-token");
    assert_eq!(
        home.run("task", r#"{"id":"T1"}"#, &server.base).0["code"],
        "INVALID_TOKEN"
    );
    // Invalid ids never reach Todoist.
    for bad in [
        r#"{"id":"../sync"}"#,
        r#"{"id":""}"#,
        r#"{}"#,
        r#"{"id":5}"#,
    ] {
        let (reply, _) = home.run("task", bad, &closed());
        assert_eq!(
            reply["error"], "That isn't a Todoist task id.",
            "{bad}: {reply}"
        );
    }
    // Signed out.
    let (reply, _) = Home::new("task-out").run("task", r#"{"id":"T1"}"#, &closed());
    assert_eq!(reply["code"], "SIGNED_OUT", "{reply}");
}
