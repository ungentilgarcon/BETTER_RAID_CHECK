#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-debian.sh [options]

Install RAID check script and systemd units on Debian.

Options:
  --hdd-limit N          Max concurrent HDD/mixed array checks (default: 1)
  --ssd-limit N          Max concurrent SSD array checks (default: 1)
  --nvm-limit N          Max concurrent NVM (NVMe) array checks (default: 1)
  --check-interval Xd|XM Schedule check interval (default: 1M)
                        Examples: 30d, 60d, 1M, 2M
  --merge-ssd-nvm 0|1    Treat SSD and NVM as one class (default: 0)
  --rotational-limit N   Alias for --hdd-limit
  --nvme-limit N         Alias for --nvm-limit
  --sleep-secs N         Poll interval in seconds (default: 20)
  --dry-run 0|1          Default DRY_RUN value in env file (default: 0)
  --skip-conflict-disable  Do not disable conflicting cron/timer RAID checks
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

is_interval_spec() {
  [[ "$1" =~ ^[1-9][0-9]*[dM]$ ]]
}

month_list_for_step() {
  local step="$1"
  local m list=""
  for ((m=1; m<=12; m+=step)); do
    list+="$(printf '%02d' "$m"),"
  done
  printf '%s\n' "${list%,}"
}

write_timer_override() {
  local interval="$1"
  local timer_override_dir="$2"
  local timer_override_file="$3"
  local count unit month_list

  count="${interval%[dM]}"
  unit="${interval: -1}"

  mkdir -p "$timer_override_dir"

  if [[ "$unit" == "d" ]]; then
    cat > "$timer_override_file" <<EOF
[Timer]
OnCalendar=
OnUnitActiveSec=${count}d
OnBootSec=15min
EOF
    return 0
  fi

  if [[ "$count" == "1" ]]; then
    cat > "$timer_override_file" <<'EOF'
[Timer]
OnUnitActiveSec=
OnCalendar=
OnCalendar=monthly
EOF
    return 0
  fi

  if (( count >= 2 && count <= 12 )); then
    month_list="$(month_list_for_step "$count")"
    cat > "$timer_override_file" <<EOF
[Timer]
OnUnitActiveSec=
OnCalendar=
OnCalendar=*-${month_list}-01 03:00:00
EOF
    return 0
  fi

  # Large month intervals fallback to monotonic timer.
  cat > "$timer_override_file" <<EOF
[Timer]
OnCalendar=
OnUnitActiveSec=${count}month
OnBootSec=15min
EOF
}

HDD_LIMIT=1
SSD_LIMIT=1
NVM_LIMIT=1
CHECK_INTERVAL="1M"
MERGE_SSD_NVM=0
SLEEP_SECS=20
DRY_RUN=0
START_NOW=0
DISABLE_CONFLICTS=1

while (( $# > 0 )); do
  case "$1" in
    --rotational-limit)
      HDD_LIMIT="${2:-}"
      shift 2
      ;;
    --hdd-limit)
      HDD_LIMIT="${2:-}"
      shift 2
      ;;
    --ssd-limit)
      SSD_LIMIT="${2:-}"
      shift 2
      ;;
    --nvme-limit)
      NVM_LIMIT="${2:-}"
      shift 2
      ;;
    --nvm-limit)
      NVM_LIMIT="${2:-}"
      shift 2
      ;;
    --check-interval)
      CHECK_INTERVAL="${2:-}"
      shift 2
      ;;
    --merge-ssd-nvm)
      MERGE_SSD_NVM="${2:-}"
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
    --skip-conflict-disable)
      DISABLE_CONFLICTS=0
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

for value_name in HDD_LIMIT SSD_LIMIT NVM_LIMIT; do
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

if [[ "$MERGE_SSD_NVM" != "0" && "$MERGE_SSD_NVM" != "1" ]]; then
  echo "Invalid MERGE_SSD_NVM: $MERGE_SSD_NVM (expected 0 or 1)" >&2
  exit 1
fi

if ! is_interval_spec "$CHECK_INTERVAL"; then
  echo "Invalid CHECK_INTERVAL: $CHECK_INTERVAL (expected Xd or XM, e.g. 60d or 2M)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="$SCRIPT_DIR/raid-check-serial.sh"
SRC_UNIT="$SCRIPT_DIR/raid-check-serial.service"
SRC_TIMER="$SCRIPT_DIR/raid-check-serial.timer"
DST_SCRIPT="/usr/local/sbin/raid-check-serial.sh"
DST_UNIT="/etc/systemd/system/raid-check-serial.service"
DST_TIMER="/etc/systemd/system/raid-check-serial.timer"
TIMER_OVERRIDE_DIR="/etc/systemd/system/raid-check-serial.timer.d"
TIMER_OVERRIDE_FILE="$TIMER_OVERRIDE_DIR/override.conf"
ENV_FILE="/etc/default/raid-check-serial"

