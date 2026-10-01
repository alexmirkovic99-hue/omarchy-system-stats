import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// One hotkey in the panel: its label, the shortcut it has (or "Not set") and the
// buttons for it. Nothing is written to the Hyprland config until a button is
// pressed:
//   Add     asks how: AUTO (a free default is added and kept free) or MANUAL
//           (you press the shortcut you want)
//   Change  press a new shortcut
//   Clear   remove it
// Buttons explain themselves in a tooltip instead of with permanent text.
// All the work is done by hotkey.sh (see its header); this row only runs it.
Item {
  id: root

  property string label: ""
  property string action: "toggle"          // which hotkey of hotkey.sh: toggle or menu
  property string pluginDir: ""
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property Item focusTarget: null           // gets the keyboard back after a capture

  property string hotkey: ""
  property string message: ""
  property bool messageError: false
  property string warning: ""
  property bool choosing: false             // Add was pressed: AUTO / MANUAL are showing
  property bool capturing: false            // waiting for the user to press a shortcut
  property bool captureAfterMode: false

  // Keyboard cursor, driven by the panel: `cursorOn` when this row has it and
  // `cursorCol` the button under it (left to right among the visible buttons).
  property bool cursorOn: false
  property int cursorCol: 0
  readonly property var buttonNames: capturing ? ["cancel"]
    : (choosing ? ["auto", "manual", "back"] : (hotkey !== "" ? ["change", "clear"] : ["add"]))
  onButtonNamesChanged: cursorCol = 0

  function moveCursor(dx) {
    cursorCol = Math.max(0, Math.min(buttonNames.length - 1, cursorCol + dx))
  }

  function activateCursor() {
    switch (buttonNames[Math.min(cursorCol, buttonNames.length - 1)]) {
      case "add": choosing = true; break
      case "auto": chooseAuto(); break
      case "manual": chooseManual(); break
      case "back": choosing = false; break
      case "change": startCapture(); break
      case "clear": run(["clear"]); break
      case "cancel": stopCapture(); break
    }
  }

  // Esc steps back out of "Add how?" before the panel itself closes.
  // True when it did something.
  function cancelChoice() {
    if (!choosing) return false
    choosing = false
    return true
  }

  implicitHeight: column.implicitHeight

  function script(args) {
    return ["bash", pluginDir + "/hotkey.sh", action].concat(args)
  }

  function load() {
    if (!getProc.running) getProc.running = true
    if (!checkProc.running) checkProc.running = true
  }

  function run(args) {
    if (runProc.running) return
    message = ""
    messageError = false
    runProc.exec(script(args))
  }

  function startCapture() {
    message = ""
    messageError = false
    choosing = false
    capturing = true
    captureBox.forceActiveFocus()
  }

  function stopCapture() {
    capturing = false
    if (focusTarget) focusTarget.forceActiveFocus()
  }

  // Add > AUTO: a free default is written now and kept free from then on.
  function chooseAuto() {
    choosing = false
    run(["mode", "auto"])
  }

  // Add > MANUAL: switch to MANUAL, then wait for the user's own shortcut.
  function chooseManual() {
    choosing = false
    if (runProc.running) return
    captureAfterMode = true
    run(["mode", "manual"])
  }

  Process {
    id: getProc
    command: root.script(["get"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.hotkey = text.trim()
    }
  }

  // Read-only: warns when another binding has since taken the same shortcut.
  Process {
    id: checkProc
    command: root.script(["check"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.warning = text.trim()
    }
  }

  // set / set-default / clear / mode. stdout carries the result, stderr the
  // reason a change was refused (invalid, already used, rejected by Hyprland).
  Process {
    id: runProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const lines = text.trim().split("\n").filter(function(l) { return l !== "" })
        if (lines.length === 0 || lines[0] === "manual") return
        root.messageError = false
        if (lines[lines.length - 1] === "auto") root.message = lines.length > 1 ? "AUTO: added " + lines[0] : "AUTO is on."
        else root.message = "Saved: " + lines[0]
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") { root.messageError = true; root.message = text.trim() }
    }
    onExited: {
      root.load()
      if (root.captureAfterMode) {
        root.captureAfterMode = false
        root.startCapture()
      }
    }
  }

  // Key capture target: takes focus while waiting for a shortcut.
  Item {
    id: captureBox
    width: 0
    height: 0
    Keys.onPressed: function(event) {
      if (!root.capturing) return
      const m = event.modifiers
      if (event.key === Qt.Key_Escape && !(m & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier))) {
        root.stopCapture()
        event.accepted = true
        return
      }
      const chord = Model.chordFromKey(event.key, !!(m & Qt.ControlModifier), !!(m & Qt.AltModifier), !!(m & Qt.ShiftModifier), !!(m & Qt.MetaModifier))
      if (chord) {
        root.stopCapture()
        root.run(["set", chord])
      } else if (event.key !== Qt.Key_Shift && event.key !== Qt.Key_Control && event.key !== Qt.Key_Alt && event.key !== Qt.Key_Meta && event.key !== Qt.Key_Super_L && event.key !== Qt.Key_Super_R) {
        root.messageError = true
        root.message = "Hold Super, Ctrl, Alt or Shift together with a letter, number or F-key."
      }
      event.accepted = true
    }
  }

  component RowButton: Button {
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    bordered: true
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: Math.max(texts.implicitHeight, buttons.implicitHeight)

      Column {
        id: texts
        anchors.left: parent.left
        anchors.right: buttons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.label
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.capturing ? "Press the new shortcut…"
            : (root.choosing ? "Add how?" : (root.hotkey !== "" ? root.hotkey : "Not set"))
          color: root.foreground
          opacity: root.hotkey === "" && !root.capturing && !root.choosing ? 0.6 : 1
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }

      Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        // No hotkey yet
        RowButton {
          visible: root.hotkey === "" && !root.capturing && !root.choosing
          text: "Add"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "add"
          tooltipText: "Adds a hotkey. You choose AUTO or MANUAL next.\nIt is one marked line in ~/.config/hypr/bindings.lua\nand is listed in the keybindings menu (SUPER + K)."
          onClicked: root.choosing = true
        }

        // Add was pressed: how?
        RowButton {
          visible: root.choosing
          text: "AUTO"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "auto"
          tooltipText: "Adds a free default shortcut for you and keeps it\nfree: it moves if another shortcut takes it.\nA shortcut you choose yourself is never changed."
          onClicked: root.chooseAuto()
        }
        RowButton {
          visible: root.choosing
          text: "MANUAL"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "manual"
          tooltipText: "You press the shortcut you want.\nNothing is ever changed automatically."
          onClicked: root.chooseManual()
        }
        RowButton {
          visible: root.choosing
          text: "Cancel"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "back"
          onClicked: root.choosing = false
        }

        // A hotkey exists
        RowButton {
          visible: root.hotkey !== "" && !root.capturing && !root.choosing
          text: "Change"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "change"
          tooltipText: "Press a new shortcut to replace this one."
          onClicked: root.startCapture()
        }
        RowButton {
          visible: root.hotkey !== "" && !root.capturing && !root.choosing
          text: "Clear"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "clear"
          tooltipText: "Removes the hotkey from your Hyprland config."
          onClicked: root.run(["clear"])
        }

        // Waiting for a shortcut
        RowButton {
          visible: root.capturing
          text: "Cancel"
          hasCursor: root.cursorOn && root.buttonNames[root.cursorCol] === "cancel"
          onClicked: root.stopCapture()
        }
      }
    }

    // Only shown when there is something to report (a result, an error, or a
    // shortcut that another binding has since taken).
    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: root.message !== "" ? root.message : root.warning
      color: root.messageError || (root.message === "" && root.warning !== "") ? root.urgent : root.foreground
      opacity: root.messageError || root.warning !== "" ? 1 : 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
