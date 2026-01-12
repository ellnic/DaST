#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST (Debian admin System Tool) v0.9.8.4
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
# DaST requires bash.
# Note: the shebang is ignored if the script is *sourced* (common in zsh).
# If we are not already in bash, re-exec safely *before* any bash-specific
# syntax is parsed. If sourced in zsh, bail out with a clear message.
# ---------------------------------------------------------------------------------------
#

if [ -z "${BASH_VERSION:-}" ]; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
      *:file)
        printf '%s\n' "DaST: this script must be *executed*, not sourced." >&2
        printf '%s\n' "Try:  ./DaST_v0.9.8.4.sh   (not: source ./DaST_v0.9.8.4.sh)" >&2
        return 1 2>/dev/null || exit 1
        ;;
    esac
  fi

  # Best effort: re-exec the current script under bash.
  # (Works for: `zsh DaST_v0.9.8.4.sh`, `sh DaST_v0.9.8.4.sh`, etc.)
  if [ -n "${0:-}" ] && [ -f "$0" ]; then
    exec bash "$0" "$@"
  fi

  printf '%s\n' "DaST: bash is required. Re-run with: bash <path-to-script>" >&2
  return 1 2>/dev/null || exit 1
fi

#
# -------------------------------------------------------------------------------------
# DaST (Debian admin System Tool) v0.9.8.4 (runtime churn patch)
# Concept inspired by SUSE's YaST
# Designed mainly for Ubuntu with limited Debian support
# -------------------------------------------------------------------------------------
#
# --- DaST safety: ensure clean bash startup ---
unset BASH_XTRACEFD
#
# Trap unexpected exits/errors early so "blink" errors are captured into the master log.
# (We keep this lightweight and always-on; it does not create ./debug.)
_dast__log_master() {
  local line="$1"
  [[ -n "${DAST_MASTER_LOG_FILE:-${DAST_LOG_FILE:-}}" ]] || return 0
  printf '%s
' "$line" >>"${DAST_MASTER_LOG_FILE:-${DAST_LOG_FILE:-}}" 2>/dev/null || true
}

_dast__on_err() {
  local rc="$1" line="$2" cmd="$3" src="$4"
  _dast__log_master "err  [CORE] abort: rc=${rc} file=${src} line=${line} cmd=${cmd}"
}

_dast__on_exit() {
  local rc="$1"
  _dast__log_master "info [CORE] exit: rc=${rc}"
}


# ----------------------------------------------------------------------------
# Debug safety: if shell tracing (-x) is enabled, ensure PS4 is safe under set -u
# Users often set PS4 to include ${FUNCNAME[0]} which is unset at top-level and
# will crash under `set -u`. We override PS4 early to a safe default.
# ----------------------------------------------------------------------------
if [[ "$-" == *x* ]]; then
  export PS4='+${BASH_SOURCE[0]-main}:${LINENO}:${FUNCNAME[0]-main}(): '
fi

set -eEuo pipefail

# -----------------------------------------------------------------------------
# Global temp cleanup (covers early dialogrc + any registered temps)
# -----------------------------------------------------------------------------
_dast_tmpfiles=()

_dast_tmp_register() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  _dast_tmpfiles+=("$p")
}

_dast_tmp_cleanup() {
  local p
  for p in "${_dast_tmpfiles[@]:-}"; do
    rm -f -- "$p" >/dev/null 2>&1 || true
  done
  _dast_tmpfiles=()
}

_dast_on_exit() {
  # Keep the master "exit" breadcrumb even though we also do temp cleanup here.
  # (A later trap assignment would otherwise overwrite the earlier EXIT trap.)
  local rc="${1:-$?}"
  _dast__on_exit "$rc"
  _dast_tmp_cleanup
}

# Preserve cleanup on signals too, while keeping a predictable rc on EXIT.
trap '_dast_on_exit "$?"' EXIT
trap '_dast_tmp_cleanup' INT TERM

if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qx "en_GB.UTF-8"; then
  export LANG="en_GB.UTF-8"
  export LC_ALL="en_GB.UTF-8"
else
  # Fallback that exists on most modern distros
  export LANG="C.UTF-8"
  export LC_ALL="C.UTF-8"
fi

# ----------------------------------------------------------------------------
# Hard requirement: dialog (DaST is a dialog-first tool; no fallback UI)
# ----------------------------------------------------------------------------
if ! command -v dialog >/dev/null 2>&1; then
  echo "ERROR: dialog is not installed. DaST requires dialog for its TUI." >&2

  # --- Surgical dialog-missing handling (distro + privilege aware) ---
  _os_id=""
  _os_name=""
  _os_class="UNKNOWN"

  if [[ -r /etc/os-release ]]; then
    _os_id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | head -n1 | sed -E 's/^ID=//; s/^"//; s/"$//')"
    _os_name="$(grep -E '^NAME=' /etc/os-release 2>/dev/null | head -n1 | sed -E 's/^NAME=//; s/^"//; s/"$//')"
  fi

  _os_id_lc="$(printf '%s' "${_os_id}" | tr '[:upper:]' '[:lower:]')"
  _os_name_lc="$(printf '%s' "${_os_name}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${_os_id_lc}" == "neon" || "${_os_name_lc}" == *"kde neon"* ]]; then
    _os_class="NEON"
  elif [[ "${_os_id_lc}" == "ubuntu" ]]; then
    _os_class="UBUNTU"
  elif [[ "${_os_id_lc}" == "debian" ]]; then
    _os_class="DEBIAN"
  else
    _os_class="UNKNOWN"
  fi

  _is_root=0
  [[ "$(id -u)" -eq 0 ]] && _is_root=1

  _has_apt=0
  command -v apt-get >/dev/null 2>&1 && _has_apt=1

  _has_sudo=0
  command -v sudo >/dev/null 2>&1 && _has_sudo=1

  _has_su=0
  command -v su >/dev/null 2>&1 && _has_su=1

  _tty_ok=0
  [[ -r /dev/tty && -w /dev/tty ]] && _tty_ok=1

  # Rule A: KDE Neon guard
  if [[ "${_os_class}" == "NEON" ]]; then
    echo "" >&2
    echo "DaST requires 'dialog' for its TUI." >&2
    echo "DaST will not auto-install dependencies on KDE neon." >&2
    echo "Please install 'dialog' using your preferred method, then rerun DaST." >&2
    exit 1
  fi

  # Rule B: Unknown OS
  if [[ "${_os_class}" == "UNKNOWN" ]]; then
    echo "" >&2
    echo "DaST requires 'dialog' for its TUI." >&2
    echo "Please install 'dialog' using your distro package manager, then rerun DaST." >&2
    exit 1
  fi

  # Rule C4: Non-interactive environment
  if [[ "${_tty_ok}" -ne 1 ]]; then
    echo "" >&2
    echo "DaST requires 'dialog' for its TUI." >&2
    echo "Non-interactive environment detected (no /dev/tty), so DaST cannot offer to install dependencies." >&2
    if [[ "${_has_apt}" -eq 1 ]]; then
      if [[ "${_is_root}" -eq 1 ]]; then
        echo "Install it as root, then rerun DaST:" >&2
        echo "apt-get install -y dialog" >&2
      else
        if [[ "${_has_sudo}" -eq 1 ]]; then
          echo "Install it, then rerun DaST:" >&2
          echo "sudo apt-get install -y dialog" >&2
        else
          echo "Install it as root, then rerun DaST:" >&2
          echo "apt-get install -y dialog" >&2
          if [[ "${_has_su}" -eq 1 ]]; then
            echo "Tip: you can become root with: su -" >&2
          fi
        fi
      fi
    else
      echo "Install 'dialog' using your package manager, then rerun DaST." >&2
    fi
    exit 1
  fi

  # Rule C: Ubuntu/Debian with apt-get
  if [[ "${_has_apt}" -eq 1 ]]; then
    if [[ "${_is_root}" -eq 1 ]]; then
      # Case C1: root
      echo "" >&2
      echo "DaST can install it now using apt-get." >&2
      printf "Install dialog now? [y/N]: " >/dev/tty
      read -r _ans </dev/tty || _ans="N"
      _ans="${_ans:-N}"
      if [[ "${_ans}" =~ ^[Yy]$ ]]; then
        apt-get update && apt-get install -y dialog
      else
        echo "" >&2
        echo "Install it as root, then rerun DaST:" >&2
        echo "apt-get install -y dialog" >&2
        exit 1
      fi
    else
      # Not root
      if [[ "${_has_sudo}" -eq 1 ]]; then
        # Case C2: sudo exists
        echo "" >&2
        echo "DaST can install it now using sudo (it may prompt for your password)." >&2
        printf "Install dialog now using sudo? [y/N]: " >/dev/tty
        read -r _ans </dev/tty || _ans="N"
        _ans="${_ans:-N}"
        if [[ "${_ans}" =~ ^[Yy]$ ]]; then
          _sudo_probe_out="$(LC_ALL=C sudo -v 2>&1)"
          _sudo_probe_rc=$?
          if [[ "${_sudo_probe_rc}" -ne 0 ]]; then
            echo "" >&2
            echo "sudo is installed, but DaST cannot use it on this account (or sudo validation failed)." >&2
            if printf '%s' "${_sudo_probe_out}" | grep -qiE 'not in the sudoers file|is not in the sudoers|may not run sudo|permission denied'; then
              echo "It looks like this user is not permitted to use sudo." >&2
            fi
            echo "" >&2
            echo "Safe alternatives:" >&2
            echo "  - Run DaST from a root shell, then install dialog and rerun DaST" >&2
            if [[ "${_has_su}" -eq 1 ]]; then
              echo "    (e.g. su -)" >&2
            fi
            echo "  - Or ask an admin to grant sudo rights" >&2
            exit 1
          fi

          sudo apt-get update && sudo apt-get install -y dialog

          if command -v dialog >/dev/null 2>&1; then
            # Re-exec elevated so the user doesn't need to restart DaST manually
            exec sudo -E bash "$0" "$@"
          fi

          echo "" >&2
          echo "dialog is still missing. Please install it and rerun DaST:" >&2
          echo "sudo apt-get install -y dialog" >&2
          exit 1
        else
          echo "" >&2
          echo "Install it, then rerun DaST:" >&2
          echo "sudo apt-get install -y dialog" >&2
          exit 1
        fi
      else
        # Case C3: sudo missing
        echo "" >&2
        echo "DaST requires 'dialog' for its TUI." >&2
        echo "sudo is not available, so DaST cannot install dependencies automatically." >&2
        echo "Install it as root, then rerun DaST:" >&2
        echo "apt-get install -y dialog" >&2
        if [[ "${_has_su}" -eq 1 ]]; then
          echo "Tip: you can become root with: su -" >&2
        fi
        exit 1
      fi
    fi
  fi

  if ! command -v dialog >/dev/null 2>&1; then
    echo "dialog is still missing. Please install it and re-run DaST." >&2
    exit 1
  fi
fi

# Debug flags
DAST_DEBUG=0
DAST_DEBUGGEN=0
for _arg in "$@"; do
  [[ "${_arg}" == "--debug" ]] && DAST_DEBUG=1
  [[ "${_arg}" == "--debug-gen" || "${_arg}" == "--debuggen" ]] && DAST_DEBUGGEN=1
done
unset _arg

APP_NAME="dast"
APP_VER="0.9.8.4"
APP_TITLE="DaST (Debian admin System Tool) v${APP_VER}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
DAST_SELF="${SCRIPT_DIR}/${BASH_SOURCE[0]##*/}"
DAST_ORIG_ARGS=("$@")
# Load DaST libs (v0.9.4 modular split)
for _lib in "$LIB_DIR/dast_config.sh" "$LIB_DIR/dast_theme.sh" "$LIB_DIR/dast_priv.sh" "$LIB_DIR/dast_ui.sh" "$LIB_DIR/dast_helper.sh"; do
  [[ -f "$_lib" ]] && source "$_lib"
