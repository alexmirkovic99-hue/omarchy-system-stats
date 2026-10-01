import QtQuick
import qs.Commons
import qs.Ui

// Inline expandable picker for stat palettes. The closed row shows the current
// choice with its four colours as swatches (CPU, RAM, GPU, VRAM); opening it
// grows the panel with one row per palette, each with its own swatches, so a
// palette can be judged before it is picked. Styled after Ui/Dropdown.qml, but
// expands in place instead of using a Popup so it lives inside the bar panel.
//
// entries: [{ value, label, colors: {cpu, ram, gpu, vram}, note }]
// value:   the selected entry's value, or "" when the selection is in the
//          other picker (the row then shows `placeholder`).
Item {
  id: root

  property string label: ""
  property var entries: []
  property string value: ""
  property string placeholder: "Choose…"
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool expanded: false
  property int maxRows: 8

  // Keyboard cursor, driven by the panel: the closed row is highlighted while
  // `hasCursor` is set, and `cursorIndex` is the highlighted entry while open.
  property bool hasCursor: false
  property int cursorIndex: -1

  signal picked(string value)
  signal toggled()

  onExpandedChanged: if (!expanded) cursorIndex = -1

  readonly property int rowHeight: Style.spacing.popupRowHeight
  readonly property int swatchSize: Math.max(8, Style.space(10))
  readonly property var current: entryFor(value)

  function entryFor(v) {
    for (var i = 0; i < entries.length; i++) if (entries[i].value === v) return entries[i]
    return null
  }

  function indexOfValue(v) {
    for (var i = 0; i < entries.length; i++) if (entries[i].value === v) return i
    return -1
  }

  // Keyboard use: open with the current choice under the cursor, move the
  // cursor (Up/Down), pick the entry under it.
  function openList() {
    cursorIndex = Math.max(0, indexOfValue(value))
    expanded = true
    list.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function closeList() { expanded = false }

  function moveCursor(delta) {
    if (entries.length === 0) return
    if (cursorIndex < 0) cursorIndex = Math.max(0, indexOfValue(value))
    else cursorIndex = Math.max(0, Math.min(entries.length - 1, cursorIndex + delta))
    list.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function pickCursor() {
    if (cursorIndex >= 0 && cursorIndex < entries.length) picked(entries[cursorIndex].value)
  }

  implicitHeight: column.implicitHeight

  component Swatches: Row {
    id: swatchRow
    property var colors: null
    spacing: Style.space(3)
    Repeater {
      model: ["cpu", "ram", "gpu", "vram"]
      Rectangle {
        required property string modelData
        width: root.swatchSize
        height: root.swatchSize
        radius: Math.round(width / 4)
        color: swatchRow.colors ? swatchRow.colors[modelData] : "transparent"
      }
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.labelGap

    Text {
      textFormat: Text.PlainText
      visible: root.label !== ""
      text: root.label
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    BorderSurface {
      id: trigger
      width: parent.width
      height: root.rowHeight
      radius: Style.cornerRadius

      readonly property bool _hot: triggerHover.hovered || root.hasCursor
      color: Style.controlFill(false, trigger._hot, root.foreground, root.accent)
      borderSpec: Border.controlSpec(trigger._hot ? "hover-cursor" : "normal", root.foreground, root.accent)

      HoverHandler { id: triggerHover }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: triggerSwatches.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.md
        text: root.current ? root.current.label : root.placeholder
        color: root.current ? root.foreground : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Swatches {
        id: triggerSwatches
        visible: root.current !== null
        colors: root.current ? root.current.colors : null
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
      }

      Text {
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
        text: root.expanded ? "󰅃" : "󰅀"
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
      }
    }

    Rectangle {
      id: listFrame
      width: parent.width
      height: root.expanded ? Math.min(root.entries.length, root.maxRows) * root.rowHeight : 0
      visible: height > 0
      clip: true
      color: Style.normalFillFor(root.foreground, root.accent)

      ListView {
        id: list
        anchors.fill: parent
        model: root.entries
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool selected: modelData.value === root.value
          width: list.width
          height: root.rowHeight
          color: rowMouse.containsMouse || index === root.cursorIndex ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

          Text {
            id: rowName
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            text: modelData.label
            color: row.selected ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: row.selected
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: rowName.right
            anchors.right: rowSwatches.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            text: modelData.note || ""
            color: Qt.darker(root.foreground, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Swatches {
            id: rowSwatches
            colors: modelData.colors
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Style.spacing.controlPaddingX
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.picked(modelData.value)
          }
        }
      }
    }
  }
}
