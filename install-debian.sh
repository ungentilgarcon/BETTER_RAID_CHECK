#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-debian.sh [options]

Install RAID check script and systemd unit on Debian.

Options:
  --rotational-limit N   Max concurrent rotational/mixed array checks (default: 1)
  --ssd-limit N          Max concurrent SSD array checks (default: 1)
  --nvme-limit N         Max concurrent NVMe array checks (default: 1)
  --sleep-secs N         Poll interval in seconds (default: 20)
  --dry-run 0|1          Default DRY_RUN value in env file (default: 0)
  --start-now            Start service after install
  -h, --help             Show this help
EOF
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

ROTATIONAL_LIMIT=1
SSD_LIMIT=1
NVME_LIMIT=1
SLEEP_SECS=20
DRY_RUN=0
START_NOW=0

while (( $# > 0 )); do
  case "$1" in
    --rotational-limit)
      ROTATIONAL_LIMIT="${2:-}"
      shift 2
      ;;
    --ssd-limit)
      SSD_LIMIT="${2:-}"
      shift 2
      ;;
    --nvme-limit)
      NVME_LIMIT="${2:-}"
      shift 2
      ;;
    --sleep-secs)
      SLEEP_SECS="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="${2:-}"
      shift 2
      ;;
    --start-now)
      START_NOW=1
      shift
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

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root (for example: sudo ./install-debian.sh ...)" >&2
  exit 1
fi

for value_name in ROTATIONAL_LIMIT SSD_LIMIT NVME_LIMIT; do
  value="${!value_name}"
  if ! is_non_negative_int "$value"; then
    echo "Invalid $value_name: $value (expected non-negative integer)" >&2
    exit 1
  fi
done

if ! is_positive_int "$SLEEP_SECS"; then
  echo "Invalid SLEEP_SECS: $SLEEP_SECS (expected positive integer)" >&2
  exit 1
fi

if [[ "$DRY_RUN" != "0" && "$DRY_RUN" != "1" ]]; then
  echo "Invalid DRY_RUN: $DRY_RUN (expected 0 or 1)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="$SCRIPT_DIR/raid-check-serial.sh"
SRC_UNIT="$SCRIPT_DIR/raid-check-serial.service"
DST_SCRIPT="/usr/local/sbin/raid-check-serial.sh"
DST_UNIT="/etc/systemd/system/raid-check-serial.service"
ENV_FILE="/etc/default/raid-check-serial"

if [[ ! -f "$SRC_SCRIPT" || ! -f "$SRC_UNIT" ]]; then
  echo "Expected files not found next to installer: raid-check-serial.sh and raid-check-serial.service" >&2
  exit 1
fi

install -m 0755 "$SRC_SCRIPT" "$DST_SCRIPT"
install -m 0644 "$SRC_UNIT" "$DST_UNIT"

cat > "$ENV_FILE" <<EOF
SLEEP_SECS=$SLEEP_SECS
DRY_RUN=$DRY_RUN
MAX_ROTATIONAL_CONCURRENT=$ROTATIONAL_LIMIT
MAX_SSD_CONCURRENT=$SSD_LIMIT
MAX_NVME_CONCURRENT=$NVME_LIMIT
EOF

systemctl daemon-reload

if (( START_NOW == 1 )); then
  systemctl start raid-check-serial.service
fi

echo "Installed: $DST_SCRIPT"
echo "Installed: $DST_UNIT"
echo "Wrote config: $ENV_FILE"
echo "Limits: rotational=$ROTATIONAL_LIMIT ssd=$SSD_LIMIT nvme=$NVME_LIMIT"
if (( START_NOW == 1 )); then
  echo "Service started: raid-check-serial.service"
else
  echo "Start with: systemctl start raid-check-serial.service"
fi
