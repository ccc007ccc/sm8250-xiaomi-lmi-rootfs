#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR=${OUT_DIR:-"$REPO_ROOT/out"}
ROOTFS_DIR=${ROOTFS_DIR:-"$OUT_DIR/rootfs"}
SUITE=${SUITE:-noble}
ARCH=${ARCH:-arm64}
MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
FORCE=${FORCE:-0}
PACKAGES=${PACKAGES:-systemd-sysv udev dbus login bash util-linux e2fsprogs procps iproute2 kmod sudo ca-certificates linux-firmware pciutils iw rfkill wireless-regdb bluez bluetooth wpasupplicant openssh-server systemd-resolved python3 libdrm2 libgbm1 libegl1 libgles2 libgl1-mesa-dri mesa-utils kmscube libdrm-tests drm-info}
FIRMWARE_SRC_DIR=${FIRMWARE_SRC_DIR:-"$REPO_ROOT/local/firmware"}
LOCAL_ENV=${LOCAL_ENV:-"$REPO_ROOT/local/rootfs.env"}
SSH_AUTHORIZED_KEYS=${SSH_AUTHORIZED_KEYS:-"$REPO_ROOT/local/authorized_keys"}
WIFI_COUNTRY=${WIFI_COUNTRY:-CN}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

if [ -e "$LOCAL_ENV" ]; then
  . "$LOCAL_ENV"
fi

unset http_proxy https_proxy ftp_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY

require_cmd debootstrap
require_cmd qemu-aarch64-static
require_cmd chroot
require_cmd mount
require_cmd umount
require_cmd mknod
require_cmd ln
require_cmd awk
require_cmd sort
require_cmd install
require_cmd sha256sum
require_cmd stat

WORK_DIR="$ROOTFS_DIR.tmp"

if [ -e "$ROOTFS_DIR" ] && [ "$FORCE" != 1 ]; then
  printf 'rootfs already exists: %s\nset FORCE=1 to rebuild\n' "$ROOTFS_DIR" >&2
  exit 1
fi

mounts_under() {
  TARGET="$1"
  awk -v target="$TARGET" '$5 == target || index($5, target "/") == 1 { print $5 }' /proc/self/mountinfo
}

cleanup_mounts() {
  RC=0
  set +e
  mounts_under "$WORK_DIR" | sort -r | while IFS= read -r MP; do
    umount -R "$MP" || umount -l "$MP" || RC=1
  done
  set -e
  return "$RC"
}

assert_no_mounts() {
  TARGET="$1"
  MOUNTS=$(mounts_under "$TARGET")
  if [ -n "$MOUNTS" ]; then
    printf '%s\n' "$MOUNTS"
    printf 'refusing to modify mounted rootfs path: %s\n' "$TARGET" >&2
    exit 1
  fi
}

trap 'cleanup_mounts || true' EXIT

assert_no_mounts "$WORK_DIR"
assert_no_mounts "$ROOTFS_DIR"
rm -rf "$WORK_DIR"
if [ "$FORCE" = 1 ]; then
  rm -rf "$ROOTFS_DIR"
fi
mkdir -p "$OUT_DIR"

debootstrap --arch="$ARCH" --foreign --variant=minbase "$SUITE" "$WORK_DIR" "$MIRROR"
install -m 0755 "$(command -v qemu-aarch64-static)" "$WORK_DIR/usr/bin/qemu-aarch64-static"
cp /etc/resolv.conf "$WORK_DIR/etc/resolv.conf"

mount -t proc proc "$WORK_DIR/proc"
mount -t sysfs sysfs "$WORK_DIR/sys"
mount -t tmpfs tmpfs "$WORK_DIR/dev"
mkdir -p "$WORK_DIR/dev/pts" "$WORK_DIR/dev/shm" "$WORK_DIR/run"
mknod -m 666 "$WORK_DIR/dev/null" c 1 3
mknod -m 666 "$WORK_DIR/dev/zero" c 1 5
mknod -m 666 "$WORK_DIR/dev/full" c 1 7
mknod -m 666 "$WORK_DIR/dev/random" c 1 8
mknod -m 666 "$WORK_DIR/dev/urandom" c 1 9
mknod -m 666 "$WORK_DIR/dev/tty" c 5 0
mknod -m 600 "$WORK_DIR/dev/console" c 5 1
mknod -m 666 "$WORK_DIR/dev/ptmx" c 5 2
ln -sf /proc/self/fd "$WORK_DIR/dev/fd"
ln -sf /proc/self/fd/0 "$WORK_DIR/dev/stdin"
ln -sf /proc/self/fd/1 "$WORK_DIR/dev/stdout"
ln -sf /proc/self/fd/2 "$WORK_DIR/dev/stderr"
mount -t devpts devpts "$WORK_DIR/dev/pts"
mount -t tmpfs tmpfs "$WORK_DIR/run"

