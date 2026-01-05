#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Monitor & Report (v0.9.8.4)
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

module_id="MONREP"
module_title="📊 Monitor & Report"
MONREP_TITLE="📊 Monitor & Report"



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
# Helper integration (current quest)
# -----------------------------------------------------------------------------

# Prefer the shared helper if it exists next to this module.
# If main already sources it globally, this is a no-op.
_dast_try_source_helper() {
  if declare -F run >/dev/null 2>&1 && declare -F run_capture >/dev/null 2>&1; then
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
# Logging hooks (use core DaST helpers if present)
# -----------------------------------------------------------------------------
monrep__log() {
  # Usage: monrep__log LEVEL message...
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$@"
  fi
}
monrep__dbg() {
  # Usage: monrep__dbg message...
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$@"
  fi
}

# Track whether we had to define local fallbacks (useful breadcrumb for debugging)
__MONREP_FALLBACKS=0

# Fallbacks if helper is still missing (should be rare)
if ! declare -F run >/dev/null 2>&1; then
  __MONREP_FALLBACKS=1
  run() { bash -c "$*" >/dev/null 2>&1 || true; }
fi
if ! declare -F run_capture >/dev/null 2>&1; then
  __MONREP_FALLBACKS=1
  run_capture() { bash -c "$*" 2>&1 || true; }
fi
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  __MONREP_FALLBACKS=1
  mktemp_safe() { mktemp; }
fi

# IMPORTANT:
# Some DaST builds already provide a `have` helper (command existence test).
# This module must not override it. Also ensure "$1" expands correctly.
if ! declare -F have >/dev/null 2>&1; then
  __MONREP_FALLBACKS=1
  have() { command -v "$1" >/dev/null 2>&1; }
fi

if [[ "${__MONREP_FALLBACKS:-0}" -eq 1 ]]; then
  monrep__log WARN "MONREP: dast_helper not loaded (using local fallbacks)."
  monrep__dbg "MONREP: helper missing; local fallbacks enabled."
fi


# ----------------------------------------------------------------------------
# Local capture helper (do not rely on shared run_capture semantics)
# Some DaST builds implement run_capture as a logger and may not return output.
# For Monitor & Report UI views we need actual captured stdout/stderr.
# ----------------------------------------------------------------------------
monrep_cmd_capture() {
  # Usage: monrep_cmd_capture "command string"
  bash -c "$1" 2>&1 || true
}

# ----------------------------------------------------------------------------
# Textbox helper (content -> temp file -> dialog)
# Many DaST ui_textbox helpers expect a *file path*. To avoid mismatches,
# this module always renders text via a temp file.
# ----------------------------------------------------------------------------
monrep_show_text() {
  local title="$1"
  local content="$2"

  # If callers build content using "\n" sequences, normalise them into real newlines.
  # This avoids littering the UI with visible "\n" while keeping tool output intact.
  content="${content//\\n/$'\n'}"

  local tmp
  tmp="$(mktemp_safe)" || return 0
  printf '%s\n' "$content" >"$tmp" 2>/dev/null || true

  if have dialog; then
    dast_ui_dialog --title "$title" --textbox "$tmp" 0 0
  else
    cat "$tmp"; echo
    read -r -p "Press Enter to continue..." _ || true
  fi
}



# -----------------------------------------------------------------------------
# OS detection (Debian/Ubuntu awareness)
# -----------------------------------------------------------------------------
monrep_os_detect() {
  PROC_OS_ID="unknown"
  PROC_OS_NAME="Unknown"
  PROC_OS_PRETTY="Unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    PROC_OS_ID="${ID:-unknown}"
    PROC_OS_NAME="${NAME:-Unknown}"
    PROC_OS_PRETTY="${PRETTY_NAME:-$PROC_OS_NAME}"
  fi

  PROC_OS_FAMILY="other"
  case "${PROC_OS_ID,,}" in
    debian|ubuntu|linuxmint|pop|kali|raspbian)
      PROC_OS_FAMILY="debian"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Monitor preference storage (kept from old module)
# -----------------------------------------------------------------------------
__monrep_cfg_file() {
  if [[ -n "${CFG_FILE:-}" ]]; then
    echo "$CFG_FILE"
  elif [[ -n "${CONFIG_FILE:-}" ]]; then
    echo "$CONFIG_FILE"
  else
    echo ""
  fi
}

monrep_cfg_load() {
  local cf
  cf="$(__monrep_cfg_file)"
  [[ -n "$cf" && -f "$cf" ]] && source "$cf" >/dev/null 2>&1 || true
  PROCESS_MONITOR_PREF="${PROCESS_MONITOR_PREF:-top}"
  PROCESS_MONITOR_REPORT_DIR="${PROCESS_MONITOR_REPORT_DIR:-/var/log/dast/reports}"
  # Report options defaults (1=on,0=off)
  MONREP_OPT_DISK="${MONREP_OPT_DISK:-1}"
  MONREP_OPT_NETWORK="${MONREP_OPT_NETWORK:-1}"
  MONREP_OPT_PROCS="${MONREP_OPT_PROCS:-1}"
  MONREP_OPT_DMESG="${MONREP_OPT_DMESG:-1}"
  MONREP_OPT_JOURNAL="${MONREP_OPT_JOURNAL:-1}"
  MONREP_OPT_SENSORS="${MONREP_OPT_SENSORS:-1}"
  MONREP_OPT_ZFS="${MONREP_OPT_ZFS:-1}"
  MONREP_OPT_PKGS="${MONREP_OPT_PKGS:-0}"
}

monrep_cfg_set() {
  local val="$1"
  local cf
  cf="$(__monrep_cfg_file)"
  [[ -z "$cf" ]] && return 0

  mkdir -p "$(dirname "$cf")" 2>/dev/null || true

  local tmp
  tmp="$(mktemp)"
  [[ -f "$cf" ]] && grep -v '^PROCESS_MONITOR_PREF=' "$cf" >"$tmp" || : >"$tmp"
  printf 'PROCESS_MONITOR_PREF=%q\n' "$val" >>"$tmp"
  mv "$tmp" "$cf"
}

monrep_cfg_set_report_dir() {
  local val="$1"
  local cf
  cf="$(__monrep_cfg_file)"
  [[ -z "$cf" ]] && return 0

  mkdir -p "$(dirname "$cf")" 2>/dev/null || true

  local tmp
  tmp="$(mktemp)"
  if [[ -f "$cf" ]]; then
    grep -v '^PROCESS_MONITOR_REPORT_DIR=' "$cf" >"$tmp" || : >"$tmp"
  else
    : >"$tmp"
  fi
  printf 'PROCESS_MONITOR_REPORT_DIR=%q
' "$val" >>"$tmp"
  mv "$tmp" "$cf"
}


monrep_cfg_set_kv() {
  local key="$1"
  local val="$2"
  local cf tmp
  cf="$(__monrep_cfg_file)"
  [[ -z "$cf" ]] && return 0

  mkdir -p "$(dirname "$cf")" 2>/dev/null || true

  tmp="$(mktemp)"
  if [[ -f "$cf" ]]; then
    grep -v "^${key}=" "$cf" >"$tmp" || : >"$tmp"
  else
    : >"$tmp"
  fi

  printf '%s=%q\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$cf"
}

monrep_zfs_present() {
  have zpool && have zfs
}

monrep_install_zfs() {
  monrep_os_detect
  if [[ "$PROC_OS_FAMILY" != "debian" ]]; then
    ui_msg "$MONREP_TITLE" "ZFS install helper is tuned for Debian/Ubuntu via apt.\n\nDetected: $PROC_OS_PRETTY\n\nInstall ZFS with your distro tools, then re-try."
    return 1
  fi

  if ui_yesno "$MONREP_TITLE" "ZFS tools not detected.\n\nInstall zfsutils-linux via apt?\n\nDefault is No."; then
    ui_programbox "Installing ZFS" "apt-get update && apt-get install -y zfsutils-linux"
  fi

  monrep_zfs_present
}

monrep_report_options_menu() {
  monrep_cfg_load
  monrep_os_detect

  local zfs_label="Include ZFS section + attachments"
  if ! monrep_zfs_present; then
    zfs_label="Include ZFS section + attachments (not installed)"
  fi

  local res=""
  if have dialog; then
    res="$(dast_ui_dialog --title "$MONREP_TITLE"--checklist "Report options (affects Preview + Export)\n\nSPACE toggles. ENTER saves." 22 78 12 \
      "DISK"    "Disk usage + block devices + mounts"        "$([[ "$MONREP_OPT_DISK" == "1" ]] && echo on || echo off)" \
      "NETWORK" "Network summary + listening ports"          "$([[ "$MONREP_OPT_NETWORK" == "1" ]] && echo on || echo off)" \
      "PROCS"   "Top processes snapshot"                     "$([[ "$MONREP_OPT_PROCS" == "1" ]] && echo on || echo off)" \
      "DMESG"   "Kernel warnings/errors section"             "$([[ "$MONREP_OPT_DMESG" == "1" ]] && echo on || echo off)" \
      "JOURNAL" "System journal warnings/errors section"     "$([[ "$MONREP_OPT_JOURNAL" == "1" ]] && echo on || echo off)" \
      "SENSORS" "Temperatures (lm-sensors)"                  "$([[ "$MONREP_OPT_SENSORS" == "1" ]] && echo on || echo off)" \
      "ZFS"     "$zfs_label"                                 "$([[ "$MONREP_OPT_ZFS" == "1" ]] && echo on || echo off)" \
      "PKGS"    "Package baseline (dpkg list summary)"       "$([[ "$MONREP_OPT_PKGS" == "1" ]] && echo on || echo off)" \
      3>&1 1>&2 2>&3)" || return 0
  else
    ui_msg "$MONREP_TITLE" "No dialog detected.\n\nReport Options UI requires 'dialog'."
    return 0
  fi

  # dialog returns quoted tags like "DISK" "NETWORK"
  MONREP_OPT_DISK=0
  MONREP_OPT_NETWORK=0
  MONREP_OPT_PROCS=0
  MONREP_OPT_DMESG=0
  MONREP_OPT_JOURNAL=0
  MONREP_OPT_SENSORS=0
  MONREP_OPT_ZFS=0
  MONREP_OPT_PKGS=0

  for t in $res; do
    t="${t//\"/}"
    case "$t" in
      DISK) MONREP_OPT_DISK=1 ;;
      NETWORK) MONREP_OPT_NETWORK=1 ;;
      PROCS) MONREP_OPT_PROCS=1 ;;
      DMESG) MONREP_OPT_DMESG=1 ;;
      JOURNAL) MONREP_OPT_JOURNAL=1 ;;
      SENSORS) MONREP_OPT_SENSORS=1 ;;
      ZFS) MONREP_OPT_ZFS=1 ;;
      PKGS) MONREP_OPT_PKGS=1 ;;
    esac
  done

  # If user enabled ZFS but it's not present, offer install (Debian/Ubuntu)
  if [[ "$MONREP_OPT_ZFS" == "1" ]] && ! monrep_zfs_present; then
    if ! monrep_install_zfs; then
      MONREP_OPT_ZFS=0
    fi
  fi

  monrep_cfg_set_kv "MONREP_OPT_DISK" "$MONREP_OPT_DISK"
  monrep_cfg_set_kv "MONREP_OPT_NETWORK" "$MONREP_OPT_NETWORK"
  monrep_cfg_set_kv "MONREP_OPT_PROCS" "$MONREP_OPT_PROCS"
  monrep_cfg_set_kv "MONREP_OPT_DMESG" "$MONREP_OPT_DMESG"
  monrep_cfg_set_kv "MONREP_OPT_JOURNAL" "$MONREP_OPT_JOURNAL"
  monrep_cfg_set_kv "MONREP_OPT_SENSORS" "$MONREP_OPT_SENSORS"
  monrep_cfg_set_kv "MONREP_OPT_ZFS" "$MONREP_OPT_ZFS"
  monrep_cfg_set_kv "MONREP_OPT_PKGS" "$MONREP_OPT_PKGS"

  monrep_cfg_load
  ui_msg "$MONREP_TITLE" "Saved report options."
}

