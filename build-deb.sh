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

for req in raid-check-serial.sh install-debian.sh raid-check-serial.service raid-check-serial.timer README.md docs/DEBIAN_INSTALL.md LICENSE; do
  if [[ ! -f "$SCRIPT_DIR/$req" ]]; then
    echo "Missing required file: $req" >&2
    exit 1
  fi
done

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
install -Dm0644 "$SCRIPT_DIR/LICENSE" "$PKG_DIR/usr/share/doc/$PKG_NAME/LICENSE"

cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: better-raid-check maintainers <maintainers@example.com>
Depends: bash, systemd, mdadm, debconf (>= 0.5) | debconf-2.0
Description: Media-aware MD RAID check scheduler with per-class concurrency
 Schedules and runs MD RAID check operations with configurable concurrency
 per media class (HDD/SSD/NVM), with conflict protection against other
 RAID check schedulers.
EOF

cat > "$PKG_DIR/DEBIAN/templates" <<'EOF'
Template: better-raid-check/check_interval
Type: string
Default: 1M
Description: RAID check interval
 Enter interval as Xd (days) or XM (months), for example 30d, 60d, 1M, 2M.

Template: better-raid-check/hdd_limit
Type: string
Default: 1
Description: Maximum concurrent HDD/mixed RAID checks
 How many HDD or mixed-media arrays may be checked in parallel.

Template: better-raid-check/ssd_limit
Type: string
Default: 1
Description: Maximum concurrent SSD RAID checks
 How many SSD arrays may be checked in parallel.

Template: better-raid-check/nvm_limit
Type: string
Default: 1
Description: Maximum concurrent NVM RAID checks
 How many NVM (NVMe) arrays may be checked in parallel.

Template: better-raid-check/merge_ssd_nvm
Type: boolean
Default: false
Description: Treat SSD and NVM as one scheduling class
 If enabled, pure NVM arrays are handled as SSD class for scheduling.

Template: better-raid-check/sleep_secs
Type: string
Default: 20
Description: Poll interval in seconds
 Delay between status checks while a RAID check run is active.

Template: better-raid-check/dry_run
Type: boolean
Default: false
Description: Enable dry-run mode
 If enabled, actions are logged but sync_action is not modified.

Template: better-raid-check/disable_conflicts
Type: boolean
Default: true
Description: Disable conflicting RAID-check cron/timer jobs
 If enabled, known mdadm/mdcheck and similar RAID check schedulers are disabled.

Template: better-raid-check/start_now
Type: boolean
Default: false
Description: Start a RAID check immediately after install
 If enabled, one RAID check run starts now in addition to timer scheduling.

Template: better-raid-check/interval_risk_confirm
Type: boolean
Default: false
Description: Interval is longer than two months
 Scheduling checks less often than every two months increases the chance
 that corruption remains undetected longer. Continue with this interval?
EOF

cat > "$PKG_DIR/DEBIAN/config" <<'EOF'
#!/bin/bash
set -e

. /usr/share/debconf/confmodule
db_version 2.0 || true

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_interval_spec() {
  [[ "$1" =~ ^[1-9][0-9]*[dM]$ ]]
}

interval_over_risk_threshold() {
  local interval="$1"
  local count="${interval%[dM]}"
  local unit="${interval: -1}"

  if [[ "$unit" == "M" && "$count" -gt 2 ]]; then
    return 0
  fi

  if [[ "$unit" == "d" && "$count" -gt 60 ]]; then
    return 0
  fi

  return 1
}

