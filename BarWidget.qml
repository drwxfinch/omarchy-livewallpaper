import QtQuick
import Quickshell
import qs.Ui
import "Model.js" as Model

// Bar button for the Livewall panel.
//
// Left click opens the panel. Right click pauses every monitor when at least
// one is playing, and resumes every monitor otherwise. The daemon lives in
// Service.qml; this widget mirrors its aggregate state for the icon and
// tooltip, and reads the flat settings only as a fallback before the service
// has been attached.
BarWidget {
  id: root
  moduleName: "morph.livewall"

  property var daemon: null

  readonly property var flatConfig: Model.monitorSettings(root.settings, "")
  readonly property bool liveMode: flatConfig.mode === "live"
  readonly property bool paused: flatConfig.paused === true
  readonly property string video: flatConfig.video

  readonly property var states: root.daemon && root.daemon.monitorStates ? root.daemon.monitorStates : []
  readonly property int playingCount: {
    var n = 0
    for (var i = 0; i < root.states.length; i++) {
      var s = root.states[i]
      if (s && s.mode === "live" && s.running && !s.paused) n++
    }
    return n
  }
  readonly property bool anyPlaying: playingCount > 0
  readonly property bool playing: {
    if (root.states.length > 0) return root.anyPlaying
    return root.liveMode && !root.paused && root.video !== ""
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function attach() {
    if (root.daemon) return
    if (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      root.daemon = root.bar.shell.serviceFor(root.moduleName)
  }

  function open() {
    if (!panelLoader.item) {
      console.warn("Livewall: panel is not loaded, cannot open")
      return
    }
    panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function commitSettings(next) {
    root.settings = next
    if (panelLoader.item && "settings" in panelLoader.item) panelLoader.item.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      var entry = { id: root.moduleName }
      for (var key in next) if (key !== "id") entry[key] = next[key]
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  // Quick "pause everything" from the bar. With sync on the flat pause flag is
  // enough; with sync off every connected output gets its own entry.
  function toggleAllPause() {
    var target = !root.anyPlaying
    var next = root.settings
    if (Model.syncEnabled(root.settings)) {
      next = Model.setMonitorSetting(next, "", { paused: target }, true)
    } else {
      var list = root.daemon ? root.daemon.monitorList : []
      if (list.length === 0) {
        next = Model.setMonitorSetting(next, "", { paused: target }, true)
      } else {
        for (var i = 0; i < list.length; i++)
          next = Model.setMonitorSetting(next, String(list[i].name), { paused: target }, false)
      }
    }
    commitSettings(next)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("daemon" in target && root.daemon) target.daemon = root.daemon
  }

  readonly property string summaryText: {
    var list = root.states
    if (list && list.length > 0) {
      if (list.length === 1) {
        var s = list[0]
        if (s.mode !== "live") return "Livewall: stock wallpaper"
        if (s.video === "") return "Livewall: no video selected"
        if (s.paused || s.reason === "manual") return "Livewall: paused"
        if (s.running) return "Livewall: playing on " + s.name
        return "Livewall: starting"
      }
      if (root.playingCount === 0) return "Livewall: all paused"
      if (root.playingCount === list.length) return "Livewall: all " + list.length + " playing"
      return "Livewall: " + root.playingCount + " of " + list.length + " playing"
    }
    if (!root.liveMode) return "Livewall: stock wallpaper"
    if (root.video === "") return "Livewall: no video selected"
    return root.paused ? "Livewall: paused" : "Livewall: playing"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onDaemonChanged: {
    injectPanel()
    if (root.daemon && typeof root.daemon.refresh === "function") root.daemon.refresh()
  }

  Component.onCompleted: root.attach()

  Timer {
    interval: 500
    repeat: true
    running: !root.daemon
    onTriggered: root.attach()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
    onStatusChanged: {
      if (status === Loader.Error) console.warn("Livewall: panel failed to load:", errorString())
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf03d"
    active: root.playing
    tooltipText: root.summaryText

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAllPause()
      else root.togglePanel()
    }
  }
}
