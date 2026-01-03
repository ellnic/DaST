#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Bootloader (v0.9.8.4)
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

module_id="BOOTLOAD"
module_title="🥾 Bootloader"
BOOTLOADER_TITLE="🥾 Bootloader"



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
# Shared helper integration (DaST v0.6+)
# -----------------------------------------------------------------------------
if ! declare -F run >/dev/null 2>&1 || ! declare -F run_capture >/dev/null 2>&1 || ! declare -F mktemp_safe >/dev/null 2>&1; then
  if [[ -r "${DAST_LIB_DIR:-./lib}/dast_helper.sh" ]]; then
    # shellcheck disable=SC1090
    source "${DAST_LIB_DIR:-./lib}/dast_helper.sh"
  elif [[ -r "$(dirname "${BASH_SOURCE[0]}")/lib/dast_helper.sh" ]]; then
    # shellcheck disable=SC1090
    source "$(dirname "${BASH_SOURCE[0]}")/lib/dast_helper.sh"
  elif [[ -r "./lib/dast_helper.sh" ]]; then
    # shellcheck disable=SC1090
    source "./lib/dast_helper.sh"
  fi
fi

# -----------------------------------------------------------------------------
# DaST logging/debug integration (surgical)
# -----------------------------------------------------------------------------
boot__log() {
  # Usage: boot__log LEVEL message...
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$@"
  fi
}

boot__dbg() {
  # Usage: boot__dbg message...
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$@"
  fi
}

# Breadcrumb if helper didn't load (no behaviour change, no stdout noise)
if ! declare -F run >/dev/null 2>&1 || ! declare -F run_capture >/dev/null 2>&1 || ! declare -F mktemp_safe >/dev/null 2>&1; then
  boot__log WARN "BOOTLOAD: helper functions missing (run/run_capture/mktemp_safe). Using local fallbacks."
  boot__dbg "BOOTLOAD: helper functions missing; sourced helper not found or incomplete."
fi

if ! declare -F run >/dev/null 2>&1; then
  run() { "$@"; }
fi
if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { "$@"; }
fi
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  mktemp_safe() { mktemp; }
fi

# -----------------------------------------------------------------------------
# Basics
# -----------------------------------------------------------------------------
boot_os_id() { . /etc/os-release 2>/dev/null; echo "${ID:-unknown}"; }
boot_arch() { uname -m 2>/dev/null || echo unknown; }
boot_is_efi() { [[ -d /sys/firmware/efi ]]; }

boot_confirm_defaultno() {
  local title="$1" msg="$2"
  if declare -F dial >/dev/null 2>&1; then
    dial --title "$title" --defaultno --yesno "$msg" 12 92 >/dev/null
  else
    ui_yesno "$title" "$msg"
  fi
}

boot_have_cmd() { command -v "$1" >/dev/null 2>&1; }

boot_grub_efi_target() {
  case "$(boot_arch)" in
    x86_64|amd64) echo "x86_64-efi" ;;
    i386|i486|i586|i686) echo "i386-efi" ;;
    aarch64|arm64) echo "arm64-efi" ;;
    armv7l|armv6l) echo "arm-efi" ;;
    *) echo "x86_64-efi" ;;
  esac
}

boot_grub_efi_bootloader_id() {
  local id
  id="$(boot_os_id)"
  case "$id" in
    ubuntu) echo "ubuntu" ;;
    debian) echo "debian" ;;
    pop|pop-os|popos) echo "Pop_OS" ;;
    linuxmint) echo "ubuntu" ;;
    *) echo "linux" ;;
  esac
}

