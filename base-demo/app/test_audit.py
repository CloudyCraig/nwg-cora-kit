"""Unit tests for app/audit.py PII redaction.

Run from the repo root:

    python -m pytest app/test_audit.py -v

or without pytest:

    python -m unittest app.test_audit
"""

from __future__ import annotations

import hmac
import importlib
import json
import os
import sys
import tempfile
import unittest
from hashlib import sha256
from io import StringIO
from unittest import mock


def _reload_audit(env: dict[str, str]):
    """Reload audit.py with a controlled environment so module-level
    pepper resolution is reproducible per test."""
    sys.modules.pop("audit", None)
    sys.modules.pop("app.audit", None)
    with mock.patch.dict(os.environ, env, clear=False):
        sys.path.insert(0, os.path.dirname(__file__))
        try:
            mod = importlib.import_module("audit")
        finally:
            sys.path.pop(0)
    return mod


class RedactCustomerIdTests(unittest.TestCase):
    def test_redact_returns_none_for_none(self):
        audit = _reload_audit({"AUDIT_PEPPER": "test-pepper"})
        self.assertIsNone(audit.redact_customer_id(None))

    def test_redact_returns_none_for_empty_string(self):
        audit = _reload_audit({"AUDIT_PEPPER": "test-pepper"})
        self.assertIsNone(audit.redact_customer_id(""))
        self.assertIsNone(audit.redact_customer_id("   "))

    def test_redact_is_stable_for_same_input_and_pepper(self):
        audit = _reload_audit({"AUDIT_PEPPER": "test-pepper"})
        a = audit.redact_customer_id("CUST-12345")
        b = audit.redact_customer_id("CUST-12345")
        self.assertEqual(a, b)
        self.assertEqual(len(a), 32)

    def test_redact_changes_with_pepper_rotation(self):
        a = _reload_audit({"AUDIT_PEPPER": "pepper-A"}).redact_customer_id("X")
        b = _reload_audit({"AUDIT_PEPPER": "pepper-B"}).redact_customer_id("X")
        self.assertNotEqual(a, b)

    def test_redact_matches_hmac_sha256_construction(self):
        """The output must be a deterministic HMAC-SHA256 with the given
        pepper, truncated to 32 hex chars. This guards against drift to a
        weaker construction (e.g. plain sha256(pepper||id))."""
        pepper = "deterministic-pepper-1234"
        audit = _reload_audit({"AUDIT_PEPPER": pepper})
        cid = "CUST-987654"
        expected = hmac.new(
            pepper.encode("utf-8"), cid.encode("utf-8"), sha256
        ).hexdigest()[:32]
        self.assertEqual(audit.redact_customer_id(cid), expected)

    def test_redact_handles_unicode(self):
        audit = _reload_audit({"AUDIT_PEPPER": "p"})
        out = audit.redact_customer_id("客户-42")
        self.assertEqual(len(out), 32)
        self.assertTrue(all(c in "0123456789abcdef" for c in out))

    def test_redact_pepper_from_file(self):
        """``AUDIT_PEPPER_PATH`` (Kubernetes Secret mount) takes
        precedence over ``AUDIT_PEPPER`` env."""
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("file-pepper-xyz\n")
            path = f.name
        try:
            audit = _reload_audit(
                {"AUDIT_PEPPER_PATH": path, "AUDIT_PEPPER": "env-pepper-ignored"}
            )
            expected = hmac.new(
                b"file-pepper-xyz", b"CUST-1", sha256
            ).hexdigest()[:32]
            self.assertEqual(audit.redact_customer_id("CUST-1"), expected)
        finally:
            os.unlink(path)


class PaymentAuditPayloadTests(unittest.TestCase):
    def setUp(self):
        self.audit = _reload_audit({"AUDIT_PEPPER": "test-pepper"})

    def _capture(self) -> str:
        buf = StringIO()
        with mock.patch.object(self.audit, "_get_audit_handler", return_value=None), \
             mock.patch.object(self.audit.sys, "stdout", buf):
            self.audit.emit_payment_audit(
                payment_id="PMT-1",
                customer_id="CUST-9",
                customer_tier="gold",
                scheme="FPS",
                amount_minor_units=1234,
                currency="GBP",
                decision="accepted",
                decline_reason=None,
                sanctions_hit=False,
                fraud_score=0.12,
            )
        return buf.getvalue().strip()

    def test_payment_audit_never_emits_raw_customer_id(self):
        line = self._capture()
        self.assertNotIn("CUST-9", line)
        record = json.loads(line)
        self.assertIn("customer_id_hash", record)
        self.assertNotIn("customer_id", record)
        self.assertEqual(len(record["customer_id_hash"]), 32)

    def test_payment_audit_coerces_unknown_tier(self):
        buf = StringIO()
        with mock.patch.object(self.audit, "_get_audit_handler", return_value=None), \
             mock.patch.object(self.audit.sys, "stdout", buf):
            self.audit.emit_payment_audit(
                payment_id="PMT-2",
                customer_id="CUST-9",
                customer_tier="platinum",
                scheme="SEPA",
                amount_minor_units=100,
                currency="EUR",
                decision="rejected",
                decline_reason="fraud_score_high",
            )
        record = json.loads(buf.getvalue().strip())
        self.assertEqual(record["customer_tier"], "bronze")
        self.assertEqual(record["decline_reason"], "fraud_score_high")

    def test_payment_audit_clamps_fraud_score(self):
        buf = StringIO()
        with mock.patch.object(self.audit, "_get_audit_handler", return_value=None), \
             mock.patch.object(self.audit.sys, "stdout", buf):
            self.audit.emit_payment_audit(
                payment_id="PMT-3",
                customer_id="CUST-9",
                customer_tier="silver",
                scheme="FPS",
                amount_minor_units=1,
                currency="GBP",
                decision="accepted",
                fraud_score=12.5,
            )
        record = json.loads(buf.getvalue().strip())
        self.assertEqual(record["fraud_score"], 1.0)


if __name__ == "__main__":
    unittest.main()
