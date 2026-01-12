#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Logs (journalctl) (v0.9.8.4)
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

module_id="LOGS"
module_title="📜 Logs (journalctl)"
LOGS_TITLE="📜 Logs (journalctl)"

dast_has_systemd() {
  # True if systemd is PID 1 OR runtime dir exists.
  # Works on Debian/systemd, avoids showing on Devuan/sysvinit.
  if [[ -d /run/systemd/system ]]; then
    return 0
  fi
  if [[ -r /proc/1/comm ]]; then
    [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]] && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------------
# Shared helper (run/logs_run_capture_to_file/mktemp_safe)
# ---------------------------------------------------------------------------------

if ! declare -F run >/dev/null 2>&1 || ! declare -F run_capture >/dev/null 2>&1; then
  # When this module is sourced, BASH_SOURCE[0] points at this file.
  _dast_mod_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _dast_root="$(cd "$_dast_mod_dir/.." && pwd)"
  if [[ -f "$_dast_root/lib/dast_helper.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_dast_root/lib/dast_helper.sh"
  elif [[ -f "/usr/local/lib/dast_helper.sh" ]]; then
    # shellcheck source=/dev/null
    source "/usr/local/lib/dast_helper.sh"
  fi
  unset _dast_mod_dir _dast_root
fi

# DaST unified logging/debug hooks (provided by main app). No behaviour change if unavailable.
logs__log() {
  local level="${1:-INFO}"; shift || true
  declare -F dast_log >/dev/null 2>&1 && dast_log "$level" "$module_id" "$*"
}
logs__dbg() {
  declare -F dast_dbg >/dev/null 2>&1 && dast_dbg "$module_id" "$*"
}

# If helper load failed, emit a single breadcrumb for troubleshooting (safe: no stdout/UI noise).
if ! declare -F run >/dev/null 2>&1; then
  logs__log "WARN" "90_logs: dast_helper.sh not loaded; module running with local fallbacks"
  logs__dbg "90_logs: helper missing (run() not found); using fallbacks"
fi


# If the helper isn't available for some reason, keep temp-file safety.
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  mktemp_safe() {
    local _tmp
    _tmp="$(mktemp)" || return 1
    # Register for global cleanup when available (provided by main loader).
    if declare -F _dast_tmp_register >/dev/null 2>&1; then
      _dast_tmp_register "$_tmp"
    fi
    printf '%s\n' "$_tmp"
  }
fi


# -----------------------------
# Fallback helpers (only if core framework didn't provide them)
# -----------------------------
if ! declare -F dial >/dev/null 2>&1; then
  dial() { dialog "$@"; }
fi

if ! declare -F ui_menu >/dev/null 2>&1; then
  ui_menu() {
    local title="$1" prompt="$2"; shift 2
    dial --clear --cancel-label "Cancel" --title "$title" --menu "$prompt" 18 88 12 "$@" 2>&1 >/dev/tty
  }
fi

if ! declare -F ui_input >/dev/null 2>&1; then
  ui_input() {
    local title="$1" prompt="$2" init="${3:-}"
    dial --clear --cancel-label "Cancel" --title "$title" --inputbox "$prompt" 10 88 "$init" 2>&1 >/dev/tty
  }
fi

if ! declare -F ui_msg >/dev/null 2>&1; then
  ui_msg() { dial --clear --title "${1:-Message}" --msgbox "${2:-}" 10 88 >/dev/tty; }
fi

if ! declare -F ui_yesno >/dev/null 2>&1; then
  ui_yesno() {
    local title="$1" body="$2"
    dial --clear --title "$title" --yesno "$body" 11 88 >/dev/tty
  }
fi

if ! declare -F ui_textbox >/dev/null 2>&1; then
  ui_textbox() {
    local title="$1" file="$2"
    dial --clear --title "$title" --exit-label "Back" --textbox "$file" 22 92 >/dev/tty
  }
fi

# -----------------------------
# Simple config persistence
# -----------------------------
get_cfg_file() {
  if [[ -n "${CFG_FILE:-}" ]]; then
    echo "$CFG_FILE"
  elif [[ -n "${CONFIG_FILE:-}" ]]; then
    echo "$CONFIG_FILE"
  else
    echo "/etc/dast.conf"
  fi
}

cfg_set_kv() {
  local key="$1" val="$2"
  local cf tmp
  cf="$(get_cfg_file)"
  tmp="$(mktemp_safe)"

  if [[ -f "$cf" ]]; then
    grep -v "^${key}=" "$cf" > "$tmp" || true
  fi
  printf '%s=%q\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$cf"

  # IMPORTANT: mktemp creates mode 0600 and mv replaces the inode. Restore safe perms and
  # ensure the config file remains owned by the real invoking user (not root).
  chmod 644 "$cf" 2>/dev/null || true

  local _inv _grp
  _inv="${DAST_INVOKER_USER:-${SUDO_USER:-}}"
  if [[ -z "$_inv" || "$_inv" == "root" ]]; then
    _inv="$(logname 2>/dev/null || true)"
  fi
  if [[ -n "$_inv" && "$_inv" != "root" ]] && id "$_inv" >/dev/null 2>&1; then
    _grp="$(id -gn "$_inv" 2>/dev/null || echo "$_inv")"
    chown "$_inv:$_grp" "$(dirname "$cf")" "$cf" 2>/dev/null || true
  fi
  unset _inv _grp
}

cfg_get_kv() {
  local key="$1" default="${2:-}"
  local cf
  cf="$(get_cfg_file)"
  if [[ -f "$cf" ]]; then
    local line
    line="$(grep -E "^${key}=" "$cf" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$line" ]]; then
      # shellcheck disable=SC1090
      eval "echo ${line#*=}"
      return 0
    fi
  fi
  echo "$default"
}

