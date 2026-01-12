#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: System (v0.9.8.4)
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

module_id="SYSTEM"
module_title="💻 System"
MODULE_SYSTEM_TITLE="💻 System"

# -----------------------------------------------------------------------------
# Logging helpers (uses DaST main helpers if present)
# -----------------------------------------------------------------------------
system__log() {
  # Usage: system__log LEVEL message...
  if declare -F dast_log >/dev/null 2>&1; then
    local level="$1"; shift || true
    dast_log "$level" "$module_id" "$*"
  fi
}

system__dbg() {
  # Usage: system__dbg message...
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$module_id" "$*"
  fi
}


# -----------------------------------------------------------------------------
# Best-effort helper loading (run/run_capture/mktemp_safe)
# - Won't hard-fail if the helper can't be found, so the module still
#   registers and at least menus/info work.
# -----------------------------------------------------------------------------
system__try_source_helper() {
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
    # Common layouts:
    #   modules/10_system.sh  -> lib/dast_helper.sh
    #   modules/..            -> lib/..
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

  system__log "WARN" "dast_helper.sh not found; falling back to local stubs (module may have reduced functionality)."
  return 1
}

# Attempt helper load at source-time (safe; if it fails, we continue)
system__try_source_helper >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Safe stubs if helper wasn't loaded
# -----------------------------------------------------------------------------
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  mktemp_safe() {
    # Local fallback (best-effort).
    # IMPORTANT: Do NOT use a RETURN trap here, or the temp file will be deleted
    # as soon as the function returns.
    local _tmp
    _tmp="$(mktemp)" || return 1

    # If the main loader provides temp registration, use it so cleanup is guaranteed.
    if declare -F _dast_tmp_register >/dev/null 2>&1; then
      _dast_tmp_register "$_tmp" || true
    fi

    printf '%s\n' "$_tmp"
  }
fi


if ! declare -F run >/dev/null 2>&1; then
  run() { "$@"; }
fi

if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { "$@"; }
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

system__is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

system__need_root() {
  local what="$1"
  if system__is_root; then
    return 0
  fi
  ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Root required\n\n$what\n\nRe-run DaST with sudo (or run this module from a root shell)."
  return 1
}

system__cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