done
unset _lib

# -----------------------------------------------------------------------------
# Early app dirs + logging harness
#
# Requirements:
# - Standard logs should *always* work and live inside the app dir.
# - Debug artefacts should only exist when --debug / --debug-gen is used.
# - Runtime (temp) should live inside the app dir for debuggability.
# -----------------------------------------------------------------------------
APP_DIR="${SCRIPT_DIR}"

LOG_DIR="${LOG_DIR:-${APP_DIR}/logs}"
CFG_DIR="${CFG_DIR:-${APP_DIR}/config}"
CFG_FILE="${CFG_FILE:-${CFG_DIR}/dast.conf}"

# Runtime dir: must be user-owned and stable across sudo re-exec.
# Prefer app-local runtime dir for visibility (inside the DaST folder).
# If the app dir is not writable (rare), fall back to /tmp.
: "${DAST_INVOKER_UID:=${SUDO_UID:-$(id -u 2>/dev/null || echo 0)}}"
RUNTIME_DIR="${RUNTIME_DIR:-${APP_DIR}/runtime}"
DAST_RUNTIME_DIR="${DAST_RUNTIME_DIR:-${RUNTIME_DIR}}"
export DAST_INVOKER_UID DAST_RUNTIME_DIR

# Debug base dir (do NOT create unless debug is enabled)
DEBUG_DIR="${DEBUG_DIR:-${APP_DIR}/debug}"

# If debug is not enabled, point DEBUG_DIR at /dev/null to prevent accidental fallbacks
# (some modules may use ${DEBUG_DIR:-$APP_DIR/debug} and would otherwise create ./debug).
if [[ "${DAST_DEBUG:-0}" -eq 0 && "${DAST_DEBUGGEN:-0}" -eq 0 ]]; then
  DEBUG_DIR="/dev/null"
fi

# Per-run session directories (fresh files each run)
DAST_RUN_ID="${DAST_RUN_ID:-$(date +"%Y%m%d_%H%M%S")_$$}"
LOG_SESSION_DIR="${LOG_SESSION_DIR:-${LOG_DIR}/run_${DAST_RUN_ID}}"
DEBUG_SESSION_DIR="${DEBUG_SESSION_DIR:-}"  # populated only when debug is enabled

DAST_CORE_LOG_FILE="${DAST_CORE_LOG_FILE:-${LOG_SESSION_DIR}/dast.log}"
DAST_MASTER_LOG_FILE="${DAST_MASTER_LOG_FILE:-${LOG_SESSION_DIR}/dast.log}"
# Back-compat: DAST_LOG_FILE refers to the CORE log (main script only)
DAST_LOG_FILE="${DAST_CORE_LOG_FILE}"
DAST_DEBUG_LOG_FILE="${DAST_DEBUG_LOG_FILE:-}"  # populated only when debug is enabled

# Identify the invoker early so root-prompt theming can chown runtime artefacts back to the user.
# (If already set by dast_priv_ensure_root, this is a no-op.)
: "${DAST_INVOKER_USER:=${SUDO_USER:-$(id -un 2>/dev/null || echo root)}}"
: "${DAST_INVOKER_GROUP:=$(id -gn 2>/dev/null || echo root)}"


# Standard dirs always exist.
if ! mkdir -p "$LOG_SESSION_DIR" "$CFG_DIR" "$DAST_RUNTIME_DIR" 2>/dev/null; then
  DAST_RUNTIME_DIR="/tmp/dast.${DAST_INVOKER_UID}"
  export DAST_RUNTIME_DIR
  mkdir -p "$LOG_SESSION_DIR" "$CFG_DIR" "$DAST_RUNTIME_DIR" 2>/dev/null || true
fi
chmod 700 "$DAST_RUNTIME_DIR" 2>/dev/null || true
if [[ "${EUID:-$(id -u)}" -eq 0 && "${DAST_INVOKER_UID:-0}" -ne 0 ]]; then
  chown "${DAST_INVOKER_USER:-${SUDO_USER:-root}}:${DAST_INVOKER_GROUP:-root}" "$DAST_RUNTIME_DIR" 2>/dev/null || true
fi

# Ensure the main log exists (best effort)
: >"$DAST_CORE_LOG_FILE" 2>/dev/null || true
: >"$DAST_MASTER_LOG_FILE" 2>/dev/null || true
# Prime run log early so non-root pre-elevation runs still leave a breadcrumb
printf '%s
' "info [CORE] loader: start (uid=$(id -u 2>/dev/null || echo ?), euid=$(id -u 2>/dev/null || echo ?), run_id=${DAST_RUN_ID})" >>"$DAST_CORE_LOG_FILE" 2>/dev/null || true

# Runtime dir safety: must be private to the invoker to avoid symlink tricks and make debugging easy.
if [[ -L "$DAST_RUNTIME_DIR" ]]; then
  echo "DaST: runtime dir is a symlink (refusing): $DAST_RUNTIME_DIR" >&2
  exit 1
fi
chmod 700 "$DAST_RUNTIME_DIR" >/dev/null 2>&1 || true
# If we're already root (or later, after sudo re-exec), ensure invoker owns the runtime dir and its artefacts.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  chown "${DAST_INVOKER_USER}:${DAST_INVOKER_GROUP}" "$DAST_RUNTIME_DIR" >/dev/null 2>&1 || true
fi
# Refuse group/world writable runtime dir (security).
if command -v stat >/dev/null 2>&1; then
  _dast_rt_mode="$(stat -c %a "$DAST_RUNTIME_DIR" 2>/dev/null || echo "")"
  if [[ -n "$_dast_rt_mode" ]]; then
    # last digit is "other" perms, middle is "group"
    _dast_rt_other="${_dast_rt_mode: -1}"
    _dast_rt_group="${_dast_rt_mode: -2:1}"
    if [[ "$_dast_rt_group" != "0" || "$_dast_rt_other" != "0" ]]; then
      echo "DaST: runtime dir permissions must be 700 (got ${_dast_rt_mode}): $DAST_RUNTIME_DIR" >&2
      exit 1
    fi
  fi
  unset _dast_rt_mode _dast_rt_other _dast_rt_group