# -----------------------------
# Preferences
# -----------------------------
load_log_prefs() {
  LOG_LINES="$(cfg_get_kv LOG_LINES "200")"
  LOG_OUTFMT="$(cfg_get_kv LOG_OUTFMT "short-iso")"
  LOG_SINCE="$(cfg_get_kv LOG_SINCE "")"
  LOG_UNTIL="$(cfg_get_kv LOG_UNTIL "")"
  LOG_PRIORITY="$(cfg_get_kv LOG_PRIORITY "")"
  LOG_KEYWORD="$(cfg_get_kv LOG_KEYWORD "")"
  LOG_BOOT="$(cfg_get_kv LOG_BOOT "0")"
  LOG_EXPORT_DIR="$(cfg_get_kv LOG_EXPORT_DIR "/root/dast-exports")"
  LOG_GZIP="$(cfg_get_kv LOG_GZIP "0")"
  LOG_SAFE_PAGER="$(cfg_get_kv LOG_SAFE_PAGER "1")"

  # Allow env overrides too (handy for testing)
  LOG_LINES="${LOG_LINES:-200}"
  LOG_SINCE="${LOG_SINCE:-}"
  LOG_UNTIL="${LOG_UNTIL:-}"
  LOG_PRIORITY="${LOG_PRIORITY:-}"
  LOG_KEYWORD="${LOG_KEYWORD:-}"
  LOG_OUTFMT="${LOG_OUTFMT:-short-iso}"
  LOG_BOOT="${LOG_BOOT:-0}"
  LOG_EXPORT_DIR="${LOG_EXPORT_DIR:-/root/dast-exports}"
  LOG_GZIP="${LOG_GZIP:-0}"
  LOG_SAFE_PAGER="${LOG_SAFE_PAGER:-1}"
}

