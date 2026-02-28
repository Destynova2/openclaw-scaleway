"""Unit tests for the kill switch handler."""

import io
import json
import os
import sys
import unittest
from http.client import HTTPResponse
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError

# Ensure the handler module is importable
sys.path.insert(0, os.path.dirname(__file__))
import handler


def _make_billing_response(consumptions):
    """Build a mock Billing API JSON response from a list of (units, nanos) tuples."""
    items = []
    for units, nanos in consumptions:
        items.append({"value": {"units": str(units), "nanos": str(nanos)}})
    return json.dumps({"consumptions": items}).encode()


def _mock_urlopen_factory(response_bytes, status=200):
    """Return a context-manager mock that behaves like urllib.request.urlopen."""
    cm = MagicMock()
    cm.__enter__ = MagicMock(return_value=MagicMock(read=MagicMock(return_value=response_bytes)))
    cm.__exit__ = MagicMock(return_value=False)
    return cm


# ── Environment shared across billing tests ──────────────────────────
_BILLING_ENV = {
    "BILLING_PROJECT_ID": "00000000-0000-0000-0000-000000000000",
    "SCW_SECRET_KEY": "fake-secret-key",
    "SERVER_ID": "11111111-1111-1111-1111-111111111111",
    "ADMIN_EMAIL": "admin@example.com",
    "DOMAIN_NAME": "example.com",
    "KILLSWITCH_TOKEN": "test-token-value",
}


class TestNanosConversion(unittest.TestCase):
    """Verify that the nanos → EUR arithmetic is correct."""

    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    @patch("handler.urllib.request.urlopen")
    def test_zero_consumption(self, mock_urlopen):
        mock_urlopen.return_value = _mock_urlopen_factory(
            _make_billing_response([])
        )
        result = handler._check_billing_and_poweroff()
        self.assertEqual(result["statusCode"], 200)
        self.assertIn("0.00 EUR", result["body"])

    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    @patch("handler.urllib.request.urlopen")
    def test_units_and_nanos_combined(self, mock_urlopen):
        # 5 units + 500_000_000 nanos = 5.50 EUR
        mock_urlopen.return_value = _mock_urlopen_factory(
            _make_billing_response([(5, 500_000_000)])
        )
        result = handler._check_billing_and_poweroff()
        self.assertEqual(result["statusCode"], 200)
        self.assertIn("5.50 EUR", result["body"])

    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    @patch("handler.urllib.request.urlopen")
    def test_multiple_consumptions_summed(self, mock_urlopen):
        # 3.00 + 2.00 + 1.50 = 6.50 EUR
        mock_urlopen.return_value = _mock_urlopen_factory(
            _make_billing_response([(3, 0), (2, 0), (1, 500_000_000)])
        )
        result = handler._check_billing_and_poweroff()
        self.assertIn("6.50 EUR", result["body"])

    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    @patch("handler.urllib.request.urlopen")
    def test_nanos_only(self, mock_urlopen):
        # 0 units + 999_999_999 nanos ≈ 1.00 EUR (0.999999999)
        mock_urlopen.return_value = _mock_urlopen_factory(
            _make_billing_response([(0, 999_999_999)])
        )
        result = handler._check_billing_and_poweroff()
        self.assertIn("1.00 EUR", result["body"])

    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    @patch("handler.urllib.request.urlopen")
    def test_missing_value_fields_default_to_zero(self, mock_urlopen):
        data = json.dumps({"consumptions": [{"value": {}}]}).encode()
        mock_urlopen.return_value = _mock_urlopen_factory(data)
        result = handler._check_billing_and_poweroff()
        self.assertIn("0.00 EUR", result["body"])


