pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Logitech Devices popup: one card per device (battery, connection) that expands to
// its settings (DPI, SmartShift, scroll wheel, Fn keys), then the receivers with their
// free pairing slots. Repeaters are driven by counts and read the current snapshot by
// index, so a refresh never rebuilds rows (a slider drag survives every snapshot).
Panel {
  id: root
  moduleName: "ubruckhaus.logitech-devices"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property var stats: ({})  // pushed by BarWidget on every snapshot
  readonly property string phase: String(stats.phase || "starting")
  readonly property var devices: stats.devices || []
  readonly property var receivers: stats.receivers || []
  property var expanded: ({})   // device id -> true while its settings are shown
  readonly property color fg: Color.popups.text
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
    for (var i = 0; i < devices.length; i++) if (devices[i].online) n++
    return n
  }

  function kindIcon(kind) {
    switch (kind) {
    case "keyboard": return "󰌌"
    case "mouse": return "󰍽"
    case "trackball": return "󰍽"
    case "touchpad": return "󰟸"
    case "numpad": return "󰎠"
    case "presenter": return "󰐯"
    case "headset": return "󰋋"
    case "gamepad": case "joystick": return "󰊴"
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
  function batteryColor(b) {
    if (!b) return root.dim
    if (b.charging) return root.green
    if (b.percent !== null && b.percent !== undefined && b.percent <= 15) return Color.urgent
    if (b.level === "critical" || b.level === "low") return Color.urgent
    return root.fg
  }
  function statusLine(dev) {
    var where = dev.connection + (dev.slot ? " · slot " + dev.slot : "")
    if (!dev.online) return where + " · not connected"
    var b = dev.battery
    if (b && b.charging) return where + " · charging"
    if (b && b.status === "full" && b.external_power) return where + " · charged"
    return where
  }

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

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
      onCloseRequested: root.close()
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
            title: "Logitech Devices"
            meta: root.phase === "ok"
              ? root.onlineCount() + " of " + root.devices.length + " devices connected · " + root.receivers.length + (root.receivers.length === 1 ? " receiver" : " receivers")
              : root.phase === "permission" ? "Access needed" : root.phase === "none" ? "Nothing found" : "Looking for devices…"
            detail: root.stats.lowest ? "Lowest battery " + root.stats.lowest.percent + "%" : ""
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰍽"
                color: root.onlineCount() > 0 ? Color.accent : root.dim
                font.family: root.font
                font.pixelSize: Style.font.display
              }
            }
          }

          // ------------------------------------------------------------ setup
          Rectangle {
            visible: root.phase === "permission"
            width: parent.width
            height: setupColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
            Column {
              id: setupColumn
              x: Style.space(10); y: Style.space(10)
              width: parent.width - Style.space(20)
              spacing: Style.space(8)
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Not ready yet · step 1 of 1"
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: "Linux only lets root talk to the receivers. Allowing access installs one udev rule (the same one Solaar uses) that gives the logged-in user access to Logitech receivers and devices. You will be asked for your password once."
                color: root.dim
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              Button {
                text: root.hostWidget && root.hostWidget.allowing ? "Waiting for password…" : "Allow access"
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
            text: root.phase === "none" ? "No Logitech receiver or device is plugged in."
              : root.phase === "error" ? "Error: " + String(root.stats.error || "")
              : String(root.stats.message || "")
            color: root.phase === "none" ? root.dim : Color.urgent
            font.family: root.font
            font.pixelSize: Style.font.caption
          }

          // ------------------------------------------------------------ devices
          PanelSeparator { visible: root.devices.length > 0; width: parent.width; foreground: root.fg }
          PanelSectionHeader { visible: root.devices.length > 0; text: "DEVICES"; foreground: root.fg; fontFamily: root.font }

          Repeater {
            model: root.devices.length
            delegate: Rectangle {
              id: card
              required property int index
              readonly property var dev: root.deviceAt(index)
              readonly property bool isOpen: root.expanded[dev.id] === true && dev.online && root.hasSettings(dev)
              readonly property real pad: Style.space(10)
              width: column.width
              height: cardColumn.implicitHeight + 2 * pad
              radius: Style.cornerRadius
              color: dev.online
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, cardHover.hovered ? 0.14 : 0.09)
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, cardHover.hovered ? 0.07 : 0.04)
              border.width: 1
              border.color: dev.online
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)
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
                    color: card.dev.online ? Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: root.kindIcon(card.dev.kind)
                      color: card.dev.online ? Color.background : root.dim
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
                      text: card.dev.name
                      color: card.dev.online ? root.fg : Qt.lighter(root.dim, 1.15)
                      font.family: root.font
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: root.statusLine(card.dev)
                      color: root.dim
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Row {
                    id: batteryBox
                    anchors.right: chevron.left
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
                      text: "Pointer speed (DPI)"
                      color: root.fg
                      font.family: root.font
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: Math.round(dpiSlider.liveValue) + (card.dev.dpi && Math.round(dpiSlider.liveValue) === card.dev.dpi.default ? " · default" : "")
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
                    fillColor: Color.accent
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
                    text: "Scroll wheel mode"
                    color: root.fg
                    font.family: root.font
                    font.pixelSize: Style.font.caption
                  }
                  ButtonGroup {
                    options: [
                      { value: "smartshift", label: "SmartShift", tooltip: "Ratchet that switches to free spin when you flick the wheel" },
                      { value: "ratchet", label: "Ratchet", tooltip: "Always click by click" },
                      { value: "freespin", label: "Free spin", tooltip: "Always spins freely" }
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
                      text: "Sensitivity"
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
                      fillColor: Color.accent
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
                    text: "Lower sensitivity values switch to free spin with a gentler flick."
                    color: root.dim
                    font.family: root.font
                    font.pixelSize: Style.font.caption * 0.9
                  }
                }

                // ---------------------------------------------- wheel
                SettingRow {
                  visible: card.isOpen && !!card.dev.wheel
                  label: "Natural scrolling"
                  hint: "Content follows the wheel, like on a touchpad"
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
                  label: "High-resolution scrolling"
                  hint: "Smoother, finer steps in apps that support it"
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
                  label: "Swap Fn keys"
                  hint: card.dev.fnswap && card.dev.fnswap.on
                    ? "On: top row gives media and special functions, hold Fn for F1–F12"
                    : "Off: top row gives F1–F12, hold Fn for media and special functions"
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

          // ------------------------------------------------------------ receivers
          PanelSeparator { visible: root.receivers.length > 0; width: parent.width; foreground: root.fg }
          PanelSectionHeader { visible: root.receivers.length > 0; text: "RECEIVERS"; foreground: root.fg; fontFamily: root.font }

          Repeater {
            model: root.receivers.length
            delegate: Item {
              id: recRow
              required property int index
              readonly property var rec: root.receiverAt(index)
              readonly property var names: {
                var out = []
                var ids = rec.devices || []
                for (var i = 0; i < ids.length; i++)
                  for (var j = 0; j < root.devices.length; j++)
                    if (root.devices[j].id === ids[i]) out.push(root.devices[j].name)
                return out
              }
              width: column.width
              height: recColumn.implicitHeight
              Text {
                id: recIcon
                anchors.left: parent.left
                anchors.top: parent.top
                textFormat: Text.PlainText
                text: "󰕓"
                color: recRow.names.length > 0 ? root.fg : root.dim
                font.family: root.font
                font.pixelSize: Style.font.body * 1.1
              }
              Column {
                id: recColumn
                anchors.left: recIcon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: recRow.rec.name + "  ·  " + recRow.names.length + " of " + recRow.rec.max_devices + " slots used"
                  color: root.fg
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: recRow.names.length > 0 ? recRow.names.join(", ") : "No device paired"
                  color: root.dim
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: "Refresh"
              iconText: "󰑐"
              bordered: true
              foreground: root.fg
              fontFamily: root.font
              onClicked: root.send({ cmd: "refresh" })
            }
          }
        }
      }
    }
  }
}
