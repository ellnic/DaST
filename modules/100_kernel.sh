#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Kernel (v0.9.8.4)
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

module_id="KERNEL"
module_title="🧬 Kernel"
KERNEL_TITLE="🧬 Kernel"



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
# Shared helper (run / run_capture / mktemp_safe)
# -----------------------------------------------------------------------------
_kernel_source_helper() {
  # If already present, do nothing
  if declare -F run >/dev/null 2>&1 && declare -F run_capture >/dev/null 2>&1 && declare -F mktemp_safe >/dev/null 2>&1; then
    return 0
  fi

  local here lib

  # 1) If the main DaST launcher provides DAST_LIB_DIR, prefer it
  if [[ -n "${DAST_LIB_DIR:-}" && -f "$DAST_LIB_DIR/dast_helper.sh" ]]; then
    # shellcheck source=/dev/null
    source "$DAST_LIB_DIR/dast_helper.sh"
    return 0
  fi

  # 2) Resolve relative to this module (common layouts)
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || pwd)"
  for lib in \
    "$here/../lib/dast_helper.sh" \
    "$here/lib/dast_helper.sh" \
    "$here/../../lib/dast_helper.sh" \
    "/usr/local/lib/dast_helper.sh" \
    "/usr/local/share/dast/lib/dast_helper.sh" \
    "./lib/dast_helper.sh"
  do
    if [[ -f "$lib" ]]; then
      # shellcheck source=/dev/null
      source "$lib"
      return 0
    fi
  done

  return 1
}

if ! _kernel_source_helper; then
  # Breadcrumb for troubleshooting: if helper can't be sourced, we fall back to minimal safe stubs.
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log WARN "kernel: could not source dast_helper.sh (using internal fallbacks)"
  fi
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "kernel: helper missing; fallbacks active"
  fi
fi

# Minimal safe fallbacks if helper is missing (do not override if present)
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  mktemp_safe() {
    local _tmp
    _tmp="$(mktemp)" || return 1
    # Register for global cleanup if the loader provides it.
    if declare -F _dast_tmp_register >/dev/null 2>&1; then
      _dast_tmp_register "$_tmp" || true
    fi
    printf '%s
' "$_tmp"
  }
fi

if ! declare -F run >/dev/null 2>&1; then
  run() { bash -o pipefail -c "$*" >/dev/null 2>&1 || true; }
fi

if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { bash -o pipefail -c "$*" 2>&1 || true; }
fi

# -----------------------------------------------------------------------------
# OS gating
# -----------------------------------------------------------------------------
kernel_os_id() {
  . /etc/os-release 2>/dev/null || true
  echo "${ID:-unknown}"
}

kernel_os_pretty() {
  . /etc/os-release 2>/dev/null || true
  echo "${PRETTY_NAME:-unknown}"
}

kernel_os_supported() {
  local id
  id="$(kernel_os_id)"
  [[ "$id" == "ubuntu" || "$id" == "debian" ]]
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
kernel_confirm_defaultno() {
  local title="$1" msg="$2"
  if declare -F dial >/dev/null 2>&1; then
    dial --title "$title" --defaultno --yesno "$msg" 12 90 >/dev/null
  else
    ui_yesno "$title" "$msg"
  fi
}

kernel_show_cmd_output() {
  # Executes via run_capture so it is logged by helper, then shows output in textbox.
  # Args: title, command (single string)
  local title="$1"
  local cmd="$2"
  local tmp
  tmp="$(mktemp_safe)" || return 0
  run_capture_sh "$cmd" >"$tmp" || true
  ui_textbox "$title" "$tmp"
}

kernel_have_apt() { command -v apt-get >/dev/null 2>&1; }
kernel_running() { uname -r 2>/dev/null || true; }

kernel_pkg_name_ok() {
  # Allow typical dpkg/apt package name chars
  local s="$1"
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9+._:-]*$ ]]
}

# -----------------------------------------------------------------------------
# Kernel / GRUB info
# -----------------------------------------------------------------------------
kernel_installed_versions() {
  dpkg -l 'linux-image-*' 2>/dev/null \
    | awk '$1=="ii"{print $2}' \
    | sed -n 's/^linux-image-//p' \
    | grep -Ev '^(generic|amd64)$' \
    | sort -V
}

kernel_grub_default_line() {
  [[ -f /etc/default/grub ]] || return 0
  grep -E '^[[:space:]]*GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | head -n 1 || true
}

kernel_grub_menuentries_raw() {
  # Titles only (no indices). Useful for simple display.
  [[ -f /boot/grub/grub.cfg ]] || return 0
  grep -E "^[[:space:]]*menuentry '" /boot/grub/grub.cfg 2>/dev/null \
    | sed -E "s/^[[:space:]]*menuentry '([^']+)'.*/\1/"
}

kernel_grub_menuentries_numbered() {
  kernel_grub_menuentries_raw | nl -ba
}

