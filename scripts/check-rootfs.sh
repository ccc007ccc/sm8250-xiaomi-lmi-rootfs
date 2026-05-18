#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOTFS_DIR=${ROOTFS_DIR:-"$REPO_ROOT/out/rootfs"}
IMAGE=${IMAGE:-"$REPO_ROOT/out/ubuntu-24.04-arm64-console.ext4"}

fail() {
  printf 'check failed: %s\n' "$*" >&2
  exit 1
}

[ -d "$ROOTFS_DIR" ] || fail "missing rootfs dir: $ROOTFS_DIR"
[ -e "$ROOTFS_DIR/sbin/init" ] || fail "missing /sbin/init"
[ -e "$ROOTFS_DIR/lib/systemd/systemd" ] || fail "missing systemd"
grep -q '^LABEL=ubuntu-rootfs / ext4 defaults,noatime 0 1$' "$ROOTFS_DIR/etc/fstab" || fail "fstab root entry mismatch"
[ -e "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" ] || fail "missing tty1 autologin override"
[ -L "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/lmi-firstboot-report.service" ] || fail "missing first boot report service link"
[ -x "$ROOTFS_DIR/usr/local/sbin/lmi-console-report" ] || fail "missing console report helper"
[ -L "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/lmi-console-report.service" ] || fail "missing console report service link"
[ -x "$ROOTFS_DIR/usr/local/sbin/lmi-usb-gadget" ] || fail "missing usb gadget helper"
[ ! -e "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/lmi-usb-gadget.service" ] || fail "usb gadget service should not be enabled"
[ -L "$ROOTFS_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service" ] || fail "missing ttyGS0 getty link"
[ -e "$ROOTFS_DIR/etc/lmi/no-autoreboot" ] || fail "missing no-autoreboot marker"

if [ -e "$IMAGE" ]; then
  e2fsck -fn "$IMAGE"
  tune2fs -l "$IMAGE" | grep -q '^Filesystem volume name:[[:space:]]*ubuntu-rootfs$' || fail "image label mismatch"
fi

printf 'rootfs checks passed\n'
