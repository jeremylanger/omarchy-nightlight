import QtQuick
import Quickshell.Io

// What hyprsunset is doing right now, read and set directly.
//
// This used to be the stock omarchy.nightlight service, but since Omarchy
// 4.0.3 a bar-widget plugin is no longer handed it (firstPartyServiceFor()
// returns null), which left the switch stuck at off. The probe and the
// threshold mirror that service and bin/omarchy-toggle-nightlight; every
// change is passed on with `omarchy-shell nightlight refresh` so the stock
// indicator still agrees when it is enabled.
Item {
  id: root

  readonly property int dayTemperature: 6500
  // Below this the light counts as on (NightlightModel.IDENTITY_TEMPERATURE).
  readonly property int identityTemperature: 6000

  property bool stateLoaded: false
  property var temperature: null
  readonly property bool lightOn: stateLoaded && temperature !== null && temperature < identityTemperature

  property bool probeAgain: false
  property var pendingTemperature: null

  // A probe overlapping an apply can read the old temperature and flip the
  // switch back for a moment; apply refreshes when it finishes anyway.
  function refresh() {
    if (apply.running) return
    if (probe.running) { probeAgain = true; return }
    probe.running = true
  }

  function applyTemperature(temp) {
    temperature = temp
    stateLoaded = true
    if (apply.running) { pendingTemperature = temp; return }
    runApply(temp)
  }

  function runApply(temp) {
    apply.command = ["bash", "-c",
      'if pgrep -x hyprsunset >/dev/null; then hyprctl hyprsunset temperature "$1" >/dev/null; else ' +
      // A fresh hyprsunset applies its own temperature at the end of its
      // boot, overriding anything sent before then, so resend until it sticks.
      'setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & ' +
      'for i in $(seq 1 10); do hyprctl hyprsunset temperature "$1" >/dev/null 2>&1; sleep 0.2; ' +
      '[ "$(hyprctl hyprsunset temperature 2>/dev/null | grep -oE "[0-9]+" | head -n1)" = "$1" ] && break; done; fi; ' +
      'omarchy-shell -q nightlight refresh',
      "_", String(Number(temp))]
    apply.running = true
  }

  Process {
    id: probe
    // Prints nothing when hyprsunset is not running, rather than letting a
    // digit in hyprctl's error message pass for a temperature.
    command: ["bash", "-c",
      'out=$(hyprctl hyprsunset temperature 2>/dev/null) && grep -oE "[0-9]+" <<<"$out" | head -n1']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (apply.running) return
        var t = parseInt(String(text || "").trim(), 10)
        root.temperature = isNaN(t) ? null : t
        root.stateLoaded = true
      }
    }
    onExited: function() { if (root.probeAgain) { root.probeAgain = false; root.refresh() } }
  }

  Process {
    id: apply
    onExited: function() {
      if (root.pendingTemperature !== null) {
        var t = root.pendingTemperature
        root.pendingTemperature = null
        root.runApply(t)
        return
      }
      root.refresh()
    }
  }

  // The keybinding, the stock indicator and hyprsunset's own schedule all
  // change the temperature without telling this widget, so look again
  // every few seconds.
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
