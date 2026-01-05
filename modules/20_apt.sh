#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: APT (v0.9.8.4)
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

module_id="APT"
module_title="📦 APT (packages)"
MODULESPEC_TITLE="📦 APT (packages)"

# -----------------------------------------------------------------------------
# Platform gating
# -----------------------------------------------------------------------------
# KDE Neon is Ubuntu-based but intentionally steers users away from APT as the
# primary package UX. DaST should hide this module on Neon and on systems that
# are not clearly APT/dpkg based.

apt_is_valid_apt_system() {
  # Must have the core tools.
  command -v dpkg >/dev/null 2>&1 || return 1
  command -v apt-get >/dev/null 2>&1 || return 1

  # Detect distro.
  local os_id="" os_like="" os_name=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
    os_name="${NAME:-}"
  fi

  # Explicit exclusions.
  if [[ "${os_id,,}" == "neon" ]] || [[ "${os_name,,}" == *"kde neon"* ]]; then
    return 1
  fi

  # Allow Debian/Ubuntu families.
  if [[ " ${os_like,,} " == *" debian "* ]] || [[ " ${os_like,,} " == *" ubuntu "* ]]; then
    return 0
  fi

  case "${os_id,,}" in
    debian|ubuntu|kubuntu|lubuntu|xubuntu|pop|linuxmint|raspbian)
      return 0
      ;;
  esac

  return 1
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
APT_LOG_DIR="${LOG_DIR:-}"
APT_LOG_FILE=""

