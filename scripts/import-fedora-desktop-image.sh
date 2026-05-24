#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ -r "$REPO_ROOT/local/fedora.env" ]; then
  set -a
  . "$REPO_ROOT/local/fedora.env"
  set +a
fi

OUT_DIR=${OUT_DIR:-"$REPO_ROOT/out"}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-"$OUT_DIR/downloads"}
ROOTFS_DIR=${ROOTFS_DIR:-"$OUT_DIR/fedora-rootfs"}
FS_LABEL=${FS_LABEL:-fedora-rootfs}
FEDORA_IMAGE_URL=${FEDORA_IMAGE_URL:-}
FEDORA_IMAGE_XZ=${FEDORA_IMAGE_XZ:-}
FEDORA_RAW_IMAGE=${FEDORA_RAW_IMAGE:-}
FEDORA_HOSTNAME=${FEDORA_HOSTNAME:-lmi-fedora}
FEDORA_USERNAME=${FEDORA_USERNAME:-lmi}
FEDORA_USER_UID=${FEDORA_USER_UID:-1000}
FEDORA_USER_GID=${FEDORA_USER_GID:-1000}
FEDORA_PASSWORD=${FEDORA_PASSWORD:-}
FEDORA_PASSWORD_HASH=${FEDORA_PASSWORD_HASH:-}
SET_ROOT_PASSWORD=${SET_ROOT_PASSWORD:-0}
FEDORA_ROOT_PASSWORD=${FEDORA_ROOT_PASSWORD:-}
FEDORA_ROOT_PASSWORD_HASH=${FEDORA_ROOT_PASSWORD_HASH:-}
INSTALL_CONTAINER_PACKAGES=${INSTALL_CONTAINER_PACKAGES:-0}
INSTALL_ROOT_SSH_KEY=${INSTALL_ROOT_SSH_KEY:-0}
INSTALL_USER_SSH_KEY=${INSTALL_USER_SSH_KEY:-0}

LOOP_DEV=
SRC_MOUNT=
SRC_ROOT=
TMP_ROOTFS=

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

cleanup() {
  set +e
  if [ -n "$SRC_MOUNT" ] && mountpoint -q "$SRC_MOUNT"; then
    umount "$SRC_MOUNT"
  fi
  if [ -n "$LOOP_DEV" ]; then
    losetup -d "$LOOP_DEV"
  fi
  if [ -n "$SRC_MOUNT" ]; then
    rmdir "$SRC_MOUNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

url_basename() {
  URL_NO_QUERY=${1%%\?*}
  printf '%s\n' "${URL_NO_QUERY##*/}"
}

prepare_image_paths() {
  mkdir -p "$DOWNLOAD_DIR" "$OUT_DIR"

  if [ -n "$FEDORA_IMAGE_URL" ] && [ -z "$FEDORA_IMAGE_XZ" ] && [ -z "$FEDORA_RAW_IMAGE" ]; then
    FEDORA_IMAGE_XZ="$DOWNLOAD_DIR/$(url_basename "$FEDORA_IMAGE_URL")"
  fi

  if [ -n "$FEDORA_IMAGE_XZ" ] && [ -z "$FEDORA_RAW_IMAGE" ]; then
    case "$FEDORA_IMAGE_XZ" in
      *.xz) FEDORA_RAW_IMAGE=${FEDORA_IMAGE_XZ%.xz} ;;
      *) FEDORA_RAW_IMAGE="$FEDORA_IMAGE_XZ.raw" ;;
    esac
  fi

  [ -n "$FEDORA_IMAGE_XZ" ] || [ -n "$FEDORA_RAW_IMAGE" ] || {
    printf 'set FEDORA_IMAGE_URL, FEDORA_IMAGE_XZ, or FEDORA_RAW_IMAGE\n' >&2
    exit 1
  }
}

download_image() {
  [ -n "$FEDORA_IMAGE_URL" ] || return 0
  [ -n "$FEDORA_IMAGE_XZ" ] || return 0
  if [ -s "$FEDORA_IMAGE_XZ" ]; then
    printf 'using existing download=%s\n' "$FEDORA_IMAGE_XZ"
    return 0
  fi
  require_cmd curl
  curl -fL --continue-at - --output "$FEDORA_IMAGE_XZ" "$FEDORA_IMAGE_URL"
}

