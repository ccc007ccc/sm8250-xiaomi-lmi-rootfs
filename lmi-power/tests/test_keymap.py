import tempfile
import unittest
from pathlib import Path

from lmi_power import keymap


class KeymapTest(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(keymap.default_keymap()["power"], "toggle-backlight")
        self.assertEqual(keymap.default_keymap()["volume-up"], "brightness-up")
        self.assertEqual(keymap.default_keymap()["volume-down"], "brightness-down")

    def test_parse_ignores_invalid_entries(self):
        mapping = keymap.parse_keymap("power=backlight-off\nvolume-up=invalid\nunknown=none\n")
        self.assertEqual(mapping["power"], "backlight-off")
        self.assertEqual(mapping["volume-up"], "brightness-up")

    def test_set_key_action_persists(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "keys.conf")
            keymap.set_key_action("power", "backlight-off", path)
            self.assertEqual(keymap.load_keymap(path)["power"], "backlight-off")

    def test_reset_keymap(self):
        with tempfile.TemporaryDirectory() as temp:
            path = str(Path(temp) / "keys.conf")
            keymap.set_key_action("volume-down", "none", path)
            keymap.reset_keymap(path)
            self.assertEqual(keymap.load_keymap(path), keymap.default_keymap())


if __name__ == "__main__":
    unittest.main()
