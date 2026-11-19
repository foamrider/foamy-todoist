pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "kit"
import "Preferences.js" as Schema

// One bar instance (4.5 draws one per monitor). Todoist lives in the
// TodoStore singleton; every instance pushes the saved settings into it,
// the leader owns the IPC target and draws the Large overlay, and any
// instance can save settings.
//
// Sizes: Small and Wide are this bar's popup; Large is one overlay for
// the whole shell (TodoStore.overlayOpen), drawn by the leader on the
// monitor of the bar that was clicked (from IPC: the focused one). Where
// Large doesn't fit it falls back to Wide, and Wide to Small.
Ui.Panel {
  id: root
  ipcTarget: "foamy.todoist"
  manageIpc: false
  readonly property alias popup: panelPopup
  readonly property alias prefs: prefsQueue
  readonly property alias member: member
  readonly property alias barContent: barContent
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FoamyPrefsQueue {
    id: prefsQueue
    bar: root.bar
    moduleName: root.moduleName
    fields: Schema.fields
    settings: root.settings
  }
  FoamyMember {
    id: member
    scope: "todoist"
    demanding: root.opened || (member.isLeader && TodoStore.overlayOpen)
  }
  function pushSettings() {
    TodoStore.refreshSeconds = prefsQueue.value("refreshSeconds")
    TodoStore.openCommand = prefsQueue.value("openCommand")
    TodoStore.othersTasks = prefsQueue.value("othersTasks")
  }
  Connections {
    target: prefsQueue
    function onEffectiveSettingsChanged() {
      root.pushSettings()
    }
  }
  Component.onCompleted: pushSettings()

  // The size setting, and what this bar's screen has room for: Large
  // needs the overlay's width and the margins beside it, Wide the wide
  // popup (the bar window spans the screen).
  readonly property string sizeSetting: prefsQueue.value("panelWidth")
  readonly property int largeWidth: Style.space(880)
  // The bar's screen (Quickshell's, for the overlay), found by the name of
  // the bar window's screen.
  readonly property var barScreen: {
    var name = button.Screen.name
    for (const screen of Quickshell.screens)
      if (screen.name === name)
        return screen
    return null
  }
  // This bar's screen width (tests replace it).
  property real screenWidth: barScreen ? barScreen.width : 0
  function fitsLarge(width) {
    return width >= root.largeWidth + FoamyStyle.padding * 4
  }
  readonly property bool wideFits: !button.Window.window || button.Window.window.width >= FoamyStyle.popupWidthWide + FoamyStyle.padding * 2
  // What a click on this bar opens: "large" (the overlay), "wide" or "standard".
  readonly property string size: sizeSetting === "large" && fitsLarge(screenWidth) ? "large" : (sizeSetting === "wide" || sizeSetting === "large") && wideFits ? "wide" : "standard"
  // The popup is never Large: where Large can't be, it is Wide.
  readonly property bool wide: size !== "standard"
  // Another size: the overlay goes (its view falls back from the Week view itself).
  onSizeSettingChanged: if (sizeSetting !== "large" && TodoStore.overlayOpen)
    TodoStore.hideOverlay()

  // A click on the bar: the overlay (Large) or the popup.
  function togglePanel() {
    if (root.size === "large") {
      if (root.opened)
        root.close()
      TodoStore.toggleOverlay(root.barScreen)
    } else {
      if (TodoStore.overlayOpen)
        TodoStore.hideOverlay()
      root.toggle()
    }
  }

  // The next open puts the caret in the add field whatever the setting says (IPC `add`).
  property bool addOnOpen: false
  function openToAdd() {
    if (root.opened) {
      const view = panelPopup.ensureBody()
      if (view)
        view.openAdd()
      return
    }
    addOnOpen = true
    root.open()
  }
  FoamySettingsState {
    id: settingsState
    panel: root
  }
  function openSettings() {
    if (root.size === "large")
      TodoStore.showOverlay(root.barScreen, "settings")
    else
      settingsState.show()
  }
  // IPC (the leader): Large opens on the focused monitor.
  FoamyIpc {
    enabled: member.isLeader
    target: "foamy.todoist"
    function toggle(): void {
      if (root.sizeSetting === "large" && !root.opened)
        TodoStore.toggleOverlay(null)
      else
        root.toggle()
    }
    function add(): void {
      if (root.sizeSetting !== "large" || root.opened)
        root.openToAdd()
      else if (TodoStore.overlayOpen && root.overlay.item)
        (root.overlay.item as TodoOverlay).view.openAdd()
      else
        TodoStore.showOverlay(null, "add")
    }
    function refresh(): void {
      TodoStore.sync()
    }
  }

  // ---- the Large overlay (the leader's) -----------------------------------------
  // It exists only while open. It stays one more turn after closing, so its
  // view's closed() (the draft, the completions, the editor's field) runs first.
  property bool overlayLive: false
  Connections {
    target: TodoStore
    function onOverlayOpenChanged() {
      if (TodoStore.overlayOpen)
        root.overlayLive = true
      else
        Qt.callLater(function () {
          root.overlayLive = TodoStore.overlayOpen
        })
    }
  }
  readonly property alias overlay: overlayLoader
  LazyLoader {
    id: overlayLoader
    active: member.isLeader && (TodoStore.overlayOpen || root.overlayLive)
    TodoOverlay {
      wantedScreen: TodoStore.overlayScreen
      cardWidth: root.largeWidth
      open: TodoStore.overlayOpen
      preferences: prefsQueue.effectiveSettings
      saving: prefsQueue.busy
      settingsError: prefsQueue.error !== "" ? FoamyI18n.t(prefsQueue.error) : ""
      retryable: prefsQueue.canRetry
      onCloseRequested: TodoStore.hideOverlay()
      // The focused monitor (IPC) has no room: Wide in this bar's popup.
      onTooNarrow: {
        const page = TodoStore.overlayPage
        TodoStore.hideOverlay()
        if (page === "settings")
          settingsState.show()
        else if (page === "add")
          root.openToAdd()
        else
          root.open()
      }
      onSaveRequested: function (key, value) {
        prefsQueue.save(key, value)
      }
      onRetryRequested: prefsQueue.retry()
    }
  }

  // The mark alone when nothing is left today: no "0".
  readonly property bool showCount: TodoStore.signedIn && TodoStore.loaded && TodoStore.counts.today > 0 && prefsQueue.value("barCount") === "today" && !(root.bar && root.bar.vertical)
  Ui.WidgetButton {
    id: button
    objectName: "todoistButton"
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.bar && root.bar.vertical ? -1 : Math.max(Style.bar.iconSlot, barContent.implicitWidth + Style.bar.iconSlot - Style.bar.iconCanvas)
    tooltipText: !TodoStore.signedIn ? FoamyI18n.t("Todoist: not signed in") : !TodoStore.loaded ? "Todoist" : FoamyI18n.t("Todoist: %1, %2", [FoamyI18n.tn("%1 left today", TodoStore.counts.today), FoamyI18n.tn("%1 overdue", TodoStore.counts.overdue)])
    onPressed: function (pressedButton) {
      if (pressedButton === Qt.RightButton)
        root.openSettings()
      else
        root.togglePanel()
    }
    Row {
      id: barContent
      readonly property alias countLabel: countLabel
      anchors.centerIn: parent
      spacing: Style.space(1)
      Item {
        width: Style.bar.iconCanvas
        height: width
        FoamyIcon {
          anchors.centerIn: parent
          name: "todoist"
          width: Style.bar.iconSize
          height: width
          color: button.foreground
        }
      }
      // One number, as foamy-zendesk's bar: the tasks left today (the
      // overdue count is in the tooltip).
      PlainText {
        id: countLabel
        visible: root.showCount
        anchors.verticalCenter: parent.verticalCenter
        text: FoamyI18n.number(TodoStore.counts.today)
        wrapMode: Text.NoWrap
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        color: root.bar ? root.bar.urgent : Commons.Color.urgent
      }
    }
  }
  FoamyPopup {
    id: panelPopup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    wide: root.wide
    body: Component {
      TodoView {
        active: root.opened
        size: root.wide ? "wide" : "standard"
        preferences: prefsQueue.effectiveSettings
        saving: prefsQueue.busy
        settingsError: prefsQueue.error !== "" ? FoamyI18n.t(prefsQueue.error) : ""
        retryable: prefsQueue.canRetry
        addOnOpen: root.addOnOpen
        editingSettings: settingsState.editing
        onSettingsRequested: settingsState.show()
        onSettingsClosed: settingsState.hide()
        onAddOnOpenUsed: root.addOnOpen = false
        onCloseView: root.close()
        onSwitchPanel: function (direction) {
          root.switchPanel(direction)
        }
        onSaveRequested: function (key, value) {
          prefsQueue.save(key, value)
        }
        onRetryRequested: prefsQueue.retry()
      }
    }
  }
}
