import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ld", os.path.join(HERE, "..", "scripts", "logitech-devices.py"))
ld = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ld)


class FakeNode:
    """Answers HID++ requests from a table keyed by (dev, b2, b3, first param)."""

    def __init__(self, table):
        self.table = table
        self.sent = []
        self.events = []

    def request(self, dev, b2, b3, params=b"", long=False, timeout=1.0, echo=None):
        params = bytes(params)
        self.sent.append((dev, b2, b3, params))
        key = (dev, b2, b3, params[0] if params else None)
        answer = self.table.get(key)
        if answer is None:
            raise ld.HidppError(0x02)
        if isinstance(answer, Exception):
            raise answer
        return bytes(answer)


class PureHelpers(unittest.TestCase):
    def test_dpi_list_with_step_range(self):
        raw = bytes([0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0, 0])  # 200, step 50 up to 8000
        values = ld.parse_dpi_list(raw)
        self.assertEqual(values[0], 200)
        self.assertEqual(values[-1], 8000)
        self.assertEqual(ld.dpi_range(values), {"min": 200, "max": 8000, "step": 50})

    def test_dpi_list_plain_values(self):
        raw = bytes([0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0, 0])
        values = ld.parse_dpi_list(raw)
        self.assertEqual(values, [400, 800, 1600])
        self.assertEqual(ld.dpi_range(values)["choices"], [400, 800, 1600])

    def test_voltage_curve(self):
        self.assertEqual(ld.voltage_percent(4200), 100)
        self.assertEqual(ld.voltage_percent(3400), 0)
        self.assertEqual(ld.voltage_percent(3811), 50)
        self.assertTrue(50 < ld.voltage_percent(3840) < 60)

    def test_smartshift_state(self):
        self.assertEqual(ld.smartshift_state(2, 10, True)["mode"], "smartshift")
        self.assertEqual(ld.smartshift_state(2, 0xFF, False)["mode"], "ratchet")
        self.assertEqual(ld.smartshift_state(1, 10, False)["mode"], "freespin")

    def test_clean_strips_markup_and_controls(self):
        self.assertEqual(ld.clean(b"MX <b>Keys\x07\0junk"), "MX bKeys")

    def test_battery_summary_picks_lowest_online(self):
        devs = [
            {"id": "a", "name": "A", "online": True, "battery": {"percent": 80}},
            {"id": "b", "name": "B", "online": True, "battery": {"percent": 30, "charging": True}},
            {"id": "c", "name": "C", "online": False, "battery": {"percent": 5}},
        ]
        self.assertEqual(ld.battery_summary(devs)["id" if False else "device"], "b")
        self.assertIsNone(ld.battery_summary([]))


class Discovery(unittest.TestCase):
    def make(self, root, name, hid_id, desc, parent):
        dev_real = os.path.join(root, "devices", parent, hid_id.replace(":", "_") + name)
        os.makedirs(dev_real)
        with open(os.path.join(dev_real, "uevent"), "w") as f:
            f.write(f"HID_ID={hid_id}\nHID_NAME=Logitech USB Receiver\n")
        with open(os.path.join(dev_real, "report_descriptor"), "wb") as f:
            f.write(desc)
        node = os.path.join(root, "hidraw", name)
        os.makedirs(node)
        os.symlink(dev_real, os.path.join(node, "device"))

    def test_receivers_and_children(self):
        hidpp = b"\x06\x00\xff\x09\x01\xa1\x01\x85\x10\x85\x11"
        with tempfile.TemporaryDirectory() as root:
            self.make(root, "hidraw5", "0003:0000046D:0000C52B", hidpp, "3-6:1.2")
            self.make(root, "hidraw2", "0003:0000046D:0000C548", hidpp, "7-1:1.2")
            self.make(root, "hidraw0", "0003:0000046D:0000C548", b"\x05\x01\x09\x06", "7-1:1.0")
            self.make(root, "hidraw7", "0003:0000046D:00004082", hidpp, "0003:046D:C52B.0008")
            self.make(root, "hidraw9", "0005:0000046D:0000B034", hidpp, "hci0:256")
            self.make(root, "hidraw4", "0003:00001462:00007D70", hidpp, "1-7:1.0")
            nodes = {n["node"]: n for n in ld.discover(os.path.join(root, "hidraw"))}
        self.assertEqual(nodes["hidraw5"]["family"], "unifying")
        self.assertEqual(nodes["hidraw2"]["family"], "bolt")
        self.assertNotIn("hidraw0", nodes)  # no HID++ reports
        self.assertNotIn("hidraw7", nodes)  # DJ child behind the receiver
        self.assertNotIn("hidraw4", nodes)  # not Logitech
        self.assertEqual(nodes["hidraw9"]["bus"], "bluetooth")
        self.assertIsNone(nodes["hidraw9"]["family"])


