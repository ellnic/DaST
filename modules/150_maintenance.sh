#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Maintenance (v0.9.8.4)
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

module_id="MAINT"
module_title="🧹 Maintenance"
MAINT_TITLE="🧹 Maintenance"



# -----------------------------------------------------------------------------
# Logging helpers (standard always, debug only when --debug)
# -----------------------------------------------------------------------------
if ! declare -F dast_log >/dev/null 2>&1; then
  dast_log() { :; }
fi
if ! declare -F dast_dbg >/dev/null 2>&1; then
  dast_dbg() { :; }
fi
# -----------------------------------------------------------------------------
# Helper integration
# -----------------------------------------------------------------------------

_dast_try_source_helper() {
  if declare -F run >/dev/null 2>&1 && declare -F ui_menu >/dev/null 2>&1; then
    return 0
  fi

  local here helper
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  helper="$here/dast_helper.sh"
  if [[ -f "$helper" ]]; then
    # shellcheck source=/dev/null
    source "$helper" >/dev/null 2>&1 || true
  fi
}
_dast_try_source_helper

# -----------------------------------------------------------------------------
# Logging/debug wrappers (prefer DaST core helpers if available)
# -----------------------------------------------------------------------------
maint__log() { if declare -F dast_log >/dev/null 2>&1; then dast_log "$@"; fi; }
maint__dbg() { if declare -F dast_dbg >/dev/null 2>&1; then dast_dbg "$@"; fi; }

# If helper integration failed, leave a breadcrumb in the app logs (no stdout noise).
__MAINT_HELPER_OK=1
if ! declare -F run >/dev/null 2>&1 || ! declare -F ui_menu >/dev/null 2>&1; then
  __MAINT_HELPER_OK=0
fi
if [[ $__MAINT_HELPER_OK -eq 0 ]]; then
  maint__log "WARN" "MAINT: dast_helper.sh not loaded (or incomplete); using local fallbacks."
  maint__dbg "MAINT: helper not loaded; run/ui_menu missing at module init."
fi

# Minimal fallbacks (only if main did not provide them)
if ! declare -F have >/dev/null 2>&1; then
  have() { command -v "$1" >/dev/null 2>&1; }
fi

if ! declare -F mktemp_safe >/dev/null 2>&1; then
  mktemp_safe() { mktemp; }
fi

if ! declare -F run >/dev/null 2>&1; then
  run() { bash -c "$*" >/dev/null 2>&1 || true; }
fi

# NOTE:
# Some DaST builds implement run_capture as a logger and may not return stdout.
# For Maintenance preview screens we want actual output, so keep this local.
maint_cmd_capture() {
  bash -c "$1" 2>&1 || true
}

# -----------------------------------------------------------------------------
# UI helpers (prefer DaST helpers if available)
# -----------------------------------------------------------------------------

maint_show_text() {
  local title="$1"
  local content="$2"

  local tmp
  tmp="$(mktemp_safe)" || return 0

  # Use printf %b so both real newlines and literal \n sequences render correctly.
  printf '%b' "$content" >"$tmp" 2>/dev/null || true

  # DaST policy: unified dialog layer only.
  ui_textbox "$title" "$tmp" "Continue"

  rm -f "$tmp" >/dev/null 2>&1 || true
}

maint_show_text_continue() {
  # Same as maint_show_text, but kept for readability in multi-step flows.
  local title="$1"
  local content="$2"
  maint_show_text "$title" "$content"
}

maint_msg() {
  local title="$1" msg="$2"
  if declare -F ui_msg >/dev/null 2>&1; then
    ui_msg "$title" "$msg"
  elif have dialog; then
    dast_ui_dialog --title "$title" --msgbox "$msg" 12 70
  else
    echo "== $title =="
    echo -e "$msg"
    read -r -p "Press Enter to continue..." _ || true
  fi
}

