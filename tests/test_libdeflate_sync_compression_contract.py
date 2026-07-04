import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / "Raid Management Addon" / "Database" / "DBSyncPayload.lua"
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class LibDeflateSyncCompressionContractTest(unittest.TestCase):
    def test_payload_supports_tagged_libdeflate_codec_and_base64_fallback(self):
        source = read(PAYLOAD)
        self.assertIn('local COMPRESSED_PREFIX = "D1:"', source)
        self.assertIn("function SnapshotPayload.EncodeTransportText(value, opts)", source)
        self.assertIn("function SnapshotPayload.DecodeTransportText(value)", source)
        self.assertIn("CompressDeflate", source)
        self.assertIn("EncodeForWoWAddonChannel", source)
        self.assertIn("DecodeForWoWAddonChannel", source)
        self.assertIn("DecompressDeflate", source)
        self.assertIn("SnapshotPayload.EncodeText(value)", source)
        self.assertIn("SnapshotPayload.DecodeText(value)", source)

    def test_syncer_uses_transport_codec_for_snapshot_and_delta_chunks(self):
        source = read(SYNCER)
        self.assertIn("EncodeTransportText", source)
        self.assertIn("DecodeTransportText", source)
        self.assertIn("supportsCompression", source)


if __name__ == "__main__":
    unittest.main()
