from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


def read_syncer():
    return SYNCER.read_text(encoding="utf-8")


def method_body(src, name):
    match = re.search(r"function\s+module:" + name + r"\s*\([^)]*\)(.*?)\n    end", src, re.S)
    if not match:
        raise AssertionError(name)
    return match.group(1)


def local_function_body(src, name):
    match = re.search(r"local\s+function\s+" + name + r"\s*\([^)]*\)(.*?)\n    end", src, re.S)
    if not match:
        return ""
    return match.group(1)


class SyncOutgoingRateLimitContractTest(unittest.TestCase):
    def test_outgoing_rate_limit_policy_exists(self):
        src = read_syncer()
        self.assertIn("OUTGOING_RATE_WINDOW_SECONDS", src)
        self.assertIn("OUTGOING_RATE_MAX_PER_TARGET", src)
        self.assertRegex(src, r"local\s+function\s+allowOutgoingRequest\s*\(")
        self.assertIn("_outgoingRate", src)

    def test_outgoing_gate_is_applied_to_request_and_push_paths(self):
        src = read_syncer()
        for name in ("RequestLoggerReq", "BroadcastLoggerPush"):
            body = method_body(src, name)
            self.assertIn("allowOutgoingRequest", body, name)

    def test_rate_limit_does_not_touch_incoming_handlers(self):
        src = read_syncer()
        for name in ("handleIncomingRequest", "handleIncomingSnapshot", "handleIncomingDelta"):
            body = local_function_body(src, name)
            self.assertNotIn("allowOutgoingRequest", body, name)

    def test_wire_format_tokens_are_not_renamed(self):
        src = read_syncer()
        self.assertIn('local MSG_REQUEST = "RQ"', src)
        self.assertIn('local MSG_SNAPSHOT = "SN"', src)
        self.assertIn('local MSG_DELTA = "DL"', src)
        self.assertIn('local MODE_REQ = "REQ"', src)
        self.assertIn('local MODE_PUSH = "PUSH"', src)
        self.assertIn('local MODE_SYNC = "SYNC"', src)


if __name__ == "__main__":
    unittest.main()