boot_is_whole_disk_device() {
  local d="$1"
  [[ -z "$d" ]] && return 1
  [[ ! -b "$d" ]] && return 1

  if command -v lsblk >/dev/null 2>&1; then
    local t
    t="$(lsblk -no TYPE "$d" 2>/dev/null | head -n 1 || true)"
    [[ "$t" == "disk" ]] && return 0
  fi

  case "$d" in
    /dev/*[0-9]) return 1 ;;
    /dev/nvme*n*p[0-9]*) return 1 ;;
    /dev/mmcblk*p[0-9]*) return 1 ;;
  esac
  return 0
}

boot_detect_bootmgr() {
  BOOT_MODE="unknown"
  BOOTLOADER="unknown"
  BOOTLOADER_HINTS=""

  if boot_is_efi; then BOOT_MODE="efi"; else BOOT_MODE="bios"; fi

  if [[ -d /boot/loader ]] || [[ -d /efi/loader ]]; then
    if boot_have_cmd bootctl; then
      if bootctl status 2>/dev/null | grep -qi 'systemd-boot'; then
        BOOTLOADER="systemd-boot"
        BOOTLOADER_HINTS="Detected via bootctl status + loader directory."
        return 0
      fi
    else
      BOOTLOADER="systemd-boot"
      BOOTLOADER_HINTS="loader directory present, but bootctl not found."
      return 0
    fi
  fi

  if boot_have_cmd grub-install || boot_have_cmd grub-mkconfig || boot_have_cmd update-grub; then
    BOOTLOADER="grub"
    BOOTLOADER_HINTS="Detected via grub tools in PATH."
    return 0
  fi

  if [[ -f /boot/grub/grub.cfg ]] || [[ -d /boot/grub ]]; then
    BOOTLOADER="grub"
    BOOTLOADER_HINTS="Detected via /boot/grub presence."
    return 0
  fi

  BOOTLOADER="unknown"
  BOOTLOADER_HINTS="No common bootloader artefacts detected."
}

boot_guess_root_disk() {
  local src
  src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -z "$src" ]] && return 1

  if [[ "$src" == /dev/mapper/* ]]; then
    lsblk -no PKNAME "$src" 2>/dev/null | head -n 1 | sed 's#^#/dev/#' || true
    return 0
  fi

  if [[ "$src" == /dev/* ]]; then
    lsblk -no PKNAME "$src" 2>/dev/null | head -n 1 | sed 's#^#/dev/#' || true
    return 0
  fi

  return 1
}

# -----------------------------------------------------------------------------
# ESP detection + safe mount
# -----------------------------------------------------------------------------
boot_esp_mountpoint_current() {
  for mp in /boot/efi /efi; do
    if findmnt -n "$mp" >/dev/null 2>&1; then
      echo "$mp"
      return 0
    fi
  done
  return 1
}

boot_find_esp_device() {
  local dev fstype mp
  for mp in /boot/efi /efi; do
    if findmnt -n "$mp" >/dev/null 2>&1; then
      dev="$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)"
      fstype="$(findmnt -n -o FSTYPE "$mp" 2>/dev/null || true)"
      if [[ -n "$dev" && ( "$fstype" == "vfat" || "$fstype" == "fat" || "$fstype" == "msdos" ) ]]; then
        echo "$dev"
        return 0
      fi
    fi
  done

  boot_have_cmd blkid || return 1

  dev="$(blkid -t PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" -o device 2>/dev/null | head -n 1 || true)"
  [[ -n "$dev" ]] && { echo "$dev"; return 0; }

  dev="$(blkid -t PARTLABEL="EFI System Partition" -o device 2>/dev/null | head -n 1 || true)"
  [[ -n "$dev" ]] && { echo "$dev"; return 0; }

  return 1
}

boot_need_esp_mounted_or_stop() {
  if ! boot_is_efi; then
    ui_msg "$BOOTLOADER_TITLE" "Safeguard: Not in EFI mode.\n\nThis action requires EFI + a mounted ESP."
    return 1
  fi

  local esp_dev mp src fstype
  esp_dev="$(boot_find_esp_device || true)"
  [[ -z "$esp_dev" ]] && { ui_msg "$BOOTLOADER_TITLE" "Safeguard: Could not confidently detect an ESP device.\n\nRefusing this action."; return 1; }

  mp="$(boot_esp_mountpoint_current || true)"
  [[ -z "$mp" ]] && { ui_msg "$BOOTLOADER_TITLE" "Safeguard: ESP not mounted at /boot/efi or /efi.\n\nUse: Bootloader -> ESP -> Mount ESP safely"; return 1; }

  src="$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)"
  fstype="$(findmnt -n -o FSTYPE "$mp" 2>/dev/null || true)"

  [[ "$src" != "$esp_dev" ]] && { ui_msg "$BOOTLOADER_TITLE" "Safeguard: Mounted ESP source mismatch.\n\nExpected: $esp_dev\nMounted:  $src\n\nRefusing."; return 1; }
  [[ "$fstype" != "vfat" && "$fstype" != "fat" && "$fstype" != "msdos" ]] && { ui_msg "$BOOTLOADER_TITLE" "Safeguard: ESP filesystem type isn't FAT.\n\nMounted fstype: $fstype\n\nRefusing."; return 1; }

  return 0
}

boot_esp_evidence_to_file() {
  local out="$1"
  local esp_dev mp
  esp_dev="$(boot_find_esp_device || true)"
  mp="$(boot_esp_mountpoint_current || true)"

  {
    echo "ESP evidence (belt-and-braces)"
    echo
    echo "EFI mode: $(boot_is_efi && echo yes || echo no)"
    echo
    echo "Detected ESP device (confident): ${esp_dev:-"(not detected)"}"
    echo "Mounted ESP at: ${mp:-"(not mounted at /boot/efi or /efi)"}"
    if [[ -n "$mp" ]]; then
      echo
      echo "findmnt:"
      findmnt "$mp" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
    fi
    echo
    echo "lsblk:"
    if [[ -n "$esp_dev" ]]; then
      lsblk -o NAME,PATH,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTLABEL,PARTTYPE,MOUNTPOINTS "$esp_dev" 2>/dev/null || true
      echo
      echo "Parent disk:"
      local pk
      pk="$(lsblk -no PKNAME "$esp_dev" 2>/dev/null || true)"
      [[ -n "$pk" ]] && lsblk -o NAME,PATH,SIZE,FSTYPE,PARTLABEL,PARTTYPE,MOUNTPOINTS "/dev/$pk" 2>/dev/null || true
    else
      echo "(no esp_dev)"
    fi
    echo
    echo "blkid:"
    if boot_have_cmd blkid; then
      [[ -n "$esp_dev" ]] && blkid "$esp_dev" 2>/dev/null || true
    else
      echo "(blkid not installed)"
    fi
    echo
    echo "Note:"
    echo "- We refuse to guess ESP by 'TYPE=vfat' alone."
    echo "- If ESP cannot be confidently identified, mounting is refused."
  } >"$out"
}

boot_show_esp_evidence_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  boot_esp_evidence_to_file "$tmp"
  ui_textbox "$BOOTLOADER_TITLE" "$tmp"
}

boot_esp_mount_safe() {
  if ! boot_is_efi; then
    ui_msg "$BOOTLOADER_TITLE" "This system is not booted in EFI mode.\n\nESP mount is not applicable."
    return 0
  fi

  local esp_dev mp
  esp_dev="$(boot_find_esp_device || true)"
  if [[ -z "$esp_dev" ]]; then
    ui_msg "$BOOTLOADER_TITLE" "Could not confidently detect an ESP.\n\nSafeguard: refusing to mount."
    return 0
  fi

  mp="$(boot_esp_mountpoint_current || true)"
  if [[ -n "$mp" ]]; then
    ui_msg "$BOOTLOADER_TITLE" "ESP already mounted at:\n\n$mp\n\nDevice:\n$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)"
    return 0
  fi

  boot_show_esp_evidence_screen
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Proceed to mount the ESP?\n\nDevice:\n$esp_dev\n\nDefault is No." || { ui_msg "$BOOTLOADER_TITLE" "Cancelled."; return 0; }

  local choice
  choice="$(ui_menu "$BOOTLOADER_TITLE" "Choose mountpoint:" \
    "BOOTEFI" "📌 Mount at /boot/efi (recommended)" \
    "EFI"     "📌 Mount at /efi" \
    "CUSTOM"  "✍ Enter a custom mountpoint" \
    "BACK"    "🔙️ Back")" || return 0
  [[ "$choice" == "BACK" ]] && return 0

  case "$choice" in
    BOOTEFI) mp="/boot/efi" ;;
    EFI)     mp="/efi" ;;
    CUSTOM)
      mp="$(ui_input "$BOOTLOADER_TITLE" "Enter mountpoint:" "/boot/efi")" || return 0
      [[ -z "$mp" ]] && return 0
      ;;
    *) return 0 ;;
  esac

  if findmnt -n "$mp" >/dev/null 2>&1; then
    ui_msg "$BOOTLOADER_TITLE" "Mountpoint already in use:\n\n$mp\n\nSafeguard: refusing."
    return 0
  fi

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Final confirmation:\n\nMount ESP?\n\nDevice: $esp_dev\nMountpoint: $mp\n\nDefault is No." || { ui_msg "$BOOTLOADER_TITLE" "Cancelled."; return 0; }

  ui_programbox "$BOOTLOADER_TITLE" "\
    set -e; \
    mkdir -p '$mp'; \
    mount -t vfat '$esp_dev' '$mp'; \
    echo; \
    findmnt '$mp' -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true \
  2>&1 || true"
}

# -----------------------------------------------------------------------------
# Package cache safety nets (DaST-style)
# -----------------------------------------------------------------------------
boot_pkg_cache_root() {
  local d="/var/cache/dast/apt"
  if mkdir -p "$d/archives" >/dev/null 2>&1 && [[ -w "$d/archives" ]]; then
    echo "$d"
    return 0
  fi
  d="/tmp/dast-apt-cache"
  mkdir -p "$d/archives" >/dev/null 2>&1 || true
  echo "$d"
}

boot_pkg_installed() {
  local p="$1"
  dpkg -s "$p" >/dev/null 2>&1
}

boot_apt_update_optional() {
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Run apt-get update first?\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "apt-get update 2>&1 || true"
}

boot_cache_download_pkgs() {
  # Downloads .debs into DaST cache dir without installing
  local cache_dir
  cache_dir="$(boot_pkg_cache_root)"
  [[ -z "$cache_dir" ]] && return 1

  local -a pkgs=("$@")
  [[ "${#pkgs[@]}" -eq 0 ]] && return 0

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Pre-download packages to DaST cache?\n\nCache:\n$cache_dir/archives\n\nDefault is No." || return 0
  boot_apt_update_optional

  local cmd="DEBIAN_FRONTEND=noninteractive apt-get -y -d -o Dir::Cache::archives='$cache_dir/archives' install"
  local p
  for p in "${pkgs[@]}"; do
    [[ -n "$p" ]] && cmd+=" '$p'"
  done

  ui_programbox "$BOOTLOADER_TITLE" "$cmd 2>&1 || true"
}

boot_install_pkgs_cached() {
  # Uses DaST cache dir where possible
  local cache_dir
  cache_dir="$(boot_pkg_cache_root)"
  [[ -z "$cache_dir" ]] && return 1

  local -a pkgs=("$@")
  local -a missing=()
  local p

  for p in "${pkgs[@]}"; do
    [[ -z "$p" ]] && continue
    if ! boot_pkg_installed "$p"; then
      missing+=("$p")
    fi
  done

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  local msg="Missing packages:\n\n"
  for p in "${missing[@]}"; do msg+="- $p\n"; done
  msg+="\nDaST can cache packages first, then install.\n\nInstall now?\n\nDefault is No."
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "$msg" || return 1

  boot_cache_download_pkgs "${missing[@]}"

  local cmd="DEBIAN_FRONTEND=noninteractive apt-get -y -o Dir::Cache::archives='$cache_dir/archives' install"
  for p in "${missing[@]}"; do cmd+=" '$p'"; done
  ui_programbox "$BOOTLOADER_TITLE" "$cmd 2>&1 || true"
  return 0
}

# -----------------------------------------------------------------------------
# Rollback bundles (configs + ESP relevant dirs + state dump)
# -----------------------------------------------------------------------------
boot_backup_root() {
  local d="/var/backups/dast/bootloader"
  if mkdir -p "$d" >/dev/null 2>&1 && [[ -w "$d" ]]; then
    echo "$d"
    return 0
  fi
  d="/tmp/dast-bootloader-backups"
  mkdir -p "$d" >/dev/null 2>&1 || true
  echo "$d"
}

boot_backup_make() {
  local root ts dir
  root="$(boot_backup_root)"
  ts="$(date '+%Y%m%d-%H%M%S')"
  dir="$root/$ts"
  mkdir -p "$dir/files" "$dir/state" >/dev/null 2>&1 || { ui_msg "$BOOTLOADER_TITLE" "Could not create backup dir:\n\n$dir"; return 1; }

  # State dumps
  {
    echo "Timestamp: $ts"
    echo "OS: $(boot_os_id)"
    echo "Arch: $(boot_arch)"
    echo "EFI mode: $(boot_is_efi && echo yes || echo no)"
    echo "Kernel: $(uname -r 2>/dev/null || true)"
    echo
    echo "Cmdline:"
    cat /proc/cmdline 2>/dev/null || true
  } >"$dir/state/summary.txt"

  findmnt / /boot /boot/efi /efi >"$dir/state/findmnt.txt" 2>/dev/null || true
  lsblk -o NAME,PATH,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTLABEL,PARTTYPE,MOUNTPOINTS >"$dir/state/lsblk.txt" 2>/dev/null || true

  if boot_have_cmd efibootmgr; then
    efibootmgr -v >"$dir/state/efibootmgr.txt" 2>/dev/null || true
  fi
  if boot_have_cmd bootctl; then
    bootctl status >"$dir/state/bootctl_status.txt" 2>/dev/null || true
  fi

  # Config files
  [[ -f /etc/default/grub ]] && cp -a /etc/default/grub "$dir/files/" 2>/dev/null || true
  [[ -f /boot/grub/grub.cfg ]] && cp -a /boot/grub/grub.cfg "$dir/files/" 2>/dev/null || true
  [[ -d /boot/loader ]] && cp -a /boot/loader "$dir/files/" 2>/dev/null || true
  [[ -d /efi/loader ]] && cp -a /efi/loader "$dir/files/" 2>/dev/null || true

  # ESP selective backup if mounted and validated
  if boot_need_esp_mounted_or_stop >/dev/null 2>&1; then
    local mp
    mp="$(boot_esp_mountpoint_current || true)"
    if [[ -n "$mp" ]]; then
      mkdir -p "$dir/esp" >/dev/null 2>&1 || true
      # Only likely-relevant paths, not the entire ESP
      for p in "$mp/EFI/ubuntu" "$mp/EFI/debian" "$mp/EFI/systemd" "$mp/EFI/Linux" "$mp/loader"; do
        [[ -e "$p" ]] && cp -a "$p" "$dir/esp/" 2>/dev/null || true
      done
      printf '%s\n' "$mp" >"$dir/state/esp_mountpoint.txt"
      findmnt "$mp" -o TARGET,SOURCE,FSTYPE,OPTIONS >"$dir/state/esp_findmnt.txt" 2>/dev/null || true
    fi
  fi

  # Tar it up for portability
  (cd "$root" && tar -czf "$root/bootloader-$ts.tgz" "$ts" >/dev/null 2>&1) || true

  ui_msg "$BOOTLOADER_TITLE" "Rollback bundle created:\n\n$dir\n\nPortable archive:\n$root/bootloader-$ts.tgz"
  return 0
}

boot_backup_list() {
  local root
  root="$(boot_backup_root)"
  ls -1 "$root" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r || true
}

boot_backup_restore() {
  local root
  root="$(boot_backup_root)"

  local -a items=()
  local e
  while read -r e; do
    [[ -z "$e" ]] && continue
    items+=("$e" "🧯 Restore $e")
  done < <(boot_backup_list)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$BOOTLOADER_TITLE" "No rollback bundles found in:\n\n$root"
    return 0
  fi

  local sel
  sel="$(ui_menu "$BOOTLOADER_TITLE" "Select a rollback bundle to restore:" "${items[@]}" "BACK" "🔙️ Back")" || return 0
  [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

  local dir="$root/$sel"
  [[ -d "$dir" ]] || { ui_msg "$BOOTLOADER_TITLE" "Not found:\n\n$dir"; return 0; }

  ui_msg "$BOOTLOADER_TITLE" "Restore will:\n- Copy backed up configs back into place\n- Optionally restore ESP items (if ESP is mounted)\n\nIt will not magically fix firmware settings.\n\nDefault is No for each step."
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Proceed with restore from:\n\n$dir\n\nDefault is No." || return 0

  # Restore configs


  if [[ -f "$dir/files/grub.cfg" ]]; then
    boot_confirm_defaultno "$BOOTLOADER_TITLE" "Restore /boot/grub/grub.cfg ?\n\nDefault is No." || true
    if [[ $? -eq 0 ]]; then
      cp -a /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
      cp -a "$dir/files/grub.cfg" /boot/grub/grub.cfg 2>/dev/null || true
    fi
  fi

# /etc/default/grub
# Actually restore /etc/default/grub cleanly
# The file is saved as "grub" by cp -a /etc/default/grub into files/
  if [[ -f "$dir/files/grub" ]]; then
    boot_confirm_defaultno "$BOOTLOADER_TITLE" "Restore /etc/default/grub ?\n\nDefault is No." || true
    if [[ $? -eq 0 ]]; then
      cp -a /etc/default/grub "/etc/default/grub.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
      cp -a "$dir/files/grub" /etc/default/grub 2>/dev/null || true
    fi
  fi

  # Restore systemd-boot dirs if present
  if [[ -d "$dir/files/loader" ]]; then
    boot_confirm_defaultno "$BOOTLOADER_TITLE" "Restore loader directory backup to /boot/loader ?\n\nDefault is No." || true
    if [[ $? -eq 0 ]]; then
      mkdir -p /boot >/dev/null 2>&1 || true
      cp -a "$dir/files/loader" "/boot/loader.restore.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
      rm -rf /boot/loader 2>/dev/null || true
      cp -a "$dir/files/loader" /boot/loader 2>/dev/null || true
    fi
  fi

  # ESP restore if mounted now
  if boot_need_esp_mounted_or_stop >/dev/null 2>&1 && [[ -d "$dir/esp" ]]; then
    local mp
    mp="$(boot_esp_mountpoint_current || true)"
    if [[ -n "$mp" ]]; then
      boot_confirm_defaultno "$BOOTLOADER_TITLE" "Restore backed up ESP items to:\n\n$mp\n\nDefault is No." || true
      if [[ $? -eq 0 ]]; then
        ui_programbox "$BOOTLOADER_TITLE" "\
          set -e; \
          cp -a '$dir/esp/'* '$mp/' 2>/dev/null || true; \
          echo 'ESP restore attempt complete.' \
        2>&1 || true"
      fi
    fi
  fi

  ui_msg "$BOOTLOADER_TITLE" "Restore complete (as requested).\n\nRecommended next steps:\n- If GRUB: regenerate config\n- If systemd-boot: check entries\n- Review efibootmgr -v\n- Reboot and confirm"
}

# -----------------------------------------------------------------------------
# Info
# -----------------------------------------------------------------------------
boot_info_to_file() {
  local out="$1"
  boot_detect_bootmgr
  local esp_dev mp
  esp_dev="$(boot_find_esp_device || true)"
  mp="$(boot_esp_mountpoint_current || true)"

  {
    echo "Bootloader module"
    echo
    echo "OS: $(boot_os_id)"
    echo "Arch: $(boot_arch)"
    echo
    echo "Boot mode: $BOOT_MODE"
    echo "Bootloader: $BOOTLOADER"
    echo "Hints: $BOOTLOADER_HINTS"
    echo
    echo "Running kernel: $(uname -r 2>/dev/null || true)"
    echo
    echo "Mounts:"
    findmnt / /boot /boot/efi /efi 2>/dev/null || true
    echo
    echo "ESP device (confident): ${esp_dev:-"(not detected)"}"
    echo "ESP mounted at: ${mp:-"(not mounted)"}"
    if [[ -n "$mp" ]]; then
      findmnt "$mp" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
    fi
    echo
    echo "Root source:"
    findmnt -n -o SOURCE / 2>/dev/null || true
    echo
    echo "lsblk:"
    lsblk -o NAME,SIZE,FSTYPE,FSVER,LABEL,UUID,PARTLABEL,PARTTYPE,MOUNTPOINTS 2>/dev/null || true
    echo
    echo "efibootmgr:"
    if boot_have_cmd efibootmgr; then
      efibootmgr -v 2>/dev/null || true
    else
      echo "(efibootmgr not installed)"
    fi
    echo
    echo "bootctl:"
    if boot_have_cmd bootctl; then
      bootctl status 2>/dev/null || true
    else
      echo "(bootctl not available)"
    fi
  } >"$out"
}

boot_info_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  boot_info_to_file "$tmp"
  ui_textbox "$BOOTLOADER_TITLE" "$tmp"
}

# -----------------------------------------------------------------------------
# GRUB / systemd-boot ops
# -----------------------------------------------------------------------------
boot_regen_grub() {
  local cmd="update-grub"
  if boot_have_cmd grub-mkconfig && [[ ! -x "$(command -v update-grub 2>/dev/null)" ]]; then
    cmd="grub-mkconfig -o /boot/grub/grub.cfg"
  fi
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Regenerate GRUB config now?\n\nCommand:\n$cmd\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "$cmd 2>&1 || true"
}

boot_reinstall_grub_bios() {
  local disk
  disk="$(boot_guess_root_disk || true)"
  [[ -z "$disk" ]] && { ui_msg "$BOOTLOADER_TITLE" "Could not guess a target disk.\n\nUse manual grub-install if needed."; return 0; }

  boot_have_cmd grub-install || { ui_msg "$BOOTLOADER_TITLE" "grub-install not found.\n\nInstall: sudo apt-get install -y grub-pc"; return 0; }
  boot_is_whole_disk_device "$disk" || { ui_msg "$BOOTLOADER_TITLE" "Safeguard: target is not a whole disk:\n\n$disk\n\nRefusing."; return 0; }

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Reinstall GRUB to disk (BIOS/MBR)?\n\nDisk:\n$disk\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "grub-install --target=i386-pc '$disk' 2>&1 || true"
}

boot_reinstall_grub_efi() {
  boot_need_esp_mounted_or_stop || return 0

  local mp target id
  mp="$(boot_esp_mountpoint_current || true)"
  target="$(boot_grub_efi_target)"
  id="$(boot_grub_efi_bootloader_id)"

  boot_have_cmd grub-install || { ui_msg "$BOOTLOADER_TITLE" "grub-install not found.\n\nInstall: sudo apt-get install -y grub-efi-amd64"; return 0; }

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Reinstall GRUB to EFI now?\n\nESP: $mp\nTarget: $target\nID: $id\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "grub-install --target='$target' --efi-directory='$mp' --bootloader-id='$id' 2>&1 || true"
}

boot_systemdboot_install() {
  boot_is_efi || { ui_msg "$BOOTLOADER_TITLE" "systemd-boot requires EFI boot mode."; return 0; }
  boot_have_cmd bootctl || { ui_msg "$BOOTLOADER_TITLE" "bootctl not found."; return 0; }
  boot_need_esp_mounted_or_stop || return 0

  # Preview / sanity check: show what DaST believes is mounted as /boot and /boot/efi
  # before running bootctl install. This helps avoid non-standard ESP layouts.
  local _mnt_preview
  _mnt_preview="$(mktemp_safe)" || true
  if [[ -n "${_mnt_preview:-}" ]]; then
    {
      echo "Mount targets (findmnt):"
      echo "------------------------"
      findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /boot 2>/dev/null || echo "/boot: not a mountpoint (or not found)"
      findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /boot/efi 2>/dev/null || echo "/boot/efi: not a mountpoint (or not found)"
      echo
      echo "Block devices (lsblk):"
      echo "----------------------"
      lsblk -o NAME,PATH,FSTYPE,LABEL,PARTLABEL,PARTUUID,MOUNTPOINTS 2>/dev/null | sed -n '1,80p'
    } >"$_mnt_preview" 2>/dev/null || true
    ui_textbox "$BOOTLOADER_TITLE" "$_mnt_preview" || true
    rm -f "$_mnt_preview" 2>/dev/null || true
  fi

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Install / update systemd-boot (bootctl install)?\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "bootctl install 2>&1 || true; echo; bootctl status 2>&1 || true"
}

boot_edit_systemdboot_entry() {
  local base=""
  [[ -d /boot/loader/entries ]] && base="/boot/loader/entries"
  [[ -z "$base" && -d /efi/loader/entries ]] && base="/efi/loader/entries"
  [[ -z "$base" ]] && { ui_msg "$BOOTLOADER_TITLE" "No systemd-boot entries dir found."; return 0; }

  local -a items=()
  local f
  for f in "$base"/*.conf; do
    [[ -f "$f" ]] || continue
    items+=("$f" "🧾 $(basename "$f")")
  done
  [[ "${#items[@]}" -eq 0 ]] && { ui_msg "$BOOTLOADER_TITLE" "No entry files found in:\n\n$base"; return 0; }

  local sel
  sel="$(ui_menu "$BOOTLOADER_TITLE" "Choose an entry file to edit:" "${items[@]}" "BACK" "🔙️ Back")" || return 0
  [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

  local editor="${EDITOR:-nano}"
  clear || true
  "$editor" "$sel" || true
}

# -----------------------------------------------------------------------------
# systemd-boot entry wizard (safe, machine-local, no guessing across disks)
# -----------------------------------------------------------------------------
boot_sdb_entry_wizard() {
  boot_is_efi || { ui_msg "$BOOTLOADER_TITLE" "This wizard requires EFI boot mode."; return 0; }

  local mp
  mp="$(boot_esp_mountpoint_current || true)"
  if [[ -z "$mp" ]]; then
    ui_msg "$BOOTLOADER_TITLE" "ESP is not mounted at /boot/efi or /efi.\n\nMount it first via ESP helpers."
    return 0
  fi

  # Choose entries dir
  local entries="/boot/loader/entries"
  if [[ -d /efi/loader/entries && ! -d /boot/loader/entries ]]; then
    entries="/efi/loader/entries"
  fi
  mkdir -p "$entries" >/dev/null 2>&1 || true

  # Detect root UUID (prefer findmnt + blkid)
  local root_src root_uuid
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_uuid=""
  if boot_have_cmd blkid && [[ -n "$root_src" ]]; then
    root_uuid="$(blkid -s UUID -o value "$root_src" 2>/dev/null | head -n 1 || true)"
  fi

  local default_title
  default_title="$(boot_os_id) (systemd-boot)"
  local title
  title="$(ui_input "$BOOTLOADER_TITLE" "Entry title:" "$default_title")" || return 0
  [[ -z "$title" ]] && return 0

  local id
  id="$(ui_input "$BOOTLOADER_TITLE" "Entry filename id (no spaces). Example: linux\n\nThis becomes: <id>.conf" "linux")" || return 0
  [[ -z "$id" ]] && return 0
  id="${id// /_}"

  # Kernel/initrd paths. systemd-boot entries usually reference paths on the ESP.
  # We do not copy kernels automatically here, we just create the entry referencing common locations.
  local kpath initrd
  kpath="$(ui_input "$BOOTLOADER_TITLE" "Kernel path (relative to ESP root).\n\nCommon examples:\n/EFI/Linux/vmlinuz.efi\n/vmlinuz-linux\n\nEnter path:" "/EFI/Linux/vmlinuz.efi")" || return 0
  [[ -z "$kpath" ]] && return 0

  initrd="$(ui_input "$BOOTLOADER_TITLE" "Initrd path (relative to ESP root).\n\nCommon examples:\n/EFI/Linux/initrd.img\n\nEnter path (or blank for none):" "/EFI/Linux/initrd.img")" || return 0

  local opts_default opts
  opts_default="$(cat /proc/cmdline 2>/dev/null || true)"
  # Strip systemd-boot irrelevant bits if any, but keep it minimal. User can edit after.
  opts="$opts_default"
  if [[ -n "$root_uuid" ]]; then
    # If current cmdline has no root=, suggest one
    if ! grep -qE '(^| )root=' <<<"$opts_default"; then
      opts="root=UUID=$root_uuid $opts_default"
    fi
  fi

  opts="$(ui_input "$BOOTLOADER_TITLE" "Kernel options (cmdline).\n\nEdit carefully.\n\nSuggested:" "$opts")" || return 0
  [[ -z "$opts" ]] && return 0

  local file="$entries/$id.conf"
  local tmp
  tmp="$(mktemp_safe)" || return 0

  {
    echo "title   $title"
    echo "linux   $kpath"
    [[ -n "$initrd" ]] && echo "initrd  $initrd"
    echo "options $opts"
  } >"$tmp"

  ui_textbox "$BOOTLOADER_TITLE" "$tmp"

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Write entry file?\n\n$file\n\nDefault is No." || return 0
  cp -a "$file" "$file.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
  cat "$tmp" >"$file"

  ui_msg "$BOOTLOADER_TITLE" "Entry written:\n\n$file\n\nNext:\n- Ensure kernel/initrd actually exist on the ESP at those paths\n- Reboot and test"
}

# -----------------------------------------------------------------------------
# Guided bootloader switch with rollback + cache
# -----------------------------------------------------------------------------
boot_guided_switch_intro() {
  boot_detect_bootmgr
  ui_msg "$BOOTLOADER_TITLE" "Guided switch bootloader\n\nCurrent:\n- Boot mode: $BOOT_MODE\n- Bootloader: $BOOTLOADER\n\nSafety nets:\n- Rollback bundle before changes\n- Package cache download option\n- ESP validation (no loose guessing)\n- Defaults are No"
}

boot_guided_choose_target() {
  if [[ "$BOOT_MODE" == "efi" ]]; then
    ui_menu "$BOOTLOADER_TITLE" "Select target bootloader:" \
      "GRUB_EFI" "Switch to GRUB (EFI)" \
      "SDB"      "Switch to systemd-boot (EFI)" \
      "BACK"     "🔙️ Back"
  else
    ui_menu "$BOOTLOADER_TITLE" "Select target bootloader:" \
      "GRUB_BIOS" "Switch to GRUB (BIOS/MBR)" \
      "BACK"      "🔙️ Back"
  fi
}

boot_guided_install_grub_efi_pkgs() {
  local target
  target="$(boot_grub_efi_target)"
  local -a pkgs=("efibootmgr" "grub-common")
  case "$target" in
    x86_64-efi) pkgs+=("grub-efi-amd64") ;;
    i386-efi) pkgs+=("grub-efi-ia32") ;;
    arm64-efi) pkgs+=("grub-efi-arm64") ;;
    arm-efi) pkgs+=("grub-efi-arm") ;;
    *) pkgs+=("grub-efi-amd64") ;;
  esac
  # optional but helpful on many Ubuntu setups
  pkgs+=("shim-signed")
  boot_install_pkgs_cached "${pkgs[@]}"
}

boot_guided_install_grub_bios_pkgs() {
  boot_install_pkgs_cached "grub-pc" "grub-common"
}

boot_guided_install_sdb_pkgs() {
  boot_install_pkgs_cached "systemd" "efibootmgr"
}

boot_guided_ensure_esp() {
  if boot_need_esp_mounted_or_stop >/dev/null 2>&1; then
    return 0
  fi
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "ESP is not ready.\n\nRun safe ESP mount helper now?\n\nDefault is No." || return 1
  boot_esp_mount_safe
  boot_need_esp_mounted_or_stop
}

boot_guided_switch_to_grub_efi() {
  boot_is_efi || { ui_msg "$BOOTLOADER_TITLE" "Not in EFI mode. Cannot do GRUB EFI."; return 0; }

  ui_msg "$BOOTLOADER_TITLE" "Plan:\n1) Create rollback bundle\n2) Install packages (cached)\n3) Validate + mount ESP\n4) grub-install\n5) Generate config\n\nThen reboot."
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Proceed?\n\nDefault is No." || return 0

  boot_backup_make || true
  boot_guided_install_grub_efi_pkgs || true
  boot_guided_ensure_esp || { ui_msg "$BOOTLOADER_TITLE" "ESP not ready. Aborting."; return 0; }

  boot_have_cmd grub-install || { ui_msg "$BOOTLOADER_TITLE" "grub-install missing. Aborting."; return 0; }

  local mp target id
  mp="$(boot_esp_mountpoint_current || true)"
  target="$(boot_grub_efi_target)"
  id="$(boot_grub_efi_bootloader_id)"

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Final confirmation:\n\nInstall GRUB to EFI now?\nESP: $mp\nTarget: $target\nID: $id\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "\
    set -e; \
    grub-install --target='$target' --efi-directory='$mp' --bootloader-id='$id'; \
    echo; \
    (command -v update-grub >/dev/null 2>&1 && update-grub) || grub-mkconfig -o /boot/grub/grub.cfg \
  2>&1 || true"

  ui_msg "$BOOTLOADER_TITLE" "Done.\n\nIf reboot fails:\n- Boot recovery media\n- Mount root\n- Run DaST and use Rollback -> Restore"
}

boot_guided_switch_to_grub_bios() {
  ui_msg "$BOOTLOADER_TITLE" "Plan:\n1) Create rollback bundle\n2) Install packages (cached)\n3) grub-install to whole disk\n4) Generate config\n\nThen reboot."
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Proceed?\n\nDefault is No." || return 0

  boot_backup_make || true
  boot_guided_install_grub_bios_pkgs || true
  boot_have_cmd grub-install || { ui_msg "$BOOTLOADER_TITLE" "grub-install missing. Aborting."; return 0; }

  local disk
  disk="$(boot_guess_root_disk || true)"
  [[ -z "$disk" ]] && { ui_msg "$BOOTLOADER_TITLE" "Could not guess root disk. Aborting."; return 0; }
  boot_is_whole_disk_device "$disk" || { ui_msg "$BOOTLOADER_TITLE" "Safeguard: not a whole disk:\n\n$disk\n\nAborting."; return 0; }

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Final confirmation:\n\nInstall GRUB to:\n$disk\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "\
    set -e; \
    grub-install --target=i386-pc '$disk'; \
    echo; \
    (command -v update-grub >/dev/null 2>&1 && update-grub) || grub-mkconfig -o /boot/grub/grub.cfg \
  2>&1 || true"

  ui_msg "$BOOTLOADER_TITLE" "Done.\n\nIf reboot fails:\n- Boot recovery media\n- Run Rollback restore"
}

boot_guided_switch_to_systemdboot() {
  boot_is_efi || { ui_msg "$BOOTLOADER_TITLE" "Not in EFI mode. systemd-boot requires EFI."; return 0; }

  ui_msg "$BOOTLOADER_TITLE" "Plan:\n1) Create rollback bundle\n2) Install packages (cached)\n3) Validate + mount ESP\n4) bootctl install\n5) Optionally create an entry\n\nThen reboot."
  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Proceed?\n\nDefault is No." || return 0

  boot_backup_make || true
  boot_guided_install_sdb_pkgs || true
  boot_guided_ensure_esp || { ui_msg "$BOOTLOADER_TITLE" "ESP not ready. Aborting."; return 0; }

  boot_have_cmd bootctl || { ui_msg "$BOOTLOADER_TITLE" "bootctl missing. Aborting."; return 0; }

  boot_confirm_defaultno "$BOOTLOADER_TITLE" "Final confirmation:\n\nRun bootctl install now?\n\nDefault is No." || return 0
  ui_programbox "$BOOTLOADER_TITLE" "bootctl install 2>&1 || true; echo; bootctl status 2>&1 || true"

  if boot_confirm_defaultno "$BOOTLOADER_TITLE" "Create a systemd-boot entry now (wizard)?\n\nDefault is No." ; then
    boot_sdb_entry_wizard
  fi

  ui_msg "$BOOTLOADER_TITLE" "Done.\n\nIf reboot fails:\n- Boot recovery media\n- Run Rollback restore"
}

boot_guided_switch_bootloader() {
  boot_guided_switch_intro
  local sel
  sel="$(boot_guided_choose_target)" || return 0
  [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

  dast_log info "$module_id" "Menu selection: $sel"

  dast_dbg "$module_id" "Menu selection: $sel"

  case "$sel" in
    GRUB_EFI)  boot_guided_switch_to_grub_efi ;;
    GRUB_BIOS) boot_guided_switch_to_grub_bios ;;
    SDB)       boot_guided_switch_to_systemdboot ;;
    *) ui_msg "$BOOTLOADER_TITLE" "Unknown selection: $sel" ;;
  esac
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------
boot_menu_esp() {
  local esp_dev mp
  esp_dev="$(boot_find_esp_device || true)"
  mp="$(boot_esp_mountpoint_current || true)"
  ui_menu "$BOOTLOADER_TITLE" "ESP helpers (device: ${esp_dev:-none}, mounted: ${mp:-no})" \
    "ESP_INFO"  "🔎 Show ESP evidence" \
    "ESP_MOUNT" "📌 Mount ESP safely" \
    "BACK"      "🔙️ Back"
}

boot_menu_rollback() {
  ui_menu "$BOOTLOADER_TITLE" "Rollback and safety nets:" \
    "MAKE"   "🧯 Create rollback bundle now" \
    "RESTORE" "🧯 Restore from rollback bundle" \
    "BACK"   "🔙️ Back"
}

boot_menu() {
  boot_detect_bootmgr
  ui_menu "$BOOTLOADER_TITLE" "Choose:" \
    "INFO"        "🥾 Boot overview" \
    "SWITCH"      "🧭 Switch bootloader (guided, rollback + cache)" \
    "SDB_ENTRY"   "🧩 systemd-boot entry wizard (create local entry)" \
    "ESP"         "🧩 ESP helpers" \
    "ROLLBACK"    "🧯 Rollback bundles (create/restore)" \
    "GRUB_REGEN"  "🧰 Regenerate GRUB config" \
    "GRUB_EFI"    "🔁 Reinstall GRUB (EFI)" \
    "GRUB_BIOS"   "🔁 Reinstall GRUB (BIOS/MBR)" \
    "SDB_INSTALL" "📥 Install / update systemd-boot (bootctl install)" \
    "SDB_ENT"     "🧾 Edit systemd-boot entry (manual)" \
    "BACK"        "🔙️ Back"
}

module_BOOTLOADER() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  while true; do
    local sel
    sel="$(boot_menu)" || return 0
    [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

    case "$sel" in
      INFO)      boot_info_screen ;;
      SWITCH)    boot_guided_switch_bootloader ;;
      SDB_ENTRY) boot_sdb_entry_wizard ;;
      ESP)
        while true; do
          local esel
          esel="$(boot_menu_esp)" || break
          [[ -z "$esel" || "$esel" == "BACK" ]] && break
          case "$esel" in
            ESP_INFO)  boot_show_esp_evidence_screen ;;
            ESP_MOUNT) boot_esp_mount_safe ;;
          esac
        done
        ;;
      ROLLBACK)
        while true; do
          local rsel
          rsel="$(boot_menu_rollback)" || break
          [[ -z "$rsel" || "$rsel" == "BACK" ]] && break
          case "$rsel" in
            MAKE) boot_backup_make ;;
            RESTORE) boot_backup_restore ;;
          esac
        done
        ;;
      GRUB_REGEN)  boot_regen_grub ;;
      GRUB_EFI)    boot_reinstall_grub_efi ;;
      GRUB_BIOS)   boot_reinstall_grub_bios ;;
      SDB_INSTALL) boot_systemdboot_install ;;
      SDB_ENT)     boot_edit_systemdboot_entry ;;
      *) ui_msg "$BOOTLOADER_TITLE" "Unknown selection: $sel" ;;
    esac
  done
}

register_module "$module_id" "$module_title" "module_BOOTLOADER"