#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Firewall (v0.9.8.4)
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

module_id="FIREWALL"
module_title="🧱 Firewall"
FIREWALL_TITLE="🧱 Firewall"

# Logging helpers (prefer DaST core helpers if available)
_firewall__log() {
  local level="$1"; shift || true
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$level" "$@"
  fi
}

_firewall__dbg() {
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$@"
  fi
}


_firewall__source_helper_if_needed() {
  if declare -F run >/dev/null 2>&1 && declare -F run_capture >/dev/null 2>&1; then
    return 0
  fi

  local helper
  helper="$(_firewall__helper_path 2>/dev/null || true)"

  if [[ -n "$helper" && -r "$helper" ]]; then
    # shellcheck source=/dev/null
    source "$helper"
    return 0
  fi

  _firewall__log "WARN" "FIREWALL: dast_helper.sh not found; module may have limited functionality"
  _firewall__dbg "FIREWALL: helper source failed (searched module dir and ./lib)"
  return 1
}

_firewall__helper_path() {
  local this_dir helper
  this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  helper="$this_dir/../lib/dast_helper.sh"
  if [[ -r "$helper" ]]; then
    printf '%s\n' "$helper"
    return 0
  fi
  if [[ -r "./lib/dast_helper.sh" ]]; then
    printf '%s\n' "./lib/dast_helper.sh"
    return 0
  fi
  return 1
}

# Wrap a command so ui_programbox executes it via run_capture() for logging.
_firewall__pb_wrap() {
  local cmd="$1"
  local helper

  helper="$(_firewall__helper_path 2>/dev/null || true)"

  # If helper isn't available, just run the command directly.
  if [[ -z "$helper" ]]; then
    printf '%s\n' "$cmd"
    return 0
  fi

  printf 'bash -o pipefail -c %q\n' "source \"$helper\"; run_capture \"$cmd\""
}

_firewall__need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  ui_msg "$FIREWALL_TITLE" "This action requires root.\n\nRe-run DaST as root (or with sudo)."
  return 1
}

_firewall__now_tag() { date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "now"; }

_firewall__tmp_dir() {
  local d="/var/tmp/dast-firewall"
  mkdir -p "$d" 2>/dev/null || d="/tmp/dast-firewall"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s\n' "$d"
}

_firewall__detect_ssh_ports() {
  # Return a space-separated list of ports that look like SSH listeners.
  local ports=""
  if command -v ss >/dev/null 2>&1; then
    # Try to find sshd listeners
    ports="$(ss -ltnp 2>/dev/null | awk '
      /LISTEN/ && /sshd/ {
        # local address is column 4, like 0.0.0.0:22 or [::]:22
        a=$4
        sub(/^.*:/,"",a)
        if (a ~ /^[0-9]+$/) print a
      }' | sort -n | uniq | tr '\n' ' ')"
  fi
  ports="${ports%% }"
  printf '%s\n' "$ports"
}

_firewall__danger_ack() {
  # Require a strong confirmation for dangerous actions.
  local prompt="$1"
  local typed
  typed="$(ui_input "$FIREWALL_TITLE" "$prompt\n\nType YES to continue:" "")" || return 1
  [[ "$typed" == "YES" ]]
}

_firewall__with_rollback() {
  # Usage:
  #   _firewall__with_rollback "label" "backup_cmd" "apply_cmd" "restore_cmd" "seconds"
  # Commands are strings run via bash -c (pipefail enabled).
  local label="$1"
  local backup_cmd="$2"
  local apply_cmd="$3"
  local restore_cmd="$4"
  local seconds="${5:-30}"

  _firewall__need_root || return 1

  local base tag confirm_file
  base="$(_firewall__tmp_dir)"
  tag="$(_firewall__now_tag)"
  confirm_file="$base/rollback-confirm-$label-$tag.ok"

  # Backup first
  if ! bash -o pipefail -c "$backup_cmd" >/dev/null 2>&1; then
    ui_msg "$FIREWALL_TITLE" "Backup failed for: $label\n\nAborting."
    return 1
  fi

  # Apply
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "$apply_cmd")"

  # Start rollback timer
  (
    sleep "$seconds"
    if [[ ! -f "$confirm_file" ]]; then
      bash -o pipefail -c "$restore_cmd" >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 &

  # Confirm prompt
  if ui_yesno "$FIREWALL_TITLE" "Changes applied.\n\nAre you still connected and happy with the result?\n\nChoose Yes to confirm and cancel auto-rollback.\nChoose No to rollback now."; then
    : >"$confirm_file" 2>/dev/null || true
    return 0
  fi

  # Immediate rollback
  bash -o pipefail -c "$restore_cmd" >/dev/null 2>&1 || true
  : >"$confirm_file" 2>/dev/null || true
  ui_msg "$FIREWALL_TITLE" "Rollback attempted for: $label"
  return 1
}

