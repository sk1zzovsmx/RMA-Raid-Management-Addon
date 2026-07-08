from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


def read_syncer():
    return SYNCER.read_text(encoding="utf-8")


def local_function_body(src, name):
    match = re.search(r"local\s+function\s+" + name + r"\s*\([^)]*\)(.*?)\n(?:\t| {4})end", src, re.S)
    if not match:
        raise AssertionError(name)
    return match.group(1)


class SyncChunkSendPreallocationContractTest(unittest.TestCase):
    def test_shared_chunk_send_helper_exists(self):
        src = read_syncer()
        self.assertRegex(src, r"local\s+function\s+sendChunkedPayload\s*\(")
        self.assertIn("chunkMessageBuffer", src)
        self.assertRegex(src, r"local\s+function\s+clearChunkMessageBuffer\s*\(")

    def test_snapshot_and_delta_send_paths_use_shared_helper(self):
        src = read_syncer()
        for name in ("sendSnapshot", "sendDelta"):
            body = local_function_body(src, name)
            self.assertIn("sendChunkedPayload", body, name)
            self.assertNotIn("for idx = 1, totalChunks do", body, name)

    def test_protocol_literals_remain_stable(self):
        src = read_syncer()
        self.assertIn('local MSG_SNAPSHOT = "SN"', src)
        self.assertIn('local MSG_DELTA = "DL"', src)
        self.assertIn("requestId", src)
        self.assertIn("totalChunks", src)
        self.assertIn("MAX_CHUNK_SIZE", src)

    def test_existing_transport_and_compression_paths_are_reused(self):
        src = read_syncer()
        helper = local_function_body(src, "sendChunkedPayload")
        self.assertIn("SnapshotPayload.EncodeTransportText", helper)
        self.assertIn("sendAddonPayload(target, msg)", helper)
        self.assertIn("setOutgoingCompressionSupport(requestId, false)", helper)


if __name__ == "__main__":
    unittest.main()
