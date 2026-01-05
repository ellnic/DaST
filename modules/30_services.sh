#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Services (v0.9.8.4)
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

module_id="SERVICES"
module_title="📡 Services (systemd)"
SERVICES_TITLE="📡 Services (systemd)"


# -----------------------------------------------------------------------------
# Logging / Debug
#
# - Standard logs should always work and live under [app]/logs
# - Debug logs should only exist when --debug is used
# -----------------------------------------------------------------------------

# mapfile -d '' quirk: when the producer emits *no* bytes at all, Bash may
# still return an array with a single empty element (""). Treat that as empty.
_services_items_normalize_empty() {
  # usage: _services_items_normalize_empty items_array_name
  local __name="$1"
  # Indirect reference without nameref for maximum compatibility
  eval "local __len=\${#${__name}[@]}"
  if [[ "${__len:-0}" -eq 1 ]]; then
    eval "local __first=\${$__name[0]}"
    if [[ -z "${__first:-}" ]]; then
      eval "$__name=()"
    fi
  fi
}
# -----------------------------------------------------------------------------
# Hard gate: do not register unless systemd is actually present/usable
# -----------------------------------------------------------------------------

dast_has_systemd() {
  # Strong detection:
  #  - systemd runtime dir OR PID 1 is systemd
  #  - systemctl exists
  #  - systemctl can answer "is-system-running" (any output is fine, including degraded)
  #
  # This prevents showing the module on Devuan/sysvinit/OpenRC and similar.
  local ok="no"

  if [[ -d /run/systemd/system ]]; then
    ok="yes"
  elif [[ -r /proc/1/comm ]]; then
    if [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]; then
      ok="yes"
    fi
  fi

  if [[ "$ok" != "yes" ]]; then
    local p1=""
    p1="$(cat /proc/1/comm 2>/dev/null || true)"
    return 1
  fi

  command -v systemctl >/dev/null 2>&1 || { dast_log INFO SERVICES "gate: FAIL (no systemctl)"; return 1; }

  # If systemctl exists but systemd is not the running init, this usually errors out.
  local st
  st="$(systemctl is-system-running 2>/dev/null || true)"
  [[ -n "$st" ]] || { dast_log INFO SERVICES "gate: FAIL (is-system-running empty)"; return 1; }

  return 0
}

# -----------------------------------------------------------------------------
# UI helpers (module-local hardening + 3-col list fallback)
# -----------------------------------------------------------------------------

_have_dialog() {
  command -v dialog >/dev/null 2>&1
}

_have_dial() {
  declare -F dial >/dev/null 2>&1
}

ui_yesno_default_no() {
  # Force a "No" default even if core helper defaults differ.
  local title="$1" msg="$2"

  if _have_dial; then
    dial --title "$title" --defaultno --yesno "$msg" 10 80
    return $?
  fi

  if _have_dialog; then
    dast_ui_dialog --title "$title" --defaultno --yesno "$msg" 10 80
    return $?
  fi

  # Fall back to core ui_yesno if available; if not, be conservative and return "No".
  if declare -F ui_yesno >/dev/null 2>&1; then
    ui_yesno "$title" "$msg"
    return $?
  fi

  return 1
}

ui_msg_force() {
  # Show a blocking message box even if core ui_msg is missing or non-blocking.
  local title="$1" msg="$2"

  if _have_dial; then
    dial --title "$title" --msgbox "$msg" 10 80
    return 0
  fi

  if _have_dialog; then
    dast_ui_dialog --title "$title" --msgbox "$msg" 10 80
    return 0
  fi

  if declare -F ui_msg >/dev/null 2>&1; then
    ui_msg "$title" "$msg"
    return 0
  fi

  printf "%s\n\n%s\n" "$title" "$msg" >&2
  read -r -p "Press Enter to continue..." _ </dev/tty 2>/dev/null || true
  return 0
}


ui_okcancel_default_cancel() {
  # Continue/Cancel prompt that defaults to Cancel.
  # Implemented via yesno with custom YES/NO labels (dialog/dial) and defaultno.
  local title="$1" msg="$2"

  if _have_dial; then
    # NOTE: yesno uses --yes-label/--no-label (not ok/cancel labels).
    # Put --defaultno *before* the box type so it's honoured.
    dial --title "$title" --defaultno \
      --yes-label "Continue" --no-label "Cancel" \
      --yesno "$msg" 10 80
    return $?
  fi

  if _have_dialog; then
    dast_ui_dialog --title "$title" --defaultno \
      --yes-label "Continue" --no-label "Cancel" \
      --yesno "$msg" 10 80
    return $?
  fi

  # Fallback: map to a standard yes/no.
  ui_yesno_default_no "$title" "$msg"
}

