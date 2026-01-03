#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: ZFS (v0.9.8.4)
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

module_id="ZFS"
module_title="💾 ZFS management"
MODULESPEC_TITLE="💾 ZFS management"

# -----------------------------------------------------------------------------
# DaST shared helper (run/run_capture/mktemp_safe)
# -----------------------------------------------------------------------------
# This module is ZFS-critical: we keep behaviour identical and only add
# best-effort helper loading so DaST v0.6 can standardise logging/exec helpers.
__zfs_try_source_helper() {
  # If run() already exists, we're good.
  declare -F run >/dev/null 2>&1 && return 0

  local here lib_try

  # 1) If DaST defines a lib dir, use it.
  if [[ -n "${DAST_LIB_DIR:-}" && -r "${DAST_LIB_DIR}/dast_helper.sh" ]]; then
    # shellcheck source=/dev/null
    source "${DAST_LIB_DIR}/dast_helper.sh" && return 0
  fi

  # 2) Try relative to this module file.
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
  if [[ -n "$here" ]]; then
    for lib_try in \
      "$here/../lib/dast_helper.sh" \
      "$here/lib/dast_helper.sh" \
      "$here/../../lib/dast_helper.sh"
    do
      if [[ -r "$lib_try" ]]; then
        # shellcheck source=/dev/null
        source "$lib_try" && return 0
      fi
    done
  fi

  return 1
}

__ZFS_HELPER_OK=0
if __zfs_try_source_helper >/dev/null 2>&1; then
  __ZFS_HELPER_OK=1
fi

# Logging wrappers (DaST main provides dast_log/dast_dbg and enforces app dirs).
__zfs_log() {
  declare -F dast_log >/dev/null 2>&1 || return 0
  dast_log "$@"
}

__zfs_dbg() {
  declare -F dast_dbg >/dev/null 2>&1 || return 0
  dast_dbg "$*"
}

if [[ "$__ZFS_HELPER_OK" -ne 1 ]]; then
  __zfs_log "WARN" "ZFS module: dast_helper.sh not loaded; using safe stubs (run/run_capture/mktemp_safe)."
fi

# Safe stubs if helper wasn't loaded (keeps module source-time safe).
if ! declare -F run >/dev/null 2>&1; then
  run() { "$@"; }
fi
if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { "$@"; }
fi
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

# -----------------------------------------------------------------------------
# OS detection
# -----------------------------------------------------------------------------
__zfs_is_supported_os() {
  # ZFS module supports Ubuntu and Ubuntu-derivatives with zfsutils-linux
  local id id_like
  . /etc/os-release 2>/dev/null || return 1
  id="${ID:-}"
  id_like="${ID_LIKE:-}"

  [[ "$id" == "ubuntu" ]] && return 0
  [[ "$id" == "debian" ]] && return 1
  [[ "$id_like" == *"ubuntu"* ]] && return 0

  return 1
}

__zfs_os_info() {
  local id codename pretty
  id="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
  codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
  pretty="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")"

  if [[ "$id" == "ubuntu" ]]; then
    if [[ -n "$codename" ]]; then
      echo "ubuntu ($codename)"
    else
      echo "ubuntu"
    fi
  else
    # If this ever shows, we didn't register on that OS.
    echo "${pretty:-$id}"
  fi
}

__zfs_have() { command -v "$1" >/dev/null 2>&1; }

__zfs_installed() { __zfs_have zpool && __zfs_have zfs; }

__zfs_require_installed() {
  if __zfs_installed; then
    return 0
  fi
  ui_msg "$MODULESPEC_TITLE" "❌ ZFS tools not found (zpool/zfs).\n\nInstall:\n  sudo apt-get update\n  sudo apt-get install -y zfsutils-linux\n\nThen rerun DaST."
  return 1
}

__zfs_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