# ----------------------------------------------------------------------------
# Firewall backend detection and selection
# ----------------------------------------------------------------------------
FW_SELECTED=""
FW_NOTE=""

_fw__have() { command -v "$1" >/dev/null 2>&1; }

_fw__svc_active() {
  local s="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$s" 2>/dev/null
    return $?
  fi
  return 1
}

_fw__svc_enabled() {
  local s="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled --quiet "$s" 2>/dev/null
    return $?
  fi
  return 1
}

_fw_detect_backends() {
  # Output: lines of "backend|state|detail"
  # backend: ufw | firewalld | nft
  local out=""

  if _fw__have firewall-cmd; then
    local st="present" det=""
    if _fw__svc_active firewalld; then
      st="active"
    elif _fw__svc_enabled firewalld; then
      st="enabled"
    fi
    det="$(firewall-cmd --state 2>/dev/null || true)"
    out+="firewalld|$st|${det:-}\n"
  fi

  if _fw__have ufw; then
    local st2="present" det2=""
    det2="$(ufw status 2>/dev/null | head -n 1 || true)"
    if [[ "$det2" =~ Status:\ active ]]; then
      st2="active"
    fi
    out+="ufw|$st2|${det2:-}\n"
  fi

  if _fw__have nft; then
    local st3="present" det3=""
    if _fw__svc_active nftables; then
      st3="active"
    elif _fw__svc_enabled nftables; then
      st3="enabled"
    fi
    # Non-empty ruleset?
    if nft list ruleset 2>/dev/null | grep -q .; then
      det3="ruleset:non-empty"
    else
      det3="ruleset:empty"
    fi
    out+="nft|$st3|$det3\n"
  fi

  printf '%b' "$out"
}

_fw_pick_default() {
  # Prefer active managed firewall: firewalld then ufw.
  # If none, but nft has non-empty ruleset, use nft.
  local lines
  lines="$(_fw_detect_backends)"

  if echo "$lines" | awk -F'|' '$1=="firewalld" && $2=="active" {found=1} END{exit found?0:1}'; then
    printf '%s\n' "firewalld"
    return 0
  fi
  if echo "$lines" | awk -F'|' '$1=="ufw" && $2=="active" {found=1} END{exit found?0:1}'; then
    printf '%s\n' "ufw"
    return 0
  fi

  if echo "$lines" | awk -F'|' '$1=="firewalld" {found=1} END{exit found?0:1}'; then
    printf '%s\n' "firewalld"
    return 0
  fi
  if echo "$lines" | awk -F'|' '$1=="ufw" {found=1} END{exit found?0:1}'; then
    printf '%s\n' "ufw"
    return 0
  fi

  # nft last
  if echo "$lines" | awk -F'|' '$1=="nft" {found=1} END{exit found?0:1}'; then
    printf '%s\n' "nft"
    return 0
  fi

  printf '%s\n' ""
}

_fw_select_menu() {
  local lines menu_args=() b st det label sel
  lines="$(_fw_detect_backends)"

  if [[ -z "$lines" ]]; then
    ui_msg "$FIREWALL_TITLE" "No supported firewall tooling detected (ufw, firewalld, nft)."
    return 1
  fi

  while IFS='|' read -r b st det; do
    [[ -z "$b" ]] && continue
    label="$b | $st"
    [[ -n "$det" ]] && label+=" | $det"
    menu_args+=("$b" "$label")
  done <<<"$lines"

  menu_args+=("BACK" "🔙 Back")

  sel="$(ui_menu "$FIREWALL_TITLE" "Select firewall backend (write operations affect only the selected backend):" "${menu_args[@]}")" || return 1
  [[ "$sel" == "BACK" ]] && return 1

  FW_SELECTED="$sel"
  return 0
}

_fw_mixed_write_warning() {
  # If UFW or firewalld is present, treat raw nft as view-only by default.
  local lines has_managed
  lines="$(_fw_detect_backends)"
  has_managed=0

  echo "$lines" | awk -F'|' '$1=="ufw" || $1=="firewalld" {found=1} END{exit found?0:1}' && has_managed=1 || true

  if [[ "$FW_SELECTED" == "nft" && $has_managed -eq 1 ]]; then
    FW_NOTE="View-only: a managed firewall (ufw/firewalld) is present. Editing nftables directly risks mixed rules."
    return 0
  fi

  FW_NOTE=""
  return 0
}

# ----------------------------------------------------------------------------
# UFW backend
# ----------------------------------------------------------------------------
_ufw__check() { _fw__have ufw; }

_ufw__status() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "ufw status verbose")"
}

_ufw__rules() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "{ echo 'UFW rules (numbered):'; ufw status numbered verbose; }")"
}

