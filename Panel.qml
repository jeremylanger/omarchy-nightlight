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
    function fade(state: string, minutes: string): string {
      if (state !== "") root.editFade = state === "on" || state === "true" || state === "1"
      var m = Math.round(Number(minutes))
      if (m >= root.minFadeMinutes) root.editFadeMinutes = Math.min(root.maxFadeMinutes, m)
      if (!root.validTimes) { root.resetEdits(); return "error: hyprsunset.conf has no valid schedule" }
      if (root.saving) { root.resetEdits(); return "error: a save is already running" }
      // Saving an unchanged schedule would restart hyprsunset for nothing.
      if (!root.dirty) return "unchanged: " + (root.fade ? "on " + root.fadeMinutes : "off")
      root.save(true)
      return root.editFade ? ("on " + root.editFadeMinutes) : "off"
    }
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string confPath: Quickshell.env("HOME") + "/.config/hypr/hyprsunset.conf"

  // Live state from the stock nightlight service (what hyprsunset is doing right now).
  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("omarchy.nightlight") : null
  readonly property bool active: service ? service.enabled : false

  // Schedule as stored in hyprsunset.conf.
  property string onTime: "20:00"
  property string offTime: "07:00"
  property int temperature: 4000
  property bool fade: false
  property int fadeMinutes: 60
  property bool parsed: false

  // Edits in progress.
  property string editOnTime: onTime
  property string editOffTime: offTime
  property int editTemperature: temperature
  property bool editFade: fade
  property int editFadeMinutes: fadeMinutes
  readonly property bool fadeDirty: editFade !== fade || (editFade && editFadeMinutes !== fadeMinutes)
  readonly property bool dirty: editOnTime !== onTime || editOffTime !== offTime || editTemperature !== temperature || fadeDirty
  readonly property bool validTimes: /^([01]?\d|2[0-3]):[0-5]\d$/.test(editOnTime) && /^([01]?\d|2[0-3]):[0-5]\d$/.test(editOffTime)
  property bool saving: false

  // ---- Gradual fade ------------------------------------------------------
  // hyprsunset has no notion of a ramp: it holds one temperature per profile
  // and switches at the profile's time. A fade is therefore written out as a
  // staircase of one-minute profiles, which keeps the whole schedule inside
  // hyprsunset.conf — no helper daemon, and it still works when the schedule
  // is picked up at login.
  //
  // Both ends fade, over the same duration: the turn-on time starts the walk
  // down to the target, and the turn-off time starts the walk back up to
  // daylight. In both cases the named time is when the ramp *begins*.
  readonly property int neutralTemperature: 6500

  // hyprsunset times are HH:MM, so one minute is the finest step available.
  readonly property int maxFadeSteps: 60

  // The range the duration field offers, shared with the config parser so a
  // hand-edited value cannot sit outside what the panel can display.
  readonly property int minFadeMinutes: 5
  readonly property int maxFadeMinutes: 240

  // The first-party service reads state back from hyprsunset and calls the
  // light "on" only below this (NightlightModel.isNightlight: temperature <
  // IDENTITY_TEMPERATURE). The top of a ramp sits above it, so anything we
  // apply on the user's behalf has to stay under it or the service reports
  // the light off and the switch springs back.
  readonly property int onThreshold: 6000

  function minutesOf(t) {
    var p = String(t).split(":")
    return Number(p[0]) * 60 + Number(p[1])
  }

  function fmtMinutes(m) {
    m = ((m % 1440) + 1440) % 1440
    var h = Math.floor(m / 60), mm = m % 60
    return (h < 10 ? "0" : "") + h + ":" + (mm < 10 ? "0" : "") + mm
  }

  function spanBetween(from, to) {
    var w = (((minutesOf(to) - minutesOf(from)) % 1440) + 1440) % 1440
    return w === 0 ? 1440 : w
  }

  // Each ramp is capped by the stretch it lives in — the night for the fade
  // in, the day for the fade out — so generated steps can never spill past the
  // other end of the schedule and fight it.
  function effectiveFade(on, off, minutes) {
    if (!(minutes > 0)) return 0
    return Math.max(0, Math.min(Math.round(minutes), spanBetween(on, off) - 1))
  }

  function effectiveFadeOut(on, off, minutes) {
    if (!(minutes > 0)) return 0
    return Math.max(0, Math.min(Math.round(minutes), spanBetween(off, on) - 1))
  }

  // Steps are interpolated in mireds (1e6/K) rather than kelvin: equal mired
  // steps are equal *perceived* steps, so the ramp does not crawl at the warm
  // end and lurch at the cool end the way a linear kelvin ramp does.
  function fadeSteps(fromTemp, toTemp, minutes) {
    var steps = Math.max(1, Math.min(Math.round(minutes), maxFadeSteps))
    var startMired = 1000000 / fromTemp
    var endMired = 1000000 / toTemp
    var out = []
    for (var k = 0; k < steps; k++) {
      var f = (k + 1) / steps
      out.push({
        offset: Math.round(k * minutes / steps),
        temp: Math.round(1000000 / (startMired + (endMired - startMired) * f))
      })
    }
    return out
  }

  // The way back up. The fade in starts moving at its named time; the fade out
  // instead has to *land* on daylight at off + minutes, where the identity
  // profile goes, so its steps are shifted one slot later and the final step —
  // which would just be neutral again — is dropped.
  function fadeOutSteps(target, minutes) {
    var all = fadeSteps(target, neutralTemperature, minutes)
    var out = []
    for (var i = 0; i < all.length - 1; i++)
      out.push({ offset: Math.round((i + 1) * minutes / all.length), temp: all[i].temp })
    return out
  }

  function minutesSince(t) {
    var now = new Date()
    return ((((now.getHours() * 60 + now.getMinutes()) - minutesOf(t)) % 1440) + 1440) % 1440
  }

  function inFadeWindow(t, eff) {
    return eff > 0 && minutesSince(t) < eff
  }

  function stepAt(steps, elapsed, fallback) {
    var t = fallback
    for (var i = 0; i < steps.length; i++) if (steps[i].offset <= elapsed) t = steps[i].temp
    return t
  }

  // Where the schedule should have the screen right now: mid fade in, mid fade
  // out, or the plain target in the steady stretch between them.
  function rampTemperature() {
    if (!fade) return temperature
    var eff = effectiveFade(onTime, offTime, fadeMinutes)
    if (inFadeWindow(onTime, eff)) {
      var steps = fadeSteps(neutralTemperature, temperature, eff)
      return stepAt(steps, minutesSince(onTime), steps[0].temp)
    }
    var effOut = effectiveFadeOut(onTime, offTime, fadeMinutes)
    if (inFadeWindow(offTime, effOut))
      return stepAt(fadeOutSteps(temperature, effOut), minutesSince(offTime), temperature)
    return temperature
  }

  // ---- Preview -----------------------------------------------------------
  // The two ramps, as the panel draws them: a gradient painted in the colours
  // the screen will actually pass through, bracketed by the clock times.
  readonly property string sunGlyph: "󰖙"
  readonly property string nightGlyph: "󰽥"

  readonly property var fadeRamps: buildFadeRamps()

  // Measured rather than guessed so the column still lines up after
  // `omarchy font set`.
  TextMetrics { id: sunMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.body; text: root.sunGlyph }
  TextMetrics { id: nightMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.body; text: root.nightGlyph }
  readonly property real glyphWidth: Math.ceil(Math.max(sunMetrics.width, nightMetrics.width))

  function buildFadeRamps() {
    if (!editFade || !validTimes) return []
    var on = pad(editOnTime), off = pad(editOffTime)
    var eff = effectiveFade(on, off, editFadeMinutes)
    var effOut = effectiveFadeOut(on, off, editFadeMinutes)
    var out = []
    if (eff > 0) out.push({
      from: neutralTemperature, to: editTemperature, outbound: false, minutes: eff,
      fromGlyph: sunGlyph, toGlyph: nightGlyph,
      fromLabel: on, toLabel: fmtMinutes(minutesOf(on) + eff)
    })
    if (effOut > 0) out.push({
      from: editTemperature, to: neutralTemperature, outbound: true, minutes: effOut,
      fromGlyph: nightGlyph, toGlyph: sunGlyph,
      fromLabel: off, toLabel: fmtMinutes(minutesOf(off) + effOut)
    })
    return out
  }

  // ---- Live position -----------------------------------------------------
  // Fractional minutes since midnight, ticked only while the panel is open.
  // The model itself stays constant so the marker slides instead of the
  // Repeater tearing its delegates down every tick.
  property real nowMinutes: 0

  Timer {
    interval: 10000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: {
      var d = new Date()
      root.nowMinutes = d.getHours() * 60 + d.getMinutes() + d.getSeconds() / 60
    }
  }

  function elapsedIn(ramp) {
    return ((((nowMinutes - minutesOf(ramp.fromLabel)) % 1440) + 1440) % 1440)
  }

  // The step the schedule is actually holding — the staircase value, not the
  // smooth one, since that is what the screen is really showing.
  function rampTempAt(ramp, elapsed) {
    var steps = ramp.outbound
      ? fadeOutSteps(ramp.from, ramp.minutes)
      : fadeSteps(ramp.from, ramp.to, ramp.minutes)
    return stepAt(steps, Math.floor(elapsed), ramp.from)
  }

  function fadeClampNote() {
    if (!editFade || !validTimes) return ""
    var on = pad(editOnTime), off = pad(editOffTime)
    if (effectiveFade(on, off, editFadeMinutes) >= editFadeMinutes
      && effectiveFadeOut(on, off, editFadeMinutes) >= editFadeMinutes) return ""
    return "Shortened to fit between " + on + " and " + off + "."
  }

  // Blackbody approximation (Tanner Helland's fit) — close enough to show
  // what the ramp looks like, which is all the swatch is for.
  function kelvinColor(k) {
    var t = k / 100, r, g, b
    if (t <= 66) {
      r = 255
      g = 99.4708025861 * Math.log(t) - 161.1195681661
      b = t <= 19 ? 0 : 138.5177312231 * Math.log(t - 10) - 305.0447927307
    } else {
      r = 329.698727446 * Math.pow(t - 60, -0.1332047592)
      g = 288.1221695283 * Math.pow(t - 60, -0.0755148492)
      b = 255
    }
    var c = function (v) { return Math.max(0, Math.min(255, v)) / 255 }
    return Qt.rgba(c(r), c(g), c(b), 1)
  }

  // Sampled the same way the schedule steps are: evenly in mireds, so the
  // gradient's midpoint is the colour the screen really shows halfway through.
  function rampColor(fromTemp, toTemp, f) {
    var a = 1000000 / fromTemp, b = 1000000 / toTemp
    return kelvinColor(1000000 / (a + (b - a) * f))
  }

  function parseConf(text) {
    var raw = String(text || "")
    var on = null, off = null, temp = null, fadeOn = null, fadeMin = null

    // A fade writes out dozens of generated profiles, so the schedule the user
    // actually chose is recorded on a header comment and read back from there.
    // Everything still falls back to the profiles, which is what a config
    // written by hand (or by an older version of this widget) looks like.
    var meta = raw.match(/#\s*nightlight:([^\n]*)/)
    if (meta) {
      var pick = function (key) {
        var m = meta[1].match(new RegExp("(?:^|\\s)" + key + "\\s*=\\s*(\\S+)"))
        return m ? m[1] : null
      }
      var mOn = pick("on"), mOff = pick("off"), mTemp = pick("temperature")
      var mFade = pick("fade"), mFadeOn = pick("fadeEnabled")
      if (mOn && /^\d{1,2}:\d{2}$/.test(mOn)) on = mOn
      if (mOff && /^\d{1,2}:\d{2}$/.test(mOff)) off = mOff
      if (mTemp && Number(mTemp)) temp = Number(mTemp)
      if (mFade && Number(mFade)) fadeMin = Number(mFade)
      if (mFadeOn) fadeOn = mFadeOn === "true"
    }

    var fallbackOn = null, fallbackTemp = null
    var blocks = raw.match(/profile\s*\{[^}]*\}/g) || []
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i]
      var t = b.match(/time\s*=\s*(\d{1,2}:\d{2})/)
      if (!t) continue
      if (/identity\s*=\s*true/.test(b)) { if (!off) off = t[1] }
      else if (on === null && temp === null) {
        // Last one wins, as before the fade: on a generated config that has
        // lost its header this at least lands on the real target temperature.
        var k = b.match(/temperature\s*=\s*(\d+)/)
        if (k) { fallbackOn = t[1]; fallbackTemp = Number(k[1]) }
      }
    }
    if (on === null) on = fallbackOn
    if (temp === null) temp = fallbackTemp
    var wasDirty = dirty
    if (on) onTime = on
    if (off) offTime = off
    if (temp) temperature = temp
    if (fadeMin) fadeMinutes = Math.max(minFadeMinutes, Math.min(maxFadeMinutes, fadeMin))
    fade = fadeOn === true
    parsed = true
    if (!wasDirty) resetEdits()
  }

  function resetEdits() {
    editOnTime = onTime
    editOffTime = offTime
    editTemperature = temperature
    editFade = fade
    editFadeMinutes = fadeMinutes
  }

  function pad(t) {
    var p = t.split(":")
    return (p[0].length < 2 ? "0" + p[0] : p[0]) + ":" + p[1]
  }

  readonly property string pendingPath: Quickshell.env("HOME") + "/.local/state/omarchy/nightlight-restart-pending"
  property bool restartPending: false
  property string saveError: ""

  // ---- Suppressing the schedule -----------------------------------------
  // A fade puts a profile on the clock every minute, and the fade out walks
  // the screen back up from the target — so once the config has one, "off"
  // does not stay off: the next step re-warms the screen within the minute,
  // and even from outside a window the dawn ramp switches the light back on.
  // hyprsunset has no way to pause a schedule, so the only honest answer is
  // to stop the process and bring it back when the schedule agrees with the
  // user again. Held in a file so it survives a shell restart, and holding a
  // wall-clock deadline rather than a countdown so it survives sleep too.
  readonly property string suppressPath: Quickshell.env("HOME") + "/.local/state/omarchy/nightlight-suppressed"
  property real suppressUntil: 0
  readonly property bool scheduleSuppressed: suppressUntil > 0

  function nextOccurrence(minutesIntoDay) {
    var now = new Date()
    var at = new Date(now)
    at.setHours(Math.floor(minutesIntoDay / 60) % 24, minutesIntoDay % 60, 0, 0)
    if (at.getTime() <= now.getTime()) at.setDate(at.getDate() + 1)
    return at.getTime()
  }

  // When the running schedule next agrees that the light is off: the identity
  // profile, which sits at the end of the fade out. Zero when the next thing
  // the schedule does is a legitimate turn-on, which needs no suppressing.
  function suppressDeadline() {
    if (!fade) return 0
    var identityAt = nextOccurrence(minutesOf(offTime)
      + effectiveFadeOut(onTime, offTime, fadeMinutes))
    return identityAt < nextOccurrence(minutesOf(onTime)) ? identityAt : 0
  }

  // ---- File access goes through nightlight-file.pl, which holds the parent
  //      directory and uses O_NOFOLLOW/O_EXCL + fstat so a swapped pathname
  //      cannot redirect a read or write. Paths are always passed as
  //      arguments, never interpolated into a script.
  readonly property string helper: Qt.resolvedUrl("nightlight-file.pl").toString().replace(/^file:\/\//, "")

  // Restart hyprsunset, waiting for the old instance to release the display
  // before launching the new one. $4 = pending marker, $5 = helper.
  readonly property string restartScript:
      'pkill -x hyprsunset; for i in $(seq 1 30); do pgrep -x hyprsunset >/dev/null || break; sleep 0.1; done; ' +
      'setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & ' +
      'for i in $(seq 1 30); do hyprctl hyprsunset temperature >/dev/null 2>&1 && break; sleep 0.1; done; sleep 0.5; ' +
      'perl -- "$5" unmark "$4"; omarchy-shell -q nightlight refresh; '

  function reload() {
    if (readProc.running) return
    readProc.command = ["perl", "--", helper, "read", confPath, pendingPath]
    readProc.running = true
  }

  // The whole config file, including the generated fade staircase. The header
  // comment carries the schedule the user chose, since the profiles alone no
  // longer say which temperature is the target.
  function profileBlock(time, temp) {
    return temp === null
      ? "\nprofile {\n    time = " + time + "\n    identity = true\n}\n"
      : "\nprofile {\n    time = " + time + "\n    temperature = " + temp + "\n}\n"
  }

  function buildConf(on, off, temp, fadeOn, fadeMin) {
    var eff = fadeOn ? effectiveFade(on, off, fadeMin) : 0
    var effOut = fadeOn ? effectiveFadeOut(on, off, fadeMin) : 0
    var body = "# Night light schedule (edited from the bar widget)\n"
      + "# nightlight: on=" + on + " off=" + off + " temperature=" + temp
      + " fade=" + fadeMin + " fadeEnabled=" + (fadeOn ? "true" : "false") + "\n"
    var i

    // Turn-off side: ramp back up, landing on identity at off + minutes.
    if (effOut <= 0) {
      body += profileBlock(off, null)
    } else {
      var outSteps = fadeOutSteps(temp, effOut)
      body += "\n# Fade out, " + off + " -> " + fmtMinutes(minutesOf(off) + effOut)
        + ", easing back to daylight. Generated by the Night Light widget; edit it there.\n"
      for (i = 0; i < outSteps.length; i++)
        body += profileBlock(fmtMinutes(minutesOf(off) + outSteps[i].offset), outSteps[i].temp)
      body += profileBlock(fmtMinutes(minutesOf(off) + effOut), null)
    }

    // Turn-on side: ramp down from daylight to the target.
    if (eff <= 0) return body + profileBlock(on, temp)

    var steps = fadeSteps(neutralTemperature, temp, eff)
    body += "\n# Fade in, " + on + " -> " + fmtMinutes(minutesOf(on) + eff)
      + ", easing to " + temp + "K. Generated by the Night Light widget; edit it there.\n"
    for (i = 0; i < steps.length; i++)
      body += profileBlock(fmtMinutes(minutesOf(on) + steps[i].offset), steps[i].temp)
    return body
  }

  function save(force) {
    if (!validTimes || saving) return
    saving = true
    saveError = ""
    var on = pad(editOnTime), off = pad(editOffTime), temp = editTemperature
    // Every step of a fade is derived from the target, so changing it
    // invalidates the schedule the running hyprsunset holds. Taking the live
    // shortcut there would leave it ramping to the old target on the far side
    // of the night — the exact jump the fade exists to remove.
    var timesChanged = on !== pad(onTime) || off !== pad(offTime) || fadeDirty
      || (editFade && temp !== temperature)
    var body = buildConf(on, off, temp, editFade, editFadeMinutes)
    // Mid-fade, the live shortcut below would jump the screen to the target and
    // skip the rest of the ramp, so let the restart re-derive the right step.
    var midFade = editFade
      && (inFadeWindow(on, effectiveFade(on, off, editFadeMinutes))
        || inFadeWindow(off, effectiveFadeOut(on, off, editFadeMinutes)))
    // While suppressed hyprsunset is not running, so the live shortcut has
    // nothing to talk to; the restart both applies the edit and revives it.
    if (scheduleSuppressed) { midFade = true; clearSuppression() }
    var tail
    if (active && !timesChanged && !midFade) {
      // Only the temperature moved while the light is on: apply it live so
      // there is no restart flash. hyprsunset does not reread its config, so
      // remember to restart it the next time the light is off (invisible).
      tail = 'hyprctl hyprsunset temperature "$3" >/dev/null; perl -- "$5" mark "$4"; omarchy-shell -q nightlight refresh'
      restartPending = true
    } else {
      tail = restartScript
      restartPending = false
    }
    saveProc.command = ["bash", "-c", 'perl -- "$5" write "$2" "$1" || exit $?; ' + tail, "_", body, confPath, String(temp), pendingPath, helper]
    saveProc.running = true
  }

  function suppressSchedule() {
    var deadline = suppressDeadline()
    if (deadline === 0) { service.setNightlight(false); return }
    suppressUntil = deadline
    // Settle on the day temperature *before* killing, and confirm it stuck.
    // `hyprsunset identity` looks right here but leaves `temperature` reading
    // back the old warm value, so the service would see the light as on, and
    // the resulting activeChanged would clear the suppression we are in the
    // middle of taking. Reading back 6500 keeps every probe in this window
    // agreeing the light is off, and once the process is gone they fail and
    // report off anyway.
    suppressProc.command = ["bash", "-c",
      'for i in $(seq 1 10); do hyprctl hyprsunset temperature 6500 >/dev/null 2>&1; ' +
      '[ "$(hyprctl hyprsunset temperature 2>/dev/null | grep -oE "[0-9]+" | head -n1)" = "6500" ] && break; ' +
      'sleep 0.2; done; pkill -x hyprsunset; ' +
      'perl -- "$3" write "$2" "$1"; omarchy-shell -q nightlight refresh',
      "_", String(deadline), suppressPath, helper]
    suppressProc.running = true
  }

  // Anything that turns the light back on — our switch, the keybinding, the
  // stock indicator — hands control back to the schedule. Both of those paths
  // relaunch hyprsunset themselves, so only the marker needs clearing.
  function clearSuppression() {
    if (!scheduleSuppressed) return
    suppressUntil = 0
    clearSuppressProc.command = ["perl", "--", helper, "unmark", suppressPath]
    clearSuppressProc.running = true
  }

  function resumeScheduleIfDue() {
    if (!scheduleSuppressed || saving || restartProc.running) return
    if (Date.now() < suppressUntil) return
    suppressUntil = 0
    // The schedule now says off too, so a plain restart lands on identity.
    restartProc.command = ["bash", "-c", restartScript, "_", "", "", "", suppressPath, helper]
    restartProc.running = true
  }

  function readSuppression() {
    if (suppressReadProc.running) return
    suppressReadProc.command = ["perl", "--", helper, "read", suppressPath]
    suppressReadProc.running = true
  }

  Process { id: suppressProc }

  // The service's own apply relaunches hyprsunset when it is not running, so
  // killing the moment the light goes off races it and the process comes
  // straight back. Let that settle, then re-check the conditions rather than
  // acting on what was true when the light went off.
  Timer {
    id: suppressDebounce
    interval: 2500
    repeat: false
    onTriggered: {
      if (root.active || !root.fade || !root.service) return
      if (root.service.temperature !== root.service.dayTemperature) return
      if (root.suppressDeadline() === 0) return
      root.suppressSchedule()
    }
  }
  Process { id: clearSuppressProc }

  Process {
    id: suppressReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = Number(String(text || "").trim())
        root.suppressUntil = v > 0 ? v : 0
        if (root.scheduleSuppressed) Qt.callLater(root.resumeScheduleIfDue)
      }
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: root.scheduleSuppressed
    onTriggered: root.resumeScheduleIfDue()
  }

  function runPendingRestart() {
    // Wait for the nightlight service to report real state; before that
    // `active` is false and a restart here would wrongly force the light off.
    if (!restartPending || !service || !service.stateLoaded || active || saving || restartProc.running) return
    // Reviving hyprsunset here would undo a suppression; the resume path
    // brings it back when the schedule agrees the light is off.
    if (scheduleSuppressed) return
    // `active` first goes false a couple of steps before a fade-out finishes,
    // when the ramp crosses the service's threshold. Restarting there would
    // force 6500 and cut the tail off the ramp, so wait for a quiet moment.
    if (fade && (inFadeWindow(onTime, effectiveFade(onTime, offTime, fadeMinutes))
      || inFadeWindow(offTime, effectiveFadeOut(onTime, offTime, fadeMinutes)))) return
    // The fresh instance applies the schedule, which may switch the light
    // back on; the user just turned it off, so keep it off.
    restartProc.command = ["bash", "-c",
      restartScript + 'hyprctl hyprsunset temperature 6500 >/dev/null; omarchy-shell -q nightlight refresh',
      "_", "", "", "", pendingPath, helper]
    restartProc.running = true
  }

  onActiveChanged: {
    // The light coming back on by any route — the keybinding and the stock
    // indicator both relaunch hyprsunset — means the schedule is running
    // again and the marker is stale.
    if (active) { suppressDebounce.stop(); clearSuppression(); return }
    // Going off is either someone asking for it or the fade out finishing on
    // its own. Only an explicit off lands exactly on the service's day
    // temperature; a ramp step never does (the coolest is a few hundred K
    // short of it), which keeps the last steps of a fade out from being read
    // as a request and cutting the ramp short.
    if (fade && service && service.temperature === service.dayTemperature
      && suppressDeadline() !== 0) suppressDebounce.restart()
    else Qt.callLater(runPendingRestart)
  }

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
    onExited: function(exitCode) {
      if (exitCode === 3) root.saveError = "Config path is a symlink or not a regular file."
    }
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
      if (exitCode === 3) root.saveError = "Config path is a symlink or not a regular file; not written."
      else if (exitCode !== 0) root.saveError = "Couldn't write hyprsunset.conf."
      root.reload()
      if (root.service) root.service.refresh()
    }
  }

  function setActive(on) {
    if (!service) return
    // Turn on with the configured temperature (not the stock 4000K) — or, if
    // the fade is under way, with the step the ramp has reached, so flipping
    // the switch on mid-fade does not jump straight to the target.
    // Clamped below the service's threshold: the first steps of a ramp are
    // above it, and applying one would leave the service reporting the light
    // off and the switch flipping straight back.
    if (on) {
      clearSuppression()
      service.applyTemperature(Math.min(rampTemperature(), onThreshold - 1))
    } else {
      // Suppression is driven from onActiveChanged rather than here, so that
      // the keybinding and the stock indicator get it too.
      service.setNightlight(false)
    }
  }

  Component.onCompleted: { reload(); readSuppression() }

  onOpenedChanged: if (opened) {
    if (service) service.refresh()
    reload()
    resumeScheduleIfDue()
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
      blocked: onField.activeFocus || offField.activeFocus || tempField.field.activeFocus || fadeField.field.activeFocus
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
          spacing: Style.space(16)

          Column {
            spacing: Style.spacing.md
            Text {
              text: "Gradual fade"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Item {
              width: fadeSwitch.implicitWidth
              height: tempField.field.height
              ToggleSwitch {
                id: fadeSwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: root.editFade
                foreground: root.foreground
                onToggled: root.editFade = !root.editFade
              }
            }
          }

          NumberField {
            id: fadeField
            label: "Over (min)"
            from: root.minFadeMinutes
            to: root.maxFadeMinutes
            stepSize: 5
            value: root.editFadeMinutes
            enabled: root.editFade
            opacity: root.editFade ? 1 : 0.4
            foreground: root.foreground
            fontFamily: root.fontFamily
            // Matches the "Turns off" field it sits under, so the two rows
            // land on the same column grid.
            fieldWidth: Style.space(80)
            onModified: function(v) { root.editFadeMinutes = v }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.fadeRamps

            delegate: Item {
              id: ramp
              required property var modelData
              width: parent.width
              height: row.height + (live ? nowTemp.implicitHeight + Style.space(3) : 0)

              readonly property real elapsed: root.elapsedIn(modelData)
              readonly property bool live: elapsed < modelData.minutes
              readonly property real progress: live ? elapsed / modelData.minutes : 0

              Text {
                id: nowTemp
                visible: ramp.live
                anchors.top: parent.top
                // Rides the marker, but never past either end of the bar.
                x: Math.max(bar.x, Math.min(bar.x + bar.width - width,
                     bar.x + bar.width * ramp.progress - width / 2))
                text: root.rampTempAt(ramp.modelData, ramp.elapsed) + "K"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Item {
                id: row
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.max(fromLabel.implicitHeight, fromGlyph.implicitHeight)

                Text {
                  id: fromLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: ramp.modelData.fromLabel
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: fromGlyph
                  anchors.left: fromLabel.right
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: ramp.modelData.fromGlyph
                  width: root.glyphWidth
                  horizontalAlignment: Text.AlignHCenter
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: toLabel
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: ramp.modelData.toLabel
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: toGlyph
                  anchors.right: toLabel.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: ramp.modelData.toGlyph
                  width: root.glyphWidth
                  horizontalAlignment: Text.AlignHCenter
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                // The border keeps the bar readable on a light theme, where
                // the daylight end of the gradient is close to the panel
                // itself.
                BorderSurface {
                  id: bar
                  anchors.left: fromGlyph.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: toGlyph.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(9)
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: root.rampColor(ramp.modelData.from, ramp.modelData.to, 0.0) }
                    GradientStop { position: 0.25; color: root.rampColor(ramp.modelData.from, ramp.modelData.to, 0.25) }
                    GradientStop { position: 0.5; color: root.rampColor(ramp.modelData.from, ramp.modelData.to, 0.5) }
                    GradientStop { position: 0.75; color: root.rampColor(ramp.modelData.from, ramp.modelData.to, 0.75) }
                    GradientStop { position: 1.0; color: root.rampColor(ramp.modelData.from, ramp.modelData.to, 1.0) }
                  }
                }

                // Where the schedule is right now. The dark halo is what keeps
                // the marker visible over the daylight end, where the bar is
                // nearly white; the overhang above and below lands on the
                // panel itself, so it never disappears into the gradient.
                Item {
                  visible: ramp.live
                  width: Style.space(6)
                  height: bar.height + Style.space(6)
                  x: bar.x + bar.width * ramp.progress - width / 2
                  anchors.verticalCenter: bar.verticalCenter

                  Rectangle {
                    anchors.centerIn: parent
                    width: Style.space(4)
                    height: parent.height
                    radius: width / 2
                    color: Qt.rgba(0, 0, 0, 0.45)
                  }

                  Rectangle {
                    anchors.centerIn: parent
                    width: Style.space(2)
                    height: parent.height - Style.space(2)
                    radius: width / 2
                    color: root.foreground
                  }
                }
              }
            }
          }

          // A ramp with no room at all is unreachable — the night and the day
          // always sum to the full 1440, so one end can always fade. A ramp
          // *clamped* short is reachable, and is what needs saying.
          Text {
            text: root.fadeClampNote()
            visible: text !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
