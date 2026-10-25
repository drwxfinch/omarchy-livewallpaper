.pragma library

// Pure helpers shared by Service.qml and Panel.qml. No Qt objects here so the
// file can also be exercised from a plain JS runtime while testing.

function defaultSettings(home) {
  return {
    folder: home + "/Videos",
    video: "",
    mode: "live",
    paused: false,
    // true: every monitor shows the flat video/mode/paused values. false:
    // monitors[name] overrides them per output. Old configs without either key
    // behave as sync=true, which is exactly the pre-multi-monitor behaviour.
    syncMonitors: true,
    monitors: {},
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

function normalizeMonitorEntry(entry) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null
  var out = {}
  if (entry.video !== undefined && entry.video !== null) out.video = String(entry.video)
  if (entry.mode !== undefined && entry.mode !== null)
    out.mode = String(entry.mode) === "static" ? "static" : "live"
  if (entry.paused !== undefined && entry.paused !== null) out.paused = coerce(entry.paused) === true
  return out
}

function normalizeMonitors(value) {
  var out = {}
  if (!value || typeof value !== "object" || Array.isArray(value)) return out
  for (var name in value) {
    var entry = normalizeMonitorEntry(value[name])
    if (entry) out[String(name)] = entry
  }
  return out
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
    if (k === "id" || k === "monitors") continue
    out[k] = coerce(entry[k])
  }
  out.monitors = normalizeMonitors(entry.monitors)
  return out
}

// Anything except an explicit false means "all monitors share one wallpaper".
// That keeps configs written before syncMonitors existed working unchanged.
function syncEnabled(settings) {
  if (!settings) return true
  return settings.syncMonitors !== false && settings.syncMonitors !== "false"
}

// Effective settings for one output. Resolution order:
//   1. sync on            -> flat video/mode/paused
//   2. sync off           -> monitors[name], missing fields from the flat values
//   3. no monitors entry  -> flat values
function monitorSettings(settings, name) {
  var s = settings || {}
  var flatMode = String(s.mode || "live") === "static" ? "static" : "live"
  var flat = {
    video: String(s.video || ""),
    mode: flatMode,
    paused: coerce(s.paused) === true
  }
  if (syncEnabled(s)) return flat
  var monitors = s.monitors
  var entry = monitors && typeof monitors === "object" && !Array.isArray(monitors)
    ? monitors[String(name || "")] : null
  if (!entry || typeof entry !== "object") return flat
  return {
    video: entry.video === undefined || entry.video === null ? flat.video : String(entry.video),
    mode: entry.mode === undefined || entry.mode === null ? flat.mode
      : (String(entry.mode) === "static" ? "static" : "live"),
    paused: entry.paused === undefined || entry.paused === null
      ? flat.paused : coerce(entry.paused) === true
  }
}

// Immutable top-level update, so QML property bindings see a new object.
function withSetting(settings, key, value) {
  var out = {}
  for (var k in (settings || {})) out[k] = settings[k]
  out[String(key)] = value
  return out
}

// Immutable per-monitor update. With sync on (or no monitor name) the patch
// lands on the flat keys, which is what "apply to all monitors" means. The
// sync flag is kept in step so a per-monitor write can never be silently
// ignored by the resolver above.
function setMonitorSetting(settings, name, patch, sync) {
  var base = settings || {}
  var out = {}
  for (var k in base) out[k] = base[k]
  var target = String(name || "").trim()
  if (sync === true || target === "") {
    if (sync === true) out.syncMonitors = true
    for (var pk in patch) out[pk] = patch[pk]
    return out
  }
  out.syncMonitors = false
  var monitors = {}
  var src = base.monitors
  if (src && typeof src === "object" && !Array.isArray(src)) {
    for (var key in src) {
      var entry = src[key]
      if (!entry || typeof entry !== "object") continue
      var copy = {}
      for (var ek in entry) copy[ek] = entry[ek]
      monitors[key] = copy
    }
  }
  // Materialise the monitor's current effective values first, so a later
  // change to the flat defaults cannot silently move an already-touched output.
  var effective = monitorSettings(base, target)
  var current = monitors[target] || {}
  current = {
    video: current.video === undefined ? effective.video : String(current.video),
    mode: current.mode === undefined ? effective.mode
      : (String(current.mode) === "static" ? "static" : "live"),
    paused: current.paused === undefined ? effective.paused : coerce(current.paused) === true
  }
  for (var pk2 in patch) current[pk2] = patch[pk2]
  monitors[target] = current
  out.monitors = monitors
  return out
}

// Drop saved monitors that are no longer connected. Returns a new settings
// object; callers decide when the user asked for this.
function pruneMonitors(settings, names) {
  var base = settings || {}
  var out = {}
  for (var k in base) out[k] = base[k]
  var keep = []
  var list = Array.isArray(names) ? names : []
  for (var i = 0; i < list.length; i++) keep.push(String(list[i]))
  var monitors = {}
  var src = base.monitors
  if (src && typeof src === "object" && !Array.isArray(src)) {
    for (var key in src) {
      if (keep.indexOf(String(key)) === -1) continue
      monitors[String(key)] = src[key]
    }
  }
  out.monitors = monitors
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