kernel_grub_entries_with_paths() {
  # Outputs lines: <path>|<title>
  #
  # Where <path> matches GRUB's saved-entry format:
  #   0            (top-level menuentry index)
  #   1>2          (submenu index > entry index)
  #
  # Note: This handles the common single-level "Advanced options" submenu.
  [[ -f /boot/grub/grub.cfg ]] || return 0

  awk -v q="'" '
    function cc(s, c,    n, t) { n=0; t=s; while (match(t, c)) { n++; t=substr(t, RSTART+1) } return n }
    BEGIN {
      brace=0
      top=-1
      in_sub=0
      sub_top=-1
      sub_ent=-1
      sub_start=0
    }
    {
      open=cc($0, "{")
      close=cc($0, "}")
      if ($0 ~ /^[[:space:]]*submenu[[:space:]]*\x27/) {
        top++
        in_sub=1
        sub_top=top
        sub_ent=-1
        t=$0
        sub(/^[[:space:]]*submenu[[:space:]]*\x27/, "", t)
        sub(/\x27.*/, "", t)
        sub_start=brace + open - close
        brace = brace + open - close
        next
      }

      if ($0 ~ /^[[:space:]]*menuentry[[:space:]]*\x27/) {
        t=$0
        sub(/^[[:space:]]*menuentry[[:space:]]*\x27/, "", t)
        sub(/\x27.*/, "", t)

        if (in_sub==1) {
          sub_ent++
          printf "%d>%d|%s\n", sub_top, sub_ent, t
        } else {
          top++
          printf "%d|%s\n", top, t
        }
      }

      brace = brace + open - close

      if (in_sub==1 && brace < sub_start) {
        in_sub=0
        sub_top=-1
        sub_ent=-1
        sub_start=0
      }
    }
  ' /boot/grub/grub.cfg 2>/dev/null
}

kernel_grub_pick_entry_path() {
  local -a items=()
  local line path title

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    path="${line%%|*}"
    title="${line#*|}"
    [[ -z "$path" || -z "$title" ]] && continue
    items+=("$path" "$title")
  done < <(kernel_grub_entries_with_paths)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$KERNEL_TITLE" "No GRUB menu entries found.\n\nExpected: /boot/grub/grub.cfg"
    return 1
  fi

  ui_menu "$KERNEL_TITLE" "Select a GRUB menu entry:" "${items[@]}"
}

kernel_pick_installed() {
  local -a items=()
  local k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    items+=("$k" "🧬 linux-image-$k")
  done < <(kernel_installed_versions)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$KERNEL_TITLE" "No installed linux-image-* packages detected via dpkg."
    return 1
  fi

  ui_menu "$KERNEL_TITLE" "Choose an installed kernel version:" "${items[@]}"
}

kernel_pick_installed_keep_running_safe() {
  local running
  running="$(kernel_running)"
  local -a items=()
  local k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if [[ "$k" == "$running" ]]; then
      items+=("$k" "🟢 running (recommended keep)")
    else
      items+=("$k" "🧬 installed")
    fi
  done < <(kernel_installed_versions)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$KERNEL_TITLE" "No installed linux-image-* packages detected."
    return 1
  fi

  ui_menu "$KERNEL_TITLE" "Choose a kernel version:" "${items[@]}"
}

# -----------------------------------------------------------------------------
# Report builders
# -----------------------------------------------------------------------------
kernel_boot_space_to_file() {
  local out="$1"
  {
    echo "/boot space + kernel artefacts"
    echo
    if mountpoint -q /boot 2>/dev/null; then
      echo "/boot is a mountpoint"
    else
      echo "/boot is not a separate mount (uses / filesystem)"
    fi
    echo
    echo "df -h /boot:"
    df -h /boot 2>/dev/null || true
    echo
    echo "df -i /boot:"
    df -i /boot 2>/dev/null || true
    echo
    echo "Largest files under /boot (top 25):"
    if command -v find >/dev/null 2>&1; then
      find /boot -maxdepth 1 -type f -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n 25 | awk '{printf "%8.1f MiB  %s\n", $1/1024/1024, $2}' || true
    else
      ls -lh /boot 2>/dev/null || true
    fi
    echo
    echo "Initramfs images:"
    ls -lh /boot/initrd.img-* 2>/dev/null || true
    echo
    echo "Kernels:"
    ls -lh /boot/vmlinuz-* 2>/dev/null || true
  } >"$out"
}

