#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ -r "$REPO_ROOT/local/fedora.env" ]; then
  set -a
  . "$REPO_ROOT/local/fedora.env"
  set +a
fi

OUT_DIR=${OUT_DIR:-"$REPO_ROOT/out"}
ROOTFS_DIR=${ROOTFS_DIR:-"$OUT_DIR/fedora-rootfs"}
DNF_CACHE_DIR=${DNF_CACHE_DIR:-"$OUT_DIR/fedora-dnf-cache"}
REPOS_DIR=${REPOS_DIR:-"$OUT_DIR/fedora-repos"}
FS_LABEL=${FS_LABEL:-fedora-rootfs}
FEDORA_HOSTNAME=${FEDORA_HOSTNAME:-lmi-fedora}
FEDORA_ARCH=${FEDORA_ARCH:-aarch64}
FEDORA_RELEASEVER=${FEDORA_RELEASEVER:-}
FEDORA_GPGCHECK=${FEDORA_GPGCHECK:-0}
ENABLE_CONTAINERS=${ENABLE_CONTAINERS:-1}
INSTALL_ROOT_SSH_KEY=${INSTALL_ROOT_SSH_KEY:-0}
INSTALL_USER_SSH_KEY=${INSTALL_USER_SSH_KEY:-0}
FEDORA_USERNAME=${FEDORA_USERNAME:-lmi}
FEDORA_USER_UID=${FEDORA_USER_UID:-1000}
FEDORA_USER_GID=${FEDORA_USER_GID:-1000}
FEDORA_PASSWORD=${FEDORA_PASSWORD:-}
FEDORA_PASSWORD_HASH=${FEDORA_PASSWORD_HASH:-}

PACKAGES=(
  basesystem
  fedora-release-kde
  fedora-repos
  dnf
  systemd
  systemd-udev
  passwd
  shadow-utils
  sudo
  vim-minimal
  bash-completion
  openssh-server
  NetworkManager
  wireless-regdb
  wpa_supplicant
  iwd
  bluez
  pipewire
  pipewire-alsa
  pipewire-pulseaudio
  wireplumber
  alsa-utils
  plasma-desktop
  plasma-workspace
  plasma-nm
  plasma-pa
  kde-settings
  sddm
  konsole
  dolphin
  kwin
  xorg-x11-server-Xwayland
  mesa-dri-drivers
  mesa-vulkan-drivers
  mesa-libEGL
  mesa-libGL
  vulkan-loader
  wayland-utils
  linux-firmware
  linux-firmware-whence
  pciutils
  usbutils
  i2c-tools
  ethtool
  iproute
  iputils
  nftables
  firewalld
  iptables-nft
  moby-engine
  docker-cli
  containerd
  runc
  crun
  fuse-overlayfs
  slirp4netns
  lxc
  lxcfs
  lxc-templates
)

if [ -n "${FEDORA_PACKAGES_EXTRA:-}" ]; then
  # shellcheck disable=SC2206
  PACKAGES+=( $FEDORA_PACKAGES_EXTRA )
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

detect_latest_release() {
  if [ -n "$FEDORA_RELEASEVER" ]; then
    printf '%s\n' "$FEDORA_RELEASEVER"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://dl.fedoraproject.org/pub/fedora/linux/releases/
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://dl.fedoraproject.org/pub/fedora/linux/releases/
  else
    printf 'FEDORA_RELEASEVER must be set when curl/wget is unavailable\n' >&2
    return 1
  fi | sed -n 's/.*href="\([0-9][0-9]*\)\/".*/\1/p' | sort -n | tail -n 1
}

choose_dnf() {
  if [ -n "${DNF:-}" ]; then
    printf '%s\n' "$DNF"
  elif command -v dnf5 >/dev/null 2>&1; then
    printf '%s\n' dnf5
  else
    printf '%s\n' dnf
  fi
}

find_unit() {
  SERVICE="$1"
  for BASE in usr/lib/systemd/system lib/systemd/system etc/systemd/system; do
    if [ -e "$ROOTFS_DIR/$BASE/$SERVICE" ]; then
      printf '/%s/%s\n' "$BASE" "$SERVICE"
      return 0
    fi
  done
  return 1
}

enable_service() {
  SERVICE="$1"
  TARGET=${2:-multi-user.target}
  UNIT=$(find_unit "$SERVICE" || true)
  [ -n "$UNIT" ] || return 0
  mkdir -p "$ROOTFS_DIR/etc/systemd/system/$TARGET.wants"
  ln -sf "$UNIT" "$ROOTFS_DIR/etc/systemd/system/$TARGET.wants/$SERVICE"
}

