import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "host" as Host
import "plugin" as Plugin

// Omarchy 4.0.3 stopped handing the stock night light service to bar-widget
// plugins: firstPartyServiceFor() now returns null unless the plugin is a
// whole bar or an Indicators clone. The host objects below are Omarchy's own,
// built the way it builds them for this widget, so the switch has to follow
// and drive hyprsunset without that service.
ShellRoot {
  id: harness

  readonly property string fake: Quickshell.env("FAKE_HYPRSUNSET")
  readonly property string home: Quickshell.env("HOME")
  readonly property var panel: loader.item

  Host.PluginShellApi { id: hostShell; pluginId: "io.github.jeremylanger.nightlight" }

  PluginBarApi {
    id: hostBar
    pluginId: "io.github.jeremylanger.nightlight"
    moduleName: "io.github.jeremylanger.nightlight"
    shell: hostShell
  }

  Loader {
    id: loader
    active: false
    sourceComponent: Component { Plugin.Panel { bar: hostBar } }
  }

  // The evening after the schedule has switched the light on: hyprsunset is
  // running and holding the target. No fade, so nothing here depends on the
  // clock.
  Process {
    id: fixture
    running: true
    command: ["sh", "-c",
      'printf "%s" "$1" >"$2/.config/hypr/hyprsunset.conf" && echo 2100 >"$3/temperature" && touch "$3/running"',
      "_",
      "# nightlight: on=19:00 off=07:00 temperature=2100 fade=60 fadeEnabled=false\n"
        + "\nprofile {\n    time = 07:00\n    identity = true\n}\n"
        + "\nprofile {\n    time = 19:00\n    temperature = 2100\n}\n",
      harness.home, harness.fake]
    onExited: function(exitCode) {
      if (exitCode !== 0) return harness.finish("could not write fixtures")
      loader.active = true
      harness.next()
    }
  }

  property string fakeTemperature: ""

  Process {
    id: fakeRead
    command: ["cat", harness.fake + "/temperature"]
    stdout: StdioCollector { onStreamFinished: harness.fakeTemperature = text.trim() }
  }

  Process { id: fakeWrite }

  readonly property var steps: [
    {
      label: "switch reads on while hyprsunset holds 2100K",
      until: function() { return panel.active }
    },
    {
      label: "switching off sets hyprsunset to 6500K",
      act: function() { panel.setActive(false) },
      until: function() { return !panel.active && fakeTemperature === "6500" }
    },
    {
      label: "switching on sets hyprsunset back to 2100K",
      act: function() { panel.setActive(true) },
      until: function() { return panel.active && fakeTemperature === "2100" }
    },
    {
      // The keybinding and the stock indicator change hyprsunset without
      // going through this widget.
      label: "switch follows a change made outside the widget",
      act: function() {
        fakeWrite.command = ["sh", "-c", 'echo 6500 >"$1/temperature"', "_", fake]
        fakeWrite.running = true
      },
      until: function() { return !panel.active },
      timeout: 8000
    },
    {
      // Stopping hyprsunset is how the widget keeps a fade schedule off.
      label: "hyprsunset stops",
      act: function() {
        fakeWrite.command = ["rm", "-f", fake + "/running"]
        fakeWrite.running = true
      },
      until: function() { return !fakeWrite.running }
    },
    {
      label: "switching on starts hyprsunset at 2100K",
      act: function() { panel.setActive(true) },
      until: function() { return panel.active && fakeTemperature === "2100" }
    }
  ]

  property int index: -1
  property real deadline: 0

  function next() {
    index++
    if (index >= steps.length) return finish("")
    var step = steps[index]
    if (step.act) step.act()
    deadline = Date.now() + (step.timeout || 4000)
    poll.start()
  }

  Timer {
    id: poll
    interval: 100
    repeat: true
    onTriggered: {
      if (!fakeRead.running) fakeRead.running = true
      var step = harness.steps[harness.index]
      if (step.until()) { stop(); harness.next() }
      else if (Date.now() > harness.deadline) {
        stop()
        harness.finish(step.label + " (active=" + harness.panel.active
          + ", hyprsunset=" + harness.fakeTemperature + ")")
      }
    }
  }

  function finish(failure) {
    for (var i = 0; i < index && i < steps.length; i++) console.log("ok  - " + steps[i].label)
    console.log(failure === "" ? "NIGHTLIGHT_PASS" : "NIGHTLIGHT_FAIL: " + failure)
    Qt.quit()
  }
}
