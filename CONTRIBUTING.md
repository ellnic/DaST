# Contributing to DaST (Debian admin System Tool) 🛠️

**Version:** v0.9.8.4 (alpha)

Thank you for your interest in contributing! DaST is built on the philosophy that system administration should be cohesive, discoverable, and safe. Inspiration is taken from tools like YaST to provide a structured interface for the powerful CLI tools underneath.

---

<h2>⏱️ A note on testing, time and help needed</h2>

<p>DaST is developed and tested by a single maintainer, in real environments, over many hours of hands-on use.</p>

<p>While care is taken to test changes, there are practical limits to the breadth of testing that can be done across different systems by one person. Help with testing, validation, documentation review, and feedback across a wider range of setups is genuinely appreciated. There may be regressions or edge cases, and AI assistance has been used to help make this project possible.</p>

<p>This project is maintained alongside family and other commitments. Thoughtful contributions, clear bug reports, and well-described test results are far more valuable than volume. Responses may occasionally be delayed, but all constructive input is welcome and appreciated.</p>

<p>The project would particularly benefit from testing in real environments where data and uptime are not considered critical. Some functions may be incomplete or contain errors. This is WIP. Help in whatever form would be very much appreciated.</p>

## 📁 Module File Naming Conventions

DaST uses numeric prefixes to determine the order of modules in the main menu. The current modules are:

| Prefix | Module | Filename |
| :--- | :--- | :--- |
| **10** | 💻 **System** | 10_system.sh |
| **20** | 📦 **APT (packages)** | 20_apt.sh |
| **30** | 📡 **Services (systemd)** | 30_services.sh |
| **40** | 💽 **Disk Management** | 40_disk_management.sh |
| **50** | 💾 **ZFS management** | 50_zfs.sh |
| **60** | 🌐 **Networking** | 60_networking.sh |
| **70** | 🧱 **Firewall** | 70_firewall.sh |
| **80** | 🕒 **Cron** | 80_cron.sh |
| **90** | 📜 **Logs (journalctl)** | 90_logs.sh |
| **100** | 🧬 **Kernel** | 100_kernel.sh |
| **110** | 🥾 **Bootloader** | 110_bootloader.sh |
| **120** | 📊 **Monitor & Report** | 120_monitor_report.sh |
| **130** | 👥 **Users & Groups** | 130_users_groups.sh |
| **140** | 🐳 **Docker** | 140_docker.sh |
| **150** | 🧹 **Maintenance** | 150_maintenance.sh |
| **160** | 🧰 **DaST Toolbox** | 160_dast_toolbox.sh |

**Format:** NN_module_name.sh or NNN_module_name.sh

---

## 🧭 Architecture Doc Note

If you are contributing, please read `ARCHITECTURE.md` first. It explains the loader flow, UI wrappers, config, logging, and how modules are registered and gated.

---

## 🏗️ Module Architecture

Each module is a standalone Bash script. To ensure compatibility with the loader and the diagnostic toolbox, follow this structure:

### 1. Metadata Block
module_id="MYMOD"
module_title="🚀 My New Module"

### 2. Helper Integration
Ensure your module can access core functions like run, ui_menu, and ui_msg.

_dast_try_source_helper() {
  if declare -F run >/dev/null 2>&1; then return 0; fi
  local here="$(cd -- \"$(dirname -- \"${BASH_SOURCE[0]}\")\" && pwd -P)"
  [[ -f "$here/dast_helper.sh" ]] && source "$here/dast_helper.sh" >/dev/null 2>&1 || true
}
_dast_try_source_helper

### 3. The Entry Point
The loader invokes module_<ID>. Use a while true loop for menu persistence.

module_MYMOD() {
  while true; do
    local choice
    choice=$(ui_menu "$module_title" "Choose action:" "DO" "Perform Task" "BACK" "Go back") || return 0
    [[ "$choice" == "BACK" ]] && return 0
    # Logic goes here
  done
}

### 4. Loader registration
DaST relies on an explicit `register_module` call to correctly identify and track modules during loading and diagnostics.

Ensure the registration call appears **outside of any function body**, typically at the bottom of the file:

```bash
register_module "MYMOD" "$module_title" "module_MYMOD"
```

This registration is used by the loader and diagnostic tooling to determine module status and should not be removed.

```bash
if declare -F register_module >/dev/null 2>&1; then
  register_module "MYMOD" "$module_title" "module_MYMOD"
fi
```

---

## 🧩 Module gating (mandatory)

DaST modules are expected to perform explicit runtime checks for required tooling and safe operating conditions.

If a module is not applicable to the current system, it must not register and must remain hidden from the main menu. This is intentional and is part of DaST’s safeguarding design.

If a module is visible, DaST believes it is appropriate for that system. If you run a "non-standard" Debian or Ubuntu distro, help would be appreciated testing this.

---

## 🛡️ Project Standards & Best Practices

### The "Safety First" Rule
* Default to NO: Any action that modifies the system (deletes, formats, stops services) must use a confirmation dialog where "No" or "Cancel" is the default focus.
* Preview Intent: Aim to show the user a preview of the command or the files affected before execution.


## 🚀 Submission Process

1. Test Standalone: Run bash your_module.sh to ensure it handles missing helpers gracefully.
2. Test Integrated: Run dast.sh and verify the module appears and functions.
3. Check the module is registered correctly: Open the DaST Toolbox -> Registered Modules and ensure your module shows a green light status.



<div style="text-align:center;">
Thanks for your interest in DaST! Made with ♥️ by ellnic/lysergic-skies.
</div>