system__crumb() {
  # Usage: system__crumb "System info" "CPU"
  local parts=()
  while [[ $# -gt 0 ]]; do
    parts+=("$1")
    shift
  done

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "$MODULE_SYSTEM_TITLE"
    return 0
  fi

  local out="$MODULE_SYSTEM_TITLE"
  local p
  for p in "${parts[@]}"; do
    out+=" 🔹 $p"
  done
  echo "$out"
}

system__textbox_from_cmd() {
  local title="$1"; shift

  (
    local tmp
    tmp="$(mktemp_safe)" || exit 0

    {
      echo "Command:"
      echo "  $*"
      echo
      "$@" 2>&1 || true
    } >"$tmp"

    ui_textbox "$title" "$tmp"
  )
}

system__validate_hostname() {
  # RFC-ish: labels [a-z0-9]([a-z0-9-]{0,61}[a-z0-9])? separated by dots
  local h="$1"
  [[ -n "$h" ]] || return 1
  [[ ${#h} -le 253 ]] || return 1
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || return 1
  return 0
}

system__locale_supported() {
  local loc="$1"
  [[ -n "$loc" ]] || return 1

  if [[ -r /usr/share/i18n/SUPPORTED ]]; then
    grep -Fxq "$loc" /usr/share/i18n/SUPPORTED
    return $?
  fi

  locale -a 2>/dev/null | grep -Fxq "$loc"
}

system__ensure_locale_gen() {
  # Ensure a locale is enabled in /etc/locale.gen
  local loc="$1"
  [[ -f /etc/locale.gen ]] || return 1

  local match="$loc"
  local line_to_add

  if [[ "$loc" =~ [[:space:]] ]]; then
    line_to_add="$loc"
  else
    line_to_add="$loc UTF-8"
  fi

  # Escape for ERE
  local esc="$match"
  esc="${esc//\\/\\\\}"
  esc="${esc//./\\.}"
  esc="${esc//+/\\+}"
  esc="${esc//*/\\*}"
  esc="${esc//?/\\?}"
  esc="${esc//[/\\[}"
  esc="${esc//]/\\]}"
  esc="${esc//(/\\(}"
  esc="${esc//)/\\)}"
  esc="${esc//\{/\\{}"
  esc="${esc//\}/\\}}"
  esc="${esc//^/\\^}"
  esc="${esc//\$/\\$}"
  esc="${esc//|/\\|}"

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${esc}([[:space:]]|$)" /etc/locale.gen; then
    run sed -i -E "s|^[[:space:]]*#[[:space:]]*(${esc})([[:space:]].*)?$|\1\2|" /etc/locale.gen
  else
    echo "$line_to_add" >> /etc/locale.gen
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Main System menu
# -----------------------------------------------------------------------------

system_menu() {
  ui_menu "$MODULE_SYSTEM_TITLE" "Choose an option:" \
    "INFO"      "📊 System info" \
    "DATETIME"  "🕒 Date and time" \
    "LOCALES"   "🌍 Locales and language" \
    "HOSTNAME"  "🏷️  Hostname" \
    "BACK"      "🔙️ Back"
}

# -----------------------------------------------------------------------------
# System Info submenu
# -----------------------------------------------------------------------------

system_info_menu() {
  ui_menu "$(system__crumb "System info")" "Choose an option:" \
    "OVERVIEW"    "📊 System overview" \
    "OS"          "🐧 OS / kernel details" \
    "CPU"         "🧠 CPU information" \
    "MEMORY"      "💾 Memory (RAM) usage" \
    "DISK"        "🗄️ Disk usage + mounts" \
    "STORAGE"     "📦 Block devices + filesystem details" \
    "SMART"       "🩺 SMART summary (if available)" \
    "PCI"         "🧩 PCI devices (lspci)" \
    "USB"         "🔌 USB devices (lsusb)" \
    "NETWORK"     "🌐 Network information" \
    "SERVICES"    "🧰 Key services status" \
    "BOOT"        "🥾 Boot + last reboot info" \
    "LOGS"        "📜 Recent system errors (journalctl)" \
    "UPTIME"      "🕒 Uptime + load averages" \
    "TEMPS"       "❄️ Temperatures / sensors (if available)" \
    "BACK"        "🔙️ Back"
}

system_info_run() {
  local action="$1"
  (
    local tmp
    tmp="$(mktemp_safe)" || exit 0

    case "$action" in
      OVERVIEW)
        {
          echo "Host: $(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
          echo "Uptime: $(uptime -p 2>/dev/null || true)"
          echo "Load: $(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || true)"
          echo
          echo "OS:"
          lsb_release -a 2>/dev/null || cat /etc/os-release 2>/dev/null || true
          echo
          echo "Kernel:"
          uname -a 2>/dev/null || true
          echo
          echo "CPU (summary):"
          (lscpu 2>/dev/null | sed -n '1,25p') || true
          echo
          echo "Memory:"
          free -h 2>/dev/null || true
          echo
          echo "Disk (df -h):"
          df -h 2>/dev/null || true
          echo
          echo "Network (ip -br a):"
          ip -br a 2>/dev/null || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      OS)
        {
          echo "OS release:"
          cat /etc/os-release 2>/dev/null || true
          echo
          echo "Kernel:"
          uname -a 2>/dev/null || true
          echo
          echo "Hostnamectl:"
          hostnamectl 2>/dev/null || true
          echo
          echo "Init system:"
          ps -p 1 -o comm= 2>/dev/null || true
          echo
          echo "Users (who):"
          who 2>/dev/null || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      CPU)
        {
          echo "CPU:"
          lscpu 2>/dev/null || true
          echo
          echo "Governor / scaling (if present):"
          if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
            echo "scaling_governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)"
            echo "scaling_driver:   $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || true)"
          else
            echo "(cpufreq info not available)"
          fi
          echo
          echo "Top CPU processes:"
          ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 25 || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      MEMORY)
        {
          echo "Memory:"
          free -h 2>/dev/null || true
          echo
          echo "vmstat (summary):"
          vmstat 1 2 2>/dev/null | tail -n 1 || true
          echo
          echo "Top memory processes:"
          ps -eo pid,ppid,comm,%mem,%cpu --sort=-%mem 2>/dev/null | head -n 25 || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      DISK)
        {
          echo "Disks (df -h):"
          df -h 2>/dev/null || true
          echo
          echo "Mounts (findmnt):"
          findmnt 2>/dev/null || cat /proc/mounts 2>/dev/null || true
          echo
          echo "Filesystem usage (df -i):"
          df -i 2>/dev/null || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      STORAGE)
        {
          echo "Block devices (lsblk):"
          lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null || lsblk 2>/dev/null || true
          echo
          echo "blkid (if available):"
          system__cmd_exists blkid && blkid 2>/dev/null || echo "(blkid not available)"
          echo
          echo "File systems (lsblk -f):"
          lsblk -f 2>/dev/null || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      SMART)
        {
          echo "SMART summary:"
          if system__cmd_exists smartctl; then
            echo "smartctl present."
            echo
            echo "Disks detected (lsblk TYPE=disk):"
            lsblk -dn -o NAME,TYPE,SIZE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1" ("$3")"}' || true
            echo
            echo "Tip: For full details, run smartctl -a /dev/sdX manually (may need sudo)."
          else
            echo "smartctl not installed."
            echo "Install: smartmontools (use your distro's package manager)"
          fi
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      PCI)
        {
          echo "PCI devices:"
          if system__cmd_exists lspci; then
            lspci -nnk 2>/dev/null || lspci 2>/dev/null || true
          else
            echo "lspci not installed."
            echo "Install: pciutils (use your distro's package manager)"
          fi
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      USB)
        {
          echo "USB devices:"
          if system__cmd_exists lsusb; then
            lsusb 2>/dev/null || true
            echo
            echo "USB tree (if available):"
            lsusb -t 2>/dev/null || true
          else
            echo "lsusb not installed."
            echo "Install: usbutils (use your distro's package manager)"
          fi
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      NETWORK)
        {
          echo "Interfaces (ip -br a):"
          ip -br a 2>/dev/null || true
          echo
          echo "Links (ip -br link):"
          ip -br link 2>/dev/null || true
          echo
          echo "Routes:"
          ip route 2>/dev/null || true
          echo
          echo "DNS (/etc/resolv.conf):"
          cat /etc/resolv.conf 2>/dev/null || true
          echo
          echo "Listening sockets (ss -tulpn, if available):"
          system__cmd_exists ss && ss -tulpn 2>/dev/null | sed -n '1,80p' || echo "(ss not available)"
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      SERVICES)
        {
          echo "Key services status:"
          if system__cmd_exists systemctl; then
            systemctl --no-pager --plain --type=service 2>/dev/null \
              | grep -Ei 'ssh|cron|systemd-resolved|NetworkManager|systemd-networkd|docker|containerd|tailscale|zfs|pve|fail2ban' \
              | sed -n '1,120p' || true
          else
            echo "(systemctl not available)"
          fi
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      BOOT)
        {
          echo "Last boot:"
          who -b 2>/dev/null || true
          echo
          echo "Uptime:"
          uptime 2>/dev/null || true
          echo
          echo "Recent reboots/shutdowns (last 20):"
          last -x 2>/dev/null | head -n 20 || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      LOGS)
        {
          echo "Recent system errors/warnings (journalctl -p 3..4, last 200):"
          if system__cmd_exists journalctl; then
            journalctl --no-pager -p 3..4 -n 200 2>/dev/null || true
          else
            echo "(journalctl not available)"
          fi
          echo
          echo "Kernel ring buffer (dmesg, last 120):"
          dmesg 2>/dev/null | tail -n 120 || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      UPTIME)
        {
          echo "Uptime:"
          uptime 2>/dev/null || true
          echo
          echo "Load averages (/proc/loadavg):"
          cat /proc/loadavg 2>/dev/null || true
          echo
          echo "Top CPU processes:"
          ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 25 || true
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      TEMPS)
        {
          echo "Temperatures / sensors:"
          if system__cmd_exists sensors; then
            sensors 2>/dev/null || true
          else
            echo "lm-sensors not installed."
            echo "Install: lm-sensors (use your distro's package manager)"
            echo
            echo "Fallback (thermal zones):"
            if [[ -d /sys/class/thermal ]]; then
              for tz in /sys/class/thermal/thermal_zone*/temp; do
                [[ -f "$tz" ]] || continue
                echo "$(basename "$(dirname "$tz")"): $(( $(cat "$tz" 2>/dev/null || echo 0) / 1000 ))°C"
              done
            else
              echo "(no /sys/class/thermal)"
            fi
          fi
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;

      BACK) ;;

      *)
        {
          echo "Unknown action: $action"
        } >"$tmp"
        ui_textbox "$(system__crumb "System info")" "$tmp"
        ;;
    esac
  )
}

system_info_loop() {
  while true; do
    local action
    action="$(system_info_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0
    system_info_run "$action"
  done
}

# -----------------------------------------------------------------------------
# Date and Time
# -----------------------------------------------------------------------------

datetime__get_ntp_state_raw() {
  # Returns: yes | no | unknown
  if system__cmd_exists timedatectl; then
    local v
    v="$(timedatectl show -p NTP --value 2>/dev/null || true)"
    case "$v" in
      yes|no) echo "$v"; return 0 ;;
    esac
  fi
  echo "unknown"
}

datetime__get_ntp_state_human() {
  local raw
  raw="$(datetime__get_ntp_state_raw)"
  case "$raw" in
    yes) echo "ON" ;;
    no)  echo "OFF" ;;
    *)   echo "UNKNOWN" ;;
  esac
}

