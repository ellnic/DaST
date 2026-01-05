#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Networking (v0.9.8.4)
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

module_id="NETWORK"
module_title="🌐 Networking"
NET_TITLE="🌐 Networking"

# -----------------------------------------------------------------------------
# Helper bootstrap (run/run_capture/mktemp_safe)
# -----------------------------------------------------------------------------

net__script_dir() {
  local src
  src="${BASH_SOURCE[0]:-$0}"
  cd -P -- "$(dirname -- "$src")" >/dev/null 2>&1 && pwd -P
}

net__try_source_helper() {
  declare -F run >/dev/null 2>&1 && declare -F run_capture >/dev/null 2>&1 && declare -F mktemp_safe >/dev/null 2>&1 && return 0

  local base=""
  if [[ -n "${SCRIPT_DIR:-}" && -d "${SCRIPT_DIR:-}" ]]; then
    base="$SCRIPT_DIR"
  else
    base="$(cd -P -- "$(net__script_dir)/.." >/dev/null 2>&1 && pwd -P)"
  fi

  local cand
  for cand in \
    "$base/lib/dast_helper.sh" \
    "$(net__script_dir)/../lib/dast_helper.sh" \
    "$(net__script_dir)/dast_helper.sh"
  do
    if [[ -f "$cand" ]]; then
      # shellcheck disable=SC1090
      source "$cand" || true
      break
    fi
  done
}

# -----------------------------------------------------------------------------
# Logging helpers (prefer DaST core helpers if available)
# -----------------------------------------------------------------------------
net__log() {
  declare -F dast_log >/dev/null 2>&1 || return 0
  # Usage: net__log LEVEL message...
  dast_log "$@"
}

net__dbg() {
  declare -F dast_dbg >/dev/null 2>&1 || return 0
  # Usage: net__dbg message...
  dast_dbg "$@"
}

net__try_source_helper


# If the helper didn't load, log once (no stdout noise)
if ! declare -F run >/dev/null 2>&1 || ! declare -F run_capture >/dev/null 2>&1 || ! declare -F mktemp_safe >/dev/null 2>&1; then
  net__log "WARN" "NETWORK: dast_helper.sh functions not available (run/run_capture/mktemp_safe). Module may be limited if DaST core helper did not load."
  net__dbg "NETWORK: helper load check failed. SCRIPT_DIR='${SCRIPT_DIR:-}' module_dir='$(net__script_dir)'."
fi

# -----------------------------------------------------------------------------
# OS detection + gating
# -----------------------------------------------------------------------------
net_os_detect() {
  NET_OS_ID="unknown"
  NET_OS_NAME="Unknown"
  NET_OS_LIKE=""

  [[ -r /etc/os-release ]] || return 0
  # shellcheck disable=SC1091
  . /etc/os-release
  NET_OS_ID="${ID:-unknown}"
  NET_OS_NAME="${NAME:-Unknown}"
  NET_OS_LIKE="${ID_LIKE:-}"
}

net_is_debian() {
  net_os_detect
  [[ "$NET_OS_ID" == "debian" || "$NET_OS_LIKE" == *"debian"* ]]
}

net_supported_os() {
  net_os_detect
  [[ "$NET_OS_ID" == "ubuntu" || "$NET_OS_ID" == "debian" || "$NET_OS_LIKE" == *"debian"* || "$NET_OS_LIKE" == *"ubuntu"* ]]
}

# -----------------------------------------------------------------------------
# Local fallbacks
# -----------------------------------------------------------------------------
net_confirm_defaultno() {
  local title="$1" msg="$2"
  if declare -F dial >/dev/null 2>&1; then
    dial --title "$title" --defaultno --yesno "$msg" 12 80 >/dev/null
  else
    ui_yesno "$title" "$msg"
  fi
}

net_script_dir() {
  if [[ -n "${SCRIPT_DIR:-}" && -d "$SCRIPT_DIR" ]]; then
    echo "$SCRIPT_DIR"
  else
    echo "$(pwd)"
  fi
}

net_is_ssh() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" || -n "${SSH_TTY:-}" ]]
}

net_default_route_iface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

# -----------------------------------------------------------------------------
# Config persistence (best effort)
# -----------------------------------------------------------------------------
net_cfg_load() {
  if declare -F cfg_load >/dev/null 2>&1; then
    cfg_load || true
    return 0
  fi

  # No config execution fallback.
  # If DaST core helpers are not loaded, we run with defaults for safety.
}

net_cfg_set() {
  local key="$1" val="$2"
  if declare -F cfg_set_kv >/dev/null 2>&1; then
    cfg_set_kv "$key" "$val" || true
    return 0
  fi

  [[ -z "${CFG_FILE:-}" ]] && return 0
  mkdir -p "$(dirname "$CFG_FILE")" 2>/dev/null || true
  touch "$CFG_FILE" 2>/dev/null || true

  local tmp
  tmp="$(mktemp_safe)" || return 0

  if [[ -f "$CFG_FILE" ]]; then
    grep -vE "^${key}=" "$CFG_FILE" >"$tmp" 2>/dev/null || true
  fi
  printf '%s=%q\n' "$key" "$val" >>"$tmp"
  mv -f "$tmp" "$CFG_FILE"
# FIX: mktemp creates 0600 and mv replaces inode; restore sane perms/owner
chmod 644 "$CFG_FILE" 2>/dev/null || true

local _inv _grp
_inv="${DAST_INVOKER_USER:-${SUDO_USER:-}}"
if [[ -z "$_inv" || "$_inv" == "root" ]]; then
  _inv="$(logname 2>/dev/null || true)"
fi
if [[ -z "$_inv" || "$_inv" == "root" ]] || ! id "$_inv" >/dev/null 2>&1; then
  _inv="root"
fi
_grp="$(id -gn "$_inv" 2>/dev/null || echo "$_inv")"
if [[ "$_inv" != "root" ]]; then
  chown "$_inv:$_grp" "$(dirname "$CFG_FILE")" "$CFG_FILE" 2>/dev/null || true
fi
unset _inv _grp
}

# -----------------------------------------------------------------------------
# Stack detection
# -----------------------------------------------------------------------------
net__strip_inline_comment() {
  local s="$*"
  s="${s%%#*}"
  s="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$s")"
  printf '%s' "$s"
}

