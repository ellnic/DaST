#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Library: dast_config (v0.9.8.4)
# DaST lib: dast_config.sh (v0.9.8).
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
# DaST requires bash. This library is intended to be sourced by DaST.
# ---------------------------------------------------------------------------------------
#
# Header notes (from original file):
#
# DaST lib: dast_config.sh (v0.9.8)
# Purpose: early, safe config path resolution + simple key reads
#
# Notes
# - This file must remain safe to source very early.
# - No eval. No command substitution from config values.
# - Hostile/TTY runtime overrides (like emoji off) must NOT write back to config.
# Resolve config paths in a way that matches DaST_v0.9.8.sh expectations.
# The main launcher typically sets SCRIPT_DIR and APP_DIR, but this lib may be
# sourced before those are established.
#

dast_cfg__resolve_paths() {
  # Derive SCRIPT_DIR if missing.
  if [[ -z "${SCRIPT_DIR:-}" ]]; then
    # Best effort: resolve relative to the currently sourced file.
    # shellcheck disable=SC2128
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" ]]; then
      SCRIPT_DIR="$(cd -- "$(dirname -- "$src")/.." 2>/dev/null && pwd -P || pwd -P)"
    else
      SCRIPT_DIR="$(pwd -P)"
    fi
  fi

  # APP_DIR mirrors SCRIPT_DIR in v0.9.8.
  : "${APP_DIR:="${SCRIPT_DIR}"}"

  # Config directory and file defaults.
  : "${CFG_DIR:="${APP_DIR}/config"}"
  : "${CFG_FILE:="${CFG_DIR}/dast.conf"}"
}

# Normalise a dialog tuple like "(WHITE,MAGENTA,ON)" into "(WHITE, MAGENTA, ON)".
# This is intentionally conservative and does not validate tokens against dialog's
# supported names. It only normalises spacing.
dast_cfg_normalise_tuple() {
  local s="${1:-}"
  # Ensure commas have a single trailing space.
  s="${s//,/,\ }"
  # Collapse repeated spaces.
  while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done
  printf '%s' "$s"
}

# Read a key from config safely (last occurrence wins).
# - Ignores comments and blank lines.
# - Returns DEFAULT if key not found or file unreadable.
# - Rejects values containing '${...}' to avoid expansion surprises.
dast_cfg_get_early() {
  local key="${1:-}"
  local def="${2:-}"
  local conf="${3:-}"

  [[ -n "$key" ]] || { printf '%s' "$def"; return 0; }

  if [[ -z "$conf" ]]; then
    dast_cfg__resolve_paths
    conf="${CFG_FILE:-}"
  fi

  [[ -r "$conf" ]] || { printf '%s' "$def"; return 0; }

  local val
  val="$(
    awk -F= -v k="$key" '
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*$/ {next}
      {
        # Trim key field
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
        if ($1==k) {
          $1=""
          sub(/^=/, "", $0)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
          v=$0
        }
      }
      END{ if (v!="") print v }
    ' "$conf" 2>/dev/null
  )"

  # Disallow embedded expansions. Keep it simple and safe.
  if [[ "$val" == *'${'*'}'* ]]; then
    val=""
  fi

  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$def"
  fi
}

# Ensure defaults are available immediately on source.
dast_cfg__resolve_paths

UI_SANITISE_TITLES="${UI_SANITISE_TITLES:-auto}"
