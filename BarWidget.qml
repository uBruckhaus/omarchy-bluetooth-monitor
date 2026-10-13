pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui

// Bar indicator for Logitech mice and keyboards: a mouse glyph with the lowest battery
// among connected devices. Turns urgent below 15 % (unless charging), dim while no
// device is connected. Left click opens the panel; right click refreshes. All device
// traffic goes through scripts/logitech-devices.py (HID++ over /dev/hidraw), which
// receives JSON commands on stdin and streams JSON snapshots on stdout.
Ui.BarWidget {
  id: root
  moduleName: "ubruckhaus.logitech-devices"

  property var stats: ({})
  // Push every snapshot into the panel; never let it read from an older widget instance.
  onStatsChanged: if (panelLoader.item && "stats" in panelLoader.item) panelLoader.item.stats = root.stats
  readonly property var devices: stats.devices || []
  readonly property var lowest: stats.lowest || null
  readonly property int onlineCount: {
    var n = 0
    for (var i = 0; i < devices.length; i++) if (devices[i].online) n++
    return n
  }
  readonly property bool low: lowest !== null && lowest.percent <= 15 && !lowest.charging
  readonly property bool showPercent: root.setting("showPercent", true) !== false
  readonly property string scriptDir: Qt.resolvedUrl("scripts").toString().replace(/^file:\/\//, "")
  property bool allowing: false

  function batteryText(dev) {
    var b = dev.battery
    if (!b) return ""
    var t = b.percent !== null && b.percent !== undefined ? b.percent + "%" : b.level
    if (b.charging) t += " ⚡"
    return t
  }

  readonly property string summary: {
    if (stats.phase === "permission") return "Logitech Devices\nNo access to the receivers yet. Click to allow it."
    if (stats.phase === "none") return "Logitech Devices\nNo Logitech receiver or device found."
    var lines = ["Logitech Devices"]
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      lines.push((d.online ? "● " : "○ ") + d.name + (d.online ? (d.battery ? "  " + batteryText(d) : "") : "  · off"))
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
    command: ["python3", root.scriptDir + "/logitech-devices.py"]
    running: true
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        try { root.stats = JSON.parse(line) } catch (e) { /* partial line during shutdown */ }
      }
    }
    onRunningChanged: if (running && root.opened) Qt.callLater(function() { root.send({ cmd: "open" }) })
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
    text: "󰍽" + (root.showPercent && root.lowest ? " " + root.lowest.percent + "%" : "")
    dimmed: root.onlineCount === 0
    foreground: root.low ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: root.opened ? "" : root.summary
    onPressed: function(code) {
      if (code === Qt.LeftButton) root.toggle()
      else if (code === Qt.RightButton) root.send({ cmd: "refresh" })
    }
  }
}