ui_menu_3col_default_no() {
  # A 3-column menu using dialog/dial if present.
  # If not, fall back to 2-column ui_menu by collapsing columns.
  #
  # Args: title, prompt, items... where items are triples:
  #   TAG  COL2  COL3
  local title="$1" prompt="$2"; shift 2
  local -a triples=("$@")
  local -a args=()
  local -a collapsed=()
  local i tag c2 c3

  # Build collapsed for ui_menu fallback
  for ((i=0; i<${#triples[@]}; i+=3)); do
    tag="${triples[i]}"
    c2="${triples[i+1]}"
    c3="${triples[i+2]}"
    collapsed+=( "$tag" "$c2  $c3" )
  done

  # We do NOT use the dialog "help" column. It's not needed, and older dialog
  # builds misbehave with --item-help. Always collapse triples into pairs.
  if _have_dial; then
    # NOTE: core 'dial' wrappers typically already emit the selection on stdout.
    # Do not do fd-swapping here or you'll capture nothing.
    dial --title "$title" --menu "$prompt" 22 118 15 "${collapsed[@]}"
    return $?
  fi

  if _have_dialog; then
    dast_ui_dialog --title "$title" --menu "$prompt" 22 118 15 "${collapsed[@]}" 3>&1 1>&2 2>&3
    return $?
  fi

  # Core fallback (2-col)
  ui_menu "$title" "$prompt" "${collapsed[@]}"
}

ui_view_file() {
  local title="$1" file="$2"
  if _have_dial; then
    dial --title "$title" --textbox "$file" 24 110
    return 0
  fi
  if _have_dialog; then
    dast_ui_dialog --title "$title" --textbox "$file" 24 110
    return 0
  fi
  # Fallback: dump into ui_msg (may truncate depending on core)
  if declare -F ui_msg >/dev/null 2>&1; then
    ui_msg "$title" "$(sed -n '1,240p' "$file")"
  else
    cat "$file"
  fi
}

ui_tail_file() {
  local title="$1" file="$2"
  if _have_dial; then
    dial --title "$title" --tailbox "$file" 24 110
    return 0
  fi
  if _have_dialog; then
    dast_ui_dialog --title "$title" --tailbox "$file" 24 110
    return 0
  fi
  # Fallback: show last chunk once
  if declare -F ui_msg >/dev/null 2>&1; then
    ui_msg "$title" "$(tail -n 120 "$file" 2>/dev/null || true)"
  else
    tail -n 120 "$file" 2>/dev/null || true
  fi
}

sanitize_unit_for_filename() {
  echo "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

is_critical_service_name() {
  # Names without ".service" suffix
  local name="$1"
  case "$name" in
    ssh|sshd|dropbear|networking|NetworkManager|systemd-networkd|systemd-resolved|wpa_supplicant|dbus|systemd-logind)
      return 0
      ;;
  esac
  return 1
}

ssh_risk_warning_maybe() {
  local unit="$1" op="$2"
  local warn=""
  local base="${unit%.service}"

  if is_critical_service_name "$base"; then
    warn="$warn\n\n🚨 This service is commonly critical. Stopping/restarting it can break networking or lock you out."
  fi

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn="$warn\n\n🚨 You appear to be in an SSH session. A bad stop/restart can kick you out."
  fi

  if [[ -n "$warn" ]]; then
    ui_msg "Heads up" "About to $op: $unit$warn\n\nIf you are not sure, hit Cancel in the next prompt."
  fi
}

require_typed_confirm() {
  # Strong confirm for high-risk actions.
  # Returns 0 if user typed the unit name exactly, else 1.
  local title="$1" unit="$2" action="$3"
  local typed
  typed="$(ui_input "$title" "Type the unit name to confirm:\n\n$action: $unit\n\n(Example: $unit)\n" 2>/dev/null)" || return 1
  [[ "$typed" == "$unit" ]]
}

# -----------------------------------------------------------------------------
# Systemctl wrappers + formatting
# -----------------------------------------------------------------------------

sysctl() {
  # shellcheck disable=SC2068
  systemctl $@ 2>&1
}

journal() {
  # shellcheck disable=SC2068
  journalctl $@ 2>&1
}

systemd_state() {
  local st
  st="$(systemctl is-system-running 2>/dev/null || true)"
  [[ -z "$st" ]] && st="unknown"
  echo "$st"
}

enabledish_of() {
  # enabled-ish: enabled, enabled-runtime, static, indirect, generated
  local enabled="$1"
  case "$enabled" in
    enabled|enabled-runtime|static|indirect|generated) echo "yes" ;;
    *) echo "no" ;;
  esac
}

traffic_light_emoji() {
  # Maps (active_state, enabled_state) to a single-codepoint indicator.
  local active="$1" enabled="$2"
  local enabledish
  enabledish="$(enabledish_of "$enabled")"

  case "$active" in
    active)
      if [[ "$enabledish" == "yes" ]]; then echo "🟢"; else echo "🟡"; fi
      ;;
    failed)
      echo "🔴"
      ;;
    activating|deactivating)
      # transitional states: show amber-ish
      echo "🟠"
      ;;
    inactive|unknown|*)
      if [[ "$enabledish" == "yes" ]]; then echo "🟠"; else echo "⚪"; fi
      ;;
  esac
}

status_short() {
  # Clean wording: "active", "inactive", "failed", etc plus enabled status.
  local active="$1" enabled="$2"
  [[ -z "$active" ]] && active="unknown"
  [[ -z "$enabled" ]] && enabled="unknown"
  printf "%s | %s" "$active" "$enabled"
}

# -----------------------------------------------------------------------------
# Data model: build once, reuse everywhere (fast)
# -----------------------------------------------------------------------------

declare -A SVC_ACTIVE=()
declare -A SVC_SUB=()
declare -A SVC_LOAD=()
declare -A SVC_DESC=()
declare -A SVC_ENABLED=()
declare -A SVC_PRESENT=()

_ensure_services_assoc_arrays() {
  # Force caches to associative arrays (prevents "invalid arithmetic operator" for unit names like foo.service)
  declare -gA SVC_ACTIVE SVC_SUB SVC_LOAD SVC_DESC SVC_ENABLED SVC_PRESENT
}

