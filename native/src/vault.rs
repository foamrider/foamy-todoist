//! Where the API token lives: the Secret Service keyring through
//! `secret-tool` (libsecret), one item with the attributes `service
//! foamy-todoist account personal-token`. The token reaches secret-tool on
//! standard input only, never in its argv. Nothing else on disk.
//!
//! `secret-tool lookup` and `clear` exit 1 without a word both when no item
//! matches and when the item is in a locked keyring: `lookup` asks to unlock
//! it and gives up when the prompt is dismissed or can't be shown, and
//! `clear` only removes unlocked items, never asking. So after either one,
//! `search` (without `--unlock`, which never prompts) says whether an item
//! is still there: one that is, locked, is `KEYRING_LOCKED`, never "signed
//! out" or "removed" (foamy-zendesk's logic, checked against a real
//! gnome-keyring there).

use std::ffi::OsString;
use std::io::ErrorKind;
use std::time::Duration;

use foamy_helper::Failure;
use foamy_helper::child::{Bounded, Output};

const ATTRIBUTES: [&str; 4] = ["service", "foamy-todoist", "account", "personal-token"];
/// secret-tool may wait for a keyring unlock prompt; the run budget caps it too.
const TIMEOUT: Duration = Duration::from_secs(20);
const MAX_OUTPUT: usize = 16 * 1024;

pub fn unavailable(detail: &str) -> Failure {
    let detail = detail.lines().next().unwrap_or("").trim();
    Failure::coded(
        "KEYRING_UNAVAILABLE",
        if detail.is_empty() {
            "No keyring is available to store the Todoist token.".to_string()
        } else {
            crate::text::message(
                "No keyring is available to store the Todoist token (%1).",
                &[&crate::text::short(detail, 120)],
            )
        },
    )
}

/// The item is there but can't be read or removed: its keyring is locked.
pub fn locked() -> Failure {
    Failure::coded(
        "KEYRING_LOCKED",
        "The keyring that holds the Todoist token is locked. Unlock it and try again.",
    )
}

/// `secret-tool {lookup|store|clear|search} service foamy-todoist account personal-token`.
pub struct SecretTool {
    program: OsString,
}

impl SecretTool {
    pub fn new() -> SecretTool {
        SecretTool {
            program: "secret-tool".into(),
        }
    }

    #[cfg(test)]
    pub fn at(program: impl Into<OsString>) -> SecretTool {
        SecretTool {
            program: program.into(),
        }
    }

    fn command(&self, verb: &str) -> Bounded {
        let mut command = Bounded::new(&self.program).arg(verb);
        if verb == "store" {
            command = command.arg("--label=Foamy Todoist API token");
        }
        command
            .args(ATTRIBUTES)
            .keep_env(&[
                "PATH",
                "HOME",
                "XDG_RUNTIME_DIR",
                "DBUS_SESSION_BUS_ADDRESS",
                "DISPLAY",
                "WAYLAND_DISPLAY",
            ])
            .timeout(TIMEOUT)
            .max_output(MAX_OUTPUT)
    }

    fn run(command: Bounded) -> Result<Output, Failure> {
        match command.run() {
            Ok(output) if output.timed_out => Err(unavailable("the keyring didn't answer")),
            Ok(output) => Ok(output),
            Err(error) if error.kind() == ErrorKind::NotFound => {
                Err(unavailable("secret-tool isn't installed"))
            }
            Err(error) => Err(unavailable(&error.to_string())),
        }
    }

    /// Whether the keyring still holds a matching item, locked or not.
    /// `search` lists each one (`[/<id>]`, its label and dates, and the
    /// secret of an unlocked one) on stdout, and complains on stderr about
    /// a locked one's secret but still exits 0; no item: no output.
    fn exists(&self) -> Result<bool, Failure> {
        let output = SecretTool::run(self.command("search"))?;
        if !output.success() {
            return Err(failed(&output));
        }
        Ok(!output.stdout.iter().all(u8::is_ascii_whitespace))
    }

    /// The stored token, `None` only when no item matches.
    pub fn get(&self) -> Result<Option<String>, Failure> {
        let output = SecretTool::run(self.command("lookup"))?;
        if output.success() {
            return Ok(Some(output.stdout_lossy().trim().to_string()));
        }
        // A missing or broken keyring says why.
        if !silent_miss(&output) {
            return Err(failed(&output));
        }
        if self.exists()? {
            Err(locked())
        } else {
            Ok(None)
        }
    }

    pub fn put(&self, secret: &str) -> Result<(), Failure> {
        let output = SecretTool::run(self.command("store").stdin(secret.as_bytes().to_vec()))?;
        if output.success() {
            Ok(())
        } else {
            Err(failed(&output))
        }
    }