_ufw__backup_dir() {
  local base tag dir
  base="$(_firewall__tmp_dir)"
  tag="$(_firewall__now_tag)"
  dir="$base/ufw-backup-$tag"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

_ufw__backup() {
  local dir
  dir="$(_ufw__backup_dir)"
  tar -czf "$dir/etc-ufw.tgz" -C / etc/ufw 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

_ufw__restore_from_dir() {
  local dir="$1"
  [[ -f "$dir/etc-ufw.tgz" ]] || return 1
  tar -xzf "$dir/etc-ufw.tgz" -C / 2>/dev/null || return 1
  ufw reload >/dev/null 2>&1 || true
  return 0
}

_ufw__enable() {
  _firewall__need_root || return 1
  local bdir restore
  bdir="$(_ufw__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed. Aborting."; return 1; }
  restore="$(printf 'bash -o pipefail -c %q' "source /dev/null 2>/dev/null || true; tar -xzf '$bdir/etc-ufw.tgz' -C / && ufw reload")"

  _firewall__with_rollback \
    "ufw-enable" \
    "true" \
    "ufw --force enable" \
    "tar -xzf '$bdir/etc-ufw.tgz' -C / && ufw reload" \
    30
}

_ufw__disable() {
  _firewall__need_root || return 1
  local bdir
  bdir="$(_ufw__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed. Aborting."; return 1; }

  _firewall__danger_ack "🚨 Disabling the firewall may expose the host." || return 1

  _firewall__with_rollback \
    "ufw-disable" \
    "true" \
    "ufw disable" \
    "tar -xzf '$bdir/etc-ufw.tgz' -C / && ufw --force enable && ufw reload" \
    30
}

_ufw__reload() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "ufw reload")"
}

_ufw__defaults() {
  _firewall__need_root || return 1

  local incoming outgoing ports ssh_ports
  incoming="$(ui_menu "$FIREWALL_TITLE" "Default policy: Incoming" \
    "deny"   "Deny" \
    "allow"  "Allow" \
    "reject" "Reject" \
    "BACK"   "🔙 Back")" || return 0
  [[ "$incoming" == "BACK" ]] && return 0

  outgoing="$(ui_menu "$FIREWALL_TITLE" "Default policy: Outgoing" \
    "deny"   "Deny" \
    "allow"  "Allow" \
    "reject" "Reject" \
    "BACK"   "🔙 Back")" || return 0
  [[ "$outgoing" == "BACK" ]] && return 0

  ssh_ports="$(_firewall__detect_ssh_ports)"
  if [[ "$incoming" != "allow" && -n "$ssh_ports" ]]; then
    ui_msg "$FIREWALL_TITLE" "Heads up:\n\nSSH appears to be listening on: $ssh_ports\n\nChanging incoming default away from allow can lock you out unless rules exist for those ports."
  fi

  _firewall__danger_ack "🚨 Changing default policies can lock you out." || return 1

  local bdir
  bdir="$(_ufw__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed. Aborting."; return 1; }

  _firewall__with_rollback \
    "ufw-defaults" \
    "true" \
    "ufw default $incoming incoming && ufw default $outgoing outgoing && ufw reload" \
    "tar -xzf '$bdir/etc-ufw.tgz' -C / && ufw reload" \
    30
}

_ufw__reset() {
  _firewall__need_root || return 1
  _firewall__danger_ack "🚨 This will reset UFW and remove all rules." || return 1

  local bdir
  bdir="$(_ufw__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed. Aborting."; return 1; }

  _firewall__with_rollback \
    "ufw-reset" \
    "true" \
    "ufw --force reset && ufw reload" \
    "tar -xzf '$bdir/etc-ufw.tgz' -C / && ufw reload" \
    30
}