_refresh_services_cache() {
  _ensure_services_assoc_arrays
  # Combine:
  #  - list-units --all --type=service (runtime state + description)
  #  - list-unit-files --type=service (enable state)
  #
  # Also include unit-files that are not currently loaded, so the manage list is complete.

  SVC_ACTIVE=()
  SVC_SUB=()
  SVC_LOAD=()
  SVC_DESC=()
  SVC_ENABLED=()
  SVC_PRESENT=()

  local line unit load active sub desc rest
  local enabled state

  # Runtime units
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Format:
    # UNIT LOAD ACTIVE SUB DESCRIPTION...
    unit="$(awk '{print $1}' <<<"$line")"
    load="$(awk '{print $2}' <<<"$line")"
    active="$(awk '{print $3}' <<<"$line")"
    sub="$(awk '{print $4}' <<<"$line")"
    desc="$(cut -d' ' -f5- <<<"$line")"

    SVC_LOAD["$unit"]="$load"
    SVC_ACTIVE["$unit"]="$active"
    SVC_SUB["$unit"]="$sub"
    SVC_DESC["$unit"]="$desc"
    SVC_PRESENT["$unit"]="yes"
  done < <(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null || true)

  # Unit files (enable state)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    unit="$(awk '{print $1}' <<<"$line")"
    state="$(awk '{print $2}' <<<"$line")"

    SVC_ENABLED["$unit"]="$state"
    SVC_PRESENT["$unit"]="yes"

    # If it is not loaded, set defaults
    if [[ -z "${SVC_ACTIVE[$unit]:-}" ]]; then
      SVC_LOAD["$unit"]="not-loaded"
      SVC_ACTIVE["$unit"]="inactive"
      SVC_SUB["$unit"]="dead"
      SVC_DESC["$unit"]="(unit file present)"
    fi
  done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true)

  # Ensure enabled field exists for all
  for unit in "${!SVC_PRESENT[@]}"; do
    if [[ -z "${SVC_ENABLED[$unit]:-}" ]]; then
      SVC_ENABLED["$unit"]="unknown"
    fi
    if [[ -z "${SVC_DESC[$unit]:-}" ]]; then
      SVC_DESC["$unit"]="(no description)"
    fi
  done
}

_sorted_units() {
  # Outputs units sorted. Uses LC_ALL=C for stable sort.
  printf "%s\n" "${!SVC_PRESENT[@]}" | LC_ALL=C sort
}

_build_menu_triples_all() {
  local unit active enabled light st desc
  local -a items=()

  while IFS= read -r unit; do
    active="${SVC_ACTIVE[$unit]:-unknown}"
    enabled="${SVC_ENABLED[$unit]:-unknown}"
    desc="${SVC_DESC[$unit]:-(no description)}"
    light="$(services_menu_indicator "$active" "$enabled")"
    st="$(status_short "$active" "$enabled")"    items+=( "$unit" "$(printf '%-6s %s' "$light" "$st")" "$desc" )
  done < <(_sorted_units)

  printf "%s\0" "${items[@]}"
}

_build_menu_triples_failed() {
  local unit active enabled light st desc
  local -a items=()

  while IFS= read -r unit; do
    active="${SVC_ACTIVE[$unit]:-unknown}"
    # Some systemd builds may represent failure via SUB rather than ACTIVE.
    [[ "$active" == "failed" || "${SVC_SUB[$unit]:-}" == "failed" ]] || continue
    enabled="${SVC_ENABLED[$unit]:-unknown}"
    desc="${SVC_DESC[$unit]:-(no description)}"
    light="$(services_menu_indicator "$active" "$enabled")"
    st="$(status_short "$active" "$enabled")"    items+=( "$unit" "$(printf '%-6s %s' "$light" "$st")" "$desc" )
  done < <(_sorted_units)

  printf "%s\0" "${items[@]}"
}

_build_menu_triples_search() {
  local q="$1"
  local unit active enabled light st desc
  local -a items=()

  while IFS= read -r unit; do
    if [[ "$unit" != *"$q"* ]] && [[ "${SVC_DESC[$unit]:-}" != *"$q"* ]]; then
      continue
    fi
    active="${SVC_ACTIVE[$unit]:-unknown}"
    enabled="${SVC_ENABLED[$unit]:-unknown}"
    desc="${SVC_DESC[$unit]:-(no description)}"
    light="$(services_menu_indicator "$active" "$enabled")"
    st="$(status_short "$active" "$enabled")"    items+=( "$unit" "$(printf '%-6s %s' "$light" "$st")" "$desc" )
  done < <(_sorted_units)

  printf "%s\0" "${items[@]}"
}

# -----------------------------------------------------------------------------
# Backup and edit safety
# -----------------------------------------------------------------------------

_services_backup_root() {
  # Choose a sensible backup root that usually works on a real system.
  # Prefer /var/backups if writable, else /var/tmp, else /tmp.
  local base=""
  if [[ -d /var/backups && -w /var/backups ]]; then
    base="/var/backups"
  elif [[ -d /var/tmp && -w /var/tmp ]]; then
    base="/var/tmp"
  else
    base="/tmp"
  fi
  echo "$base/dast/services"
}

_make_backup_dir() {
  local unit="$1"
  local root ts safe out
  root="$(_services_backup_root)"
  ts="$(date '+%Y%m%d_%H%M%S')"
  safe="$(sanitize_unit_for_filename "$unit")"
  out="$root/$ts/$safe"
  mkdir -p "$out" 2>/dev/null || true
  echo "$out"
}

