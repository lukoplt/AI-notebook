import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "Tests/fixtures/contracts"
NAMES = ("presets", "limits", "probe", "options", "routing", "systems", "store", "errors")


class ProviderFixturesTests(unittest.TestCase):
    def test_complete_envelopes(self):
        for name in NAMES:
            data = json.loads((ROOT / f"provider-{name}-v1.json").read_text())
            self.assertEqual(data["contract"], f"provider-{name}")
            self.assertEqual(data["version"], 1)
            names = [case["name"] for case in data["cases"]]
            self.assertTrue(names)
            self.assertEqual(len(names), len(set(names)))

    def test_probe_matrix_and_presets(self):
        probes = json.loads((ROOT / "provider-probe-v1.json").read_text())["cases"]
        self.assertEqual(len(probes), 55)
        self.assertTrue(all(not x["generationVerified"] for x in probes))
        presets = json.loads((ROOT / "provider-presets-v1.json").read_text())["cases"]
        self.assertEqual([x["name"] for x in presets],
                         ["lmstudio", "openrouter", "vllm", "groq", "mistral", "together", "custom"])


if __name__ == "__main__":
    unittest.main()
