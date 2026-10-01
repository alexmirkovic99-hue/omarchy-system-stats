import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  // The bar injects moduleName (this widget's id from manifest.json), so the
  // id is not repeated here.
  manageIpc: false

  readonly property bool vertical: bar ? bar.vertical : false

  // CPU percent needs two /proc/stat samples, so the previous one is kept
  // here and the first reading after load shows RAM/GPU only.
  property var prevCpu: null
  property var stats: null
  property var cpu: null

  // Accept false and "false" (a value set with `omarchy bar set` without --json).
  readonly property bool showTemps: String(setting("showTemps", true)) !== "false"
  readonly property int intervalMs: Math.max(1000, Math.min(10000, Number(setting("intervalMs", 2000)) || 2000))
  readonly property var segments: Model.segments(stats, cpu, showTemps)
  readonly property string labelText: Model.label(stats, cpu, showTemps, vertical)

  // ---- Palette ------------------------------------------------------------
  // The choice is stored inline in shell.json as `palette`: "system" (follow
  // the active Omarchy theme), "fixed:<id>" (a popular terminal palette) or
  // "theme:<name>" (another Omarchy theme's colours, without switching to it).
  property string choice: ""
  readonly property string selection: choice !== "" ? choice : String(setting("palette", "system"))

  // Colours of the active Omarchy theme, kept live (see themeFile below).
  property var systemColors: null
  // The active theme's background, used to flag low-contrast palettes.
  property var systemBackground: null
  // Every Omarchy theme on this machine, scanned from disk.
  property var themes: []

  // The label waits until the colours it needs have been read, so it never
  // shows up in the wrong palette and then changes. "System" needs the active
  // theme's colours and "theme:<name>" needs the theme scan; fixed palettes
  // are ready immediately. If something is unreadable, show it anyway after a
  // moment instead of staying hidden.
  property bool gaveUpWaiting: false
  readonly property bool paletteReady: gaveUpWaiting
    || (selection === "system" ? systemColors !== null
      : (selection.indexOf("theme:") === 0 ? themes.length > 0 : true))

  Timer {
    interval: 1500
    running: true
    onTriggered: root.gaveUpWaiting = true
  }

  readonly property var colors: Model.paletteColors(selection, systemColors, themes)
  readonly property var paletteRows: Model.paletteEntries(systemColors, systemBackground)
  readonly property var themeRows: Model.themeEntries(themes, systemBackground)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string richText: Model.richLabel(segments, colors, String(urgentColor), vertical)

  function apply(raw) {
    const next = Model.parse(raw)
    if (!next) return
    cpu = Model.cpuPercent(prevCpu, next.cpu)
    prevCpu = next.cpu
    stats = next
  }

  // Saves one option in this widget's shell.json entry (hot-reloaded by the
  // shell). Uses the shell's scoped updateEntryInline when it exists and
  // accepts the write; otherwise the public `omarchy bar set` command.
  function saveSetting(key, value) {
    if (root.moduleName === "") return
    // Nothing to save; also means a false result below is a refusal, not "unchanged".
    if (root.settings && JSON.stringify(root.settings[key]) === JSON.stringify(value)) return
    const next = Object.assign({}, root.settings)
    next[key] = value
    root.settings = next
    let saved = false
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      saved = root.bar.shell.updateEntryInline(root.moduleName, next) === true
    if (!saved)
      saveProc.exec(["omarchy", "bar", "set", root.moduleName, key, JSON.stringify(value), "--json"])
  }

  function choose(value) {
    choice = value
    paletteList.expanded = false
    themeList.expanded = false
    saveSetting("palette", value)
  }

  // Collapsed: the stats are hidden and a small button stands in for them;
  // clicking it brings the stats back. Stored as `collapsed` in shell.json.
  property var collapsedChoice: null
  readonly property bool collapsed: collapsedChoice !== null ? collapsedChoice : setting("collapsed", false) === true

  function setCollapsed(value) {
    collapsedChoice = value
    close()
    saveSetting("collapsed", value)
  }

  // ---- Keyboard -----------------------------------------------------------------
  // Like the other Omarchy panels: arrows (or h/j/k/l) move a cursor, Enter or
  // Space activates, Esc steps back and then closes, Tab switches panel. The
  // cursor appears with the first key press, so mouse use looks unchanged.
  // Rows: 0 palette, 1 Omarchy themes, 2 hide/show hotkey, 3 menu hotkey, 4 remove.
  property bool cursorActive: false
  property int cursorRow: 0
  readonly property int cursorRows: 5

  function openDropdown() {
    return paletteList.expanded ? paletteList : (themeList.expanded ? themeList : null)
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) { cursorActive = true; return }
    const dd = openDropdown()
    if (dd) {
      if (dy !== 0) dd.moveCursor(dy)
      return
    }
    if (dy !== 0) cursorRow = Math.max(0, Math.min(cursorRows - 1, cursorRow + dy))
    else if (cursorRow === 2) toggleKey.moveCursor(dx)
    else if (cursorRow === 3) menuKey.moveCursor(dx)
  }

  function activateCursor() {
    if (!cursorActive) return
    const dd = openDropdown()
    if (dd) { dd.pickCursor(); return }
    switch (cursorRow) {
      case 0: themeList.closeList(); paletteList.openList(); break
      case 1: paletteList.closeList(); themeList.openList(); break
      case 2: toggleKey.activateCursor(); break
      case 3: menuKey.activateCursor(); break
      case 4: setCollapsed(!collapsed); break
    }
  }

  // Esc steps back out of an open list or "Add how?" first, then closes the panel.
  function stepBack() {
    const dd = openDropdown()
    if (dd) { dd.closeList(); return }
    if (toggleKey.cancelChoice() || menuKey.cancelChoice()) return
    close()
  }

  // ---- Hotkeys (optional) -----------------------------------------------------
  // hotkey.sh keeps each one as a marked block in ~/.config/hypr/bindings.lua.
  // Nothing is written until a button in the panel is pressed; AUTO is chosen
  // after pressing Add (see README and the header of hotkey.sh).
  // Qt.resolvedUrl percent-encodes the path, so decode it before use.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property bool capturing: toggleKey.capturing || menuKey.capturing

  function scanThemes() {
    if (!themesProc.running) themesProc.running = true
  }

  // AUTO hotkeys only (does nothing for MANUAL ones): adds or moves the defaults.
  Process {
    id: hotkeyEnsureProc
    command: ["bash", root.pluginDir + "/hotkey.sh", "ensure"]
    onExited: { toggleKey.load(); menuKey.load() }
  }

  Timer {
    interval: 4000
    running: true
    onTriggered: hotkeyEnsureProc.running = true
  }

  // Fallback persistence when the shell's updateEntryInline is missing or refuses.
  Process { id: saveProc }

  // ---- Data collection ------------------------------------------------------
  // `timeout` bounds the collector, so a hung nvidia-smi can't wedge the
  // widget: the process always exits and the next tick can start a new one.
  Process {
    id: statsProc
    command: ["/usr/bin/timeout", "--kill-after=0.25s", "1.5s", "/bin/bash", "-c", Model.statsScript, "system-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  Timer {
    interval: root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statsProc.running) statsProc.running = true
  }

  // All Omarchy themes, for the theme list and for a saved "theme:<name>"
  // choice. Rescanned each time the panel opens so new custom themes show up.
  Process {
    id: themesProc
    command: ["/usr/bin/timeout", "--kill-after=0.25s", "3s", "/bin/bash", "-c", Model.themesScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const list = Model.parseThemes(text)
        if (JSON.stringify(list) !== JSON.stringify(root.themes)) root.themes = list
      }
    }
  }

  // The active theme's colours, for "System". The shell swaps the theme
  // directory on `omarchy theme set`, so the file is watched and also re-read
  // on a slow timer in case the swap replaces the watched file.
  FileView {
    id: themeFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      const map = Model.parseThemeToml(text())
      const c = Model.themeColors(map)
      if (JSON.stringify(c) !== JSON.stringify(root.systemColors)) root.systemColors = c
      const bg = Model.themeBackground(map)
      if (bg !== root.systemBackground) root.systemBackground = bg
    }
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    onTriggered: themeFile.reload()
  }

  // Once shell.json carries the new value the local override is redundant,
  // and clearing it lets hand edits of shell.json take effect.
  onSettingsChanged: { choice = ""; collapsedChoice = null }

  Component.onCompleted: scanThemes()
  onOpenedChanged: {
    if (opened) {
      scanThemes()
      toggleKey.load()
      menuKey.load()
    } else {
      toggleKey.capturing = false
      menuKey.capturing = false
      toggleKey.choosing = false
      menuKey.choosing = false
      paletteList.expanded = false
      themeList.expanded = false
      cursorActive = false
      cursorRow = 0
    }
  }

  // ---- Bar widget -----------------------------------------------------------
  visible: collapsed || (labelText !== "" && paletteReady)
  implicitWidth: collapsed ? iconButton.implicitWidth : button.implicitWidth
  implicitHeight: collapsed ? iconButton.implicitHeight : button.implicitHeight

  // The small button shown while collapsed: left click brings the stats back,
  // right click opens the panel (palette, hotkey, remove).
  BarIconButton {
    id: iconButton
    anchors.fill: parent
    visible: root.collapsed
    bar: root.bar
    text: "\uf2db"
    slotSize: Style.bar.statusSlot
    tooltipText: "Show system stats"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggle()
      else root.setCollapsed(false)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    visible: !root.collapsed
    bar: root.bar
    text: root.labelText
    fontSize: Style.font.caption
    horizontalMargin: 4
    // The coloured label below replaces the button's single-colour text; the
    // button still provides sizing, hover cursor and the click target.
    labelVisible: false
    fixedWidth: root.vertical ? -1 : coloredLabel.implicitWidth + Style.spaceReal(4) * 2
    fixedHeight: root.vertical ? coloredLabel.implicitHeight + Style.spaceReal(6) * 2 : -1
    onPressed: function(mouse) { if (mouse === Qt.LeftButton) root.toggle() }
  }

  Text {
    id: coloredLabel
    visible: !root.collapsed
    anchors.centerIn: button
    textFormat: Text.RichText
    text: root.richText
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    renderType: Text.NativeRendering
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }

  // ---- Palette panel ----------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.collapsed ? iconButton : button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.capturing
      onCloseRequested: root.stepBack()
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        PanelSectionHeader {
          text: "STATS COLOURS"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        PaletteDropdown {
          id: paletteList
          hasCursor: root.cursorActive && root.cursorRow === 0 && !expanded
          width: parent.width
          label: "Palette"
          entries: root.paletteRows
          value: root.selection === "system" || root.selection.indexOf("fixed:") === 0 ? root.selection : ""
          placeholder: "Using an Omarchy theme"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onToggled: { expanded = !expanded; if (expanded) themeList.expanded = false }
          onPicked: function(v) { root.choose(v) }
        }

        PaletteDropdown {
          id: themeList
          hasCursor: root.cursorActive && root.cursorRow === 1 && !expanded
          width: parent.width
          label: "Omarchy themes"
          entries: root.themeRows
          value: root.selection.indexOf("theme:") === 0 ? root.selection : ""
          placeholder: root.themeRows.length === 0 ? "No themes found" : "Choose a theme…"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onToggled: { expanded = !expanded; if (expanded) paletteList.expanded = false }
          onPicked: function(v) { root.choose(v) }
        }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        PanelSectionHeader {
          text: "HOTKEYS"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        HotkeyRow {
          id: toggleKey
          cursorOn: root.cursorActive && root.cursorRow === 2
          width: parent.width
          label: "Expand / Collapse"
          action: "toggle"
          pluginDir: root.pluginDir
          foreground: root.bar ? root.bar.foreground : Color.foreground
          urgent: root.urgentColor
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          focusTarget: keyCatcher
        }

        HotkeyRow {
          id: menuKey
          cursorOn: root.cursorActive && root.cursorRow === 3
          width: parent.width
          label: "Open this menu"
          action: "menu"
          pluginDir: root.pluginDir
          foreground: root.bar ? root.bar.foreground : Color.foreground
          urgent: root.urgentColor
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          focusTarget: keyCatcher
        }

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        Button {
          width: parent.width
          text: root.collapsed ? "Expand" : "Collapse"
          hasCursor: root.cursorActive && root.cursorRow === 4
          tooltipText: root.collapsed ? "Shows the stats again." : "Hides the stats and leaves a small button on the bar;
click it to bring them back. To take the widget off
the bar completely, disable the plugin."
          fontSize: Style.font.bodySmall
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: root.setCollapsed(!root.collapsed)
        }
      }
    }
  }
}