net__netplan_renderers() {
  local f line val
  local -a vals=()

  shopt -s nullglob
  for f in /etc/netplan/*.yaml; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      line="$(net__strip_inline_comment "$line")"
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ^[[:space:]]*renderer:[[:space:]]*(.+)$ ]]; then
        val="${BASH_REMATCH[1]}"
        val="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$val")"
        [[ -n "$val" ]] && vals+=("$val")
      fi
    done <"$f"
  done
  shopt -u nullglob

  (( ${#vals[@]} == 0 )) && return 0

  local -a uniq=()
  local v u found
  for v in "${vals[@]}"; do
    found=0
    for u in "${uniq[@]}"; do
      [[ "$u" == "$v" ]] && { found=1; break; }
    done
    (( found )) || uniq+=("$v")
  done

  printf '%s\n' "${uniq[@]}"
}

net_has_netplan() {
  command -v netplan >/dev/null 2>&1 && return 0
  [[ -d /etc/netplan ]] && compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1 && return 0
  return 1
}

net_detect_stack() {
  net_os_detect

  NET_STACK="unknown"
  NET_STACK_HUMAN="Unknown"
  NET_NETPLAN_RENDERER=""
  NET_NETPLAN_RENDERERS=""
  NET_STACK_AMBIGUOUS=0
  NET_STACK_UNSUPPORTED=0

  local have_netplan=0 have_nm=0 have_networkd=0 have_ifupdown=0
  local nm_active=0 networkd_active=0 ifupdown_active=0

  net_has_netplan && have_netplan=1

  command -v nmcli >/dev/null 2>&1 && have_nm=1
  systemctl is-active --quiet NetworkManager 2>/dev/null && { have_nm=1; nm_active=1; }
  systemctl is-enabled --quiet NetworkManager 2>/dev/null && have_nm=1

  command -v networkctl >/dev/null 2>&1 && have_networkd=1
  systemctl is-active --quiet systemd-networkd 2>/dev/null && { have_networkd=1; networkd_active=1; }
  systemctl is-enabled --quiet systemd-networkd 2>/dev/null && have_networkd=1

  command -v ifup >/dev/null 2>&1 && have_ifupdown=1
  [[ -f /etc/network/interfaces ]] && have_ifupdown=1
  systemctl is-active --quiet networking 2>/dev/null && { have_ifupdown=1; ifupdown_active=1; }

  if (( have_netplan )); then
    local -a rs=()
    local r
    while IFS= read -r r; do
      [[ -n "$r" ]] && rs+=("$r")
    done < <(net__netplan_renderers || true)

    if (( ${#rs[@]} == 0 )); then
      NET_NETPLAN_RENDERER="networkd"
      NET_NETPLAN_RENDERERS="networkd"
      NET_STACK="netplan-networkd"
      NET_STACK_HUMAN="Netplan (renderer: networkd)"
      return 0
    fi

    if (( ${#rs[@]} > 1 )); then
      NET_STACK_AMBIGUOUS=1
      NET_NETPLAN_RENDERER="${rs[0]}"
      NET_NETPLAN_RENDERERS="$(IFS=,; echo "${rs[*]}")"
      NET_STACK="netplan-ambiguous"
      NET_STACK_HUMAN="Netplan (renderer: multiple: ${NET_NETPLAN_RENDERERS})"
      return 0
    fi

    NET_NETPLAN_RENDERER="${rs[0]}"
    NET_NETPLAN_RENDERERS="${rs[0]}"

    case "${NET_NETPLAN_RENDERER}" in
      NetworkManager|networkmanager)
        NET_STACK="netplan-nm"
        NET_STACK_HUMAN="Netplan (renderer: NetworkManager)"
        return 0
        ;;
      networkd)
        NET_STACK="netplan-networkd"
        NET_STACK_HUMAN="Netplan (renderer: networkd)"
        return 0
        ;;
      *)
        NET_STACK_UNSUPPORTED=1
        NET_STACK="netplan"
        NET_STACK_HUMAN="Netplan (renderer: ${NET_NETPLAN_RENDERER})"
        return 0
        ;;
    esac
  fi

  local active_cnt=0
  (( nm_active )) && ((active_cnt++))
  (( networkd_active )) && ((active_cnt++))
  (( ifupdown_active )) && ((active_cnt++))

  if (( active_cnt > 1 )); then
    NET_STACK_AMBIGUOUS=1
    NET_STACK="ambiguous"
    NET_STACK_HUMAN="Ambiguous (multiple managers active)"
    return 0
  fi

  if (( have_nm )); then
    NET_STACK="networkmanager"
    NET_STACK_HUMAN="NetworkManager"
    return 0
  fi

  if (( have_networkd )); then
    NET_STACK="networkd"
    NET_STACK_HUMAN="systemd-networkd"
    return 0
  fi

  if (( have_ifupdown )); then
    NET_STACK="ifupdown"
    NET_STACK_HUMAN="ifupdown (/etc/network/interfaces)"
    return 0
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Complexity detection
# -----------------------------------------------------------------------------
net__grep_any() {
  local pattern="$1"; shift
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    grep -qiE "$pattern" "$f" && return 0
  done
  return 1
}

net_detect_complexity() {
  NET_COMPLEXITY="simple"
  NET_COMPLEXITY_REASON="No obvious advanced constructs detected"

  # Netplan heuristics
  if net_has_netplan; then
    local -a nfiles=()
    shopt -s nullglob
    nfiles=(/etc/netplan/*.yaml)
    shopt -u nullglob
    if (( ${#nfiles[@]} )); then
      if net__grep_any '(^|[[:space:]])(bridges:|bonds:|vlans:|tunnels:|wireguard:|routes:|routing-policy:|vrf:|vxlan:|bridge:|bond:|vlan:)' "${nfiles[@]}"; then
        NET_COMPLEXITY="complex"
        NET_COMPLEXITY_REASON="Netplan advanced keys detected (bridge/bond/vlan/tunnel/routes/etc)"
        return 0
      fi
      if net__grep_any '(^|[[:space:]])(addresses:|gateway4:|gateway6:|nameservers:)' "${nfiles[@]}"; then
        NET_COMPLEXITY="complex"
        NET_COMPLEXITY_REASON="Netplan static addressing or custom DNS detected"
        return 0
      fi
    fi
  fi

  # systemd-networkd heuristics
  if [[ -d /etc/systemd/network ]]; then
    local -a sfiles=()
    shopt -s nullglob
    sfiles=(/etc/systemd/network/*.network /etc/systemd/network/*.netdev)
    shopt -u nullglob

    if (( ${#sfiles[@]} )); then
      # .netdev alone implies advanced (bridge/bond/vlan/vxlan)
      local f
      for f in /etc/systemd/network/*.netdev; do
        [[ -f "$f" ]] && {
          NET_COMPLEXITY="complex"
          NET_COMPLEXITY_REASON="systemd-networkd .netdev present (bridge/bond/vlan/vxlan/etc likely)"
          return 0
        }
      done

      if net__grep_any '(^|[[:space:]])(VLAN=|Bond=|Bridge=|VXLAN=|VRF=|Tunnel=|Address=|Gateway=|RoutingPolicyRule=|IPForward=|IPMasquerade=)' "${sfiles[@]}"; then
        NET_COMPLEXITY="complex"
        NET_COMPLEXITY_REASON="systemd-networkd advanced config detected"
        return 0
      fi
    fi
  fi

  # ifupdown heuristics
  if [[ -f /etc/network/interfaces ]]; then
    if grep -qiE '(^|[[:space:]])(bridge_ports|bond-|vlan-raw-device|post-up|pre-up|up[[:space:]]+ip[[:space:]]+route|address|gateway|hwaddress|metric)' /etc/network/interfaces; then
      NET_COMPLEXITY="complex"
      NET_COMPLEXITY_REASON="ifupdown advanced/static config detected"
      return 0
    fi
  fi

  # NetworkManager heuristics
  if command -v nmcli >/dev/null 2>&1; then
    # Anything non-ethernet, or manual IPv4/IPv6
    if nmcli -t -f NAME,TYPE con show 2>/dev/null | grep -qiE ':(bridge|bond|vlan|team|tun|vpn|wireguard)$'; then
      NET_COMPLEXITY="complex"
      NET_COMPLEXITY_REASON="NetworkManager advanced connection type detected (bridge/bond/vlan/vpn/etc)"
      return 0
    fi
    if nmcli -t -f NAME,ipv4.method,ipv6.method con show 2>/dev/null | grep -qiE ':(manual|shared|disabled):|:(auto):(manual|shared|disabled)$'; then
      NET_COMPLEXITY="complex"
      NET_COMPLEXITY_REASON="NetworkManager non-default IP method detected (manual/shared/disabled)"
      return 0
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# High-risk acknowledgement helper
# -----------------------------------------------------------------------------
net_require_ack_switch() {
  local why="$1"

  local msg="🚨 HIGH RISK ACTION\n\n$why\n\nTo continue, type SWITCH exactly.\n\nDefault is cancel."
  local input=""

  if declare -F ui_input >/dev/null 2>&1; then
    input="$(ui_input "$NET_TITLE" "$msg" "")" || return 1
  else
    # Ultra-basic fallback
    echo "$msg" >&2
    read -r -p "Type SWITCH to continue: " input || return 1
  fi

  [[ "$input" == "SWITCH" ]]
}

# -----------------------------------------------------------------------------
# Info helpers
# -----------------------------------------------------------------------------
net_dns_summary() {
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "DNS manager: systemd-resolved (active)"
    if command -v resolvectl >/dev/null 2>&1; then
      echo
      echo "resolvectl (first ~60 lines):"
      resolvectl status 2>/dev/null | sed -n '1,60p' || true
    fi
  else
    echo "DNS manager: systemd-resolved (inactive or not present)"
  fi

  if [[ -L /etc/resolv.conf ]]; then
    echo "/etc/resolv.conf: symlink -> $(readlink -f /etc/resolv.conf 2>/dev/null || true)"
  else
    echo "/etc/resolv.conf: regular file"
  fi

  echo
  echo "resolv.conf:"
  (sed -n '1,120p' /etc/resolv.conf 2>/dev/null || true)
}

net_vpn_summary() {
  local any=0

  if command -v tailscale >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^tailscaled'; then
    any=1
    echo "- Tailscale:"
    systemctl is-active tailscaled 2>/dev/null | sed 's/^/  service: /' || true
    ip link show tailscale0 >/dev/null 2>&1 && echo "  iface: tailscale0 present" || echo "  iface: tailscale0 not present"
  fi

  if command -v wg >/dev/null 2>&1; then
    any=1
    echo "- WireGuard:"
    (wg show 2>/dev/null | sed -n '1,80p' | sed 's/^/  /') || echo "  wg present, no active tunnels"
  else
    ip -br link 2>/dev/null | grep -q '^wg' && { any=1; echo "- WireGuard: interface(s) present"; }
  fi

  if systemctl list-unit-files 2>/dev/null | grep -qi '^openvpn'; then
    any=1
    echo "- OpenVPN:"
    systemctl --no-pager --plain --type=service 2>/dev/null | grep -i openvpn | head -n 5 | sed 's/^/  /' || true
  else
    pgrep -a openvpn >/dev/null 2>&1 && { any=1; echo "- OpenVPN: process running"; }
  fi

  if command -v zerotier-cli >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -qi 'zerotier'; then
    any=1
    echo "- Zerotier:"
    systemctl is-active zerotier-one 2>/dev/null | sed 's/^/  service: /' || true
  fi

  (( any )) || echo "- None detected"
}

net_overview_to_file() {
  local out="$1"
  net_detect_stack
  net_detect_complexity

  {
    echo "OS: ${NET_OS_NAME} (${NET_OS_ID})"
    echo "Networking stack: ${NET_STACK_HUMAN}"
    [[ -n "$NET_NETPLAN_RENDERERS" ]] && echo "Netplan renderer(s): $NET_NETPLAN_RENDERERS"
    echo "Complexity: $NET_COMPLEXITY"
    echo "Complexity reason: $NET_COMPLEXITY_REASON"
    echo
    echo "Default route interface: $(net_default_route_iface || echo "unknown")"
    echo
    echo "Interfaces (ip -br a):"
    ip -br a 2>/dev/null || true
    echo
    echo "Routes:"
    ip route 2>/dev/null || true
    echo
    echo "DNS:"
    net_dns_summary
    echo
    echo "VPN / overlays:"
    net_vpn_summary
  } >"$out"
}

net_logs_to_file() {
  local out="$1"
  local lines="${NET_LOG_LINES:-200}"
  net_detect_stack
  net_detect_complexity

  {
    echo "OS: ${NET_OS_NAME} (${NET_OS_ID})"
    echo "Detected stack: ${NET_STACK_HUMAN}"
    echo "Complexity: $NET_COMPLEXITY"
    echo "Complexity reason: $NET_COMPLEXITY_REASON"
    echo
    echo "Networking logs (last $lines lines per unit where available)"
    echo

    echo "=== dmesg (link related, last ~120) ==="
    (dmesg 2>/dev/null | grep -Ei 'link is|renamed|mtu|carrier|dhcp|NetworkManager|networkd|resolved' | tail -n 120) || true
    echo

    echo "=== systemd-resolved ==="
    journalctl --no-pager -u systemd-resolved -n "$lines" 2>/dev/null || echo "(no logs / unit missing)"
    echo

    echo "=== NetworkManager ==="
    journalctl --no-pager -u NetworkManager -n "$lines" 2>/dev/null || echo "(no logs / unit missing)"
    echo

    echo "=== systemd-networkd ==="
    journalctl --no-pager -u systemd-networkd -n "$lines" 2>/dev/null || echo "(no logs / unit missing)"
    echo

    echo "=== ifupdown (networking) ==="
    journalctl --no-pager -u networking -n "$lines" 2>/dev/null || echo "(no logs / unit missing)"
  } >"$out"
}

# -----------------------------------------------------------------------------
# Interface picker (for renew)
# -----------------------------------------------------------------------------
net_pick_iface() {
  local -a items=()
  local line name state
  while IFS= read -r line; do
    name="$(awk -F': ' '{print $2}' <<<"$line" | awk '{print $1}')"
    [[ -z "$name" ]] && continue
    [[ "$name" == "lo" ]] && continue
    [[ "$name" =~ ^(tailscale0|wg[0-9]+|tun[0-9]+|tap[0-9]+)$ ]] && continue
    state="$(awk '{print $9}' <<<"$line")"
    [[ -z "$state" ]] && state="?"
    items+=("$name" "🔌 $name ($state)")
  done < <(ip -o link show 2>/dev/null || true)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$NET_TITLE" "No interfaces found."
    return 1
  fi

  ui_menu "$NET_TITLE" "Choose an interface:" "${items[@]}"
}

# -----------------------------------------------------------------------------
# Restart / renew
# -----------------------------------------------------------------------------
net_restart_networking() {
  net_detect_stack
  net_detect_complexity

  local warn=""
  if net_is_ssh; then
    warn+="🚨 You appear to be on an SSH session.\nRestarting networking can drop your connection.\n\n"
  fi
  if [[ "$NET_COMPLEXITY" == "complex" ]]; then
    warn+="🚨 Complex networking detected:\n$NET_COMPLEXITY_REASON\n\n"
  fi

  local iface
  iface="$(net_default_route_iface || true)"
  [[ -n "$iface" ]] && warn+="Default route interface: $iface\n\n"

  net_confirm_defaultno "$NET_TITLE" "${warn}Restart networking now?\n\nDefault is No." || return 0

  case "$NET_STACK" in
    netplan-nm|netplan-networkd|netplan|netplan-ambiguous)
      ui_programbox "$NET_TITLE" "netplan apply 2>&1 || true"
      ;;
    networkmanager)
      ui_programbox "$NET_TITLE" "systemctl restart NetworkManager 2>&1 || true"
      ;;
    networkd)
      ui_programbox "$NET_TITLE" "systemctl restart systemd-networkd 2>&1 || true"
      ;;
    ifupdown)
      if systemctl list-unit-files 2>/dev/null | grep -q '^networking\.service'; then
        ui_programbox "$NET_TITLE" "systemctl restart networking 2>&1 || true"
      else
        ui_programbox "$NET_TITLE" "echo 'networking.service not found. Try ifdown/ifup per interface.'"
      fi
      ;;
    *)
      ui_msg "$NET_TITLE" "Could not determine how to restart networking on this system."
      ;;
  esac
}

net_renew_dhcp() {
  net_detect_stack
  net_detect_complexity

  local warn=""
  if net_is_ssh; then
    warn+="🚨 You appear to be on an SSH session.\nRenewing DHCP can drop your connection.\n\n"
  fi
  if [[ "$NET_COMPLEXITY" == "complex" ]]; then
    warn+="🚨 Complex networking detected:\n$NET_COMPLEXITY_REASON\n\nDHCP renew might not be appropriate.\n\n"
  fi

  local iface
  iface="$(net_pick_iface)" || return 0

  net_confirm_defaultno "$NET_TITLE" "${warn}Renew DHCP for interface: $iface ?\n\nDefault is No." || return 0

  if [[ "$NET_STACK" == "networkmanager" || "$NET_STACK" == "netplan-nm" ]]; then
    ui_programbox "$NET_TITLE" "nmcli dev disconnect '$iface' 2>&1 || true; nmcli dev connect '$iface' 2>&1 || true; nmcli -f GENERAL,IP4,IP6 dev show '$iface' 2>&1 || true"
    return 0
  fi

  if command -v networkctl >/dev/null 2>&1; then
    ui_programbox "$NET_TITLE" "networkctl renew '$iface' 2>&1 || { echo 'networkctl renew not supported or failed.'; true; }"
    return 0
  fi

  if command -v dhclient >/dev/null 2>&1; then
    ui_programbox "$NET_TITLE" "dhclient -r '$iface' 2>&1 || true; dhclient '$iface' 2>&1 || true"
    return 0
  fi

  ui_msg "$NET_TITLE" "No supported DHCP renew method found (nmcli/networkctl/dhclient)."
}

# -----------------------------------------------------------------------------
# Config editor
# -----------------------------------------------------------------------------
net_open_config() {
  net_detect_stack

  local f=""
  case "$NET_STACK" in
    netplan-nm|netplan-networkd|netplan|netplan-ambiguous)
      f="$(ls -1 /etc/netplan/*.yaml 2>/dev/null | head -n 1 || true)"
      ;;
    networkmanager)
      f="/etc/NetworkManager/NetworkManager.conf"
      ;;
    networkd)
      f="$(ls -1 /etc/systemd/network/*.network 2>/dev/null | head -n 1 || true)"
      ;;
    ifupdown)
      f="/etc/network/interfaces"
      ;;
  esac

  if [[ -z "$f" || ! -e "$f" ]]; then
    ui_msg "$NET_TITLE" "No obvious config file found for: ${NET_STACK_HUMAN}"
    return 0
  fi

  local warn=""
  if net_is_ssh; then
    warn+="🚨 You're on SSH. Editing is fine, but applying/restarting can drop you.\n\n"
  fi

  net_confirm_defaultno "$NET_TITLE" "${warn}Open config editor?\n\nFile:\n$f\n\nDefault is No." || return 0

  if declare -F dial >/dev/null 2>&1; then
    local tmp edited
    tmp="$(mktemp_safe)" || return 0

    edited="$(dial --title "$NET_TITLE" --editbox "$f" 24 100)" || return 0
    printf '%s\n' "$edited" >"$tmp"

    if ! cmp -s "$tmp" "$f" 2>/dev/null; then
      if net_confirm_defaultno "$NET_TITLE" "Save changes to:\n\n$f\n\nDefault is No." ; then
        cp -a "$f" "${f}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
        cat "$tmp" >"$f"
        ui_msg "$NET_TITLE" "Saved.\n\nBackup created alongside:\n${f}.bak.*"
      else
        ui_msg "$NET_TITLE" "Cancelled. No changes saved."
      fi
    else
      ui_msg "$NET_TITLE" "No changes."
    fi
    return 0
  fi

  local editor="${EDITOR:-nano}"
  clear || true
  "$editor" "$f" || true
}

# -----------------------------------------------------------------------------
# Backup / restore
# -----------------------------------------------------------------------------
net_backup_configs() {
  local d="/var/backups/dast/network"
  local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
  local out="${d}/backup-${stamp}"

  mkdir -p "$out" 2>/dev/null || true

  ip -br a 2>/dev/null >"${out}/ip-brief.txt" || true
  ip route 2>/dev/null >"${out}/routes.txt" || true
  (command -v resolvectl >/dev/null 2>&1 && resolvectl status 2>/dev/null || cat /etc/resolv.conf 2>/dev/null || true) >"${out}/dns.txt" || true
  systemctl --no-pager --plain --type=service 2>/dev/null | grep -Ei 'NetworkManager|networkd|resolved|tailscale|openvpn|wireguard|zerotier|networking' >"${out}/services.txt" || true

  [[ -d /etc/netplan ]] && cp -a /etc/netplan "${out}/" 2>/dev/null || true
  [[ -d /etc/NetworkManager ]] && cp -a /etc/NetworkManager "${out}/" 2>/dev/null || true
  [[ -d /etc/systemd/network ]] && cp -a /etc/systemd/network "${out}/" 2>/dev/null || true
  [[ -f /etc/network/interfaces ]] && cp -a /etc/network/interfaces "${out}/" 2>/dev/null || true
  [[ -e /etc/resolv.conf ]] && cp -a /etc/resolv.conf "${out}/resolv.conf.backup" 2>/dev/null || true

  echo "$out"
}

net_list_backups() {
  local base="/var/backups/dast/network"
  [[ -d "$base" ]] || return 1
  ls -1dt "$base"/backup-* 2>/dev/null || true
}

net_pick_backup() {
  local -a items=()
  local b
  while IFS= read -r b; do
    [[ -d "$b" ]] || continue
    items+=("$b" "📦 $(basename "$b")")
  done < <(net_list_backups)

  if [[ "${#items[@]}" -eq 0 ]]; then
    ui_msg "$NET_TITLE" "No backups found under /var/backups/dast/network."
    return 1
  fi

  ui_menu "$NET_TITLE" "Choose a backup to restore:" "${items[@]}"
}

net_restore_backup() {
  local b="$1"
  [[ -d "$b" ]] || { ui_msg "$NET_TITLE" "Backup folder not found:\n\n$b"; return 0; }

  local warn=""
  if net_is_ssh; then
    warn+="🚨 You're on SSH.\nRestoring network configs can drop your connection.\n\n"
  fi

  net_confirm_defaultno "$NET_TITLE" "${warn}Restore this backup?\n\n$b\n\nDefault is No." || return 0

  ui_programbox "$NET_TITLE" "\
    set -e; \
    echo 'Restoring from:' '$b'; echo; \
    [[ -d '$b/netplan' ]] && { echo 'Restoring /etc/netplan'; rm -rf /etc/netplan 2>/dev/null || true; cp -a '$b/netplan' /etc/netplan; } || true; \
    [[ -d '$b/NetworkManager' ]] && { echo 'Restoring /etc/NetworkManager'; rm -rf /etc/NetworkManager 2>/dev/null || true; cp -a '$b/NetworkManager' /etc/NetworkManager; } || true; \
    [[ -d '$b/network' ]] && { echo 'Restoring /etc/systemd/network'; rm -rf /etc/systemd/network 2>/dev/null || true; cp -a '$b/network' /etc/systemd/network; } || true; \
    [[ -f '$b/interfaces' ]] && { echo 'Restoring /etc/network/interfaces'; cp -a '$b/interfaces' /etc/network/interfaces; } || true; \
    [[ -f '$b/resolv.conf.backup' ]] && { echo 'Restoring /etc/resolv.conf (file copy)'; cp -a '$b/resolv.conf.backup' /etc/resolv.conf; } || true; \
    echo; echo 'Restore done (best effort).'; \
    true"

  if net_confirm_defaultno "$NET_TITLE" "${warn}Attempt to restart networking now?\n\nDefault is No." ; then
    net_restart_networking
  else
    ui_msg "$NET_TITLE" "Restore complete.\n\nRestart networking manually when ready."
  fi
}

# -----------------------------------------------------------------------------
# Switch helpers (unchanged mechanics, added gating)
# -----------------------------------------------------------------------------
net_set_netplan_renderer() {
  local target="$1"

  local -a files=()
  local f
  shopt -s nullglob
  for f in /etc/netplan/*.yaml; do
    [[ -f "$f" ]] && files+=("$f")
  done
  shopt -u nullglob
  (( ${#files[@]} )) || return 1

  local tmp
  for f in "${files[@]}"; do
    tmp="$(mktemp_safe)" || return 1

    if grep -qE '^[[:space:]]*renderer:[[:space:]]*' "$f"; then
      sed -E "s/^([[:space:]]*)renderer:[[:space:]]*.*/\\1renderer: ${target}/" "$f" >"$tmp"
    else
      awk -v tgt="$target" '
        BEGIN { inserted=0 }
        {
          print $0
          if (!inserted && $0 ~ /^[[:space:]]*network:[[:space:]]*$/) {
            print "  renderer: " tgt
            inserted=1
          }
        }
        END {
          if (!inserted) {
            print ""
            print "network:"
            print "  renderer: " tgt
          }
        }
      ' "$f" >"$tmp"
    fi

    cp -a "$f" "${f}.bak.$(date '+%Y%m%d-%H%M%S')" 2>/dev/null || true
    cat "$tmp" >"$f"
  done

  return 0
}

