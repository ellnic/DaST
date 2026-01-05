#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: DaST Toolbox (v0.9.8.4)
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

module_id="DASTTOOL"
module_title="🧰 DaST Toolbox"
DAST_TOOLBOX_TITLE="🧰 DaST Toolbox"
SETTINGS_TITLE="🧰 DaST settings"



# -----------------------------------------------------------------------------
# Logging helpers (standard always, debug only when --debug)
# -----------------------------------------------------------------------------
if ! declare -F dast_log >/dev/null 2>&1; then
  dast_log() { :; }
fi
if ! declare -F dast_dbg >/dev/null 2>&1; then
  dast_dbg() { :; }
fi
# --- DaST app dirs (logs/debug/config) ----------------------------------------
# These are normally provided by the main DaST launcher. If this module is run
# standalone, derive them from the module location (../).
if [[ -z "${DAST_APP_DIR:-}" ]]; then
  DAST_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P || pwd -P)"
fi

# Use the safe :- syntax to prevent "unbound variable" crashes under set -u
: "${LOG_DIR:="${DAST_APP_DIR:-}/logs"}"
# DEBUG_DIR is provided by the main launcher. When debug is off it should be "/dev/null".
# Do not force a fallback that would create ./debug implicitly.
: "${DEBUG_DIR:="${DEBUG_DIR:-}"}"
: "${CFG_DIR:="${DAST_APP_DIR:-}/config"}"

_dast_toolbox__current_run_dir() {
  # Prefer the current run id from the main launcher. Fallback to newest run_* directory.
  local base="${LOG_DIR:-}" rid d
  [[ -n "${base:-}" ]] || { echo ""; return 0; }

  rid="${DAST_RUN_ID:-}"
  if [[ -n "${rid:-}" && -d "${base}/run_${rid}" ]]; then
    echo "${base}/run_${rid}"
    return 0
  fi

  d="$(ls -1dt "${base}"/run_* 2>/dev/null | head -n 1 || true)"
  [[ -n "${d:-}" && -d "${d}" ]] && echo "${d}" || echo ""
}

: "${CFG_FILE:="${CFG_DIR:-}/dast.conf"}"
: "${RUN_LOG_DIR:="$(_dast_toolbox__current_run_dir)"}"
# For viewing/export convenience only (toolbox must not write to this file)
: "${LOG_FILE:="${RUN_LOG_DIR:-}/dast.log"}"
: "${ALL_LOG_FILE:="${RUN_LOG_DIR:-}/all.log"}"

# ----------------------------------------------------------------------------
# Invoker identity (real user who launched DaST, even though we run as root)
# ----------------------------------------------------------------------------
if ! declare -F _dast_invoker_user >/dev/null 2>&1; then
  _dast_invoker_user() {
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
    printf '%s' "root"
  }
fi


# Compatibility aliases (older names used in some modules)
: "${CONFIG_DIR:="${CFG_DIR:-}"}"
: "${CONFIG_FILE:="${CFG_FILE:-}"}"

# --- Config consolidation & ownership repair -----------------------------------
# DaST historically used config/dast.cfg. Canonical is now config/dast.conf.
# We also ensure the config stays owned by the invoking (non-root) user so settings persist.
__dast_toolbox_real_user() {
  # Prefer persisted invoker (set before sudo re-exec) if present.
_ctx_user="${DAST_INVOKER_USER:-}"
  if [[ -n "$_ctx_user" && "$_ctx_user" != "root" ]]; then
    echo "$_ctx_user"
    return 0
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return 0
  fi

  # best-effort: logname can fail in non-TTY contexts
  local ln
  ln="$(logname 2>/dev/null || true)"
  if [[ -n "$ln" && "$ln" != "root" ]]; then
    echo "$ln"
    return 0
  fi

  # If we're root but DaST is installed in a user-owned path, infer owner from the tree.
  local owner
  owner="$(stat -c '%U' "${SCRIPT_DIR:-${CFG_DIR:-.}}" 2>/dev/null || true)"
  if [[ -n "$owner" && "$owner" != "root" ]] && id -u "$owner" >/dev/null 2>&1; then
    echo "$owner"
    return 0
  fi

# Fallback: if DaST lives in a user-owned tree but sudo context is missing,
# infer the intended owner from the config dir (or app dir).
local _owner
if [[ -n "${CFG_DIR:-}" ]]; then
  _owner="$(stat -c '%U' "${CFG_DIR}" 2>/dev/null || true)"
  if [[ -n "$_owner" && "$_owner" != "root" ]]; then
    echo "$_owner"
    return 0
  fi
fi
if [[ -n "${DAST_APP_DIR:-}" ]]; then
  _owner="$(stat -c '%U' "${DAST_APP_DIR}" 2>/dev/null || true)"
  if [[ -n "$_owner" && "$_owner" != "root" ]]; then
    echo "$_owner"
    return 0
  fi
fi

  echo "root"
}

__dast_toolbox_cfg_consolidate() {
  local cfg_dir="${CFG_DIR:-}"
  local conf="${CFG_FILE:-}"
  local legacy_cfg="${cfg_dir}/dast.cfg"
  local real_user real_group
  real_user="$(__dast_toolbox_real_user)"
  real_group="$(id -gn "$real_user" 2>/dev/null || echo "$real_user")"
# If we couldn't detect a non-root invoker (e.g. sudo context stripped),
# fall back to the owner of the config dir/app dir so we never leave config root-owned.
if [[ "$real_user" == "root" ]]; then
  local _owner
  _owner="$(stat -c '%U' "$cfg_dir" 2>/dev/null || true)"
  if [[ -n "$_owner" && "$_owner" != "root" ]]; then
    real_user="$_owner"
    real_group="$(id -gn "$real_user" 2>/dev/null || echo "$real_user")"
  else
    _owner="$(stat -c '%U' "${DAST_APP_DIR:-.}" 2>/dev/null || true)"
    if [[ -n "$_owner" && "$_owner" != "root" ]]; then
      real_user="$_owner"
      real_group="$(id -gn "$real_user" 2>/dev/null || echo "$real_user")"
    fi
  fi
fi


  # If legacy exists and canonical missing, migrate by rename.
  if [[ -f "$legacy_cfg" && ! -f "$conf" ]]; then
    mkdir -p "$cfg_dir" 2>/dev/null || true
    mv -f "$legacy_cfg" "$conf" 2>/dev/null || true
  fi

  # If both exist, prefer canonical, but if legacy is newer, merge UI keys across.
  if [[ -f "$legacy_cfg" && -f "$conf" ]]; then
    if [[ "$legacy_cfg" -nt "$conf" ]]; then
      # Merge only UI-related keys from legacy into canonical, preserving other settings.
      local tmp; tmp="$(mktemp)"
      awk -F= '
        BEGIN{want["UI_COLOUR"]=1;want["UI_COMPACT"]=1;want["SHOW_STARTUP_WARNING"]=1;want["EXPORT_LINES"]=1;want["UI_EMOJI"]=1;
              want["DIALOG_SCREEN_COLOUR"]=1;want["DIALOG_ITEM_SELECTED_COLOUR"]=1;want["DIALOG_TAG_SELECTED_COLOUR"]=1;
              want["DIALOG_BUTTON_ACTIVE_COLOUR"]=1;want["DIALOG_BUTTON_KEY_ACTIVE_COLOUR"]=1;want["DIALOG_BUTTON_LABEL_ACTIVE_COLOUR"]=1;}
        NF>=2 && $1 in want {print $1"="$2}
      ' "$legacy_cfg" >"$tmp" 2>/dev/null || true

      # Remove those keys from canonical, then append merged values (last-wins).
      awk -F= '
        BEGIN{skip["UI_COLOUR"]=1;skip["UI_COMPACT"]=1;skip["SHOW_STARTUP_WARNING"]=1;skip["EXPORT_LINES"]=1;skip["UI_EMOJI"]=1;
              skip["DIALOG_SCREEN_COLOUR"]=1;skip["DIALOG_ITEM_SELECTED_COLOUR"]=1;skip["DIALOG_TAG_SELECTED_COLOUR"]=1;
              skip["DIALOG_BUTTON_ACTIVE_COLOUR"]=1;skip["DIALOG_BUTTON_KEY_ACTIVE_COLOUR"]=1;skip["DIALOG_BUTTON_LABEL_ACTIVE_COLOUR"]=1;}
        {k=$1; if(!(k in skip)) print $0}
      ' "$conf" >"${tmp}.base" 2>/dev/null || true

      cat "${tmp}.base" "$tmp" >"${tmp}.new" 2>/dev/null || true
      mv -f "${tmp}.new" "$conf" 2>/dev/null || true
      rm -f "$tmp" "${tmp}.base" 2>/dev/null || true
    fi

    # Retire legacy file to avoid future confusion.
    # Move legacy out of the way so it cannot be accidentally re-merged later.
    local _ret_dir="${cfg_dir}/retired"
    mkdir -p "$_ret_dir" 2>/dev/null || true
    mv -f "$legacy_cfg" "${_ret_dir}/dast.cfg.retired_$(date +%s)" 2>/dev/null || true
  fi

  # Ensure config dir/file exist.
  mkdir -p "$cfg_dir" 2>/dev/null || true
  touch "$conf" 2>/dev/null || true

  # Ensure ownership is the real invoking user (when applicable).
  if [[ "$real_user" != "root" ]]; then
    chown "$real_user:$real_group" "$cfg_dir" "$conf" 2>/dev/null || true
    chmod 755 "$cfg_dir" 2>/dev/null || true
    chmod 644 "$conf" 2>/dev/null || true
  fi
}