datetime_menu() {
  local ntp_state
  ntp_state="$(datetime__get_ntp_state_human)"

  ui_menu "$(system__crumb "Date and time")" "Choose an option:" \
    "STATUS"      "📋 Show current date/time settings" \
    "TIMEZONE"    "🌐 Set timezone" \
    "NTP"         "📶 NTP sync (currently: $ntp_state)" \
    "SETTIME"     "📝 Set date/time manually" \
    "BACK"        "🔙️ Back"
}

datetime__zoneinfo_dir() {
  [[ -d /usr/share/zoneinfo ]] && echo "/usr/share/zoneinfo" || echo ""
}

datetime__list_tz_regions() {
  local zdir
  zdir="$(datetime__zoneinfo_dir)"
  [[ -z "$zdir" ]] && return 1

  find "$zdir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -Ev '^(posix|right|SystemV)$' \
    | sort -u
}

datetime__list_tz_under_region() {
  local region="$1"
  local zdir
  zdir="$(datetime__zoneinfo_dir)"
  [[ -z "$zdir" ]] && return 1
  [[ -z "$region" ]] && return 1
  [[ ! -d "$zdir/$region" ]] && return 1

  find "$zdir/$region" -type f -printf '%P\n' 2>/dev/null \
    | grep -Ev '(^|/)(posix|right)$' \
    | grep -Ev '(^|/)(zone\.tab|zone1970\.tab|tzdata\.zi|leapseconds|iso3166\.tab|posixrules|localtime|README)(/|$)' \
    | grep -Ev '^\.' \
    | awk -v r="$region" '{print r "/" $0}' \
    | sort -u
}