pick_monitor() {
  monrep_cfg_load

  case "$PROCESS_MONITOR_PREF" in
    top)  have top  && echo "top"  ;;
    btop) have btop && echo "btop" ;;
    htop) have htop && echo "htop" ;;
    auto|"")
      have btop && echo "btop" && return 0
      have htop && echo "htop" && return 0
      have top  && echo "top"  && return 0
      ;;
  esac

  echo ""
}

install_monitor() {
  local tool="$1"

  if [[ "$PROC_OS_FAMILY" != "debian" ]]; then
    ui_msg "$MONREP_TITLE" "Auto-install is tuned for Debian/Ubuntu via apt.\n\nDetected: $PROC_OS_PRETTY\n\nInstall '$tool' using your distro package manager, then re-try."
    return 0
  fi

  if ui_yesno "Install $tool?" "Install $tool using apt?\n\nDefault is No."; then
    ui_programbox "Installing $tool" "apt-get update && apt-get install -y $tool"
  fi
}

# -----------------------------------------------------------------------------
# Process helpers
# -----------------------------------------------------------------------------
__monrep_top_ps() {
  ps -eo pid=,pcpu=,pmem=,user=,comm=,args= --sort=-pcpu 2>/dev/null | head -n 200
}

monrep_pick_pid() {
  local prompt="${1:-Select a process:}"
  local -a items=()
  local line pid cpu mem user comm args desc

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid="$(awk '{print $1}' <<<"$line")"
    cpu="$(awk '{print $2}' <<<"$line")"
    mem="$(awk '{print $3}' <<<"$line")"
    user="$(awk '{print $4}' <<<"$line")"
    comm="$(awk '{print $5}' <<<"$line")"
    args="$(cut -d' ' -f6- <<<"$line")"
    desc="${cpu}% ${mem}% ${user} ${comm}  ${args}"
    desc="${desc:0:110}"
    items+=("$pid" "$desc")
  done < <(__monrep_top_ps)

  [[ "${#items[@]}" -eq 0 ]] && { ui_msg "$MONREP_TITLE" "No process list available."; return 1; }

  ui_menu "$MONREP_TITLE" "$prompt\n\n(Top by CPU, scrollable)" "${items[@]}"
}