__dast_toolbox_cfg_consolidate
# ------------------------------------------------------------------------------

# Export dir (debug-only): keep exports inside the debug run directory when debugging is enabled.
# When debug is off, avoid creating any ./debug or ./debug/exports paths.
if [[ "${DAST_DEBUG:-0}" -eq 1 && -n "${DEBUG_DIR:-}" && "${DEBUG_DIR}" != "/dev/null" ]]; then
  : "${EXPORT_DIR:="${DEBUG_DIR}/exports"}"
else
  : "${EXPORT_DIR:=""}"
fi
# Ensure dirs exist and are writable (repair ownership like config dir logic)
_dast_toolbox__ensure_dir() {
  # Usage: _dast_toolbox__ensure_dir <dir>
  # Creates the dir and (when running as root) repairs ownership to the real invoker
  # so modules can append logs/debug without leaving root-owned artefacts behind.
  local d="$1"
  [[ -z "${d:-}" ]] && return 1

  mkdir -p "$d" 2>/dev/null || return 1

  # Keep perms sane and ownership consistent with config ownership rules.
  # (This is critical because DaST often runs under sudo, but we want files
  # to remain writable/persistent for the invoking user.)
  _dast_toolbox__fix_owner_perms "$d" 2>/dev/null || true
  return 0
}


# -----------------------------------------------------------------------------
# Config ownership safety helpers (prevents config/dast.conf becoming root-owned)
# -----------------------------------------------------------------------------

_dast_toolbox__target_owner() {
  # Prints: "<user>:<group>"
  local u g

  u="${DAST_INVOKER_USER:-}"
  if [[ -z "${u:-}" || "${u}" == "root" ]]; then
    u="${SUDO_USER:-}"
  fi
  if [[ -z "${u:-}" || "${u}" == "root" ]]; then
    u="$(__dast_toolbox_real_user 2>/dev/null || true)"
  fi
  if [[ -z "${u:-}" || "${u}" == "root" ]]; then
    # Fall back to owner of config dir, then script dir, then HOME.
    u="$(stat -c '%U' "${CFG_DIR:-.}" 2>/dev/null || true)"
  fi
  if [[ -z "${u:-}" || "${u}" == "root" ]]; then
    u="$(stat -c '%U' "${SCRIPT_DIR:-.}" 2>/dev/null || true)"
  fi
  if [[ -z "${u:-}" || "${u}" == "root" ]]; then
    u="$(stat -c '%U' "${HOME:-.}" 2>/dev/null || true)"
  fi
  if [[ -z "${u:-}" ]]; then
    u="root"
  fi

  g="${DAST_INVOKER_GROUP:-}"
  if [[ -z "${g:-}" && "${u}" != "root" ]]; then
    g="$(id -gn "${u}" 2>/dev/null || echo "${u}")"
  fi
  if [[ -z "${g:-}" ]]; then
    g="${u}"
  fi

  printf '%s:%s\n' "$u" "$g"
}

_dast_toolbox__fix_owner_perms() {
  # Usage: _dast_toolbox__fix_owner_perms <path> [mode]
  local p="$1" mode="${2:-}"
  [[ -z "${p:-}" ]] && return 0

  local og
  og="$(_dast_toolbox__target_owner)"
  local u="${og%%:*}" g="${og##*:}"

  # Always keep perms sane (dir 755, file 644 unless caller overrides).
  if [[ -d "$p" ]]; then
    chmod 755 "$p" 2>/dev/null || true
  elif [[ -f "$p" ]]; then
    if [[ -n "${mode:-}" ]]; then
      chmod "$mode" "$p" 2>/dev/null || true
    else
      chmod 644 "$p" 2>/dev/null || true
    fi
  fi

  # Only chown when running as root and we have a non-root target.
  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${u:-}" && "${u}" != "root" ]]; then
    chown "${u}:${g}" "$p" 2>/dev/null || true
  fi
}

_dast_toolbox__fix_config_owner_perms() {
  local cf="$1"
  [[ -z "${cf:-}" ]] && return 0

  local dir
  dir="$(dirname "$cf")"
  mkdir -p "$dir" 2>/dev/null || true
  _dast_toolbox__fix_owner_perms "$dir" 2>/dev/null || true

  if [[ ! -e "$cf" ]]; then
    : >"$cf" 2>/dev/null || true
  fi
  _dast_toolbox__fix_owner_perms "$cf" 644 2>/dev/null || true
}

_dast_toolbox__cfg_set_kv_common() {
  local key="$1" val="$2" cf="$3"
  [[ -z "${key:-}" || -z "${cf:-}" ]] && return 1

  _dast_toolbox__fix_config_owner_perms "$cf"

  local dir tmp
  dir="$(dirname "$cf")"
  tmp="$(mktemp -p "$dir" ".dast.conf.tmp.XXXXXX" 2>/dev/null || mktemp 2>/dev/null)"
  [[ -z "${tmp:-}" ]] && return 1

  # Keep tmp owned by the target owner before mv.
  _dast_toolbox__fix_owner_perms "$tmp" 600 2>/dev/null || true

  if [[ -f "$cf" ]]; then
    grep -vE "^${key}=" "$cf" >"$tmp" 2>/dev/null || true
  else
    : >"$tmp"
  fi

  printf '%s=%q\n' "$key" "$val" >>"$tmp"

  mv -f "$tmp" "$cf" 2>/dev/null || cat "$tmp" >"$cf"
  rm -f "$tmp" 2>/dev/null || true

  _dast_toolbox__fix_config_owner_perms "$cf"
}

_dast_toolbox__ensure_dir "$LOG_DIR" || true
_dast_toolbox__ensure_dir "$CFG_DIR" || true

# Only create debug/export dirs when debug is enabled and DEBUG_DIR is a real directory path.
if [[ "${DAST_DEBUG:-0}" -eq 1 && -n "${DEBUG_DIR:-}" && "${DEBUG_DIR}" != "/dev/null" ]]; then
  _dast_toolbox__ensure_dir "$DEBUG_DIR" || true
  [[ -n "${EXPORT_DIR:-}" ]] && _dast_toolbox__ensure_dir "$EXPORT_DIR" || true
fi

# Logging wrappers (prefer main helpers if present)
# Fallbacks here MUST be safe under sudo: append as the real invoking user, not root.
_dast_toolbox__append_line() {
  # Usage: _dast_toolbox__append_line <file> <line>
  local f="$1" line="$2"
  [[ -z "${f:-}" ]] && return 1

  local d; d="$(dirname "$f")"
  _dast_toolbox__ensure_dir "$d" >/dev/null 2>&1 || true

  # Make sure the file exists with sane owner/perms before appending.
  if [[ ! -e "$f" ]]; then
    : >"$f" 2>/dev/null || true
  fi
  _dast_toolbox__fix_owner_perms "$f" 644 2>/dev/null || true

  local og u
  og="$(_dast_toolbox__target_owner 2>/dev/null || echo root:root)"
  u="${og%%:*}"

  if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${u:-}" && "${u}" != "root" ]] && command -v sudo >/dev/null 2>&1; then
    # Append as the invoker, preserving ownership and preventing root-owned logs.
    # Append as the invoker, preserving ownership and preventing root-owned logs.
    # Use bash -c with positional args to avoid quote/escape hell.
    sudo -u "$u" bash -c 'printf "%s\n" "$1" >>"$2"' _ "$line" "$f" 2>/dev/null || true
  else
    printf '%s\n' "$line" >>"$f" 2>/dev/null || true
  fi
}

_dast_toolbox__log_fallback() {
  # Always route through the core logger when available.
  local msg="$*"
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log INFO "$module_id" "$msg"
  fi
}

_dast_toolbox__dbg_fallback() {
  [[ "${DAST_DEBUG:-0}" -eq 1 ]] || return 0
  local msg="$*"
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$module_id" "$msg"
  fi
}

toolbox__log() {
  if command -v dast_log >/dev/null 2>&1; then
    dast_log "${@}" || true
  else
    _dast_toolbox__log_fallback "${@}"
  fi
}

toolbox__dbg() {
  if command -v dast_dbg >/dev/null 2>&1; then
    dast_dbg "${@}" || true
  else
    _dast_toolbox__dbg_fallback "${@}"
  fi
}
# -----------------------------------------------------------------------------

CURRENT_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${LIB_DIR:=$(dirname "${CURRENT_MODULE_DIR}")/lib}"

# Prefer CFG_FILE (new main), fall back to CFG_FILE (older naming).
# Keep LEGACY_CONFIG_FILE support too.
__tools_cfg_file() {
  # Canonical config file path
  if [[ -n "${CFG_FILE:-}" ]]; then
    echo "$CFG_FILE"
  else
    echo ""
  fi
}

# ---- small helpers for config ----
# Only define these if main doesn't already provide them.
# ---- config helpers ----
# (defined later in this module, guarded to avoid clashing with main)

# ---- fallbacks (only if your main doesn't provide them) ----

# Default history file (persistent) if not defined elsewhere.
# Keep this under config to avoid creating /var/log artefacts from a module.
: "${HISTORY_FILE:="${CFG_DIR:-${DAST_APP_DIR:-.}/config}/history.log"}"

# Legacy helper (no-op): directory creation is handled centrally by the launcher.
__tools_ensure_log_dir() { :; }