_ufw__add_rule() {
  _fw__have ufw || { ui_msg "$FIREWALL_TITLE" "ufw is not installed."; return 1; }
  _firewall__need_root || return 1

  local action direction port proto srcip comment cmd
  action="$(ui_menu "$FIREWALL_TITLE" "Add rule: choose action" \
    "allow"  "✅ Allow" \
    "deny"   "⛔ Deny" \
    "reject" "🚫 Reject" \
    "limit"  "🧯 Limit (rate-limit)" \
    "BACK"   "🔙 Back")" || return 0
  [[ "$action" == "BACK" ]] && return 0

  direction="$(ui_menu "$FIREWALL_TITLE" "Direction" \
    "in"   "Incoming" \
    "out"  "Outgoing" \
    "BACK" "🔙 Back")" || return 0
  [[ "$direction" == "BACK" ]] && return 0

  port="$(ui_input "$FIREWALL_TITLE" "Port (e.g. 22, 80, 51820):" "")" || return 0
  port="${port//[[:space:]]/}"
  [[ -z "$port" ]] && { ui_msg "$FIREWALL_TITLE" "Port cannot be empty."; return 1; }

  proto="$(ui_menu "$FIREWALL_TITLE" "Protocol" \
    "tcp"  "TCP" \
    "udp"  "UDP" \
    "both" "Both / Any" \
    "BACK" "🔙 Back")" || return 0
  [[ "$proto" == "BACK" ]] && return 0

  srcip="$(ui_input "$FIREWALL_TITLE" "Source (leave blank for 'any', or enter IP/CIDR):" "")" || return 0
  srcip="${srcip//[[:space:]]/}"

  comment="$(ui_input "$FIREWALL_TITLE" "Optional comment (leave blank for none):" "")" || return 0 || true

  cmd=(ufw "$action")
  [[ "$direction" == "out" ]] && cmd+=(out)

  if [[ -n "$srcip" && "$direction" == "in" ]]; then
    cmd+=(from "$srcip" to any port "$port")
  elif [[ -n "$srcip" && "$direction" == "out" ]]; then
    cmd+=(to "$srcip" port "$port")
  else
    cmd+=("$port")
  fi

  if [[ "$proto" != "both" ]]; then
    cmd+=(proto "$proto")
  fi
  if [[ -n "$comment" ]]; then
    cmd+=(comment "$comment")
  fi

  local cmd_str
  cmd_str="$(printf '%q ' "${cmd[@]}")"
  cmd_str="${cmd_str% }"

  if ui_yesno "$FIREWALL_TITLE" "Run this command?\n\n$cmd_str"; then
    ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "$cmd_str")"
  fi
}

_ufw__delete_rule() {
  _fw__have ufw || { ui_msg "$FIREWALL_TITLE" "ufw is not installed."; return 1; }
  _firewall__need_root || return 1

  _ufw__rules
  local num
  num="$(ui_input "$FIREWALL_TITLE" "Delete rule number:" "")" || return 0
  num="${num//[[:space:]]/}"
  [[ "$num" =~ ^[0-9]+$ ]] || { ui_msg "$FIREWALL_TITLE" "Rule number must be a whole number."; return 1; }

  if ui_yesno "$FIREWALL_TITLE" "Really delete rule #$num ?"; then
    ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "ufw --force delete $num")"
  fi
}

# ----------------------------------------------------------------------------
# firewalld backend
# ----------------------------------------------------------------------------
_fwd__check() { _fw__have firewall-cmd; }

_fwd__zone_default() {
  firewall-cmd --get-default-zone 2>/dev/null || echo "public"
}

_fwd__status() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "{ echo 'firewalld state:'; firewall-cmd --state || true; echo; echo 'default zone:'; firewall-cmd --get-default-zone || true; echo; echo 'active zones:'; firewall-cmd --get-active-zones || true; }")"
}

_fwd__rules() {
  local z
  z="$(_fwd__zone_default)"
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "{ echo 'Zone: $z (runtime)'; firewall-cmd --zone='$z' --list-all || true; echo; echo 'Zone: $z (permanent)'; firewall-cmd --permanent --zone='$z' --list-all || true; }")"
}

_fwd__backup_dir() {
  local base tag dir
  base="$(_firewall__tmp_dir)"
  tag="$(_firewall__now_tag)"
  dir="$base/firewalld-backup-$tag"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

_fwd__backup() {
  local dir
  dir="$(_fwd__backup_dir)"
  if [[ -d /etc/firewalld ]]; then
    tar -czf "$dir/etc-firewalld.tgz" -C / etc/firewalld 2>/dev/null || return 1
  else
    # Still create an empty marker backup
    : >"$dir/no-etc-firewalld.marker" 2>/dev/null || true
  fi
  printf '%s\n' "$dir"
}

_fwd__restore_from_dir() {
  local dir="$1"
  if [[ -f "$dir/etc-firewalld.tgz" ]]; then
    tar -xzf "$dir/etc-firewalld.tgz" -C / 2>/dev/null || return 1
  fi
  firewall-cmd --reload >/dev/null 2>&1 || true
  return 0
}

_fwd__enable() {
  _firewall__need_root || return 1
  local bdir
  bdir="$(_fwd__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed. Aborting."; return 1; }

  _firewall__with_rollback \
    "firewalld-enable" \
    "true" \
    "systemctl enable --now firewalld" \
    "tar -xzf '$bdir/etc-firewalld.tgz' -C / 2>/dev/null || true; systemctl disable --now firewalld || true" \
    30
}

_fwd__disable() {
  _firewall__need_root || return 1
  local bdir
  bdir="$(_fwd__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed. Aborting."; return 1; }

  _firewall__danger_ack "🚨 Disabling firewalld may expose the host." || return 1

  _firewall__with_rollback \
    "firewalld-disable" \
    "true" \
    "systemctl disable --now firewalld" \
    "tar -xzf '$bdir/etc-firewalld.tgz' -C / 2>/dev/null || true; systemctl enable --now firewalld || true" \
    30
}

_fwd__reload() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "firewall-cmd --reload")"
}