__zfs_require_root() {
  if __zfs_is_root; then
    return 0
  fi
  ui_msg "$MODULESPEC_TITLE" "❌ Root required.\n\nRe-run DaST with sudo for this action."
  return 1
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
__zfs_yesno_default_no() {
  # shellcheck disable=SC2034
  local title="$1" msg="$2"
  ui_confirm "$title" "$msg"
}

__zfs_input_default() {
  local title="$1" msg="$2" def="$3"
  ui_inputbox "$title" "$msg" "$def"
}

__zfs_programbox() {
  local title="$1"
  local cmd="$2"
  ui_programbox "$title" "$cmd"
}

__zfs_textbox_from_cmd() {
  local title="$1" cmd="$2"
  ui_programbox "$title" "$cmd"
}

__zfs_danger_gate() {
  local title="$1" msg="$2"
  ui_confirm "$title" "$msg"
}

# -----------------------------------------------------------------------------
# Pickers
# -----------------------------------------------------------------------------
__zfs_pick_pool() {
  local opts=() p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    opts+=("$p" "")
  done < <(zpool list -H -o name 2>/dev/null || true)

  if [[ ${#opts[@]} -eq 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "📄 No pools found."
    return 1
  fi

  ui_menu "$MODULESPEC_TITLE" "Select a pool:" "${opts[@]}"
}

__zfs_pick_importable_pool() {
  local opts=() line p
  while IFS= read -r line; do
    [[ "$line" =~ pool:\ (.*)$ ]] || continue
    p="${BASH_REMATCH[1]}"
    [[ -z "$p" ]] && continue
    opts+=("$p" "")
  done < <(zpool import 2>/dev/null || true)

  if [[ ${#opts[@]} -eq 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "📄 No importable pools found.\n\n(zpool import returned nothing.)"
    return 1
  fi

  ui_menu "$MODULESPEC_TITLE" "Select an importable pool:" "${opts[@]}"
}

__zfs_pick_dataset() {
  local opts=() ds
  while IFS= read -r ds; do
    [[ -z "$ds" ]] && continue
    opts+=("$ds" "")
  done < <(zfs list -H -o name -t filesystem,volume 2>/dev/null || true)

  if [[ ${#opts[@]} -eq 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "📄 No datasets found."
    return 1
  fi

  ui_menu "$MODULESPEC_TITLE" "Select a dataset:" "${opts[@]}"
}

__zfs_pick_snapshot_for_dataset() {
  local ds="$1"
  local opts=() snap
  while IFS= read -r snap; do
    [[ -z "$snap" ]] && continue
    opts+=("$snap" "")
  done < <(zfs list -t snapshot -H -o name -s creation -d 1 -- "$ds" 2>/dev/null || true)

  if [[ ${#opts[@]} -eq 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "📄 No snapshots found for:\n$ds"
    return 1
  fi

  ui_menu "$MODULESPEC_TITLE" "Select a snapshot for:\n$ds" "${opts[@]}"
}

# -----------------------------------------------------------------------------
# Info / Health
# -----------------------------------------------------------------------------
zfs_action_list() {
  __zfs_require_installed || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== zpool list ==='; zpool list; echo; echo '=== zfs list ==='; zfs list"
}


# Backward-compat: older menus call this name
zfs_action_pool_details() {
  # Pool details historically mapped to a combined status/properties view.
  # Keep behaviour stable by delegating to the existing implementation.
  zfs_action_pool_status
}

zfs_action_pool_status() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0

  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== zpool status -v $pool ==='; zpool status -v -- '$pool'; \
     echo; echo '=== zpool get (useful) ==='; \
     zpool get -H -o property,value ashift,autotrim,autoexpand,capacity,comment,delegation,failmode,feature@,listsnapshots,autoreplace -- '$pool' 2>/dev/null || true; \
     echo; echo '=== zpool get all (trimmed) ==='; zpool get -H -o property,value all -- '$pool' | sed -n '1,220p'"
}


# --- Health shortcuts (menu HX/HV) ---
# DaST v0.7 health menu expects these handlers. They are non-destructive and
# simply render the current pool health summary/verbose output.
zfs_action_health_x() {
  __zfs_require_installed || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== zpool status -x ==='; zpool status -x 2>/dev/null || true; \
     echo; echo '=== zpool status -v ==='; zpool status -v 2>/dev/null || true"
}

zfs_action_health_v() {
  __zfs_require_installed || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== zpool status -v ==='; zpool status -v 2>/dev/null || true"
}


zfs_action_dataset_status() {
  __zfs_require_installed || return 0
  local ds
  ds="$(__zfs_pick_dataset)" || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== zfs list (details) $ds ==='; zfs list -o name,used,avail,refer,mountpoint,compressratio,logicalused,logicalrefer -- '$ds' 2>/dev/null || true; \
     echo; echo '=== key props (local/default/inherited) ==='; \
     zfs get -o name,property,value -s local,default,inherited -r \
       mountpoint,canmount,compression,recordsize,atime,xattr,acltype,aclmode,aclinherit,casesensitivity,utf8only,normalization,dnodesize,primarycache,secondarycache,quota,refquota,reservation,refreservation \
       -- '$ds' 2>/dev/null || true"
}

zfs_action_events() { __zfs_require_installed || return 0; __zfs_programbox "$MODULESPEC_TITLE" "zpool events -v 2>/dev/null || zpool events 2>/dev/null || true"; }

# -----------------------------------------------------------------------------
# History (interactive / cautious)
# -----------------------------------------------------------------------------
zfs_action_history() {
  __zfs_require_installed || return 0

  local pool max_lines mode timeout_secs has_timeout
  local tmp raw cmd_rc tail_rc
  local choice custom_timeout
  local old_trap_int

  pool="$(__zfs_pick_pool)" || return 0

  max_lines=1000
  timeout_secs=300

  tmp="$(mktemp -t dast-zpool-history.XXXXXX 2>/dev/null || mktemp "/tmp/dast-zpool-history.XXXXXX")"
  raw="${tmp}.raw"

  # --- Mode picker (default = recommended 300s) ---
  choice="$(
    ui_menu "$MODULESPEC_TITLE" \
      "Depending on the size of the pool and its activity, this operation can take some time.

If you proceed, the history will first be captured to a temporary file and then displayed here.

A timeout prevents the UI/TTY from hanging. If you see error 124, it simply means you need to wait longer.

Choose how to proceed:" \
      "T300" "Proceed (300s timeout, recommended)" \
      "TCUST" "Proceed (custom timeout)" \
      "FOREVER" "Proceed (no timeout, may take a long time)" \
      "BACK" "🔙️ Back"
  )" || { rm -f "$tmp" "$raw" 2>/dev/null || true; return 0; }

  case "$choice" in
    T300) mode="timeout"; timeout_secs=300 ;;
    TCUST)
      custom_timeout="$(
        __zfs_input_default "$MODULESPEC_TITLE" \
          "Enter timeout seconds (numbers only).

- Recommended: 300
- Use 0 for 'no timeout' (same as the forever option)." \
          "$timeout_secs"
      )" || { rm -f "$tmp" "$raw" 2>/dev/null || true; return 0; }

      # Trim spaces; basic numeric validation.
      custom_timeout="${custom_timeout//[[:space:]]/}"
      if [[ -z "$custom_timeout" ]]; then
        rm -f "$tmp" "$raw" 2>/dev/null || true
        return 0
      fi
      if [[ "$custom_timeout" =~ ^[0-9]+$ ]]; then
        if [[ "$custom_timeout" -eq 0 ]]; then
          mode="forever"
        else
          mode="timeout"
          timeout_secs="$custom_timeout"
        fi
      else
        ui_msg "$MODULESPEC_TITLE" "❌ Invalid timeout value.\n\nMust be a number."
        rm -f "$tmp" "$raw" 2>/dev/null || true
        return 0
      fi
      ;;
    FOREVER) mode="forever" ;;
    *) rm -f "$tmp" "$raw" 2>/dev/null || true; return 0 ;;
  esac

  # Determine if timeout exists
  has_timeout=0
  if __zfs_have timeout; then
    has_timeout=1
  fi

  # Preserve INT trap if any, but keep behaviour as-is.
  old_trap_int="$(trap -p INT 2>/dev/null || true)"

  (
    # Within subshell: allow cleanup on INT
    trap 'rm -f "$tmp" "$raw" 2>/dev/null || true; exit 130' INT

    if [[ "$mode" == "timeout" && "$has_timeout" -eq 1 ]]; then
      timeout "${timeout_secs}" zpool history -il -- "$pool" >"$raw" 2>"$tmp"
      cmd_rc=$?
    else
      zpool history -il -- "$pool" >"$raw" 2>"$tmp"
      cmd_rc=$?
    fi

    if [[ "$cmd_rc" -ne 0 ]]; then
      echo "Command returned rc=$cmd_rc" >>"$tmp"
      echo >>"$tmp"
      echo "stderr:" >>"$tmp"
      cat "$tmp" >>"$tmp" 2>/dev/null || true
      exit "$cmd_rc"
    fi

    tail -n "$max_lines" "$raw" >"$tmp" 2>/dev/null || {
      tail_rc=$?
      echo "tail failed rc=$tail_rc" >>"$tmp"
      exit "$tail_rc"
    }

    ui_textbox "$MODULESPEC_TITLE" "$tmp"
  )
  cmd_rc=$?

  # Restore INT trap (best effort)
  if [[ -n "$old_trap_int" ]]; then
    eval "$old_trap_int" 2>/dev/null || true
  else
    trap - INT 2>/dev/null || true
  fi

  rm -f "$tmp" "$raw" 2>/dev/null || true

  if [[ "$cmd_rc" -eq 124 ]]; then
    ui_msg "$MODULESPEC_TITLE" "📄 Timeout reached.\n\nTry a higher timeout or the 'forever' option."
  fi
}
zfs_action_versions() {
  __zfs_require_installed || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== zfs version ==='; zfs version 2>/dev/null || true; \
     echo; echo '=== zpool version ==='; zpool version 2>/dev/null || true; \
     echo; echo '=== module ==='; (lsmod | grep -E '^zfs\\b' || echo 'zfs module not listed in lsmod'); \
     echo; echo '=== mounts ==='; mount | grep -E ' type zfs ' || echo 'No ZFS mounts detected'"
}

zfs_action_arc_stats() {
  __zfs_require_installed || return 0
  if __zfs_have arcstat; then
    __zfs_programbox "$MODULESPEC_TITLE" "arcstat 1 10 2>/dev/null || true"
    return 0
  fi
  if [[ -r /proc/spl/kstat/zfs/arcstats ]]; then
    __zfs_programbox "$MODULESPEC_TITLE" \
      "echo '=== /proc/spl/kstat/zfs/arcstats (selected) ==='; \
       awk 'NR==1{next} {print}' /proc/spl/kstat/zfs/arcstats | awk '($1 ~ /^(size|c|c_min|c_max|hits|misses|demand_data_hits|demand_data_misses|prefetch_data_hits|prefetch_data_misses)$/){print}'"
    return 0
  fi
  ui_msg "$MODULESPEC_TITLE" "📄 ARC stats not available.\n\nIf you want arcstat, install the package that provides it on your distro."
}


zfs_action_arc_summary() {
  __zfs_require_installed || return 0

  if __zfs_have arc_summary; then
    __zfs_programbox "$MODULESPEC_TITLE" "arc_summary 2>/dev/null || true"
    return 0
  fi

  # Common locations for OpenZFS helper scripts
  local py=""
  for py in     /usr/share/zfs/arc_summary.py     /usr/lib/zfs/arc_summary.py     /usr/share/zfs-linux/arc_summary.py     /usr/libexec/zfs/arc_summary.py
  do
    [[ -r "$py" ]] && break
    py=""
  done

  if [[ -n "$py" ]]; then
    if __zfs_have python3; then
      __zfs_programbox "$MODULESPEC_TITLE" "python3 '$py' 2>/dev/null || true"
      return 0
    elif __zfs_have python; then
      __zfs_programbox "$MODULESPEC_TITLE" "python '$py' 2>/dev/null || true"
      return 0
    fi
  fi

  ui_msg "$MODULESPEC_TITLE"     "📄 ARC summary helper not found.

If you want arc_summary, install the OpenZFS helper scripts for your distro."
}

zfs_action_dataset_properties_full() {
  __zfs_require_installed || return 0
  local ds
  ds="$(__zfs_pick_dataset)" || return 0
  __zfs_programbox "$MODULESPEC_TITLE"     "echo '=== zfs get all (trimmed) ===';      zfs get -H -o name,property,value,source all -- '$ds' 2>/dev/null | sed -n '1,260p';      echo; echo '(Tip: properties shown are trimmed to keep the UI readable.)'"
}

zfs_action_pool_properties_full() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0
  __zfs_programbox "$MODULESPEC_TITLE"     "echo '=== zpool get all (trimmed) ===';      zpool get -H -o name,property,value,source all -- '$pool' 2>/dev/null | sed -n '1,260p';      echo; echo '(Tip: properties shown are trimmed to keep the UI readable.)'"
}

zfs_action_space_hogs() {
  __zfs_require_installed || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== Top datasets by USED ==='; \
     zfs list -H -o name,used,avail,refer,mountpoint -S used 2>/dev/null | head -n 40 | column -t; \
     echo; echo '=== Top snapshots by USED ==='; \
     zfs list -t snapshot -H -o name,used,refer -S used 2>/dev/null | head -n 60 | column -t || true"
}

# -----------------------------------------------------------------------------
# Maintenance (state changing)
# -----------------------------------------------------------------------------
zfs_action_scrub_start() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "🧼 Start scrub on pool:\n\n$pool\n\nProceed?" || return 0
  __zfs_programbox "$MODULESPEC_TITLE" "zpool scrub -- '$pool'; echo; zpool status -- '$pool'"
}

zfs_action_scrub_stop() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0
  __zfs_danger_gate "$MODULESPEC_TITLE" "Stop scrub on pool:\n\n$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "zpool scrub -s -- '$pool'; echo; zpool status -- '$pool'"
}

zfs_action_scrub_status() { __zfs_require_installed || return 0; __zfs_programbox "$MODULESPEC_TITLE" "zpool status"; }

zfs_action_trim_start() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0
  __zfs_danger_gate "$MODULESPEC_TITLE" "Start TRIM on pool:\n\n$pool\n\nOnly do this on SSD/NVMe pools." || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm TRIM start:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "zpool trim -- '$pool'; echo; zpool status -- '$pool'"
}

zfs_action_trim_stop() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0
  __zfs_danger_gate "$MODULESPEC_TITLE" "Stop TRIM on pool:\n\n$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm TRIM stop:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "zpool trim -s -- '$pool'; echo; zpool status -- '$pool'"
}

# -----------------------------------------------------------------------------
# Import / Export (basic)
# -----------------------------------------------------------------------------
zfs_action_import_show() { __zfs_require_installed || return 0; __zfs_programbox "$MODULESPEC_TITLE" "if [ -d /dev/disk/by-id ]; then zpool import -d /dev/disk/by-id 2>/dev/null || true; else zpool import 2>/dev/null || true; fi"; }

zfs_action_import_pool_basic() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_importable_pool)" || return 0
  __zfs_danger_gate "$MODULESPEC_TITLE" "Import pool:\n\n$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm import:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "if [ -d /dev/disk/by-id ]; then zpool import -d /dev/disk/by-id -- \'$pool\'; else zpool import -- \'$pool\'; fi; echo; zpool status -v -- \'$pool\'"
}