maint_yesno() {
  local title="$1" msg="$2"
  if declare -F ui_yesno >/dev/null 2>&1; then
    ui_yesno "$title" "$msg"
    return $?
  fi

  if have dialog; then
    dast_ui_dialog --title "$title" --yesno "$msg" 14 72
    return $?
  fi

  read -r -p "$title: $msg [y/N] " _ans
  [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
}


maint_yesno_defaultno() {
  # Like maint_yesno, but the default selection is NO (Cancel).
  local title="$1" msg="$2"

  if declare -F ui_yesno_defaultno >/dev/null 2>&1; then
    ui_yesno_defaultno "$title" "$msg"
    return $?
  fi

  if have dialog; then
    dast_ui_dialog --defaultno --title "$title" --yesno "$msg" 14 72
    return $?
  fi

  read -r -p "$title: $msg [y/N] " _ans
  [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
}

maint_confirm_proceed_defaultno() {
  # Confirmation dialog with Proceed/Cancel labels and default = Cancel.
  local title="$1" msg="$2"

  if have dialog; then
    if declare -F dial >/dev/null 2>&1; then
      dial --defaultno --yes-label "Proceed" --no-label "Cancel" --title "$title" --yesno "$msg" 14 72
    else
      dast_ui_dialog --defaultno --yes-label "Proceed" --no-label "Cancel" --title "$title" --yesno "$msg" 14 72
    fi
    return $?
  fi

  read -r -p "$title: $msg [y/N] " _ans
  [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
}

maint_input() {
  local title="$1" prompt="$2" initial="${3:-}"
  if declare -F ui_input >/dev/null 2>&1; then
    ui_input "$title" "$prompt" "$initial"
    return $?
  fi

  if have dialog; then
    local tmp
    tmp="$(mktemp_safe)" || return 1
    dast_ui_dialog --title "$title" --inputbox "$prompt" 10 70 "$initial" 2>"$tmp"
    local rc=$?
    local out=""
    [[ $rc -eq 0 ]] && out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp" >/dev/null 2>&1 || true
    [[ $rc -eq 0 ]] && { printf '%s' "$out"; return 0; }
    return 1
  fi

  read -r -p "$prompt " _ans
  printf '%s' "${_ans:-$initial}"
}

maint_menu() {
  # Wrapper to ui_menu if it exists, otherwise a basic dialog menu
  local title="$1" prompt="$2"
  shift 2

  if declare -F ui_menu >/dev/null 2>&1; then
    ui_menu "$title" "$prompt" "$@"
    return $?
  fi

  if have dialog; then
    local tmp
    tmp="$(mktemp_safe)" || return 1
    dast_ui_dialog --title "$title" --menu "$prompt" 0 0 0 "$@" 2>"$tmp"
    local rc=$?
    local out=""
    [[ $rc -eq 0 ]] && out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp" >/dev/null 2>&1 || true
    [[ $rc -eq 0 ]] && { printf '%s' "$out"; return 0; }
    return 1
  fi

  # Very basic TTY fallback: print choices
  echo "$title"
  echo "$prompt"
  local i=0
  while (( $# )); do
    local key="$1" desc="$2"
    shift 2
    i=$((i+1))
    printf '%2d) %s - %s\n' "$i" "$key" "$desc"
  done
  read -r -p "Choose: " _n
  echo "$_n"
}

# -----------------------------------------------------------------------------
# Guard rails
# -----------------------------------------------------------------------------

maint_require_root() {
  if [[ "${EUID:-999}" -ne 0 ]]; then
    maint_msg "Permission" "This action requires root.\n\nRe-run DaST as root, or use sudo."
    return 1
  fi
  return 0
}

maint_danger_confirm() {
  # Strong confirm: show warning and require typed phrase
  local title="$1"
  local warning="$2"
  local phrase="${3:-I UNDERSTAND}"

  maint_show_text "$title" "$warning"$'\n\n'"To proceed, you must type:"$'\n\n'"  $phrase"$'\n'

  local typed
  typed="$(maint_input "$title" "Type the phrase exactly to proceed:" "")" || return 1
  [[ "$typed" == "$phrase" ]]
}

# -----------------------------------------------------------------------------
# Common preview + apply pattern
# -----------------------------------------------------------------------------

maint_preview_and_run() {
  # Usage:
  # maint_preview_and_run "Title" "Explain text" "preview_cmd" "run_cmd" "needs_root(0/1)" "Danger?(0/1)" "Danger phrase" "DefaultNo?(0/1)"
  local title="$1"
  local explain="$2"
  local preview_cmd="$3"
  local run_cmd="$4"
  local needs_root="${5:-1}"
  local danger="${6:-0}"
  local phrase="${7:-}"
  local defaultno="${8:-1}"  # DaST philosophy: destructive actions default to Cancel/No.

  if [[ "$needs_root" == "1" ]] && ! maint_require_root; then
    return 0
  fi

  local preview
  preview="$(maint_cmd_capture "$preview_cmd")"
  [[ -z "$preview" ]] && preview="(no output)"

  maint_show_text "$title" "$explain"$'

'"Preview:"$'
'"--------"$'
'"$preview"$'

'"Next: you will be able to choose Proceed or Cancel on the confirmation screen (default Cancel)."

  # Confirmation screen (Proceed/Cancel, default = Cancel)
  if ! maint_confirm_proceed_defaultno "$title" "Proceed with this action?"; then
    maint_msg "Cancelled" "No changes made."
    return 0
  fi

  if [[ "$danger" == "1" ]]; then
    if [[ -n "$phrase" ]]; then
      if ! maint_danger_confirm "$title" "$explain"$'

'"This is a higher risk action." "$phrase"; then
        maint_msg "Cancelled" "Phrase mismatch. No changes made."
        return 0
      fi
    else
      if ! maint_confirm_proceed_defaultno "$title" "Higher risk action. Are you sure?"; then
        maint_msg "Cancelled" "No changes made."
        return 0
      fi
    fi
  fi

  local out
  out="$(maint_cmd_capture "$run_cmd")"
  maint_show_text "$title" "Result:"$'
'"------"$'
'"$out"
}


# -----------------------------------------------------------------------------
# Routine Maintenance actions (safe)
# -----------------------------------------------------------------------------

maint_routine_clear_tmp() {
  local days
  days="$(maint_input "$MAINT_TITLE" "Clear /tmp files older than how many days? (recommended 3)" "3")" || return 0
  [[ -z "$days" ]] && return 0

  maint_preview_and_run \
    "🧹 Clear /tmp" \
    "Removes files in /tmp older than $days days.\n\nNotes:\n- Uses find -xdev\n- Leaves the directory itself in place\n- Good for clearing stale temp files" \
    "find /tmp -xdev -mindepth 1 -mtime +$days -print 2>/dev/null | head -n 200" \
    "find /tmp -xdev -mindepth 1 -mtime +$days -print -delete 2>/dev/null; echo; echo 'Done.'; df -h /tmp 2>/dev/null || true" \
    1 0
}

maint_routine_clear_var_tmp() {
  local days
  days="$(maint_input "$MAINT_TITLE" "Clear /var/tmp files older than how many days? (recommended 7)" "7")" || return 0
  [[ -z "$days" ]] && return 0

  maint_preview_and_run \
    "🧹 Clear /var/tmp" \
    "Removes files in /var/tmp older than $days days.\n\nNotes:\n- /var/tmp is meant for temp files that survive reboot\n- This can free space safely on most systems" \
    "find /var/tmp -xdev -mindepth 1 -mtime +$days -print 2>/dev/null | head -n 200" \
    "find /var/tmp -xdev -mindepth 1 -mtime +$days -print -delete 2>/dev/null; echo; echo 'Done.'; df -h /var/tmp 2>/dev/null || true" \
    1 0
}

maint_routine_journal_vacuum_time() {
  local age
  age="$(maint_input "$MAINT_TITLE" "Vacuum journal by time (example: 7d, 2weeks, 1month)" "7d")" || return 0
  [[ -z "$age" ]] && return 0

  maint_preview_and_run \
    "🧾 Journal vacuum (by time)" \
    "Removes old systemd journal entries, keeping only the most recent period you specify.\n\nThis is safe and reversible only in the sense that logs are deleted." \
    "journalctl --disk-usage 2>/dev/null || true" \
    "journalctl --vacuum-time=$age 2>&1 || true; echo; journalctl --disk-usage 2>/dev/null || true" \
    1 0
}

maint_routine_logrotate() {
  if ! have logrotate; then
    maint_msg "Missing dependency" "logrotate is not installed."
    return 0
  fi

  maint_preview_and_run \
    "🧾 Force logrotate" \
    "Forces a logrotate run.\n\nThis is generally safe, but logrotate rules can vary by system." \
    "logrotate -d /etc/logrotate.conf 2>&1 | head -n 200" \
    "logrotate -f /etc/logrotate.conf 2>&1 || true" \
    1 0
}

maint_routine_apt_clean() {
  if ! have apt-get; then
    maint_msg "Not available" "apt-get not found. This action is for APT based systems only."
    return 0
  fi

  maint_preview_and_run \
    "📦 APT clean" \
    "Clears downloaded package files from APT cache.\n\nThis does not remove installed packages." \
    "du -sh /var/cache/apt/archives 2>/dev/null || true" \
    "apt-get clean 2>&1 || true; echo; du -sh /var/cache/apt/archives 2>/dev/null || true" \
    1 0
}

maint_routine_crash_reports() {
  [[ -d /var/crash ]] || { maint_msg "Not present" "/var/crash not found on this system."; return 0; }

  maint_preview_and_run \
    "🧯 Clear crash reports" \
    "Removes old crash reports under /var/crash.\n\nDefaults to older than 30 days." \
    "find /var/crash -xdev -type f -mtime +30 -print 2>/dev/null | head -n 200" \
    "find /var/crash -xdev -type f -mtime +30 -print -delete 2>/dev/null; echo; echo 'Done.'; ls -la /var/crash 2>/dev/null || true" \
    1 0 "" 1
}

maint_routine_system_checks() {
  local out
  out="$(
    {
      echo "System checks (read only)"
      echo "-------------------------"
      echo
      echo "[Disk usage]"
      df -hT 2>/dev/null || true
      echo
      echo "[Inodes]"
      df -hi 2>/dev/null || true
      echo
      echo "[Journal size]"
      journalctl --disk-usage 2>/dev/null || true
      echo
      echo "[Top 15 biggest directories under /var]"
      du -xh /var 2>/dev/null | sort -h | tail -n 15 || true
    } 2>&1
  )"
  maint_show_text "🩺 System checks" "$out"
}

# -----------------------------------------------------------------------------
# Deep Cleaning actions (warned)
# -----------------------------------------------------------------------------

maint_deep_apt_autoremove() {
  if ! have apt-get; then
    maint_msg "Not available" "apt-get not found. This action is for APT based systems only."
    return 0
  fi

  maint_preview_and_run \
    "📦 APT autoremove" \
    "Removes packages that were automatically installed and are no longer needed.\n\nThis is usually safe, but you should review the list carefully." \
    "apt-get -s autoremove 2>&1 | sed -n '1,220p'" \
    "apt-get autoremove -y 2>&1 || true" \
    1 1 "I UNDERSTAND"
}

maint_deep_journal_vacuum_size() {
  local size
  size="$(maint_input "$MAINT_TITLE" "Vacuum journal to a maximum size (example: 200M, 1G)" "200M")" || return 0
  [[ -z "$size" ]] && return 0

  maint_preview_and_run \
    "🧾 Journal vacuum (by size)" \
    "Shrinks systemd journal logs to at most the size you specify.\n\nThis deletes logs. Use with care." \
    "journalctl --disk-usage 2>/dev/null || true" \
    "journalctl --vacuum-size=$size 2>&1 || true; echo; journalctl --disk-usage 2>/dev/null || true" \
    1 1 "I UNDERSTAND"
}

maint_deep_coredumps() {
  if ! have coredumpctl; then
    maint_msg "Not available" "coredumpctl not found on this system."
    return 0
  fi

  maint_preview_and_run \
    "💥 Clear core dumps" \
    "Removes stored core dumps.\n\nThis can reclaim space but may remove useful debugging artefacts." \
    "coredumpctl list 2>/dev/null | head -n 50 || true" \
    "coredumpctl purge 2>&1 || true; echo; coredumpctl list 2>/dev/null | head -n 10 || true" \
    1 1 "I UNDERSTAND"
}

maint_deep_docker_prune() {
  if ! have docker; then
    maint_msg "Not available" "docker not found."
    return 0
  fi

  maint_preview_and_run \
    "🐳 Docker prune (safe)" \
    "Removes stopped containers, unused networks, and dangling images.\n\nDoes NOT remove volumes." \
    "docker system df 2>&1 || true" \
    "docker system prune -f 2>&1 || true; echo; docker system df 2>&1 || true" \
    1 1 "I UNDERSTAND"
}

maint_deep_docker_prune_volumes() {
  if ! have docker; then
    maint_msg "Not available" "docker not found."
    return 0
  fi

  maint_preview_and_run \
    "🐳 Docker prune volumes (danger)" \
    "Removes unused Docker volumes.\n\nThis can delete data.\nOnly proceed if you are sure the volumes are not needed." \
    "docker system df -v 2>&1 | sed -n '1,220p' || true" \
    "docker volume prune -f 2>&1 || true; echo; docker system df -v 2>&1 | sed -n '1,140p' || true" \
    1 1 "DELETE DOCKER VOLUMES"
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

maint_routine_menu() {
  while true; do
    local choice
    choice="$(maint_menu "$MAINT_TITLE" "Routine Maintenance (safe):" \
      TMP      "🧹 Clear /tmp (older than N days)" \
      VARTMP   "🧹 Clear /var/tmp (older than N days)" \
      JTIME    "🧾 Vacuum journal by time" \
      APTCLN   "📦 APT clean (cache only)" \
      LOGROT   "🧾 Force logrotate" \
      CRASH    "🧯 Clear old crash reports" \
      CHECK    "🩺 System checks (read only)" \
      BACK     "🔙️ Back")" || return 0

    case "$choice" in
      TMP)    maint_routine_clear_tmp ;;
      VARTMP) maint_routine_clear_var_tmp ;;
      JTIME)  maint_routine_journal_vacuum_time ;;
      APTCLN) maint_routine_apt_clean ;;
      LOGROT) maint_routine_logrotate ;;
      CRASH)  maint_routine_crash_reports ;;
      CHECK)  maint_routine_system_checks ;;
      BACK)   return 0 ;;
    esac
  done
}