apt_log_init() {
  # Prefer DaST main's LOG_DIR; otherwise derive app root from this module path.
  local target_dir="${APT_LOG_DIR}"

  if [[ -z "$target_dir" ]]; then
    local mod_dir app_dir
    mod_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    app_dir="$(cd -- "$mod_dir/.." && pwd -P)"
    target_dir="${app_dir}/logs"
  fi

  # Create the log directory (no fallback).
  if ! mkdir -p "$target_dir" 2>/dev/null; then
    APT_LOG_FILE=""
    return 1
  fi

  # Repair permissions similarly to DaST config dir logic.
  # If running via sudo, prefer the invoking user.
  if [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    chown "$SUDO_USER":"$SUDO_USER" "$target_dir" 2>/dev/null || true
  else
    chown "$(id -u)":"$(id -g)" "$target_dir" 2>/dev/null || true
  fi
  chmod 755 "$target_dir" 2>/dev/null || true

  APT_LOG_DIR="$target_dir"
  APT_LOG_FILE="${APT_LOG_DIR}/apt.log"

  touch "$APT_LOG_FILE" 2>/dev/null || true
  chmod 644 "$APT_LOG_FILE" 2>/dev/null || true
}


# -----------------------------------------------------------------------------
# Helper-aware runners
# -----------------------------------------------------------------------------
# Prefer shared lib/dast_helper.sh if present (run/run_capture).
# Fall back to direct execution if this module is used standalone.
apt__capture() {
  if declare -F run_capture >/dev/null 2>&1; then
    # run_capture expects argv. If we were given a single string, it may contain
    # shell operators (|, ||, &&, redirects, subshell parens). Wrap it.
    if [[ $# -eq 1 ]]; then
      run_capture bash -o pipefail -c "$1"
    else
      run_capture "$@"
    fi
    return $?
  fi

  if [[ $# -eq 1 ]]; then
    bash -o pipefail -c "$1"
  else
    "$@"
  fi
}

apt__run() {
  if declare -F run >/dev/null 2>&1; then
    # Same reasoning as apt__capture: allow callers to pass a single
    # shell-string safely.
    if [[ $# -eq 1 ]]; then
      run bash -o pipefail -c "$1"
    else
      run "$@"
    fi
    return $?
  fi

  if [[ $# -eq 1 ]]; then
    bash -o pipefail -c "$1"
  else
    "$@"
  fi
}

# Plain mktemp (NO auto-trap), because this module manages cleanup itself.
apt__mktemp_plain() {
  mktemp
}

have_dialog() {
  command -v dialog >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# UI helpers (module-local)
# -----------------------------------------------------------------------------
# Some older DaST mains don't provide ui_inputbox; some modules previously called
# _apt_ui_inputbox but forgot to define it. That can look like a "cancel" because
# the call fails (exit 127). Define it here safely.
_apt_ui_inputbox() {
  local title="$1"
  local prompt="$2"
  local def="${3:-}"

  if declare -F ui_inputbox >/dev/null 2>&1; then
    ui_inputbox "$title" "$prompt" "$def"
    return $?
  fi

  # Fallback: direct dialog (use dial() if main provides it, else call dialog).
  if declare -F dial >/dev/null 2>&1; then
    dial --title "$title" --inputbox "$prompt" 10 70 "$def"
    return $?
  fi

  dast_ui_dialog --title "$title" --inputbox "$prompt" 10 70 "$def"
  return $?
}

apt_log() {
  apt_log_init || true
  local msg="$*"

  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "INFO" "$module_id" "${msg}"
    return 0
  fi

  [[ -n "${APT_LOG_FILE:-}" ]] || return 0
  printf '[%s] %s
' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$APT_LOG_FILE" 2>/dev/null || true
}

apt_dbg() {
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$module_id" "$*"
  fi
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
backup_sources_file() {
  local f="$1"
  local bdir="/var/backups/dast/apt-sources"
  mkdir -p "$bdir"
  local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
  cp -a "$f" "$bdir/$(basename "$f").$stamp.bak"
  echo "$bdir/$(basename "$f").$stamp.bak"
}

apt_sources_files() {
  local f

  [[ -f /etc/apt/sources.list ]] && echo "/etc/apt/sources.list"

  if [[ -d /etc/apt/sources.list.d ]]; then
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      [[ -f "$f" ]] && echo "$f"
    done
  fi
}

pick_sources_file() {
  local -a items=()
  local f

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    items+=("$f" "$(basename "$f")")
  done < <(apt_sources_files)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "No APT sources files found."
    return 1
  fi

  ui_menu "$MODULESPEC_TITLE" "Choose a file to edit:" \
    "${items[@]}" \
    "BACK" "Back"
}

edit_sources_file_dialog() {
  local f="$1"
  [[ -f "$f" ]] || { ui_msg "$MODULESPEC_TITLE" "File not found: $f"; return 0; }

  local edited
  edited="$(dial --title "Edit: $(basename "$f")" --editbox "$f" 22 90)" || return 0

  if ! ui_yesno "Save Changes?" "Save changes to:\n$f\n\nA backup will be created first."; then
    return 0
  fi

  local bkp
  bkp="$(backup_sources_file "$f")"
  printf '%s' "$edited" >"$f"

  ui_msg "Saved" "Changes saved.\n\nBackup created:\n$bkp"
}

apt__make_script() {
  local cmd="$1"
  local tscript
  tscript="$(apt__mktemp_plain)"

  apt_log_init

  cat >"$tscript" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

APT_LOG_FILE=${APT_LOG_FILE@Q}

{
  $cmd
} 2>&1 | tee -a "\$APT_LOG_FILE"
exit \${PIPESTATUS[0]}
EOF

  chmod +x "$tscript"

  apt_log "MAKE_SCRIPT path=$tscript"
  apt_log "MAKE_SCRIPT cmd=$(printf '%q' "$cmd")"
  apt_log "MAKE_SCRIPT log_file=$APT_LOG_FILE"

  echo "$tscript"
}

apt_run_box() {
  local title="$1"
  local cmd="$2"

  local tscript
  tscript="$(apt__make_script "$cmd")"

  # Ensure temporary script is cleaned up even if the user aborts or the
  # terminal disconnects while dialog is running.
  trap 'rm -f "$tscript" 2>/dev/null || true' EXIT INT TERM

  apt_log "RUN_BOX title=$title uid=$(id -u) user=$(id -un 2>/dev/null || echo '?')"
  apt_log "RUN_BOX script=$tscript"

  # Also record in shared helper log if available (nice for central visibility)
  if declare -F _dast_run_append_log_line >/dev/null 2>&1; then
    _dast_run_append_log_line "[$(date '+%Y-%m-%d %H:%M:%S%z')] module=APT action=RUN_BOX title=$(printf '%q' "$title") cmd=$(printf '%q' "$cmd")"
  fi

  if have_dialog; then
    local dlgbin
    dlgbin="$(command -v dialog || true)"
    apt_log "RUN_BOX invoking dialog progressbox via pipe"
    # IMPORTANT: Do NOT pipe into dial() here. dial() binds stdin to /dev/tty, which
    # breaks widgets like --progressbox that must read from stdin. Call dialog
    # directly so it can consume the pipe and exit cleanly.
    set +e
    /bin/bash "$tscript" 2>&1 | "$dlgbin" --backtitle "$APP_TITLE" \
      --title "$title" \
      --no-cancel --no-collapse --cr-wrap \
      --progressbox "Running..." 22 90 \
      >/dev/tty 2>/dev/tty
    local rc=$?
    set -e
    apt_log "RUN_BOX dialog_exit=$rc"
  else
    apt_log "RUN_BOX dialog not found, running script directly"
    /bin/bash "$tscript" || true
    apt_log "RUN_BOX direct_exit=$?"
  fi

  rm -f "$tscript" 2>/dev/null || true
  trap - EXIT INT TERM
  apt_log "RUN_BOX done"

  ui_msg "$title" "Complete.\n\nPress OK to return.\n\nLog file:\n$APT_LOG_FILE"
}

apt_has_autoremove() {
  # Returns 0 if there are packages that would be removed by autoremove, else 1.
  # We intentionally keep this lightweight and simulation-only.
  # 'Remv' appears in apt-get -s output when packages would be removed.
  local out
  out="$(apt__capture "apt-get -o Dpkg::Progress-Fancy=0 -s autoremove 2>/dev/null || true")" || true
  echo "$out" | grep -E '^(Remv|Remv[[:space:]])' >/dev/null 2>&1
}

apt_preview_box() {
  local title="$1"
  local cmd="$2"
  local tmp
  tmp="$(apt__mktemp_plain)"

  # Ensure temporary file is cleaned up even if the user aborts the textbox.
  trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM

  {
    echo "Command:"
    echo "  $cmd"
    echo
    echo "Next: you will be shown what needs to be installed, and you can Cancel or Proceed (default is Cancel)."
    echo
    apt__capture "$cmd" 2>&1 || true
  } >"$tmp"

  # Prefer dialog directly so we can set a friendlier button label.
  if command -v dialog >/dev/null 2>&1; then
    dast_ui_dialog --title "$title" --ok-label "Continue" --textbox "$tmp" 22 80 || true
  else
    ui_textbox "$title" "$tmp"
  fi
  rm -f "$tmp" || true
  trap - EXIT INT TERM
}

apt_preview_box_argv() {
  local title="$1"
  shift
  local tmp
  tmp="$(apt__mktemp_plain)"

  # Ensure temporary file is cleaned up even if the user aborts the textbox.
  trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM

  {
    echo "Command:"
    printf "  "
    local a
    for a in "$@"; do
      printf "%q " "$a"
    done
    echo
    echo
    echo "Next: you will be shown what needs to be installed, and you can Cancel or Proceed (default is Cancel)."
    echo
    apt__capture "$@" 2>&1 || true
  } >"$tmp"

  # Prefer dialog directly so we can set a friendlier button label.
  if command -v dialog >/dev/null 2>&1; then
    dast_ui_dialog --title "$title" --ok-label "Continue" --textbox "$tmp" 22 80 || true
  else
    ui_textbox "$title" "$tmp"
  fi
  rm -f "$tmp" || true
  trap - EXIT INT TERM
}

apt_confirm_run() {
  local title="$1"
  local prompt="$2"
  local cmd="$3"

  # Safety: default to "No" so a preview doesn't lead to an accidental "Yes".
  # Prefer dial() (from main) so we inherit the /dev/tty + set -e safe wrapper.
  if declare -F dial >/dev/null 2>&1; then
    if dial --title "Confirm" --defaultno --yes-label "Proceed" --no-label "Cancel" --yesno "$prompt" 12 78; then
      apt_run_box "$title" "$cmd"
    fi
    return 0
  fi

  # Fallback: raw dialog with defaultno.
  if command -v dialog >/dev/null 2>&1; then
    if dast_ui_dialog --title "Confirm" --defaultno --yes-label "Proceed" --no-label "Cancel" --yesno "$prompt" 12 78; then
      apt_run_box "$title" "$cmd"
    fi
    return 0
  fi

  # Last resort: whatever ui_yesno does.
  if ui_yesno "Confirm" "$prompt"; then
    apt_run_box "$title" "$cmd"
  fi
}


apt__apt_sim_has_changes() {
  # Usage: apt__apt_sim_has_changes "<apt-get -s ...>"
  # Returns 0 if the simulation indicates changes (upgrade/install/remove), else 1.
  local sim_cmd="$1"
  local out line
  out="$(eval "$sim_cmd" 2>&1 || true)"

  # Typical apt summary: "0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded."
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove' | tail -n1 || true)"
  if [[ "$line" =~ ^([0-9]+)[[:space:]]+upgraded,[[:space:]]+([0-9]+)[[:space:]]+newly[[:space:]]+installed,[[:space:]]+([0-9]+)[[:space:]]+to[[:space:]]+remove ]]; then
    local u="${BASH_REMATCH[1]}"
    local n="${BASH_REMATCH[2]}"
    local r="${BASH_REMATCH[3]}"
    if (( u + n + r == 0 )); then
      return 1
    fi
    return 0
  fi

  # If we can't parse, be conservative and assume it might do something.
  return 0
}

apt__apt_sim_has_kept_back() {
  # Usage: apt__apt_sim_has_kept_back "<apt-get -s ...>"
  # Returns 0 if the simulation output indicates packages are kept back.
  local sim_cmd="$1"
  local out
  out="$(eval "$sim_cmd" 2>&1 || true)"
  printf '%s\n' "$out" | grep -qiE 'kept back|kept-back' && return 0
  return 1
}

apt_history_collect() {
  local out="$1"

  {
    echo "APT HISTORY VIEW"
    echo "Generated: $(date)"
    echo

    echo "== /var/log/apt/history.log* (most recent first) =="
    echo

    if compgen -G "/var/log/apt/history.log*" >/dev/null; then
      for f in /var/log/apt/history.log*; do
        [[ -e "$f" ]] || continue
        echo "--- $f ---"
        if [[ "$f" == *.gz ]]; then
          zcat "$f" 2>/dev/null | tail -n 250 || true
        else
          tail -n 250 "$f" 2>/dev/null || true
        fi
        echo
      done
    else
      echo "No history logs found."
      echo
    fi

    echo "== /var/log/apt/term.log* (most recent first) =="
    echo

    if compgen -G "/var/log/apt/term.log*" >/dev/null; then
      for f in /var/log/apt/term.log*; do
        [[ -e "$f" ]] || continue
        echo "--- $f ---"
        if [[ "$f" == *.gz ]]; then
          zcat "$f" 2>/dev/null | tail -n 250 || true
        else
          tail -n 250 "$f" 2>/dev/null || true
        fi
        echo
      done
    else
      echo "No term logs found."
      echo
    fi
  } >"$out"
}

apt_show_history() {
  local tmp
  tmp="$(apt__mktemp_plain)"
  apt_history_collect "$tmp"
  ui_textbox "APT History" "$tmp"
  rm -f "$tmp" || true
}

# -----------------------------------------------------------------------------
# Holds management (interactive pickers)
# -----------------------------------------------------------------------------
apt_pick_installed_pkg() {

  local filter
  filter="$(_apt_ui_inputbox "🔒 Manage holds" "Filter (optional, e.g. nginx). Leave blank to list all:" "")" || {
    apt_log "HOLDS pick_installed cancelled at filter input"
    return 1
  }

  local tmp
  tmp="$(apt__mktemp_plain)"
  if [[ -n "${filter:-}" ]]; then
    dpkg-query -W -f='${Package}	${Version}
' 2>/dev/null | grep -i -- "$filter" | sort -u >"$tmp" || true
  else
    dpkg-query -W -f='${Package}	${Version}
' 2>/dev/null | sort -u >"$tmp" || true
  fi

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" || true
    apt_log "HOLDS pick_installed no matches filter=$(printf '%q' "${filter:-}")"
    ui_msg "🔒 Manage holds" "No matching installed packages found."
    return 1
  fi

  local -a items=()
  local pkg ver
  local count=0
  while IFS=$'	' read -r pkg ver; do
    [[ -n "$pkg" ]] || continue
    items+=("$pkg" "v$ver")
    count=$((count+1))
    [[ $count -ge 200 ]] && break
  done <"$tmp"
  rm -f "$tmp" || true

  if [[ "${#items[@]}" -eq 0 ]]; then
    apt_log "HOLDS pick_installed items empty after build filter=$(printf '%q' "${filter:-}")"
    ui_msg "🔒 Manage holds" "No matching installed packages found."
    return 1
  fi

  local choice
  choice="$(ui_menu "🔒 Manage holds" "Pick a package (showing up to 200 matches):" \
    "${items[@]}" \
    "BACK" "Back")" || {
    apt_log "HOLDS pick_installed cancelled at menu filter=$(printf '%q' "${filter:-}")"
    return 1
  }

  if [[ -z "${choice:-}" || "$choice" == "BACK" ]]; then
    apt_log "HOLDS pick_installed back/empty choice filter=$(printf '%q' "${filter:-}")"
    return 1
  fi

  apt_log "HOLDS pick_installed selected pkg=$choice filter=$(printf '%q' "${filter:-}")"
  printf '%s' "$choice"
  return 0
}

apt_pick_held_pkg() {

  local tmp
  tmp="$(apt__mktemp_plain)"
  apt-mark showhold 2>/dev/null | sort -u >"$tmp" || true

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" || true
    apt_log "HOLDS pick_held none held"
    ui_msg "🔒 Manage holds" "No held packages."
    return 1
  fi

  local -a items=()
  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    items+=("$pkg" "held")
  done <"$tmp"
  rm -f "$tmp" || true

  if [[ "${#items[@]}" -eq 0 ]]; then
    apt_log "HOLDS pick_held items empty"
    ui_msg "🔒 Manage holds" "No held packages."
    return 1
  fi

  local choice
  choice="$(ui_menu "🔒 Manage holds" "Pick a held package:" \
    "${items[@]}" \
    "BACK" "Back")" || {
    apt_log "HOLDS pick_held cancelled at menu"
    return 1
  }

  if [[ -z "${choice:-}" || "$choice" == "BACK" ]]; then
    apt_log "HOLDS pick_held back/empty choice"
    return 1
  fi

  apt_log "HOLDS pick_held selected pkg=$choice"
  printf '%s' "$choice"
  return 0
}

apt_manage_holds() {
  while true; do
    local sel
    sel="$(ui_menu "🔒 Manage holds" "Choose:" \
      "VIEW"   "👁️  View held packages" \
      "HOLD"   "📌 Hold a package (picker)" \
      "UNHOLD" "🧷 Unhold a package (picker)" \
      "BACK"   "🔙️ Back")" || return 0

    apt_log "HOLDS menu sel=${sel:-<empty>}"

    case "$sel" in
      VIEW)
        apt_preview_box "Held packages" \
          "apt-mark showhold || true"
        ;;
      HOLD)
        local pkg
        pkg="$(apt_pick_installed_pkg)" || {
          continue
        }

        if ui_yesno "Confirm" "Hold this package?

$pkg

This prevents upgrades for it."; then
          apt_log "HOLDS HOLD confirmed pkg=$pkg"
          apt_run_box "Hold package" \
            "echo \"Holding: $pkg\"; apt-mark hold -- '$pkg'; echo; echo 'Current holds:'; apt-mark showhold || true"
        else
          apt_log "HOLDS HOLD cancelled pkg=$pkg"
        fi
        ;;
      UNHOLD)
        local pkg2
        pkg2="$(apt_pick_held_pkg)" || {
          continue
        }

        if ui_yesno "Confirm" "Unhold this package?

$pkg2

This allows upgrades again."; then
          apt_log "HOLDS UNHOLD confirmed pkg=$pkg2"
          apt_run_box "Unhold package" \
            "echo \"Unholding: $pkg2\"; apt-mark unhold -- '$pkg2'; echo; echo 'Current holds:'; apt-mark showhold || true"
        else
          apt_log "HOLDS UNHOLD cancelled pkg=$pkg2"
        fi
        ;;
      BACK)
        return 0
        ;;
      *)
        ui_msg "Error" "Unknown selection: $sel"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Submenus (Upgrades / Fix / Clean)
# -----------------------------------------------------------------------------
apt_menu_upgrades() {
  while true; do
    local sel
    sel="$(ui_menu "⬆️ Upgrades" "Choose:" \
      "UPDATE"        "🔄 Update package lists (apt-get update)" \
      "RECOMMENDED"   "✅ Update + Upgrade (recommended)" \
      "UPGRADABLE"    "🔍 List upgradable packages" \
      "UPGRADE"       "⬆️ Upgrade (apt-get upgrade)" \
      "DIST_UPGRADE"  "🧠 Dist upgrade (apt-get dist-upgrade)" \
      "FULL_UPGRADE"  "🚀 Full upgrade (apt-get full-upgrade)" \
      "BACK"          "🔙️ Back")" || return 0

    apt_log "UPGRADES menu sel=${sel:-<empty>}"

    case "$sel" in
      UPDATE)
        if [[ "$(id -u)" -ne 0 ]]; then
          ui_msg "$MODULESPEC_TITLE" "This action requires root. Re-run DaST with sudo."
          continue
        fi
        apt_confirm_run "APT Update" \
          "Run:

apt-get update

Proceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update"
        ;;

      RECOMMENDED)
        if [[ "$(id -u)" -ne 0 ]]; then
          ui_msg "$MODULESPEC_TITLE" "This action requires root. Re-run DaST with sudo."
          continue
        fi

        # If there's nothing to upgrade, don't bother prompting.
        if ! apt__apt_sim_has_changes "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s upgrade"; then
          if apt__apt_sim_has_kept_back "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s upgrade"; then
            ui_msg "$MODULESPEC_TITLE" "No packages can be upgraded with 'upgrade' right now, but some are kept back. Try Dist upgrade or Full upgrade."
          else
            ui_msg "$MODULESPEC_TITLE" "No packages require upgrading. Nothing to do."
          fi
          continue
        fi

        apt_preview_box "Preview: apt-get -s upgrade" \
          "apt-get -o Dpkg::Progress-Fancy=0 -s upgrade || true"
        apt_confirm_run "APT Update + Upgrade" \
          "Run:

apt-get update
apt-get -y upgrade

Proceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y upgrade"
        ;;

      UPGRADABLE)
        # Safe to run as non-root; just a view.
        if command -v apt >/dev/null 2>&1; then
          apt_preview_box "Upgradable packages" \
            "apt list --upgradable 2>/dev/null | sed -n '2,\$p' || true"
        else
          apt_preview_box "Upgradable packages (simulation)" \
            "apt-get -o Dpkg::Progress-Fancy=0 -s upgrade || true"
        fi
        ;;

      UPGRADE)
        if [[ "$(id -u)" -ne 0 ]]; then
          ui_msg "$MODULESPEC_TITLE" "This action requires root. Re-run DaST with sudo."
          continue
        fi

        if ! apt__apt_sim_has_changes "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s upgrade"; then
          if apt__apt_sim_has_kept_back "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s upgrade"; then
            ui_msg "$MODULESPEC_TITLE" "No packages can be upgraded with 'upgrade' right now, but some are kept back. Try Dist upgrade or Full upgrade."
          else
            ui_msg "$MODULESPEC_TITLE" "No packages require upgrading. Nothing to do."
          fi
          continue
        fi

        apt_preview_box "Preview: apt-get -s upgrade" \
          "apt-get -o Dpkg::Progress-Fancy=0 -s upgrade || true"
        apt_confirm_run "APT Upgrade" \
          "Run:

apt-get update
apt-get -y upgrade

Proceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y upgrade"
        ;;

      DIST_UPGRADE)
        if [[ "$(id -u)" -ne 0 ]]; then
          ui_msg "$MODULESPEC_TITLE" "This action requires root. Re-run DaST with sudo."
          continue
        fi

        if ! apt__apt_sim_has_changes "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s dist-upgrade"; then
          ui_msg "$MODULESPEC_TITLE" "No packages require a dist-upgrade. Nothing to do."
          continue
        fi

        apt_preview_box "Preview: apt-get -s dist-upgrade" \
          "apt-get -o Dpkg::Progress-Fancy=0 -s dist-upgrade || true"
        apt_confirm_run "APT Dist Upgrade" \
          "Run:

apt-get update
apt-get -y dist-upgrade

Proceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y dist-upgrade"
        ;;

      FULL_UPGRADE)
        if [[ "$(id -u)" -ne 0 ]]; then
          ui_msg "$MODULESPEC_TITLE" "This action requires root. Re-run DaST with sudo."
          continue
        fi

        if ! apt__apt_sim_has_changes "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s full-upgrade"; then
          ui_msg "$MODULESPEC_TITLE" "No packages require a full-upgrade. Nothing to do."
          continue
        fi

        apt_preview_box "Preview: apt-get -s full-upgrade" \
          "apt-get -o Dpkg::Progress-Fancy=0 -s full-upgrade || true"
        apt_confirm_run "APT Full Upgrade" \
          "Run:

apt-get update
apt-get -y full-upgrade

Proceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y full-upgrade"
        ;;

      BACK) return 0 ;;
      *) ui_msg "Error" "Unknown selection: $sel" ;;
    esac
  done
}


