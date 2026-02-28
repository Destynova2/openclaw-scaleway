"""Kill switch handler for Scaleway Serverless Functions.

Packaged and deployed by ``terraform/killswitch.tf``. Runs hourly via cron
to check project billing and power off the instance if the budget threshold
is exceeded.
"""
import hmac
import json
import os
import sys
import urllib.request


def handler(event, context):
    """Dispatches between cron and HTTP triggers.

    Cron triggers (no ``httpMethod``) run the automatic billing check.
    HTTP triggers require Bearer or query-param token authentication
    and force an immediate poweroff.

    Args:
        event: Scaleway Serverless event dict. Cron triggers omit ``httpMethod``.
            HTTP triggers include ``httpMethod``, ``headers``, and optionally
            ``queryStringParameters``.
        context: Scaleway Serverless context (unused).

    Returns:
        Dict with ``statusCode`` (int) and ``body`` (str).
        200: billing check completed (poweroff may or may not have occurred).
        403: HTTP trigger with invalid or missing token.

    Environment:
        KILLSWITCH_TOKEN: Required for HTTP trigger authentication.
    """
    # Cron trigger: no httpMethod → automatic billing check
    if "httpMethod" not in event:
        return _check_billing_and_poweroff()

    # HTTP trigger: token authentication required (Bearer or query param)
    expected_token = os.environ["KILLSWITCH_TOKEN"]
    headers = event.get("headers", {})

    auth_header = headers.get("Authorization", "")
    bearer_token = (
        auth_header.removeprefix("Bearer ").strip()
        if auth_header.startswith("Bearer ")
        else ""
    )
    query_token = (event.get("queryStringParameters") or {}).get("token", "")
    token = bearer_token or query_token

    if not token or not hmac.compare_digest(token, expected_token):
        return {"statusCode": 403, "body": "Forbidden"}

    return _poweroff()


def _check_billing_and_poweroff():
    """Checks project billing and enforces budget thresholds.

    Sends a warning email at the alert threshold and powers off the instance
    at the budget threshold.

    Returns:
        Dict with ``statusCode`` and ``body``. Status 200 on success (regardless
        of whether poweroff was triggered). Non-200 if the Billing API call fails.

    Raises:
        KeyError: If ``BILLING_PROJECT_ID`` or ``SCW_SECRET_KEY`` is not set.
            Also propagated from ``_poweroff()`` if ``SERVER_ID`` is missing.
        ValueError: If ``BUDGET_THRESHOLD_EUR`` or ``ALERT_THRESHOLD_EUR`` is not a valid number.

    Environment:
        BILLING_PROJECT_ID: Scaleway project to check.
        SCW_SECRET_KEY: API authentication key.
        BUDGET_THRESHOLD_EUR: Poweroff threshold in EUR (default: 13).
        ALERT_THRESHOLD_EUR: Warning email threshold in EUR (default: 10).
    """
    project_id = os.environ["BILLING_PROJECT_ID"]
    secret_key = os.environ["SCW_SECRET_KEY"]
    # Defaults are fallbacks — production values are injected by killswitch.tf
    threshold_eur = float(os.environ.get("BUDGET_THRESHOLD_EUR", "13"))
    alert_eur = float(os.environ.get("ALERT_THRESHOLD_EUR", "10"))

    url = f"https://api.scaleway.com/billing/v2beta1/consumptions?project_id={project_id}"
    req = urllib.request.Request(url)
    req.add_header("X-Auth-Token", secret_key)

    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return {"statusCode": e.code, "body": f"Billing API error: {body}"}

    # Sum all consumption entries for the project
    total_eur = 0.0
    for c in data.get("consumptions", []):
        value = c.get("value", {})
        units = int(value.get("units", 0))
        nanos = int(value.get("nanos", 0))
        total_eur += units + nanos / 1_000_000_000

    if total_eur >= threshold_eur:
        _send_email(
            f"[CRITICAL] Kill switch — {total_eur:.2f} EUR",
            f"Le seuil de {threshold_eur:.2f} EUR a ete depasse.\n"
            f"Consommation projet openclaw : {total_eur:.2f} EUR.\n"
            f"L'instance a ete eteinte automatiquement.\n\n"
            f"Pour rallumer : scw instance server start <server-id>",
        )
        result = _poweroff()
        result["body"] = (
            f"ALERT: {total_eur:.2f} EUR >= {threshold_eur:.2f} EUR — {result['body']}"
        )
        return result

    if total_eur >= alert_eur:
        _send_email(
            f"[WARNING] Consommation elevee — {total_eur:.2f} EUR",
            f"Consommation projet openclaw : {total_eur:.2f} EUR.\n"
            f"Le kill switch se declenchera a {threshold_eur:.2f} EUR.\n"
            f"Verifiez votre usage API.",
        )
        return {
            "statusCode": 200,
            "body": f"WARNING: {total_eur:.2f} EUR >= {alert_eur:.2f} EUR (email sent)",
        }

    return {
        "statusCode": 200,
        "body": f"OK: {total_eur:.2f} EUR < {alert_eur:.2f} EUR",
    }


def _poweroff():
    """Powers off the instance via the Scaleway Instance API.

    Returns:
        Dict with ``statusCode`` and ``body``.

    Raises:
        KeyError: If ``SERVER_ID`` or ``SCW_SECRET_KEY`` is not set.

    Environment:
        SERVER_ID: Scaleway instance ID to power off.
        SCW_SECRET_KEY: API authentication key.
        SCW_DEFAULT_ZONE: Instance zone (default ``fr-par-1``).
    """
    server_id = os.environ["SERVER_ID"]
    zone = os.environ.get("SCW_DEFAULT_ZONE", "fr-par-1")
    secret_key = os.environ["SCW_SECRET_KEY"]

    url = f"https://api.scaleway.com/instance/v1/zones/{zone}/servers/{server_id}/action"
    data = json.dumps({"action": "poweroff"}).encode()

    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Auth-Token", secret_key)

    try:
        with urllib.request.urlopen(req) as resp:
            return {"statusCode": 200, "body": "Instance powered off"}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return {"statusCode": e.code, "body": f"Scaleway API error: {body}"}


def _send_email(subject, text):
    """Sends an alert email via Scaleway TEM API.

    Errors are logged to stderr but swallowed (best effort) to avoid
    blocking the kill switch if the email service is unavailable.

    Args:
        subject: Email subject line.
        text: Plain-text email body.

    Environment:
        SCW_SECRET_KEY: API authentication key.
        ADMIN_EMAIL: Recipient email address.
        DOMAIN_NAME: Sender domain (``killswitch@<domain>``).
        BILLING_PROJECT_ID: TEM project scope.
    """
    secret_key = os.environ["SCW_SECRET_KEY"]
    admin_email = os.environ["ADMIN_EMAIL"]
    domain_name = os.environ["DOMAIN_NAME"]
    project_id = os.environ["BILLING_PROJECT_ID"]

    url = "https://api.scaleway.com/transactional-email/v1alpha1/regions/fr-par/emails"
    payload = json.dumps(
        {
            "from": {
                "email": f"killswitch@{domain_name}",
                "name": "OpenClaw Kill Switch",
            },
            "to": [{"email": admin_email}],
            "subject": subject,
            "text": text,
            "project_id": project_id,
        }
    ).encode()

    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Auth-Token", secret_key)

    try:
        with urllib.request.urlopen(req) as resp:
            pass
    except urllib.error.HTTPError as e:
        print(f"Email send failed: {e.code} {e.reason}", file=sys.stderr)
        # Best effort — don't block the kill switch if email fails