class TestBillingThresholds(unittest.TestCase):
    """Test the exact boundary conditions at 10 EUR (warning) and 13 EUR (poweroff)."""

    def _run_with_total(self, total_eur, mock_urlopen, mock_send_email):
        """Helper: set up a single consumption entry that sums to total_eur."""
        units = int(total_eur)
        nanos = int(round((total_eur - units) * 1_000_000_000))
        mock_urlopen.return_value = _mock_urlopen_factory(
            _make_billing_response([(units, nanos)])
        )
        # Also mock _poweroff to avoid a second urlopen call
        return handler._check_billing_and_poweroff()

    # ── Below alert threshold ──

    @patch("handler._send_email")
    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_below_alert_9_99(self, mock_urlopen, mock_send_email):
        result = self._run_with_total(9.99, mock_urlopen, mock_send_email)
        self.assertEqual(result["statusCode"], 200)
        self.assertIn("OK:", result["body"])
        self.assertIn("9.99 EUR", result["body"])
        mock_send_email.assert_not_called()

    # ── Exactly at alert threshold ──

    @patch("handler._send_email")
    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_exactly_10_eur_triggers_warning(self, mock_urlopen, mock_send_email):
        result = self._run_with_total(10.0, mock_urlopen, mock_send_email)
        self.assertEqual(result["statusCode"], 200)
        self.assertIn("WARNING:", result["body"])
        mock_send_email.assert_called_once()
        subject = mock_send_email.call_args[0][0]
        self.assertIn("WARNING", subject)

    # ── Between alert and poweroff threshold ──

    @patch("handler._send_email")
    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_12_99_triggers_warning_not_poweroff(self, mock_urlopen, mock_send_email):
        result = self._run_with_total(12.99, mock_urlopen, mock_send_email)
        self.assertEqual(result["statusCode"], 200)
        self.assertIn("WARNING:", result["body"])
        mock_send_email.assert_called_once()
        # Should NOT contain ALERT (poweroff language)
        self.assertNotIn("ALERT:", result["body"])

    # ── Exactly at poweroff threshold ──

    @patch("handler._send_email")
    @patch("handler._poweroff", return_value={"statusCode": 200, "body": "Instance powered off"})
    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_exactly_13_eur_triggers_poweroff(self, mock_urlopen, mock_poweroff, mock_send_email):
        result = self._run_with_total(13.0, mock_urlopen, mock_send_email)
        self.assertIn("ALERT:", result["body"])
        self.assertIn("13.00 EUR", result["body"])
        mock_poweroff.assert_called_once()
        mock_send_email.assert_called_once()
        subject = mock_send_email.call_args[0][0]
        self.assertIn("CRITICAL", subject)

    # ── Above poweroff threshold ──

    @patch("handler._send_email")
    @patch("handler._poweroff", return_value={"statusCode": 200, "body": "Instance powered off"})
    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_13_01_triggers_poweroff(self, mock_urlopen, mock_poweroff, mock_send_email):
        result = self._run_with_total(13.01, mock_urlopen, mock_send_email)
        self.assertIn("ALERT:", result["body"])
        mock_poweroff.assert_called_once()
        mock_send_email.assert_called_once()


class TestBillingAPIErrors(unittest.TestCase):
    """Test behaviour when the Billing API returns an HTTP error."""

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_billing_api_403(self, mock_urlopen):
        error = HTTPError(
            url="https://api.scaleway.com/billing/v2beta1/consumptions",
            code=403,
            msg="Forbidden",
            hdrs={},
            fp=io.BytesIO(b'{"message":"insufficient permissions"}'),
        )
        mock_urlopen.side_effect = error
        result = handler._check_billing_and_poweroff()
        self.assertEqual(result["statusCode"], 403)
        self.assertIn("Billing API error", result["body"])
        self.assertIn("insufficient permissions", result["body"])

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "BUDGET_THRESHOLD_EUR": "13", "ALERT_THRESHOLD_EUR": "10"})
    def test_billing_api_500(self, mock_urlopen):
        error = HTTPError(
            url="https://api.scaleway.com/billing/v2beta1/consumptions",
            code=500,
            msg="Internal Server Error",
            hdrs={},
            fp=io.BytesIO(b"server error"),
        )
        mock_urlopen.side_effect = error
        result = handler._check_billing_and_poweroff()
        self.assertEqual(result["statusCode"], 500)
        self.assertIn("Billing API error", result["body"])


class TestPoweroff(unittest.TestCase):
    """Test the _poweroff function's HTTP call and error handling."""

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, _BILLING_ENV)
    def test_poweroff_success(self, mock_urlopen):
        mock_urlopen.return_value = _mock_urlopen_factory(b"")
        result = handler._poweroff()
        self.assertEqual(result["statusCode"], 200)
        self.assertIn("powered off", result["body"])

        # Verify the request was built correctly
        call_args = mock_urlopen.call_args[0][0]
        self.assertIn("/action", call_args.full_url)
        self.assertEqual(call_args.get_method(), "POST")
        self.assertEqual(call_args.get_header("Content-type"), "application/json")
        self.assertEqual(call_args.get_header("X-auth-token"), "fake-secret-key")

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, _BILLING_ENV)
    def test_poweroff_api_error(self, mock_urlopen):
        error = HTTPError(
            url="https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/xxx/action",
            code=404,
            msg="Not Found",
            hdrs={},
            fp=io.BytesIO(b'{"message":"server not found"}'),
        )
        mock_urlopen.side_effect = error
        result = handler._poweroff()
        self.assertEqual(result["statusCode"], 404)
        self.assertIn("Scaleway API error", result["body"])

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, {**_BILLING_ENV, "SCW_DEFAULT_ZONE": "nl-ams-1"})
    def test_poweroff_uses_custom_zone(self, mock_urlopen):
        mock_urlopen.return_value = _mock_urlopen_factory(b"")
        handler._poweroff()
        call_args = mock_urlopen.call_args[0][0]
        self.assertIn("nl-ams-1", call_args.full_url)


