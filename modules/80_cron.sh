#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Cron (v0.9.8.4)
# Menu module for DaST.
# Concept inspired by SUSE's YaST.
# Released under the GPLv3.
# Designed mainly for Ubuntu. Some Debian-derived distros may have limited module
# support. See the docs for more information on which modules will load on your system.
# ---------------------------------------------------------------------------------------
# WARNING(!) DaST IS CURRENTLY IN ITS INFANCY AND SHOULD BE CONSIDERED ALPHA SOFTWARE!
# DaST MAY CONTAIN BUGS LEADING TO SYSTEM BREAKAGE AND DATA DESTRUCTION. YOU SHOULD
# REVIEW THE CODE YOURSELF BEFORE RUNNING IT. DaST COMES WITH ABSOLUTELY NO WARRANTY,
# EXPRESS OR IMPLIED, AND THE AUTHORS OR COPYRIGHT HOLDERS SHALL NOT BE LIABLE FOR ANY 
# LOSS OR DAMAGES RESULTING FROM USING THESE SCRIPTS. YOU USE AT YOUR OWN RISK. THESE
# SCRIPTS ARE PROVIDED "AS IS" AND IN "GOOD FAITH" WITH THE INTENTION OF IMPROVING
# UBUNTU/DEBIAN FOR EVERYONE.
# ---------------------------------------------------------------------------------------
# DaST requires bash. This module is intended to be sourced by DaST.
# ---------------------------------------------------------------------------------------

module_id="CRON"
module_title="🕒 Cron"
MODULE_CRON_TITLE="🕒 Cron"

# -----------------------------------------------------------------------------
# Best-effort helper loading (run/run_capture/mktemp_safe)
# - Won't hard-fail if the helper can't be found, so the module still
#   registers and at least menus/info work.
# -----------------------------------------------------------------------------

cron__try_source_helper() {
  # If run() already exists, we're good.
  declare -F run >/dev/null 2>&1 && return 0

  local here lib_try

  # 1) If DaST defines a lib dir, use it.
  if [[ -n "${DAST_LIB_DIR:-}" && -r "${DAST_LIB_DIR}/dast_helper.sh" ]]; then
    # shellcheck source=/dev/null
    source "${DAST_LIB_DIR}/dast_helper.sh" && return 0
  fi

  # 2) Try relative to this module file (best effort)
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  if [[ -n "$here" ]]; then
    for lib_try in \
      "${here}/../lib/dast_helper.sh" \
      "${here}/../../lib/dast_helper.sh" \
      "${here}/dast_helper.sh"
    do
      if [[ -r "$lib_try" ]]; then
        # shellcheck source=/dev/null
        source "$lib_try" && return 0
      fi
    done
  fi

  return 1
}

cron__try_source_helper || true

# Fallbacks if helper not loaded
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  mktemp_safe() { mktemp; }
fi
if ! declare -F run >/dev/null 2>&1; then
  run() { "$@"; }
fi
if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { "$@"; }
fi


# -----------------------------------------------------------------------------
# Logging / Debug (uses DaST core helpers if available)
# -----------------------------------------------------------------------------

cron__app_root() {
  # Best effort: module lives in [app]/modules, so go one level up.
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  [[ -n "$here" ]] || return 1
  echo "$(cd -- "$here/.." 2>/dev/null && pwd)"
}

cron__log() {
  # Usage: cron__log LEVEL message...
  local level="${1:-INFO}"; shift || true
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$level" "$module_id" "$*"
  fi
}

cron__dbg() {
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$module_id" "$*"
  fi
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

cron__is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

cron__need_root() {
  local what="$1"
  if cron__is_root; then
    return 0
  fi
  ui_msgbox "$MODULE_CRON_TITLE" "❌ Root required.\n\nThis action needs root:\n$what"
  return 1
}

cron__ts() { date +"%Y%m%d_%H%M%S"; }


cron__backup_dir() {
  # Backups live under the DaST app tree (no /tmp fallback).
  # Default: [app]/logs/cron_backups
  local app base
  if [[ -n "${LOG_DIR:-}" ]]; then
    base="${LOG_DIR%/}/cron_backups"
  else
    app="$(cron__app_root 2>/dev/null || true)"
    base="${app%/}/logs/cron_backups"
  fi

  if [[ -z "$base" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Unable to determine DaST logs directory for cron backups."
    return 1
  fi

  if ! run mkdir -p "$base" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Failed to create cron backup directory:

$base"
    return 1
  fi

  # Best-effort permission repair (match config-dir behaviour: keep it writable for the invoker).
  if cron__is_root && [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER:-}" ]]; then
    if [[ "$base" == "/home/${SUDO_USER}"/* ]]; then
      run chown -R "${SUDO_USER}:${SUDO_USER}" "$base" >/dev/null 2>&1 || true
    fi
  fi

  cron__dbg "cron backup dir: $base"
  echo "$base"
}



cron__backup_file() {
  local src="$1" label="$2"
  local bdir dst

  bdir="$(cron__backup_dir)" || return 1
  dst="$bdir/${label}_$(cron__ts).bak"

  run cp -a -- "$src" "$dst" >/dev/null 2>&1 || return 1
  cron__log INFO "Backup created: $dst"
  echo "$dst"
}



cron__backup_stdin() {
  local label="$1"
  local bdir dst

  bdir="$(cron__backup_dir)" || return 1
  dst="$bdir/${label}_$(cron__ts).bak"

  cat >"$dst"
  cron__log INFO "Backup created: $dst"
  echo "$dst"
}


cron__sanitize_filename() {
  # allow: a-zA-Z0-9._-
  local s="$1"
  [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]]
}

cron__is_blank_or_comment() {
  local line="$1"
  [[ -z "${line//[[:space:]]/}" ]] && return 0
  [[ "$line" =~ ^[[:space:]]*# ]] && return 0
  return 1
}

cron__validate_user_line() {
  local line="$1"
  cron__is_blank_or_comment "$line" && return 0

  # allow env assignments
  if [[ "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]]; then
    return 0
  fi

  # @special
  if [[ "$line" =~ ^[[:space:]]*@([A-Za-z]+)[[:space:]]+.+$ ]]; then
    return 0
  fi

  # standard: 5 fields + command (>= 6 tokens)
  local -a tok
  read -r -a tok <<<"$line"
  (( ${#tok[@]} >= 6 )) || return 1
  return 0
}

cron__validate_crond_line() {
  local line="$1"
  cron__is_blank_or_comment "$line" && return 0

  # allow env assignments
  if [[ "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]]; then
    return 0
  fi

  # @special + user + command
  if [[ "$line" =~ ^[[:space:]]*@([A-Za-z]+)[[:space:]]+[A-Za-z0-9._-]+[[:space:]]+.+$ ]]; then
    return 0
  fi

  # standard: 5 fields + user + command (>= 7 tokens)
  local -a tok
  read -r -a tok <<<"$line"
  (( ${#tok[@]} >= 7 )) || return 1
  return 0
}

cron__validate_whole_user_crontab() {
  local file="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    cron__validate_user_line "$line" || return 1
  done <"$file"
  return 0
}

cron__validate_whole_crond_file() {
  local file="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    cron__validate_crond_line "$line" || return 1
  done <"$file"
  return 0
}

cron__diff_to_file() {
  local a="$1" b="$2" out="$3"
  if command -v diff >/dev/null 2>&1; then
    diff -u --label "BEFORE" --label "AFTER" "$a" "$b" >"$out" 2>/dev/null || true
  else
    {
      echo "diff not available; showing AFTER only:"
      echo "--------------------------------------"
      cat "$b"
    } >"$out"
  fi
}

# -----------------------------------------------------------------------------
# Cron backend detection (supports multiple cron implementations)
# -----------------------------------------------------------------------------

CRON_HAS_CRONTAB=0
CRON_HAS_CROND=0
CRON_HAS_SYSTEM_CRONTAB=0

cron__detect_backends() {
  CRON_HAS_CRONTAB=0
  CRON_HAS_CROND=0
  CRON_HAS_SYSTEM_CRONTAB=0

  command -v crontab >/dev/null 2>&1 && CRON_HAS_CRONTAB=1
  [[ -d "/etc/cron.d" ]] && CRON_HAS_CROND=1
  [[ -r "/etc/crontab" ]] && CRON_HAS_SYSTEM_CRONTAB=1
}

cron__backend_summary() {
  # human string for INFO and for "refuse to load" guardrails
  local bits=()
  (( CRON_HAS_CRONTAB == 1 )) && bits+=("✅ crontab") || bits+=("❌ crontab")
  (( CRON_HAS_CROND == 1 )) && bits+=("✅ /etc/cron.d") || bits+=("❌ /etc/cron.d")
  (( CRON_HAS_SYSTEM_CRONTAB == 1 )) && bits+=("✅ /etc/crontab") || bits+=("❌ /etc/crontab")
  printf '%s' "${bits[*]}"
}

# -----------------------------------------------------------------------------
# Schedule Picker
# -----------------------------------------------------------------------------
cron__schedule_picker() {
  # echoes schedule string to stdout
  # sets CRON_SCHED_EXPLAIN global
  CRON_SCHED_EXPLAIN=""

  local mode
  mode="$(ui_menu "$MODULE_CRON_TITLE" "Pick a schedule style:" \
    "SIMPLE"   "🧭 Simple presets" \
    "WIZARD"   "🪄 Wizard" \
    "ADVANCED" "📐 Custom (Advanced)" \
    "@REBOOT"  "🥾 Run once at system boot" \
    "BACK"     "🔙 Back"
  )" || return 1

  [[ "$mode" == "BACK" || -z "$mode" ]] && return 1

  case "$mode" in
    "SIMPLE")
      local p
      p="$(ui_menu "$MODULE_CRON_TITLE" "Pick a preset:" \
        "EVERY_5"   "🕒 Every 5 minutes" \
        "EVERY_15"  "🕒 Every 15 minutes" \
        "HOURLY"    "🕐 Hourly (minute 0)" \
        "DAILY"     "🌙 Daily (02:00)" \
        "WEEKLY"    "📅 Weekly (Sun 03:00)" \
        "MONTHLY"   "🗓️ Monthly (1st at 04:00)" \
        "BACK"      "🔙 Back"
      )" || return 1

      [[ "$p" == "BACK" || -z "$p" ]] && return 1

      case "$p" in
        "EVERY_5")   echo "*/5 * * * *";  CRON_SCHED_EXPLAIN="Every 5 minutes";;
        "EVERY_15")  echo "*/15 * * * *"; CRON_SCHED_EXPLAIN="Every 15 minutes";;
        "HOURLY")    echo "0 * * * *";    CRON_SCHED_EXPLAIN="At minute 0 of every hour";;
        "DAILY")     echo "0 2 * * *";    CRON_SCHED_EXPLAIN="Every day at 02:00";;
        "WEEKLY")    echo "0 3 * * 0";    CRON_SCHED_EXPLAIN="Every Sunday at 03:00";;
        "MONTHLY")   echo "0 4 1 * *";    CRON_SCHED_EXPLAIN="On the 1st of every month at 04:00";;
      esac
      ;;
"WIZARD")
  # Full add wizard is handled by the caller (user crontab) because it also
  # collects the command and offers "Edit schedule" in the review step.
  #
  # For callers that only need a schedule token (e.g. /etc/cron.d builder),
  # they should detect the magic token and run cron__wizard_build_schedule().
  echo "__WIZARD__"
  CRON_SCHED_EXPLAIN="Wizard (step-by-step builder)"
  ;;
    "ADVANCED")
      local m h dom mon dow
      m="$(ui_inputbox "$MODULE_CRON_TITLE" "Minute field (0-59, *, */n, lists):" "*")" || return 1
      h="$(ui_inputbox "$MODULE_CRON_TITLE" "Hour field (0-23, *, */n, lists):" "*")" || return 1
      dom="$(ui_inputbox "$MODULE_CRON_TITLE" "Day of month (1-31, *, lists):" "*")" || return 1
      mon="$(ui_inputbox "$MODULE_CRON_TITLE" "Month (1-12, *, lists):" "*")" || return 1
      dow="$(ui_inputbox "$MODULE_CRON_TITLE" "Day of week (0-7, 0/7=Sun, *, lists):" "*")" || return 1
      echo "$m $h $dom $mon $dow"
      CRON_SCHED_EXPLAIN="Custom schedule: $m $h $dom $mon $dow"
      ;;
    "@REBOOT")
      echo "@reboot"
      CRON_SCHED_EXPLAIN="Runs once each time the system boots"
      ;;
  esac
}


