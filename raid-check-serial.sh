#!/usr/bin/env bash
set -euo pipefail

# Per-class concurrency policy (override with environment variables):
# - MAX_HDD_CONCURRENT
# - MAX_SSD_CONCURRENT
# - MAX_NVM_CONCURRENT
#
# Backward-compatible aliases:
# - MAX_ROTATIONAL_CONCURRENT -> MAX_HDD_CONCURRENT
# - MAX_NVME_CONCURRENT -> MAX_NVM_CONCURRENT

SLEEP_SECS="${SLEEP_SECS:-20}"
DRY_RUN="${DRY_RUN:-0}"
MAX_HDD_CONCURRENT="${MAX_HDD_CONCURRENT:-${MAX_ROTATIONAL_CONCURRENT:-1}}"
MAX_SSD_CONCURRENT="${MAX_SSD_CONCURRENT:-1}"
MAX_NVM_CONCURRENT="${MAX_NVM_CONCURRENT:-${MAX_NVME_CONCURRENT:-1}}"
MERGE_SSD_NVM_CLASSES="${MERGE_SSD_NVM_CLASSES:-0}"

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_settings() {
  local var value

  for var in MAX_HDD_CONCURRENT MAX_SSD_CONCURRENT MAX_NVM_CONCURRENT; do
    value="${!var}"
    if ! is_non_negative_int "$value"; then
      echo "Invalid $var: $value (expected non-negative integer)" >&2
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

  if [[ "$MERGE_SSD_NVM_CLASSES" != "0" && "$MERGE_SSD_NVM_CLASSES" != "1" ]]; then
    echo "Invalid MERGE_SSD_NVM_CLASSES: $MERGE_SSD_NVM_CLASSES (expected 0 or 1)" >&2
    exit 1
  fi
}

normalize_md_name() {
  local in="$1"
  in="${in#/dev/}"
  in="${in#md/}"
  if [[ "$in" != md* ]]; then
    in="md$in"
  fi
  printf '%s\n' "$in"
}

base_block_dev() {
  local part="$1"
  case "$part" in
    nvme*n*p*) printf '%s\n' "${part%p*}" ;;
    mmcblk*p*) printf '%s\n' "${part%p*}" ;;
    *) printf '%s\n' "${part%%[0-9]*}" ;;
  esac
}

discover_redundant_arrays() {
  local md level
  for path in /sys/block/md*; do
    [[ -d "$path" ]] || continue
    md="$(basename "$path")"
    [[ -r "$path/md/level" && -r "$path/md/sync_action" ]] || continue
    level="$(<"$path/md/level")"
    case "$level" in
      raid1|raid4|raid5|raid6|raid10) printf '%s\n' "$md" ;;
    esac
  done | sort -V
}

