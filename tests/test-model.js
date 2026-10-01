// Unit tests for Model.js (parsing, labels, palettes, contrast, hotkey capture).
// Run: node tests/test-model.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const M = require(path.join(__dirname, "..", "Model.js"))
const raw = "cpu\t1000 800\nmem\t8000000 3000000\ncputemp\t46000\ngpu\t3, 512, 2048, 44\n"
const a = M.parse(raw)
assert.deepStrictEqual(a.cpu, { total: 1000, idle: 800 })
assert.strictEqual(a.cpuTempC, 46)
assert.deepStrictEqual(a.gpu, { off: false, util: 3, usedMiB: 512, totalMiB: 2048, tempC: 44 })
const b = M.parse("cpu\t1200 900\n")
assert.strictEqual(M.cpuPercent(a.cpu, b.cpu), 50)
assert.strictEqual(M.cpuPercent(null, b.cpu), null)
assert.strictEqual(M.cpuPercent(b.cpu, a.cpu), null)
assert.strictEqual(M.label(a, 12, true, false), "CPU 12% 46°C RAM 4.8 GPU 3% 44°C VRAM 0.5")
assert.strictEqual(M.label(a, 12, false, false), "CPU 12% RAM 4.8 GPU 3% VRAM 0.5")
assert.strictEqual(M.label(a, null, true, false), "46°C RAM 4.8 GPU 3% 44°C VRAM 0.5")
const noGpu = M.parse("cpu\t1 1\nmem\t100 50\n")
assert.strictEqual(noGpu.gpu, null)
assert.strictEqual(M.label(noGpu, 5, true, false), "CPU 5% RAM 0.0")
assert.strictEqual(M.parse("garbage\nfoo\tbar\n"), null)
assert.strictEqual(M.parse("gpu\t[N/A], [N/A], [N/A], [N/A]\n"), null)
// utilisation [N/A] but VRAM known: shown without a percentage
const naUtil = M.parse("gpu\t[N/A], 512, 2048, [N/A]\n")
assert.deepStrictEqual(naUtil.gpu, { off: false, util: null, usedMiB: 512, totalMiB: 2048, tempC: null })
assert.strictEqual(M.label(naUtil, null, true, false), "GPU VRAM 0.5")
// a runtime-suspended discrete GPU
const off = M.parse("mem\t100 50\ngpu\toff\n")
assert.deepStrictEqual(off.gpu, { off: true })
assert.strictEqual(M.label(off, 5, true, false), "CPU 5% RAM 0.0 GPU off")
assert.strictEqual(M.parse("mem\t0 0\n"), null)
const segs = M.segments(a, 12, true)
assert.deepStrictEqual(segs.map(x => x.id), ["cpu", "ram", "gpu", "vram"])
assert.ok(segs.every(x => x.hot === false))
const hotCpu = M.segments(M.parse("cpu\t1 1\ncputemp\t90000\ngpu\t1, 1, 2048, 50\n"), 5, true)
assert.deepStrictEqual(hotCpu.map(x => [x.id, x.hot]), [["cpu", true], ["gpu", false], ["vram", false]])
const hotGpu = M.segments(M.parse("gpu\t1, 1, 2048, 85\n"), null, true)
assert.deepStrictEqual(hotGpu.map(x => [x.id, x.hot]), [["gpu", true], ["vram", false]])
assert.strictEqual(M.segments(M.parse("cputemp\t84400\n"), null, true)[0].hot, false)
assert.strictEqual(M.colorOr("#7DD3FC", "#fff000"), "#7DD3FC")
assert.strictEqual(M.colorOr("red\"><b>", "#fff000"), "#fff000")
assert.strictEqual(M.colorOr(undefined, "#fff000"), "#fff000")
const colors = { cpu: "#111111", ram: "#222222", gpu: "#333333", vram: "#444444" }
assert.strictEqual(M.richLabel(segs, colors, "#ff0000", false),
  '<font color="#111111">CPU 12% 46\u00b0C</font> <font color="#222222">RAM 4.8</font> <font color="#333333">GPU 3% 44\u00b0C</font> <font color="#444444">VRAM 0.5</font>')
assert.strictEqual(M.richLabel(hotCpu, colors, "#ff0000", true),
  '<font color="#ff0000">CPU 5% 90\u00b0C!</font><br><font color="#333333">GPU 1% 50\u00b0C</font><br><font color="#444444">VRAM 0.0</font>')
