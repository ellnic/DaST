#!/usr/bin/env bash

# ---------------------------------------------------------------------------------------
# DaST Module: Docker (v0.9.8.4)
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

module_id="DOCKER"
module_title="🐳 Docker"
DOCKER_TITLE="🐳 Docker"



# -----------------------------------------------------------------------------
# Logging helpers (standard always, debug only when --debug)
# -----------------------------------------------------------------------------
if ! declare -F dast_log >/dev/null 2>&1; then
  dast_log() { :; }
fi
if ! declare -F dast_dbg >/dev/null 2>&1; then
  dast_dbg() { :; }
fi
# -----------------------------
# DaST logging/debug dirs (app-local, no /tmp fallback)
# -----------------------------
_docker__module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_docker__app_dir="$(cd "$_docker__module_dir/.." && pwd)"

DOCKER_LOG_DIR="${LOG_DIR:-"$_docker__app_dir/logs"}"
DOCKER_DEBUG_DIR="${DEBUG_DIR:-"$_docker__app_dir/debug"}"

# Create dirs and repair ownership similarly to config dir behaviour
mkdir -p "$DOCKER_LOG_DIR" 2>/dev/null || true
if [[ "${DAST_DEBUG:-0}" -eq 1 ]]; then
  mkdir -p "$DOCKER_DEBUG_DIR" 2>/dev/null || true
