# Logitech Devices (Omarchy plugin)

Bar widget for Logitech mice and keyboards on Unifying, Bolt, Nano and Lightspeed
receivers, Bluetooth or cable. The bar icon is green while every connected battery is
fine, orange when one drops to 25 % or less and red at 10 % or less (charging devices
don't count). The icon shows which device is low: a keyboard glyph when the keyboard is
lower, otherwise a mouse (also on a tie). The panel lists every paired device and every
receiver with its free slots.

Per device, when the hardware supports it:

- battery (percent, charging)
- pointer speed (DPI)
- scroll wheel mode: SmartShift / ratchet / free spin, SmartShift sensitivity
- natural and high-resolution scrolling
- Fn-key swap

Settings you change are remembered in `~/.config/omarchy/logitech-devices/settings.json`
and written again when a device reconnects.

## How it works

`scripts/logitech-devices.py` (Python stdlib only) talks Logitech's HID++ protocol
straight over `/dev/hidraw`. No Solaar, no daemon besides the helper the bar widget runs.

Access to `/dev/hidraw` is root-only by default. The panel's **Allow access** button
runs `scripts/allow-access.sh` through `pkexec`; it installs
`/etc/udev/rules.d/42-omarchy-logitech-devices.rules`, which gives the logged-in user
(`uaccess`) access to Logitech hidraw nodes, the same scope as Solaar's rule. Remove the
file to revoke it.

## Tests

    python3 -m unittest discover -s tests
    omarchy plugin validate .

Local plugin, not published.
