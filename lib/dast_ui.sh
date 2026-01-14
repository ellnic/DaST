#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Library: dast_ui (v0.9.8.4)
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
# DaST lib: ui wrappers (v0.9.8.4)
# Provides:
#   - dast_ui_clear
#   - dast_ui_msgbox TITLE TEXT
#
# Sourced by:
#   - core (dast.sh) and modules (safe standalone)
#
# Notes:
#   Minimal shared wrappers. Existing scripts can continue calling dialog directly.
#

dast_ui_clear() { clear || true; }

ui__strip_icon_prefix_for_menu_label() {
  # For menu/list labels only: remove known icon tokens and any leftover leading space.
  # This fixes the TTY/emoji-off alignment issue where labels were constructed as ICON + space + TEXT.
  local s="$1" out
  out="$(ui_strip_known_icons_anywhere "$s")"
  # Only trim leading whitespace if it was introduced by stripping.
  if [[ "$s" != "$out" && ! "$s" =~ ^[[:space:]] && "$out" =~ ^[[:space:]] ]]; then
    out="${out#"${out%%[![:space:]]*}"}"
  fi
  printf '%s' "$out"
}
ui__normalise_menu_label() {
  # For menu/list labels only:
  # - Trim outer whitespace
  # - If label begins with a known DaST icon token:
  #     * UI_EMOJI=1: ensure exactly one space between ICON and TEXT
  #     * UI_EMOJI=0: strip ICON and any boundary whitespace cleanly
  #
  # This avoids the "phantom gap" effect in hostile TTY while also keeping labels tidy
  # when emoji are enabled.
  local s="$1" token rest stripped

  # Trim outer whitespace first
  s="$(printf '%s' "$s" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"

  # Nothing to do if empty or no spaces
  [[ -z "$s" || "$s" != *[[:space:]]* ]] && { printf '%s' "$s"; return; }

  token="${s%%[[:space:]]*}"
  rest="${s#"$token"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"  # trim leading spaces

  # Only treat the prefix as an icon if it is a *known* DaST icon token
  if declare -F ui_strip_known_icons_anywhere >/dev/null 2>&1; then
    stripped="$(ui_strip_known_icons_anywhere "$token")"
    if [[ "$stripped" != "$token" ]]; then
      if [[ "${UI_EMOJI:-1}" -eq 0 ]]; then
        printf '%s' "$rest"
        return
      else
        [[ -n "$rest" ]] && printf '%s %s' "$token" "$rest" || printf '%s' "$token"
        return
      fi
    fi
  fi

  # Default: return trimmed original
  printf '%s' "$s"
}


dast_ui_msgbox() {
  local title="$(ui_sanitise_title "${1:-DaST}")" text="${2:-}"
  dialog --backtitle "DaST" --title "$title" --msgbox "$text" 14 80
}