kernel_info_to_file() {
  local out="$1"
  local running
  running="$(kernel_running)"

  {
    echo "Kernel module"
    echo
    echo "OS: $(kernel_os_pretty)"
    echo "Running kernel: $running"
    echo
    echo "Kernel (uname -a):"
    uname -a 2>/dev/null || true
    echo
    echo "Installed kernel images (dpkg):"
    dpkg -l 'linux-image-*' 2>/dev/null | awk '$1=="ii"{print $2, $3}' | sort -V || true
    echo
    echo "Installed kernel headers (dpkg):"
    dpkg -l 'linux-headers-*' 2>/dev/null | awk '$1=="ii"{print $2, $3}' | sort -V || true
    echo
    echo "Reboot required:"
    if [[ -f /var/run/reboot-required ]]; then
      echo "YES"
      echo
      echo "/var/run/reboot-required.pkgs:"
      cat /var/run/reboot-required.pkgs 2>/dev/null || true
    else
      echo "NO"
    fi
    echo
    echo "GRUB default setting:"
    kernel_grub_default_line
    echo
    echo "GRUB menuentries (index shown):"
    kernel_grub_menuentries_numbered
    echo
    echo "Held packages (apt-mark showhold):"
    if command -v apt-mark >/dev/null 2>&1; then
      apt-mark showhold 2>/dev/null || true
    else
      echo "(apt-mark not found)"
    fi
    echo
    echo "DKMS status (if present):"
    if command -v dkms >/dev/null 2>&1; then
      dkms status 2>/dev/null || true
    else
      echo "(dkms not installed)"
    fi
  } >"$out"
}

kernel_dkms_to_file() {
  local out="$1"
  {
    echo "DKMS status:"
    if command -v dkms >/dev/null 2>&1; then
      dkms status 2>/dev/null || true
      echo
      echo "Installed DKMS packages (dpkg):"
      dpkg -l '*dkms*' 2>/dev/null | awk '$1=="ii"{print $2, $3}' | sort -V || true
    else
      echo "(dkms not installed)"
      echo "Install: sudo apt-get install -y dkms"
    fi
  } >"$out"
}

kernel_safe_to_remove_report_to_file() {
  local out="$1"
  local running keep1 keep2
  running="$(kernel_running)"
  keep1="$(kernel_installed_versions | tail -n 1)"
  keep2="$(kernel_installed_versions | tail -n 2 | head -n 1)"

  {
    echo "Kernel cleanup helper (best effort)"
    echo
    echo "Running kernel: $running"
    echo "Newest installed: $keep1"
    echo "2nd newest:       $keep2"
    echo
    echo "Recommendation:"
    echo "- Keep the running kernel, and the newest 1-2 kernels as fallback."
    echo "- Candidate kernels are those NOT equal to running/newest/2nd newest."
    echo
    echo "Installed kernels:"
    kernel_installed_versions || true
    echo
    echo "Candidates to remove (dpkg purge linux-image-<ver> linux-headers-<ver>):"
    kernel_installed_versions | while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      if [[ "$k" == "$running" || "$k" == "$keep1" || "$k" == "$keep2" ]]; then
        printf "KEEP: %s\n" "$k"
      else
        printf "RM?:  %s\n" "$k"
      fi
    done
    echo
    echo "Notes:"
    echo "- This does not check whether a kernel is pinned/held, or required by meta packages."
    echo "- Always confirm /boot free space and update-grub after cleanup."
  } >"$out"
}

kernel_reboot_required_to_file() {
  local out="$1"
  {
    echo "Reboot required check"
    echo
    if [[ -f /var/run/reboot-required ]]; then
      echo "Reboot required: YES"
      echo
      echo "Packages:"
      cat /var/run/reboot-required.pkgs 2>/dev/null || true
    else
      echo "Reboot required: NO"
    fi
  } >"$out"
}