fi
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  # If the app lives under the invoking user's home, keep logs/debug owned by them
  case "$_docker__app_dir" in
    "/home/$SUDO_USER"/*)
      chown "$SUDO_USER:$SUDO_USER" "$DOCKER_LOG_DIR" 2>/dev/null || true
      [[ -d "$DOCKER_DEBUG_DIR" ]] && chown "$SUDO_USER:$SUDO_USER" "$DOCKER_DEBUG_DIR" 2>/dev/null || true
      ;;
  esac
fi

docker__log() { 
  if declare -F dast_log >/dev/null 2>&1; then
    dast_log "$@"
  else
    printf '%s [%s] %s\n' "$(date '+%F %T')" "${1:-INFO}" "${*:2}" >>"$DOCKER_LOG_DIR/dast.log" 2>/dev/null || true
  fi
}

docker__dbg() {
  if declare -F dast_dbg >/dev/null 2>&1; then
    dast_dbg "$@"
  elif [[ "${DAST_DEBUG:-0}" == "1" ]]; then
    printf '%s [DEBUG] %s\n' "$(date '+%F %T')" "$*" >>"$DOCKER_DEBUG_DIR/dast.debug.log" 2>/dev/null || true
  fi
}

# -----------------------------
# Small helpers (local only)
# -----------------------------
_have() { command -v "$1" >/dev/null 2>&1; }

_is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

_bytes_human() {
  local b="$1"
  awk -v b="$b" 'function human(x){
    s="B KiB MiB GiB TiB PiB"; split(s,a," ");
    i=1; while (x>=1024 && i<6){x/=1024; i++}
    return sprintf("%.2f %s", x, a[i])
  } BEGIN{ if (b<0) b=0; print human(b) }'
}

_dir_size_bytes() {
  local d="$1"
  [[ -d "$d" ]] || { echo 0; return 0; }
  du -sb "$d" 2>/dev/null | awk '{print $1}' | head -n1
}

_count_files() {
  local d="$1"
  [[ -d "$d" ]] || { echo 0; return 0; }
  find "$d" -xdev -type f 2>/dev/null | wc -l | tr -d ' '
}

_confirm_danger() {
  local title="$1"
  local msg="$2"
  ui_yesno "$title" "$msg

Default is No."
}

_ui_input() {
  # _ui_input "TITLE" "PROMPT" "DEFAULT"
  local title="$1"
  local prompt="$2"
  local def="${3:-}"

  # DaST policy: unified dialog layer only.
  ui_input "$title" "$prompt" "$def"
}


# -----------------------------
# Detect optional features
# -----------------------------
has_journalctl() { _have journalctl && [[ -d /run/systemd/system || -r /proc/1/comm ]]; }
has_logrotate() { _have logrotate && [[ -r /etc/logrotate.conf ]]; }
has_apport_crash_dir() { [[ -d /var/crash ]]; }
has_systemd_coredump_dir() { [[ -d /var/lib/systemd/coredump ]]; }
has_coredumpctl() { _have coredumpctl; }

has_docker() {
  _have docker || return 1
  # Don't require daemon access just to show menu, but we will warn later if it cannot talk to dockerd.
  return 0
}

docker_daemon_ok() {
  # Fast health check: avoid long stalls if the daemon is down or the socket is inaccessible.
  if [[ "$(id -u)" -ne 0 ]]; then
    if [[ -S /var/run/docker.sock ]] && [[ ! -r /var/run/docker.sock || ! -w /var/run/docker.sock ]]; then
      return 1
    fi
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout 3 docker info >/dev/null 2>&1
  else
    docker info >/dev/null 2>&1
  fi
}


# -----------------------------
# Docker helpers
# -----------------------------
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return 0
  fi
  if _have docker-compose; then
    echo "docker-compose"
    return 0
  fi
  return 1
}

dast_ts() { date +"%Y%m%d_%H%M%S"; }

dast_backup_dir_for() {
  # $1 = base dir
  local base="$1"
  echo "$base/.dast_backups/$(dast_ts)"
}

dast_backup_file() {
  # $1 = file path
  local f="$1"
  [[ -f "$f" ]] || return 1
  local dir
  dir="$(dast_backup_dir_for "$(dirname "$f")")"
  mkdir -p "$dir" || return 1
  cp -a "$f" "$dir/" || return 1
  return 0
}

pick_container() {
  local title="${1:-$DOCKER_TITLE}"
  local prompt="${2:-Select a container:}"

  local lines
  lines="$(docker ps -a --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null || true)"
  if [[ -z "$lines" ]]; then
    ui_msg "$title" "No containers found."
    return 1
  fi

  local items=()
  local id name status image
  while IFS='|' read -r id name status image; do
    [[ -z "$id" ]] && continue
    items+=("$id" "📦 $name | $status | $image")
  done <<<"$lines"

  ui_menu "$title" "$prompt" "${items[@]}" "BACK" "⬅ Back"
}

pick_volume() {
  local title="${1:-$DOCKER_TITLE}"
  local prompt="${2:-Select a volume:}"

  local vols
  vols="$(docker volume ls -q 2>/dev/null || true)"
  if [[ -z "$vols" ]]; then
    ui_msg "$title" "No volumes found."
    return 1
  fi

  local items=()
  local v
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    items+=("$v" "🧊 $v")
  done <<<"$vols"

  ui_menu "$title" "$prompt" "${items[@]}" "BACK" "⬅ Back"
}

pick_network() {
  local title="${1:-$DOCKER_TITLE}"
  local prompt="${2:-Select a network:}"

  local nets
  nets="$(docker network ls --format '{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}' 2>/dev/null || true)"
  if [[ -z "$nets" ]]; then
    ui_msg "$title" "No networks found."
    return 1
  fi

  local items=()
  local id name driver scope
  while IFS='|' read -r id name driver scope; do
    [[ -z "$id" ]] && continue
    items+=("$id" "🕸 $name | $driver | $scope")
  done <<<"$nets"

  ui_menu "$title" "$prompt" "${items[@]}" "BACK" "⬅ Back"
}

find_compose_projects() {
  # Output: unique directories containing compose files
  local roots=()

  if [[ -n "${DAST_DOCKER_STACK_DIRS:-}" ]]; then
    IFS=':' read -r -a roots <<<"$DAST_DOCKER_STACK_DIRS"
  else
    # Conservative defaults to avoid crawling the whole disk
    roots=(/opt /srv "$HOME")
  fi

  local found=()
  local r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    while IFS= read -r f; do
      found+=("$(dirname "$f")")
    done < <(find "$r" -maxdepth 4 -type f \( -name "compose.yml" -o -name "compose.yaml" -o -name "docker-compose.yml" -o -name "docker-compose.yaml" \) 2>/dev/null | head -n 200)
  done

  if (( ${#found[@]} == 0 )); then
    return 1
  fi

  printf "%s\n" "${found[@]}" | sort -u
}

pick_compose_project() {
  local title="${1:-$DOCKER_TITLE}"
  local prompt="${2:-Select a compose project:}"

  local projects
  projects="$(find_compose_projects || true)"
  if [[ -z "$projects" ]]; then
    ui_msg "$title" "No compose projects found.

Tip:
- Set DAST_DOCKER_STACK_DIRS to a colon-separated list of stack roots.
  Example: /opt/stacks:/srv/docker:$HOME/docker"
    return 1
  fi

  local items=()
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    items+=("$p" "🧱 $p")
  done <<<"$projects"

  ui_menu "$title" "$prompt" "${items[@]}" "BACK" "⬅ Back"
}

pick_compose_service() {
  # $1 = project dir
  local proj="$1"
  local cc
  cc="$(compose_cmd || true)"
  if [[ -z "$cc" ]]; then
    ui_msg "$DOCKER_TITLE" "Compose not detected (docker compose / docker-compose missing)."
    return 1
  fi
  [[ -d "$proj" ]] || return 1

  local services
  services="$(cd "$proj" && $cc config --services 2>/dev/null || true)"
  if [[ -z "$services" ]]; then
    ui_msg "$DOCKER_TITLE" "Could not detect services for:
$proj"
    return 1
  fi

  local items=()
  local s
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    items+=("$s" "🔧 $s")
  done <<<"$services"

  ui_menu "$DOCKER_TITLE" "Select a service:" "${items[@]}" "BACK" "⬅ Back"
}


# -----------------------------
# UI: main menu
# -----------------------------
maintenance_menu() {
  local items=(
    "TMP_VIEW"   "🧺 View temp usage (/tmp, /var/tmp)"
    "TMP_CLEAN"  "🧹 Clean temp files (age-based, safe-ish)"
    "JOURNAL"    "📰 Systemd journal maintenance (vacuum)"
    "LOGROTATE"  "🔁 Force logrotate now"
    "CRASH"      "💥 Clear crash reports (/var/crash)"
    "COREDUMP"   "🧠 Clear core dumps (systemd-coredump)"
    "APT"        "📦 APT cleanup (cache, autoclean, autoremove)"
    "DOCKER"     "🐳 Docker cleanup (only if detected)"
    "BACK"       "🔙️ Back"
  )

  # If docker is not present, keep the entry but make it obvious
  if ! has_docker; then
    items=(
      "TMP_VIEW"   "🧺 View temp usage (/tmp, /var/tmp)"
      "TMP_CLEAN"  "🧹 Clean temp files (age-based, safe-ish)"
      "JOURNAL"    "📰 Systemd journal maintenance (vacuum)"
      "LOGROTATE"  "🔁 Force logrotate now"
      "CRASH"      "💥 Clear crash reports (/var/crash)"
      "COREDUMP"   "🧠 Clear core dumps (systemd-coredump)"
      "APT"        "📦 APT cleanup (cache, autoclean, autoremove)"
      "DOCKER"     "🐳 Docker cleanup (not detected)"
      "BACK"       "🔙️ Back"
    )
  fi
  ui_menu "$DOCKER_TITLE" "Pick a maintenance task:" "${items[@]}"
}

# -----------------------------
# Temp: view + clean
# -----------------------------
tmp_view() {
  local t1b t2b t1h t2h
  t1b="$(_dir_size_bytes /tmp)"
  t2b="$(_dir_size_bytes /var/tmp)"
  t1h="$(_bytes_human "$t1b")"
  t2h="$(_bytes_human "$t2b")"

  ui_msg "Temp usage" "/tmp:     $t1h
/var/tmp: $t2h

Note:
- Cleaning temp can remove leftovers from crashed apps.
- It can also remove temp files that an app still expects.
Use the age-based cleaner to reduce risk."
}

tmp_clean_picker() {
  ui_menu "$DOCKER_TITLE" "Choose a temp clean policy (age-based):" \
    "AGE_1"   "🧽 Delete files older than 1 day (more aggressive)" \
    "AGE_3"   "🧺 Delete files older than 3 days (recommended)" \
    "AGE_7"   "🧼 Delete files older than 7 days (safer)" \
    "BACK"    "🔙️ Back"
}

tmp_clean_run() {
  local days="$1"

  local before_tmp before_vtmp after_tmp after_vtmp
  before_tmp="$(_dir_size_bytes /tmp)"
  before_vtmp="$(_dir_size_bytes /var/tmp)"

  if ! _confirm_danger "Confirm temp cleanup" "This will delete files under:
- /tmp
- /var/tmp

Policy: delete regular files older than ${days} day(s).

This is usually safe, but can break badly-written apps that keep state in /tmp.

Proceed?"; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  # Directories: we only delete empty dirs older than N days to avoid nuking active trees.
  # Files: delete regular files older than N days.
  if _is_root; then
    run_sh "find /tmp /var/tmp -xdev -type f -mtime +$days -print -delete 2>/dev/null || true"
    run_sh "find /tmp /var/tmp -xdev -type d -empty -mtime +$days -print -delete 2>/dev/null || true"
  else
    ui_msg "Need root" "Temp cleanup needs root to be meaningful.
Please run DaST as root (or with sudo)."
    return 1
  fi

  after_tmp="$(_dir_size_bytes /tmp)"
  after_vtmp="$(_dir_size_bytes /var/tmp)"

  ui_msg "Done" "Temp cleanup complete (>${days} day(s)).

Before:
- /tmp     $(_bytes_human "$before_tmp")
- /var/tmp $(_bytes_human "$before_vtmp")

After:
- /tmp     $(_bytes_human "$after_tmp")
- /var/tmp $(_bytes_human "$after_vtmp")"
}

# -----------------------------
# Journalctl vacuum
# -----------------------------
journal_menu() {
  if ! has_journalctl; then
    ui_msg "Not available" "systemd journal tools not detected (journalctl).
Nothing to do here."
    return 1
  fi

  ui_menu "$DOCKER_TITLE" "systemd journal maintenance:" \
    "J_USAGE"     "📏 Show journal disk usage" \
    "J_SIZE_100"  "🧽 Vacuum to 100M" \
    "J_SIZE_500"  "🧺 Vacuum to 500M (recommended)" \
    "J_SIZE_1G"   "🧼 Vacuum to 1G" \
    "J_TIME_7"    "📅 Vacuum older than 7 days" \
    "J_TIME_30"   "📅 Vacuum older than 30 days" \
    "BACK"        "🔙️ Back"
}

journal_run() {
  local action="$1"

  case "$action" in
    J_USAGE)
      ui_msg "Journal usage" "$(journalctl --disk-usage 2>&1)"
      return 0
      ;;
  esac

  if ! _is_root; then
    ui_msg "Need root" "Journal maintenance needs root.
Please run DaST as root (or with sudo)."
    return 1
  fi

  local cmd desc
  case "$action" in
    J_SIZE_100) cmd="journalctl --vacuum-size=100M"; desc="Vacuum journal to 100M";;
    J_SIZE_500) cmd="journalctl --vacuum-size=500M"; desc="Vacuum journal to 500M";;
    J_SIZE_1G)  cmd="journalctl --vacuum-size=1G";   desc="Vacuum journal to 1G";;
    J_TIME_7)   cmd="journalctl --vacuum-time=7d";   desc="Vacuum journal older than 7 days";;
    J_TIME_30)  cmd="journalctl --vacuum-time=30d";  desc="Vacuum journal older than 30 days";;
    *) return 1;;
  esac

  if ! _confirm_danger "Confirm journal vacuum" "$desc?

This removes old logs. That is usually fine, but if you are mid-investigation, don't do it."; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  local before after out
  before="$(journalctl --disk-usage 2>&1)"
  out="$(bash -c "$cmd" 2>&1 || true)"
  after="$(journalctl --disk-usage 2>&1 || true)"

  ui_msg "Done" "$desc complete.

Before:
$before

Output:
$out

After:
$after"
}

# -----------------------------
# Logrotate
# -----------------------------
logrotate_run() {
  if ! has_logrotate; then
    ui_msg "Not available" "logrotate not found or /etc/logrotate.conf missing."
    return 1
  fi

  if ! _is_root; then
    ui_msg "Need root" "Forcing logrotate needs root.
Please run DaST as root (or with sudo)."
    return 1
  fi

  if ! _confirm_danger "Confirm logrotate" "This will force logrotate across the system:
logrotate -f /etc/logrotate.conf

It is usually safe. Worst case, some logs rotate earlier than expected.

Proceed?"; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  local out
  out="$(logrotate -f /etc/logrotate.conf 2>&1 || true)"
  ui_msg "Done" "Forced logrotate complete.

Output:
$out"
}

# -----------------------------
# Crash reports
# -----------------------------
crash_clear_run() {
  if ! has_apport_crash_dir; then
    ui_msg "Not available" "/var/crash not found. (Apport crash reports not present.)"
    return 1
  fi

  local cnt sz
  cnt="$(_count_files /var/crash)"
  sz="$(_bytes_human "$(_dir_size_bytes /var/crash)")"

  if (( cnt == 0 )); then
    ui_msg "Nothing to clear" "/var/crash exists but appears empty."
    return 0
  fi

  if ! _is_root; then
    ui_msg "Need root" "Clearing /var/crash needs root."
    return 1
  fi

  if ! _confirm_danger "Confirm crash report cleanup" "This will delete crash reports in /var/crash.

Files: $cnt
Size:  $sz

If you need them for debugging, do not delete them.

Proceed?"; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  run_sh "rm -f /var/crash/* 2>/dev/null || true"
  ui_msg "Done" "Crash reports cleared from /var/crash."
}

# -----------------------------
# Core dumps
# -----------------------------
coredump_run() {
  local present=0
  has_systemd_coredump_dir && present=1
  has_coredumpctl && present=1

  if (( present == 0 )); then
    ui_msg "Not available" "No systemd core dump support detected."
    return 1
  fi

  if ! _is_root; then
    ui_msg "Need root" "Clearing core dumps needs root."
    return 1
  fi

  local hint="This will remove stored core dumps.
This is destructive (by design) and can remove evidence needed for debugging."

  if ! _confirm_danger "Confirm core dump purge" "$hint

Proceed?"; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  local out=""
  if has_coredumpctl; then
    out+="coredumpctl:\n"
    out+="$(coredumpctl purge 2>&1 || true)\n"
  fi

  if has_systemd_coredump_dir; then
    out+="\nFilesystem:\n"
    run_sh "rm -f /var/lib/systemd/coredump/* 2>/dev/null || true"
    out+="Removed files in /var/lib/systemd/coredump (if any).\n"
  fi

  ui_msg "Done" "Core dump purge complete.

$out"
}

# -----------------------------
# APT cleanup
# -----------------------------
apt_menu() {
  if ! _have apt-get; then
    ui_msg "Not available" "apt-get not found."
    return 1
  fi

  ui_menu "$DOCKER_TITLE" "APT cleanup options:" \
    "APT_CLEAN"     "🧽 apt-get clean (clear package cache)" \
    "APT_AUTOCLEAN" "🧺 apt-get autoclean (remove obsolete cache)" \
    "APT_AUTOREMOVE" "🧹 apt-get autoremove --purge (remove unused deps)" \
    "BACK"          "🔙️ Back"
}

apt_run() {
  local action="$1"

  if ! _is_root; then
    ui_msg "Need root" "APT maintenance needs root."
    return 1
  fi

  local cmd desc
  case "$action" in
    APT_CLEAN) cmd="apt-get clean"; desc="APT clean";;
    APT_AUTOCLEAN) cmd="apt-get autoclean"; desc="APT autoclean";;
    APT_AUTOREMOVE) cmd="apt-get autoremove --purge -y"; desc="APT autoremove --purge";;
    *) return 1;;
  esac

  local warn="Command:
$cmd"

  if [[ "$action" == "APT_AUTOREMOVE" ]]; then
    warn+="

This can remove packages you no longer use, but sometimes surprises happen
(especially on systems with niche drivers or meta-packages).
Read the output carefully."
  fi

  if ! _confirm_danger "Confirm APT action" "$warn

Proceed?"; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  local out
  out="$(bash -c "$cmd" 2>&1 || true)"
  ui_msg "Done" "$desc complete.

Output:
$out"
}

# -----------------------------
# Docker cleanup (only if detected)
# -----------------------------
docker_menu() {
  if ! has_docker; then
    ui_msg "Not available" "Docker not detected (docker command missing)."
    return 1
  fi

  ui_menu "$DOCKER_TITLE" "Docker:" \
    "OVERVIEW"   "🔎 Overview and health" \
    "CONTAINERS" "📦 Containers (start/stop/logs/exec)" \
    "STACKS"     "🧱 Compose projects/stacks" \
    "EDIT"       "📝 Edit compose/.env/configs (with backups)" \
    "IMAGES"     "🖼️  Images (pull/remove/prune)" \
    "VOLUMES"    "🧊 Volumes (inspect/backup/cleanup)" \
    "NETWORKS"   "🌐 Networks (inspect/cleanup)" \
    "PORTAINER"  "🧭 Portainer Agent (install/manage)" \
    "UPDATER"    "🔄 Auto-updater (Watchtower) with caveats" \
    "DAEMON"     "🛠️  Docker daemon controls" \
    "CLEANUP"    "🧽 Cleanup/prune tools" \
    "BACK"       "🔙️ Back"
}

docker_cleanup_menu() {
  if ! has_docker; then
    ui_msg "Not available" "Docker not detected (docker command missing)."
    return 1
  fi

  ui_menu "$DOCKER_TITLE" "Docker cleanup:" \
    "D_DF"         "📏 Show docker disk usage (docker system df)" \
    "D_IMG"        "🧽 Prune unused images (safe-ish)" \
    "D_CONT"       "🧺 Prune stopped containers" \
    "D_NET"        "🧼 Prune unused networks" \
    "D_VOL"        "🧨 Prune unused volumes (danger)" \
    "D_SYSTEM"     "🧨 System prune (danger)" \
    "D_SYSTEM_VOL" "☢️ System prune + volumes (very danger)" \
    "BACK"         "🔙️ Back" 
}



docker_overview() {
  local out
  out="$(docker info 2>/dev/null | sed -n '1,40p' || true)"
  out+="

Containers:
$(docker ps --format '  - {{.Names}} ({{.Status}})' 2>/dev/null | head -n 30 || true)"

  local unhealthy
  unhealthy="$(docker ps --filter health=unhealthy --format '{{.Names}} | {{.Status}}' 2>/dev/null || true)"
  if [[ -n "$unhealthy" ]]; then
    out+="

Unhealthy containers:
$unhealthy"
  fi

  out+="

Disk usage:
$(docker system df 2>/dev/null || true)"

  ui_msg "$DOCKER_TITLE" "$out"
}

docker_container_menu() {
  ui_menu "$DOCKER_TITLE" "Container actions:" \
    "C_PICK"   "📦 Select container" \
    "C_LIST"   "📋 List containers (ps -a)" \
    "C_STATS"  "📈 Live stats (docker stats)" \
    "BACK"     "🔙️ Back"
}

docker_container_run() {
  local a="$1"
  case "$a" in
    C_LIST)
      ui_msg "$DOCKER_TITLE" "$(docker ps -a 2>/dev/null || true)"
      return 0
      ;;
    C_STATS)
      ui_msg "$DOCKER_TITLE" "Press Ctrl+C to stop stats."
      docker stats
      return 0
      ;;
    C_PICK)
      ;;
    *) return 1;;
  esac

  local cid
  cid="$(pick_container "$DOCKER_TITLE" "Select a container:")" || return 0
  [[ "$cid" == "BACK" ]] && return 0

  local name
  name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || echo "$cid")"

  while true; do
    local act
    act="$(ui_menu "$DOCKER_TITLE" "📦 $name" \
      "START"   "▶️ Start" \
      "STOP"    "⏹️ Stop" \
      "RESTART" "🔄 Restart" \
      "LOGS"    "📜 Logs (tail)" \
      "FOLLOW"  "📜 Logs (follow)" \
      "EXEC"    "🖥 Exec shell" \
      "INSPECT" "🔎 Inspect (summary)" \
      "RM"      "🗑 Remove (stopped only)" \
      "BACK"    "🔙️ Back")" || return 0

    case "$act" in
      START) docker start "$cid" >/dev/null 2>&1; ui_msg "$DOCKER_TITLE" "Started $name";;
      STOP) docker stop "$cid" >/dev/null 2>&1; ui_msg "$DOCKER_TITLE" "Stopped $name";;
      RESTART) docker restart "$cid" >/dev/null 2>&1; ui_msg "$DOCKER_TITLE" "Restarted $name";;
      KILL)
        if ui_yesno "$DOCKER_TITLE" "Kill container $name?

This sends SIGKILL. Use only if stop/restart won\'t work." ; then
          docker kill "$cid" >/dev/null 2>&1 || true
          ui_msg "$DOCKER_TITLE" "Killed $name"
        fi
        ;;
      PAUSE)
        docker pause "$cid" >/dev/null 2>&1 || true
        ui_msg "$DOCKER_TITLE" "Paused $name"
        ;;
      UNPAUSE)
        docker unpause "$cid" >/dev/null 2>&1 || true
        ui_msg "$DOCKER_TITLE" "Unpaused $name"
        ;;
      STATS)
        ui_msg "$DOCKER_TITLE" "$(docker stats --no-stream "$cid" 2>&1 || true)"
        ;;
      LOGS) ui_msg "$DOCKER_TITLE" "$(docker logs --tail 200 "$cid" 2>&1 | tail -n 200)";;
      FOLLOW)
        ui_msg "$DOCKER_TITLE" "Press Ctrl+C to stop following logs."
        docker logs -f --tail 50 "$cid"
        ;;
      EXEC)
        ui_msg "$DOCKER_TITLE" "Launching shell in $name.

Tip:
- Exit the shell to return."
        if docker exec "$cid" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
          docker exec -it "$cid" bash
        else
          docker exec -it "$cid" sh
        fi
        ;;
      INSPECT)
        ui_msg "$DOCKER_TITLE" "$(docker inspect "$cid" 2>/dev/null | head -n 250 || true)"
        ;;
      RM)
        local st
        st="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "true")"
        if [[ "$st" == "true" ]]; then
          ui_msg "$DOCKER_TITLE" "Refusing: container is running."
        else
          if ui_yesno "$DOCKER_TITLE" "Remove container $name?

This is destructive." ; then
            docker rm "$cid" >/dev/null 2>&1 || true
            ui_msg "$DOCKER_TITLE" "Removed $name"
            return 0
          fi
        fi
        ;;
      BACK) return 0;;
    esac
  done
}

docker_stacks_menu() {
  ui_menu "$DOCKER_TITLE" "Compose projects/stacks:" \
    "S_PICK"   "🧱 Select project" \
    "S_LIST"   "📋 List discovered projects" \
    "BACK"     "🔙️ Back"
}

docker_stacks_run() {
  local a="$1"
  local proj=""
  case "$a" in
    S_LIST)
      ui_msg "$DOCKER_TITLE" "$(find_compose_projects 2>/dev/null || echo 'No projects found.')"
      return 0
      ;;
    S_PICK) ;;
    *) return 1;;
  esac

  proj="$(pick_compose_project "$DOCKER_TITLE" "Select a compose project:")" || return 0
  [[ "$proj" == "BACK" ]] && return 0

  local cc
  cc="$(compose_cmd || true)"
  if [[ -z "$cc" ]]; then
    ui_msg "$DOCKER_TITLE" "Compose not detected (docker compose / docker-compose missing)."
    return 0
  fi

  while true; do
    local act
    act="$(ui_menu "$DOCKER_TITLE" "🧱 $proj" \
      "STATUS"  "🔎 Status" \
      "UP"      "▶️ Up (detached)" \
      "DOWN"    "⏹️ Down (stop stack)" \
      "PULLUP"  "📥 Pull then Up" \
      "RESTART" "🔄 Restart stack" \
      "SVC"     "🔧 Service actions" \
      "LOGS"    "📜 Stack logs (tail)" \
      "BACK"    "🔙️ Back")" || return 0

    case "$act" in
      STATUS)
        ui_msg "$DOCKER_TITLE" "$(cd "$proj" && $cc ps 2>/dev/null || true)"
        ;;
      UP)
        if ui_yesno "$DOCKER_TITLE" "Bring stack up (up -d) for:
$proj" ; then
          (cd "$proj" && $cc up -d 2>&1) | tail -n 200 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true
          ui_msg "$DOCKER_TITLE" "Done.

$(tail -n 200 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)"
        fi
        ;;
      DOWN)
        if ui_yesno "$DOCKER_TITLE" "Bring stack down for:
$proj

Note:
- This removes the compose network(s) for the project." ; then
          (cd "$proj" && $cc down 2>&1) | tail -n 200 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true
          ui_msg "$DOCKER_TITLE" "Done.

$(tail -n 200 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)"
        fi
        ;;
      PULLUP)
        if ui_yesno "$DOCKER_TITLE" "Pull images, then up -d for:
$proj" ; then
          (cd "$proj" && $cc pull 2>&1; $cc up -d 2>&1) | tail -n 220 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true
          ui_msg "$DOCKER_TITLE" "Done.

$(tail -n 220 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)"
        fi
        ;;
      RESTART)
        if ui_yesno "$DOCKER_TITLE" "Restart stack for:
$proj

This will cause downtime." ; then
          (cd "$proj" && $cc down 2>&1; $cc up -d 2>&1) | tail -n 220 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true
          ui_msg "$DOCKER_TITLE" "Done.

$(tail -n 220 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)"
        fi
        ;;
      LOGS)
        ui_msg "$DOCKER_TITLE" "$(cd "$proj" && $cc logs --tail 200 2>&1 | tail -n 200 || true)"
        ;;
      SVC)
        local svc
        svc="$(pick_compose_service "$proj")" || continue
        [[ "$svc" == "BACK" ]] && continue

        local sa
        sa="$(ui_menu "$DOCKER_TITLE" "🔧 $svc" \
          "S_UP"     "▶️ Start service" \
          "S_STOP"   "⏹️ Stop service" \
          "S_RESTART" "🔄 Restart service" \
          "S_LOGS"   "📜 Logs (tail)" \
          "S_EXEC"   "🖥 Exec shell" \
          "BACK"     "🔙️ Back")" || continue

        case "$sa" in
          S_UP) (cd "$proj" && $cc up -d "$svc" 2>&1) | tail -n 120 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true; ui_msg "$DOCKER_TITLE" "$(tail -n 120 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)";;
          S_STOP) (cd "$proj" && $cc stop "$svc" 2>&1) | tail -n 120 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true; ui_msg "$DOCKER_TITLE" "$(tail -n 120 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)";;
          S_RESTART) (cd "$proj" && $cc restart "$svc" 2>&1) | tail -n 120 > "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true; ui_msg "$DOCKER_TITLE" "$(tail -n 120 "$DOCKER_DEBUG_DIR/dast_docker_last.out" 2>/dev/null || true)";;
          S_LOGS) ui_msg "$DOCKER_TITLE" "$(cd "$proj" && $cc logs --tail 200 "$svc" 2>&1 | tail -n 200 || true)";;
          S_EXEC)
            ui_msg "$DOCKER_TITLE" "Launching shell in service $svc.

Tip:
- Exit the shell to return."
            (cd "$proj" && $cc exec "$svc" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1 && $cc exec "$svc" bash) || (cd "$proj" && $cc exec "$svc" sh)
            ;;
        esac
        ;;
      BACK) return 0;;
    esac
  done
}

docker_edit_menu() {
  ui_menu "$DOCKER_TITLE" "Edit compose/configs (with backups):" \
    "E_PICK" "📝 Select project to edit" \
    "BACK"   "🔙️ Back"
}

docker_edit_run() {
  local a="$1"
  [[ "$a" == "E_PICK" ]] || return 1

  local proj
  proj="$(pick_compose_project "$DOCKER_TITLE" "Select project to edit:")" || return 0
  [[ "$proj" == "BACK" ]] && return 0

  local files=()
  local f
  for f in "$proj/compose.yml" "$proj/compose.yaml" "$proj/docker-compose.yml" "$proj/docker-compose.yaml" "$proj/.env"; do
    [[ -f "$f" ]] && files+=("$f")
  done

  # Add a small set of extra configs (size-limited)
  while IFS= read -r f; do
    [[ -f "$f" ]] && files+=("$f")
  done < <(find "$proj" -maxdepth 2 -type f -size -1024k \( -name "*.conf" -o -name "*.cfg" -o -name "*.ini" -o -name "*.yml" -o -name "*.yaml" -o -name "*.json" \) 2>/dev/null | head -n 30)

  # Unique list
  mapfile -t files < <(printf "%s\n" "${files[@]}" | sort -u)

  if (( ${#files[@]} == 0 )); then
    ui_msg "$DOCKER_TITLE" "No editable config files found in:
$proj"
    return 0
  fi

  local items=()
  for f in "${files[@]}"; do
    items+=("$f" "📝 $(basename "$f")")
  done

  local target
  target="$(ui_menu "$DOCKER_TITLE" "Pick a file to edit (backup will be taken):" "${items[@]}" "BACK" "⬅ Back")" || return 0
  [[ "$target" == "BACK" || -z "$target" ]] && return 0

  if ! dast_backup_file "$target"; then
    ui_msg "$DOCKER_TITLE" "Backup failed for:
$target"
    return 0
  fi

  local editor="${EDITOR:-nano}"
  ui_msg "$DOCKER_TITLE" "Backup created.

Now opening editor:
$editor

File:
$target"
  "$editor" "$target"

  ui_msg "$DOCKER_TITLE" "Edit complete.

If this was a compose or .env change, you may need to run:
- Pull then Up
- Restart stack"
}

docker_images_menu() {
  ui_menu "$DOCKER_TITLE" "Images:" \
    "I_LIST"        "📋 List images" \
    "I_INSPECT"     "🔎 Inspect an image" \
    "I_PULL_TYPED"  "⬇ Pull image (type name/tag)" \
    "I_PULL_USED"   "⬇ Pull images used by running containers" \
    "I_PULL_STACK"  "⬇ Pull images for a compose project" \
    "I_RM"          "🗑 Remove image" \
    "I_PRUNE"       "🧽 Prune dangling images" \
    "BACK"          "🔙️ Back"
}

docker_images_run() {
  local a="$1"

  case "$a" in
    I_LIST)
      ui_msg "$DOCKER_TITLE" "$(docker images 2>/dev/null || true)"
      return 0
      ;;
    I_PRUNE)
      if ui_yesno "$DOCKER_TITLE" "Prune dangling images?

This is usually safe." ; then
        ui_msg "$DOCKER_TITLE" "$(docker image prune -f 2>&1 || true)"
      fi
      return 0
      ;;
    I_RM)
      local img
      img="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -n 400 | awk 'NF' || true)"
      if [[ -z "$img" ]]; then
        ui_msg "$DOCKER_TITLE" "No named images found."
        return 0
      fi
      local items=()
      while IFS= read -r i; do
        items+=("$i" "🖼 $i")
      done <<<"$img"
      local sel
      sel="$(ui_menu "$DOCKER_TITLE" "Select image to remove:" "${items[@]}" "BACK" "⬅ Back")" || return 0
      [[ "$sel" == "BACK" ]] && return 0

      # Show dependents to reduce surprise
      local deps
      deps="$(docker ps -a --filter "ancestor=$sel" --format '{{.Names}} | {{.Status}}' 2>/dev/null | head -n 40 || true)"
      if [[ -n "$deps" ]]; then
        ui_msg "$DOCKER_TITLE" "Heads up: these containers reference this image:
$deps"
      fi

      if ui_yesno "$DOCKER_TITLE" "Remove image:
$sel

This can break containers that depend on it." ; then
        ui_msg "$DOCKER_TITLE" "$(docker rmi "$sel" 2>&1 || true)"
      fi
      return 0
      ;;
    I_INSPECT)
      local img2
      img2="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -n 400 | awk 'NF' || true)"
      if [[ -z "$img2" ]]; then
        ui_msg "$DOCKER_TITLE" "No named images found."
        return 0
      fi
      local items2=()
      while IFS= read -r i; do
        items2+=("$i" "🔎 $i")
      done <<<"$img2"
      local sel2
      sel2="$(ui_menu "$DOCKER_TITLE" "Select image to inspect:" "${items2[@]}" "BACK" "⬅ Back")" || return 0
      [[ "$sel2" == "BACK" ]] && return 0
      ui_msg "$DOCKER_TITLE" "$(docker image inspect "$sel2" 2>/dev/null | head -n 260 || true)"
      return 0
      ;;
    I_PULL_TYPED)
      local ref
      ref="$(_ui_input "$DOCKER_TITLE" "Enter image reference to pull (e.g. nginx:latest, ghcr.io/user/app:1.2.3):" "")" || return 0
      ref="${ref//[$'
']/}"
      [[ -z "$ref" ]] && return 0

      if ! ui_yesno "$DOCKER_TITLE" "Pull image:
$ref

This will download layers from the registry." ; then
        ui_msg "$DOCKER_TITLE" "Cancelled."
        return 0
      fi

      local out
      out="$(docker pull "$ref" 2>&1 || true)"
      ui_msg "$DOCKER_TITLE" "Pull complete (showing last output):

$(printf "%s" "$out" | tail -n 120)"
      return 0
      ;;
    I_PULL_USED)
      local used
      used="$(docker ps --format '{{.Image}}' 2>/dev/null | sort -u | head -n 300 || true)"
      if [[ -z "$used" ]]; then
        ui_msg "$DOCKER_TITLE" "No running containers found."
        return 0
      fi

      if ! ui_yesno "$DOCKER_TITLE" "Pull images used by running containers?

Images:
$(printf "%s
" "$used" | head -n 25)
$( [[ $(printf "%s
" "$used" | wc -l | tr -d ' ') -gt 25 ]] && echo '... (more)')

This is safe, but can take time/bandwidth." ; then
        ui_msg "$DOCKER_TITLE" "Cancelled."
        return 0
      fi

      local out=""
      while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        out+="
=== $img ===
"
        out+="$(docker pull "$img" 2>&1 | tail -n 50)
"
      done <<<"$used"
      ui_msg "$DOCKER_TITLE" "Done.

$(printf "%b" "$out" | tail -n 220)"
      return 0
      ;;
    I_PULL_STACK)
      local proj cc
      proj="$(pick_compose_project "$DOCKER_TITLE" "Select project to pull images for:")" || return 0
      [[ "$proj" == "BACK" ]] && return 0

      cc="$(compose_cmd || true)"
      if [[ -z "$cc" ]]; then
        ui_msg "$DOCKER_TITLE" "Compose not detected (docker compose / docker-compose missing)."
        return 0
      fi

      if ! ui_yesno "$DOCKER_TITLE" "Pull images for compose project:
$proj

This runs:
  (cd \"$proj\" && $cc pull)" ; then
        ui_msg "$DOCKER_TITLE" "Cancelled."
        return 0
      fi

      local out
      out="$(cd "$proj" && $cc pull 2>&1 || true)"
      ui_msg "$DOCKER_TITLE" "Pull complete (showing last output):

$(printf "%s" "$out" | tail -n 160)"
      return 0
      ;;
  esac

  return 1
}

docker_volumes_menu() {
  ui_menu "$DOCKER_TITLE" "Volumes:" \
    "V_PICK"  "🧊 Select volume" \
    "V_PRUNE" "🧨 Prune unused volumes (danger)" \
    "BACK"    "🔙️ Back"
}

docker_volumes_run() {
  local a="$1"
  case "$a" in
    V_PRUNE)
      if ui_yesno "$DOCKER_TITLE" "Prune unused volumes?

Stop. This can delete real data.

If you are not 100% sure, choose No." ; then
        ui_msg "$DOCKER_TITLE" "$(docker volume prune -f 2>&1 || true)"
      fi
      return 0
      ;;
    V_PICK) ;;
    *) return 1;;
  esac

  local vol
  vol="$(pick_volume "$DOCKER_TITLE" "Select a volume:")" || return 0
  [[ "$vol" == "BACK" ]] && return 0

  while true; do
    local act
    act="$(ui_menu "$DOCKER_TITLE" "🧊 $vol" \
      "INSPECT" "🔎 Inspect" \
      "BACKUP"  "💾 Backup to tar.gz (reads volume)" \
      "RM"      "🗑 Remove volume (danger)" \
      "BACK"    "🔙️ Back")" || return 0

    case "$act" in
      INSPECT) ui_msg "$DOCKER_TITLE" "$(docker volume inspect "$vol" 2>/dev/null || true)";;
      BACKUP)
        if ui_yesno "$DOCKER_TITLE" "Backup volume:
$vol

This will create a tar.gz using a temporary container." ; then
          local dest="${HOME}/.dast_backups/docker_volumes/$(dast_ts)"
          mkdir -p "$dest" || true
          local out
          out="$(docker run --rm -v "$vol":/volume -v "$dest":/backup alpine sh -c 'cd /volume && tar -czf /backup/volume_backup.tar.gz . ' 2>&1 || true)"
          ui_msg "$DOCKER_TITLE" "Backup complete.

Saved to:
$dest/volume_backup.tar.gz

Output:
$out"
        fi
        ;;
      RM)
        if ui_yesno "$DOCKER_TITLE" "Remove volume:
$vol

Stop. This can delete real data." ; then
          ui_msg "$DOCKER_TITLE" "$(docker volume rm "$vol" 2>&1 || true)"
          return 0
        fi
        ;;
      BACK) return 0;;
    esac
  done
}

docker_networks_menu() {
  ui_menu "$DOCKER_TITLE" "Networks:" \
    "N_PICK"  "🕸 Select network" \
    "N_PRUNE" "🧼 Prune unused networks" \
    "BACK"    "🔙️ Back"
}

docker_networks_run() {
  local a="$1"
  case "$a" in
    N_PRUNE)
      if ui_yesno "$DOCKER_TITLE" "Prune unused networks?

Usually safe." ; then
        ui_msg "$DOCKER_TITLE" "$(docker network prune -f 2>&1 || true)"
      fi
      return 0
      ;;
    N_PICK) ;;
    *) return 1;;
  esac

  local nid
  nid="$(pick_network "$DOCKER_TITLE" "Select a network:")" || return 0
  [[ "$nid" == "BACK" ]] && return 0

  ui_msg "$DOCKER_TITLE" "$(docker network inspect "$nid" 2>/dev/null || true)"
}

docker_daemon_menu() {
  ui_menu "$DOCKER_TITLE" "Docker daemon:" \
    "D_STATUS"  "🔎 Status (systemctl)" \
    "D_START"   "▶️ Start docker service" \
    "D_STOP"    "⏹️ Stop docker service" \
    "D_RESTART" "🔄 Restart docker service" \
    "D_LOGS"    "📜 Daemon logs (journalctl)" \
    "BACK"      "🔙️ Back"
}

docker_daemon_run() {
  local a="$1"
  local svc="docker"
  case "$a" in
    D_STATUS) ui_msg "$DOCKER_TITLE" "$(systemctl status "$svc" --no-pager 2>&1 | head -n 120 || true)";;
    D_LOGS) ui_msg "$DOCKER_TITLE" "$(journalctl -u "$svc" -n 200 --no-pager 2>&1 | tail -n 200 || true)";;
    D_START|D_STOP|D_RESTART)
      if ! _is_root; then
        ui_msg "$DOCKER_TITLE" "Root required for systemctl actions."
        return 0
      fi
      local cmd="systemctl ${a#D_} $svc"
      cmd="${cmd,,}" # lowercase
      if ui_yesno "$DOCKER_TITLE" "Run:
$cmd" ; then
        ui_msg "$DOCKER_TITLE" "$(bash -c "$cmd" 2>&1 || true)"
      fi
      ;;
    *) return 1;;
  esac
}


# ---------------------------
# Portainer Agent + Updater
# ---------------------------

docker_portainer_status_line() {
  # outputs: "installed|running|stopped|missing"
  if ! has_docker || ! docker_daemon_ok; then
    echo "missing"
    return 0
  fi
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
    echo "missing"
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
    echo "running"
  else
    echo "stopped"
  fi
}

docker_portainer_menu() {
  if ! has_docker; then
    ui_msg "Not available" "Docker not detected (docker command missing)."
    return 1
  fi
  if ! docker_daemon_ok; then
    ui_msg "Docker daemon" "Docker detected, but I cannot talk to the daemon.\n\nRun DaST as root or fix docker access first."
    return 1
  fi

  local st hint
  st="$(docker_portainer_status_line)"
  case "$st" in
    running) hint="Status: RUNNING (container: portainer_agent, port: 9001)";;
    stopped) hint="Status: STOPPED (container: portainer_agent, port: 9001)";;
    *) hint="Status: NOT INSTALLED";;
  esac

  ui_menu "🧭 Portainer Agent" "This is the Portainer *Agent* (NOT the Portainer Server UI).\n\nUse it to connect this Docker host to a Portainer Server running elsewhere.\n\n${hint}\n\nActions:" \
    "STATUS"  "🔎 Show agent status/info" \
    "INSTALL" "⬇ Install Portainer Agent (recommended)" \
    "START"   "▶️ Start agent" \
    "STOP"    "⏹️ Stop agent" \
    "RESTART" "🔁 Restart agent" \
    "LOGS"    "📜 View agent logs" \
    "REMOVE"  "🗑 Remove agent container" \
    "BACK"    "🔙️ Back"
}

docker_portainer_run() {
  local action="$1"

  case "$action" in
    STATUS)
      local st
      st="$(docker_portainer_status_line)"
      if [[ "$st" == "missing" ]]; then
        ui_msg "Portainer Agent" "Agent is not installed.\n\nInstall it to allow a Portainer Server UI elsewhere to manage this host.\n\nDefault port: 9001 (agent API)."
        return 0
      fi
      docker inspect portainer_agent >"$DOCKER_DEBUG_DIR/dast_portainer_agent_inspect.$$" 2>/dev/null || true
      ui_msg "Portainer Agent" "Container: portainer_agent\nStatus: $st\n\nPorts:\n- 9001/tcp (host:9001)\n\nTip: In your Portainer Server, add an environment/edge endpoint using this host and port.\n\n(Inspect saved to "$DOCKER_DEBUG_DIR/dast_portainer_agent_inspect.$$" for reference.)"
      return 0
      ;;
    INSTALL)
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
        ui_msg "Already installed" "Container 'portainer_agent' already exists.\n\nUse Start/Restart, or Remove then Install if you need to recreate it."
        return 0
      fi

      ui_yesno "Install Portainer Agent?" "This will install the Portainer *Agent* container.\n\nIt will:\n- expose port 9001 on the host\n- mount /var/run/docker.sock (gives the agent control of Docker)\n- mount /var/lib/docker/volumes (needed for volume browsing)\n\nGuard rails:\n- This is powerful. Only connect it to a Portainer Server you trust.\n\nProceed?" || return 0

      # Note: keep this simple and explicit (no swarm needed)
run_sh "docker run -d --name portainer_agent --restart=always -p 9001:9001 -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes portainer/agent:latest"
      ui_msg "Installed" "Portainer Agent installed.\n\nNext:\n- In Portainer Server UI (elsewhere), add this host as an Agent endpoint (host:9001).\n\nReminder: this is the agent only (no web UI on this host)."
      ;;
    START)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
        ui_msg "Not installed" "Portainer Agent is not installed yet."
        return 0
      fi
      run docker start portainer_agent
      ;;
    STOP)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
        ui_msg "Not installed" "Portainer Agent is not installed."
        return 0
      fi
      ui_yesno "Stop agent?" "Stop Portainer Agent container?\n\nThis will disconnect the host from Portainer Server until started again." || return 0
      run docker stop portainer_agent
      ;;
    RESTART)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
        ui_msg "Not installed" "Portainer Agent is not installed."
        return 0
      fi
      ui_yesno "Restart agent?" "Restart Portainer Agent container now?" || return 0
      run docker restart portainer_agent
      ;;
    LOGS)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
        ui_msg "Not installed" "Portainer Agent is not installed."
        return 0
      fi
      docker logs --tail 200 portainer_agent 2>&1 | ui_pager "📜 Portainer Agent logs (last 200 lines)"
      ;;
    REMOVE)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "portainer_agent"; then
        ui_msg "Not installed" "Portainer Agent is not installed."
        return 0
      fi
      ui_yesno "Remove Portainer Agent?" "This will stop and remove the container 'portainer_agent'.\n\nIt will NOT remove your containers/images/volumes.\n\nProceed?" || return 0
      run docker rm -f portainer_agent
      ui_msg "Removed" "Portainer Agent container removed."
      ;;
    *) return 1;;
  esac
}

docker_updater_status_line() {
  if ! has_docker || ! docker_daemon_ok; then
    echo "missing"
    return 0
  fi
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
    echo "missing"
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
    echo "running"
  else
    echo "stopped"
  fi
}

docker_updater_menu() {
  if ! has_docker; then
    ui_msg "Not available" "Docker not detected (docker command missing)."
    return 1
  fi
  if ! docker_daemon_ok; then
    ui_msg "Docker daemon" "Docker detected, but I cannot talk to the daemon.\n\nRun DaST as root or fix docker access first."
    return 1
  fi

  local st hint
  st="$(docker_updater_status_line)"
  case "$st" in
    running) hint="Status: RUNNING (container: watchtower)";;
    stopped) hint="Status: STOPPED (container: watchtower)";;
    *) hint="Status: NOT INSTALLED";;
  esac

  ui_menu "🔄 Auto-updater (Watchtower)" "This installs a container auto-updater (Watchtower).\n\nCaveats (read carefully):\n- It can restart containers automatically\n- Updates can break apps if images change unexpectedly\n- If you rely on stability, prefer *label-only* mode\n\n${hint}\n\nActions:" \
    "ABOUT"   "ℹ Caveats and recommended approach" \
    "INSTALL_LABEL" "⬇ Install (label-only mode, safer)" \
    "INSTALL_ALL"   "⬇ Install (all containers, riskier)" \
    "START"   "▶️ Start updater" \
    "STOP"    "⏹️ Stop updater" \
    "RESTART" "🔁 Restart updater" \
    "LOGS"    "📜 View updater logs" \
    "REMOVE"  "🗑 Remove updater container" \
    "BACK"    "🔙️ Back"
}

docker_updater_run() {
  local action="$1"

  case "$action" in
    ABOUT)
      ui_msg "Auto-updater caveats" "Watchtower can keep containers updated automatically, but it's not magic.\n\nRecommended:\n- Prefer label-only mode.\n- Pin critical apps to specific tags (avoid :latest when stability matters).\n- Expect restarts during updates.\n\nLabel-only mode updates ONLY containers with:\ncom.centurylinklabs.watchtower.enable=true\n\nYou can add that label in your compose service definition."
      ;;
    INSTALL_LABEL|INSTALL_ALL)
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
        ui_msg "Already installed" "Container 'watchtower' already exists.\n\nUse Start/Restart, or Remove then Install if you need to recreate it."
        return 0
      fi

      local mode_txt extra_args
      if [[ "$action" == "INSTALL_LABEL" ]]; then
        mode_txt="LABEL-ONLY (safer)"
        extra_args="--label-enable"
      else
        mode_txt="ALL CONTAINERS (riskier)"
        extra_args=""
      fi

      ui_yesno "Install Watchtower?" "Mode: ${mode_txt}\n\nThis will install Watchtower with a daily schedule at 04:00.\n\nIt will:\n- mount /var/run/docker.sock (gives it control of Docker)\n- periodically pull newer images and restart containers\n\nProceed?" || return 0

      # daily at 04:00 (cron format: sec min hour dom mon dow)
run_sh "docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower ${extra_args} --cleanup --schedule '0 0 4 * * *'"
      ui_msg "Installed" "Watchtower installed.\n\nMode: ${mode_txt}\nSchedule: daily at 04:00\n\nReminder: container auto-updaters have caveats. If stability matters, label-only mode is the safer choice."
      ;;
    START)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
        ui_msg "Not installed" "Watchtower is not installed yet."
        return 0
      fi
      run docker start watchtower
      ;;
    STOP)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
        ui_msg "Not installed" "Watchtower is not installed."
        return 0
      fi
      ui_yesno "Stop updater?" "Stop Watchtower container?\n\nNo auto-updates will run while it's stopped." || return 0
      run docker stop watchtower
      ;;
    RESTART)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
        ui_msg "Not installed" "Watchtower is not installed."
        return 0
      fi
      ui_yesno "Restart updater?" "Restart Watchtower now?" || return 0
      run docker restart watchtower
      ;;
    LOGS)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
        ui_msg "Not installed" "Watchtower is not installed."
        return 0
      fi
      docker logs --tail 250 watchtower 2>&1 | ui_pager "📜 Watchtower logs (last 250 lines)"
      ;;
    REMOVE)
      if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower"; then
        ui_msg "Not installed" "Watchtower is not installed."
        return 0
      fi
      ui_yesno "Remove Watchtower?" "This will stop and remove the container 'watchtower'.\n\nIt will NOT remove your containers/images/volumes.\n\nProceed?" || return 0
      run docker rm -f watchtower
      ui_msg "Removed" "Watchtower container removed."
      ;;
    *) return 1;;
  esac
}

docker_run() {
  local action="$1"

  if ! has_docker; then
    ui_msg "Not available" "Docker not detected."
    return 1
  fi

  if ! docker_daemon_ok; then
    ui_msg "Docker daemon" "Docker is installed, but I cannot talk to the daemon.

Common causes:
- dockerd not running
- you are not root and not in the docker group
- remote context issues"
    return 0
  fi

  case "$action" in
    OVERVIEW) docker_overview ;;
    CONTAINERS)
      local a
      a="$(docker_container_menu)" || return 0
      [[ -z "$a" || "$a" == "BACK" ]] && return 0
      docker_container_run "$a"
      ;;
    STACKS)
      local s
      s="$(docker_stacks_menu)" || return 0
      [[ -z "$s" || "$s" == "BACK" ]] && return 0
      docker_stacks_run "$s"
      ;;
    EDIT)
      local e
      e="$(docker_edit_menu)" || return 0
      [[ -z "$e" || "$e" == "BACK" ]] && return 0
      docker_edit_run "$e"
      ;;
    IMAGES)
      local i
      i="$(docker_images_menu)" || return 0
      [[ -z "$i" || "$i" == "BACK" ]] && return 0
      docker_images_run "$i"
      ;;
    VOLUMES)
      local v
      v="$(docker_volumes_menu)" || return 0
      [[ -z "$v" || "$v" == "BACK" ]] && return 0
      docker_volumes_run "$v"
      ;;
    NETWORKS)
      local n
      n="$(docker_networks_menu)" || return 0
      [[ -z "$n" || "$n" == "BACK" ]] && return 0
      docker_networks_run "$n"
      ;;

    PORTAINER)
      local p
      p="$(docker_portainer_menu)" || return 0
      [[ -z "$p" || "$p" == "BACK" ]] && return 0
      docker_portainer_run "$p"
      ;;
    UPDATER)
      local u
      u="$(docker_updater_menu)" || return 0
      [[ -z "$u" || "$u" == "BACK" ]] && return 0
      docker_updater_run "$u"
      ;;
    DAEMON)
      local d
      d="$(docker_daemon_menu)" || return 0
      [[ -z "$d" || "$d" == "BACK" ]] && return 0
      docker_daemon_run "$d"
      ;;
    CLEANUP)
      local c
      c="$(docker_cleanup_menu)" || return 0
      [[ -z "$c" || "$c" == "BACK" ]] && return 0
      docker_cleanup_run "$c"
      ;;
    D_*)
      docker_cleanup_run "$action"
      ;;
    *) return 1;;
  esac
}

docker_cleanup_run() {
  local action="$1"

  if ! has_docker; then
    ui_msg "Not available" "Docker not detected."
    return 1
  fi

  if ! docker_daemon_ok; then
    ui_msg "Docker daemon" "Docker is installed, but I cannot talk to the daemon.

Common causes:
- dockerd not running
- you are not root and not in the docker group
- remote context issues

Try running DaST as root, or fix docker daemon access first."
    return 1
  fi

  local cmd desc danger=0
  case "$action" in
    D_DF) cmd="docker system df"; desc="Docker disk usage";;
    D_IMG) cmd="docker image prune -f"; desc="Prune unused images";;
    D_CONT) cmd="docker container prune -f"; desc="Prune stopped containers";;
    D_NET) cmd="docker network prune -f"; desc="Prune unused networks";;
    D_VOL) cmd="docker volume prune -f"; desc="Prune unused volumes"; danger=1;;
    D_SYSTEM) cmd="docker system prune -f"; desc="System prune"; danger=1;;
    D_SYSTEM_VOL) cmd="docker system prune -a -f --volumes"; desc="System prune (including all unused images) + volumes"; danger=1;;
    *) return 1;;
  esac

  local msg="Command:
$cmd"

  if (( danger == 1 )); then
    msg+="

This is destructive.
- Volumes can contain real data.
- system prune -a can remove images you expect to keep.

Proceed only if you understand the impact."
  fi

  if ! _confirm_danger "Confirm Docker action" "$msg

Proceed?"; then
    ui_msg "Cancelled" "No changes made."
    return 0
  fi

  local out
  out="$(bash -c "$cmd" 2>&1 || true)"
  ui_msg "Done" "$desc complete.

Output:
$out"
}

# -----------------------------
# Main module entry
# -----------------------------

maintenance_dispatch() {
  local action="$1"

  case "$action" in
    TMP_VIEW)
      tmp_view
      ;;
    TMP_CLEAN)
      local pol
      pol="$(tmp_clean_picker)" || return 0
      case "$pol" in
        AGE_1) tmp_clean_run 1;;
        AGE_3) tmp_clean_run 3;;
        AGE_7) tmp_clean_run 7;;
        BACK|"") ;;
      esac
      ;;
    JOURNAL)
      local j
      j="$(journal_menu)" || return 0
      [[ -z "$j" || "$j" == "BACK" ]] && return 0
      journal_run "$j"
      ;;
    LOGROTATE)
      logrotate_run
      ;;
    CRASH)
      crash_clear_run
      ;;
    COREDUMP)
      coredump_run
      ;;
    APT)
      local a
      a="$(apt_menu)" || return 0
      [[ -z "$a" || "$a" == "BACK" ]] && return 0
      apt_run "$a"
      ;;
    DOCKER)
      if ! has_docker; then
        ui_msg "Not available" "Docker not detected (docker command missing)."
        return 0
      fi
      local d
      d="$(docker_menu)" || return 0
      [[ -z "$d" || "$d" == "BACK" ]] && return 0
      [[ "$d" == "MAINT" ]] && return 0
      docker_run "$d"
      ;;
    *) return 1;;
  esac

  return 0
}

maintenance_loop() {
  while true; do
    local action
    action="$(maintenance_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0
    maintenance_dispatch "$action"
  done
}

module_DOCKER() {
  dast_log info "$module_id" "Entering module"
  dast_dbg "$module_id" "DAST_DEBUG=${DAST_DEBUG:-0} DAST_DEBUGGEN=${DAST_DEBUGGEN:-0}"
  # Docker module should only expose Docker tooling.
  # If Docker is not present, explain and return (avoid surprising users with unrelated menus).
  if ! has_docker; then
    ui_msg "Not available" "Docker not detected (docker command missing).\n\nInstall Docker, then reopen this module."
    return 0
  fi

  while true; do

    local action
    action="$(docker_menu)" || return 0
    [[ -z "$action" || "$action" == "BACK" ]] && return 0

    case "$action" in
      MAINT)
        maintenance_loop
        ;;
      *)
        docker_run "$action"
        ;;
    esac
  done
}

# Loader marker

# Loader marker (Keep this line for diagnostic scanners)
if declare -F register_module >/dev/null 2>&1; then
  # Only register when Docker is actually present to avoid confusing menus.
  if has_docker; then
    register_module "DOCKER" "$module_title" "module_DOCKER"
  fi
fi
