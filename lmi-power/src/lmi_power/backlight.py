import glob
import os
import threading
import time
from dataclasses import dataclass
from typing import Callable, Optional

LogFn = Callable[[str], None]


@dataclass(frozen=True)
class BacklightStatus:
    path: str
    brightness: int
    actual_brightness: int
    max_brightness: int
    bl_power: int
    fb_blank: Optional[int]
    forced_off: bool
    is_off: bool


class BacklightController:
    def __init__(
        self,
        root: str = "/sys/class/backlight",
        fb_root: str = "/sys/class/graphics",
        log: Optional[LogFn] = None,
        brightness_interval: float = 0.08,
        blank_interval: float = 0.25,
    ) -> None:
        self.root = root
        self.fb_root = fb_root
        self.log = log or (lambda message: None)
        self.last_brightness = 0
        self.forced_off = False
        self.brightness_interval = brightness_interval
        self.blank_interval = blank_interval
        self._display_lock = threading.RLock()
        self._last_brightness_write = 0.0
        self._last_blank_write = 0.0

    def _pace_display_write(self, attr: str, interval: float) -> None:
        if interval <= 0:
            setattr(self, attr, time.monotonic())
            return
        now = time.monotonic()
        delay = getattr(self, attr) + interval - now
        if delay > 0:
            time.sleep(delay)
        setattr(self, attr, time.monotonic())

    def _pace_brightness_write(self) -> None:
        self._pace_display_write("_last_brightness_write", self.brightness_interval)

    def _pace_blank_write(self) -> None:
        self._pace_display_write("_last_blank_write", self.blank_interval)

    def read_text(self, path: str, default: str = "") -> str:
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return default

    def read_int(self, path: str, default: int = 0) -> int:
        try:
            return int(self.read_text(path))
        except ValueError:
            return default

    def write_text(self, path: str, value: object) -> bool:
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(str(value))
            return True
        except OSError as exc:
            self.log(f"write_failed path={path} value={value} error={str(exc).replace(' ', '_')}")
            return False

    def path(self) -> Optional[str]:
        for path in sorted(glob.glob(os.path.join(self.root, "*"))):
            if os.path.exists(os.path.join(path, "brightness")) and os.path.exists(os.path.join(path, "max_brightness")):
                return path
        return None

    def fb_blank_path(self) -> Optional[str]:
        for path in sorted(glob.glob(os.path.join(self.fb_root, "fb*"))):
            blank_path = os.path.join(path, "blank")
            if os.path.exists(blank_path):
                return blank_path
        return None

    def read_fb_blank(self) -> Optional[int]:
        path = self.fb_blank_path()
        return None if path is None else self.read_int(path, 0)

    def write_fb_blank(self, value: int) -> bool:
        path = self.fb_blank_path()
        if path is None:
            return True
        return self.write_text(path, value)

    def status(self) -> Optional[BacklightStatus]:
        path = self.path()
        if not path:
            return None
        brightness = self.read_int(os.path.join(path, "brightness"), 0)
        actual = self.read_int(os.path.join(path, "actual_brightness"), brightness)
        max_brightness = max(1, self.read_int(os.path.join(path, "max_brightness"), 1))
        bl_power = self.read_int(os.path.join(path, "bl_power"), 0)
        fb_blank = self.read_fb_blank()
        is_off = self.forced_off or bl_power != 0 or brightness == 0 or actual == 0 or (fb_blank is not None and fb_blank != 0)
        return BacklightStatus(
            path=path,
            brightness=brightness,
            actual_brightness=actual,
            max_brightness=max_brightness,
            bl_power=bl_power,
            fb_blank=fb_blank,
            forced_off=self.forced_off,
            is_off=is_off,
        )

    def is_off(self, path: Optional[str] = None) -> bool:
        if path is None:
            status = self.status()
            return True if status is None else status.is_off
        bl_power = self.read_int(os.path.join(path, "bl_power"), 0)
        brightness = self.read_int(os.path.join(path, "brightness"), 0)
        actual = self.read_int(os.path.join(path, "actual_brightness"), brightness)
        fb_blank = self.read_fb_blank()
        return self.forced_off or bl_power != 0 or brightness == 0 or actual == 0 or (fb_blank is not None and fb_blank != 0)

    def set_on(self) -> bool:
        path = self.path()
        if not path:
            self.log("backlight_missing action=on")
            return False
        max_brightness = max(1, self.read_int(os.path.join(path, "max_brightness"), 1))
        target = self.last_brightness if 0 < self.last_brightness <= max_brightness else max(1, max_brightness // 2)
        with self._display_lock:
            ok = True
            fb_blank = self.read_fb_blank()
            bl_power = self.read_int(os.path.join(path, "bl_power"), 0)
            actual = self.read_int(os.path.join(path, "actual_brightness"), target)
            if fb_blank is not None and (fb_blank != 0 or actual == 0):
                self._pace_blank_write()
                ok = self.write_fb_blank(0)
            if bl_power != 0 or actual == 0:
                self._pace_blank_write()
                ok = self.write_text(os.path.join(path, "bl_power"), 0) and ok
            self._pace_brightness_write()
            ok = self.write_text(os.path.join(path, "brightness"), target) and ok
        if ok:
            self.forced_off = False
            self.last_brightness = target
            self.log(f"backlight_on path={path} brightness={target}/{max_brightness}")
        return ok

    def set_off(self) -> bool:
        path = self.path()
        if not path:
            self.log("backlight_missing action=off")
            return False
        max_brightness = max(1, self.read_int(os.path.join(path, "max_brightness"), 1))
        current = self.read_int(os.path.join(path, "brightness"), 0)
        if current > 0:
            self.last_brightness = current
        elif self.last_brightness <= 0:
            self.last_brightness = max(1, max_brightness // 2)
        with self._display_lock:
            self._pace_brightness_write()
            ok = self.write_text(os.path.join(path, "brightness"), 0)
        if ok:
            self.forced_off = True
            self.log(f"backlight_off path={path} restore={self.last_brightness}/{max_brightness}")
        return ok

    def toggle(self) -> bool:
        path = self.path()
        if not path:
            self.log("backlight_missing action=toggle")
            return False
        if self.is_off(path):
            return self.set_on()
        return self.set_off()

    def adjust(self, direction: int) -> bool:
        path = self.path()
        if not path:
            self.log("backlight_missing action=adjust")
            return False
        max_brightness = max(1, self.read_int(os.path.join(path, "max_brightness"), 1))
        current = self.read_int(os.path.join(path, "brightness"), 0)
        was_off = self.is_off(path)
        if was_off:
            current = self.last_brightness if self.last_brightness > 0 else max(1, max_brightness // 2)
        step = max(1, max_brightness // 20)
        target = max(1, min(max_brightness, current + direction * step))
        with self._display_lock:
            ok = True
            if was_off:
                self._pace_blank_write()
                ok = self.write_fb_blank(0)
                ok = self.write_text(os.path.join(path, "bl_power"), 0) and ok
            self._pace_brightness_write()
            ok = self.write_text(os.path.join(path, "brightness"), target) and ok
        if ok:
            self.forced_off = False
            self.last_brightness = target
            self.log(f"brightness_change direction={direction} brightness={target}/{max_brightness} step={step}")
        return ok

    def set_brightness(self, value: int) -> bool:
        path = self.path()
        if not path:
            self.log("backlight_missing action=brightness")
            return False
        max_brightness = max(1, self.read_int(os.path.join(path, "max_brightness"), 1))
        target = max(0, min(max_brightness, value))
        with self._display_lock:
            ok = True
            if target > 0:
                self._pace_blank_write()
                ok = self.write_fb_blank(0)
                ok = self.write_text(os.path.join(path, "bl_power"), 0) and ok
            self._pace_brightness_write()
            ok = self.write_text(os.path.join(path, "brightness"), target) and ok
        if ok:
            self.forced_off = target == 0
            if target > 0:
                self.last_brightness = target
            self.log(f"brightness_set brightness={target}/{max_brightness}")
        return ok