_backup_unit_snapshot() {
  local unit="$1"
  local dir="$2"
  local f

  mkdir -p "$dir" 2>/dev/null || true

  f="$dir/00_meta.txt"
  {
    echo "Unit: $unit"
    echo "When: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Host: $(hostname 2>/dev/null || true)"
    echo "State: active=$(systemctl is-active "$unit" 2>/dev/null || true) enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  } > "$f" 2>/dev/null || true

  sysctl status "$unit" --no-pager > "$dir/10_status.txt" 2>/dev/null || true
  sysctl show "$unit" > "$dir/20_show.txt" 2>/dev/null || true
  sysctl cat "$unit" > "$dir/30_cat.txt" 2>/dev/null || true

  # Drop-in directory (common)
  if [[ -d "/etc/systemd/system/$unit.d" ]]; then
    mkdir -p "$dir/40_dropins" 2>/dev/null || true
    cp -a "/etc/systemd/system/$unit.d" "$dir/40_dropins/" 2>/dev/null || true
  fi
}

_post_edit_prompt_reload() {
  ui_yesno_default_no "$SERVICES_TITLE" "Edits complete.\n\nRun: systemctl daemon-reload ?" || return 0
  sysctl daemon-reload >/dev/null 2>&1 || true
  ui_msg "$SERVICES_TITLE" "Done: daemon-reload"
}

_try_verify_unit() {
  local unit="$1"
  local tmp
  tmp="$(mktemp)"
  {
    echo "systemd-analyze verify $unit"
    echo
    systemd-analyze verify "$unit" 2>&1 || true
  } > "$tmp"
  ui_view_file "Verify: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Views: details, properties, deps, unit file, journal, boot analysis
# -----------------------------------------------------------------------------

_view_status() {
  local unit="$1" tmp
  tmp="$(mktemp)"
  sysctl status "$unit" --no-pager > "$tmp" || true
  ui_view_file "Status: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_view_unit_cat() {
  local unit="$1" tmp
  tmp="$(mktemp)"
  {
    echo "systemctl cat $unit"
    echo
    sysctl cat "$unit" || true
  } > "$tmp"
  ui_view_file "Unit file: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_view_properties_curated() {
  local unit="$1" tmp
  tmp="$(mktemp)"
  {
    echo "Properties: $unit"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    for p in Id Description LoadState ActiveState SubState FragmentPath UnitFileState UnitFilePreset MainPID ExecMainPID ExecMainStatus ExecMainCode Result NRestarts Restart KillMode TimeoutStartUSec TimeoutStopUSec; do
      printf "%-18s %s\n" "$p:" "$(systemctl show "$unit" -p "$p" --value 2>/dev/null || true)"
    done
    echo
    echo "Tip: Use 'Show ALL properties' for the full dump."
  } > "$tmp"
  ui_view_file "Properties: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_view_properties_all() {
  local unit="$1" tmp
  tmp="$(mktemp)"
  sysctl show "$unit" > "$tmp" || true
  ui_view_file "ALL properties: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_view_dependencies() {
  local unit="$1" tmp
  tmp="$(mktemp)"
  {
    echo "Dependencies: $unit"
    echo
    sysctl list-dependencies "$unit" --no-pager || true
  } > "$tmp"
  ui_view_file "Deps: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_view_reverse_dependencies() {
  local unit="$1" tmp
  tmp="$(mktemp)"
  {
    echo "Reverse dependencies: $unit"
    echo
    sysctl list-dependencies --reverse "$unit" --no-pager || true
  } > "$tmp"
  ui_view_file "Rev deps: $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_journal_menu_for_unit() {
  local unit="$1" op tmp
  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "📜 Journal for: $unit" \
      "BOOT"   "📌 Since boot" \
      "1H"     "🕒 Last 1 hour" \
      "200"    "📄 Last 200 lines" \
      "ERR"    "🔴 Errors only" \
      "FOLLOW" "👀 Follow (live)" \
      "BACK"   "🔙 Back")" || return 0

    tmp="$(mktemp)"
    case "$op" in
      BOOT)
        journal -u "$unit" -b --no-pager > "$tmp" || true
        ui_view_file "Journal (boot): $unit" "$tmp"
        ;;
      1H)
        journal -u "$unit" --since "1 hour ago" --no-pager > "$tmp" || true
        ui_view_file "Journal (1h): $unit" "$tmp"
        ;;
      200)
        journal -u "$unit" -n 200 --no-pager > "$tmp" || true
        ui_view_file "Journal (200): $unit" "$tmp"
        ;;
      ERR)
        journal -u "$unit" -p err..alert --no-pager > "$tmp" || true
        ui_view_file "Journal (errors): $unit" "$tmp"
        ;;
      FOLLOW)
        : > "$tmp"
        # Pre-fill with last lines so tailbox has content immediately
        journal -u "$unit" -n 50 --no-pager >> "$tmp" 2>/dev/null || true
        ( journal -u "$unit" -f --no-pager >> "$tmp" 2>/dev/null ) &
        local pid=$!
        ui_tail_file "Follow journal: $unit (close to stop)" "$tmp"
        kill "$pid" 2>/dev/null || true
        ;;
      BACK) rm -f "$tmp" 2>/dev/null || true; return 0 ;;
    esac
    rm -f "$tmp" 2>/dev/null || true
  done
}