bool_from_zero_one() {
  if [[ "$1" == "1" ]]; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

seed_from_existing_config() {
  local cfg="/etc/default/raid-check-serial"
  local val

  [[ -r "$cfg" ]] || return 0

  val="$(grep -E '^MAX_HDD_CONCURRENT=' "$cfg" | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [[ -n "$val" ]] && db_set better-raid-check/hdd_limit "$val" || true

  val="$(grep -E '^MAX_SSD_CONCURRENT=' "$cfg" | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [[ -n "$val" ]] && db_set better-raid-check/ssd_limit "$val" || true

  val="$(grep -E '^MAX_NVM_CONCURRENT=' "$cfg" | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [[ -n "$val" ]] && db_set better-raid-check/nvm_limit "$val" || true

  val="$(grep -E '^MERGE_SSD_NVM_CLASSES=' "$cfg" | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [[ -n "$val" ]] && db_set better-raid-check/merge_ssd_nvm "$(bool_from_zero_one "$val")" || true

  val="$(grep -E '^SLEEP_SECS=' "$cfg" | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [[ -n "$val" ]] && db_set better-raid-check/sleep_secs "$val" || true

  val="$(grep -E '^DRY_RUN=' "$cfg" | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [[ -n "$val" ]] && db_set better-raid-check/dry_run "$(bool_from_zero_one "$val")" || true

  if [[ -r /etc/systemd/system/raid-check-serial.timer.d/override.conf ]]; then
    val="$(grep -E '^OnUnitActiveSec=' /etc/systemd/system/raid-check-serial.timer.d/override.conf | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    if [[ "$val" =~ ^[1-9][0-9]*d$ ]]; then
      db_set better-raid-check/check_interval "$val" || true
    fi
  fi
}

reset_seen() {
  local q="$1"
  db_fset "$q" seen false || true
}

seed_from_existing_config

while true; do
  db_input medium better-raid-check/check_interval || true
  db_input medium better-raid-check/hdd_limit || true
  db_input medium better-raid-check/ssd_limit || true
  db_input medium better-raid-check/nvm_limit || true
  db_input medium better-raid-check/merge_ssd_nvm || true
  db_input medium better-raid-check/sleep_secs || true
  db_input medium better-raid-check/dry_run || true
  db_input medium better-raid-check/disable_conflicts || true
  db_input low better-raid-check/start_now || true
  db_go || true

  db_get better-raid-check/check_interval
  CHECK_INTERVAL="$RET"
  db_get better-raid-check/hdd_limit
  HDD_LIMIT="$RET"
  db_get better-raid-check/ssd_limit
  SSD_LIMIT="$RET"
  db_get better-raid-check/nvm_limit
  NVM_LIMIT="$RET"
  db_get better-raid-check/sleep_secs
  SLEEP_SECS="$RET"

  if ! is_interval_spec "$CHECK_INTERVAL"; then
    db_set better-raid-check/check_interval 1M || true
    reset_seen better-raid-check/check_interval
    continue
  fi

  if ! is_non_negative_int "$HDD_LIMIT"; then
    db_set better-raid-check/hdd_limit 1 || true
    reset_seen better-raid-check/hdd_limit
    continue
  fi

  if ! is_non_negative_int "$SSD_LIMIT"; then
    db_set better-raid-check/ssd_limit 1 || true
    reset_seen better-raid-check/ssd_limit
    continue
  fi

  if ! is_non_negative_int "$NVM_LIMIT"; then
    db_set better-raid-check/nvm_limit 1 || true
    reset_seen better-raid-check/nvm_limit
    continue
  fi

  if ! is_positive_int "$SLEEP_SECS"; then
    db_set better-raid-check/sleep_secs 20 || true
    reset_seen better-raid-check/sleep_secs
    continue
  fi

  if interval_over_risk_threshold "$CHECK_INTERVAL"; then
    db_set better-raid-check/interval_risk_confirm false || true
    reset_seen better-raid-check/interval_risk_confirm
    db_input high better-raid-check/interval_risk_confirm || true
    db_go || true
    db_get better-raid-check/interval_risk_confirm
    if [[ "$RET" != "true" ]]; then
      reset_seen better-raid-check/check_interval
      continue
    fi
  fi

  break
done

db_stop
exit 0
EOF
chmod 0755 "$PKG_DIR/DEBIAN/config"

cat > "$PKG_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e

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
  local timer_override_dir="/etc/systemd/system/raid-check-serial.timer.d"
  local timer_override_file="$timer_override_dir/override.conf"
  local count unit month_list

  count="${interval%[dM]}"
  unit="${interval: -1}"

  mkdir -p "$timer_override_dir"

  if [[ "$unit" == "d" ]]; then
    cat > "$timer_override_file" <<EOT
[Timer]
OnCalendar=
OnUnitActiveSec=${count}d
OnBootSec=15min
EOT
    return 0
  fi

  if [[ "$count" == "1" ]]; then
    rm -f "$timer_override_file"
    rmdir "$timer_override_dir" 2>/dev/null || true
    return 0
  fi

  if (( count >= 2 && count <= 12 )); then
    month_list="$(month_list_for_step "$count")"
    cat > "$timer_override_file" <<EOT
[Timer]
OnUnitActiveSec=
OnCalendar=
OnCalendar=*-${month_list}-01 03:00:00
EOT
    return 0
  fi

  cat > "$timer_override_file" <<EOT
[Timer]
OnCalendar=
OnUnitActiveSec=${count}month
OnBootSec=15min
EOT
}

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
    return 0
  fi

  mapfile -t unique_timers < <(printf '%s\n' "${candidates[@]}" | awk 'NF' | sort -u)
  for timer in "${unique_timers[@]}"; do
    systemctl disable --now "$timer" >/dev/null 2>&1 || true
    systemctl mask "$timer" >/dev/null 2>&1 || true
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
      fi
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
  done
}