save_log_prefs() {
  cfg_set_kv "LOG_LINES" "$LOG_LINES"
  cfg_set_kv "LOG_OUTFMT" "$LOG_OUTFMT"
  cfg_set_kv "LOG_SINCE" "$LOG_SINCE"
  cfg_set_kv "LOG_UNTIL" "$LOG_UNTIL"
  cfg_set_kv "LOG_PRIORITY" "$LOG_PRIORITY"
  cfg_set_kv "LOG_KEYWORD" "$LOG_KEYWORD"
  cfg_set_kv "LOG_BOOT" "$LOG_BOOT"
  cfg_set_kv "LOG_EXPORT_DIR" "$LOG_EXPORT_DIR"
  cfg_set_kv "LOG_GZIP" "$LOG_GZIP"
  cfg_set_kv "LOG_SAFE_PAGER" "$LOG_SAFE_PAGER"
}

# -----------------------------
# Runner wrapper: capture to file
# (This used to be called run_capture(), but that clashes with the shared helper)
# -----------------------------
logs_run_capture_to_file() {
  # usage: logs_run_capture_to_file "<cmd>" "<out_file>"  (out_file can be empty)
  # Runs via shared run_capture() so the command is logged. On failure, shows a UI error.
  local cmd="$1" out="${2:-}"
  local output rc

  output="$(run_capture_sh "$cmd")"
  rc=$?

  if (( rc != 0 )); then
    # Keep the UI readable if the command spews.
    ui_msg "$LOGS_TITLE" "❌ Command failed (rc=$rc)\n\n$cmd\n\n$(printf '%s' "$output" | head -c 4000)"
    return $rc
  fi

  if [[ -n "$out" ]]; then
    printf '%s\n' "$output" >"$out"
  else
    printf '%s' "$output"
  fi
  return 0
}

# -----------------------------
# journalctl base builder
# -----------------------------
build_journalctl_base() {
  local cmd="journalctl"

  [[ "$LOG_SAFE_PAGER" == "1" ]] && cmd+=" --no-pager"
  [[ -n "$LOG_OUTFMT" ]] && cmd+=" -o $LOG_OUTFMT"
  [[ -n "$LOG_LINES"  ]] && cmd+=" -n $LOG_LINES"

  if [[ "$LOG_BOOT" != "0" && -n "$LOG_BOOT" ]]; then
    cmd+=" --boot=$LOG_BOOT"
  fi

  if [[ -n "$LOG_SINCE" ]]; then
    cmd+=" --since='$LOG_SINCE'"
  fi

  if [[ -n "$LOG_UNTIL" ]]; then
    cmd+=" --until='$LOG_UNTIL'"
  fi

  if [[ -n "$LOG_PRIORITY" ]]; then
    cmd+=" -p '$LOG_PRIORITY'"
  fi

  if [[ -n "$LOG_KEYWORD" ]]; then
    # Prefer native --grep if supported; otherwise fallback to pipe grep.
    if journalctl --help 2>&1 | grep -q -- "--grep"; then
      cmd+=" --grep='$LOG_KEYWORD'"
    else
      cmd+=" | grep -i '$LOG_KEYWORD'"
    fi
  fi

  printf '%s' "$cmd"
}

# -----------------------------
# Views
# -----------------------------
render_view_to_file() {
  local view="$1" unit="${2:-}" out="$3"
  local cmd base

  base="$(build_journalctl_base)"

  case "$view" in
    ALL)
      cmd="$base"
      ;;
    KERNEL)
      cmd="$base -k"
      ;;
    UNIT)
      cmd="$base -u '$unit'"
      ;;
    BOOT)
      cmd="$base -b"
      ;;
    ERRORS)
      cmd="$base -p err"
      ;;
    *)
      ui_msg "$LOGS_TITLE" "Unknown view: $view"
      return 1
      ;;
  esac

  logs_run_capture_to_file "$cmd" "$out"
}

show_view() {
  local title="$1" file="$2"
  local title="$1" file="$2"
  ui_textbox "$title" "$file"
}