_journal_system_menu() {
  local op tmp
  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "📜 System journal shortcuts" \
      "BOOT"   "📌 Since boot" \
      "1H"     "🕒 Last 1 hour" \
      "WARN"   "🚨 Warnings and above" \
      "ERR"    "🔴 Errors only" \
      "BACK"   "🔙️ Back")" || return 0

    tmp="$(mktemp)"
    case "$op" in
      BOOT)
        journal -b --no-pager > "$tmp" || true
        ui_view_file "Journal (boot)" "$tmp"
        ;;
      1H)
        journal --since "1 hour ago" --no-pager > "$tmp" || true
        ui_view_file "Journal (1h)" "$tmp"
        ;;
      WARN)
        journal -p warning..alert --no-pager > "$tmp" || true
        ui_view_file "Journal (warn+)" "$tmp"
        ;;
      ERR)
        journal -p err..alert --no-pager > "$tmp" || true
        ui_view_file "Journal (errors)" "$tmp"
        ;;
      BACK) rm -f "$tmp" 2>/dev/null || true; return 0 ;;
    esac
    rm -f "$tmp" 2>/dev/null || true
  done
}

_boot_analyze_menu() {
  local op tmp
  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "🕒 Boot analysis (systemd-analyze)" \
      "TIME"     "🕒 Time" \
      "BLAME"    "📋 Blame (slow units)" \
      "CHAIN"    "🔗 critical-chain" \
      "BACK"     "🔙 Back")" || return 0

    tmp="$(mktemp)"
    case "$op" in
      TIME)
        {
          echo "systemd-analyze time"
          echo
          systemd-analyze time 2>&1 || true
        } > "$tmp"
        ui_view_file "Analyze time" "$tmp"
        ;;
      BLAME)
        {
          echo "systemd-analyze blame"
          echo
          systemd-analyze blame 2>&1 || true
        } > "$tmp"
        ui_view_file "Analyze blame" "$tmp"
        ;;
      CHAIN)
        {
          echo "systemd-analyze critical-chain"
          echo
          systemd-analyze critical-chain 2>&1 || true
        } > "$tmp"
        ui_view_file "Analyze chain" "$tmp"
        ;;
      BACK) rm -f "$tmp" 2>/dev/null || true; return 0 ;;
    esac
    rm -f "$tmp" 2>/dev/null || true
  done
}

# -----------------------------------------------------------------------------
# Actions: start/stop/restart/enable/disable/mask/unmask/edit/revert/export
# -----------------------------------------------------------------------------

_do_simple_action() {
  local unit="$1" action="$2"
  local title="$SERVICES_TITLE"

  ssh_risk_warning_maybe "$unit" "$action"

  ui_yesno_default_no "$title" "Confirm:\n\n$action $unit ?" || return 1

  local out tmp
  tmp="$(mktemp)"
  out="$(sysctl "$action" "$unit" || true)"
  printf "%s\n" "$out" > "$tmp"
  ui_view_file "Result: $action $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true

  return 0
}

_do_kill_action() {
  local unit="$1"
  ssh_risk_warning_maybe "$unit" "kill"

  ui_msg "$SERVICES_TITLE" "🚨 Advanced action\n\nThis will send signals to the service process.\nIf you are not sure, do not proceed."
  require_typed_confirm "$SERVICES_TITLE" "$unit" "KILL" || return 1

  local sig
  sig="$(ui_input "$SERVICES_TITLE" "Signal to send (default: SIGKILL). Examples: SIGTERM, SIGKILL, SIGINT\n\nLeave blank for SIGKILL.\n" 2>/dev/null)" || return 1
  [[ -z "$sig" ]] && sig="SIGKILL"

  local tmp out
  tmp="$(mktemp)"
  out="$(sysctl kill -s "$sig" "$unit" || true)"
  printf "%s\n" "$out" > "$tmp"
  ui_view_file "Result: kill -s $sig $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_do_mask_action() {
  local unit="$1"
  ui_msg "$SERVICES_TITLE" "⛔ Masking a service blocks it from being started.\n\nThis is a high-risk action."
  require_typed_confirm "$SERVICES_TITLE" "$unit" "MASK" || return 1
  _do_simple_action "$unit" "mask"
}

_do_edit_dropin() {
  local unit="$1"
  local dir
  dir="$(_make_backup_dir "$unit")"
  _backup_unit_snapshot "$unit" "$dir"

  ui_msg "$SERVICES_TITLE" "📝 Editing drop-in override\n\nA backup snapshot was saved to:\n$dir\n\nThis uses 'systemctl edit $unit' (drop-in)."

  # Launch editor
  systemctl edit "$unit" 2>/dev/null || true

  # Offer verify + reload
  if command -v systemd-analyze >/dev/null 2>&1; then
    ui_yesno_default_no "$SERVICES_TITLE" "Run: systemd-analyze verify $unit ?" && _try_verify_unit "$unit"
  fi
  _post_edit_prompt_reload
}

_do_edit_full() {
  local unit="$1"
  local dir
  dir="$(_make_backup_dir "$unit")"
  _backup_unit_snapshot "$unit" "$dir"

  ui_msg "$SERVICES_TITLE" "🚨 Full unit edit (danger)\n\nA backup snapshot was saved to:\n$dir\n\nThis uses 'systemctl edit --full $unit'.\nIf you are not sure, Cancel out of the editor."

  require_typed_confirm "$SERVICES_TITLE" "$unit" "FULL EDIT" || return 1

  systemctl edit --full "$unit" 2>/dev/null || true

  if command -v systemd-analyze >/dev/null 2>&1; then
    ui_yesno_default_no "$SERVICES_TITLE" "Run: systemd-analyze verify $unit ?" && _try_verify_unit "$unit"
  fi
  _post_edit_prompt_reload
}