if ! declare -F show_deps_status >/dev/null 2>&1; then
  show_deps_status() {
    local tmp; tmp="$(mktemp)"
    {
      echo "Dependency status"
      echo "-----------------"
      for cmd in dialog systemctl journalctl apt-get awk sed sort grep tail head; do
        if command -v "$cmd" >/dev/null 2>&1; then
          echo "[ OK ] $cmd"
        else
          echo "[MISS] $cmd"
        fi
      done
      echo
      echo "Note: Some optional tools used by certain modules may not appear here."
    } >"$tmp"
    ui_textbox "$DAST_TOOLBOX_TITLE" "$tmp"
    rm -f "$tmp" || true
  }
fi

if ! declare -F export_file_with_scope >/dev/null 2>&1; then
  export_file_with_scope() {
    local src="$1"
    local base="$2"

    [[ -f "$src" ]] || { ui_msg "Export" "File not found:\n\n$src"; return 0; }

    local dest_dir
    dest_dir="$(ui_menu "$DAST_TOOLBOX_TITLE" "Choose where to write the export:" \
      "DAST"   "/var/log/dast/exports" \
      "TMP"    "/tmp" \
      "ROOT"   "/root" \
      "CUSTOM" "Choose a path" \
      "BACK"   "🔙️ Back")" || return 0

    case "$dest_dir" in
      DAST) dest_dir="/var/log/dast/exports" ;;
      TMP)  dest_dir="/tmp" ;;
      ROOT) dest_dir="/root" ;;
      CUSTOM)
        dest_dir="$(ui_input "Export path" "Enter a directory path:" "")" || return 0
        [[ -z "$dest_dir" ]] && return 0
        ;;
      BACK) return 0 ;;
      *) return 0 ;;
    esac

    mkdir -p "$dest_dir" 2>/dev/null || { ui_msg "Export failed" "Could not create:\n\n$dest_dir"; return 0; }

    local stamp outpath
    stamp="$(date '+%Y%m%d-%H%M%S')"
    outpath="$dest_dir/${base}-${stamp}.txt"

    if ui_yesno "Confirm export" "Write export to:\n\n$outpath\n\nDefault is No."; then
      cp -a "$src" "$outpath" 2>/dev/null || cat "$src" >"$outpath" 2>/dev/null || true
      ui_msg "Exported" "Saved:\n\n$outpath"
    else
      ui_msg "Cancelled" "No export created."
    fi
  }
fi

# ---- Menu + runner ----

tools_menu() {
  ui_menu "$DAST_TOOLBOX_TITLE" "Select an option:" \
    "RUNTIME" "🏃 Runtime & environment" \
    "HEALTH"  "🩺 Health checks" \
    "MODULES" "📦 Registered Modules" \
    "DEPS"    "🔗 Dependency status" \
    "BUNDLE"  "📦 Create support bundle" \
    "LOG"     "📜 View log file" \
    "HISTORY" "🕓 View command history" \
    "DSETT"   "🔧 DaST settings" \
    "BACK"    "🔙️ Back"
}


# ------------------------------------------------------------
# Toolbox: runtime, health checks, support bundle, module status
# ------------------------------------------------------------

cp_runtime_info() {
  local os pretty ver git_commit root dialogrc

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-unknown}"
    ver="${VERSION_ID:-}"
  else
    pretty="unknown"
    ver=""
  fi

  git_commit="$(git -C "${SCRIPT_DIR:-.}" rev-parse --short HEAD 2>/dev/null || echo "n/a")"
  root="$( [[ "${EUID:-999}" -eq 0 ]] && echo "yes" || echo "no" )"
  dialogrc="${DIALOGRC:-default}"

    local init pid1_comm effective_export_dir export_dir_raw
  pid1_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
  init="${pid1_comm:-unknown}"

  export_dir_raw="${EXPORT_DIR:-}"
  effective_export_dir="${EXPORT_DIR:-${DAST_EXPORT_DIR:-/tmp}}"

  # Module gating summary (rules are conservative by design)
  local distro_id distro_like
  distro_id="${ID:-unknown}"
  distro_like="${ID_LIKE:-}"

  local apt_gate zfs_gate svc_gate
  if [[ "$distro_id" == "neon" ]] || [[ "$distro_like" == *"neon"* ]]; then
    apt_gate="🔴 hidden (KDE Neon: APT discouraged)"
  else
    apt_gate="🟢 available (APT system)"
  fi

  if [[ "$distro_id" == "debian" ]] || [[ "$distro_like" == *"debian"* && "$distro_id" != "ubuntu" && "$distro_id" != "neon" ]]; then
    zfs_gate="🔴 hidden (Debian: ZFS module disabled by default)"
  else
    zfs_gate="🟢 available (ZFS capable)"
  fi

  if [[ "$pid1_comm" == "systemd" ]] || command -v systemctl >/dev/null 2>&1; then
    svc_gate="🟢 available (systemd)"
  else
    svc_gate="🔴 hidden (no systemd)"
  fi

  runtime_text="$(cat <<EOF
Detected OS: ${pretty}${ver:+ (v$ver)}
Init / PID1: ${init}

DaST version: ${APP_VER:-unknown}
Git commit: ${git_commit}

CFG_FILE: ${CFG_FILE:-}
CFG_DIR: ${CFG_DIR:-}
MODULES_DIR: ${MODULE_SEARCH_DIR:-}
LIB_DIR: ${LIB_DIR:-NOT_SET}
LOG_FILE: ${LOG_FILE:-}
HISTORY_FILE: ${HISTORY_FILE:-}
EXPORT_DIR: ${export_dir_raw:-<unset>}
Export effective: ${effective_export_dir}

Module gating (summary)
- APT: ${apt_gate}
- ZFS: ${zfs_gate}
- Services: ${svc_gate}

Dialog theme: ${dialogrc}
Running as root: ${root}
EOF
)"

  # Size the runtime window to the content where possible (and fall back to scrolling
  # if the terminal is small).
  local term_lines term_cols max_h max_w want_h want_w content_lines max_line rt_h rt_w
  if command -v tput >/dev/null 2>&1; then
    term_lines="$(tput lines 2>/dev/null || echo 24)"
    term_cols="$(tput cols  2>/dev/null || echo 80)"
  else
    term_lines="24"
    term_cols="80"
  fi

  max_h=$(( term_lines - 4 ))
  max_w=$(( term_cols  - 4 ))
  (( max_h < 12 )) && max_h=12
  (( max_w < 60 )) && max_w=60

  content_lines="$(printf "%s\n" "$runtime_text" | wc -l | tr -d '[:space:]')"
  max_line="$(printf "%s\n" "$runtime_text" | awk '{ if (length > m) m = length } END { print (m ? m : 60) }')"

  # A little padding for borders/title.
  want_h=$(( content_lines + 4 ))
  want_w=$(( max_line + 6 ))

  rt_h="$want_h"
  rt_w="$want_w"

  (( rt_h < 14 )) && rt_h=14
  (( rt_h > max_h )) && rt_h="$max_h"

  (( rt_w < 70 )) && rt_w=70
  (( rt_w > max_w )) && rt_w="$max_w"

  dast_ui_dialog --title "🏃 DaST Runtime" --msgbox "$runtime_text" "$rt_h" "$rt_w"

}

cp_health_checks() {
  local tmp; tmp="$(mktemp)"
  {
    echo "DaST health checks"
    echo "-----------------"
    echo

    # 1) config writable
    if mkdir -p "$(dirname "${CFG_FILE}")" 2>/dev/null && touch "${CFG_FILE}" 2>/dev/null; then
      echo "🟢 Config writable: ${CFG_FILE:-}"
    else
      echo "🔴 Config writable: ${CFG_FILE:-} (failed)"
    fi

    # 2) log writable
    if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE}" ]]; then
  echo "🟢 Log present: ${LOG_FILE:-}"
else
  echo "🔴 Log present: ${LOG_FILE:-} (missing)"
fi


    # 3) export dir creatable
    if mkdir -p "${EXPORT_DIR}" 2>/dev/null; then
      echo "🟢 Export dir creatable: ${EXPORT_DIR:-}"
    else
      echo "🔴 Export dir creatable: ${EXPORT_DIR:-} (failed)"
    fi

    # 4) shared lib load (PATCHED)
    if [[ -d "${LIB_DIR:-}" && -f "${LIB_DIR}/dast_helper.sh" ]]; then
      # shellcheck disable=SC1090
      if source "${LIB_DIR}/dast_helper.sh" 2>/dev/null; then
        echo "🟢 Shared lib load: OK (${LIB_DIR}/dast_helper.sh)"
      else
        echo "🔴 Shared lib load: ${LIB_DIR}/dast_helper.sh (failed to source)"
      fi
    else
      echo "🔴 Shared lib load: FAILED. Looked in: ${LIB_DIR:-<empty>}"
    fi

    # 5) enumerate modules
    if [[ -n "${MODULE_SEARCH_DIR:-}" ]] && ls "${MODULE_SEARCH_DIR}"/[0-9][0-9]_*.sh >/dev/null 2>&1; then
      echo "🟢 Modules enumerable: ${MODULE_SEARCH_DIR}"
    else
      echo "🔴 Modules enumerable: ${MODULE_SEARCH_DIR:-} (none found)"
    fi

    echo
    echo "Tip: If something is red, check file permissions and paths in Runtime & environment."
  } >"$tmp"

  ui_textbox "$DAST_TOOLBOX_TITLE" "$tmp"
  rm -f "$tmp" || true
}

