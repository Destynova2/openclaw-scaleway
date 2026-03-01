// Tests end-to-end : demarre un vrai upstream mock + token-guard, envoie des requetes HTTP.

use std::net::TcpListener;
use std::time::Duration;
use tokio::process::Command;
use tokio::time::sleep;

/// Binds to port 0 and returns the OS-assigned ephemeral port number.
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Mini serveur upstream qui repond 200 + echo du body.
async fn start_upstream(port: u16) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}"))
            .await
            .unwrap();
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                use tokio::io::{AsyncReadExt, AsyncWriteExt};
                let mut buf = vec![0u8; 4096];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                // Extraire le body apres \r\n\r\n
                let req = String::from_utf8_lossy(&buf[..n]);
                let body = req.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes()).await;
            });
        }
    })
}

/// Handle to a running `token-guard` process, killed on drop via `kill_on_drop`.
struct TokenGuardProcess {
    _child: tokio::process::Child,
    port: u16,
}

impl TokenGuardProcess {
    async fn start(upstream_port: u16, blocked_tokens: &str) -> Self {
        let port = free_port();

        // Build le binaire debug si necessaire
        let build = Command::new("cargo")
            .args(["build"])
            .current_dir(env!("CARGO_MANIFEST_DIR"))
            .output()
            .await
            .expect("cargo build failed");
        assert!(build.status.success(), "cargo build failed: {}", String::from_utf8_lossy(&build.stderr));

        let bin = format!("{}/target/debug/token-guard", env!("CARGO_MANIFEST_DIR"));
        let child = Command::new(&bin)
            .env("UPSTREAM_URL", format!("http://127.0.0.1:{upstream_port}"))
            .env("LISTEN_ADDR", format!("127.0.0.1:{port}"))
            .env("BLOCKED_TOKENS", blocked_tokens)
            .kill_on_drop(true)
            .spawn()
            .expect("failed to start token-guard");

        // Poll for readiness (max 2.5s). If server never starts, test assertions will fail.
        for _ in 0..50 {
            sleep(Duration::from_millis(50)).await;
            if reqwest::get(format!("http://127.0.0.1:{port}/healthz"))
                .await
                .is_ok()
            {
                break;
            }
        }

        Self { _child: child, port }
    }

    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{}", self.port, path)
    }
}

/// Setup commun : upstream mock + token-guard sans blocked_tokens.
async fn setup() -> (tokio::task::JoinHandle<()>, TokenGuardProcess) {
    setup_with_tokens("").await
}

/// Setup commun avec blocked_tokens personnalises.
async fn setup_with_tokens(tokens: &str) -> (tokio::task::JoinHandle<()>, TokenGuardProcess) {
    let up_port = free_port();
    let upstream = start_upstream(up_port).await;
    let guard = TokenGuardProcess::start(up_port, tokens).await;
    (upstream, guard)
}

// --- Tests E2E ---

#[tokio::test]
async fn e2e_healthz() {
    let (_upstream, guard) = setup().await;

    let resp = reqwest::get(guard.url("/healthz")).await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.text().await.unwrap(), "ok");
}

#[tokio::test]
async fn e2e_clean_prompt_forwarded() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"Bonjour"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
    let body = resp.text().await.unwrap();
    assert!(body.contains("Bonjour"), "upstream should echo body back");
}

#[tokio::test]
async fn e2e_blocks_github_pat() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"my token github_pat_11ABCDE2Y0abcdefghijklmnopqrstuvwx"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 403);
    let body = resp.text().await.unwrap();
    assert!(body.contains("token_guard"));
}

#[tokio::test]
async fn e2e_blocks_visa() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"paye avec 4111111111111111"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 403);
}

#[tokio::test]
async fn e2e_blocks_iban() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"virement FR7630006000011234567890189"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 403);
}

#[tokio::test]
async fn e2e_blocks_eth_wallet() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"send 1 ETH to 0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 403);
}

#[tokio::test]
async fn e2e_blocks_exact_token() {
    let (_upstream, guard) = setup_with_tokens("my-secret-uuid-1234-abcd-5678").await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"key is my-secret-uuid-1234-abcd-5678"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 403);
}

#[tokio::test]
async fn e2e_allows_email() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"contacte admin@example.com"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
}

#[tokio::test]
async fn e2e_blocks_btc_wallet() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/chat/completions"))
        .body(r#"{"messages":[{"role":"user","content":"pay bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"}]}"#)
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 403);
}

#[tokio::test]
async fn e2e_multiple_clean_requests() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    for msg in ["Hello", "Comment ca va?", "Explique le pattern observer"] {
        let resp = client
            .post(guard.url("/v1/chat/completions"))
            .body(format!(r#"{{"messages":[{{"role":"user","content":"{msg}"}}]}}"#))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 200, "clean prompt '{msg}' should pass");
    }
}

#[tokio::test]
async fn e2e_path_preserved() {
    let (_upstream, guard) = setup().await;

    let client = reqwest::Client::new();
    let resp = client
        .post(guard.url("/v1/models"))
        .body("{}")
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), 200);
}