# -----------------------------------------------------------------------------
# Wizard schedule builder (5-field cron)
# -----------------------------------------------------------------------------

cron__wizard_field_mode_menu() {
  # Args: field_label, hint_text
  local field="$1" hint="$2"

  ui_menu "$MODULE_CRON_TITLE" "$hint" \
    "ANY"      "Any (*)" \
    "EVERYN"   "Every N (*/N)" \
    "SPECIFIC" "Specific values" \
    "RANGE"    "Range (A-B)" \
    "BACK"     "🔙 Back" || return 1
}

cron__wizard__validate_int_in_range() {
  local v="$1" min="$2" max="$3"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  (( v >= min && v <= max )) || return 1
  return 0
}

cron__wizard__sanitize_csv_ints() {
  # Args: csv, min, max
  # Echoes normalized csv (commas, no spaces) or empty on failure.
  local csv="$1" min="$2" max="$3"
  local out=() x

  # Remove spaces and split on commas.
  csv="${csv//[[:space:]]/}"
  [[ -n "$csv" ]] || return 1

  IFS=',' read -r -a out <<<"$csv"

  local norm=() seen=() i
  for x in "${out[@]}"; do
    [[ -n "$x" ]] || continue
    cron__wizard__validate_int_in_range "$x" "$min" "$max" || return 1
    # de-dupe while preserving order (cheap for small lists)
    local dup=0
    for i in "${seen[@]}"; do
      [[ "$i" == "$x" ]] && dup=1 && break
    done
    (( dup == 1 )) && continue
    seen+=("$x")
    norm+=("$x")
  done

  (( ${#norm[@]} > 0 )) || return 1

  local IFS=,
  printf '%s' "${norm[*]}"
}

cron__wizard_build_field() {
  # Args: field_key
  # Echoes the cron token for that field.
  local key="$1"
  local mode hint min max

  case "$key" in
    "MIN") hint=$'Minute\n\nChoose when the job runs (0-59).'; min=0; max=59;;
    "HOUR") hint=$'Hour\n\nChoose which hours (0-23).'; min=0; max=23;;
    "DOM") hint=$'Day of Month\n\nChoose which day of the month (1-31).'; min=1; max=31;;
    "MON") hint=$'Month\n\nChoose which months (1-12).'; min=1; max=12;;
    "DOW") hint=$'Day of Week\n\nChoose which days (0-7, 0/7 = Sun).'; min=0; max=7;;
    *) return 1;;
  esac

  while true; do
    mode="$(cron__wizard_field_mode_menu "$key" "$hint")" || return 1
    [[ "$mode" == "BACK" || -z "$mode" ]] && return 2

    case "$mode" in
      "ANY")
        echo "*"
        return 0
        ;;
      "EVERYN")
        local n
        n="$(ui_inputbox "$MODULE_CRON_TITLE" "$hint\n\nEvery N (enter N):" "1")" || return 2
        cron__wizard__validate_int_in_range "$n" 1 "$max" || { ui_msgbox "$MODULE_CRON_TITLE" "Invalid N.\n\nExpected an integer in range 1-$max."; continue; }
        echo "*/$n"
        return 0
        ;;
      "SPECIFIC")
        local v norm
        if [[ "$key" == "DOM" ]]; then
          v="$(ui_inputbox "$MODULE_CRON_TITLE" "$hint\n\nEnter a single value ($min-$max):" "$min")" || return 2
          cron__wizard__validate_int_in_range "$v" "$min" "$max" || { ui_msgbox "$MODULE_CRON_TITLE" "Invalid value.\n\nExpected an integer in range $min-$max."; continue; }
          echo "$v"
          return 0
        fi

        v="$(ui_inputbox "$MODULE_CRON_TITLE" "$hint\n\nEnter comma-separated values ($min-$max):" "")" || return 2
        norm="$(cron__wizard__sanitize_csv_ints "$v" "$min" "$max" 2>/dev/null)" || { ui_msgbox "$MODULE_CRON_TITLE" "Invalid list.\n\nUse comma-separated integers in range $min-$max.\n\nExample: $min,$((min+1)),$((min+2))"; continue; }
        echo "$norm"
        return 0
        ;;
      "RANGE")
        local a b
        a="$(ui_inputbox "$MODULE_CRON_TITLE" "$hint\n\nRange start (A):" "$min")" || return 2
        b="$(ui_inputbox "$MODULE_CRON_TITLE" "$hint\n\nRange end (B):" "$max")" || return 2
        cron__wizard__validate_int_in_range "$a" "$min" "$max" || { ui_msgbox "$MODULE_CRON_TITLE" "Invalid A.\n\nExpected an integer in range $min-$max."; continue; }
        cron__wizard__validate_int_in_range "$b" "$min" "$max" || { ui_msgbox "$MODULE_CRON_TITLE" "Invalid B.\n\nExpected an integer in range $min-$max."; continue; }
        (( a <= b )) || { ui_msgbox "$MODULE_CRON_TITLE" "Invalid range.\n\nA must be <= B."; continue; }
        echo "$a-$b"
        return 0
        ;;
    esac
  done
}

