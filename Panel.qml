pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "kit"
import "Preferences.js" as Schema

// One bar instance (4.5 draws one per monitor). Todoist lives in the
// TodoStore singleton; every instance pushes the saved settings into it,
// the leader owns the IPC target, and any instance can save settings.
//
// Sizes: both are this bar's popup under the Todoist button. Small is 420
// with tabs. Wide (the rail and the list) is `narrowWidth` while no task is
// selected, and grows to `fullWidth` (880) while the details pane shows a
// task or the Week view shows; it is capped at 70% of the screen's height
// and its settings page is 560. The width change animates (FoamyMotion.grow,
// instant under reduced motion). Where the popup has no room for Wide's
// narrow width on this bar's screen, Small.
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
    // A saved "large" reads as "wide" (the next save of a setting writes it so).
    settings: Schema.current(root.settings)
  }
  FoamyMember {
    id: member
    scope: "todoist"
    demanding: root.opened
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
  Component.onCompleted: {
    pushSettings()
    shownWidth = cardWidth
  }

  // The size setting, and what the popup has room for on this bar's
  // screen (the host's width there: the screen minus its margins).
  readonly property string sizeSetting: prefsQueue.value("panelWidth")
  readonly property int fullWidth: Style.space(880)
  // Wide without the pane: the full width less the pane (TodoView's
  // paneWidth) and its divider, so the list keeps its width, and its rows
  // their layout, when the pane opens or closes.
  readonly property int narrowWidth: fullWidth - Style.space(270) - FoamyStyle.borderWidth
  readonly property real room: panelPopup.availableCardWidth
  // What a click on this bar opens: "wide" or "standard".
  readonly property string size: sizeSetting === "wide" && room >= narrowWidth ? "wide" : "standard"
  readonly property bool wide: size === "wide"
  // The card's width: Small's, the settings page's, or Wide's narrow or
  // full width (the view asks for it: TodoView.fullWidth), never wider than
  // the popup's room (the host clamps it and keeps it under the button).
  readonly property TodoView view: panelPopup.bodyItem as TodoView
  readonly property bool full: wide && view !== null && view.fullWidth
  readonly property int cardWidth: panelPopup.fittedContentWidth(!wide ? FoamyStyle.popupWidth : settingsState.editing ? FoamyStyle.popupWidthWide : full ? fullWidth : narrowWidth)
  // The width drawn: it follows cardWidth while the popup is open (animated
  // once the card has settled after opening, KeyboardPanel.heightLive;
  // FoamyMotion.grow is 0 under reduced motion, so the change is instant)
  // and is held while the card fades out, so it never changes width as it
  // goes. The host keeps the card centred under the button (clamped to the
  // screen's margins), so its leading edge moves as it grows: by half the
  // change, by all of it against the screen's right edge, not at all
  // against its left. The view inside doesn't move or reflow
  // (TodoView.layoutWidth): the rows slide with the card.
  property real shownWidth: 0
  Behavior on shownWidth {
    enabled: root.opened && panelPopup.heightLive
    NumberAnimation {
      duration: FoamyMotion.grow
      easing.type: Easing.Bezier
      easing.bezierCurve: FoamyMotion.easeOut
    }
  }
  onCardWidthChanged: if (root.opened || !panelPopup.visible)
    shownWidth = cardWidth
  onOpenedChanged: if (root.opened)
    shownWidth = cardWidth

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
  // IPC (the leader's popup).
  FoamyIpc {
    enabled: member.isLeader
    target: "foamy.todoist"
    function toggle(): void {
      root.toggle()
    }
    function add(): void {
      root.openToAdd()
    }
    function refresh(): void {
      TodoStore.sync()
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
        settingsState.show()
      else
        root.toggle()
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
    contentWidth: Math.round(root.shownWidth)
    maxHeight: root.wide ? Math.round(panelPopup.screenH * 0.7) : 0
    body: Component {
      TodoView {
        active: root.opened
        shown: panelPopup.visible
        size: root.size
        // How much wider (or narrower) the card is still going (none while
        // it fades out at the width it had).
        widthAhead: root.opened ? root.cardWidth - panelPopup.contentWidth : 0
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