decompress_image() {
  [ -n "$FEDORA_IMAGE_XZ" ] || return 0
  if [ -s "$FEDORA_RAW_IMAGE" ]; then
    printf 'using existing raw_image=%s\n' "$FEDORA_RAW_IMAGE"
    return 0
  fi
  require_cmd xz
  TMP_RAW="$FEDORA_RAW_IMAGE.tmp"
  rm -f "$TMP_RAW"
  xz -dkc "$FEDORA_IMAGE_XZ" > "$TMP_RAW"
  mv "$TMP_RAW" "$FEDORA_RAW_IMAGE"
}

mount_candidate() {
  PART="$1"
  FSTYPE=$(blkid -o value -s TYPE "$PART" 2>/dev/null || true)
  case "$FSTYPE" in
    ext2|ext3|ext4|xfs|btrfs)
      mount -o ro "$PART" "$SRC_MOUNT" 2>/tmp/lmi-fedora-mount.err || return 1
      ;;
    *)
      return 1
      ;;
  esac

  for REL in . root @root @; do
    CANDIDATE="$SRC_MOUNT/$REL"
    if [ -r "$CANDIDATE/etc/os-release" ] && grep -q '^ID=fedora$' "$CANDIDATE/etc/os-release"; then
      SRC_ROOT="$CANDIDATE"
      return 0
    fi
  done

  umount "$SRC_MOUNT"
  return 1
}

mount_source_root() {
  require_cmd losetup
  require_cmd blkid
  require_cmd mount
  require_cmd umount

  SRC_MOUNT=$(mktemp -d)
  LOOP_DEV=$(losetup --find --show --partscan "$FEDORA_RAW_IMAGE")

  I=0
  while [ "$I" -lt 30 ]; do
    if ls "${LOOP_DEV}"p* >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
    I=$((I + 1))
  done

  for PART in "${LOOP_DEV}"p* "$LOOP_DEV"; do
    [ -b "$PART" ] || continue
    if mount_candidate "$PART"; then
      printf 'source_root=%s\n' "$PART"
      printf 'source_root_dir=%s\n' "$SRC_ROOT"
      return 0
    fi
  done

  printf 'failed to find Fedora root partition in %s\n' "$FEDORA_RAW_IMAGE" >&2
  exit 1
}

