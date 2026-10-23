pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "I18n.js" as I18n

// Logitech Devices popup: one card per device (battery, connection) that expands to
// its settings (DPI, SmartShift, scroll wheel, Fn keys), then the receivers with their
// free pairing slots. The gear opens the settings page (language, warning levels,
// which devices to show, receiver access); back with the button, Backspace or Esc. Repeaters are driven by counts and read the current snapshot by
// index, so a refresh never rebuilds rows (a slider drag survives every snapshot).
Panel {
  id: root
  moduleName: "ubruckhaus.bluetooth-monitor"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var stats: ({})  // pushed by BarWidget on every snapshot
  readonly property string phase: String(stats.phase || "starting")
  readonly property var allDevices: stats.devices || []
  // Every device, connected or switched off, unless hidden by hand with its eye button
  // (like Launch & Bind's hidden apps; kept in shell.json). The eye in the header shows
  // the hidden ones too, dimmed, until the panel closes.
  property bool showHidden: false
  function isHidden(dev) { return !!root.hostWidget && root.hostWidget.isHidden(dev) }
  function setHidden(dev, on) { if (root.hostWidget) root.hostWidget.setHidden(dev, on) }
  readonly property var shownDevices: allDevices.filter(function(d) { return !root.isHidden(d) })
  readonly property var devices: showHidden ? allDevices : shownDevices
  readonly property int hiddenCount: allDevices.length - shownDevices.length
  // Lowest battery among connected devices that are not hidden.
  readonly property var lowest: {
    var best = null
    for (var i = 0; i < shownDevices.length; i++) {
      var d = shownDevices[i], b = d.battery
      if (!d.online || !b || b.percent === null || b.percent === undefined) continue
      if (!best || b.percent < best.percent) best = { percent: b.percent }
    }
    return best
  }
  readonly property var receivers: stats.receivers || []
  property var expanded: ({})   // device id -> true while its settings are shown
  property bool settingsOpen: false
  property bool infoOpen: false
  readonly property string lang: hostWidget ? hostWidget.lang : "en"
  readonly property string languageSetting: hostWidget ? hostWidget.languageSetting : "auto"
  readonly property string systemLang: hostWidget ? hostWidget.systemLang : "en"
  function t(key, args) { return I18n.tr(lang, key, args) }
  function tn(key, n, args) { return I18n.trn(lang, key, n, args) }
  function deviceName(dev) { return dev.name || t("unnamed") }
  function connName(code) { return code ? t("conn_" + code) : "" }
  // Receiver access is missing while some Logitech node could not be opened.
  readonly property bool accessMissing: (stats.denied || []).length > 0
  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string font: root.bar ? root.bar.fontFamily : Style.font.family
  property color green: "#66c98b"

  function send(obj) { if (root.hostWidget) root.hostWidget.send(obj) }
  function set(dev, key, value) { send({ cmd: "set", device: dev.id, key: key, value: value }) }
  function deviceAt(i) { return i < devices.length ? devices[i] : ({ id: "", name: "", online: false }) }
  function receiverAt(i) { return i < receivers.length ? receivers[i] : ({ devices: [] }) }
  function toggleExpanded(dev) {
    var next = Object.assign({}, expanded)
    next[dev.id] = !next[dev.id]
    expanded = next
  }
  function hasSettings(dev) { return !!(dev.dpi || dev.smartshift || dev.wheel || dev.fnswap) }
  function onlineCount() {
    var n = 0
    for (var i = 0; i < shownDevices.length; i++) if (shownDevices[i].online) n++
    return n
  }

  function kindIcon(kind) {
    switch (kind) {
    case "mouse": case "trackball": return "󰍽"
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
    default: return "󰗊"
    }
  }
  function batteryIcon(b) {
    if (!b) return ""
    var p = b.percent
    if (b.charging) return "󰂄"
    if (p === null || p === undefined) return b.level === "critical" || b.level === "low" ? "󰁺" : "󰁹"
    var icons = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return icons[Math.max(0, Math.min(10, Math.round(p / 10)))]
  }
  // Same thresholds and colours as the bar icon.
  function batteryColor(b) {
    if (!b) return root.dim
    if (b.charging) return root.green
    if (!root.hostWidget) return root.fg
    var s = root.hostWidget.batteryState(b)
    return s === "ok" ? root.fg : root.hostWidget.stateColor(s)
  }
  function statusLine(dev) {
    var where = linkIcon(dev.receiver ? "dongle" : dev.connection) + " " + connName(dev.connection) + (dev.slot ? " · " + t("slotN", [dev.slot]) : "")
    if (!dev.online) return where + " · " + t("notConnected")
    var b = dev.battery
    if (b && b.charging) return where + " · " + t("charging")
    if (b && b.status === "full" && b.external_power) return where + " · " + t("charged")
    if (!b) return where + " · " + t("noBattery")
    return where
  }

  // Links for the connection tree: every dongle (numbered when there are several of a
  // kind), then the Bluetooth adapter, USB cable and other wireless devices.
  readonly property var links: {
    var out = []
    var perFamily = {}
    for (var i = 0; i < receivers.length; i++) perFamily[receivers[i].family] = (perFamily[receivers[i].family] || 0) + 1
    var seen = {}
    for (var r = 0; r < receivers.length; r++) {
      var rec = receivers[r]
      seen[rec.family] = (seen[rec.family] || 0) + 1
      var devs = devices.filter(function(d) { return d.receiver === rec.id })
      if (!devs.length && !showHidden) continue
      var paired = allDevices.filter(function(d) { return d.receiver === rec.id }).length
      out.push({ type: "dongle", label: connName(rec.family) + (perFamily[rec.family] > 1 ? " " + seen[rec.family] : ""),
                 sub: t("dongleSub", [paired, rec.max_devices]), devices: devs,
                 online: devs.filter(function(d) { return d.online }).length })
    }
    // One link per Bluetooth adapter: built into the PC, or a USB Bluetooth stick.
    var adapters = stats.adapters || []
    var btDevices = devices.filter(function(d) { return !d.receiver && d.connection === "bluetooth" })
    for (var a = 0; a < adapters.length; a++) {
      var ad = adapters[a]
      var mine = btDevices.filter(function(d) { return d.adapter === ad.id || (!d.adapter && a === 0) })
      if (!mine.length && !showHidden) continue
      out.push({ type: "bluetooth", builtin: ad.builtin,
                 label: ad.builtin ? t("btBuiltin") : t("btDongle") + (adapters.length > 1 ? " " + (a + 1) : ""),
                 sub: (ad.builtin ? t("btBuiltinSub") : t("btDongleSub")) + (ad.vendor ? " · " + ad.vendor : ""),
                 devices: mine, online: mine.filter(function(d) { return d.online }).length })
    }
    var groups = adapters.length ? [] : [["bluetooth", t("btAdapter")]]
    groups = groups.concat([["usb", connName("usb")], ["wireless", connName("wireless")]])
    for (var g = 0; g < groups.length; g++) {
      var code = groups[g][0]
      var list = devices.filter(function(d) { return !d.receiver && d.connection === code })
      if (list.length) out.push({ type: code, label: groups[g][1], sub: "", devices: list,
                                  online: list.filter(function(d) { return d.online }).length })
    }
    return out
  }
  function linkIcon(type) {
    switch (type) {
    case "dongle": return "󰕓"
    case "bluetooth": return "󰂯"
    case "usb": return "󰌘"
    default: return "󰖩"
    }
  }
  readonly property real nodeSize: Style.space(30)
  readonly property real linkLabelWidth: Style.space(118)
  property string hostName: ""
  FileView {
    path: "/etc/hostname"
    onLoaded: root.hostName = text().trim().slice(0, 40)
  }

  function open() { root.controller.show() }
  function close() { root.infoOpen = false; root.controller.hide() }
  // However the panel closes (Esc, a click outside, another panel, the bar icon), it
  // opens again on the device list with the hidden devices hidden.
  onOpenedChanged: if (!root.opened) { root.settingsOpen = false; root.showHidden = false; root.btOpen = false }
  function toggle() { if (root.opened) root.close(); else root.open() }

  // ------------------------------------------------------------ Bluetooth page
  // Pair, connect, forget and power, like Omarchy's own Bluetooth panel (which can be
  // turned off then). The actions go through Omarchy's helpers with a fixed argv; rows
  // hold plain values only, never the BlueZ device objects (they can vanish mid-update).
  property bool btOpen: false
  onBtOpenChanged: root.confirmForget = ""
  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property bool btEnabled: !!root.btAdapter && root.btAdapter.enabled
  readonly property bool btScanning: root.btEnabled && scanProcess.running
  readonly property var btDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  property var btPending: ({})        // address -> "connecting" | "disconnecting" | "forgetting"
  property string confirmForget: ""   // address waiting for the second click on Forget
  property var audioTarget: null      // device just connected; its sink becomes the default
  property int audioTries: 0

  // The alias first: a name you gave the device wins over the one it reports.
  function btName(d) { return String(d.name || d.deviceName || "").trim() }
  function btHumanName(d) {
    var n = btName(d)
    return n !== "" && !/^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(n)
      && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(n)
  }
  function btRow(d, section) {
    return { address: String(d.address || ""), name: btName(d), icon: String(d.icon || ""), section: section,
             connected: !!d.connected, state: d.state !== undefined ? d.state : -1, pairing: !!d.pairing,
             battery: d.batteryAvailable ? Math.round(d.battery * 100) : -1 }
  }
  readonly property var btRows: {
    var connected = [], paired = [], found = []
    for (var i = 0; i < btDevices.length; i++) {
      var d = btDevices[i]
      if (!d || !btHumanName(d)) continue
      if (d.connected) connected.push(btRow(d, "connected"))
      else if (d.paired || d.bonded || d.trusted) paired.push(btRow(d, "paired"))
      else if (root.btScanning) found.push(btRow(d, "available"))
    }
    var byName = function(a, b) { return a.name.localeCompare(b.name) }
    // A crowded place can show hundreds of devices; the nearest 40 by name are plenty.
    return { connected: connected.sort(byName), paired: paired.sort(byName), available: found.sort(byName).slice(0, 40) }
  }
  function btDevice(address) {
    for (var i = 0; i < btDevices.length; i++) if (btDevices[i] && btDevices[i].address === address) return btDevices[i]
    return null
  }
  function btKindIcon(icon, connected) {
    var s = String(icon)
    if (s.indexOf("audio-head") === 0) return "󰋋"
    if (s.indexOf("audio") === 0) return "󰓃"
    if (s.indexOf("input-mouse") === 0) return "󰍽"
    if (s.indexOf("input-keyboard") === 0) return "󰌌"
    if (s.indexOf("input-gaming") === 0) return "󰊴"
    if (s.indexOf("input-tablet") === 0) return "󰟸"   // BlueZ calls trackpads tablets
    if (s.indexOf("video") === 0) return "󰔂"
    if (s.indexOf("phone") === 0) return "󰏲"
    if (s.indexOf("computer") === 0) return "󰇄"
    return connected ? "󰂱" : "󰂯"
  }
  function setBtPending(address, action) {
    var next = Object.assign({}, btPending)
    if (action) next[address] = action
    else delete next[address]
    btPending = next
    if (action) btPendingTimeout.restart()
  }
  function btRun(action, address, pending) {
    // BlueZ addresses only; anything else never reaches the helper.
    if (!/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(address)) return
    setBtPending(address, pending)
    Quickshell.execDetached(["omarchy-bluetooth-device", action, address])
  }
  function btConnect(row) {
    var d = btDevice(row.address)
    if (!d || d.connected) return
    btRun(row.section === "available" ? "pair" : "connect", row.address, "connecting")
  }
  function btDisconnect(row) {
    var d = btDevice(row.address)
    if (!d || !d.connected) return
    btRun("disconnect", row.address, "disconnecting")
  }
  function btForget(row) {
    if (root.confirmForget !== row.address) { root.confirmForget = row.address; return }
    root.confirmForget = ""
    btRun("forget", row.address, "forgetting")
  }
  // The rfkill block survives a reboot; BlueZ's Powered would not.
  function btPower(on) { Quickshell.execDetached(["omarchy-bluetooth-power", on ? "on" : "off"]) }
  onBtDevicesChanged: syncBtPending()
  onBtRowsChanged: syncBtPending()
  function syncBtPending() {
    var next = Object.assign({}, btPending), changed = false
    for (var address in next) {
      var d = btDevice(address), action = next[address]
      var connectedNow = action === "connecting" && d && d.connected
      if (connectedNow || (action === "disconnecting" && d && !d.connected)
          || (action === "forgetting" && (!d || (!d.paired && !d.bonded && !d.trusted)))) {
        if (connectedNow) { root.audioTarget = { address: address, name: btName(d) }; root.audioTries = 0; audioSwitch.restart() }
        delete next[address]
        changed = true
      }
    }
    if (changed) btPending = next
  }
  // A headset or speaker that just connected becomes the default output, as in Omarchy's panel.
  function switchAudio() {
    if (!root.audioTarget) return
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var addr = root.audioTarget.address.toLowerCase().replace(/[^0-9a-f]/g, "")
    var name = root.audioTarget.name.toLowerCase()
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream) continue
      var p = n.ready && n.properties ? n.properties : {}
      var text = [n.name, n.description, n.nickname, p["node.name"], p["node.description"], p["device.description"],
                  p["api.bluez5.address"]].join(" ").toLowerCase()
      if ((addr && text.replace(/[^0-9a-f]/g, "").indexOf(addr) !== -1) || (name && text.indexOf(name) !== -1)) {
        Pipewire.preferredDefaultAudioSink = n
        // A numeric id and a plain sink name only, so nothing reaches wpctl/pactl as an option.
        if (/^[0-9]{1,9}$/.test(String(n.id)) && /^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,199}$/.test(String(n.name || "")))
          Quickshell.execDetached(["omarchy-audio-output-set-default", String(n.id), String(n.name)])
        root.audioTarget = null
        return
      }
    }
    if (++root.audioTries >= 8) root.audioTarget = null
    else audioSwitch.restart()
  }
  Timer { id: audioSwitch; interval: 500; onTriggered: root.switchAudio() }
  Timer { id: btPendingTimeout; interval: 20000; onTriggered: root.btPending = ({}) }
  // Scan only while the Bluetooth page is on screen, through bluetoothctl's own
  // discovery session: BlueZ ends it the moment the process exits, so closing the
  // page (or the shell) always stops it; an endless scan makes Bluetooth audio
  // stutter. Quickshell's adapter.discovering is not used for this: it stays stale
  // while another program (another plugin's scan) holds a session, so the start
  // and stop it drives can both be lost. The timeout is a backstop; a page still
  // open after it starts a new scan.
  readonly property bool wantScan: root.opened && root.btOpen && root.btEnabled
  onWantScanChanged: scanProcess.running = root.wantScan
  Process {
    id: scanProcess
    command: ["bluetoothctl", "--timeout", "300", "scan", "on"]
    stdout: SplitParser { onRead: function(_line) {} }
    stderr: SplitParser { onRead: function(_line) {} }
    onExited: if (root.wantScan) Qt.callLater(function() { scanProcess.running = root.wantScan })
  }
  Component.onDestruction: scanProcess.running = false

  // The theme's green (colors.toml) for charging batteries, like the bar's running indicators.
  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      var match = text().match(/^\s*green\s*=\s*"(#[0-9a-fA-F]{6})"/m)
      if (match) root.green = match[1]
    }
  }

  // A labelled row: caption on the left, any control on the right.
  component SettingRow: Item {
    id: row
    property string label: ""
    property string hint: ""
    default property alias control: slot.data
    width: parent ? parent.width : 0
    height: Math.max(labels.implicitHeight, slot.childrenRect.height)
    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: slot.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: row.label
        color: root.fg
        font.family: root.font
        font.pixelSize: Style.font.caption
      }
      Text {
        visible: row.hint !== ""
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: row.hint
        color: root.dim
        font.family: root.font
        font.pixelSize: Style.font.caption * 0.9
      }
    }
    Item {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  // One Bluetooth device: kind icon, name and state, then its action and Forget (asks twice).
  component BtRow: Item {
    id: btRow
    property var row: ({})
    readonly property string pending: root.btPending[row.address] || ""
    readonly property bool busy: pending !== "" || row.state === 2 || row.state === 3 || row.pairing
    readonly property bool asking: root.confirmForget === row.address
    height: Math.max(btInfo.implicitHeight, btActions.implicitHeight) + Style.space(4)
    Text {
      id: btIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(26)
      textFormat: Text.PlainText
      text: root.btKindIcon(btRow.row.icon, btRow.row.connected)
      color: btRow.row.connected ? Commons.Color.accent : root.dim
      font.family: root.font
      font.pixelSize: Style.font.title
    }
    Column {
      id: btInfo
      anchors.left: btIcon.right
      anchors.leftMargin: Style.space(6)
      anchors.right: btActions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: btRow.row.name
        color: root.fg
        font.family: root.font
        font.pixelSize: Style.font.body
      }
      Text {
        readonly property string status: btRow.pending === "forgetting" ? root.t("btForgetting")
          : btRow.pending === "disconnecting" || btRow.row.state === 2 ? root.t("btDisconnecting")
          : btRow.row.connected ? (btRow.row.battery >= 0 ? btRow.row.battery + " %" : "")
          : btRow.pending === "connecting" || btRow.row.state === 3 || btRow.row.pairing ? root.t("btConnecting") : ""
        visible: status !== ""
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: status
        color: btRow.busy ? Commons.Color.accent : root.dim
        font.family: root.font
        font.pixelSize: Style.font.caption
      }
    }
    Row {
      id: btActions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)
      Button {
        visible: btRow.row.section !== "available"
        text: btRow.asking ? root.t("btReallyForget") : ""
        iconText: "󰅙"
        bordered: true
        foreground: btRow.asking ? Commons.Color.urgent : root.fg
        fontFamily: root.font
        fontSize: Style.font.caption
        tooltipText: btRow.asking ? "" : root.t("btForget")
        enabled: btRow.pending === ""
        onClicked: root.btForget(btRow.row)
      }
      Button {
        text: btRow.row.connected ? root.t("btDisconnect") : btRow.row.section === "available" ? root.t("btPair") : root.t("btConnect")
        iconText: btRow.row.connected ? "󰂲" : "󰂱"
        bordered: true
        foreground: root.fg
        fontFamily: root.font
        fontSize: Style.font.caption
        enabled: !btRow.busy
        onClicked: btRow.row.connected ? root.btDisconnect(btRow.row) : root.btConnect(btRow.row)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Open dropdown lists take their own keys.
      blocked: languagePicker.popupOpen || lowPicker.popupOpen || criticalPicker.popupOpen
      onCloseRequested: { if (root.infoOpen) root.infoOpen = false; else if (root.settingsOpen) root.settingsOpen = false; else if (root.btOpen) root.btOpen = false; else root.close() }
      onTextKey: function(text) {
        if (text === "\b" && root.infoOpen) { root.infoOpen = false; return }
        if (text !== "\b") return
        if (root.settingsOpen) root.settingsOpen = false
        else if (root.btOpen) root.btOpen = false
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(10)

          PanelHero {
            foreground: root.fg
            fontFamily: root.font
            title: "Bluetooth Monitor"
            meta: root.phase === "ok"
              ? root.t("connectedOf", [root.onlineCount(), root.shownDevices.length]) + (root.receivers.length ? " · " + root.tn("receiversN", root.receivers.length, [root.receivers.length]) : "")
              : root.phase === "permission" ? root.t("accessNeeded") : root.phase === "none" ? root.t("nothingFound") : root.t("looking")
            detail: root.lowest ? root.t("lowestBattery", [root.lowest.percent]) : ""
            trailingControl: Component {
              // As tall as the hero text, with the gear centred on the title
              // row so it lines up with the detail pill.
              Item {
                visible: !root.settingsOpen && !root.btOpen && !root.infoOpen
                implicitWidth: gearButton.x + gearButton.width
                implicitHeight: heroTitle.implicitHeight + Style.space(2) + heroMeta.implicitHeight
                Text { id: heroTitle; visible: false; textFormat: Text.PlainText; text: "W"; font.family: root.font; font.pixelSize: Style.font.title; font.bold: true }
                Text { id: heroBody; visible: false; textFormat: Text.PlainText; text: "W"; font.family: root.font; font.pixelSize: Style.font.body; font.bold: true }
                Text { id: heroMeta; visible: false; textFormat: Text.PlainText; text: "W"; font.family: root.font; font.pixelSize: Style.font.caption; font.bold: true }
                // Eye: show / hide the hidden devices; the count says how many there are.
                Button {
                  id: eyeButton
                  visible: root.hiddenCount > 0 || root.showHidden
                  width: visible ? implicitWidth : -Style.space(6)
                  y: Math.round((heroTitle.implicitHeight - height) / 2)
                  height: heroBody.implicitHeight + Style.space(4)
                  iconText: root.showHidden ? "󰈉" : "󰈈"
                  text: root.showHidden ? "" : String(root.hiddenCount)
                  selected: root.showHidden
                  bordered: true
                  iconSize: Style.font.body
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(5)
                  verticalPadding: Style.space(1)
                  foreground: root.fg
                  fontFamily: root.font
                  tooltipText: root.showHidden ? root.t("hideHidden") : root.t("showHidden", [root.hiddenCount])
                  onClicked: root.showHidden = !root.showHidden
                }
                Button {
                  id: infoButton
                  x: eyeButton.width + Style.space(6)
                  y: gearButton.y
                  height: gearButton.height
                  width: height
                  iconText: "\u{F02FC}"
                  bordered: true
                  iconSize: Style.font.body
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(1)
                  foreground: root.fg
                  fontFamily: root.font
                  tooltipText: root.t("information")
                  onClicked: root.infoOpen = true
                }
                Button {
                  id: gearButton
                  x: infoButton.x + infoButton.width + Style.space(6)
                  y: Math.round((heroTitle.implicitHeight - height) / 2)
                  // The pill is its body text plus Style.space(4); a square gear of that height.
                  height: heroBody.implicitHeight + Style.space(4)
                  width: height
                  iconText: "\udb81\udc93"
                  bordered: true
                  iconSize: Style.font.body
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(1)
                  foreground: root.fg
                  fontFamily: root.font
                  tooltipText: root.t("settings")
                  onClicked: root.settingsOpen = true
                }
              }
            }
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰍽"
                color: root.onlineCount() > 0 ? Commons.Color.accent : root.dim
                font.family: root.font
                font.pixelSize: Style.font.display
              }
            }
          }


          // ---------------------------------------------------------------- information
          Column {
            visible: root.infoOpen
            width: parent.width
            spacing: Style.space(12)

            PanelSeparator { width: parent.width; foreground: root.fg }

            Row {
              spacing: Style.space(12)
              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: root.t("back") + " · \u232b"
                iconText: "\udb80\udc4d"
                bordered: true
                foreground: root.fg
                fontFamily: root.font
                tooltipText: root.t("backTip")
                onClicked: root.infoOpen = false
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.t("information").toUpperCase()
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
            }
            PanelSeparator { width: parent.width; foreground: root.fg }

            MorePlugins {
              width: parent.width
              separated: false
              ownId: "ubruckhaus.bluetooth-monitor"
              // The list from the marketplace's catalog when the page shows (plugin_catalog.py).
              catalogScript: decodeURIComponent(Qt.resolvedUrl("plugin_catalog.py").toString().replace(/^file:\/\//, ""))
              lang: root.lang
              fg: root.fg
              dim: root.dim
              fontFamily: root.font
              onOpened: root.close()
            }
          }

          // ------------------------------------------------------------ settings
          Column {
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(12)

            PanelSeparator { width: parent.width; foreground: root.fg }

            Row {
              spacing: Style.space(12)
              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: root.t("back") + " · \u232b"
                iconText: "\udb80\udc4d"
                bordered: true
                foreground: root.fg
                fontFamily: root.font
                tooltipText: root.t("backTip")
                onClicked: root.settingsOpen = false
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.t("settings").toUpperCase()
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
            }
            PanelSeparator { width: parent.width; foreground: root.fg }

            Row {
              spacing: Style.space(10)
              Text {
                id: languageLabel
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(170)
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.t("language")
                color: root.dim
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              CompactDropdown {
                id: languagePicker
                anchors.verticalCenter: parent.verticalCenter
                // Wide enough for the longest option, plus padding and the chevron.
                width: fitWidth
                fontSize: Style.font.caption
                rowHeight: languageLabel.implicitHeight + Style.space(6)
                popupRowHeight: languageLabel.implicitHeight + Style.space(8)
                showLabel: false
                fontFamily: root.font
                options: [{ value: "auto", label: root.t("systemLanguage", [I18n.languageName(root.systemLang)]) }]
                  .concat(I18n.LANGUAGES.map(function(l) { return { value: l.code, label: l.name } }))
                value: root.languageSetting
                // Picking cuts the value binding inside the dropdown; restore it.
                onChanged: function(picked) {
                  if (root.hostWidget) root.hostWidget.setLanguage(picked)
                  languagePicker.value = Qt.binding(function() { return root.languageSetting })
                }
              }
            }

            Row {
              spacing: Style.space(10)
              Text {
                id: lowLabel
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(170)
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.t("lowAt")
                color: root.dim
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              CompactDropdown {
                id: lowPicker
                anchors.verticalCenter: parent.verticalCenter
                width: fitWidth
                fontSize: Style.font.caption
                rowHeight: languageLabel.implicitHeight + Style.space(6)
                popupRowHeight: languageLabel.implicitHeight + Style.space(8)
                showLabel: false
                fontFamily: root.font
                options: [15, 20, 25, 30, 40, 50].map(function(v) { return { value: String(v), label: root.t("atOrBelow", [v]) } })
                value: String(root.hostWidget ? root.hostWidget.lowAt : 25)
                onChanged: function(picked) {
                  if (root.hostWidget) root.hostWidget.setOption("lowAt", Number(picked), 25)
                  lowPicker.value = Qt.binding(function() { return String(root.hostWidget ? root.hostWidget.lowAt : 25) })
                }
              }
            }

            Row {
              spacing: Style.space(10)
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(170)
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.t("criticalAt")
                color: root.dim
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              CompactDropdown {
                id: criticalPicker
                anchors.verticalCenter: parent.verticalCenter
                width: fitWidth
                fontSize: Style.font.caption
                rowHeight: languageLabel.implicitHeight + Style.space(6)
                popupRowHeight: languageLabel.implicitHeight + Style.space(8)
                showLabel: false
                fontFamily: root.font
                options: [5, 10, 15, 20].map(function(v) { return { value: String(v), label: root.t("atOrBelow", [v]) } })
                value: String(root.hostWidget ? root.hostWidget.criticalAt : 10)
                onChanged: function(picked) {
                  if (root.hostWidget) root.hostWidget.setOption("criticalAt", Number(picked), 10)
                  criticalPicker.value = Qt.binding(function() { return String(root.hostWidget ? root.hostWidget.criticalAt : 10) })
                }
              }
            }


            SettingRow {
              label: root.t("otherDevices")
              hint: root.t("otherDevicesHint")
              ToggleSwitch {
                cursorRing: false
                trackHeight: Style.space(18)
                checked: !root.hostWidget || root.hostWidget.otherDevices
                foreground: root.fg
                onToggled: if (root.hostWidget) root.hostWidget.setOption("otherDevices", !root.hostWidget.otherDevices, true)
              }
            }

            SettingRow {
              label: root.t("access")
              hint: root.accessMissing ? root.t("accessMissing") : root.t("accessGranted")
              Button {
                visible: root.accessMissing
                text: root.hostWidget && root.hostWidget.allowing ? root.t("waitingPassword") : root.t("allowAccess")
                iconText: "󰌋"
                bordered: true
                foreground: root.fg
                fontFamily: root.font
                enabled: !(root.hostWidget && root.hostWidget.allowing)
                onClicked: if (root.hostWidget) root.hostWidget.allowAccess()
              }
            }
          }

          // ------------------------------------------------------------ Bluetooth
          Column {
            visible: root.btOpen && !root.settingsOpen
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: Math.max(btBackRow.implicitHeight, btPowerRow.implicitHeight)
              Row {
                id: btBackRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)
                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.t("back") + " · \u232b"
                  iconText: "\udb80\udc4d"
                  bordered: true
                  foreground: root.fg
                  fontFamily: root.font
                  tooltipText: root.t("backTip")
                  onClicked: root.btOpen = false
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.t("bluetooth").toUpperCase()
                  color: root.fg
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
              }
              Row {
                id: btPowerRow
                visible: !!root.btAdapter
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.btScanning ? root.t("btScanningShort") : root.btEnabled ? root.t("btOn") : root.t("btOffState")
                  color: root.btScanning ? Commons.Color.accent : root.dim
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
                ToggleSwitch {
                  id: btPowerSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  cursorRing: false
                  trackHeight: Style.space(18)
                  checked: root.btEnabled
                  foreground: root.fg
                  onToggled: root.btPower(!root.btEnabled)
                  PanelToolTip {
                    visible: btPowerSwitch.containsMouse
                    text: root.btEnabled ? root.t("btTurnOff") : root.t("btTurnOn")
                    fontFamily: root.font
                  }
                }
              }
            }

            Repeater {
              model: ["connected", "paired", "available"]
              Column {
                id: btSection
                required property string modelData
                readonly property var rows: root.btRows[modelData] || []
                visible: rows.length > 0
                width: parent.width
                spacing: Style.space(8)
                PanelSeparator { width: parent.width; foreground: root.fg }
                PanelSectionHeader {
                  text: root.t(btSection.modelData === "connected" ? "btSecConnected" : btSection.modelData === "paired" ? "btSecPaired" : "btSecAvailable").toUpperCase()
                  foreground: root.fg
                  fontFamily: root.font
                }
                Repeater {
                  model: btSection.rows
                  BtRow { required property var modelData; row: modelData; width: btSection.width }
                }
              }
            }

            Text {
              visible: root.btRows.connected.length + root.btRows.paired.length + root.btRows.available.length === 0 || (root.btScanning && root.btRows.available.length === 0)
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: !root.btAdapter ? root.t("btNoAdapter") : !root.btEnabled ? root.t("btOffHint") : root.t("btScanning")
              color: root.dim
              font.family: root.font
              font.pixelSize: Style.font.caption
            }
          }

          // ------------------------------------------------------------ main view
          Column {
            visible: !root.settingsOpen && !root.btOpen && !root.infoOpen
            width: parent.width
            spacing: Style.space(10)

          // ------------------------------------------------------------ setup
          Rectangle {
            visible: root.phase === "permission"
            width: parent.width
            height: setupColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.4)
            Column {
              id: setupColumn
              x: Style.space(10); y: Style.space(10)
              width: parent.width - Style.space(20)
              spacing: Style.space(8)
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.t("setupStep")
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.t("setupText")
                color: root.dim
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              Button {
                text: root.hostWidget && root.hostWidget.allowing ? root.t("waitingPassword") : root.t("allowAccess")
                iconText: "󰌋"
                bordered: true
                foreground: root.fg
                fontFamily: root.font
                enabled: !(root.hostWidget && root.hostWidget.allowing)
                onClicked: if (root.hostWidget) root.hostWidget.allowAccess()
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.phase === "none" ? root.t("noneText")
              : root.phase === "error" ? root.t("error", [String(root.stats.error || "")])
              : root.stats.message_code ? root.t(root.stats.message_code, root.stats.message_args || []) : ""
            color: root.phase === "none" ? root.dim : Commons.Color.urgent
            font.family: root.font
            font.pixelSize: Style.font.caption
          }

          // ------------------------------------------------------------ connections
          // A tree: this PC, then every link (dongle, Bluetooth adapter, cable) on a solid
          // line (plugged in), then its devices on a dotted line (radio) with their battery.
          PanelSeparator { visible: root.links.length > 0; width: parent.width; foreground: root.fg }
          PanelSectionHeader { visible: root.links.length > 0; text: root.t("connections").toUpperCase(); foreground: root.fg; fontFamily: root.font }

          Item {
            visible: root.links.length > 0
            width: parent.width
            height: pcRow.height
            Rectangle {
              id: pcBadge
              width: root.nodeSize; height: width
              radius: Style.cornerRadius > 0 ? width / 2 : 0
              color: Commons.Color.accent
              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "󰍹"
                color: Commons.Color.background
                font.family: root.font
                font.pixelSize: Style.font.body
              }
            }
            Row {
              id: pcRow
              x: pcBadge.width + Style.space(10)
              height: pcBadge.height
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.t("thisPc") + (root.hostName ? "  ·  " + root.hostName : "")
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Repeater {
            model: root.links.length
            delegate: Item {
              id: linkRow
              required property int index
              readonly property var link: root.links[index] || ({ devices: [] })
              readonly property bool last: index === root.links.length - 1
              readonly property bool live: link.online > 0
              readonly property color lineColor: live ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
              readonly property real trunkX: root.nodeSize / 2 - 1
              readonly property real badgeX: root.nodeSize + Style.space(8)
              width: column.width
              height: Math.max(linkHead.height, chips.height) + Style.space(10)

              // Trunk from the PC down to this link (and on to the next one).
              Rectangle {
                x: linkRow.trunkX
                y: -column.spacing
                width: 2
                height: (linkRow.last ? linkHead.height / 2 : linkRow.height) + column.spacing
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
              }
              // Solid branch: the dongle / adapter is plugged into this PC.
              Rectangle {
                x: linkRow.trunkX
                y: linkHead.height / 2 - 1
                width: linkRow.badgeX - linkRow.trunkX
                height: 2
                color: linkRow.lineColor
              }

              Row {
                id: linkHead
                x: linkRow.badgeX
                spacing: Style.space(8)
                Rectangle {
                  id: linkBadge
                  width: root.nodeSize; height: width
                  radius: Style.cornerRadius > 0 ? Style.space(6) : 0
                  color: linkRow.live ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.2) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
                  border.width: 1
                  border.color: linkRow.lineColor
                  // Small corner mark for Bluetooth: built into the PC, or a USB stick.
                  Rectangle {
                    visible: linkRow.link.type === "bluetooth" && linkRow.link.builtin !== undefined
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: -Style.space(4)
                    width: Style.space(15); height: width
                    radius: width / 2
                    color: Commons.Color.popups.background
                    border.width: 1
                    border.color: linkRow.lineColor
                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: linkRow.link.builtin ? "󰍹" : "󰕓"
                      color: linkRow.live ? root.fg : root.dim
                      font.family: root.font
                      font.pixelSize: Style.font.caption * 0.7
                    }
                    z: 1
                  }
                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.linkIcon(linkRow.link.type)
                    color: linkRow.live ? root.fg : root.dim
                    font.family: root.font
                    font.pixelSize: Style.font.body
                  }
                }
                Column {
                  anchors.verticalCenter: linkBadge.verticalCenter
                  width: root.linkLabelWidth
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: linkRow.link.label
                    color: linkRow.live ? root.fg : root.dim
                    font.family: root.font
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    visible: text !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: linkRow.link.sub
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    color: root.dim
                    font.family: root.font
                    font.pixelSize: Style.font.caption * 0.85
                  }
                }
              }

              // Devices hang off the link on dotted lines: they talk to it by radio.
              Column {
                id: chips
                x: linkRow.badgeX + root.nodeSize + Style.space(8) + root.linkLabelWidth + Style.space(6)
                width: linkRow.width - x
                spacing: Style.space(4)
                Repeater {
                  model: linkRow.link.devices.length
                  delegate: Item {
                    id: chip
                    required property int index
                    readonly property var dev: linkRow.link.devices[index] || ({})
                    width: chips.width
                    opacity: root.isHidden(dev) ? 0.5 : 1
                    height: chipBox.height
                    // Dotted radio line from the link to the device.
                    Row {
                      id: dots
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)
                      Repeater {
                        model: 4
                        delegate: Rectangle {
                          width: Style.space(3); height: width; radius: width / 2
                          color: chip.dev.online ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
                        }
                      }
                    }
                    Rectangle {
                      id: chipBox
                      x: dots.width + Style.space(4)
                      width: parent.width - x
                      height: chipRow.implicitHeight + Style.space(8)
                      radius: Style.cornerRadius > 0 ? height / 2 : 0
                      color: chip.dev.online ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.12) : "transparent"
                      border.width: 1
                      border.color: chip.dev.online ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.45) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                      Row {
                        id: chipRow
                        x: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Style.space(16)
                        spacing: Style.space(6)
                        Text {
                          id: chipIcon
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: root.kindIcon(chip.dev.kind)
                          color: chip.dev.online ? root.fg : root.dim
                          font.family: root.font
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: parent.width - chipIcon.width - chipBattery.width - 2 * parent.spacing
                          textFormat: Text.PlainText
                          elide: Text.ElideRight
                          text: root.deviceName(chip.dev)
                          color: chip.dev.online ? root.fg : root.dim
                          font.family: root.font
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          id: chipBattery
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: !chip.dev.online ? root.t("deviceOff")
                            : chip.dev.battery ? root.batteryIcon(chip.dev.battery) + " " + (chip.dev.battery.percent !== null && chip.dev.battery.percent !== undefined ? chip.dev.battery.percent + "%" : chip.dev.battery.level) : ""
                          color: chip.dev.online ? root.batteryColor(chip.dev.battery) : root.dim
                          font.family: root.font
                          font.pixelSize: Style.font.caption
                          font.bold: chip.dev.online
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.links.length > 0
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.t("radioHint")
            color: root.dim
            font.family: root.font
            font.pixelSize: Style.font.caption * 0.85
          }

          // ------------------------------------------------------------ devices
          PanelSeparator { visible: root.devices.length > 0; width: parent.width; foreground: root.fg }
          PanelSectionHeader { visible: root.devices.length > 0; text: root.t("devices").toUpperCase(); foreground: root.fg; fontFamily: root.font }

          Repeater {
            model: root.devices.length
            delegate: Rectangle {
              id: card
              required property int index
              readonly property var dev: root.deviceAt(index)
              readonly property bool isOpen: root.expanded[dev.id] === true && dev.online && root.hasSettings(dev)
              readonly property real pad: Style.space(10)
              readonly property bool hiddenDev: root.isHidden(dev)
              width: column.width
              opacity: hiddenDev ? 0.55 : 1
              height: cardColumn.implicitHeight + 2 * pad
              radius: Style.cornerRadius
              color: dev.online
                ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, cardHover.hovered ? 0.14 : 0.09)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, cardHover.hovered ? 0.07 : 0.04)
              border.width: 1
              border.color: dev.online
                ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.35)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
              HoverHandler { id: cardHover }

              Column {
                id: cardColumn
                x: card.pad
                y: card.pad
                width: card.width - 2 * card.pad
                spacing: Style.space(10)

                Item {
                  width: parent.width
                  height: Math.max(badge.height, nameColumn.implicitHeight)

                  Rectangle {
                    id: badge
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(34)
                    height: width
                    radius: Style.cornerRadius > 0 ? width / 2 : 0
                    color: card.dev.online ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: root.kindIcon(card.dev.kind)
                      color: card.dev.online ? Commons.Color.background : root.dim
                      font.family: root.font
                      font.pixelSize: Style.font.body * 1.15
                    }
                  }

                  Column {
                    id: nameColumn
                    anchors.left: badge.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: batteryBox.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: root.deviceName(card.dev)
                      color: card.dev.online ? root.fg : Qt.lighter(root.dim, 1.15)
                      font.family: root.font
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: root.statusLine(card.dev) + (card.hiddenDev ? " · " + root.t("hiddenTag") : "")
                      color: root.dim
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Row {
                    id: batteryBox
                    anchors.right: hideButton.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)
                    visible: card.dev.online && !!card.dev.battery
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: root.batteryIcon(card.dev.battery)
                      color: root.batteryColor(card.dev.battery)
                      font.family: root.font
                      font.pixelSize: Style.font.body * 1.1
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: card.dev.battery && card.dev.battery.percent !== null && card.dev.battery.percent !== undefined
                        ? card.dev.battery.percent + "%" : (card.dev.battery ? card.dev.battery.level : "")
                      color: root.batteryColor(card.dev.battery)
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  // Hide / show again, right on the card (no menu): the eye.
                  Button {
                    id: hideButton
                    anchors.right: chevron.left
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    z: 1
                    iconText: card.hiddenDev ? "󰈈" : "󰈉"
                    iconSize: Style.font.body
                    horizontalPadding: Style.space(3)
                    verticalPadding: Style.space(1)
                    opacity: card.hiddenDev || cardHover.hovered ? 1 : 0.4
                    foreground: root.fg
                    fontFamily: root.font
                    tooltipText: card.hiddenDev ? root.t("unhide") : root.t("hide")
                    onClicked: root.setHidden(card.dev, !card.hiddenDev)
                  }

                  Text {
                    id: chevron
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    width: Style.space(14)
                    horizontalAlignment: Text.AlignRight
                    text: card.dev.online && root.hasSettings(card.dev) ? (card.isOpen ? "󰅀" : "󰅂") : ""
                    color: headerMouse.containsMouse ? root.fg : root.dim
                    font.family: root.font
                    font.pixelSize: Style.font.body
                  }

                  MouseArea {
                    id: headerMouse
                    anchors.fill: parent
                    enabled: card.dev.online && root.hasSettings(card.dev)
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.toggleExpanded(card.dev)
                  }
                }

                Rectangle {
                  visible: card.isOpen
                  width: parent.width
                  height: 1
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
                }

                // ---------------------------------------------- DPI
                Column {
                  visible: card.isOpen && !!card.dev.dpi && card.dev.dpi.max > 0
                  width: parent.width
                  spacing: Style.space(4)
                  Item {
                    width: parent.width
                    height: dpiLabel.implicitHeight
                    Text {
                      id: dpiLabel
                      textFormat: Text.PlainText
                      text: root.t("dpi")
                      color: root.fg
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: Math.round(dpiSlider.liveValue) + (card.dev.dpi && Math.round(dpiSlider.liveValue) === card.dev.dpi.default ? " · " + root.t("dpiDefault") : "")
                      color: root.fg
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                  PanelSlider {
                    id: dpiSlider
                    width: parent.width
                    bar: root.bar
                    minimum: card.dev.dpi ? card.dev.dpi.min : 0
                    maximum: card.dev.dpi ? card.dev.dpi.max : 1
                    step: card.dev.dpi && card.dev.dpi.step > 0 ? card.dev.dpi.step : 50
                    fillColor: Commons.Color.accent
                    value: card.dev.dpi ? card.dev.dpi.value : 0
                    onReleased: function(v) { root.set(card.dev, "dpi", Math.round(v)) }
                    onRightClicked: if (card.dev.dpi) root.set(card.dev, "dpi", card.dev.dpi.default)
                  }
                }

                // ---------------------------------------------- SmartShift
                Column {
                  visible: card.isOpen && !!card.dev.smartshift
                  width: parent.width
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: root.t("wheelMode")
                    color: root.fg
                    font.family: root.font
                    font.pixelSize: Style.font.caption
                  }
                  ButtonGroup {
                    options: [
                      { value: "smartshift", label: root.t("smartshift"), tooltip: root.t("smartshiftTip") },
                      { value: "ratchet", label: root.t("ratchet"), tooltip: root.t("ratchetTip") },
                      { value: "freespin", label: root.t("freespin"), tooltip: root.t("freespinTip") }
                    ]
                    value: card.dev.smartshift ? card.dev.smartshift.mode : ""
                    foreground: root.fg
                    fontFamily: root.font
                    fontSize: Style.font.caption
                    onChanged: function(picked) { root.set(card.dev, "smartshift", picked) }
                  }
                  Item {
                    visible: !!card.dev.smartshift && card.dev.smartshift.mode === "smartshift"
                    width: parent.width
                    height: thresholdSlider.implicitHeight
                    Text {
                      id: thresholdLabel
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: root.t("sensitivity")
                      color: root.dim
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                    }
                    PanelSlider {
                      id: thresholdSlider
                      anchors.left: thresholdLabel.right
                      anchors.leftMargin: Style.space(10)
                      anchors.right: thresholdValue.left
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      bar: root.bar
                      minimum: 1
                      maximum: 50
                      step: 1
                      fillColor: Commons.Color.accent
                      value: card.dev.smartshift && card.dev.smartshift.threshold ? card.dev.smartshift.threshold : 10
                      onReleased: function(v) { root.set(card.dev, "threshold", Math.round(v)) }
                    }
                    Text {
                      id: thresholdValue
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(28)
                      horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText
                      text: Math.round(thresholdSlider.liveValue)
                      color: root.fg
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                    }
                  }
                  Text {
                    visible: !!card.dev.smartshift && card.dev.smartshift.mode === "smartshift"
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    text: root.t("sensitivityHint")
                    color: root.dim
                    font.family: root.font
                    font.pixelSize: Style.font.caption * 0.9
                  }
                }

                // ---------------------------------------------- wheel
                SettingRow {
                  visible: card.isOpen && !!card.dev.wheel
                  label: root.t("natural")
                  hint: root.t("naturalHint")
                  ToggleSwitch {
                    cursorRing: false
                    trackHeight: Style.space(18)
                    checked: !!card.dev.wheel && card.dev.wheel.invert
                    foreground: root.fg
                    onToggled: root.set(card.dev, "invert", !(card.dev.wheel && card.dev.wheel.invert))
                  }
                }
                SettingRow {
                  visible: card.isOpen && !!card.dev.wheel
                  label: root.t("hires")
                  hint: root.t("hiresHint")
                  ToggleSwitch {
                    cursorRing: false
                    trackHeight: Style.space(18)
                    checked: !!card.dev.wheel && card.dev.wheel.hires
                    foreground: root.fg
                    onToggled: root.set(card.dev, "hires", !(card.dev.wheel && card.dev.wheel.hires))
                  }
                }

                // ---------------------------------------------- Fn keys
                SettingRow {
                  visible: card.isOpen && !!card.dev.fnswap
                  label: root.t("fnswap")
                  hint: card.dev.fnswap && card.dev.fnswap.on ? root.t("fnswapOn") : root.t("fnswapOff")
                  ToggleSwitch {
                    cursorRing: false
                    trackHeight: Style.space(18)
                    checked: !!card.dev.fnswap && card.dev.fnswap.on
                    foreground: root.fg
                    onToggled: root.set(card.dev, "fnswap", !(card.dev.fnswap && card.dev.fnswap.on))
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: root.t("refresh")
              iconText: "󰑐"
              bordered: true
              foreground: root.fg
              fontFamily: root.font
              onClicked: root.send({ cmd: "refresh" })
            }
            Button {
              text: root.t("bluetooth")
              iconText: "󰂯"
              bordered: true
              foreground: root.fg
              fontFamily: root.font
              tooltipText: root.t("bluetoothTip")
              onClicked: root.btOpen = true
            }
          }
          }
        }
      }
    }
  }
}
