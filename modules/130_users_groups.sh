#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Users & Groups (v0.9.8.4)
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

module_id="USRGRP"
module_title="👥 Users & Groups"
MODULE_USERS_TITLE="👥 Users & Groups"



# -----------------------------------------------------------------------------
# Logging helpers (standard always, debug only when --debug)
# -----------------------------------------------------------------------------
if ! declare -F dast_log >/dev/null 2>&1; then
  dast_log() { :; }
fi
if ! declare -F dast_dbg >/dev/null 2>&1; then
  dast_dbg() { :; }
fi
users__try_source_helper() {
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
    #   modules/45_users_groups.sh -> lib/dast_helper.sh
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

# Attempt helper load at source-time (safe; if it fails, we continue)
users__try_source_helper >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# DaST logging hooks (provided by main DaST; no-op if unavailable)
# ----------------------------------------------------------------------------
users__log() {
  # Usage: users__log LEVEL message...
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$@"
  fi
}

users__dbg() {
  # Usage: users__dbg message...
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$*"
  fi
}

# If helper didn't load, record a breadcrumb (before local stubs are defined).
if ! declare -F mktemp_safe >/dev/null 2>&1; then
  users__log "WARN" "Users & Groups: dast_helper.sh not loaded; using local stubs."
  users__dbg "Users & Groups: helper missing at source-time; local stubs will be used."
fi


# -----------------------------------------------------------------------------
# Safe stubs if helper wasn't loaded
# -----------------------------------------------------------------------------
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
  run() { "$@"; }
fi

if ! declare -F run_capture >/dev/null 2>&1; then
  run_capture() { "$@"; }
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

# Optional helpers used here; if absent, we fall back to dialog directly.
users__checklist() {
  local title="$1"; shift
  local prompt="$1"; shift
  if declare -F ui_checklist >/dev/null 2>&1; then
    ui_checklist "$title" "$prompt" "$@"
    return $?
  fi
  # Fallback: try raw dialog
  if command -v dialog >/dev/null 2>&1; then
    dast_ui_dialog --title "$title" --checklist "$prompt" 20 80 14 "$@"
    return $?
  fi
  return 1
}

users__radiolist() {
  local title="$1"; shift
  local prompt="$1"; shift
  if declare -F ui_radiolist >/dev/null 2>&1; then
    ui_radiolist "$title" "$prompt" "$@"
    return $?
  fi
  if command -v dialog >/dev/null 2>&1; then
    dast_ui_dialog --title "$title" --radiolist "$prompt" 20 80 14 "$@"
    return $?
  fi
  return 1
}

users__s1list() {
  # Single-select list helper.
  # Prefers ui_s1list (DaST), then ui_menu, then dialog.
  #
  # IMPORTANT: In DaST wrappers, Cancel can return rc=0 with an empty string.
  # Treat empty selection as Cancel to prevent redraw/resize oddities.
  local title="$1"; shift
  local prompt="$1"; shift
  local sel rc

  if declare -F ui_s1list >/dev/null 2>&1; then
    sel="$(ui_s1list "$title" "$prompt" "$@")"
    rc=$?
    if [[ $rc -eq 0 && -n "${sel:-}" ]]; then
      printf '%s' "$sel"
      return 0
    fi
    return 1
  fi

  if declare -F ui_menu >/dev/null 2>&1; then
    sel="$(ui_menu "$title" "$prompt" "$@")"
    rc=$?
    if [[ $rc -eq 0 && -n "${sel:-}" ]]; then
      printf '%s' "$sel"
      return 0
    fi
    return 1
  fi

  # Last resort: raw dialog menu (scrollable/selectable).
  local dlg="${DAST_DIALOG_BIN:-${DIALOG_BIN:-${DIALOG:-dialog}}}"
  sel="$( "$dlg" --title "$title" --menu "$prompt" 20 80 14 "$@" 2>&1 >/dev/tty)"
  rc=$?
  if [[ $rc -eq 0 && -n "${sel:-}" ]]; then
    printf '%s' "$sel"
    return 0
  fi

  return 1
}



# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
users__is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

users__need_root() {
  local what="$1"
  if users__is_root; then
    return 0
  fi
  ui_msgbox "$MODULE_USERS_TITLE" "❌ Root required\n\n$what\n\nRe-run DaST with sudo (or run this module from a root shell)."
  return 1
}

users__cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

users__crumb() {
  local parts=()
  while [[ $# -gt 0 ]]; do
    parts+=("$1")
    shift
  done

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "$MODULE_USERS_TITLE"
    return 0
  fi

  local out="$MODULE_USERS_TITLE"
  local p
  for p in "${parts[@]}"; do
    out+=" → $p"
  done
  echo "$out"
}

users__current_user() {
  # Prefer DaST's invoker user if available.
  if [[ -n "${DAST_INVOKER_USER:-}" ]]; then
    echo "$DAST_INVOKER_USER"
    return 0
  fi

  # Prefer the real human user behind sudo where possible.
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    echo "$SUDO_USER"
    return 0
  fi
  local u=""
  u="$(logname 2>/dev/null || true)"
  if [[ -n "$u" && "$u" != "root" ]]; then
    echo "$u"
    return 0
  fi
  u="$(who am i 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
  if [[ -n "$u" && "$u" != "root" ]]; then
    echo "$u"
    return 0
  fi
  id -un 2>/dev/null || whoami 2>/dev/null || echo "unknown"
}

users__user_exists() { id -u "$1" >/dev/null 2>&1; }
users__group_exists() { getent group "$1" >/dev/null 2>&1; }

users__user_primary_group() {
  id -gn "$1" 2>/dev/null || true
}

users__is_self_or_root() {
  local u=\"${1:-}\"
  [[ -n \"$u\" ]] || return 1
  local me
  me="$(users__current_user)"
  [[ "$u" == "root" ]] && return 0
  [[ "$u" == "$me" ]] && return 0
  return 1
}

users__valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
users__valid_groupname() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

users__detect_admin_group() {
  if users__group_exists sudo; then
    echo "sudo"
    return 0
  fi
  if users__group_exists wheel; then
    echo "wheel"
    return 0
  fi
  echo ""
  return 1
}

users__list_users_table() {
  run_capture getent passwd 2>/dev/null | awk -F: '
    BEGIN {
      printf "%-20s %-6s %-6s %-28s %-26s %s\n", "user", "uid", "gid", "home", "shell", "gecos"
      printf "%-20s %-6s %-6s %-28s %-26s %s\n", "----", "---", "---", "----", "-----", "-----"
    }
    {
      u=$1; uid=$3; gid=$4; gecos=$5; home=$6; shell=$7;
      if (length(home)>28) home=substr(home,1,25)"...";
      if (length(shell)>26) shell=substr(shell,1,23)"...";
      printf "%-20s %-6s %-6s %-28s %-26s %s\n", u, uid, gid, home, shell, gecos
    }
  '
}

users__list_groups_table() {
  run_capture getent group 2>/dev/null | awk -F: '
    BEGIN {
      printf "%-24s %-6s %s\n", "group", "gid", "members"
      printf "%-24s %-6s %s\n", "-----", "---", "-------"
    }
    {
      g=$1; gid=$3; m=$4;
      if (length(m)>55) m=substr(m,1,52)"...";
      printf "%-24s %-6s %s\n", g, gid, m
    }
  '
}


users__menu_pick_user() {
  # Build a proper Tag/Description pair list of users for dialog/ui_menu.
  # Use getent so NSS/LDAP users are included.
  local items=()
  local user _ uid _ gecos _

  while IFS=: read -r user _ uid _ gecos _; do
    # Always include everything (like Services lists everything).
    # Keep description compact for TTY friendliness.
    local desc="UID: $uid"
    if [[ -n "${gecos:-}" ]]; then
      desc="$desc | ${gecos}"
    fi
    items+=("$user" "$desc")
  done < <(getent passwd 2>/dev/null | sort -t: -k1,1)

  if [[ ${#items[@]} -eq 0 ]]; then
    ui_msgbox "$MODULE_USERS_TITLE" "❌ No users found (getent passwd returned nothing)."
    return 1
  fi

  users__s1list "$(users__crumb "Users" "Select")" "Choose a user:" "${items[@]}"
}


users__menu_pick_group() {
  # Build a proper Tag/Description pair list of groups for dialog/ui_menu.
  local items=()
  local g _ gid members

  while IFS=: read -r g _ gid members; do
    # Show a short member hint (truncate for readability).
    local m="${members:-}"
    if [[ ${#m} -gt 42 ]]; then m="${m:0:42}…"; fi
    local desc="GID: $gid"
    if [[ -n "$m" ]]; then desc="$desc | $m"; fi
    items+=("$g" "$desc")
  done < <(getent group 2>/dev/null | sort -t: -k1,1)

  if [[ ${#items[@]} -eq 0 ]]; then
    ui_msgbox "$MODULE_USERS_TITLE" "❌ No groups found (getent group returned nothing)."
    return 1
  fi

  users__s1list "$(users__crumb "Groups" "Select")" "Choose a group:" "${items[@]}"
}


users__pick_user() {
  # Always attempt an interactive picker first.
  # If the user cancels, return non-zero and do NOT fall back to manual input.
  local sel
  sel="$(users__menu_pick_user 2>/dev/null)" || return 1
  sel="${sel//\"/}"
  sel="$(echo "$sel" | tr -d '[:space:]')"
  [[ -n "$sel" ]] || return 1
  echo "$sel"
  return 0
}


users__pick_group() {
  local sel
  sel="$(users__menu_pick_group 2>/dev/null)" || return 1
  sel="${sel//\"/}"
  sel="$(echo "$sel" | tr -d '[:space:]')"
  [[ -n "$sel" ]] || return 1
  echo "$sel"
  return 0
}


users__show_user_info() {
  local u="${1:-}"
  [[ -n "$u" ]] || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  local tmp
  tmp="$(mktemp_safe)" || return 1
  {
    echo "User: $u"
    echo "----------------------------------------"
    echo
    echo "id:"
    id "$u" 2>/dev/null || true
    echo
    echo "passwd status:"
    passwd -S "$u" 2>/dev/null || true
    echo
    echo "primary group:"
    users__user_primary_group "$u" 2>/dev/null || true
    echo
    echo "groups:"
    id -nG "$u" 2>/dev/null || true
    echo
    echo "/etc/passwd info:"
    getent passwd "$u" 2>/dev/null | awk -F: '{print "  home: " $6 "\n  shell: " $7 "\n  gecos: " $5}' || true
    echo
    echo "lastlog:"
    lastlog -u "$u" 2>/dev/null || true
  } >"$tmp"
  ui_textbox "$(users__crumb "Users" "Info")" "$tmp"
}

users__show_group_info() {
  local g="${1:-}"
  [[ -n "$g" ]] || return 0
  users__group_exists "$g" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ Group '$g' does not exist."; return 0; }

  local tmp
  tmp="$(mktemp_safe)" || return 1
  {
    echo "Group: $g"
    echo "----------------------------------------"
    echo
    echo "getent group:"
    getent group "$g" 2>/dev/null || true
    echo
    echo "Members:"
    getent group "$g" 2>/dev/null | awk -F: '{print ($4=="" ? "  (none)" : "  " $4)}' || true
  } >"$tmp"
  ui_textbox "$(users__crumb "Groups" "Info")" "$tmp"
}

# -----------------------------------------------------------------------------
# Actions: Users
# -----------------------------------------------------------------------------
users__action_create_user() {
  users__need_root "Create a new user." || return 0

  local u
  u="$(ui_inputbox "$(users__crumb "Users" "Create")" "Username:" "")" || return 0
  u="${u//\"/}"
  u="$(echo "$u" | tr -d '[:space:]')"
  [[ -n "$u" ]] || return 0

  if ! users__valid_username "$u"; then
    ui_msgbox "$MODULE_USERS_TITLE" "❌ Invalid username\n\nExpected: [a-z_][a-z0-9_-]{0,31}\n\nGot: $u"
    return 0
  fi
  if users__user_exists "$u"; then
    ui_msgbox "$MODULE_USERS_TITLE" "💡 User already exists: $u"
    return 0
  fi

  local gecos shell
  gecos="$(ui_inputbox "$(users__crumb "Users" "Create")" "Full name (optional):" "")" || return 0
  gecos="${gecos//\"/}"

  shell="$(ui_inputbox "$(users__crumb "Users" "Create")" "Shell (blank = default):" "")" || return 0
  shell="${shell//\"/}"
  shell="$(echo "$shell" | tr -d '[:space:]')"

  local -a cmd=(useradd -m)
  [[ -n "$gecos" ]] && cmd+=(-c "$gecos")
  [[ -n "$shell" ]] && cmd+=(-s "$shell")
  cmd+=("$u")

  if ! ui_yesno "$(users__crumb "Users" "Create")" "Create user '$u'?\n\nCommand:\n${cmd[*]}"; then
    return 0
  fi

  run "${cmd[@]}" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ User created: $u\n\nNext: set a password."
}

users__action_set_password() {
  users__need_root "Set a user's password." || return 0
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  ui_msgbox "$(users__crumb "Users" "Password")" "You will now run:\n\n  passwd $u"
  run passwd "$u"
}

users__action_force_pw_change() {
  users__need_root "Force password change at next login." || return 0
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  if ! users__cmd_exists chage; then
    ui_msgbox "$MODULE_USERS_TITLE" "❌ chage not available on this system."
    return 0
  fi

  if ! ui_yesno "$(users__crumb "Users" "Password")" "Force '$u' to change password at next login?\n\nCommand:\nchage -d 0 $u"; then
    return 0
  fi

  run chage -d 0 "$u" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ '$u' will be prompted to change password at next login."
}

users__action_lock_unlock() {
  users__need_root "Lock or unlock a user." || return 0

  local u
  u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  local st action
  st="$(passwd -S "$u" 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$st" == "L" ]]; then
    action="unlock"
  else
    action="lock"
  fi

  if [[ "$action" == "lock" ]]; then
    if users__is_self_or_root "$u"; then
      ui_msgbox "$MODULE_USERS_TITLE" "🛡️ Refusing to lock '$u'\n\n(Protects root and your current session user.)"
      return 0
    fi
    if ! ui_yesno "$(users__crumb "Users" "Lock")" "Lock account '$u'?\n\nThis prevents password logins."; then
      return 0
    fi
    run usermod -L "$u" || run passwd -l "$u" || return 0
    ui_msgbox "$MODULE_USERS_TITLE" "✅ Locked: $u"
  else
    if ! ui_yesno "$(users__crumb "Users" "Unlock")" "Unlock account '$u'?"; then
      return 0
    fi
    run usermod -U "$u" || run passwd -u "$u" || return 0
    ui_msgbox "$MODULE_USERS_TITLE" "✅ Unlocked: $u"
  fi
}

users__action_edit_user() {
  users__need_root "Edit user shell/full name." || return 0
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  local gecos shell
  gecos="$(getent passwd "$u" 2>/dev/null | awk -F: '{print $5}' || true)"
  shell="$(getent passwd "$u" 2>/dev/null | awk -F: '{print $7}' || true)"

  local new_gecos new_shell
  new_gecos="$(ui_inputbox "$(users__crumb "Users" "Edit")" "Full name (GECOS) for '$u':" "$gecos")" || return 0
  new_gecos="${new_gecos//\"/}"

  new_shell="$(ui_inputbox "$(users__crumb "Users" "Edit")" "Shell for '$u':" "$shell")" || return 0
  new_shell="${new_shell//\"/}"
  new_shell="$(echo "$new_shell" | tr -d '[:space:]')"

  local -a cmd=(usermod)
  local changed=0

  if [[ "$new_gecos" != "$gecos" ]]; then
    cmd+=(-c "$new_gecos")
    changed=1
  fi
  if [[ -n "$new_shell" && "$new_shell" != "$shell" ]]; then
    cmd+=(-s "$new_shell")
    changed=1
  fi
  cmd+=("$u")

  if [[ "$changed" -eq 0 ]]; then
    ui_msgbox "$MODULE_USERS_TITLE" "💡 No changes to apply."
    return 0
  fi

  if ! ui_yesno "$(users__crumb "Users" "Edit")" "Apply changes to '$u'?\n\nCommand:\n${cmd[*]}"; then
    return 0
  fi

  run "${cmd[@]}" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ Updated: $u"
}

users__action_set_groups() {
  users__need_root "Set supplementary groups for a user." || return 0
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  local primary
  primary="$(users__user_primary_group "$u")"

  local raw
  raw="$(run_capture getent group 2>/dev/null || true)"

  local -a opts=()
  local g members status desc
  while IFS=: read -r g _ _ members; do
    [[ -z "$g" ]] && continue
    desc="group"
    status="off"

    if [[ "$g" == "$primary" ]]; then
      desc="primary (kept)"
      status="on"
    else
      if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
        status="on"
      fi
    fi

    opts+=("$g" "$desc" "$status")
  done <<< "$raw"

  local selected
  selected="$(users__checklist "$(users__crumb "Users" "Groups")" "Select supplementary groups for '$u'.\nPrimary group: $primary" "${opts[@]}")" || return 0
  selected="$(echo "$selected" | tr -d '"')"
  selected="$(echo "$selected" | tr ' ' ',' | sed 's/^,//; s/,$//')"

  if ! ui_yesno "$(users__crumb "Users" "Groups")" "Set supplementary groups for '$u' to:\n\n${selected:-"(none)"}"; then
    return 0
  fi

  if [[ -z "$selected" ]]; then
    run usermod -G "" "$u" || return 0
  else
    run usermod -G "$selected" "$u" || return 0
  fi

  ui_msgbox "$MODULE_USERS_TITLE" "✅ Groups updated for: $u"
}

# ----------------------------------------------------------------------
# Additional safe helpers (DaST philosophy: guarded, predictable)
# ----------------------------------------------------------------------

users__user_home_dir() {
  local u="$1"
  getent passwd "$u" 2>/dev/null | awk -F: '{print $6}'
}

users__is_logged_in() {
  # returns 0 if user appears in who(1)
  local u="$1"
  who 2>/dev/null | awk '{print $1}' | grep -qx "$u"
}

users__action_fix_home_ownership() {
  users__need_root "Fix home ownership" || return 1
  local u="$1"
  [[ -n "$u" ]] || return 1

  local home; home="$(users__user_home_dir "$u")"
  [[ -n "$home" ]] || { ui_msgbox "$MODULE_USERS_TITLE" "❌ Could not determine home directory for '$u'."; return 1; }

  if [[ ! -d "$home" ]]; then
    ui_msgbox "$(users__crumb "Users" "Fix home" "$u")" "❌ Home directory does not exist:\n\n$home"
    return 1
  fi

  local pg; pg="$(users__user_primary_group "$u" 2>/dev/null || true)"
  [[ -n "$pg" ]] || pg="$u"

  ui_yesno "$(users__crumb "Users" "Fix home" "$u")" \
    "This will recursively set ownership of:\n\n$home\n\nto:\n\n$u:$pg\n\nProceed?" || return 0

  users__run chown -R "$u:$pg" "$home"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    ui_msgbox "$(users__crumb "Users" "Fix home" "$u")" "✅ Ownership updated."
  else
    ui_msgbox "$(users__crumb "Users" "Fix home" "$u")" "❌ Failed (rc=$rc)."
  fi
}

users__action_disable_login() {
  users__need_root "Disable login" || return 1
  local u="$1"
  [[ -n "$u" ]] || return 1

  local nologin=""
  for nologin in /usr/sbin/nologin /sbin/nologin /bin/false; do
    [[ -x "$nologin" ]] && break
  done
  [[ -x "$nologin" ]] || { ui_msgbox "$(users__crumb "Users" "Disable login" "$u")" "❌ No nologin binary found."; return 1; }

  ui_yesno "$(users__crumb "Users" "Disable login" "$u")" \
    "This will set the login shell for '$u' to:\n\n$nologin\n\nProceed?" || return 0

  users__run usermod -s "$nologin" "$u"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    ui_msgbox "$(users__crumb "Users" "Disable login" "$u")" "✅ Login disabled (shell set to nologin/false)."
  else
    ui_msgbox "$(users__crumb "Users" "Disable login" "$u")" "❌ Failed (rc=$rc)."
  fi
}

users__action_enable_login() {
  users__need_root "Enable login" || return 1
  local u="$1"
  [[ -n "$u" ]] || return 1

  local shell
  shell="$(ui_inputbox "$(users__crumb "Users" "Enable login" "$u")" \
    "Enter a login shell for '$u' (example: /bin/bash):" "/bin/bash")" || return 0
  shell="$(echo "$shell" | xargs 2>/dev/null || echo "$shell")"

  [[ -n "$shell" ]] || return 0
  [[ -x "$shell" ]] || { ui_msgbox "$(users__crumb "Users" "Enable login" "$u")" "❌ Shell is not executable:\n\n$shell"; return 1; }

  ui_yesno "$(users__crumb "Users" "Enable login" "$u")" \
    "Set login shell for '$u' to:\n\n$shell\n\nProceed?" || return 0

  users__run usermod -s "$shell" "$u"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    ui_msgbox "$(users__crumb "Users" "Enable login" "$u")" "✅ Login shell updated."
  else
    ui_msgbox "$(users__crumb "Users" "Enable login" "$u")" "❌ Failed (rc=$rc)."
  fi
}

users__action_set_primary_group() {
  users__need_root "Set primary group" || return 1
  local u="$1"
  [[ -n "$u" ]] || return 1

  local g
  g="$(users__pick_group)" || return 0
  users__group_exists "$g" || { ui_msgbox "$(users__crumb "Users" "Primary group" "$u")" "❌ Group '$g' does not exist."; return 1; }

  ui_yesno "$(users__crumb "Users" "Primary group" "$u")" \
    "Set primary group for '$u' to:\n\n$g\n\nProceed?" || return 0

  users__run usermod -g "$g" "$u"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    ui_msgbox "$(users__crumb "Users" "Primary group" "$u")" "✅ Primary group updated."
  else
    ui_msgbox "$(users__crumb "Users" "Primary group" "$u")" "❌ Failed (rc=$rc)."
  fi
}

users__action_find_owned_files() {
  users__need_root "Find owned files" || return 1
  local u="$1"
  [[ -n "$u" ]] || return 1

  local scope
  scope="$(ui_menu "$(users__crumb "Users" "Find owned files" "$u")" "Choose search scope (safe default is /home):" \
    "HOME"  "🏠 Home only (recommended)" \
    "ROOTFS" "💣 Entire filesystem (slow)" \
    "BACK"  "🔙️ Back" \
  )" || return 0

  [[ "$scope" == "BACK" ]] && return 0

  local path="/home"
  if [[ "$scope" == "HOME" ]]; then
    path="$(users__user_home_dir "$u")"
    [[ -n "$path" ]] || path="/home"
  else
    path="/"
  fi

  ui_yesno "$(users__crumb "Users" "Find owned files" "$u")" \
    "This will scan:\n\n$path\n\nfor files owned by:\n\n$u\n\nProceed?" || return 0

  local tmp; tmp="$(users__mktemp)" || return 1
  {
    echo "Files owned by: $u"
    echo "Scope: $path"
    echo "----------------------------------------"
    echo
    # Avoid pseudo filesystems when scanning /
    if [[ "$path" == "/" ]]; then
      find / \
        \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
        -user "$u" -print 2>/dev/null | head -n 200
      echo
      echo "(Showing first 200 matches. Use a narrower scope for full detail.)"
    else
      find "$path" -user "$u" -print 2>/dev/null | head -n 200
      echo
      echo "(Showing first 200 matches.)"
    fi
  } >"$tmp"
  ui_textbox "$(users__crumb "Users" "Find owned files" "$u")" "$tmp"
  rm -f "$tmp"
}

users__action_migrate_home() {
  users__need_root "Migrate home dir" || return 1
  local u="$1"
  [[ -n "$u" ]] || return 1

  local old_home; old_home="$(users__user_home_dir "$u")"
  [[ -n "$old_home" ]] || { ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ Could not determine current home directory."; return 1; }

  if [[ ! -d "$old_home" ]]; then
    ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ Current home directory does not exist:\n\n$old_home"
    return 1
  fi

  if users__is_logged_in "$u"; then
    ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" \
      "⚠ '$u' appears to be logged in.\n\nMigrating a home directory while the user is active can cause data loss.\n\nLog them out first if possible."
  fi

  local new_home
  new_home="$(ui_inputbox "$(users__crumb "Users" "Migrate home" "$u")" \
    "Current home:\n$old_home\n\nEnter NEW home directory path:" "/home/$u")" || return 0
  new_home="$(echo "$new_home" | xargs 2>/dev/null || echo "$new_home")"
  [[ -n "$new_home" ]] || return 0

  if [[ "$new_home" == "$old_home" ]]; then
    ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "Nothing to do (new home equals current)."
    return 0
  fi

  if [[ -e "$new_home" && ! -d "$new_home" ]]; then
    ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ Destination exists and is not a directory:\n\n$new_home"
    return 1
  fi

  local mode
  mode="$(ui_menu "$(users__crumb "Users" "Migrate home" "$u")" \
    "Choose method:" \
    "MOVE" "🚚 Move (usermod -d NEW -m) (fast, same filesystem best)" \
    "COPY" "📦 Copy via rsync, then switch (safer across filesystems)" \
    "BACK" "🔙️ Back" \
  )" || return 0
  [[ "$mode" == "BACK" ]] && return 0

  ui_yesno "$(users__crumb "Users" "Migrate home" "$u")" \
    "Proceed to migrate home for '$u'?\n\nFROM:\n$old_home\n\nTO:\n$new_home\n\nMethod: $mode" || return 0

  local pg; pg="$(users__user_primary_group "$u" 2>/dev/null || true)"
  [[ -n "$pg" ]] || pg="$u"

  # Ensure destination exists
  users__run mkdir -p "$new_home"

  if [[ "$mode" == "MOVE" ]]; then
    users__run usermod -d "$new_home" -m "$u"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ usermod move failed (rc=$rc).\n\nTip: try COPY method for cross-filesystem moves."
      return 1
    fi
  else
    if ! command -v rsync >/dev/null 2>&1; then
      ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ rsync is required for COPY method."
      return 1
    fi

    # Copy content (preserve as much as practical; numeric ids are safer if UID changes later)
    users__run rsync -aHAX --numeric-ids --info=stats2 "$old_home"/ "$new_home"/
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ rsync failed (rc=$rc). Home not switched."
      return 1
    fi

    # Switch home in passwd entry (do not auto-move, we've already copied)
    users__run usermod -d "$new_home" "$u"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ usermod failed to set new home (rc=$rc)."
      return 1
    fi

    # Ensure ownership sane
    users__run chown -R "$u:$pg" "$new_home" >/dev/null 2>&1 || true
  fi

  ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "✅ Home migration complete.\n\nNew home:\n$new_home"

  # Optional cleanup: archive old home instead of deleting
  if ui_yesno "$(users__crumb "Users" "Migrate home" "$u")" \
    "Optional cleanup:\n\nArchive the old home directory?\n\n$old_home\n\nIt will be moved to:\n/root/dast-home-archive/<user>-<timestamp>/" ; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local archive_dir="/root/dast-home-archive/${u}-${ts}"
    users__run mkdir -p "/root/dast-home-archive"
    users__run mv "$old_home" "$archive_dir"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "✅ Archived old home to:\n\n$archive_dir"
    else
      ui_msgbox "$(users__crumb "Users" "Migrate home" "$u")" "❌ Failed to archive old home (rc=$rc)."
    fi
  fi
}



users__action_toggle_admin() {
  users__need_root "Add/remove a user from sudo/wheel." || return 0
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  local ag
  ag="$(users__detect_admin_group || true)"
  if [[ -z "$ag" ]]; then
    ui_msgbox "$MODULE_USERS_TITLE" "❌ No admin group detected (sudo/wheel)."
    return 0
  fi

  local is_member="no"
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$ag"; then
    is_member="yes"
  fi

  if [[ "$is_member" == "yes" ]]; then
    if ! ui_yesno "$(users__crumb "Users" "Admin")" "Remove '$u' from '$ag' (admin rights)?"; then
      return 0
    fi
    if users__cmd_exists gpasswd; then
      run gpasswd -d "$u" "$ag" || return 0
    else
      # rebuild groups list minus admin group
      local new
      new="$(id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -vx "$ag" | paste -sd, -)"
      run usermod -G "${new:-}" "$u" || return 0
    fi
    ui_msgbox "$MODULE_USERS_TITLE" "✅ Removed '$u' from $ag"
  else
    if ! ui_yesno "$(users__crumb "Users" "Admin")" "Add '$u' to '$ag' (admin rights)?"; then
      return 0
    fi
    run usermod -aG "$ag" "$u" || return 0
    ui_msgbox "$MODULE_USERS_TITLE" "✅ Added '$u' to $ag"
  fi
}

users__action_delete_user() {
  users__need_root "Delete a user." || return 0
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  if users__is_self_or_root "$u"; then
    ui_msgbox "$MODULE_USERS_TITLE" "🛡️ Refusing to delete '$u'\n\n(Protects root and your current session user.)"
    return 0
  fi

  local choice
  choice="$(users__radiolist "$(users__crumb "Users" "Delete")" "Delete '$u' - what about their home directory?" \
    "keep"   "Keep home directory" "on" \
    "remove" "Remove home directory (-r)" "off" \
  )" || return 0
  choice="$(echo "$choice" | tr -d '"')"

  local -a cmd=(userdel)
  [[ "$choice" == "remove" ]] && cmd+=(-r)
  cmd+=("$u")

  if ! ui_yesno "$(users__crumb "Users" "Delete")" "Delete user '$u'?\n\nCommand:\n${cmd[*]}"; then
    return 0
  fi

  run "${cmd[@]}" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ Deleted user: $u"
}

# -----------------------------------------------------------------------------
# Actions: Groups
# -----------------------------------------------------------------------------
users__action_create_group() {
  users__need_root "Create a group." || return 0

  local g
  g="$(ui_inputbox "$(users__crumb "Groups" "Create")" "Group name:" "")" || return 0
  g="${g//\"/}"
  g="$(echo "$g" | tr -d '[:space:]')"
  [[ -n "$g" ]] || return 0

  if ! users__valid_groupname "$g"; then
    ui_msgbox "$MODULE_USERS_TITLE" "❌ Invalid group name\n\nExpected: [a-z_][a-z0-9_-]{0,31}\n\nGot: $g"
    return 0
  fi
  if users__group_exists "$g"; then
    ui_msgbox "$MODULE_USERS_TITLE" "💡 Group already exists: $g"
    return 0
  fi

  if ! ui_yesno "$(users__crumb "Groups" "Create")" "Create group '$g'?\n\nCommand:\ngroupadd $g"; then
    return 0
  fi

  run groupadd "$g" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ Group created: $g"
}

users__action_delete_group() {
  users__need_root "Delete a group." || return 0

  local g
  g="$1"
  [[ -n "$g" ]] || g="$(users__pick_group)" || return 0
  users__group_exists "$g" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ Group '$g' does not exist."; return 0; }

  if [[ "$g" == "root" ]]; then
    ui_msgbox "$MODULE_USERS_TITLE" "🛡️ Refusing to delete 'root' group."
    return 0
  fi

  # Refuse to delete a group that is the primary group of any existing user.
  local gid prim_users
  gid="$(getent group "$g" | cut -d: -f3 2>/dev/null || true)"
  if [[ -n "$gid" ]]; then
    prim_users="$(awk -F: -v gid="$gid" '$4==gid {print $1}' /etc/passwd 2>/dev/null | head -n 20 || true)"
    if [[ -n "$prim_users" ]]; then
      ui_msgbox "$MODULE_USERS_TITLE" "🛡️ Refusing to delete group '$g' because it is the primary group for one or more users.

Users (sample):
$prim_users

Change those users' primary group first (usermod -g), then retry."
      return 0
    fi
  fi


  if ! ui_yesno "$(users__crumb "Groups" "Delete")" "Delete group '$g'?\n\nCommand:\ngroupdel $g"; then
    return 0
  fi

  run groupdel "$g" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ Group deleted: $g"
}

users__action_add_member() {
  users__need_root "Add a user to a group." || return 0

  local g u
  g="$1"
  [[ -n "$g" ]] || g="$(users__pick_group)" || return 0
  users__group_exists "$g" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ Group '$g' does not exist."; return 0; }

  u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  if ! ui_yesno "$(users__crumb "Groups" "Add member")" "Add '$u' to '$g'?\n\nCommand:\nusermod -aG $g $u"; then
    return 0
  fi

  run usermod -aG "$g" "$u" || return 0
  ui_msgbox "$MODULE_USERS_TITLE" "✅ Added '$u' to '$g'"
}

users__action_remove_member() {
  users__need_root "Remove a user from a group." || return 0

  local g u
  g="$1"
  [[ -n "$g" ]] || g="$(users__pick_group)" || return 0
  users__group_exists "$g" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ Group '$g' does not exist."; return 0; }

  u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  if ! id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
    ui_msgbox "$MODULE_USERS_TITLE" "💡 '$u' is not a member of '$g'."
    return 0
  fi

  if ! ui_yesno "$(users__crumb "Groups" "Remove member")" "Remove '$u' from '$g'?"; then
    return 0
  fi

  if users__cmd_exists gpasswd; then
    run gpasswd -d "$u" "$g" || return 0
  else
    local new
    new="$(id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -vx "$g" | paste -sd, -)"
    run usermod -G "${new:-}" "$u" || return 0
  fi

  ui_msgbox "$MODULE_USERS_TITLE" "✅ Removed '$u' from '$g'"
}

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------

users__menu_manage_user() {
  local u=\"${1:-}\"
  [[ -n "$u" ]] || u="$(users__pick_user)" || return 0
  users__user_exists "$u" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ User '$u' does not exist."; return 0; }

  while true; do
    local choice
    choice="$(ui_menu "$(users__crumb "Users" "Manage" "$u")" "Selected user: $u\n\nChoose an action:" \
      "INFO"     "💡  User info" \
      "EDIT"     "✏️  Edit user (name/shell)" \
      "PASSWD"   "🔑 Set password" \
      "FORCEPW"  "⏳ Force password change (next login)" \
      "GROUPS"   "👥 Set supplementary groups" \
      "ADMIN"    "🛡️ Toggle admin rights (sudo/wheel)" \
      "LOCK"     "🔒 Lock/unlock user" \
      "HOMEFIX"  "🧹 Fix home ownership (chown -R)" \
      "MIGHOME"  "🏠 Migrate home directory" \
      "NOLOGIN"  "🚫 Disable login (set shell nologin/false)" \
      "LOGIN"    "✅ Enable login (set shell)" \
      "PRIGRP"   "👑 Set primary group" \
      "FINDOWN"  "🔎 Find files owned by user" \
      "DELETE"   "🗑️ Delete user" \
      "BACK"     "🔙️ Back" \
    )" || return 0

    case "$choice" in
      INFO)    users__show_user_info "$u" ;;
      EDIT)    users__action_edit_user "$u" ;;
      PASSWD)  users__action_set_password "$u" ;;
      FORCEPW) users__action_force_pw_change "$u" ;;
      GROUPS)  users__action_set_groups "$u" ;;
      ADMIN)   users__action_toggle_admin "$u" ;;
      LOCK)    users__action_lock_unlock "$u" ;;
      HOMEFIX) users__action_fix_home_ownership "$u" ;;
      MIGHOME) users__action_migrate_home "$u" ;;
      NOLOGIN) users__action_disable_login "$u" ;;
      LOGIN)   users__action_enable_login "$u" ;;
      PRIGRP)  users__action_set_primary_group "$u" ;;
      FINDOWN) users__action_find_owned_files "$u" ;;
      DELETE)  users__action_delete_user "$u" ;;
      BACK)    return 0 ;;
    esac
  done
}

