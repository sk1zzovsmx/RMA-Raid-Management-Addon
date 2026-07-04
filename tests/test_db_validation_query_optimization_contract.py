from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "Raid Management Addon" / "Database"
VALIDATOR = DB / "DBRaidValidator.lua"
QUERIES = DB / "DBRaidQueries.lua"
MIGRATIONS = DB / "DBRaidMigrations.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class DbValidationQueryOptimizationContractTest(unittest.TestCase):
    def test_validator_caches_hot_string_helpers(self):
        src = read(VALIDATOR)
        self.assertIn("local strsub = string.sub", src)
        self.assertIn("strsub(key, 1, 1)", src)

    def test_queries_prefer_runtime_indexes_for_hot_lookup_paths(self):
        src = read(QUERIES)
        self.assertIn("runtime", src)
        self.assertTrue("playerByNid" in src or "playerIdxByNid" in src)
        self.assertIn("bossByNid", src)
        self.assertRegex(src, r"local\s+function\s+getPlayerByNid\s*\(")

    def test_migrations_have_current_schema_fast_path(self):
        src = read(MIGRATIONS)
        self.assertIn("local function isCurrentSchema", src)
        self.assertRegex(src, r"if\s+isCurrentSchema\s*\(")

    def test_no_non_rma_savedvariables_are_introduced(self):
        combined = "\n".join(read(path) for path in (VALIDATOR, QUERIES, MIGRATIONS))
        forbidden = ("KRT_", "Karazhan", "KaraRaid", "KRaid")
        for token in forbidden:
            self.assertNotIn(token, combined)


if __name__ == "__main__":
    unittest.main()