enable_display_manager() {
  UNIT=$(find_unit sddm.service || true)
  [ -n "$UNIT" ] || return 0
  ln -sf "$UNIT" "$ROOTFS_DIR/etc/systemd/system/display-manager.service"
}

password_hash() {
  PASSWORD="$1"
  require_cmd openssl
  openssl passwd -6 "$PASSWORD"
}

resolve_password_hash() {
  if [ -n "$FEDORA_PASSWORD_HASH" ]; then
    printf '%s\n' "$FEDORA_PASSWORD_HASH"
  elif [ -n "$FEDORA_PASSWORD" ]; then
    password_hash "$FEDORA_PASSWORD"
  else
    printf '!\n'
  fi
}

set_shadow_entry() {
  USERNAME="$1"
  HASH="$2"
  LAST_CHANGE="$3"
  SHADOW="$ROOTFS_DIR/etc/shadow"
  TMP=$(mktemp "$SHADOW.XXXXXX")
  FOUND=0

  if [ -e "$SHADOW" ]; then
    while IFS= read -r LINE || [ -n "$LINE" ]; do
      case "$LINE" in
        "$USERNAME":*)
          printf '%s:%s:%s:0:99999:7:::\n' "$USERNAME" "$HASH" "$LAST_CHANGE"
          FOUND=1
          ;;
        *)
          printf '%s\n' "$LINE"
          ;;
      esac
    done < "$SHADOW" > "$TMP"
  else
    : > "$TMP"
  fi

  if [ "$FOUND" = 0 ]; then
    printf '%s:%s:%s:0:99999:7:::\n' "$USERNAME" "$HASH" "$LAST_CHANGE" >> "$TMP"
  fi

  cat "$TMP" > "$SHADOW"
  rm -f "$TMP"
  chmod 0640 "$SHADOW"
}

lock_root_password() {
  LAST_CHANGE=$(( $(date +%s) / 86400 ))
  mkdir -p "$ROOTFS_DIR/etc"
  set_shadow_entry root '!' "$LAST_CHANGE"
}

create_local_user() {
  [ -n "$FEDORA_USERNAME" ] || return 0
  case "$FEDORA_USERNAME" in
    *[!A-Za-z0-9_-]*)
      printf 'invalid FEDORA_USERNAME: %s\n' "$FEDORA_USERNAME" >&2
      exit 1
      ;;
  esac
  HASH=$(resolve_password_hash)
  LAST_CHANGE=$(( $(date +%s) / 86400 ))
  mkdir -p "$ROOTFS_DIR/etc" "$ROOTFS_DIR/home/$FEDORA_USERNAME"
  grep -q "^$FEDORA_USERNAME:" "$ROOTFS_DIR/etc/group" 2>/dev/null || printf '%s:x:%s:\n' "$FEDORA_USERNAME" "$FEDORA_USER_GID" >> "$ROOTFS_DIR/etc/group"
  grep -q "^$FEDORA_USERNAME:" "$ROOTFS_DIR/etc/gshadow" 2>/dev/null || printf '%s:!::\n' "$FEDORA_USERNAME" >> "$ROOTFS_DIR/etc/gshadow"
  grep -q "^$FEDORA_USERNAME:" "$ROOTFS_DIR/etc/passwd" 2>/dev/null || printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$FEDORA_USERNAME" "$FEDORA_USER_UID" "$FEDORA_USER_GID" "$FEDORA_USERNAME" >> "$ROOTFS_DIR/etc/passwd"
  set_shadow_entry "$FEDORA_USERNAME" "$HASH" "$LAST_CHANGE"
  chown "$FEDORA_USER_UID:$FEDORA_USER_GID" "$ROOTFS_DIR/home/$FEDORA_USERNAME"
}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

DNF_BIN=$(choose_dnf)
require_cmd "$DNF_BIN"
require_cmd sed
require_cmd sort
require_cmd install

FEDORA_RELEASEVER=$(detect_latest_release)
[ -n "$FEDORA_RELEASEVER" ] || {
  printf 'failed to detect Fedora release version\n' >&2
  exit 1
}

mkdir -p "$ROOTFS_DIR" "$DNF_CACHE_DIR" "$REPOS_DIR"

cat > "$REPOS_DIR/fedora-lmi.repo" <<EOF
[fedora]
name=Fedora \$releasever - $FEDORA_ARCH
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-\$releasever&arch=$FEDORA_ARCH
enabled=1
gpgcheck=$FEDORA_GPGCHECK
repo_gpgcheck=0