users__menu_manage_group() {
  local g=\"${1:-}\"
  [[ -n "$g" ]] || g="$(users__pick_group)" || return 0
  users__group_exists "$g" || { ui_msgbox "$MODULE_USERS_TITLE" "❌ Group '$g' does not exist."; return 0; }

  while true; do
    local choice
    choice="$(ui_menu "$(users__crumb "Groups" "Manage" "$g")" "Selected group: $g\n\nChoose an action:" \
      "INFO"    "💡  Group info" \
      "ADD"     "➕ Add member to group" \
      "REMOVE"  "➖ Remove member from group" \
      "DELETE"  "🗑️ Delete group" \
      "BACK"    "🔙️ Back" \
    )" || return 0

    case "$choice" in
      INFO)    users__show_group_info "$g" ;;
      ADD)     users__action_add_member "$g" ;;
      REMOVE)  users__action_remove_member "$g" ;;
      DELETE)  users__action_delete_group "$g" ;;
      BACK)    return 0 ;;
    esac
  done
}

users__menu_users() {
  while true; do
    local choice
    choice="$(ui_menu "$(users__crumb "Users")" "Choose an option:" \
      "LIST"     "📋 List users" \
      "MANAGE"   "🛠️ Manage a user (pick from list)" \
      "INFO"     "💡  User info" \
      "CREATE"   "➕ Create user" \
      "PASSWD"   "🔑 Set password" \
      "FORCEPW"  "⏳ Force password change (next login)" \
      "EDIT"     "✏️  Edit user (name/shell)" \
      "GROUPS"   "👥 Set supplementary groups" \
      "ADMIN"    "🛡️ Toggle admin rights (sudo/wheel)" \
      "LOCK"     "🔒 Lock/unlock user" \
      "DELETE"   "🗑️ Delete user" \
      "HOMEFIX"  "🧹 Fix home ownership (pick user)" \
      "MIGHOME"  "🏠 Migrate home directory (pick user)" \
      "FINDOWN"  "🔎 Find owned files (pick user)" \
      "BACK"     "🔙️ Back" \
    )" || return 0

    case "$choice" in
      LIST)
        local tmp
        tmp="$(mktemp_safe)" || continue
        users__list_users_table >"$tmp"
        ui_textbox "$(users__crumb "Users" "List")" "$tmp"
        ;;
      INFO)
        local u; u="$(users__pick_user)" || continue
        users__show_user_info "$u"
        ;;
      MANAGE)
        local u; u="$(users__pick_user)" || continue
        users__menu_manage_user "$u"
        ;;
      CREATE) users__action_create_user ;;
      PASSWD)
        local u; u="$(users__pick_user)" || continue
        users__action_set_password "$u"
        ;;
      FORCEPW)
        local u; u="$(users__pick_user)" || continue
        users__action_force_pw_change "$u"
        ;;
      EDIT)
        local u; u="$(users__pick_user)" || continue
        users__action_edit_user "$u"
        ;;
      GROUPS)
        local u; u="$(users__pick_user)" || continue
        users__action_set_groups "$u"
        ;;
      ADMIN)
        local u; u="$(users__pick_user)" || continue
        users__action_toggle_admin "$u"
        ;;
      LOCK)
        local u; u="$(users__pick_user)" || continue
        users__action_lock_unlock "$u"
        ;;
      HOMEFIX)
        local u; u="$(users__pick_user)" || continue
        users__action_fix_home_ownership "$u"
        ;;
      MIGHOME)
        local u; u="$(users__pick_user)" || continue
        users__action_migrate_home "$u"
        ;;
      FINDOWN)
        local u; u="$(users__pick_user)" || continue
        users__action_find_owned_files "$u"
        ;;
      DELETE)
        local u; u="$(users__pick_user)" || continue
        users__action_delete_user "$u"
        ;;
      BACK) return 0 ;;
    esac
  done
}