_fwd__add_rule() {
  _fwd__check || { ui_msg "$FIREWALL_TITLE" "firewall-cmd not found (firewalld not installed)."; return 1; }
  _firewall__need_root || return 1

  local z runtime_perm direction action port proto
  z="$(_fwd__zone_default)"

  runtime_perm="$(ui_menu "$FIREWALL_TITLE" "Apply to:" \
    "runtime"    "Runtime (immediate, not persistent)" \
    "permanent"  "Permanent (persistent, requires reload)" \
    "BACK"       "🔙 Back")" || return 0
  [[ "$runtime_perm" == "BACK" ]] && return 0

  direction="$(ui_menu "$FIREWALL_TITLE" "Direction (firewalld is zone/incoming oriented)" \
    "in"   "Incoming (supported)" \
    "out"  "Outgoing (not supported here)" \
    "BACK" "🔙 Back")" || return 0
  [[ "$direction" == "BACK" ]] && return 0
  if [[ "$direction" == "out" ]]; then
    ui_msg "$FIREWALL_TITLE" "Outgoing rules are not modelled as simply in firewalld zones.\n\nIf you need outbound control, use rich rules carefully or manage nftables directly on a system without a managed firewall."
    return 1
  fi

  action="$(ui_menu "$FIREWALL_TITLE" "Action (firewalld port rules are allow; deny requires rich rules)" \
    "allow"  "✅ Allow (add port)" \
    "deny"   "⛔ Deny (rich rule)" \
    "reject" "🚫 Reject (rich rule)" \
    "BACK"   "🔙 Back")" || return 0
  [[ "$action" == "BACK" ]] && return 0

  port="$(ui_input "$FIREWALL_TITLE" "Port (e.g. 22, 80, 51820):" "")" || return 0
  port="${port//[[:space:]]/}"
  [[ -z "$port" ]] && { ui_msg "$FIREWALL_TITLE" "Port cannot be empty."; return 1; }

  proto="$(ui_menu "$FIREWALL_TITLE" "Protocol" \
    "tcp"  "TCP" \
    "udp"  "UDP" \
    "BACK" "🔙 Back")" || return 0
  [[ "$proto" == "BACK" ]] && return 0

  local basecmd flags cmd_str
  flags="--zone='$z'"
  if [[ "$runtime_perm" == "permanent" ]]; then
    flags="--permanent $flags"
  fi

  if [[ "$action" == "allow" ]]; then
    basecmd="firewall-cmd $flags --add-port=${port}/${proto}"
    cmd_str="$basecmd"
  else
    # Rich rule deny/reject
    local rr_act
    rr_act="$action"
    cmd_str="firewall-cmd $flags --add-rich-rule='rule family=\"ipv4\" port port=\"${port}\" protocol=\"${proto}\" ${rr_act}'"
  fi

  if ui_yesno "$FIREWALL_TITLE" "Run this command?\n\n$cmd_str"; then
    ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "$cmd_str")"
    if [[ "$runtime_perm" == "permanent" ]]; then
      if ui_yesno "$FIREWALL_TITLE" "Reload firewalld now to apply permanent changes?"; then
        _fwd__reload
      fi
    fi
  fi
}

_fwd__delete_rule() {
  _fwd__check || { ui_msg "$FIREWALL_TITLE" "firewall-cmd not found (firewalld not installed)."; return 1; }
  _firewall__need_root || return 1

  local z runtime_perm
  z="$(_fwd__zone_default)"

  runtime_perm="$(ui_menu "$FIREWALL_TITLE" "Remove from:" \
    "runtime"    "Runtime (immediate)" \
    "permanent"  "Permanent (persistent)" \
    "BACK"       "🔙 Back")" || return 0
  [[ "$runtime_perm" == "BACK" ]] && return 0

  local list_cmd
  if [[ "$runtime_perm" == "permanent" ]]; then
    list_cmd="firewall-cmd --permanent --zone='$z' --list-ports"
  else
    list_cmd="firewall-cmd --zone='$z' --list-ports"
  fi

  local ports
  ports="$(bash -o pipefail -c "$list_cmd" 2>/dev/null || true)"
  ports="${ports//[[:space:]]/ }"

  if [[ -z "$ports" ]]; then
    ui_msg "$FIREWALL_TITLE" "No simple port rules found in zone '$z' for $runtime_perm.\n\nIf the rule is a rich rule, use the raw rich-rule remove option."
  fi

  local sel menu_args=()
  local p
  for p in $ports; do
    menu_args+=("$p" "Remove port $p from zone $z ($runtime_perm)")
  done
  menu_args+=("RICH" "🧩 Remove a rich rule (paste exact rule string)")
  menu_args+=("BACK" "🔙 Back")

  sel="$(ui_menu "$FIREWALL_TITLE" "Select rule to remove:" "${menu_args[@]}")" || return 0
  [[ "$sel" == "BACK" ]] && return 0

  if [[ "$sel" == "RICH" ]]; then
    local rr
    rr="$(ui_input "$FIREWALL_TITLE" "Paste the exact rich rule to remove (as shown by --list-rich-rules):" "")" || return 0
    rr="${rr//$'\r'/}"
    [[ -z "$rr" ]] && { ui_msg "$FIREWALL_TITLE" "No rich rule provided."; return 1; }
    if [[ "$runtime_perm" == "permanent" ]]; then
      ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "firewall-cmd --permanent --zone='$z' --remove-rich-rule='$rr'")"
    else
      ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "firewall-cmd --zone='$z' --remove-rich-rule='$rr'")"
    fi
    return 0
  fi

  if [[ "$runtime_perm" == "permanent" ]]; then
    ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "firewall-cmd --permanent --zone='$z' --remove-port='$sel'")"
    if ui_yesno "$FIREWALL_TITLE" "Reload firewalld now to apply permanent changes?"; then
      _fwd__reload
    fi
  else
    ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "firewall-cmd --zone='$z' --remove-port='$sel'")"
  fi
}