to_zero_one() {
  local v="$1"
  if [[ "$v" == "true" || "$v" == "1" ]]; then
    printf '%s\n' 1
  else
    printf '%s\n' 0
  fi
}

if [ "$1" = "configure" ]; then
  if [[ -r /usr/share/debconf/confmodule ]]; then
    . /usr/share/debconf/confmodule
    db_version 2.0 || true
  fi

  db_get better-raid-check/check_interval || true
  CHECK_INTERVAL="${RET:-1M}"
  db_get better-raid-check/hdd_limit || true
  HDD_LIMIT="${RET:-1}"
  db_get better-raid-check/ssd_limit || true
  SSD_LIMIT="${RET:-1}"
  db_get better-raid-check/nvm_limit || true
  NVM_LIMIT="${RET:-1}"
  db_get better-raid-check/merge_ssd_nvm || true
  MERGE_SSD_NVM="$(to_zero_one "${RET:-false}")"
  db_get better-raid-check/sleep_secs || true
  SLEEP_SECS="${RET:-20}"
  db_get better-raid-check/dry_run || true
  DRY_RUN="$(to_zero_one "${RET:-false}")"
  db_get better-raid-check/disable_conflicts || true
  DISABLE_CONFLICTS="$(to_zero_one "${RET:-true}")"
  db_get better-raid-check/start_now || true
  START_NOW="$(to_zero_one "${RET:-false}")"

  cat > /etc/default/raid-check-serial <<EOCFG
SLEEP_SECS=$SLEEP_SECS
DRY_RUN=$DRY_RUN
MAX_HDD_CONCURRENT=$HDD_LIMIT
MAX_SSD_CONCURRENT=$SSD_LIMIT
MAX_NVM_CONCURRENT=$NVM_LIMIT
MERGE_SSD_NVM_CLASSES=$MERGE_SSD_NVM
MAX_ROTATIONAL_CONCURRENT=$HDD_LIMIT
MAX_NVME_CONCURRENT=$NVM_LIMIT
EOCFG

  if [[ "$CHECK_INTERVAL" == "1M" ]]; then
    rm -f /etc/systemd/system/raid-check-serial.timer.d/override.conf
    rmdir /etc/systemd/system/raid-check-serial.timer.d 2>/dev/null || true
  else
    write_timer_override "$CHECK_INTERVAL"
  fi

  if [[ "$DISABLE_CONFLICTS" == "1" ]]; then
    disable_conflicting_systemd_timers
    disable_conflicting_cron_jobs
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now raid-check-serial.timer >/dev/null 2>&1 || true

  if [[ "$START_NOW" == "1" ]]; then
    systemctl start --no-block raid-check-serial.service >/dev/null 2>&1 || true
  fi

  if [[ -r /usr/share/debconf/confmodule ]]; then
    db_stop || true
  fi
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/postinst"

cat > "$PKG_DIR/DEBIAN/prerm" <<'EOF'
#!/bin/bash
set -e

if [ "$1" = "remove" ]; then
  systemctl disable --now raid-check-serial.timer >/dev/null 2>&1 || true
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/prerm"

cat > "$PKG_DIR/DEBIAN/postrm" <<'EOF'
#!/bin/bash
set -e

if [[ "$1" == "purge" ]]; then
  rm -f /etc/default/raid-check-serial
  rm -f /etc/systemd/system/raid-check-serial.timer.d/override.conf
  rmdir /etc/systemd/system/raid-check-serial.timer.d 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [[ -r /usr/share/debconf/confmodule ]]; then
    . /usr/share/debconf/confmodule
    db_purge || true
    db_stop || true
  fi
fi
EOF
chmod 0755 "$PKG_DIR/DEBIAN/postrm"

cat > "$PKG_DIR/usr/share/doc/$PKG_NAME/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: better-raid-check
Source: local

Files: *
Copyright: 2026 better-raid-check contributors
License: GPL-3+

License: GPL-3+
 This package is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 .
 On Debian systems, the complete text of the GNU General Public License
 version 3 can be found in /usr/share/common-licenses/GPL-3.
EOF

mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"
OUT_DEB="$SCRIPT_DIR/$OUTPUT_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"

dpkg-deb --build --root-owner-group "$PKG_DIR" "$OUT_DEB" >/dev/null

echo "Built package: $OUT_DEB"
