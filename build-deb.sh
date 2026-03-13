#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-deb.sh [options]

Build a Debian package for better-raid-check.

Options:
  --version X.Y.Z   Package version (default: 1.0.0)
  --arch ARCH       Package architecture (default: all)
  --output-dir DIR  Output directory for .deb (default: ./dist)
  -h, --help        Show this help
EOF
}

VERSION="1.0.0"
ARCH="all"
OUTPUT_DIR="dist"

while (( $# > 0 )); do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "dpkg-deb not found. Install dpkg-dev/dpkg first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_NAME="better-raid-check"
PKG_ROOT_DIR="${PKG_NAME}_${VERSION}_${ARCH}"
WORK_DIR="$(mktemp -d)"
PKG_DIR="$WORK_DIR/$PKG_ROOT_DIR"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$PKG_DIR/DEBIAN"

install -Dm0755 "$SCRIPT_DIR/raid-check-serial.sh" "$PKG_DIR/usr/local/sbin/raid-check-serial.sh"
install -Dm0755 "$SCRIPT_DIR/install-debian.sh" "$PKG_DIR/usr/local/sbin/raid-check-serial-install.sh"
install -Dm0644 "$SCRIPT_DIR/raid-check-serial.service" "$PKG_DIR/lib/systemd/system/raid-check-serial.service"
install -Dm0644 "$SCRIPT_DIR/raid-check-serial.timer" "$PKG_DIR/lib/systemd/system/raid-check-serial.timer"
install -Dm0644 "$SCRIPT_DIR/README.md" "$PKG_DIR/usr/share/doc/$PKG_NAME/README.md"
install -Dm0644 "$SCRIPT_DIR/docs/DEBIAN_INSTALL.md" "$PKG_DIR/usr/share/doc/$PKG_NAME/DEBIAN_INSTALL.md"

cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: better-raid-check maintainers <maintainers@example.com>
Depends: bash, systemd, mdadm
Description: Media-aware MD RAID check scheduler with per-class concurrency
 Schedules and runs MD RAID check operations with configurable concurrency
 per media class (HDD/SSD/NVM), with conflict protection against other
 RAID check schedulers.
EOF

cat > "$PKG_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "configure" ]; then
  if [ ! -f /etc/default/raid-check-serial ]; then
    cat > /etc/default/raid-check-serial <<'EOCFG'
SLEEP_SECS=20
DRY_RUN=0
MAX_HDD_CONCURRENT=1
MAX_SSD_CONCURRENT=1
MAX_NVM_CONCURRENT=1
MERGE_SSD_NVM_CLASSES=0
MAX_ROTATIONAL_CONCURRENT=1
MAX_NVME_CONCURRENT=1
EOCFG
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now raid-check-serial.timer >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/postinst"

cat > "$PKG_DIR/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "remove" ]; then
  systemctl disable --now raid-check-serial.timer >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/prerm"

mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"
OUT_DEB="$SCRIPT_DIR/$OUTPUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"

dpkg-deb --build --root-owner-group "$PKG_DIR" "$OUT_DEB" >/dev/null

echo "Built package: $OUT_DEB"
