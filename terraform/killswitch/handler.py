import hmac
import json
import os
import sys
import urllib.request


def handler(event, context):
    # Cron trigger : pas de httpMethod → verification conso automatique
    if "httpMethod" not in event:
        return _check_billing_and_poweroff()

    # HTTP trigger : authentification requise (Bearer ou query param)
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
    """Verifie la conso du projet et agit selon les seuils."""
    project_id = os.environ["BILLING_PROJECT_ID"]
    secret_key = os.environ["SCW_SECRET_KEY"]
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

    # Calculer la conso totale du projet
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
    """Eteint l'instance via l'API Scaleway."""
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
    """Envoie un email via Scaleway TEM API (best effort)."""
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
        # Best effort — ne pas bloquer le kill switch si l'email echoue
