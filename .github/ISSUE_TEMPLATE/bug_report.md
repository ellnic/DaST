---
name: Bug Report
about: Report a bug or unexpected behaviour in DaST
title: "[BUG] <short, descriptive summary>"
labels: bug
assignees: ''
---

## ⚠️ IMPORTANT – READ FIRST

**Issues without logs, system information, and clear reproduction steps will be closed without investigation.** 

Please note that I am one person with family commitments, so responses may be limited/delayed.

DaST provides structured logging and debug output. If you do not include the required information below, the issue cannot be triaged.

---

## Summary

A clear and concise description of the issue. Module, function etc.

---

## Expected Behaviour

What you expected DaST to do.

---

## Actual Behaviour

What DaST actually did.

Include exact wording of any error messages shown.

---

## Steps to Reproduce

Provide step-by-step instructions so the issue can be reproduced reliably.

Example:

1. Launch DaST from the app directory with debug enabled:

​	cd /path/to/DaST/App
​	./DaST.sh --debug

2. Navigate to the relevant module or menu.
3. Perform the action that triggers the issue.
4. Exit DaST after the issue occurs.
5. Collect logs from:

​	[DaST app dir]/logs/
​	[DaST app dir]/debug/

---

## DaST Version

Provide the exact DaST version or commit hash:

DaST version:

---

## System Information (REQUIRED)

Please provide all of the following:

- Distribution:
- Version:
- Kernel:
- Init system (systemd / sysvinit / openrc / other):
- Shell (`bash --version`):

Example:

OS: Debian 12  
Kernel: 6.1.0-18-amd64  
Init: systemd  
Shell: GNU bash 5.2.15

---

## Logs (REQUIRED)

Run DaST with debug enabled, reproduce the issue once, then attach or paste the relevant sections from:

[DaST app dir]/logs/dast.log  
[DaST app dir]/debug/dast.debug.log

- Attach files where possible.
- If pasting, include only the relevant section, not entire log files.

**Issues without logs will be closed.**

---

## Module(s) Affected

Tick all that apply:

- [ ] System
- [ ] APT
- [ ] Services
- [ ] Disk Management
- [ ] ZFS
- [ ] Networking
- [ ] Firewall
- [ ] Cron
- [ ] Logs
- [ ] Kernel
- [ ] Bootloader
- [ ] Docker
- [ ] Users & Groups
- [ ] Maintenance
- [ ] DaST Toolbox
- [ ] Helper / Core
- [ ] Unknown

---

## Additional Context

Anything else that may help, such as:

- Non-standard system configuration
- Running under sudo vs user
- Custom forks or local modifications
- Screenshots (if relevant)

---

## Confirmation

Please confirm the following:

- [ ] I ran DaST with `--debug`
- [ ] I attached or pasted relevant logs
- [ ] I provided full system information
- [ ] I searched existing issues before opening this one
- [ ] I stated whether UI icons were enabled (`UI_EMOJI=1`), disabled (`UI_EMOJI=0`), or auto-disabled due to a fragile terminal

---

Thank you for helping improve DaST.
Well-formed reports get fixed faster.