net_nm_ensure_running() {
  run_sh "systemctl enable --now NetworkManager >/dev/null 2>&1 || true"
}

net_networkd_ensure_running() {
  run_sh "systemctl enable --now systemd-networkd >/dev/null 2>&1 || true"
  run_sh "systemctl enable --now systemd-resolved >/dev/null 2>&1 || true"
}

net_nm_try_autoconnect() {
  command -v nmcli >/dev/null 2>&1 || return 0
  local ifc
  while IFS= read -r ifc; do
    [[ -z "$ifc" ]] && continue
    [[ "$ifc" == "lo" ]] && continue
    [[ "$ifc" =~ ^(tailscale0|wg[0-9]+|tun[0-9]+|tap[0-9]+)$ ]] && continue
    run_sh "nmcli dev connect '$ifc' >/dev/null 2>&1 || true"
  done < <(ip -br link 2>/dev/null | awk '{print $1}' || true)
}

net_networkd_write_dhcp_profiles() {
  mkdir -p /etc/systemd/network 2>/dev/null || true

  local ifc
  while IFS= read -r ifc; do
    [[ -z "$ifc" ]] && continue
    [[ "$ifc" == "lo" ]] && continue
    [[ "$ifc" =~ ^(tailscale0|wg[0-9]+|tun[0-9]+|tap[0-9]+)$ ]] && continue

    local f="/etc/systemd/network/10-dast-${ifc}.network"
    [[ -f "$f" ]] && continue

    cat >"$f" <<EOF
[Match]
Name=${ifc}

[Network]
DHCP=yes
EOF
  done < <(ip -br link 2>/dev/null | awk '{print $1}' || true)
}