# -----------------------------
# Follow / live view
# -----------------------------
follow_unit() {
  local unit="$1"
  [[ -z "$unit" ]] && return 1
  local args=(journalctl -fu "$unit")
  [[ "$LOG_SAFE_PAGER" == "1" ]] && args+=(--no-pager)
  args+=(-o "$LOG_OUTFMT")

  # Follow mode should stream to terminal, not dialog.
  ui_msg "$LOGS_TITLE" "Starting follow for:
$unit

Press Ctrl+C to stop."
  "${args[@]}" || true
}

# -----------------------------
# Search builder UI
# -----------------------------
pick_output_format() {
  local sel
  sel="$(ui_menu "$LOGS_TITLE" "Select output format (journalctl -o)" \
    "short"       "short" \
    "short-iso"   "short-iso" \
    "short-iso-precise" "short-iso-precise" \
    "short-monotonic" "short-monotonic" \
    "cat"         "cat (message only)" \
    "json"        "json" \
    "json-pretty" "json-pretty" \
    "verbose"     "verbose" \
    "BACK"        "🔙 Back")" || return 1

  [[ "$sel" == "BACK" ]] && return 1
  LOG_OUTFMT="$sel"
  save_log_prefs
  return 0
}

pick_lines() {
  local v
  v="$(ui_input "$LOGS_TITLE" "How many lines (-n)?\n\nExample: 200, 1000" "$LOG_LINES")" || return 1
  [[ -z "$v" ]] && return 1
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    ui_msg "$LOGS_TITLE" "Invalid number: $v"
    return 1
  fi
  LOG_LINES="$v"
  save_log_prefs
  return 0
}

pick_since_until() {
  local s u
  s="$(ui_input "$LOGS_TITLE" "Since (--since). Examples:\n- yesterday\n- '2025-12-20 10:00'\n\nLeave empty to clear." "$LOG_SINCE")" || return 1
  u="$(ui_input "$LOGS_TITLE" "Until (--until). Examples:\n- now\n- '2025-12-20 12:00'\n\nLeave empty to clear." "$LOG_UNTIL")" || return 1

  LOG_SINCE="$s"
  LOG_UNTIL="$u"
  save_log_prefs
  return 0
}

pick_priority() {
  local sel
  sel="$(ui_menu "$LOGS_TITLE" "Select priority (-p)\n\nEmpty clears the filter." \
    "EMERG" "emerg" \
    "ALERT" "alert" \
    "CRIT"  "crit" \
    "ERR"   "err" \
    "WARNING" "warning" \
    "NOTICE"  "notice" \
    "INFO"  "info" \
    "DEBUG" "debug" \
    "CLEAR" "Clear" \
    "BACK"  "🔙 Back")" || return 1

  case "$sel" in
    BACK) return 1 ;;
    CLEAR) LOG_PRIORITY="" ;;
    *) LOG_PRIORITY="${sel,,}" ;;
  esac

  save_log_prefs
  return 0
}

pick_keyword() {
  local k
  k="$(ui_input "$LOGS_TITLE" "Keyword (grep or --grep). Leave empty to clear." "$LOG_KEYWORD")" || return 1
  LOG_KEYWORD="$k"
  save_log_prefs
  return 0
}

pick_boot() {
  local sel
  sel="$(ui_menu "$LOGS_TITLE" "Boot selection\n\n0 means current boot.\nUse 'BOOTLIST' to view --list-boots." \
    "0"        "Current boot (0)" \
    "-1"       "Previous boot (-1)" \
    "-2"       "Two boots ago (-2)" \
    "BOOTLIST" "Show boot list" \
    "CLEAR"    "Clear boot filter (0)" \
    "BACK"     "🔙 Back")" || return 1

  case "$sel" in
    BACK) return 1 ;;
    BOOTLIST)
      local tmp; tmp="$(mktemp_safe)"
      if ! logs_run_capture_to_file "journalctl --list-boots --no-pager" "$tmp"; then
        rm -f "$tmp"
        return 1
      fi
      show_view "Boot list" "$tmp"
      rm -f "$tmp"
      return 0
      ;;
    CLEAR) LOG_BOOT="0" ;;
    *) LOG_BOOT="$sel" ;;
  esac

  save_log_prefs
  return 0
}

