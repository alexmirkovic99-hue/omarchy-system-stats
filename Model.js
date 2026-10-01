// System stats data helpers.
// The stats command prints a small, finite, tab-separated schema. It only
// reads /proc and /sys and calls nvidia-smi (if present) by absolute path; it
// never writes anything and never touches the network.
//
// Run as: bash -c statsScript <name> [root] [nvidia-smi path]
// The widget passes neither optional argument. The tests pass a fake root
// directory and a fake nvidia-smi so every hardware variant can be checked.
//
// CPU temperature: Intel `coretemp`, AMD `k10temp` (Tdie when the kernel
// labels it, else Tctl) or `zenpower`, ARM `cpu_thermal`, in that order.
// GPU: NVIDIA through nvidia-smi, else the first AMD GPU (amdgpu sysfs).
// A discrete GPU that is runtime-suspended is reported as "off" and is NOT
// queried, because querying it would wake it up and drain the battery.

var statsScript = [
  "set -u",
  "R=${1:-}; NVIDIA_SMI=${2:-/usr/bin/nvidia-smi}",
  "AWK=/usr/bin/awk; HEAD=/usr/bin/head",
  "\"$AWK\" '/^cpu / { t = 0; for (i = 2; i <= NF; i++) t += $i; printf \"cpu\\t%d %d\\n\", t, $5 + $6; exit }' \"$R/proc/stat\"",
  "\"$AWK\" '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf \"mem\\t%d %d\\n\", t, a }' \"$R/proc/meminfo\"",
  "best=''; rank=9",
  "for h in \"$R\"/sys/class/hwmon/hwmon*; do",
  "  read -r n 2>/dev/null < \"$h/name\" || continue",
  "  case $n in coretemp) r=0 ;; k10temp) r=1 ;; zenpower) r=2 ;; cpu_thermal) r=3 ;; *) continue ;; esac",
  "  [ \"$r\" -lt \"$rank\" ] || continue",
  "  f=\"$h/temp1_input\"",
  "  if [ \"$n\" = k10temp ]; then",
  "    for l in \"$h\"/temp*_label; do",
  "      read -r lab 2>/dev/null < \"$l\" || continue",
  "      if [ \"$lab\" = Tdie ]; then f=${l%_label}_input; break; fi",
  "    done",
  "  fi",
  "  if read -r t 2>/dev/null < \"$f\"; then best=$t; rank=$r; fi",
  "done",
  "if [ -n \"$best\" ]; then printf 'cputemp\\t%s\\n' \"$best\"; fi",
  "done_gpu=0",
  "if [ -x \"$NVIDIA_SMI\" ]; then",
  "  any=0; awake=0",
  "  for s in \"$R\"/sys/bus/pci/drivers/nvidia/*/power/runtime_status; do",
  "    read -r st 2>/dev/null < \"$s\" || continue",
  "    any=1; [ \"$st\" = suspended ] || awake=1",
  "  done",
  "  if [ \"$any\" = 1 ] && [ \"$awake\" = 0 ]; then",
  "    printf 'gpu\\toff\\n'; done_gpu=1",
  "  else",
  "    g=$(\"$NVIDIA_SMI\" --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | \"$HEAD\" -n 1)",
  "    if [ -n \"$g\" ]; then printf 'gpu\\t%s\\n' \"$g\"; done_gpu=1; fi",
  "  fi",
  "fi",
  "if [ \"$done_gpu\" = 0 ]; then",
  "  for d in \"$R\"/sys/class/drm/card*/device; do",
  "    [ -r \"$d/gpu_busy_percent\" ] || continue",
  "    read -r st 2>/dev/null < \"$d/power/runtime_status\" || st=active",
  "    if [ \"$st\" = suspended ]; then printf 'gpu\\toff\\n'; break; fi",
  "    read -r u 2>/dev/null < \"$d/gpu_busy_percent\" || continue",
  "    read -r vu 2>/dev/null < \"$d/mem_info_vram_used\" || continue",
  "    read -r vt 2>/dev/null < \"$d/mem_info_vram_total\" || continue",
  "    case \"$u:$vu:$vt\" in *[!0-9:]* | :* | *::* | *:) continue ;; esac",
  "    tc=''",
  "    for hw in \"$d\"/hwmon/hwmon*; do",
  "      if read -r t 2>/dev/null < \"$hw/temp1_input\"; then case $t in '' | *[!0-9]*) ;; *) tc=$((t / 1000)) ;; esac; break; fi",
  "    done",
  "    printf 'gpu\\t%s, %s, %s, %s\\n' \"$u\" \"$((vu / 1048576))\" \"$((vt / 1048576))\" \"$tc\"",
  "    break",
  "  done",
  "fi"
].join("\n")

