//! DLP reverse proxy for OpenClaw LLM API calls.
//!
//! Scans outgoing prompts for leaked secrets (API keys, PEM keys, credit cards,
//! IBAN, crypto wallets) and blocks them before they reach the upstream LLM API.
//! ~3 MB RAM, <1 ms overhead, zero-copy response streaming (SSE).
//!
//! Built via `containers/Containerfile.token-guard`, configured in
//! `terraform/instance.tf` (kube.yml template).

use axum::{body::Body, extract::State, response::Response, Router};
use http::StatusCode;
use http_body_util::BodyExt;
use regex::RegexSet;
use std::sync::Arc;
use tokio::net::TcpListener;

/// Shared application state holding the upstream URL, secret patterns, and alert configuration.
struct AppState {
    /// HTTP client reused across all proxy requests.
    client: reqwest::Client,
    /// Compiled regex set from [`TOKEN_PATTERNS`], matching known secret formats.
    patterns: RegexSet,
    /// Exact strings to block (e.g., Scaleway secret keys with no regex pattern). Min length 8.
    exact_tokens: Vec<String>,
    /// Base URL of the upstream LLM API (no trailing slash).
    upstream: String,
    /// Pre-built Telegram sendMessage URL, `None` if alerting is disabled.
    telegram_url: Option<String>,
    /// Telegram chat ID for alert messages.
    telegram_chat_id: Option<String>,
}

/// Regex patterns matching secrets that must never appear in an LLM prompt.
///
/// Covers cloud providers (AWS, Scaleway, Google, DigitalOcean), VCS tokens
/// (GitHub, GitLab), SaaS API keys (OpenAI, Stripe, Slack, Telegram, Vault),
/// PEM private keys, credit cards (Visa, Mastercard, Amex, Discover, JCB),
/// IBAN, and crypto wallets (ETH, BTC, XMR).
///
/// Email patterns are intentionally excluded due to high false positive rates
/// in system prompts and normal discussion content.
const TOKEN_PATTERNS: &[&str] = &[
    // Cloud providers
    r"AKIA[A-Z0-9]{16}",                  // AWS access key
    r"SCW[A-Z0-9]{17,}",                  // Scaleway access key
    r"AIZA[A-Za-z0-9_-]{35}",            // Google API key
    r"GOCSPX-[A-Za-z0-9_-]{20,}",        // Google OAuth client secret
    r"dop_v1_[a-f0-9]{64}",              // DigitalOcean PAT
    // VCS
    r"github_pat_[A-Za-z0-9_]{30,}",     // GitHub fine-grained PAT
    r"gh[pos]_[A-Za-z0-9]{36,}",         // GitHub classic/OAuth token
    r"glpat-[A-Za-z0-9_-]{20,}",         // GitLab PAT
    // SaaS / API keys
    r"sk-[A-Za-z0-9]{20,}",              // OpenAI / Anthropic / Stripe secret key
    r"BSA[A-Za-z0-9]{20,}",              // Brave Search API key
    r"xox[bporas]-[A-Za-z0-9-]{10,}",    // Slack token
    r"\d{8,10}:[A-Za-z0-9_-]{35}",       // Telegram bot token
    r"hvs\.[A-Za-z0-9]{25,}",            // HashiCorp Vault token
    // Crypto
    r"-----BEGIN[A-Z ]*PRIVATE KEY-----", // PEM private key
    // Cartes bancaires (Visa, Mastercard, Amex, Discover, JCB)
    r"\b4[0-9]{12}(?:[0-9]{3})?\b",                           // Visa
    r"\b5[1-5][0-9]{14}\b",                                    // Mastercard
    r"\b3[47][0-9]{13}\b",                                     // Amex
    r"\b6(?:011|5[0-9]{2})[0-9]{12}\b",                       // Discover
    r"\b(?:2131|1800|35[0-9]{3})[0-9]{11}\b",                 // JCB
    // Bancaire (IBAN seulement — SWIFT/BIC et SEPA trop larges, matchent des mots courants)
    r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b",                     // IBAN
    // Crypto wallets
    r"\b0x[a-fA-F0-9]{40}\b",                                 // Ethereum (ETH)
    r"\b(?:bc1|[13])[a-zA-HJ-NP-Z0-9]{25,39}\b",            // Bitcoin (BTC)
    r"\b4[0-9AB][1-9A-HJ-NP-Za-km-z]{93}\b",                // Monero (XMR)
];

