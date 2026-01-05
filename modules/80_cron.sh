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
    "SIMPLE"   "🧭 Simple presets (recommended)" \
    "ADVANCED" "🧠 Custom 5-field schedule" \
    "@REBOOT"  "🔌 Run once at system boot" \
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
# User selection
# -----------------------------------------------------------------------------
cron__pick_user() {
  if ! cron__is_root; then
    id -un
    return 0
  fi

  local items=() name uid shell
  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$shell" =~ (false|nologin)$ ]] && continue
    if (( uid == 0 )) || (( uid >= 1000 && uid < 60000 )); then
      items+=("$name" "uid=$uid")
    fi
  done </etc/passwd

  ui_menu "$MODULE_CRON_TITLE" "Select a user crontab to manage:" "${items[@]}" "BACK" "🔙 Back"
}

cron__load_user_crontab_to_file() {
  local user="$1" out="$2"
  if run crontab -u "$user" -l >/dev/null 2>&1; then
    run crontab -u "$user" -l >"$out" 2>/dev/null || true
  else
    : >"$out"
  fi
}

cron__install_user_crontab_from_file() {
  local user="$1" file="$2"
  run crontab -u "$user" "$file"
}

# -----------------------------------------------------------------------------
# User crontab menu
# -----------------------------------------------------------------------------
cron__user_menu() {
  local user="$1"
  ui_menu "$MODULE_CRON_TITLE" "User crontab: $user" \
    "VIEW"    "👀 View current crontab" \
    "ADD"     "🆕 Add a new cron job (guided)" \
    "TOGGLE"  "🧷 Enable/Disable a line (comment/uncomment)" \
    "DELETE" "🗑️ Delete a specific line (backup + confirm)" \
    "EDIT"    "📝 Edit entire crontab (diff + validate + apply)" \
    "CLEAR"   "💣 Remove all jobs (backup first)" \
    "BACK"    "🔙 Back"
}

cron__user_view() {
  local tmp="$1" user="$2"
  ui_textbox "$MODULE_CRON_TITLE" "$tmp"
}

cron__user_delete() {
  local tmp="$1" user="$2"

  local items=() i=0 line label
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((i++))
    label="$line"
    [[ -z "$label" ]] && label="(blank)"
    label="${label:0:90}"
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

  local review; review="$(mktemp_safe)"
  {
    echo "Line $pick will be DELETED:"
    echo
    echo "LINE: $cur"
    echo
    echo "DaST will backup before applying."
  } >"$review"
  ui_textbox "$MODULE_CRON_TITLE" "$review"
  rm -f "$review"

  ui_confirm "$MODULE_CRON_TITLE" "Final confirm:\n\nDelete line $pick now?" || return 0

  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  local newfile; newfile="$(mktemp_safe)"
  awk -v n="$pick" 'NR!=n {print}' "$tmp" >"$newfile"

  if ! cron__validate_whole_user_crontab "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed after delete.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$newfile" >/dev/null 2>&1; then
    mv -f "$newfile" "$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Deleted.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
  fi
}

cron__user_add() {
  local tmp="$1" user="$2"

  local sched cmd tag newline
  sched="$(cron__schedule_picker)" || return 0
  cmd="$(ui_inputbox "$MODULE_CRON_TITLE" "Command to run:\n\nExample:\n/usr/local/sbin/my-script.sh --flag" "")" || return 0
  tag="$(ui_inputbox "$MODULE_CRON_TITLE" "Optional comment tag (shown above the job):" "DaST Cron")" || true

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
  ui_textbox "$MODULE_CRON_TITLE" "$review"
  rm -f "$review"

  ui_confirm "$MODULE_CRON_TITLE" "Final confirm:\n\nApply this change to $user now?" || return 0

  # Backup existing
  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  # Append
  local new; new="$(mktemp_safe)"
  {
    cat "$tmp"
    [[ -s "$tmp" ]] && echo
    echo "$newline"
  } >"$new"

  if ! cron__validate_whole_user_crontab "$new"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nThis looks like malformed cron syntax.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$new"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$new" >/dev/null 2>&1; then
    mv -f "$new" "$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Applied.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\nNothing should have changed.\nBackup:\n${bkp:-none}"
    rm -f "$new"
  fi
}

