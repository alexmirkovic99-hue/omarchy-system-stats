// Runs the real collector script (Model.statsScript) against fake /proc and
// /sys trees and a fake nvidia-smi, covering hardware this machine may not
// have: AMD CPUs (k10temp, zenpower), AMD GPUs (amdgpu), sleeping NVIDIA GPUs,
// no sensors at all. Run: node tests/test-stats.js
const assert = require("assert")
const fs = require("fs")
const os = require("os")
const path = require("path")
const { execFileSync } = require("child_process")
const M = require(path.join(__dirname, "..", "Model.js"))

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "stats-test-"))
process.on("exit", () => fs.rmSync(tmp, { recursive: true, force: true }))

let n = 0
function tree(files) {
  const root = path.join(tmp, "root" + n++)
  for (const [p, content] of Object.entries(files)) {
    const full = path.join(root, p)
    fs.mkdirSync(path.dirname(full), { recursive: true })
    fs.writeFileSync(full, content)
  }
  return root
}
const base = {
  "proc/stat": "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 1 1 1 1 1 1 1 1 1\n",
  "proc/meminfo": "MemTotal:       8000000 kB\nMemFree:        1000000 kB\nMemAvailable:   3000000 kB\n",
}
// A fake nvidia-smi that records that it ran (so we can prove it was NOT run).
function fakeSmi(output, exitCode = 0) {
  const p = path.join(tmp, "nvidia-smi" + n++)
  fs.writeFileSync(p, `#!/bin/bash\ntouch "$0.ran"\nprintf '%s\\n' '${output}'\nexit ${exitCode}\n`)
  fs.chmodSync(p, 0o755)
  return p
}
function run(root, smi) {
  const out = execFileSync("/bin/bash", ["-c", M.statsScript, "system-stats", root, smi || path.join(tmp, "absent")]).toString()
  return { raw: out, parsed: M.parse(out) }
}

