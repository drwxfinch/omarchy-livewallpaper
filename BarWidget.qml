import QtQuick
import Quickshell
import qs.Ui
import "Model.js" as Model

// Bar button for the Livewall panel.
//
// Left click opens the panel, right click flips the manual pause so the video
// can be frozen without opening anything. The daemon lives in Service.qml; this
// widget only mirrors the settings it needs for its icon state.
BarWidget {
  id: root
  moduleName: "morph.livewall"

  readonly property bool liveMode: String(setting("mode", "live")) === "live"
  readonly property bool paused: Model.coerce(setting("paused", false)) === true
  readonly property string video: String(setting("video", ""))
  readonly property bool playing: liveMode && !paused && video !== ""

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

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

  // Mirrors Panel.persistSettings for the right-click shortcut, which has no
  // panel open to do it for it.
  function setPaused(value) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.paused = value

    root.settings = entry
    if (panelLoader.item && "settings" in panelLoader.item) panelLoader.item.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    tooltipText: !root.liveMode
      ? "Livewall: stock wallpaper"
      : (root.video === ""
        ? "Livewall: no video selected"
        : (root.paused ? "Livewall: paused" : "Livewall: playing"))

    onPressed: function(b) {
      if (b === Qt.RightButton) root.setPaused(!root.paused)
      else root.togglePanel()
    }
  }
}
