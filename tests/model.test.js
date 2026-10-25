// Development-only checks for the pure helpers in ../Model.js.
//
//   node tests/model.test.js
//
// Node is not a runtime dependency of the plugin: the shell only loads the QML
// files and Model.js. This script exists so settings resolution, migration and
// the per-monitor merge rules can be checked without a compositor.

const fs = require("fs")
const assert = require("assert")
const path = require("path")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(".pragma library", "")
const Model = new Function(source + "\nreturn {"
  + "defaultSettings, coerce, findEntry, parseSettings, expandHome,"
  + "hasCoveringWindow, parseScanOutput, baseName, mpvOptions,"
  + "syncEnabled, monitorSettings, setMonitorSetting, pruneMonitors,"
  + "withSetting, normalizeMonitors}")()
const home = "/home/morph"

// --- defaults / coercion
const defs = Model.defaultSettings(home)
assert.equal(defs.folder, "/home/morph/Videos")
assert.equal(defs.syncMonitors, true)
assert.deepEqual(defs.monitors, {})
assert.equal(Model.coerce("false"), false)
assert.equal(Model.coerce("true"), true)
assert.equal(Model.coerce(false), false)
assert.equal(Model.expandHome("~/Videos", home), "/home/morph/Videos")
assert.equal(Model.expandHome("~", home), "/home/morph")
assert.equal(Model.expandHome("/abs/path", home), "/abs/path")
assert.equal(Model.baseName("/a/b/c.mp4"), "c.mp4")

// --- entry lookup (bar layout + plugins[])
const config = {
  bar: { layout: { left: [], center: [], right: [{ id: "morph.livewall", mode: "static", paused: "true", autoWindows: false }] } },
  plugins: [{ id: "other" }]
}
assert.equal(Model.findEntry(config, "morph.livewall").mode, "static")
assert.equal(Model.findEntry(config, "nope"), null)
const parsed = Model.parseSettings(JSON.stringify(config), "morph.livewall", Model.defaultSettings(home))
assert.equal(parsed.mode, "static")
assert.equal(parsed.paused, true)
assert.equal(parsed.autoBattery, true)
assert.equal(parsed.autoWindows, false)
assert.equal(parsed.syncMonitors, true)

// --- old flat config: every monitor shares the flat values
const oldCfg = { bar: { layout: { right: [{ id: "morph.livewall", video: "/v/a.mp4", mode: "live", paused: false }] } } }
const old = Model.parseSettings(JSON.stringify(oldCfg), "morph.livewall", Model.defaultSettings(home))
assert.equal(old.syncMonitors, true)
assert.deepEqual(Model.monitorSettings(old, "eDP-1"), { video: "/v/a.mp4", mode: "live", paused: false })
assert.deepEqual(Model.monitorSettings(old, "DP-1"), { video: "/v/a.mp4", mode: "live", paused: false })
assert.equal(Model.syncEnabled(old), true)

// --- new per-monitor config
const perCfg = {
  bar: { layout: { right: [{
    id: "morph.livewall", video: "/v/default.mp4", mode: "live", paused: false,
    syncMonitors: "false",
    monitors: {
      "DP-1": { video: "/v/dp.mp4", mode: "static", paused: "true" },
      "HDMI-A-1": { video: "/v/hdmi.mp4" },
      "bad": "nope"
    }
  }] } }
}
const per = Model.parseSettings(JSON.stringify(perCfg), "morph.livewall", Model.defaultSettings(home))
assert.equal(per.syncMonitors, false)
assert.deepEqual(Model.monitorSettings(per, "DP-1"), { video: "/v/dp.mp4", mode: "static", paused: true })
// missing mode/paused fall back to the flat values
assert.deepEqual(Model.monitorSettings(per, "HDMI-A-1"), { video: "/v/hdmi.mp4", mode: "live", paused: false })
// unknown monitor falls back to flat
assert.deepEqual(Model.monitorSettings(per, "eDP-1"), { video: "/v/default.mp4", mode: "live", paused: false })
// malformed entries are dropped by the normalizer
assert.equal(per.monitors.bad, undefined)