users__menu_groups() {
  while true; do
    local choice
    choice="$(ui_menu "$(users__crumb "Groups")" "Choose an option:" \
      "LIST"    "📋 List groups" \
      "MANAGE"  "🛠️ Manage a group (pick from list)" \
      "INFO"    "💡  Group info" \
      "CREATE"  "➕ Create group" \
      "ADD"     "➕ Add member to group" \
      "REMOVE"  "➖ Remove member from group" \
      "DELETE"  "🗑️ Delete group" \
      "BACK"    "🔙️ Back" \
    )" || return 0

    case "$choice" in
      LIST)
        local tmp
        tmp="$(mktemp_safe)" || continue
        users__list_groups_table >"$tmp"
        ui_textbox "$(users__crumb "Groups" "List")" "$tmp"
        ;;
      INFO)
        local g; g="$(users__pick_group)" || continue
        users__show_group_info "$g"
        ;;
      MANAGE)
        local g; g="$(users__pick_group)" || continue
        users__menu_manage_group "$g"
        ;;
      CREATE) users__action_create_group ;;
      ADD)
        local g; g="$(users__pick_group)" || continue
        users__action_add_member "$g"
        ;;
      REMOVE)
        local g; g="$(users__pick_group)" || continue
        users__action_remove_member "$g"
        ;;
      DELETE)
        local g; g="$(users__pick_group)" || continue
        users__action_delete_group "$g"
        ;;
      BACK) return 0 ;;
    esac
  done
}