    /// `Ok` only when no item is left.
    pub fn delete(&self) -> Result<(), Failure> {
        let output = SecretTool::run(self.command("clear"))?;
        if !output.success() && !silent_miss(&output) {
            return Err(failed(&output));
        }
        // Removed, or nothing it could remove: either way, what is left?
        if self.exists()? {
            Err(locked())
        } else {
            Ok(())
        }
    }
}

/// Exited 1 on its own and said nothing: "no such item", or a locked one.
fn silent_miss(output: &Output) -> bool {
    output.status.code() == Some(1)
        && !output.overflowed
        && output.stderr.iter().all(u8::is_ascii_whitespace)
}

/// Any other failure: what it said, else how it ended.
fn failed(output: &Output) -> Failure {
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stderr.trim().is_empty() {
        unavailable(&stderr)
    } else if output.overflowed {
        unavailable("secret-tool's answer was too long")
    } else {
        unavailable(&format!("secret-tool ended with {}", output.status))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    /// `tests/fake-secret-tool.sh` in a directory of its own, which holds
    /// its state (the item, whether it is locked, its log).
    fn fake(tag: &str) -> (PathBuf, SecretTool) {
        let dir =
            std::env::temp_dir().join(format!("foamy-todoist-vault-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("secret-tool");
        std::fs::write(&script, include_str!("../tests/fake-secret-tool.sh")).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        (dir, SecretTool::at(script))
    }

    fn set(dir: &Path, item: bool, locked: bool) {
        let _ = std::fs::remove_file(dir.join("item"));
        let _ = std::fs::remove_file(dir.join("locked"));
        if item {
            std::fs::write(dir.join("item"), "T0KEN").unwrap();
        }
        if locked {
            std::fs::write(dir.join("locked"), "").unwrap();
        }
    }

    #[test]
    fn a_locked_item_is_neither_absent_nor_removed() {
        let (dir, tool) = fake("cases");
        // (case, item, locked, get, delete, item left after delete)
        let cases = [
            ("unlocked with the item", true, false, "some", "ok", false),
            ("unlocked without it", false, false, "none", "ok", false),
            (
                "locked with the item",
                true,
                true,
                "KEYRING_LOCKED",
                "KEYRING_LOCKED",
                true,
            ),
            ("locked without it", false, true, "none", "ok", false),
        ];
        for (case, item, locked, get, delete, left) in cases {
            set(&dir, item, locked);
            let got = match tool.get() {
                Ok(Some(secret)) => {
                    assert_eq!(secret, "T0KEN", "{case}");
                    "some".to_string()
                }
                Ok(None) => "none".into(),
                Err(failure) => failure.code,
            };
            assert_eq!(got, get, "get, {case}");
            let deleted = match tool.delete() {
                Ok(()) => "ok".to_string(),
                Err(failure) => failure.code,
            };
            assert_eq!(deleted, delete, "delete, {case}");
            assert_eq!(
                dir.join("item").exists(),
                left,
                "the item after delete, {case}"
            );
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn store_sends_the_secret_on_stdin_only() {
        let (dir, tool) = fake("store");
        set(&dir, false, false);
        tool.put("S3CRET").unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("item")).unwrap(), "S3CRET");
        let log = std::fs::read_to_string(dir.join("log")).unwrap();
        assert!(log.starts_with("store "), "{log}");
        assert!(!log.contains("S3CRET"), "the secret reached argv: {log}");
        // A locked collection refuses the item, and says so.
        set(&dir, false, true);
        assert_eq!(tool.put("S3CRET").unwrap_err().code, "KEYRING_UNAVAILABLE");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_silent_miss_is_checked_and_any_other_failure_is_an_error() {
        let (dir, tool) = fake("failures");
        set(&dir, false, false);
        std::fs::write(dir.join("search-fails"), "").unwrap();
        // Not found, but whether it is there can't be told: an error, not "absent".
        assert_eq!(tool.get().unwrap_err().code, "KEYRING_UNAVAILABLE");
        assert_eq!(tool.delete().unwrap_err().code, "KEYRING_UNAVAILABLE");
        std::fs::remove_file(dir.join("search-fails")).unwrap();
        std::fs::write(dir.join("lookup-dies"), "").unwrap();
        let failure = tool.get().unwrap_err();
        assert_eq!(failure.code, "KEYRING_UNAVAILABLE");
        assert!(failure.message.contains("signal"), "{}", failure.message);
        // Not installed: the keyring can't be used, which is not "signed out".
        let failure = SecretTool::at(dir.join("absent")).get().unwrap_err();
        assert_eq!(
            (failure.code.as_str(), failure.message.as_str()),
            (
                "KEYRING_UNAVAILABLE",
                "No keyring is available to store the Todoist token (%1).\u{1f}secret-tool isn't installed"
            )
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
