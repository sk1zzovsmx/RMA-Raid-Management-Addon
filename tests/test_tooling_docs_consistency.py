import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOLS_README = ROOT / "tools" / "README.md"
VALIDATION_DOC = ROOT / "docs" / "VALIDATION.md"
DEVELOPMENT_DOC = ROOT / "docs" / "DEVELOPMENT.md"
DOCS_README = ROOT / "docs" / "README.md"
SAVED_VARIABLES_DOC = ROOT / "docs" / "SAVED_VARIABLES.md"
GREENFIELD_CONTRACT = ROOT / "docs" / "GREENFIELD_REWRITE_CONTRACT.md"
GREENFIELD_COHERENCE = ROOT / "docs" / "GREENFIELD_COMMIT_COHERENCE.md"


def read(path):
    return path.read_text(encoding="utf-8")


class ToolingDocsConsistencyTest(unittest.TestCase):
    def test_tools_readme_matches_reset_baseline_validation_surface(self):
        tools_readme = read(TOOLS_README)
        validation_doc = read(VALIDATION_DOC)
        development_doc = read(DEVELOPMENT_DOC)

        self.assertFalse((ROOT / "tools" / "check-rma.ps1").exists())
        self.assertFalse((ROOT / "tools" / "check_rma.py").exists())

        for doc in (validation_doc, development_doc):
            self.assertIn("reset baseline does not track", doc)
            self.assertIn("validate_toc.py", doc)
            self.assertIn("lint_lua51.py", doc)
            self.assertIn("scan_xpcall.py", doc)

        self.assertIn("reset baseline does not track", tools_readme)
        self.assertIn("validate_toc.py", tools_readme)
        self.assertIn("lint_lua51.py", tools_readme)
        self.assertIn("scan_xpcall.py", tools_readme)
        self.assertNotIn("tools/check-rma.ps1", tools_readme)
        self.assertNotIn("tools/check_rma.py", tools_readme)

    def test_reset_baseline_docs_use_py_launcher_for_skill_validators(self):
        docs = {
            "tools/README.md": read(TOOLS_README),
            "docs/VALIDATION.md": read(VALIDATION_DOC),
            "docs/DEVELOPMENT.md": read(DEVELOPMENT_DOC),
            "docs/README.md": read(DOCS_README),
            "docs/SAVED_VARIABLES.md": read(SAVED_VARIABLES_DOC),
        }
        for label, doc in docs.items():
            self.assertNotIn(".venv\\Scripts\\python.exe", doc, label)
            self.assertIn("py -3 .agents\\skills\\wow-addon-dev-wotlk-v335a\\scripts\\validate_toc.py", doc, label)

    def test_greenfield_contract_reports_absent_reset_baseline_checker(self):
        contract = read(GREENFIELD_CONTRACT)

        self.assertFalse((ROOT / "tools" / "check-rma.ps1").exists())
        self.assertIn("reset baseline does not track", contract)
        self.assertIn("tools/check-rma.ps1", contract)
        self.assertNotIn("powershell -ExecutionPolicy Bypass -File tools\\check-rma.ps1", contract)

    def test_greenfield_contract_names_current_slash_dispatch_owner(self):
        contract = read(GREENFIELD_CONTRACT)

        self.assertTrue((ROOT / "Raid Management Addon" / "EntryPoints" / "SlashEvents.lua").exists())
        self.assertFalse((ROOT / "Raid Management Addon" / "EntryPoints" / "SlashCommandHandlers.lua").exists())
        self.assertIn("Raid Management Addon/EntryPoints/SlashEvents.lua", contract)
        self.assertNotIn("Raid Management Addon/EntryPoints/SlashCommandHandlers.lua", contract)

    def test_runtime_smoke_gap_wording_requires_not_run_status(self):
        validation_doc = read(VALIDATION_DOC)
        contract = read(GREENFIELD_CONTRACT)

        for label, doc in {
            "docs/VALIDATION.md": validation_doc,
            "docs/GREENFIELD_REWRITE_CONTRACT.md": contract,
        }.items():
            self.assertIn("runtime smoke: not run; manual acceptance pending", doc, label)

    def test_greenfield_coherence_report_records_commit_readiness_scope(self):
        report = read(GREENFIELD_COHERENCE)

        for heading in (
            "## Current Staged Scope",
            "## Unstaged Runtime Scope",
            "## TOC And Load Order",
            "## Registry And Deleted References",
            "## Validation Evidence",
            "## Runtime Smoke Gap",
            "## Residual Risk",
        ):
            self.assertIn(heading, report)

        self.assertIn("runtime smoke: not run; manual acceptance pending", report)
        self.assertIn("static/offline commit coherence report", report)
        self.assertNotIn("not a final GREENFIELD_REWRITE completion claim", report)

    def test_greenfield_coherence_report_validation_count_matches_current_suite(self):
        report = read(GREENFIELD_COHERENCE)

        self.assertIn("387 tests OK", report)
        self.assertNotIn("371 tests OK", report)
        self.assertNotIn("370 tests OK", report)
        self.assertNotIn("369 tests OK", report)
        self.assertNotIn("368 tests OK", report)

    def test_greenfield_coherence_report_records_no_unstaged_runtime_after_full_stage(self):
        report = read(GREENFIELD_COHERENCE)

        self.assertIn("No unstaged runtime files remain in the working tree", report)
        self.assertNotIn("many unstaged runtime", report)


if __name__ == "__main__":
    unittest.main()