kernel_held_packages_to_file() {
  local out="$1"
  {
    echo "Held packages"
    echo
    if command -v apt-mark >/dev/null 2>&1; then
      apt-mark showhold 2>/dev/null || true
    else
      echo "(apt-mark not found)"
    fi
  } >"$out"
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
kernel_regen_initramfs_running() {
  local k
  k="$(kernel_running)"
  [[ -z "$k" ]] && { ui_msg "$KERNEL_TITLE" "Could not read running kernel version."; return 0; }

  kernel_confirm_defaultno "$KERNEL_TITLE" "Rebuild initramfs for running kernel?\n\nKernel: $k\n\nCommand:\nupdate-initramfs -u -k $k\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "update-initramfs -u -k '$k' 2>&1 || true"
}

kernel_regen_initramfs_pick() {
  local k
  k="$(kernel_pick_installed)" || return 0

  kernel_confirm_defaultno "$KERNEL_TITLE" "Rebuild initramfs for selected kernel?\n\nKernel: $k\n\nCommand:\nupdate-initramfs -u -k $k\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "update-initramfs -u -k '$k' 2>&1 || true"
}

kernel_regen_initramfs_all() {
  kernel_confirm_defaultno "$KERNEL_TITLE" "Rebuild initramfs for ALL kernels?\n\nCommand:\nupdate-initramfs -u -k all\n\nThis can take a while.\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "update-initramfs -u -k all 2>&1 || true"
}

kernel_update_grub() {
  kernel_confirm_defaultno "$KERNEL_TITLE" "Regenerate GRUB config now?\n\nCommand:\nupdate-grub\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "update-grub 2>&1 || true"
}

kernel_initramfs_then_updategrub() {
  local k
  k="$(kernel_running)"
  [[ -z "$k" ]] && k="(unknown)"

  kernel_confirm_defaultno "$KERNEL_TITLE" "Rebuild initramfs then update-grub?\n\nKernel (running): $k\n\nCommands:\nupdate-initramfs -u -k all\nupdate-grub\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "update-initramfs -u -k all 2>&1 || true; echo; update-grub 2>&1 || true"
}

kernel_set_grub_default_saved() {
  kernel_confirm_defaultno "$KERNEL_TITLE" "Set GRUB_DEFAULT=saved and enable grub-set-default control?\n\nThis will edit /etc/default/grub.\nThen you can set defaults via grub-set-default.\n\nDefault is No." || return 0

  kernel_show_cmd_output "$KERNEL_TITLE" "set -e; \
    f=/etc/default/grub; \
    [[ -f \"$f\" ]] || { echo 'Missing /etc/default/grub'; exit 0; }; \
    cp -a \"$f\" \"${f}.bak.$(date +%Y%m%d-%H%M%S)\" || true; \
    if grep -qE '^[[:space:]]*GRUB_DEFAULT=' \"$f\"; then \
      sed -i -E 's/^[[:space:]]*GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \"$f\"; \
    else \
      echo 'GRUB_DEFAULT=saved' >> \"$f\"; \
    fi; \
    echo 'Updated /etc/default/grub:'; \
    grep -E '^[[:space:]]*GRUB_DEFAULT=' \"$f\" || true; \
    echo; \
    echo 'Now run update-grub to apply.' \
  2>&1 || true"
}

kernel_grub_set_default_pick() {
  if ! command -v grub-set-default >/dev/null 2>&1; then
    ui_msg "$KERNEL_TITLE" "grub-set-default not found.\n\nInstall:\nsudo apt-get install -y grub-common\n(or grub2-common on some distros)"
    return 0
  fi

  local path
  path="$(kernel_grub_pick_entry_path)" || return 0
  [[ -z "$path" ]] && return 0

  kernel_confirm_defaultno "$KERNEL_TITLE" "Set GRUB default to:\n\n$path\n\nThis changes the *default kernel at next boot*.\nCommand:\ngrub-set-default '$path'\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "grub-set-default '$path' 2>&1 || true; echo; echo 'Tip: If you want this to persist, ensure GRUB_DEFAULT=saved and run update-grub after edits.'"
  ui_msg "$KERNEL_TITLE" "Done.\n\nTo actually switch the running kernel, you must reboot."
}

kernel_grub_reboot_once_pick() {
  if ! command -v grub-reboot >/dev/null 2>&1; then
    ui_msg "$KERNEL_TITLE" "grub-reboot not found.\n\nInstall:\nsudo apt-get install -y grub-common\n(or grub2-common on some distros)"
    return 0
  fi

  local path
  path="$(kernel_grub_pick_entry_path)" || return 0
  [[ -z "$path" ]] && return 0

  kernel_confirm_defaultno "$KERNEL_TITLE" "Reboot once into:\n\n$path\n\nThis sets the next boot only.\nCommand:\ngrub-reboot '$path'\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "grub-reboot '$path' 2>&1 || true; echo; echo 'Next reboot will use that entry once.'"
  ui_msg "$KERNEL_TITLE" "Done.\n\nTo actually switch the running kernel, you must reboot."
}


kernel_set_grub_default_by_index() {
  if ! command -v grub-set-default >/dev/null 2>&1; then
    ui_msg "$KERNEL_TITLE" "grub-set-default not found.\n\nInstall: sudo apt-get install -y grub-common\n(or grub2-common on some distros)"
    return 0
  fi

  local idx
  idx="$(ui_input "$KERNEL_TITLE" "Enter GRUB saved-entry path.

Examples:
  0     (top-level entry)
  1>2   (submenu entry)

Tip: Use the picker list option if unsure.\n\nTip: Use Kernel -> Info to view menu entries." "")" || return 0
  [[ -z "$idx" ]] && return 0
  if ! [[ "$idx" =~ ^[0-9]+(>[0-9]+)*$ ]]; then
    ui_msg "$KERNEL_TITLE" "That does not look like a valid GRUB saved-entry path.

Examples:
  0
  1>2"
    return 0
  fi

  # Verify the path exists in the parsed GRUB menu (prevents selecting submenu headers or invalid paths)
  if ! kernel_grub_entries_with_paths | cut -d'|' -f1 | grep -Fxq -- "$idx"; then
    ui_msg "$KERNEL_TITLE" "That GRUB saved-entry path was not found in the current GRUB menu:

$idx

Tip: Use the picker list option if unsure.

Tip: Use Kernel -> Info to view menu entries."
    return 0
  fi


  kernel_confirm_defaultno "$KERNEL_TITLE" "Set GRUB default to index $idx?\n\nCommand:\ngrub-set-default $idx\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "grub-set-default '$idx' 2>&1 || true; echo; echo 'GRUB default now uses saved entry (if enabled).'"
}

kernel_find_grub_index_for_kernel() {
  # Given a kernel version string like 6.8.0-xx-generic, try to find a matching
  # GRUB saved-entry path (e.g. 1>2). Best effort.
  local k="$1"
  [[ -z "$k" ]] && return 1
  [[ -f /boot/grub/grub.cfg ]] || return 1

  local line path title
  while IFS= read -r line; do
    path="${line%%|*}"
    title="${line#*|}"
    # Ignore recovery entries to avoid confusing mapping
    if [[ "$title" == *"recovery mode"* ]]; then
      continue
    fi
    if [[ -n "$title" && "$title" == *"$k"* ]]; then
      echo "$path"
      return 0
    fi
  done < <(kernel_grub_entries_with_paths)

  return 1
}


kernel_set_default_by_version() {
  if ! command -v grub-set-default >/dev/null 2>&1; then
    ui_msg "$KERNEL_TITLE" "grub-set-default not found.\n\nInstall: sudo apt-get install -y grub-common"
    return 0
  fi

  local k
  k="$(kernel_pick_installed)" || return 0

  local idx
  idx="$(kernel_find_grub_index_for_kernel "$k" || true)"
  if [[ -z "$idx" ]]; then
    ui_msg "$KERNEL_TITLE" "Couldn't automatically map kernel to a GRUB entry.\n\nUse Kernel -> Info to view GRUB entries and set by index."
    return 0
  fi

  kernel_confirm_defaultno "$KERNEL_TITLE" "Set GRUB default to kernel:\n\n$k\n\nMatched menu index: $idx\n\nCommand:\ngrub-set-default $idx\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "grub-set-default '$idx' 2>&1 || true; echo; echo 'If GRUB_DEFAULT is not saved, set it first (Kernel -> GRUB -> Set GRUB_DEFAULT=saved), then update-grub.'"
}

kernel_remove_recommended_old() {
  if ! kernel_have_apt; then
    ui_msg "$KERNEL_TITLE" "apt-get not found."
    return 0
  fi

  local running keep1 keep2
  running="$(kernel_running)"
  keep1="$(kernel_installed_versions | tail -n 1)"
  keep2="$(kernel_installed_versions | tail -n 2 | head -n 1)"

  local -a pkgs=()
  local k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if [[ "$k" == "$running" || "$k" == "$keep1" || "$k" == "$keep2" ]]; then
      continue
    fi
    pkgs+=("linux-image-$k" "linux-headers-$k")
  done < <(kernel_installed_versions)

  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    ui_msg "$KERNEL_TITLE" "No old kernels found to remove (keeping running + newest two)."
    return 0
  fi

  local list=""
  for k in "${pkgs[@]}"; do list+="$k\n"; done

  kernel_confirm_defaultno "$KERNEL_TITLE" "Purge old kernels (keep running + newest two)?\n\nRunning: $running\nKeep: $keep1, $keep2\n\nThis will purge:\n$list\nDefault is No." || return 0

  kernel_show_cmd_output "$KERNEL_TITLE" "apt-get purge -y ${pkgs[*]} 2>&1 || true; \
    echo; \
    echo 'Running apt autoremove:'; \
    apt-get autoremove -y 2>&1 || true; \
    echo; \
    echo 'Consider running update-grub afterwards.'"
}

kernel_install_kernel() {
  if ! kernel_have_apt; then
    ui_msg "$KERNEL_TITLE" "apt-get not found. Install is not supported on this system."
    return 0
  fi

  local pkg
  pkg="$(ui_input "$KERNEL_TITLE" "Enter a kernel image package to install.\n\nExamples:\n- linux-image-generic\n- linux-image-generic-hwe-22.04\n- linux-image-6.8.0-xx-generic\n\n(You can also install headers similarly.)" "linux-image-generic")" || return 0
  [[ -z "$pkg" ]] && return 0

  if ! kernel_pkg_name_ok "$pkg"; then
    ui_msg "$KERNEL_TITLE" "That does not look like a valid package name:\n\n$pkg"
    return 0
  fi

  kernel_confirm_defaultno "$KERNEL_TITLE" "Install package:\n\n$pkg\n\nCommands:\napt-get update\napt-get install -y $pkg\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "apt-get update 2>&1 || true; apt-get install -y '$pkg' 2>&1 || true"
}

kernel_remove_kernel() {
  if ! kernel_have_apt; then
    ui_msg "$KERNEL_TITLE" "apt-get not found. Removal is not supported on this system."
    return 0
  fi

  local k running
  running="$(kernel_running)"
  k="$(kernel_pick_installed_keep_running_safe)" || return 0

  if [[ "$k" == "$running" ]]; then
    ui_msg "$KERNEL_TITLE" "Refusing to remove the running kernel:\n\n$k\n\nBoot into another kernel first."
    return 0
  fi

  local pkg_img="linux-image-$k"
  local pkg_hdr="linux-headers-$k"

  kernel_confirm_defaultno "$KERNEL_TITLE" "Remove kernel packages?\n\nImage:   $pkg_img\nHeaders: $pkg_hdr (if installed)\n\nCommand:\napt-get purge -y $pkg_img $pkg_hdr\n\nDefault is No." || return 0

  kernel_show_cmd_output "$KERNEL_TITLE" "apt-get purge -y '$pkg_img' '$pkg_hdr' 2>&1 || true; \
    echo; \
    echo 'Running apt autoremove (optional):'; \
    apt-get autoremove -y 2>&1 || true; \
    echo; \
    echo 'Consider running update-grub afterwards.'"
}

kernel_autoremove() {
  if ! kernel_have_apt; then
    ui_msg "$KERNEL_TITLE" "apt-get not found."
    return 0
  fi
  kernel_confirm_defaultno "$KERNEL_TITLE" "Run apt autoremove now?\n\nThis may remove older kernels.\n\nDefault is No." || return 0
  kernel_show_cmd_output "$KERNEL_TITLE" "apt-get autoremove -y 2>&1 || true"
}

# -----------------------------------------------------------------------------
# Screens
# -----------------------------------------------------------------------------
kernel_info_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  kernel_info_to_file "$tmp"
  ui_textbox "$KERNEL_TITLE" "$tmp"
}