monrep_show_top() {
  monrep_show_text "$MONREP_TITLE" "$(__monrep_top_ps | sed 's/^/ /')"
}

monrep_kill_pid() {
  local pid sig

  pid="$(monrep_pick_pid "Kill which process?")" || return 0
  [[ -z "$pid" ]] && return 0

  # Capture process identity to reduce PID-reuse risk
  local pid_stat comm cmdline
  if [[ -r "/proc/$pid/stat" ]]; then
    pid_stat="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
  fi
  if [[ -r "/proc/$pid/comm" ]]; then
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
  fi
  if [[ -r "/proc/$pid/cmdline" ]]; then
    # /proc/<pid>/cmdline is NUL-separated and may contain non-UTF8 bytes; sanitize for dialog.
    cmdline="$(LC_ALL=C tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null       | LC_ALL=C tr -cd '[:print:]\t '       | sed -E 's/[[:space:]]+/ /g'       | head -c 300       || true)"
  fi

  sig="$(ui_menu "$MONREP_TITLE" "Choose signal for PID $pid:" \
    "TERM" "Terminate (polite)" \
    "KILL" "Kill (force)" \
    "HUP"  "Hangup / reload" \
    "INT"  "Interrupt (Ctrl-C)" \
    "BACK" "Back")" || return 0

  [[ "$sig" == "BACK" ]] && return 0

  if ! ui_yesno "$MONREP_TITLE" "Send SIG${sig} to PID ${pid}?

Process:
  comm: ${comm:-?}
  cmd:  ${cmdline:-?}

This may stop services or break sessions."; then
    return 0
  fi

    # Re-validate identity right before signalling (PID may have been recycled)
  if [[ -n "${pid_stat:-}" && -r "/proc/$pid/stat" ]]; then
    local pid_stat_now
    pid_stat_now="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    if [[ -n "$pid_stat_now" && "$pid_stat_now" != "$pid_stat" ]]; then
      ui_msg "$MONREP_TITLE" "Refusing to signal PID ${pid}.

The process identity changed after selection (PID reuse detected)."
      return 0
    fi
  fi

  if kill -s "$sig" "$pid" >/dev/null 2>&1; then
    ui_msg "$MONREP_TITLE" "Signal SIG${sig} sent to PID ${pid}."
  else
    ui_msg "$MONREP_TITLE" "Failed to signal PID ${pid}.\n\nYou may not have permission, or the process already exited."
  fi
}

