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
  Component.onCompleted: pushSettings()

  // Wide only where the screen has room for it (the bar window spans the screen).
  readonly property bool wide: prefsQueue.value("panelWidth") === "wide" && (!button.Window.window || button.Window.window.width >= FoamyStyle.popupWidthWide + FoamyStyle.padding * 2)

  // The next open puts the caret in the add field whatever the setting says (IPC `add`).
  property bool addOnOpen: false
  function openToAdd() {
    if (root.opened) {
      const view = panelPopup.ensureBody()
      if (view)
        view.openField()
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
    settingsState.show()
  }
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
    function openTask(id: string): void {
      TodoStore.openTask(id)
    }
    function openInbox(): void {
      TodoStore.openView("inbox", "")
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
    wide: root.wide
    body: Component {
      TodoView {
        active: root.opened
        wide: root.wide
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