apt_menu_fix() {
  while true; do
    local sel
    sel="$(ui_menu "🩹 Fix / Recovery" "Choose:" \
      "FIX_BROKEN"    "🩹 Fix broken deps (apt-get -f install)" \
      "DPKG_CONFIG"   "🧰 Finish interrupted dpkg (dpkg --configure -a)" \
      "BACK"          "Back")" || return 0

    apt_log "FIX menu sel=${sel:-<empty>}"

    case "$sel" in
      FIX_BROKEN)
        apt_confirm_run "Fix broken deps" \
          "Run:\n\napt-get -y -f install\n\nProceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y -f install"
        ;;
      DPKG_CONFIG)
        apt_confirm_run "dpkg recovery" \
          "Run:\n\ndpkg --configure -a\n\nProceed?" \
          "dpkg --configure -a"
        ;;
      BACK) return 0 ;;
      *) ui_msg "Error" "Unknown selection: $sel" ;;
    esac
  done
}

apt_menu_clean() {
  while true; do
    local sel
    sel="$(ui_menu "🧼 Clean-up" "Choose:" \
      "AUTOREMOVE"    "🧹 Autoremove (update + preview + confirm)" \
      "AUTOCLEAN"     "🧼 Autoclean (apt-get autoclean)" \
      "CLEAN"         "🧽 Clean cache (apt-get clean)" \
      "BACK"          "🔙 Back")" || return 0

    apt_log "CLEAN menu sel=${sel:-<empty>}"

    case "$sel" in
      AUTOREMOVE)
        if ! apt_has_autoremove; then
          ui_msg "$MODULESPEC_TITLE" "No packages are currently eligible for autoremove."
          continue
        fi

        apt_preview_box "Preview: apt-get -s autoremove" \
          "apt-get -o Dpkg::Progress-Fancy=0 -s autoremove || true"
        apt_confirm_run "APT Autoremove" \
          "Run:\n\napt-get update\napt-get -y autoremove\n\nProceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y autoremove"
        ;;
      AUTOCLEAN)
        apt_confirm_run "APT Autoclean" \
          "Run:\n\napt-get autoclean\n\nProceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 autoclean"
        ;;
      CLEAN)
        apt_confirm_run "APT Clean" \
          "Run:\n\napt-get clean\n\nProceed?" \
          "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 clean"
        ;;
      BACK) return 0 ;;
      *) ui_msg "Error" "Unknown selection: $sel" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Module entrypoint