disable_conflicting_systemd_timers() {
  local timer
  local -a candidates=()
  local -a known=(mdcheck_start.timer mdcheck_continue.timer mdcheck.timer)

  for timer in "${known[@]}"; do
    if systemctl list-unit-files --type=timer --no-legend --no-pager | awk '{print $1}' | grep -Fxq "$timer"; then
      candidates+=("$timer")
    fi
  done

  mapfile -t auto_detected < <(
    systemctl list-unit-files --type=timer --no-legend --no-pager |
      awk '{print $1}' |
      grep -Ei '(^|[-_])(md|raid).*?(check|scrub)|(^|[-_])(check|scrub).*?(md|raid)' || true
  )

  for timer in "${auto_detected[@]}"; do
    [[ "$timer" == "raid-check-serial.timer" ]] && continue
    candidates+=("$timer")
  done

  if (( ${#candidates[@]} == 0 )); then
    echo "No conflicting RAID-check timers found."
    return 0
  fi

  mapfile -t unique_timers < <(printf '%s\n' "${candidates[@]}" | awk 'NF' | sort -u)
  for timer in "${unique_timers[@]}"; do
    systemctl disable --now "$timer" >/dev/null 2>&1 || true
    systemctl mask "$timer" >/dev/null 2>&1 || true
    echo "Disabled and masked conflicting timer: $timer"
  done
}

disable_conflicting_cron_jobs() {
  local f backup
  local -a dirs=(/etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.hourly /etc/cron.monthly)

  for f in /etc/crontab /etc/anacrontab; do
    [[ -f "$f" ]] || continue
    if grep -Eiq 'checkarray|mdcheck|(^|[^a-z])raid[-_ ]?check([^a-z]|$)' "$f"; then
      backup="$f.raid-check-serial.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$f" "$backup"
      sed -E -i '/checkarray|mdcheck|(^|[^a-z])raid[-_ ]?check([^a-z]|$)/I {
        /disabled-by-raid-check-serial/I! s/^/# disabled-by-raid-check-serial: /
      }' "$f"
      echo "Commented conflicting entries in $f (backup: $backup)"
    fi
  done

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [[ "$f" == *.disabled-by-raid-check-serial ]]; then
        continue
      fi
      if grep -Eiq 'checkarray|mdcheck|(^|[^a-z])raid[-_ ]?check([^a-z]|$)' "$f"; then
        mv "$f" "$f.disabled-by-raid-check-serial"
        echo "Disabled conflicting cron file: $f"
      fi
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
  done
}

if [[ ! -f "$SRC_SCRIPT" || ! -f "$SRC_UNIT" || ! -f "$SRC_TIMER" ]]; then
  echo "Expected files not found next to installer: raid-check-serial.sh, raid-check-serial.service, raid-check-serial.timer" >&2
  exit 1
fi

install -m 0755 "$SRC_SCRIPT" "$DST_SCRIPT"
install -m 0644 "$SRC_UNIT" "$DST_UNIT"
install -m 0644 "$SRC_TIMER" "$DST_TIMER"

if [[ "$CHECK_INTERVAL" == "1M" ]]; then
  rm -f "$TIMER_OVERRIDE_FILE"
  rmdir "$TIMER_OVERRIDE_DIR" 2>/dev/null || true
else
  write_timer_override "$CHECK_INTERVAL" "$TIMER_OVERRIDE_DIR" "$TIMER_OVERRIDE_FILE"
fi

cat > "$ENV_FILE" <<EOF
SLEEP_SECS=$SLEEP_SECS
DRY_RUN=$DRY_RUN
MAX_HDD_CONCURRENT=$HDD_LIMIT
MAX_SSD_CONCURRENT=$SSD_LIMIT
MAX_NVM_CONCURRENT=$NVM_LIMIT
MERGE_SSD_NVM_CLASSES=$MERGE_SSD_NVM
# Backward-compatible aliases
MAX_ROTATIONAL_CONCURRENT=$HDD_LIMIT
MAX_NVME_CONCURRENT=$NVM_LIMIT
EOF

if (( DISABLE_CONFLICTS == 1 )); then
  disable_conflicting_systemd_timers
  disable_conflicting_cron_jobs
fi

systemctl daemon-reload
systemctl enable --now raid-check-serial.timer

if (( START_NOW == 1 )); then
  systemctl start --no-block raid-check-serial.service
fi

echo "Installed: $DST_SCRIPT"
echo "Installed: $DST_UNIT"
echo "Installed: $DST_TIMER"
echo "Wrote config: $ENV_FILE"
echo "Limits: hdd=$HDD_LIMIT ssd=$SSD_LIMIT nvm=$NVM_LIMIT"
echo "Merge SSD+NVM classes: $MERGE_SSD_NVM"
echo "Check interval: $CHECK_INTERVAL"
if (( DISABLE_CONFLICTS == 1 )); then
  echo "Conflicting cron/timer RAID checks were disabled and masked when detected."
else
  echo "Conflicting cron/timer RAID checks were not modified (--skip-conflict-disable)."
fi
echo "Timer enabled: raid-check-serial.timer"
if (( START_NOW == 1 )); then
  echo "Service started: raid-check-serial.service"
else
  echo "Start now with: systemctl start --no-block raid-check-serial.service"
fi
