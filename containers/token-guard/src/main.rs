// token-guard — DLP reverse proxy for OpenClaw LLM API calls.
// Scans outgoing prompts for leaked secrets and blocks them.
// ~3MB RAM, <1ms overhead, zero-copy response streaming (SSE).

use axum::{body::Body, extract::State, response::Response, Router};
use http::StatusCode;
use http_body_util::BodyExt;
use regex::RegexSet;
use std::sync::Arc;
use tokio::net::TcpListener;

struct AppState {
    client: reqwest::Client,
    patterns: RegexSet,
    exact_tokens: Vec<String>,
    upstream: String,
    telegram_url: Option<String>,
    telegram_chat_id: Option<String>,
}

// Patterns de tokens qui ne doivent JAMAIS apparaitre dans un prompt LLM.
// Couvre les principaux providers cloud, VCS et services SaaS.
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
    // Bancaire
    r"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b",                     // IBAN
    r"\b[A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b",             // SWIFT/BIC
    r"\b[A-Z]{2}\d{3}[A-Z0-9]{6,28}\b",                      // SEPA Creditor ID
    // Crypto wallets
    r"\b0x[a-fA-F0-9]{40}\b",                                 // Ethereum (ETH)
    r"\b(?:bc1|[13])[a-zA-HJ-NP-Z0-9]{25,39}\b",            // Bitcoin (BTC)
    r"\b4[0-9AB][1-9A-HJ-NP-Za-km-z]{93}\b",                // Monero (XMR)
    // PII
    r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",   // Email
];

async fn proxy(
    State(state): State<Arc<AppState>>,
    req: http::Request<Body>,
) -> Response<Body> {
    if req.uri().path() == "/healthz" {
        return Response::builder()
            .status(StatusCode::OK)
            .body(Body::from("ok"))
            .unwrap();
    }

    let (parts, body) = req.into_parts();

    // Buffer le body pour scanner (les prompts font < 1 MB)
    let body_bytes = match body.collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(e) => {
            eprintln!("[ERROR] read body: {e}");
            return error_response(StatusCode::BAD_REQUEST, "failed to read body");
        }
    };

    // Scanner les tokens (patterns regex + valeurs exactes)
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

    // Forward vers l'upstream (stream la reponse pour le SSE)
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
                .unwrap()
        }
        Err(e) => {
            eprintln!("[ERROR] upstream: {e}");
            error_response(StatusCode::BAD_GATEWAY, &e.to_string())
        }
    }
}

fn error_response(status: StatusCode, msg: &str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"error":{{"message":"{}","type":"token_guard"}}}}"#,
            msg.replace('"', "\\\"")
        )))
        .unwrap()
}

fn alert_telegram(state: &AppState) {
    if let (Some(url), Some(chat_id)) = (&state.telegram_url, &state.telegram_chat_id) {
        let client = state.client.clone();
        let url = url.clone();
        let chat_id = chat_id.clone();
        tokio::spawn(async move {
            let _ = client
                .post(&url)
                .json(&serde_json::json!({
                    "chat_id": chat_id,
                    "text": "\u{1f6a8} token-guard: secret bloque dans un prompt LLM"
                }))
                .send()
                .await;
        });
    }
}

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
        .filter(|s| s.len() >= 8)
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

    fn app(exact: Vec<&str>) -> Router {
        Router::new().fallback(proxy).with_state(test_state(exact))
    }

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

    // --- Crypto wallets ---

    #[tokio::test]
    async fn blocks_eth_address() {
        assert_eq!(post(&app(vec![]), "send to 0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18").await, 403);
    }

    #[tokio::test]
    async fn blocks_btc_address() {
        assert_eq!(post(&app(vec![]), "btc bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq").await, 403);
    }

    // --- Email ---

    #[tokio::test]
    async fn blocks_email() {
        assert_eq!(post(&app(vec![]), "contact admin@example.com for help").await, 403);
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