monrep_inspect_pid() {
  local pid out cmdline

  pid="$(monrep_pick_pid "Inspect which process?")" || return 0
  [[ -z "$pid" ]] && return 0

  if [[ ! -d "/proc/${pid}" ]]; then
    ui_msg "$MONREP_TITLE" "PID ${pid} no longer exists."
    return 0
  fi

  local priv_hint=""
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    priv_hint="\nNOTE: Running as non-root. Some details (sockets/open files) may be hidden.\n"
  fi

  out=""
  out+="DaST Monitor & Report | Process Inspect\n"
  out+="PID: ${pid}\n"
  out+="Generated: $(date '+%Y-%m-%d %H:%M:%S')\n"
  out+="$priv_hint\n"

  out+="[Summary]\n"
  out+="$(ps -p "$pid" -o pid,ppid,pgid,sid,tty,user,group,stat,ni,pri,psr,pcpu,pmem,rss,vsz,etimes,lstart,cmd --no-headers 2>/dev/null || echo ' <process not found>')\n\n"

  if [[ -r "/proc/${pid}/cmdline" ]]; then
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || true)"
    out+="[cmdline]\n${cmdline:-<empty>}\n\n"
  fi

  out+="[/proc/${pid}/status]\n"
  if [[ -r "/proc/${pid}/status" ]]; then
    out+="$(cat "/proc/${pid}/status" 2>/dev/null || true)\n"
  else
    out+=" <unreadable>\n"
  fi
  out+="\n"

  out+="[Listening ports]\n"
  if have ss; then
    out+="TCP listeners:\n"
    out+="$(ss -lptn 2>/dev/null | grep -E "pid=${pid}[,)]" | head -n 80 || echo ' <none found or insufficient permission>')\n\n"
    out+="UDP listeners:\n"
    out+="$(ss -lpun 2>/dev/null | grep -E "pid=${pid}[,)]" | head -n 80 || echo ' <none found or insufficient permission>')\n\n"
  else
    out+="Tip: install 'iproute2' for 'ss' socket inspection.\n\n"
  fi

  out+="[Open files]\n"
  if have lsof; then
    out+="lsof (first 80 lines):\n"
    out+="$(lsof -p "$pid" 2>/dev/null | head -n 80 || true)\n\n"
  else
    out+="Tip: install 'lsof' for detailed open-file inspection.\n\n"
  fi

  local tmp
  tmp="$(mktemp_safe)" || return 0
  printf '%s' "$out" >"$tmp"

  if have dialog; then
    dast_ui_dialog --title "$MONREP_TITLE" --textbox "$tmp" 0 0
  else
    cat "$tmp"; echo
    read -r -p "Press Enter to continue..." _ || true
  fi
}

# -----------------------------------------------------------------------------
# System reporting
# -----------------------------------------------------------------------------
monrep_report_collect() {
  monrep_os_detect
  monrep_cfg_load

  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S%z')"

  echo "DaST Monitor & Report"
  echo "Generated: $ts"
  echo "Host: $(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  echo "User: ${SUDO_USER:-$USER} (euid=${EUID:-$(id -u)})"
  echo "OS: $PROC_OS_PRETTY"
  echo

  echo "===== UPTIME / LOAD ====="
  run_capture uptime || true
  echo

  echo "===== CPU ====="
  if have lscpu; then
    run_capture lscpu | sed -n '1,80p' || true
  else
    run_capture cat /proc/cpuinfo | sed -n '1,80p' || true
  fi
  echo

  echo "===== MEMORY ====="
  run_capture free -h || true
  echo

  if [[ "$MONREP_OPT_PROCS" == "1" ]]; then
    echo "===== TOP PROCESSES (CPU) ====="
    __monrep_top_ps || true
    echo
  fi

  if [[ "$MONREP_OPT_DISK" == "1" ]]; then
    echo "===== DISK USAGE ====="
    run_capture df -hT || true
    echo

    echo "===== BLOCK DEVICES ====="
    if have lsblk; then
      run_capture lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL || true
    else
      echo "lsblk not installed"
    fi
    echo

    echo "===== MOUNTS ====="
    run_capture mount | head -n 200 || true
    echo
  fi

  if [[ "$MONREP_OPT_NETWORK" == "1" ]]; then
    echo "===== NETWORK (SUMMARY) ====="
    if have ip; then
      run_capture ip -brief addr || true
      echo
      run_capture ip route || true
    else
      echo "ip (iproute2) not installed"
    fi
    echo

    echo "===== LISTENING PORTS (TOP 120) ====="
    if have ss; then
      run_capture ss -lntup | head -n 120 || true
    else
      echo "ss not installed (iproute2)"
    fi
    echo
  fi

  echo "===== SERVICES (FAILED) ====="
  if have systemctl; then
    run_capture systemctl --failed --no-pager || true
  else
    echo "systemctl not present"
  fi
  echo

  echo "===== SYSTEMD UNIT COUNT (QUICK) ====="
  if have systemctl; then
    run_capture systemctl list-units --type=service --state=running --no-pager | wc -l | sed 's/^/running services: /' || true
  fi
  echo

  if [[ "$MONREP_OPT_DMESG" == "1" ]]; then
    echo "===== KERNEL / DMESG (WARN/ERR, LAST 200) ====="
    if have journalctl; then
      run_capture journalctl -k -p warning..emerg --no-pager -n 200 || true
    else
      run_capture_sh "dmesg --level=warn,err,crit,alert,emerg 2>/dev/null | tail -n 200" || true
    fi
    echo
  fi

  if [[ "$MONREP_OPT_JOURNAL" == "1" ]]; then
    echo "===== JOURNAL (WARN/ERR, LAST 200) ====="
    if have journalctl; then
      run_capture journalctl -p warning..emerg --no-pager -n 200 || true
    else
      echo "journalctl not available"
    fi
    echo
  fi

  if [[ "$MONREP_OPT_ZFS" == "1" ]]; then
    echo "===== ZFS (IF PRESENT) ====="
    if monrep_zfs_present; then
      run_capture zpool status -v || true
      echo
      run_capture zfs list || true
      echo
      run_capture_sh "zfs get -H -o name,property,value,source atime,compression,recordsize,xattr,acltype 2>/dev/null | head -n 200" || true
    else
      echo "zpool/zfs not present"
    fi
    echo
  fi

  if [[ "$MONREP_OPT_SENSORS" == "1" ]]; then
    echo "===== TEMPERATURES (IF AVAILABLE) ====="
    if have sensors; then
      run_capture sensors || true
    else
      echo "Tip: install 'lm-sensors' and run sensors-detect."
    fi
    echo
  fi

  echo "===== SMART (IF AVAILABLE) ====="
  if have smartctl; then
    run_capture smartctl --scan-open || true
    echo
    echo "Tip: Run a per-disk SMART report from DaST Storage/ZFS modules if needed."
  else
    echo "smartctl not installed (smartmontools)"
  fi
  echo

  if [[ "$MONREP_OPT_PKGS" == "1" ]]; then
    echo "===== PACKAGE BASELINE ====="
    if [[ "$PROC_OS_FAMILY" == "debian" ]] && have dpkg; then
      echo "dpkg: $(dpkg-query -W -f='${binary:Package}
' 2>/dev/null | wc -l | tr -d ' ') packages installed"
      echo
      run_capture dpkg -l | sed -n '1,120p' || true
    else
      echo "Package listing not supported here for this distro"
    fi
    echo
  fi
}