kernel_dkms_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  kernel_dkms_to_file "$tmp"
  ui_textbox "$KERNEL_TITLE" "$tmp"
}

kernel_boot_space_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  kernel_boot_space_to_file "$tmp"
  ui_textbox "$KERNEL_TITLE" "$tmp"
}

kernel_safe_remove_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  kernel_safe_to_remove_report_to_file "$tmp"
  ui_textbox "$KERNEL_TITLE" "$tmp"
}

kernel_reboot_required_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  kernel_reboot_required_to_file "$tmp"
  ui_textbox "$KERNEL_TITLE" "$tmp"
}

kernel_held_packages_screen() {
  local tmp
  tmp="$(mktemp_safe)" || return 0
  kernel_held_packages_to_file "$tmp"
  ui_textbox "$KERNEL_TITLE" "$tmp"
}


# -----------------------------------------------------------------------------
# Guided kernel selection (install + set next boot)
# -----------------------------------------------------------------------------
kernel_grub_path_for_kernel_version() {
  # Best-effort: find GRUB saved-entry path whose title contains the version string.
  local ver="$1"
  [[ -z "$ver" ]] && return 1
  kernel_find_grub_index_for_kernel "$ver" 2>/dev/null
}

kernel_pick_installed_with_grub_path() {
  # Returns: "<ver>|<path>" or empty on cancel.
  local running
  running="$(kernel_running)"

  local -a items=()
  local k path desc
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    path="$(kernel_grub_path_for_kernel_version "$k" || true)"
    desc="🧬 installed"
    if [[ "$k" == "$running" ]]; then
      desc="🟢 running"
    fi
    if [[ -n "$path" ]]; then
      desc="$desc | GRUB: $path"
    else
      if [[ ! -f /boot/grub/grub.cfg ]]; then
        desc="$desc | GRUB: n/a (no grub.cfg)"
      else
        desc="$desc | GRUB: not indexed (run update-grub)"
      fi
    fi
    items+=("$k" "$desc")
  done < <(kernel_installed_versions)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$KERNEL_TITLE" "No installed kernels detected."
    return 1
  fi

  local ver
  ver="$(ui_menu "$KERNEL_TITLE" "Select an installed kernel (mapped to GRUB where possible):" "${items[@]}")" || return 1
  [[ -z "$ver" ]] && return 1

  path="$(kernel_grub_path_for_kernel_version "$ver" || true)"
  printf '%s|%s\n' "$ver" "$path"
}