users__menu_audit() {
  while true; do
    local choice
    choice="$(ui_menu "$(users__crumb "Audit")" "Choose an option:" \
      "WHOAMI"  "👤 Current session user + groups" \
      "SUDOERS" "🛡️ Admin groups (sudo/wheel) members" \
      "LAST"    "🕒 Recent logins (last)" \
      "BACK"    "🔙️ Back" \
    )" || return 0

    case "$choice" in
      WHOAMI)
        local tmp
        tmp="$(mktemp_safe)" || continue
        {
          local inv
          inv="$(users__current_user)"

          echo "Invoking identity"
          echo "----------------------------------------"
          echo
          echo "user: $inv"
          echo
          echo "id:"
          id "$inv" 2>/dev/null || true
          echo
          echo "groups:"
          id -nG "$inv" 2>/dev/null || true

          echo
          echo "Currently running as:"
          echo "  $(id -un 2>/dev/null || true) (euid=$(id -u 2>/dev/null || true))"
        } >"$tmp"
        ui_textbox "$(users__crumb "Audit" "Whoami")" "$tmp"
        ;;
      SUDOERS)
        local tmp ag
        tmp="$(mktemp_safe)" || continue
        ag="$(users__detect_admin_group || true)"
        {
          echo "Admin groups"
          echo "----------------------------------------"
          echo
          echo "Detected admin group: ${ag:-"(none)"}"
          echo
          if [[ -n "$ag" ]]; then
            echo "Members:"
            getent group "$ag" 2>/dev/null | awk -F: '{print ($4=="" ? "  (none)" : "  " $4)}'
          fi
          echo
          echo "sudo:"
          getent group sudo 2>/dev/null || true
          echo
          echo "wheel:"
          getent group wheel 2>/dev/null || true
        } >"$tmp"
        ui_textbox "$(users__crumb "Audit" "Admin groups")" "$tmp"
        ;;
      LAST)
        local tmp
        tmp="$(mktemp_safe)" || continue
        {
          echo "Recent logins (last)"
          echo "----------------------------------------"
          echo
          last -a 2>/dev/null || true
        } >"$tmp"
        ui_textbox "$(users__crumb "Audit" "Last")" "$tmp"
        ;;
      BACK) return 0 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Module entry point (standard naming pattern)
# -----------------------------------------------------------------------------
module_USERS() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  while true; do
    local choice
    choice="$(ui_menu "$MODULE_USERS_TITLE" "Choose an option:" \
      "USERS"  "👤 Users" \
      "GROUPS" "👥 Groups" \
      "AUDIT"  "📜 Audit and info" \
      "BACK"   "🔙️ Back" \
    )" || return 0

    case "$choice" in
      USERS)  users__menu_users ;;
      GROUPS) users__menu_groups ;;
      AUDIT)  users__menu_audit ;;

      BACK) return 0 ;;
    esac
  done
}

# Register with DaST (STANDARD: id, title, entry fn)
register_module "$module_id" "$module_title" "module_USERS"