monrep_report_make_files() {
  monrep_cfg_load

  local base ts outdir host host_safe attachdir
  ts="$(date '+%Y%m%d_%H%M%S')"

  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  host_safe="$(echo "$host" | tr ' ' '_' | tr -c 'A-Za-z0-9._-' '_' | sed 's/_\+/_/g; s/^_//; s/_$//')"
  [[ -z "$host_safe" ]] && host_safe="unknown"

  base="${PROCESS_MONITOR_REPORT_DIR:-/var/log/dast/reports}"

  # Preferred dir first; fallback if unwritable
  if ! mkdir -p "$base" >/dev/null 2>&1 || [[ ! -w "$base" ]]; then
    base="/tmp/dast-reports"
    mkdir -p "$base" >/dev/null 2>&1 || return 1
  fi

  outdir="$base/dast_monitor_report_${host_safe}_${ts}"
  mkdir -p "$outdir" >/dev/null 2>&1 || return 1

  attachdir="$outdir/attachments"
  mkdir -p "$attachdir" >/dev/null 2>&1 || true

  local txt
  txt="$outdir/system_report.txt"
  monrep_report_collect >"$txt" 2>&1 || true


  # Attachments (separate files for easier sharing/grep)
  if [[ "$MONREP_OPT_DISK" == "1" ]]; then
    if have df; then df -h >"$attachdir/df-h.txt" 2>&1 || true; fi
    if have lsblk; then lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL >"$attachdir/lsblk.txt" 2>&1 || true; fi
  fi
  if [[ "$MONREP_OPT_PROCS" == "1" ]]; then
    __monrep_top_ps >"$attachdir/top-procs.txt" 2>&1 || true
  fi
  if have free; then free -h >"$attachdir/free-h.txt" 2>&1 || true; fi
  if [[ "$MONREP_OPT_NETWORK" == "1" ]]; then
    if have ip; then ip -br addr >"$attachdir/ip-addr.txt" 2>&1 || true; ip -s link >"$attachdir/ip-link.txt" 2>&1 || true; fi
    if have ss; then ss -tulpen >"$attachdir/ss-tulpen.txt" 2>&1 || true; fi
  fi
  if [[ "$MONREP_OPT_DMESG" == "1" ]]; then
    if have dmesg; then dmesg -T 2>/dev/null | tail -n 300 >"$attachdir/dmesg-tail.txt" 2>&1 || true; fi
  fi
  if [[ "$MONREP_OPT_JOURNAL" == "1" ]]; then
    if have journalctl; then journalctl -p warning..alert --since "24 hours ago" --no-pager >"$attachdir/journal-warn-24h.txt" 2>&1 || true; fi
  fi
  if [[ "$MONREP_OPT_SENSORS" == "1" ]]; then
    if have sensors; then sensors >"$attachdir/sensors.txt" 2>&1 || true; fi
  fi
  if [[ "$MONREP_OPT_ZFS" == "1" ]]; then
    if monrep_zfs_present; then
      zpool status >"$attachdir/zpool-status.txt" 2>&1 || true
      zpool list >"$attachdir/zpool-list.txt" 2>&1 || true
      zfs list -o name,used,avail,refer,mountpoint >"$attachdir/zfs-list.txt" 2>&1 || true
    fi
  fi

  # Also include a tiny env metadata file (nice for later tooling)
  monrep_os_detect
  {
    echo "timestamp=$ts"
    echo "host=$host"
    echo "host_safe=$host_safe"
    echo "report_dir=$outdir"
    echo "attachments_dir=$attachdir"
    echo "os_pretty=$PROC_OS_PRETTY"
    echo "euid=${EUID:-$(id -u)}"
  } >"$outdir/meta.env" 2>/dev/null || true

  echo "$outdir"
}

monrep_export_report() {
  local outdir tarball

  outdir="$(monrep_report_make_files)" || {
    ui_msg "$MONREP_TITLE" "Failed to create report folder."
    return 0
  }

  tarball="${outdir}.tar.gz"

  if have tar; then
    (cd "$(dirname "$outdir")" && tar -czf "$tarball" "$(basename "$outdir")") >/dev/null 2>&1 || true
  fi

  local msg
  msg="Report created:\n\n$outdir\n\nIncluded:\n- system_report.txt\n- meta.env"
  if [[ -f "$tarball" ]]; then
    msg+="\n\nCompressed:\n$tarball"
  fi
  msg+="\n\nTip: default export is /var/log/dast/reports (fallback: /tmp/dast-reports if unwritable)."

  ui_msg "$MONREP_TITLE" "$msg"
}

monrep_view_report_preview() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  monrep_report_collect >"$tmp" 2>&1 || true

  if have dialog; then
    dast_ui_dialog --title "$MONREP_TITLE" --textbox "$tmp" 0 0
  else
    cat "$tmp"; echo
    read -r -p "Press Enter to continue..." _ || true
  fi
}

# -----------------------------------------------------------------------------
# Quick monitors (non-interactive, still useful in SSH)
# -----------------------------------------------------------------------------
monrep_quick_summary() {
  local out
  monrep_os_detect

  out=""
  out+=$'DaST Quick Summary\n'
  out+=$'Host: '"$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"$'\n'
  out+=$'OS: '"$PROC_OS_PRETTY"$'\n'
  out+=$'Time: '"$(date '+%Y-%m-%d %H:%M:%S')"$'\n\n'

  out+=$'Uptime:\n'"$(monrep_cmd_capture "uptime 2>/dev/null" || true)"$'\n\n'
  out+=$'Memory:\n'"$(monrep_cmd_capture "free -h 2>/dev/null" || true)"$'\n\n'
  out+=$'Disk:\n'"$(monrep_cmd_capture "df -hT 2>/dev/null" | head -n 30 || true)"$'\n\n'

  monrep_show_text "$MONREP_TITLE" "$out"
}