kernel_kernel_selector_guided() {
  # A single front-door for: install kernel package (optional) -> update-grub -> pick kernel -> set default/once.
  # This does NOT attempt to hot-swap the running kernel (impossible).
  if ! kernel_os_supported; then
    ui_msg "$KERNEL_TITLE" "This module supports Ubuntu and Debian.\n\nDetected: $(kernel_os_pretty)"
    return 0
  fi

  while true; do
    local running
    running="$(kernel_running)"

    local sel
    sel="$(ui_menu "$KERNEL_TITLE" "Kernel selector (running: $running)\n\nPick what you want to boot next:" \
      "PICK"    "🔀 Pick an *installed* kernel and set next boot" \
      "INSTALL" "📥 Install a kernel package (apt) then continue" \
      "UPDGRUB" "🧰 update-grub (refresh menu entries)" \
      "BACK"    "🔙️ Back")" || return 0

    dast_log info "$module_id" "Menu selection: $sel"

    dast_dbg "$module_id" "Menu selection: $sel"

    case "$sel" in
      BACK|"") return 0 ;;
      INSTALL)
        kernel_install_kernel
        ;;
      UPDGRUB)
        kernel_update_grub
        ;;
      PICK)
        local vp ver path
        vp="$(kernel_pick_installed_with_grub_path)" || continue
        ver="${vp%%|*}"
        path="${vp#*|}"

        if [[ -z "$path" ]]; then
          ui_msg "$KERNEL_TITLE" "I couldn't map that kernel to a GRUB menu entry automatically.\n\nKernel: $ver\n\nThis does NOT mean it won't boot.\nIt usually means GRUB's menu hasn't been regenerated yet, or your boot setup isn't standard.\n\nTry:\n1) Run update-grub (from here)\n2) Then retry this picker\n3) Or use the GRUB picker manually (Kernel -> GRUB)\n\nNothing changed."
          continue
        fi

        local action
        action="$(ui_menu "$KERNEL_TITLE" "Selected:\n\nKernel: $ver\nGRUB:   $path\n\nWhat do you want?" \
          "DEFAULT" "🎯 Set as default for future boots (grub-set-default)" \
          "ONCE"    "⏱ Boot this kernel once (grub-reboot)" \
          "BACK"    "🔙️ Back")" || continue

        case "$action" in
          BACK|"") continue ;;
          DEFAULT)
            if ! command -v grub-set-default >/dev/null 2>&1; then
              ui_msg "$KERNEL_TITLE" "grub-set-default not found.\n\nInstall:\nsudo apt-get install -y grub-common\n(or grub2-common on some distros)"
              continue
            fi
            kernel_confirm_defaultno "$KERNEL_TITLE" "Set default boot kernel to:\n\n$ver\n\nGRUB entry: $path\n\nCommand:\ngrub-set-default '$path'\n\nNote: For persistence, GRUB_DEFAULT should be 'saved'.\n\nDefault is No." || continue
            kernel_show_cmd_output "$KERNEL_TITLE" "grub-set-default '$path' 2>&1 || true; echo; echo 'Reminder: If GRUB_DEFAULT is not saved, set it (Kernel -> GRUB -> Set GRUB_DEFAULT=saved), then update-grub.'"
            ui_msg "$KERNEL_TITLE" "Default set.\n\nReboot to actually change the running kernel."
            ;;
          ONCE)
            if ! command -v grub-reboot >/dev/null 2>&1; then
              ui_msg "$KERNEL_TITLE" "grub-reboot not found.\n\nInstall:\nsudo apt-get install -y grub-common\n(or grub2-common on some distros)"
              continue
            fi
            kernel_confirm_defaultno "$KERNEL_TITLE" "Boot once into:\n\n$ver\n\nGRUB entry: $path\n\nCommand:\ngrub-reboot '$path'\n\nDefault is No." || continue
            kernel_show_cmd_output "$KERNEL_TITLE" "grub-reboot '$path' 2>&1 || true"
            ui_msg "$KERNEL_TITLE" "One-time boot set.\n\nReboot to actually change the running kernel."
            ;;
        esac
        ;;
      *)
        ui_msg "$KERNEL_TITLE" "Unknown selection: $sel"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------
