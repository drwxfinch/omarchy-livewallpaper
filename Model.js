.pragma library

// Pure helpers shared by Service.qml and Panel.qml. No Qt objects here so the
// file can also be exercised from a plain JS runtime while testing.

function defaultSettings(home) {
  return {
    folder: home + "/Videos",
    video: "",
    mode: "live",
    paused: false,
    autoWindows: true,
    autoBattery: true,
    autoLock: true,
    bind: ""
  }
}

// `omarchy bar plugin set` stores strings unless it is given --json, so a
// hand-edited or CLI-written "true" must still read as a boolean.
function coerce(value) {
  if (value === "true") return true
  if (value === "false") return false
  return value
}

// A plugin's state lives inline on its entry in shell.json: inside a bar
// layout section for a bar widget, or in plugins[] for a non-widget plugin.
function findEntry(config, id) {
  if (!config || typeof config !== "object") return null
  var sections = ["left", "center", "right"]
  var bar = config.bar
  if (bar && bar.layout) {
    for (var s = 0; s < sections.length; s++) {
      var entries = bar.layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && String(entries[i].id || "") === id) return entries[i]
      }
    }
  }
  var plugins = config.plugins
  if (Array.isArray(plugins)) {
    for (var j = 0; j < plugins.length; j++) {
      if (plugins[j] && String(plugins[j].id || "") === id) return plugins[j]
    }
  }
  return null
}

function parseSettings(text, id, defaults) {
  var out = {}
  for (var key in defaults) out[key] = defaults[key]
  var config = null
  try {
    config = JSON.parse(String(text || ""))
  } catch (e) {
    return out
  }
  var entry = findEntry(config, id)
  if (!entry) return out
  for (var k in entry) {
    if (k === "id") continue
    out[k] = coerce(entry[k])
  }
  return out
}

function expandHome(path, home) {
  var p = String(path || "").trim()
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return home + p.slice(1)
  return p
}

function hasCoveringWindow(monitor, clients) {
  if (!monitor) return false
  var ws = monitor.activeWorkspace ? monitor.activeWorkspace.id : null
  var special = monitor.specialWorkspace
  var specialId = special && special.name ? special.id : 0
  var list = Array.isArray(clients) ? clients : []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c || c.mapped !== true || c.hidden === true) continue
    var cws = c.workspace ? c.workspace.id : null
    if (cws !== ws && !(specialId !== 0 && cws === specialId)) continue
    if (c.floating !== true) return true
    var fs = String(c.fullscreen === undefined || c.fullscreen === null ? 0 : c.fullscreen)
    if (fs !== "0" && fs !== "false") return true
  }
  return false
}

// One line per video from scan.sh:
//   mtime \t has-thumbnail \t path \t thumbnail
function parseScanOutput(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length < 4) continue
    var mtime = Number(parts[0])
    if (!isFinite(mtime) || !parts[2] || !parts[3]) continue
    out.push({
      mtime: mtime,
      ready: parts[1] === "1",
      path: parts[2],
      thumb: parts[3]
    })
  }
  return out
}

// Last path segment, for the label under a preview.
function baseName(path) {
  var parts = String(path || "").split("/")
  return parts.length > 0 ? parts[parts.length - 1] : ""
}

function mpvOptions(token) {
  return "no-audio loop=inf hwdec=auto-safe panscan=1.0 no-osc "
    + "no-input-default-bindings title=" + token
}