classify_md() {
  local md="$1"
  local has_hdd=0
  local has_ssd=0
  local has_nvm=0
  local slave base rot

  for slave_path in /sys/block/"$md"/slaves/*; do
    [[ -e "$slave_path" ]] || continue
    slave="$(basename "$slave_path")"
    base="$(base_block_dev "$slave")"
    if [[ -r /sys/block/"$base"/queue/rotational ]]; then
      rot="$(<"/sys/block/$base/queue/rotational")"
      if [[ "$rot" == "1" ]]; then
        has_hdd=1
      else
        case "$base" in
          nvme*) has_nvm=1 ;;
          *) has_ssd=1 ;;
        esac
      fi
    else
      # Unknown media type: treat as rotational to keep policy conservative.
      has_hdd=1
    fi
  done

  # Conservative precedence for mixed members (slowest wins): hdd > ssd > nvm.
  if (( has_hdd == 1 )); then
    printf '%s\n' hdd
  elif (( has_ssd == 1 )); then
    printf '%s\n' ssd
  elif (( has_nvm == 1 )); then
    if [[ "$MERGE_SSD_NVM_CLASSES" == "1" ]]; then
      printf '%s\n' ssd
    else
      printf '%s\n' nvm
    fi
  else
    printf '%s\n' hdd
  fi
}

read_sync_action() {
  local md="$1"
  cat "/sys/block/$md/md/sync_action"
}

set_sync_action() {
  local md="$1"
  local action="$2"
  local path="/sys/block/$md/md/sync_action"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] $md <= $action"
    return 0
  fi

  if [[ "$EUID" -eq 0 ]]; then
    echo "$action" > "$path"
  else
    echo "$action" | sudo tee "$path" >/dev/null
  fi
}

start_check_if_idle() {
  local md="$1"
  local action
  action="$(read_sync_action "$md")"
  if [[ "$action" != "idle" ]]; then
    echo "[$md] busy ($action), postponed"
    return 1
  fi

  set_sync_action "$md" check
  echo "[$md] check started"
  return 0
}

print_md_progress() {
  local md="$1"
  grep -A1 "^$md " /proc/mdstat || true
}

reap_finished() {
  local -n running_ref="$1"
  local class_name="$2"
  local -a still_running=()
  local md

  for md in "${running_ref[@]}"; do
    if [[ "$(read_sync_action "$md")" == "idle" ]]; then
      echo "[$md] finished ($class_name)"
    else
      still_running+=("$md")
    fi
  done

  running_ref=("${still_running[@]}")
}

launch_for_class() {
  local -n queue_ref="$1"
  local -n running_ref="$2"
  local limit="$3"
  local class_name="$4"
  local capacity slot qlen attempt started md

  (( limit > 0 )) || return 0

  capacity=$(( limit - ${#running_ref[@]} ))
  (( capacity > 0 )) || return 0

  for ((slot=0; slot<capacity; slot++)); do
    started=0
    qlen=${#queue_ref[@]}
    (( qlen > 0 )) || break

    # Try each queued array once to avoid spinning forever on busy arrays.
    for ((attempt=0; attempt<qlen; attempt++)); do
      md="${queue_ref[0]}"
      queue_ref=("${queue_ref[@]:1}")
      if start_check_if_idle "$md"; then
        running_ref+=("$md")
        started=1
        break
      fi
      queue_ref+=("$md")
    done

    (( started == 1 )) || break
  done

  return 0
}

print_running_progress() {
  local -n running_ref="$1"
  local md
  for md in "${running_ref[@]}"; do
    print_md_progress "$md"
  done
}

has_remaining_work() {
  local -n q_hdd="$1"
  local -n q_ssd="$2"
  local -n q_nvm="$3"
  local -n r_hdd="$4"
  local -n r_ssd="$5"
  local -n r_nvm="$6"

  (( ${#q_hdd[@]} > 0 || ${#q_ssd[@]} > 0 || ${#q_nvm[@]} > 0 || \
     ${#r_hdd[@]} > 0 || ${#r_ssd[@]} > 0 || ${#r_nvm[@]} > 0 ))
}

main() {
  local -a requested=()
  local -a clean_arrays=()
  local -a hdd_queue=()
  local -a ssd_queue=()
  local -a nvm_queue=()
  local -a hdd_running=()
  local -a ssd_running=()
  local -a nvm_running=()
  local -a skipped_arrays=()
  local md class

  validate_settings

  if (( $# > 0 )); then
    requested=("$@")
  else
    mapfile -t requested < <(discover_redundant_arrays)
  fi

  if (( ${#requested[@]} == 0 )); then
    echo "No RAID arrays found."
    exit 0
  fi

  for item in "${requested[@]}"; do
    md="$(normalize_md_name "$item")"
    if [[ -r "/sys/block/$md/md/sync_action" ]]; then
      clean_arrays+=("$md")
    else
      echo "Skipping $md (no /sys/block/$md/md/sync_action)"
    fi
  done

  if (( ${#clean_arrays[@]} == 0 )); then
    echo "No eligible RAID arrays to check."
    exit 0
  fi

  echo "Queue build:"
  for md in "${clean_arrays[@]}"; do
    class="$(classify_md "$md")"
    case "$class" in
      hdd)
        hdd_queue+=("$md")
        echo "  $md -> hdd"
        ;;
      ssd)
        ssd_queue+=("$md")
        echo "  $md -> ssd"
        ;;
      nvm)
        nvm_queue+=("$md")
        echo "  $md -> nvm"
        ;;
      *)
        hdd_queue+=("$md")
        echo "  $md -> unknown (treated as hdd)"
        ;;
    esac
  done

  if (( MAX_HDD_CONCURRENT == 0 && ${#hdd_queue[@]} > 0 )); then
    echo "Skipping hdd arrays because MAX_HDD_CONCURRENT=0"
    skipped_arrays+=("${hdd_queue[@]}")
    hdd_queue=()
  fi

  if (( MAX_SSD_CONCURRENT == 0 && ${#ssd_queue[@]} > 0 )); then
    echo "Skipping ssd arrays because MAX_SSD_CONCURRENT=0"
    skipped_arrays+=("${ssd_queue[@]}")
    ssd_queue=()
  fi

  if (( MAX_NVM_CONCURRENT == 0 && ${#nvm_queue[@]} > 0 )); then
    echo "Skipping nvm arrays because MAX_NVM_CONCURRENT=0"
    skipped_arrays+=("${nvm_queue[@]}")
    nvm_queue=()
  fi

  while has_remaining_work hdd_queue ssd_queue nvm_queue hdd_running ssd_running nvm_running; do
    reap_finished hdd_running hdd
    reap_finished ssd_running ssd
    reap_finished nvm_running nvm

    launch_for_class hdd_queue hdd_running "$MAX_HDD_CONCURRENT" hdd
    launch_for_class ssd_queue ssd_running "$MAX_SSD_CONCURRENT" ssd
    launch_for_class nvm_queue nvm_running "$MAX_NVM_CONCURRENT" nvm

    print_running_progress hdd_running
    print_running_progress ssd_running
    print_running_progress nvm_running

    if has_remaining_work hdd_queue ssd_queue nvm_queue hdd_running ssd_running nvm_running; then
      sleep "$SLEEP_SECS"
    fi
  done

  if (( ${#skipped_arrays[@]} > 0 )); then
    echo "Skipped arrays: ${skipped_arrays[*]}"
  fi

  echo "All queued RAID checks completed (limits: hdd=$MAX_HDD_CONCURRENT, ssd=$MAX_SSD_CONCURRENT, nvm=$MAX_NVM_CONCURRENT)."
}

main "$@"