datetime__apply_timezone() {
  local tz="$1"
  local current="$2"

  if ! timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Invalid timezone: $tz\n\nThis didn't match timedatectl list-timezones."
    return 0
  fi

  ui_confirm "$MODULE_SYSTEM_TITLE" "Set timezone to:\n\n$tz\n\nCurrent: ${current:-unknown}\n\nProceed?" || return 0

  if run timedatectl set-timezone "$tz"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ Timezone set to: $tz"
  else
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Failed to set timezone to: $tz"
  fi
}

datetime_pick_timezone() {
  system__need_root "Setting timezone" || return 0

  if ! system__cmd_exists timedatectl; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ timedatectl not available.\n\nTimezone setting requires systemd tools."
    return 0
  fi

  local current zdir
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  zdir="$(datetime__zoneinfo_dir)"

  # Fallback: use timedatectl list-timezones if tzdata dir missing
  if [[ -z "$zdir" ]]; then
    local tz opts=() line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      opts+=("$line" "")
    done < <(timedatectl list-timezones 2>/dev/null | head -n 3000)

    tz="$(ui_menu "$(system__crumb "Date and time")" "Pick a timezone:\n\nCurrent: ${current:-unknown}" "${opts[@]}" "BACK" "🔙️ Back")" || return 0
    [[ "$tz" == "BACK" || -z "$tz" ]] && return 0

    datetime__apply_timezone "$tz" "$current"
    return 0
  fi

  # Step 1: region
  local region_opts=() region
  region_opts+=("UTC" "Coordinated Universal Time")
  local r
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    region_opts+=("$r" "")
  done < <(datetime__list_tz_regions || true)

  region="$(ui_menu "$(system__crumb "Date and time")" "Pick a region:\n\nCurrent: ${current:-unknown}" "${region_opts[@]}" "BACK" "🔙️ Back")" || return 0
  [[ "$region" == "BACK" || -z "$region" ]] && return 0

  if [[ "$region" == "UTC" ]]; then
    datetime__apply_timezone "UTC" "$current"
    return 0
  fi

  # Step 2: zone within region
  local tz_opts=() tz pretty
  while IFS= read -r tz; do
    [[ -z "$tz" ]] && continue
    pretty="${tz#${region}/}"
    pretty="${pretty//_/ }"
    tz_opts+=("$tz" "$pretty")
  done < <(datetime__list_tz_under_region "$region" || true)

  if [[ "${#tz_opts[@]}" -lt 2 ]]; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Couldn't enumerate timezones for region: $region\n\nCheck tzdata installation."
    return 0
  fi

  tz="$(ui_menu "$(system__crumb "Date and time")" "Pick a timezone:\n\nRegion: $region\nCurrent: ${current:-unknown}" "${tz_opts[@]}" "BACK" "🔙️ Back")" || return 0
  [[ "$tz" == "BACK" || -z "$tz" ]] && return 0

  datetime__apply_timezone "$tz" "$current"
}