fi
# -----------------------------------------------------------------------------
# Early UI theme apply (for the sudo password dialog)
# -----------------------------------------------------------------------------
# Why: if DaST is launched as a normal user, we show a dialog passwordbox before
# the full loader has run. We still want the selected colour theme visible here.
_dast_cfg_get_early() {
  local key="$1"
  local def="${2:-}"
  [[ -r "$CFG_FILE" ]] || { printf '%s' "$def"; return 0; }
  # Read last matching key=value (ignore comments/blank lines)
  local val
  val="$(awk -F= -v k="$key" '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1==k) {
        $1=""
        sub(/^=/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        v=$0
      }
    }
    END { if (v!="") print v }
  ' "$CFG_FILE" 2>/dev/null || true)"

  # Strip simple surrounding quotes if present (legacy configs sometimes store tuples quoted).
  if [[ "$val" =~ ^\".*\"$ ]]; then val="${val#\"}"; val="${val%\"}"; fi
  if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val#\'}"; val="${val%\'}"; fi
  # Ignore literal shell expansions from older default configs.
  if [[ "$val" == *'${'*'}'* ]]; then val=""; fi
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$def"
  fi
}

_dast_apply_dialog_theme_early() {
  # Only bother if dialog is present
  command -v dialog >/dev/null 2>&1 || return 0

  # Reuse a single early dialogrc per run to avoid tmp-file churn/leaks.
  if [[ -n "${DAST_EARLY_DIALOGRC:-}" && -f "${DAST_EARLY_DIALOGRC:-}" ]]; then
    export DIALOGRC="$DAST_EARLY_DIALOGRC"
    return 0
  fi

  use_colours="1"

  screen_colour="(WHITE,MAGENTA,ON)"
  item_sel_colour="(WHITE,MAGENTA,ON)"
  tag_sel_colour="(WHITE,MAGENTA,ON)"
  btn_active_colour="(WHITE,MAGENTA,ON)"
  btn_key_active_colour="(YELLOW,MAGENTA,ON)"
  btn_label_active_colour="(WHITE,MAGENTA,ON)"


  # Normalise "(WHITE,MAGENTA,ON)" -> "(WHITE, MAGENTA, ON)"
  _dast__norm_tuple() {
    local s="${1:-}"
    s="${s//\(/(}"; s="${s//\)/)}"; s="${s//\,/,}"
    s="${s//,/,\ }"
    printf '%s' "$s"
  }

local run_dir="${DAST_RUNTIME_DIR:-/tmp}"
local tmp_rc=""

# Single, stable dialogrc for the whole run (no mktemp churn).
mkdir -p "$run_dir" >/dev/null 2>&1 || return 0
chmod 700 "$run_dir" >/dev/null 2>&1 || true
tmp_rc="$run_dir/dialogrc"
: >"$tmp_rc" 2>/dev/null || return 0
chmod 600 "$tmp_rc" >/dev/null 2>&1 || true
if [[ "${EUID:-$(id -u)}" -eq 0 && "${DAST_INVOKER_UID:-0}" -ne 0 ]]; then
  chown "${DAST_INVOKER_USER:-${SUDO_USER:-root}}:${DAST_INVOKER_GROUP:-root}" "$tmp_rc" >/dev/null 2>&1 || true
fi

  if [[ "${use_colours}" -eq 1 ]]; then
    cat >"$tmp_rc" <<EOF
use_colors = ON
screen_color = $(_dast__norm_tuple "$screen_colour")
item_selected_color = $(_dast__norm_tuple "$item_sel_colour")
tag_selected_color  = $(_dast__norm_tuple "$tag_sel_colour")
button_active_color = $(_dast__norm_tuple "$btn_active_colour")
button_key_active_color = $(_dast__norm_tuple "$btn_key_active_colour")
button_label_active_color = $(_dast__norm_tuple "$btn_label_active_colour")
EOF
  else
    cat >"$tmp_rc" <<'EOF'
use_colors = OFF
EOF
  fi

  DAST_EARLY_DIALOGRC="$tmp_rc"
  export DIALOGRC="$DAST_EARLY_DIALOGRC"
  # Intentionally not registered as a temp: stable runtime file reused each run.
  return 0
}

# -----------------------------------------------------------------------------
# Local root elevation helper (keeps dialog theme + forces real password check)
#
# Why:
# - sudo can keep a timestamp; if we show our own passwordbox while sudo doesn't
#   actually need a password, it will look like "any password works".
# - some sudo configurations drop or ignore DIALOGRC, so we pass it explicitly.
#
# This helper:
# - invalidates sudo timestamp (sudo -k)
# - prompts via dialog (with explicit DIALOGRC)
# - validates the password using `sudo -S -v`
# - re-execs DaST under sudo while preserving DIALOGRC + invoker identity
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Invoker identity (real user who launched DaST, even though we run as root)
# -----------------------------------------------------------------------------
_dast_invoker_user() {
  # Prefer persisted invoker (set before sudo re-exec) if present.
  if [[ -n "${DAST_INVOKER_USER:-}" && "${DAST_INVOKER_USER}" != "root" ]]; then
    printf '%s' "$DAST_INVOKER_USER"
    return 0
  fi
  # Prefer sudo's reported user; fall back to logname for edge cases.
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s' "$SUDO_USER"
    return 0
  fi

  local ln
  ln="$(logname 2>/dev/null || true)"
  if [[ -n "$ln" && "$ln" != "root" ]]; then
    printf '%s' "$ln"
    return 0
  fi

  # If we're root but DaST lives in a user-owned tree (common when people "su -" then run it),
  # infer the "real" user from the install path so config doesn't get stuck root-owned.
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local owner
    owner="$(stat -c '%U' "${SCRIPT_DIR:-.}" 2>/dev/null || true)"
    if [[ -n "$owner" && "$owner" != "root" ]] && id -u "$owner" >/dev/null 2>&1; then
      printf '%s' "$owner"
      return 0
    fi
    owner="$(stat -c '%U' "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
    if [[ -n "$owner" && "$owner" != "root" ]] && id -u "$owner" >/dev/null 2>&1; then
      printf '%s' "$owner"
      return 0
    fi
  fi

  printf '%s' "root"
}
_dast_invoker_group() {
  # Prefer persisted invoker group if present.
  if [[ -n "${DAST_INVOKER_GROUP:-}" && -n "${DAST_INVOKER_USER:-}" && "${DAST_INVOKER_USER}" != "root" ]]; then
    printf '%s' "$DAST_INVOKER_GROUP"
    return 0
  fi
  local u
  u="$(_dast_invoker_user)"
  id -gn "$u" 2>/dev/null || printf '%s' "$u"
}

_dast_log_early() {
  local lvl="$1"; shift || true
  printf "%s [CORE] %s
" "${lvl,,}" "$*" >>"${DAST_CORE_LOG_FILE:-${DAST_LOG_FILE:-/dev/null}}" 2>/dev/null || true
  printf "%s [CORE] %s
" "${lvl,,}" "$*" >>"${DAST_MASTER_LOG_FILE:-${DAST_LOG_FILE:-/dev/null}}" 2>/dev/null || true
}

_dast__tag_to_file() {
  # Convert a tag into a safe filename stem
  # - lower-case
  # - replace non [a-z0-9_-] with '_'
  local t="${1:-unknown}"
  t="${t,,}"
  t="${t//[^a-z0-9_-]/_}"
  printf '%s' "$t"
}

_dast__ensure_log_owner() {
  # Best-effort: make new artefacts owned by the invoker, so they can grab logs.
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0
  local u g
  u="$(_dast_invoker_user 2>/dev/null || echo root)"
  g="$(_dast_invoker_group 2>/dev/null || echo root)"
  [[ -n "$u" ]] || u="root"
  [[ -n "$g" ]] || g="root"
  [[ "$u" != "root" ]] || return 0
  chown "$u:$g" "$@" >/dev/null 2>&1 || true
}

dast_log() {
  # Usage: dast_log LEVEL TAG message...
  local lvl="${1:-INFO}" tag="${2:-CORE}"
  shift 2 || true
  local msg="$*"
  local stem file
  stem="$(_dast__tag_to_file "$tag")"
  if [[ "${tag}" == "CORE" ]]; then
    file="${DAST_CORE_LOG_FILE:-${LOG_SESSION_DIR%/}/dast.log}"
  else
    # Per-tag logs are debug-only. In normal mode we only write to dast.log.
    if [[ "${DAST_DEBUG:-0}" -eq 1 ]]; then
      mkdir -p "${LOG_SESSION_DIR%/}/modules" 2>/dev/null || true
      file="${LOG_SESSION_DIR%/}/modules/${stem}.log"
    else
      file=""
    fi
  fi

  # Best effort: ensure the per-tag log exists (debug-only)
  if [[ -n "${file:-}" ]]; then
    : >>"$file" 2>/dev/null || true
    _dast__ensure_log_owner "$file" "$LOG_SESSION_DIR" "$LOG_DIR" >/dev/null 2>&1 || true

    printf "%s [%s] %s
" "${lvl,,}" "$tag" "$msg" >>"$file" 2>/dev/null || true
  fi
  # Always append to the master combined log
  printf "%s [%s] %s
" "${lvl,,}" "$tag" "$msg" >>"$DAST_MASTER_LOG_FILE" 2>/dev/null || true
  # Append to the CORE log only for CORE-tagged messages (main script only)
  if [[ "$tag" == "CORE" ]]; then
    printf "%s [%s] %s
" "${lvl,,}" "$tag" "$msg" >>"$DAST_CORE_LOG_FILE" 2>/dev/null || true
  fi
}

dast_dbg() {
  # Usage: dast_dbg TAG message...
  [[ "${DAST_DEBUG:-0}" -eq 1 ]] || return 0
  [[ -n "${DEBUG_SESSION_DIR:-}" ]] || return 0

  local tag="${1:-CORE}"
  shift || true
  local msg="$*"
  local stem file
  stem="$(_dast__tag_to_file "$tag")"
  if [[ "${tag}" == "CORE" ]]; then
    file="${DEBUG_SESSION_DIR%/}/dast.debug.log"
  else
    mkdir -p "${DEBUG_SESSION_DIR%/}/modules" 2>/dev/null || true
    file="${DEBUG_SESSION_DIR%/}/modules/${stem}.debug.log"
  fi

  : >>"$file" 2>/dev/null || true
  _dast__ensure_log_owner "$file" "$DEBUG_SESSION_DIR" "$DEBUG_DIR" >/dev/null 2>&1 || true

  printf "dbg [%s] %s
" "$tag" "$msg" >>"$file" 2>/dev/null || true
}

_dast_run_append_log_line() {
  # Compatibility helper used by some modules
  local line="$*"
  local f="${LOG_SESSION_DIR%/}/run.log"
  : >>"$f" 2>/dev/null || true
  _dast__ensure_log_owner "$f" >/dev/null 2>&1 || true
  printf '%s\n' "$line" >>"$f" 2>/dev/null || true
}

_dast_debug_enable() {
  [[ -n "${DEBUG_DIR:-}" ]] || return 0
  [[ "${DEBUG_DIR}" != "/dev/null" ]] || return 0
  # Debug artefacts live inside this run folder so everything for a run is in one place.
  # We keep them session-scoped so each run gets fresh files.
  DEBUG_SESSION_DIR="${DEBUG_SESSION_DIR:-${LOG_SESSION_DIR%/}/debug}"
  local trace_file="${DEBUG_SESSION_DIR}/dast_trace.log"
  local err_file="${DEBUG_SESSION_DIR}/dast_err.log"
  local target_owner target_group

  # Best effort: never hard-fail debug mode
  mkdir -p "$DEBUG_SESSION_DIR" 2>/dev/null || true

  # Prefer the real invoker for ownership, even though we are running as root.
  target_owner="$(_dast_invoker_user 2>/dev/null || echo root)"
  target_group="$(_dast_invoker_group 2>/dev/null || echo root)"
  [[ -n "$target_owner" ]] || target_owner="root"
  [[ -n "$target_group" ]] || target_group="root"

  # Ensure files exist with sane perms/ownership before we attach xtrace FD 9.
  : >"$trace_file" 2>/dev/null || true
  : >"$err_file" 2>/dev/null || true
  chmod 644 "$trace_file" "$err_file" 2>/dev/null || true

  # Keep debug artefacts owned by the invoker where possible.
  if [[ "$target_owner" != "root" ]]; then
    chown "$target_owner:$target_group" "$DEBUG_DIR" "$DEBUG_SESSION_DIR" "$trace_file" "$err_file" 2>/dev/null || true
  fi

  # Bash xtrace -> file descriptor 9 (only if FD 9 can be opened)
  unset BASH_XTRACEFD 2>/dev/null || true
  if exec 9>>"$trace_file" 2>/dev/null; then
    export BASH_XTRACEFD=9
    export PS4='+${BASH_SOURCE[0]-main}:${LINENO}:${FUNCNAME[0]-main}(): '
    set -o xtrace
  else
    export PS4='+${BASH_SOURCE[0]-main}:${LINENO}:${FUNCNAME[0]-main}(): '
    _dast_log_early "WARN" "CORE: debug trace disabled (cannot open $trace_file)"
  fi

  set -o errtrace

  # Nounset-safe ERR trap (do not override existing EXIT handler)
  trap '_rc=$?; src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]-unknown}}"; ln="${BASH_LINENO[0]:-${LINENO:-?}}"; fn="${FUNCNAME[1]-${FUNCNAME[0]-main}}"; cmd="${BASH_COMMAND:-?}"; printf "%s [ERR] rc=%s file=%s line=%s func=%s cmd=%s
" "$(date +"%Y-%m-%d %H:%M:%S")" "$_rc" "$src" "$ln" "$fn" "$cmd" >>"'"$err_file"'" 2>/dev/null || true; _dast_log_early "ERROR" "CORE: ERR rc=${_rc} at ${src}:${ln} func=${fn} cmd=${cmd}";' ERR

  _dast_log_early "INFO" "debug enabled (trace=$(basename "$trace_file") err=$(basename "$err_file"))"
}

_dast_debug_gen() {
  local ts report_file
  ts="$(date +"%Y%m%d_%H%M%S")"
  DEBUG_SESSION_DIR="${DEBUG_SESSION_DIR:-${LOG_SESSION_DIR%/}/debug}"
  report_file="${DEBUG_SESSION_DIR}/dast_debuggen_${ts}.txt"

  mkdir -p "$DEBUG_SESSION_DIR" "$LOG_SESSION_DIR" 2>/dev/null || true

  {
    echo "DaST debug-gen report"
    echo "Timestamp: $(date -Is 2>/dev/null || date)"
    echo "App version: ${APP_VER}"
    echo "Script: $0"
    echo "Script dir: ${SCRIPT_DIR}"
    echo "User: $(id -un 2>/dev/null || echo unknown) (uid=$(id -u 2>/dev/null || echo ?))"
    echo "SUDO_USER: ${SUDO_USER:-}"
    echo "EUID: ${EUID:-$(id -u 2>/dev/null || echo ?)}"
    echo
    echo "Environment"
    echo "  TERM=${TERM:-}"
    echo "  LANG=${LANG:-}"
    echo "  LC_ALL=${LC_ALL:-}"
    echo
    echo "Versions"
    echo "  bash: ${BASH_VERSION:-}"
    echo -n "  dialog: " ; dialog --version 2>/dev/null | head -n 1 || echo "missing"
    echo -n "  distro: " ; (command -v lsb_release >/dev/null 2>&1 && lsb_release -ds) 2>/dev/null || (grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"') || echo "unknown"
    echo
    echo "Locales (first 50)"
    (command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | head -n 50) || true
    echo
    echo "Processes"
    pgrep -a dialog 2>/dev/null || true
    ps -o pid,ppid,stat,cmd -C bash -C sudo -C dialog 2>/dev/null || true
    echo
    echo "Paths"
    echo "  LOG_DIR=$LOG_DIR"
    echo "  DEBUG_DIR=$DEBUG_DIR"
    echo "  CFG_DIR=$CFG_DIR"
    echo "  CFG_FILE=$CFG_FILE"
    echo
    echo "Tree permissions (top level)"
    (ls -ld "$SCRIPT_DIR" "$SCRIPT_DIR/modules" "$LOG_DIR" "$CFG_DIR" 2>/dev/null) || true
    [[ -d "$DEBUG_DIR" ]] && (ls -ld "$DEBUG_DIR" "$DEBUG_SESSION_DIR" 2>/dev/null) || true
    echo
    echo "Config (head)"
    (sed -n '1,120p' "$CFG_FILE" 2>/dev/null) || echo "(missing/unreadable)"
    echo
    echo "Recent logs"
    echo "---- dast.log (CORE) (tail 200) ----"
    (tail -n 200 "$DAST_CORE_LOG_FILE" 2>/dev/null) || true
    echo
    echo "---- modules/module.log (tail 200) ----"
    (tail -n 200 "${LOG_SESSION_DIR%/}/modules/module.log" 2>/dev/null) || true
    echo
    echo "---- modules/services.log (tail 200) ----"
    (tail -n 200 "${LOG_SESSION_DIR%/}/modules/services.log" 2>/dev/null) || true
    echo
    echo "---- dast_trace.log (tail 200) ----"
    (tail -n 200 "${DEBUG_SESSION_DIR}/dast_trace.log" 2>/dev/null) || true
    echo
    echo "---- dast_err.log (tail 200) ----"
    (tail -n 200 "${DEBUG_SESSION_DIR}/dast_err.log" 2>/dev/null) || true
    echo
    echo "Done."
  } >"$report_file" 2>/dev/null || true

  _dast_log_early "INFO" "debug-gen wrote $(basename "$report_file")"
  printf "DaST: debug-gen wrote: %s\n" "$report_file" >/dev/tty 2>/dev/null || true
}

[[ "${DAST_DEBUG:-0}" -eq 1 && "${EUID:-$(id -u)}" -eq 0 ]] && _dast_debug_enable
# -----------------------------------------------------------------------------
# Root check (DaST must run as root)
# If not root, prompt for sudo password using dialog and re-exec.
# -----------------------------------------------------------------------------
dast_theme_apply_early auth || _dast_apply_dialog_theme_early || true


if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  # Apply theme early (so the sudo/password dialog uses the chosen colours)
  if declare -F dast_theme_apply_early >/dev/null 2>&1; then
    dast_theme_apply_early auth || true
  else
    _dast_apply_dialog_theme_early || true
  fi

  # Request elevation and re-exec as root (keeps the UI in dialog unless --debug-gen)
	dast_priv_ensure_root "$@"
fi

# --debug-gen: dump diagnostics into a single file and exit (no UI)
if [[ "${DAST_DEBUGGEN:-0}" -eq 1 ]]; then
  # _dast_debug_gen is defined inside _dast_debug_enable; ensure it exists here.
  type _dast_debug_gen >/dev/null 2>&1 || _dast_debug_enable
  _dast_debug_gen
  exit 0
fi


# -----------------------------------------------------------------------------
# Script folder sanity check (permissions + ownership)
# -----------------------------------------------------------------------------
# Why: DaST sources modules from the script tree, and uses config/dast.conf for settings.
# If the folder/files are missing read/execute bits, or are owned in a weird way,
# DaST can appear to "load modules" but fail when trying to use them.
#
# Behaviour:
# - If issues are detected, show a warning and offer:
#     Continue (no fix) | Fix (attempt to correct) | Exit
# - Fix chooses a sensible ownership target:
#     * If running via sudo and DaST lives inside the invoking user's HOME -> user:group
#     * Otherwise -> root:root
# - Permissions applied (conservative + typical):
#     * Directories: 755
#     * *.sh files: 644 (sourced, not executed)
#     * Main DaST script ($0): 755
#     * (no persistent dialogrc file)
dast_perm_check() {
  local invoker inv_group inv_home target_owner target_group
  local issues="" f d
  local severe=0

  # test access as the invoking user (best effort, even if sudo isn't available)
  _dast_invoker_test() {
    local _inv="$1" _op="$2" _path="$3"
    if [[ "$_inv" == "root" || "$_inv" == "$(id -un 2>/dev/null || echo root)" || ! -x "$(command -v sudo 2>/dev/null || true)" ]]; then
      test "$_op" "$_path"
    else
      sudo -u "$_inv" test "$_op" "$_path"
    fi
  }

  invoker="$(_dast_invoker_user)"
  if id "$invoker" >/dev/null 2>&1; then
    inv_group="$(id -gn "$invoker" 2>/dev/null || echo "$invoker")"
    inv_home="$(getent passwd "$invoker" 2>/dev/null | awk -F: '{print $6}')"
  else
    invoker="root"
    inv_group="root"
    inv_home="/root"
  fi

  target_owner="root"
  target_group="root"
  if [[ "$invoker" != "root" ]]; then
    target_owner="$invoker"
    target_group="$inv_group"
  else
    # If invoker detection resolves to root (eg. su -), prefer the owner of the DaST tree
    # so config remains writable/persistent for the human who installed/maintains it.
    local sd_owner sd_group
    sd_owner="$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || true)"
    sd_group="$(stat -c '%G' "$SCRIPT_DIR" 2>/dev/null || true)"
    if [[ -n "$sd_owner" && "$sd_owner" != "root" ]] && id -u "$sd_owner" >/dev/null 2>&1; then
      target_owner="$sd_owner"
      target_group="${sd_group:-$sd_owner}"
    fi
  fi

  # Config dir/file: keep writable by the invoking user (and fix perms if wrong)
  mkdir -p "$CFG_DIR" 2>/dev/null || true
  touch "$CFG_FILE" 2>/dev/null || true
  chmod 755 "$CFG_DIR" 2>/dev/null || true
  chmod 644 "$CFG_FILE" 2>/dev/null || true
  chown "$target_owner:$target_group" "$CFG_DIR" "$CFG_FILE" 2>/dev/null || true

  # Directories must be searchable (x) and readable (r) to list modules.
  for d in "$SCRIPT_DIR" "$SCRIPT_DIR/modules"; do
    [[ -d "$d" ]] || continue
    if ! _dast_invoker_test "$invoker" -r "$d" 2>/dev/null || ! _dast_invoker_test "$invoker" -x "$d" 2>/dev/null; then
      issues+=$'\n'"- Invoker '$invoker' cannot access directory: $d (needs r+x)"
    fi
    if [[ ! -r "$d" || ! -x "$d" ]]; then
      issues+=$'\n'"- Root cannot access directory: $d (unexpected)"
    fi
    if [[ -w "$d" && "$(stat -c %U "$d" 2>/dev/null || echo '')" != "$target_owner" ]]; then
      : # writable dirs are fine; ownership handled below
    fi
    # Flag world-writable dirs (security smell)
    if [[ -w "$d" && "$(stat -c %a "$d" 2>/dev/null || echo 0)" =~ .*[2367]$ ]]; then
      issues+=$'
'"- Directory is world-writable (unsafe): $d"
      severe=1
    fi
  done

  # Main script should be readable by invoker and executable.
  if ! _dast_invoker_test "$invoker" -r "$0" 2>/dev/null || ! _dast_invoker_test "$invoker" -x "$0" 2>/dev/null; then
    issues+=$'\n'"- Invoker '$invoker' cannot read/execute: $0"
  fi

  # Module files must be readable by invoker (they are sourced as root, but this keeps installs sane).
  if [[ -d "$SCRIPT_DIR/modules" ]]; then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      if ! _dast_invoker_test "$invoker" -r "$f" 2>/dev/null; then
        issues+=$'\n'"- Invoker '$invoker' cannot read module: $f"
      fi
      # Flag group/world-writable module files (security smell)
      if [[ -w "$f" && "$(stat -c %a "$f" 2>/dev/null || echo 0)" =~ ..[2367]$ ]]; then
        issues+=$'
'"- Module file is group/world-writable (unsafe): $f"
        severe=1
      fi
    done < <(find "$SCRIPT_DIR/modules" -maxdepth 1 -type f -name "*.sh" 2>/dev/null | sort)
  fi

  # If we already can't create runtime dialog theme later, flag it now.
  if ! test -w "$SCRIPT_DIR" 2>/dev/null; then
    issues+=$'\n'"- Script directory is not writable by root? ($SCRIPT_DIR)"
  fi

  if [[ -z "$issues" ]]; then
    return 0
  fi

  local msg
  msg="DaST noticed permission/ownership issues in its script folder.\n\nThese can cause weird behaviour (modules not opening, theme file failing to write, etc.).\n\nDetected:\n${issues}\n\nSuggested ownership target if you choose Fix:\n  ${target_owner}:${target_group}\n\nWhat would you like to do?"

  if [[ "$severe" -eq 1 ]]; then
    msg+="\n\nWARNING: World/group-writable DaST files can allow privilege escalation. Strongly recommended: Fix."
  fi

  if command -v dialog >/dev/null 2>&1; then
    local _dast_tmp_dialogrc choice rc
    _dast_tmp_dialogrc="${DAST_RUNTIME_DIR:-/tmp}/dialogrc.perms"
    mkdir -p "${DAST_RUNTIME_DIR:-/tmp}" >/dev/null 2>&1 || true
    : >"$_dast_tmp_dialogrc" 2>/dev/null || true
    chmod 600 "$_dast_tmp_dialogrc" 2>/dev/null || true
    if [[ "${EUID:-$(id -u)}" -eq 0 && "${DAST_INVOKER_UID:-0}" -ne 0 ]]; then
      chown "${DAST_INVOKER_USER:-${SUDO_USER:-root}}:${DAST_INVOKER_GROUP:-root}" "$_dast_tmp_dialogrc" 2>/dev/null || true
    fi
    local __old_dialogrc="${DIALOGRC:-}"
    export DIALOGRC="$_dast_tmp_dialogrc"
    
cat >"$_dast_tmp_dialogrc" <<'EOF'
use_colors = ON
screen_color = (WHITE, MAGENTA, ON)
item_selected_color = (WHITE, MAGENTA, ON)
tag_selected_color  = (WHITE, MAGENTA, ON)
button_active_color = (WHITE, MAGENTA, ON)
button_key_active_color = (YELLOW, MAGENTA, ON)
button_label_active_color = (WHITE, MAGENTA, ON)
EOF

    set +e
    dast_ui_dialog --clear --title "🚨 DaST folder permissions" --msgbox "$msg" 18 80
    rc=$?
    set -e
    [[ $rc -eq 0 ]] || { [[ -n "${_dast_tmp_dialogrc:-}" ]] && rm -f "$_dast_tmp_dialogrc" 2>/dev/null || true; clear || true; return 1;
    # Restore prior dialogrc env
    if [[ -n "${__old_dialogrc:-}" ]]; then export DIALOGRC="$__old_dialogrc"; else unset DIALOGRC 2>/dev/null || true; fi
 } #
    # 3-way choice
    set +e
    choice="$(
      dast_ui_dialog --clear --title "Choose an action" \
        --menu "Select one:" 12 70 3 \
        "continue" "Continue (no fix)" \
        "fix"      "Fix permissions/ownership" \
        "exit"     "Exit DaST" \
        3>&1 1>&2 2>&3
    )"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      clear
      exit 1
    fi
  else
    echo "WARNING: DaST folder permissions look wrong:" >&2
    printf '%b\n' "$issues" >&2
    echo >&2
    echo "1) Continue (no fix)" >&2
    echo "2) Fix permissions/ownership" >&2
    echo "3) Exit" >&2
    read -r -p "Choose [1-3]: " choice || choice="3"
    case "$choice" in
      1) choice="continue" ;;
      2) choice="fix" ;;
      *) choice="exit" ;;
    esac
    if [[ -n "${__old_dialogrc:-}" ]]; then export DIALOGRC="$__old_dialogrc"; else unset DIALOGRC 2>/dev/null || true; fi
  fi

  case "$choice" in
    continue)
      return 0
      ;;
    exit)
      clear || true
      exit 1
      ;;
    fix)
      # Ownership
      chown -R "${target_owner}:${target_group}" "$SCRIPT_DIR" 2>/dev/null || true

      # Permissions
      # - Directories: 755
      # - Files: default to 644 (safe for config/data)
      # - Any file already marked executable: 755 (preserve intentional executables)
      # Capture currently-executable files *before* we normalise perms
      local -a __exec_files=()
      while IFS= read -r -d '' __f; do
        __exec_files+=("$__f")
      done < <(find "$SCRIPT_DIR" -type f -perm /111 -print0 2>/dev/null)

      # Permissions
      # - Directories: 755
      # - Files: default to 644 (safe for config/data)
      # - Files that were executable before: 755 (preserve intentional executables)
      find "$SCRIPT_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
      find "$SCRIPT_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
      if (( ${#__exec_files[@]} > 0 )); then
        chmod 755 "${__exec_files[@]}" 2>/dev/null || true
      fi
      chmod 755 "$0" 2>/dev/null || true
      chmod 644 "$DIALOGRC_FILE" 2>/dev/null || true

      # Re-check and warn if still not clean
      if ! dast_perm_check_quiet "$invoker"; then
        if command -v dialog >/dev/null 2>&1; then
          dast_ui_dialog --clear --title "🚨 Fix attempted" --msgbox "DaST attempted to fix permissions, but some issues may remain.\n\nIf DaST is on a read-only filesystem or in a protected location, you may need to adjust manually.\n\nContinuing anyway." 12 70 || true
        else
          echo "DaST: Fix attempted, but some issues may remain. Continuing anyway." >&2
        fi
      fi
      return 0
      ;;
    *)
      if [[ "$severe" -eq 1 ]]; then
        if command -v dialog >/dev/null 2>&1; then
          dast_ui_dialog --clear --title "🚨 Unsafe permissions" --yesno "World/group-writable DaST files were detected. Continuing can allow privilege escalation.

Do you REALLY want to continue without fixing?" 12 70
          [[ $? -eq 0 ]] || return 1
        else
          echo "DaST: Unsafe permissions detected. Refusing to continue without Fix." >&2
          return 1
        fi
      fi
      return 0
      ;;
  esac
}

# Quiet post-fix check (no UI)
dast_perm_check_quiet() {
  local invoker="${1:-${SUDO_USER:-root}}"
  local d
  _dast_invoker_test_quiet() {
    local _inv="$1" _op="$2" _path="$3"
    if [[ "$_inv" == "root" || "$_inv" == "$(id -un 2>/dev/null || echo root)" || ! -x "$(command -v sudo 2>/dev/null || true)" ]]; then
      test "$_op" "$_path"
    else
      sudo -u "$_inv" test "$_op" "$_path"
    fi
  }

  for d in "$SCRIPT_DIR" "$SCRIPT_DIR/modules"; do
    [[ -d "$d" ]] || continue
    _dast_invoker_test_quiet "$invoker" -r "$d" 2>/dev/null || return 1
    _dast_invoker_test_quiet "$invoker" -x "$d" 2>/dev/null || return 1
  done
  _dast_invoker_test_quiet "$invoker" -r "$0" 2>/dev/null || return 1
  _dast_invoker_test_quiet "$invoker" -x "$0" 2>/dev/null || return 1
  return 0
}

# Run the check now (we are root by this point)
dast_perm_check

# ----------------------------------------------------------------------------
# OS label (for backtitle)
# ----------------------------------------------------------------------------
DAST_OS_ID="unknown"
DAST_OS_LABEL="Unknown"

detect_os_label() {
  local os_id os_like
  os_id=""
  os_like=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi

  os_id="${os_id,,}"
  os_like="${os_like,,}"

  if [[ "$os_id" == "ubuntu" || "$os_like" == *"ubuntu"* ]]; then
    DAST_OS_ID="ubuntu"
    DAST_OS_LABEL="Ubuntu"
    return 0
  fi

  if [[ "$os_id" == "debian" || "$os_like" == *"debian"* ]]; then
    DAST_OS_ID="debian"
    DAST_OS_LABEL="Debian"
    return 0
  fi

  DAST_OS_ID="unknown"
  DAST_OS_LABEL="Unknown"
}

detect_os_label

DAST_BACKTITLE="${APP_TITLE} [${DAST_OS_LABEL}]"

# -----------------------------------------------------------------------------
# Dialog theme
# Theme settings are stored in config/dast.conf (NOT in a persistent dialogrc file).
# At runtime, DaST generates a temporary dialogrc (usually under /run) and exports
# DIALOGRC for this process only.
# -----------------------------------------------------------------------------

CFG_DIR="${CFG_DIR:-${SCRIPT_DIR}/config}"
: "${CFG_FILE:=$CFG_DIR/dast.conf}"
mkdir -p "$CFG_DIR"

# Ensure config dir/file are usable by the invoking user (not root-owned by accident)
# Ownership target:
# - If running via sudo and DaST lives inside the invoking user's HOME -> user:group
# - Otherwise -> root:root
{
  _dast_cfg_inv="$(_dast_invoker_user)"
  if id "$_dast_cfg_inv" >/dev/null 2>&1; then
    _dast_cfg_grp="$(id -gn "$_dast_cfg_inv" 2>/dev/null || echo "$_dast_cfg_inv")"
    _dast_cfg_home="$(getent passwd "$_dast_cfg_inv" 2>/dev/null | awk -F: '{print $6}')"
  else
    _dast_cfg_inv="root"; _dast_cfg_grp="root"; _dast_cfg_home="/root"
  fi
  _dast_cfg_owner="root"; _dast_cfg_group="root"
  # Always prefer the original invoking user (SUDO_USER) for config ownership when present.
  # Reason: DaST is re-exec'd via sudo, but config should remain editable by the user who launched DaST.
  if [[ "$_dast_cfg_inv" != "root" ]]; then
    _dast_cfg_owner="$_dast_cfg_inv"; _dast_cfg_group="$_dast_cfg_grp"
  fi
  touch "$CFG_FILE" 2>/dev/null || true
  chmod 755 "$CFG_DIR" 2>/dev/null || true
  chmod 644 "$CFG_FILE" 2>/dev/null || true
  chown "$_dast_cfg_owner:$_dast_cfg_group" "$CFG_DIR" "$CFG_FILE" 2>/dev/null || true
  unset _dast_cfg_inv _dast_cfg_grp _dast_cfg_home _dast_cfg_owner _dast_cfg_group
}


# (dirs + logging are initialised early; do not redefine here)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
cleanup() { [[ -n "${DAST_TMP_DIALOGRC:-}" ]] && rm -f "$DAST_TMP_DIALOGRC" >/dev/null 2>&1 || true; clear || true; }

# -----------------------------------------------------------------------------
# Module dependency helpers (optional)
# Modules may define: module_deps_<ID>() { echo "cmd1 cmd2"; }
# Core will annotate the main menu with missing deps, but will not auto-install.
# -----------------------------------------------------------------------------
module_missing_deps() {
  local id="$1"
  local deps_fn="module_deps_${id}"
  local deps missing dep

  missing=""

  if ! declare -F "$deps_fn" >/dev/null 2>&1; then
    return 1
  fi

  # shellcheck disable=SC2034
  deps="$("$deps_fn" 2>/dev/null || true)"
  for dep in $deps; do
    if ! have "$dep"; then
      if [[ -n "$missing" ]]; then
        missing+=", "
      fi
      missing+="$dep"
    fi
  done

  if [[ -n "$missing" ]]; then
    printf '%s
' "$missing"
    return 0
  fi

  return 2
}


# -----------------------------------------------------------------------------
# UI prefs (emoji + compact) driven by config
# -----------------------------------------------------------------------------

# Defaults (will be overwritten by cfg_load once it exists and runs)
UI_EMOJI="${UI_EMOJI:-0}"
UI_COMPACT="${UI_COMPACT:-0}"

# Strip leading emoji and extra spaces from a string when UI_EMOJI=0
# This is intentionally conservative: it only strips from the start.
ui_strip_emoji_prefix() {
  local s="$1"

  # Safe + portable: most of our strings look like "🙂 Text".
  # Strip leading non-alnum run + spaces. Avoids GNU sed unicode escape issues.
  printf '%s\n' "$s" | awk '{ sub(/^[^[:alnum:]]+[[:space:]]+/, ""); print }'
}

# Curated DaST icon tokens to remove when emoji/icons are disabled.
# Deterministic and DaST-owned: edit manually as needed.
DAST_ICON_TOKENS=(
  '⏪' '⏱' '⏳' '⏹' '▶' '☢' '♻' '⚖' '⚙' '⚠' '⚡' '⚪' 
  '⛔' '✅' '✍' '✏' '✨' '❄' '❌' '❗' '❤' '➕' '➖' '⬅' 
  '⬆' '⬇' '🆕' '🌍' '🌐' '🌙' '🌡' '🎚' '🎛' '🎨' '🎯' '🏃' 
  '🏠' '🏷' '🐘' '🐞' '🐧' '🐳' '👀' '👁' '👑' '👤' '👥' '💣' 
  '💥' '💽' '💾' '📁' '📂' '📃' '📄' '📅' '📈' '📊' '📋' '📌' 
  '📏' '📚' '📜' '📝' '📡' '📣' '📤' '📥' '📦' '📰' '📶' '📸' 
  '🔀' '🔁' '🔃' '🔄' '🔌' '🔍' '🔎' '🔐' '🔑' '🔒' '🔗' '🔙' 
  '🔥' '🔧' '🔬' '🔴' '🔹' '🕐' '🕒' '🕓' '🕘' '🕰' '🕵' '🕸' 
  '🖥' '🖼' '🗂' '🗄' '🗑' '🗓' '🗜' '🙂' '🚀' '🚚' '🚨' '🚫' 
  '🛑' '🛠' '🛡' '🟠' '🟡' '🟢' '🥾' '🧊' '🧠' '🧨' '🧩' '🧪' 
  '🧬' '🧭' '🧯' '🧰' '🧱' '🧷' '🧹' '🧺' '🧼' '🧽' '🧾' '🩹' 
  '🩺'   '💻'

)

ui_strip_known_icons_anywhere() {
  local s="$1" ic

  # Strip VS16 universally (prevents tofu/double-diamond in some terminals)
  s="${s//$'\uFE0F'/}"

  for ic in "${DAST_ICON_TOKENS[@]}"; do
    [[ -n "$ic" ]] || continue
    s="${s//"$ic"/}"
  done

  printf '%s' "$s"
}


# Determine whether the current terminal environment is likely to be "hostile"
# to emoji / coloured glyphs (e.g., real Linux VT/TTY). This is used to apply a
# one-run override WITHOUT writing back to config.
ui_env_is_hostile_for_emoji() {
  # User/env override (one run only)
  [[ "${DAST_FORCE_EMOJI_OFF:-0}" -eq 1 ]] && return 0

  # Linux virtual console (common tofu/double-diamond offender)
  case "${TERM:-}" in
    linux|dumb) return 0 ;;
  esac

  return 1
}

