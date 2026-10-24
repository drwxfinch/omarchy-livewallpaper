import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Livewall's popup: mode and pause switches, a preview grid of the videos in
// the chosen folder, the folder field, the automatic-pause switches, and the
// keybinding helper.
//
// Video frames are rendered by ffmpeg through three workers at most, only
// while the panel is open. scan.sh reports which cache files already exist,
// so reopening the panel costs one directory walk and no decoding at all.
Panel {
  id: root
  moduleName: "morph.livewall"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Injected by attach(): the plugin's headless Service.qml instance.
  property var daemon: null

  readonly property color fg: barForeground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent

  readonly property string home: Quickshell.env("HOME")
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || home + "/.cache"
  readonly property string thumbDir: cacheHome + "/morph.livewall/thumbs"
  // Qt.resolvedUrl keeps this relative to the plugin folder, so the script
  // moves with it and no path outside the plugin is assumed.
  readonly property string scanScript: decodeURIComponent(String(Qt.resolvedUrl("scan.sh")).replace("file://", ""))

  readonly property bool liveMode: String(setting("mode", "live")) === "live"
  readonly property bool manualPause: boolSetting("paused", false)
  readonly property bool autoWindows: boolSetting("autoWindows", true)
  readonly property bool autoBattery: boolSetting("autoBattery", true)
  readonly property bool autoLock: boolSetting("autoLock", true)
  readonly property string folder: String(setting("folder", home + "/Videos"))
  readonly property string selectedVideo: String(setting("video", ""))
  readonly property int columns: 3

  // ffmpeg is what renders the previews. Without it the grid still lists the
  // folder, it just keeps the placeholders.
  readonly property bool canThumb: !(daemon && daemon.haveFfmpeg === false)

  function boolSetting(name, fallback) {
    return Model.coerce(setting(name, fallback)) === true
  }

  // ------------------------------------------------------------- lifecycle

  function attach() {
    if (root.daemon) return
    if (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      root.daemon = root.bar.shell.serviceFor(root.moduleName)
  }

  function open() {
    attach()
    refresh()
    root.controller.show()
    // Set after showing: showing hands the popout coordinator over, and that
    // closes whichever panel was open, which clears the shared flag.
    Qt.callLater(function() {
      if (!root.opened) return
      setCenterHoverRevealSuppressed(true)
      folderField.text = String(root.setting("folder", root.home + "/Videos"))
      bindField.text = String(root.setting("bind", ""))
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still holding
  // must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  function refresh() {
    attach()
    refreshScan()
    if (root.daemon && typeof root.daemon.refresh === "function") root.daemon.refresh()
  }

  // ---------------------------------------------------------------- status

  readonly property string monitorLabel: {
    var names = daemon ? daemon.monitorNames : null
    return names && names.length > 0 ? names.join(", ") : "this display"
  }

  readonly property string statusText: {
    if (!root.liveMode) return "Stock wallpaper"
    if (root.selectedVideo === "") return "No video selected"
    var d = root.daemon
    if (!d) return "Starting…"
    if (d.haveMpvpaper === false) return "mpvpaper is not installed"
    if (d.videoOk === false) return "Selected video is missing"
    var reason = String(d.reason || "")
    if (reason === "manual") return "Paused manually"
    if (reason === "locked") return "Paused while the screen is locked"
    if (reason === "battery") return "Paused on battery"
    if (reason === "window") return "Paused: a window covers the workspace"
    if (reason === "video missing") return "Selected video is missing"
    return "Playing on " + root.monitorLabel
  }

  readonly property bool playing: liveMode && statusText.indexOf("Playing") === 0

  readonly property string warning: {
    var d = root.daemon
    if (!d) return ""
    if (d.haveMpvpaper === false) return "mpvpaper is not installed — live wallpapers cannot play."
    if (d.haveFfmpeg === false) return "ffmpeg is not installed — video previews are unavailable."
    return String(d.lastError || "")
  }

  // -------------------------------------------------------------- settings

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setMode(live) {
    persistSettings({ mode: live ? "live" : "static" })
  }

  function setPaused(value) {
    persistSettings({ paused: value })
  }

  function setAuto(key, value) {
    var values = {}
    values[key] = value
    persistSettings(values)
  }

  function chooseVideo(path) {
    if (path === root.selectedVideo) return
    persistSettings({ video: path })
  }

  function applyFolder() {
    var next = String(folderField.text || "").trim()
    if (next === "") return
    persistSettings({ folder: next })
    refreshScan()
  }

  function bindLineFor(combo) {
    var key = String(combo || "").trim()
    if (key === "") return ""
    return 'o.bind("' + key + '", "Livewall", "omarchy-shell shell toggle ' + root.moduleName + '")'
  }

  readonly property string bindLine: bindLineFor(setting("bind", ""))

  function applyBind() {
    persistSettings({ bind: String(bindField.text || "").trim() })
  }

  function copyBind() {
    var line = bindLineFor(bindField.text)
    if (line === "") return
    applyBind()
    Quickshell.clipboardText = line
  }

  // ----------------------------------------------------------------- scan

  ListModel {
    id: videoModel
  }

  Process {
    id: scanProc
    running: false
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.loadScan(String(scanOut.text || ""))
    }
  }

  function refreshScan() {
    if (!root.opened || scanProc.running) return
    scanProc.command = ["bash", root.scanScript, Model.expandHome(root.folder, root.home), root.thumbDir]
    scanProc.running = true
  }

  function loadScan(text) {
    var items = Model.parseScanOutput(text)
    videoModel.clear()
    for (var i = 0; i < items.length; i++) {
      videoModel.append({
        path: items[i].path,
        thumb: items[i].thumb,
        ready: items[i].ready,
        failed: false,
        claimed: false,
        ver: items[i].ready ? 1 : 0
      })
    }
    pumpThumbs()
  }

  // ------------------------------------------------------------ thumbnails

  function nextThumbJob() {
    for (var i = 0; i < videoModel.count; i++) {
      var item = videoModel.get(i)
      if (item.ready === true || item.failed === true || item.claimed === true) continue
      return i
    }
    return -1
  }

  function pumpThumbs() {
    if (!root.opened || !root.canThumb) return
    if (!thumbA.running) startThumb(thumbA)
    if (!thumbB.running) startThumb(thumbB)
    if (!thumbC.running) startThumb(thumbC)
  }

  function startThumb(worker) {
    var index = nextThumbJob()
    if (index < 0) return
    var item = videoModel.get(index)
    videoModel.setProperty(index, "claimed", true)
    worker.jobIndex = index
    worker.command = ["ffmpeg", "-v", "error", "-nostdin", "-ss", "1", "-i", item.path,
      "-frames:v", "1", "-vf", "scale=320:-2", "-y", item.thumb]
    worker.running = true
  }

  function finishThumb(worker, exitCode) {
    var index = worker.jobIndex
    worker.jobIndex = -1
    if (index >= 0 && index < videoModel.count) {
      if (exitCode === 0 && index < videoModel.count) {
        videoModel.setProperty(index, "ready", true)
        videoModel.setProperty(index, "ver", Number(videoModel.get(index).ver) + 1)
      } else {
        videoModel.setProperty(index, "failed", true)
      }
    }
    if (root.opened) startThumb(worker)
  }

  Process {
    id: thumbA
    property int jobIndex: -1
    running: false
    onExited: function(exitCode) { root.finishThumb(thumbA, exitCode) }
  }

  Process {
    id: thumbB
    property int jobIndex: -1
    running: false
    onExited: function(exitCode) { root.finishThumb(thumbB, exitCode) }
  }

  Process {
    id: thumbC
    property int jobIndex: -1
    running: false
    onExited: function(exitCode) { root.finishThumb(thumbC, exitCode) }
  }

  // Attached late when the bar loads before the service does.
  Timer {
    interval: 500
    repeat: true
    running: root.opened && !root.daemon
    onTriggered: root.attach()
  }

  // ------------------------------------------------------------------- UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(layout.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: folderField.activeFocus || bindField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: layout.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: layout
          width: scroll.width
          spacing: Style.space(10)

          // Escape must still close while a field owns the keyboard, which is
          // the one case PanelKeyCatcher steps aside for.
          Keys.onEscapePressed: root.close()

          Item {
            width: parent.width
            height: Style.space(24)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Livewall"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.liveMode ? "LIVE" : "STOCK"
              color: root.playing
                ? Style.selectedStateColor(root.fg, root.accent)
                : Qt.darker(root.fg, 1.9)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
              font.bold: true
            }
          }

          Text {
            width: parent.width
            text: root.statusText
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.warning !== ""
            text: root.warning
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.fg
          }

          Row {
            width: parent.width
            spacing: Style.spacing.lg

            Toggle {
              width: (parent.width - parent.spacing) / 2
              label: "Live wallpaper"
              checked: root.liveMode
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setMode(!root.liveMode)
            }

            Toggle {
              width: (parent.width - parent.spacing) / 2
              label: "Pause"
              checked: root.manualPause
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setPaused(!root.manualPause)
            }
          }

          Item {
            width: parent.width
            height: videoHeader.implicitHeight

            PanelSectionHeader {
              id: videoHeader
              text: "VIDEO"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: videoModel.count === 0
                ? ""
                : videoModel.count + (videoModel.count === 1 ? " file" : " files")
              color: Qt.darker(root.fg, 1.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          GridView {
            id: videoGrid
            width: parent.width
            height: {
              var rows = Math.min(2, Math.ceil(videoModel.count / root.columns))
              return Math.max(videoGrid.cellHeight, rows * videoGrid.cellHeight)
            }
            cellWidth: Math.floor(width / root.columns)
            cellHeight: Math.floor(cellWidth * 0.62) + Style.space(18)
            model: videoModel
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
              id: cell
              required property int index
              required property string path
              required property string thumb
              required property bool ready
              required property int ver

              readonly property bool current: cell.path === root.selectedVideo
              readonly property bool hot: cellMouse.containsMouse

              width: videoGrid.cellWidth
              height: videoGrid.cellHeight

              Rectangle {
                id: frame
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: Style.space(3)
                width: parent.width - Style.space(8)
                height: parent.height - label.height - Style.space(7)
                radius: Style.cornerRadius
                clip: true
                color: Style.normalFillFor(root.fg, root.accent)
                border.width: cell.current ? Math.max(1, Style.space(2)) : Style.spacing.hairline
                border.color: cell.current
                  ? Style.selectedStateColor(root.fg, root.accent)
                  : (cell.hot ? Style.hoverBorderFor(root.fg, root.accent) : Style.normalBorderFor(root.fg, root.accent))

                Image {
                  id: frameImage
                  anchors.fill: parent
                  source: cell.ready ? Util.fileUrl(cell.thumb) + "?v=" + cell.ver : ""
                  // Decoding stays off the UI thread, and the frame only paints
                  // once it is complete so a half-decoded frame never flashes.
                  asynchronous: true
                  cache: true
                  fillMode: Image.PreserveAspectCrop
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: !frameImage.visible
                  text: "\uf03d"
                  color: Qt.darker(root.fg, 1.8)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              Text {
                id: label
                anchors.top: frame.bottom
                anchors.topMargin: Style.space(2)
                anchors.horizontalCenter: parent.horizontalCenter
                width: frame.width
                text: Model.baseName(cell.path)
                color: cell.current
                  ? Style.selectedStateColor(root.fg, root.accent)
                  : (cell.hot ? root.fg : Qt.darker(root.fg, 1.5))
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
              }

              MouseArea {
                id: cellMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.chooseVideo(cell.path)
              }
            }
          }

          Text {
            width: parent.width
            visible: videoModel.count === 0
            text: "No videos in " + root.folder
              + "\nAdd mp4, mkv, webm, mov or gif files (up to 3 folders deep)."
            color: Qt.darker(root.fg, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.spacing.lg

            TextField {
              id: folderField
              width: parent.width - applyButton.width - parent.spacing
              placeholderText: "~/Videos"
              foreground: root.fg
              accent: root.accent
              font.family: root.fontFamily
              onAccepted: root.applyFolder()
            }

            Button {
              id: applyButton
              text: "Apply"
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.applyFolder()
            }
          }

          Item {
            width: parent.width
            height: autoHeader.implicitHeight + Style.space(4)

            PanelSectionHeader {
              id: autoHeader
              text: "PAUSE AUTOMATICALLY"
              foreground: root.fg
              fontFamily: root.fontFamily
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.lg

            Toggle {
              width: (parent.width - parent.spacing * 2) / 3
              label: "Window"
              checked: root.autoWindows
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setAuto("autoWindows", !root.autoWindows)
            }

            Toggle {
              width: (parent.width - parent.spacing * 2) / 3
              label: "Battery"
              checked: root.autoBattery
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setAuto("autoBattery", !root.autoBattery)
            }

            Toggle {
              width: (parent.width - parent.spacing * 2) / 3
              label: "Lock"
              checked: root.autoLock
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.setAuto("autoLock", !root.autoLock)
            }
          }

          Text {
            width: parent.width
            text: "Freezes on a covered workspace, on battery, and while locked."
            color: Qt.darker(root.fg, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.fg
          }

          Item {
            width: parent.width
            height: bindHeader.implicitHeight + Style.space(4)

            PanelSectionHeader {
              id: bindHeader
              text: "KEYBIND"
              foreground: root.fg
              fontFamily: root.fontFamily
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.lg

            TextField {
              id: bindField
              width: parent.width - copyButton.width - parent.spacing
              placeholderText: "SUPER + ALT + W"
              foreground: root.fg
              accent: root.accent
              font.family: root.fontFamily
              onAccepted: root.applyBind()
            }

            Button {
              id: copyButton
              text: "Copy"
              enabled: String(bindField.text || "").trim() !== ""
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.copyBind()
            }
          }

          Text {
            width: parent.width
            visible: root.bindLine !== ""
            text: root.bindLine
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          }

          Text {
            width: parent.width
            text: root.bindLine === ""
              ? "Type a key combination, then Copy: the o.bind() line for your Hyprland config appears here."
              : "Paste the line into ~/.config/hypr/bindings.lua. Livewall never edits your config."
            color: Qt.darker(root.fg, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