kernel_menu_rebuilds() {
  local running
  running="$(kernel_running)"
  ui_menu "$KERNEL_TITLE" "Rebuilds:" \
    "INIT_RUN"  "🧱 Rebuild initramfs (running: $running)" \
    "INIT_PICK" "🧱 Rebuild initramfs (choose kernel)" \
    "INIT_ALL"  "🧱 Rebuild initramfs (all kernels)" \
    "INIT_GRUB" "🧱+🧰 Rebuild initramfs (all) then update-grub" \
    "BACK"      "🔙️ Back"
}

kernel_menu_grub() {
  ui_menu "$KERNEL_TITLE" "GRUB:" \
    "GRUB_UPD"       "🧰 Regenerate GRUB config (update-grub)" \
    "GRUB_SAVED"     "💾 Set GRUB_DEFAULT=saved (enables saved entries)" \
    "GRUB_PICK_DEF"  "🎯 Set default boot entry (picker list)" \
    "GRUB_PICK_ONCE" "⏱ Reboot once into entry (picker list)" \
    "GRUB_SET"       "🎯 Set GRUB default entry (manual path/index)" \
    "GRUB_VER"       "🧬 Set GRUB default kernel (picker, map by version)" \
    "BACK"           "🔙️ Back"
}

kernel_menu_cleanup() {
  ui_menu "$KERNEL_TITLE" "Cleanup:" \
    "SAFE"   "🧯 Safe-to-remove helper (keep running + newest two)" \
    "RM_OLD" "🧹 Purge old kernels (keep running + newest two)" \
    "AUTORM" "🧽 apt autoremove (cleanup old kernels)" \
    "BACK"   "🔙️ Back"
}