datetime_status() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  {
    echo "Now: $(date)"
    echo
    if system__cmd_exists timedatectl; then
      timedatectl 2>/dev/null || true
    else
      echo "timedatectl not available."
      echo
      echo "Timezone env: ${TZ:-"(not set)"}"
      echo "Local time: $(date)"
      echo "UTC time:   $(date -u)"
    fi
  } >"$tmp"
  ui_textbox "$(system__crumb "Date and time")" "$tmp"
}

datetime_toggle_ntp() {
  system__need_root "Toggling NTP" || return 0
  system__cmd_exists timedatectl || {
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ timedatectl not available."
    return 0
  }

  local cur want cur_h
  cur="$(datetime__get_ntp_state_raw)"
  cur_h="$(datetime__get_ntp_state_human)"

  if [[ "$cur" == "yes" ]]; then
    want="no"
    ui_confirm "$MODULE_SYSTEM_TITLE" "Current NTP sync: ON\n\nDisable NTP sync?\n\nNote: This may affect time drift." || return 0
  elif [[ "$cur" == "no" ]]; then
    want="yes"
    ui_confirm "$MODULE_SYSTEM_TITLE" "Current NTP sync: OFF\n\nEnable NTP sync?" || return 0
  else
    local choice
    choice="$(ui_menu "$(system__crumb "Date and time")" "Current NTP sync: UNKNOWN\n\nWhat do you want to do?" \
      "ENABLE"  "Enable NTP sync" \
      "DISABLE" "Disable NTP sync" \
      "BACK"    "🔙️ Back")" || return 0
    case "$choice" in
      ENABLE)  want="yes" ;;
      DISABLE) want="no" ;;
      *) return 0 ;;
    esac
  fi

  if run timedatectl set-ntp "$want"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ NTP sync updated.\n\nWas: $cur_h\nNow: $(datetime__get_ntp_state_human)"
  else
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Failed to change NTP setting."
  fi
}