# -----------------------------------------------------------------------------
# Live process monitor launcher
# -----------------------------------------------------------------------------
run_monitor() {
  monrep_os_detect

  local mon
  mon="$(pick_monitor)"

  if [[ -z "$mon" ]]; then
    local choice
    choice="$(ui_menu "$MONREP_TITLE" "No monitor found. Install one?\n\nDetected: $PROC_OS_PRETTY" \
      "TOP"  "Install top (procps)" \
      "BTOP" "Install btop (recommended)" \
      "HTOP" "Install htop" \
      "BACK" "Back")" || return 0

    case "$choice" in
      TOP)  install_monitor procps ;;
      BTOP) install_monitor btop ;;
      HTOP) install_monitor htop ;;
      BACK) return 0 ;;
    esac

    mon="$(pick_monitor)"
    [[ -z "$mon" ]] && { ui_msg "$MONREP_TITLE" "No monitor available."; return 0; }
  fi

  # Some DaST cores define a cleanup() helper for dialog/tty state.
  # Don't hard-fail if it's missing.
  if declare -F cleanup >/dev/null 2>&1; then
    cleanup
  fi
  "$mon"
}


# -----------------------------------------------------------------------------
# Report directory configuration
# -----------------------------------------------------------------------------
monrep_set_report_dir() {
  monrep_cfg_load

  local current="${PROCESS_MONITOR_REPORT_DIR:-/var/log/dast/reports}"
  local newdir=""

  if have dialog; then
    local tmp
    tmp="$(mktemp_safe)" || return 0
    printf '%s
' "$current" >"$tmp" 2>/dev/null || true
    newdir="$(dast_ui_dialog --title "$MONREP_TITLE"--inputbox "Report export directory:\n\nDefault: /var/log/dast/reports\nFallback: /tmp/dast-reports\n\nCurrent:" 14 70 "$current" 3>&1 1>&2 2>&3)" || return 0
  else
    printf '
Report export directory (default /var/log/dast/reports)
Current: %s
New: ' "$current"
    read -r newdir || true
  fi

  # Blank means "reset to default"
  if [[ -z "$newdir" ]]; then
    newdir="/var/log/dast/reports"
  fi

  # Trim trailing slashes
  newdir="${newdir%/}"

  monrep_cfg_set_report_dir "$newdir"
  monrep_cfg_load
  ui_msg "$MONREP_TITLE" "Saved:\n\nPROCESS_MONITOR_REPORT_DIR=$PROCESS_MONITOR_REPORT_DIR"
}
# -----------------------------------------------------------------------------
# Tool gating + install guidance (DaST philosophy: guard, don't guess)
# -----------------------------------------------------------------------------
monrep_need_tool() {
  # Usage: monrep_need_tool <binary> <apt_package_hint> <why>
  local bin="${1:-}"
  local pkg="${2:-}"
  local why="${3:-This feature requires an additional tool.}"

  if [[ -z "$bin" ]]; then
    return 1
  fi

  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi

  ui_msg "$MONREP_TITLE" "Missing tool: ${bin}\n\n${why}\n\nInstall via:\n  APT -> Common installs\n\nSuggested package:\n  ${pkg}"
  return 1
}

monrep_need_root() {
  # Usage: monrep_need_root <why>
  local why="${1:-This action needs root for accurate results.}"
  if (( EUID == 0 )); then
    return 0
  fi
  ui_msg "$MONREP_TITLE" "Root required.\n\n${why}\n\nRe-run DaST as root (or via sudo) for this view."
  return 1
}

# -----------------------------------------------------------------------------
# Pickers (TTY-friendly)
# -----------------------------------------------------------------------------
monrep_pick_blockdev() {
  # Returns a device path like /dev/sda or /dev/nvme0n1
  # Optional arg:
  #   nvme      -> only NVMe namespaces (/dev/nvme*)
  #   non_nvme  -> exclude NVMe namespaces
  #   any       -> all disks (default)
  local filter="${1:-any}"
  local out items line name model size dev type

  _monrep_is_nvme_dev() {
    # Arg: /dev/XXX or XXX
    local d="${1#/dev/}"
    [[ "$d" == nvme* ]] && return 0
    # sysfs check (covers odd naming)
    [[ -e "/sys/block/$d/device/subsystem" ]] && readlink -f "/sys/block/$d/device/subsystem" 2>/dev/null | grep -q "/nvme" && return 0
    return 1
  }

  items=()

  # Prefer KEY="VALUE" output. Some lsblk builds don't support -P, so fall back.
  out="$(monrep_cmd_capture "lsblk -dn -P -o NAME,SIZE,MODEL,TYPE 2>/dev/null" || true)"
  if [[ -n "$out" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue

      name="$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<<"$line")"
      size="$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<<"$line")"
      model="$(sed -n 's/.*MODEL="\([^"]*\)".*/\1/p' <<<"$line")"
      type="$(sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' <<<"$line")"

      [[ -z "$name" ]] && continue
      [[ "$type" != "disk" ]] && continue

      dev="/dev/$name"

      case "$filter" in
        nvme)     _monrep_is_nvme_dev "$dev" || continue ;;
        non_nvme) _monrep_is_nvme_dev "$dev" && continue ;;
        *) : ;;
      esac

      [[ -z "$model" ]] && model="(no model)"
      items+=("$dev" "💽 $dev  ${size}  ${model}")
    done <<<"$out"
  fi

  # Fallback parser if -P is unsupported/empty
  if [[ "${#items[@]}" -eq 0 ]]; then
    out="$(monrep_cmd_capture "lsblk -dn -r -o NAME,SIZE,TYPE,MODEL 2>/dev/null" || true)"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue

      # NAME SIZE TYPE MODEL...
      name="$(awk '{print $1}' <<<"$line")"
      size="$(awk '{print $2}' <<<"$line")"
      type="$(awk '{print $3}' <<<"$line")"
      model="$(cut -d' ' -f4- <<<"$line" | sed 's/^[[:space:]]*//')"

      [[ -z "$name" ]] && continue
      [[ "$type" != "disk" ]] && continue

      dev="/dev/$name"

      case "$filter" in
        nvme)     _monrep_is_nvme_dev "$dev" || continue ;;
        non_nvme) _monrep_is_nvme_dev "$dev" && continue ;;
        *) : ;;
      esac

      [[ -z "$model" ]] && model="(no model)"
      items+=("$dev" "💽 $dev  ${size}  ${model}")
    done <<<"$out"
  fi

  [[ "${#items[@]}" -eq 0 ]] && { ui_msg "$MONREP_TITLE" "No block devices found."; return 1; }

  ui_menu "$MONREP_TITLE" "Select a disk:" "${items[@]}"
}