toggle_safe_pager() {
  if [[ "$LOG_SAFE_PAGER" == "1" ]]; then
    LOG_SAFE_PAGER="0"
  else
    LOG_SAFE_PAGER="1"
  fi
  save_log_prefs
}

toggle_gzip() {
  if [[ "$LOG_GZIP" == "1" ]]; then
    LOG_GZIP="0"
  else
    LOG_GZIP="1"
  fi
  save_log_prefs
}

pick_export_dir() {
  local d
  d="$(ui_input "$LOGS_TITLE" "Export directory (will be created if missing):" "$LOG_EXPORT_DIR")" || return 1
  [[ -z "$d" ]] && return 1
  LOG_EXPORT_DIR="$d"
  save_log_prefs
  return 0
}

# -----------------------------
# Export
# -----------------------------
do_export() {
  local view="$1" unit="${2:-}"

  mkdir -p "$LOG_EXPORT_DIR" 2>/dev/null || true

  local ts outname outpath
  ts="$(date +%Y%m%d_%H%M%S)"
  case "$view" in
    UNIT) outname="journal_${unit}_${ts}.log" ;;
    KERNEL) outname="journal_kernel_${ts}.log" ;;
    ERRORS) outname="journal_errors_${ts}.log" ;;
    BOOT) outname="journal_boot_${ts}.log" ;;
    ALL|*) outname="journal_${ts}.log" ;;
  esac

  outname="${outname//\//_}"
  outpath="$LOG_EXPORT_DIR/$outname"

  local tmp; tmp="$(mktemp_safe)"
  if ! render_view_to_file "$view" "$unit" "$tmp"; then
    rm -f "$tmp"
    ui_msg "$LOGS_TITLE" "Export failed."
    return 1
  fi

  mv "$tmp" "$outpath"

  if [[ "$LOG_GZIP" == "1" ]]; then
    if logs_run_capture_to_file "gzip -f '$outpath'" ""; then
      outpath="${outpath}.gz"
    fi
  fi

  ui_msg "$LOGS_TITLE" "✅ Exported to:\n$outpath"
  return 0
}

# -----------------------------
# Disk usage, failed units
# -----------------------------
show_disk_usage() {
  local tmp; tmp="$(mktemp_safe)"
  logs_run_capture_to_file "journalctl --disk-usage --no-pager" "$tmp" || true
  show_view "Journal disk usage" "$tmp"
  rm -f "$tmp"
}

show_failed_units() {
  local tmp; tmp="$(mktemp_safe)"
  if command -v systemctl >/dev/null 2>&1; then
    logs_run_capture_to_file "systemctl --failed --no-pager" "$tmp" || true
  else
    printf '%s\n' "systemctl not found." >"$tmp"
  fi
  show_view "Failed systemd units" "$tmp"
  rm -f "$tmp"
}

# -----------------------------
# Maintenance
# -----------------------------
maint_rotate() {
  ui_msg "$LOGS_TITLE" "This will run: journalctl --rotate\n\nThis may write to the journal."
  if ! ui_yesno "$LOGS_TITLE" "Proceed?"; then
    return 0
  fi
  logs_run_capture_to_file "journalctl --rotate" "" || true
  ui_msg "$LOGS_TITLE" "✅ Rotation requested."
}

