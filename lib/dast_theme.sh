#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Library: dast_theme (v0.9.8.4)
# DaST lib: dialog theme helpers (v0.9.8).
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
# DaST requires bash. This library is intended to be sourced by DaST.
# ---------------------------------------------------------------------------------------
#
# Header notes (from original file):
# DaST lib: dialog theme helpers (v0.9.8)
#

__DAST_DIALOGRC_SUPPORTED_CACHE="${__DAST_DIALOGRC_SUPPORTED_CACHE:-}"
__DAST_THEME_APPLY_EARLY_COUNT="${__DAST_THEME_APPLY_EARLY_COUNT:-0}"

_dast_theme__log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"

  if declare -F _dast_log >/dev/null 2>&1; then
    _dast_log "$level" "[THEME] $msg"
  else
    printf '%s %s %s\n' "$(date '+%F %T')" "$level" "$msg" >&2
  fi
}

_dast__ensure_dialogrc_supported_cache() {
  [[ -n "${__DAST_DIALOGRC_SUPPORTED_CACHE:-}" ]] && return 0

  local tmp
  tmp="$(mktemp -p "${TMPDIR:-/tmp}" dast.dialogrc.supported.XXXXXX 2>/dev/null || mktemp 2>/dev/null)" || return 1

  if ! dialog --create-rc "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  __DAST_DIALOGRC_SUPPORTED_CACHE="$(
    awk '/^[[:space:]]*[a-zA-Z0-9_]+[[:space:]]*=/ { gsub(/[[:space:]]*/, "", $1); print $1 }' "$tmp" | sort -u
  )"

  rm -f "$tmp"
  [[ -n "$__DAST_DIALOGRC_SUPPORTED_CACHE" ]]
}

_dast__dialogrc_supported_has() {
  grep -qxF "$1" <<<"$__DAST_DIALOGRC_SUPPORTED_CACHE" 2>/dev/null
}

_dast__dialogrc_add() {
  local arr="$1" key="$2" val="$3"
  _dast__dialogrc_supported_has "$key" || return 0
  local -n _a="$arr"
  _a+=("${key} = ${val}")
}

dast_theme_apply_early() {
  local mode="${1:-normal}"
  local tmp
  tmp="$(mktemp -p "${TMPDIR:-/tmp}" dast.dialogrc.early.XXXXXX 2>/dev/null || mktemp 2>/dev/null)" || return 0

  _dast__ensure_dialogrc_supported_cache || return 0

  __DAST_THEME_APPLY_EARLY_COUNT=$((__DAST_THEME_APPLY_EARLY_COUNT + 1))

  local -a lines=()

  _dast__dialogrc_add lines use_colors "ON"

  # Keep the screen consistent for ALL widgets, including passwordbox
  _dast__dialogrc_add lines screen_color "(WHITE, MAGENTA, ON)"


  _dast__dialogrc_add lines button_active_color "(WHITE, MAGENTA, ON)"
  _dast__dialogrc_add lines button_key_active_color "(YELLOW, MAGENTA, ON)"
  _dast__dialogrc_add lines button_label_active_color "(WHITE, MAGENTA, ON)"


  _dast__dialogrc_add lines item_selected_color "(WHITE, MAGENTA, ON)"

  _dast__dialogrc_add lines tag_selected_color "(WHITE, MAGENTA, ON)"


  printf '%s\n' "${lines[@]}" >"$tmp"
  export DIALOGRC="$tmp"
}

dast_theme_apply() {
  dast_theme_apply_early
}