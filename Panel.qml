pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "I18n.js" as I18n

// Logitech Devices popup: one card per device (battery, connection) that expands to
// its settings (DPI, SmartShift, scroll wheel, Fn keys), then the receivers with their
// free pairing slots. The gear opens the settings page (language, warning levels,
// which devices to show, receiver access); back with the button, Backspace or Esc. Repeaters are driven by counts and read the current snapshot by
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
  readonly property var allDevices: stats.devices || []
  // Switched-off devices only when the setting asks for them.
  readonly property var devices: {
    if (!hostWidget || hostWidget.showOffline) return allDevices
    return allDevices.filter(function(d) { return d.online })
  }
  readonly property var receivers: stats.receivers || []
  property var expanded: ({})   // device id -> true while its settings are shown
  property bool settingsOpen: false
  readonly property string lang: hostWidget ? hostWidget.lang : "en"
  readonly property string languageSetting: hostWidget ? hostWidget.languageSetting : "auto"
  readonly property string systemLang: hostWidget ? hostWidget.systemLang : "en"
  function t(key, args) { return I18n.tr(lang, key, args) }
  function tn(key, n, args) { return I18n.trn(lang, key, n, args) }
  function deviceName(dev) { return dev.name || t("unnamed") }
  function connName(code) { return code ? t("conn_" + code) : "" }
  // Receiver access is missing while some Logitech node could not be opened.
  readonly property bool accessMissing: (stats.denied || []).length > 0
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
    for (var i = 0; i < allDevices.length; i++) if (allDevices[i].online) n++
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
    var where = connName(dev.connection) + (dev.slot ? " · " + t("slotN", [dev.slot]) : "")
    if (!dev.online) return where + " · " + t("notConnected")
    var b = dev.battery
    if (b && b.charging) return where + " · " + t("charging")
    if (b && b.status === "full" && b.external_power) return where + " · " + t("charged")
    return where
  }

  function open() { root.controller.show() }
  function close() { root.controller.hide(); root.settingsOpen = false }
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
      // Open dropdown lists take their own keys.
      blocked: languagePicker.popupOpen || lowPicker.popupOpen || criticalPicker.popupOpen
      onCloseRequested: { if (root.settingsOpen) root.settingsOpen = false; else root.close() }
      onTextKey: function(text) { if (text === "\b" && root.settingsOpen) root.settingsOpen = false }
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
              ? root.t("connectedOf", [root.onlineCount(), root.allDevices.length]) + (root.receivers.length ? " · " + root.tn("receiversN", root.receivers.length, [root.receivers.length]) : "")
              : root.phase === "permission" ? root.t("accessNeeded") : root.phase === "none" ? root.t("nothingFound") : root.t("looking")
            detail: root.stats.lowest ? root.t("lowestBattery", [root.stats.lowest.percent]) : ""
            trailingControl: Component {
              // As tall as the hero text, with the gear centred on the title
              // row so it lines up with the detail pill.
              Item {
                visible: !root.settingsOpen
                implicitWidth: gearButton.width
                implicitHeight: heroTitle.implicitHeight + Style.space(2) + heroMeta.implicitHeight
                Text { id: heroTitle; visible: false; textFormat: Text.PlainText; text: "W"; font.family: root.font; font.pixelSize: Style.font.title; font.bold: true }
                Text { id: heroBody; visible: false; textFormat: Text.PlainText; text: "W"; font.family: root.font; font.pixelSize: Style.font.body; font.bold: true }
                Text { id: heroMeta; visible: false; textFormat: Text.PlainText; text: "W"; font.family: root.font; font.pixelSize: Style.font.caption; font.bold: true }
                Button {
                  id: gearButton
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
                color: root.onlineCount() > 0 ? Color.accent : root.dim
                font.family: root.font
                font.pixelSize: Style.font.display
              }
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
              label: root.t("showOffline")
              ToggleSwitch {
                cursorRing: false
                trackHeight: Style.space(18)
                checked: !root.hostWidget || root.hostWidget.showOffline
                foreground: root.fg
                onToggled: if (root.hostWidget) root.hostWidget.setOption("showOffline", !root.hostWidget.showOffline, true)
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

          // ------------------------------------------------------------ main view
          Column {
            visible: !root.settingsOpen
            width: parent.width
            spacing: Style.space(10)

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
            color: root.phase === "none" ? root.dim : Color.urgent
            font.family: root.font
            font.pixelSize: Style.font.caption
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

          // ------------------------------------------------------------ receivers
          PanelSeparator { visible: root.receivers.length > 0; width: parent.width; foreground: root.fg }
          PanelSectionHeader { visible: root.receivers.length > 0; text: root.t("receivers").toUpperCase(); foreground: root.fg; fontFamily: root.font }

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
                  for (var j = 0; j < root.allDevices.length; j++)
                    if (root.allDevices[j].id === ids[i]) out.push(root.deviceName(root.allDevices[j]))
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
                  text: root.connName(recRow.rec.family) + "  ·  " + root.t("slotsUsed", [recRow.names.length, recRow.rec.max_devices])
                  color: root.fg
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: recRow.names.length > 0 ? recRow.names.join(", ") : root.t("noDevicePaired")
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
              text: root.t("refresh")
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
}