maint_vacuum_size() {
  local sz
  sz="$(ui_input "$LOGS_TITLE" "Vacuum by size.\n\nExamples:\n- 500M\n- 2G\n\nEnter size:" "")" || return 1
  [[ -z "$sz" ]] && return 1

  ui_msg "$LOGS_TITLE" "This will run: journalctl --vacuum-size='$sz'\n\nThis deletes old journal data."
  if ! ui_yesno "$LOGS_TITLE" "Proceed?"; then
    return 0
  fi

  logs_run_capture_to_file "journalctl --vacuum-size='$sz'" "" || true
  ui_msg "$LOGS_TITLE" "✅ Vacuum by size requested."
}

maint_vacuum_time() {
  local t
  t="$(ui_input "$LOGS_TITLE" "Vacuum by time.\n\nExamples:\n- 2weeks\n- 10days\n- 1month\n\nEnter time:" "")" || return 1
  [[ -z "$t" ]] && return 1

  ui_msg "$LOGS_TITLE" "This will run: journalctl --vacuum-time='$t'\n\nThis deletes old journal data."
  if ! ui_yesno "$LOGS_TITLE" "Proceed?"; then
    return 0
  fi

  logs_run_capture_to_file "journalctl --vacuum-time='$t'" "" || true
  ui_msg "$LOGS_TITLE" "✅ Vacuum by time requested."
}

# -----------------------------
# Menu
# -----------------------------
logs_menu() {
  load_log_prefs

  ui_menu "$LOGS_TITLE" "Select an action" \
    "VIEW_ALL"     "📜 View all logs (base filters)" \
    "VIEW_KERNEL"  "🧠 Kernel logs (-k)" \
    "VIEW_ERRORS"  "❗ Recent errors (priority err)" \
    "VIEW_UNIT"    "🧩 View unit logs (-u)" \
    "FOLLOW_UNIT"  "🔴 Follow unit logs (-fu)" \
    "EXPORT_ALL"   "💾 Export view to file" \
    "DISK"         "📦 Journal disk usage" \
    "FAILED"       "🚨  Failed systemd units" \
    "FILTERS"      "🛠️  Filters / preferences" \
    "MAINT"        "🧨 Maintenance" \
    "BACK"         "🔙 Back"
}

menu_filters() {
  while true; do
    local sel
    sel="$(ui_menu "$LOGS_TITLE" "Filters / preferences\n\nCurrent:\n- lines: $LOG_LINES\n- format: $LOG_OUTFMT\n- since: ${LOG_SINCE:-<none>}\n- until: ${LOG_UNTIL:-<none>}\n- priority: ${LOG_PRIORITY:-<none>}\n- keyword: ${LOG_KEYWORD:-<none>}\n- boot: $LOG_BOOT\n- safe pager: $LOG_SAFE_PAGER\n- gzip export: $LOG_GZIP\n- export dir: $LOG_EXPORT_DIR" \
      "LINES"   "Set lines (-n)" \
      "FMT"     "Set output format (-o)" \
      "TIME"    "Set since/until" \
      "PRIO"    "Set priority (-p)" \
      "KEY"     "Set keyword (grep)" \
      "BOOT"    "Set boot (--boot)" \
      "PAGER"   "Toggle safe pager (--no-pager)" \
      "GZIP"    "Toggle gzip on export" \
      "EXPDIR"  "Set export dir" \
      "BACK"    "🔙 Back")" || return 0

    case "$sel" in
      LINES) pick_lines ;;
      FMT) pick_output_format ;;
      TIME) pick_since_until ;;
      PRIO) pick_priority ;;
      KEY)  pick_keyword ;;
      BOOT) pick_boot ;;
      PAGER) toggle_safe_pager ;;
      GZIP) toggle_gzip ;;
      EXPDIR) pick_export_dir ;;
      BACK) return 0 ;;
    esac
  done
}