monrep_pick_iface() {
  local out items line name desc
  out="$(monrep_cmd_capture "ip -o link show 2>/dev/null | awk -F': ' '{print \$2}' | awk '{print \$1}'" || true)"
  items=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # Brief status line
    desc="$(monrep_cmd_capture "ip -br link show dev '$name' 2>/dev/null | sed 's/^/ /'" || true)"
    desc="${desc//$'\n'/ }"
    desc="${desc:0:110}"
    items+=("$name" "🌐 $name  ${desc}")
  done <<<"$out"

  [[ "${#items[@]}" -eq 0 ]] && { ui_msg "$MONREP_TITLE" "No network interfaces found."; return 1; }

  ui_menu "$MONREP_TITLE" "Select an interface:" "${items[@]}"
}

# -----------------------------------------------------------------------------
# Storage health (SMART / NVMe / ZFS)
# -----------------------------------------------------------------------------
monrep_smart_summary() {
  monrep_need_tool smartctl smartmontools "SMART health reporting uses smartmontools." || return 1

  local dev
  dev="$(monrep_pick_blockdev non_nvme)" || return 1

  # Some SMART data needs root for full accuracy
  if (( EUID != 0 )); then
    ui_msg "$MONREP_TITLE" "Note: SMART output may be limited without root.\n\nTip: re-run DaST as root for full details."
  fi

  monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "smartctl -H -i -A '$dev' 2>&1" || true)"
}

monrep_nvme_health() {
  monrep_need_tool nvme nvme-cli "NVMe health reporting uses nvme-cli." || return 1

  local dev
  dev="$(monrep_pick_blockdev nvme)" || return 1

  if [[ "$dev" != /dev/nvme* ]]; then
    ui_msg "$MONREP_TITLE" "That doesn't look like an NVMe namespace.\n\nSelected: $dev\n\nTip: pick a /dev/nvmeXnY device."
    return 1
  fi

  if (( EUID != 0 )); then
    ui_msg "$MONREP_TITLE" "Note: Some NVMe fields may be limited without root.\n\nTip: re-run DaST as root for full details."
  fi

  monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "nvme smart-log '$dev' 2>&1; echo; nvme id-ctrl '$dev' 2>&1 | sed -n '1,120p'" || true)"
}
monrep_zfs_status() {
  # ZFS status is safe read-only, but tools may not exist.
  if ! command -v zpool >/dev/null 2>&1 && ! command -v zfs >/dev/null 2>&1; then
    ui_msg "$MONREP_TITLE" "ZFS tools not found.\n\nInstall via: APT -> ZFS\n\nSuggested package:\n  zfsutils-linux"
    return 1
  fi

  local txt=""
  if command -v zpool >/dev/null 2>&1; then
    txt+=$'=== zpool status ===\n'
    txt+="$(monrep_cmd_capture "zpool status 2>&1" || true)"
    txt+=$'\n\n'
  fi
  if command -v zfs >/dev/null 2>&1; then
    txt+=$'=== zfs list ===\n'
    txt+="$(monrep_cmd_capture "zfs list 2>&1" || true)"
    txt+=$'\n\n'
  fi

  monrep_show_text "$MONREP_TITLE" "$txt"
}


monrep_storage_menu() {
  while true; do
    local sel
    sel="$(ui_menu "$MONREP_TITLE" "Storage health:" \
      "SMART" "🧠 SMART health (smartctl)" \
      "NVME"  "⚡ NVMe health (nvme-cli)" \
      "ZFS"   "🧊 ZFS status (zpool/zfs)" \
      "LSBLK" "🧾 Block device map (lsblk)" \
      "BACK"  "🔙️ Back")" || return 0

    dast_log info "$module_id" "Menu selection: $sel"

    dast_dbg "$module_id" "Menu selection: $sel"

    case "$sel" in
      SMART) monrep_smart_summary ;;
      NVME)  monrep_nvme_health ;;
      ZFS)   monrep_zfs_status ;;
      LSBLK) monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL 2>&1" || true)" ;;
      BACK)  return 0 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Network status
# -----------------------------------------------------------------------------
monrep_network_overview() {
  monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "ip -br addr 2>&1; echo; ip route 2>&1; echo; ss -tulpn 2>&1 | sed -n '1,220p'" || true)"
}

monrep_iface_detail() {
  monrep_need_tool ethtool ethtool "Interface details use ethtool." || return 1
  local iface
  iface="$(monrep_pick_iface)" || return 1
  monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "ip -details addr show dev '$iface' 2>&1; echo; ethtool '$iface' 2>&1; echo; ethtool -S '$iface' 2>/dev/null | sed -n '1,220p' || true" || true)"
}

monrep_network_menu() {
  while true; do
    local sel
    sel="$(ui_menu "$MONREP_TITLE" "Network:" \
      "OVERVIEW" "🌐 Overview (IP/routes/ports)" \
      "IFACE"    "🔌 Interface details (ethtool)" \
      "BACK"     "🔙️ Back")" || return 0

    case "$sel" in
      OVERVIEW) monrep_network_overview ;;
      IFACE)    monrep_iface_detail ;;
      BACK)     return 0 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Logs (safe read-only summaries)