# ----------------------------------------------------------------------------
# nftables backend (view-first, with snapshot/restore + safe apply)
# ----------------------------------------------------------------------------
_nft__check() { _fw__have nft; }

_nft__view_only() {
  _fw_mixed_write_warning
  [[ -n "$FW_NOTE" ]]
}

_nft__status() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "{ echo 'nftables service:'; (systemctl is-active nftables 2>/dev/null || true); echo; echo 'ruleset:'; nft list ruleset 2>/dev/null || echo 'no ruleset / insufficient privileges'; }")"
}

_nft__rules() {
  ui_programbox "$FIREWALL_TITLE" "$(_firewall__pb_wrap "nft list ruleset")"
}

_nft__snapshot_dir() {
  local base tag dir
  base="$(_firewall__tmp_dir)"
  tag="$(_firewall__now_tag)"
  dir="$base/nft-backup-$tag"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

_nft__snapshot() {
  _firewall__need_root || return 1
  local dir
  dir="$(_nft__snapshot_dir)"
  nft list ruleset >"$dir/ruleset.nft" 2>"$dir/ruleset.err" || return 1
  printf '%s\n' "$dir"
}

_nft__restore_from_dir() {
  _firewall__need_root || return 1
  local dir="$1"
  [[ -f "$dir/ruleset.nft" ]] || return 1
  nft -f "$dir/ruleset.nft" >/dev/null 2>&1 || return 1
  return 0
}

_nft__apply_from_file() {
  _firewall__need_root || return 1
  local path="$1"
  [[ -f "$path" ]] || { ui_msg "$FIREWALL_TITLE" "File not found: $path"; return 1; }

  if _nft__view_only; then
    ui_msg "$FIREWALL_TITLE" "$FW_NOTE\n\nIf you really want nftables write-mode, disable/remove the managed firewall first, or select the managed backend."
    return 1
  fi

  # Validate first
  if ! nft -c -f "$path" >/dev/null 2>&1; then
    ui_msg "$FIREWALL_TITLE" "Validation failed: nft -c -f $path\n\nRefusing to apply."
    return 1
  fi

  local bdir
  bdir="$(_nft__snapshot)" || { ui_msg "$FIREWALL_TITLE" "Snapshot failed. Aborting."; return 1; }

  _firewall__danger_ack "🚨 Applying an nftables ruleset can lock you out." || return 1

  _firewall__with_rollback \
    "nft-apply" \
    "true" \
    "nft -f '$path'" \
    "nft -f '$bdir/ruleset.nft'" \
    30
}

# ----------------------------------------------------------------------------
# Unified UI actions (dispatch to backend)
# ----------------------------------------------------------------------------
_fw_overview() {
  local lines backend_count ssh_ports
  lines="$(_fw_detect_backends)"
  backend_count="$(echo "$lines" | awk 'NF{c++} END{print c+0}')"
  ssh_ports="$(_firewall__detect_ssh_ports)"

  local txt=""
  txt+="Selected backend: ${FW_SELECTED:-<auto>}\n"
  if [[ -n "$FW_NOTE" ]]; then
    txt+="Note: $FW_NOTE\n"
  fi
  txt+="\nDetected backends:\n"
  if [[ -z "$lines" ]]; then
    txt+="  (none detected)\n"
  else
    txt+="$(echo "$lines" | awk -F'|' 'NF{printf "  - %s (%s) %s\n",$1,$2,$3}')"
  fi
  txt+="\nSSH listeners (best effort): ${ssh_ports:-none detected}\n"
  txt+="\nSafety:\n"
  txt+="  - If both a managed firewall and nftables exist, DaST defaults nft to view-only.\n"
  txt+="  - Risky operations may auto-rollback unless confirmed.\n"

  ui_msg "$FIREWALL_TITLE" "$txt"
}

_fw_auto_select_if_needed() {
  if [[ -z "$FW_SELECTED" ]]; then
    FW_SELECTED="$(_fw_pick_default)"
  fi
  _fw_mixed_write_warning
}

_fw_status() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__status ;;
    firewalld) _fwd__status ;;
    nft) _nft__status ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_rules() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__rules ;;
    firewalld) _fwd__rules ;;
    nft) _nft__rules ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_enable() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__enable ;;
    firewalld) _fwd__enable ;;
    nft)
      ui_msg "$FIREWALL_TITLE" "Enable for nftables is distro-specific.\n\nUse systemctl enable --now nftables if your distro provides it.\nDaST keeps nft enable/disable conservative."
      ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_disable() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__disable ;;
    firewalld) _fwd__disable ;;
    nft)
      ui_msg "$FIREWALL_TITLE" "Disable for nftables is distro-specific.\n\nIf you really mean it, stop/disable nftables service manually.\nDaST keeps nft enable/disable conservative."
      ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_reload() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__reload ;;
    firewalld) _fwd__reload ;;
    nft)
      ui_msg "$FIREWALL_TITLE" "Reload for nftables depends on how rules are managed.\n\nIf you applied a ruleset file, re-apply that file.\nYou can also restart nftables service where available."
      ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_add_rule() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__add_rule ;;
    firewalld) _fwd__add_rule ;;
    nft)
      ui_msg "$FIREWALL_TITLE" "nftables add/delete is not exposed here by design.\n\nUse: Snapshot/Apply ruleset file (validated + rollback).\nThis avoids mixing rules and accidental lockouts."
      ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_delete_rule() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw) _ufw__delete_rule ;;
    firewalld) _fwd__delete_rule ;;
    nft)
      ui_msg "$FIREWALL_TITLE" "nftables delete is not exposed here by design.\n\nUse: Snapshot/Apply ruleset file (validated + rollback)."
      ;;
    *) ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected." ;;
  esac
}