# Merged: keep loader emoji status, but show only registered modules (clean columns)
cp_show_module_status() {
  local tmp; tmp="$(mktemp)"
  {
    echo "Registered Modules"
    echo "------------------"
    echo

    local id title func src ok f st reason emoji
    for id in "${MODULE_IDS[@]}"; do
      title="${MODULE_TITLES[$id]:-}"
      func="${MODULE_FUNCS[$id]:-}"
      src="${MODULE_SRCFILE[$id]:-unknown}"

      ok="yes"
      if [[ -z "$func" ]] || ! declare -F "$func" >/dev/null 2>&1; then
        ok="no"
      fi

      # Status from module loader (per file), if available.
      st=""
      reason=""
      if declare -p MODULE_FILE_STATUS >/dev/null 2>&1; then
        st="${MODULE_FILE_STATUS[$src]:-}"
        reason="${MODULE_FILE_REASON[$src]:-}"

        # If the source file path differs (eg relative vs absolute), fall back by basename match.
        if [[ -z "$st" && "$src" != "unknown" ]]; then
          for f in "${!MODULE_FILE_STATUS[@]}"; do
            if [[ "$(basename "$f")" == "$(basename "$src")" ]]; then
              st="${MODULE_FILE_STATUS[$f]:-}"
              reason="${MODULE_FILE_REASON[$f]:-}"
              break
            fi
          done
        fi
      fi

      # Emoji mapping
      case "$st" in
        LOADED)  emoji="🟢" ;;
        SKIPPED) emoji="🟠" ;;
        FAILED)  emoji="🔴" ;;
        *)       emoji="⚪" ;;
      esac

      # Missing function is always a hard fail.
      if [[ "$ok" != "yes" ]]; then
        emoji="🔴"
      fi

      # Mismatch warning: module is registered but the loader marked its source file as SKIPPED.
      if [[ "$ok" == "yes" && "$st" == "SKIPPED" ]]; then
        emoji="🟡"
      fi

      # Keep original columns: emoji, module id, title, source basename.
      if [[ "$ok" == "yes" ]]; then
        if [[ "$st" == "LOADED" ]]; then
          printf "%s %-12s  %-40s  (%s)\n" "$emoji" "$id" "$title" "$(basename "$src")"
        else
          if [[ -n "$reason" ]]; then
            printf "%s %-12s  %-40s  (%s) [%s - %s]\n" "$emoji" "$id" "$title" "$(basename "$src")" "${st:-UNKNOWN}" "$reason"
          else
            printf "%s %-12s  %-40s  (%s) [%s]\n" "$emoji" "$id" "$title" "$(basename "$src")" "${st:-UNKNOWN}"
          fi
        fi
      else
        printf "%s %-12s  %-40s  (%s) missing func: %s\n" "$emoji" "$id" "$title" "$(basename "$src")" "$func"
      fi
    done

    echo
    echo "Status key:"
    echo "  🟢  Loaded   - module is available and active"
    echo "  🟠  Skipped  - module is not applicable on this system"
    echo "  🟡  Warning  - module is registered but loader marked its source file as SKIPPED"
    echo "  🔴  Failed   - module attempted to load but failed (or function is missing)"
    echo "  ⚪  Unknown  - module state could not be determined"

    echo
    echo "Duplicate ID scan:"
    if [[ -n "${MODULE_SEARCH_DIR:-}" ]]; then
      declare -A __id_to_files=()
      local __f __line __id
      for __f in "${MODULE_SEARCH_DIR}"/[0-9][0-9]_*.sh; do
        [[ -f "$__f" ]] || continue
        while IFS= read -r __line; do
          if [[ "$__line" =~ register_module[[:space:]]+"([A-Za-z0-9_]+)" ]]; then
            __id="${BASH_REMATCH[1]}"
            __id_to_files["$__id"]+="${__id_to_files[$__id]:+ ,}$(basename "$__f")"
          fi
        done < <(grep -E "register_module[[:space:]]+\"[A-Za-z0-9_]+\"" "$__f" 2>/dev/null || true)
      done

      local __found=0
      local __k __v
      local __lines=()
      for __k in "${!__id_to_files[@]}"; do
        __v="${__id_to_files[$__k]}"
        if [[ "$__v" == *","* ]]; then
          __found=1
          __lines+=("  🚨  $__k | $__v")
        fi
      done

      if [[ $__found -eq 0 ]]; then
        echo "  ✅ No duplicate module IDs detected."
      else
        printf "%s
" "${__lines[@]}" | sort
        echo
        echo "Tip: duplicate module ids cause one file to be SKIPPED, which shows up as a 🟡 warning."
      fi
    else
      echo "  (MODULE_SEARCH_DIR not set; cannot scan.)"
    fi

    echo
    echo "Debug (non-green):"
    local _id _title _func _src _ok _st _reason _why _hint
    local _any=0
    for _id in "${MODULE_IDS[@]}"; do
      _title="${MODULE_TITLES[$_id]:-}"
      _func="${MODULE_FUNCS[$_id]:-}"
      _src="${MODULE_SRCFILE[$_id]:-unknown}"

      _ok="yes"
      if [[ -z "$_func" ]] || ! declare -F "$_func" >/dev/null 2>&1; then
        _ok="no"
      fi

      _st=""
      _reason=""
      if declare -p MODULE_FILE_STATUS >/dev/null 2>&1; then
        _st="${MODULE_FILE_STATUS[$_src]:-}"
        _reason="${MODULE_FILE_REASON[$_src]:-}"
        if [[ -z "$_st" && "$_src" != "unknown" ]]; then
          for f in "${!MODULE_FILE_STATUS[@]}"; do
            if [[ "$(basename "$f")" == "$(basename "$_src")" ]]; then
              _st="${MODULE_FILE_STATUS[$f]:-}"
              _reason="${MODULE_FILE_REASON[$f]:-}"
              break
            fi
          done
        fi
      fi
      [[ -z "$_st" ]] && _st="UNKNOWN"

      _why=""
      _hint=""

      if [[ "$_ok" != "yes" ]]; then
        _why="FAILED - missing function: ${_func:-<unset>}"
      elif [[ "$_st" == "SKIPPED" ]]; then
        _why="WARNING - registered but loader marked SKIPPED"
        if [[ -n "$_reason" ]]; then
          _why="${_why} - ${_reason}"
        fi
        # If the loader skips because it cannot find a register_module marker, the fix is usually
        # to ensure the module registers using a literal module id string (not a variable).
        if [[ "${_reason,,}" == *"marker"* || "${_reason,,}" == *"register_module"* ]]; then
          _hint="hint: ensure the module calls register_module with a literal id, e.g. register_module \"MAINT\" ..."
        fi
      elif [[ "$_st" == "FAILED" ]]; then
        _why="FAILED - loader marked FAILED"
        [[ -n "$_reason" ]] && _why="${_why} - ${_reason}"
      elif [[ "$_st" == "UNKNOWN" ]]; then
        _why="UNKNOWN - no loader status recorded for source file"
      fi

      if [[ "$_ok" != "yes" || "$_st" != "LOADED" ]]; then
        _any=1
        printf "  %-12s  (%s)  %s\n" "$_id" "$(basename "$_src")" "$_why"
        [[ -n "$_hint" ]] && printf "               %s\n" "$_hint"
      fi
    done

    if [[ $_any -eq 0 ]]; then
      echo "  ✅ No issues detected."
    fi
  } >"$tmp"

  ui_textbox "$DAST_TOOLBOX_TITLE" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