# Apply one-run UI_EMOJI override if needed (does NOT persist to config)
ui_apply_runtime_emoji_policy() {
  UI_EMOJI_FORCED_OFF=0
  UI_EMOJI_FORCED_REASON=""

  # Hostile environments always override at runtime (never persisted).
  # This must apply even if UI_EMOJI is currently 0/1, because the env itself is authoritative for the run.
  if ui_env_is_hostile_for_emoji; then
    UI_EMOJI=0
    UI_EMOJI_FORCED_OFF=1
    UI_EMOJI_FORCED_REASON="HOSTILE_ENV"
    _dast__log_master "info [CORE] ui: emoji forced off at runtime (HOSTILE_ENV) (TERM=${TERM:-}, DAST_FORCE_EMOJI_OFF=${DAST_FORCE_EMOJI_OFF:-0})"
    return
  fi

  # Capability gate: if preference is ON but emoji font is missing, force off at runtime (never persisted).
  if [[ "${UI_EMOJI:-0}" -eq 1 ]] && [[ "${UI_EMOJI_CAPABLE:-0}" -ne 1 ]]; then
    UI_EMOJI=0
    UI_EMOJI_FORCED_OFF=1
    UI_EMOJI_FORCED_REASON="NO_EMOJI_FONT"
    _dast__log_master "info [CORE] ui: emoji forced off at runtime (NO_EMOJI_FONT)"
    return
  fi
}

