import re
import subprocess
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE64_LUA = ROOT / "Raid Management Addon" / "Modules" / "Base64.lua"


class Base64ModuleTests(unittest.TestCase):
    def test_encode_decode_matches_standard_vectors(self):
        script = textwrap.dedent(
            f"""
            local addon = {{
                Database = {{}},
            }}
            _G = _G or {{}}
            package.path = package.path .. ";{str(BASE64_LUA).replace("\\", "\\\\")}"
            local chunk = assert(loadfile("{str(BASE64_LUA).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local cases = {{
                {{ "", "" }},
                {{ "f", "Zg==" }},
                {{ "fo", "Zm8=" }},
                {{ "foo", "Zm9v" }},
                {{ "foob", "Zm9vYg==" }},
                {{ "fooba", "Zm9vYmE=" }},
                {{ "foobar", "Zm9vYmFy" }},
                {{ string.char(0, 1, 2, 253, 254, 255), "AAEC/f7/" }},
            }}

            for i = 1, #cases do
                local input, encoded = cases[i][1], cases[i][2]
                local actual = addon.Base64.Encode(input)
                if actual ~= encoded then
                    error("encode mismatch " .. i .. ": " .. tostring(actual) .. " ~= " .. encoded)
                end
                local decoded = addon.Base64.Decode(encoded)
                if decoded ~= input then
                    error("decode mismatch " .. i)
                end
            end
            """
        )
        subprocess.run(["lua.cmd", "-e", script], check=True, cwd=ROOT)

    def test_implementation_does_not_build_bit_strings_per_byte(self):
        source = BASE64_LUA.read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"\bout\s*=\s*out\s*\.\.", source))


if __name__ == "__main__":
    unittest.main()