# -----------------------------------------------------------------------------
apt_menu_maintenance_custom() {
  local title="$MODULESPEC_TITLE"

  if ! have_dialog; then
    ui_msg "$title" "Dialog is not available, so the custom checklist cannot be shown.\n\nTip: install the 'dialog' package.\n\nReturning to the menu."
    return 0
  fi

  local selection
  if declare -F dial >/dev/null 2>&1; then
    selection="$(dial --title "Maintenance (custom checklist)" \
      --checklist "Select maintenance steps to run:" 22 90 10 \
      "UPDATE"     "Update package lists (apt-get update)" on \
      "AUTOREMOVE" "Remove unused packages (apt-get autoremove)" on \
      "AUTOCLEAN"  "Clear obsolete packages (apt-get autoclean)" on \
      "CLEAN"      "Clear downloaded archives (apt-get clean)" off \
      "HISTORY"    "Show APT history at the end" on)" || return 0
  else
    # Fallback to raw dialog if the main DaST wrapper isn't available.
    selection="$(dast_ui_dialog --title "Maintenance (custom checklist)" \
      --checklist "Select maintenance steps to run:" 22 90 10 \
      "UPDATE"     "Update package lists (apt-get update)" on \
      "AUTOREMOVE" "Remove unused packages (apt-get autoremove)" on \
      "AUTOCLEAN"  "Clear obsolete packages (apt-get autoclean)" on \
      "CLEAN"      "Clear downloaded archives (apt-get clean)" off \
      "HISTORY"    "Show APT history at the end" on \
      --output-fd 1)" || return 0
  fi

  selection="${selection//\"/}"
  local -a tags=()
  # shellcheck disable=SC2206
  tags=($selection)

  if [[ "${#tags[@]}" -eq 0 ]]; then
    ui_msg "$title" "No steps selected.\n\nNothing to do."
    return 0
  fi

  local do_update=0 do_autoremove=0 do_autoclean=0 do_clean=0 do_history=0
  local t
  for t in "${tags[@]}"; do
    case "$t" in
      UPDATE) do_update=1 ;;
      AUTOREMOVE) do_autoremove=1 ;;
      AUTOCLEAN) do_autoclean=1 ;;
      CLEAN) do_clean=1 ;;
      HISTORY) do_history=1 ;;
    esac
  done

  local steps=""
  [[ "$do_update" -eq 1 ]] && steps="${steps}🔹 update\n"
  [[ "$do_autoremove" -eq 1 ]] && steps="${steps}🔹 autoremove\n"
  [[ "$do_autoclean" -eq 1 ]] && steps="${steps}🔹 autoclean\n"
  [[ "$do_clean" -eq 1 ]] && steps="${steps}🔹 clean\n"
  [[ "$do_history" -eq 1 ]] && steps="${steps}🔹 show history after\n"

  local preview_cmd=""
  preview_cmd+="echo 'Selected steps:'; echo; printf '%b' \"$steps\"; echo;"

  if [[ "$do_update" -eq 1 ]]; then
    preview_cmd+="echo '== apt-get -s update =='; echo; LANG=C LC_ALL=C apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s update || true; echo;"
  fi

  if [[ "$do_autoremove" -eq 1 ]]; then
    preview_cmd+="echo '== apt-get -s autoremove =='; echo; LANG=C LC_ALL=C apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -s autoremove || true; echo;"
  fi

  if [[ "$do_autoclean" -eq 1 ]]; then
    preview_cmd+="echo '== apt-get autoclean =='; echo; echo '(autoclean has no useful simulation output)'; echo;"
  fi

  if [[ "$do_clean" -eq 1 ]]; then
    preview_cmd+="echo '== apt-get clean =='; echo; echo '(clean has no simulation output)'; echo;"
  fi

  apt_preview_box "Preview: maintenance (custom)" "$preview_cmd"

  if ! ui_yesno "Confirm" "Run these maintenance steps?\n\n$(printf '%b' "$steps")\nProceed?"; then
    return 0
  fi

  local run_cmd=""
  local sep=""
  if [[ "$do_update" -eq 1 ]]; then
    run_cmd+="${sep}apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update"
    sep=" && "
  fi
  if [[ "$do_autoremove" -eq 1 ]]; then
    run_cmd+="${sep}apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y autoremove"
    sep=" && "
  fi
  if [[ "$do_autoclean" -eq 1 ]]; then
    run_cmd+="${sep}apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y autoclean"
    sep=" && "
  fi
  if [[ "$do_clean" -eq 1 ]]; then
    run_cmd+="${sep}apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 clean"
    sep=" && "
  fi

  if [[ -z "$run_cmd" ]]; then
    ui_msg "$title" "No runnable steps were selected.\n\nNothing to do."
    return 0
  fi

  apt_run_box "APT Maintenance (custom)" "$run_cmd"

  if [[ "$do_history" -eq 1 ]]; then
    apt_show_history
  fi
}