# Read prefs from config (if available) without exploding early in startup.

  # One-run override for hostile TTY/VT environments (does not touch config)
ui_detect_emoji_capability() {
    UI_EMOJI_CAPABLE=0
    UI_EMOJI_CAP_REASON=""

    # Primary: known emoji font file (Noto Color Emoji)
    if [ -f /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf ]; then
        UI_EMOJI_CAPABLE=1
        return
    fi

    # Secondary: fontconfig, if available
    if command -v fc-match >/dev/null 2>&1; then
        if fc-match emoji >/dev/null 2>&1; then
            UI_EMOJI_CAPABLE=1
            return
        fi
    fi

    UI_EMOJI_CAP_REASON="NO_EMOJI_FONT"
}

ui_refresh_prefs() {
  # If cfg_load exists, use it to populate UI_* variables
  if declare -F cfg_load >/dev/null 2>&1; then
    cfg_load || true
  fi

  UI_EMOJI="${UI_EMOJI:-0}"
  UI_COMPACT="${UI_COMPACT:-0}"


  ui_detect_emoji_capability

  ui_apply_runtime_emoji_policy

  # Apply compact sizing presets (used by wrappers below)
  if [[ "${UI_COMPACT}" -eq 1 ]]; then
    UI_MSG_H=10;  UI_MSG_W=70
    UI_IN_H=10;   UI_IN_W=70
    UI_MENU_H=20; UI_MENU_W=70; UI_MENU_LIST=15
    UI_TBOX_H=21; UI_TBOX_W=85
  else
    UI_MSG_H=12;  UI_MSG_W=80
    UI_IN_H=12;   UI_IN_W=80
    UI_MENU_H=23; UI_MENU_W=80; UI_MENU_LIST=16
    UI_TBOX_H=22; UI_TBOX_W=90
  fi
}