zfs_action_export_pool() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0
  __zfs_danger_gate "$MODULESPEC_TITLE" "Export pool:\n\n$pool\n\nThis unmounts datasets and makes it unavailable until imported again." || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm export:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "zpool export -- '$pool'; echo; zpool list || true"
}

# -----------------------------------------------------------------------------
# Import (advanced options)
# -----------------------------------------------------------------------------
zfs_action_import_pool_advanced() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_importable_pool)" || return 0

  ui_msg "$MODULESPEC_TITLE" "📥 Advanced import\n\nYou will choose options next.\n\nPool:\n$pool"

  local readonly="off" force="off" nomount="off" altroot=""
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "Import readonly?\n\nYes = -o readonly=on" && readonly="on" || readonly="off"
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "Force import?\n\nYes = -f\nOnly if you know why." && force="on" || force="off"
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "Do not mount datasets?\n\nYes = -N" && nomount="on" || nomount="off"

  __zfs_yesno_default_no "$MODULESPEC_TITLE" "Use altroot?\n\nYes = import with -R <path>\nUseful for recovery." && {
    altroot="$(ui_input "$MODULESPEC_TITLE" "Enter altroot path (example: /mnt/recovery):" "/mnt/recovery")" || return 0
    [[ -n "$altroot" ]] || altroot=""
  } || altroot=""

  local args=""
  [[ "$force" == "on" ]] && args+=" -f"
  [[ "$nomount" == "on" ]] && args+=" -N"
  [[ "$readonly" == "on" ]] && args+=" -o readonly=on"
  [[ -n "$altroot" ]] && args+=" -R '${altroot}'"

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "Advanced import will run:\n\nzpool import${args} -- '$pool'" \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm import:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "if [ -d /dev/disk/by-id ]; then zpool import -d /dev/disk/by-id${args} -- \'$pool\'; else zpool import${args} -- \'$pool\'; fi 2>&1 || true; echo; zpool status -v -- \'$pool\' 2>/dev/null || true"
}

# -----------------------------------------------------------------------------
# Snapshots
# -----------------------------------------------------------------------------
zfs_action_snap_list() {
  __zfs_require_installed || return 0
  local ds
  ds="$(__zfs_pick_dataset)" || return 0
  __zfs_programbox "$MODULESPEC_TITLE" \
    "echo '=== Snapshots for $ds ==='; \
     zfs list -t snapshot -H -o name,creation,used,refer -s creation -r -- '$ds' 2>/dev/null | awk -v d=\"$ds@\" '$1 ~ ("^" d) {print}' || true"
}