cron__user_toggle() {
  local tmp="$1" user="$2"

  local items=() i=0 line label
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((i++))
    label="$line"
    [[ -z "$label" ]] && label="(blank)"
    label="${label:0:90}"
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

  local review; review="$(mktemp_safe)"
  {
    echo "Line $pick will be changed:"
    echo
    echo "BEFORE: $cur"
    echo "AFTER : $new"
    echo
    echo "DaST will backup before applying."
  } >"$review"
  ui_textbox "$MODULE_CRON_TITLE" "$review"
  rm -f "$review"

  ui_confirm "$MODULE_CRON_TITLE" "Final confirm:\n\nApply this toggle now?" || return 0

  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  local newfile; newfile="$(mktemp_safe)"
  awk -v n="$pick" -v repl="$new" 'NR==n{$0=repl} {print}' "$tmp" >"$newfile"

  if ! cron__validate_whole_user_crontab "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed after toggle.\nNothing applied.\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
    return 0
  fi

  if cron__install_user_crontab_from_file "$user" "$newfile" >/dev/null 2>&1; then
    mv -f "$newfile" "$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Applied.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install crontab.\n\nBackup:\n${bkp:-none}"
    rm -f "$newfile"
  fi
}

cron__user_edit() {
  local tmp="$1" user="$2"

  local edited newfile diff
  edited="$(mktemp_safe)"
  newfile="$(mktemp_safe)"
  diff="$(mktemp_safe)"
  cp -f "$tmp" "$edited"

  # ui_editbox is not in your system module, so we do the classic DaST approach:
  # ask for a preferred editor; if none, fall back to $EDITOR or nano/vi.
  local editor
  editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then editor="nano"
    elif command -v vi >/dev/null 2>&1; then editor="vi"
    else editor=""
    fi
  fi

  if [[ -z "$editor" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "No editor found (EDITOR not set, and nano/vi not present)."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_msgbox "$MODULE_CRON_TITLE" "Editor will open now:\n\n$editor\n\nWhen you exit, DaST will show a diff and ask to apply."
  run "$editor" "$edited"

  cp -f "$edited" "$newfile"
  cron__diff_to_file "$tmp" "$newfile" "$diff"
  ui_textbox "$MODULE_CRON_TITLE" "$diff"

  if ! cron__validate_whole_user_crontab "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nEdits look malformed.\nNothing applied."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_confirm "$MODULE_CRON_TITLE" "Final confirm:\n\nApply edited crontab to $user now?" || {
    rm -f "$edited" "$newfile" "$diff"
    return 0
  }

  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  if cron__install_user_crontab_from_file "$user" "$newfile" >/dev/null 2>&1; then
    mv -f "$newfile" "$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Applied.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to install.\n\nBackup:\n${bkp:-none}"
  fi

  rm -f "$edited" "$diff" 2>/dev/null || true
}

cron__user_clear() {
  local tmp="$1" user="$2"

  ui_confirm "$MODULE_CRON_TITLE" "DANGER ZONE:\n\nClear ALL cron jobs for $user?\n\nA backup will be created first." || return 0
  ui_confirm "$MODULE_CRON_TITLE" "Last chance:\n\nReally clear everything for $user?" || return 0

  local bkp
  bkp="$(cron__backup_stdin "user_${user}_crontab" <"$tmp" 2>/dev/null || true)"

  local empty; empty="$(mktemp_safe)"
  : >"$empty"

  if cron__install_user_crontab_from_file "$user" "$empty" >/dev/null 2>&1; then
    : >"$tmp"
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Cleared.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to clear.\n\nBackup:\n${bkp:-none}"
  fi

  rm -f "$empty"
}

cron__user_loop() {
  local user tmp
  user="$(cron__pick_user)" || return 0
  [[ "$user" == "BACK" || -z "$user" ]] && return 0

  tmp="$(mktemp_safe)"
  cron__load_user_crontab_to_file "$user" "$tmp"

  while true; do
    local action
    action="$(cron__user_menu "$user")" || break
    [[ -z "$action" || "$action" == "BACK" ]] && break

    case "$action" in
      "VIEW")    cron__user_view "$tmp" "$user" ;;
      "ADD")     cron__user_add "$tmp" "$user" ;;
      "TOGGLE")  cron__user_toggle "$tmp" "$user" ;;
      "DELETE") cron__user_delete "$tmp" "$user" ;;
      "EDIT")    cron__user_edit "$tmp" "$user" ;;
      "CLEAR")   cron__user_clear "$tmp" "$user" ;;
    esac
  done

  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# /etc/cron.d management
