# DaST Architecture

**Version:** v0.9.8.4 (alpha)

This document explains how DaST is structured, how the launcher boots, how modules register, and which helper functions exist for contributors.

DaST is deliberately conservative. It prefers clarity, logging, and explicit confirmation over clever automation.

---

## 1. Repository layout

| Path | Role |
| --- | --- |
| `DaST_v0.9.8.4.sh` | Main entrypoint. Loads libs, applies runtime UI policy, loads modules, and dispatches the main menu. |
| `lib/dast_config.sh` | Early config helpers and config path resolution. |
| `lib/dast_helper.sh` | Command wrappers and logging helpers (`run`, `run_capture`, `mktemp_safe`, environment fingerprint). |
| `lib/dast_priv.sh` | Privilege handling (`dast_priv_ensure_root`) and auth theme handling. |
| `lib/dast_theme.sh` | dialog theme management and dialogrc generation. |
| `lib/dast_ui.sh` | Thin wrappers for `dialog` calls (`dast_ui_msgbox`, `dast_ui_dialog`, etc). |
| `modules/*.sh` | Feature modules. Each module provides an entry function and registers itself via `register_module`. |
| `config/dast.conf` | Auto-created config file (persisted user preferences). |
| `logs/run_<RUN_ID>/dast.log` | Per-run log file (default). |
| `debug/run_<RUN_ID>/...` | Debug artifacts when debug flags are enabled. |

---

## 2. Boot flow

High level flow when you run the launcher:

1. **Sanity and environment**
   - Confirms Bash.
   - Sets up run/session directories.
   - Applies an early dialog theme (so authentication prompts look consistent).

2. **Config and UI preferences**
   - Loads config (if present) and applies defaults.
   - Applies a one-run emoji policy via `ui_apply_runtime_emoji_policy`.
     - If `UI_EMOJI=0`, DaST strips its known icon set everywhere.
     - If the terminal is detected as hostile for emoji, DaST can auto-disable icons for that run.

3. **Module loading**
   - The launcher sources module scripts in numeric order.
   - Each module decides whether it can run on the current system.
   - If applicable, the module calls `register_module` and becomes visible in the main menu.

4. **Main menu dispatch**
   - `ui_main_menu` shows the authoritative module list.
   - Selecting a module calls the module entry function.

5. **Exit and cleanup**
   - Temporary files created via `mktemp_safe` are tracked and cleaned up.
   - Logs remain per-run.

---

## 3. Module model

A DaST module is a sourced Bash file that provides:

- `module_id` (uppercase identifier string)
- `module_title` (icon + name, icon must be a single Unicode codepoint)
- An entry function (conventionally `module_<ID>`)
- A registration call

Minimal pattern:

```bash
module_id="MYMOD"
module_title="🚀 My Module"

module_MYMOD() {
  while true; do
    local choice
    choice=$(ui_menu "$module_title" "Choose action:" \
      "BACK" "Back") || return 0
    [[ "$choice" == "BACK" ]] && return 0
  done
}

if declare -F register_module >/dev/null 2>&1; then
  register_module "$module_id" "$module_title" "module_MYMOD"
fi
```

### 3.1 Module gating

Modules must not register if they are not appropriate for the system.

Examples of gating checks:

- Required commands or packages not present
- Unsupported distro or init system
- Feature would be unsafe in the detected context

Simply: If a module is visible, DaST believes it is appropriate for that system.

---

## 4. UI layer

DaST uses `dialog` for its text-based user interface (TUI).

If `dialog` is missing, DaST checks the operating system and execution context and then:

- On supported systems (Ubuntu, and Debian where applicable), DaST may offer to install `dialog` automatically.
  - If running as root, installation is offered directly.
  - If running as a normal user and `sudo` is available and permitted, DaST can install `dialog` using `sudo` and then re-launch itself.
- On systems where automatic installation is not appropriate (for example KDE Neon - as APT is not preferred, unknown distributions, non-interactive environments, or where `sudo` is unavailable or not permitted), DaST prints clear, safe instructions and exits.

DaST never modifies sudoers or system policy.  If automatic installation is not possible, `dialog` must be installed manually before rerunning DaST.

There are two layers of UI helpers:

### 4.1 Launcher UI helpers

Defined in the main launcher:

- `ui_msg`, `ui_msg_sized`
- `ui_yesno`
- `ui_input`, `ui_inputbox`
- `ui_menu`, `ui_main_menu`
- `ui_textbox`, `ui_programbox`

These functions:

- keep dialog usage consistent
- centralise sizing and ergonomics
- integrate with icon stripping rules

### 4.2 lib UI wrappers

Defined in `lib/dast_ui.sh`:

- `dast_ui_msgbox`
- `dast_ui_dialog`
- `dast_ui_clear`
- `ui_sanitise_title`

These provide a stable surface for module code and reduce copy/paste dialog blocks.

---


## 6. Logging and command execution

DaST aims to make changes visible and auditable.

### 6.1 Logging

The launcher provides:

- `dast_log LEVEL MODULE message...`
- `dast_dbg MODULE message...`

Logs are written per-run to the active log path (default under `logs/run_<RUN_ID>/`).

### 6.2 Command wrappers

Modules should execute system commands via `run` or `run_capture` (from `lib/dast_helper.sh`).

Why:

- consistent log formatting
- predictable output capture
- easier debugging

Also available:

- `run_sh`, `run_capture_sh` for shell snippets
- `dast_env_fingerprint` for issue reports

---


## 7. Config and runtime state

Config is persisted to `config/dast.conf` (auto-created).

Common persisted settings include UI preferences such as:

- `UI_COLOUR`
- `UI_COMPACT`
- `SHOW_STARTUP_WARNING`
- `EXPORT_LINES`
- `UI_EMOJI`

`lib/dast_config.sh` provides early config access helpers so the launcher can apply prefs before the main UI starts.


## 8. Privilege model

DaST is designed to be run interactively as root.

- The launcher and some modules perform privilege checks.
- `lib/dast_priv.sh` provides `dast_priv_ensure_root`.

DaST does not attempt complex privilege separation. This is intentional.

## 9. Theme management

DaST applies a fixed, TTY-safe theme.

Theme helpers:

- `dast_theme_apply_early` (auth prompts)
- `dast_theme_apply` (main UI)

Theme switching is not exposed in the UI in this release.

## 10. AI assistance note

I am not a Bash expert. AI assistance helped make this project possible.

All design choices, testing, and responsibility remain human, and contributors should review changes carefully.



<div style="text-align:center;">
Thanks for your interest in DaST! Made with ♥️ by ellnic/lysergic-skies.
</div>
