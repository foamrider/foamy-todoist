pragma ComponentBehavior: Bound
import QtQuick
import QtTest
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
  property var previewStates: ["today", "add-empty", "add-open", "add-error", "add-error-refused", "suggest-projects", "suggest-labels", "suggest-sections", "suggest-people", "footer-error", "inbox", "upcoming", "search", "search-none", "completed", "row-cursor", "row-moved", "date-menu", "editor", "editor-date-open", "editor-error", "editor-section-cursor", "editor-place-menu", "editor-completed", "wide", "wide-add-open", "wide-suggest", "wide-inbox", "wide-project", "wide-upcoming", "wide-search", "wide-crowded", "wide-rail", "wide-long-label", "wide-today-done", "wide-inbox-empty", "wide-task", "wide-task-place-error", "wide-task-completed", "wide-task-sent", "wide-task-unconfirmed", "wide-task-long-place", "wide-long-heading", "wide-week", "wide-week-pane", "wide-week-unconfirmed", "wide-settings", "truncated", "unconfirmed", "error", "empty", "loading", "signed-out", "settings", "settings-open-command", "settings-sign-out", "settings-signed-out"]
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
    // Each state is a fresh opening: Wide holds its tallest height only
    // while it is open, and the renderer keeps one view for every state.
    view.heldBodyHeight = 0
    var signedIn = previewState !== "signed-out" && previewState !== "settings-signed-out"
    var data = ["loading", "signed-out", "settings-signed-out"].indexOf(previewState) >= 0 ? null : sample()
    // Nothing left today (the overview shows tomorrow); an empty Inbox.
    if (previewState === "empty" || previewState === "wide-today-done")
      data.tasks = data.tasks.filter(function (task) {
        return task.due === null || task.due.date.slice(0, 10) > Model.dayKey(new Date())
      })
    if (previewState === "wide-inbox-empty")
      data.tasks = data.tasks.filter(function (task) {
        return task.project_id !== data.user.inbox_project_id
      })
    if (previewState === "truncated")
      data.truncated = true
    // A place too long for the pane's header (its task unconfirmed: the
    // sync icon beside it).
    if (previewState === "wide-task-long-place") {
      data.projects = data.projects.map(function (project) {
        return project.id === "work" ? Object.assign({}, project, {
          name: "Work for the quarterly planning group"
        }) : project
      })
      data.sections = data.sections.map(function (section) {
        return section.id === "s-review" ? Object.assign({}, section, {
          name: "Reviews waiting for the release"
        }) : section
      })
    }
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
      // Deadlines: one today, more than the part shows ("+N more").
      const deadlines = [["dl0", "File the expense report", 0], ["dl1", "Send the slides to the board", 1], ["dl2", "Renew the domain", 5], ["dl3", "Book the venue", 6]]
      deadlines.forEach(function (item) {
        data.tasks.push(Fixtures.task(item[0], item[1], "work", {
          deadline: Fixtures.shift(Model.dayKey(new Date()), item[2])
        }))
      })
    }
    // A section name too long for its heading row (it ends with "…").
    if (previewState === "wide-long-heading")
      data.sections = data.sections.map(function (section) {
        return section.id === "s-review" ? Object.assign({}, section, {
          name: "Review everything the release needs before Friday's launch meeting"
        }) : section
      })
    // Wide's suggestions for "#ho": six projects, one name longer than
    // the menu's 320.
    if (previewState === "wide-suggest")
      ["Hobby projects", "Holiday in the mountains with the whole family", "Home renovation and garden planning for the spring of 2027", "Horse riding lessons", "Hosting"].forEach(function (name, i) {
        data.projects.push({
          id: "ho" + i,
          name: name,
          color: ["blue", "orange", "red", "green", "yellow"][i],
          parent_id: null,
          child_order: 10 + i,
          inbox: false
        })
      })
    // A rail with 26 projects, many named past its width: the views stay,
    // "My projects" scrolls; the pointer on a cut name shows it whole.
    if (previewState === "wide-rail")
      for (let i = 0; i < 22; i++)
        data.projects.push({
          id: "r" + i,
          name: ["Platform team: quarterly planning", "Incident reviews and follow-ups", "Customer onboarding", "Kitchen renovation", "Electrician and plumbing quotes", "Family calendar and school events", "Taxes and insurance papers", "Someday / maybe"][i % 8] + (i >= 8 ? " " + (i - 7) : ""),
          color: ["blue", "orange", "red", "green", "yellow", "grape", "charcoal", "blue"][i % 8],
          parent_id: i % 3 === 1 ? "work" : null,
          child_order: 10 + i,
          inbox: false
        })
    if (previewState === "wide-long-label")
      data.tasks.push(Fixtures.task("long", "Plan the move", "inbox", {
        labels: ["waiting-for-the-landlord-to-confirm-the-moving-date-in-march"]
      }))
    store.loadFixture(data, signedIn)
    store.fixtureDescriptions = Fixtures.descriptions
    // The fixtures assign one task to someone else: show it, as an example.
    store.othersTasks = "show"
    // A completion whose outcome is unknown: the list's row, a Week card, the pane.
    if (previewState === "unconfirmed" || previewState === "wide-week-unconfirmed" || previewState === "wide-task-unconfirmed" || previewState === "wide-task-long-place")
      store.unconfirmed = {
        "t4": true
      }
    // Its completion sent, the reply not in yet.
    if (previewState === "wide-task-sent")
      store.sending = {
        "t4": true
      }
    view.editingSettings = previewState.indexOf("settings") >= 0
    view.preferences = previewState === "settings-open-command" ? {
      openCommand: "omarchy-launch-or-focus-webapp Todoist {url}"
    } : ({})
    store.launchError = previewState === "footer-error" ? FoamyI18n.t("Can't open Todoist") : ""
    view.prepare()
    var next = previewState === "inbox" || previewState === "wide-inbox" || previewState === "wide-long-label" || previewState === "wide-inbox-empty" ? "inbox" : previewState === "upcoming" || previewState === "wide-upcoming" ? "upcoming" : previewState === "wide-project" || previewState === "wide-long-heading" ? "project" : previewState.indexOf("wide-week") === 0 ? "week" : "today"
    view.setView(next, "work")
    if (previewState === "error")
      store.error = FoamyI18n.t("Can't reach Todoist. Check your connection.")
    // Search: results with their matches bold; no match, with Add as a task.
    if (previewState === "search" || previewState === "wide-search" || previewState === "search-none")
      Qt.callLater(function () {
        view.startSearch()
        view.field.text = previewState === "search-none" ? "xyz" : "the"
        view.query = view.field.text
      })
    // The band's field, its Quick Add tokens in colour, the keys in the footer.
    if (previewState === "add-open" || previewState === "wide-add-open")
      Qt.callLater(function () {
        view.openAdd()
        view.field.text = "Call the plumber tomorrow #Home p1 @calls"
      })
    // The empty add field: Quick Add's forms in the footer.
    if (previewState === "add-empty")
      Qt.callLater(function () {
        view.openAdd()
      })
    // A failed add at the field: Quick Add sent, no answer (the task may
    // exist: yellow); refused, safe to send again (red, Enter retries).
    if (previewState === "add-error" || previewState === "add-error-refused")
      Qt.callLater(function () {
        view.openAdd()
        view.field.text = "Call the plumber tomorrow #Home"
        store.addErrorKind = previewState === "add-error" ? "unknown" : "refused"
        store.addError = previewState === "add-error" ? FoamyI18n.t("Todoist didn't answer. The task may have been added: check the list before adding it again.") : FoamyI18n.t("Todoist is limiting requests. Try again in %1 seconds.", [FoamyI18n.number(42)])
      })
    if (previewState.indexOf("suggest-") === 0 || previewState === "wide-suggest")
      Qt.callLater(function () {
        view.openAdd()
        view.field.text = ({
            "suggest-projects": "Call the plumber #h",
            "suggest-labels": "Pay the rent @",
            "suggest-sections": "Review the release notes #Work /",
            "suggest-people": "Plan the launch #Launch +",
            "wide-suggest": "Plan the summer #ho"
          })[previewState]
        view.field.cursorPosition = view.field.text.length
        view.field.textEdited()
      })
    // Sign out's question, with a completion still in its undo window.
    if (previewState === "completed" || previewState === "editor-completed" || previewState === "wide-task-completed" || previewState === "settings-sign-out")
      store.complete("t4")
    if (previewState === "settings-sign-out")
      Qt.callLater(function () {
        view.settingsPage.askSignOut()
      })
    if (previewState === "row-cursor" || previewState === "completed")
      Qt.callLater(function () {
        view.goTo(view.firstRowStop + 2)
      })
    // A move waiting for its undo window; the menu of days on the cursor row.
    if (previewState === "row-moved")
      store.move("t4", Model.addDays(store.today, 1))
    if (previewState === "row-moved" || previewState === "date-menu")
      Qt.callLater(function () {
        view.goTo(view.firstRowStop + 3)
        if (previewState === "date-menu")
          Qt.callLater(function () {
            view.openDateMenu(view.cursorRow().id, null, true)
          })
      })
    // The editor: the page (Small), the pane (Wide); the Date field open,
    // a refused save under the date, the keys on the empty Deadline section
    // (its fill as on hover, and the keys' ring; the renderer can't hover);
    // the move menu open under the band's place (the Project control).
    // A completed task, its Undo time running: the page (Small) and the
    // pane (Wide) show it completed, with Undo; sent, without; unconfirmed,
    // a plain ring and "Checking with Todoist…" (the sync icon in the
    // pane's header, where the words don't fit whole; also with a long
    // place).
    if (previewState === "editor-completed" || previewState === "wide-task-completed" || previewState === "wide-task-sent" || previewState === "wide-task-unconfirmed" || previewState === "wide-task-long-place")
      Qt.callLater(function () {
        view.openTask("t4", false)
      })
    if (previewState === "editor" || previewState === "editor-error" || previewState === "editor-date-open" || previewState === "editor-section-cursor" || previewState === "editor-place-menu")
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
        if (previewState === "editor-place-menu")
          Qt.callLater(function () {
            view.editor.openPlaceMenu(false)
          })
      })
    // Wide: a task in the pane (the full width), also with a move Todoist
    // refused under the pane's header; the Week view (always full).
    if (previewState === "wide-task" || previewState === "wide-task-place-error")
      Qt.callLater(function () {
        view.goTo(view.firstRowStop)
        if (previewState === "wide-task-place-error")
          Qt.callLater(function () {
            view.editor.setError("place", FoamyI18n.t("Todoist answered HTTP %1.", ["500"]))
          })
      })
    if (previewState === "wide-rail")
      Qt.callLater(function () {
        // The renderer can't hover: a pointer move onto the first cut name
        // (its row lit; the tooltip draws in the window's overlay, which
        // the renderer's pictures leave out).
        Qt.callLater(function () {
          var name = preview.firstCut(view)
          if (name)
            pointer.mouseMove(name, name.width / 2, name.height / 2, -1, Qt.NoButton, Qt.NoModifier)
        })
      })
    if (previewState.indexOf("wide-week") === 0)
      Qt.callLater(function () {
        view.goTo(view.firstRowStop)
        view.weekMove(1, 0)
        if (previewState === "wide-week-pane")
          view.openTask(view.cursorRow().id, false)
      })
  }
  // The rail's first project name cut with "…" (the tooltip's case).
  function firstCut(item) {
    if (item.objectName === "railText" && item.visible && item.truncated)
      return item
    for (let i = 0; i < item.children.length; i++) {
      const found = firstCut(item.children[i])
      if (found)
        return found
    }
    return null
  }
  TestEvent {
    id: pointer
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
    maxHeight: Math.round(previewPopup.screenH * 0.7)
    body: Component {
      Plugin.TodoView {
        size: preview.wide ? "wide" : "standard"
        onSettingsRequested: editingSettings = true
        onSettingsClosed: editingSettings = false
      }
    }
  }
}
