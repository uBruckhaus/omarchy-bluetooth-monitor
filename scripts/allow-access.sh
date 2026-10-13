#!/bin/bash
# Lets the logged-in user talk HID++ to Logitech receivers and devices (run as root via pkexec).
# Same scope as Solaar's 42-logitech-unify-permissions.rules: hidraw nodes of USB devices
# with Logitech's vendor id and Logitech devices on Bluetooth, granted with uaccess (only
# the user at the seat, only while logged in).
set -euo pipefail
rule=/etc/udev/rules.d/42-omarchy-logitech-devices.rules
cat > "$rule.tmp" <<'RULES'
# Managed by ubruckhaus.logitech-devices (Omarchy plugin)
ACTION == "remove", GOTO="omarchy_logitech_end"
SUBSYSTEM != "hidraw", GOTO="omarchy_logitech_end"
ATTRS{idVendor}=="046d", GOTO="omarchy_logitech_apply"
KERNELS == "0005:046D:*", GOTO="omarchy_logitech_apply"
GOTO="omarchy_logitech_end"
LABEL="omarchy_logitech_apply"
TAG+="uaccess"
LABEL="omarchy_logitech_end"
RULES
chmod 0644 "$rule.tmp"
mv -f "$rule.tmp" "$rule"
udevadm control --reload-rules
udevadm trigger --subsystem-match=hidraw --action=add
udevadm settle --timeout=5 || true
