import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"


def runtime_lua_sources():
    for path in ADDON.rglob("*.lua"):
        if "Libs" not in path.parts:
            yield path, path.read_text(encoding="utf-8")


class ServiceNamespaceOwnershipTest(unittest.TestCase):
    def test_service_namespace_factory_is_owned_by_services(self):
        init = (ADDON / "Init.lua").read_text(encoding="utf-8")
        self.assertIn("function addon.Services.EnsureNamespace(...)", init)
        self.assertNotIn("Database.EnsureServiceNamespace", init)

    def test_runtime_has_no_database_owned_service_namespace_calls(self):
        offenders = []
        for path, source in runtime_lua_sources():
            if "EnsureServiceNamespace" in source:
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