cron__wizard_build_schedule() {
  # Echoes a 5-field schedule string.
  local min hour dom mon dow
  local rc
  local step=1

  while true; do
    case "$step" in
      1) min="$(cron__wizard_build_field "MIN")"; rc=$?;;
      2) hour="$(cron__wizard_build_field "HOUR")"; rc=$?;;
      3) dom="$(cron__wizard_build_field "DOM")"; rc=$?;;
      4) mon="$(cron__wizard_build_field "MON")"; rc=$?;;
      5) dow="$(cron__wizard_build_field "DOW")"; rc=$?;;
      *) rc=1;;
    esac

    if (( rc == 0 )); then
      ((step++))
      if (( step == 6 )); then
        local sched="$min $hour $dom $mon $dow"
        CRON_SCHED_EXPLAIN="Wizard schedule: $sched"
        echo "$sched"
        return 0
      fi
      continue
    fi

    # rc==2 means "Back"
    if (( rc == 2 )); then
      if (( step == 1 )); then
        return 1
      fi
      ((step--))
      continue
    fi

    return 1
  done
}

cron__add_wizard() {
  # Args: tmp_crontab_file user
  local tmp="$1" user="$2"

  local sched cmd newline

  while true; do
    sched="$(cron__wizard_build_schedule)" || return 0

    cmd="$(ui_inputbox "$MODULE_CRON_TITLE" "Enter the command exactly as it would appear in crontab:" "")" || return 0
    if [[ -z "${cmd//[[:space:]]/}" ]]; then
      ui_msgbox "$MODULE_CRON_TITLE" "Command cannot be empty."
      continue
    fi

    newline="$sched $cmd"

    local msg
    msg=$'Review cron job:\n\n'
    msg+="$newline"
    msg+=$'\n\nConfirm to install, or edit the schedule.'

    # 3-button confirm: Confirm (default NO), Edit schedule, Cancel
    local _had_errexit=0
    [[ $- == *e* ]] && _had_errexit=1
    set +e
    dast_ui_dialog --defaultno --yes-label "Confirm" --extra-button --extra-label "Edit schedule" --no-label "Cancel" \
      --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE" \
      --yesno "$msg" 0 0
    local rc=$?
    [[ $_had_errexit -eq 1 ]] && set -e

    # rc: 0=Confirm, 1=Cancel, 3=Extra (Edit schedule)
    if (( rc == 3 )); then
      continue
    fi
    (( rc == 0 )) || return 0

    break
  done

  # Install via the existing user-crontab append/validate/install path.
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  local new; new="$(mktemp_safe)"
  {
    cat "$tmp"
    [[ -s "$tmp" ]] && echo
    printf '%s\n' "$newline"
  } >"$new"

  if ! cron__validate_whole_user_crontab "$new"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nThis looks like malformed cron syntax.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$new"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$new"; then
    mv -f "$new" "$tmp"
    cron__msgbox_back "$MODULE_CRON_TITLE" "The entry has been added." || true
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\n${CRON_LAST_INSTALL_ERR:-}\n\nNothing should have changed.\nBackup:\n${bkp:-none}"
    rm -f "$new"
  fi
}

# -----------------------------------------------------------------------------
# User selection
# -----------------------------------------------------------------------------
cron__pick_user() {
  # Arg1: 1 = exclude root from picker.
  local exclude_root="${1:-0}"

  if ! cron__is_root; then
    id -un
    return 0
  fi

  local items=() name uid shell
  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$shell" =~ (false|nologin)$ ]] && continue

    if (( exclude_root == 1 && uid == 0 )); then
      continue
    fi

    if (( uid == 0 )) || (( uid >= 1000 && uid < 60000 )); then
      items+=("$name" "uid=$uid")
    fi
  done </etc/passwd

  ui_menu "$MODULE_CRON_TITLE" "Select a user crontab to manage:" "${items[@]}" "BACK" "🔙 Back" || return 0
}


cron__load_user_crontab_to_file() {
  local user="$1" out="$2"
  local out_txt rc

  # Always create destination file so downstream logic is predictable.
  : >"$out"

  # Under set -e we must not hard-exit.
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e

  # First pass: suppress stderr entirely so nothing can leak to the terminal.
  if [[ "$user" == "root" ]]; then
    out_txt="$(crontab -l 2>/dev/null)"; rc=$?
  else
    out_txt="$(crontab -u "$user" -l 2>/dev/null)"; rc=$?
  fi

  [[ $_had_errexit -eq 1 ]] && set -e

  # rc==0: normal. rc!=0 with 'no crontab for': treat as valid empty.
  if (( rc != 0 )); then
    local err_txt
    if [[ "$user" == "root" ]]; then
      err_txt="$(run_capture crontab -l)" || true
    else
      err_txt="$(run_capture crontab -u "$user" -l)" || true
    fi

    if [[ "$err_txt" == *"no crontab for"* ]]; then
      return 0
    fi

    ui_msgbox "$MODULE_CRON_TITLE" "❌ Failed to read crontab for '$user'.

${err_txt:-Unknown error}" || true
    return 1
  fi

  if [[ -n "$out_txt" ]]; then
    printf '%s\n' "$out_txt" >"$out"
  fi
}


cron__install_user_crontab_from_file() {
  local user="$1" file="$2"

  # NOTE: DaST runs as root. We still target the selected user's crontab via -u.
  # For root, prefer plain `crontab <file>` for symmetry with `crontab -l`.
  local err rc
  err="$(mktemp_safe)"

  # Under set -e we must not hard-exit if crontab fails.
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  if [[ "$user" == "root" ]]; then
    crontab "$file" >"/dev/null" 2>"$err"; rc=$?
  else
    crontab -u "$user" "$file" >"/dev/null" 2>"$err"; rc=$?
  fi
  [[ $_had_errexit -eq 1 ]] && set -e

  CRON_LAST_INSTALL_ERR=""
  if (( rc != 0 )); then
    CRON_LAST_INSTALL_ERR="$(cat "$err" 2>/dev/null || true)"
  fi

  rm -f "$err"
  return $rc
}

# -----------------------------------------------------------------------------
# User crontab menu
# -----------------------------------------------------------------------------
cron__user_menu() {
  local user="$1"
  ui_menu "$MODULE_CRON_TITLE" "User crontab: $user" \
    "VIEW"    "👀 View crontab" \
    "ADD"     "🆕 Add job (guided)" \
    "TOGGLE"  "🧷 Toggle line (comment)" \
    "DELETE"  "❌ Delete line" \
    "ITEMS"   "🧩 Edit cron items (interactive)" \
    "RAW"     "🧾 Raw edit full crontab" \
    "CLEAR"   "💣 Clear all jobs" \
    "BACK"    "🔙 Back" || return 0
}


cron__user_view() {
  local tmp="$1" user="$2"

  if [[ ! -s "$tmp" ]]; then
    # Back-labelled info dialog (TUI-only).
    local _had_errexit=0
    [[ $- == *e* ]] && _had_errexit=1
    set +e
    dast_ui_dialog --ok-label "Back" --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"       --msgbox $'No crontab exists for this user yet.\n\nIt\x27s empty or missing.\n\nUse Add to create the first entry.' 14 80
    [[ $_had_errexit -eq 1 ]] && set -e
    return 0
  fi

  ui_textbox "$MODULE_CRON_TITLE" "$tmp" || true
}