# -----------------------------------------------------------------------------
monrep_logs_menu() {
  while true; do
    local sel
    sel="$(ui_menu "$MONREP_TITLE" "Logs:" \
      "JOURNAL1H" "📜 Journal warnings/errors (last 1 hour)" \
      "JOURNAL24" "📜 Journal warnings/errors (last 24 hours)" \
      "DMESG"     "🧾 Kernel ring buffer (dmesg tail)" \
      "BOOT"      "🧯 Boot errors (journal -b)" \
      "BACK"      "🔙️ Back")" || return 0

    case "$sel" in
      JOURNAL1H)
        if command -v journalctl >/dev/null 2>&1; then
          monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "journalctl -p warning..alert --since '1 hour ago' --no-pager 2>&1 | tail -n 400" || true)"
        else
          ui_msg "$MONREP_TITLE" "journalctl not found (systemd required)."
        fi
        ;;
      JOURNAL24)
        if command -v journalctl >/dev/null 2>&1; then
          monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "journalctl -p warning..alert --since '24 hours ago' --no-pager 2>&1 | tail -n 600" || true)"
        else
          ui_msg "$MONREP_TITLE" "journalctl not found (systemd required)."
        fi
        ;;
      DMESG)
        if command -v dmesg >/dev/null 2>&1; then
          monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "dmesg -T 2>&1 | tail -n 250" || true)"
        else
          ui_msg "$MONREP_TITLE" "dmesg not found."
        fi
        ;;
      BOOT)
        if command -v journalctl >/dev/null 2>&1; then
          monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "journalctl -b -p warning..alert --no-pager 2>&1 | tail -n 500" || true)"
        else
          ui_msg "$MONREP_TITLE" "journalctl not found (systemd required)."
        fi
        ;;
      BACK) return 0 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Sensors / temps
# -----------------------------------------------------------------------------
monrep_sensors_menu() {
  while true; do
    local sel
    sel="$(ui_menu "$MONREP_TITLE" "Sensors:" \
      "SENSORS" "🌡 sensors (lm-sensors)" \
      "THERMAL" "🔥 Thermal zones (/sys/class/thermal)" \
      "BACK"    "🔙️ Back")" || return 0

    case "$sel" in
      SENSORS)
        monrep_need_tool sensors lm-sensors "Hardware sensor reporting uses lm-sensors." || continue
        monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture "sensors 2>&1" || true)"
        ;;
      THERMAL)
        monrep_show_text "$MONREP_TITLE" "$(monrep_cmd_capture '(
          shopt -s nullglob
          zones=(/sys/class/thermal/thermal_zone*)
          if [[ ${#zones[@]} -eq 0 ]]; then
            echo "No thermal zones found under /sys/class/thermal."
            exit 0
          fi
          for z in "${zones[@]}"; do
            t="$(cat "$z/type" 2>/dev/null || echo unknown)"
            temp_raw="$(cat "$z/temp" 2>/dev/null || echo "")"
            if [[ "$temp_raw" =~ ^[0-9]+$ ]]; then
              # Most kernels expose millidegrees C.
              temp_c=$(awk -v v="$temp_raw" "BEGIN{printf \"%.1f\", v/1000}")
              echo "$t: ${temp_c}°C  ($(basename "$z"))"
            else
              echo "$t: (no temp)  ($(basename "$z"))"
            fi
          done
        ) 2>&1' || true)"
        ;;
      BACK) return 0 ;;
    esac
  done
}
# -----------------------------------------------------------------------------
# Main module menu
# -----------------------------------------------------------------------------
module_MONREP() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  monrep_os_detect
  monrep_cfg_load

  while true; do
    local sel
    sel="$(ui_menu "$MONREP_TITLE" "Choose:" \
      "LIVE"     "📊 Live monitor (top/btop/htop)" \
      "SUMMARY"  "📋 Quick summary (uptime/mem/disk)" \
      "STORAGE"  "💽 Storage health (SMART/NVMe/ZFS)" \
      "NETWORK"  "🌐 Network status (IP/routes/ports)" \
      "LOGS"     "📜 Logs (journal/dmesg)" \
      "SENSORS"  "❄️  Sensors & temps" \
      "REPORT"   "🧾 View system report (preview)" \
      "EXPORT"   "📦 Export system report (to reports dir)" \
      "OPTS"     "🧩 Report options (sections/attachments)" \
      "RDIR"     "📁 Set report export directory" \
      "INSPECT"  "🔎 Inspect process (detailed)" \
      "KILL"     "🛑 Manage process (signal/kill)" \
      "PREF"     "🛠️  Set monitor preference (top/btop/htop/auto)" \
      "BACK"     "🔙️ Back")" || return 0

    case "$sel" in
      LIVE)
        run_monitor
        ;;
      SUMMARY)
        monrep_quick_summary
        ;;

STORAGE)
  monrep_storage_menu
  ;;
NETWORK)
  monrep_network_menu
  ;;
LOGS)
  monrep_logs_menu
  ;;
SENSORS)
  monrep_sensors_menu
  ;;
      REPORT)
        monrep_view_report_preview
        ;;
      EXPORT)
        monrep_export_report
        ;;
      OPTS)
        monrep_report_options_menu
        ;;

      RDIR)
        monrep_set_report_dir
        ;;
      INSPECT)
        monrep_inspect_pid
        ;;
      KILL)
        monrep_kill_pid
        ;;
      PREF)
        local p
        p="$(ui_menu "$MONREP_TITLE" "Choose process monitor preference:" \
          "top"  "📈 Always top (universal default)" \
          "btop" "🚀 Always btop" \
          "htop" "🧰 Always htop" \
          "auto" "✨ Auto (prefer btop, fallback htop, then top)" \
          "BACK" "🔙️ Back")" || continue

        [[ "$p" == "BACK" ]] && continue
        monrep_cfg_set "$p"
        monrep_cfg_load
        ui_msg "Saved" "PROCESS_MONITOR_PREF=$p"
        ;;
      BACK)
        return 0
        ;;
    esac
  done
}

if declare -F register_module >/dev/null 2>&1; then
  register_module "$module_id" "$module_title" "module_MONREP"
fi