[updates]
name=Fedora \$releasever Updates - $FEDORA_ARCH
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f\$releasever&arch=$FEDORA_ARCH
enabled=1
gpgcheck=$FEDORA_GPGCHECK
repo_gpgcheck=0
EOF

"$DNF_BIN" -y \
  --installroot="$ROOTFS_DIR" \
  --releasever="$FEDORA_RELEASEVER" \
  --forcearch="$FEDORA_ARCH" \
  --setopt="reposdir=$REPOS_DIR" \
  --setopt="cachedir=$DNF_CACHE_DIR" \
  install "${PACKAGES[@]}"

install -d -m 0755 "$ROOTFS_DIR/etc" "$ROOTFS_DIR/etc/systemd/system" "$ROOTFS_DIR/etc/systemd/system/graphical.target.wants" "$ROOTFS_DIR/etc/ssh/sshd_config.d" "$ROOTFS_DIR/var/lib/logrotate" "$ROOTFS_DIR/var/lib/plocate"
ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-repart.service"
ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/gssproxy.service"
printf 'LABEL=%s / ext4 defaults,noatime 0 1\n' "$FS_LABEL" > "$ROOTFS_DIR/etc/fstab"
printf '%s\n' "$FEDORA_HOSTNAME" > "$ROOTFS_DIR/etc/hostname"
: > "$ROOTFS_DIR/etc/machine-id"
rm -f "$ROOTFS_DIR/etc/ssh/sshd_config.d/"*lmi-password-login.conf
cat > "$ROOTFS_DIR/etc/ssh/sshd_config.d/99-lmi-no-password-login.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
ln -sf /usr/lib/systemd/system/graphical.target "$ROOTFS_DIR/etc/systemd/system/default.target"
lock_root_password
create_local_user

if [ -n "$FEDORA_USERNAME" ]; then
  install -d -m 0755 -o "$FEDORA_USER_UID" -g "$FEDORA_USER_GID" \
    "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/systemd/user" \
    "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/gtk-3.0" \
    "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/gtk-4.0"
  ln -sf /dev/null "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/systemd/user/grub-boot-success.service"
  ln -sf /dev/null "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/systemd/user/app-sealertauto@autostart.service"
  cat > "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/kdeglobals" <<'EOF'
[KScreen]
ScreenScaleFactors=DSI-1=1.25;
EOF
  cat > "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/kcmfonts" <<'EOF'
[General]
forceFontDPI=120
EOF
  cat > "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/kwinrc" <<'EOF'
[Xwayland]
Scale=1.25
EOF
  cat > "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-xft-dpi=122880
EOF
  cat > "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config/gtk-4.0/settings.ini" <<'EOF'
[Settings]
gtk-xft-dpi=122880
EOF
  chown -R "$FEDORA_USER_UID:$FEDORA_USER_GID" "$ROOTFS_DIR/home/$FEDORA_USERNAME/.config"
fi

enable_service NetworkManager.service
enable_service bluetooth.service
enable_service firewalld.service
enable_service sshd.service
enable_service sddm.service graphical.target
enable_display_manager

if [ "$ENABLE_CONTAINERS" = 1 ]; then
  enable_service docker.service
  enable_service containerd.service
  enable_service lxcfs.service
fi

if [ "$INSTALL_ROOT_SSH_KEY" = 1 ] && [ -r "$REPO_ROOT/local/authorized_keys" ]; then
  install -d -m 0700 "$ROOTFS_DIR/root/.ssh"
  install -m 0600 "$REPO_ROOT/local/authorized_keys" "$ROOTFS_DIR/root/.ssh/authorized_keys"
fi

if [ "$INSTALL_USER_SSH_KEY" = 1 ] && [ -n "$FEDORA_USERNAME" ] && [ -r "$REPO_ROOT/local/authorized_keys" ]; then
  install -d -m 0700 "$ROOTFS_DIR/home/$FEDORA_USERNAME/.ssh"
  install -m 0600 "$REPO_ROOT/local/authorized_keys" "$ROOTFS_DIR/home/$FEDORA_USERNAME/.ssh/authorized_keys"
  chown -R "$FEDORA_USER_UID:$FEDORA_USER_GID" "$ROOTFS_DIR/home/$FEDORA_USERNAME/.ssh"
fi

printf 'fedora_release=%s\n' "$FEDORA_RELEASEVER"
printf 'rootfs=%s\n' "$ROOTFS_DIR"
printf 'label=%s\n' "$FS_LABEL"