apt_menu_common_installs() {
  # This menu is intentionally conservative:
  # - It installs only a curated set of packages
  # - It checks OS suitability and what's already installed
  # - It defaults to "No" on confirms (via apt_confirm_run)
  # - It requires root (installing packages as a normal user is a footgun)

  if [[ "$(id -u)" -ne 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "Common installs requires root.\n\nRe-run DaST with sudo:\n\n  sudo $0\n"
    return 0
  fi

  local os_id os_like pretty
  os_id=""
  os_like=""
  pretty=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
    pretty="${PRETTY_NAME:-$os_id}"
  else
    pretty="unknown (no /etc/os-release)"
  fi

  local is_ubuntu=0
  if [[ "${os_id,,}" == "ubuntu" ]] || [[ "${os_like,,}" == *ubuntu* ]]; then
    is_ubuntu=1
  fi

  while true; do
    local sel
    sel="$(ui_menu "$MODULESPEC_TITLE" "Common installs (curated)\n\nDetected OS: $pretty\n\nPick a bundle:" \
      "BASE"    "🧰 Common admin tools (curl, git, htop, tmux, jq, ...)" \
      "NET"     "🌐 Network tools (mtr, nmap, tcpdump, iperf3, ...)" \
      "DISK"    "💽 Disk/SMART tools (smartmontools, nvme-cli, ...)" \
      "MONKIT"  "📈 Monitoring toolkit (SMART, NVMe, sensors, sysstat, ...)" \
      "DOCKER"  "🐳 Docker (distro packages: docker.io + compose plugin)" \
      "ZFS"     "🧊 ZFS (Ubuntu only) (zfsutils-linux, zfs-zed)" \
      "BACK"    "🔙 Back")" || return 0

    case "$sel" in
      BASE)
        apt__common_install_bundle "Common admin tools" \
          curl ca-certificates wget git htop ncdu tmux jq ripgrep unzip
        ;;
      NET)
        apt__common_install_bundle "Network tools" \
          mtr-tiny nmap tcpdump iperf3 dnsutils net-tools
        ;;
      DISK)
        apt__common_install_bundle "Disk / SMART tools" \
          smartmontools nvme-cli lsof fio
        ;;
      MONKIT)
        apt__common_install_checklist_bundle "Monitoring toolkit" \
          "smartmontools" "SMART health checks (smartctl)" \
          "nvme-cli"      "NVMe health & wear stats" \
          "lm-sensors"    "Temperature/fan sensors (sensors)" \
          "sysstat"       "iostat/mpstat/sar performance stats" \
          "ethtool"       "NIC link info & error counters" \
          "dnsutils"      "DNS tools (dig/nslookup)" \
          "ncdu"          "Disk usage browser (ncdu)" \
          "htop"          "Interactive process viewer" \
          "psmisc"        "Extra process tools (pstree, killall)" \
          "pciutils"      "Hardware reporting (lspci)" \
          "usbutils"      "Hardware reporting (lsusb)"
        ;;
      DOCKER)
        # Keeping this repo-simple by default: Debian/Ubuntu packages.
        apt__common_install_bundle "Docker (distro packages)" \
          docker.io docker-compose-plugin
        ;;
      ZFS)
        if (( ! is_ubuntu )); then
          ui_msg "$MODULESPEC_TITLE" "ZFS install is restricted to Ubuntu in DaST.\n\nDetected: $pretty\n\nReason: packaging and kernel module expectations vary across Debian derivatives.\n\nIf you really want ZFS on non-Ubuntu, do it manually so you can own the trade-offs."
          continue
        fi
        apt__common_install_bundle "ZFS (Ubuntu)" \
          zfsutils-linux zfs-zed
        ;;
      BACK) return 0 ;;
      *) ui_msg "Error" "Unknown selection: $sel" ;;
    esac
  done
}