# -----------------------------------------------------------------------------
# UI (dialog)
# -----------------------------------------------------------------------------
have_dialog() { command -v dialog >/dev/null 2>&1; }
dial() {
  # Wrapper around dialog that:
  # - binds stdin to /dev/tty so nested calls work reliably
  # - leaves stdout/stderr attached to the terminal so the UI always renders
  # - captures the *result* via --output-fd into a temp file
  # - preserves dialog's exit code
  local args=("$@")
  local tmp errtmp rc out
# Default label normalisation (prevents dialogrc/theme defaults like "Exit")
# Policy:
# - Menus/lists: Cancel -> Back
# - View-only boxes: OK -> Back
# - Msgbox: OK -> OK
# - Input/Edit: OK -> OK, Cancel -> Cancel
# - Yes/No: Yes -> Yes, No -> No
local _has_ok_label=0 _has_cancel_label=0 _has_yes_label=0 _has_no_label=0 _has_exit_label=0 _has_defaultno=0
local _is_menu=0 _is_viewbox=0 _is_msgbox=0 _is_input=0 _is_yesno=0
local i
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --ok-label|--ok-label=*) _has_ok_label=1 ;;
    --cancel-label|--cancel-label=*) _has_cancel_label=1 ;;
    --yes-label|--yes-label=*) _has_yes_label=1 ;;
    --no-label|--no-label=*) _has_no_label=1 ;;
    --exit-label|--exit-label=*) _has_exit_label=1 ;;
    --defaultno) _has_defaultno=1 ;;
    --menu|--radiolist|--checklist) _is_menu=1 ;;
    --textbox|--tailbox|--programbox|--progressbox|--prgbox) _is_viewbox=1 ;;
    --msgbox) _is_msgbox=1 ;;
    --inputbox|--passwordbox|--passwordform|--editbox|--form) _is_input=1 ;;
    --yesno) _is_yesno=1 ;;
  esac
done

if [[ $_is_menu -eq 1 && $_has_cancel_label -eq 0 ]]; then
  args=(--cancel-label "Back" "${args[@]}")
fi
if [[ $_is_viewbox -eq 1 && $_has_exit_label -eq 0 ]]; then
  args=(--exit-label "Back" "${args[@]}")
elif [[ $_is_msgbox -eq 1 && $_has_ok_label -eq 0 ]]; then
  args=(--ok-label "OK" "${args[@]}")
elif [[ $_is_input -eq 1 ]]; then
  [[ $_has_ok_label -eq 0 ]] && args=(--ok-label "OK" "${args[@]}")
  [[ $_has_cancel_label -eq 0 ]] && args=(--cancel-label "Cancel" "${args[@]}")
fi
if [[ $_is_yesno -eq 1 ]]; then
  [[ $_has_defaultno -eq 0 ]] && args=(--defaultno "${args[@]}")
  [[ $_has_yes_label -eq 0 ]] && args=(--yes-label "Yes" "${args[@]}")
  [[ $_has_no_label -eq 0 ]] && args=(--no-label "No" "${args[@]}")
fi


# Stable per-run capture files (avoid mktemp churn + leftover files).
tmp="${DAST_DLG_OUT:-${DAST_RUNTIME_DIR:-/tmp}/dast.dlg.out}"
errtmp="${DAST_DLG_ERR:-${DAST_RUNTIME_DIR:-/tmp}/dast.dlg.err}"
mkdir -p "${DAST_RUNTIME_DIR:-/tmp}" >/dev/null 2>&1 || true
: >"$tmp" 2>/dev/null || true
: >"$errtmp" 2>/dev/null || true
chmod 600 "$tmp" "$errtmp" 2>/dev/null || true
  # If running as root, ensure runtime capture files stay owned by the invoker
  if [[ "$(id -u 2>/dev/null || echo 0)" -eq 0 && -n "${DAST_INVOKER_USER:-}" && -n "${DAST_INVOKER_GROUP:-}" ]]; then
    chown "${DAST_INVOKER_USER}:${DAST_INVOKER_GROUP}" "$tmp" "$errtmp" 2>/dev/null || true
  fi

  # IMPORTANT: DaST runs with `set -e` globally. dialog returns non-zero on Cancel/Esc,
  # and without guarding, that can abort the entire script and leave the terminal
  # looking like it "hung" on a blank screen.
  #
  # We temporarily disable -e around dialog, and we bind *all* I/O to /dev/tty so
  # dialog always has a real terminal to talk to.
  set +e
  dialog --backtitle "$DAST_BACKTITLE" --output-fd 3 "${args[@]}" \
    3>"$tmp" </dev/tty >/dev/tty 2>"$errtmp"
  rc=$?
  set -e

  out="$(cat "$tmp" 2>/dev/null || true)"
  # Do not delete $tmp. Reuse it to avoid runtime churn.
  if [[ "$rc" -eq 255 ]]; then
    # rc=255 can mean either:
    #   - User pressed ESC (normal cancel): stderr is empty
    #   - dialog couldn't run (TTY/TERM/locale/etc.): stderr has diagnostics
    local _derr
    _derr="$(cat "$errtmp" 2>/dev/null || true)"
    if [[ -n "$_derr" ]]; then
      _dast_log_early "ERROR" "dialog failed (rc=255) TERM=${TERM:-} LANG=${LANG:-} LC_ALL=${LC_ALL:-} err=${_derr}"
      printf "\nDaST: dialog failed (rc=255). TERM=%s LANG=%s\n%s...\n" \
        "${TERM:-}" "${LANG:-}" "${_derr}" >/dev/tty 2>/dev/null || true
    fi
  fi

  : # keep $errtmp for reuse

  case "$rc" in
    0)   printf '%s' "$out"; return 0 ;;
    1)   return 1 ;;
    255) return 255 ;;
    *)   return "$rc" ;;
  esac
}

ui_msg() {
  ui_refresh_prefs
  local title="$1" msg="$2"

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_emoji_prefix "$title")"
    msg="$(ui_strip_emoji_prefix "$msg")"
  fi

  dial --title "$title" --ok-label "OK" --msgbox "$msg" "$UI_MSG_H" "$UI_MSG_W" >/dev/null || true
}

ui_msg_sized() {
  ui_refresh_prefs
  local title="$1" msg="$2" h="${3:-$UI_MSG_H}" w="${4:-$UI_MSG_W}"
  local max_h max_w

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_emoji_prefix "$title")"
    msg="$(ui_strip_emoji_prefix "$msg")"
  fi

  # Clamp to terminal size to avoid dialog errors on smaller TTYs.
  max_h="$(tput lines 2>/dev/null || echo 0)"
  max_w="$(tput cols  2>/dev/null || echo 0)"
  if [[ "$max_h" =~ ^[0-9]+$ ]] && [[ "$max_h" -gt 0 ]]; then
    (( h > max_h - 4 )) && h=$((max_h - 4))
  fi
  if [[ "$max_w" =~ ^[0-9]+$ ]] && [[ "$max_w" -gt 0 ]]; then
    (( w > max_w - 4 )) && w=$((max_w - 4))
  fi

  # Final sanity: dialog requires positive dims.
  (( h < 6 )) && h=6
  (( w < 20 )) && w=20

  dial --title "$title" --ok-label "OK" --msgbox "$msg" "$h" "$w" >/dev/null || true
}

ui_yesno() {
  ui_refresh_prefs
  local title="$1" msg="$2"
  local _compat_unused="${3:-}"

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_emoji_prefix "$title")"
    msg="$(ui_strip_emoji_prefix "$msg")"
  fi

  # Safety policy: ALWAYS default to NO to prevent accidental destructive actions.
  dial --title "$title" --defaultno --yesno "$msg" "$UI_MSG_H" "$UI_MSG_W" >/dev/null
}


ui_input() {
  ui_refresh_prefs
  local title="$1" msg="$2" init="${3:-}"

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_emoji_prefix "$title")"
    msg="$(ui_strip_emoji_prefix "$msg")"
  fi

  dial --title "$title" --inputbox "$msg" "$UI_IN_H" "$UI_IN_W" "$init"
}

# Compatibility alias: some modules use ui_inputbox(), older core uses ui_input().
ui_inputbox() {
  ui_input "$@"
}