run_chroot() {
  env -u http_proxy -u https_proxy -u ftp_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u FTP_PROXY -u ALL_PROXY -u NO_PROXY \
    chroot "$WORK_DIR" /usr/bin/qemu-aarch64-static /bin/sh -c "$*"
}

run_chroot '/debootstrap/debootstrap --second-stage'

cat > "$WORK_DIR/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR $SUITE-updates main restricted universe multiverse
deb $MIRROR $SUITE-security main restricted universe multiverse
EOF

cat > "$WORK_DIR/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$WORK_DIR/usr/sbin/policy-rc.d"

run_chroot 'apt-get update'
run_chroot "env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PACKAGES"

install_firmware() {
  MANIFEST="$OUT_DIR/firmware-manifest.txt"
  rm -f "$MANIFEST"

  if [ ! -d "$FIRMWARE_SRC_DIR" ]; then
    printf 'firmware source not found, skipping: %s\n' "$FIRMWARE_SRC_DIR"
    return 0
  fi

  FW_DIR="$WORK_DIR/usr/lib/firmware"
  mkdir -p "$FW_DIR"
  (
    cd "$FIRMWARE_SRC_DIR"
    find . -type f | LC_ALL=C sort
  ) | while IFS= read -r REL; do
    REL=${REL#./}
    install -D -m 0644 "$FIRMWARE_SRC_DIR/$REL" "$FW_DIR/$REL"
  done

  ATH11K_DIR="$FW_DIR/ath11k/QCA6390/hw2.0"
  if [ -e "$ATH11K_DIR/amss20.bin" ] && [ ! -e "$ATH11K_DIR/amss.bin" ]; then
    cp -a "$ATH11K_DIR/amss20.bin" "$ATH11K_DIR/amss.bin"
  fi
  if [ -e "$ATH11K_DIR/bdwlan.elf" ] && [ ! -e "$ATH11K_DIR/board.bin" ]; then
    cp -a "$ATH11K_DIR/bdwlan.elf" "$ATH11K_DIR/board.bin"
  fi

  (
    cd "$FW_DIR"
    find . -type f | LC_ALL=C sort
  ) | while IFS= read -r REL; do
    REL=${REL#./}
    SIZE=$(stat -c %s "$FW_DIR/$REL")
    SHA=$(sha256sum "$FW_DIR/$REL" | awk '{ print $1 }')
    printf '%s  %s  %s\n' "$SHA" "$SIZE" "$REL"
  done > "$MANIFEST"
}

install_firmware

install_lmi_tools() {
  install -D -m 0755 "$REPO_ROOT/files/usr/local/bin/lmi-touch-refresh-test" \
    "$WORK_DIR/usr/local/bin/lmi-touch-refresh-test"
  install -D -m 0755 "$REPO_ROOT/files/usr/local/bin/lmi-sahara-image34-loader" \
    "$WORK_DIR/usr/local/bin/lmi-sahara-image34-loader"
  install -D -m 0755 "$REPO_ROOT/files/usr/local/bin/lmi-sahara-loader" \
    "$WORK_DIR/usr/local/bin/lmi-sahara-loader"
  install -D -m 0755 "$REPO_ROOT/files/usr/local/sbin/lmi-sahara-image34-test" \
    "$WORK_DIR/usr/local/sbin/lmi-sahara-image34-test"
  install -D -m 0755 "$REPO_ROOT/files/usr/local/sbin/lmi-sahara-test" \
    "$WORK_DIR/usr/local/sbin/lmi-sahara-test"
  mkdir -p "$WORK_DIR/usr/local/lib/lmi-power"
  rm -rf "$WORK_DIR/usr/local/lib/lmi-power/lmi_power"
  cp -a "$REPO_ROOT/lmi-power/src/lmi_power" "$WORK_DIR/usr/local/lib/lmi-power/lmi_power"
  find "$WORK_DIR/usr/local/lib/lmi-power/lmi_power" -type d -name __pycache__ -prune -exec rm -rf {} +
  find "$WORK_DIR/usr/local/lib/lmi-power/lmi_power" -type d -exec chmod 0755 {} +
  find "$WORK_DIR/usr/local/lib/lmi-power/lmi_power" -type f -exec chmod 0644 {} +
  install -D -m 0755 "$REPO_ROOT/files/usr/local/bin/lmi-power" \
    "$WORK_DIR/usr/local/bin/lmi-power"
  install -D -m 0755 "$REPO_ROOT/files/usr/local/sbin/lmi-powerd" \
    "$WORK_DIR/usr/local/sbin/lmi-powerd"
  install -D -m 0755 "$REPO_ROOT/files/usr/local/sbin/lmi-power-keysd" \
    "$WORK_DIR/usr/local/sbin/lmi-power-keysd"
  install -D -m 0644 "$REPO_ROOT/files/etc/systemd/system/lmi-powerd.service" \
    "$WORK_DIR/etc/systemd/system/lmi-powerd.service"
  install -D -m 0644 "$REPO_ROOT/files/etc/systemd/system/lmi-power-keysd.service" \
    "$WORK_DIR/etc/systemd/system/lmi-power-keysd.service"
  install -D -m 0644 "$REPO_ROOT/files/etc/lmi-power/keys.conf" \
    "$WORK_DIR/etc/lmi-power/keys.conf"
}

install_lmi_tools

configure_networking() {
  mkdir -p "$WORK_DIR/etc/systemd/network"
  cat > "$WORK_DIR/etc/systemd/network/20-wlan.network" <<'EOF'
[Match]
Name=wlan* wlp*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
RouteMetric=20
EOF

  if [ -n "${WIFI_SSID:-}" ]; then
    [ -n "${WIFI_PSK:-}" ] || {
      printf 'WIFI_PSK is required when WIFI_SSID is set\n' >&2
      exit 1
    }
    mkdir -p "$WORK_DIR/etc/wpa_supplicant"
    TMP_CONF="$WORK_DIR/etc/wpa_supplicant/lmi-wifi.conf.tmp"
    {
      printf 'ctrl_interface=DIR=/run/wpa_supplicant\n'
      printf 'update_config=1\n'
      printf 'country=%s\n\n' "$WIFI_COUNTRY"
      printf '%s\n' "$WIFI_PSK" | chroot "$WORK_DIR" /usr/bin/qemu-aarch64-static /usr/bin/wpa_passphrase "$WIFI_SSID" | grep -v '^[[:space:]]*#psk='
    } > "$TMP_CONF"
    install -m 0600 "$TMP_CONF" "$WORK_DIR/etc/wpa_supplicant/lmi-wifi.conf"
    rm -f "$TMP_CONF"
  fi

  ln -sf /run/systemd/resolve/stub-resolv.conf "$WORK_DIR/etc/resolv.conf"
}

install_ssh_authorized_keys() {
  mkdir -p "$WORK_DIR/etc/ssh/sshd_config.d"
  cat > "$WORK_DIR/etc/ssh/sshd_config.d/lmi.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF

  mkdir -p "$WORK_DIR/etc/systemd/system/bluetooth.service.d"
  cat > "$WORK_DIR/etc/systemd/system/bluetooth.service.d/lmi.conf" <<'EOF'
[Unit]
After=lmi-wireless-reprobe.service
EOF

  if [ -e "$SSH_AUTHORIZED_KEYS" ]; then
    install -d -m 0700 "$WORK_DIR/root/.ssh"
    install -m 0600 "$SSH_AUTHORIZED_KEYS" "$WORK_DIR/root/.ssh/authorized_keys"
  else
    printf 'ssh authorized_keys not found, key login will be unavailable: %s\n' "$SSH_AUTHORIZED_KEYS"
  fi
}

configure_networking
install_ssh_authorized_keys

printf 'lmi-ubuntu\n' > "$WORK_DIR/etc/hostname"
cat > "$WORK_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 lmi-ubuntu

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > "$WORK_DIR/etc/fstab" <<'EOF'
LABEL=ubuntu-rootfs / ext4 defaults,noatime 0 1
EOF

mkdir -p "$WORK_DIR/etc/systemd/logind.conf.d"
cat > "$WORK_DIR/etc/systemd/logind.conf.d/10-lmi-power-key.conf" <<'EOF'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
EOF

mkdir -p "$WORK_DIR/etc/systemd/system/getty@tty1.service.d"
cat > "$WORK_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

cat > "$WORK_DIR/usr/local/sbin/lmi-firstboot-report" <<'EOF'
#!/bin/sh
OUT=/dev/tty0
[ -e "$OUT" ] || OUT=/dev/console
{
  echo 'LMI Ubuntu 24.04 console rootfs'
  uname -a
  findmnt /
  df -h /
  systemctl --no-pager --failed || true
} > "$OUT" 2>&1 || true
EOF
chmod 0755 "$WORK_DIR/usr/local/sbin/lmi-firstboot-report"

cat > "$WORK_DIR/etc/systemd/system/lmi-firstboot-report.service" <<'EOF'
[Unit]
Description=LMI first boot console report
After=local-fs.target systemd-remount-fs.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lmi-firstboot-report

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORK_DIR/usr/local/sbin/lmi-console-report" <<'EOF'
#!/bin/sh
set +e

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/lmi-console-report.log
OUT=/dev/tty0
[ -e "$OUT" ] || OUT=/dev/console
mkdir -p /var/log /run/lmi

emit() {
  MSG="LMI_UBUNTU $*"
  printf '%s\n' "$MSG" >> "$LOG"
  printf '%s\n' "$MSG" > "$OUT" 2>/dev/null || true
  [ -e /dev/pmsg0 ] && printf '%s\n' "$MSG" > /dev/pmsg0 2>/dev/null || true
}

run() {
  emit "cmd_begin $*"
  "$@" >> "$LOG" 2>&1
  RC=$?
  tail -n 20 "$LOG" > "$OUT" 2>/dev/null || true
  emit "cmd_end rc=$RC $*"
}

emit "report_start"
emit "kernel=$(uname -a)"
emit "cmdline=$(cat /proc/cmdline 2>/dev/null)"
run findmnt /
run df -h /
run lsblk
run blkid
run ip addr

ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null)
ROOT_DEV=$ROOT_SRC
if [ -z "$ROOT_DEV" ] || [ ! -b "$ROOT_DEV" ]; then
  ROOT_DEV=$(findfs LABEL=ubuntu-rootfs 2>/dev/null || true)
fi
ROOT_REAL=
if [ -n "$ROOT_DEV" ]; then
  ROOT_REAL=$(readlink -f "$ROOT_DEV" 2>/dev/null || printf '%s' "$ROOT_DEV")
fi
emit "root_source=$ROOT_SRC root_dev=$ROOT_DEV root_real=$ROOT_REAL"
case "$ROOT_REAL" in
  /dev/sda34|/dev/block/sda34|/dev/sda35|/dev/block/sda35)
    emit "resize2fs_begin dev=$ROOT_DEV"
    resize2fs "$ROOT_DEV" >> "$LOG" 2>&1
    emit "resize2fs_end rc=$?"
    run df -h /
    ;;
  *)
    emit "resize2fs_skip unexpected_root=$ROOT_REAL"
    ;;
