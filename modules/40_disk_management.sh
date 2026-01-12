#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Disk Management (non-ZFS) (v0.9.8.4)
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

module_id="DISKMGT"
module_title="💽 Disk Management"
MODULE_TITLE="💽 Disk Management"

# Target: normal disks and filesystems (ext4/xfs/btrfs/vfat/swap), not ZFS.
#
# Safety philosophy:
# - ZFS members are BLOCKED (refuse) to protect pools and prevent confusing imports.
# - System/root disk is WARNED heavily (user keeps final say).
# - mdraid/LVM/LUKS/bcache signatures WARN loudly; destructive actions require double-confirm.

# ----------------------------------------------------------------------------
# Logging wrappers (prefer DaST core helpers)
# ----------------------------------------------------------------------------
# These become no-ops if the main DaST script has not provided logging helpers.
diskmgmt__log() {
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$@"
  fi
}

diskmgmt__dbg() {
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$@"
  fi
}

# -----------------------------------------------------------------------------
# Shared lib loading (standard DaST pattern)
# -----------------------------------------------------------------------------
diskmgmt__try_source_helper() {
  # If the helper already loaded and defines run, we’re good
  declare -F run >/dev/null 2>&1 && return 0

  local here lib_try

  if [[ -n "${DAST_LIB_DIR:-}" && -r "${DAST_LIB_DIR}/dast_helper.sh" ]]; then
    # shellcheck source=/dev/null
    source "${DAST_LIB_DIR}/dast_helper.sh" && return 0
  fi

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

if ! diskmgmt__try_source_helper >/dev/null 2>&1; then
  diskmgmt__log "WARN" "DISKMGT: could not source dast_helper.sh; falling back to internal stubs."
fi

# -----------------------------------------------------------------------------
# Safe stubs (only used if shared lib not present)
# -----------------------------------------------------------------------------
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

if ! declare -F run >/dev/null 2>&1; then
  run() { "$@"; }
fi

if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { "$@"; }
fi

if ! declare -F ui_msgbox >/dev/null 2>&1; then
  ui_msgbox() { printf "\n[%s]\n%s\n\n" "$1" "$2" >&2; }
fi

if ! declare -F ui_yesno >/dev/null 2>&1; then
  ui_yesno() { return 1; }
fi

if ! declare -F ui_inputbox >/dev/null 2>&1; then
  ui_inputbox() { return 1; }
fi

if ! declare -F ui_textbox >/dev/null 2>&1; then
  ui_textbox() {
    local _title="$1"
    local _file="$2"
    local _msg="Textbox not available.\n\nFile:\n${_file}"

    # Labels-only: prevent dialog theme defaults (often "EXIT") leaking into view-only screens.
    if declare -F dast_ui_dialog >/dev/null 2>&1; then
      dast_ui_dialog --title "${_title}" --ok-label "Back" --msgbox "${_msg}" 12 70
      return $?
    fi
    if command -v dialog >/dev/null 2>&1; then
      dialog --title "${_title}" --ok-label "Back" --msgbox "${_msg}" 12 70
      return $?
    fi
    # Last-resort fallback.
    printf '%s\n' "${_title}" "${_msg}" >&2
    return 1
  }
fi

if ! declare -F ui_menu >/dev/null 2>&1; then
  ui_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    if command -v dialog >/dev/null 2>&1; then
      dast_ui_dialog --title "$title" --menu "$prompt" 20 92 14 "$@"
      return $?
    fi
    return 1
  }
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
diskmgmt__is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
diskmgmt__cmd_exists() { command -v "$1" >/dev/null 2>&1; }

diskmgmt__crumb() {
  local out="$MODULE_TITLE"
  local p
  for p in "$@"; do out+=" 🔹 $p"; done
  echo "$out"
}


# -----------------------------------------------------------------------------
# UI glyph safety (TTY/fragile mode)
# -----------------------------------------------------------------------------
# Some terminals (notably Linux TTY) render emoji as tofu boxes.
# For status "traffic lights", fall back to ASCII tags in fragile contexts.
diskmgmt__ui_avoid_emoji() {
  # Prefer DaST core detection if available.
  if declare -F dast_ui_is_fragile >/dev/null 2>&1; then
    dast_ui_is_fragile && return 0
  fi

  # Explicit overrides
  [[ "${DAST_NO_EMOJI:-}" == "1" ]] && return 0
  [[ "${DAST_UI_FRAGILE:-}" == "1" ]] && return 0

  # TERM hints (Linux console is commonly emoji-hostile)
  case "${TERM:-}" in
    linux|vt*|dumb) return 0 ;;
  esac

  # Locale hint (best-effort)
  if [[ -n "${LC_ALL:-}" ]]; then
    [[ "${LC_ALL}" != *UTF-8* && "${LC_ALL}" != *utf8* ]] && return 0
  elif [[ -n "${LANG:-}" ]]; then
    [[ "${LANG}" != *UTF-8* && "${LANG}" != *utf8* ]] && return 0
  fi

  return 1
}

diskmgmt__tl_ok()  { diskmgmt__ui_avoid_emoji && printf "[OK]"  || printf "🟢"; }
diskmgmt__tl_warn(){ diskmgmt__ui_avoid_emoji && printf "[WRN]" || printf "🟠"; }
diskmgmt__tl_bad() { diskmgmt__ui_avoid_emoji && printf "[NO ]" || printf "🔴"; }

diskmgmt__need_root() {
  local what="$1"
  if diskmgmt__is_root; then
    return 0
  fi
  ui_msgbox "$MODULE_TITLE" "❌ Root required\n\n$what\n\nRe-run DaST with sudo (or run from a root shell)."
  return 1
}

