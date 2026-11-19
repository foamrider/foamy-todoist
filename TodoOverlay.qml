pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "kit"

// The Large panel: a centred overlay window, the host's own OverlayWindow
// as Foamy Menu's launcher uses it (a fresh layer surface on each open,
// shown once the output's scale has arrived; overlay layer, exclusive
// keyboard focus). It opens on `wantedScreen`, the monitor of the bar that
// was clicked, or on the focused one (null, from IPC). Panel.qml creates
// it only while Large is open, so nothing of it lives while closed.
//
// The card is the popup's: its radius, surface and border, the band
// first. It is as wide as `cardWidth` (the settings page: the popup's
// width), never wider than the screen minus the margins, and as tall as
// its content up to 70% of the screen; the list scrolls inside. A click
// outside closes it; Esc closes it when nothing inside uses Esc (the view's
// closeView). A screen without room for it says `tooNarrow` instead, and
// the panel opens Wide in the popup.
OverlayWindow {
  id: window
  property var wantedScreen: null
  property real cardWidth: Style.space(880)
  // The overlay is showing (false while it goes: the view closes first).
  property bool open: true
  property var preferences: ({})
  property bool saving: false
  property string settingsError: ""
  property bool retryable: false
  readonly property alias view: todoView
  readonly property alias card: card
  signal closeRequested
  signal tooNarrow
  signal saveRequested(string key, var value)
  signal retryRequested

  WlrLayershell.namespace: "foamy-todoist"

  readonly property real margin: FoamyStyle.padding * 2
  readonly property bool editingSettings: TodoStore.overlayPage === "settings"
  readonly property real shownWidth: Math.min(editingSettings ? FoamyStyle.popupWidth : cardWidth, Math.max(0, width - margin * 2))
  readonly property real maxCardHeight: Math.round(height * 0.7)

  // Shown while open, so it goes at once on close while its view closes
  // behind it. The host picks the focused monitor (and refreshes
  // Hyprland's) when it is shown; a bar's own monitor replaces it.
  Component.onCompleted: {
    shown = Qt.binding(function () {
      return window.open
    })
    if (wantedScreen)
      targetScreen = wantedScreen
    if (targetScreen && targetScreen.width < cardWidth + margin * 2)
      Qt.callLater(window.tooNarrow)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: window.closeRequested()
  }

  BorderSurface {
    id: card
    objectName: "overlayCard"
    width: window.shownWidth
    height: Math.min(todoView.implicitHeight + card.borderTop + card.borderBottom, window.maxCardHeight)
    anchors.centerIn: parent
    radius: FoamyStyle.radius
    color: FoamyPalette.background
    borderSpec: FoamyStyle.popupBorderSpec
    clip: true

    // A click inside never reaches the close area behind the card.
    MouseArea {
      anchors.fill: parent
    }

    TodoView {
      id: todoView
      objectName: "overlayView"
      x: card.borderLeft
      y: card.borderTop
      width: card.width - card.borderLeft - card.borderRight
      height: card.height - card.borderTop - card.borderBottom
      size: "large"
      active: window.open
      preferences: window.preferences
      saving: window.saving
      settingsError: window.settingsError
      retryable: window.retryable
      editingSettings: window.editingSettings
      addOnOpen: TodoStore.overlayPage === "add"
      onAddOnOpenUsed: if (TodoStore.overlayPage === "add")
        TodoStore.overlayPage = ""
      onSettingsRequested: TodoStore.overlayPage = "settings"
      onSettingsClosed: TodoStore.overlayPage = ""
      onCloseView: window.closeRequested()
      onSaveRequested: function (key, value) {
        window.saveRequested(key, value)
      }
      onRetryRequested: window.retryRequested()
    }
  }
}