function uint(value) {
  var s = String(value).trim()
  return /^\d{1,15}$/.test(s) ? Number(s) : null
}

// Returns {cpu:{total,idle}|null, memTotalKb, memAvailKb, cpuTempC|null,
// gpu:{util,usedMiB,totalMiB,tempC|null}|null}, or null when nothing parsed.
function parse(raw) {
  var out = { cpu: null, memTotalKb: null, memAvailKb: null, cpuTempC: null, gpu: null }
  var any = false
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    var key = lines[i].substring(0, idx)
    var val = lines[i].substring(idx + 1).trim()
    var parts
    if (key === "cpu") {
      parts = val.split(" ")
      var t = uint(parts[0]), id = uint(parts[1])
      if (parts.length === 2 && t !== null && id !== null) { out.cpu = { total: t, idle: id }; any = true }
    } else if (key === "mem") {
      parts = val.split(" ")
      var mt = uint(parts[0]), ma = uint(parts[1])
      if (parts.length === 2 && mt !== null && mt > 0 && ma !== null) { out.memTotalKb = mt; out.memAvailKb = Math.min(ma, mt); any = true }
    } else if (key === "cputemp") {
      var milli = uint(val)
      if (milli !== null) { out.cpuTempC = Math.round(milli / 1000); any = true }
    } else if (key === "gpu") {
      if (val === "off") { out.gpu = { off: true }; any = true; continue }
      parts = val.split(",")
      // Some GPUs report utilisation as [N/A]; VRAM is still worth showing.
      var u = uint(parts[0]), used = uint(parts[1]), total = uint(parts[2])
      var temp = parts.length > 3 ? uint(parts[3]) : null
      if (parts.length >= 3 && used !== null && total !== null && total > 0) {
        out.gpu = { off: false, util: u === null ? null : Math.min(u, 100), usedMiB: used, totalMiB: total, tempC: temp }
        any = true
      }
    }
  }
  return any ? out : null
}

// Total CPU busy percent between two samples; null until there are two.
function cpuPercent(prev, cur) {
  if (!prev || !cur) return null
  var dt = cur.total - prev.total
  var di = cur.idle - prev.idle
  if (dt <= 0 || di < 0) return null
  return Math.max(0, Math.min(100, Math.round((dt - di) * 100 / dt)))
}

function temp(c) { return c === null || c === undefined ? "" : c + "°C" }

var HOT_C = 85

// Binary units (like omarchy-system-stats), labelled GB.
function gib(kb) { return (kb / 1024 / 1024).toFixed(1) }
function gibMiB(mib) { return (mib / 1024).toFixed(1) }

// Ordered segments [{id, text, hot}], e.g.
//   CPU 12% 48°C | RAM 4.6 | GPU 3% 44°C | VRAM 0.2
// RAM/VRAM are GB in use. `hot` marks a chip at or above HOT_C, which turns
// that chip's own segment urgent-coloured AND appends "!" so the warning does
// not rely on colour alone. Unavailable metrics are left out; a sleeping
// discrete GPU shows as "GPU off".
function segments(s, cpu, showTemps) {
  var out = []
  if (!s) return out
  var c = []
  var cpuHot = s.cpuTempC !== null && s.cpuTempC >= HOT_C
  if (cpu !== null) c.push("CPU " + cpu + "%")
  if (showTemps && s.cpuTempC !== null) c.push(temp(s.cpuTempC) + (cpuHot ? "!" : ""))
  if (c.length) out.push({ id: "cpu", text: c.join(" "), hot: cpuHot })
  if (s.memTotalKb) out.push({ id: "ram", text: "RAM " + gib(s.memTotalKb - s.memAvailKb), hot: false })
  if (s.gpu && s.gpu.off) {
    out.push({ id: "gpu", text: "GPU off", hot: false })
  } else if (s.gpu) {
    var gpuHot = s.gpu.tempC !== null && s.gpu.tempC >= HOT_C
    var g = [s.gpu.util === null ? "GPU" : "GPU " + s.gpu.util + "%"]
    if (showTemps && s.gpu.tempC !== null) g.push(temp(s.gpu.tempC) + (gpuHot ? "!" : ""))
    out.push({ id: "gpu", text: g.join(" "), hot: gpuHot })
    out.push({ id: "vram", text: "VRAM " + gibMiB(s.gpu.usedMiB), hot: false })
  }
  return out
}