_do_revert() {
  local unit="$1"
  ui_msg "$SERVICES_TITLE" "🔄 Revert changes\n\nThis removes overrides and restores the vendor unit where applicable."
  require_typed_confirm "$SERVICES_TITLE" "$unit" "REVERT" || return 1

  local tmp out
  tmp="$(mktemp)"
  out="$(sysctl revert "$unit" || true)"
  printf "%s\n" "$out" > "$tmp"
  ui_view_file "Result: revert $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true

  _post_edit_prompt_reload
}

_do_export() {
  local unit="$1"
  local root dir safe
  root="$(_services_backup_root)"
  safe="$(sanitize_unit_for_filename "$unit")"
  dir="$root/EXPORTS/$(date '+%Y%m%d_%H%M%S')_$safe"
  mkdir -p "$dir" 2>/dev/null || true
  _backup_unit_snapshot "$unit" "$dir"

  ui_msg "$SERVICES_TITLE" "💾 Export complete\n\nSaved snapshot to:\n$dir"
}

_do_try_restart() {
  local unit="$1"
  ssh_risk_warning_maybe "$unit" "try-restart"
  ui_yesno_default_no "$SERVICES_TITLE" "Confirm:\n\ntry-restart $unit ?\n\n(Only restarts if running)" || return 1
  local tmp out
  tmp="$(mktemp)"
  out="$(sysctl try-restart "$unit" || true)"
  printf "%s\n" "$out" > "$tmp"
  ui_view_file "Result: try-restart $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_do_enable_now() {
  local unit="$1"
  ssh_risk_warning_maybe "$unit" "enable+start"
  ui_yesno_default_no "$SERVICES_TITLE" "Confirm:\n\nenable --now $unit ?" || return 1
  local tmp out
  tmp="$(mktemp)"
  out="$(sysctl enable --now "$unit" || true)"
  printf "%s\n" "$out" > "$tmp"
  ui_view_file "Result: enable --now $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_do_disable_now() {
  local unit="$1"
  ssh_risk_warning_maybe "$unit" "disable+stop"
  ui_yesno_default_no "$SERVICES_TITLE" "Confirm:\n\nstop + disable $unit ?" || return 1
  local tmp out
  tmp="$(mktemp)"
  {
    sysctl stop "$unit" || true
    echo
    sysctl disable "$unit" || true
  } > "$tmp"
  ui_view_file "Result: stop+disable $unit" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Per-service menu
# -----------------------------------------------------------------------------

_service_actions_menu() {
  local unit="$1"
  local active enabled light st desc header op

  active="${SVC_ACTIVE[$unit]:-unknown}"
  enabled="${SVC_ENABLED[$unit]:-unknown}"
  desc="${SVC_DESC[$unit]:-(no description)}"
  light="$(services_menu_indicator "$active" "$enabled")"
  st="$(status_short "$active" "$enabled")"
  header="$unit\n$light $st\n$desc"

  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "$header\n\nChoose:" \
      "BACKMENU"  "🔙️ Back (Services menu)" \
      "BACKRELOAD" "🔙️ Back (reload list - takes time)" \
      "STATUS"    "📄 Status (systemctl status)" \
      "PROPS"     "🔬 Properties (curated)" \
      "PROPSALL"  "📚 Properties (ALL)" \
      "CAT"       "📦 Unit file (systemctl cat)" \
      "DEPS"      "🧩 Dependencies" \
      "RDEPS"     "🔁 Reverse dependencies" \
      "START"     "▶️ Start" \
      "STOP"      "⏹️ Stop" \
      "RESTART"   "🔄 Restart" \
      "RELOAD"    "♻️ Reload" \
      "TRYR"      "🧪 Try-restart" \
      "ENABLE"    "✅ Enable" \
      "DISABLE"   "🚫 Disable" \
      "ENABLENOW" "✅ Enable now (enable + start)" \
      "DISABLENOW" "🚫 Disable now (stop + disable)" \
      "MASK"      "⛔ Mask (advanced)" \
      "UNMASK"    "🧼 Unmask" \
      "KILL"      "💥 Kill (advanced)" \
      "JOURNAL"   "📜 Journal" \
      "EDIT"      "📝 Edit drop-in override (safe)" \
      "FULL"      "📝 Edit full unit (danger)" \
      "REVERT"    "🚫 Revert changes" \
      "EXPORT"    "💾 Export snapshot" \
      "REFRESH"   "🔃 Refresh status")" || return 0

    case "$op" in
      STATUS) _view_status "$unit" ;;
      PROPS) _view_properties_curated "$unit" ;;
      PROPSALL) _view_properties_all "$unit" ;;
      CAT) _view_unit_cat "$unit" ;;
      DEPS) _view_dependencies "$unit" ;;
      RDEPS) _view_reverse_dependencies "$unit" ;;
      START) _do_simple_action "$unit" "start" ;;
      STOP) _do_simple_action "$unit" "stop" ;;
      RESTART) _do_simple_action "$unit" "restart" ;;
      RELOAD) _do_simple_action "$unit" "reload" ;;
      TRYR) _do_try_restart "$unit" ;;
      ENABLE) _do_simple_action "$unit" "enable" ;;
      DISABLE) _do_simple_action "$unit" "disable" ;;
      ENABLENOW) _do_enable_now "$unit" ;;
      DISABLENOW) _do_disable_now "$unit" ;;
      MASK) _do_mask_action "$unit" ;;
      UNMASK) _do_simple_action "$unit" "unmask" ;;
      KILL) _do_kill_action "$unit" ;;
      JOURNAL) _journal_menu_for_unit "$unit" ;;
      EDIT) _do_edit_dropin "$unit" ;;
      FULL) _do_edit_full "$unit" ;;
      REVERT) _do_revert "$unit" ;;
      EXPORT) _do_export "$unit" ;;
      REFRESH)
        _refresh_services_cache
        active="${SVC_ACTIVE[$unit]:-unknown}"
        enabled="${SVC_ENABLED[$unit]:-unknown}"
        desc="${SVC_DESC[$unit]:-(no description)}"
        light="$(services_menu_indicator "$active" "$enabled")"
        st="$(status_short "$active" "$enabled")"
        header="$unit\n$light $st\n$desc"
        ;;
      BACKMENU) return 0 ;;
      BACKRELOAD) return 2 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Top-level menus
