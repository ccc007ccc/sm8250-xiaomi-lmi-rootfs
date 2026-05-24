#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOTFS_DIR=${ROOTFS_DIR:-"$REPO_ROOT/out/fedora-rootfs"}
FS_LABEL=${FS_LABEL:-fedora-rootfs}
FEDORA_USERNAME=${FEDORA_USERNAME:-lmi}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check_path() {
  [ -e "$ROOTFS_DIR/$1" ] || fail "missing $1"
}

check_absent() {
  [ ! -e "$ROOTFS_DIR/$1" ] || fail "unexpected debug file $1"
}

unit_exists() {
  UNIT="$1"
  [ -e "$ROOTFS_DIR/usr/lib/systemd/system/$UNIT" ] || [ -e "$ROOTFS_DIR/lib/systemd/system/$UNIT" ] || [ -e "$ROOTFS_DIR/etc/systemd/system/$UNIT" ]
}

check_unit() {
  UNIT="$1"
  unit_exists "$UNIT" || fail "missing unit $UNIT"
}

check_display_manager() {
  [ -e "$ROOTFS_DIR/etc/systemd/system/display-manager.service" ] && return 0
  unit_exists sddm.service && return 0
  unit_exists plasmalogin.service && return 0
  fail "missing display manager service"
}

check_ssh_password_disabled() {
  for CONF in "$ROOTFS_DIR"/etc/ssh/sshd_config.d/*.conf; do
    [ -e "$CONF" ] || continue
    grep -Eq '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication)[[:space:]]+yes([[:space:]]|$)' "$CONF" && fail "SSH password login is enabled in $CONF"
  done

  CONF="$ROOTFS_DIR/etc/ssh/sshd_config.d/99-lmi-no-password-login.conf"
  [ -r "$CONF" ] || fail "missing SSH no-password config"
  grep -q '^PasswordAuthentication no$' "$CONF" || fail "SSH password auth is not disabled"
  grep -q '^KbdInteractiveAuthentication no$' "$CONF" || fail "SSH keyboard-interactive auth is not disabled"
}

check_password_locked() {
  USERNAME="$1"
  ENTRY=$(grep "^$USERNAME:" "$ROOTFS_DIR/etc/shadow" 2>/dev/null || true)
  [ -n "$ENTRY" ] || fail "missing shadow entry for $USERNAME"
  HASH=${ENTRY#*:}
  HASH=${HASH%%:*}
  case "$HASH" in
    '!'|'*'|'!!'|!*) return 0 ;;
  esac
  fail "password is not locked for $USERNAME"
}

check_bin() {
  BIN="$1"
  [ -x "$ROOTFS_DIR/usr/bin/$BIN" ] || [ -x "$ROOTFS_DIR/usr/sbin/$BIN" ] || [ -x "$ROOTFS_DIR/sbin/$BIN" ] || fail "missing executable $BIN"
}

[ -d "$ROOTFS_DIR" ] || fail "missing rootfs dir: $ROOTFS_DIR"
check_path etc/os-release
check_path sbin/init
check_path etc/fstab
check_path etc/hostname

grep -q '^ID=fedora$' "$ROOTFS_DIR/etc/os-release" || fail "not a Fedora rootfs"
grep -q "LABEL=$FS_LABEL / ext4" "$ROOTFS_DIR/etc/fstab" || fail "fstab does not mount LABEL=$FS_LABEL as /"

check_unit NetworkManager.service
check_display_manager
check_unit firewalld.service
check_unit sshd.service
grep -q "^$FEDORA_USERNAME:" "$ROOTFS_DIR/etc/passwd" || fail "missing Fedora SSH user $FEDORA_USERNAME"
check_password_locked root
check_password_locked "$FEDORA_USERNAME"
check_ssh_password_disabled
check_bin nft

if [ "${REQUIRE_CONTAINERS:-0}" = 1 ]; then
  check_bin docker
  check_bin containerd
  check_bin runc
  check_bin crun
  check_bin lxc-start
  check_bin lxc-checkconfig
fi

check_absent usr/local/sbin/lmi-debug-keys.py
check_absent etc/systemd/system/lmi-debug-keys.service
check_absent etc/systemd/system/lmi-wifi-connect.service
check_absent etc/systemd/system/lmi-usb-gadget.service
check_absent etc/systemd/system/lmi-firstboot-report.service
check_absent etc/systemd/system/getty@tty1.service.d/autologin.conf

[ -L "$ROOTFS_DIR/etc/systemd/system/default.target" ] || fail "default.target is not a symlink"
printf 'OK: Fedora rootfs checks passed: %s\n' "$ROOTFS_DIR"