// hot is also marked without colour ("!"), and only on the temperature
assert.strictEqual(M.label(M.parse("cpu\t1 1\ncputemp\t90000\n"), 5, true, false), "CPU 5% 90\u00b0C!")
assert.strictEqual(M.label(M.parse("cpu\t1 1\ncputemp\t90000\n"), 5, false, false), "CPU 5%")
// richLabel never trusts its inputs: bad colours fall back, text is escaped
const evil = [{ id: "cpu", text: "<b>x</b> & y", hot: false }, { id: "ram", text: "RAM 1", hot: true }]
assert.strictEqual(M.richLabel(evil, { cpu: '#123456"><img src=x>' }, "red", false),
  '<font color="' + M.DEFAULT_COLORS.cpu + '">&lt;b&gt;x&lt;/b&gt; &amp; y</font> <font color="#ff5555">RAM 1</font>')
assert.strictEqual(M.richLabel(evil.slice(1), null, "#80ff0000", false), '<font color="#80ff0000">RAM 1</font>')
// ---- palettes ----
const toml = 'mode = "dark"\nblue = "#111111"\nyellow = "#222222"\ngreen = "#333333"\nmagenta = "#444444"\nbackground = "#000000"\n'
assert.deepStrictEqual(M.themeColors(M.parseThemeToml(toml)), { cpu: "#111111", ram: "#222222", gpu: "#333333", vram: "#444444" })
assert.strictEqual(M.themeColors(M.parseThemeToml('blue = "#111111"\n')), null)
assert.strictEqual(M.themeColors(M.parseThemeToml('blue = "red"\nyellow = "#222222"\ngreen = "#333333"\nmagenta = "#444444"\n')), null)
assert.strictEqual(M.titleCase("osaka-jade"), "Osaka Jade")
assert.strictEqual(M.titleCase("retro-82"), "Retro 82")
const body = (b, y, g, m) => 'blue = "' + b + '"\nyellow = "' + y + '"\ngreen = "' + g + '"\nmagenta = "' + m + '"\n'
const rawThemes =
  "@@theme\tstock\tgrey-theme\n" + body("#888888", "#8a8a8a", "#868686", "#8c8c8c") +
  "@@theme\tstock\tcolorful\n" + body("#4488ff", "#ffcc00", "#33cc55", "#ff44aa") +
  "@@theme\tstock\tbroken\nblue = \"#4488ff\"\n" +
  "@@theme\tstock\toverlaid\n" + body("#4488ff", "#ffcc00", "#33cc55", "#ff44aa") +
  "@@theme\tuser\toverlaid\nmagenta = \"#ff0000\"\n" +
  "@@theme\tuser\tmine-only\n" + body("#777777", "#7a7a7a", "#767676", "#7c7c7c") +
  "@@theme\tuser\tmalformed\n"
