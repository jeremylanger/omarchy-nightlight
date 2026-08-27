import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.jeremylanger.nightlight"
  ipcTarget: "io.github.jeremylanger.nightlight"
  manageIpc: false

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function apply(): string { root.editTemperature = root.editTemperature; root.save(true); return "ok" }
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string confPath: Quickshell.env("HOME") + "/.config/hypr/hyprsunset.conf"

  // Live state from the stock nightlight service (what hyprsunset is doing right now).
  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.nightlight") : null
  readonly property bool active: service ? service.enabled : false
  readonly property var currentTemp: service ? service.temperature : null

  // Schedule as stored in hyprsunset.conf.
  property string onTime: "20:00"
  property string offTime: "07:00"
  property int temperature: 4000
  property bool parsed: false

  // Edits in progress.
  property string editOnTime: onTime
  property string editOffTime: offTime
  property int editTemperature: temperature
  readonly property bool dirty: editOnTime !== onTime || editOffTime !== offTime || editTemperature !== temperature
  readonly property bool validTimes: /^([01]?\d|2[0-3]):[0-5]\d$/.test(editOnTime) && /^([01]?\d|2[0-3]):[0-5]\d$/.test(editOffTime)
  property bool saving: false

  function parseConf(text) {
    var blocks = String(text || "").match(/profile\s*\{[^}]*\}/g) || []
    var on = null, off = null, temp = null
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i]
      var t = b.match(/time\s*=\s*(\d{1,2}:\d{2})/)
      if (!t) continue
      if (/identity\s*=\s*true/.test(b)) off = t[1]
      else {
        var k = b.match(/temperature\s*=\s*(\d+)/)
        if (k) { on = t[1]; temp = Number(k[1]) }
      }
    }
    var wasDirty = dirty
    if (on) onTime = on
    if (off) offTime = off
    if (temp) temperature = temp
    parsed = true
    if (!wasDirty) resetEdits()
  }

  function resetEdits() {
    editOnTime = onTime
    editOffTime = offTime
    editTemperature = temperature
  }

  function pad(t) {
    var p = t.split(":")
    return (p[0].length < 2 ? "0" + p[0] : p[0]) + ":" + p[1]
  }

  readonly property string pendingPath: Quickshell.env("HOME") + "/.local/state/omarchy/nightlight-restart-pending"
  property bool restartPending: false
  property string saveError: ""

  // ---- File access. Paths are passed to bash as positional arguments, never
  //      interpolated into the script. Reads require a regular file and are
  //      capped at 64 KiB; writes go to a temp file in the target directory and
  //      are renamed into place. A symlinked config is honored only when it
  //      resolves to a regular file under $HOME.

  readonly property string readScript:
      '[ -e "$2" ] && echo "__PENDING__"; ' +
      '[ -f "$1" ] && head -c 65536 -- "$1"; exit 0'

  readonly property string writeScript:
      'body=$1; conf=$2; target=$conf; ' +
      'if [ -L "$conf" ]; then target=$(realpath -e -- "$conf") || exit 2; ' +
      '  case $target in "$HOME"/*) ;; *) exit 2;; esac; fi; ' +
      'if [ -e "$target" ] && [ ! -f "$target" ]; then exit 3; fi; ' +
      'dir=$(dirname -- "$target"); mkdir -p -- "$dir" || exit 1; ' +
      'tmp=$(mktemp -- "$dir/.hyprsunset.conf.XXXXXX") || exit 1; ' +
      'printf "%s" "$body" > "$tmp" && mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; exit 1; }; '

  // Restart hyprsunset, waiting for the old instance to release the display
  // before launching the new one. $4 is the pending-restart marker.
  readonly property string restartScript:
      'pkill -x hyprsunset; for i in $(seq 1 30); do pgrep -x hyprsunset >/dev/null || break; sleep 0.1; done; ' +
      'setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & ' +
      'for i in $(seq 1 30); do hyprctl hyprsunset temperature >/dev/null 2>&1 && break; sleep 0.1; done; sleep 0.5; ' +
      'rm -f -- "$4"; omarchy-shell -q nightlight refresh; '

  function reload() {
    if (readProc.running) return
    readProc.command = ["bash", "-c", readScript, "_", confPath, pendingPath]
    readProc.running = true
  }

  function save(force) {
    if (!validTimes || saving) return
    saving = true
    saveError = ""
    var on = pad(editOnTime), off = pad(editOffTime), temp = editTemperature
    var timesChanged = on !== pad(onTime) || off !== pad(offTime)
    var body = "# Night light schedule (edited from the bar widget)\n"
      + "profile {\n    time = " + off + "\n    identity = true\n}\n\n"
      + "profile {\n    time = " + on + "\n    temperature = " + temp + "\n}\n"
    var tail
    if (active && !timesChanged) {
      // Only the temperature moved while the light is on: apply it live so
      // there is no restart flash. hyprsunset does not reread its config, so
      // remember to restart it the next time the light is off (invisible).
      tail = 'hyprctl hyprsunset temperature "$3" >/dev/null; touch -- "$4"; omarchy-shell -q nightlight refresh'
      restartPending = true
    } else {
      tail = restartScript
      restartPending = false
    }
    saveProc.command = ["bash", "-c", writeScript + tail, "_", body, confPath, String(temp), pendingPath]
    saveProc.running = true
  }

  function runPendingRestart() {
    // Wait for the nightlight service to report real state; before that
    // `active` is false and a restart here would wrongly force the light off.
    if (!restartPending || !service || !service.stateLoaded || active || saving || restartProc.running) return
    // The fresh instance applies the schedule, which may switch the light
    // back on; the user just turned it off, so keep it off.
    restartProc.command = ["bash", "-c",
      restartScript + 'hyprctl hyprsunset temperature 6500 >/dev/null; omarchy-shell -q nightlight refresh',
      "_", "", "", "", pendingPath]
    restartProc.running = true
  }

  onActiveChanged: if (!active) Qt.callLater(runPendingRestart)

  Timer {
    interval: 3000
    repeat: true
    running: root.restartPending
    onTriggered: root.runPendingRestart()
  }

  Process {
    id: restartProc
    onExited: function() { root.restartPending = false; if (root.service) root.service.refresh() }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        var pending = raw.indexOf("__PENDING__") === 0
        if (pending) raw = raw.replace(/^__PENDING__\n?/, "")
        root.restartPending = pending
        root.parseConf(raw)
        if (pending) Qt.callLater(root.runPendingRestart)
      }
    }
  }

  Process {
    id: saveProc
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode === 2) root.saveError = "Config is a symlink outside your home directory; not written."
      else if (exitCode === 3) root.saveError = "Config path is not a regular file; not written."
      else if (exitCode !== 0) root.saveError = "Couldn't write hyprsunset.conf."
      root.reload()
      if (root.service) root.service.refresh()
    }
  }

  function setActive(on) {
    if (!service) return
    // Turn on with the configured temperature (not the stock 4000K).
    if (on) service.applyTemperature(temperature)
    else service.setNightlight(false)
  }

  Component.onCompleted: reload()

  onOpenedChanged: if (opened) {
    if (service) service.refresh()
    reload()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Hide when off, like the stock indicators: reveal dimmed while the bar's
  // center section is hovered (or the panel is open), full when active.
  readonly property bool centerRevealed: bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true
  readonly property bool shown: active || opened || centerRevealed || button.tooltipHovered
  visible: shown
  opacity: active ? 1 : 0.45
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight
  Behavior on opacity { NumberAnimation { duration: 120 } }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰔎"
          color: root.active ? root.barForeground : Qt.darker(root.barForeground, 1.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }
    }
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.setActive(!root.active)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: onField.activeFocus || offField.activeFocus || tempField.field.activeFocus
      onReturnRequested: root.setActive(!root.active)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Night Light"
          meta: root.active
            ? ("On · " + (root.currentTemp ? root.currentTemp + "K" : ""))
            : "Off"
          iconComponent: Component {
            Text {
              text: "󰔎"
              color: root.active ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              checked: root.active
              foreground: root.foreground
              onToggled: root.setActive(!root.active)
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader {
          text: "SCHEDULE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          spacing: Style.space(16)

          Column {
            spacing: Style.spacing.md
            Text {
              text: "Turns on"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            TextField {
              id: onField
              width: Style.space(80)
              height: tempField.field.height
              text: root.editOnTime
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "20:00"
              onTextEdited: root.editOnTime = text
              Keys.onPressed: function(e) {
                if (e.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); e.accepted = true }
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.save(); e.accepted = true }
              }
            }
          }

          Column {
            spacing: Style.spacing.md
            Text {
              text: "Turns off"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            TextField {
              id: offField
              width: Style.space(80)
              height: tempField.field.height
              text: root.editOffTime
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "07:00"
              onTextEdited: root.editOffTime = text
              Keys.onPressed: function(e) {
                if (e.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); e.accepted = true }
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.save(); e.accepted = true }
              }
            }
          }

          NumberField {
            id: tempField
            label: "Temperature (K)"
            from: 1000
            to: 6000
            stepSize: 100
            value: root.editTemperature
            foreground: root.foreground
            fontFamily: root.fontFamily
            fieldWidth: Style.space(110)
            onModified: function(v) { root.editTemperature = v }
          }
        }

        Row {
          spacing: Style.space(8)
          visible: root.dirty || root.saving

          Button {
            text: root.saving ? "Saving…" : "Apply"
            enabled: root.validTimes && !root.saving
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.save()
          }
          Button {
            text: "Reset"
            enabled: !root.saving
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.resetEdits()
          }
          Text {
            visible: !root.validTimes
            anchors.verticalCenter: parent.verticalCenter
            text: "Use HH:MM"
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          visible: root.saveError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.saveError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

      }
    }
  }
}