/// Scans the request body for leaked secrets and either forwards to the upstream or returns 403.
///
/// Requests to `/healthz` bypass scanning and return 200 immediately.
///
/// # Errors
/// - 400: request body could not be read
/// - 403: a secret pattern or exact token was detected in the body
/// - 502: the upstream request failed
///
/// Non-UTF8 bytes are replaced with U+FFFD before scanning (lossy conversion).
async fn proxy(
    State(state): State<Arc<AppState>>,
    req: http::Request<Body>,
) -> Response<Body> {
    if req.uri().path() == "/healthz" {
        return Response::builder()
            .status(StatusCode::OK)
            .body(Body::from("ok"))
            .expect("static response is valid");
    }

    let (parts, body) = req.into_parts();

    // Prompts are < 1 MB — safe to buffer fully for scanning.
    let body_bytes = match body.collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(e) => {
            eprintln!("[ERROR] read body: {e}");
            return error_response(StatusCode::BAD_REQUEST, "failed to read body");
        }
    };

    let body_str = String::from_utf8_lossy(&body_bytes);
    let regex_hit = state.patterns.is_match(&body_str);
    let exact_hit = state.exact_tokens.iter().any(|t| body_str.contains(t.as_str()));
    if regex_hit || exact_hit {
        eprintln!("[BLOCK] token detected -> {}", parts.uri);
        alert_telegram(&state);
        return error_response(
            StatusCode::FORBIDDEN,
            "blocked: sensitive token detected in request body",
        );
    }

    // Stream the response for SSE compatibility (no buffering).
    let path = parts
        .uri
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");
    let url = format!("{}{}", state.upstream, path);

    let mut fwd = state.client.request(parts.method, &url);
    for (name, value) in &parts.headers {
        if name != "host" {
            fwd = fwd.header(name, value);
        }
    }

    match fwd.body(body_bytes).send().await {
        Ok(resp) => {
            let mut builder = Response::builder().status(resp.status());
            for (k, v) in resp.headers() {
                builder = builder.header(k, v);
            }
            builder
                .body(Body::from_stream(resp.bytes_stream()))
                .expect("upstream response headers are valid")
        }
        Err(e) => {
            eprintln!("[ERROR] upstream: {e}");
            error_response(StatusCode::BAD_GATEWAY, &e.to_string())
        }
    }
}

/// Builds a JSON response in OpenAI API error format.
fn error_response(status: StatusCode, msg: &str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"error":{{"message":"{}","type":"token_guard"}}}}"#,
            msg.replace('"', "\\\"")
        )))
        .expect("static error response is valid")
}

/// Sends a non-blocking Telegram alert when a secret is detected.
///
/// Failures are logged to stderr but swallowed to avoid blocking the proxy response.
fn alert_telegram(state: &AppState) {
    if let (Some(url), Some(chat_id)) = (&state.telegram_url, &state.telegram_chat_id) {
        let client = state.client.clone();
        let url = url.clone();
        let chat_id = chat_id.clone();
        tokio::spawn(async move {
            if let Err(e) = client
                .post(&url)
                .json(&serde_json::json!({
                    "chat_id": chat_id,
                    "text": "\u{1f6a8} token-guard: secret bloque dans un prompt LLM"
                }))
                .send()
                .await
            {
                eprintln!("[WARN] telegram alert failed: {e}");
            }
        });
    }
}