zfs_action_snap_create() {
  __zfs_require_installed || return 0
  local ds tag rec
  ds="$(__zfs_pick_dataset)" || return 0
  tag="$(ui_input "$MODULESPEC_TITLE" "📸 Create snapshot for:\n\n$ds\n\nEnter snapshot tag (A-Z a-z 0-9 . _ -):" "")" || return 0
  __zfs_valid_snap_tag "$tag" || { ui_msg "$MODULESPEC_TITLE" "❌ Invalid snapshot tag."; return 0; }
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "📸 Recursive snapshot?\n\nYes = include children (-r)\nNo = dataset only" && rec="1" || rec="0"

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "Create snapshot:\n\n${ds}@${tag}\n\nSnapshots are usually safe, but can increase space usage." \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type exactly to confirm:\n\n${ds}@${tag}" "${ds}@${tag}" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  if [[ "$rec" == "1" ]]; then
    __zfs_programbox "$MODULESPEC_TITLE" "zfs snapshot -r -- '${ds}@${tag}'; echo; zfs list -t snapshot -o name,creation -s creation | tail -n 30"
  else
    __zfs_programbox "$MODULESPEC_TITLE" "zfs snapshot -- '${ds}@${tag}'; echo; zfs list -t snapshot -o name,creation -s creation | tail -n 30"
  fi
}

zfs_action_snap_diff() {
  __zfs_require_installed || return 0
  local ds snap
  ds="$(__zfs_pick_dataset)" || return 0
  snap="$(__zfs_pick_snapshot_for_dataset "$ds")" || return 0
  __zfs_programbox "$MODULESPEC_TITLE" "zfs diff -- '$snap' '$ds' 2>/dev/null || true"
}
# -----------------------------------------------------------------------------
# Snapshot mount / unmount (safe read-only browsing)
# -----------------------------------------------------------------------------
__zfs_is_mountpoint_in_use() {
  local tgt="$1"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -rn --target "$tgt" >/dev/null 2>&1 && return 0 || return 1
  fi
  grep -qsE "[[:space:]]${tgt//\//\\/}[[:space:]]" /proc/mounts 2>/dev/null
}