datetime_set_time_manual() {
  system__need_root "Setting date/time manually" || return 0
  system__cmd_exists timedatectl || {
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ timedatectl not available."
    return 0
  }

  local current input
  current="$(date '+%Y-%m-%d %H:%M:%S')"
  input="$(ui_inputbox "$(system__crumb "Date and time")" "NTP should usually be ON.\n\nEnter new date/time in this format:\nYYYY-MM-DD HH:MM:SS" "$current")" || return 0
  [[ -z "$input" ]] && return 0

  if ! date -d "$input" >/dev/null 2>&1; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Invalid date/time: $input\n\nExpected: YYYY-MM-DD HH:MM:SS"
    return 0
  fi

  ui_confirm "$MODULE_SYSTEM_TITLE" "Set system time to:\n\n$input\n\nThis can break TLS and logs if wrong. Proceed?" || return 0

  if run timedatectl set-time "$input"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ Time updated."
  else
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Failed to set time."
  fi
}

datetime_loop() {
  while true; do
    local action
    action="$(datetime_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      STATUS)   datetime_status ;;
      TIMEZONE) datetime_pick_timezone ;;
      NTP)      datetime_toggle_ntp ;;
      SETTIME)  datetime_set_time_manual ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Locales and Language
# -----------------------------------------------------------------------------

locales_menu() {
  ui_menu "$(system__crumb "Locales and language")" "Choose an option:" \
    "STATUS"   "📋 Show current locale settings" \
    "SETLANG"  "📝 Set LANG (and generate if needed)" \
    "GEN"      "🔄 Generate a locale (locale-gen)" \
    "BACK"     "🔙️ Back"
}

locales_status() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  {
    echo "Current locale (locale):"
    locale 2>/dev/null || true
    echo
    echo "localectl (if available):"
    system__cmd_exists localectl && localectl 2>/dev/null || echo "(localectl not available)"
    echo
    echo "/etc/default/locale:"
    [[ -f /etc/default/locale ]] && cat /etc/default/locale || echo "(missing)"
    echo
    echo "Generated locales (locale -a, first 60):"
    locale -a 2>/dev/null | sed -n '1,60p' || true
    echo
    echo "Supported locales file: /usr/share/i18n/SUPPORTED"
    [[ -r /usr/share/i18n/SUPPORTED ]] && echo "(present)" || echo "(missing)"
  } >"$tmp"
  ui_textbox "$(system__crumb "Locales and language")" "$tmp"
}

locales_generate_with_value() {
  local loc="$1"
  [[ -z "$loc" ]] && return 1

  system__need_root "Generating locales" || return 1

  if [[ -f /etc/locale.gen ]]; then
    system__ensure_locale_gen "$loc" || true
  fi

  system__cmd_exists locale-gen || return 1
  run locale-gen >/dev/null 2>&1 || return 1
  return 0
}