cron__user_delete() {
  local tmp="$1" user="$2"

  local items=() i=0 line label
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((++i))
    label="$line"
    [[ -z "$label" ]] && label="(blank)"
    label="${label//$'\t'/ }"
    label="${label:0:60}"
    items+=("$i" "$label")
  done <"$tmp"

  if (( ${#items[@]} == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "Crontab is empty."
    return 0
  fi

  local pick
  pick="$(ui_menu "$MODULE_CRON_TITLE" "Pick a line number to DELETE:" "${items[@]}" "BACK" "🔙 Back")" || return 0
  [[ "$pick" == "BACK" || -z "$pick" ]] && return 0

  local cur
  cur="$(sed -n "${pick}p" "$tmp")"

  # Create a backup first so we can show the exact path in the confirm dialog.
  # This does not change the active crontab.
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  local msg
  msg=$'Line '$pick$' will be DELETED:\n\n'
  msg+=$'LINE: '
  msg+="$cur"
  msg+=$'\n\nBackup will be written to:\n'
  msg+="${bkp:-none}"
  msg+=$'\n\nProceed?'

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
       --backtitle "$DAST_BACKTITLE" --title "$MODULE_CRON_TITLE" \
       --yesno "$msg" 0 0; then
    return 0
  fi

  local newfile; newfile="$(mktemp_safe)"
  awk -v n="$pick" 'NR!=n {print}' "$tmp" >"$newfile"

  if ! cron__validate_whole_user_crontab "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed after delete.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$newfile"; then
    mv -f "$newfile" "$tmp"
    cron__msgbox_back "$MODULE_CRON_TITLE" "The entry has been deleted." || true
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\n${CRON_LAST_INSTALL_ERR:-}\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
  fi
}

cron__user_add() {
  local tmp="$1" user="$2"

  local sched cmd tag newline
  sched="$(cron__schedule_picker)" || return 0
if [[ "$sched" == "__WIZARD__" ]]; then
  cron__add_wizard "$tmp" "$user"
  return 0
fi

  cmd="$(ui_inputbox "$MODULE_CRON_TITLE" "Command to run:\n\nExample:\n/usr/local/sbin/my-script.sh --flag" "")" || return 0

  # Optional inputboxes can return non-zero (including when OK is pressed with an empty value).
  # Guard against set -e hard-exit (and restore previous errexit state).
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  tag="$(ui_inputbox "$MODULE_CRON_TITLE" "Optional comment tag (shown above the job):\n\nTip: leave blank and press OK to skip." "DaST Cron")"
  [[ $_had_errexit -eq 1 ]] && set -e
  # Treat any non-fatal result as "no tag".
  # (We cannot reliably distinguish Cancel vs OK+empty here, so both skip the tag.)
  tag="${tag:-}"

  newline=""
  if [[ -n "${tag// /}" ]]; then
    newline+="# $tag"$'\n'
  fi
  newline+="$sched $cmd"

  local review; review="$(mktemp_safe)"
  {
    echo "About to add this job to user: $user"
    echo
    echo "Schedule: $sched"
    echo "Meaning : ${CRON_SCHED_EXPLAIN:-}"
    echo "Command : $cmd"
    echo
    echo "This will append:"
    echo "-----------------------------------"
    echo "$newline"
    echo "-----------------------------------"
    echo
    echo "DaST will backup the existing crontab first."
  } >"$review"

  # Use a single confirm dialog that contains the full review text, so the user
  # gets an explicit Apply/Back choice (default is NO) instead of a textbox-only
  # screen with a single button.
  local msg
  msg="$(cat "$review" 2>/dev/null || true)"
  rm -f "$review"

  # Create a backup first so the confirm dialog can show the exact path.
  # This does not change the active crontab.
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  msg+="

Backup will be written to:
${bkp:-none}"

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
      --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE" \
      --yesno "$msg" 0 0; then
    return 0
  fi


  # Append
  local new; new="$(mktemp_safe)"
  {
    cat "$tmp"
    [[ -s "$tmp" ]] && echo
    printf '%s\n' "$newline"
  } >"$new"

  if ! cron__validate_whole_user_crontab "$new"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nThis looks like malformed cron syntax.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$new"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$new"; then
    mv -f "$new" "$tmp"
    cron__msgbox_back "$MODULE_CRON_TITLE" "The entry has been added." || true
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\n${CRON_LAST_INSTALL_ERR:-}\n\nNothing should have changed.\nBackup:\n${bkp:-none}"
    rm -f "$new"
  fi
}

cron__user_toggle() {
  local tmp="$1" user="$2"

  local items=() i=0 line label
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((++i))
    label="$line"
    [[ -z "$label" ]] && label="(blank)"
    label="${label//$'\t'/ }"
    label="${label:0:60}"
    items+=("$i" "$label")
  done <"$tmp"

  if (( ${#items[@]} == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "Crontab is empty."
    return 0
  fi

  local pick
  pick="$(ui_menu "$MODULE_CRON_TITLE" "Pick a line number to comment/uncomment:" "${items[@]}" "BACK" "🔙 Back")" || return 0
  [[ "$pick" == "BACK" || -z "$pick" ]] && return 0

  local cur new
  cur="$(sed -n "${pick}p" "$tmp")"
  if [[ "$cur" =~ ^[[:space:]]*# ]]; then
    new="$(echo "$cur" | sed 's/^[[:space:]]*#\s\{0,1\}//')"
  else
    new="# $cur"
  fi

  # Create a backup first so the confirm dialog can show the exact path.
  # This does not change the active crontab.
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  local msg
  msg=$'Line '$pick$' will be toggled (comment/uncomment):

'
  msg+=$'BEFORE: '
  msg+="$cur"
  msg+=$'
AFTER : '
  msg+="$new"
  msg+=$'

Backup will be written to:
'
  msg+="${bkp:-none}"
  msg+=$'

Proceed?'

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back"       --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"       --yesno "$msg" 0 0; then
    return 0
  fi

  local newfile; newfile="$(mktemp_safe)"
  awk -v n="$pick" -v repl="$new" 'NR==n{$0=repl} {print}' "$tmp" >"$newfile"

  if ! cron__validate_whole_user_crontab "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed after toggle.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$newfile"; then
    mv -f "$newfile" "$tmp"
    cron__msgbox_back "$MODULE_CRON_TITLE" "✅ Applied.\n\nBackup:\n${bkp:-none}" || true
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\n${CRON_LAST_INSTALL_ERR:-}\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
  fi
}


# -----------------------------------------------------------------------------
# Interactive cron items editor (Option A)
# -----------------------------------------------------------------------------

cron__items__trim_leading_ws() {
  local s="$1"
  # Remove leading spaces/tabs only
  s="${s#${s%%[!$' \t']*}}"
  printf '%s' "$s"
}

cron__items__is_env_line() {
  local s="$1"
  [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]]
}

cron__items__safe_field() {
  local f="$1"
  # Allow digits, '*', '/', '-', ',', and letters for names.
  [[ "$f" =~ ^[0-9A-Za-z*/,-]+$ ]]
}

cron__items__parse_file() {
  # Args: file
  # Outputs (globals):
  #   CRON_ITEMS_RAW_LINES[]
  #   CRON_ITEMS_TAGS[]
  #   CRON_ITEMS_TYPES[]
  #   CRON_ITEMS_SCHEDS[]
  #   CRON_ITEMS_CMDS[]
  #   CRON_ITEMS_KEYS[]
  #   CRON_ITEMS_VALUES[]
  #   CRON_ITEMS_COMMENTS[]
  #   CRON_ITEMS_OMITTED_COUNT

  local file="$1"

  CRON_ITEMS_RAW_LINES=()
  CRON_ITEMS_TAGS=()
  CRON_ITEMS_TYPES=()
  CRON_ITEMS_SCHEDS=()
  CRON_ITEMS_CMDS=()
  CRON_ITEMS_KEYS=()
  CRON_ITEMS_VALUES=()
  CRON_ITEMS_COMMENTS=()
  CRON_ITEMS_OMITTED_COUNT=0

  mapfile -t CRON_ITEMS_RAW_LINES <"$file" 2>/dev/null || true

  local i line tline tag
  for i in "${!CRON_ITEMS_RAW_LINES[@]}"; do
    line="${CRON_ITEMS_RAW_LINES[$i]}"

    # Classify blanks early (we preserve them but do not list them to reduce clutter).
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi

    # Omit multiline continuations
    if [[ "$line" =~ \\$ ]]; then
      ((++CRON_ITEMS_OMITTED_COUNT))
      continue
    fi

    # Omit percent semantics
    if [[ "$line" == *"%"* ]]; then
      ((++CRON_ITEMS_OMITTED_COUNT))
      continue
    fi

    tline="$(cron__items__trim_leading_ws "$line")"
    tag=$(printf 'L%04d' $((i+1)))

    # Comment
    if [[ "$tline" =~ ^# ]]; then
      CRON_ITEMS_TAGS+=("$tag")
      CRON_ITEMS_TYPES+=("comment")
      CRON_ITEMS_SCHEDS+=("")
      CRON_ITEMS_CMDS+=("")
      CRON_ITEMS_KEYS+=("")
      CRON_ITEMS_VALUES+=("")
      CRON_ITEMS_COMMENTS+=("$tline")
      continue
    fi

    # Environment line
    if cron__items__is_env_line "$tline"; then
      local key="${tline%%=*}"
      local val="${tline#*=}"
      CRON_ITEMS_TAGS+=("$tag")
      CRON_ITEMS_TYPES+=("env")
      CRON_ITEMS_SCHEDS+=("")
      CRON_ITEMS_CMDS+=("")
      CRON_ITEMS_KEYS+=("$key")
      CRON_ITEMS_VALUES+=("$val")
      CRON_ITEMS_COMMENTS+=("")
      continue
    fi

    # Special job
    if [[ "$tline" =~ ^@ ]]; then
      if [[ "$tline" =~ ^@(reboot|hourly|daily|weekly|monthly|yearly|annually)[[:space:]]+(.+)$ ]]; then
        local special="@${BASH_REMATCH[1]}"
        local cmd="${BASH_REMATCH[2]}"
        CRON_ITEMS_TAGS+=("$tag")
        CRON_ITEMS_TYPES+=("job_special")
        CRON_ITEMS_SCHEDS+=("$special")
        CRON_ITEMS_CMDS+=("$cmd")
        CRON_ITEMS_KEYS+=("")
        CRON_ITEMS_VALUES+=("")
        CRON_ITEMS_COMMENTS+=("")
      else
        ((++CRON_ITEMS_OMITTED_COUNT))
      fi
      continue
    fi

    # Standard job: 5 fields + command
    local -a toks=()
    read -r -a toks <<<"$tline"
    if (( ${#toks[@]} < 6 )); then
      ((++CRON_ITEMS_OMITTED_COUNT))
      continue
    fi

    local f0="${toks[0]}" f1="${toks[1]}" f2="${toks[2]}" f3="${toks[3]}" f4="${toks[4]}"
    if ! cron__items__safe_field "$f0" || ! cron__items__safe_field "$f1" || ! cron__items__safe_field "$f2" || ! cron__items__safe_field "$f3" || ! cron__items__safe_field "$f4"; then
      ((++CRON_ITEMS_OMITTED_COUNT))
      continue
    fi

    local sched="$f0 $f1 $f2 $f3 $f4"
    local cmd
    # Command is everything after the first 5 schedule fields.
    cmd="${toks[@]:5}"
    if [[ -z "$cmd" ]]; then
      ((++CRON_ITEMS_OMITTED_COUNT))
      continue
    fi

    CRON_ITEMS_TAGS+=("$tag")
    CRON_ITEMS_TYPES+=("job_standard")
    CRON_ITEMS_SCHEDS+=("$sched")
    CRON_ITEMS_CMDS+=("$cmd")
    CRON_ITEMS_KEYS+=("")
    CRON_ITEMS_VALUES+=("")
    CRON_ITEMS_COMMENTS+=("")
  done
}

cron__items__idx_from_tag() {
  local tag="$1"
  # Tag format: L0001 (line number)
  local n="${tag#L}"
  [[ "$n" =~ ^[0-9]{4}$ ]] || { echo ""; return 0; }
  echo $((10#$n - 1))
}

cron__items__render_display() {
  local i="$1"
  local tag="${CRON_ITEMS_TAGS[$i]}"
  local idx; idx="$(cron__items__idx_from_tag "$tag")"
  local line_no=$((idx+1))

  local typ="${CRON_ITEMS_TYPES[$i]}"
  local text=""

  case "$typ" in
    "job_standard")
      text="✅ [$line_no] ${CRON_ITEMS_SCHEDS[$i]}  ${CRON_ITEMS_CMDS[$i]}"
      ;;
    "job_special")
      text="✅ [$line_no] ${CRON_ITEMS_SCHEDS[$i]}  ${CRON_ITEMS_CMDS[$i]}"
      ;;
    "env")
      text="⚙️ [$line_no]  ${CRON_ITEMS_KEYS[$i]}=${CRON_ITEMS_VALUES[$i]}"
      ;;
    "comment")
      # Keep short
      text="💬 [$line_no]  ${CRON_ITEMS_COMMENTS[$i]}"
      ;;
    *)
      text="[$line_no]"
      ;;
  esac

  # Tidy whitespace and clamp length for menu
  text="${text//$'\t'/ }"
  if (( ${#text} > 90 )); then
    text="${text:0:87}..."
  fi

  printf '%s' "$text"
}

cron__user_items_editor() {
  local tmp="$1" user="$2"

  # Work on a staging copy and only apply when asked.
  local work orig diff
  work="$(mktemp_safe)"
  orig="$(mktemp_safe)"
  diff="$(mktemp_safe)"
  cp -f "$tmp" "$work"
  cp -f "$tmp" "$orig"

  while true; do
    cron__items__parse_file "$work"

    local menu_text=$'Cron items for: '"$user"$'\nNote: commands may be normalised when edited here.'
    if (( CRON_ITEMS_OMITTED_COUNT > 0 )); then
      menu_text=$'⚠️ Some cron lines could not be safely parsed and are not shown here.\nUse 🧾 Raw edit full crontab to view/edit them.\n\n'"$menu_text"
    fi

    local items=() i
    for i in "${!CRON_ITEMS_TAGS[@]}"; do
      items+=("${CRON_ITEMS_TAGS[$i]}" "$(cron__items__render_display "$i")")
    done

    # Footer actions
    items+=("APPLY" "✅ Diff + apply changes")
    items+=("BACK"  "🔙 Back")

    local pick
    pick="$(cron__menu_dialog "$MODULE_CRON_TITLE" "$menu_text" "${items[@]}")" || break
    [[ -z "$pick" || "$pick" == "BACK" ]] && break

    if [[ "$pick" == "APPLY" ]]; then
      cron__diff_to_file "$orig" "$work" "$diff"

      if [[ ! -s "$diff" ]]; then
        ui_msgbox "$MODULE_CRON_TITLE" "No changes to apply."
        continue
      fi

      ui_textbox "$MODULE_CRON_TITLE" "$diff" || true

      if ! cron__validate_whole_user_crontab "$work"; then
        ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nNothing applied."
        continue
      fi

      local bkp
      bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

      if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back"           --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"           --yesno "Final confirm:

Apply these changes to $user now?

Backup will be written to:
${bkp:-none}" 0 0; then
        continue
      fi

      if cron__install_user_crontab_from_file "$user" "$work"; then
        cp -f "$work" "$tmp"
        cp -f "$work" "$orig"
        ui_msgbox "$MODULE_CRON_TITLE" "✅ Applied.\n\nBackup:\n${bkp:-none}"
      else
        ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\n${CRON_LAST_INSTALL_ERR:-}\n\nBackup:\n${bkp:-none}"
      fi

      continue
    fi

    # Find selected item index
    local sel=-1
    for i in "${!CRON_ITEMS_TAGS[@]}"; do
      if [[ "${CRON_ITEMS_TAGS[$i]}" == "$pick" ]]; then
        sel=$i
        break
      fi
    done
    (( sel < 0 )) && continue

    local typ="${CRON_ITEMS_TYPES[$sel]}"
    local idx
    idx="$(cron__items__idx_from_tag "$pick")"

    # Reload work lines for mutation
    local -a WORK_LINES=()
    mapfile -t WORK_LINES <"$work" 2>/dev/null || true

    # Safety: idx must exist
    if (( idx < 0 || idx >= ${#WORK_LINES[@]} )); then
      continue
    fi

    # Action menu
    local act
    case "$typ" in
      "job_standard")
        act="$(ui_menu "$MODULE_CRON_TITLE" "Cron line $((idx+1))" \
          "EDIT_S" "✏️ Edit schedule" \
          "EDIT_C" "✏️ Edit command" \
          "DUP"    "📋 Duplicate" \
          "DEL"    "❌ Delete line" \
          "BACK"   "🔙 Back")" || act="BACK"
        ;;
      "job_special")
        act="$(ui_menu "$MODULE_CRON_TITLE" "Cron line $((idx+1))" \
          "EDIT_S" "✏️ Edit special (@daily etc)" \
          "EDIT_C" "✏️ Edit command" \
          "DUP"    "📋 Duplicate" \
          "DEL"    "❌ Delete line" \
          "BACK"   "🔙 Back")" || act="BACK"
        ;;
      "env")
        act="$(ui_menu "$MODULE_CRON_TITLE" "Cron line $((idx+1))" \
          "EDIT_V" "✏️ Edit value" \
          "DUP"    "📋 Duplicate" \
          "DEL"    "❌ Delete line" \
          "BACK"   "🔙 Back")" || act="BACK"
        ;;
      "comment")
        act="$(ui_menu "$MODULE_CRON_TITLE" "Cron line $((idx+1))" \
          "EDIT_T" "✏️ Edit text" \
          "DUP"    "📋 Duplicate" \
          "DEL"    "❌ Delete line" \
          "BACK"   "🔙 Back")" || act="BACK"
        ;;
      *)
        act="BACK"
        ;;
    esac

    [[ -z "$act" || "$act" == "BACK" ]] && continue

    if [[ "$act" == "DEL" ]]; then
      if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
          --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE" \
          --yesno "Delete this line from the working buffer?

Line: $((idx+1))

(This does not apply to the real crontab until you choose ✅ Diff + apply.)" 0 0; then
        continue
      fi
      unset 'WORK_LINES[idx]'
      WORK_LINES=("${WORK_LINES[@]}")
    elif [[ "$act" == "DUP" ]]; then
      if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
          --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE" \
          --yesno "Duplicate this line in the working buffer?

Line: $((idx+1))

(This does not apply to the real crontab until you choose ✅ Diff + apply.)" 0 0; then
        continue
      fi
      WORK_LINES=("${WORK_LINES[@]:0:idx+1}" "${WORK_LINES[idx]}" "${WORK_LINES[@]:idx+1}")
    elif [[ "$act" == "EDIT_C" ]]; then
      local cur_cmd="${CRON_ITEMS_CMDS[$sel]}"
      local new_cmd
      new_cmd="$(ui_inputbox "$MODULE_CRON_TITLE" "Command:" "$cur_cmd")" || continue
      if [[ "$typ" == "job_special" ]]; then
        WORK_LINES[idx]="${CRON_ITEMS_SCHEDS[$sel]} $new_cmd"
      else
        WORK_LINES[idx]="${CRON_ITEMS_SCHEDS[$sel]} $new_cmd"
      fi
    elif [[ "$act" == "EDIT_S" ]]; then
      if [[ "$typ" == "job_special" ]]; then
        local cur_sp="${CRON_ITEMS_SCHEDS[$sel]}"
        local sp
        sp="$(ui_menu "$MODULE_CRON_TITLE" "Choose special schedule:" \
          "@reboot"   "@reboot" \
          "@hourly"   "@hourly" \
          "@daily"    "@daily" \
          "@weekly"   "@weekly" \
          "@monthly"  "@monthly" \
          "@yearly"   "@yearly" \
          "@annually" "@annually" \
          "BACK"      "🔙 Back")" || sp="BACK"
        [[ "$sp" == "BACK" || -z "$sp" ]] && continue
        WORK_LINES[idx]="$sp ${CRON_ITEMS_CMDS[$sel]}"
      else
        local sched="${CRON_ITEMS_SCHEDS[$sel]}"
        local m h dom mon dow
        m="${sched%% *}"; sched="${sched#* }"
        h="${sched%% *}"; sched="${sched#* }"
        dom="${sched%% *}"; sched="${sched#* }"
        mon="${sched%% *}"; dow="${sched#* }"

        m="$(ui_inputbox "$MODULE_CRON_TITLE" "Minute field:" "$m")" || continue
        h="$(ui_inputbox "$MODULE_CRON_TITLE" "Hour field:" "$h")" || continue
        dom="$(ui_inputbox "$MODULE_CRON_TITLE" "Day of month field:" "$dom")" || continue
        mon="$(ui_inputbox "$MODULE_CRON_TITLE" "Month field:" "$mon")" || continue
        dow="$(ui_inputbox "$MODULE_CRON_TITLE" "Day of week field:" "$dow")" || continue

        if ! cron__items__safe_field "$m" || ! cron__items__safe_field "$h" || ! cron__items__safe_field "$dom" || ! cron__items__safe_field "$mon" || ! cron__items__safe_field "$dow"; then
          ui_msgbox "$MODULE_CRON_TITLE" "❌ That schedule contains unsupported characters.\n\nNothing changed."
          continue
        fi

        WORK_LINES[idx]="$m $h $dom $mon $dow ${CRON_ITEMS_CMDS[$sel]}"
      fi
    elif [[ "$act" == "EDIT_V" ]]; then
      local key="${CRON_ITEMS_KEYS[$sel]}"
      local cur_val="${CRON_ITEMS_VALUES[$sel]}"
      local new_val
      new_val="$(ui_inputbox "$MODULE_CRON_TITLE" "Value for $key:" "$cur_val")" || continue
      WORK_LINES[idx]="$key=$new_val"
    elif [[ "$act" == "EDIT_T" ]]; then
      local cur="${CRON_ITEMS_COMMENTS[$sel]}"
      # Strip leading '#'
      local cur_text="${cur#\#}"
      cur_text="$(cron__items__trim_leading_ws "$cur_text")"
      local new_text
      new_text="$(ui_inputbox "$MODULE_CRON_TITLE" "Comment text:" "$cur_text")" || continue
      WORK_LINES[idx]="# $new_text"
    fi

    # Write back work file
    : >"$work"
    for i in "${!WORK_LINES[@]}"; do
      printf '%s\n' "${WORK_LINES[$i]}" >>"$work"
    done
  done

  rm -f "$work" "$orig" "$diff" 2>/dev/null || true
}

cron__user_raw_edit() {
  local tmp="$1" user="$2"

  local edited newfile diff
  edited="$(mktemp_safe)"
  newfile="$(mktemp_safe)"
  diff="$(mktemp_safe)"
  cp -f "$tmp" "$edited"

  # Raw edit opens a real terminal editor (outside dialog).
  # IMPORTANT: do NOT run editors through the usual run() wrapper, and do NOT
  # assume $EDITOR is a single word (many users set: "nano -w").
  local editor
  if [[ -n "${VISUAL:-}" ]]; then
    editor="${VISUAL}"
  else
    editor="${EDITOR:-}"
  fi

  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then editor="nano"
    elif command -v vi >/dev/null 2>&1; then editor="vi"
    else editor=""
    fi
  fi

  if [[ -z "$editor" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "No editor found (VISUAL/EDITOR not set, and nano/vi not present)."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  # Reject clearly unsafe editor strings (we are root in DaST).
  # Allow simple commands and basic flags only.
  if [[ "$editor" =~ [\;\|\&\>\<\`\$\(\)] ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "EDITOR looks unsafe or contains shell metacharacters:

$editor

Set EDITOR to a simple command (e.g. nano, vi) or a command plus basic flags (e.g. nano -w)."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  # Split editor into argv (simple whitespace split; safe, but no quote support).
  local -a eargv
  read -r -a eargv <<<"$editor"

  if (( ${#eargv[@]} == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "Unable to parse editor from:

$editor"
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  if ! command -v "${eargv[0]}" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "Editor command not found:

${eargv[0]}

Full setting:
$editor"
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_msgbox "$MODULE_CRON_TITLE" "Editor will open now:

$editor

When you exit, DaST will show a diff and ask to apply."

  # Editors are interactive and may return non-zero for reasons we do not want
  # to treat as fatal. Guard errexit.
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  "${eargv[@]}" "$edited"
  local erc=$?
  [[ $_had_errexit -eq 1 ]] && set -e

  cp -f "$edited" "$newfile"
  cron__diff_to_file "$tmp" "$newfile" "$diff"

  if [[ ! -s "$diff" ]]; then
    if (( erc != 0 )); then
      ui_msgbox "$MODULE_CRON_TITLE" "No changes to apply.

Note: editor exited with code $erc."
    else
      ui_msgbox "$MODULE_CRON_TITLE" "No changes to apply."
    fi
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_textbox "$MODULE_CRON_TITLE" "$diff" || true

  if ! cron__validate_whole_user_crontab "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.

Edits look malformed.
Nothing applied."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  # Create a backup first so the confirm dialog can show the exact path.
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back"       --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"       --yesno "Final confirm:

Apply edited crontab to $user now?

Backup will be written to:
${bkp:-none}" 0 0; then
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$newfile"; then
    mv -f "$newfile" "$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "The entry has been updated."
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install.

${CRON_LAST_INSTALL_ERR:-}

Backup:
${bkp:-none}"
  fi

  rm -f "$edited" "$diff" 2>/dev/null || true
}

cron__user_clear() {
  local tmp="$1" user="$2"

  # Create a backup first so the confirm dialogs can show the exact path.
  # This does not change the active crontab.
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
      --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE" \
      --yesno "DANGER ZONE:

Clear ALL cron jobs for $user?

Backup will be written to:
${bkp:-none}" 0 0; then
    return 0
  fi
  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
      --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE" \
      --yesno "Last chance:

Really clear everything for $user?

Backup will be written to:
${bkp:-none}" 0 0; then
    return 0
  fi

  local empty; empty="$(mktemp_safe)"
  : >"$empty"

  if cron__install_user_crontab_from_file "$user" "$empty"; then
    : >"$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Cleared.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to clear.\n\n${CRON_LAST_INSTALL_ERR:-}\n\nBackup:\n${bkp:-none}"
  fi

  rm -f "$empty"
}

cron__user_loop() {
  local user="${1:-}" tmp

  if [[ -z "$user" ]]; then
    user="$(cron__pick_user 1)" || return 0
    [[ "$user" == "BACK" || -z "$user" ]] && return 0
  fi

  tmp="$(mktemp_safe)"
  if ! cron__load_user_crontab_to_file "$user" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  while true; do
    local action
    action="$(cron__user_menu "$user")" || break
    [[ -z "$action" || "$action" == "BACK" ]] && break

    case "$action" in
      "VIEW")    cron__user_view "$tmp" "$user" ;;
      "ADD")     cron__user_add "$tmp" "$user" ;;
      "TOGGLE")  cron__user_toggle "$tmp" "$user" ;;
      "DELETE")  cron__user_delete "$tmp" "$user" ;;
      "ITEMS")   cron__user_items_editor "$tmp" "$user" ;;
      "RAW")     cron__user_raw_edit "$tmp" "$user" ;;
      "CLEAR")   cron__user_clear "$tmp" "$user" ;;
    esac
  done

  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# /etc/cron.d management
# -----------------------------------------------------------------------------
cron__crond_menu() {
  ui_menu "$MODULE_CRON_TITLE" "Manage /etc/cron.d:" \
    "LIST"   "📃 List files" \
    "VIEW"   "👀 View file" \
    "EDIT"   "📝 Edit file" \
    "NEW"    "🆕 New file (guided)" \
    "DELETE" "❌ Delete file" \
    "BACK"   "🔙 Back" || return 0
}

cron__crond_pick_file() {
  local dir="/etc/cron.d"
  local items=() f
  for f in "$dir"/*; do
    [[ -e "$f" ]] || continue
    [[ -f "$f" ]] || continue
    items+=("$(basename "$f")" "$f")
  done

  if (( ${#items[@]} == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "No files found in /etc/cron.d"
    return 0
  fi

  ui_menu "$MODULE_CRON_TITLE" "Pick a /etc/cron.d file:" "${items[@]}" "BACK" "🔙 Back" || return 0
}

cron__crond_list() {
  local tmp; tmp="$(mktemp_safe)"
  local out_txt rc

  : >"$tmp"
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  out_txt="$(run_capture ls -la /etc/cron.d 2>/dev/null)"; rc=$?
  [[ $_had_errexit -eq 1 ]] && set -e
  if [[ -n "$out_txt" ]]; then
    printf '%s\n' "$out_txt" >"$tmp"
  else
    printf '%s\n' "Unable to list /etc/cron.d" >"$tmp"
  fi

  ui_textbox "$MODULE_CRON_TITLE" "$tmp" || true
  rm -f "$tmp"
}

cron__crond_view() {
  local f; f="$(cron__crond_pick_file)"
  [[ -z "$f" || "$f" == "BACK" ]] && return 0
  ui_textbox "$MODULE_CRON_TITLE" "/etc/cron.d/$f" || true
}

cron__crond_edit() {
  cron__need_root "Edit /etc/cron.d files" || return 0

  local f; f="$(cron__crond_pick_file)"
  [[ -z "$f" || "$f" == "BACK" ]] && return 0

  local path="/etc/cron.d/$f"
  [[ -r "$path" ]] || { ui_msgbox "$MODULE_CRON_TITLE" "Cannot read: $path"; return 0; }

  local edited newfile diff
  edited="$(mktemp_safe)"
  newfile="$(mktemp_safe)"
  diff="$(mktemp_safe)"
  cp -f "$path" "$edited"

  # Raw edit opens a real terminal editor (outside dialog).
  local editor
  if [[ -n "${VISUAL:-}" ]]; then
    editor="${VISUAL}"
  else
    editor="${EDITOR:-}"
  fi

  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then editor="nano"
    elif command -v vi >/dev/null 2>&1; then editor="vi"
    else editor=""
    fi
  fi

  if [[ -z "$editor" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "No editor found (VISUAL/EDITOR not set, and nano/vi not present)."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  # Reject clearly unsafe editor strings (we are root in DaST).
  if [[ "$editor" =~ [\;\|\&\>\<\`\$\(\)] ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "EDITOR looks unsafe or contains shell metacharacters:

$editor

Set EDITOR to a simple command (e.g. nano, vi) or a command plus basic flags (e.g. nano -w)."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  local -a eargv
  read -r -a eargv <<<"$editor"

  if (( ${#eargv[@]} == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "Unable to parse editor from:

$editor"
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  if ! command -v "${eargv[0]}" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "Editor command not found:

${eargv[0]}

Full setting:
$editor"
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_msgbox "$MODULE_CRON_TITLE" "Editor will open now:

$editor

When you exit, DaST will show a diff and ask to apply."

  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  "${eargv[@]}" "$edited"
  local erc=$?
  [[ $_had_errexit -eq 1 ]] && set -e

  cp -f "$edited" "$newfile"
  cron__diff_to_file "$path" "$newfile" "$diff"

  if [[ ! -s "$diff" ]]; then
    if (( erc != 0 )); then
      ui_msgbox "$MODULE_CRON_TITLE" "No changes to apply.

Note: editor exited with code $erc."
    else
      ui_msgbox "$MODULE_CRON_TITLE" "No changes to apply."
    fi
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_textbox "$MODULE_CRON_TITLE" "$diff" || true

  if ! cron__validate_whole_crond_file "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.

Edits look malformed for /etc/cron.d format.
Nothing applied."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  # Create a backup first so the confirm dialog can show the exact path.
  local bkp
  bkp="$(cron__backup_file "$path" "crond_${f}" 2>/dev/null || true)"

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back"       --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"       --yesno "Final confirm:

Apply edited file to:
$path

Backup will be written to:
${bkp:-none}" 0 0; then
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  if run install -o root -g root -m 0644 "$newfile" "$path" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "The entry has been added."
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to write file.

Backup:
${bkp:-none}"
  fi

  rm -f "$edited" "$newfile" "$diff"
}

cron__crond_new() {
  cron__need_root "Create /etc/cron.d file" || return 0

  local name
  name="$(ui_inputbox "$MODULE_CRON_TITLE" "New file name (no spaces, allowed: A-Z a-z 0-9 . _ -):" "dast_custom")" || return 0

  if ! cron__sanitize_filename "$name"; then
    ui_msgbox "$MODULE_CRON_TITLE" "Invalid filename.\n\nAllowed: A-Z a-z 0-9 . _ -"
    return 0
  fi

  local path="/etc/cron.d/$name"
  local bkp=""
  if [[ -e "$path" ]]; then
    # Create the backup now so the confirm can show the exact path.
    bkp="$(cron__backup_file "$path" "crond_${name}" 2>/dev/null || true)"
    if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back"         --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"         --yesno "File already exists:
$path

Overwrite?

Backup will be written to:
${bkp:-none}" 0 0; then
      return 0
    fi
  fi

  local sched user cmd comment
  sched="$(cron__schedule_picker)" || return 0
if [[ "$sched" == "__WIZARD__" ]]; then
  sched="$(cron__wizard_build_schedule)" || return 0
fi

  user="$(ui_inputbox "$MODULE_CRON_TITLE" "User to run as (cron.d requires a user field):" "root")" || return 0
  cmd="$(ui_inputbox "$MODULE_CRON_TITLE" "Command to run:" "")" || return 0

  # Optional inputboxes can return non-zero (including when OK is pressed with an empty value).
  # Guard against set -e hard-exit (and restore previous errexit state).
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  comment="$(ui_inputbox "$MODULE_CRON_TITLE" "Optional comment tag:\n\nTip: leave blank and press OK to skip." "DaST Cron")"
  local _rc=$?
  [[ $_had_errexit -eq 1 ]] && set -e
  comment="${comment:-}"

  local tmp; tmp="$(mktemp_safe)"
  {
    echo "# ${comment:-DaST Cron}"
    echo "# Created by DaST Cron module on $(date -Is 2>/dev/null || date)"
    echo "# Schedule: $sched"
    echo "# Meaning : ${CRON_SCHED_EXPLAIN:-}"
    echo
    echo "$sched $user $cmd"
  } >"$tmp"

  if ! cron__validate_whole_crond_file "$tmp"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nYour entry doesn't look valid for /etc/cron.d.\nNothing created."
    rm -f "$tmp"
    return 0
  fi

  ui_textbox "$MODULE_CRON_TITLE" "$tmp" || true

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back"       --backtitle "${DAST_BACKTITLE:-DaST}" --title "$MODULE_CRON_TITLE"       --yesno "Final confirm:

Create/overwrite:
$path

Backup will be written to:
${bkp:-none}" 0 0; then
    rm -f "$tmp"
    return 0
  fi

  if run install -o root -g root -m 0644 "$tmp" "$path" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Created/Updated:\n$path\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to write:\n$path\n\nBackup:\n${bkp:-none}"
  fi

  rm -f "$tmp"
}

cron__crond_delete() {
  cron__need_root "Delete /etc/cron.d file" || return 0

  local f; f="$(cron__crond_pick_file)"
  [[ -z "$f" || "$f" == "BACK" ]] && return 0

  local path="/etc/cron.d/$f"
  # Create the backup first so the confirm dialog can show the exact path.
  local bkp
  bkp="$(cron__backup_file "$path" "crond_${f}" 2>/dev/null || true)"

  local msg
  msg=$'DANGER ZONE\n\nDelete:\n'
  msg+="$path"
  msg+=$'\n\nBackup will be written to:\n'
  msg+="${bkp:-none}"
  msg+=$'\n\nProceed?'

  if ! dast_ui_dialog --defaultno --yes-label "Apply" --no-label "Back" \
       --backtitle "$DAST_BACKTITLE" --title "$MODULE_CRON_TITLE" \
       --yesno "$msg" 0 0; then
    return 0
  fi

  if run rm -f -- "$path" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Deleted.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to delete.\n\nBackup:\n${bkp:-none}"
  fi
}

cron__crond_loop() {
  cron__need_root "Manage /etc/cron.d" || return 0

  if [[ ! -d "/etc/cron.d" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "Folder not found: /etc/cron.d\n\n(On Debian/Ubuntu it should exist.)"
    return 0
  fi

  while true; do
    local action
    action="$(cron__crond_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      "LIST")   cron__crond_list ;;
      "VIEW")   cron__crond_view ;;
      "EDIT")   cron__crond_edit ;;
      "NEW")    cron__crond_new ;;
      "DELETE") cron__crond_delete ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
cron__msgbox_back() {
  # Message box with an explicit "Back" button label.
  # Guard dialog rc under set -e.
  local title="$1" text="$2"

  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  dast_ui_dialog --ok-label "Back" --backtitle "${DAST_BACKTITLE:-DaST}" --title "$title" --msgbox "$text" 14 80
  local _rc=$?
  [[ $_had_errexit -eq 1 ]] && set -e
  return $_rc
}

cron__menu_dialog() {
  # Dynamic-ish sizing: choose width based on longest item description.
  # Final clamp is handled centrally in dast_ui_dialog().
  local title="$1" text="$2"; shift 2

  local term_h term_w max_h max_w
  term_h="$(tput lines 2>/dev/null || echo 24)"; term_w="$(tput cols 2>/dev/null || echo 80)"
  [[ "$term_h" =~ ^[0-9]+$ ]] || term_h=24
  [[ "$term_w" =~ ^[0-9]+$ ]] || term_w=80
  max_h=$(( term_h - 4 )); max_w=$(( term_w - 4 ))
  (( max_h < 10 )) && max_h=10
  (( max_w < 40 )) && max_w=40

  local -a args=("--backtitle" "${DAST_BACKTITLE:-DaST}" "--title" "$title" "--menu" "$text")

  local count=$(( $# / 2 ))
  local i w=0 tag desc
  for ((i=1; i<=count; ++i)); do
    tag="${1}"; desc="${2}"; shift 2
    # Pick width based on description (tags are short).
    (( ${#desc} > w )) && w=${#desc}
    args+=("$tag" "$desc")
  done

  local height width listheight

  # Width: driven by the longest line we show (menu text or item description),
  # with sensible padding. Keep a small minimum so it does not look cramped.
  local text_w
  text_w=${#text}
  (( text_w > w )) && w=$text_w

  width=$(( w + 10 ))
  (( width < 44 )) && width=44
  (( width > max_w )) && width=max_w

  # Height: content-led. Avoid huge empty dialogs for small menus.
  height=$(( count + 8 ))
  (( height < 12 )) && height=12
  (( height > max_h )) && height=max_h

  listheight=$count
  (( listheight > height - 8 )) && listheight=$(( height - 8 ))
  (( listheight < 4 )) && listheight=4

  # Inject dimensions after --menu text
  # dialog: --menu text height width menuheight [items...]
  args=("${args[0]}" "${args[1]}" "${args[2]}" "${args[3]}" "${args[4]}" "${args[5]}" "$height" "$width" "$listheight" "${args[@]:6}")

  # IMPORTANT: dialog returns non-zero for Cancel/Esc. Under set -e this must not hard-exit.
  local _had_errexit=0
  [[ $- == *e* ]] && _had_errexit=1
  set +e
  local _out
  _out="$(dast_ui_dialog "${args[@]}")"
  local _rc=$?
  [[ $_had_errexit -eq 1 ]] && set -e
  printf "%s" "$_out"
  return $_rc
}

cron_menu() {
  cron__menu_dialog "$MODULE_CRON_TITLE" "Choose a Cron manager:" \
    "USER"   "👤 Manage user crontabs (crontab -u user)" \
    "SYSTEM" "📌 View /etc/crontab (system-wide, info only)" \
    "ROOT"   "👑 Manage root crontab (crontab -l)" \
    "CROND"  "🧰 Manage /etc/cron.d (system drop-ins)" \
    "INFO"   "📄 Info: where cron jobs live + safety notes" \
    "BACK"   "🔙 Back"
}



cron_info() {
  local tmp; tmp="$(mktemp_safe)"
  {
    echo "DaST Cron module"
    echo "Backend: $(cron__detect_backends >/dev/null 2>&1 || true; cron__backend_summary)"
    echo
    echo "Cron job locations"
    echo "  - Root crontab: crontab -l"
    echo "  - User crontabs: crontab -u USER -l"
    echo "  - System drop-ins: /etc/cron.d/*"
    echo
    echo "What DaST edits"
    echo "  - User crontabs via crontab(1)"
    echo "  - /etc/cron.d files"
    echo
    echo "Before writing"
    echo "  - Shows a diff in edit flows"
    echo "  - Basic syntax checks"
    echo "  - Confirmation prompts"
    echo "  - Backup created in: $(cron__backup_dir)"
    echo
    echo "Notes"
    echo "  - DaST runs as root, so system cron locations are editable"
  } >"$tmp"
  ui_textbox "$MODULE_CRON_TITLE" "$tmp" || true
  rm -f "$tmp"
}


# -----------------------------------------------------------------------------
# /etc/crontab (info-only)
# -----------------------------------------------------------------------------
cron__system_view() {
  local f="/etc/crontab"
  if [[ ! -e "$f" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Not found: $f"
    return 0
  fi
  if [[ ! -r "$f" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Cannot read: $f"
    return 0
  fi

  ui_textbox "$MODULE_CRON_TITLE" "$f" || true
}

# -----------------------------------------------------------------------------
# Module entrypoint
# -----------------------------------------------------------------------------
module_CRON() {
  # Guard rail: only run if we can find at least one supported cron surface.
  # (Module still registers so the loader stays happy, but we refuse to operate.)
  cron__detect_backends >/dev/null 2>&1 || true
  local have_crontab have_crond have_system
  have_crontab="${CRON_HAS_CRONTAB:-0}"
  have_crond="${CRON_HAS_CROND:-0}"
  have_system="${CRON_HAS_SYSTEM_CRONTAB:-0}"

  if (( have_crontab == 0 && have_crond == 0 && have_system == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ No supported cron backend found.\n\nDaST needs at least one of:\n  • crontab command (user crontabs)\n  • /etc/cron.d folder (system drop-ins)\n  • /etc/crontab (system crontab)\n\nNothing to manage on this system, so this module will not load."
    return 0
  fi

  while true; do
    local action
    action="$(cron_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      "ROOT")
        if (( have_crontab == 1 )); then
          cron__user_loop "root"
        else
          ui_msgbox "$MODULE_CRON_TITLE" "❌ 'crontab' not found."
        fi
        ;;
      "SYSTEM")
        if (( have_system == 1 )); then
          cron__system_view
        else
          ui_msgbox "$MODULE_CRON_TITLE" "❌ /etc/crontab not found."
        fi
        ;;
      "USER")
        if (( have_crontab == 1 )); then
          cron__user_loop
        else
          ui_msgbox "$MODULE_CRON_TITLE" "❌ 'crontab' not found.\n\nThis system doesn't appear to support user crontabs via the crontab command.\n\nTry: \n  • install cron/cronie package\n  • or use /etc/cron.d instead"
        fi
        ;;
      "CROND")
        if (( have_crond == 1 )); then
          cron__crond_loop
        else
          ui_msgbox "$MODULE_CRON_TITLE" "❌ /etc/cron.d not found.\n\nThis system doesn't appear to use /etc/cron.d drop-ins."
        fi
        ;;
      "INFO")  cron_info ;;
    esac
  done
}

# IMPORTANT: This is the bit that, if missing, makes the module vanish from menu.
# We only register if a supported cron surface exists on this system.
cron__detect_backends >/dev/null 2>&1 || true
if (( ${CRON_HAS_CRONTAB:-0} == 1 || ${CRON_HAS_CROND:-0} == 1 || ${CRON_HAS_SYSTEM_CRONTAB:-0} == 1 )); then
  register_module "$module_id" "$module_title" "module_CRON"
else
  # No supported backend; do not register.
  :
fi
