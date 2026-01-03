#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Library: dast_priv (v0.9.8.4)
# DaST lib: privilege escalation (v0.9.8).
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
# DaST lib: privilege escalation (v0.9.8)
# Provides:
#   - dast_priv_ensure_root "$@"
#
# Behaviour:
#   - If already root: returns.
#   - If not root: uses dialog passwordbox (unless --debug-gen) with a 3-strike policy,
#     validates via sudo -S -v, then execs DaST under sudo while preserving DIALOGRC.
#

_dast_priv__dbg() {
  [[ "${DAST_DEBUG:-0}" -eq 1 ]] || return 0
  local __dbg_dir="${DEBUG_SESSION_DIR:-${LOG_SESSION_DIR:+${LOG_SESSION_DIR%/}/debug}}"
  [[ -n "$__dbg_dir" ]] || __dbg_dir="${DEBUG_DIR:-./debug}/run_${DAST_RUN_ID:-unknown}"
  mkdir -p "$__dbg_dir" >/dev/null 2>&1 || true
  local __f="$__dbg_dir/dast_priv.sh.debug.log"
  printf '%s\n' "$*" >>"$__f" 2>/dev/null || true
}

_dast_priv__log() {

  local msg="$1"
  [[ -n "${DAST_LOG_FILE:-}" ]] || return 0
  printf '%s\n' "info [CORE] PRIV: ${msg}" >>"$DAST_LOG_FILE" 2>/dev/null || true
}

_dast_priv__apply_auth_theme() {
  local rc=0

  # Prefer core's config-aware early theme generator when available.
  if declare -F _dast_apply_dialog_theme_early >/dev/null 2>&1; then
    _dast_priv__dbg "AUTH: using _dast_apply_dialog_theme_early()"
    set +e
    _dast_apply_dialog_theme_early
    rc=$?
    set -e
    _dast_priv__dbg "AUTH: _dast_apply_dialog_theme_early rc=$rc"
    _dast_priv__dbg "AUTH: DIALOGRC=${DIALOGRC:-<unset>}"

    # If early core theme didn't produce a usable DIALOGRC, fall back to lib theme.
    if [[ -z "${DIALOGRC:-}" || ! -r "${DIALOGRC:-/nope}" ]]; then
      _dast_priv__dbg "AUTH: core theme produced no readable DIALOGRC, trying dast_theme_apply_early(auth)"
      if declare -F dast_theme_apply_early >/dev/null 2>&1; then
        set +e
        dast_theme_apply_early auth
        rc=$?
        set -e
        _dast_priv__dbg "AUTH: dast_theme_apply_early rc=$rc DIALOGRC=${DIALOGRC:-<unset>}"
      fi
    fi
    return 0
  fi

  # Fallback to lib theme helper if present.
  if declare -F dast_theme_apply_early >/dev/null 2>&1; then
    _dast_priv__dbg "AUTH: using dast_theme_apply_early(auth)"
    set +e
    dast_theme_apply_early auth
    rc=$?
    set -e
    _dast_priv__dbg "AUTH: dast_theme_apply_early rc=$rc DIALOGRC=${DIALOGRC:-<unset>}"
    return 0
  fi

  _dast_priv__dbg "AUTH: no theme function available; DIALOGRC=${DIALOGRC:-<unset>}"
  return 0
}

dast_priv_ensure_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0

  if ! command -v sudo >/dev/null 2>&1; then
    echo "DaST requires sudo to elevate to root." >&2
    exit 1
  fi

  # In debug-gen mode: avoid dialog prompts (keeps output capture predictable)
  if [[ "${DAST_DEBUGGEN:-0}" -eq 1 ]]; then
    printf "DaST: sudo required. Type your sudo password now (input hidden), then press Enter.\n" >/dev/tty 2>/dev/null || true
    if ! sudo -p "" -v </dev/tty >/dev/tty 2>/dev/tty; then
      printf "DaST: sudo authentication failed.\n" >/dev/tty 2>/dev/null || true
      exit 1
    fi
    clear || true
    exec sudo -E DIALOGRC="${DIALOGRC:-}"     DAST_FORCE_EMOJI_OFF="${DAST_FORCE_EMOJI_OFF:-0}" /usr/bin/env bash "${DAST_SELF:-$0}" "${DAST_ORIG_ARGS[@]:-$@}"
  fi

  if ! command -v dialog >/dev/null 2>&1; then
    echo "DaST must be run as root. Please run: sudo ${DAST_SELF:-$0}" >&2
    exit 1
  fi

  _dast_priv__apply_auth_theme

  local attempt pass rc left
  for attempt in 1 2 3; do
    # Force sudo to require a real password each attempt (prevents cached timestamp confusion).
    sudo -k >/dev/null 2>&1 || true

    pass="$(DIALOGRC="$DIALOGRC" dialog --insecure --stdout --passwordbox "DaST requires root. Enter sudo password:" 10 60 </dev/tty 2>/dev/tty)"
    rc=$?
    clear || true

    if [[ "$rc" -ne 0 ]]; then
      _dast_priv__log "sudo prompt cancelled/failed (dialog rc=${rc})"
      exit 1
    fi

    if printf '%s\n' "$pass" | sudo -S -p "" -v >/dev/null 2>&1; then
      unset pass
      break
    fi
    unset pass

    left=$((3 - attempt))
    if [[ "$left" -gt 0 ]]; then
      _dast_priv__apply_auth_theme
      local msg="⚠ Incorrect password. Attempts left: ${left}"
      if [[ "${UI_EMOJI:-1}" -eq 0 ]] && declare -F ui_strip_known_icons_anywhere >/dev/null 2>&1; then
        msg="$(ui_strip_known_icons_anywhere "$msg")"
      fi
      DIALOGRC="$DIALOGRC" dialog --stdout --msgbox "$msg" 7 50 </dev/tty 2>/dev/tty || true
      clear || true
    else
      _dast_priv__apply_auth_theme
      local msg="🔒 Too many failed attempts. Exiting."
      if [[ "${UI_EMOJI:-1}" -eq 0 ]] && declare -F ui_strip_known_icons_anywhere >/dev/null 2>&1; then
        msg="$(ui_strip_known_icons_anywhere "$msg")"
      fi
      DIALOGRC="$DIALOGRC" dialog --stdout --msgbox "$msg" 7 50 </dev/tty 2>/dev/tty || true
      clear || true
      exit 1
    fi
  done

  # Preserve theme + invoker identity across sudo.
  exec sudo     DIALOGRC="${DIALOGRC:-}"     DAST_FORCE_EMOJI_OFF="${DAST_FORCE_EMOJI_OFF:-0}"     DAST_INVOKER_USER="${DAST_INVOKER_USER:-${SUDO_USER:-$(id -un 2>/dev/null || echo root)}}"     DAST_INVOKER_GROUP="${DAST_INVOKER_GROUP:-$(id -gn 2>/dev/null || echo root)}"     DAST_RUN_ID="${DAST_RUN_ID:-}"     /usr/bin/env bash "${DAST_SELF:-$0}" "${DAST_ORIG_ARGS[@]:-$@}"
}