maint_deep_menu() {
  while true; do
    local docker_items=()
    if have docker; then
      docker_items=(
        DPRUNE   "🐳 Docker prune (no volumes)"
        DVPRUNE  "🐳 Docker prune volumes (danger)"
      )
    fi

    local choice
    choice="$(maint_menu "$MAINT_TITLE" "Deep Cleaning (warned, review first):" \
      APTAUTO  "📦 APT autoremove (review carefully)" \
      JSIZE    "🧾 Vacuum journal by size" \
      COREDUMP "💥 Clear core dumps" \
      "${docker_items[@]}" \
      BACK     "🔙️ Back")" || return 0

    case "$choice" in
      APTAUTO)  maint_deep_apt_autoremove ;;
      JSIZE)    maint_deep_journal_vacuum_size ;;
      COREDUMP) maint_deep_coredumps ;;
      DPRUNE)
        if have docker; then
          maint_deep_docker_prune
        else
          maint_msg "$MAINT_TITLE" "Docker not detected on this system."
        fi
        ;;
      DVPRUNE)
        if have docker; then
          maint_deep_docker_prune_volumes
        else
          maint_msg "$MAINT_TITLE" "Docker not detected on this system."
        fi
        ;;
      BACK)     return 0 ;;
    esac
  done
}


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

module_MAINT() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  while true; do
    local choice
    choice="$(maint_menu "$MAINT_TITLE" "Choose a maintenance tier:" \
      ROUTINE "🧹 Routine Maintenance (safe)" \
      DEEP    "🚨 Deep Cleaning (review first)" \
      BACK    "🔙️ Back")" || return 0

    case "$choice" in
      ROUTINE) maint_routine_menu ;;
      DEEP)    maint_deep_menu ;;
      BACK)    return 0 ;;
    esac
  done
}

# Loader marker (Keep this line for diagnostic scanners)
# register_module "MAINT" "$MAINT_TITLE" "module_MAINT"

if declare -F register_module >/dev/null 2>&1; then
  register_module "MAINT" "$MAINT_TITLE" "module_MAINT"
fi