cp_support_bundle() {
  __tools_ensure_log_dir

  local stamp outdir out tarball tmp
  stamp="$(date +%Y%m%d_%H%M%S)"
  outdir="${EXPORT_DIR}/dast_support_${stamp}"
  mkdir -p "$outdir" 2>/dev/null || true

  # Config, logs, history (if present)
  [[ -f "${CFG_FILE:-}" ]] && cp -a "${CFG_FILE}" "$outdir/" 2>/dev/null || true
  [[ -n "${RUN_LOG_DIR:-}" && -d "${RUN_LOG_DIR}" ]] && cp -a "${RUN_LOG_DIR}"/*.log "$outdir/" 2>/dev/null || true
  [[ -f "${HISTORY_FILE:-}" ]] && cp -a "${HISTORY_FILE}" "$outdir/" 2>/dev/null || true

  # System info
  [[ -r /etc/os-release ]] && cp -a /etc/os-release "$outdir/" 2>/dev/null || true
  uname -a >"$outdir/uname.txt" 2>/dev/null || true
  if command -v zfs >/dev/null 2>&1; then
    zfs version >"$outdir/zfs_version.txt" 2>/dev/null || true
  fi

  # Module status
  tmp="$outdir/module_status.txt"
  {
    echo "Module status (generated by DaST)"
    echo "--------------------------------"
    echo
    for f in "${!MODULE_FILE_STATUS[@]}"; do
      echo "$(basename "$f"): ${MODULE_FILE_STATUS[$f]} - ${MODULE_FILE_REASON[$f]}"
    done | sort
    echo
    echo "Registered module ids"
    echo "---------------------"
    for id in "${MODULE_IDS[@]}"; do
      echo "$id | ${MODULE_TITLES[$id]:-} | ${MODULE_FUNCS[$id]:-} | $(basename "${MODULE_SRCFILE[$id]:-unknown}")"
    done
  } >"$tmp"

  # Dependency status
  show_deps_status_to_file "$outdir/deps_status.txt"

  # Create tarball
  tarball="${outdir}.tar.gz"
  tar -czf "$tarball" -C "$(dirname "$outdir")" "$(basename "$outdir")" 2>/dev/null || true

  ui_msg "📦 Support bundle" "Created:

$tarball"
}

# Helper: reuse deps check but write to a file
show_deps_status_to_file() {
  local out="$1"
  {
    echo "Dependency status"
    echo "-----------------"
    for cmd in dialog systemctl journalctl apt-get awk sed sort grep tail head; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "🟢 $cmd: OK ($(command -v "$cmd"))"
      else
        echo "🔴 $cmd: missing"
      fi
    done
    echo
    echo "Optional:"
    for cmd in zfs zpool nft ufw ss ip ethtool smartctl sensors; do
      if command -v "$cmd" >/dev/null 2>&1; then
        echo "🟢 $cmd: OK ($(command -v "$cmd"))"
      else
        echo "🟠 $cmd: missing"
      fi
    done
  } >"$out"
}

tools_run() {
  local action="$1"
  case "$action" in
    RUNTIME) cp_runtime_info ;;
    HEALTH)  cp_health_checks ;;
    MODULES) cp_show_module_status ;;
    DEPS)    show_deps_status ;;
    DSETT)  settings_menu ;;
    BUNDLE)  cp_support_bundle ;;
    LOG)
      if [[ -f "$LOG_FILE" ]]; then
        ui_textbox "$DAST_TOOLBOX_TITLE" "$LOG_FILE"
      else
        ui_msg "$DAST_TOOLBOX_TITLE" "Log file not found:

$LOG_FILE"
      fi
      ;;
    HISTORY)
      if [[ -f "$HISTORY_FILE" ]]; then
        ui_textbox "$DAST_TOOLBOX_TITLE" "$HISTORY_FILE"
      else
        ui_msg "$DAST_TOOLBOX_TITLE" "History file not found:

$HISTORY_FILE"
      fi
      ;;
    BACK) ;;
  esac
}

# ------------------------------------------------------------
# Merged DaST settings (formerly Settings module)
# ------------------------------------------------------------

__settings_cfg_file() {
  if [[ -n "${CFG_FILE:-}" ]]; then
    echo "$CFG_FILE"
  elif [[ -n "${CFG_FILE:-}" ]]; then
    echo "$CFG_FILE"
  else
    echo ""
  fi
}

# ---------- config helpers ----------
# Only define these if main doesn't already provide them.
if ! declare -F cfg_load >/dev/null 2>&1; then
  cfg_load() {
    local cf
    cf="$(__settings_cfg_file)"

    [[ -f "${LEGACY_CONFIG_FILE:-}" ]] && source "$LEGACY_CONFIG_FILE" >/dev/null 2>&1 || true
    [[ -n "$cf" && -f "$cf" ]]        && source "$cf"               >/dev/null 2>&1 || true
  }
fi

if ! declare -F cfg_set_kv >/dev/null 2>&1; then
  cfg_set_kv() {
    local key="$1" val="$2"
    [[ -z "$key" ]] && return 1
    local cf
    cf="$(__settings_cfg_file)"
    [[ -z "$cf" ]] && return 1
    _dast_toolbox__cfg_set_kv_common "$key" "$val" "$cf"
  }
fi

cfg_write_defaults() {
  local cf
  cf="$(__settings_cfg_file)"
  [[ -z "$cf" ]] && return 1

  local dir tmp
  dir="$(dirname "$cf")"
  mkdir -p "$dir" 2>/dev/null || true

  # Ensure dir/file ownership is aligned to the real invoker.
  _dast_toolbox__fix_owner_perms "$dir" 2>/dev/null || true

  tmp="$(mktemp -p "$dir" ".dast.conf.defaults.XXXXXX" 2>/dev/null || mktemp 2>/dev/null)"
  [[ -z "${tmp:-}" ]] && return 1

  cat >"$tmp" <<'EOF'
# DaST user config (auto-generated)

# Export / display defaults
EXPORT_LINES=200

# Process monitor preference: auto|btop|htop
PROCESS_MONITOR_PREF=auto

# Appearance / UI
UI_EMOJI=1
UI_COLOUR=1

# Dialog colour tuples stored in dast.cfg (no spaces; runtime formatter adds spaces)
DIALOG_SCREEN_COLOUR=(WHITE,MAGENTA,ON)
DIALOG_ITEM_SELECTED_COLOUR=(WHITE,MAGENTA,ON)
DIALOG_TAG_SELECTED_COLOUR=(WHITE,MAGENTA,ON)
DIALOG_BUTTON_ACTIVE_COLOUR=(WHITE,MAGENTA,ON)
DIALOG_BUTTON_KEY_ACTIVE_COLOUR=(YELLOW,MAGENTA,ON)
DIALOG_BUTTON_LABEL_ACTIVE_COLOUR=(WHITE,MAGENTA,ON)

UI_COMPACT=0

# Logging / history
LOG_TO_FILE=0
LOG_LEVEL=info
HISTORY_MAX=200
EOF

  # Keep tmp sane before the mv (mv preserves tmp ownership).
  _dast_toolbox__fix_owner_perms "$tmp" 600 2>/dev/null || true

  mv -f "$tmp" "$cf" 2>/dev/null || cat "$tmp" >"$cf"
  rm -f "$tmp" 2>/dev/null || true

  _dast_toolbox__fix_config_owner_perms "$cf"
}

cfg_ensure_exists() {
  local cf
  cf="$(__settings_cfg_file)"
  [[ -z "$cf" ]] && return 0
  if [[ ! -f "$cf" ]]; then
    cfg_write_defaults || true
  fi
}

# ---------- apply settings (make them actually do something) ----------


__settings_apply_ui_now() {
  # Re-apply runtime theme in the current DaST process (no persistent dialogrc files).
  if declare -F cfg_load >/dev/null 2>&1; then
    cfg_load || true
  fi
  if declare -F dast_apply_dialog_theme >/dev/null 2>&1; then
    dast_apply_dialog_theme || true
  fi
}



__settings_unescape_dialog_colours() {
  # cfg_set_kv (historically) used %q which escapes commas/parentheses, producing values like:
  #   \(WHITE\,MAGENTA\,ON\)
  # dialog expects:
  #   (WHITE,MAGENTA,ON)
  local _k _v
  for _k in DIALOG_SCREEN_COLOUR DIALOG_ITEM_SELECTED_COLOUR DIALOG_TAG_SELECTED_COLOUR DIALOG_BUTTON_ACTIVE_COLOUR DIALOG_BUTTON_KEY_ACTIVE_COLOUR DIALOG_BUTTON_LABEL_ACTIVE_COLOUR; do
    _v="${!_k:-}"
    [[ -z "$_v" ]] && continue
    _v="${_v//\\(/(}"
    _v="${_v//\\)/)}"
    _v="${_v//\\,/,}"
    printf -v "$_k" '%s' "$_v"
    export "$_k"
  done
  unset _k _v
}



# Compatibility shim: older Settings module used settings_write_dialogrc.
# DaST core now generates a temp dialogrc via dast_apply_dialog_theme().
settings_write_dialogrc() {
  # Args: 1=enable colours, 0=disable colours (kept for compatibility)
  local _enable="${1:-1}"
  export UI_COLOUR="${_enable}"
  if declare -F dast_apply_dialog_theme >/dev/null 2>&1; then
    dast_apply_dialog_theme >/dev/null 2>&1 || true
    return 0
  fi
  # If running outside the main loader context, do nothing.
  return 0
}

settings_apply_now() {
  cfg_load
  cfg_ensure_exists
  cfg_load
  __settings_unescape_dialog_colours || true


  # Apply Debug mode (like running DaST with --debug)
  # Default: OFF when config is missing.
  if [[ "${DEBUG_MODE:-0}" -eq 1 ]]; then
    export DAST_DEBUG=1
    export DEBUG=1
    _dast_toolbox__ensure_dir "$DEBUG_DIR" >/dev/null 2>&1 || true
    _dast_toolbox__ensure_dir "$EXPORT_DIR" >/dev/null 2>&1 || true
    _dast_toolbox__ensure_dir "$LOG_DIR" >/dev/null 2>&1 || true
    toolbox__dbg "[DEBUG] DASTTOOL: Debug mode enabled (debug dir: ${DEBUG_DIR})"
  else
    export DAST_DEBUG=0
    export DEBUG=0
  fi

  if [[ "${UI_COLOUR:-1}" -eq 1 ]]; then
    settings_write_dialogrc 1
  else
    settings_write_dialogrc 0
  fi
  return 0
}

cfg_reset() {
  if declare -F dial >/dev/null 2>&1; then
    dial --title "♻ Reset settings" --defaultno --yesno "This will reset DaST settings to defaults.\n\nContinue?" 12 80 >/dev/null || return 0
  else
    ui_yesno "♻ Reset settings" "This will reset DaST settings to defaults.\n\nContinue?" || return 0
  fi

  cfg_write_defaults
  if declare -F cfg_load >/dev/null 2>&1; then
    cfg_load || true
  fi
  settings_apply_now || true
  ui_msg "✅ Reset complete" "Settings restored to defaults."
}

# ---------- config tools ----------

settings_show_config() {
  cfg_ensure_exists
  local cf tmp
  cf="$(__settings_cfg_file)"
  [[ -z "$cf" ]] && { ui_msg "$SETTINGS_TITLE" "Config path not available."; return 0; }

  tmp="$(mktemp)"
  {
    echo "DaST config"
    echo
    echo "CFG_FILE: $cf"
    echo "CFG_DIR : $(dirname "$cf")"
    echo "DIALOGRC: ${DIALOGRC:-"(not set)"}"
    echo
    echo "-----"
    if [[ -f "$cf" ]]; then
      cat "$cf"
    else
      echo "(config file does not exist)"
    fi
  } >"$tmp"

  ui_textbox "$SETTINGS_TITLE" "$tmp"
  rm -f "$tmp" || true
}

settings_edit_config() {
  cfg_ensure_exists
  local cf
  cf="$(__settings_cfg_file)"
  [[ -z "$cf" ]] && { ui_msg "$SETTINGS_TITLE" "Config path not available."; return 0; }

  if ! declare -F dial >/dev/null 2>&1; then
    ui_msg "$SETTINGS_TITLE" "No dialog editor available in this build."
    return 0
  fi

  dial --title "📝 Edit config" --defaultno --yesno "Edit DaST config file?\n\n$cf\n\nDefault is No." 12 90 >/dev/null || return 0

  local tmp edited
  tmp="$(mktemp)"
  edited="$(dial --title "📝 Edit config" --editbox "$cf" 24 100)" || { rm -f "$tmp"; return 0; }
  printf '%s\n' "$edited" >"$tmp"

  if ! cmp -s "$tmp" "$cf" 2>/dev/null; then
    dial --title "Save changes" --defaultno --yesno "Save changes to:\n\n$cf\n\nDefault is No." 12 90 >/dev/null || { rm -f "$tmp"; return 0; }
    cp -a "$cf" "${cf}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
    cat "$tmp" >"$cf"
    settings_apply_now || true
    ui_msg "✅ Saved" "Config updated.\n\nBackup created:\n${cf}.bak.*"
  else
    ui_msg "$SETTINGS_TITLE" "No changes."
  fi

  rm -f "$tmp" || true
}

# ---------- menus ----------

appearance_menu() {
  settings_apply_now || true
  while true; do
    local emoji_state compact_state choice
    emoji_state="$([[ "${UI_EMOJI:-1}" -eq 1 ]] && echo "ON" || echo "OFF")"
    compact_state="$([[ "${UI_COMPACT:-0}" -eq 1 ]] && echo "ON" || echo "OFF")"
    warn_state="$([[ "${SHOW_STARTUP_WARNING:-1}" -eq 1 ]] && echo "ON" || echo "OFF")"

    choice="$(ui_menu "🎨 Appearance / UI" "Choose a UI option:" \
      "EMOJI"      "🙂 Emoji in menus (pref: $emoji_state, auto-off on TTY)" \
      "COMPACT"    "📦 Compact dialogs (current: $compact_state)" \
      "STARTUP_WARN" "🚨 Startup safety warning popup (current: $warn_state)" \
      "BACK"       "🔙️ Back")" || return 0

    case "$choice" in
      EMOJI)
        if [[ "${UI_EMOJI:-1}" -eq 1 ]]; then cfg_set_kv "UI_EMOJI" 0; else cfg_set_kv "UI_EMOJI" 1; fi
        settings_apply_now || true
        ;;
      COMPACT)
        if [[ "${UI_COMPACT:-0}" -eq 1 ]]; then cfg_set_kv "UI_COMPACT" 0; else cfg_set_kv "UI_COMPACT" 1; fi
        settings_apply_now || true
        ;;
      STARTUP_WARN)
        if [[ "${SHOW_STARTUP_WARNING:-1}" -eq 1 ]]; then cfg_set_kv "SHOW_STARTUP_WARNING" 0; else cfg_set_kv "SHOW_STARTUP_WARNING" 1; fi
        cfg_load
        ;;
      BACK) return 0 ;;
    esac
  done
}

logging_menu() {
  cfg_ensure_exists
  cfg_load
  while true; do
    local ltf lvl hm dbg choice
    ltf="$([[ "${LOG_TO_FILE:-0}" -eq 1 ]] && echo "ON" || echo "OFF")"
    lvl="${LOG_LEVEL:-info}"
    hm="${HISTORY_MAX:-200}"
    dbg="$([[ "${DEBUG_MODE:-0}" -eq 1 ]] && echo "ON" || echo "OFF")"

    choice="$(ui_menu "📝 Logging & history" "⚠ Changes here affect DaST-wide logging/debug behaviour.

Choose an option:" \
      "LOG_TO_FILE" "📚 Log to file (current: $ltf)" \
      "DEBUG_MODE"  "🐞 Debug mode (like --debug) (current: $dbg)" \
      "OPEN_DIRS"   "📂 Show log/debug paths" \
      "LOG_LEVEL"   "📈 Log level (current: $lvl)" \
      "HISTORY_MAX" "📊 History max entries (current: $hm)" \
      "BACK"        "🔙️ Back")" || return 0

    case "$choice" in
      LOG_TO_FILE)
        if [[ "${LOG_TO_FILE:-0}" -eq 1 ]]; then cfg_set_kv "LOG_TO_FILE" 0; else cfg_set_kv "LOG_TO_FILE" 1; fi
        cfg_load
        ;;
      LOG_LEVEL)
        local sel
        sel="$(ui_menu "🎚 Log level" "Pick a log level:" "debug" "debug" "info" "info" "warn" "warn" "error" "error" "BACK" "Back")" || return 0
        [[ "$sel" == "BACK" ]] && continue
        cfg_set_kv "LOG_LEVEL" "$sel"
        cfg_load
        ;;
      HISTORY_MAX)
        local v
        v="$(ui_input "📊 History max entries" "Enter max entries:" "${HISTORY_MAX:-200}")" || continue
        [[ "$v" =~ ^[0-9]+$ ]] && cfg_set_kv "HISTORY_MAX" "$v"
        cfg_load
        ;;
      DEBUG_MODE)
        if [[ "${DEBUG_MODE:-0}" -eq 1 ]]; then cfg_set_kv "DEBUG_MODE" 0; else cfg_set_kv "DEBUG_MODE" 1; fi
        cfg_load
        # Apply immediately so the current run behaves like --debug without relaunch.
        settings_apply_now >/dev/null 2>&1 || true
        ;;
      OPEN_DIRS)
        ui_msg "📂 DaST log/debug paths" "LOG_DIR:
${LOG_DIR}

DEBUG_DIR:
${DEBUG_DIR}

CONFIG:
$(__settings_cfg_file)

Tip: enable Debug mode to populate ${DEBUG_DIR} with richer diagnostics."
        ;;
      BACK) return 0 ;;
    esac
  done
}

procmon_menu() {
  cfg_ensure_exists
  cfg_load
  local sel

  sel="$(ui_menu "📊 Process monitor" "Choose preference:"     "auto" "Auto"     "btop" "Prefer btop"     "htop" "Prefer htop"     "BACK" "🔙️ Back")" || return 0

  if [[ -z "$sel" || "$sel" == "BACK" ]]; then
    return 0
  fi

  cfg_set_kv "PROCESS_MONITOR_PREF" "$sel"
  cfg_load
  return 0
}


export_lines_menu() {
  cfg_ensure_exists
  cfg_load
  local v
  v="$(ui_input "📤 Export lines" "How many lines?

Allowed range: 1 to 5000" "${EXPORT_LINES:-200}")" || return 0

  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    ui_msg "📤 Export lines" "Please enter a number."
    return 0
  fi

  if (( v < 1 || v > 5000 )); then
    ui_msg "📤 Export lines" "Value out of range.

Allowed range: 1 to 5000"
    return 0
  fi

  cfg_set_kv "EXPORT_LINES" "$v" && cfg_load
}

settings_menu() {
  # Avoid a crash loop if settings_apply_now || true fails (missing files, syntax error, etc.)
  local _rc
  set +e
  settings_apply_now || true
  _rc=$?
  set -e
  if [[ $_rc -ne 0 ]]; then
    ui_msg "⚙️ DaST Settings" "⚠ Warning: Failed to apply settings (rc=$_rc).

You can still view/edit/reset the config from this menu."
  fi
  while true; do
    local choice
    choice="$(ui_menu "⚙️ DaST Settings" "Choose an area:" \
      "APPEARANCE"   "🎨 Appearance / UI" \
      "EXPORT_LINES" "📤 Export line count" \
      "PROCMON"      "📊 Process monitor preference" \
      "LOGGING"      "📝 Logging & history options" \
      "PATH_MGMT"    "🔗 Manage PATH integration (dast shortcut)" \
      "SHOW_CFG"     "🔎 Show config file" \
      "EDIT_CFG"     "📝 Manually edit config file" \
      "RESET"        "🔁 Reset settings" \
      "BACK"         "🔙️ Back")" || return 0

    case "$choice" in
      APPEARANCE)   appearance_menu ;;
      EXPORT_LINES) export_lines_menu ;;
      PROCMON)      procmon_menu ;;
      LOGGING)      logging_menu ;;
      PATH_MGMT)    toolbox_manage_dast_shortcut ;;
      SHOW_CFG)     settings_show_config ;;
      EDIT_CFG)     settings_edit_config ;;
      RESET)        cfg_reset ;;
      BACK)         return 0 ;;
    esac
  done
}


# --- BEGIN DaST Toolbox PATH Shortcut Helpers (SAFE / ADDITIVE) ---

# Resolve the "current" DaST root based on how we're actually running.
# Prefer DAST_APP_DIR if set and valid, otherwise infer from this module location.
toolbox_current_dast_root() {
  local root=""
  if [[ -n "${DAST_APP_DIR:-}" && -d "${DAST_APP_DIR:-}" ]]; then
    root="$(cd "${DAST_APP_DIR}" && pwd -P)"
    printf '%s\n' "$root"
    return 0
  fi

  # Infer: <root>/modules/160_dast_toolbox.sh -> <root>
  local mod="${BASH_SOURCE[0]:-}"
  local mod_real=""
  mod_real="$(readlink -f "$mod" 2>/dev/null || true)"
  if [[ -z "$mod_real" ]]; then
    mod_real="$mod"
  fi

  local mod_dir
  mod_dir="$(cd "$(dirname "$mod_real")" 2>/dev/null && pwd -P || true)"
  if [[ -n "$mod_dir" && "$(basename "$mod_dir")" == "modules" ]]; then
    root="$(cd "$mod_dir/.." 2>/dev/null && pwd -P || true)"
  else
    root="$mod_dir"
  fi

  if [[ -n "$root" && -d "$root" ]]; then
    printf '%s\n' "$root"
    return 0
  fi
  return 1
}

toolbox_launcher_cfg_path() {
  local cfg="${CFG_DIR:-}"
  if [[ -z "$cfg" ]]; then
    # Last-resort fallback; DaST normally sets CFG_DIR.
    cfg="$HOME/.config/dast"
  fi
  printf '%s\n' "$cfg/.dast_launcher_path"
}

toolbox_launcher_choice_load() {
  local f
  f="$(toolbox_launcher_cfg_path)"
  # Guard: config exists but is unreadable (likely written under sudo/root).
  if [[ -e "$f" && ! -r "$f" ]]; then
    set +e
    ui_msg "⚠ DaST shortcut" "The launcher config file exists but is not readable:

$f

This is usually caused by it being created as root (sudo).

Use the PATH integration menu to repair ownership/permissions, or fix it manually (chown/chmod)."
    set -e
    return 1
  fi
  [[ -r "$f" ]] || return 1
  local p=""
  p="$(head -n1 "$f" 2>/dev/null || true)"
  if [[ -n "$p" && -f "$p" && -x "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi
  return 1
}

toolbox_launcher_choice_save() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 1
  local f dir
  f="$(toolbox_launcher_cfg_path)"
  dir="$(dirname "$f")"

  mkdir -p -- "$dir" 2>/dev/null || true
  printf '%s\n' "$p" >"$f" 2>/dev/null || true
  chmod 600 "$f" 2>/dev/null || true
  # Defensive safety net: this file must stay owned by the *invoking* user.
  # (DaST may sudo-reexec; we still want user settings to persist and remain readable.)
  local inv_user inv_group
  inv_user="$(__dast_toolbox_real_user)"
  inv_group="$(id -gn "$inv_user" 2>/dev/null || echo "$inv_user")"

  if [[ -n "$inv_user" && "$inv_user" != "root" ]]; then
    chown "$inv_user:$inv_group" "$f" 2>/dev/null || true
    chmod 644 "$f" 2>/dev/null || true
  fi
  return 0
}

toolbox_list_launcher_candidates() {
  local root="${1:-}"
  [[ -n "$root" && -d "$root" ]] || return 1

  # Conservative hand-picked candidates first (most common layouts).
  local cand
  for cand in \
    "$root/dast" \
    "$root/dast.sh" \
    "$root/bin/dast" \
    "$root/bin/dast.sh" \
    "$root/scripts/dast" \
    "$root/scripts/dast.sh"; do
    if [[ -f "$cand" && -x "$cand" ]]; then
      printf '%s\n' "$cand"
    fi
  done

  # Then a constrained search (avoid expensive or risky patterns).
  # Note: sort -u for stable display.
  find "$root" -maxdepth 3 -type f \
    \( -iname 'dast' -o -iname 'dast.sh' -o -iname 'dast-*' -o -iname 'dast_*.sh' \) \
    -perm -u+x 2>/dev/null | sort -u
}

toolbox_pick_dast_entrypoint() {
  # 1) Prefer persisted choice (if still valid)
  local saved=""
  saved="$(toolbox_launcher_choice_load || true)"
  if [[ -n "$saved" ]]; then
    printf '%s\n' "$saved"
    return 0
  fi

  # 2) Discover near current DaST root
  local root
  root="$(toolbox_current_dast_root 2>/dev/null || true)"
  [[ -n "$root" ]] || return 1

  local cands
  cands="$(toolbox_list_launcher_candidates "$root" 2>/dev/null || true)"

  # Normalise to unique non-empty lines
  local arr=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && arr+=("$line")
  done <<<"$cands"

  if [[ "${#arr[@]}" -eq 1 ]]; then
    toolbox_launcher_choice_save "${arr[0]}" || true
    printf '%s\n' "${arr[0]}"
    return 0
  fi

  if [[ "${#arr[@]}" -gt 1 ]]; then
    # Prompt user to choose. Build ui_menu args as tag/desc pairs.
    local menu_args=()
    local i=1
    local p
    for p in "${arr[@]}"; do
      menu_args+=("$i" "$p")
      i=$((i + 1))
    done

    local pick
    pick="$(ui_menu "🔗 DaST shortcut" "Multiple DaST launchers were found. Choose the one this shortcut should run:" "${menu_args[@]}")" || return 1
    [[ -n "$pick" ]] || return 1

    local idx=$((pick - 1))
    if [[ "$idx" -ge 0 && "$idx" -lt "${#arr[@]}" ]]; then
      toolbox_launcher_choice_save "${arr[$idx]}" || true
      printf '%s\n' "${arr[$idx]}"
      return 0
    fi
  fi

  return 1
}

# Determine if a resolved target is under the current DaST root.
toolbox_target_is_under_current_root() {
  local target="${1:-}"
  [[ -n "$target" ]] || return 1

  local root
  root="$(toolbox_current_dast_root 2>/dev/null || true)"
  [[ -n "$root" ]] || return 1

  # Ensure trailing slash semantics for prefix match.
  case "$target" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# Report current 'dast' shortcut status.
# Outputs 4 lines:
#   found(0/1)
#   path (or empty)
#   realpath (or empty)
#   is_ours(0/1)
toolbox_dast_shortcut_status() {
  local p=""
  local rp=""
  local ours="0"

  if command -v dast >/dev/null 2>&1; then
    p="$(command -v dast 2>/dev/null || true)"
    if [[ -n "$p" ]]; then
      rp="$(readlink -f "$p" 2>/dev/null || true)"

      # If /usr/local/bin/dast is a wrapper script (not a symlink), extract the real entry.
      # This prevents DaST from mis-identifying the install and also makes status accurate.
      if [[ "$p" == "/usr/local/bin/dast" && -f "$p" && ! -L "$p" ]]; then
        local _t=""
        _t="$(grep -E '^[[:space:]]*DAST_ENTRY=' "$p" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*DAST_ENTRY=//')"
        _t="${_t%\"}"; _t="${_t#\"}"
        _t="${_t%\'}"; _t="${_t#\'}"
        if [[ -n "$_t" ]]; then
          rp="$(readlink -f -- "$_t" 2>/dev/null || printf '%s' "$_t")"
        fi
      fi
    fi
  fi

  # "Ours" means:
  # - The resolved target is under the current running DaST root, OR
  # - It matches our persisted launcher choice.
  if [[ -n "$rp" ]]; then
    if toolbox_target_is_under_current_root "$rp"; then
      ours="1"
    else
      local saved=""
      saved="$(toolbox_launcher_choice_load || true)"
      if [[ -n "$saved" && "$rp" == "$saved" ]]; then
        ours="1"
      fi
    fi
  fi

  if [[ -n "$p" ]]; then
    printf '1 %s %s %s\n' "$p" "$rp" "$ours"
  else
    printf '0 "" "" 0\n'
  fi
}



toolbox_manage_dast_shortcut() {
  local found p rp ours rc
  local root launcher

  # Build a tight, TTY-clean status header for the menu (ASCII only).
  local status_label cmd_path sh_dir
  local menu_hdr

  while true; do
    read -r found p rp ours < <(toolbox_dast_shortcut_status)

    root="$(toolbox_current_dast_root 2>/dev/null || true)"
    launcher="$(toolbox_pick_dast_entrypoint 2>/dev/null || true)"

    status_label="Not installed"
    cmd_path="not found"
    sh_dir="<unknown>"

    if [[ "$found" == "1" && -n "$p" ]]; then
      cmd_path="$p"
      if [[ "$ours" == "1" ]]; then
        status_label="Installed"
      else
        status_label="Foreign command"
      fi
    fi

    if [[ -n "$launcher" ]]; then
      local launcher_real
      launcher_real="$(readlink -f -- "$launcher" 2>/dev/null || true)"
      if [[ -n "$launcher_real" ]]; then
        sh_dir="$(dirname -- "$launcher_real" 2>/dev/null || true)"
      fi
    fi
    [[ -z "$sh_dir" ]] && sh_dir="<unknown>"

    menu_hdr=$'Status: '"$status_label"$'
Command: '"$cmd_path"$'
Sh dir: '"$sh_dir"$'

Choose an action:'
    local choice
    choice="$(ui_menu "🔗 Manage PATH integration" "$menu_hdr" \
      "INSTALL" "🔗 Install or update /usr/local/bin/dast" \
      "REMOVE"  "🧹 Remove 'dast' shortcut (safe locations only)" \
      "BACK"    "Back")" || return 0

    case "$choice" in
      INSTALL)
        # If it's already installed (and ours), don't run install again.
        # Just inform the user and return to this menu.
        if [[ "$found" == "1" && -n "$p" && "$p" == "/usr/local/bin/dast" && "$ours" == "1" ]]; then
          ui_msg "✅ DaST shortcut" "Already installed.\n\nThe 'dast' shortcut is already installed and points at this DaST instance:\n\n$p -> ${rp:-<unknown>}"
          continue
        fi
        set +e
        toolbox_install_dast_shortcut
        rc=$?
        set -e
        if [[ "$rc" -eq 2 ]]; then
          continue
        fi
        hash -r 2>/dev/null || true
        ;;
      REMOVE)
        # If it's not installed, don't run remove.
        # Just inform the user and return to this menu.
        if [[ "$found" != "1" || -z "$p" ]]; then
          ui_msg "🧹 Remove DaST shortcut" "No 'dast' command is currently installed on your PATH."
          continue
        fi
        set +e
        toolbox_remove_dast_shortcut
        rc=$?
        set -e
        if [[ "$rc" -eq 2 ]]; then
          continue
        fi
        hash -r 2>/dev/null || true
        ;;
      BACK)
        return 0
        ;;
    esac
  done
}

toolbox_install_dast_shortcut() {
  local found p rp ours
  read -r found p rp ours < <(toolbox_dast_shortcut_status)

  # Do not overwrite a non-/usr/local/bin/dast command.
  if [[ "$found" == "1" && -n "$p" && "$p" != "/usr/local/bin/dast" ]]; then
    ui_msg "🔗 DaST shortcut" "A 'dast' command already exists on your PATH, but it is NOT /usr/local/bin/dast:

$p

For safety, DaST will not overwrite this.

Use the 'Remove existing' option in this menu (if appropriate), or adjust your PATH."
    return 0
  fi


  # If already installed and pointing at this instance, inform and return.
  # IMPORTANT: Do not return non-zero here under errexit, or DaST can drop out to terminal.
  if [[ "$found" == "1" && -n "$p" && "$p" == "/usr/local/bin/dast" && "$ours" == "1" ]]; then
    ui_msg "✅ DaST shortcut" "The 'dast' shortcut is already installed and points at this DaST instance:

$p -> ${rp:-<unknown>}"
    return 0
  fi

  local sudo_cmd=""
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      set +e
      ui_msg "🔗 DaST shortcut" "This installs a system shortcut at /usr/local/bin/dast.

Sudo is required but not available on this system."
      set -e
      return 0
    fi
    sudo_cmd="sudo"
  fi

  local entry
  entry="$(toolbox_pick_dast_entrypoint || true)"
  if [[ -z "$entry" ]]; then
    ui_msg "🔗 DaST shortcut" "Couldn't find a runnable DaST launcher near the current DaST instance.

Tip: Ensure the main DaST launcher file is executable, then try again."
    return 0
  fi

  if ! ui_yesno "🔗 DaST shortcut" "Create/update /usr/local/bin/dast to point to:

$entry

Proceed?"; then
    return 0
  fi
  # We deliberately install a small wrapper script rather than a symlink.
  # Reason: if /usr/local/bin/dast is a symlink, many scripts that use BASH_SOURCE[0]
  # (or SCRIPT_DIR based on it) will think the DaST root is /usr/local/bin, causing:
  # - logs to go under /usr/local/bin/logs
  # - libs/modules to fail to source (command not found)
  #
  # The wrapper exports DAST_APP_DIR so the real launcher can locate its tree correctly.
  local root entry_real
  root="$(toolbox_current_dast_root 2>/dev/null || true)"
  entry_real="$(readlink -f -- "$entry" 2>/dev/null || printf '%s' "$entry")"
  [[ -n "$root" ]] || root="$(dirname -- "$entry_real" 2>/dev/null || true)"

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
#!/usr/bin/env bash
# Generated by DaST Toolbox: PATH integration wrapper (do not edit by hand)
# This wrapper exists so the DaST launcher can resolve its real root when invoked via PATH.
DAST_ENTRY="$entry_real"
export DAST_APP_DIR="$root"
exec "\$DAST_ENTRY" "\$@"
EOF

  local _rc
  set +e
  $sudo_cmd install -m 0755 -- "$tmp" /usr/local/bin/dast 2>/dev/null
  _rc=$?
  rm -f -- "$tmp" 2>/dev/null || true
  set -e

if [[ $_rc -ne 0 ]]; then
    ui_msg "🔗 DaST shortcut" "❌ Failed to create/update symlink (rc=$_rc).

Target: $entry
Link:   /usr/local/bin/dast"
    return 0
  fi

  ui_msg "🔗 DaST shortcut" "✅ Installed.

/usr/local/bin/dast wrapper -> $entry_real"
  return 0
}


toolbox_remove_dast_shortcut() {
  local found p rp ours
  read -r found p rp ours < <(toolbox_dast_shortcut_status)

  if [[ "$found" != "1" || -z "$p" ]]; then
    ui_msg "🧹 Remove 'dast'" "No 'dast' command was found on your PATH."
    return 2
  fi

  local why_block=""
  local needs_root="0"
  local removable="0"

  case "$p" in
    "$HOME/.local/bin/dast" | "$HOME/bin/dast")
      removable="1"
      ;;
    "/usr/local/bin/dast")
      removable="1"
      needs_root="1"
      ;;
    "/usr/bin/dast" | "/bin/dast" | "/sbin/dast" | "/usr/sbin/dast")
      why_block="This appears to be a system-managed binary:
$p

DaST will not remove it."
      ;;
    *)
      why_block="This 'dast' is in an unexpected location:
$p

For safety, DaST will not remove it."
      ;;
  esac

  if [[ -n "$why_block" || "$removable" != "1" ]]; then
    ui_msg "🧹 Remove 'dast'" "$why_block"
    return 0
  fi

  local sudo_cmd=""
  if [[ "$needs_root" == "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      set +e
      ui_msg "🧹 Remove 'dast'" "This 'dast' shortcut is in /usr/local/bin and needs sudo to remove:

$p

Sudo is required but not available on this system."
      set -e
      return 0
    fi
    sudo_cmd="sudo"
  fi

  # Extra safety: if it isn't "ours", call it out.
  local warn=""
  if [[ "$ours" != "1" ]]; then
    warn="⚠ Note: This 'dast' does not appear to point at the current DaST instance.

"
  fi

  if ! ui_yesno "🧹 Remove 'dast'" "${warn}Remove this shortcut?

$p"; then
    return 0
  fi

  local _rc
  set +e
  $sudo_cmd rm -f -- "$p" 2>/dev/null
  _rc=$?
  set -e
  if [[ $_rc -ne 0 ]]; then
    ui_msg "🧹 Remove 'dast'" "❌ Failed to remove (rc=$_rc).

Path: $p"
    return 0
  fi

  ui_msg "🧹 Remove 'dast'" "✅ Removed.

Path: $p"
  return 0
}

# --- END DaST Toolbox PATH Shortcut Helpers ---




module_DAST_TOOLBOX() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  while true; do
    local action
    action="$(tools_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0
    tools_run "$action"
  done
}

register_module "$module_id" "$module_title" "module_DAST_TOOLBOX"

# UI title sanitisation toggle

# --- BEGIN DaST Toolbox Emoji Enable Flow (SAFE / ADDITIVE) ---

# Helper: detect KDE Neon (instructions-only)
is_kde_neon() {
    [ -r /etc/os-release ] && grep -qi '^NAME=.*neon' /etc/os-release
}

# Guarded emoji enable flow to respect capability and distro rules
dast_toolbox_handle_emoji_toggle() {
    cfg_ensure_exists
    cfg_load

    # Preference is what is stored in config, not the current runtime effective state.
    local pref=""
    if [ -f "$CFG_FILE" ]; then
        pref="$(grep -E '^UI_EMOJI=' "$CFG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2)"
    fi
    pref="${pref:-${UI_EMOJI:-0}}"

    # If preference is ON, this action is treated as "turn preference OFF".
    if [ "$pref" = "1" ]; then
        if [ "${UI_EMOJI_FORCED_OFF:-0}" = "1" ]; then
            local reason="${UI_EMOJI_FORCED_REASON:-UNKNOWN}"
            local why="Unknown reason"
            case "$reason" in
                HOSTILE_ENV)   why="Hostile environment (TTY/TERM/dumb or forced off)" ;;
                NO_EMOJI_FONT) why="Emoji font not detected" ;;
            esac

            if ask_yes_no "Emoji preference is currently ON, but DaST is forcing emoji OFF at runtime.

Reason: $why

Do you want to turn emoji preference OFF in config?"; then
                cfg_set_kv "UI_EMOJI" 0
                cfg_load
            fi
            return
        fi

        cfg_set_kv "UI_EMOJI" 0
        cfg_load
        return
    fi

    # Enabling emoji is refused in hostile environments (runtime safety gate).
    if ui_env_is_hostile_for_emoji; then
        dast_msgbox "Emoji cannot be enabled right now.

DaST detected a hostile environment (TTY/TERM=dumb or similar), so emoji are forced OFF at runtime.

You can enable emoji later from a normal terminal or UI. DaST works correctly without emoji."
        return
    fi

    # Refresh capability facts and enable if supported.
    ui_detect_emoji_capability
    if [ "${UI_EMOJI_CAPABLE:-0}" = "1" ]; then
        cfg_set_kv "UI_EMOJI" 1
        cfg_load
        return
    fi

    # No emoji font detected. Distro rules apply.
    if is_kde_neon; then
        dast_msgbox "Emoji font not detected.

Recommended font: Noto Color Emoji

KDE Neon discourages direct package installation via apt.
Please install the font using a method appropriate for your system.

DaST will continue to function correctly without emoji."
        return
    fi

    if ask_yes_no "Emoji font not detected.

Recommended font: Noto Color Emoji

DaST works correctly without emoji.
Would you like to install the font now?"; then
        if command -v apt-get >/dev/null 2>&1; then
            dast_install_pkg "fonts-noto-color-emoji"
            ui_detect_emoji_capability
            if [ "${UI_EMOJI_CAPABLE:-0}" = "1" ]; then
                cfg_set_kv "UI_EMOJI" 1
                cfg_load
            fi
        else
            dast_msgbox "Please install 'fonts-noto-color-emoji' using your system's package manager."
        fi
    fi
}

# --- END DaST Toolbox Emoji Enable Flow ---