esac

run sh -c "dmesg | grep -Ei 'ufshcd|sda3[45]|linuxroot|ubuntu-rootfs|ext4|systemd|drm|dsi|panel|error|fail|warn' | tail -n 160"

if [ -e /etc/lmi/no-autoreboot ]; then
  emit "autoreboot_disabled marker=/etc/lmi/no-autoreboot"
fi

emit "report_done"
exit 0
EOF
chmod 0755 "$WORK_DIR/usr/local/sbin/lmi-console-report"

cat > "$WORK_DIR/etc/systemd/system/lmi-console-report.service" <<'EOF'
[Unit]
Description=LMI no-input console diagnostics
After=local-fs.target systemd-remount-fs.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/lmi-console-report
StandardInput=null
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORK_DIR/usr/local/sbin/lmi-usb-gadget" <<'EOF'
#!/bin/sh
set +e

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/lmi-usb-gadget.log
OUT=/dev/tty0
[ -e "$OUT" ] || OUT=/dev/console
mkdir -p /var/log

emit() {
  MSG="LMI_USB $*"
  printf '%s\n' "$MSG" >> "$LOG"
  printf '%s\n' "$MSG" > "$OUT" 2>/dev/null || true
  [ -e /dev/pmsg0 ] && printf '%s\n' "$MSG" > /dev/pmsg0 2>/dev/null || true
}

