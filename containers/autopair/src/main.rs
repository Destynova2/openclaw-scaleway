use inotify::{Inotify, WatchMask};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use std::{thread, time::Duration};

const DEVICES_DIR: &str = "/config/devices";
const PENDING_FILE: &str = "/config/devices/pending.json";
const PAIRED_FILE: &str = "/config/devices/paired.json";
const CLIENT_ID: &str = "cli";
const INOTIFY_BUF_SIZE: usize = 1024;
const DIR_POLL_INTERVAL: Duration = Duration::from_secs(2);
const WRITE_DEBOUNCE: Duration = Duration::from_millis(200);
const ERROR_BACKOFF: Duration = Duration::from_secs(5);

type Devices = HashMap<String, DeviceEntry>;

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DeviceEntry {
    client_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    approved_at_ms: Option<u64>,
    /// Captures unknown JSON fields for forward-compatibility with future schema changes.
    #[serde(flatten)]
    extra: HashMap<String, serde_json::Value>,
}

impl DeviceEntry {
    fn is_cli(&self) -> bool {
        self.client_id.as_deref() == Some(CLIENT_ID)
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn load_json<T: serde::de::DeserializeOwned>(path: impl AsRef<Path>) -> Option<T> {
    let path = path.as_ref();
    let data = fs::read_to_string(path).ok()?;
    match serde_json::from_str(&data) {
        Ok(v) => Some(v),
        Err(e) => {
            eprintln!("autopair: failed to parse {}: {e}", path.display());
            None
        }
    }
}

/// Writes content to path atomically via a tmp file + rename to prevent partial reads.
fn write_atomic(path: impl AsRef<Path>, content: &str) -> std::io::Result<()> {
    let path = path.as_ref();
    let mut tmp_os = path.as_os_str().to_os_string();
    tmp_os.push(".tmp");
    let tmp = PathBuf::from(tmp_os);
    if let Err(e) = fs::write(&tmp, content).and_then(|_| fs::rename(&tmp, path)) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

fn has_cli_entry(devices: &Devices) -> bool {
    devices.values().any(DeviceEntry::is_cli)
}

fn approve_cli(pending: &mut Devices, paired: &mut Devices) -> Option<String> {
    let key = pending
        .iter()
        .find(|(_, entry)| entry.is_cli())
        .map(|(k, _)| k.clone())?;

    let mut entry = pending.remove(&key).expect("key was found via find()");
    entry.approved_at_ms = Some(now_ms());
    paired.insert(key.clone(), entry);
    Some(key)
}

fn try_approve(pending_path: &Path, paired_path: &Path) {
    // Already paired — nothing to do
    if load_json::<Devices>(paired_path).is_some_and(|p| has_cli_entry(&p)) {
        return;
    }

    let Some(mut pending) = load_json::<Devices>(pending_path) else {
        return;
    };
    let mut paired: Devices = load_json(paired_path).unwrap_or_default();

    let Some(key) = approve_cli(&mut pending, &mut paired) else {
        eprintln!("autopair: no pending CLI entry found");
        return;
    };

    let paired_json =
        serde_json::to_string_pretty(&paired).expect("Devices serialization is infallible");
    let pending_json =
        serde_json::to_string_pretty(&pending).expect("Devices serialization is infallible");

    // Write paired first — worst case the entry stays in both files
    // and gets deduplicated on next run (idempotent).
    if let Err(e) = write_atomic(paired_path, &paired_json) {
        eprintln!("autopair: failed to write paired.json: {e}");
        return;
    }
    if let Err(e) = write_atomic(pending_path, &pending_json) {
        eprintln!("autopair: failed to write pending.json: {e}");
        return;
    }

    eprintln!("autopair: CLI paired (deviceId={key})");
}

fn is_pending_json_event(event: &inotify::Event<&OsStr>) -> bool {
    event
        .name
        .and_then(|os_name| os_name.to_str())
        .is_some_and(|name| name == "pending.json")
}

fn wait_for_directory(path: &str) {
    while !Path::new(path).exists() {
        thread::sleep(DIR_POLL_INTERVAL);
    }
}

fn run_event_loop(mut inotify: Inotify) {
    let pending = Path::new(PENDING_FILE);
    let paired = Path::new(PAIRED_FILE);
    let mut buffer = [0; INOTIFY_BUF_SIZE];

    loop {
        match inotify.read_events_blocking(&mut buffer) {
            Ok(events) => {
                if events.into_iter().any(|e| is_pending_json_event(&e)) {
                    thread::sleep(WRITE_DEBOUNCE);
                    try_approve(pending, paired);
                }
            }
            Err(e) => {
                eprintln!("autopair: inotify error: {e}");
                thread::sleep(ERROR_BACKOFF);
            }
        }
    }
}

fn main() {
    eprintln!("autopair: watching {DEVICES_DIR} for pending CLI connections");

    wait_for_directory(DEVICES_DIR);

    // Check on startup (in case pending.json already exists)
    try_approve(Path::new(PENDING_FILE), Path::new(PAIRED_FILE));

    let inotify = Inotify::init().expect("failed to init inotify");

    inotify
        .watches()
        .add(
            DEVICES_DIR,
            WatchMask::CREATE | WatchMask::MODIFY | WatchMask::MOVED_TO,
        )
        .expect("failed to watch devices dir");

    run_event_loop(inotify);
}

#[cfg(test)]
mod tests {
    use super::*;

    const FAKE_TIMESTAMP: u64 = 1000;

    fn make_entry(client_id: &str, approved: bool) -> DeviceEntry {
        DeviceEntry {
            client_id: Some(client_id.to_string()),
            approved_at_ms: if approved { Some(FAKE_TIMESTAMP) } else { None },
            extra: HashMap::new(),
        }
    }

    #[test]
    fn has_cli_entry_returns_true_when_cli_present() {
        let mut devices = Devices::new();
        devices.insert("dev1".into(), make_entry("cli", false));
        assert!(has_cli_entry(&devices));
    }

    #[test]
    fn has_cli_entry_returns_false_when_empty() {
        assert!(!has_cli_entry(&Devices::new()));
    }

    #[test]
    fn has_cli_entry_returns_false_for_other_clients() {
        let mut devices = Devices::new();
        devices.insert("dev1".into(), make_entry("web", true));
        assert!(!has_cli_entry(&devices));
    }

    #[test]
    fn approve_cli_moves_entry_from_pending_to_paired() {
        let mut pending = Devices::new();
        pending.insert("dev-abc".into(), make_entry("cli", false));

        let mut paired = Devices::new();
        let key = approve_cli(&mut pending, &mut paired);

        assert_eq!(key, Some("dev-abc".into()));
        assert!(pending.is_empty());
        assert!(paired.contains_key("dev-abc"));
        assert!(paired["dev-abc"].approved_at_ms.is_some());
    }

    #[test]
    fn approve_cli_returns_none_when_no_cli_entry() {
        let mut pending = Devices::new();
        pending.insert("dev1".into(), make_entry("web", false));
        let mut paired = Devices::new();

        assert_eq!(approve_cli(&mut pending, &mut paired), None);
        assert_eq!(pending.len(), 1);
    }

    #[test]
    fn approve_cli_leaves_other_entries_in_pending() {
        let mut pending = Devices::new();
        pending.insert("dev-cli".into(), make_entry("cli", false));
        pending.insert("dev-web".into(), make_entry("web", false));

        let mut paired = Devices::new();
        approve_cli(&mut pending, &mut paired);

        assert_eq!(pending.len(), 1);
        assert!(pending.contains_key("dev-web"));
        assert_eq!(paired.len(), 1);
        assert!(paired.contains_key("dev-cli"));
    }

    #[test]
    fn approve_cli_preserves_existing_paired_entries() {
        let mut pending = Devices::new();
        pending.insert("dev-cli".into(), make_entry("cli", false));

        let mut paired = Devices::new();
        paired.insert("dev-old".into(), make_entry("web", true));

        approve_cli(&mut pending, &mut paired);

        assert_eq!(paired.len(), 2);
        assert!(paired.contains_key("dev-old"));
        assert!(paired.contains_key("dev-cli"));
    }

    #[test]
    fn approve_cli_sets_approved_at_ms() {
        let mut pending = Devices::new();
        pending.insert("dev1".into(), make_entry("cli", false));
        let mut paired = Devices::new();

        approve_cli(&mut pending, &mut paired);

        let ts = paired["dev1"].approved_at_ms.unwrap();
        assert!(ts > 0);
    }

    mod io {
        use super::*;

        #[test]
        fn load_json_returns_none_for_nonexistent_file() {
            let result: Option<Devices> = load_json("/tmp/autopair-test-does-not-exist.json");
            assert!(result.is_none());
        }

        #[test]
        fn load_json_returns_none_for_invalid_json() {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("bad.json");
            fs::write(&path, "not valid json {{{").unwrap();

            let result: Option<Devices> = load_json(&path);
            assert!(result.is_none());
        }

        #[test]
        fn load_json_parses_valid_file() {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("good.json");
            let mut devices = Devices::new();
            devices.insert("dev1".into(), make_entry("cli", false));
            fs::write(&path, serde_json::to_string(&devices).unwrap()).unwrap();

            let result: Option<Devices> = load_json(&path);
            assert!(result.is_some());
            assert!(has_cli_entry(&result.unwrap()));
        }

        #[test]
        fn write_atomic_writes_content_and_cleans_tmp() {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("output.json");

            write_atomic(&path, r#"{"hello":"world"}"#).unwrap();

            assert_eq!(fs::read_to_string(&path).unwrap(), r#"{"hello":"world"}"#);
            assert!(!dir.path().join("output.json.tmp").exists());
        }

        #[test]
        fn write_atomic_fails_on_invalid_path() {
            let result = write_atomic("/nonexistent/dir/file.json", "data");
            assert!(result.is_err());
        }
    }

    mod roundtrip {
        use super::*;

        #[test]
        fn extra_fields_preserved_through_approve_cycle() {
            let json = r#"{
                "dev-cli": {
                    "clientId": "cli",
                    "futureField": 42,
                    "nested": {"deep": true}
                }
            }"#;

            let mut pending: Devices = serde_json::from_str(json).unwrap();
            let mut paired = Devices::new();

            approve_cli(&mut pending, &mut paired);

            let output = serde_json::to_string(&paired["dev-cli"]).unwrap();
            assert!(output.contains("\"futureField\":42"));
            assert!(output.contains("\"deep\":true"));
            assert!(output.contains("\"approvedAtMs\":"));
        }

        #[test]
        fn full_flow_pending_to_paired_on_disk() {
            let dir = tempfile::tempdir().unwrap();
            let pending_path = dir.path().join("pending.json");
            let paired_path = dir.path().join("paired.json");

            // Write a pending file with a CLI entry
            let mut pending = Devices::new();
            pending.insert("dev-test".into(), make_entry("cli", false));
            fs::write(&pending_path, serde_json::to_string(&pending).unwrap()).unwrap();

            // Call the real function with temp paths
            try_approve(&pending_path, &paired_path);

            // Verify on-disk state
            let final_paired: Devices = load_json(&paired_path).unwrap();
            let final_pending: Devices = load_json(&pending_path).unwrap();

            assert!(has_cli_entry(&final_paired));
            assert!(final_pending.is_empty());
        }

        #[test]
        fn try_approve_skips_when_already_paired() {
            let dir = tempfile::tempdir().unwrap();
            let pending_path = dir.path().join("pending.json");
            let paired_path = dir.path().join("paired.json");

            // Pre-existing paired CLI entry
            let mut paired = Devices::new();
            paired.insert("dev-old".into(), make_entry("cli", true));
            fs::write(&paired_path, serde_json::to_string(&paired).unwrap()).unwrap();

            // A new pending entry that should NOT be approved
            let mut pending = Devices::new();
            pending.insert("dev-new".into(), make_entry("cli", false));
            fs::write(&pending_path, serde_json::to_string(&pending).unwrap()).unwrap();

            try_approve(&pending_path, &paired_path);

            // Pending should be unchanged (skipped because already paired)
            let final_pending: Devices = load_json(&pending_path).unwrap();
            assert_eq!(final_pending.len(), 1);
            assert!(final_pending.contains_key("dev-new"));
        }
    }
}