class Protocol(unittest.TestCase):
    def test_bolt_pairing(self):
        table = {(0xFF, 0x83, 0xB5, 0x50 + s): None for s in range(1, 7)}
        table[(0xFF, 0x83, 0xB5, 0x52)] = [0x52, 0x02, 0x42, 0xB0, 1, 2, 3, 4]
        table[(0xFF, 0x83, 0xB5, 0x62)] = [0x62, 0x01, 0x0B] + list(b"MX Master 4") + [0, 0]
        rec = ld.Receiver(FakeNode({k: v for k, v in table.items() if v}), "bolt")
        self.assertEqual(rec.paired(), [(2, 0xB042, 2, "MX Master 4")])

    def test_unifying_pairing(self):
        table = {
            (0xFF, 0x83, 0xB5, 0x20): [0x20, 0x08, 0x14, 0x40, 0x66, 0, 0, 0x01],
            (0xFF, 0x83, 0xB5, 0x40): [0x40, 0x05] + list(b"Craft"),
        }
        rec = ld.Receiver(FakeNode(table), "unifying")
        self.assertEqual(rec.paired(), [(1, 0x4066, 1, "Craft")])

    def test_offline_device_ping(self):
        node = FakeNode({(1, 0x00, 0x10 | ld.SW_ID, 0): ld.HidppError(ld.ERR_RESOURCE)})
        self.assertIsNone(ld.Device(node, 1).ping())

    def test_unified_battery_and_writes(self):
        sw = ld.SW_ID
        table = {
            (2, 0x00, sw, 0x10): [0x08, 0, 3],          # UNIFIED_BATTERY at index 8
            (2, 0x08, 0x10 | sw, None): [42, 4, 1, 1],  # 42 %, good, charging, external power
            (2, 0x00, sw, 0x22): [0x0C, 0, 0],          # 0x2201 DPI at index 12 (getFeature 0x22,0x01)
            (2, 0x0C, 0x30 | sw, 0): [0, 0x06, 0x40],
        }
        node = FakeNode(table)
        dev = ld.Device(node, 2)
        b = dev.battery()
        self.assertEqual((b["percent"], b["level"], b["charging"]), (42, "good", True))
        dev.set_dpi(1600)
        self.assertEqual(node.sent[-1], (2, 0x0C, 0x30 | sw, bytes([0, 0x06, 0x40])))

    def test_settings_store_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x", "settings.json")
            s = ld.SettingsStore(path)
            s.put("b042", "dpi", 1600)
            self.assertEqual(ld.SettingsStore(path).get("b042"), {"dpi": 1600})
            with open(path) as f:
                self.assertEqual(json.load(f), {"b042": {"dpi": 1600}})


UPOWER_DUMP = """Device: /org/freedesktop/UPower/devices/battery_BAT0
  native-path:          BAT0
  power supply:         yes
  battery
    present:             yes
    state:               discharging
    percentage:          80%

Device: /org/freedesktop/UPower/devices/touchpad_dev_AA_BB_CC_DD_EE_FF
  native-path:          /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
  model:                Magic Trackpad
  power supply:         no
  touchpad
    present:             yes
    state:               discharging
    warning-level:       none
    percentage:          22%

Device: /org/freedesktop/UPower/devices/headphones_dev_11_22_33_44_55_66
  native-path:          /org/bluez/hci0/dev_11_22_33_44_55_66
  model:                <b>Galaxy Buds</b>
  power supply:         no
  headphones
    present:             yes
    state:               charging
    percentage:          60%

Device: /org/freedesktop/UPower/devices/mouse_hidpp_battery_0
  native-path:          hidpp_battery_0
  model:                MX Master 4
  mouse
    present:             yes
    percentage:          100%

Device: /org/freedesktop/UPower/devices/mouse_hid_aa_bb_cc_dd_ee_01_battery
  native-path:          hid-aa:bb:cc:dd:ee:01-battery
  model:                MX Master 4
  mouse
    present:             yes
    state:               discharging
    percentage:          99%

Device: /org/freedesktop/UPower/devices/gaming_input_dev_3C
  native-path:          /org/bluez/hci0/dev_3C
  model:                Xbox Wireless Controller
  gaming-input
    present:             yes
    state:               discharging
    battery-level:       low
    percentage:          10%

Device: /org/freedesktop/UPower/devices/DisplayDevice
  power supply:         no
  unknown
    percentage:          0%

Daemon:
  daemon-version:  1.91.3
"""


class UPower(unittest.TestCase):
    def test_parse_peripherals(self):
        devs = {d["name"]: d for d in ld.parse_upower(UPOWER_DUMP)}
        self.assertNotIn("BAT0", str(devs))            # laptop battery skipped
        pad = devs["Magic Trackpad"]
        self.assertEqual((pad["kind"], pad["battery"]["percent"], pad["connection"]), ("touchpad", 22, "Bluetooth"))
        buds = devs["bGalaxy Buds/b"]
        self.assertEqual(buds["kind"], "headset")
        self.assertTrue(buds["battery"]["charging"])
        pad_level = devs["Xbox Wireless Controller"]["battery"]
        self.assertEqual((pad_level["level"], pad_level["percent"]), ("low", 10))
        # hidpp_battery entries are skipped; the hid-<mac>-battery one is Bluetooth
        self.assertEqual(devs["MX Master 4"]["connection"], "Bluetooth")
        self.assertEqual(sum(1 for d in ld.parse_upower(UPOWER_DUMP) if d["name"] == "MX Master 4"), 1)

    def test_merge_skips_devices_hidpp_already_shows(self):
        hidpp = [{"name": "MX Master 4"}]
        merged = ld.merge_upower(hidpp, ld.parse_upower(UPOWER_DUMP))
        self.assertNotIn("MX Master 4", [d["name"] for d in merged])
        self.assertIn("Magic Trackpad", [d["name"] for d in merged])

    def test_empty_dump(self):
        self.assertEqual(ld.parse_upower(""), [])


if __name__ == "__main__":
    unittest.main()