_fw_defaults_or_reset_menu() {
  _fw_auto_select_if_needed
  case "$FW_SELECTED" in
    ufw)
      local sel
      sel="$(ui_menu "$FIREWALL_TITLE" "UFW policy actions:" \
        "DEFAULTS" "🧭 Set default policies" \
        "RESET"    "♻ Reset UFW (danger)" \
        "BACK"     "🔙 Back")" || return 0
      case "$sel" in
        DEFAULTS) _ufw__defaults ;;
        RESET) _ufw__reset ;;
        BACK) return 0 ;;
      esac
      ;;
    firewalld)
      ui_msg "$FIREWALL_TITLE" "firewalld default policy modelling varies (zones/targets/rich rules).\n\nDaST currently supports:\n- Add/remove port rules\n- Add/remove rich rules (paste exact string)\n\nDefaults/reset are not offered to avoid unsafe assumptions."
      ;;
    nft)
      ui_msg "$FIREWALL_TITLE" "Defaults/reset are not offered for nftables.\n\nUse snapshot + apply a known-good ruleset."
      ;;
    *)
      ui_msg "$FIREWALL_TITLE" "No firewall backend selected/detected."
      ;;
  esac
}

_fw_backup_restore_menu() {
  _fw_auto_select_if_needed

  local sel
  sel="$(ui_menu "$FIREWALL_TITLE" "Backups / Restore (selected backend: ${FW_SELECTED:-none})" \
    "BACKUP"  "💾 Create backup/snapshot now" \
    "RESTORE" "🩹 Restore from a backup/snapshot path" \
    "BACK"    "🔙 Back")" || return 0

  case "$sel" in
    BACKUP)
      case "$FW_SELECTED" in
        ufw)
          _firewall__need_root || return 1
          local d
          d="$(_ufw__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed."; return 1; }
          ui_msg "$FIREWALL_TITLE" "UFW backup created:\n\n$d\n\n(Contains: $d/etc-ufw.tgz)"
          ;;
        firewalld)
          _firewall__need_root || return 1
          local d2
          d2="$(_fwd__backup)" || { ui_msg "$FIREWALL_TITLE" "Backup failed."; return 1; }
          ui_msg "$FIREWALL_TITLE" "firewalld backup created:\n\n$d2\n\n(Contains: $d2/etc-firewalld.tgz if /etc/firewalld existed)"
          ;;
        nft)
          if _nft__view_only; then
            # Snapshot is read, but still needs root to write into dir? We still require root for consistent file write.
            ui_msg "$FIREWALL_TITLE" "$FW_NOTE"
            return 1
          fi
          _firewall__need_root || return 1
          local d3
          d3="$(_nft__snapshot)" || { ui_msg "$FIREWALL_TITLE" "Snapshot failed."; return 1; }
          ui_msg "$FIREWALL_TITLE" "nftables snapshot created:\n\n$d3\n\n(Contains: $d3/ruleset.nft)"
          ;;
        *)
          ui_msg "$FIREWALL_TITLE" "No backend selected."
          ;;
      esac
      ;;

    RESTORE)
      _firewall__need_root || return 1
      local path
      path="$(ui_input "$FIREWALL_TITLE" "Enter backup/snapshot directory path:" "")" || return 0
      path="${path//[$'\r']/}"

      case "$FW_SELECTED" in
        ufw)
          if ui_yesno "$FIREWALL_TITLE" "Restore UFW from:\n\n$path\n\nThis will overwrite /etc/ufw.\nContinue?"; then
            _ufw__restore_from_dir "$path" && ui_msg "$FIREWALL_TITLE" "Restore attempted. Check status/rules." || ui_msg "$FIREWALL_TITLE" "Restore failed."
          fi
          ;;
        firewalld)
          if ui_yesno "$FIREWALL_TITLE" "Restore firewalld from:\n\n$path\n\nThis will overwrite /etc/firewalld.\nContinue?"; then
            _fwd__restore_from_dir "$path" && ui_msg "$FIREWALL_TITLE" "Restore attempted. Check status/rules." || ui_msg "$FIREWALL_TITLE" "Restore failed."
          fi
          ;;
        nft)
          if _nft__view_only; then
            ui_msg "$FIREWALL_TITLE" "$FW_NOTE\n\nRefusing restore in mixed-backend mode."
            return 1
          fi
          if ui_yesno "$FIREWALL_TITLE" "Restore nftables ruleset from:\n\n$path\n\nThis will apply $path/ruleset.nft.\nContinue?"; then
            _nft__restore_from_dir "$path" && ui_msg "$FIREWALL_TITLE" "Restore attempted. Check ruleset." || ui_msg "$FIREWALL_TITLE" "Restore failed."
          fi
          ;;
        *)
          ui_msg "$FIREWALL_TITLE" "No backend selected."
          ;;
      esac
      ;;

    BACK) return 0 ;;
  esac
}

