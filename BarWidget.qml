pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "I18n.js" as I18n

// Bar indicator for Logitech mice and keyboards and other battery-powered peripherals:
// a mouse glyph in the theme's green while every connected battery is fine, orange when
// one runs low and red when one is critical (thresholds in the panel's settings, 25 % and
// 10 % by default); charging devices don't count. The glyph switches to the device
// running low (keyboard, trackpad, earphones, ...); mouse on a tie. Dim while no device
// is connected. Left click opens the panel; right click refreshes. All device
// traffic goes through scripts/bluetooth-monitor.py (HID++ over /dev/hidraw), which
// receives JSON commands on stdin and streams JSON snapshots on stdout.
Ui.BarWidget {
  id: root
  moduleName: "ubruckhaus.bluetooth-monitor"

  // Interface language: the system's unless one is picked in the panel's settings.
  // Options live in this widget's own shell.json entry, like the language.
  readonly property string systemLang: I18n.systemLanguage(Quickshell.env("LC_ALL"), Quickshell.env("LC_MESSAGES"), Quickshell.env("LANG"))
  readonly property string languageSetting: String(root.setting("language", "auto"))
  readonly property string lang: I18n.resolve(languageSetting, systemLang)
  function t(key, args) { return I18n.tr(lang, key, args) }
  function tn(key, n, args) { return I18n.trn(lang, key, n, args) }
  readonly property int lowAt: Number(root.setting("lowAt", 25))
  readonly property int criticalAt: Number(root.setting("criticalAt", 10))
  readonly property bool otherDevices: root.setting("otherDevices", true) !== false
  // value === defaultValue removes the key, so shell.json only holds real choices.
  function setOption(key, value, defaultValue) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = Object.assign({}, root.settings || {})
    if (value === defaultValue) delete next[key]
    else next[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, next)
  }
  function setLanguage(code) { setOption("language", code, "auto") }
  // Devices hidden by hand in the panel (like Launch & Bind's hidden apps), by their
  // stable key (model id or serial), not the per-boot hidraw id. Hidden devices leave
  // the bar's icon and tooltip too, so an ignored device never warns.
  readonly property var hidden: {
    // From shell.json at startup the list arrives as a Qt sequence, not a JS array
    // (Array.isArray() is false for it), so copy it item by item.
    var h = root.setting("hidden", [])
    var out = []
    if (h && typeof h !== "string" && typeof h.length === "number")
      for (var i = 0; i < h.length && i < 500; i++) out.push(String(h[i]))
    return out
  }
  function deviceKey(d) { return String(d.key || d.id || "") }
  function isHidden(d) { return root.hidden.indexOf(deviceKey(d)) >= 0 }
  function setHidden(d, on) {
    var k = deviceKey(d)
    if (!k) return
    var next = root.hidden.filter(function(x) { return x !== k })
    if (on) next.push(k)
    next.sort()
    setOption("hidden", next.length ? next : undefined, undefined)
  }
  onOtherDevicesChanged: send({ cmd: "options", other_devices: root.otherDevices })

  property var stats: ({})
  // Push every snapshot into the panel; never let it read from an older widget instance.
  onStatsChanged: if (panelLoader.item && "stats" in panelLoader.item) panelLoader.item.stats = root.stats
  readonly property var devices: (stats.devices || []).filter(function(d) { return !root.isHidden(d) })
  readonly property int onlineCount: {
    var n = 0
    for (var i = 0; i < devices.length; i++) if (devices[i].online) n++
    return n
  }
  // "ok" | "low" | "critical" for one device's battery (percent if known, else its level).
  function batteryState(b) {
    if (!b || b.charging) return "ok"
    var p = b.percent
    if (p !== null && p !== undefined) return p <= root.criticalAt ? "critical" : (p <= root.lowAt ? "low" : "ok")
    return b.level === "critical" || b.level === "empty" ? "critical" : (b.level === "low" ? "low" : "ok")
  }
  // The worst state among connected devices, and which device kind it belongs to. On a
  // tie (or while all is fine) a mouse wins, so the icon stays a mouse unless a
  // keyboard (or another device) is lower.
  readonly property var batteryAlert: {
    var rank = { ok: 0, low: 1, critical: 2 }
    var best = { state: "ok", kind: "mouse" }
    for (var i = 0; i < devices.length; i++) {
      if (!devices[i].online) continue
      var s = batteryState(devices[i].battery)
      if (rank[s] > rank[best.state] || (rank[s] === rank[best.state] && rank[s] > 0 && devices[i].kind === "mouse"))
        best = { state: s, kind: devices[i].kind }
    }
    return best
  }
  function kindGlyph(kind) {
    switch (kind) {
    case "keyboard": return "󰌌"
    case "numpad": return "󰎠"
    case "touchpad": return "󰟸"
    case "headset": return "󰋋"
    case "speaker": return "󰓃"
    case "presenter": return "󰐯"
    case "remote": return "󰑔"
    case "gamepad": case "joystick": return "󰊴"
    case "tablet": case "pen": return "󰏪"
    case "phone": return "󰏲"
    case "wearable": return "󰖉"
    case "camera": return "󰄀"
    default: return "󰍽"
    }
  }
  function stateColor(s) { return s === "critical" ? root.red : (s === "low" ? root.orange : root.green) }

  // Theme colours (colors.toml), like the other status indicators in the bar.
  property color green: "#66c98b"
  property color orange: "#f0a35e"
  property color red: Color.urgent
  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var t = text()
      function pick(name) { var m = t.match(new RegExp("^\\s*" + name + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m")); return m ? m[1] : "" }
      if (pick("green")) root.green = pick("green")
      if (pick("orange")) root.orange = pick("orange")
      else if (pick("yellow")) root.orange = pick("yellow")
      if (pick("red")) root.red = pick("red")
    }
  }
  readonly property string scriptDir: Qt.resolvedUrl("scripts").toString().replace(/^file:\/\//, "")
  property bool allowing: false

  function batteryText(dev) {
    var b = dev.battery
    if (!b) return ""
    var t = b.percent !== null && b.percent !== undefined ? b.percent + "%" : b.level
    if (b.charging) t += " ⚡"
    return t
  }

  function deviceName(d) { return d.name || t("unnamed") }

  readonly property string summary: {
    if (stats.phase === "permission") return "Bluetooth Monitor\n" + t("tipAccess")
    if (stats.phase === "none") return "Bluetooth Monitor\n" + t("tipNone")
    var lines = ["Bluetooth Monitor"]
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (!d.online) continue
      lines.push("● " + deviceName(d) + (d.battery ? "  " + batteryText(d) : ""))
    }
    return lines.join("\n")
  }

  function send(obj) {
    if (helper.running) helper.write(JSON.stringify(obj) + "\n")
  }

  // One polkit prompt installs the uaccess udev rule (scripts/allow-access.sh).
  function allowAccess() {
    if (allowing) return
    allowing = true
    allowProc.running = true
  }
  Process {
    id: allowProc
    command: ["pkexec", "/bin/bash", root.scriptDir + "/allow-access.sh"]
    onExited: { root.allowing = false; root.send({ cmd: "refresh" }) }
  }

  Process {
    id: helper
    command: ["python3", root.scriptDir + "/bluetooth-monitor.py"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        try { root.stats = JSON.parse(line) } catch (e) { /* partial line during shutdown */ }
      }
    }
    onRunningChanged: if (running) Qt.callLater(function() {
      root.send({ cmd: "options", other_devices: root.otherDevices })
      if (root.opened) root.send({ cmd: "open" })
    })
    onExited: restart.start()
  }
  Timer { id: restart; interval: 5000; onTriggered: helper.running = true }
  onOpenedChanged: send({ cmd: root.opened ? "open" : "closed" })

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("stats" in target) target.stats = root.stats
  }

  // Shape contract for shell summon/hide/toggle routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml") + "?load=" + Date.now()
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.kindGlyph(root.batteryAlert.kind)
    dimmed: root.onlineCount === 0
    foreground: root.onlineCount === 0 ? (root.bar ? root.bar.barForeground : Color.foreground) : root.stateColor(root.batteryAlert.state)
    tooltipText: root.opened ? "" : root.summary
    onPressed: function(code) {
      if (code === Qt.LeftButton) root.toggle()
      else if (code === Qt.RightButton) root.send({ cmd: "refresh" })
    }
  }
}