diskmgmt__require_tools() {
  local missing=()
  local t
  for t in "$@"; do
    diskmgmt__cmd_exists "$t" || missing+=("$t")
  done

  [[ ${#missing[@]} -gt 0 ]] || return 0

  # If we can, offer to install missing tools (prompt first, never auto).
  local can_offer_install=0
  local os_id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    os_id="${ID:-}"
  fi

  # KDE Neon must be instructions-only (no apt usage).
  if [[ "$os_id" == "neon" ]]; then
    can_offer_install=0
  elif diskmgmt__cmd_exists apt-get && diskmgmt__is_root; then
    can_offer_install=1
  fi

  local pm_hint="Install them with your package manager and retry."
  if diskmgmt__cmd_exists apt-get; then
    pm_hint="Install them and retry:

  apt-get update
  apt-get install ${missing[*]}"
  fi

  if [[ "$can_offer_install" -eq 1 ]]; then
    if ui_yesno "$MODULE_TITLE" "❌ Missing tools

This action needs:
  ${missing[*]}

Would you like DaST to install them now?

(You will see the apt output next.)"; then
      local tmp
      tmp="$(mktemp_safe)" || return 1
      {
        echo "Installing missing tools: ${missing[*]}"
        echo "--------------------------------------------------------------------------------"
        echo
        echo "Command:"
        echo "  apt-get update"
        echo "  apt-get install -y ${missing[*]}"
        echo
        echo "Output:"
        echo "--------------------------------------------------------------------------------"
        echo
        # Keep output contained to avoid dialog screen corruption.
        DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 || true
        echo
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" 2>&1 || true
      } >"$tmp"

      ui_textbox "$MODULE_TITLE" "$tmp"

      # Re-check after install attempt
      missing=()
      for t in "$@"; do
        diskmgmt__cmd_exists "$t" || missing+=("$t")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        ui_msgbox "$MODULE_TITLE" "❌ Still missing tools

These are still not available:
  ${missing[*]}

Please install manually (or check your apt sources) then retry."
        return 1
      fi
      return 0
    fi
  fi

  ui_msgbox "$MODULE_TITLE" "❌ Missing tools

This action needs:
  ${missing[*]}

$pm_hint"
  return 1
}

diskmgmt__yesno_default_no() {
  local title="$1"
  local msg="$2"

  # Unified dialog layer only. Default should be No.
  ui_yesno "$title" "$msg" 1
}




diskmgmt__is_device_mounted_or_busy() {
  local dev="$1"
  # Any mountpoint in the tree means busy
  lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -qv '^[[:space:]]*$' && return 0
  return 1
}

# Warning only: do not block
diskmgmt__warn_if_system_disk() {
  local disk="$1"

  local root_src root_disk
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -n "$root_src" ]]; then
    root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
    if [[ -n "$root_disk" && "/dev/$root_disk" == "$disk" ]]; then
      ui_msgbox "$MODULE_TITLE" "🚨 WARNING: System disk detected\n\nRoot filesystem appears to live on:\n  $disk\n\nYou can proceed, but destructive actions here can brick the system.\n\nIf you're not 100% sure, back out now."
    fi
  fi
  return 0
}

diskmgmt__type_to_confirm() {
  local title="$1"
  local prompt="$2"
  local confirm_text="$3"

  local typed
  typed="$(ui_inputbox "$title" "$prompt\n\nType exactly:\n$confirm_text" "")" || return 1
  typed="${typed//\"/}"
  typed="$(echo "$typed" | tr -d '[:space:]')"
  [[ "$typed" == "$confirm_text" ]]
}

diskmgmt__double_confirm_destroy() {
  local obj="$1"
  local scope="$2"

  if ! ui_yesno "$(diskmgmt__crumb "Confirm")" "🚨 Destructive operation ($scope)\n\nTarget:\n  $obj\n\nProceed?"; then
    return 1
  fi

  if ! diskmgmt__type_to_confirm "$(diskmgmt__crumb "Confirm")" \
      "Final check. You are about to destroy data." \
      "$obj"; then
    ui_msgbox "$MODULE_TITLE" "Cancelled (confirmation did not match)."
    return 1
  fi

  if ! diskmgmt__type_to_confirm "$(diskmgmt__crumb "Confirm")" \
      "Second confirmation. Type this phrase:" \
      "I_UNDERSTAND_DATA_WILL_BE_LOST"; then
    ui_msgbox "$MODULE_TITLE" "Cancelled (confirmation did not match)."
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Signature detection (ZFS + other member types)
# -----------------------------------------------------------------------------
diskmgmt__scan_signatures_raw() {
  local dev="$1"

  blkid -o export "$dev" 2>/dev/null | awk -v d="$dev" '
    $0 ~ /^TYPE=/     {print "DEV=" d " TYPE=" substr($0,6)}
    $0 ~ /^PTTYPE=/   {print "DEV=" d " PTTYPE=" substr($0,8)}
    $0 ~ /^PARTUUID=/ {print "DEV=" d " PARTUUID=" substr($0,10)}
    $0 ~ /^PARTLABEL=/{print "DEV=" d " PARTLABEL=" substr($0,11)}
    $0 ~ /^UUID=/     {print "DEV=" d " UUID=" substr($0,6)}
    $0 ~ /^LABEL=/    {print "DEV=" d " LABEL=" substr($0,7)}
  '

  # PARTTYPE (GPT partition type GUID) if available
  lsblk -no PARTTYPE "$dev" 2>/dev/null | awk -v d="$dev" 'NF{print "DEV=" d " PARTTYPE=" $0}'
}

diskmgmt__collect_dev_tree() {
  local dev="$1"
  if lsblk -no TYPE "$dev" 2>/dev/null | grep -qx "disk"; then
    {
      echo "$dev"
      lsblk -nr -o PATH "$dev" 2>/dev/null | tail -n +2
    } | awk 'NF' | sort -u
  else
    echo "$dev"
  fi
}

diskmgmt__signature_summary() {
  local dev="$1"
  local tmp
  tmp="$(mktemp_safe)" || return 1

  {
    echo "Signature scan for: $dev"
    echo "--------------------------------------------------------------------------------"
    echo
    echo "Tree (lsblk):"
    echo "--------------------------------------------------------------------------------"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,PARTTYPE,PARTLABEL,PARTUUID,MODEL -e7 "$dev" 2>/dev/null || true
    echo
    echo "Detected signatures (blkid export + PARTTYPE):"
    echo "--------------------------------------------------------------------------------"
    echo
    local d
    while read -r d; do
      diskmgmt__scan_signatures_raw "$d"
    done < <(diskmgmt__collect_dev_tree "$dev")
    echo
    echo "wipefs probe (non-destructive):"
    echo "--------------------------------------------------------------------------------"
    wipefs -n "$dev" 2>/dev/null || true
  } >"$tmp"

  ui_textbox "$(diskmgmt__crumb "Signatures")" "$tmp"
}

diskmgmt__is_zfs_member_by_signature() {
  local dev="$1"
  local d line

  # ZFS GPT partition type GUID (Solaris/ZFS):
  # 6A898CC3-1DD2-11B2-99A6-080020736631
  while read -r d; do
    while read -r line; do
      echo "$line" | grep -q ' TYPE=zfs_member' && return 0
      echo "$line" | grep -qi ' PARTTYPE=6a898cc3-1dd2-11b2-99a6-080020736631' && return 0
    done < <(diskmgmt__scan_signatures_raw "$d")
  done < <(diskmgmt__collect_dev_tree "$dev")

  return 1
}

diskmgmt__zpool_member_paths() {
  # parse /dev/* tokens from zpool status -P
  zpool status -P 2>/dev/null | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^\/dev\//) print $i
      }
    }
  ' | sed 's/[[:space:]]*$//' | awk 'NF' | sort -u
}

