pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Preferences.js" as Schema
import "Model.js" as Model

// The panel, in both sizes: the band (the title row; + and Search grow
// the band's field), the tab row (Small) or the rail (Wide), the list, the
// footer, and the settings page in place of all of it. Small opens a task
// on the editor page in place of the list; Wide shows it in the details
// pane beside the list, and has the Week view. Wide's card is as wide as
// the rail and the list until a task is in the pane or the Week view shows
// (`fullWidth`; Panel.qml sizes the card).
//
// The band field: + (or `a`) and Search (or `/`) open it, growing from
// their button over the title row. Adding, it colours the Quick Add tokens
// and the footer shows the keys; Enter adds and does what "After adding a
// task" says (close the panel, or keep the field open), Shift+Enter the
// other. Esc clears the text, then closes the field. An empty field closes
// when it loses the keys; one with text stays open.
//
// One cursor (FoamyCursor) over the stops, in on-screen order: +, Search
// (Open, while the Wide pane shows a task), ⋯ (the band's, while its
// field is closed), the tabs or the rail, each list row that does something
// (the Week view's grid is one stop), the footer's Todoist button and
// Refresh. Nothing has the cursor on open. While a field, the editor or a
// menu has the keys the key catcher is blocked.
//
// A click on the list's space that isn't a row clears the selection
// (clearSelection); a click on any empty space takes the keys from a text
// field and gives them to `keyFocus` (the kit's click-away, `foamyKeyHome`).
PanelKeyCatcher {
  id: root
  property bool active: true
  // The popup still draws this view (it fades out after `active` goes).
  // The popup keeps its body while closed: the lists are built only while
  // the view is open or still on screen, never for a sync behind a closed
  // popup.
  property bool shown: false
  readonly property bool live: active || shown
  // "standard" (Small) or "wide" (Panel.qml decides when the screen has
  // room).
  property string size: "standard"
  readonly property bool wide: size === "wide"
  // Wide: the card's full width while the pane shows a task or the Week
  // view shows; else the rail and the list.
  readonly property bool fullWidth: wide && !editingSettings && (paneShown || weekShown)
  // How much wider (negative: narrower) the card is still going while its
  // width animates (Panel.qml). The body is laid out at the width to come
  // (`layoutWidth`), so the rows never reflow as it moves: a growing card
  // uncovers the pane, a shrinking one closes over empty space.
  property real widthAhead: 0
  readonly property real layoutWidth: width + widthAhead
  clip: width < layoutWidth - 0.5
  property bool editingSettings: false
  property bool addOnOpen: false
  property var preferences: ({})
  property bool saving: false
  property string settingsError: ""
  property bool retryable: false
  signal addOnOpenUsed
  signal closeView
  signal switchPanel(int direction)
  signal settingsRequested
  signal settingsClosed
  signal saveRequested(string key, var value)
  signal retryRequested
  function pref(key) {
    return Prefs.value(Schema.fields, preferences, key)
  }

  readonly property alias cursor: viewCursor
  readonly property alias band: heroBand
  readonly property alias list: taskList
  readonly property alias field: addField
  readonly property alias footer: panelFooter
  readonly property alias settingsPage: settingsView
  readonly property alias editor: taskEditor
  readonly property alias week: weekView

  // The keys go to this item when nothing else has them (the catcher
  // sees what it leaves); it takes the chords the catcher can't tell
  // apart: Ctrl+O, and Ctrl+←/→ in the Week view.
  focus: false
  Item {
    id: keyFocus
    focus: true
    Keys.onPressed: function (event) {
      root.chordKey(event)
    }
  }
  function focusList() {
    keyFocus.forceActiveFocus()
  }
  // Where a click on empty space leaves the keys it takes from a field
  // (FoamyClickAway): the list's, as focusList() does. The editor page and
  // the settings page keep them instead.
  readonly property Item foamyKeyHome: keyFocus
  function chordKey(event) {
    if (!(event.modifiers & Qt.ControlModifier) || root.blocked)
      return
    var row = cursorRow()
    if (event.key === Qt.Key_O) {
      if (row && row.kind === "task")
        store.openView("task", row.id)
      event.accepted = true
    } else if ((event.key === Qt.Key_Left || event.key === Qt.Key_Right) && weekShown && on(firstRowStop)) {
      const later = (event.key === Qt.Key_Right) !== LayoutMirroring.enabled
      if (row)
        store.shiftDue(row.id, later ? 1 : -1)
      event.accepted = true
    }
  }

  // ---- the view ---------------------------------------------------------------------
  // inbox, today, upcoming, project or week (Wide).
  property string view: "today"
  property string projectId: ""
  property bool searching: false
  property string query: ""
  property bool overdueOpen: false
  // Upcoming's default date: the day of the group the cursor was in last.
  property string upcomingDay: ""
  readonly property string listView: searching ? "search" : view
  readonly property bool weekShown: view === "week" && !searching
  readonly property var store: TodoStore
  readonly property var rows: !live || weekShown ? [] : Model.rows(store.model, listView, store.today, {
    struck: store.struck,
    hidden: store.sending,
    hideOthers: store.hideOthers,
    unconfirmed: store.unconfirmed,
    overdueOpen: overdueOpen,
    weekStart: weekStart,
    projectId: projectId,
    query: query
  })
  // The Week view's columns, only while it shows.
  readonly property var weekColumns: live && weekShown ? Model.weekColumns(store.model, store.today, {
    struck: store.struck,
    hidden: store.sending,
    hideOthers: store.hideOthers,
    unconfirmed: store.unconfirmed
  }) : []
  readonly property int weekCount: weekColumns.reduce(function (sum, column) {
    return sum + column.cards.length
  }, 0)
  // Row index → cursor stop (-1 for headers), and the rows that are stops.
  readonly property var stops: rows.reduce(function (found, row, index) {
    if (row.kind !== "header")
      found.push(index)
    return found
  }, [])
  readonly property var stopOfRow: {
    var out = rows.map(function () {
      return -1
    })
    stops.forEach(function (rowIndex, i) {
      out[rowIndex] = root.firstRowStop + i
    })
    return out
  }

  // The locale's first day of the week (0 = Sunday), for Upcoming's groups.
  readonly property int weekStart: Qt.locale(FoamyI18n.formatLocale).firstDayOfWeek
  // The locale's date formatting and the catalog, for Model's texts.
  function formatDate(date, pattern) {
    return date.toLocaleDateString(Qt.locale(FoamyI18n.formatLocale), pattern)
  }
  function translate(key, values) {
    return FoamyI18n.t(key, values)
  }
  function setView(next, project) {
    if (next === "project" && (!wide || !Model.validId(project)))
      return
    if (next === "week" && !wide)
      return
    // Search ends with the view (its query never becomes an add draft); an
    // add draft stays, whatever changed the view.
    leaveSearch()
    view = next
    projectId = next === "project" ? project : ""
    overdueOpen = false
    upcomingDay = ""
    weekPaneOpen = false
    store.addError = ""
    store.lastView = next
    store.lastProject = projectId
    taskList.positionViewAtBeginning()
    if (viewCursor.index >= firstRowStop && viewCursor.index !== refreshStop && viewCursor.index !== openStop)
      viewCursor.index = rowStops ? firstRowStop : -1
    if (weekShown)
      weekHome()
  }
  // The Week view is Wide's: Small shows Today instead.
  onWideChanged: if (!wide && view === "week")
    setView("today")
  readonly property var viewKeys: ["inbox", "today", "upcoming"]

  // ---- cursor stops ------------------------------------------------------------------
  // The band's buttons are stops only while its field is closed.
  readonly property int addStop: 0
  // Search, or Open while the Wide pane shows a task (taskInBand).
  readonly property int searchStop: 1
  readonly property int menuStop: 2
  readonly property int switchStop: wide ? -1 : 3
  readonly property int railStop: wide ? 3 : -1
  readonly property int firstRowStop: 4
  // A state's button (Open settings, Retry) is the one stop when there are
  // no rows; the Week view's grid is one stop.
  readonly property int rowStops: weekShown ? (weekCount ? 1 : 0) : stops.length ? stops.length : stateButton.visible ? 1 : 0
  // The footer: its Todoist button, then Refresh.
  readonly property int openStop: footerStops ? firstRowStop + rowStops : -1
  readonly property int refreshStop: footerStops ? openStop + 1 : -1
  readonly property bool footerStops: panelFooter.visible && !adding
  FoamyCursor {
    id: viewCursor
    count: root.firstRowStop + root.rowStops + (root.footerStops ? 2 : 0)
  }
  // The cursor is on `stop` (a stop the layout doesn't have is -1: never).
  function on(stop) {
    return stop >= 0 && viewCursor.index === stop
  }
  function usable(stop) {
    if (stop === addStop || stop === searchStop)
      return heroBand.buttonsActive && store.signedIn
    if (stop === menuStop)
      return heroBand.buttonsActive
    if (stop === switchStop)
      return views.visible
    if (stop === railStop)
      return rail.visible
    return stop >= firstRowStop && stop < viewCursor.count
  }
  // Moves along the stops, skipping hidden ones; from no cursor, an arrow
  // goes to the first row (else the tabs or the rail).
  function step(delta) {
    var at = viewCursor.index
    if (at < 0) {
      if (rowStops)
        goTo(firstRowStop)
      else if (usable(railStop))
        goTo(railStop)
      else if (usable(switchStop))
        goTo(switchStop)
      return
    }
    for (let next = at + delta; next >= 0 && next < viewCursor.count; next += delta)
      if (usable(next)) {
        goTo(next)
        return
      }
  }
  // The keys' way to a stop (hover only lights it): in Wide the details
  // pane follows the row it lands on.
  function goTo(stop) {
    if (addField.inputActiveFocus)
      focusList()
    viewCursor.index = stop
    if (stop === railStop)
      railCursor = railIndexOfView()
    if (stop === firstRowStop && weekShown && !weekCurrent())
      weekHome()
    reveal()
    followPane()
  }
  function followPane() {
    var row = cursorRow()
    if (wide && row && row.kind === "task" && (!weekShown || weekPaneOpen))
      paneTask = row.id
  }
  // A click on the list's space that isn't a row (below the last row, a
  // heading between groups, the Week view's empty column space), as in
  // Todoist: no row selected, the cursor gone, the pane closed (the card
  // back to the rail and the list's width, outside the Week view). The
  // pane's draft is saved as it lets the task go (TaskEditor.show()).
  // Clicks in the pane never reach the list.
  function clearSelection() {
    viewCursor.index = -1
    paneTask = ""
    weekPaneOpen = false
  }
  // The band's field: add or search, over the title row.
  property bool fieldOpen: false
  readonly property bool adding: fieldOpen && !searching
  readonly property bool fieldFocused: addField.inputActiveFocus
  onFieldFocusedChanged: {
    if (fieldFocused)
      viewCursor.index = -1
    else if (fieldOpen && !searching && addField.text === "")
      closeField()
  }
  // The add field, open and with the keys (search mode ends).
  function openAdd() {
    if (!store.signedIn)
      return
    if (editingTask !== "")
      closeTask()
    if (searching)
      leaveSearch()
    fieldOpen = true
    viewCursor.index = -1
    addField.focusInput()
  }
  // A click outside the field (a tab, a ring, the rail, a button) takes
  // the keys back first, so an empty field closes as it does on any blur.
  // Suggestions never call it: the field keeps the keys there.
  function leaveField() {
    if (fieldFocused)
      focusList()
  }
  // Closes the field (the band's title row comes back); the cursor goes to
  // the button it grew from when the field had the keys.
  function closeField() {
    var hadKeys = fieldFocused
    fieldOpen = false
    clearSuggest()
    addField.text = ""
    if (hadKeys) {
      viewCursor.index = addStop
      focusList()
    }
  }
  function startSearch() {
    if (!store.signedIn)
      return
    if (editingTask !== "")
      closeTask()
    if (!searching) {
      // Search takes the field: an add draft in it is kept for when the
      // search ends (and for the next open, should the popup close first).
      searchDraft = fieldOpen ? addField.text : ""
      if (searchDraft !== "")
        store.addDraft = searchDraft
      searching = true
      clearSuggest()
      addField.text = ""
      query = ""
      store.addError = ""
    }
    fieldOpen = true
    viewCursor.index = -1
    addField.focusInput()
  }
  // The add draft the field held when search started ("" for none).
  property string searchDraft: ""
  // Ends search. A draft from before it comes back (the field open, the
  // caret at its end, the keys); without one, the field closes. When the
  // popup closes (`restore` false) the field just empties.
  function leaveSearch(restore) {
    if (!searching)
      return
    var hadKeys = fieldFocused
    searching = false
    query = ""
    var draft = searchDraft
    searchDraft = ""
    if (restore === false || draft === "") {
      addField.text = ""
      if (restore !== false) {
        fieldOpen = false
        clearSuggest()
        if (hadKeys) {
          viewCursor.index = searchStop
          focusList()
        }
      }
      return
    }
    addField.text = draft
    addField.cursorPosition = draft.length
    fieldOpen = true
    viewCursor.index = -1
    addField.focusInput()
  }
  // The task row under the cursor (the Week view's card), or null.
  function cursorRow() {
    if (weekShown)
      return on(firstRowStop) ? weekCurrent() : null
    var i = viewCursor.index - firstRowStop
    return i >= 0 && i < stops.length ? rows[stops[i]] : null
  }
  function reveal() {
    if (weekShown) {
      if (on(firstRowStop))
        weekView.reveal()
      return
    }
    var i = viewCursor.index - firstRowStop
    if (i >= 0 && i < stops.length)
      taskList.positionViewAtIndex(stops[i], ListView.Contain)
  }
  // The row of a task, as the cursor's stop (-1 when it isn't listed).
  function stopOf(id) {
    for (let i = 0; i < stops.length; i++)
      if (rows[stops[i]].id === id)
        return firstRowStop + i
    return -1
  }
  // The cursor stays on its task when the rows change (a sync, a completion
  // leaving); when that task is gone, on the row that took its place.
  property string cursorKey: ""
  Connections {
    target: viewCursor
    function onIndexChanged() {
      var row = root.cursorRow()
      root.cursorKey = row && !root.weekShown ? row.key : ""
      // Upcoming's add date: the day group the cursor was last in; tomorrow
      // in the week and month groups, or with no cursor.
      if (row && row.kind === "task" && root.view === "upcoming" && !root.searching)
        root.upcomingDay = row.group === "day" ? row.dueDay : ""
      else if (viewCursor.index < 0)
        root.upcomingDay = ""
    }
  }
  onRowsChanged: {
    if (cursorKey === "")
      return
    // `stops` may not be updated yet: count the new rows' stops here.
    let stop = firstRowStop
    for (const row of rows) {
      if (row.kind === "header")
        continue
      if (row.key === cursorKey) {
        viewCursor.index = stop
        return
      }
      stop++
    }
    const last = stop - 1
    if (viewCursor.index >= firstRowStop && viewCursor.index > last)
      viewCursor.index = last >= firstRowStop ? last : -1
  }

  // ---- the Week view's cursor (Wide) -----------------------------------------------------
  // A column, and a card in it (its tasks, headings left out). It follows
  // its task when the columns change (Ctrl+→ moves it to the next one).
  property int weekColumn: 0
  property int weekCard: 0
  property string weekTask: ""
  // A column's number of cards, and one card (Model.weekColumns' indices).
  function weekCards(column) {
    var col = weekColumns[column]
    return col ? col.cards.length : 0
  }
  function weekCardAt(column, card) {
    var col = weekColumns[column]
    return col && col.cards.length ? col.entries[col.cards[Math.max(0, Math.min(card, col.cards.length - 1))]] : null
  }
  function weekCurrent() {
    return weekCardAt(weekColumn, weekCard)
  }
  function weekPlace(column, card) {
    weekColumn = column
    weekCard = card
    var current = weekCurrent()
    weekTask = current ? current.id : ""
  }
  // The first card of the first column that has one.
  function weekHome() {
    for (let i = 0; i < weekColumns.length; i++)
      if (weekCards(i)) {
        weekPlace(i, 0)
        return
      }
    weekPlace(0, 0)
  }
  onWeekColumnsChanged: {
    if (!weekShown)
      return
    for (let i = 0; i < weekColumns.length; i++) {
      const col = weekColumns[i]
      for (let j = 0; j < col.cards.length; j++)
        if (col.entries[col.cards[j]].id === weekTask) {
          weekColumn = i
          weekCard = j
          return
        }
    }
    const count = weekCards(weekColumn)
    if (!count)
      weekHome()
    else
      weekPlace(weekColumn, Math.min(weekCard, count - 1))
  }
  // ↑/↓ within a column (↑ on the first card: the rail), ←/→ to the next
  // column with cards (← from the first: the rail).
  function weekMove(dx, dy) {
    if (dy !== 0) {
      const next = weekCard + dy
      if (next < 0) {
        goTo(railStop)
        return
      }
      if (next < weekCards(weekColumn))
        weekPlace(weekColumn, next)
    } else {
      let column = weekColumn + dx
      while (column >= 0 && column < weekColumns.length && !weekCards(column))
        column += dx
      if (column < 0) {
        goTo(railStop)
        return
      }
      if (column >= weekColumns.length)
        return
      weekPlace(column, Math.min(weekCard, weekCards(column) - 1))
    }
    weekView.reveal()
    followPane()
  }

  // ---- the rail (Wide) -----------------------------------------------------------------
  readonly property var railEntries: {
    var counts = store.counts
    var out = [
      {
        kind: "view",
        value: "inbox",
        text: FoamyI18n.t("Inbox"),
        iconName: "inbox",
        count: counts.inbox > 0 ? counts.inbox : -1
      },
      {
        kind: "view",
        value: "today",
        text: FoamyI18n.t("Today"),
        iconName: "calendar",
        count: counts.today > 0 ? counts.today : -1,
        urgent: counts.overdue > 0
      },
      {
        kind: "view",
        value: "upcoming",
        text: FoamyI18n.t("Upcoming"),
        iconName: "calendar-days",
        count: -1
      }
    ]
    if (wide)
      out.push({
        kind: "view",
        value: "week",
        text: FoamyI18n.t("Week"),
        iconName: "calendar-range",
        count: -1
      })
    var projects = Model.railProjects(store.model, counts.projects)
    if (projects.length)
      out.push({
        kind: "label",
        text: FoamyI18n.t("My projects")
      })
    return out.concat(projects.map(function (project) {
      return {
        kind: "project",
        value: project.id,
        text: project.name,
        iconName: "hash",
        role: project.role,
        depth: project.depth,
        count: project.count
      }
    }))
  }
  property int railCursor: -1
  function railIndexOfView() {
    for (let i = 0; i < railEntries.length; i++) {
      const entry = railEntries[i]
      if ((entry.kind === "view" && view === entry.value) || (entry.kind === "project" && view === "project" && projectId === entry.value))
        return i
    }
    return 0
  }
  function railMove(delta) {
    for (let i = railCursor + delta; i >= 0 && i < railEntries.length; i += delta)
      if (railEntries[i].kind !== "label") {
        railCursor = i
        railWheel.ensureVisible(railRows.itemAt(i))
        return true
      }
    return false
  }
  function railActivate(index) {
    var entry = railEntries[index]
    if (!entry || entry.kind === "label")
      return
    setView(entry.kind === "project" ? "project" : entry.value, entry.value)
  }
  // The projects for the editor's place dropdowns: the Inbox, then the rail's.
  readonly property var placeProjects: (store.model.inboxId && store.model.projects[store.model.inboxId] ? [
      {
        id: store.model.inboxId,
        name: store.model.projects[store.model.inboxId].name
      }
    ] : []).concat(Model.railProjects(store.model, {}))

  // ---- the editor -------------------------------------------------------------------
  // Small: the task open on the editor page ("" shows the list).
  property string editingTask: ""
  readonly property bool pageShown: !wide && editingTask !== "" && !editingSettings
  // Wide: the task the details pane shows (the list's selection; in the
  // Week view, the card the pane was opened on). The pane shows only while
  // that task is in the snapshot: none selected, or gone, closes it.
  property string paneTask: ""
  property bool weekPaneOpen: false
  readonly property bool paneShown: wide && !editingSettings && store.signedIn && store.loaded && paneTask !== "" && !!store.model.byId[paneTask] && (!weekShown || weekPaneOpen)
  // A click on a row, Enter or `e`: the editor page (Small), or the pane on
  // it (Wide; `focusField` puts the caret in it).
  function openTask(id, focusField) {
    if (!Model.validId(id) || !store.model.byId[id])
      return
    if (wide) {
      paneTask = id
      if (weekShown)
        weekPaneOpen = true
      if (focusField)
        Qt.callLater(taskEditor.focusFirst)
      return
    }
    leaveField()
    heroBand.closeMenu()
    editingTask = id
    Qt.callLater(function () {
      taskEditor.backButton.forceActiveFocus()
    })
  }
  // Back from the page: the list, the task under the cursor.
  function closeTask() {
    var id = editingTask
    taskEditor.commit()
    editingTask = ""
    focusList()
    var stop = stopOf(id)
    if (stop >= 0) {
      viewCursor.index = stop
      Qt.callLater(reveal)
    }
  }

  // ---- adding ---------------------------------------------------------------------------
  // The add in flight and its outcome are the store's (once per shell):
  // a popup opened on another monitor before the reply shows it too.
  readonly property string addError: store.addError
  readonly property bool addBusy: store.addPending
  readonly property string addDay: view === "today" ? store.today : view === "upcoming" ? (upcomingDay || Model.addDays(store.today, 1)) : ""
  readonly property string closeAfterAdd: pref("afterAdd")
  // Enter (alternate false) does what "After adding a task" says,
  // Shift+Enter the other: close (the field and the panel; the text stays
  // the draft until Todoist has the task, so a failed add keeps it and its
  // error), or keep the field open for the next task.
  function submit(alternate) {
    if (searching) {
      if (stops.length)
        goTo(firstRowStop)
      return
    }
    var text = addField.text
    if (text.trim() === "" || addBusy || !store.signedIn)
      return
    var close = (closeAfterAdd === "close") !== !!alternate
    if (!store.addFromField(text, addDay, view === "project" ? projectId : ""))
      return
    if (close)
      root.closeView()
  }
  Connections {
    target: root.store
    // Added: cleared only where it still holds what was added (typing
    // went on), also after the popup closed or a search started.
    function onFieldAdded(sent) {
      if (root.field.text === sent && !root.searching)
        root.field.text = ""
      if (root.searchDraft === sent)
        root.searchDraft = ""
    }
  }
  // The Quick Add tokens' colours (Model.quickAddRuns), on the band.
  readonly property var tokenColors: ({
      project: FoamyPalette.onSurface(FoamyPalette.accent),
      section: FoamyPalette.onSurface(FoamyPalette.accent),
      assignee: FoamyPalette.onSurface(FoamyPalette.accent),
      label: Qt.tint(FoamyPalette.text, Qt.alpha(FoamyPalette.accent, 0.55)),
      priority: FoamyPalette.onSurface(FoamyPalette.urgent),
      reminder: FoamyPalette.onSurface(FoamyPalette.urgent),
      deadline: FoamyPalette.mutedText,
      description: FoamyPalette.mutedText
    })

  // ---- activation ------------------------------------------------------------------------
  property bool enterPressed: false
  onReturnRequested: enterPressed = true
  function activate(enter) {
    var at = viewCursor.index
    if (at === addStop)
      return openAdd()
    if (at === searchStop)
      return taskInBand ? openPaneTask() : searching ? leaveSearch() : startSearch()
    if (at === menuStop)
      return heroBand.openMenu(true)
    if (on(switchStop))
      return views.activateCursor()
    if (on(railStop))
      return railActivate(railCursor)
    if (at === refreshStop)
      return store.sync()
    if (at === openStop)
      return openViewInTodoist()
    if (!weekShown && !stops.length && at === firstRowStop && stateButton.visible)
      return stateButton.clicked()
    var row = cursorRow()
    if (!row)
      return
    if (row.kind === "fold")
      overdueOpen = !overdueOpen
    else if (enter)
      openTask(row.id, true)
    else
      completeTask(row.id)
  }
  // A row's ring or Space: the editor's typed changes to the same task are
  // saved first, so they reach the queue ahead of the completion.
  function completeTask(id) {
    if (taskEditor.shownId === id)
      taskEditor.commit()
    store.toggleComplete(id)
  }
  function openViewInTodoist() {
    store.openView(view === "week" ? "upcoming" : view, projectId)
  }
  // Wide, a task in the pane: Open (that task) takes Search's place in the
  // band and Search moves to the top of the ⋯ menu; `/` still searches.
  readonly property bool taskInBand: paneShown && taskEditor.task !== null
  function openPaneTask() {
    if (taskInBand)
      store.openView("task", paneTask)
  }
  onActivateRequested: {
    var enter = enterPressed
    enterPressed = false
    activate(enter)
  }
  onMoveRequested: function (dx, dy) {
    if (dy === 0 && on(switchStop)) {
      views.moveCursor(dx)
      return
    }
    if (on(railStop)) {
      if (dy !== 0 && !railMove(dy) && dy < 0)
        step(-1)
      else if (dx > 0)
        goTo(rowStops ? firstRowStop : railStop)
      return
    }
    if (weekShown && on(firstRowStop)) {
      weekMove(dx, dy)
      return
    }
    var row = cursorRow()
    if (dx !== 0 && row) {
      if (wide && dx < 0)
        goTo(railStop)
      else if (dx > 0 && row.kind === "fold" && !overdueOpen)
        overdueOpen = true
      return
    }
    step(dy !== 0 ? dy : dx)
  }
  // Esc: the details pane closes first (the Week view's; in a list the
  // selection clears, and the card narrows); then the panel.
  onCloseRequested: {
    if (weekShown && weekPaneOpen)
      weekPaneOpen = false
    else if (!weekShown && paneShown)
      clearSelection()
    else
      root.closeView()
  }
  // Tab: the next panel; in Wide, into the details pane.
  onTabRequested: function (direction) {
    if (paneShown && taskEditor.task)
      taskEditor.focusFirst()
    else
      root.switchPanel(direction)
  }
  onTextKey: function (text, modifiers) {
    var digit = viewKeys[Number(text) - 1]
    if (digit && (viewCursor.plain(modifiers) || (modifiers & Qt.AltModifier))) {
      setView(digit)
      return
    }
    if (!viewCursor.plain(modifiers))
      return
    var row = cursorRow()
    if (text === "a")
      openAdd()
    else if (text === "/")
      startSearch()
    else if (text === "r")
      store.sync()
    else if (text === "s")
      root.settingsRequested()
    else if (text === "e" && row && row.kind === "task")
      openTask(row.id, true)
    else if (text === "t" && row && row.kind === "task")
      store.moveToTomorrow(row.id)
  }
  // ---- autocomplete (#project, @label) in the add field ---------------------------------------
  // Model.suggestions for the word at the caret, or null. Esc dismisses the
  // list until the text changes again.
  property var suggest: null
  property int suggestIndex: 0
  property bool suggestDismissed: false
  readonly property bool suggestOpen: suggest !== null && suggest.items.length > 0 && adding && fieldFocused
  function updateSuggest() {
    var next = adding && !suggestDismissed ? Model.suggestions(store.model, addField.text, addField.cursorPosition) : null
    // A new word (or a new query) starts at the top of the list.
    if (!next || !suggest || next.start !== suggest.start || next.query !== suggest.query)
      suggestIndex = 0
    suggest = next
  }
  function clearSuggest() {
    suggest = null
    suggestIndex = 0
    suggestDismissed = false
  }
  // Puts the entry in place of the word, the caret after it; textEdited
  // fires as for typing, so the colours and the error line follow.
  function insertSuggestion(index) {
    if (!suggestOpen || index < 0 || index >= suggest.items.length)
      return
    var result = Model.applySuggestion(addField.text, suggest.start, suggest.end, suggest.items[index])
    // Past the field's limit the text would be cut: keep the draft as it is.
    if (result.text.length > addField.maximumLength) {
      store.addError = FoamyI18n.t("The task is too long for this suggestion")
      // The list covers the error line: close it (until the text changes).
      suggestDismissed = true
      suggest = null
      return
    }
    addField.text = result.text
    addField.cursorPosition = result.caret
    addField.textEdited()
    addField.focusInput()
  }
  // The list's keys while it shows: true when the key was its.
  function suggestKey(event) {
    if (!suggestOpen)
      return false
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      const last = suggest.items.length - 1
      suggestIndex = Math.max(0, Math.min(last, suggestIndex + (event.key === Qt.Key_Down ? 1 : -1)))
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
      insertSuggestion(suggestIndex)
    } else if (event.key === Qt.Key_Escape) {
      suggestDismissed = true
      suggest = null
    } else
      return false
    event.accepted = true
    return true
  }
  // The field's own keys (the catcher is blocked while it has them).
  function fieldKey(event) {
    if (suggestKey(event))
      return
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    if (alt && event.key >= Qt.Key_1 && event.key <= Qt.Key_3) {
      setView(viewKeys[event.key - Qt.Key_1])
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      if (rowStops)
        goTo(firstRowStop)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      // Text: cleared. Empty: the field closes (search ends too).
      if (addField.text !== "") {
        addField.text = ""
        query = ""
        store.addError = ""
        if (!searching)
          store.addDraft = ""
      } else if (searching)
        leaveSearch()
      else
        closeField()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      // Never away from text: Tab switches panels only from an empty field.
      if (addField.text === "")
        root.switchPanel(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      submit((event.modifiers & Qt.ShiftModifier) !== 0)
      event.accepted = true
    }
  }

  // ---- open and close ------------------------------------------------------------------
  function prepare() {
    var openOn = pref("openOn")
    var next = openOn === "last" ? store.lastView : openOn
    if (next === "project" && !(wide && store.model.projects[store.lastProject]))
      next = "today"
    if (next === "week" && !wide)
      next = "today"
    // The draft comes back with why its add failed (the reply may have
    // come after the popup closed); setView clears the error otherwise.
    var draftError = store.addDraft !== "" ? store.addError : ""
    editingTask = ""
    paneTask = ""
    setView(next, store.lastProject)
    store.addError = draftError
    fieldOpen = false
    addField.text = ""
    viewCursor.index = -1
    focusList()
    // An add draft from before (the popup closed while it was being
    // typed), or IPC `add`: the field open with the keys, the caret at the end.
    if (store.addDraft !== "") {
      addField.text = store.addDraft
      addField.cursorPosition = addField.text.length
    }
    // Read before addOnOpenUsed(), which clears it through the binding.
    var addWanted = addOnOpen
    if (addWanted)
      root.addOnOpenUsed()
    if (addWanted || store.addDraft !== "")
      Qt.callLater(openAdd)
    store.refreshIfStale(30000)
  }
  // Closing sends the completions still in their undo window at once, and
  // the editor's field that had the keys.
  function closed() {
    taskEditor.commit()
    store.flushCompletions()
    // The add draft outlives the popup (search text never is one).
    if (!searching)
      store.addDraft = fieldOpen ? addField.text : ""
    leaveSearch(false)
    fieldOpen = false
    clearSuggest()
    addField.text = ""
    editingTask = ""
    paneTask = ""
    weekPaneOpen = false
    if (store.addDraft === "" && !store.addPending)
      store.addError = ""
    viewCursor.reset()
    heroBand.closeMenu()
  }
  onActiveChanged: active ? prepare() : closed()
  // The popup builds this view on its first open with `active` already true.
  Component.onCompleted: if (active)
    prepare()
  onEditingSettingsChanged: {
    if (editingSettings) {
      heroBand.closeMenu()
      viewCursor.reset()
      settingsView.resetScroll()
      Qt.callLater(settingsView.focusBack)
    } else
      Qt.callLater(focusList)
  }
  blocked: editingSettings || pageShown || heroBand.menuOpen || fieldFocused || taskEditor.activeFocus || taskEditor.menuOpen
  // A minute tick for "Updated …" while the popup is open.
  FoamyWallClock {
    id: clock
    enabled: root.active
  }

  implicitWidth: wide ? Commons.Style.space(880) : FoamyStyle.popupWidth
  readonly property real maxListHeight: FoamyStyle.rowHeight * (wide ? 18 : 13)
  // Row heights are fixed per kind, so the list's height is known without
  // building its (lazy) rows.
  function heightOf(row) {
    if (row.kind === "header")
      return row.divider ? FoamyStyle.rowHeight + 2 : FoamyStyle.rowHeight - 6
    return row.kind === "task" && row.detail ? FoamyStyle.rowHeight + 6 : FoamyStyle.rowHeight
  }
  readonly property real rowsHeight: rows.reduce(function (sum, row) {
    return sum + root.heightOf(row)
  }, 0)
  // The suggestion list floats over the rows; the list pane is at least as
  // tall as it while it shows, so it stays inside the card.
  readonly property real listHeight: Math.max(stateBox.visible ? stateBox.implicitHeight : weekShown ? Math.min(weekView.implicitHeight, maxListHeight) : Math.min(rowsHeight, maxListHeight), suggestions.visible ? suggestions.height : 0)
  // The list pane around the rows: a gap, the error lines (when shown), and a gap.
  readonly property real listChrome: FoamyStyle.gap + (errorLine.visible ? errorLine.height + FoamyStyle.gapSmall : 0) + FoamyStyle.gap
  readonly property real railHeight: Math.min(railColumn.implicitHeight + FoamyStyle.gap * 2, maxListHeight)
  // The pane (also over the Week view, which then grows to show it).
  readonly property real paneHeight: paneShown ? Math.min(taskEditor.implicitHeight, maxListHeight) : 0
  readonly property real bodyHeight: wide ? Math.max(railHeight, listChrome + listHeight, paneHeight) : (tabsBox.visible ? tabsBox.height : 0) + listChrome + listHeight
  implicitHeight: editingSettings ? settingsView.implicitHeight : pageShown ? taskEditor.implicitHeight : heroBand.implicitHeight + bodyHeight + (panelFooter.visible ? panelFooter.implicitHeight : 0)

  // ---- the band ----------------------------------------------------------------------------
  readonly property string viewTitle: view === "project" && store.model.projects[projectId] ? store.model.projects[projectId].name : ""
  readonly property string meta: {
    if (!store.signedIn || !store.loaded)
      return ""
    var counts = store.counts
    if (searching)
      return FoamyI18n.t("Search")
    if (view === "inbox")
      return FoamyI18n.tn("Inbox · %1 tasks", counts.inbox)
    if (view === "upcoming")
      return FoamyI18n.tn("Upcoming · %1 tasks in the next 7 days", counts.week)
    if (view === "week")
      return FoamyI18n.tn("Week · %1 tasks", weekCount)
    if (view === "project")
      return FoamyI18n.tn("%1 · %2 tasks", counts.projects[projectId] || 0, [viewTitle, FoamyI18n.number(counts.projects[projectId] || 0)])
    var left = FoamyI18n.tn("Today · %1 left", counts.today)
    return counts.overdue ? left + " · " + FoamyI18n.tn("%1 overdue", counts.overdue) : left
  }
  FoamyHeroBand {
    id: heroBand
    visible: !root.editingSettings && !root.pageShown
    width: parent.width
    title: "Todoist"
    iconName: "todoist"
    meta: root.meta
    // +, Search and ⋯ (Open in Todoist, then Settings): three buttons. With
    // a task in the Wide pane: +, Open (the task) and ⋯ (Search first).
    maxButtons: 3
    field: fieldBox
    fieldOrigin: root.searching ? searchAction : addAction
    fieldOpen: root.fieldOpen
    settingsHasCursor: viewCursor.at(root.menuStop)
    menuHasCursor: viewCursor.at(root.menuStop)
    onSettingsClicked: {
      root.leaveField()
      root.settingsRequested()
    }
    onSettingsHovered: function (hovered) {
      if (hovered && !root.fieldFocused)
        viewCursor.hover(root.menuStop)
    }
    onMenuHovered: function (hovered) {
      if (hovered && !root.fieldFocused)
        viewCursor.hover(root.menuStop)
    }
    menuItems: [
      FoamyMenuItem {
        objectName: "searchItem"
        visible: root.taskInBand && root.store.signedIn
        text: FoamyI18n.t("Search")
        iconName: "search"
        onTriggered: root.startSearch()
      },
      FoamyMenuItem {
        objectName: "openInTodoist"
        text: FoamyI18n.t("Open in Todoist")
        iconName: "external-link"
        onTriggered: root.openViewInTodoist()
      }
    ]
    trailing: [
      FoamyAction {
        id: addAction
        objectName: "addAction"
        visible: root.store.signedIn
        iconName: "plus"
        tooltipText: FoamyI18n.t("Add a task")
        hasCursor: viewCursor.at(root.addStop)
        onHoveredChanged: if (hovered && !root.fieldFocused)
          viewCursor.hover(root.addStop)
        onClicked: root.openAdd()
      },
      FoamyAction {
        id: searchAction
        objectName: "searchAction"
        visible: root.store.signedIn && !root.taskInBand
        iconName: "search"
        tooltipText: FoamyI18n.t("Search")
        hasCursor: viewCursor.at(root.searchStop)
        onHoveredChanged: if (hovered && !root.fieldFocused)
          viewCursor.hover(root.searchStop)
        onClicked: {
          root.leaveField()
          root.searching ? root.leaveSearch() : root.startSearch()
        }
      },
      // The pane's task in Todoist, in Search's place (the same cursor stop).
      FoamyAction {
        id: openTaskAction
        objectName: "openTaskAction"
        visible: root.taskInBand
        iconName: "external-link"
        tooltipText: FoamyI18n.t("Open in Todoist")
        hasCursor: viewCursor.at(root.searchStop)
        onHoveredChanged: if (hovered && !root.fieldFocused)
          viewCursor.hover(root.searchStop)
        onClicked: {
          root.leaveField()
          root.openPaneTask()
        }
      }
    ]
  }
  // The band's field (the band places and sizes it): the add or search
  // text, its icon, and a spinner while an add is on its way.
  Item {
    id: fieldBox
    objectName: "fieldBox"
    readonly property string placeholder: root.searching ? FoamyI18n.t("Search tasks") : Model.addPlaceholder(root.view, root.addDay, root.store.today, root.viewTitle, root.formatDate, root.translate)
    SafeTextField {
      id: addField
      objectName: "addField"
      anchors.fill: parent
      // The band's title size (the band can't set it: its field is fieldBox).
      font.pixelSize: FoamyStyle.font.title
      placeholderText: fieldBox.placeholder
      translate: FoamyI18n.t
      maximumLength: 500
      // Quick Add's tokens in colour, only while adding.
      runs: root.adding ? Model.quickAddRuns(text, root.tokenColors) : []
      // The icon at the reading start, the spinner at the end: padding
      // isn't mirrored, so RTL swaps the sides.
      readonly property real startPadding: FoamyStyle.iconSize + FoamyStyle.gap * 2
      readonly property real endPadding: spinner.visible ? FoamyStyle.iconSize + FoamyStyle.gap * 2 : FoamyStyle.gap
      leftPadding: LayoutMirroring.enabled ? endPadding : startPadding
      rightPadding: LayoutMirroring.enabled ? startPadding : endPadding
      Accessible.name: fieldBox.placeholder
      onTextEdited: {
        root.store.addError = ""
        if (root.searching)
          root.query = text
        root.suggestDismissed = false
        root.updateSuggest()
      }
      onCursorPositionChanged: root.updateSuggest()
      onKeyPressed: function (event) {
        root.fieldKey(event)
      }
    }
    FoamyIcon {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.gap + 2
      width: FoamyStyle.iconSize
      height: width
      name: root.searching ? "search" : "plus"
      color: FoamyPalette.mutedText
    }
    FoamyIcon {
      id: spinner
      objectName: "addSpinner"
      visible: root.addBusy && root.adding
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.gap
      width: FoamyStyle.iconSize
      height: width
      name: "refresh-cw"
      color: FoamyPalette.mutedText
      RotationAnimation on rotation {
        running: spinner.visible && root.active && !FoamyMotion.reduceMotion
        from: 0
        to: 360
        duration: FoamyMotion.spin
        loops: Animation.Infinite
        onStopped: spinner.rotation = 0
      }
    }
  }

  // ---- the tab row (Small) -----------------------------------------------------------
  // Under the band's hairline, full width; it draws its own bottom hairline.
  Item {
    id: tabsBox
    visible: !root.wide && !root.editingSettings && !root.pageShown && root.store.signedIn
    anchors.top: heroBand.bottom
    width: parent.width
    height: visible ? views.implicitHeight : 0
    FoamyTabs {
      id: views
      objectName: "viewSwitch"
      width: parent.width
      value: root.searching ? "" : root.view
      hasCursor: root.on(root.switchStop)
      model: [
        {
          value: "inbox",
          text: FoamyI18n.t("Inbox"),
          iconName: "inbox",
          // No count at 0, like the bar.
          count: root.store.loaded && root.store.counts.inbox > 0 ? root.store.counts.inbox : -1
        },
        {
          value: "today",
          text: FoamyI18n.t("Today"),
          iconName: "calendar",
          count: root.store.loaded && root.store.counts.today > 0 ? root.store.counts.today : -1,
          countUrgent: root.store.counts.overdue > 0
        },
        {
          value: "upcoming",
          text: FoamyI18n.t("Upcoming"),
          iconName: "calendar-days"
        }
      ]
      onActivated: function (value) {
        root.leaveField()
        root.setView(value)
      }
      onHovered: if (!root.fieldFocused)
        viewCursor.hover(root.switchStop)
    }
  }

  // ---- the body ---------------------------------------------------------------------------------
  Item {
    id: content
    visible: !root.editingSettings && !root.pageShown
    anchors.top: tabsBox.visible ? tabsBox.bottom : heroBand.bottom
    anchors.bottom: panelFooter.visible ? panelFooter.top : parent.bottom
    // Laid out at the width to come (layoutWidth) from the reading start:
    // anchored, not placed by x, so RTL puts the rail on the right and the
    // part still to be uncovered (the pane) past the left edge.
    anchors.left: parent.left
    width: root.layoutWidth

    // The rail (Wide): views, then the projects.
    Flickable {
      id: rail
      objectName: "rail"
      visible: root.wide && root.store.signedIn && root.store.loaded
      anchors.left: parent.left
      width: visible ? 156 : 0
      height: parent.height
      contentHeight: railColumn.implicitHeight + FoamyStyle.gap * 2
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      FoamyWheelScroll {
        id: railWheel
        target: rail
      }
      Column {
        id: railColumn
        y: FoamyStyle.gap
        x: FoamyStyle.gap
        width: rail.width - FoamyStyle.gap * 2
        Repeater {
          id: railRows
          model: root.railEntries
          Item {
            id: railRow
            required property var modelData
            required property int index
            objectName: "rail-" + (modelData.value || "label")
            width: railColumn.width
            height: modelData.kind === "label" ? FoamyStyle.rowHeight - 4 : FoamyStyle.rowHeight - 6
            readonly property bool selected: (modelData.kind === "view" && root.view === modelData.value && !root.searching) || (modelData.kind === "project" && root.view === "project" && root.projectId === modelData.value && !root.searching)
            PlainText {
              objectName: "railLabel"
              visible: railRow.modelData.kind === "label"
              anchors.bottom: parent.bottom
              anchors.bottomMargin: FoamyStyle.gapSmall
              anchors.left: parent.left
              anchors.leftMargin: FoamyStyle.gap
              text: railRow.modelData.text
              wrapMode: Text.NoWrap
              font.pixelSize: FoamyStyle.font.caption
              font.weight: Font.DemiBold
              color: FoamyPalette.mutedText
            }
            FoamyCursorSurface {
              visible: railRow.modelData.kind !== "label"
              anchors.fill: parent
              hasCursor: root.on(root.railStop) && root.railCursor === railRow.index
              current: railRow.selected
              onHovered: if (!root.fieldFocused) {
                viewCursor.hover(root.railStop)
                root.railCursor = railRow.index
              }
              onClicked: {
                root.leaveField()
                root.railActivate(railRow.index)
              }
              Accessible.role: Accessible.Button
              Accessible.name: railRow.modelData.text
              FoamyIcon {
                id: railIcon
                objectName: "railIcon"
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: FoamyStyle.gap + (railRow.modelData.depth || 0) * FoamyStyle.gapLarge
                width: FoamyStyle.iconSize
                height: width
                name: railRow.modelData.iconName || "hash"
                color: railRow.modelData.kind === "project" ? railColors.of(railRow.modelData.role) : FoamyPalette.secondaryText
              }
              PlainText {
                objectName: "railText"
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: railIcon.right
                anchors.leftMargin: FoamyStyle.gap
                anchors.right: railCount.left
                anchors.rightMargin: FoamyStyle.gapSmall
                text: railRow.modelData.text
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                font.pixelSize: FoamyStyle.font.bodySmall
                font.weight: railRow.selected ? Font.DemiBold : Font.Normal
              }
              PlainText {
                id: railCount
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: FoamyStyle.gap
                text: railRow.modelData.count > 0 ? FoamyI18n.number(railRow.modelData.count) : ""
                wrapMode: Text.NoWrap
                font.family: FoamyStyle.monoFamily
                font.pixelSize: FoamyStyle.font.caption
                color: railRow.modelData.urgent ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.mutedText
              }
            }
          }
        }
      }
    }
    QtObject {
      id: railColors
      function of(role) {
        return role === "error" ? FoamyPalette.error : role === "warning" ? FoamyPalette.warning : role === "success" ? FoamyPalette.success : role === "info" ? FoamyPalette.info : role === "accent" ? FoamyPalette.accent : FoamyPalette.mutedText
      }
    }
    Rectangle {
      visible: rail.visible
      anchors.left: rail.right
      width: FoamyStyle.borderWidth
      height: parent.height
      color: FoamyPalette.divider
    }

    Item {
      id: listArea
      objectName: "listArea"
      anchors.left: rail.visible ? rail.right : parent.left
      anchors.leftMargin: rail.visible ? FoamyStyle.borderWidth : 0
      // Beside it, the details pane at the reading end (over the Week
      // view, which keeps its width).
      width: content.width - (rail.visible ? rail.width + FoamyStyle.borderWidth : 0) - (root.paneShown && !root.weekShown ? root.paneWidth + FoamyStyle.borderWidth : 0)
      height: parent.height

      // The list's space that isn't a row (the margins, the error lines,
      // the Week view's headings): under everything in it.
      FoamyClickAway {
        anchors.fill: parent
        z: -1
        onClicked: root.clearSelection()
      }

      // Lines at the top: why the last add, sync or change failed (an
      // error, whole), and that the snapshot was cut (a note, while rows show).
      Column {
        id: errorLine
        readonly property string message: root.addError !== "" ? root.addError : root.store.loaded ? root.store.error : ""
        readonly property bool truncated: root.store.model.truncated && (root.rows.length > 0 || root.weekCount > 0)
        visible: root.store.signedIn && (message !== "" || truncated)
        anchors.left: parent.left
        anchors.leftMargin: FoamyStyle.gapLarge + FoamyStyle.rowPadding
        anchors.right: parent.right
        anchors.rightMargin: FoamyStyle.gapLarge
        y: FoamyStyle.gap
        height: visible ? implicitHeight : 0
        spacing: FoamyStyle.gapTiny
        PlainText {
          id: errorText
          objectName: "errorLine"
          visible: errorLine.message !== ""
          width: parent.width
          text: errorLine.message
          font.pixelSize: FoamyStyle.font.bodySmall
          color: Commons.Color.urgent
          Accessible.role: Accessible.AlertMessage
        }
        PlainText {
          objectName: "truncatedLine"
          visible: errorLine.truncated
          width: parent.width
          text: FoamyI18n.t(Model.TRUNCATED_TEXT)
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.mutedText
        }
      }
      ListView {
        id: taskList
        objectName: "taskList"
        visible: !root.weekShown
        anchors.top: errorLine.visible ? errorLine.bottom : parent.top
        anchors.topMargin: errorLine.visible ? FoamyStyle.gapSmall : FoamyStyle.gap
        anchors.bottom: parent.bottom
        anchors.bottomMargin: FoamyStyle.gap
        width: parent.width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows
        // Lazy: only the rows in view (and a little more) exist.
        cacheBuffer: FoamyStyle.rowHeight * 6
        reuseItems: true
        Controls.ScrollBar.vertical: Controls.ScrollBar {
          policy: Controls.ScrollBar.AsNeeded
        }
        FoamyWheelScroll {
          target: taskList
          // Below the last row, a heading between groups.
          onSpaceClicked: root.clearSelection()
        }
        delegate: TaskRow {
          required property var modelData
          required property int index
          entry: modelData
          heading: modelData.kind === "header" && modelData.group ? Model.upcomingHeading(modelData, root.formatDate, root.translate) : null
          trailDay: modelData.kind === "task" ? Model.trailingDay(modelData, root.formatDate, root.translate) : ""
          dateText: modelData.kind === "task" ? Model.detailDate(modelData, root.formatDate, root.translate, root.store.today) : ""
          width: ListView.view.width
          height: root.heightOf(modelData)
          hasCursor: root.stopOfRow[index] >= 0 && viewCursor.index === root.stopOfRow[index]
          selected: root.paneShown && modelData.kind === "task" && root.paneTask === modelData.id
          onHovered: if (!root.fieldFocused && root.stopOfRow[index] >= 0)
            viewCursor.hover(root.stopOfRow[index])
          onCompleteRequested: {
            root.leaveField()
            root.completeTask(modelData.id)
          }
          // Small: the editor page; Wide: the pane shows it.
          onOpenRequested: {
            root.leaveField()
            if (root.stopOfRow[index] >= 0)
              viewCursor.index = root.stopOfRow[index]
            root.openTask(modelData.id, false)
          }
          onFoldRequested: {
            root.leaveField()
            root.overdueOpen = !root.overdueOpen
          }
        }
      }
      // The Week view (Wide): four columns in the list's place.
      WeekView {
        id: weekView
        objectName: "weekView"
        visible: root.weekShown && root.store.signedIn && root.store.loaded
        anchors.top: errorLine.visible ? errorLine.bottom : parent.top
        anchors.topMargin: errorLine.visible ? FoamyStyle.gapSmall : FoamyStyle.gap
        anchors.bottom: parent.bottom
        anchors.bottomMargin: FoamyStyle.gap
        width: parent.width
        columns: root.weekColumns
        hasCursor: root.on(root.firstRowStop)
        cursorColumn: root.weekColumn
        cursorCard: root.weekCard
        selectedId: root.weekPaneOpen ? root.paneTask : ""
        onHovered: function (column, card) {
          if (root.fieldFocused)
            return
          viewCursor.hover(root.firstRowStop)
          root.weekPlace(column, card)
        }
        onClicked: function (column, card) {
          root.leaveField()
          viewCursor.index = root.firstRowStop
          root.weekPlace(column, card)
          var current = root.weekCurrent()
          if (current)
            root.openTask(current.id, false)
        }
        onCompleteRequested: function (id) {
          root.leaveField()
          root.completeTask(id)
        }
        onSpaceClicked: root.clearSelection()
      }

      // Signed out, loading, empty, or failed without data: one line.
      Column {
        id: stateBox
        objectName: "stateBox"
        readonly property string kind: root.store.account === "unavailable" ? "unavailable" : root.store.account === "error" ? "accountError" : root.store.account === "checking" ? "loading" : !root.store.signedIn ? "signedOut" : !root.store.loaded ? (root.store.error !== "" ? "failed" : "loading") : root.weekShown || root.rows.length ? "" : "empty"
        visible: kind !== ""
        anchors.top: errorLine.visible ? errorLine.bottom : parent.top
        width: parent.width
        topPadding: FoamyStyle.gapLarge
        bottomPadding: FoamyStyle.gapLarge
        spacing: FoamyStyle.gap
        readonly property bool failure: kind === "failed" || kind === "accountError" || kind === "unavailable"
        PlainText {
          objectName: "stateText"
          x: FoamyStyle.padding
          width: parent.width - FoamyStyle.padding * 2
          horizontalAlignment: Text.AlignHCenter
          font.pixelSize: FoamyStyle.font.bodySmall
          color: stateBox.failure ? Commons.Color.urgent : FoamyPalette.mutedText
          Accessible.role: stateBox.failure ? Accessible.AlertMessage : Accessible.StaticText
          text: {
            switch (stateBox.kind) {
            case "signedOut":
              return FoamyI18n.t("Add your Todoist API token in Settings")
            case "loading":
              return FoamyI18n.t("Loading…")
            case "failed":
              return root.store.error
            case "accountError":
            case "unavailable":
              return root.store.accountError
            case "empty":
              return FoamyI18n.t(Model.emptyText(root.listView, root.store.model.truncated))
            default:
              return ""
            }
          }
        }
        FoamyButton {
          id: stateButton
          objectName: "stateButton"
          visible: stateBox.kind === "signedOut" || stateBox.kind === "failed" || stateBox.kind === "accountError"
          anchors.horizontalCenter: parent.horizontalCenter
          text: stateBox.kind === "signedOut" ? FoamyI18n.t("Open settings") : FoamyI18n.t("Retry")
          kind: stateBox.kind === "signedOut" ? "primary" : "secondary"
          hasCursor: viewCursor.at(root.firstRowStop) && !root.stops.length
          onHoveredChanged: if (hovered)
            viewCursor.hover(root.firstRowStop)
          onClicked: stateBox.kind === "signedOut" ? root.settingsRequested() : root.store.retry()
        }
      }
    }
  }

  // The suggestions: a menu-like list dropping from the band over the
  // body, as wide as the field. The field keeps the keys.
  Rectangle {
    id: suggestions
    objectName: "suggestions"
    visible: root.suggestOpen
    z: 20
    x: FoamyStyle.padding
    y: heroBand.y + heroBand.height + FoamyStyle.gapTiny
    width: parent.width - FoamyStyle.padding * 2
    height: suggestionColumn.implicitHeight + FoamyStyle.menuPadding * 2 + FoamyStyle.borderWidth * 2
    radius: FoamyStyle.radius
    color: FoamyPalette.menuFill
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.border
    Column {
      id: suggestionColumn
      anchors.fill: parent
      anchors.margins: FoamyStyle.menuPadding + FoamyStyle.borderWidth
      Repeater {
        model: root.suggestOpen ? root.suggest.items : []
        Item {
          id: suggestionRow
          required property var modelData
          required property int index
          readonly property bool hasCursor: root.suggestIndex === index
          readonly property bool isProject: modelData.kind === "project"
          // What the row's glyph is: # for projects (an icon), @ / + for the rest.
          readonly property string sigil: ({
              "label": "@",
              "section": "/",
              "assignee": "+"
            })[modelData.kind] || ""
          objectName: "suggestion-" + modelData.name
          width: suggestionColumn.width
          height: FoamyStyle.rowHeight
          Accessible.role: Accessible.MenuItem
          Accessible.name: (isProject ? "#" : sigil) + modelData.name + (modelData.email ? ", " + modelData.email : "")
          Rectangle {
            anchors.fill: parent
            radius: FoamyStyle.innerRadius(FoamyStyle.radius, FoamyStyle.menuPadding / 2)
            color: suggestionRow.hasCursor ? FoamyPalette.hoverFill : "transparent"
          }
          Row {
            anchors.left: parent.left
            anchors.leftMargin: FoamyStyle.rowPadding
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - FoamyStyle.rowPadding * 2
            clip: true
            spacing: FoamyStyle.gap
            FoamyIcon {
              visible: suggestionRow.isProject
              anchors.verticalCenter: parent.verticalCenter
              width: FoamyStyle.iconSize
              height: width
              name: "hash"
              color: railColors.of(suggestionRow.modelData.role)
            }
            // The name, its matched part DemiBold (plain text runs, no markup).
            Row {
              anchors.verticalCenter: parent.verticalCenter
              PlainText {
                visible: !suggestionRow.isProject
                text: suggestionRow.sigil
                wrapMode: Text.NoWrap
                // Labels' @ in the info colour, as on task rows; / and + muted.
                color: suggestionRow.modelData.kind === "label" ? FoamyPalette.onSurface(FoamyPalette.info) : FoamyPalette.mutedText
              }
              PlainText {
                text: suggestionRow.modelData.name.slice(0, suggestionRow.modelData.matchStart)
                wrapMode: Text.NoWrap
              }
              PlainText {
                text: suggestionRow.modelData.name.substr(suggestionRow.modelData.matchStart, suggestionRow.modelData.matchLength)
                wrapMode: Text.NoWrap
                font.weight: Font.DemiBold
              }
              PlainText {
                text: suggestionRow.modelData.name.slice(suggestionRow.modelData.matchStart + suggestionRow.modelData.matchLength)
                wrapMode: Text.NoWrap
              }
            }
            // A person's email, muted after the name (one-line menu rows).
            PlainText {
              objectName: "suggestionDetail"
              visible: text !== ""
              anchors.verticalCenter: parent.verticalCenter
              text: suggestionRow.modelData.email || ""
              wrapMode: Text.NoWrap
              elide: Text.ElideRight
              font.pixelSize: FoamyStyle.font.bodySmall
              color: FoamyPalette.mutedText
            }
          }
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.suggestIndex = suggestionRow.index
            onClicked: root.insertSuggestion(suggestionRow.index)
          }
        }
      }
    }
  }

  // ---- the editor (the page in Small, the pane in Wide) --------------------------------
  // Panel.qml's narrowWidth leaves this out (the list keeps its width).
  readonly property real paneWidth: Commons.Style.space(270)
  // The pane's surface at the body's reading end: over the Week view it
  // covers that part. Anchored, so RTL puts it on the left.
  Rectangle {
    visible: root.paneShown
    anchors.right: content.right
    anchors.top: content.top
    width: root.paneWidth + FoamyStyle.borderWidth
    height: content.height
    z: 4
    color: FoamyPalette.background
    Rectangle {
      anchors.left: parent.left
      width: FoamyStyle.borderWidth
      height: parent.height
      color: FoamyPalette.divider
    }
  }
  TaskEditor {
    id: taskEditor
    objectName: "taskEditor"
    visible: root.wide ? root.paneShown : root.pageShown
    z: 5
    mode: root.wide ? "pane" : "page"
    projects: root.placeProjects
    taskId: root.wide ? (root.paneShown ? root.paneTask : "") : root.pageShown ? root.editingTask : ""
    // Wide: on the pane's surface (anchored, as it); Small: the whole card.
    anchors.right: root.wide ? content.right : parent.right
    y: root.wide ? content.y : 0
    width: root.wide ? root.paneWidth : root.width
    height: root.wide ? content.height : root.height
    onBack: root.closeTask()
    onKeysReturned: root.focusList()
  }

  // ---- the footer ------------------------------------------------------------------------
  // While adding, the keys and what they do; else where the tasks come
  // from, how fresh they are, and Refresh.
  FoamyPanelFooter {
    id: panelFooter
    objectName: "footer"
    visible: !root.editingSettings && !root.pageShown && root.store.signedIn
    anchors.bottom: parent.bottom
    width: parent.width
    horizontalPadding: FoamyStyle.padding
    // A launch that failed first (until the next one works), as foamy-clock's
    // footer; else, with cached data shown after a failed sync, the time of
    // the last good one.
    status: root.adding ? "" : root.store.launchError !== "" ? root.store.launchError : root.store.syncing && root.store.loaded && clock.date.getTime() - root.store.syncedAt > root.store.refreshSeconds * 1000 ? FoamyI18n.t("Updating…") : FoamyI18n.updatedAgo(root.store.syncedAt, clock.date.getTime())
    statusError: !root.adding && root.store.launchError !== ""
    showRefresh: !root.adding
    refreshing: root.store.syncing
    refreshEnabled: root.store.signedIn && !root.store.busy
    refreshHasCursor: viewCursor.at(root.refreshStop)
    onRefreshHovered: function (hovered) {
      if (hovered && !root.fieldFocused)
        viewCursor.hover(root.refreshStop)
    }
    onRefreshClicked: {
      root.leaveField()
      root.store.sync()
    }

    // Opens the current view in Todoist (with the open command, if set).
    FoamyAction {
      id: openAction
      objectName: "openTodoist"
      visible: !root.adding
      iconName: "todoist"
      label: FoamyI18n.t("Todoist")
      foreground: FoamyPalette.secondaryText
      tooltipText: FoamyI18n.t("Open Todoist")
      hasCursor: root.on(root.openStop)
      onHoveredChanged: if (hovered && !root.fieldFocused)
        viewCursor.hover(root.openStop)
      onClicked: {
        root.leaveField()
        root.openViewInTodoist()
      }
    }
    // The add field's keys, as "After adding a task" sets them.
    Row {
      id: keyHints
      objectName: "keyHints"
      visible: root.adding
      spacing: FoamyStyle.gapLarge
      readonly property bool closing: root.closeAfterAdd === "close"
      readonly property var hints: [
        {
          key: "↵",
          text: closing ? FoamyI18n.t("add and close") : FoamyI18n.t("add, keep typing")
        },
        {
          key: "⇧↵",
          text: closing ? FoamyI18n.t("add, keep typing") : FoamyI18n.t("add and close")
        },
        {
          key: "Esc",
          text: FoamyI18n.t("cancel")
        }
      ]
      Repeater {
        model: keyHints.hints
        Row {
          id: hint
          required property var modelData
          required property int index
          objectName: "keyHint" + index
          readonly property string label: modelData.text
          spacing: FoamyStyle.gapSmall
          KeyCap {
            anchors.verticalCenter: parent.verticalCenter
            text: hint.modelData.key
          }
          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            text: hint.modelData.text
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.bodySmall
            color: FoamyPalette.secondaryText
          }
        }
      }
    }
  }

  TodoSettings {
    id: settingsView
    visible: root.editingSettings
    width: parent.width
    height: parent.height
    preferences: root.preferences
    saving: root.saving
    error: root.settingsError
    retryable: root.retryable
    onBack: root.settingsClosed()
    onRetry: root.retryRequested()
    onSaveRequested: function (key, value) {
      root.saveRequested(key, value)
    }
  }
}
