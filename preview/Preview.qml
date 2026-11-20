pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons as Commons
import "../kit"
import ".." as Plugin
import "../Model.js" as Model
import "Fixtures.js" as Fixtures

// Offscreen previews (foamy-kit preview/render.py): sample data, no helper.
// Every size is the popup under the bar button, as Panel.qml sizes it.
Item {
  id: preview
  required property QtObject bar
  required property Item anchorItem
  property var previewStates: ["today", "add-open", "add-error", "suggest-projects", "suggest-labels", "suggest-sections", "suggest-people", "footer-error", "inbox", "upcoming", "search", "completed", "row-cursor", "editor", "editor-error", "wide", "wide-add-open", "wide-project", "wide-upcoming", "wide-editor", "large", "large-week", "large-week-pane", "truncated", "unconfirmed", "error", "empty", "loading", "signed-out", "settings", "settings-open-command", "settings-signed-out"]
  property string previewState: "today"
  readonly property bool large: previewState.indexOf("large") === 0
  readonly property bool wide: previewState.indexOf("wide") === 0
  readonly property var popup: previewPopup

  function sample() {
    var reply = Fixtures.snapshot(Model.dayKey(new Date()))
    reply.tasks = reply.tasks.concat(Fixtures.upcomingExtras(Model.dayKey(new Date())))
    reply.synced_at = new Date(Date.now() - 4 * 60000).toISOString()
    reply.ok = true
    return reply
  }
  function applyState() {
    var store = Plugin.TodoStore
    var view = previewPopup.ensureBody()
    if (!view)
      return
    var signedIn = previewState !== "signed-out" && previewState !== "settings-signed-out"
    var data = ["loading", "signed-out", "settings-signed-out"].indexOf(previewState) >= 0 ? null : sample()
    if (previewState === "empty")
      data.tasks = data.tasks.filter(function (task) {
        return task.due === null || task.due.date.slice(0, 10) > Model.dayKey(new Date())
      })
    if (previewState === "truncated")
      data.truncated = true
    store.loadFixture(data, signedIn)
    store.fixtureDescriptions = Fixtures.descriptions
    // The fixtures assign one task to someone else: show it, as an example.
    store.othersTasks = "show"
    if (previewState === "unconfirmed")
      store.unconfirmed = {
        "t4": true
      }
    view.editingSettings = previewState.indexOf("settings") === 0
    view.preferences = previewState === "settings-open-command" ? {
      openCommand: "omarchy-launch-or-focus-webapp Todoist {url}"
    } : ({})
    store.launchError = previewState === "footer-error" ? FoamyI18n.t("Can't open Todoist") : ""
    view.prepare()
    var next = previewState === "inbox" ? "inbox" : previewState === "upcoming" || previewState === "wide-upcoming" ? "upcoming" : previewState === "wide-project" ? "project" : previewState.indexOf("large-week") === 0 ? "week" : "today"
    view.setView(next, "work")
    if (previewState === "error")
      store.error = FoamyI18n.t("Can't reach Todoist. Check your connection.")
    if (previewState === "search")
      Qt.callLater(function () {
        view.startSearch()
        view.field.text = "the"
        view.query = "the"
      })
    // The band's field, its Quick Add tokens in colour, the keys in the footer.
    if (previewState === "add-open" || previewState === "wide-add-open")
      Qt.callLater(function () {
        view.openAdd()
        view.field.text = "Call the plumber tomorrow #Home p1 @calls"
      })
    // Quick Add sent, no answer: the whole warning under the band.
    if (previewState === "add-error")
      Qt.callLater(function () {
        view.openAdd()
        view.field.text = "Call the plumber tomorrow #Home"
        store.addError = FoamyI18n.t("Todoist didn't answer. The task may have been added: check the list before adding it again.")
      })
    if (previewState.indexOf("suggest-") === 0)
      Qt.callLater(function () {
        view.openAdd()
        view.field.text = ({
            "suggest-projects": "Call the plumber #h",
            "suggest-labels": "Pay the rent @",
            "suggest-sections": "Review the release notes #Work /",
            "suggest-people": "Plan the launch #Launch +"
          })[previewState]
        view.field.cursorPosition = view.field.text.length
        view.field.textEdited()
      })
    if (previewState === "completed")
      store.complete("t4")
    if (previewState === "row-cursor" || previewState === "completed")
      Qt.callLater(function () {
        view.goTo(view.firstRowStop + 2)
      })
    // The editor: the page (Small, Wide), the pane (Large).
    if (previewState === "editor" || previewState === "wide-editor" || previewState === "editor-error")
      Qt.callLater(function () {
        view.openTask(previewState === "wide-editor" ? "t1" : "t4", false)
        if (previewState === "editor-error")
          Qt.callLater(function () {
            view.editor.setError("due", FoamyI18n.t("Todoist answered HTTP %1.", ["500"]))
          })
      })
    if (previewState === "large")
      Qt.callLater(function () {
        view.goTo(view.firstRowStop)
      })
    if (previewState.indexOf("large-week") === 0)
      Qt.callLater(function () {
        view.goTo(view.firstRowStop)
        view.weekMove(1, 0)
        if (previewState === "large-week-pane")
          view.openTask(view.cursorRow().id, false)
      })
  }
  onPreviewStateChanged: Qt.callLater(applyState)
  Component.onCompleted: {
    Plugin.TodoStore.fixtures = true
    Qt.callLater(applyState)
  }
  FoamyPopup {
    id: previewPopup
    anchorItem: preview.anchorItem
    bar: preview.bar
    open: true
    contentWidth: previewPopup.fittedContentWidth(preview.large ? Commons.Style.space(880) : preview.wide ? FoamyStyle.popupWidthWide : FoamyStyle.popupWidth)
    maxHeight: preview.large ? Math.round(previewPopup.screenH * 0.7) : 0
    body: Component {
      Plugin.TodoView {
        size: preview.large ? "large" : preview.wide ? "wide" : "standard"
        onSettingsRequested: editingSettings = true
        onSettingsClosed: editingSettings = false
      }
    }
  }
}