class TestSendEmail(unittest.TestCase):
    """Test the _send_email function, including the new error logging."""

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, _BILLING_ENV)
    def test_send_email_success(self, mock_urlopen):
        mock_urlopen.return_value = _mock_urlopen_factory(b"")
        # Should not raise
        handler._send_email("Test Subject", "Test body")

        # Verify the request payload
        call_args = mock_urlopen.call_args[0][0]
        payload = json.loads(call_args.data.decode())
        self.assertEqual(payload["subject"], "Test Subject")
        self.assertEqual(payload["text"], "Test body")
        self.assertEqual(payload["from"]["email"], "killswitch@example.com")
        self.assertEqual(payload["to"], [{"email": "admin@example.com"}])
        self.assertEqual(payload["project_id"], "00000000-0000-0000-0000-000000000000")

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, _BILLING_ENV)
    def test_send_email_http_error_logs_to_stderr(self, mock_urlopen):
        error = HTTPError(
            url="https://api.scaleway.com/transactional-email/v1alpha1/regions/fr-par/emails",
            code=429,
            msg="Too Many Requests",
            hdrs={},
            fp=io.BytesIO(b"rate limited"),
        )
        mock_urlopen.side_effect = error

        # Capture stderr
        captured = io.StringIO()
        with patch("sys.stderr", captured):
            handler._send_email("Subject", "Body")

        stderr_output = captured.getvalue()
        self.assertIn("Email send failed", stderr_output)
        self.assertIn("429", stderr_output)
        self.assertIn("Too Many Requests", stderr_output)

    @patch("handler.urllib.request.urlopen")
    @patch.dict(os.environ, _BILLING_ENV)
    def test_send_email_error_does_not_raise(self, mock_urlopen):
        """Email errors must be swallowed (best effort) — no exception propagation."""
        error = HTTPError(
            url="https://api.scaleway.com/transactional-email/v1alpha1/regions/fr-par/emails",
            code=500,
            msg="Internal Server Error",
            hdrs={},
            fp=io.BytesIO(b"error"),
        )
        mock_urlopen.side_effect = error
        # Must not raise
        handler._send_email("Subject", "Body")


class TestHandlerEntryPoint(unittest.TestCase):
    """Test the main handler() dispatch: cron vs HTTP triggers."""

    @patch("handler._check_billing_and_poweroff", return_value={"statusCode": 200, "body": "OK"})
    def test_cron_trigger_no_http_method(self, mock_check):
        """Events without httpMethod are treated as cron triggers."""
        result = handler.handler({}, None)
        mock_check.assert_called_once()
        self.assertEqual(result["statusCode"], 200)

    @patch("handler._poweroff", return_value={"statusCode": 200, "body": "Instance powered off"})
    @patch.dict(os.environ, _BILLING_ENV)
    def test_http_trigger_bearer_auth(self, mock_poweroff):
        event = {
            "httpMethod": "POST",
            "headers": {"Authorization": "Bearer test-token-value"},
        }
        result = handler.handler(event, None)
        mock_poweroff.assert_called_once()
        self.assertEqual(result["statusCode"], 200)

    @patch("handler._poweroff", return_value={"statusCode": 200, "body": "Instance powered off"})
    @patch.dict(os.environ, _BILLING_ENV)
    def test_http_trigger_query_param_auth(self, mock_poweroff):
        event = {
            "httpMethod": "POST",
            "headers": {},
            "queryStringParameters": {"token": "test-token-value"},
        }
        result = handler.handler(event, None)
        mock_poweroff.assert_called_once()

    @patch.dict(os.environ, _BILLING_ENV)
    def test_http_trigger_wrong_token_returns_403(self):
        event = {
            "httpMethod": "POST",
            "headers": {"Authorization": "Bearer wrong-token"},
        }
        result = handler.handler(event, None)
        self.assertEqual(result["statusCode"], 403)
        self.assertIn("Forbidden", result["body"])

    @patch.dict(os.environ, _BILLING_ENV)
    def test_http_trigger_missing_token_returns_403(self):
        event = {
            "httpMethod": "POST",
            "headers": {},
        }
        result = handler.handler(event, None)
        self.assertEqual(result["statusCode"], 403)

    @patch.dict(os.environ, _BILLING_ENV)
    def test_http_trigger_empty_bearer_returns_403(self):
        event = {
            "httpMethod": "POST",
            "headers": {"Authorization": "Bearer "},
        }
        result = handler.handler(event, None)
        self.assertEqual(result["statusCode"], 403)

    @patch.dict(os.environ, _BILLING_ENV)
    def test_http_trigger_null_query_string_parameters(self):
        """queryStringParameters can be None in real AWS/Scaleway events."""
        event = {
            "httpMethod": "POST",
            "headers": {},
            "queryStringParameters": None,
        }
        result = handler.handler(event, None)
        self.assertEqual(result["statusCode"], 403)


if __name__ == "__main__":
    unittest.main()
