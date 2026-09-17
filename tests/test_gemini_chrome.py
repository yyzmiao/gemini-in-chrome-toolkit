import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import gemini_chrome


class ConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.user_data = self.root / "User Data"
        self.profile = self.user_data / "Default"
        self.profile.mkdir(parents=True)
        self.chrome = self.root / "chrome.exe"
        self.chrome.write_bytes(b"")

        self.local_state = self.user_data / "Local State"
        self.local_state.write_text(
            json.dumps(
                {
                    "variations_country": "cn",
                    "variations_permanent_consistency_country": ["123.0.0.0", "cn"],
                    "intl": {"app_locale": "zh-CN"},
                    "feature": {"is_glic_eligible": False},
                }
            ),
            encoding="utf-8",
        )
        self.preferences = self.profile / "Preferences"
        self.preferences.write_text(
            json.dumps(
                {
                    "intl": {
                        "selected_languages": "zh-CN",
                        "accept_languages": "zh-CN,zh",
                    },
                    "nested": [{"is_glic_eligible": False}],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_configuration_updates_expected_fields(self) -> None:
        local_changes = gemini_chrome.configure_local_state(self.local_state, self.chrome)
        preference_changes = gemini_chrome.configure_preferences(self.preferences)

        local = gemini_chrome.load_json(self.local_state)
        preferences = gemini_chrome.load_json(self.preferences)

        self.assertEqual(local["variations_country"], "us")
        self.assertEqual(
            local["variations_permanent_consistency_country"],
            ["123.0.0.0", "us"],
        )
        self.assertEqual(local["intl"]["app_locale"], "en-US")
        self.assertTrue(local["feature"]["is_glic_eligible"])
        self.assertEqual(preferences["intl"]["selected_languages"], "en-US,en")
        self.assertEqual(preferences["intl"]["accept_languages"], "en-US,en")
        self.assertTrue(preferences["nested"][0]["is_glic_eligible"])
        self.assertEqual(local_changes, 1)
        self.assertEqual(preference_changes, 1)

    def test_backup_and_restore_round_trip(self) -> None:
        backup_base = self.root / "backups"
        original_local_state = self.local_state.read_bytes()
        original_preferences = self.preferences.read_bytes()

        with patch.object(gemini_chrome, "backup_root", return_value=backup_base):
            backup = gemini_chrome.create_backup(self.user_data)

        gemini_chrome.configure_local_state(self.local_state, self.chrome)
        gemini_chrome.configure_preferences(self.preferences)

        with patch.object(gemini_chrome, "stop_chrome"):
            gemini_chrome.restore(backup, assume_yes=True)

        self.assertEqual(self.local_state.read_bytes(), original_local_state)
        self.assertEqual(self.preferences.read_bytes(), original_preferences)

    def test_launcher_forces_new_chrome_process_with_expected_flags(self) -> None:
        content = gemini_chrome.launcher_content(self.chrome)

        self.assertIn("taskkill /IM chrome.exe /F", content)
        self.assertIn("--variations-override-country=us", content)
        self.assertIn("--disable-features=GlicCountryFiltering", content)
        self.assertIn(str(self.chrome), content)


if __name__ == "__main__":
    unittest.main()