kernel_menu_packages() {
  ui_menu "$KERNEL_TITLE" "Packages:" \
    "INSTALL" "📥 Install kernel package (apt)" \
    "REMOVE"  "🧹 Remove an installed kernel (apt purge, not running)" \
    "HELD"    "📌 Show held packages" \
    "BACK"    "🔙️ Back"
}

kernel_menu_health() {
  ui_menu "$KERNEL_TITLE" "Health:" \
    "REBOOT" "🔁 Reboot required check" \
    "BACK"   "🔙️ Back"
}

kernel_menu_main() {
  local running os
  running="$(kernel_running)"
  os="$(kernel_os_pretty)"
  ui_menu "$KERNEL_TITLE" "Choose (OS: $os | running: $running):" \
    "INFO"     "📊 Kernel overview" \
    "BOOT"     "🧾 /boot free space + kernel artefacts" \
    "DKMS"     "🧩 DKMS status" \
    "HEALTH"   "🩺 Health" \
    "REBUILDS" "🧱 Rebuilds" \
    "SWITCH"   "🔀 Change/Select kernel (guided)" \
    "GRUB"     "🧰 GRUB" \
    "CLEAN"    "🧹 Cleanup" \
    "PKGS"     "📦 Packages" \
    "BACK"     "🔙️ Back"
}

# -----------------------------------------------------------------------------
# Module
# -----------------------------------------------------------------------------
module_KERNEL() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  if ! kernel_os_supported; then
    ui_msg "$KERNEL_TITLE" "This module supports Ubuntu and Debian.\n\nDetected: $(kernel_os_pretty)"
    return 0
  fi

  while true; do
    local sel
    sel="$(kernel_menu_main)" || return 0
    [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

    case "$sel" in
      INFO)   kernel_info_screen ;;
      BOOT)   kernel_boot_space_screen ;;
      DKMS)   kernel_dkms_screen ;;
      HEALTH)
        while true; do
          local h
          h="$(kernel_menu_health)" || break
          [[ -z "$h" || "$h" == "BACK" ]] && break
          case "$h" in
            REBOOT) kernel_reboot_required_screen ;;
            *) ui_msg "$KERNEL_TITLE" "Unknown selection: $h" ;;
          esac
        done
        ;;
      REBUILDS)
        while true; do
          local r
          r="$(kernel_menu_rebuilds)" || break
          [[ -z "$r" || "$r" == "BACK" ]] && break
          case "$r" in
            INIT_RUN)  kernel_regen_initramfs_running ;;
            INIT_PICK) kernel_regen_initramfs_pick ;;
            INIT_ALL)  kernel_regen_initramfs_all ;;
            INIT_GRUB) kernel_initramfs_then_updategrub ;;
            *) ui_msg "$KERNEL_TITLE" "Unknown selection: $r" ;;
          esac
        done
        ;;      SWITCH) kernel_kernel_selector_guided ;;

      GRUB)
        while true; do
          local g
          g="$(kernel_menu_grub)" || break
          [[ -z "$g" || "$g" == "BACK" ]] && break
          case "$g" in
            GRUB_UPD)   kernel_update_grub ;;
            GRUB_SAVED)     kernel_set_grub_default_saved ;;
            GRUB_PICK_DEF)  kernel_grub_set_default_pick ;;
            GRUB_PICK_ONCE) kernel_grub_reboot_once_pick ;;
            GRUB_SET)       kernel_set_grub_default_by_index ;;
            GRUB_VER)       kernel_set_default_by_version ;;
            *) ui_msg "$KERNEL_TITLE" "Unknown selection: $g" ;;
          esac
        done
        ;;
      CLEAN)
        while true; do
          local c
          c="$(kernel_menu_cleanup)" || break
          [[ -z "$c" || "$c" == "BACK" ]] && break
          case "$c" in
            SAFE)   kernel_safe_remove_screen ;;
            RM_OLD) kernel_remove_recommended_old ;;
            AUTORM) kernel_autoremove ;;
            *) ui_msg "$KERNEL_TITLE" "Unknown selection: $c" ;;
          esac
        done
        ;;
      PKGS)
        while true; do
          local p
          p="$(kernel_menu_packages)" || break
          [[ -z "$p" || "$p" == "BACK" ]] && break
          case "$p" in
            INSTALL) kernel_install_kernel ;;
            REMOVE)  kernel_remove_kernel ;;
            HELD)    kernel_held_packages_screen ;;
            *) ui_msg "$KERNEL_TITLE" "Unknown selection: $p" ;;
          esac
        done
        ;;
      *) ui_msg "$KERNEL_TITLE" "Unknown selection: $sel" ;;
    esac
  done
}

# Only register on supported OS
if kernel_os_supported; then
  register_module "$module_id" "$module_title" "module_KERNEL"
fi