apt__common_install_bundle() {
  local label="$1"; shift
  local pkgs=("$@")

  # Work out what's missing
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    ui_msg "$MODULESPEC_TITLE" "✅ $label\n\nAll packages in this bundle are already installed."
    return 0
  fi

  # Build a safely-quoted package list for the command script
  local missing_q=""
  for p in "${missing[@]}"; do
    missing_q+=" $(printf '%q' "$p")"
  done
  missing_q="${missing_q# }"

  # Preview (dry run) to reduce surprises
  ui_msg "$MODULESPEC_TITLE" "Next you will see a preview of what APT wants to do.

After the preview you can Cancel or Proceed (default is Cancel)."

  apt_preview_box "Install preview: $label" \
    "apt-get -s install --no-install-recommends $missing_q 2>&1 || true"

  apt_confirm_run "Install: $label" \
    "This will install the following packages:\n\n${missing[*]}\n\nDaST safety notes:\n- Uses distro APT repos (no vendor repos here)\n- Uses --no-install-recommends to keep it lean\n- Defaults to NO on confirmation\n\nProceed?" \
    "apt-get update || true; echo; apt-get install -y --no-install-recommends $missing_q || true"
}


apt__common_install_checklist_bundle() {
  # Usage:
  #   apt__common_install_checklist_bundle "Label" "pkg1" "desc1" "pkg2" "desc2" ...
  #
  # Shows a checklist with defaults ON for all items.
  # Then confirms with default=Cancel, and installs only missing packages.

  local label="$1"; shift

  if ! have_dialog && ! declare -F dial >/dev/null 2>&1; then
    ui_msg "$MODULESPEC_TITLE" "This action requires 'dialog' for the checklist UI.\n\nInstall it via:\n\n  apt-get install dialog\n\nThen try again."
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    ui_msg "$MODULESPEC_TITLE" "$label requires root.\n\nRe-run DaST with sudo:\n\n  sudo $0\n"
    return 0
  fi

  # Build checklist items (tag, item, status)
  local -a items=()
  local pkg desc status
  while (( $# >= 2 )); do
    pkg="$1"; desc="$2"; shift 2
    status="on"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      desc="$desc (already installed)"
    fi
    items+=("$pkg" "$desc" "$status")
  done

  local selection=""
  if declare -F dial >/dev/null 2>&1; then
    selection="$(dial --title "$label" --checklist \
      "Select what to install (defaults ON for all):" 22 90 12 \
      "${items[@]}")" || return 0
  else
    selection="$(dast_ui_dialog --title "$label" --checklist \
      "Select what to install (defaults ON for all):" 22 90 12 \
      "${items[@]}" 3>&1 1>&2 2>&3)" || return 0
  fi

  # dialog returns items like: "pkg1" "pkg2"
  selection="${selection//\"/}"
  selection="$(echo "$selection" | xargs 2>/dev/null || true)"

  if [[ -z "$selection" ]]; then
    ui_msg "$MODULESPEC_TITLE" "Nothing selected.\n\nNothing to do."
    return 0
  fi

  # Work out what's missing from the selection
  local -a missing=()
  for pkg in $selection; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    ui_msg "$MODULESPEC_TITLE" "✅ $label\n\nEverything you selected is already installed."
    return 0
  fi

  # Quote packages for shell safety
  local missing_q=""
  for pkg in "${missing[@]}"; do
    missing_q+=" $(printf '%q' "$pkg")"
  done
  missing_q="${missing_q# }"

  # Preview (dry run)
  ui_msg "$MODULESPEC_TITLE" "Next you will see a preview of what APT wants to do.

After the preview you can Cancel or Proceed (default is Cancel)."

  apt_preview_box "Install preview: $label" \
    "apt-get -s install --no-install-recommends $missing_q 2>&1 || true"

  # Confirm (default Cancel via apt_confirm_run behaviour)
  apt_confirm_run "Install: $label" \
    "This will install the following packages (already-installed selections will be skipped):\n\n${missing[*]}\n\nDefault is Cancel.\n\nProceed?" \
    "apt-get update || true; echo; apt-get install -y --no-install-recommends $missing_q || true"
}
module_APT() {
  local MODULESPEC_TITLE="📦 APT (packages)"
  apt_log_init
  apt_log "APT module start uid=$(id -u) user=$(id -un 2>/dev/null || echo '?') log_file=$APT_LOG_FILE"

  while true; do
    local sel
    sel="$(ui_menu "$MODULESPEC_TITLE" "Choose:" \
      "UPGRADES_MENU" "⬆️ Upgrades (update/upgrade/dist/full)" \
      "MAINT"         "🧰 Maintenance bundle (update + autoremove + clean up + show history)" \
      "MAINT_CUSTOM"  "🧰 Maintenance (custom checklist)" \
      "COMMON_INSTALLS" "🧩 Common installs (curated)" \
      "FIX_MENU"      "🩹 Fix / recovery (broken deps, dpkg)" \
      "CLEAN_MENU"    "🧼 Clean-up (autoremove, autoclean, clean)" \
      "HOLDS_MENU"    "🔒 Manage holds (view/hold/unhold)" \
      "HISTORY"       "🕘 View APT history (history.log / term.log)" \
      "SEARCH"        "🔎 Search packages (apt-cache search)" \
      "SHOW"          "📄 Show package details (apt-cache show)" \
      "POLICY"        "🧭 Package policy (apt-cache policy)" \
      "SOURCES"       "📝 Edit APT sources (with backup)" \
      "BACK"          "🔙 Back")" || return 0

    apt_log "MAIN menu sel=${sel:-<empty>}"

    case "$sel" in
      UPGRADES_MENU) apt_menu_upgrades ;;
      MAINT)
        apt_preview_box "Preview: maintenance bundle" \
          "echo '== apt-get -s autoremove =='; echo; apt-get -o Dpkg::Progress-Fancy=0 -s autoremove || true; echo; echo '---'; echo; echo '== apt-get -s autoclean =='; echo; apt-get -o Dpkg::Progress-Fancy=0 -s autoclean || true; echo; echo '---'; echo; echo '== apt-get clean =='; echo; echo '(clean has no simulation output)'"

        if ui_yesno "Confirm" "Run maintenance bundle?\n\nThis will run:\n\n1) apt-get update\n2) apt-get -y autoremove\n3) apt-get -y autoclean\n4) apt-get clean\n\nThen it will show APT history logs.\n\nProceed?"; then
          apt_run_box "APT Maintenance bundle" \
            "apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 update && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y autoremove && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 -y autoclean && apt-get -o Dpkg::Progress-Fancy=0 -o APT::Colour=0 clean"
          apt_show_history
        fi
        ;;
      MAINT_CUSTOM)
        apt_menu_maintenance_custom
        ;;
      COMMON_INSTALLS)
        apt_menu_common_installs
        ;;
      FIX_MENU) apt_menu_fix ;;
      CLEAN_MENU) apt_menu_clean ;;
      HOLDS_MENU) apt_manage_holds ;;
      HISTORY) apt_show_history ;;
      SEARCH)
        local q
        q="$(ui_inputbox "$MODULESPEC_TITLE" "Search term (apt-cache search):" "")" || continue
        [[ -z "${q:-}" ]] && continue
        apt_preview_box_argv "Search results: $q" \
          apt-cache search -- "$q"
        ;;
      SHOW)
        local pkg
        pkg="$(ui_inputbox "$MODULESPEC_TITLE" "Package name (apt-cache show):" "")" || continue
        [[ -z "${pkg:-}" ]] && continue
        apt_preview_box_argv "Package details: $pkg" \
          apt-cache show -- "$pkg"
        ;;
      POLICY)
        local pkg2
        pkg2="$(ui_inputbox "$MODULESPEC_TITLE" "Package name (apt-cache policy):" "")" || continue
        [[ -z "${pkg2:-}" ]] && continue
        apt_preview_box_argv "Policy: $pkg2" \
          apt-cache policy -- "$pkg2"
        ;;
      SOURCES)
        local f
        f="$(pick_sources_file)" || continue
        [[ "$f" == "BACK" || -z "$f" ]] && continue
        edit_sources_file_dialog "$f"
        ;;
      BACK) return 0 ;;
      *) ui_msg "Error" "Unknown selection: $sel" ;;
    esac
  done
}

if apt_is_valid_apt_system; then
  register_module "$module_id" "$module_title" "module_APT"
fi