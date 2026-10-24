import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower

import "Model.js" as Model

// Headless live-wallpaper daemon.
//
// One instance runs for the whole shell. It owns one mpvpaper child per
// monitor, keeps them on the "bottom" layer (above Omarchy's background
// surface, below windows and the bar), freezes them with SIGSTOP when the
// wallpaper is covered, and tears every child down when the plugin is
// disabled, removed, or the shell exits.
//
// State lives in this plugin's inline entry in ~/.config/omarchy/shell.json,
// the same store the bar widget writes. Reading the file here is what lets the
// daemon keep running when no widget is on screen.
Item {
  id: root
  visible: false

  // Injected by the shell host.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "morph.livewall"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || home + "/.cache"
  readonly property string cacheDir: cacheHome + "/morph.livewall"
  // Unique mpv option so a leftover process from a hard-killed shell can be
  // found and stopped before a new one starts.
  readonly property string token: "omarchy-livewall-" + pluginId
  readonly property string mpvOptions: Model.mpvOptions(token)
  // Give a fresh mpvpaper time to map its surface and draw one frame before a
  // freeze, otherwise the layer can stay black.
  readonly property int graceMs: 2000

  property var settings: Model.defaultSettings(home)
  property var monitorsJson: []
  property var clientsJson: []
  property var covered: ({})
  property var monitorNames: []

  property bool haveMpvpaper: false
  property bool haveFfmpeg: false
  property bool depsChecked: false
  property bool sweepDone: false
  property bool cleanupDone: false
  property bool lockRunning: false
  property bool videoOk: false
  property bool pendingRefresh: false
  property string lastError: ""
  // Mirrors overallReason() so the panel can bind to a real property instead
  // of calling a function whose dependencies QML cannot track.
  property string reason: ""

  readonly property string videoFile: Model.expandHome(String(settings.video || ""), home)
  readonly property bool liveMode: String(settings.mode || "live") === "live"
  readonly property bool manualPause: settings.paused === true
  readonly property bool batteryPause: settings.autoBattery === true && UPower.onBattery
  readonly property bool lockPause: settings.autoLock === true && lockRunning
  readonly property bool shouldRun: liveMode && videoOk && haveMpvpaper

  function shouldPause(name) {
    if (manualPause || batteryPause || lockPause) return true
    return settings.autoWindows === true && covered[name] === true
  }

  function pauseReason(name) {
    if (!liveMode) return "static"
    if (videoFile === "") return "no video"
    if (!videoOk) return "video missing"
    if (!haveMpvpaper) return "mpvpaper missing"
    if (manualPause) return "manual"
    if (lockPause) return "locked"
    if (batteryPause) return "battery"
    if (settings.autoWindows === true && covered[name] === true) return "window"
    return ""
  }

  function overallReason() {
    for (var i = 0; i < monitorModel.count; i++) {
      var item = monitorRepeater.itemAt(i)
      if (!item) continue
      var reason = pauseReason(item.name)
      if (reason !== "") return reason
    }
    return ""
  }

  function statusJson() {
    var list = []
    for (var i = 0; i < monitorRepeater.count; i++) {
      var item = monitorRepeater.itemAt(i)
      if (!item) continue
      list.push({
        name: item.name,
        running: item.alive,
        paused: item.frozen,
        reason: pauseReason(item.name)
      })
    }
    return JSON.stringify({
      mode: liveMode ? "live" : "static",
      video: videoFile,
      videoOk: videoOk,
      mpvpaper: haveMpvpaper,
      ffmpeg: haveFfmpeg,
      manualPause: manualPause,
      reason: overallReason(),
      lastError: lastError,
      monitors: list
    })
  }

  // ------------------------------------------------------------- settings

  function loadSettings(raw) {
    var next = Model.parseSettings(raw, pluginId, Model.defaultSettings(home))
    var videoChanged = String(next.video || "") !== String(settings.video || "")
    settings = next
    if (videoChanged) {
      videoOk = false
      stopAll()
      probeVideo()
    }
    if (depsChecked && cleanupDone) Qt.callLater(reconcile)
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onFileChanged: reload()
    onLoadFailed: root.loadSettings("")
  }

  Process {
    id: videoProbe
    running: false
    onExited: function(exitCode) {
      root.videoOk = exitCode === 0
      if (root.videoProbePending) {
        root.videoProbePending = false
        root.probeVideo()
        return
      }
      root.reconcile()
    }
  }

  property bool videoProbePending: false

  function probeVideo() {
    if (videoFile === "") {
      videoOk = false
      if (cleanupDone) Qt.callLater(reconcile)
      return
    }
    if (videoProbe.running) {
      videoProbePending = true
      return
    }
    videoProbe.command = ["test", "-f", videoFile]
    videoProbe.running = true
  }

  // ---------------------------------------------------------- dependencies

  Process {
    id: depsProc
    running: false
    command: ["bash", "-c", "command -v mpvpaper >/dev/null && echo yes || echo no; command -v ffmpeg >/dev/null && echo yes || echo no"]
    stdout: StdioCollector {
      id: depsOut
      waitForEnd: true
    }
    onExited: {
      var lines = String(depsOut.text || "").trim().split("\n")
      root.haveMpvpaper = String(lines[0] || "") === "yes"
      root.haveFfmpeg = String(lines[1] || "") === "yes"
      root.depsChecked = true
      root.maybeStart()
    }
  }

  // Kill wallpapers a previous shell may have left behind after a hard exit.
  // Patterns match this script's own argv, so its pid is skipped.
  Process {
    id: sweepProc
    running: false
    environment: ({ TOKEN: root.token })
    command: ["bash", "-c", "for pid in $(pgrep -f -- \"$TOKEN\" 2>/dev/null); do [ \"$pid\" = \"$$\" ] && continue; kill -CONT \"$pid\" 2>/dev/null; kill -TERM \"$pid\" 2>/dev/null; done"]
    onExited: {
      root.sweepDone = true
      root.maybeStart()
    }
  }

  function maybeStart() {
    if (cleanupDone || !depsChecked || !sweepDone) return
    cleanupDone = true
    refresh()
  }

  // -------------------------------------------------------------- hyprland

  function refresh() {
    if (!cleanupDone) return
    if (monitorsProc.running || clientsProc.running) {
      pendingRefresh = true
      return
    }
    monitorsProc.running = true
  }

  Process {
    id: monitorsProc
    running: false
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      id: monitorsOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          root.monitorsJson = JSON.parse(String(monitorsOut.text || "[]"))
        } catch (e) {
          root.lastError = "Could not read monitors"
        }
      }
      clientsProc.running = true
    }
  }

  Process {
    id: clientsProc
    running: false
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      id: clientsOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        try {
          root.clientsJson = JSON.parse(String(clientsOut.text || "[]"))
        } catch (e) {
          root.lastError = "Could not read windows"
        }
      }
      root.applyState()
      if (root.pendingRefresh) {
        root.pendingRefresh = false
        root.refresh()
      }
    }
  }

  function relevantEvent(name) {
    var prefixes = ["workspace", "focusedmon", "openwindow", "closewindow",
      "movewindow", "moveworkspace", "fullscreen", "changefloatingmode",
      "activespecial", "monitoradded", "monitorremoved"]
    if (String(name || "") === "configreloaded") return true
    for (var i = 0; i < prefixes.length; i++) {
      if (String(name || "").indexOf(prefixes[i]) === 0) return true
    }
    return false
  }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      var name = event ? String(event.name || "") : ""
      if (!root.relevantEvent(name)) return
      // Monitor hotplug settles slower than a window map.
      debounce.interval = name.indexOf("monitor") === 0 ? 300 : 100
      debounce.restart()
    }
  }

  Timer {
    id: debounce
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: 5000
    running: root.cleanupDone
    repeat: true
    onTriggered: {
      root.refresh()
      root.checkLock()
    }
  }

  Process {
    id: lockProc
    running: false
    command: ["pgrep", "-x", "hyprlock"]
    onExited: function(exitCode) {
      var locked = exitCode === 0
      if (locked === root.lockRunning) return
      root.lockRunning = locked
      root.reconcile()
    }
  }

  function checkLock() {
    if (!lockProc.running) lockProc.running = true
  }

  // --------------------------------------------------------------- monitors

  ListModel {
    id: monitorModel
  }

  // One Process per monitor. The process is created with its delegate and
  // killed with it, so a removed monitor cannot leave an orphan behind.
  Repeater {
    id: monitorRepeater
    model: monitorModel

    delegate: Item {
      id: monitorItem
      required property string name

      property bool frozen: false
      property bool stopping: false
      property bool restartAfterStop: false
      property real startedAt: 0
      property int failures: 0

      readonly property bool alive: worker.running

      function startWallpaper() {
        if (worker.running) return
        root.lastError = ""
        worker.command = ["mpvpaper", "-l", "bottom", "-o", root.mpvOptions, name, root.videoFile]
        worker.running = true
        frozen = false
        startedAt = Date.now() / 1000
      }

      function ensureRunning() {
        if (!worker.running && !stopping) startWallpaper()
      }

      function stopWallpaper(restart) {
        if (!worker.running) {
          if (restart) startWallpaper()
          return
        }
        if (stopping) return
        // A stopped process cannot act on SIGTERM until it is continued.
        if (frozen) worker.signal(18)
        worker.signal(15)
        frozen = false
        stopping = true
        restartAfterStop = restart === true
        killTimer.restart()
      }

      // SIGTERM is polite; a wedged child must still not outlive the plugin.
      function hardStop() {
        if (!worker.running) return
        if (frozen) worker.signal(18)
        worker.signal(15)
        frozen = false
      }

      function pauseWallpaper() {
        if (!worker.running || frozen) return
        var age = Date.now() / 1000 - startedAt
        var graceLeft = root.graceMs / 1000 - age
        if (graceLeft > 0) {
          graceTimer.interval = Math.max(100, Math.round(graceLeft * 1000))
          graceTimer.restart()
          return
        }
        worker.signal(19)
        frozen = true
      }

      function resumeWallpaper() {
        if (!worker.running || !frozen) return
        worker.signal(18)
        frozen = false
      }

      function handleExit(exitCode) {
        if (stopping) {
          var restart = restartAfterStop
          stopping = false
          restartAfterStop = false
          if (restart) startWallpaper()
          else Qt.callLater(root.reconcile)
          return
        }
        if (exitCode !== 0) root.lastError = "mpvpaper exited with code " + exitCode
        var lived = Date.now() / 1000 - startedAt
        failures = lived > 30 ? 1 : failures + 1
        retryTimer.interval = Math.min(30000, 2000 * Math.pow(2, Math.min(3, failures - 1)))
        retryTimer.restart()
      }

      Process {
        id: worker
        running: false
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(exitCode) { monitorItem.handleExit(exitCode) }
      }

      Timer {
        id: graceTimer
        repeat: false
        onTriggered: root.reconcile()
      }

      Timer {
        id: retryTimer
        repeat: false
        onTriggered: {
          if (root.shouldRun && !worker.running) monitorItem.startWallpaper()
        }
      }

      // Only fires when the child ignored SIGTERM.
      Timer {
        id: killTimer
        interval: 3000
        repeat: false
        onTriggered: if (worker.running) worker.signal(9)
      }

      Component.onDestruction: hardStop()
    }
  }

  function indexOfMonitor(name) {
    for (var i = 0; i < monitorModel.count; i++) {
      if (String(monitorModel.get(i).name) === name) return i
    }
    return -1
  }

  // Diff the model instead of resetting it: a reset would destroy and recreate
  // every delegate, restarting a perfectly healthy wallpaper.
  function syncMonitors(names) {
    for (var i = monitorModel.count - 1; i >= 0; i--) {
      if (names.indexOf(String(monitorModel.get(i).name)) === -1) monitorModel.remove(i)
    }
    for (var j = 0; j < names.length; j++) {
      if (indexOfMonitor(names[j]) === -1) monitorModel.append({ name: names[j] })
    }
  }

  function applyState() {
    var names = []
    var next = {}
    for (var i = 0; i < monitorsJson.length; i++) {
      var monitor = monitorsJson[i]
      if (!monitor || !monitor.name) continue
      var name = String(monitor.name)
      names.push(name)
      next[name] = Model.hasCoveringWindow(monitor, clientsJson)
    }
    covered = next
    monitorNames = names
    syncMonitors(names)
    Qt.callLater(reconcile)
  }

  function stopAll() {
    for (var i = 0; i < monitorRepeater.count; i++) {
      var item = monitorRepeater.itemAt(i)
      if (item) item.stopWallpaper(false)
    }
  }

  function reconcile() {
    if (!cleanupDone) return
    for (var i = 0; i < monitorRepeater.count; i++) {
      var item = monitorRepeater.itemAt(i)
      if (!item) continue
      if (!shouldRun) {
        item.stopWallpaper(false)
        continue
      }
      item.ensureRunning()
      if (shouldPause(item.name)) item.pauseWallpaper()
      else item.resumeWallpaper()
    }
    var next = overallReason()
    if (next !== reason) reason = next
  }

  onCoveredChanged: if (cleanupDone) Qt.callLater(reconcile)
  onShouldRunChanged: if (cleanupDone) Qt.callLater(reconcile)

  Connections {
    target: UPower
    function onOnBatteryChanged() { root.reconcile() }
  }

  IpcHandler {
    target: "morph.livewall"

    function status(): string {
      return root.statusJson()
    }

    function refresh(): void {
      root.refresh()
    }
  }

  Component.onCompleted: {
    depsProc.running = true
    sweepProc.running = true
  }

  // Last line of defence for disable/remove and shell teardown. Delegates also
  // clean up in their own onDestruction, but this runs while they are alive.
  Component.onDestruction: {
    for (var i = 0; i < monitorRepeater.count; i++) {
      var item = monitorRepeater.itemAt(i)
      if (item) item.hardStop()
    }
  }
}