net_prepare_package_cache() {
  local cache_dir="$1"; shift
  local -a pkgs=("$@")

  mkdir -p "$cache_dir" 2>/dev/null || true
  run_sh "apt-get update >/dev/null 2>&1 || true"

  local pkg_list="" p
  for p in "${pkgs[@]}"; do
    [[ -n "$p" ]] && pkg_list+="$p "
  done

  ui_programbox "$NET_TITLE" "echo 'Downloading packages to:' '$cache_dir'; echo; apt-get -y --download-only -o Dir::Cache::archives='$cache_dir' install $pkg_list 2>&1 || true; echo; echo 'Done.'"
}

net_install_from_cache() {
  local cache_dir="$1"
  [[ -d "$cache_dir" ]] || { ui_msg "$NET_TITLE" "Cache dir not found:\n\n$cache_dir"; return 0; }

  net_confirm_defaultno "$NET_TITLE" "Install packages from local cache?\n\nCache:\n$cache_dir\n\nThis uses dpkg -i on cached .deb files.\n\nDefault is No." || return 0

  ui_programbox "$NET_TITLE" "\
    set +e; \
    echo 'Installing from cache:' '$cache_dir'; echo; \
    ls -1 '$cache_dir'/*.deb >/dev/null 2>&1 || { echo 'No .deb files found.'; exit 0; }; \
    dpkg -i '$cache_dir'/*.deb 2>&1 || true; \
    echo; \
    echo 'If dependencies are missing, you may need:'; \
    echo '  apt-get -f install'; \
    true"
}