logs_run() {
  local action="$1"
  load_log_prefs

  case "$action" in
    VIEW_ALL)
      local tmp; tmp="$(mktemp_safe)"
      if render_view_to_file "ALL" "" "$tmp"; then
        show_view "All logs" "$tmp"
      fi
      rm -f "$tmp"
      ;;
    VIEW_KERNEL)
      local tmp; tmp="$(mktemp_safe)"
      if render_view_to_file "KERNEL" "" "$tmp"; then
        show_view "Kernel logs" "$tmp"
      fi
      rm -f "$tmp"
      ;;
    VIEW_ERRORS)
      local tmp; tmp="$(mktemp_safe)"
      if render_view_to_file "ERRORS" "" "$tmp"; then
        show_view "Recent errors" "$tmp"
      fi
      rm -f "$tmp"
      ;;
    VIEW_UNIT)
      local u
      u="$(ui_input "$LOGS_TITLE" "Unit name (systemd). Example: ssh.service" "")" || return 0
      [[ -z "$u" ]] && return 0
      local tmp; tmp="$(mktemp_safe)"
      if render_view_to_file "UNIT" "$u" "$tmp"; then
        show_view "Unit: $u" "$tmp"
      fi
      rm -f "$tmp"
      ;;
    FOLLOW_UNIT)
      local u
      u="$(ui_input "$LOGS_TITLE" "Unit name (systemd) to follow. Example: ssh.service" "")" || return 0
      [[ -z "$u" ]] && return 0
      follow_unit "$u"
      ;;
    EXPORT_ALL)
      local sel
      sel="$(ui_menu "$LOGS_TITLE" "Choose what to export" \
        "ALL"    "All logs (base filters)" \
        "KERNEL" "Kernel logs" \
        "ERRORS" "Recent errors" \
        "UNIT"   "Specific unit" \
        "BOOT"   "Current boot (-b)" \
        "BOOTLIST" "Show boot list" \
        "BACK"   "🔙 Back")" || return 0

      case "$sel" in
        ALL)    do_export "ALL" ;;
        KERNEL) do_export "KERNEL" ;;
        ERRORS) do_export "ERRORS" ;;
        BOOT)   do_export "BOOT" ;;
        UNIT)
          local u
          u="$(ui_input "$LOGS_TITLE" "Unit name to export. Example: ssh.service" "")" || return 0
          [[ -z "$u" ]] && return 0
          do_export "UNIT" "$u"
          ;;
        BOOTLIST)
          local tmp; tmp="$(mktemp_safe)"
          if ! render_view_to_file "ERRORS" "" "$tmp"; then :; fi
          show_view "Recent errors" "$tmp"
          rm -f "$tmp"
          ;;
        BACK) : ;;
      esac
      ;;
    DISK)   show_disk_usage ;;
    FAILED) show_failed_units ;;
    FILTERS) menu_filters ;;
    MAINT)  menu_maint ;;
    BACK)   : ;;
  esac
}

menu_maint() {
  while true; do
    local sel
    sel="$(ui_menu "$LOGS_TITLE" "🧨 Maintenance (writes/deletes, default No)" \
      "ROTATE"   "🧹 Rotate journal" \
      "VAC_SIZE" "🧹 Vacuum by size" \
      "VAC_TIME" "🧹 Vacuum by time" \
      "BACK"     "🔙 Back")" || return 0

    case "$sel" in
      ROTATE)   maint_rotate ;;
      VAC_SIZE) maint_vacuum_size ;;
      VAC_TIME) maint_vacuum_time ;;
      BACK) return 0 ;;
    esac
  done
}

module_LOGS() {
  if ! dast_has_systemd || ! command -v journalctl >/dev/null 2>&1; then
    ui_msg "$LOGS_TITLE" "systemd was not detected on this system.\n\nThis module is only available on systemd-based distros (journalctl)."
    return 0
  fi

  while true; do
    local action
    action="$(logs_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0
    logs_run "$action"
  done
}

if dast_has_systemd && command -v journalctl >/dev/null 2>&1; then
  register_module "$module_id" "$module_title" "module_LOGS"
fi
