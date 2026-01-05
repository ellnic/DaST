#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Library: dast_helper (v0.9.8.4)
# DaST lib: shared command runner (v0.9.8).
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
# DaST lib: shared command runner (v0.9.8)
# Provides:
#   - mktemp_safe
#   - run        : execute + log. Shows UI error on failure (if ui_msg exists)
#   - run_capture: execute + log, returns output to caller, never shows UI
#   - run_sh     : convenience wrapper for: bash -lc "..."
#   - run_capture_sh: capture wrapper for: bash -lc "..."
#   - dast_env_fingerprint: stable string for log/session correlation
#
# Sourced by:
#   - core (dast.sh) and modules (safe to source standalone)
# Logging:
#   - Default log dir: [app]/logs
#   - Default log file: commands.log
#
# Log rotation (recommended):
#   Install a logrotate snippet for [app]/logs/*.log, e.g.:
#
#     [app]/logs/*.log {
#       rotate 12
#       weekly
#       compress
#       missingok
#       notifempty
#       create 0644 root root
#     }
#
# Notes:
#   - This helper is designed to be sourced by multiple modules.
#   - It tries to log every command and its output.
#   - It supports a "capture" mode for callers that need stdout.
#   - UI popups are only shown if a ui_msg function exists.
#

_dast_run_now() {
  date +"%Y-%m-%d %H:%M:%S"
}

mktemp_safe() {
  local _tmp _dir

  # Default temp files go to TMPDIR (or /tmp). Use runtime only when explicitly requested.
  _dir="${TMPDIR:-/tmp}"
  if [[ "${DAST_TMP_IN_RUNTIME:-0}" -eq 1 && -n "${DAST_RUNTIME_DIR:-}" ]]; then
    _dir="$DAST_RUNTIME_DIR"
  fi
  if [[ -n "$_dir" && -d "$_dir" && -w "$_dir" ]]; then
    _tmp="$(mktemp -p "$_dir" dast.tmp.XXXXXX 2>/dev/null)" || _tmp=""
  fi
  [[ -n "$_tmp" ]] || _tmp="$(mktemp 2>/dev/null)" || return 1

  # Register for cleanup if the trap system is available.
  if declare -F _dast_tmp_register >/dev/null 2>&1; then
    _dast_tmp_register "$_tmp"
  fi

  printf '%s
' "$_tmp"
}

_dast_run_has_func() {
  declare -F "$1" >/dev/null 2>&1
}

_dast_run_ensure_logdir() {
  : "${DAST_APP_DIR:="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"}"
  : "${DAST_LOG_DIR:="${DAST_APP_DIR}/logs"}"
  : "${DAST_LOG_FILE:="commands.log"}"

  mkdir -p "$DAST_LOG_DIR" 2>/dev/null || true
  if [[ -d "$DAST_LOG_DIR" && -w "$DAST_LOG_DIR" ]]; then
    return 0
  fi

  if _dast_run_has_func ui_msg; then
    ui_msg "Logging error" "Cannot write to log directory:\n\n$DAST_LOG_DIR"
  fi
  return 1
}

_dast_run_log_path() {
  _dast_run_ensure_logdir || return 1
  printf '%s/%s' "$DAST_LOG_DIR" "$DAST_LOG_FILE"
}

_dast_run_fmt_cmd() {
  # Best-effort "pretty" command line for logs.
  # Avoids leaking control chars into logs.
  local out="" a
  for a in "$@"; do
    # Collapse newlines/tabs.
    a="${a//$'\n'/\\n}"
    a="${a//$'\t'/\\t}"
    out+="$a "
  done
  printf '%s' "${out% }"
}

_dast_run_append_log_line() {
  local line="$1"
  local log_file

  log_file="$(_dast_run_log_path)" || return 1
  printf '%s\n' "$line" >>"$log_file" 2>/dev/null || return 1
}

_dast_run_exec() {
  local mode="$1"; shift
  local cmd_safe cmd_human output rc

  cmd_human="$(_dast_run_fmt_cmd "$@")"
  cmd_safe="$cmd_human"

  # Run and capture stdout+stderr. Preserve rc.
  output="$("$@" 2>&1)"
  rc=$?

  _dast_run_append_log_line "[$(_dast_run_now)] CMD: $cmd_safe"
  _dast_run_append_log_line "[$(_dast_run_now)] RC : $rc"

  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      _dast_run_append_log_line "[$(_dast_run_now)] OUT: $line"
    done <<<"$output"
  else
    _dast_run_append_log_line "[$(_dast_run_now)] OUT:"
  fi

  if [[ $rc -ne 0 && "$mode" == "ui" ]]; then
    if _dast_run_has_func ui_msg; then
      ui_msg "Command failed (rc=$rc)" "Command:\n$cmd_human\n\nOutput:\n$output"
    fi
    return $rc
  fi

  if [[ "$mode" == "capture" ]]; then
    printf '%s' "$output"
  fi
  return $rc
}

run() {
  _dast_run_exec "ui" "$@"
}

run_capture() {
  _dast_run_exec "capture" "$@"
}

run_sh() {
  # Convenience wrapper for callers that want a single string with shell features.
  # Example: run_sh "ls -la | head"
  local cmd="${1:-}"
  run bash -lc "$cmd"
}

run_capture_sh() {
  local cmd="${1:-}"
  run_capture bash -lc "$cmd"
}

dast_env_fingerprint() {
  # Stable-ish session fingerprint for correlating log lines across modules.
  # Keep it simple and dependency-light.
  local u h p
  u="${SUDO_USER:-${USER:-unknown}}"
  h="$(hostname 2>/dev/null || echo unknown)"
  p="${PWD:-/}"
  printf '%s@%s:%s' "$u" "$h" "$p"
}
