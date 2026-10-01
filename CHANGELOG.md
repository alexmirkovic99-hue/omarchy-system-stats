# Changelog

## 1.0.0 (unreleased)

First public release.

- Bar widget with total CPU %, RAM in use, GPU %, VRAM in use and CPU/GPU
  temperatures, each in its own colour
- Palettes: System (follows the active Omarchy theme), nine fixed palettes,
  or any installed Omarchy theme's colours; `similar colours` and
  `low contrast` notes in the picker
- Hot chips (85 °C or more) turn the urgent colour and add `!`
- CPU temperature from `coretemp`, `k10temp` (Tdie when available) or
  `zenpower`; GPU from `nvidia-smi` or AMD `amdgpu` sysfs
- A sleeping laptop dGPU shows `GPU off` and is not woken up to be measured
- "Collapse" hides the stats into a small chip button (the same button reads "Expand" while collapsed)
- The panel is fully keyboard-driven: arrows / `hjkl`, Enter or Space, Esc, Tab
- Two optional hotkeys: expand / collapse the stats, and open the widget's menu.
  Each is one marked block in `~/.config/hypr/bindings.lua`, written only after
  you press a button in the panel. **Add** asks AUTO (a free default is added
  and moved if another shortcut takes it; a shortcut you chose is never
  changed) or MANUAL (you press your own shortcut). Conflicts are refused, and
  the change is undone if Hyprland reports new config errors. Buttons explain
  themselves on hover
- `toggle.sh` show / hide / toggle / delete / status, remembering the
  widget's options and position across a delete