unbind_gadget() {
  OLD_G="$1"
  [ -d "$OLD_G" ] || return 0
  OLD_UDC=$(cat "$OLD_G/UDC" 2>/dev/null)
  [ -n "$OLD_UDC" ] || return 0

  printf '' > "$OLD_G/UDC" 2>>"$LOG" || {
    emit "unbind_failed gadget=${OLD_G##*/} udc=$OLD_UDC"
    return 1
  }
  emit "unbound ${OLD_G##*/} from $OLD_UDC"
}

wait_udc_free() {
  TARGET="$1"
  I=0
  while [ "$I" -lt 20 ]; do
    BUSY=0
    for OLD_G in /sys/kernel/config/usb_gadget/*; do
      [ -e "$OLD_G/UDC" ] || continue
      [ "$(cat "$OLD_G/UDC" 2>/dev/null)" = "$TARGET" ] && BUSY=1
    done
    [ "$BUSY" = 0 ] && return 0
    sleep 1
    I=$((I + 1))
  done
  return 1
}

mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config 2>>"$LOG"
[ -d /sys/kernel/config/usb_gadget ] || {
  emit "no_configfs_usb_gadget"
  exit 0
}

modprobe libcomposite 2>>"$LOG" || true
modprobe usb_f_acm 2>>"$LOG" || true
modprobe usb_f_rndis 2>>"$LOG" || true

I=0
UDC=
while [ "$I" -lt 60 ]; do
  UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
  [ -n "$UDC" ] && break
  sleep 1
  I=$((I + 1))
done

if [ -z "$UDC" ]; then
  emit "no_udc"
  exit 0
fi

unbind_gadget /sys/kernel/config/usb_gadget/lmi_ubuntu || true
G=/sys/kernel/config/usb_gadget/lmi
unbind_gadget "$G" || true
wait_udc_free "$UDC" || emit "udc_still_busy udc=$UDC"

mkdir -p "$G"
printf '0x18d1' > "$G/idVendor"
printf '0x4ee7' > "$G/idProduct"
printf '0x0200' > "$G/bcdUSB"
printf '0x0100' > "$G/bcdDevice"
mkdir -p "$G/strings/0x409"
printf 'lmi-mainline-ubuntu' > "$G/strings/0x409/serialnumber"
printf 'Xiaomi' > "$G/strings/0x409/manufacturer"
printf 'LMI Ubuntu debug gadget' > "$G/strings/0x409/product"
mkdir -p "$G/configs/c.1/strings/0x409"
printf 'ACM serial + RNDIS debug' > "$G/configs/c.1/strings/0x409/configuration"
printf '250' > "$G/configs/c.1/MaxPower"

mkdir -p "$G/functions/acm.usb0"
ln -sf "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"

if mkdir -p "$G/functions/rndis.usb0" 2>>"$LOG"; then
  printf '02:00:00:00:00:01' > "$G/functions/rndis.usb0/dev_addr" 2>/dev/null || true
  printf '02:00:00:00:00:02' > "$G/functions/rndis.usb0/host_addr" 2>/dev/null || true
  if [ -d "$G/functions/rndis.usb0/os_desc/interface.rndis" ]; then
    printf 'RNDIS' > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id" 2>/dev/null || true
    printf '5162001' > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id" 2>/dev/null || true
  fi
  ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
  mkdir -p "$G/os_desc"
  printf '1' > "$G/os_desc/use" 2>/dev/null || true
  printf '0xcd' > "$G/os_desc/b_vendor_code" 2>/dev/null || true
  printf 'MSFT100' > "$G/os_desc/qw_sign" 2>/dev/null || true
  ln -sf "$G/configs/c.1" "$G/os_desc/c.1" 2>/dev/null || true
fi

printf '%s' "$UDC" > "$G/UDC" 2>>"$LOG" || {
  emit "bind_failed udc=$UDC"
  exit 0
}

I=0
while [ "$I" -lt 20 ]; do
  if ip link show usb0 >/dev/null 2>&1; then
    ip addr add 192.168.7.2/24 dev usb0 2>/dev/null || true
    ip link set usb0 up 2>/dev/null || true
    break
  fi
  sleep 1
  I=$((I + 1))
done

systemctl start serial-getty@ttyGS0.service 2>>"$LOG" || true
emit "ready udc=$UDC serial=/dev/ttyGS0 addr=192.168.7.2/24"
EOF
chmod 0755 "$WORK_DIR/usr/local/sbin/lmi-usb-gadget"

cat > "$WORK_DIR/etc/systemd/system/lmi-usb-gadget.service" <<'EOF'
[Unit]
Description=LMI USB gadget debug console
After=local-fs.target sys-kernel-config.mount systemd-udevd.service
Wants=sys-kernel-config.mount
Before=serial-getty@ttyGS0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/lmi-usb-gadget
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORK_DIR/usr/local/sbin/lmi-firmware-import" <<'EOF'
#!/bin/sh
set +e

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/lmi-firmware-import.log
ATH_DIR=/usr/lib/firmware/ath11k/QCA6390/hw2.0
QCA_DIR=/usr/lib/firmware/qca
mkdir -p /var/log "$ATH_DIR" "$QCA_DIR" /mnt/lmi-firmware-modem /mnt/lmi-firmware-bt

emit() {
  MSG="LMI_FIRMWARE $*"
  printf '%s\n' "$MSG" >> "$LOG"
  [ -e /dev/pmsg0 ] && printf '%s\n' "$MSG" > /dev/pmsg0 2>/dev/null || true
}

find_part() {
  LABEL=$1
  for DEV in "/dev/disk/by-partlabel/$LABEL" "/dev/block/by-name/$LABEL"; do
    [ -e "$DEV" ] && readlink -f "$DEV" && return 0
  done
  blkid -t "PARTLABEL=$LABEL" -o device 2>/dev/null | head -n 1
}

copy_wifi() {
  MODEM_DEV=$(find_part modem)
  [ -n "$MODEM_DEV" ] || {
    emit "wifi_skip missing_modem_part"
    return 0
  }
  mountpoint -q /mnt/lmi-firmware-modem || mount -o ro "$MODEM_DEV" /mnt/lmi-firmware-modem 2>>"$LOG"
  SRC=/mnt/lmi-firmware-modem/image/qca6390
  [ -d "$SRC" ] || {
    emit "wifi_skip missing_qca6390_dir"
    return 0
  }
  cp -a "$SRC/." "$ATH_DIR/" 2>>"$LOG"
  [ -e "$ATH_DIR/amss20.bin" ] && cp -a "$ATH_DIR/amss20.bin" "$ATH_DIR/amss.bin"
  [ -e "$ATH_DIR/bdwlan.elf" ] && cp -a "$ATH_DIR/bdwlan.elf" "$ATH_DIR/board.bin"
  emit "wifi_imported src=$MODEM_DEV"
}

copy_bt() {
  BT_DEV=$(find_part bluetooth)
  [ -n "$BT_DEV" ] || {
    emit "bt_skip missing_bluetooth_part"
    return 0
  }
  mountpoint -q /mnt/lmi-firmware-bt || mount -o ro "$BT_DEV" /mnt/lmi-firmware-bt 2>>"$LOG"
  SRC=/mnt/lmi-firmware-bt/image
  [ -d "$SRC" ] || {
    emit "bt_skip missing_bt_image_dir"
    return 0
  }
  cp -a "$SRC/." "$QCA_DIR/" 2>>"$LOG"
  emit "bt_imported src=$BT_DEV"
}

copy_wifi
copy_bt
(
  cd /usr/lib/firmware
  find ath11k/QCA6390/hw2.0 qca -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r REL; do
    SIZE=$(stat -c %s "$REL" 2>/dev/null)
    SHA=$(sha256sum "$REL" 2>/dev/null | awk '{ print $1 }')
    [ -n "$SIZE" ] && [ -n "$SHA" ] && printf '%s  %s  %s\n' "$SHA" "$SIZE" "$REL"
  done
) > /usr/lib/firmware/lmi-firmware-manifest.txt
emit "done"
EOF
chmod 0755 "$WORK_DIR/usr/local/sbin/lmi-firmware-import"

cat > "$WORK_DIR/etc/systemd/system/lmi-firmware-import.service" <<'EOF'
[Unit]
Description=LMI import firmware from stock partitions
After=local-fs.target
Before=lmi-wireless-reprobe.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/lmi-firmware-import
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORK_DIR/usr/local/sbin/lmi-wireless-reprobe" <<'EOF'
#!/bin/sh
set +e

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/lmi-wireless-reprobe.log
PERSIST_MOUNT=/mnt/lmi-persist
WLAN_MAC=
BT_MAC=
mkdir -p /var/log "$PERSIST_MOUNT"

emit() {
  MSG="LMI_WIRELESS $*"
  printf '%s\n' "$MSG" >> "$LOG"
  [ -e /dev/pmsg0 ] && printf '%s\n' "$MSG" > /dev/pmsg0 2>/dev/null || true
}

find_part() {
  LABEL=$1
  for DEV in "/dev/disk/by-partlabel/$LABEL" "/dev/block/by-name/$LABEL"; do
    [ -e "$DEV" ] && readlink -f "$DEV" && return 0
  done
  blkid -t "PARTLABEL=$LABEL" -o device 2>/dev/null | head -n 1
}

format_mac() {
  HEX=$1
  printf '%s:%s:%s:%s:%s:%s' \
    "$(printf '%s' "$HEX" | cut -c1-2)" \
    "$(printf '%s' "$HEX" | cut -c3-4)" \
    "$(printf '%s' "$HEX" | cut -c5-6)" \
    "$(printf '%s' "$HEX" | cut -c7-8)" \
    "$(printf '%s' "$HEX" | cut -c9-10)" \
    "$(printf '%s' "$HEX" | cut -c11-12)"
}

load_wireless_identity() {
  PERSIST_DEV=$(find_part persist)
  [ -n "$PERSIST_DEV" ] || {
    emit "identity_skip missing_persist_part"
    return 0
  }

  mountpoint -q "$PERSIST_MOUNT" || mount -o ro "$PERSIST_DEV" "$PERSIST_MOUNT" 2>>"$LOG"
  MAC_FILE="$PERSIST_MOUNT/wlan_mac.bin"
  [ -r "$MAC_FILE" ] || {
    emit "identity_skip missing_wlan_mac_bin"
    umount "$PERSIST_MOUNT" 2>/dev/null || true
    return 0
  }

  MAC_HEX=$(tr -d '\000\r\n' < "$MAC_FILE" | sed -n 's/.*=\([0-9A-Fa-f]\{12\}\).*/\1/p' | head -n 1 | tr 'A-F' 'a-f')
  if [ ${#MAC_HEX} -eq 12 ] && [ "$MAC_HEX" != "000000000000" ] && [ "$MAC_HEX" != "ffffffffffff" ]; then
    WLAN_MAC=$(format_mac "$MAC_HEX")
    PREFIX=$(printf '%s' "$MAC_HEX" | cut -c1-10)
    LAST_HEX=$(printf '%s' "$MAC_HEX" | cut -c11-12)
    LAST=$((0x$LAST_HEX + 1))
    [ "$LAST" -gt 255 ] && LAST=0
    BT_HEX=$(printf '%s%02x' "$PREFIX" "$LAST")
    BT_MAC=$(format_mac "$BT_HEX")
    emit "identity_loaded wlan_mac=$WLAN_MAC bt_addr=$BT_MAC"
  else
    emit "identity_skip invalid_wlan_mac_bin"
  fi

  umount "$PERSIST_MOUNT" 2>/dev/null || true
}

fallback_wifi_mac() {
  MID=$(tr -dc '0-9a-f' < /etc/machine-id 2>/dev/null | head -c 10)
  [ ${#MID} -eq 10 ] || MID=0063910001
  printf '02:%s:%s:%s:%s:%s' \
    "$(printf '%s' "$MID" | cut -c1-2)" \
    "$(printf '%s' "$MID" | cut -c3-4)" \
    "$(printf '%s' "$MID" | cut -c5-6)" \
    "$(printf '%s' "$MID" | cut -c7-8)" \
    "$(printf '%s' "$MID" | cut -c9-10)"
}

fix_wifi_mac() {
  IFACE=$1
  ADDR=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
  [ -n "$ADDR" ] || return 0

  if [ -n "$WLAN_MAC" ]; then
    [ "$ADDR" = "$WLAN_MAC" ] && return 0
    MAC=$WLAN_MAC
  else
    [ "$ADDR" = "00:00:00:00:00:00" ] || return 0
    MAC=$(fallback_wifi_mac)
  fi

  ip link set dev "$IFACE" down 2>>"$LOG" || true
  ip link set dev "$IFACE" address "$MAC" 2>>"$LOG" && emit "wifi_mac_set iface=$IFACE mac=$MAC"
}

wait_wifi_iface() {
  DEVPATH=$1
  I=0
  while [ "$I" -lt 30 ]; do
    for NETPATH in "$DEVPATH"/net/*; do
      [ -e "$NETPATH/address" ] || continue
      IFACE=${NETPATH##*/}
      fix_wifi_mac "$IFACE"
      ip link set "$IFACE" up >>"$LOG" 2>&1 || true
      emit "wifi_iface_ready iface=$IFACE addr=$(cat /sys/class/net/$IFACE/address 2>/dev/null)"
      return 0
    done
    sleep 1
    I=$((I + 1))
  done
  emit "wifi_iface_timeout dev=${DEVPATH##*/}"
}

bind_wifi() {
  [ -e /usr/lib/firmware/ath11k/QCA6390/hw2.0/amss.bin ] || {
    emit "wifi_skip missing_amss"
    return 0
  }

  for DEVPATH in /sys/bus/pci/devices/*; do
    [ -e "$DEVPATH/vendor" ] || continue
    [ "$(cat "$DEVPATH/vendor" 2>/dev/null)" = "0x17cb" ] || continue
    [ "$(cat "$DEVPATH/device" 2>/dev/null)" = "0x1101" ] || continue
    SLOT=${DEVPATH##*/}
    if [ ! -e "$DEVPATH/driver" ] && [ -e /sys/bus/pci/drivers/ath11k_pci/bind ]; then
      echo "$SLOT" > /sys/bus/pci/drivers/ath11k_pci/bind 2>>"$LOG"
      emit "wifi_bind slot=$SLOT"
    fi
    wait_wifi_iface "$DEVPATH"
  done
}

bt_is_raw() {
  hciconfig hci0 2>/dev/null | grep -q RAW
}

set_bt_public_addr() {
  [ -n "$BT_MAC" ] || return 1
  command -v btmgmt >/dev/null 2>&1 || return 1
  btmgmt -i 0 public-addr "$BT_MAC" >>"$LOG" 2>&1 && {
    emit "bt_addr_set hci0=$BT_MAC"
    return 0
  }
  return 1
}

bind_bt() {
  [ -e /usr/lib/firmware/qca/htbtfw20.tlv ] || {
    emit "bt_skip missing_htbtfw20"
    return 0
  }
  [ -e /sys/bus/serial/drivers/hci_uart_qca/bind ] || return 0

  if [ -e /sys/class/bluetooth/hci0 ]; then
    if bt_is_raw; then
      set_bt_public_addr && return 0
    else
      emit "bt_skip hci0_configured"
      return 0
    fi
  fi

  if [ -e /sys/bus/serial/devices/serial0-0/driver/unbind ]; then
    echo serial0-0 > /sys/bus/serial/devices/serial0-0/driver/unbind 2>>"$LOG"
    sleep 1
  fi
  echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/bind 2>>"$LOG"
  emit "bt_rebind serial0-0"
  I=0
  while [ "$I" -lt 10 ]; do
    [ -e /sys/class/bluetooth/hci0 ] && set_bt_public_addr && return 0
    sleep 1
    I=$((I + 1))
  done
}

load_wireless_identity
bind_wifi
bind_bt
emit "done"
EOF
chmod 0755 "$WORK_DIR/usr/local/sbin/lmi-wireless-reprobe"

cat > "$WORK_DIR/etc/systemd/system/lmi-wireless-reprobe.service" <<'EOF'
[Unit]
Description=LMI wireless firmware reprobe
After=local-fs.target lmi-firmware-import.service
Wants=lmi-firmware-import.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/lmi-wireless-reprobe
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

cat > "$WORK_DIR/usr/local/sbin/lmi-wifi-connect" <<'EOF'
#!/bin/sh
set +e

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/lmi-wifi-connect.log
CONF=/etc/wpa_supplicant/lmi-wifi.conf
mkdir -p /var/log /run/wpa_supplicant

emit() {
  MSG="LMI_WIFI $*"
  printf '%s\n' "$MSG" >> "$LOG"
  [ -e /dev/pmsg0 ] && printf '%s\n' "$MSG" > /dev/pmsg0 2>/dev/null || true
}

[ -e "$CONF" ] || {
  emit "skip missing_config"
  exit 0
}

systemctl start systemd-networkd.service systemd-resolved.service >>"$LOG" 2>&1 || true
rfkill unblock wifi >>"$LOG" 2>&1 || true

IFACE=
I=0
while [ "$I" -lt 60 ]; do
  for NETPATH in /sys/class/net/wlp* /sys/class/net/wlan*; do
    [ -e "$NETPATH" ] || continue
    [ -d "$NETPATH/wireless" ] || [ -e "$NETPATH/phy80211" ] || continue
    IFACE=${NETPATH##*/}
    break
  done
  [ -n "$IFACE" ] && break
  sleep 1
  I=$((I + 1))
done

[ -n "$IFACE" ] || {
  emit "skip missing_iface"
  exit 0
}

ip link set dev "$IFACE" up >>"$LOG" 2>&1 || true
networkctl reload >>"$LOG" 2>&1 || true
networkctl reconfigure "$IFACE" >>"$LOG" 2>&1 || true

if [ -S "/run/wpa_supplicant/$IFACE" ]; then
  emit "wpa_already_running iface=$IFACE"
  while true; do sleep 3600; done
fi

emit "wpa_exec iface=$IFACE"
exec wpa_supplicant -i "$IFACE" -c "$CONF" -f /var/log/lmi-wpa_supplicant.log
EOF
chmod 0755 "$WORK_DIR/usr/local/sbin/lmi-wifi-connect"

cat > "$WORK_DIR/etc/systemd/system/lmi-wifi-connect.service" <<'EOF'
[Unit]
Description=LMI Wi-Fi connection
After=lmi-wireless-reprobe.service systemd-networkd.service systemd-resolved.service
Wants=lmi-wireless-reprobe.service systemd-networkd.service systemd-resolved.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/lmi-wifi-connect
Restart=on-failure
RestartSec=2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$WORK_DIR/etc/systemd/system/serial-getty@ttyGS0.service.d"
cat > "$WORK_DIR/etc/systemd/system/serial-getty@ttyGS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
Type=idle
EOF

mkdir -p "$WORK_DIR/etc/systemd/system/multi-user.target.wants" "$WORK_DIR/etc/systemd/system/getty.target.wants" "$WORK_DIR/etc/lmi"
touch "$WORK_DIR/etc/lmi/no-autoreboot"
ln -sf /etc/systemd/system/lmi-firstboot-report.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/lmi-firstboot-report.service"
ln -sf /etc/systemd/system/lmi-firmware-import.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/lmi-firmware-import.service"
ln -sf /etc/systemd/system/lmi-wireless-reprobe.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/lmi-wireless-reprobe.service"
ln -sf /etc/systemd/system/lmi-wifi-connect.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/lmi-wifi-connect.service"
ln -sf /etc/systemd/system/lmi-power-keysd.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/lmi-power-keysd.service"
ln -sf /etc/systemd/system/lmi-powerd.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/lmi-powerd.service"
ln -sf /lib/systemd/system/systemd-networkd.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /lib/systemd/system/systemd-resolved.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
ln -sf /lib/systemd/system/ssh.service "$WORK_DIR/etc/systemd/system/multi-user.target.wants/ssh.service"
ln -sf /lib/systemd/system/serial-getty@.service "$WORK_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
ln -sf /lib/systemd/system/multi-user.target "$WORK_DIR/etc/systemd/system/default.target"
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  ln -sf /dev/null "$WORK_DIR/etc/systemd/system/$target"
done

run_chroot 'passwd -d root'
run_chroot 'apt-get clean'

rm -f "$WORK_DIR/usr/sbin/policy-rc.d"
rm -f "$WORK_DIR/usr/bin/qemu-aarch64-static"
rm -f "$WORK_DIR/etc/machine-id" "$WORK_DIR/var/lib/dbus/machine-id"
touch "$WORK_DIR/etc/machine-id"
rm -rf "$WORK_DIR/var/lib/apt/lists/"* "$WORK_DIR/tmp/"* "$WORK_DIR/var/tmp/"*

if ! cleanup_mounts; then
  findmnt -R "$WORK_DIR" || true
  printf 'failed to unmount rootfs runtime mounts\n' >&2
  exit 1
fi
assert_no_mounts "$WORK_DIR"
find "$WORK_DIR/proc" "$WORK_DIR/sys" "$WORK_DIR/dev" "$WORK_DIR/run" -mindepth 1 -xdev -exec rm -rf -- {} +
trap - EXIT
mv "$WORK_DIR" "$ROOTFS_DIR"
printf 'rootfs ready: %s\n' "$ROOTFS_DIR"