const themes = M.parseThemes(rawThemes)
assert.deepStrictEqual(themes.map(x => x.id).sort(), ["colorful", "grey-theme", "mine-only", "overlaid"])
assert.strictEqual(themes.find(x => x.id === "overlaid").custom, true)
assert.strictEqual(themes.find(x => x.id === "overlaid").colors.vram, "#ff0000")
assert.strictEqual(themes.find(x => x.id === "overlaid").colors.cpu, "#4488ff")
assert.strictEqual(themes.find(x => x.id === "colorful").custom, false)
const order = M.sortThemes(themes).map(x => x.id)
assert.deepStrictEqual(order, ["overlaid", "mine-only", "colorful", "grey-theme"])
const rows = M.themeEntries(themes)
assert.strictEqual(rows.find(r => r.value === "theme:mine-only").note, "custom")
assert.strictEqual(rows.find(r => r.value === "theme:grey-theme").note, "similar colours")
assert.strictEqual(rows.find(r => r.value === "theme:colorful").note, "")
assert.ok(M.distinctness(themes.find(x => x.id === "colorful").colors) > M.SIMILAR_BELOW)
assert.ok(M.distinctness(themes.find(x => x.id === "grey-theme").colors) < M.SIMILAR_BELOW)
const sysC = { cpu: "#010101", ram: "#020202", gpu: "#030303", vram: "#040404" }
assert.deepStrictEqual(M.paletteColors("system", sysC, themes), sysC)
assert.deepStrictEqual(M.paletteColors("system", null, themes), M.DEFAULT_COLORS)
assert.deepStrictEqual(M.paletteColors("", sysC, themes), sysC)
assert.strictEqual(M.paletteColors("fixed:dracula", sysC, themes).gpu, "#50fa7b")
assert.strictEqual(M.paletteColors("theme:colorful", sysC, themes).cpu, "#4488ff")
assert.deepStrictEqual(M.paletteColors("theme:deleted", sysC, themes), sysC)
assert.deepStrictEqual(M.paletteColors("fixed:nope", sysC, themes), sysC)
assert.deepStrictEqual(M.paletteColors("garbage", sysC, themes), sysC)
assert.strictEqual(M.selectionKnown("theme:colorful", themes), true)
assert.strictEqual(M.selectionKnown("theme:deleted", themes), false)
assert.strictEqual(M.selectionKnown("theme:anything", []), true)
assert.strictEqual(M.selectionKnown("fixed:dracula", themes), true)
assert.strictEqual(M.selectionKnown("fixed:snazzy", themes), false) // removed palette: falls back to System
assert.strictEqual(M.selectionKnown("garbage", themes), false)
const entries = M.paletteEntries(sysC)
assert.strictEqual(entries[0].value, "system")
assert.strictEqual(entries.length, 1 + M.FIXED_PALETTES.length)
for (const p of M.FIXED_PALETTES) {
  for (const k of M.STATS) assert.ok(/^#[0-9a-f]{6}$/.test(p.colors[k]), p.id + " " + k)
  assert.ok(M.distinctness(p.colors) >= M.SIMILAR_BELOW, p.id + " is too similar")
}
assert.strictEqual(new Set(M.FIXED_PALETTES.map(p => p.id)).size, M.FIXED_PALETTES.length)
// the real theme scan runs and parses every stock theme (only on Omarchy)
if (fs.existsSync("/usr/share/omarchy/themes")) {
  const real = M.parseThemes(require("child_process").execFileSync("/bin/bash", ["-c", M.themesScript]).toString())
  assert.ok(real.length >= 20)
  assert.ok(real.every(t => M.STATS.every(k => /^#[0-9a-fA-F]{6}$/.test(t.colors[k]))))
} else {
  console.log("skip: /usr/share/omarchy/themes not found")
}
// ---- contrast ----
assert.strictEqual(M.themeBackground(M.parseThemeToml('background = "#faf4ed"\n')), "#faf4ed")
assert.strictEqual(M.themeBackground(M.parseThemeToml('background = "white"\n')), null)
assert.ok(Math.abs(M.contrastRatio("#000000", "#ffffff") - 21) < 1e-9)
assert.ok(Math.abs(M.contrastRatio("#777777", "#777777") - 1) < 1e-9)
const dracula = M.FIXED_PALETTES.find(p => p.id === "dracula").colors
assert.strictEqual(M.lowContrast(dracula, "#ffffff"), true)   // yellow on white is ~1.1:1
assert.strictEqual(M.lowContrast(dracula, "#1a1b26"), false)
assert.strictEqual(M.lowContrast(dracula, null), false)        // unknown background: no claim
const light = M.paletteEntries(null, "#ffffff")
assert.strictEqual(light.find(r => r.value === "fixed:dracula").note, "low contrast")
assert.ok(M.paletteEntries(null, "#1a1b26").every(r => r.note === ""))
const lightRows = M.themeEntries(themes, "#ffffff")
assert.strictEqual(lightRows.find(r => r.value === "theme:colorful").note, "low contrast")
assert.strictEqual(lightRows.find(r => r.value === "theme:mine-only").note, "custom")
// fixed palettes must not drift into near-duplicates of one another
for (let i = 0; i < M.FIXED_PALETTES.length; i++) for (let j = i + 1; j < M.FIXED_PALETTES.length; j++) {
  const a = M.FIXED_PALETTES[i], b = M.FIXED_PALETTES[j]
  const d = M.STATS.reduce((s, k) => s + M.deltaE(a.colors[k], b.colors[k]), 0) / M.STATS.length
  assert.ok(d >= 18, a.id + " ~ " + b.id + " too alike: " + d.toFixed(1))
}
// ---- hotkey capture ----
assert.strictEqual(M.chordFromKey(0x4d, true, false, false, false), "CTRL + M")
assert.strictEqual(M.chordFromKey(0x4d, true, false, true, true), "SUPER + CTRL + SHIFT + M")
assert.strictEqual(M.chordFromKey(0x01000000, true, false, true, false), "CTRL + SHIFT + ESCAPE")
assert.strictEqual(M.chordFromKey(0x01000030, false, true, false, false), "ALT + F1")
assert.strictEqual(M.chordFromKey(0x21, false, false, true, true), "SUPER + SHIFT + 1")
assert.strictEqual(M.chordFromKey(0x4d, false, false, false, false), null)
assert.strictEqual(M.chordFromKey(0x01000021, true, false, false, false), null)
assert.strictEqual(M.chordFromKey(0x01000022, false, false, false, true), null)
assert.strictEqual(M.chordFromKey(0x1234, true, false, false, false), null)
assert.ok(M.validChord("SUPER + SHIFT + M"))
assert.ok(M.validChord("CTRL + ALT + F5"))
assert.ok(!M.validChord("M"))
assert.ok(!M.validChord("CTRL + M\"); os.execute(\"x"))
assert.ok(!M.validChord("CTRL + m"))
assert.ok(!M.validChord("HYPER + M"))
assert.ok(!M.validChord("SUPER + SUPER + M"))
assert.ok(M.validChord("CTRL + SUPER + M"))
console.log("ok")