locales_generate() {
  system__need_root "Generating locales" || return 0

  local loc
  loc="$(ui_inputbox "$(system__crumb "Locales and language")" "Enter locale to generate (eg: en_GB.UTF-8):" "en_GB.UTF-8")" || return 0
  [[ -z "$loc" ]] && return 0

  if ! system__locale_supported "$loc"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Locale not found in SUPPORTED (or not present).\n\nLocale: $loc\n\nTip: check /usr/share/i18n/SUPPORTED or run locale -a."
    return 0
  fi

  ui_confirm "$MODULE_SYSTEM_TITLE" "Generate locale: $loc ?" || return 0

  if [[ -f /etc/locale.gen ]]; then
    system__ensure_locale_gen "$loc" || true
  fi

  if system__cmd_exists locale-gen; then
    if run locale-gen >/dev/null 2>&1; then
      ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ locale-gen completed."
    else
      ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ locale-gen failed."
    fi
  else
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ locale-gen not found.\n\nOn Debian/Ubuntu it lives in the locales package."
  fi
}

locales_set_lang() {
  system__need_root "Setting LANG" || return 0

  local current loc
  current="$(grep -E '^LANG=' /etc/default/locale 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true)"
  [[ -z "$current" ]] && current="$(locale 2>/dev/null | awk -F= '$1=="LANG"{print $2}' | head -n1 || true)"

  loc="$(ui_inputbox "$(system__crumb "Locales and language")" "Current LANG: ${current:-"(unknown)"}\n\nEnter new LANG (eg: en_GB.UTF-8):" "${current:-en_GB.UTF-8}")" || return 0
  [[ -z "$loc" ]] && return 0

  if ! system__locale_supported "$loc"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Locale not found in SUPPORTED (or not present).\n\nLocale: $loc\n\nI can still try to generate it via locale-gen first."
    ui_confirm "$MODULE_SYSTEM_TITLE" "Run locale-gen for $loc now?" || return 0
    locales_generate_with_value "$loc" || {
      ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ locale-gen failed for: $loc"
      return 0
    }
  else
    if system__cmd_exists locale-gen && [[ -f /etc/locale.gen ]]; then
      system__ensure_locale_gen "$loc" || true
      run locale-gen >/dev/null 2>&1 || true
    fi
  fi

  ui_confirm "$MODULE_SYSTEM_TITLE" "Set LANG to: $loc ?" || return 0

  if system__cmd_exists update-locale; then
    if run update-locale "LANG=$loc" >/dev/null 2>&1; then
      ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ LANG updated to: $loc\n\nLog out and back in (or reboot) for everything to pick it up."
    else
      ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ update-locale failed."
    fi
  else
    {
      echo "LANG=\"$loc\""
    } >/etc/default/locale
    ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ /etc/default/locale written.\n\nLog out and back in (or reboot) for everything to pick it up."
  fi
}

locales_loop() {
  while true; do
    local action
    action="$(locales_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      STATUS)  locales_status ;;
      SETLANG) locales_set_lang ;;
      GEN)     locales_generate ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Hostname
# -----------------------------------------------------------------------------

hostname_menu() {
  ui_menu "$(system__crumb "Hostname")" "Choose an option:" \
    "STATUS"  "📋 Show hostname and system IDs" \
    "SET"     "📝 Set hostname" \
    "BACK"    "🔙️ Back"
}

hostname_status() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  {
    echo "Hostname (hostname): $(hostname 2>/dev/null || true)"
    echo
    echo "hostnamectl (if available):"
    system__cmd_exists hostnamectl && hostnamectl 2>/dev/null || echo "(hostnamectl not available)"
    echo
    echo "/etc/hostname:"
    [[ -f /etc/hostname ]] && cat /etc/hostname || echo "(missing)"
    echo
    echo "/etc/hosts (first 80 lines):"
    [[ -f /etc/hosts ]] && sed -n '1,80p' /etc/hosts || echo "(missing)"
  } >"$tmp"
  ui_textbox "$(system__crumb "Hostname")" "$tmp"
}

