import tempfile
import unittest
from pathlib import Path

from lmi_power.backlight import BacklightController


class BacklightTest(unittest.TestCase):
    def make_backlight(self):
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name) / "backlight"
        fb_root = Path(temp.name) / "graphics"
        panel = root / "panel0"
        fb0 = fb_root / "fb0"
        panel.mkdir(parents=True)
        fb0.mkdir(parents=True)
        (panel / "brightness").write_text("100", encoding="utf-8")
        (panel / "actual_brightness").write_text("100", encoding="utf-8")
        (panel / "max_brightness").write_text("200", encoding="utf-8")
        (panel / "bl_power").write_text("0", encoding="utf-8")
        (fb0 / "blank").write_text("0", encoding="utf-8")
        return temp, panel, fb0, BacklightController(root=str(root), fb_root=str(fb_root), brightness_interval=0, blank_interval=0)

    def test_toggle_off_and_on_restores_brightness(self):
        temp, panel, fb0, controller = self.make_backlight()
        self.addCleanup(temp.cleanup)
        self.assertTrue(controller.toggle())
        self.assertEqual((panel / "brightness").read_text(encoding="utf-8"), "0")
        self.assertEqual((panel / "bl_power").read_text(encoding="utf-8"), "0")
        self.assertEqual((fb0 / "blank").read_text(encoding="utf-8"), "0")
        self.assertTrue(controller.toggle())
        self.assertEqual((panel / "brightness").read_text(encoding="utf-8"), "100")
        self.assertEqual((panel / "bl_power").read_text(encoding="utf-8"), "0")
        self.assertEqual((fb0 / "blank").read_text(encoding="utf-8"), "0")

    def test_brightness_zero_counts_as_off(self):
        temp, panel, fb0, controller = self.make_backlight()
        self.addCleanup(temp.cleanup)
        (panel / "brightness").write_text("0", encoding="utf-8")
        self.assertTrue(controller.status().is_off)
        self.assertTrue(controller.toggle())
        self.assertEqual((panel / "brightness").read_text(encoding="utf-8"), "100")
        self.assertEqual((fb0 / "blank").read_text(encoding="utf-8"), "0")

    def test_actual_brightness_zero_counts_as_off(self):
        temp, panel, fb0, controller = self.make_backlight()
        self.addCleanup(temp.cleanup)
        (panel / "actual_brightness").write_text("0", encoding="utf-8")
        self.assertTrue(controller.status().is_off)
        self.assertTrue(controller.toggle())
        self.assertEqual((panel / "brightness").read_text(encoding="utf-8"), "100")

    def test_framebuffer_blank_counts_as_off(self):
        temp, panel, fb0, controller = self.make_backlight()
        self.addCleanup(temp.cleanup)
        (fb0 / "blank").write_text("4", encoding="utf-8")
        self.assertTrue(controller.status().is_off)
        self.assertTrue(controller.toggle())
        self.assertEqual((fb0 / "blank").read_text(encoding="utf-8"), "0")

    def test_adjust_wakes_when_off(self):
        temp, panel, fb0, controller = self.make_backlight()
        self.addCleanup(temp.cleanup)
        controller.set_off()
        self.assertTrue(controller.adjust(1))
        self.assertEqual((panel / "bl_power").read_text(encoding="utf-8"), "0")
        self.assertEqual((fb0 / "blank").read_text(encoding="utf-8"), "0")
        self.assertGreater(int((panel / "brightness").read_text(encoding="utf-8")), 0)


if __name__ == "__main__":
    unittest.main()