# -----------------------------------------------------------------------------

_overview_screen() {
  _refresh_services_cache

  local st total active failed degraded tmp
  st="$(systemd_state)"

  total="$(printf "%s\n" "${!SVC_PRESENT[@]}" | wc -l | awk '{print $1}')"
  active="$(printf "%s\n" "${!SVC_PRESENT[@]}" | while read -r u; do [[ "${SVC_ACTIVE[$u]:-}" == "active" ]] && echo "$u"; done | wc -l | awk '{print $1}')"
  failed="$(printf "%s\n" "${!SVC_PRESENT[@]}" | while read -r u; do [[ "${SVC_ACTIVE[$u]:-}" == "failed" ]] && echo "$u"; done | wc -l | awk '{print $1}')"

  tmp="$(mktemp)"
  {
    echo "📊 Overview"
    echo
    echo "System state: $st"
    echo "Services total: $total"
    echo "Active: $active"
    echo "Failed: $failed"
    echo

    if [[ "$failed" -gt 0 ]]; then
      echo "🚨 Failed units:"
      printf "%s\n" "${!SVC_PRESENT[@]}" | LC_ALL=C sort | while read -r u; do
        [[ "${SVC_ACTIVE[$u]:-}" == "failed" ]] || continue
        echo "  🔴 $u  (${SVC_DESC[$u]:-})"
      done | sed -n '1,30p'
      echo
      echo "Tip: Use '🚨 Failed services' to manage these quickly."
    else
      echo "✅ No failed services detected."
    fi

    echo
    if command -v systemd-analyze >/dev/null 2>&1; then
      echo "🕒 systemd-analyze time:"
      systemd-analyze time 2>&1 | sed -n '1,4p' || true
    fi
  } > "$tmp"

  ui_view_file "$SERVICES_TITLE" "$tmp"
  rm -f "$tmp" 2>/dev/null || true
}

_manage_services_menu() {
  while true; do
    _refresh_services_cache

    local -a items=()
    local sel rc

    # Preserve NUL delimiters by reading directly from the generator.
    mapfile -d '' -t items < <(_build_menu_triples_all)
    _services_items_normalize_empty items

    local prompt
if _services_menu_force_tags; then
  prompt="Manage services\n\n$(_services_menu_legend_line)\n\nPick a service:"
else
  prompt="📋 Manage services\n\nPick a service:"
fi

sel="$(ui_menu_3col_default_no "$SERVICES_TITLE" "$prompt" "${items[@]}")" || return 0
    [[ -n "$sel" ]] || return 0

    _service_actions_menu "$sel"
    rc=$?
    [[ "$rc" -eq 2 ]] && continue
    return 0
  done
}

_failed_services_menu() {
  while true; do
    _refresh_services_cache

    local -a items=()
    local sel rc

    mapfile -d '' -t items < <(_build_menu_triples_failed)
    _services_items_normalize_empty items

    if [[ "${#items[@]}" -eq 0 ]]; then
      ui_msg_force "$SERVICES_TITLE" "✅ No failed services.

Nothing to manage here."
      return 0
    fi

    local prompt
if _services_menu_force_tags; then
  prompt="Failed services\n\n$(_services_menu_legend_line)\n\nPick one:"
else
  prompt="🚨 Failed services\n\nPick one:"
fi

sel="$(ui_menu_3col_default_no "$SERVICES_TITLE" "$prompt" "${items[@]}")" || return 0
    [[ -n "$sel" ]] || return 0

    _service_actions_menu "$sel"
    rc=$?
    [[ "$rc" -eq 2 ]] && continue
    return 0
  done
}

_search_services_menu() {
  _refresh_services_cache

  local q
  q="$(ui_input "$SERVICES_TITLE" "🔎 Search

Enter text to match unit name or description:
" 2>/dev/null)" || return 0
  [[ -n "$q" ]] || return 0

  while true; do
    _refresh_services_cache

    local -a items=()
    local sel rc

    mapfile -d '' -t items < <(_build_menu_triples_search "$q")
    _services_items_normalize_empty items

    if [[ "${#items[@]}" -eq 0 ]]; then
      ui_msg_force "$SERVICES_TITLE" "No matches for:

$q"
      return 0
    fi

    local prompt
if _services_menu_force_tags; then
  prompt="Results for: $q\n\n$(_services_menu_legend_line)\n\nPick a service:"
else
  prompt="🔎 Results for: $q\n\nPick a service:"
fi

sel="$(ui_menu_3col_default_no "$SERVICES_TITLE" "$prompt" "${items[@]}")" || return 0
    [[ -n "$sel" ]] || return 0

    _service_actions_menu "$sel"
    rc=$?
    [[ "$rc" -eq 2 ]] && continue
    return 0
  done
}