hostname_set() {
  system__need_root "Setting hostname" || return 0

  local current new
  current="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"

  new="$(ui_inputbox "$(system__crumb "Hostname")" "Current hostname: ${current:-"(unknown)"}\n\nEnter new hostname (letters, digits, hyphen, dots allowed):" "$current")" || return 0
  [[ -z "$new" ]] && return 0

  new="${new,,}"

  if ! system__validate_hostname "$new"; then
    ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ Invalid hostname: $new\n\nRules:\n- letters/digits/hyphens only (and optional dots between labels)\n- no underscores\n- no leading/trailing hyphen\n- max 253 chars"
    return 0
  fi

  ui_confirm "$MODULE_SYSTEM_TITLE" "Set hostname to: $new ?\n\nThis may affect DHCP, mDNS, certs, and SSH known_hosts." || return 0

  if system__cmd_exists hostnamectl; then
    run hostnamectl set-hostname "$new" >/dev/null 2>&1 || {
      ui_msgbox "$MODULE_SYSTEM_TITLE" "❌ hostnamectl failed."
      return 0
    }
  else
    echo "$new" >/etc/hostname
    if ! hostname "$new" 2>/dev/null; then
      ui_msgbox "$MODULE_SYSTEM_TITLE" "🚨 Wrote /etc/hostname, but failed to set the runtime hostname via the hostname command.\n\nA reboot will usually apply the new hostname."
    fi
  fi

  # Ensure /etc/hostname is aligned
  echo "$new" >/etc/hostname

  # Best-effort /etc/hosts fix without nuking aliases:
  # - If a 127.0.1.1 line exists, replace ONLY the primary hostname token, preserving aliases/comments.
  # - If it doesn't exist, append a standard 127.0.1.1 entry.
  if [[ -f /etc/hosts ]]; then
    if grep -Eq '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
      local _hosts_tmp
      _hosts_tmp="$(mktemp_safe)" || true
      if [[ -n "${_hosts_tmp:-}" ]]; then
        run awk -v new="$new" '
          BEGIN { done=0 }
          /^[[:space:]]*127\.0\.1\.1[[:space:]]+/ && done==0 {
            line=$0
            comment=""
            h=index(line, "#")
            if (h>0) { comment=substr(line, h); line=substr(line, 1, h-1) }

            n=split(line, f, /[[:space:]]+/)
            # f[1]=127.0.1.1, f[2]=old hostname (may be missing), f[3..]=aliases
            out=f[1] "	" new
            for (i=3; i<=n; i++) if (f[i] != "") out=out "	" f[i]
            if (comment != "") out=out "	" comment
            print out
            done=1
            next
          }
          { print }
        ' /etc/hosts >"$_hosts_tmp" 2>/dev/null && run mv -f "$_hosts_tmp" /etc/hosts || true
      fi
    else
      if grep -Eq '^[[:space:]]*127\.0\.1\.1([[:space:]]|$)' /etc/hosts; then
        ui_msgbox "$MODULE_SYSTEM_TITLE" "⚠ /etc/hosts already contains a 127.0.1.1 entry, but DaST could not safely update it.

Your hostname *was* updated, but /etc/hosts was left unchanged to avoid creating duplicate entries.

If needed, update it manually:
127.0.1.1\t$new"
      else
        printf "\n127.0.1.1\t%s\n" "$new" >> /etc/hosts
      fi
    fi
  fi

  ui_msgbox "$MODULE_SYSTEM_TITLE" "✅ Hostname updated to: $new"
}

hostname_loop() {
  while true; do
    local action
    action="$(hostname_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      STATUS) hostname_status ;;
      SET)    hostname_set ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Module entrypoint
# -----------------------------------------------------------------------------

module_SYSTEM() {
  while true; do
    local action
    action="$(system_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      INFO)     system_info_loop ;;
      DATETIME) datetime_loop ;;
      LOCALES)  locales_loop ;;
      HOSTNAME) hostname_loop ;;
    esac
  done
}

# IMPORTANT: This is the bit that, if missing, makes the module vanish from menu.
register_module "$module_id" "$module_title" "module_SYSTEM"
