from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOC = ROOT / "Raid Management Addon" / "Raid Management Addon.toc"


def read(path):
    return path.read_text(encoding="utf-8")


class TocPackagingContractTest(unittest.TestCase):
    def _toc_runtime_entries(self):
        entries = []
        for raw_line in read(TOC).splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or line.startswith("##"):
                continue
            if line.lower().endswith((".lua", ".xml")):
                entries.append("Raid Management Addon/" + line.replace("\\", "/"))
        return entries

    def test_toc_runtime_files_are_tracked_for_release_packaging(self):
        tracked = set(subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).splitlines())
        missing = [entry for entry in self._toc_runtime_entries() if entry not in tracked]

        self.assertEqual([], missing)

    def test_module_registry_dependencies_load_before_consumers(self):
        lua_order = {}
        for index, entry in enumerate(self._toc_runtime_entries()):
            if entry.lower().endswith(".lua"):
                lua_order[entry] = index

        provider_order = {}
        dependency_edges = []
        add_module = re.compile(r'registry\.AddModule\("([^"]+)"\s*,\s*\{(?P<body>.*?)\}\s*\)', re.S)
        deps_block = re.compile(r"deps\s*=\s*\{(?P<body>.*?)\}", re.S)
        quoted_value = re.compile(r'"([^"]+)"')
        local_name = re.compile(r'local\s+name\s*=\s*"([^"]+)"')

        for entry, toc_index in lua_order.items():
            module_path = entry[len("Raid Management Addon/") : -len(".lua")]
            provider_order.setdefault(module_path, (toc_index, -1))
            source = read(ROOT / entry)
            for match in local_name.finditer(source):
                provider_order.setdefault(match.group(1), (toc_index, match.start()))
            for match in add_module.finditer(source):
                module_name = match.group(1)
                provider_order.setdefault(module_name, (toc_index, match.start()))
                deps_match = deps_block.search(match.group("body"))
                if deps_match:
                    for dependency in quoted_value.findall(deps_match.group("body")):
                        dependency_edges.append((module_name, dependency, entry))

        provider_order.setdefault("Init", (lua_order["Raid Management Addon/Init.lua"], -1))

        failures = []
        for module_name, dependency, entry in dependency_edges:
            module_order = provider_order.get(module_name)
            dependency_order = provider_order.get(dependency)
            if dependency_order is None:
                failures.append(f"{module_name} depends on unregistered {dependency} in {entry}")
            elif module_order and dependency_order > module_order:
                failures.append(f"{module_name} loads before dependency {dependency} in {entry}")

        self.assertEqual([], failures)