// --- setMonitorSetting: sync on -> flat
let s = Model.defaultSettings(home)
let n = Model.setMonitorSetting(s, "DP-1", { video: "/v/x.mp4" }, true)
assert.equal(n.video, "/v/x.mp4")
assert.equal(n.monitors["DP-1"], undefined)
assert.equal(n.syncMonitors, true)
// original untouched
assert.equal(s.video, "")

// --- setMonitorSetting: sync off -> only that monitor
n = Model.setMonitorSetting(s, "DP-1", { video: "/v/x.mp4" }, false)
assert.equal(n.monitors["DP-1"].video, "/v/x.mp4")
assert.equal(n.video, "")
assert.equal(n.syncMonitors, false)
// second monitor keeps its own entry
n = Model.setMonitorSetting(n, "HDMI-A-1", { mode: "static" }, false)
assert.equal(n.monitors["DP-1"].video, "/v/x.mp4")
assert.equal(n.monitors["HDMI-A-1"].mode, "static")
// touched monitors keep their materialised values; untouched ones inherit flat
let moved = Model.withSetting(n, "video", "/v/other.mp4")
assert.equal(Model.monitorSettings(moved, "DP-1").video, "/v/x.mp4")
assert.equal(Model.monitorSettings(moved, "HDMI-A-1").video, "")
assert.equal(Model.monitorSettings(moved, "DP-2").video, "/v/other.mp4")
// empty monitor name means all
n = Model.setMonitorSetting(s, "", { paused: true }, false)
assert.equal(n.paused, true)
assert.equal(n.monitors[""], undefined)

// --- pruneMonitors
const withTwo = Model.setMonitorSetting(Model.setMonitorSetting(s, "DP-1", { video: "/v/a" }, false), "HDMI-A-1", { video: "/v/b" }, false)
const pruned = Model.pruneMonitors(withTwo, ["DP-1"])
assert.equal(pruned.monitors["DP-1"].video, "/v/a")
assert.equal(pruned.monitors["HDMI-A-1"], undefined)
assert.equal(withTwo.monitors["HDMI-A-1"].video, "/v/b")
assert.deepEqual(Model.pruneMonitors(withTwo, []).monitors, {})

// --- withSetting is immutable
const ws = Model.withSetting(s, "autoBattery", false)
assert.equal(ws.autoBattery, false)
assert.equal(s.autoBattery, true)

// --- window coverage
const monitor = { activeWorkspace: { id: 3 }, specialWorkspace: { id: 0, name: "" } }
assert.equal(Model.hasCoveringWindow(monitor, []), false)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: true, hidden: false, floating: false, fullscreen: 0, workspace: { id: 3 } }]), true)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: true, hidden: false, floating: true, fullscreen: 0, workspace: { id: 3 } }]), false)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: true, hidden: false, floating: true, fullscreen: 1, workspace: { id: 3 } }]), true)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: true, hidden: false, floating: false, fullscreen: 0, workspace: { id: 5 } }]), false)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: false, hidden: false, floating: false, fullscreen: 0, workspace: { id: 3 } }]), false)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: true, hidden: true, floating: false, fullscreen: 0, workspace: { id: 3 } }]), false)
const withSpecial = { activeWorkspace: { id: 3 }, specialWorkspace: { id: 99, name: "special:scratch" } }
assert.equal(Model.hasCoveringWindow(withSpecial, [{ mapped: true, hidden: false, floating: false, fullscreen: 0, workspace: { id: 99 } }]), true)
assert.equal(Model.hasCoveringWindow(monitor, [{ mapped: true, hidden: false, floating: false, fullscreen: 0, workspace: { id: 0 } }]), false)

// --- scan output
const scan = "1720000000.123\t1\t/home/u/Videos/a.mp4\t/home/u/.cache/morph.livewall/thumbs/aa.jpg\n"
  + "1719000000.5\t0\t/home/u/Videos/sub/b.mkv\t/home/u/.cache/morph.livewall/thumbs/bb.jpg\n"
  + "garbage\n\n"
const items = Model.parseScanOutput(scan)
assert.equal(items.length, 2)
assert.equal(items[0].ready, true)
assert.equal(items[1].ready, false)
assert.equal(items[1].path, "/home/u/Videos/sub/b.mkv")

assert.ok(Model.mpvOptions("tok").includes("title=tok"))
assert.ok(Model.mpvOptions("tok").includes("loop=inf"))
console.log("Model.js: all assertions passed")