diskmgmt__is_zfs_member_by_zpool() {
  local dev="$1"
  diskmgmt__cmd_exists zpool || return 1

  local pool_paths
  pool_paths="$(diskmgmt__zpool_member_paths 2>/dev/null || true)"
  [[ -n "$pool_paths" ]] || return 1

  local d p
  while read -r d; do
    # exact match first
    echo "$pool_paths" | grep -Fxq "$d" && return 0

    # realpath match (handles /dev/disk/by-id/ vs /dev/sdX)
    local real_d
    real_d="$(readlink -f "$d" 2>/dev/null || true)"
    if [[ -n "$real_d" ]]; then
      while read -r p; do
        local real_p
        real_p="$(readlink -f "$p" 2>/dev/null || true)"
        [[ -n "$real_p" && "$real_p" == "$real_d" ]] && return 0
      done <<< "$pool_paths"
    fi
  done < <(diskmgmt__collect_dev_tree "$dev")

  return 1
}

diskmgmt__other_member_types() {
  local dev="$1"
  local d line
  local found=()

  while read -r d; do
    while read -r line; do
      echo "$line" | grep -q ' TYPE=linux_raid_member' && found+=("mdraid (linux_raid_member)")
      echo "$line" | grep -q ' TYPE=LVM2_member' && found+=("LVM PV (LVM2_member)")
      echo "$line" | grep -q ' TYPE=crypto_LUKS' && found+=("LUKS (crypto_LUKS)")
      echo "$line" | grep -q ' TYPE=bcache' && found+=("bcache")
    done < <(diskmgmt__scan_signatures_raw "$d")
  done < <(diskmgmt__collect_dev_tree "$dev")

  if [[ ${#found[@]} -gt 0 ]]; then
    printf "%s\n" "${found[@]}" | awk '!seen[$0]++'
  fi
}

diskmgmt__warn_other_member_types() {
  local dev="$1"
  local types
  types="$(diskmgmt__other_member_types "$dev" | paste -sd $'
' - 2>/dev/null || true)"
  [[ -z "$types" ]] && return 0

  ui_msgbox "$MODULE_TITLE" "🚨 RAID/volume signatures detected

Target: $dev

Detected signatures:
$types

This may be a member of mdraid/LVM/LUKS/bcache.

This is a warning only. Some actions (format, mount, fstab write) will ask for explicit confirmation before proceeding."
  return 0
}

diskmgmt__confirm_other_member_types() {
  local dev="$1"
  local action="${2:-"Proceed"}"
  local types
  types="$(diskmgmt__other_member_types "$dev" | paste -sd $'
' - 2>/dev/null || true)"
  [[ -z "$types" ]] && return 0

  # Hard blocks for ACTIVE members (do not allow format/partition ops to proceed)
  if echo "$types" | grep -q 'TYPE=lvm2_member'; then
    if command -v pvs >/dev/null 2>&1; then
      local vg
      vg="$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk 'NF{print $1; exit}')"
      if [[ -n "${vg:-}" ]]; then
        ui_msgbox "$MODULE_TITLE" "❌ REFUSED: Active LVM Physical Volume detected

Target: $dev
Volume Group: $vg

Remove it safely first (vgreduce/pvremove) before wiping or formatting."
        return 1
      fi
    fi
  fi

  if echo "$types" | grep -q 'TYPE=linux_raid_member'; then
    # Best-effort "active" check: if /proc/mdstat references this device/partition, refuse.
    if [[ -r /proc/mdstat ]]; then
      local bn
      bn="$(basename "$dev" 2>/dev/null || true)"
      if grep -qE "(^|[[:space:]])${bn}([[:space:]]|\[[0-9]+\])" /proc/mdstat 2>/dev/null; then
        ui_msgbox "$MODULE_TITLE" "❌ REFUSED: Active mdraid member detected

Target: $dev

The kernel currently has this device assembled into an md array (/proc/mdstat shows it).
Remove it cleanly with mdadm before wiping or formatting."
        return 1
      fi
    fi
  fi

  if ! ui_yesno "$(diskmgmt__crumb "Safety check")" "🚨 RAID/volume member detected

Action: $action
Target: $dev

Detected signatures:
$types

Proceeding can corrupt arrays, VGs, or encrypted volumes, and can cause permanent data loss.

If this is intentional, make sure you removed the device cleanly first (mdadm/vgreduce/pvremove/cryptsetup, etc.).

Proceed anyway?"; then
    ui_msgbox "$MODULE_TITLE" "Cancelled."
    return 1
  fi

  return 0
}

diskmgmt__refuse_if_zfs_member() {
  local dev="$1"

  if diskmgmt__is_zfs_member_by_signature "$dev" || diskmgmt__is_zfs_member_by_zpool "$dev"; then
    local tmp
    tmp="$(mktemp_safe)" || return 1
    {
      echo "REFUSED: ZFS member detected"
      echo "--------------------------------------------------------------------------------"
      echo
      echo "Target: $dev"
      echo
      echo "This device (or one of its partitions) appears to be a ZFS member."
      echo
      echo "Detection methods:"
      echo "- Signature scan: TYPE=zfs_member or ZFS GPT PARTTYPE"
      echo "- zpool status -P membership (if zpool is available)"
      echo
      echo "DaST Disk Management will not touch it until you remove it from the pool properly."
      echo
      echo "What to do (high level):"
      echo "1) Identify pool membership:"
      echo "   zpool status -P"
      echo
      echo "2) Remove/replace using ZFS:"
      echo "- Mirror: zpool detach <pool> <device>"
      echo "- Replace: zpool replace <pool> <old> <new>"
      echo "- RAIDZ: replace disk then wait for resilver"
      echo "- If supported: zpool remove <pool> <device>"
      echo
      echo "3) After it is no longer part of ANY pool, clear labels:"
      echo "   zpool labelclear -f <device or partition>"
      echo
      echo "Tip: Use 'Signature scan' in this module to see what was detected."
    } >"$tmp"
    ui_textbox "$(diskmgmt__crumb "Safety block")" "$tmp"
    return 1
  fi

  return 0
}

diskmgmt__extra_guidance_for_member_types() {
  cat <<'EOF'
Other member-type removals (high level):

mdraid:
- mdadm --detail /dev/mdX
- mdadm /dev/mdX --fail /dev/sdXN --remove /dev/sdXN
- mdadm --zero-superblock /dev/sdXN

LVM:
- pvs / vgs / lvs
- vgreduce <vg> /dev/sdXN
- pvremove /dev/sdXN

LUKS:
- cryptsetup status <name>
- cryptsetup luksClose <name> (if open)
- Only wipe/repartition when you understand what you are destroying
EOF
}

# -----------------------------------------------------------------------------
# Discovery and pickers
# -----------------------------------------------------------------------------
diskmgmt__show_disks() {
  local tmp
  tmp="$(mktemp_safe)" || return 1

  {
    echo "Disks (top-level only)"
    echo "--------------------------------------------------------------------------------"
    echo
    lsblk -d -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA,RM -e7 2>/dev/null | sed 's/[[:space:]]*$//'
    echo
    echo "Detailed tree (filesystems, UUIDs, mounts, PARTTYPE)"
    echo "--------------------------------------------------------------------------------"
    echo
    lsblk -o NAME,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS,PARTTYPE,PARTLABEL,PARTUUID,MODEL -e7 2>/dev/null
  } >"$tmp"

  ui_textbox "$(diskmgmt__crumb "Discovery")" "$tmp"
}

diskmgmt__sigscan_block_status() {
  # Returns two fields: "<icon>\t<reason>"
  # Icon uses DaST "traffic light" convention.
  # Reasons are short tokens to keep the overview table compact.
  local dev="$1"

  # Hard block: ZFS member (signature scan or zpool membership)
  if diskmgmt__is_zfs_member_by_signature "$dev" || diskmgmt__is_zfs_member_by_zpool "$dev"; then
    printf "%s\tZFS\n" "$(diskmgmt__tl_bad)"
    return 0
  fi

  # Warn: mounted/busy
  if diskmgmt__is_device_mounted_or_busy "$dev"; then
    printf "%s\tmounted\n" "$(diskmgmt__tl_warn)"
    return 0
  fi

  # Warn: system/root disk (best-effort detection, no popups here)
  local root_src root_disk
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -n "$root_src" ]]; then
    root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
    if [[ -n "$root_disk" && "/dev/$root_disk" == "$dev" ]]; then
      printf "%s\tsystem\n" "$(diskmgmt__tl_warn)"
      return 0
    fi
  fi

  # Warn: other member signatures (mdraid/LVM/LUKS/bcache etc)
  local types
  types="$(diskmgmt__other_member_types "$dev" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$types" ]]; then
    # Collapse to short reason tokens (keep it tight, deterministic).
    if echo "$types" | grep -qi 'raid'; then
      printf "%s\tmdraid\n" "$(diskmgmt__tl_warn)"
    elif echo "$types" | grep -qi 'lvm'; then
      printf "%s\tLVM\n" "$(diskmgmt__tl_warn)"
    elif echo "$types" | grep -qi 'luks'; then
      printf "%s\tLUKS\n" "$(diskmgmt__tl_warn)"
    elif echo "$types" | grep -qi 'bcache'; then
      printf "%s\tbcache\n" "$(diskmgmt__tl_warn)"
    else
      printf "%s\tmember\n" "$(diskmgmt__tl_warn)"
    fi
    return 0
  fi

  # OK
  printf "%s\t-\n" "$(diskmgmt__tl_ok)"
  return 0
}