ui_menu() {
  ui_refresh_prefs
  local title="$1" prompt="$2"
  shift 2
  local -a items=("$@")

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_known_icons_anywhere "$title")"
    prompt="$(ui_strip_known_icons_anywhere "$prompt")"

    local i
    for (( i=1; i<${#items[@]}; i+=2 )); do
      items[$i]="$(ui_strip_known_icons_anywhere "${items[$i]}")"
    done
  fi

  dial --title "$title" --menu "$prompt" "$UI_MENU_H" "$UI_MENU_W" "$UI_MENU_LIST" "${items[@]}"
}

ui_main_menu() {
  ui_refresh_prefs
  local title="$1" prompt="$2"
  shift 2
  local -a items=("$@")

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_known_icons_anywhere "$title")"
    prompt="$(ui_strip_known_icons_anywhere "$prompt")"

    local i
    for (( i=1; i<${#items[@]}; i+=2 )); do
      items[$i]="$(ui_strip_known_icons_anywhere "${items[$i]}")"
    done
  fi

  dial --title "$title" --ok-label "Select" --cancel-label "Exit" --menu "$prompt" "$UI_MENU_H" "$UI_MENU_W" "$UI_MENU_LIST" "${items[@]}"
}

ui_textbox() {
  ui_refresh_prefs
  local title="$1" file="$2"
  local ok_label="${3:-Back}"

  if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
    title="$(ui_strip_emoji_prefix "$title")"
  fi

  dial --title "$title" --exit-label "Back" --textbox "$file" "$UI_TBOX_H" "$UI_TBOX_W" >/dev/null || true
}

ui_programbox() {
  ui_refresh_prefs
  local title="$1" cmd="$2"
  local tmp; tmp="$(mktemp -p "${TMPDIR:-/tmp}" dast.tmp.XXXXXX 2>/dev/null || mktemp -t dast.tmp.XXXXXX 2>/dev/null)"
  bash -c "$cmd" >"$tmp" 2>&1 || true
  ui_textbox "$title" "$tmp"
  rm -f "$tmp" || true
}


# -----------------------------------------------------------------------------
# Run helper (used by modules)
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# Config defaults (first run)
# -----------------------------------------------------------------------------
cfg_ensure_defaults() {
  # Ensure config dir exists
  mkdir -p "$CFG_DIR" 2>/dev/null || true

  # If config is missing or empty, write defaults
  if [[ ! -s "$CFG_FILE" ]]; then
    {
      echo "# DaST config"
      echo "# Auto-created on first run"
      echo "SHOW_STARTUP_WARNING=1"
    } >"$CFG_FILE" 2>/dev/null || true
  fi
}

dast_maybe_show_startup_warning() {
  # Default ON if missing
  [[ "${SHOW_STARTUP_WARNING:-1}" -eq 1 ]] || return 0

  # Prevent double display if something re-enters main in the same process
  [[ -n "${DAST_STARTUP_WARNING_SHOWN:-}" ]] && return 0
  export DAST_STARTUP_WARNING_SHOWN=1

  local msg
  msg=$'WARNING(!) DaST IS CURRENTLY IN ITS INFANCY AND SHOULD BE CONSIDERED ALPHA SOFTWARE! DaST MAY CONTAIN BUGS LEADING TO SYSTEM BREAKAGE AND DATA DESTRUCTION. YOU SHOULD REVIEW THE CODE YOURSELF BEFORE RUNNING IT. DaST COMES WITH ABSOLUTELY NO WARRANTY, EXPRESS OR IMPLIED, AND THE AUTHORS OR COPYRIGHT HOLDERS SHALL NOT BE LIABLE FOR ANY LOSS OR DAMAGES RESULTING FROM USING THESE SCRIPTS. YOU USE AT YOUR OWN RISK. THESE SCRIPTS ARE PROVIDED "AS IS" AND IN "GOOD FAITH" WITH THE INTENTION OF IMPROVING UBUNTU/DEBIAN FOR EVERYONE.\n\nDisable this warning in:\nDaST Toolbox -> DaST settings -> Appearance / UI -> Startup safety warning popup.'
  ui_msg_sized "DaST Safety Warning & Disclaimer" "$msg" 16 80
}

# -----------------------------------------------------------------------------
# Config helpers (available to modules)
# -----------------------------------------------------------------------------
cfg_load() {
  [[ -f "$CFG_FILE" ]] || return 0

  # Security: DaST runs as root. Do not 'source' arbitrary shell from a writable location.
  # We only accept simple KEY=VALUE assignments (no command substitutions, pipes, redirects, etc).
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # allow only KEY=VALUE
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"

      # reject anything that looks like shell execution or expansion
      if [[ "$val" == *'$('* || "$val" == *'`'* || "$val" == *'|'* || "$val" == *'&'* || "$val" == *';'* || "$val" == *'<'* || "$val" == *'>'* ]]; then
        echo "DaST: ignoring unsafe config line in $CFG_FILE: $key=<unsafe>" >&2
        continue
      fi

      # Reject quotes/spaces for most keys. For DIALOG_* tuples, allow them (legacy configs) and normalise.
      if [[ "$key" == DIALOG_* ]]; then
        # Strip surrounding quotes if present
        if [[ "$val" =~ ^\".*\"$ ]]; then val="${val#\"}"; val="${val%\"}"; fi
        if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val#\'}"; val="${val%\'}"; fi
        # Remove any spaces (dialog tuples should be stored as (WHITE,MAGENTA,ON))
        val="${val//[[:space:]]/}"
      else
        if [[ "$val" =~ [[:space:]] || "$val" == *"'"* || "$val" == *'"'* ]]; then
          echo "DaST: ignoring unsupported config line in $CFG_FILE (use simple values only): $key=<unsupported>" >&2
          continue
        fi
      fi

      printf -v "$key" '%s' "$val"
      export "$key"
    else
      echo "DaST: ignoring unrecognised config line in $CFG_FILE" >&2
    fi
  done < "$CFG_FILE"
}


# -----------------------------------------------------------------------------
# Emoji preference persistence (first run)
# -----------------------------------------------------------------------------

cfg_has_key() {
  local key="$1"
  [[ -z "$key" ]] && return 1
  [[ -f "$CFG_FILE" ]] || return 1
  grep -qE "^${key}=" "$CFG_FILE" 2>/dev/null
}

dast_emoji_first_run_maybe_persist_pref() {
  # First run means: UI_EMOJI is not present in config at all.
  cfg_has_key "UI_EMOJI" && return 0

  # If the environment is hostile, do not write a preference.
  if ui_env_is_hostile_for_emoji; then
    UI_EMOJI="${UI_EMOJI:-0}"
    return 0
  fi

  # Friendly environment: detect capability and persist an initial preference once.
  ui_detect_emoji_capability

  if [[ "${UI_EMOJI_CAPABLE:-0}" -eq 1 ]]; then
    cfg_set_kv "UI_EMOJI" 1
    UI_EMOJI=1
  else
    cfg_set_kv "UI_EMOJI" 0
    UI_EMOJI=0
  fi

  return 0
}

cfg_set_kv() {
  local key="$1" val="$2"
  [[ -z "$key" ]] && return 1

  mkdir -p "$CFG_DIR" 2>/dev/null || true

  # Decide ownership BEFORE rewriting (mv replaces inode, so ownership would become root when running under sudo).
  local inv_user inv_uid="0" inv_gid="0"
  inv_user="$(_dast_invoker_user 2>/dev/null || echo root)"
  if [[ -n "$inv_user" && "$inv_user" != "root" ]] && id -u "$inv_user" >/dev/null 2>&1; then
    inv_uid="$(id -u "$inv_user" 2>/dev/null || echo 0)"
    inv_gid="$(id -g "$inv_user" 2>/dev/null || echo 0)"
  fi

  local target_uid="0" target_gid="0"
  if [[ -f "$CFG_FILE" ]]; then
    local cur_uid cur_gid
    cur_uid="$(stat -c '%u' "$CFG_FILE" 2>/dev/null || echo 0)"
    cur_gid="$(stat -c '%g' "$CFG_FILE" 2>/dev/null || echo 0)"
    # Preserve non-root ownership if it already exists; otherwise fall back to invoker.
    if [[ "$cur_uid" != "0" && "$cur_gid" != "0" ]]; then
      target_uid="$cur_uid"; target_gid="$cur_gid"
    elif [[ "$inv_uid" != "0" && "$inv_gid" != "0" ]]; then
      target_uid="$inv_uid"; target_gid="$inv_gid"
    fi
  else
    # File does not exist yet: make it invoker-owned where possible.
    if [[ "$inv_uid" != "0" && "$inv_gid" != "0" ]]; then
      target_uid="$inv_uid"; target_gid="$inv_gid"
    fi
  fi

  _dast__cfg_dbg() {
    [[ "${DAST_DEBUG:-0}" -eq 1 ]] || return 0
    if declare -F _dast_dbg >/dev/null 2>&1; then
      _dast_dbg "CFG: $*"
    else
      _dast_log_early "DBG" "CFG: $*"
    fi
  }

  _dast__cfg_dbg "cfg_set_kv key=${key} invoker=${inv_user} target_uidgid=${target_uid}:${target_gid}"

  local tmp
  tmp="$(mktemp "${CFG_DIR}/.dast.conf.tmp.XXXXXX" 2>/dev/null || mktemp 2>/dev/null || echo "")"
  [[ -z "$tmp" ]] && return 1

  if [[ -f "$CFG_FILE" ]]; then
    grep -vE "^${key}=" "$CFG_FILE" >"$tmp" 2>/dev/null || true
  fi
  if [[ "$key" == UI_COLOUR || "$key" == DIALOG_* ]]; then
    printf '%s=%s
' "$key" "$val" >>"$tmp" 2>/dev/null || true
  else
    printf '%s=%q
' "$key" "$val" >>"$tmp" 2>/dev/null || true
  fi

  if ! mv -f "$tmp" "$CFG_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    _dast__cfg_dbg "cfg_set_kv FAILED to move tmp into place ($CFG_FILE)"
    return 1
  fi

  chmod 755 "$CFG_DIR" 2>/dev/null || true
  chmod 644 "$CFG_FILE" 2>/dev/null || true

  # Only chown if we have a non-root target; otherwise leave as-is.
  if [[ "${target_uid}" != "0" && "${target_gid}" != "0" ]]; then
    chown "${target_uid}:${target_gid}" "$CFG_DIR" "$CFG_FILE" 2>/dev/null || true
  fi

  if [[ "${DAST_DEBUG:-0}" -eq 1 ]]; then
    _dast__cfg_dbg "cfg_set_kv wrote owner=$(stat -c '%u:%g' "$CFG_FILE" 2>/dev/null || echo '?') mode=$(stat -c '%a' "$CFG_FILE" 2>/dev/null || echo '?')"
  fi

  unset -f _dast__cfg_dbg 2>/dev/null || true

  # Update live environment for the current run.
  printf -v "$key" '%s' "$val"
  export "$key"

  # If UI/theme keys changed, re-apply dialog theme immediately so changes show without manual refresh.
  if [[ "$key" == UI_COLOUR || "$key" == DIALOG_* ]]; then
    if declare -F dast_apply_dialog_theme >/dev/null 2>&1; then
      dast_apply_dialog_theme >/dev/null 2>&1 || true
    fi
  fi
}



# -----------------------------------------------------------------------------
# Dialog theme (runtime)
# -----------------------------------------------------------------------------
DAST_TMP_DIALOGRC=""

_dast_fmt_colour_tuple() {
  # Convert "(WHITE,MAGENTA,ON)" or "\(WHITE\,MAGENTA\,ON\)" -> "(WHITE, MAGENTA, ON)"
  local s="${1:-}"

  # Unescape common config encodings (we allow config to store \(WHITE\,MAGENTA\,ON\) safely)
  s="${s//\\(/(}"
  s="${s//\\)/)}"
  s="${s//\\,/,}"

  # Normalise spacing after commas for dialogrc readability
  s="${s//,/,\ }"

  printf '%s' "$s"
}

dast_apply_dialog_theme() {
  # Read UI/theme values from config vars (set by cfg_load).
  # We generate a temp dialogrc at runtime. Note: dialogrc keywords MUST use dialog's spellings (color/colors).
  local use_colours="1"

  local screen_colour="(WHITE,MAGENTA,ON)"
  local item_sel_colour="(WHITE,MAGENTA,ON)"
  local tag_sel_colour="(WHITE,MAGENTA,ON)"
  local btn_active_colour="(WHITE,MAGENTA,ON)"
  local btn_key_active_colour="(YELLOW,MAGENTA,ON)"
  local btn_label_active_colour="(WHITE,MAGENTA,ON)"

  # Reuse a single runtime dialogrc per run.
  if [[ -n "${DAST_TMP_DIALOGRC:-}" && -f "${DAST_TMP_DIALOGRC:-}" ]]; then
    export DIALOGRC="$DAST_TMP_DIALOGRC"
    return 0
  fi


  # Ensure runtime dir exists (inside app dir, for debuggability)
  mkdir -p "$DAST_RUNTIME_DIR" >/dev/null 2>&1 || true
  chmod 700 "$DAST_RUNTIME_DIR" >/dev/null 2>&1 || true
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown "${DAST_INVOKER_USER}:${DAST_INVOKER_GROUP}" "$DAST_RUNTIME_DIR" >/dev/null 2>&1 || true
  fi

DAST_TMP_DIALOGRC="${DAST_TMP_DIALOGRC:-$DAST_RUNTIME_DIR/dialogrc}"
: >"$DAST_TMP_DIALOGRC" 2>/dev/null || true
chmod 600 "$DAST_TMP_DIALOGRC" >/dev/null 2>&1 || true
if [[ "${EUID:-$(id -u)}" -eq 0 && "${DAST_INVOKER_UID:-0}" -ne 0 ]]; then
  chown "${DAST_INVOKER_USER:-${SUDO_USER:-root}}:${DAST_INVOKER_GROUP:-root}" "$DAST_TMP_DIALOGRC" >/dev/null 2>&1 || true
fi

  if [[ "${use_colours}" -eq 1 ]]; then
    cat >"$DAST_TMP_DIALOGRC" <<EOF
use_colors = ON
screen_color = $(_dast_fmt_colour_tuple "$screen_colour")
item_selected_color = $(_dast_fmt_colour_tuple "$item_sel_colour")
tag_selected_color  = $(_dast_fmt_colour_tuple "$tag_sel_colour")
button_active_color = $(_dast_fmt_colour_tuple "$btn_active_colour")
button_key_active_color = $(_dast_fmt_colour_tuple "$btn_key_active_colour")
button_label_active_color = $(_dast_fmt_colour_tuple "$btn_label_active_colour")
EOF
  else
    cat >"$DAST_TMP_DIALOGRC" <<EOF
use_colors = OFF
EOF
  fi

  export DIALOGRC="$DAST_TMP_DIALOGRC"
  return 0
}



# -----------------------------------------------------------------------------
# Module discovery + registry (registration style only)
# -----------------------------------------------------------------------------
MODULE_DIR="$SCRIPT_DIR/modules"
MODULE_SEARCH_DIR="$MODULE_DIR"

declare -a MODULE_IDS=()
declare -A MODULE_TITLES=()
declare -A MODULE_FUNCS=()
declare -A MODULE_SEEN=()

# ------------------------------------------------------------
# Module load tracking (per module file + module id mapping)
# ------------------------------------------------------------
declare -A MODULE_FILE_STATUS=()   # LOADED | FAILED | SKIPPED | INVALID
declare -A MODULE_FILE_REASON=()
declare -A MODULE_FILE_PATH=()

declare -A MODULE_SRCFILE=()       # module_id -> module file path

CURRENT_LOADING_FILE=""
DAST_SKIP_REASON=""

_dast_module_order_from_file() {
  # Extract numeric prefix (e.g., 010 from 010_system.sh). Returns empty if none.
  local f="${1:-}"
  local b n
  b="$(basename -- "$f" 2>/dev/null || echo "")"
  n="${b%%_*}"
  [[ "$n" =~ ^[0-9]+$ ]] || { printf '%s' ""; return 0; }
  # strip leading zeros for readability but keep 0 as 0
  n="$(printf "%s" "$n" | sed -E 's/^0+//')"
  [[ -n "$n" ]] || n="0"
  printf '%s' "$n"
}

register_module() {
  local id="$1" title="$2" func="$3"
  [[ -n "${id:-}" && -n "${title:-}" && -n "${func:-}" ]] || return 0

  if [[ -z "${MODULE_SEEN[$id]:-}" ]]; then
    MODULE_IDS+=("$id")
    MODULE_SEEN["$id"]=1
  fi

  MODULE_TITLES["$id"]="$title"

  # Record the function name; verify at runtime too
  MODULE_FUNCS["$id"]="$func"

  # Track which module file registered this id
  if [[ -n "${CURRENT_LOADING_FILE:-}" ]]; then
    MODULE_SRCFILE["$id"]="$CURRENT_LOADING_FILE"
  fi
# Deterministic registration logging (does not rely on modules logging themselves)
local _src="${CURRENT_LOADING_FILE:-}"
local _ord
_ord="$(_dast_module_order_from_file "$_src")"
if [[ -n "$_ord" ]]; then
  dast_log INFO "MODULE" "register: order=${_ord} id=${id} title=${title} func=${func} src=$(basename -- "$_src" 2>/dev/null || echo "$_src")"
else
  dast_log INFO "MODULE" "register: id=${id} title=${title} func=${func} src=$(basename -- "$_src" 2>/dev/null || echo "$_src")"
fi
}

# Set a human readable skip reason during module load
# Modules may call: dast_skip "reason" and then return 0
dast_skip() {
  DAST_SKIP_REASON="$1"
  return 0
}


list_modules() {
  shopt -s nullglob
  local f base stem
  local -a sh_files=() txt_files=()

  # Prefer real module files (.sh). Also accept .txt so people can temporarily
  # rename modules for external tooling without breaking DaST.
  declare -A seen=()

  # Collect 2-digit and 3-digit module files, then version-sort for sane ordering
  for f in "$MODULE_SEARCH_DIR"/[0-9][0-9]_*.sh "$MODULE_SEARCH_DIR"/[0-9][0-9][0-9]_*.sh; do
    [[ -f "$f" ]] || continue
    sh_files+=("$f")
  done

  if ((${#sh_files[@]})); then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      stem="${base%.sh}"
      [[ -n "${seen[$stem]:-}" ]] && continue
      seen["$stem"]=1
      echo "$f"
    done < <(printf '%s
' "${sh_files[@]}" | sort -V)
  fi

  for f in "$MODULE_SEARCH_DIR"/[0-9][0-9]_*.txt "$MODULE_SEARCH_DIR"/[0-9][0-9][0-9]_*.txt; do
    [[ -f "$f" ]] || continue
    txt_files+=("$f")
  done

  if ((${#txt_files[@]})); then
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      stem="${base%.txt}"
      [[ -n "${seen[$stem]:-}" ]] && continue
      echo "$f"
    done < <(printf '%s
' "${txt_files[@]}" | sort -V)
  fi

  shopt -u nullglob
}

load_modules() {
  local f rc tmp_err
  local -a before_ids=() after_ids=() new_ids=()

  # Reuse a single stderr capture file to avoid mktemp churn in runtime
  tmp_err="${DAST_RUNTIME_DIR:-/tmp}/dast.module_load.err"
  : >"$tmp_err" 2>/dev/null || true
  if [[ "$(id -u 2>/dev/null || echo 0)" -eq 0 && -n "${DAST_INVOKER_USER:-}" && -n "${DAST_INVOKER_GROUP:-}" ]]; then
    chown "${DAST_INVOKER_USER}:${DAST_INVOKER_GROUP}" "$tmp_err" 2>/dev/null || true
  fi

  while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    CURRENT_LOADING_FILE="$f"
    DAST_SKIP_REASON=""

    dast_log INFO "MODULE" "load: sourcing $(basename -- "$f" 2>/dev/null || echo "$f")"


    before_ids=("${MODULE_IDS[@]}")
    : >"$tmp_err" 2>/dev/null || true
    # Source defensively in the *current shell* so module registration persists.
    # We still want to survive:
    # - non-zero returns while DaST is running with `set -e`
    # - unset var usage while DaST is running with `set -u`
    # - accidental `exit` calls inside module files
    local __old_opts
    __old_opts="$(set +o)"

    set +e
    set +u

    # If a module calls `exit`, don't let it terminate DaST
    exit() { return "${1:-0}"; }

    source "$f" 2>"$tmp_err"
    rc=$?

    unset -f exit 2>/dev/null || true
    eval "$__old_opts"

    after_ids=("${MODULE_IDS[@]}")

    # Determine which module_ids (if any) were registered by this file
    new_ids=()
    if (( ${#after_ids[@]} > ${#before_ids[@]} )); then
      local id found
      for id in "${after_ids[@]}"; do
        found=0
        for bid in "${before_ids[@]}"; do
          [[ "$bid" == "$id" ]] && { found=1; break; }
        done
        [[ $found -eq 0 ]] && new_ids+=("$id")
      done
    fi

    MODULE_FILE_PATH["$f"]="$f"

    if (( rc != 0 )); then
      MODULE_FILE_STATUS["$f"]="FAILED"
      MODULE_FILE_REASON["$f"]="source failed (rc=$rc): $(head -n 1 "$tmp_err")"
      continue
    fi

    if [[ -n "${DAST_SKIP_REASON:-}" ]]; then
      MODULE_FILE_STATUS["$f"]="SKIPPED"
      MODULE_FILE_REASON["$f"]="$DAST_SKIP_REASON"
      continue
    fi

    if (( ${#new_ids[@]} == 0 )); then
      MODULE_FILE_STATUS["$f"]="SKIPPED"
      MODULE_FILE_REASON["$f"]="module did not register"
      continue
    fi

    # Validate that registered functions exist
    local bad=0 func
    for id in "${new_ids[@]}"; do
      func="${MODULE_FUNCS[$id]:-}"
      if [[ -z "$func" || ! "$(declare -F "$func" 2>/dev/null)" ]]; then
        bad=1
      fi
    done

    if (( bad == 1 )); then
      MODULE_FILE_STATUS["$f"]="INVALID"
      MODULE_FILE_REASON["$f"]="registered but missing entry function"
    else
      MODULE_FILE_STATUS["$f"]="LOADED"
      MODULE_FILE_REASON["$f"]="ok"
    fi

  done < <(list_modules)

  CURRENT_LOADING_FILE=""
}


build_main_menu_items() {
  local -a items=()
  local id fn missing

  for id in "${MODULE_IDS[@]}"; do
    fn="${MODULE_FUNCS[$id]:-}"

    if [[ -z "$fn" ]] || ! declare -F "$fn" >/dev/null 2>&1; then
      items+=("$id" "${MODULE_TITLES[$id]}  (not runnable)")
      continue
    fi

    # Optional dependency annotation
    missing=""
    if missing="$(module_missing_deps "$id" 2>/dev/null)"; then
      items+=("$id" "${MODULE_TITLES[$id]}  (missing: $missing)")
    else
      items+=("$id" "${MODULE_TITLES[$id]}")
    fi
  done

  printf '%s\0' "${items[@]}"
}


run_module() {
  local id="$1"
  local fn="${MODULE_FUNCS[$id]:-}"

  if [[ -z "$fn" ]]; then
    ui_msg "Module error" "Module '$id' did not register a function."
    return 0
  fi

  if ! declare -F "$fn" >/dev/null 2>&1; then
    ui_msg "Module error" "Registered function missing for '$id': $fn"
    return 0
  fi

  "$fn"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {

  cfg_ensure_defaults
  cfg_load
  dast_emoji_first_run_maybe_persist_pref
  dast_apply_dialog_theme
  dast_maybe_show_startup_warning
  load_modules

  if [[ "${#MODULE_IDS[@]}" -eq 0 ]]; then
    ui_msg "DaST" "No modules registered.
Scanning: $MODULE_SEARCH_DIR
Expected: modules to call register_module \"ID\" \"Title\" \"function\""
    cleanup
    exit 1
  fi

  while true; do
    local -a items=()
    while IFS= read -r -d '' it; do items+=("$it"); done < <(build_main_menu_items)

    local sel
    sel="$(ui_main_menu "Main Menu" "Choose a module:" "${items[@]}")" || { cleanup; exit 0; }

    run_module "$sel"
  done
}

main "$@"
