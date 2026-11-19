import QtQuick
import "kit"

// A key drawn as a key cap (the add field's footer hints): the key's
// symbol in the mono font in a small bordered box. The kit has none.
Rectangle {
  id: cap
  property string text: ""
  implicitWidth: Math.max(implicitHeight, label.implicitWidth + FoamyStyle.gap)
  implicitHeight: FoamyStyle.font.caption + FoamyStyle.gap
  radius: FoamyStyle.radiusSmall
  color: FoamyPalette.fieldFill
  border.width: FoamyStyle.borderWidth
  border.color: FoamyPalette.border
  PlainText {
    id: label
    anchors.centerIn: parent
    text: cap.text
    wrapMode: Text.NoWrap
    font.family: FoamyStyle.monoFamily
    font.pixelSize: FoamyStyle.font.caption
    color: FoamyPalette.secondaryText
  }
}