// 1. Intel + NVIDIA awake: coretemp wins over other sensors; nvidia-smi queried
{
  const root = tree({ ...base,
    "sys/class/hwmon/hwmon0/name": "acpitz\n", "sys/class/hwmon/hwmon0/temp1_input": "99000\n",
    "sys/class/hwmon/hwmon1/name": "coretemp\n", "sys/class/hwmon/hwmon1/temp1_input": "46000\n",
    "sys/bus/pci/drivers/nvidia/0000:01:00.0/power/runtime_status": "active\n" })
  const smi = fakeSmi("7, 300, 4096, 51")
  const { raw, parsed } = run(root, smi)
  assert.ok(raw.startsWith("cpu\t1000 850\nmem\t8000000 3000000\n"), raw)
  assert.strictEqual(parsed.cpuTempC, 46)
  assert.deepStrictEqual(parsed.gpu, { off: false, util: 7, usedMiB: 300, totalMiB: 4096, tempC: 51 })
  assert.ok(fs.existsSync(smi + ".ran"))
}
// 2. NVIDIA runtime-suspended (Optimus laptop idle): reported off, NOT queried
{
  const root = tree({ ...base, "sys/bus/pci/drivers/nvidia/0000:01:00.0/power/runtime_status": "suspended\n" })
  const smi = fakeSmi("7, 300, 4096, 51")
  const { parsed } = run(root, smi)
  assert.deepStrictEqual(parsed.gpu, { off: true })
  assert.ok(!fs.existsSync(smi + ".ran"), "nvidia-smi must not wake a sleeping GPU")
}
// 3. NVIDIA desktop without runtime PM files: queried normally
{
  const root = tree({ ...base })
  const smi = fakeSmi("3, 512, 2048, 44")
  assert.strictEqual(run(root, smi).parsed.gpu.util, 3)
}
// 4. AMD Ryzen, k10temp with Tdie label: Tdie is used rather than Tctl
{
  const root = tree({ ...base,
    "sys/class/hwmon/hwmon2/name": "k10temp\n",
    "sys/class/hwmon/hwmon2/temp1_input": "70000\n", "sys/class/hwmon/hwmon2/temp1_label": "Tctl\n",
    "sys/class/hwmon/hwmon2/temp2_input": "50000\n", "sys/class/hwmon/hwmon2/temp2_label": "Tdie\n" })
  assert.strictEqual(run(root).parsed.cpuTempC, 50)
}
// 5. k10temp without Tdie (newer kernels): Tctl (temp1)
{
  const root = tree({ ...base, "sys/class/hwmon/hwmon0/name": "k10temp\n", "sys/class/hwmon/hwmon0/temp1_input": "61500\n" })
  assert.strictEqual(run(root).parsed.cpuTempC, 62)
}
// 6. zenpower, and coretemp beats k10temp whatever the hwmon order
{
  assert.strictEqual(run(tree({ ...base, "sys/class/hwmon/hwmon0/name": "zenpower\n", "sys/class/hwmon/hwmon0/temp1_input": "55000\n" })).parsed.cpuTempC, 55)
  const root = tree({ ...base,
    "sys/class/hwmon/hwmon0/name": "k10temp\n", "sys/class/hwmon/hwmon0/temp1_input": "70000\n",
    "sys/class/hwmon/hwmon1/name": "coretemp\n", "sys/class/hwmon/hwmon1/temp1_input": "40000\n" })
  assert.strictEqual(run(root).parsed.cpuTempC, 40)
}
// 7. AMD GPU through amdgpu sysfs (no nvidia-smi)
const amd = {
  "sys/class/drm/card1/device/gpu_busy_percent": "12\n",
  "sys/class/drm/card1/device/mem_info_vram_used": "1073741824\n",
  "sys/class/drm/card1/device/mem_info_vram_total": "8589934592\n",
  "sys/class/drm/card1/device/hwmon/hwmon5/temp1_input": "61000\n",
  "sys/class/drm/card1/device/power/runtime_status": "active\n",
}
{
  const { parsed } = run(tree({ ...base, ...amd }))
  assert.deepStrictEqual(parsed.gpu, { off: false, util: 12, usedMiB: 1024, totalMiB: 8192, tempC: 61 })
}
// 8. AMD dGPU runtime-suspended: off, and its counters are not read
{
  const root = tree({ ...base, ...amd, "sys/class/drm/card1/device/power/runtime_status": "suspended\n" })
  assert.deepStrictEqual(run(root).parsed.gpu, { off: true })
}
// 9. nvidia-smi present but failing (e.g. nouveau loaded): falls back to amdgpu
{
  const root = tree({ ...base, ...amd })
  const smi = fakeSmi("", 6)
  assert.strictEqual(run(root, smi).parsed.gpu.util, 12)
}
// 10. garbage in sysfs is ignored, never passed through
{
  const root = tree({ ...base, ...amd, "sys/class/drm/card1/device/gpu_busy_percent": "12; rm -rf ~\n",
    "sys/class/hwmon/hwmon0/name": "coretemp\n", "sys/class/hwmon/hwmon0/temp1_input": "hot\n" })
  const { raw, parsed } = run(root)
  assert.strictEqual(parsed.gpu, null)
  assert.strictEqual(parsed.cpuTempC, null)
  assert.ok(!/rm -rf/.test(raw))
}
// 11. no sensors, no GPU (VM / container): CPU and RAM only
{
  const { raw, parsed } = run(tree({ ...base }))
  assert.strictEqual(raw, "cpu\t1000 850\nmem\t8000000 3000000\n")
  assert.strictEqual(M.label(parsed, 15, true, false), "CPU 15% RAM 4.8")
}
// 12. the widget's own invocation (no root argument) works on this machine
{
  const out = execFileSync("/bin/bash", ["-c", M.statsScript, "system-stats"]).toString()
  const p = M.parse(out)
  assert.ok(p && p.cpu && p.memTotalKb > 0, out)
}
console.log("ok")
