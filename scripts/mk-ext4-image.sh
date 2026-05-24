#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOTFS_DIR=${ROOTFS_DIR:-"$REPO_ROOT/out/rootfs"}
OUT_DIR=${OUT_DIR:-"$REPO_ROOT/out"}
IMAGE=${IMAGE:-"$OUT_DIR/ubuntu-24.04-arm64-console.ext4"}
IMAGE_SIZE=${IMAGE_SIZE:-6G}
FS_LABEL=${FS_LABEL:-ubuntu-rootfs}

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd mkfs.ext4
require_cmd e2fsck
require_cmd tune2fs
require_cmd truncate
require_cmd sha256sum

[ -d "$ROOTFS_DIR" ] || {
  printf 'missing rootfs dir: %s\n' "$ROOTFS_DIR" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
TMP_IMAGE="$IMAGE.tmp"
rm -f "$TMP_IMAGE"
truncate -s "$IMAGE_SIZE" "$TMP_IMAGE"
mkfs.ext4 -F -L "$FS_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 -d "$ROOTFS_DIR" "$TMP_IMAGE"
e2fsck -fy "$TMP_IMAGE"
mv "$TMP_IMAGE" "$IMAGE"
sha256sum "$IMAGE" > "$IMAGE.sha256"

if command -v img2simg >/dev/null 2>&1; then
  img2simg "$IMAGE" "$IMAGE.sparse"
  sha256sum "$IMAGE.sparse" > "$IMAGE.sparse.sha256"
fi

tune2fs -l "$IMAGE" | grep -E '^(Filesystem volume name|Filesystem UUID|Block count|Block size):'