// Plain-text label (used for sizing/visibility); vertical bars stack segments.
function label(s, cpu, showTemps, vertical) {
  return segments(s, cpu, showTemps).map(function(x) { return x.text }).join(vertical ? "\n" : " ")
}

// Accept only #rrggbb so a setting can never inject markup into the label.
function colorOr(value, fallback) {
  return /^#[0-9a-fA-F]{6}$/.test(String(value)) ? String(value) : fallback
}

function escapeHtml(text) {
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

// Rich-text label: every segment (letters and numbers) in its own colour,
// or the urgent colour while its chip is hot. `colors` maps id -> #rrggbb.
// Colours are re-validated and text is escaped here, so nothing read from a
// theme file or from shell.json can ever inject markup into the label.
// `urgent` may be #rrggbb or #aarrggbb (a QML color); anything else falls back.
function richLabel(segs, colors, urgent, vertical) {
  var hot = /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(String(urgent)) ? String(urgent) : "#ff5555"
  return segs.map(function(x) {
    var c = x.hot ? hot : colorOr(colors ? colors[x.id] : null, DEFAULT_COLORS[x.id] || "#cccccc")
    return "<font color=\"" + c + "\">" + escapeHtml(x.text) + "</font>"
  }).join(vertical ? "<br>" : " ")
}


// ---------------------------------------------------------------------------
// Palettes
// ---------------------------------------------------------------------------

// Stat order everywhere a palette is displayed.
var STATS = ["cpu", "ram", "gpu", "vram"]

// Used only if the active theme's colours cannot be read.
var DEFAULT_COLORS = { cpu: "#7DD3FC", ram: "#4A6CF7", gpu: "#4ADE80", vram: "#C084FC" }

// Fixed palettes, independent of the Omarchy theme. Chosen to look different
// from each other, not just to be popular: the terminal schemes below are
// distinct families (neon-pastel, classic, retro, warm/lime, clean GitHub),
// plus colour-blind-safe and data-visualisation palettes that use different hue
// roles. Sources:
//   Dracula, One Dark, Solarized Dark, Monokai, GitHub Dark - ANSI colours as
//     published in github.com/mbadolato/iTerm2-Color-Schemes
//   Synthwave '84 - the theme's own terminal colours (github.com/robb0wen/
//     synthwave-vscode); GPU uses its salmon accent, as its mint sits too close
//     to the cyan
//   Okabe-Ito - Wong 2011, "Points of view: Color blindness", Nature Methods
//   Tol Vibrant - Paul Tol's colour schemes (personal.sron.nl/~pault)
//   Tableau 10 - Tableau's default categorical palette
// CPU = blue/cyan, RAM = yellow/orange, GPU = green (salmon in Synthwave),
// VRAM = magenta/purple. Palettes that are already Omarchy themes (Catppuccin,
// Gruvbox, Nord, Tokyo Night, ...) are deliberately absent: they appear in the
// Omarchy themes list. test-model.js keeps the palettes from drifting into
// near-duplicates of each other.
var FIXED_PALETTES = [
  { id: "dracula",     name: "Dracula",        colors: { cpu: "#8be9fd", ram: "#f1fa8c", gpu: "#50fa7b", vram: "#ff79c6" } },
  { id: "one-dark",    name: "One Dark",       colors: { cpu: "#61afef", ram: "#e5c07b", gpu: "#98c379", vram: "#c678dd" } },
  { id: "solarized",   name: "Solarized Dark", colors: { cpu: "#268bd2", ram: "#b58900", gpu: "#859900", vram: "#d33682" } },
  { id: "monokai",     name: "Monokai",        colors: { cpu: "#66d9ef", ram: "#e6db74", gpu: "#a6e22e", vram: "#ae81ff" } },
  { id: "github-dark", name: "GitHub Dark",    colors: { cpu: "#58a6ff", ram: "#d29922", gpu: "#3fb950", vram: "#bc8cff" } },
  { id: "synthwave",   name: "Synthwave '84",  colors: { cpu: "#03edf9", ram: "#fede5d", gpu: "#f97e72", vram: "#ff7edb" } },
  { id: "okabe-ito",   name: "Okabe-Ito (colour-blind safe)", colors: { cpu: "#56b4e9", ram: "#e69f00", gpu: "#009e73", vram: "#cc79a7" } },
  { id: "tol-vibrant", name: "Tol Vibrant",    colors: { cpu: "#33bbee", ram: "#ee7733", gpu: "#009988", vram: "#ee3377" } },
  { id: "tableau",     name: "Tableau 10",     colors: { cpu: "#76b7b2", ram: "#f28e2b", gpu: "#59a14f", vram: "#b07aa1" } }
]

// Lists every Omarchy theme's colour file: stock themes, then the user's own
// (custom themes, or overlays on a stock theme). Read-only.
var themesScript = [
  "set -u",
  "CAT=/usr/bin/cat",
  "emit() { [ -f \"$3/colors.toml\" ] || return 0; printf '@@theme\\t%s\\t%s\\n' \"$1\" \"$2\"; \"$CAT\" \"$3/colors.toml\"; printf '\\n'; }",
  "for d in /usr/share/omarchy/themes/*/; do [ -d \"$d\" ] || continue; n=${d%/}; n=${n##*/}; emit stock \"$n\" \"${d%/}\"; done",
  "for d in \"$HOME\"/.config/omarchy/themes/*/; do [ -d \"$d\" ] || continue; n=${d%/}; n=${n##*/}; emit user \"$n\" \"${d%/}\"; done"
].join("\n")

// key = "value" pairs of a colors.toml (flat file; values are quoted).
function parseThemeToml(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']([^"']*)["']/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

var HEX = /^#[0-9a-fA-F]{6}$/

// The four stat colours of a parsed colors.toml (blue, yellow, green, magenta),
// or null when any is missing or malformed.
function themeColors(map) {
  if (!map) return null
  var c = { cpu: map.blue, ram: map.yellow, gpu: map.green, vram: map.magenta }
  for (var i = 0; i < STATS.length; i++) if (!HEX.test(String(c[STATS[i]]))) return null
  return c
}

function titleCase(name) {
  return String(name).split(/[-_ ]+/).map(function(w) { return w ? w.charAt(0).toUpperCase() + w.slice(1) : w }).join(" ")
}

// CIELAB distance between two #rrggbb colours (perceptual difference), with
// lightness counted at half weight: two stats are told apart mostly by hue,
// so a light red and a dark red should not count as "different".
function lab(hex) {
  function lin(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
  var r = lin(parseInt(hex.substr(1, 2), 16) / 255)
  var g = lin(parseInt(hex.substr(3, 2), 16) / 255)
  var b = lin(parseInt(hex.substr(5, 2), 16) / 255)
  var x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
  var y = 0.2126 * r + 0.7152 * g + 0.0722 * b
  var z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
  function f(t) { return t > 0.008856 ? Math.pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
  return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
}

function deltaE(a, b) {
  var p = lab(a), q = lab(b)
  return Math.sqrt(Math.pow((p[0] - q[0]) * 0.5, 2) + Math.pow(p[1] - q[1], 2) + Math.pow(p[2] - q[2], 2))
}

// How different the four stat colours are from each other: the smallest
// pairwise CIELAB distance (the two most alike colours decide).
function distinctness(colors) {
  var min = Infinity
  for (var i = 0; i < STATS.length; i++)
    for (var j = i + 1; j < STATS.length; j++)
      min = Math.min(min, deltaE(colors[STATS[i]], colors[STATS[j]]))
  return min
}

// Below this, two of the four colours are hard to tell apart. Calibrated on
// the stock Omarchy themes: Osaka Jade, Lumon, Hackerman, the greyscale
// themes and Retro 82 fall under it; Catppuccin, Gruvbox, Nord and Tokyo Night
// are well above.
var SIMILAR_BELOW = 15

// Parses the themesScript output into [{id, name, custom, colors, score}].
// A user theme with the same name as a stock theme overlays it (user keys win)
// and counts as custom.
function parseThemes(raw) {
  var byName = {}
  var order = []
  var cur = null
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("@@theme\t") === 0) {
      var p = lines[i].split("\t")
      var name = p[2]
      if (!name || p.length !== 3) { cur = null; continue }
      if (!byName[name]) { byName[name] = { id: name, custom: false, map: {} }; order.push(name) }
      cur = byName[name]
      if (p[1] === "user") cur.custom = true
      cur.text = ""
      cur.pending = true
    } else if (cur) {
      Object.assign(cur.map, parseThemeToml(lines[i]))
    }
  }
  var out = []
  for (var k = 0; k < order.length; k++) {
    var t = byName[order[k]]
    var colors = themeColors(t.map)
    if (!colors) continue
    out.push({ id: t.id, name: titleCase(t.id), custom: t.custom, colors: colors, score: distinctness(colors) })
  }
  return out
}

// Custom themes first, then by how different their colours are (most
// distinct first), then by name.
function sortThemes(list) {
  return list.slice().sort(function(a, b) {
    if (a.custom !== b.custom) return a.custom ? -1 : 1
    if (Math.abs(a.score - b.score) > 0.05) return b.score - a.score
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  })
}

// Resolves a stored selection ("system", "fixed:<id>", "theme:<id>") to the
// four colours. An unknown or removed choice falls back to System.
function paletteColors(selection, systemColors, themes) {
  var sys = systemColors || DEFAULT_COLORS
  var sel = String(selection || "system")
  var i
  if (sel.indexOf("fixed:") === 0) {
    for (i = 0; i < FIXED_PALETTES.length; i++) if ("fixed:" + FIXED_PALETTES[i].id === sel) return FIXED_PALETTES[i].colors
  } else if (sel.indexOf("theme:") === 0 && themes) {
    for (i = 0; i < themes.length; i++) if ("theme:" + themes[i].id === sel) return themes[i].colors
  }
  return sys
}

// Whether the stored selection still points at something that exists
// (themes may still be loading, in which case a theme choice is kept).
function selectionKnown(selection, themes) {
  var sel = String(selection || "system")
  var i
  if (sel === "system") return true
  if (sel.indexOf("fixed:") === 0) {
    for (i = 0; i < FIXED_PALETTES.length; i++) if ("fixed:" + FIXED_PALETTES[i].id === sel) return true
    return false
  }
  if (sel.indexOf("theme:") === 0) {
    if (!themes || themes.length === 0) return true
    for (i = 0; i < themes.length; i++) if ("theme:" + themes[i].id === sel) return true
    return false
  }
  return false
}

// ---------------------------------------------------------------------------
// Contrast (accessibility)
// ---------------------------------------------------------------------------

// The active theme's background colour, or null.
function themeBackground(map) {
  return map && HEX.test(String(map.background)) ? String(map.background) : null
}

// WCAG 2 contrast ratio between two #rrggbb colours (1 to 21).
function contrastRatio(a, b) {
  function lum(hex) {
    var c = [1, 3, 5].map(function(i) {
      var v = parseInt(hex.substr(i, 2), 16) / 255
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    })
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
  }
  var x = lum(a), y = lum(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}

// Below this, at least one stat would be hard to read on the bar. WCAG asks
// 4.5:1 for small text; 3:1 is used so that the warning flags palettes that
// are genuinely hard to read (e.g. Dracula's yellow on a light theme, 1.1:1)
// without flagging most dark themes' own colours.
var LOW_CONTRAST_BELOW = 3

function lowContrast(colors, background) {
  if (!colors || !background || !HEX.test(background)) return false
  for (var i = 0; i < STATS.length; i++)
    if (HEX.test(String(colors[STATS[i]])) && contrastRatio(colors[STATS[i]], background) < LOW_CONTRAST_BELOW) return true
  return false
}

function joinNotes(notes) {
  return notes.filter(function(n) { return n !== "" }).join(", ")
}

// Rows for the two pickers: [{value, label, colors, note}]. `background` is
// the active theme's background (or null); palettes that would be hard to
// read on it are marked "low contrast".
function paletteEntries(systemColors, background) {
  var sys = systemColors || DEFAULT_COLORS
  var rows = [{ value: "system", label: "System (follows theme)", colors: sys,
                note: lowContrast(sys, background) ? "low contrast" : "" }]
  for (var i = 0; i < FIXED_PALETTES.length; i++)
    rows.push({ value: "fixed:" + FIXED_PALETTES[i].id, label: FIXED_PALETTES[i].name, colors: FIXED_PALETTES[i].colors,
                note: lowContrast(FIXED_PALETTES[i].colors, background) ? "low contrast" : "" })
  return rows
}

function themeEntries(themes, background) {
  return sortThemes(themes || []).map(function(t) {
    return { value: "theme:" + t.id, label: t.name, colors: t.colors,
             note: joinNotes([t.custom ? "custom" : (t.score < SIMILAR_BELOW ? "similar colours" : ""),
                              lowContrast(t.colors, background) ? "low contrast" : ""]) }
  })
}


// ---------------------------------------------------------------------------
// Hotkey capture
// ---------------------------------------------------------------------------

// Hyprland key names for the Qt key codes the capture box accepts. Keys that
// Qt reports as their shifted symbol on a US layout (Shift+1 -> "!") map back
// to the physical key, because Hyprland wants the key plus a SHIFT modifier.
var KEY_NAMES = (function() {
  var m = {}
  var i
  for (i = 0; i < 26; i++) m[0x41 + i] = String.fromCharCode(0x41 + i)
  for (i = 0; i < 10; i++) m[0x30 + i] = String(i)
  for (i = 1; i <= 12; i++) m[0x01000030 + i - 1] = "F" + i
  var named = {
    0x01000000: "ESCAPE", 0x01000001: "TAB", 0x01000003: "BACKSPACE", 0x01000004: "RETURN",
    0x01000005: "RETURN", 0x01000006: "INSERT", 0x01000007: "DELETE", 0x01000010: "HOME",
    0x01000011: "END", 0x01000012: "LEFT", 0x01000013: "UP", 0x01000014: "RIGHT",
    0x01000015: "DOWN", 0x01000016: "PRIOR", 0x01000017: "NEXT", 0x20: "SPACE",
    0x2c: "COMMA", 0x2d: "MINUS", 0x2e: "PERIOD", 0x2f: "SLASH", 0x3b: "SEMICOLON",
    0x3d: "EQUAL", 0x5b: "BRACKETLEFT", 0x5d: "BRACKETRIGHT", 0x5c: "BACKSLASH",
    0x27: "APOSTROPHE", 0x60: "GRAVE",
    // shifted symbols on a US layout
    0x21: "1", 0x40: "2", 0x23: "3", 0x24: "4", 0x25: "5", 0x5e: "6", 0x26: "7", 0x2a: "8",
    0x28: "9", 0x29: "0", 0x5f: "MINUS", 0x2b: "EQUAL", 0x7b: "BRACKETLEFT", 0x7d: "BRACKETRIGHT",
    0x7c: "BACKSLASH", 0x3a: "SEMICOLON", 0x22: "APOSTROPHE", 0x3c: "COMMA", 0x3e: "PERIOD",
    0x3f: "SLASH", 0x7e: "GRAVE", 0x01000002: "TAB"
  }
  for (var k in named) m[k] = named[k]
  return m
})()

var MODIFIER_KEYS = { 0x01000020: true, 0x01000021: true, 0x01000022: true, 0x01000023: true, 0x01001103: true }

// "SUPER + CTRL + M" from a Qt key press, or null while only modifiers are
// held / the key is unsupported. At least one modifier is required, so a
// hotkey can never swallow plain typing.
function chordFromKey(key, ctrl, alt, shift, meta) {
  if (MODIFIER_KEYS[key]) return null
  var name = KEY_NAMES[key]
  if (!name) return null
  var mods = []
  if (meta) mods.push("SUPER")
  if (ctrl) mods.push("CTRL")
  if (shift) mods.push("SHIFT")
  if (alt) mods.push("ALT")
  if (mods.length === 0) return null
  return mods.concat([name]).join(" + ")
}

// Whether a captured/typed chord is acceptable to hotkey.sh: 1-4 distinct
// modifiers in any order, then one key name. Must match hotkey.sh's check.
function validChord(chord) {
  var s = String(chord)
  if (!/^((SUPER|CTRL|SHIFT|ALT) \+ ){1,4}[A-Z0-9]{1,16}$/.test(s)) return false
  var mods = s.split(" + ").slice(0, -1)
  for (var i = 0; i < mods.length; i++) if (mods.indexOf(mods[i]) !== i) return false
  return true
}

if (typeof module !== "undefined") module.exports = { statsScript: statsScript, parse: parse, cpuPercent: cpuPercent, segments: segments, label: label, colorOr: colorOr, escapeHtml: escapeHtml, richLabel: richLabel, STATS: STATS, DEFAULT_COLORS: DEFAULT_COLORS, FIXED_PALETTES: FIXED_PALETTES, themesScript: themesScript, parseThemeToml: parseThemeToml, themeColors: themeColors, themeBackground: themeBackground, contrastRatio: contrastRatio, lowContrast: lowContrast, LOW_CONTRAST_BELOW: LOW_CONTRAST_BELOW, titleCase: titleCase, deltaE: deltaE, distinctness: distinctness, SIMILAR_BELOW: SIMILAR_BELOW, parseThemes: parseThemes, sortThemes: sortThemes, paletteColors: paletteColors, selectionKnown: selectionKnown, paletteEntries: paletteEntries, themeEntries: themeEntries, chordFromKey: chordFromKey, validChord: validChord }