/// Starts the token-guard DLP reverse proxy.
///
/// # Panics
///
/// Panics if `UPSTREAM_URL` is not set or if the regex patterns fail to compile.
///
/// # Environment
///
/// - `UPSTREAM_URL` (required): Base URL of the upstream LLM API.
/// - `LISTEN_ADDR` (optional): Bind address (default `127.0.0.1:8081`).
/// - `BLOCKED_TOKENS` (optional): Comma-separated exact strings to block.
/// - `TELEGRAM_BOT_TOKEN` (optional): Enables Telegram alerts on block events.
/// - `TELEGRAM_CHAT_ID` (optional): Telegram chat for alerts.
#[tokio::main]
async fn main() {
    let upstream = std::env::var("UPSTREAM_URL").expect("UPSTREAM_URL required");
    let addr = std::env::var("LISTEN_ADDR").unwrap_or_else(|_| "127.0.0.1:8081".into());
    let tg_token = std::env::var("TELEGRAM_BOT_TOKEN").ok();

    // Tokens exacts a bloquer (secrets sans pattern identifiable, ex: UUID Scaleway secret key)
    // Comma-separated dans BLOCKED_TOKENS env var.
    let exact_tokens: Vec<String> = std::env::var("BLOCKED_TOKENS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| s.len() >= 8) // Skip short tokens to avoid false positives
        .collect();
    eprintln!("[token-guard] {} regex patterns + {} exact tokens", TOKEN_PATTERNS.len(), exact_tokens.len());

    let state = Arc::new(AppState {
        client: reqwest::Client::new(),
        patterns: RegexSet::new(TOKEN_PATTERNS).expect("invalid regex"),
        exact_tokens,
        upstream: upstream.clone(),
        telegram_url: tg_token
            .map(|t| format!("https://api.telegram.org/bot{t}/sendMessage")),
        telegram_chat_id: std::env::var("TELEGRAM_CHAT_ID").ok(),
    });

    let app = Router::new().fallback(proxy).with_state(state);
    let listener = TcpListener::bind(&addr).await.expect("bind failed");
    eprintln!("[token-guard] {addr} -> {upstream}");
    axum::serve(listener, app).await.expect("server failed");
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http::Request;
    use tower::util::ServiceExt;

    /// Creates an [`AppState`] with the given exact tokens and an unreachable upstream.
    fn test_state(exact: Vec<&str>) -> Arc<AppState> {
        Arc::new(AppState {
            client: reqwest::Client::new(),
            patterns: RegexSet::new(TOKEN_PATTERNS).expect("invalid regex"),
            exact_tokens: exact.into_iter().map(String::from).collect(),
            upstream: "http://127.0.0.1:1".into(),
            telegram_url: None,
            telegram_chat_id: None,
        })
    }

    /// Builds a test router with the given exact tokens.
    fn app(exact: Vec<&str>) -> Router {
        Router::new().fallback(proxy).with_state(test_state(exact))
    }

    /// Sends a POST to `/v1/chat/completions` and returns the HTTP status code.
    async fn post(app: &Router, body: &str) -> u16 {
        let req = Request::post("/v1/chat/completions")
            .body(Body::from(body.to_string()))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        resp.status().as_u16()
    }

    // --- Regex pattern tests ---

    #[tokio::test]
    async fn blocks_aws_key() {
        assert_eq!(post(&app(vec![]), "key is AKIAIOSFODNN7EXAMPLE").await, 403);
    }

    #[tokio::test]
    async fn blocks_scaleway_access_key() {
        assert_eq!(post(&app(vec![]), "scw SCWABCDEFGHIJKLMNOPQR").await, 403);
    }

    #[tokio::test]
    async fn blocks_github_pat() {
        assert_eq!(post(&app(vec![]), "github_pat_11ABCDE2Y0abcdefghijklmnopqrstuvwx").await, 403);
    }

    #[tokio::test]
    async fn blocks_github_classic() {
        assert_eq!(post(&app(vec![]), "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij").await, 403);
    }

    #[tokio::test]
    async fn blocks_openai_key() {
        assert_eq!(post(&app(vec![]), "sk-proj1234567890abcdefghij").await, 403);
    }

    #[tokio::test]
    async fn blocks_brave_key() {
        assert_eq!(post(&app(vec![]), "BSAabcdefghijklmnopqrstuvwxyz").await, 403);
    }

    #[tokio::test]
    async fn blocks_google_oauth_secret() {
        assert_eq!(post(&app(vec![]), "GOCSPX-abcdefghijklmnopqrstuvw").await, 403);
    }

    #[tokio::test]
    async fn blocks_telegram_bot() {
        assert_eq!(post(&app(vec![]), "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi").await, 403);
    }

    #[tokio::test]
    async fn blocks_slack_token() {
        assert_eq!(post(&app(vec![]), "xoxb-1234567890-1234567890-abcdef").await, 403);
    }

    #[tokio::test]
    async fn blocks_gitlab_pat() {
        assert_eq!(post(&app(vec![]), "glpat-ABCDEFGHIJKLMNOPQRSTu").await, 403);
    }

    #[tokio::test]
    async fn blocks_pem_key() {
        assert_eq!(post(&app(vec![]), "-----BEGIN RSA PRIVATE KEY-----").await, 403);
    }

    #[tokio::test]
    async fn blocks_pem_ed25519() {
        assert_eq!(post(&app(vec![]), "-----BEGIN PRIVATE KEY-----").await, 403);
    }

    // --- Cartes bancaires ---

    #[tokio::test]
    async fn blocks_visa() {
        assert_eq!(post(&app(vec![]), "card: 4111111111111111 thanks").await, 403);
    }

    #[tokio::test]
    async fn blocks_mastercard() {
        assert_eq!(post(&app(vec![]), "mc 5500000000000004 end").await, 403);
    }

    #[tokio::test]
    async fn blocks_amex() {
        assert_eq!(post(&app(vec![]), "amex 378282246310005 ok").await, 403);
    }

    // --- Bancaire ---

    #[tokio::test]
    async fn blocks_iban() {
        assert_eq!(post(&app(vec![]), "virement FR7630006000011234567890189").await, 403);
    }

    #[tokio::test]
    async fn blocks_iban_de() {
        assert_eq!(post(&app(vec![]), "IBAN DE89370400440532013000").await, 403);
    }

    // --- Patterns retires (doivent passer) ---

    #[tokio::test]
    async fn allows_email_in_prompt() {
        let status = post(&app(vec![]), "contact admin@example.com for help").await;
        assert_ne!(status, 403);
    }

    #[tokio::test]
    async fn allows_uppercase_words() {
        // SWIFT/BIC pattern retiré — ne doit plus bloquer les mots majuscules
        let status = post(&app(vec![]), "REQUIRED FUNCTION RESPONSE").await;
        assert_ne!(status, 403);
    }

    // --- Crypto wallets ---

    #[tokio::test]
    async fn blocks_eth_address() {
        assert_eq!(post(&app(vec![]), "send to 0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18").await, 403);
    }

    #[tokio::test]
    async fn blocks_btc_address() {
        assert_eq!(post(&app(vec![]), "btc bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq").await, 403);
    }

    // --- Exact tokens ---

    #[tokio::test]
    async fn blocks_exact_uuid_token() {
        let app = app(vec!["a1b2c3d4-e5f6-7890-abcd-ef1234567890"]);
        assert_eq!(post(&app, "key a1b2c3d4-e5f6-7890-abcd-ef1234567890 leaked").await, 403);
    }

    #[tokio::test]
    async fn blocks_exact_gateway_token() {
        let app = app(vec!["xK9mN2pQ7rS4tU6vW8yZ0aB3cD5eF1gH"]);
        assert_eq!(post(&app, "token is xK9mN2pQ7rS4tU6vW8yZ0aB3cD5eF1gH here").await, 403);
    }

    // --- Cas normaux (doit passer) ---

    #[tokio::test]
    async fn allows_clean_prompt() {
        // Upstream down = 502, but NOT 403 — proves scanning passed
        let status = post(&app(vec![]), "Bonjour, explique-moi le pattern observer.").await;
        assert_ne!(status, 403);
    }

    #[tokio::test]
    async fn allows_short_numbers() {
        let status = post(&app(vec![]), "il y a 42 items et le code est 12345").await;
        assert_ne!(status, 403);
    }

    #[tokio::test]
    async fn allows_partial_exact_no_match() {
        let app = app(vec!["abcdefghijklmnop"]);
        let status = post(&app, "abcdefg is not long enough").await;
        assert_ne!(status, 403);
    }

    // --- Healthcheck ---

    #[tokio::test]
    async fn healthz_returns_ok() {
        let req = Request::get("/healthz").body(Body::empty()).unwrap();
        let resp = app(vec![]).oneshot(req).await.unwrap();
        assert_eq!(resp.status(), 200);
    }
}