diskmgmt__sigscan_pick_disk_menu() {
  # SIGSCAN-only picker:
  # - overview is the picker (no separate textbox)
  # - does NOT show the large discovery textbox
  # - uses safe lsblk -P parsing (MODEL can contain spaces)
  diskmgmt__require_tools lsblk || return 1

  local -a items=()
  local line NAME SIZE TRAN ROTA RM MODEL
  while IFS= read -r line; do
    NAME="" SIZE="" TRAN="" ROTA="" RM="" MODEL=""
    # Safe parse of lsblk -P output (no eval; values may contain spaces)
    local rest key val
    rest="$line"
    while [[ -n "$rest" ]]; do
      if [[ "$rest" =~ ^([A-Z0-9_]+)=\"([^\"]*)\"[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        case "$key" in
          NAME)  NAME="$val" ;;
          SIZE)  SIZE="$val" ;;
          TRAN)  TRAN="$val" ;;
          ROTA)  ROTA="$val" ;;
          RM)    RM="$val" ;;
          MODEL) MODEL="$val" ;;
        esac
      else
        break
      fi
    done
    [[ -z "$NAME" ]] && continue
    [[ "$NAME" == loop* ]] && continue
    [[ "$NAME" == zram* ]] && continue

    local dev="/dev/$NAME"

    # Normalise TRAN and classify media
    local tran med
    tran="${TRAN:-}"
    if [[ -z "$tran" && "$NAME" == nvme* ]]; then
      tran="nvme"
    fi

    # Media type (spindle/ssd/nvme) - prefer lsblk ROTA, but fall back to sysfs for reliability.
    med="?"
    if [[ "$NAME" == nvme* ]]; then
      med="nvme"
    elif [[ "${ROTA:-}" == "1" ]]; then
      med="spn"
    elif [[ "${ROTA:-}" == "0" ]]; then
      med="ssd"
    else
      # Some environments omit ROTA; sysfs is usually present.
      local sys_rota=""
      if [[ -r "/sys/block/$NAME/queue/rotational" ]]; then
        sys_rota="$(cat "/sys/block/$NAME/queue/rotational" 2>/dev/null || true)"
      fi
      if [[ "$sys_rota" == "1" ]]; then
        med="spn"
      elif [[ "$sys_rota" == "0" ]]; then
        med="ssd"
      fi
    fi

    # Block / warn status: traffic light + short reason token
    local status icon reason
    status="$(diskmgmt__sigscan_block_status "$dev" 2>/dev/null || true)"
    icon="${status%%$'\t'*}"
    reason="${status#*$'\t'}"
    [[ -z "$icon" || "$icon" == "$status" ]] && icon="$(diskmgmt__tl_ok)"
    [[ -z "$reason" ]] && reason="-"

    # Compact description (keep it tight to avoid wide menus)
    local model_trim desc
    model_trim="${MODEL:-}"
    # Trim to reduce width; keep deterministic
    [[ -n "$model_trim" ]] && model_trim="${model_trim:0:28}"

    desc="$icon"

    # REASON column: show *why* DaST thinks operations are unsafe/blocked.
    # Keep it compact and column-aligned to avoid wide menus.
    local reason_disp
    reason_disp="$reason"
    [[ -z "$reason_disp" || "$reason_disp" == "-" ]] && reason_disp="OK"
    # Trim and pad to 8 chars for a stable column.
    reason_disp="${reason_disp:0:8}"
    printf -v reason_disp "%-8s" "$reason_disp"
    desc+=" $reason_disp"

    # Keep columns predictable and compact: ICON REASON | SIZE TRAN MED [rm] | MODEL

    local tran_disp med_disp
    tran_disp="${tran:-?}"
    med_disp="$med"
    [[ "$med_disp" == "?" ]] && med_disp="unk"

    desc+=" | ${SIZE:-?} $tran_disp $med_disp"
    [[ "${RM:-}" == "1" ]] && desc+=" rm"
    [[ -n "$model_trim" ]] && desc+=" | $model_trim"

    # Use NAME as the tag to keep the menu narrow; expand to /dev/NAME on return.
    items+=("$NAME" "$desc")
  done < <(lsblk -dn -o NAME,SIZE,TRAN,ROTA,RM,MODEL -P -e7 2>/dev/null)

  [[ ${#items[@]} -ge 2 ]] || { ui_msgbox "$MODULE_TITLE" "❌ No disks found."; return 1; }

  local sel
  sel="$(ui_menu "$(diskmgmt__crumb "SIGSCAN")" "Select a disk (overview)\nDisk scanning will take a few seconds, this is not destructive:" "${items[@]}")" || return 1
  printf "/dev/%s" "$sel"
}

diskmgmt__disk_info() {
  local disk="$1"
  local tmp
  tmp="$(mktemp_safe)" || return 1
  {
    echo "Disk: $disk"
    echo "--------------------------------------------------------------------------------"
    echo
    lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,PARTTYPE,PARTLABEL,PARTUUID,MODEL,SERIAL -e7 "$disk" 2>/dev/null || true
    echo
    echo "Partition table (parted -s print)"
    echo "--------------------------------------------------------------------------------"
    echo
    parted -s "$disk" print 2>&1 || true
  } >"$tmp"
  ui_textbox "$(diskmgmt__crumb "Disk info")" "$tmp"
}

diskmgmt__disk_info_merged() {
  local disk="$1"
  local tmp
  tmp="$(mktemp_safe)" || return 1

  local status icon reason
  status="$(diskmgmt__sigscan_block_status "$disk" 2>/dev/null || true)"
  icon="${status%%$'\t'*}"
  reason="${status#*$'\t'}"
  [[ -z "$icon" || "$icon" == "$reason" ]] && icon="?"
  [[ -z "$reason" || "$reason" == "$icon" ]] && reason="UNKNOWN"

  # Best-effort facts (keep lightweight; do not fail the whole view if any command errors)
  local size tran rota rm model serial
  size="$(lsblk -dn -o SIZE "$disk" 2>/dev/null || true)"
  tran="$(lsblk -dn -o TRAN "$disk" 2>/dev/null || true)"
  rota="$(lsblk -dn -o ROTA "$disk" 2>/dev/null || true)"
  rm="$(lsblk -dn -o RM "$disk" 2>/dev/null || true)"
  model="$(lsblk -dn -o MODEL "$disk" 2>/dev/null || true)"
  serial="$(lsblk -dn -o SERIAL "$disk" 2>/dev/null || true)"

  {
    echo "Disk: $disk"
    echo "Status: $icon  $reason"
    echo "Facts: size=${size:-?}, tran=${tran:-?}, rota=${rota:-?}, rm=${rm:-?}, model=${model:-?}, serial=${serial:-?}"
    echo "--------------------------------------------------------------------------------"
    echo
    lsblk -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,PARTTYPE,PARTLABEL,PARTUUID,MODEL,SERIAL -e7 "$disk" 2>/dev/null || true
    echo
    echo "Partition table (parted -s print)"
    echo "--------------------------------------------------------------------------------"
    echo
    parted -s "$disk" print 2>&1 || true
  } >"$tmp"

  ui_textbox "$(diskmgmt__crumb "Disk info")" "$tmp"
}

diskmgmt__picker_disks_menu() {
  diskmgmt__require_tools lsblk || return 1

  local -a items=()
  local name size model tran rota rm desc
  while IFS=$'\t' read -r name size model tran rota rm; do
    [[ -z "$name" ]] && continue
    [[ "$name" == loop* ]] && continue
    [[ "$name" == zram* ]] && continue

    desc="size=$size"
    [[ -n "$tran" ]] && desc+=", $tran"
    [[ "$rota" == "1" ]] && desc+=", hdd"
    [[ "$rota" == "0" ]] && desc+=", ssd"
    [[ "$rm" == "1" ]] && desc+=", removable"
    [[ -n "$model" ]] && desc+=", ${model:0:32}"

    items+=("/dev/$name" "$desc")
  done < <(lsblk -dn -o NAME,SIZE,MODEL,TRAN,ROTA,RM -e7 2>/dev/null | sed 's/[[:space:]]*$//' | awk -v OFS="\t" '{print $1,$2,$3,$4,$5,$6}')

  [[ ${#items[@]} -ge 2 ]] || { ui_msgbox "$MODULE_TITLE" "❌ No disks found."; return 1; }

  ui_menu "$(diskmgmt__crumb "Select disk")" "Select a disk device:" "${items[@]}"
}

diskmgmt__picker_partitions_menu() {
  diskmgmt__require_tools lsblk || return 1

  local -a items=()
  local path size fstype label mp pttype
  while IFS=$'\t' read -r path size fstype label mp pttype; do
    [[ -z "$path" ]] && continue

    local desc="size=$size"
    [[ -n "$fstype" ]] && desc+=", fs=$fstype"
    [[ -n "$label" ]] && desc+=", label=$label"
    [[ -n "$mp" ]] && desc+=", mnt=${mp:0:28}"
    [[ -n "$pttype" ]] && desc+=", pttype=${pttype:0:8}"

    items+=("$path" "$desc")
  done < <(lsblk -rpn -o PATH,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,PARTTYPE -e7 2>/dev/null | awk '
    $2=="part"{
      path=$1; size=$3; fstype=$4; label=$5;
      mp=""; pt="";
      if (NF>=7) { mp=$(NF-1); pt=$NF; }
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", path, size, fstype, label, mp, pt
    }')

  [[ ${#items[@]} -ge 2 ]] || { ui_msgbox "$MODULE_TITLE" "❌ No partitions found."; return 1; }

  ui_menu "$(diskmgmt__crumb "Select partition")" "Select a partition device:" "${items[@]}"
}

diskmgmt__pick_disk() {
  diskmgmt__show_disks >/dev/null 2>&1 || true
  local disk
  disk="$(diskmgmt__picker_disks_menu)" || return 1
  disk="${disk//\"/}"
  disk="$(echo "$disk" | tr -d '[:space:]')"
  [[ -n "$disk" && "$disk" == /dev/* && -b "$disk" ]] || return 1
  echo "$disk"
}

diskmgmt__pick_partition() {
  diskmgmt__show_disks >/dev/null 2>&1 || true
  local part
  part="$(diskmgmt__picker_partitions_menu)" || return 1
  part="${part//\"/}"
  part="$(echo "$part" | tr -d '[:space:]')"
  [[ -n "$part" && "$part" == /dev/* && -b "$part" ]] || return 1
  echo "$part"
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
diskmgmt__action_create_partitions_guided() {
  diskmgmt__need_root "Create partitions." || return 0
  diskmgmt__require_tools lsblk parted wipefs partprobe blkid wipefs || return 0

  local disk
  disk="$(diskmgmt__pick_disk)" || return 0

  diskmgmt__disk_info "$disk" || true
  diskmgmt__signature_summary "$disk" || true

  diskmgmt__refuse_if_zfs_member "$disk" || return 0
  diskmgmt__confirm_other_member_types "$disk" "Create partitions (guided)" || return 0
  diskmgmt__warn_if_system_disk "$disk" || true

  if diskmgmt__is_device_mounted_or_busy "$disk"; then
    ui_msgbox "$MODULE_TITLE" "❌ Refusing: device appears mounted/busy\n\n$disk (or a child partition) is mounted.\n\nUnmount everything first."
    return 0
  fi

  diskmgmt__double_confirm_destroy "$disk" "disk" || return 0

  local layout
  layout="$(ui_menu "$(diskmgmt__crumb "Partition" "Layout")" "Choose guided layout:" \
    "SINGLE"   "Single partition using all space (data disk)" \
    "BOOTROOT" "Two partitions: EFI (512M) + root/data (rest) (boot-friendly)" \
    "BACK"     "Back" \
  )" || return 0
  [[ "$layout" != "BACK" ]] || return 0

  local ptt label
  ptt="$(ui_menu "$(diskmgmt__crumb "Partition" "Table")" "Partition table type:" \
    "GPT"  "GPT (recommended)" \
    "MBR"  "MBR/DOS (legacy)" \
    "BACK" "Back" \
  )" || return 0
  [[ "$ptt" != "BACK" ]] || return 0
  label="gpt"
  [[ "$ptt" == "MBR" ]] && label="msdos"

  if ui_yesno "$(diskmgmt__crumb "Partition" "Wipe signatures")" \
      "Wipe existing filesystem signatures on $disk before creating partitions?\n\nRecommended for reused disks."; then
    run wipefs -a "$disk" || true
  fi

  run parted -s "$disk" mklabel "$label" || { ui_msgbox "$MODULE_TITLE" "❌ Failed to create partition table on $disk"; return 0; }

  if [[ "$layout" == "SINGLE" ]]; then
    run parted -s "$disk" mkpart primary 1MiB 100% || { ui_msgbox "$MODULE_TITLE" "❌ Failed to create partition."; return 0; }
  else
    run parted -s "$disk" mkpart ESP fat32 1MiB 513MiB || { ui_msgbox "$MODULE_TITLE" "❌ Failed to create EFI partition."; return 0; }
    run parted -s "$disk" set 1 esp on || true
    run parted -s "$disk" mkpart primary 513MiB 100% || { ui_msgbox "$MODULE_TITLE" "❌ Failed to create root/data partition."; return 0; }
  fi

  run partprobe "$disk" >/dev/null 2>&1 || true
  ui_msgbox "$MODULE_TITLE" "✅ Partitions created on $disk\n\nNext: Format partitions."
  diskmgmt__disk_info "$disk" || true
}

diskmgmt__action_delete_partition() {
  diskmgmt__need_root "Delete a partition." || return 0
  diskmgmt__require_tools lsblk parted partprobe blkid || return 0

  local disk
  disk="$(diskmgmt__pick_disk)" || return 0

  diskmgmt__disk_info "$disk" || true
  diskmgmt__signature_summary "$disk" || true

  diskmgmt__refuse_if_zfs_member "$disk" || return 0
  diskmgmt__confirm_other_member_types "$disk" "Create partitions (guided)" || return 0
  diskmgmt__warn_if_system_disk "$disk" || true

  if diskmgmt__is_device_mounted_or_busy "$disk"; then
    ui_msgbox "$MODULE_TITLE" "❌ Refusing: device appears mounted/busy\n\nUnmount partitions on $disk first."
    return 0
  fi

  local num
  num="$(ui_inputbox "$(diskmgmt__crumb "Partition" "Delete")" "Enter partition number to delete on $disk (example: 1):" "")" || return 0
  num="${num//\"/}"
  num="$(echo "$num" | tr -d '[:space:]')"
  [[ "$num" =~ ^[0-9]+$ ]] || { ui_msgbox "$MODULE_TITLE" "❌ Invalid number."; return 0; }

  if ! ui_yesno "$(diskmgmt__crumb "Partition" "Delete")" "🚨 Delete partition $num on:\n  $disk\n\nProceed?"; then
    return 0
  fi

  if ! diskmgmt__type_to_confirm "$(diskmgmt__crumb "Confirm")" \
      "Type the disk path to confirm delete of partition $num." \
      "$disk"; then
    ui_msgbox "$MODULE_TITLE" "Cancelled (confirmation did not match)."
    return 0
  fi

  if ! diskmgmt__type_to_confirm "$(diskmgmt__crumb "Confirm")" \
      "Second confirmation. Type this phrase:" \
      "I_UNDERSTAND_DATA_WILL_BE_LOST"; then
    ui_msgbox "$MODULE_TITLE" "Cancelled (confirmation did not match)."
    return 0
  fi

  run parted -s "$disk" rm "$num" || { ui_msgbox "$MODULE_TITLE" "❌ Failed to delete partition."; return 0; }
  run partprobe "$disk" >/dev/null 2>&1 || true

  ui_msgbox "$MODULE_TITLE" "✅ Deleted partition $num on $disk"
  diskmgmt__disk_info "$disk" || true
}

diskmgmt__action_format_partition() {
  diskmgmt__need_root "Format a partition." || return 0
  diskmgmt__require_tools lsblk blkid wipefs || return 0

  local part
  part="$(diskmgmt__pick_partition)" || return 0

  diskmgmt__refuse_if_zfs_member "$part" || return 0

  diskmgmt__confirm_other_member_types "$part" "Mount filesystem" || return 0

  local parent
  parent="$(lsblk -no PKNAME "$part" 2>/dev/null || true)"
  if [[ -n "$parent" && -b "/dev/$parent" ]]; then
    diskmgmt__warn_if_system_disk "/dev/$parent" || true
  fi
  diskmgmt__confirm_other_member_types "$part" "Format partition" || return 0

  if diskmgmt__is_device_mounted_or_busy "$part"; then
    ui_msgbox "$MODULE_TITLE" "❌ Refusing: partition is mounted/busy\n\nUnmount $part first."
    return 0
  fi

  local cur
  cur="$(blkid "$part" 2>/dev/null || true)"

  local fs
  fs="$(ui_menu "$(diskmgmt__crumb "Format")" "Choose filesystem type for:\n$part\n\nCurrent:\n${cur:-"(none)"}" \
    "EXT4"  "ext4 (general purpose)" \
    "XFS"   "xfs (throughput / large files)" \
    "BTRFS" "btrfs (snapshots/features)" \
    "VFAT"  "vfat (EFI/USB compatibility)" \
    "SWAP"  "swap" \
    "BACK"  "Back" \
  )" || return 0
  [[ "$fs" != "BACK" ]] || return 0

  local label
  label="$(ui_inputbox "$(diskmgmt__crumb "Format")" "Optional label (blank for none):" "")" || return 0
  label="${label//\"/}"
  label="$(echo "$label" | tr -d '[:space:]')"

  diskmgmt__double_confirm_destroy "$part" "partition" || return 0

  if ui_yesno "$(diskmgmt__crumb "Format")" \
      "Wipe existing signatures on $part first (wipefs -a)?\n\nRecommended if reusing a RAID/LVM disk."; then
    run wipefs -a "$part" || true
  fi

  case "$fs" in
    EXT4)
      diskmgmt__require_tools mkfs.ext4 || return 0
      if [[ -n "$label" ]]; then
        run mkfs.ext4 -F -L "$label" "$part" || return 0
      else
        run mkfs.ext4 -F "$part" || return 0
      fi
      ;;
    XFS)
      diskmgmt__require_tools mkfs.xfs || return 0
      if [[ -n "$label" ]]; then
        run mkfs.xfs -f -L "$label" "$part" || return 0
      else
        run mkfs.xfs -f "$part" || return 0
      fi
      ;;
    BTRFS)
      diskmgmt__require_tools mkfs.btrfs || return 0
      if [[ -n "$label" ]]; then
        run mkfs.btrfs -f -L "$label" "$part" || return 0
      else
        run mkfs.btrfs -f "$part" || return 0
      fi
      ;;
    VFAT)
      diskmgmt__require_tools mkfs.vfat || return 0
      if [[ -n "$label" ]]; then
        run mkfs.vfat -F 32 -n "$label" "$part" || return 0
      else
        run mkfs.vfat -F 32 "$part" || return 0
      fi
      ;;
    SWAP)
      diskmgmt__require_tools mkswap || return 0
      if [[ -n "$label" ]]; then
        run mkswap -L "$label" "$part" || return 0
      else
        run mkswap "$part" || return 0
      fi
      ;;
  esac

  ui_msgbox "$MODULE_TITLE" "✅ Format complete for $part"
}

diskmgmt__action_mount() {
  diskmgmt__need_root "Mount a filesystem." || return 0
  diskmgmt__require_tools mount lsblk blkid || return 0

  local part
  part="$(diskmgmt__pick_partition)" || return 0

  diskmgmt__refuse_if_zfs_member "$part" || return 0

  if diskmgmt__is_device_mounted_or_busy "$part"; then
    ui_msgbox "$MODULE_TITLE" "💡 Already mounted/busy\n\n$part appears to be mounted.\n\nUse Unmount instead."
    return 0
  fi

  local mp
  mp="$(ui_inputbox "$(diskmgmt__crumb "Mount")" "Mountpoint path (example: /mnt/data):" "/mnt")" || return 0
  mp="${mp//\"/}"
  mp="$(echo "$mp" | tr -d '[:space:]')"
  [[ -n "$mp" ]] || return 0

  if [[ ! -d "$mp" ]]; then
    if ui_yesno "$(diskmgmt__crumb "Mount")" "Mountpoint does not exist:\n$mp\n\nCreate it?"; then
      run mkdir -p "$mp" || { ui_msgbox "$MODULE_TITLE" "❌ Failed to create $mp"; return 0; }
    else
      return 0
    fi
  fi

  local opts
  opts="$(ui_inputbox "$(diskmgmt__crumb "Mount")" "Mount options (blank for defaults):" "")" || return 0
  opts="${opts//\"/}"

  if [[ -n "$opts" ]]; then
    run mount -o "$opts" "$part" "$mp" || { ui_msgbox "$MODULE_TITLE" "❌ mount failed."; return 0; }
  else
    run mount "$part" "$mp" || { ui_msgbox "$MODULE_TITLE" "❌ mount failed."; return 0; }
  fi

  ui_msgbox "$MODULE_TITLE" "✅ Mounted\n\n$part → $mp"
}

diskmgmt__action_unmount() {
  diskmgmt__need_root "Unmount a filesystem." || return 0
  diskmgmt__require_tools umount lsblk || return 0

  local part
  part="$(diskmgmt__pick_partition)" || return 0

  diskmgmt__refuse_if_zfs_member "$part" || return 0
  diskmgmt__confirm_other_member_types "$part" "Unmount filesystem" || return 0

  local parent
  parent="$(lsblk -no PKNAME "$part" 2>/dev/null || true)"
  if [[ -n "$parent" && -b "/dev/$parent" ]]; then
    diskmgmt__warn_if_system_disk "/dev/$parent" || true
  fi

  if ! diskmgmt__is_device_mounted_or_busy "$part"; then
    ui_msgbox "$MODULE_TITLE" "💡 Not mounted\n\n$part does not appear to be mounted."
    return 0
  fi

  if ! ui_yesno "$(diskmgmt__crumb "Unmount")" "Unmount:\n$part\n\nProceed?"; then
    return 0
  fi

  run umount "$part" || { ui_msgbox "$MODULE_TITLE" "❌ umount failed."; return 0; }
  ui_msgbox "$MODULE_TITLE" "✅ Unmounted: $part"
}

diskmgmt__action_fstab_helper() {
  diskmgmt__need_root "Assist with /etc/fstab entries." || return 0
  diskmgmt__require_tools blkid mount lsblk findmnt || return 0

  local part
  part="$(diskmgmt__pick_partition)" || return 0

  diskmgmt__refuse_if_zfs_member "$part" || return 0


  diskmgmt__confirm_other_member_types "$part" "Write /etc/fstab entry" || return 0


  local parent
  parent="$(lsblk -no PKNAME "$part" 2>/dev/null || true)"
  if [[ -n "$parent" && -b "/dev/$parent" ]]; then
    diskmgmt__warn_if_system_disk "/dev/$parent" || true
  fi

  local uuid fstype label
  uuid="$(blkid -s UUID -o value "$part" 2>/dev/null || true)"
  fstype="$(blkid -s TYPE -o value "$part" 2>/dev/null || true)"
  label="$(blkid -s LABEL -o value "$part" 2>/dev/null || true)"

  if [[ -z "$uuid" || -z "$fstype" ]]; then
    ui_msgbox "$MODULE_TITLE" "❌ Missing UUID or filesystem type\n\n$part does not look formatted.\n\nFormat it first."
    return 0
  fi

  local mp
  mp="$(ui_inputbox "$(diskmgmt__crumb "fstab helper")" "Mountpoint to use in fstab (example: /mnt/data):" "/mnt")" || return 0
  mp="${mp//\"/}"
  mp="$(echo "$mp" | tr -d '[:space:]')"
  [[ -n "$mp" ]] || return 0

  local opts dumpno passno
  opts="$(ui_inputbox "$(diskmgmt__crumb "fstab helper")" \
    "Mount options (blank = defaults). Examples:\n  defaults,noatime\n  nofail,x-systemd.automount" "defaults")" || return 0
  opts="${opts//\"/}"
  opts="$(echo "$opts" | tr -d '[:space:]')"
  [[ -n "$opts" ]] || opts="defaults"

  dumpno="0"
  passno="2"
  if [[ "$fstype" == "vfat" || "$fstype" == "swap" ]]; then
    passno="0"
  fi

  local line
  line="UUID=${uuid} ${mp} ${fstype} ${opts} ${dumpno} ${passno}"

  local tmp
  tmp="$(mktemp_safe)" || return 1
  {
    echo "fstab helper"
    echo "--------------------------------------------------------------------------------"
    echo
    echo "Device:     $part"
    echo "UUID:       $uuid"
    echo "FSType:     $fstype"
    echo "Label:      ${label:-"(none)"}"
    echo "Mountpoint: $mp"
    echo
    echo "Suggested line:"
    echo "$line"
    echo
    echo "Notes:"
    echo "- Prefer UUID= entries to avoid device name changes."
    echo "- Consider adding: nofail,x-systemd.device-timeout=5s for removable/secondary disks."
    echo "- For SSD data mounts you may want: noatime"
  } >"$tmp"
  ui_textbox "$(diskmgmt__crumb "fstab helper" "Preview")" "$tmp"

  if ! ui_yesno "$(diskmgmt__crumb "fstab helper")" "Append this line to /etc/fstab?\n\n$line"; then
    return 0
  fi

  if [[ ! -d "$mp" ]]; then
    if ui_yesno "$(diskmgmt__crumb "fstab helper")" "Mountpoint does not exist:\n$mp\n\nCreate it now?"; then
      run mkdir -p "$mp" || { ui_msgbox "$MODULE_TITLE" "❌ Failed to create $mp"; return 0; }
    else
      ui_msgbox "$MODULE_TITLE" "Cancelled: mountpoint missing."
      return 0
    fi
  fi

  local bak="/etc/fstab.dast.$(date +%Y%m%d-%H%M%S).bak"
  run cp -a /etc/fstab "$bak" || { ui_msgbox "$MODULE_TITLE" "❌ Failed to backup /etc/fstab"; return 0; }

  echo "$line" | run tee -a /etc/fstab >/dev/null || {
    ui_msgbox "$MODULE_TITLE" "❌ Failed to write /etc/fstab\n\nBackup is at:\n$bak"
    return 0
  }

  if ui_yesno "$(diskmgmt__crumb "fstab helper")" "✅ Written to /etc/fstab\n\nBackup:\n$bak\n\nTest it now with:\n  mount -a\n\nRun test?"; then
    run mount -a || {
      ui_msgbox "$MODULE_TITLE" "❌ mount -a reported an error.\n\nYou can restore:\n  cp -a $bak /etc/fstab"
      return 0
    }
    ui_msgbox "$MODULE_TITLE" "✅ mount -a OK"
  else
    ui_msgbox "$MODULE_TITLE" "✅ Written.\n\nBackup:\n$bak"
  fi
}

# -----------------------------------------------------------------------------
# Optional handoff entrypoint (other modules can call this)
# -----------------------------------------------------------------------------
diskmgmt_handoff() {
  local dev="${1:-}"
  if [[ -n "$dev" && -b "$dev" ]]; then
    diskmgmt__disk_info "$dev" || true
  fi
  module_DISKMGT
}

# -----------------------------------------------------------------------------
# Main module menu
# -----------------------------------------------------------------------------
module_DISKMGT() {
  while true; do
    local choice
    choice="$(ui_menu "$MODULE_TITLE" "Normal disks and filesystems (non-ZFS).\nSome operations may take a while to load, be patient.\n\nChoose an option:" \
      "DISCOVER" "🔍 Disk discovery (lsblk)" \
      "INFO"     "🧾 Show disk info" \
      "CREATE"   "🧭 Guided partition create (disk-destroying)" \
      "DELETE"   "🗑️  Delete partition (disk-destroying)" \
      "FORMAT"   "🧱 Format partition (data-destroying)" \
      "MOUNT"    "📥 Mount" \
      "UMOUNT"   "📤 Unmount" \
      "FSTAB"    "🧾 fstab helper (UUID-based)" \
      "NOTES"    "🛡️  Safety notes" \
      "BACK"     "🔙 Back" \
    )" || return 0

    case "$choice" in
      DISCOVER)
        diskmgmt__require_tools lsblk || continue
        diskmgmt__show_disks
        ;;
      INFO)
        diskmgmt__require_tools parted lsblk blkid wipefs || continue
        local disk
        disk="$(diskmgmt__sigscan_pick_disk_menu)" || continue

        diskmgmt__disk_info_merged "$disk"

        # Optional: detailed signature scan (default No)
        if diskmgmt__yesno_default_no "$(diskmgmt__crumb "INFO")" "More info for:
  $disk

Show detailed signature scan?"; then
          diskmgmt__signature_summary "$disk"
        fi
        ;;
      CREATE) diskmgmt__action_create_partitions_guided ;;
      DELETE) diskmgmt__action_delete_partition ;;
      FORMAT) diskmgmt__action_format_partition ;;
      MOUNT)  diskmgmt__action_mount ;;
      UMOUNT) diskmgmt__action_unmount ;;
      FSTAB)  diskmgmt__action_fstab_helper ;;
      NOTES)
        local tmp
        tmp="$(mktemp_safe)" || continue
        {
          echo "Safety rules"
          echo "--------------------------------------------------------------------------------"
          echo
          echo "- Refuses destructive ops on mounted/busy devices"
          echo "- Refuses to touch ZFS members (signatures + zpool status -P if available)"
          echo "- Warns heavily if the selected disk appears to be the system/root disk (but does not block)"
          echo "- Warns for mdraid, LVM PV, LUKS, bcache signatures"
          echo "- Disk-destroying ops require double confirmation"
          echo
          echo "ZFS member removal (high level):"
          echo "  zpool status -P"
          echo "  remove/replace/detach via ZFS"
          echo "  zpool labelclear -f <device>"
          echo
          diskmgmt__extra_guidance_for_member_types
        } >"$tmp"
        ui_textbox "$(diskmgmt__crumb "Safety notes")" "$tmp"
        ;;
      BACK) return 0 ;;
    esac
  done
}

# Register with DaST
register_module "$module_id" "$module_title" "module_DISKMGT"