__zfs_pick_mounted_snapshot_mount() {
  local -a items=()
  local src tgt root d
  declare -A mounted=()

  while read -r src tgt; do
    [[ -n "$src" && -n "$tgt" ]] || continue
    [[ "$src" == *"/.zfs/snapshot/"* ]] || continue
    mounted["$tgt"]=1
    items+=("MOUNTED|$tgt" "Mounted from: $src")
  done < <(awk '{print $1, $2}' /proc/mounts 2>/dev/null || true)

  # Also offer cleanup for stale mount directories under our default root.
  root="/mnt/zfs-snapshots"
  if [[ -d "$root" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      [[ -n "${mounted[$d]:-}" ]] && continue
      items+=("STALE|$d" "Stale dir (not mounted) - offer cleanup")
    done < <(find "$root" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | sort || true)
  fi

  if [[ ${#items[@]} -eq 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "📄 No mounted snapshot browse points detected.

(We look for bind mounts whose source contains /.zfs/snapshot/.)"
    return 1
  fi

  ui_menu "$MODULESPEC_TITLE" "Pick a mounted snapshot to unmount (or a stale dir to clean):" "${items[@]}"
}

zfs_action_snap_mount() {
  __zfs_require_installed || return 0

  local ds snap tag mp snap_path tgt default_tgt
  ds="$(__zfs_pick_dataset)" || return 0
  snap="$(__zfs_pick_snapshot_for_dataset "$ds")" || return 0
  tag="${snap#*@}"

  mp="$(zfs get -H -o value mountpoint -- "$ds" 2>/dev/null || echo "")"
  if [[ -z "$mp" || "$mp" == "none" || "$mp" == "legacy" ]]; then
    ui_msg "$MODULESPEC_TITLE" "❌ Cannot browse-mount snapshots for this dataset.\n\nDataset:\n$ds\n\nReason: mountpoint is '$mp'.\n\nTip: set a real mountpoint (and ensure it is mounted), then try again."
    return 0
  fi

  snap_path="${mp%/}/.zfs/snapshot/${tag}"
  if [[ ! -d "$snap_path" ]]; then
    ui_msg "$MODULESPEC_TITLE" "❌ Snapshot path not found on disk.\n\nExpected:\n$snap_path\n\nThis can happen if the dataset isn't mounted, or if .zfs snapshot access is disabled/hidden."
    return 0
  fi

  default_tgt="/mnt/zfs-snapshots/${ds//@/_}@${tag}"
  tgt="$(ui_input "$MODULESPEC_TITLE" "🗂️ Mount snapshot (read-only browse)\n\nSnapshot:\n$snap\n\nSource path:\n$snap_path\n\nEnter mount target directory:" "$default_tgt")" || return 0
  [[ -n "$tgt" ]] || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  if [[ "$tgt" != /* ]]; then
    ui_msg "$MODULESPEC_TITLE" "❌ Mount target must be an absolute path."
    return 0
  fi

  if __zfs_is_mountpoint_in_use "$tgt"; then
    ui_msg "$MODULESPEC_TITLE" "❌ That mount target is already in use:\n\n$tgt"
    return 0
  fi

  if [[ -e "$tgt" && ! -d "$tgt" ]]; then
    ui_msg "$MODULESPEC_TITLE" "❌ Target exists but is not a directory:\n\n$tgt"
    return 0
  fi

  __zfs_danger_gate "$MODULESPEC_TITLE" "Mount snapshot for browsing (read-only).\n\nSnapshot:\n$snap\n\nMount at:\n$tgt" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the snapshot name to confirm:\n\n$snap" "$snap" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" \
    "set -e
mkdir -p -- '$tgt'
echo 'Bind-mounting snapshot path:'
echo '  $snap_path'
echo 'To:'
echo '  $tgt'
echo
mount --bind -- '$snap_path' '$tgt'
# Remount read-only (best-effort; some kernels ignore ro on bind mounts)
mount -o remount,ro,bind -- '$tgt' 2>/dev/null || true
echo
echo 'Mounted. You can browse files now.'
echo
echo 'To unmount later, use: 🧹 Unmount snapshot'
" || true
}

zfs_action_snap_unmount() {
  __zfs_require_installed || return 0

  local sel kind tgt tmp
  sel="$(__zfs_pick_mounted_snapshot_mount)" || return 0
  kind="${sel%%|*}"
  tgt="${sel#*|}"

  if [[ "$kind" == "STALE" ]]; then
    __zfs_yesno_default_no "$MODULESPEC_TITLE" "🧹 Stale mount directory (not mounted):

$tgt

Remove this empty directory?" || return 0
    tmp="$(mktemp -t dast-zfs-rmdir.XXXXXX 2>/dev/null || mktemp "/tmp/dast-zfs-rmdir.XXXXXX")"
    if rmdir -- "$tgt" 2>"$tmp"; then
      rm -f "$tmp" 2>/dev/null || true
      ui_msg "$MODULESPEC_TITLE" "✅ Removed:

$tgt"
    else
      ui_textbox "$MODULESPEC_TITLE" "$tmp"
      rm -f "$tmp" 2>/dev/null || true
    fi
    return 0
  fi

  __zfs_danger_gate "$MODULESPEC_TITLE" "Unmount snapshot browse mount?

$tgt" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the mount target to confirm:

$tgt" "$tgt" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  tmp="$(mktemp -t dast-zfs-umount.XXXXXX 2>/dev/null || mktemp "/tmp/dast-zfs-umount.XXXXXX")"
  {
    echo "Unmounting: $tgt"
    echo
    umount -- "$tgt" 2>&1 || true
    echo
    if mountpoint -q "$tgt" 2>/dev/null; then
      echo "🚨 Still mounted."
    else
      echo "✅ Unmounted."
    fi
  } >"$tmp"
  ui_textbox "$MODULESPEC_TITLE" "$tmp"
  rm -f "$tmp" 2>/dev/null || true

  # Cleanup option: directory exists but is not mounted anymore.
  if [[ -d "$tgt" ]] && ! mountpoint -q "$tgt" 2>/dev/null; then
    __zfs_yesno_default_no "$MODULESPEC_TITLE" "🧹 Cleanup?

Directory exists but is not mounted:

$tgt

Remove if empty?" || return 0
    tmp="$(mktemp -t dast-zfs-rmdir.XXXXXX 2>/dev/null || mktemp "/tmp/dast-zfs-rmdir.XXXXXX")"
    if rmdir -- "$tgt" 2>"$tmp"; then
      rm -f "$tmp" 2>/dev/null || true
      ui_msg "$MODULESPEC_TITLE" "✅ Removed:

$tgt"
    else
      ui_textbox "$MODULESPEC_TITLE" "$tmp"
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
}

zfs_action_snap_rollback() {
  __zfs_require_installed || return 0
  local ds snap rec
  ds="$(__zfs_pick_dataset)" || return 0
  snap="$(__zfs_pick_snapshot_for_dataset "$ds")" || return 0
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "⏪ Rollback recursively?\n\nYes = include children (-r)\nNo = dataset only" && rec="1" || rec="0"

  __zfs_danger_gate "$MODULESPEC_TITLE" "ROLLBACK IS DESTRUCTIVE.\n\nSnapshot:\n$snap" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the snapshot name to confirm:\n\n$snap" "$snap" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  if [[ "$rec" == "1" ]]; then
    __zfs_programbox "$MODULESPEC_TITLE" "zfs rollback -r -- '$snap' 2>&1 || true; echo; zfs list -- '$ds' 2>/dev/null || true"
  else
    __zfs_programbox "$MODULESPEC_TITLE" "zfs rollback -- '$snap' 2>&1 || true; echo; zfs list -- '$ds' 2>/dev/null || true"
  fi
}

zfs_action_snap_destroy() {
  __zfs_require_installed || return 0
  local ds snap
  ds="$(__zfs_pick_dataset)" || return 0
  snap="$(__zfs_pick_snapshot_for_dataset "$ds")" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" "DESTROYING A SNAPSHOT IS DESTRUCTIVE.\n\nSnapshot:\n$snap" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the snapshot name to confirm destroy:\n\n$snap" "$snap" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zfs destroy -- '$snap' 2>&1 || true; echo; echo 'Done.'"
}

# -----------------------------------------------------------------------------
# Pool and dataset management
# -----------------------------------------------------------------------------
zfs_action_dataset_create() {
  __zfs_require_installed || return 0
  local pool ds parent mp
  pool="$(__zfs_pick_pool)" || return 0

  ds="$(ui_input "$MODULESPEC_TITLE" "📁 Create dataset under pool:\n\n$pool\n\nEnter dataset name (example: media, docker, backups):" "")" || return 0
  [[ -n "$ds" ]] || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  parent="${pool}/${ds}"

  __zfs_yesno_default_no "$MODULESPEC_TITLE" "Set a mountpoint now?\n\nYes = enter mountpoint\nNo = inherit/default" && {
    mp="$(ui_input "$MODULESPEC_TITLE" "Enter mountpoint for:\n\n$parent\n\nExamples:\n  /mnt/${pool}/${ds}\n  /${pool}/${ds}\n\nLeave blank to cancel:" "")" || return 0
    [[ -n "$mp" ]] || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  } || mp=""

  __zfs_danger_gate "$MODULESPEC_TITLE" "Create dataset:\n\n$parent" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type exactly to confirm dataset create:\n\n$parent" "$parent" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  if [[ -n "$mp" ]]; then
    __zfs_programbox "$MODULESPEC_TITLE" "zfs create -o mountpoint='${mp}' -- '$parent' 2>&1 || true; echo; zfs list -- '$parent' 2>/dev/null || true"
  else
    __zfs_programbox "$MODULESPEC_TITLE" "zfs create -- '$parent' 2>&1 || true; echo; zfs list -- '$parent' 2>/dev/null || true"
  fi
}

zfs_action_dataset_destroy() {
  __zfs_require_installed || return 0
  local ds
  ds="$(__zfs_pick_dataset)" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "DESTROY DATASET IS DESTRUCTIVE.\n\nDataset:\n$ds\n\nThis will destroy the dataset and children (-r)." \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the dataset name to confirm:\n\n$ds" "$ds" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Final confirm: type DESTROY_DATASET" "DESTROY_DATASET" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zfs destroy -r -- '$ds' 2>&1 || true; echo; echo 'Done.'"
}

zfs_action_dataset_props_menu() {
  __zfs_require_installed || return 0
  local ds
  ds="$(__zfs_pick_dataset)" || return 0

  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "⚙️ Set dataset properties\n\nTarget:\n$ds" \
        "SHOW" "👀 Show key props" \
        "COMP" "🗜️ compression" \
        "RS"   "📦 recordsize" \
        "AT"   "⏱️ atime" \
        "XA"   "🧩 xattr" \
        "ACL"  "🔐 acltype" \
        "SYNC" "🧨 sync" \
        "LB"   "⚖️ logbias" \
        "PC"   "🗄️ primarycache" \
        "SC"   "🗄️ secondarycache" \
        "CANCEL" "🔙️ Cancel"
    )" || c="BACK"

    case "$c" in
      SHOW) zfs_action_dataset_info ;;
      COMP)
        local v
        v="$(
          ui_menu "$MODULESPEC_TITLE" "Pick compression:" \
            "off" "🚫 off" \
            "lz4" "⚡ lz4" \
            "zstd-3" "🗜️ zstd-3" \
            "zstd-6" "🗜️ zstd-6" \
            "zstd-9" "🗜️ zstd-9" \
            "gzip-1" "🗜️ gzip-1"
        )" || continue
        __zfs_set_dataset_prop "$ds" "compression" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      RS)
        local v
        v="$(
          ui_menu "$MODULESPEC_TITLE" "Pick recordsize:" \
            "16K" "📦 16K" \
            "32K" "📦 32K" \
            "64K" "📦 64K" \
            "128K" "📦 128K" \
            "256K" "📦 256K" \
            "1M" "📦 1M"
        )" || continue
        __zfs_set_dataset_prop "$ds" "recordsize" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      AT)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick atime:" "on" "✅ on" "off" "🚫 off")" || continue
        __zfs_set_dataset_prop "$ds" "atime" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      XA)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick xattr:" "sa" "⚡ sa" "dir" "📁 dir")" || continue
        __zfs_set_dataset_prop "$ds" "xattr" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      ACL)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick acltype:" "posixacl" "🔐 posixacl" "off" "🚫 off")" || continue
        __zfs_set_dataset_prop "$ds" "acltype" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      SYNC)
        ui_msg "$MODULESPEC_TITLE" "🚨 sync notes\n\nstandard: normal safety\nalways: max safety, slower\ndisabled: can lose recent writes on power loss"
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick sync:" "standard" "✅ standard" "always" "🛡️ always" "disabled" "🧨 disabled")" || continue
        __zfs_set_dataset_prop "$ds" "sync" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      LB)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick logbias:" "latency" "⏱️ latency" "throughput" "🚀 throughput")" || continue
        __zfs_set_dataset_prop "$ds" "logbias" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      PC)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick primarycache:" "all" "✅ all" "metadata" "📄 metadata" "none" "🚫 none")" || continue
        __zfs_set_dataset_prop "$ds" "primarycache" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      SC)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "Pick secondarycache:" "all" "✅ all" "metadata" "📄 metadata" "none" "🚫 none")" || continue
        __zfs_set_dataset_prop "$ds" "secondarycache" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      BACK) break ;;
      *) break ;;
    esac
  done
}

# Pool create/destroy
zfs_action_pool_create() {
  __zfs_require_installed || return 0

  local pool
  pool="$(ui_input "$MODULESPEC_TITLE" "➕ Create a new pool\n\nEnter pool name:" "")" || return 0
  __zfs_valid_pool_name "$pool" || { ui_msg "$MODULESPEC_TITLE" "❌ Invalid pool name."; return 0; }

  local -a disks=()
  while IFS= read -r d; do disks+=("$d"); done < <(__zfs_checklist_disks || true)
  [[ ${#disks[@]} -gt 0 ]] || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  local topo
  topo="$(__zfs_pick_topology)" || return 0
  local mindisks
  mindisks="$(__zfs_topology_min_disks "$topo")"
  (( ${#disks[@]} >= mindisks )) || { ui_msg "$MODULESPEC_TITLE" "❌ Not enough disks for $topo.\nNeed: $mindisks\nSelected: ${#disks[@]}"; return 0; }

  local mp
  mp="$(__zfs_pick_mountpoint "$pool")" || return 0

  local sug_a ashift_choice ashift
  sug_a="$(__zfs_suggest_ashift_for_disks "${disks[@]}")"
  ashift_choice="$(
    ui_menu "$MODULESPEC_TITLE" "Pick ashift:" \
      "$sug_a" "✅ Suggested: $sug_a" \
      "custom" "✏️ Custom"
  )" || return 0
  ashift="$sug_a"
  if [[ "$ashift_choice" == "custom" ]]; then
    ashift="$(ui_input "$MODULESPEC_TITLE" "Enter ashift (9-16 usually):\n\nSuggested: $sug_a" "$sug_a")" || return 0
    [[ "$ashift" =~ ^[0-9]+$ ]] || { ui_msg "$MODULESPEC_TITLE" "❌ Invalid ashift."; return 0; }
    (( ashift >= 9 && ashift <= 16 )) || { ui_msg "$MODULESPEC_TITLE" "❌ ashift out of range."; return 0; }
  fi

  local warn=""
  local d
  for d in "${disks[@]}"; do
    if __zfs_disk_is_mounted "$d"; then
      warn+="- $d appears to have mounted partitions\n"
    elif __zfs_disk_looks_in_use "$d"; then
      warn+="- $d appears to have existing signatures/partitions\n"
    fi
  done

  local mp_arg=""
  if [[ "$mp" == "none" ]]; then
    mp_arg="-m none"
  else
    mp_arg="-m '${mp}'"
  fi

  local vdev=""
  case "$topo" in
    stripe) vdev="${disks[*]}" ;;
    mirror) vdev="mirror ${disks[*]}" ;;
    raidz1) vdev="raidz1 ${disks[*]}" ;;
    raidz2) vdev="raidz2 ${disks[*]}" ;;
    raidz3) vdev="raidz3 ${disks[*]}" ;;
  esac

  local summary="Pool: $pool
Topology: $topo
Disks:
$(printf '  - %s\n' "${disks[@]}")
Mountpoint: $mp
ashift: $ashift
"
  [[ -n "$warn" ]] && summary+="
🚨 Disk warnings:
$warn"

  ui_msg "$MODULESPEC_TITLE" "🧨 CREATE POOL SUMMARY\n\n$summary\n\nNext screens will require confirmations."

  __zfs_danger_gate "$MODULESPEC_TITLE" "Creating a pool WILL OVERWRITE selected disks.\n\n$summary" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Final confirm: type YES_ERASE" "YES_ERASE" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  local apply_defaults="0"
  __zfs_yesno_default_no "$MODULESPEC_TITLE" "Apply recommended defaults after create?\n\ncompression=lz4\natime=off\nxattr=sa\nacltype=posixacl" && apply_defaults="1" || apply_defaults="0"

  # shellcheck disable=SC2086
  __zfs_programbox "$MODULESPEC_TITLE" \
    "set -e
echo 'Creating pool...'
zpool create -f -o ashift='${ashift}' ${mp_arg} -- '${pool}' ${vdev}
echo
echo 'Pool created. Status:'
zpool status -v -- '${pool}' || true
echo
if [[ '${apply_defaults}' == '1' ]]; then
  echo 'Applying recommended defaults on pool root dataset...'
  zfs set compression=lz4 -- '${pool}' || true
  zfs set atime=off -- '${pool}' || true
  zfs set xattr=sa -- '${pool}' || true
  zfs set acltype=posixacl -- '${pool}' || true
  echo
  echo 'Key props:'
  zfs get -H -o property,value compression,atime,xattr,acltype,recordsize,mountpoint -- '${pool}' || true
fi
echo
echo 'Done.'
" || true
}

zfs_action_pool_destroy() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "DESTROY POOL IS DESTRUCTIVE.\n\nPool:\n$pool\n\nThis will destroy the pool definition and make data inaccessible." \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to confirm:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Final confirm: type DESTROY_POOL" "DESTROY_POOL" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool destroy -- '$pool' 2>&1 || true; echo; echo 'Done.'"
}

# -----------------------------------------------------------------------------
# Pool properties (autotrim, autoexpand, listsnapshots, autoreplace)
# -----------------------------------------------------------------------------
zfs_action_pool_props_menu() {
  __zfs_require_installed || return 0
  local pool
  pool="$(__zfs_pick_pool)" || return 0

  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "⚙️ Pool properties\n\nTarget:\n$pool" \
        "SHOW" "👀 Show useful pool props" \
        "TRIM" "🧹 autotrim (on/off)" \
        "AEXP" "📏 autoexpand (on/off)" \
        "LSN"  "📸 listsnapshots (on/off)" \
        "ARPL" "🔁 autoreplace (on/off)" \
        "CANCEL" "🔙️ Cancel"
    )" || c="BACK"

    case "$c" in
      SHOW)
        __zfs_programbox "$MODULESPEC_TITLE" "zpool get -H -o property,value ashift,autotrim,autoexpand,listsnapshots,autoreplace -- '$pool' 2>/dev/null || true"
        ;;
      TRIM)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "autotrim:" "on" "✅ on" "off" "🚫 off")" || continue
        __zfs_set_pool_prop "$pool" "autotrim" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      AEXP)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "autoexpand:" "on" "✅ on" "off" "🚫 off")" || continue
        __zfs_set_pool_prop "$pool" "autoexpand" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      LSN)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "listsnapshots:" "on" "✅ on" "off" "🚫 off")" || continue
        __zfs_set_pool_prop "$pool" "listsnapshots" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      ARPL)
        local v
        v="$(ui_menu "$MODULESPEC_TITLE" "autoreplace:" "on" "✅ on" "off" "🚫 off")" || continue
        __zfs_set_pool_prop "$pool" "autoreplace" "$v" || ui_msg "$MODULESPEC_TITLE" "Cancelled."
        ;;
      BACK) break ;;
      *) break ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Vdev ops: replace / attach / detach
# -----------------------------------------------------------------------------
zfs_action_vdev_replace() {
  __zfs_require_installed || return 0
  ui_msg "$MODULESPEC_TITLE" "🧰 Replace device\n\nThis is state-changing.\nYou will confirm twice."

  local pool old new
  pool="$(__zfs_pick_pool)" || return 0
  old="$(__zfs_pick_pool_vdev "$pool")" || return 0
  new="$(__zfs_pick_single_disk_menu "Pick NEW replacement disk:")" || return 0

  if __zfs_disk_looks_in_use "$new"; then
    ui_msg "$MODULESPEC_TITLE" "❌ Selected disk appears to be in use or has partitions:\n\n$new\n\nPick a different disk."
    return 0
  fi

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "Replace device in pool:\n\nPool: $pool\nOld: $old\nNew: $new" \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the old device path to confirm:\n\n$old" "$old" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool replace -- '$pool' '$old' '$new' 2>&1 || true; echo; zpool status -v -- '$pool' || true"
}

zfs_action_vdev_attach() {
  __zfs_require_installed || return 0
  ui_msg "$MODULESPEC_TITLE" "🧰 Attach device\n\nUsually used to turn a single disk into a mirror by attaching a new disk.\nYou will confirm twice."

  local pool existing new
  pool="$(__zfs_pick_pool)" || return 0
  existing="$(__zfs_pick_pool_vdev "$pool")" || return 0
  new="$(__zfs_pick_single_disk_menu "Pick disk to attach (new mirror side):")" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "Attach device:\n\nPool: $pool\nAttach new: $new\nTo existing: $existing" \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the existing device path to confirm:\n\n$existing" "$existing" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool attach -- '$pool' '$existing' '$new' 2>&1 || true; echo; zpool status -v -- '$pool' || true"
}

zfs_action_vdev_detach() {
  __zfs_require_installed || return 0
  ui_msg "$MODULESPEC_TITLE" "🧰 Detach device\n\nOnly valid on mirrors.\nYou will confirm twice."

  local pool dev
  pool="$(__zfs_pick_pool)" || return 0
  dev="$(__zfs_pick_pool_vdev "$pool")" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" \
    "Detach device:\n\nPool: $pool\nDevice: $dev" \
    || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the device path to confirm detach:\n\n$dev" "$dev" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool detach -- '$pool' '$dev' 2>&1 || true; echo; zpool status -v -- '$pool' || true"
}

# -----------------------------------------------------------------------------
# SLOG / L2ARC
# -----------------------------------------------------------------------------
zfs_action_slog_add() {
  __zfs_require_installed || return 0
  ui_msg "$MODULESPEC_TITLE" "🚨 SLOG notes\n\nOnly matters for sync writes.\nNot a write cache.\nBest on power-loss-protected SSDs."
  local pool dev
  pool="$(__zfs_pick_pool)" || return 0
  dev="$(__zfs_pick_single_disk_menu "Pick SLOG device:")" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" "Add SLOG:\n\nPool: $pool\nDevice: $dev" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool add -- '$pool' log '$dev' 2>&1 || true; echo; zpool status -v -- '$pool' || true"
}

zfs_action_l2arc_add() {
  __zfs_require_installed || return 0
  ui_msg "$MODULESPEC_TITLE" "📄 L2ARC notes\n\nHelps read cache for hot data.\nCan increase metadata writes on the cache device."
  local pool dev
  pool="$(__zfs_pick_pool)" || return 0
  dev="$(__zfs_pick_single_disk_menu "Pick L2ARC (cache) device:")" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" "Add L2ARC:\n\nPool: $pool\nDevice: $dev" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool add -- '$pool' cache '$dev' 2>&1 || true; echo; zpool status -v -- '$pool' || true"
}

zfs_action_vdev_remove() {
  __zfs_require_installed || return 0
  ui_msg "$MODULESPEC_TITLE" "🧰 Remove device\n\nUsed for removing cache, special vdevs (where supported), sometimes mirrors.\nNot always possible."

  local pool dev
  pool="$(__zfs_pick_pool)" || return 0
  dev="$(__zfs_pick_pool_vdev "$pool")" || return 0

  __zfs_danger_gate "$MODULESPEC_TITLE" "Remove device:\n\nPool: $pool\nDevice: $dev" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the pool name to continue:\n\n$pool" "$pool" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type the device path to confirm remove:\n\n$dev" "$dev" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }

  __zfs_programbox "$MODULESPEC_TITLE" "zpool remove -- '$pool' '$dev' 2>&1 || true; echo; zpool status -v -- '$pool' || true"
}

# -----------------------------------------------------------------------------
# Install / Purge (Ubuntu only)
# -----------------------------------------------------------------------------
zfs_action_install() {
  __zfs_warn_ubuntu_only || return 0
  if __zfs_installed; then
    ui_msg "$MODULESPEC_TITLE" "✅ ZFS tools already appear to be installed."
    return 0
  fi
  __zfs_danger_gate "$MODULESPEC_TITLE" "Install ZFS packages via apt." || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type INSTALL to proceed:" "INSTALL" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "apt-get update && apt-get install -y zfsutils-linux zfs-zed"
  __zfs_installed && ui_msg "$MODULESPEC_TITLE" "✅ Install complete." || ui_msg "$MODULESPEC_TITLE" "🚨 Install finished but tools not detected. Check output."
}

zfs_action_purge() {
  __zfs_warn_ubuntu_only || return 0
  if ! __zfs_installed; then
    ui_msg "$MODULESPEC_TITLE" "📄 ZFS tools do not appear to be installed."
    return 0
  fi
  __zfs_danger_gate "$MODULESPEC_TITLE" "Purge ZFS packages.\n\nPools will be inaccessible until reinstalled." || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_type_to_confirm "$MODULESPEC_TITLE" "Type PURGE to proceed:" "PURGE" || { ui_msg "$MODULESPEC_TITLE" "Cancelled."; return 0; }
  __zfs_programbox "$MODULESPEC_TITLE" "apt-get purge -y zfsutils-linux zfs-zed && apt-get autoremove -y"
  ui_msg "$MODULESPEC_TITLE" "✅ Purge complete."
}

# -----------------------------------------------------------------------------
# Sub-menus
# -----------------------------------------------------------------------------
zfs_menu_health() {
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "❤️ Health checks" \
        "HX"   "✅ Health (status -x + -v)" \
        "HV"   "🔎 Health (status -v)" \
        "LIST" "📋 List pools and datasets" \
        "PDET" "🧾 Pool details (pick pool)" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      HX) zfs_action_health_x ;;
      HV) zfs_action_health_v ;;
      LIST) zfs_action_list ;;
      PDET) zfs_action_pool_details ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_info() {
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "📄 Info and reporting" \
        "DINFO"  "📄 Dataset info (pick dataset)" \
        "DPROPS" "📌 Dataset properties (full)" \
        "PPROPS" "📌 Pool properties (full)" \
        "EVENTS" "📣 Events (zpool events)" \
        "HIST"   "🕰️ History (zpool history)" \
        "VERS"   "🏷️ Versions, module, mounts" \
        "ARC"    "🗄️ ARC stats" \
        "ARCSUM" "🧾 ARC summary" \
        "HOGS"   "🐘 Space hogs" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      DINFO) zfs_action_dataset_info ;;
      EVENTS) zfs_action_events ;;
      HIST) zfs_action_history ;;
      VERS) zfs_action_versions ;;
      ARC) zfs_action_arc_stats ;;
      ARCSUM) zfs_action_arc_summary ;;
      DPROPS) zfs_action_dataset_properties_full ;;
      PPROPS) zfs_action_pool_properties_full ;;
      HOGS) zfs_action_space_hogs ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_maint() {
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "🧰 Maintenance" \
        "SCRS" "🧼 Scrub start (pick pool)" \
        "SCRX" "🧽 Scrub stop (pick pool) 🧨" \
        "SCRT" "🧼 Scrub status" \
        "TRMS" "🧹 TRIM start (pick pool) 🧨" \
        "TRMX" "🧹 TRIM stop (pick pool) 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      SCRS) zfs_action_scrub_start ;;
      SCRX) zfs_action_scrub_stop ;;
      SCRT) zfs_action_scrub_status ;;
      TRMS) zfs_action_trim_start ;;
      TRMX) zfs_action_trim_stop ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_snaps() {
  ui_msg "$MODULESPEC_TITLE" "📸 Snapshots\n\nRollback/destroy are destructive.\nYou will be asked to confirm twice."
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "📸 Snapshots" \
        "LS"   "📚 List snapshots (pick dataset)" \
        "NEW"  "📸 Create snapshot (pick dataset) 🧨" \
        "DIFF" "🧾 Diff vs current (pick snapshot)" \
        "MNT"  "🗂️ Mount snapshot (where?)" \
        "UMNT" "🧹 Unmount snapshot" \
        "RB"   "⏪ Rollback (pick snapshot) 🧨" \
        "DEL"  "🗑️ Destroy snapshot (pick snapshot) 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      LS) zfs_action_snap_list ;;
      NEW) zfs_action_snap_create ;;
      DIFF) zfs_action_snap_diff ;;
      RB) zfs_action_snap_rollback ;;
      DEL) zfs_action_snap_destroy ;;      MNT) zfs_action_snap_mount ;;
      UMNT) zfs_action_snap_unmount ;;

      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_import_export() {
  ui_msg "$MODULESPEC_TITLE" "📦 Import / Export\n\nThese are state-changing actions.\nYou will be asked to confirm twice."
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "📦 Import and export" \
        "SHOW" "👀 Show importable pools" \
        "IMP"  "📥 Import pool (basic) 🧨" \
        "IMPA" "📥 Import pool (advanced) 🧨" \
        "EXP"  "📤 Export pool (pick) 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      SHOW) zfs_action_import_show ;;
      IMP) zfs_action_import_pool_basic ;;
      IMPA) zfs_action_import_pool_advanced ;;
      EXP) zfs_action_export_pool ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_install() {
  ui_msg "$MODULESPEC_TITLE" "📦 Install / Purge\n\nUbuntu-only.\nPurge can still ruin your day."
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "📦 Install and purge (Ubuntu only)" \
        "INS"  "📦 Install ZFS 🧨" \
        "PUR"  "🧨 Purge ZFS 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      INS) zfs_action_install ;;
      PUR) zfs_action_purge ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_manage() {
  ui_msg "$MODULESPEC_TITLE" "🧱 Pool and dataset management\n\nCreate/destroy are destructive.\nYou will be asked to confirm multiple times."
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "🧱 Create and manage" \
        "PC"   "🆕 Create pool 🧨" \
        "PD"   "🧨 Destroy pool 🧨" \
        "DC"   "📁 Create dataset 🧨" \
        "DD"   "🧨 Destroy dataset 🧨" \
        "DP"   "⚙️ Set dataset properties 🧨" \
        "PP"   "⚙️ Pool properties 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      PC) zfs_action_pool_create ;;
      PD) zfs_action_pool_destroy ;;
      DC) zfs_action_dataset_create ;;
      DD) zfs_action_dataset_destroy ;;
      DP) zfs_action_dataset_props_menu ;;
      PP) zfs_action_pool_props_menu ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_vdev_ops() {
  ui_msg "$MODULESPEC_TITLE" "🧰 Vdev operations\n\nReplace/attach/detach affect pool layout.\nYou will be asked to confirm twice."
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "🧰 Vdev operations" \
        "RPL"  "🔁 Replace disk 🧨" \
        "ATT"  "🆕 Attach disk (mirror) 🧨" \
        "DET"  "❌ Detach disk (mirror) 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      RPL) zfs_action_vdev_replace ;;
      ATT) zfs_action_vdev_attach ;;
      DET) zfs_action_vdev_detach ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

zfs_menu_cache_log() {
  ui_msg "$MODULESPEC_TITLE" "🗄️ Cache and log devices\n\nSLOG and L2ARC are advanced.\nYou will be asked to confirm twice."
  while true; do
    local c
    c="$(
      ui_menu "$MODULESPEC_TITLE" "🗄️ Cache and log" \
        "SLOG" "⚡ Add SLOG (log vdev) 🧨" \
        "L2"   "🗄️ Add L2ARC (cache vdev) 🧨" \
        "REM"  "🧽 Remove device (zpool remove) 🧨" \
        "CANCEL" "🔙️ Cancel"
    )" || c="CANCEL"

    case "$c" in
      SLOG) zfs_action_slog_add ;;
      L2) zfs_action_l2arc_add ;;
      REM) zfs_action_vdev_remove ;;
      CANCEL) break ;;
      *) break ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
module_ZFS() {
  local os state
  os="$(__zfs_os_info)"
  if __zfs_installed; then state="✅ installed"; else state="❌ not installed"; fi

  while true; do
    local choice
    choice="$(
      ui_menu "$MODULESPEC_TITLE" \
        "ZFS tools: $state | OS: $os" \
        "HEALTH" "❤️ Health checks" \
        "INFO"   "📄 Info and reporting" \
        "HIST"   "📜 Pool history (view)" \
        "MAINT"  "🧰 Maintenance (scrub, trim)" \
        "SNAPS"  "📸 Snapshots" \
        "IMPEXP" "📦 Import and export" \
        "MGMT"   "🧱 Pools and datasets" \
        "VDEV"   "🧰 Vdev operations (replace/attach/detach)" \
        "CACHE"  "🗄️  Cache and log (SLOG/L2ARC)" \
        "INST"   "📦 Install and purge" \
        "BACK"   "🔙️ Back"
    )" || choice="BACK"

    case "$choice" in
      HEALTH) zfs_menu_health ;;
      INFO) zfs_menu_info ;;
      HIST) zfs_action_history ;;
      MAINT) zfs_menu_maint ;;
      SNAPS) zfs_menu_snaps ;;
      IMPEXP) zfs_menu_import_export ;;
      MGMT) zfs_menu_manage ;;
      VDEV) zfs_menu_vdev_ops ;;
      CACHE) zfs_menu_cache_log ;;
      INST) zfs_menu_install ;;
      BACK) break ;;
      *) break ;;
    esac
  done
}

if __zfs_is_supported_os; then
register_module "$module_id" "$module_title" module_ZFS
fi
