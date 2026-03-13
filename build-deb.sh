#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-deb.sh [options]

Build Debian packages using dpkg-buildpackage from the standard debian/ layout.

Options:
  --source          Build source package artifacts (.dsc/.changes/.tar.*)
  --binary          Build binary package artifacts (.deb) [default]
  --output-dir DIR  Copy produced artifacts to DIR (default: ./dist)
  -h, --help        Show this help
EOF
}

MODE="binary"
OUTPUT_DIR="dist"

while (( $# > 0 )); do
  case "$1" in
    --source)
      MODE="source"
      shift
      ;;
    --binary)
      MODE="binary"
      shift
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

if ! command -v dpkg-buildpackage >/dev/null 2>&1; then
  echo "dpkg-buildpackage not found. Install dpkg-dev first." >&2
  exit 1
fi

if ! command -v dpkg-parsechangelog >/dev/null 2>&1; then
  echo "dpkg-parsechangelog not found. Install dpkg-dev first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_NAME="better-raid-check"
VERSION="$(dpkg-parsechangelog -l"$SCRIPT_DIR/debian/changelog" -SVersion)"
UPSTREAM_VERSION="${VERSION%%-*}"

pushd "$SCRIPT_DIR" >/dev/null
if [[ "$MODE" == "source" ]]; then
  dpkg-buildpackage -us -uc -S -sa
else
  dpkg-buildpackage -us -uc -b
fi
popd >/dev/null

mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"

copy_matches() {
  local pattern="$1"
  local found=1
  shopt -s nullglob
  for f in $pattern; do
    cp -f "$f" "$SCRIPT_DIR/$OUTPUT_DIR/"
    found=0
  done
  shopt -u nullglob
  return $found
}

copy_matches "$PARENT_DIR/${PKG_NAME}_${VERSION}_all.deb" || true
copy_matches "$PARENT_DIR/${PKG_NAME}_${VERSION}_*.changes" || true
copy_matches "$PARENT_DIR/${PKG_NAME}_${VERSION}_*.buildinfo" || true
copy_matches "$PARENT_DIR/${PKG_NAME}_${VERSION}.dsc" || true
copy_matches "$PARENT_DIR/${PKG_NAME}_${VERSION}.debian.tar.*" || true
copy_matches "$PARENT_DIR/${PKG_NAME}_${UPSTREAM_VERSION}.orig.tar.*" || true

echo "Build mode: $MODE"
echo "Copied artifacts to: $SCRIPT_DIR/$OUTPUT_DIR"