safe_tmp_rootfs() {
  OUT_REAL=$(realpath -m "$OUT_DIR")
  ROOT_REAL=$(realpath -m "$ROOTFS_DIR")
  case "$ROOT_REAL" in
    "$OUT_REAL"/*) ;;
    *)
      printf 'refusing ROOTFS_DIR outside OUT_DIR: %s\n' "$ROOTFS_DIR" >&2
      exit 1
      ;;
  esac

  TMP_ROOTFS="$ROOTFS_DIR.tmp"
  case "$(realpath -m "$TMP_ROOTFS")" in
    "$OUT_REAL"/*) ;;
    *)
      printf 'refusing tmp rootfs outside OUT_DIR: %s\n' "$TMP_ROOTFS" >&2
      exit 1
      ;;
  esac
  rm -rf "$TMP_ROOTFS"
  mkdir -p "$TMP_ROOTFS"
}

copy_rootfs() {
  require_cmd rsync
  [ -n "$SRC_ROOT" ] || {
    printf 'source root was not selected\n' >&2
    exit 1
  }
  safe_tmp_rootfs
  rsync -aHAX --numeric-ids --info=progress2 "$SRC_ROOT"/ "$TMP_ROOTFS"/
}

password_hash() {
  PASSWORD="$1"
  require_cmd openssl
  openssl passwd -6 "$PASSWORD"
}

resolve_password_hash() {
  HASH="$1"
  PASSWORD="$2"
  if [ -n "$HASH" ]; then
    printf '%s\n' "$HASH"
  elif [ -n "$PASSWORD" ]; then
    password_hash "$PASSWORD"
  else
    printf '!\n'
  fi
}

enable_service() {
  TARGET_ROOT="$1"
  SERVICE="$2"
  TARGET=${3:-multi-user.target}
  UNIT=
  for BASE in usr/lib/systemd/system lib/systemd/system etc/systemd/system; do
    if [ -e "$TARGET_ROOT/$BASE/$SERVICE" ]; then
      UNIT="/$BASE/$SERVICE"
      break
    fi
  done
  [ -n "$UNIT" ] || return 1
  mkdir -p "$TARGET_ROOT/etc/systemd/system/$TARGET.wants"
  ln -sf "$UNIT" "$TARGET_ROOT/etc/systemd/system/$TARGET.wants/$SERVICE"
}

configure_users() {
  FEDORA_PASSWORD_HASH=$(resolve_password_hash "$FEDORA_PASSWORD_HASH" "$FEDORA_PASSWORD")
  if [ "$SET_ROOT_PASSWORD" = 1 ]; then
    FEDORA_ROOT_PASSWORD_HASH=$(resolve_password_hash "$FEDORA_ROOT_PASSWORD_HASH" "$FEDORA_ROOT_PASSWORD")
  else
    FEDORA_ROOT_PASSWORD_HASH=${FEDORA_ROOT_PASSWORD_HASH:-!}
  fi

  ROOTFS_FOR_PY="$TMP_ROOTFS" \
  FEDORA_USERNAME="$FEDORA_USERNAME" \
  FEDORA_USER_UID="$FEDORA_USER_UID" \
  FEDORA_USER_GID="$FEDORA_USER_GID" \
  FEDORA_PASSWORD_HASH="$FEDORA_PASSWORD_HASH" \
  SET_ROOT_PASSWORD="$SET_ROOT_PASSWORD" \
  FEDORA_ROOT_PASSWORD_HASH="$FEDORA_ROOT_PASSWORD_HASH" \
  python3 <<'PY'
import os
import time
from pathlib import Path

root = Path(os.environ["ROOTFS_FOR_PY"])
username = os.environ["FEDORA_USERNAME"]
uid = os.environ["FEDORA_USER_UID"]
gid = os.environ["FEDORA_USER_GID"]
password_hash = os.environ["FEDORA_PASSWORD_HASH"]
root_password_hash = os.environ["FEDORA_ROOT_PASSWORD_HASH"]
last_change = str(int(time.time() // 86400))

if not username or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in username):
    raise SystemExit(f"invalid FEDORA_USERNAME: {username}")

def read_lines(rel):
    path = root / rel
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8", errors="surrogateescape").splitlines()

def write_lines(rel, lines, mode=0o644):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", errors="surrogateescape")
    path.chmod(mode)

def upsert_colon(rel, key, fields, mode=0o644):
    lines = read_lines(rel)
    out = []
    done = False
    for line in lines:
        if line.split(":", 1)[0] == key:
            out.append(":".join(fields))
            done = True
        else:
            out.append(line)
    if not done:
        out.append(":".join(fields))
    write_lines(rel, out, mode)

def add_group_member(group_name, member):
    lines = read_lines("etc/group")
    out = []
    done = False
    for line in lines:
        parts = line.split(":")
        if parts[0] == group_name:
            members = [m for m in parts[3].split(",") if m] if len(parts) > 3 else []
            if member not in members:
                members.append(member)
            parts[3] = ",".join(members)
            done = True
            out.append(":".join(parts))
        else:
            out.append(line)
    if not done:
        out.append(f"{group_name}:x:10:{member}")
    write_lines("etc/group", out)

upsert_colon("etc/group", username, [username, "x", gid, ""])
upsert_colon("etc/gshadow", username, [username, "!", "", ""], 0o640)
upsert_colon("etc/passwd", username, [username, "x", uid, gid, "LMI User", f"/home/{username}", "/bin/bash"])
upsert_colon("etc/shadow", username, [username, password_hash, last_change, "0", "99999", "7", "", "", ""], 0o640)
add_group_member("wheel", username)

upsert_colon("etc/shadow", "root", ["root", root_password_hash, last_change, "0", "99999", "7", "", "", ""], 0o640)

home = root / "home" / username
home.mkdir(parents=True, exist_ok=True)
os.chown(home, int(uid), int(gid))
PY
}

configure_ssh() {
  mkdir -p "$TMP_ROOTFS/etc/ssh/sshd_config.d"
  rm -f "$TMP_ROOTFS/etc/ssh/sshd_config.d/"*lmi-password-login.conf
  cat > "$TMP_ROOTFS/etc/ssh/sshd_config.d/99-lmi-no-password-login.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

  if ! enable_service "$TMP_ROOTFS" sshd.service; then
    if [ "$INSTALL_CONTAINER_PACKAGES" = 1 ] && command -v dnf >/dev/null 2>&1; then
      VERSION_ID=$(sed -n 's/^VERSION_ID=//p' "$TMP_ROOTFS/etc/os-release" | tr -d '"')
      dnf -y --installroot="$TMP_ROOTFS" --releasever="$VERSION_ID" install openssh-server
      enable_service "$TMP_ROOTFS" sshd.service || true
    fi
  fi

  [ -e "$TMP_ROOTFS/usr/lib/systemd/system/sshd.service" ] || [ -e "$TMP_ROOTFS/lib/systemd/system/sshd.service" ] || [ -e "$TMP_ROOTFS/etc/systemd/system/sshd.service" ] || {
    printf 'imported image does not contain openssh-server/sshd.service\n' >&2
    exit 1
  }
}

configure_system() {
  require_cmd python3
  install -d -m 0755 "$TMP_ROOTFS/etc" "$TMP_ROOTFS/etc/systemd/system"
  printf 'LABEL=%s / ext4 defaults,noatime 0 1\n' "$FS_LABEL" > "$TMP_ROOTFS/etc/fstab"
  printf '%s\n' "$FEDORA_HOSTNAME" > "$TMP_ROOTFS/etc/hostname"
  : > "$TMP_ROOTFS/etc/machine-id"

  if [ -e "$TMP_ROOTFS/usr/lib/systemd/system/graphical.target" ]; then
    ln -sf /usr/lib/systemd/system/graphical.target "$TMP_ROOTFS/etc/systemd/system/default.target"
  fi

  configure_users
  configure_ssh

  enable_service "$TMP_ROOTFS" NetworkManager.service || true
  enable_service "$TMP_ROOTFS" bluetooth.service || true
  enable_service "$TMP_ROOTFS" firewalld.service || true
  enable_service "$TMP_ROOTFS" sddm.service graphical.target || true
  enable_service "$TMP_ROOTFS" docker.service || true
  enable_service "$TMP_ROOTFS" containerd.service || true
  enable_service "$TMP_ROOTFS" lxcfs.service || true

  if [ -e "$TMP_ROOTFS/usr/lib/systemd/system/sddm.service" ]; then
    ln -sf /usr/lib/systemd/system/sddm.service "$TMP_ROOTFS/etc/systemd/system/display-manager.service"
  fi

  if [ "$INSTALL_ROOT_SSH_KEY" = 1 ] && [ -r "$REPO_ROOT/local/authorized_keys" ]; then
    install -d -m 0700 "$TMP_ROOTFS/root/.ssh"
    install -m 0600 "$REPO_ROOT/local/authorized_keys" "$TMP_ROOTFS/root/.ssh/authorized_keys"
  fi

  if [ "$INSTALL_USER_SSH_KEY" = 1 ] && [ -r "$REPO_ROOT/local/authorized_keys" ]; then
    install -d -m 0700 "$TMP_ROOTFS/home/$FEDORA_USERNAME/.ssh"
    install -m 0600 "$REPO_ROOT/local/authorized_keys" "$TMP_ROOTFS/home/$FEDORA_USERNAME/.ssh/authorized_keys"
    chown -R "$FEDORA_USER_UID:$FEDORA_USER_GID" "$TMP_ROOTFS/home/$FEDORA_USERNAME/.ssh"
  fi
}

install_container_packages_if_requested() {
  [ "$INSTALL_CONTAINER_PACKAGES" = 1 ] || return 0
  if ! command -v dnf >/dev/null 2>&1; then
    printf 'dnf unavailable; leaving container user-space packages as provided by image\n' >&2
    return 0
  fi
  VERSION_ID=$(sed -n 's/^VERSION_ID=//p' "$TMP_ROOTFS/etc/os-release" | tr -d '"')
  dnf -y --installroot="$TMP_ROOTFS" --releasever="$VERSION_ID" install \
    nftables firewalld iptables-nft moby-engine docker-cli containerd runc crun fuse-overlayfs slirp4netns lxc lxcfs lxc-templates
}

publish_rootfs() {
  if [ -e "$ROOTFS_DIR" ]; then
    rm -rf "$ROOTFS_DIR.previous"
    mv "$ROOTFS_DIR" "$ROOTFS_DIR.previous"
  fi
  mv "$TMP_ROOTFS" "$ROOTFS_DIR"
  TMP_ROOTFS=
}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

require_cmd realpath
require_cmd install

prepare_image_paths
download_image
decompress_image
mount_source_root
copy_rootfs
install_container_packages_if_requested
configure_system
publish_rootfs

printf 'rootfs=%s\n' "$ROOTFS_DIR"
printf 'label=%s\n' "$FS_LABEL"
printf 'ssh_user=%s\n' "$FEDORA_USERNAME"
printf 'ssh_password=disabled\n'
