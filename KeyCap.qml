pragma ComponentBehavior: Bound
import QtQuick
import "kit"

// A key drawn as a key cap (the footer's key hints): actionSize less a gap
// high (20 px), in the text colour. Enter, Shift and the arrows are drawn
// as icon strokes (a cap's text made only of those symbols, such as "⇧↵"
// or "↑↓", one icon each, never mirrored: they are the keys as printed);
// any other text ("Esc", "Space", "t") as text in bodySmall.
Rectangle {
  id: cap
  property string text: ""
  // The key symbols drawn as icons.
  readonly property var icons: ({
      "↵": "corner-down-left",
      "⇧": "arrow-big-up",
      "↑": "arrow-up",
      "↓": "arrow-down",
      "←": "arrow-left",
      "→": "arrow-right"
    })
  readonly property var parts: {
    var chars = Array.from(text)
    var drawn = chars.length > 0 && chars.every(function (c) {
      return cap.icons[c] !== undefined
    })
    return drawn ? chars : [text]
  }
  implicitHeight: FoamyStyle.actionSize - FoamyStyle.gap
  implicitWidth: Math.max(implicitHeight, content.implicitWidth + FoamyStyle.gap)
  radius: FoamyStyle.radiusSmall
  color: FoamyPalette.fieldFill
  border.width: FoamyStyle.borderWidth
  border.color: FoamyPalette.border
  Row {
    id: content
    anchors.centerIn: parent
    spacing: FoamyStyle.gapTiny
    Repeater {
      model: cap.parts
      Item {
        id: part
        required property string modelData
        readonly property bool drawn: cap.icons[modelData] !== undefined
        implicitWidth: drawn ? FoamyStyle.iconSize - FoamyStyle.gapTiny : label.implicitWidth
        implicitHeight: FoamyStyle.iconSize
        FoamyIcon {
          objectName: "keyIcon"
          visible: part.drawn
          anchors.centerIn: parent
          width: parent.implicitWidth
          height: width
          name: part.drawn ? cap.icons[part.modelData] : "x"
          // The key as printed: no mirroring in RTL.
          mirror: false
          color: FoamyPalette.text
        }
        PlainText {
          id: label
          visible: !part.drawn
          anchors.centerIn: parent
          text: part.drawn ? "" : part.modelData
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.text
        }
      }
    }
  }
}