dast_ui_dialog() {
  # Thin wrapper around dialog that sanitises --title (Option A).
  # Preserves args, return codes, and any caller fd redirection.
  local args=("$@") i
  # When emoji/icons are disabled, strip DaST icon tokens from menu/list item labels only.
  # Do not rewrite every arg, as that can leave leading padding behind (ICON removed, space kept).
  # Normalise DaST icon prefixes for menu/list item labels only.
# - UI_EMOJI=1: enforce exactly one space between ICON and TEXT
# - UI_EMOJI=0: strip ICON and boundary whitespace cleanly
if declare -F ui__normalise_menu_label >/dev/null 2>&1; then
  local mode="" mode_idx=-1 first k
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      --menu|--radiolist|--checklist)
        mode="${args[i]}"; mode_idx=$i; break
        ;;
    esac
  done

  if [[ -n "$mode" ]]; then
    first=$((mode_idx + 5))
    case "$mode" in
      --menu)
        for ((k=first; k+1<${#args[@]}; k+=2)); do
          args[k+1]="$(ui__normalise_menu_label "${args[k+1]}")"
        done
        ;;
      --radiolist|--checklist)
        for ((k=first; k+2<${#args[@]}; k+=3)); do
          args[k+1]="$(ui__normalise_menu_label "${args[k+1]}")"
        done
        ;;
    esac
  fi
  fi
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[i]}" == "--title" ]]; then
      if (( i+1 < ${#args[@]} )); then
        args[i+1]="$(ui_sanitise_title "${args[i+1]}")"
      fi
    elif [[ "${args[i]}" == --title=* ]]; then
      args[i]="--title=$(ui_sanitise_title "${args[i]#--title=}")"
    fi
  done


  # Default EXIT label for view-only boxes (prevents theme default like EXIT)
  # dialog uses EXIT label for textbox/tailbox/programbox/prgbox, not OK label.
  local _has_exit_label=0 _is_viewbox=0
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      --exit-label|--exit-label=*) _has_exit_label=1 ;;
      --textbox|--tailbox|--programbox|--progressbox|--prgbox) _is_viewbox=1 ;;
    esac
  done

  if [[ $_is_viewbox -eq 1 && $_has_exit_label -eq 0 ]]; then
    args=(--exit-label "Back" "${args[@]}")
  fi

  # Safety policy: ALWAYS default to NO for yes/no prompts, even if the caller forgot.
  local _is_yesno=0 _has_defaultno=0 _has_yes_label=0 _has_no_label=0
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      --yesno) _is_yesno=1 ;;
      --defaultno) _has_defaultno=1 ;;
      --yes-label|--yes-label=*) _has_yes_label=1 ;;
      --no-label|--no-label=*) _has_no_label=1 ;;
    esac
  done
  if [[ $_is_yesno -eq 1 ]]; then
    [[ $_has_defaultno -eq 0 ]] && args=(--defaultno "${args[@]}")
    [[ $_has_yes_label -eq 0 ]] && args=(--yes-label "Yes" "${args[@]}")
    [[ $_has_no_label -eq 0 ]] && args=(--no-label "No" "${args[@]}")
  fi

  # Clamp common dialog dimensions to the current terminal size.
  local term_h term_w max_h max_w _mode _mi _h _w _lh
  term_h="$(tput lines 2>/dev/null || echo 24)"
  term_w="$(tput cols  2>/dev/null || echo 80)"
  [[ "$term_h" =~ ^[0-9]+$ ]] || term_h=24
  [[ "$term_w" =~ ^[0-9]+$ ]] || term_w=80
  max_h=$(( term_h - 4 )); max_w=$(( term_w - 4 ))
  (( max_h < 10 )) && max_h=10
  (( max_w < 40 )) && max_w=40

  _mode=""; _mi=-1
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      --msgbox|--yesno|--inputbox|--passwordbox|--passwordform|--editbox|--form|--textbox|--tailbox|--programbox|--progressbox|--prgbox|--menu|--radiolist|--checklist)
        _mode="${args[i]}"; _mi=$i; break
        ;;
    esac
  done

  case "$_mode" in
    --msgbox|--yesno)
      _h="${args[_mi+2]}"; _w="${args[_mi+3]}"
      ;;
    --inputbox|--passwordbox|--passwordform|--editbox|--form)
      _h="${args[_mi+2]}"; _w="${args[_mi+3]}"
      ;;
    --textbox|--tailbox|--programbox|--progressbox|--prgbox)
      _h="${args[_mi+2]}"; _w="${args[_mi+3]}"
      ;;
    --menu|--radiolist|--checklist)
      _h="${args[_mi+2]}"; _w="${args[_mi+3]}"; _lh="${args[_mi+4]}"
      ;;
  esac

  if [[ "${_h:-}" =~ ^[0-9]+$ && "${_w:-}" =~ ^[0-9]+$ ]]; then
    (( _h > 0 && _h > max_h )) && _h=$max_h
    (( _w > 0 && _w > max_w )) && _w=$max_w

    case "$_mode" in
      --msgbox|--yesno|--inputbox|--passwordbox|--passwordform|--editbox|--form|--textbox|--tailbox|--programbox|--progressbox|--prgbox)
        args[_mi+2]="${_h}"
        args[_mi+3]="${_w}"
        ;;
      --menu|--radiolist|--checklist)
        if [[ "${_lh:-}" =~ ^[0-9]+$ ]]; then
          (( _lh > _h - 8 )) && _lh=$(( _h - 8 ))
          (( _lh < 6 )) && _lh=6
          args[_mi+4]="${_lh}"
        fi
        args[_mi+2]="${_h}"
        args[_mi+3]="${_w}"
        ;;
    esac
  fi

  # DaST-wide output:
  # To make output capture reliable across the project, we force --stdout unless the
  # caller already specified an output directive.
  local _has_output=0
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      --stdout|--stderr|--output-fd|--output-fd=*)
        _has_output=1
        break
        ;;
    esac
  done

  if [[ $_has_output -eq 1 ]]; then
    dialog "${args[@]}"
  else
    dialog --stdout "${args[@]}"
  fi
}


ui_sanitise_title() {
  local t="$1"
  if [[ "${DAST_HOSTILE_TTY:-0}" = "1" && "${UI_SANITISE_TITLES}" != "off" ]]; then
    t="$(printf '%s' "$t" | LC_ALL=C tr -cd '\11\12\15\40-\176')"
    t="$(printf '%s' "$t" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  fi
  printf '%s' "$t"
}