net_switch_pkgs_for_sel() {
  local sel="$1"
  case "$sel" in
    NP_TO_NM)       echo "netplan.io network-manager" ;;
    NP_TO_NETWORKD) echo "netplan.io" ;;
    TO_NM)          echo "network-manager" ;;
    TO_NETWORKD)    echo "" ;;
    *)              echo "" ;;
  esac
}

net_cache_has_pkgs() {
  local cache_dir="$1"; shift
  local -a pkgs=("$@")
  [[ -d "$cache_dir" ]] || return 1

  local p
  for p in "${pkgs[@]}"; do
    [[ -z "$p" ]] && continue
    ls -1 "$cache_dir"/${p}_*.deb >/dev/null 2>&1 || return 1
  done
  return 0
}

net_switch_choose_target() {
  net_detect_stack

  if [[ "$NET_STACK" == "netplan" && "${NET_STACK_UNSUPPORTED:-0}" -eq 1 ]]; then
    ui_msg "$NET_TITLE" "Detected Netplan with a custom/unknown renderer:

  ${NET_NETPLAN_RENDERER:-unknown}

DaST only switches Netplan between:
- networkd
- NetworkManager

Because this looks custom, DaST will NOT make changes automatically.

Use CONFIG to edit /etc/netplan/*.yaml manually."
    echo "BACK"
    return 0
  fi

  local -a choices=()

  if net_has_netplan; then
    choices+=("NP_TO_NM"       "🔁 Netplan → NetworkManager (all YAML)")
    choices+=("NP_TO_NETWORKD" "🔁 Netplan → networkd (all YAML)")
    choices+=("BACK"           "🔙️ Back")
    ui_menu "$NET_TITLE" "Choose target:" "${choices[@]}"
    return 0
  fi

  case "$NET_STACK" in
    networkmanager)
      choices+=("TO_NETWORKD" "🔁 Switch NM → systemd-networkd (DHCP)")
      choices+=("KEEP"        "✅ Already using NetworkManager")
      ;;
    networkd)
      choices+=("TO_NM"       "🔁 Switch networkd → NetworkManager")
      choices+=("KEEP"        "✅ Already using systemd-networkd")
      ;;
    ifupdown)
      choices+=("TO_NM"       "🔁 Switch ifupdown → NetworkManager (simple only)")
      choices+=("TO_NETWORKD" "🔁 Switch ifupdown → systemd-networkd (simple only)")
      choices+=("KEEP"        "✅ Already using ifupdown")
      ;;
    ambiguous|netplan-ambiguous)
      ui_msg "$NET_TITLE" "Multiple network managers appear active.

DaST will not switch automatically in this state.
Fix it manually first, or use CONFIG to review your setup."
      echo "BACK"
      return 0
      ;;
    *)
      choices+=("TO_NM"       "🔁 Enable NetworkManager (best effort)")
      choices+=("TO_NETWORKD" "🔁 Enable systemd-networkd (best effort)")
      ;;
  esac

  choices+=("BACK" "🔙️ Back")

  local pick
  pick="$(ui_menu "$NET_TITLE" "Choose target:" "${choices[@]}")" || return 0

  [[ "$pick" == "KEEP" ]] && { echo "BACK"; return 0; }
  echo "$pick"
}

net_switch_prepare() {
  net_detect_stack
  net_detect_complexity

  local base_dir cache_dir manifest_dir
  base_dir="$(net_script_dir)"
  cache_dir="${base_dir}/cache/apt-archives"
  manifest_dir="${base_dir}/cache"
  mkdir -p "$manifest_dir" 2>/dev/null || true

  local sel
  sel="$(net_switch_choose_target)" || return 0
  [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

  local warn=""
  if net_is_ssh; then
    warn+="🚨 You are on SSH.\nThis step only prepares backups and package cache.\n\n"
  fi
  if [[ "$NET_COMPLEXITY" == "complex" ]]; then
    warn+="🚨 Complex networking detected:\n$NET_COMPLEXITY_REASON\n\n"
  fi
  if net_is_debian; then
    warn+="Note: Debian often uses ifupdown/ifupdown2 or custom networkd.\nSwitching managers can break connectivity.\n\n"
  fi

  net_confirm_defaultno "$NET_TITLE" "${warn}Prepare a switch bundle?\n\nThis will:\n- Backup configs/state\n- Download packages to:\n  ${cache_dir}\n- Write a manifest under:\n  ${manifest_dir}\n\nDefault is No." || return 0

  local backup_path
  backup_path="$(net_backup_configs)"

  local pkgs_str
  pkgs_str="$(net_switch_pkgs_for_sel "$sel")"
  local -a pkgs=()
  if [[ -n "$pkgs_str" ]]; then
    # shellcheck disable=SC2206
    pkgs=($pkgs_str)
  fi

  local stamp mf
  stamp="$(date '+%Y%m%d-%H%M%S')"
  mf="${manifest_dir}/network-switch-${stamp}.txt"

  {
    echo "DaST Networking: switch bundle"
    echo "Timestamp: $stamp"
    echo "OS: ${NET_OS_NAME} (${NET_OS_ID})"
    echo "Detected stack: ${NET_STACK_HUMAN}"
    echo "Complexity: $NET_COMPLEXITY"
    echo "Complexity reason: $NET_COMPLEXITY_REASON"
    echo "Selection: $sel"
    echo "Backup path: $backup_path"
    echo "Cache dir: $cache_dir"
    echo "Packages:"
    if (( ${#pkgs[@]} )); then
      printf '  - %s\n' "${pkgs[@]}"
    else
      echo "  - (none)"
    fi
    echo
    echo "Notes:"
    echo "- Prepare step only. Apply step is separate."
  } >"$mf"

  net_cfg_set "NET_SWITCH_LAST_MANIFEST" "$mf"
  net_cfg_set "NET_SWITCH_LAST_SELECTION" "$sel"
  net_cfg_set "NET_SWITCH_LAST_CACHE_DIR" "$cache_dir"

  if (( ${#pkgs[@]} )); then
    net_prepare_package_cache "$cache_dir" "${pkgs[@]}"
  fi

  ui_msg "$NET_TITLE" "Prepared bundle.\n\nSelection:\n$sel\n\nBackup:\n$backup_path\n\nManifest:\n$mf\n\nCache:\n$cache_dir"
}

net_switch_apply_selection() {
  net_cfg_load
  local last_sel="${NET_SWITCH_LAST_SELECTION:-}"
  local sel

  if [[ -n "$last_sel" ]]; then
    sel="$(ui_menu "$NET_TITLE" "Apply which target?" \
      "$last_sel" "✅ Last prepared target ($last_sel)" \
      "CHOOSE"   "📋 Choose another target" \
      "BACK"     "🔙 Back")" || return 0
    [[ "$sel" == "BACK" || -z "$sel" ]] && return 1
    if [[ "$sel" == "CHOOSE" ]]; then
      sel="$(net_switch_choose_target)" || return 1
      [[ -z "$sel" || "$sel" == "BACK" ]] && return 1
    fi
  else
    sel="$(net_switch_choose_target)" || return 1
    [[ -z "$sel" || "$sel" == "BACK" ]] && return 1
  fi

  echo "$sel"
}

net_switch_apply() {
  net_detect_stack
  net_detect_complexity
  net_cfg_load

  local warn=""
  local need_ack=0
  local ack_why=""

  if net_is_ssh; then
    need_ack=1
    ack_why+="You are on SSH. Applying a manager switch can drop your connection.\n\n"
  fi
  if [[ "$NET_COMPLEXITY" == "complex" ]]; then
    need_ack=1
    ack_why+="Complex networking detected:\n$NET_COMPLEXITY_REASON\n\n"
  fi
  if net_is_debian; then
    need_ack=1
    ack_why+="OS is Debian. Debian hosts often have ifupdown/ifupdown2 or custom networkd.\n\n"
  fi

  local sel
  sel="$(net_switch_apply_selection)" || return 0

  warn="$ack_why"
  warn+="APPLY switch now?\n\nTarget: $sel\n\nThis WILL modify network configuration and may restart/apply networking.\n\nDefault is No."
  net_confirm_defaultno "$NET_TITLE" "$warn" || return 0

  if (( need_ack )); then
    if ! net_require_ack_switch "$ack_why"; then
      ui_msg "$NET_TITLE" "Cancelled. No changes made."
      return 0
    fi
  fi

  local backup_path
  backup_path="$(net_backup_configs)"

  local cache_dir="${NET_SWITCH_LAST_CACHE_DIR:-}"
  [[ -z "$cache_dir" ]] && cache_dir="$(net_script_dir)/cache/apt-archives"

  local pkgs_str
  pkgs_str="$(net_switch_pkgs_for_sel "$sel")"
  local -a pkgs=()
  if [[ -n "$pkgs_str" ]]; then
    # shellcheck disable=SC2206
    pkgs=($pkgs_str)
  fi

  if (( ${#pkgs[@]} )); then
    if ! net_cache_has_pkgs "$cache_dir" "${pkgs[@]}"; then
      if net_confirm_defaultno "$NET_TITLE" "Required packages are not fully cached yet.\n\nDaST will download them now to:\n$cache_dir\n\nThis does NOT change networking yet.\n\nProceed?\n\nDefault is No." ; then
        net_prepare_package_cache "$cache_dir" "${pkgs[@]}"
      else
        ui_msg "$NET_TITLE" "Cancelled.\n\nNothing changed."
        return 0
      fi
    fi

    if net_confirm_defaultno "$NET_TITLE" "Install required packages from local cache now?\n\nCache:\n$cache_dir\n\nDefault is No." ; then
      net_install_from_cache "$cache_dir"
    fi
  fi

  case "$sel" in
    NP_TO_NM)
      if ! command -v netplan >/dev/null 2>&1; then
        ui_msg "$NET_TITLE" "netplan not found. Cannot apply Netplan renderer switch."
        return 0
      fi
      net_set_netplan_renderer "NetworkManager" || { ui_msg "$NET_TITLE" "Failed to update netplan renderer."; return 0; }
      net_nm_ensure_running
      ui_programbox "$NET_TITLE" "netplan apply 2>&1 || true; systemctl status NetworkManager --no-pager 2>&1 | sed -n '1,60p' || true"
      ;;

    NP_TO_NETWORKD)
      if ! command -v netplan >/dev/null 2>&1; then
        ui_msg "$NET_TITLE" "netplan not found. Cannot apply Netplan renderer switch."
        return 0
      fi
      net_set_netplan_renderer "networkd" || { ui_msg "$NET_TITLE" "Failed to update netplan renderer."; return 0; }
      net_networkd_ensure_running
      ui_programbox "$NET_TITLE" "netplan apply 2>&1 || true; systemctl status systemd-networkd --no-pager 2>&1 | sed -n '1,60p' || true"
      ;;

    TO_NM)
      net_nm_ensure_running
      run_sh "systemctl disable --now systemd-networkd >/dev/null 2>&1 || true"
      run_sh "systemctl disable --now networking >/dev/null 2>&1 || true"
      net_nm_try_autoconnect
      ui_programbox "$NET_TITLE" "echo 'NetworkManager enabled. Autoconnect attempted.'; echo; nmcli con show 2>&1 || true; echo; ip -br a 2>&1 || true; echo; ip route 2>&1 || true"
      ;;

    TO_NETWORKD)
      net_networkd_write_dhcp_profiles
      net_networkd_ensure_running
      run_sh "systemctl disable --now NetworkManager >/dev/null 2>&1 || true"
      run_sh "systemctl disable --now networking >/dev/null 2>&1 || true"
      ui_programbox "$NET_TITLE" "systemctl restart systemd-networkd 2>&1 || true; echo; networkctl status 2>&1 | sed -n '1,120p' || true; echo; ip -br a 2>&1 || true; echo; ip route 2>&1 || true"
      ;;

    *)
      ui_msg "$NET_TITLE" "Unknown apply target: $sel"
      return 0
      ;;
  esac

  net_cfg_set "NET_SWITCH_LAST_APPLY_BACKUP" "$backup_path"
  ui_msg "$NET_TITLE" "Apply step finished.\n\nBackup taken:\n$backup_path\n\nIf anything went wrong, use Switch -> Rollback."
}

net_switch_rollback() {
  local b
  b="$(net_pick_backup)" || return 0
  net_restore_backup "$b"
}

net_switch_show_last_manifest() {
  net_cfg_load
  local mf="${NET_SWITCH_LAST_MANIFEST:-}"
  if [[ -z "$mf" || ! -f "$mf" ]]; then
    ui_msg "$NET_TITLE" "No manifest recorded yet.\n\nUse Switch -> Prepare bundle first."
    return 0
  fi
  ui_textbox "$NET_TITLE" "$mf"
}

net_switch_menu() {
  net_cfg_load

  ui_menu "$NET_TITLE" "🚨 WARNING: This can take your system offline if something does not work as expected. Use with caution!

Choose:" \
    "PREPARE"  "📦 Prepare bundle (backup + download packages)" \
    "APPLY"    "✅ Apply switch (makes changes, risky)" \
    "ROLLBACK" "🧯 Rollback (restore a backup)" \
    "MANIFEST" "📄 View last manifest" \
    "OFFLINE"  "📥 Install from cache" \
    "BACK"     "🔙 Back"
}

net_switch_dispatch() {
  while true; do
    local sel
    sel="$(net_switch_menu)" || return 0
    [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

    case "$sel" in
      PREPARE)  net_switch_prepare ;;
      APPLY)    net_switch_apply ;;
      ROLLBACK) net_switch_rollback ;;
      MANIFEST) net_switch_show_last_manifest ;;
      OFFLINE)
        net_cfg_load
        if [[ -n "${NET_SWITCH_LAST_CACHE_DIR:-}" ]]; then
          net_install_from_cache "$NET_SWITCH_LAST_CACHE_DIR"
        else
          ui_msg "$NET_TITLE" "No cache dir recorded yet.\n\nUse Switch -> Prepare bundle first."
        fi
        ;;
      *) ui_msg "$NET_TITLE" "Unknown selection: $sel" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Screens
# -----------------------------------------------------------------------------
net_info_screen() {
  local tmp; tmp="$(mktemp_safe)" || return 0
  net_overview_to_file "$tmp"
  ui_textbox "$NET_TITLE" "$tmp"
}

net_ifaces_screen() {
  ui_programbox "$NET_TITLE" "echo 'Interfaces:'; ip -br a 2>/dev/null || true; echo; echo 'Links:'; ip -br link 2>/dev/null || true"
}

net_routes_screen() {
  ui_programbox "$NET_TITLE" "echo 'Routes:'; ip route 2>/dev/null || true; echo; echo 'Policy rules:'; ip rule 2>/dev/null || true"
}

net_dns_screen() {
  local tmp; tmp="$(mktemp_safe)" || return 0
  net_dns_summary >"$tmp"
  ui_textbox "$NET_TITLE" "$tmp"
}

net_vpn_screen() {
  ui_programbox "$NET_TITLE" "echo 'VPN / overlays report:'; echo; \
    { command -v tailscale >/dev/null 2>&1 && tailscale status 2>/dev/null | sed -n '1,120p' || echo 'tailscale not installed'; } ; \
    echo; \
    { command -v wg >/dev/null 2>&1 && wg show 2>/dev/null || echo 'wg not installed'; } ; \
    echo; \
    { systemctl --no-pager --plain --type=service 2>/dev/null | grep -Ei 'openvpn|tailscale|zerotier|wireguard' | head -n 20 || true; }"
}

net_set_log_lines() {
  local sel
  sel="$(ui_menu "$NET_TITLE" "Choose how many lines of logs to show:" \
    "500"  "📄 500" \
    "300"  "📄 300" \
    "200"  "📄 200" \
    "100"  "📄 100" \
    "50"   "📄 50" \
    "SPEC" "✍ Specify" \
    "BACK" "🔙 Back")" || return 0

  case "$sel" in
    500|300|200|100|50) NET_LOG_LINES="$sel" ;;
    SPEC)
      local n
      n="$(ui_input "$NET_TITLE" "Enter a number (e.g. 250):" "")" || return 0
      [[ -z "$n" ]] && return 0
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
        NET_LOG_LINES="$n"
      else
        ui_msg "$NET_TITLE" "That isn't a positive integer."
      fi
      ;;
    BACK|*) return 0 ;;
  esac
}

net_logs_screen() {
  local tmp; tmp="$(mktemp_safe)" || return 0
  net_logs_to_file "$tmp"
  ui_textbox "$NET_TITLE" "$tmp"
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
net_menu() {
  net_detect_stack
  net_detect_complexity
  net_cfg_load

  local stack_label="${NET_STACK_HUMAN}"
  local ssh_label="no"
  net_is_ssh && ssh_label="YES"

  local switch_label="🔁 Switch manager (prepare/apply/rollback)"

  ui_menu "$NET_TITLE" "OS: ${NET_OS_ID}
Stack: $stack_label
SSH: $ssh_label

Choose:" \
    "IFACES"   "🔌 Interfaces and addresses" \
    "ROUTES"   "🧭 Routing table" \
    "DNS"      "🧠 DNS status and resolvers" \
    "VPN"      "🕵️  VPN and overlays (Tailscale/WireGuard/etc)" \
    "LOGSET"   "📏 Set log lines (currently: ${NET_LOG_LINES:-200})" \
    "LOGS"     "📜 Network logs" \
    "RENEW"    "♻️  Renew DHCP lease" \
    "RESTART"  "🔄 Restart networking" \
    "CONFIG"   "📝 Open config file (edit only)" \
    "SWITCH"   "$switch_label" \
    "BACK"     "🔙 Back"
}

module_NETWORK() {
  while true; do
    local sel
    sel="$(net_menu)" || return 0
    [[ -z "$sel" || "$sel" == "BACK" ]] && return 0

    case "$sel" in
      IFACES)  net_ifaces_screen ;;
      ROUTES)  net_routes_screen ;;
      DNS)     net_dns_screen ;;
      VPN)     net_vpn_screen ;;
      LOGSET)  net_set_log_lines ;;
      LOGS)    net_logs_screen ;;
      RENEW)   net_renew_dhcp ;;
      RESTART) net_restart_networking ;;
      CONFIG)  net_open_config ;;
      SWITCH)  net_switch_dispatch ;;
      *) ui_msg "$NET_TITLE" "Unknown selection: $sel" ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Register (Ubuntu + Debian)
# -----------------------------------------------------------------------------
if net_supported_os; then
  register_module "$module_id" "$module_title" "module_NETWORK"
fi