# -----------------------------------------------------------------------------
cron__crond_menu() {
  ui_menu "$MODULE_CRON_TITLE" "Manage /etc/cron.d (system cron drop-ins):" \
    "LIST"   "📃 List files in /etc/cron.d" \
    "VIEW"   "👀 View a file" \
    "EDIT"   "📝 Edit a file (diff + validate + apply)" \
    "NEW"    "🆕 Create a new cron.d file (guided)" \
    "DELETE" "🗑️ Delete a file (backup first)" \
    "BACK"   "🔙 Back"
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
    echo ""
    return 0
  fi

  ui_menu "$MODULE_CRON_TITLE" "Pick a /etc/cron.d file:" "${items[@]}" "BACK" "🔙 Back"
}

cron__crond_list() {
  local tmp; tmp="$(mktemp_safe)"
  run ls -la /etc/cron.d >"$tmp" 2>/dev/null || echo "Unable to list /etc/cron.d" >"$tmp"
  ui_textbox "$MODULE_CRON_TITLE" "$tmp"
  rm -f "$tmp"
}

cron__crond_view() {
  local f; f="$(cron__crond_pick_file)"
  [[ -z "$f" || "$f" == "BACK" ]] && return 0
  ui_textbox "$MODULE_CRON_TITLE" "/etc/cron.d/$f"
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

  local editor
  editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if command -v nano >/dev/null 2>&1; then editor="nano"
    elif command -v vi >/dev/null 2>&1; then editor="vi"
    else editor=""
    fi
  fi

  if [[ -z "$editor" ]]; then
    ui_msgbox "$MODULE_CRON_TITLE" "No editor found (EDITOR not set, and nano/vi not present)."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_msgbox "$MODULE_CRON_TITLE" "Editor will open now:\n\n$editor\n\nWhen you exit, DaST will show a diff and ask to apply."
  run "$editor" "$edited"

  cp -f "$edited" "$newfile"
  cron__diff_to_file "$path" "$newfile" "$diff"
  ui_textbox "$MODULE_CRON_TITLE" "$diff"

  if ! cron__validate_whole_crond_file "$newfile"; then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ Validation failed.\n\nEdits look malformed for /etc/cron.d format.\nNothing applied."
    rm -f "$edited" "$newfile" "$diff"
    return 0
  fi

  ui_confirm "$MODULE_CRON_TITLE" "Final confirm:\n\nApply edited file to:\n$path\n\nA backup will be created first." || {
    rm -f "$edited" "$newfile" "$diff"
    return 0
  }

  local bkp
  bkp="$(cron__backup_file "$path" "crond_${f}" 2>/dev/null || true)"

  if run install -o root -g root -m 0644 "$newfile" "$path" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_CRON_TITLE" "✅ Applied.\n\nBackup:\n${bkp:-none}"
  else
    ui_msgbox "$MODULE_CRON_TITLE" "❌ FAILED to write file.\n\nBackup:\n${bkp:-none}"
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
  if [[ -e "$path" ]]; then
    ui_confirm "$MODULE_CRON_TITLE" "File already exists:\n$path\n\nOverwrite? (backup will be made)" || return 0
  fi

  local sched user cmd comment
  sched="$(cron__schedule_picker)" || return 0
  user="$(ui_inputbox "$MODULE_CRON_TITLE" "User to run as (cron.d requires a user field):" "root")" || return 0
  cmd="$(ui_inputbox "$MODULE_CRON_TITLE" "Command to run:" "")" || return 0
  comment="$(ui_inputbox "$MODULE_CRON_TITLE" "Optional comment tag:" "DaST Cron")" || true

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

  ui_textbox "$MODULE_CRON_TITLE" "$tmp"
  ui_confirm "$MODULE_CRON_TITLE" "Final confirm:\n\nCreate/overwrite:\n$path\n\nBackup will be created if overwriting." || {
    rm -f "$tmp"
    return 0
  }

  local bkp=""
  if [[ -e "$path" ]]; then
    bkp="$(cron__backup_file "$path" "crond_${name}" 2>/dev/null || true)"
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
  ui_confirm "$MODULE_CRON_TITLE" "DANGER ZONE:\n\nDelete:\n$path\n\nA backup will be made first." || return 0
  ui_confirm "$MODULE_CRON_TITLE" "Last chance:\n\nReally delete:\n$path ?" || return 0

  local bkp
  bkp="$(cron__backup_file "$path" "crond_${f}" 2>/dev/null || true)"

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
cron_menu() {
  ui_menu "$MODULE_CRON_TITLE" "Choose a Cron manager:" \
    "USER"   "👤 Manage user crontabs (crontab -u user)" \
    "CROND"  "🧰 Manage /etc/cron.d (system drop-ins)" \
    "INFO"   "📄 Info: where cron jobs live + safety notes" \
    "BACK"   "🔙 Back"
}

cron_info() {
  local tmp; tmp="$(mktemp_safe)"
  {
    echo "DaST Cron module notes"
    echo "Backend check: $(cron__detect_backends >/dev/null 2>&1 || true; cron__backend_summary)"
    echo
    echo "This module manages:"
    echo "  1) User crontabs via: crontab -u USER -l / crontab -u USER FILE"
    echo "  2) System cron drop-ins in: /etc/cron.d"
    echo "  3) (Info only) System-wide crontab file: /etc/crontab"
    echo
    echo "On Ubuntu/Debian, packages may install scheduled jobs in /etc/cron.d"
    echo "Example: zfsutils-linux often installs periodic scrub jobs there."
    echo
    echo "Safety nets:"
    echo "  - Backups before apply: $(cron__backup_dir)"
    echo "  - Diff shown before edits are applied"
    echo "  - Double confirmation prompts"
    echo
    echo "Guard rails:"
    echo "  - Best-effort validation (basic syntax checks)"
    echo "  - Root required for /etc/cron.d"
  } >"$tmp"
  ui_textbox "$MODULE_CRON_TITLE" "$tmp"
  rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# Module entrypoint
# -----------------------------------------------------------------------------
module_CRON() {
  # Guard rail: only run if we can find at least one supported cron surface.
  # (Module still registers so the loader stays happy, but we refuse to operate.)
  cron__detect_backends >/dev/null 2>&1 || true
  local have_crontab have_crond
  have_crontab="$CRON_HAS_CRONTAB"
  have_crond="$CRON_HAS_CROND"

  if (( have_crontab == 0 && have_crond == 0 )); then
    ui_msgbox "$MODULE_CRON_TITLE" "❌ No supported cron backend found.\n\nDaST needs at least one of:\n  • crontab command (user crontabs)\n  • /etc/cron.d folder (system drop-ins)\n\nNothing to manage on this system, so this module will not load."
    return 0
  fi

  while true; do
    local action
    action="$(cron_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
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
if (( CRON_HAS_CRONTAB == 1 || CRON_HAS_CROND == 1 || CRON_HAS_SYSTEM_CRONTAB == 1 )); then
  register_module "$module_id" "$module_title" "module_CRON"
else
  # No supported backend; do not register.
  :
fi