_fw_nft_apply_menu() {
  _fw_auto_select_if_needed
  if [[ "$FW_SELECTED" != "nft" ]]; then
    ui_msg "$FIREWALL_TITLE" "This option is for nftables only.\n\nSelect nft as the backend first."
    return 1
  fi

  local path
  path="$(ui_input "$FIREWALL_TITLE" "Enter path to nft ruleset file to apply:" "")" || return 0
  path="${path//[$'\r']/}"
  [[ -z "$path" ]] && return 0
  _nft__apply_from_file "$path"
}

# ----------------------------------------------------------------------------
# Main module menu
# ----------------------------------------------------------------------------
module_FIREWALL() {
  _firewall__source_helper_if_needed || true

  # Auto select a backend on entry (if any).
  FW_SELECTED="$(_fw_pick_default)"
  _fw_mixed_write_warning

  while true; do
    local subtitle sel
    subtitle="Selected: ${FW_SELECTED:-none}"
    [[ -n "$FW_NOTE" ]] && subtitle+=" | NOTE: ${FW_NOTE}"

    sel="$(ui_menu "$FIREWALL_TITLE" "$subtitle" \
      "OVERVIEW"   "📋 Overview (detected backends + safety notes)" \
      "SELECT"     "🧩 Select backend" \
      "STATUS"     "📊 Status" \
      "ENABLE"     "🟢 Enable" \
      "DISABLE"    "🔴 Disable" \
      "RULES"      "📏 List rules" \
      "ADD"        "➕ Add rule" \
      "DELETE"     "➖ Delete rule" \
      "POLICY"     "🧭 Defaults / Reset (where supported)" \
      "RELOAD"     "🔄 Reload / Apply" \
      "BACKUP"     "💾 Backup / Restore" \
      "NFT_APPLY"  "📄 nftables: Apply ruleset file (validated + rollback)" \
      "BACK"       "🔙 Back")" || return 0

    case "$sel" in
      OVERVIEW) _fw_overview ;;
      SELECT) _fw_select_menu && _fw_mixed_write_warning ;;
      STATUS) _fw_status ;;
      ENABLE) _fw_enable ;;
      DISABLE) _fw_disable ;;
      RULES) _fw_rules ;;
      ADD) _fw_add_rule ;;
      DELETE) _fw_delete_rule ;;
      POLICY) _fw_defaults_or_reset_menu ;;
      RELOAD) _fw_reload ;;
      BACKUP) _fw_backup_restore_menu ;;
      NFT_APPLY) _fw_nft_apply_menu ;;
      BACK) return 0 ;;
      *) ui_msg "$FIREWALL_TITLE" "Unknown selection: $sel" ;;
    esac
  done
}

# Register module (not OS-limited). Show something even if no backend is present.
register_module "$module_id" "$module_title" "module_FIREWALL"