_logs_menu() {
  local op unit

  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "📜 Logs" \
      "UNIT" "📜 Logs for a service" \
      "SYS"  "📜 System journal shortcuts" \
      "BACK" "🔙️ Back")" || return 0

    case "$op" in
      UNIT)
        _refresh_services_cache
        unit="$(_pick_unit_quick "Pick a service for logs:")" || true
        [[ -n "$unit" ]] && _journal_menu_for_unit "$unit"
        ;;
      SYS)
        _journal_system_menu
        ;;
    esac
  done
}

_pick_unit_quick() {
  local prompt="$1"
  local -a items=()
  local sel
  # Preserve NUL delimiters by reading directly from the generator.
  mapfile -d '' -t items < <(_build_menu_triples_all)
  sel="$(ui_menu_3col_default_no "$SERVICES_TITLE" "$prompt" "${items[@]}")" || return 1
  echo "$sel"
}

_daemon_controls_menu() {
  local op tmp out

  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "🔧 Daemon controls (advanced)" \
      "RELOAD" "🔃 daemon-reload" \
      "REEXEC" "🔁 daemon-reexec (high risk)" \
      "STATE"  "📄 Show system state" \
      "BACK"   "🔙️ Back")" || return 0

    tmp="$(mktemp)"
    case "$op" in
      RELOAD)
        ui_yesno_default_no "$SERVICES_TITLE" "Run: systemctl daemon-reload ?" || { rm -f "$tmp" 2>/dev/null || true; continue; }
        out="$(sysctl daemon-reload || true)"
        printf "%s\n" "$out" > "$tmp"
        ui_view_file "daemon-reload" "$tmp"
        ;;
      REEXEC)
        ui_msg "$SERVICES_TITLE" "🚨 daemon-reexec restarts systemd manager.\n\nThis is high risk. Only do it if you understand the impact."
        ui_yesno_default_no "$SERVICES_TITLE" "Confirm: daemon-reexec ?" || { rm -f "$tmp" 2>/dev/null || true; continue; }
        out="$(sysctl daemon-reexec || true)"
        printf "%s\n" "$out" > "$tmp"
        ui_view_file "daemon-reexec" "$tmp"
        ;;
      STATE)
        {
          echo "is-system-running: $(systemd_state)"
          echo
          sysctl list-units --failed --no-pager || true
        } > "$tmp"
        ui_view_file "System state" "$tmp"
        ;;
      BACK) rm -f "$tmp" 2>/dev/null || true; return 0 ;;
    esac
    rm -f "$tmp" 2>/dev/null || true
  done
}

_export_menu() {
  local root
  root="$(_services_backup_root)"
  mkdir -p "$root/EXPORTS" 2>/dev/null || true

  ui_msg "$SERVICES_TITLE" "💾 Exports and backups\n\nThis module stores snapshots here:\n$root\n\n- Timestamped backups are created before edits\n- 'Export snapshot' saves a copy on demand"
}

_help_menu() {
  ui_msg "$SERVICES_TITLE" "📄 Help\n\nTraffic lights:\n\n🟢 active | enabled-ish\n🟡 active | disabled\n🟠 inactive-ish | enabled-ish (should probably be running)\n🔴 failed\n⚪ inactive-ish | disabled-ish\n\nStatus wording is simplified.\nYou will not see systemd property spam like 'active=active'.\n\nSafety:\n- Destructive actions default to NO\n- High-risk actions require typed confirmation\n- SSH sessions get warnings for risky services"
}

# -----------------------------------------------------------------------------
# Module entrypoint
# -----------------------------------------------------------------------------

module_SERVICES() {
  # If something changed under us (weird chroot/container), bail safely.
  if ! dast_has_systemd; then
    ui_msg "$SERVICES_TITLE" "This module requires systemd.\n\nNo changes made."
    return 0
  fi

  local op

  while true; do
    op="$(ui_menu "$SERVICES_TITLE" "Choose:\n\n🕒 Some lists/actions here can take a few seconds to load (Manage, Failed, Search as we have to parse systemd output). If it appears to hang, give it a moment." \
      "OVERVIEW" "📊 Overview" \
      "MANAGE"   "📋 Manage services" \
      "FAILED"   "🚨 Failed services" \
      "SEARCH"   "🔎 Search service" \
      "LOGS"     "📜 Logs (journal)" \
      "BOOT"     "🕒 Analyze boot" \
      "DAEMON"   "🔧 Daemon controls" \
      "EXPORT"   "💾 Export / Backup info" \
      "BACK"     "🔙️ Back")" || return 0

    case "$op" in
      OVERVIEW) _overview_screen ;;
      MANAGE) _manage_services_menu ;;
      FAILED) _failed_services_menu ;;
      SEARCH) _search_services_menu ;;
      LOGS) _logs_menu ;;
      BOOT) _boot_analyze_menu ;;
      DAEMON) _daemon_controls_menu ;;
      EXPORT) _export_menu ;;
      BACK) return 0 ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Loader marker (Keep this line for diagnostic scanners)
# -----------------------------------------------------------------------------

register_module "$module_id" "$module_title" "module_SERVICES"
