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
  property var previewStates: ["today", "add-open", "add-error", "suggest-projects", "suggest-labels", "suggest-sections", "suggest-people", "footer-error", "inbox", "upcoming", "search", "completed", "row-cursor", "editor", "editor-date-open", "editor-error", "editor-section-cursor", "wide", "wide-add-open", "wide-inbox", "wide-project", "wide-upcoming", "wide-search", "wide-crowded", "wide-long-label", "wide-task", "wide-week", "wide-week-pane", "wide-settings", "truncated", "unconfirmed", "error", "empty", "loading", "signed-out", "settings", "settings-open-command", "settings-signed-out"]
  property string previewState: "today"
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
    // 11:50 today: Today's overview has a task ahead ("Next") and a past
    // one, and the "now" line inside its timeline.
    store.now = function () {
      var now = new Date()
      now.setHours(11, 50, 0, 0)
      return now
    }
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
    // Today's timeline crowded at 10:00 (three lanes, the rest summed up)
    // and a task at 23:59; the Inbox with a label as long as Todoist allows.
    if (previewState === "wide-crowded") {
      for (let i = 0; i < 20; i++)
        data.tasks.push(Fixtures.task("c" + i, "Crowd " + i, "home", {
          due: Fixtures.due(Model.dayKey(new Date()) + "T10:00:00")
        }))
      data.tasks.push(Fixtures.task("late", "Last call", "home", {
        due: Fixtures.due(Model.dayKey(new Date()) + "T23:59:00")
      }))
    }
    if (previewState === "wide-long-label")
      data.tasks.push(Fixtures.task("long", "Plan the move", "inbox", {
        labels: ["waiting-for-the-landlord-to-confirm-the-moving-date-in-march"]
      }))
    store.loadFixture(data, signedIn)
    store.fixtureDescriptions = Fixtures.descriptions
    // The fixtures assign one task to someone else: show it, as an example.
    store.othersTasks = "show"
    if (previewState === "unconfirmed")
      store.unconfirmed = {
        "t4": true
      }
    view.editingSettings = previewState.indexOf("settings") >= 0
    view.preferences = previewState === "settings-open-command" ? {
      openCommand: "omarchy-launch-or-focus-webapp Todoist {url}"
    } : ({})
    store.launchError = previewState === "footer-error" ? FoamyI18n.t("Can't open Todoist") : ""
    view.prepare()
    var next = previewState === "inbox" || previewState === "wide-inbox" || previewState === "wide-long-label" ? "inbox" : previewState === "upcoming" || previewState === "wide-upcoming" ? "upcoming" : previewState === "wide-project" ? "project" : previewState.indexOf("wide-week") === 0 ? "week" : "today"
    view.setView(next, "work")
    if (previewState === "error")
      store.error = FoamyI18n.t("Can't reach Todoist. Check your connection.")
    if (previewState === "search" || previewState === "wide-search")
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
    // The editor: the page (Small), the pane (Wide); the Date field open,
    // a refused save under the date, the keys on the empty Deadline section
    // (its fill as on hover, and the keys' ring; the renderer can't hover).
    if (previewState === "editor" || previewState === "editor-error" || previewState === "editor-date-open" || previewState === "editor-section-cursor")
      Qt.callLater(function () {
        view.openTask("t4", false)
        if (previewState === "editor-error")
          Qt.callLater(function () {
            view.editor.setError("due", FoamyI18n.t("Todoist answered HTTP %1.", ["500"]))
          })
        if (previewState === "editor-date-open")
          Qt.callLater(function () {
            view.editor.openField("due")
          })
        if (previewState === "editor-section-cursor")
          Qt.callLater(function () {
            view.editor.closeField("deadline", true)
          })
      })
    // Wide: a task in the pane (the full width); the Week view (always full).
    if (previewState === "wide-task")
      Qt.callLater(function () {
        view.goTo(view.firstRowStop)
      })
    if (previewState.indexOf("wide-week") === 0)
      Qt.callLater(function () {
        view.goTo(view.firstRowStop)
        view.weekMove(1, 0)
        if (previewState === "wide-week-pane")
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
    // As Panel.qml: Wide is always 880.
    contentWidth: previewPopup.fittedContentWidth(preview.wide ? Commons.Style.space(880) : FoamyStyle.popupWidth)
    maxHeight: preview.wide ? Math.round(previewPopup.screenH * 0.7) : 0
    body: Component {
      Plugin.TodoView {
        size: preview.wide ? "wide" : "standard"
        onSettingsRequested: editingSettings = true
        onSettingsClosed: editingSettings = false
      }
    }
  }
}
