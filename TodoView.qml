pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "kit/FoamyText.js" as FoamyText
import "Preferences.js" as Schema
import "Model.js" as Model

// The panel, in both sizes: the band (the title row; + and Search grow
// the band's field), the tab row (Small) or the rail (Wide), the list, the
// footer, and the settings page in place of all of it. Small opens a task
// on the editor page in place of the list; Wide shows it in the details
// pane beside the list, and has the Week view. Wide's pane is always there
// beside a list: the selected task's details, else an overview of the view
// (Overview.qml; Tab goes into it). The Week view shows the pane beside its
// (narrowed) columns only while a card is open in it.
//
// The band field: + (or `a`) and Search (or `/`) open it, growing from
// their button over the title row. Adding, it colours the Quick Add tokens
// and the footer says what the keys do now (an empty field: Quick Add's
// forms instead, as Enter does nothing; the suggestion list's own keys
// while it shows); Enter adds and does what "After adding a task" says
// (close the panel, or keep the field open), Shift+Enter the other. Esc
// clears the text, then closes the field; the field's × closes it at once.
// An empty field closes when its edit ends without the keys (not for its
// own right-click menu); one with text stays open. A failed add says why
// at the field: its border and a strip hanging from it in the reason's
// tone (TodoStore.addErrorKind), over the tab row, so no row moves.
//
// Wide: the field spans only the list column (the band's field slot);
// the title stays over the rail and +, Search and ⋯ over the pane, usable
// while it is open (+ gives the keys back to the field). The suggestions
// are a menu under the word being typed.
//
// One cursor (FoamyCursor) over the stops, in on-screen order: +, Search,
// ⋯ (the band's, while its field is closed; in Wide always), the tabs or
// the rail, each list row that does something
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
  property bool editingSettings: false
  property bool addOnOpen: false
  property var preferences: ({})
  // The Panel's FoamyPrefsQueue, for the settings page's choices.
  property FoamyPrefsQueue prefs: null
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
    var row = keyTarget()
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
  // Search lists its results from the first character typed; until then
  // the open view stays, with its tab or rail row, so the panel keeps its
  // place.
  readonly property bool searchActive: searching && query.trim() !== ""
  readonly property string listView: searchActive ? "search" : view
  readonly property bool weekShown: view === "week" && !searchActive
  // Small: the list's height when search started; results never make the
  // card shorter than that while searching (Wide holds its height anyway).
  property real searchHeldHeight: 0
  readonly property int searchCount: searchActive ? rows.reduce(function (sum, row) {
    return sum + (row.kind === "task" ? 1 : 0)
  }, 0) : 0
  readonly property var store: TodoStore
  readonly property var rows: !live || weekShown ? [] : Model.rows(store.model, listView, store.today, {
    struck: store.struck,
    moves: store.shownMoves,
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
    moves: store.shownMoves,
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
    weekAddColumn = ""
    weekPaneOpen = false
    // Not a reason nobody has seen yet: it stays with its draft.
    if (!store.addUnseen)
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
  onWideChanged: {
    releaseHeight()
    if (!wide && view === "week")
      setView("today")
  }
  readonly property var viewKeys: ["inbox", "today", "upcoming"]

  // ---- cursor stops ------------------------------------------------------------------
  // The band's buttons are stops only while its field is closed.
  readonly property int addStop: 0
  // Search.
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
    viewCursor.byKeys = true
    if (stop === railStop)
      railCursor = railIndexOfView()
    if (stop === firstRowStop && weekShown && !weekCurrent())
      weekHome()
    noteWeekDay()
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
  // Todoist: no row selected, the cursor gone, the pane on the view's
  // overview (closed over the Week view). The pane's draft is saved as it
  // lets the task go (TaskEditor.show()). Clicks in the pane never reach
  // the list.
  function clearSelection() {
    viewCursor.index = -1
    upcomingDay = ""
    weekAddColumn = ""
    paneTask = ""
    weekPaneOpen = false
  }
  // The band's field: add or search, over the title row.
  property bool fieldOpen: false
  readonly property bool adding: fieldOpen && !searching
  readonly property bool fieldFocused: addField.inputActiveFocus
  onFieldFocusedChanged: if (fieldFocused)
    viewCursor.index = -1
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
  // the keys back first, which ends the field's edit: an empty field
  // closes (onEditingFinished). With the field's own menu open, the press
  // closes the menu and the keys come back to the field before the click.
  // Suggestions never call it: the field keeps the keys there.
  function leaveField() {
    if (fieldFocused)
      focusList()
  }
  // Closes the field (the band's title row comes back); the cursor goes to
  // the button it grew from when the field had the keys. The field itself
  // says whether it has them: at the end of its edit (editingFinished) the
  // fieldFocused binding may not have caught up yet.
  function closeField() {
    var hadKeys = addField.inputActiveFocus
    fieldOpen = false
    clearSuggest()
    addField.text = ""
    if (hadKeys) {
      viewCursor.index = addStop
      focusList()
    }
  }
  // The field's ×: the add's text and its reason go, the field closes (as
  // Esc twice); in search, search ends.
  function cancelField() {
    if (searching) {
      leaveSearch()
      return
    }
    store.sentKept = false
    store.addError = ""
    store.addDraft = ""
    addField.text = ""
    closeField()
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
      searchHeldHeight = wide ? 0 : listHeight
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
    searchHeldHeight = 0
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
  // No match: the query becomes a new task (only when search didn't put
  // an add draft aside, which would come back in the field).
  function addQuery() {
    var text = query.trim()
    if (text === "" || searchDraft !== "")
      return
    leaveSearch()
    // The text hides the placeholder that would name a remembered Week
    // day: the view's own day (today) then.
    weekAddColumn = ""
    openAdd()
    // Put in by the view, not typed after a sent text.
    store.sentKept = false
    addField.text = text
    addField.cursorPosition = text.length
  }
  // ---- moving tasks to another day -----------------------------------------------
  // The menu of days for a task (a row's date action, or `d` on the cursor
  // row): Today, Tomorrow, Next week (the start of the locale's next
  // week), No date. A pick moves it, undoable (TodoStore.move).
  property string dateMenuTask: ""
  readonly property alias dateMenuItem: dateMenu
  // The menu task's day as it stands (a pending move's), "" for none: its
  // entry is checked, so the keys start on it.
  readonly property string dateMenuDay: {
    var task = store.model.byId[dateMenuTask]
    if (!task)
      return "-"
    return Model.has(store.shownMoves, dateMenuTask) ? store.shownMoves[dateMenuTask] : task.due ? task.due.day : ""
  }
  function openDateMenu(id, anchor, keyboard) {
    var task = store.model.byId[id]
    if (!task || !store.canMove(id))
      return
    // A repeating task: why at once, not after a pick.
    var refusal = store.moveRefusal(id)
    if (refusal !== "") {
      store.editRefused(refusal)
      return
    }
    const stop = stopOf(id)
    const built = !anchor && stop >= 0 ? taskList.itemAtIndex(stops[stop - firstRowStop]) as TaskRow : null
    const at = anchor || (built ? built.dateAction : null)
    if (!at)
      return
    dateMenuTask = id
    dateMenu.anchorItem = at
    dateMenu.open(keyboard)
  }
  function moveFromMenu(day) {
    store.move(dateMenuTask, day)
  }
  readonly property string nextWeekDay: Model.addDays(Model.weekEndOf(store.today, weekStart), 1)
  // A row under Today's Overdue heading: its task's own date is past, also
  // while a move shows it with a new day.
  function overdueRow(row) {
    var task = store.model.byId[row.id]
    return !!task && !!task.due && task.due.day < store.today
  }
  // Shift+T moves Today's Overdue tasks when the key's task (keyTarget) is
  // one of them, not in search. The key and Move to today's tooltip both
  // ask here.
  function moveAllKeyActs(row) {
    return !!row && row.kind === "task" && view === "today" && !searchActive && overdueRow(row)
  }
  readonly property bool moveAllKeyHere: moveAllKeyActs(keyTarget())
  // Today's Overdue heading: each of its tasks to today. A repeating task
  // stays (the error line says why).
  function moveOverdueToToday() {
    store.moveAll(rows.filter(function (row) {
      return row.kind === "task" && row.overdue && !row.struck && !row.moved
    }).map(function (row) {
      return row.id
    }), store.today)
  }
  FoamyMenu {
    id: dateMenu
    onAboutToOpen: root.store.holdUndo(true)
    onClosed: root.store.holdUndo(false)
    FoamyMenuItem {
      objectName: "dateToday"
      checked: root.dateMenuDay === root.store.today
      text: FoamyI18n.t("Today")
      iconName: "calendar"
      onTriggered: root.moveFromMenu(root.store.today)
    }
    FoamyMenuItem {
      objectName: "dateTomorrow"
      checked: root.dateMenuDay === Model.addDays(root.store.today, 1)
      text: FoamyI18n.t("Tomorrow")
      iconName: "sun"
      onTriggered: root.moveFromMenu(Model.addDays(root.store.today, 1))
    }
    FoamyMenuItem {
      objectName: "dateNextWeek"
      checked: root.dateMenuDay === root.nextWeekDay
      text: FoamyI18n.t("Next week")
      iconName: "calendar-range"
      onTriggered: root.moveFromMenu(root.nextWeekDay)
    }
    FoamyMenuItem {
      separator: true
    }
    FoamyMenuItem {
      objectName: "dateNone"
      checked: root.dateMenuDay === ""
      text: FoamyI18n.t("No date")
      iconName: "x"
      onTriggered: root.moveFromMenu("")
    }
  }
  // The task row under the cursor (the Week view's card), or null.
  function cursorRow() {
    if (weekShown)
      return on(firstRowStop) ? weekCurrent() : null
    var i = viewCursor.index - firstRowStop
    return i >= 0 && i < stops.length ? rows[stops[i]] : null
  }
  // The task row (or Week card) a key acts on: the cursor's, except in
  // Wide while the pane shows a task and the pointer has put the cursor
  // on another one (hover lights a row, the pane stays): then the pane's,
  // the task being read. The arrow keys still move from the cursor. The
  // pane's task is its list row, else (the Week view, or not listed) its
  // id alone (see paneTarget for `d`).
  function keyTarget() {
    var row = cursorRow()
    // A completion on its way is no task to act on: the cursor's row then.
    if (!paneShown || viewCursor.byKeys || !row || row.kind !== "task" || row.id === paneTask || Model.has(store.sending, paneTask))
      return row
    var stop = stopOf(paneTask)
    return stop >= 0 ? rows[stops[stop - firstRowStop]] : {
      kind: "task",
      id: paneTask
    }
  }
  // A key's task is the pane's, not the cursor's row. `d` then opens the
  // pane's own Date menu: its row may be out of view (not built) or not in
  // this list at all, and the pane is where that task is read.
  function paneTarget(row) {
    var at = cursorRow()
    return !!row && paneShown && row.id === paneTask && (!at || at.id !== row.id)
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
      // Upcoming's add date: the day group the cursor was last in (it stays
      // when the cursor leaves for the add field); tomorrow in the week and
      // month groups, or once the selection is cleared (clearSelection).
      if (row && row.kind === "task" && root.view === "upcoming" && !root.searchActive)
        root.upcomingDay = row.group === "day" ? row.dueDay : ""
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
    noteWeekDay()
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
          // The cursor's card moved (Ctrl+←/→, a typed date, a sync): the
          // add day is its new column's.
          noteWeekDay()
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
  // The views at the rail's top (fixed); the label and the projects after
  // them scroll.
  readonly property int railViewCount: railEntries.filter(function (entry) {
    return entry.kind === "view"
  }).length
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
        if (i >= railViewCount)
          railWheel.ensureVisible(railRows.itemAt(i - railViewCount))
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
  // The pane's surface: beside every list, over the Week view only with a task.
  readonly property bool paneOpen: wide && !editingSettings && store.signedIn && store.loaded && (!weekShown || paneShown)
  // No task in the pane: the overview of the view, built only then and
  // while the view is live (as the rows).
  readonly property bool overviewShown: paneOpen && !paneShown
  readonly property var overviewData: live && overviewShown ? Model.overview(store.model, listView, store.today, {
    hidden: store.sending,
    hideOthers: store.hideOthers,
    struck: store.struck,
    weekStart: weekStart,
    projectId: projectId,
    query: query,
    projectCounts: store.counts.projects,
    nowMinutes: nowMinutes
  }) : null
  // The list's next time ahead today (its row's time stands out).
  readonly property string nextTimedId: {
    var best = null
    for (const row of rows)
      if (row.kind === "task" && row.dueDay === store.today && row.dueMinutes > nowMinutes && !row.struck && (!best || row.dueMinutes < best.dueMinutes))
        best = row
    return best ? best.id : ""
  }
  // The store's clock (tests set it), read again on each minute tick
  // (the wall clock's date is the binding's dependency).
  readonly property int nowMinutes: minutesOf(clock.date, store.now())
  function minutesOf(tick, now) {
    return now.getHours() * 60 + now.getMinutes()
  }
  // The overview's clicks. A task (a timeline block, Next, the next
  // deadline): selected, as a click on its row (the pane shows it, the
  // list scrolls to it; Upcoming opens its Overdue fold for it).
  function selectTask(id) {
    var task = Model.validId(id) ? store.model.byId[id] : null
    if (!task)
      return
    focusList()
    if (view === "upcoming" && !searchActive && task.due && task.due.day < store.today)
      overdueOpen = true
    var stop = stopOf(id)
    if (stop >= 0) {
      goTo(stop)
      // Picked with the pointer (the overview): not the keys' look.
      viewCursor.byKeys = false
    } else
      paneTask = id
  }
  // A section ("" for the tasks without one): the list scrolls to it.
  function showSection(id) {
    var key = "header:section:" + id
    for (let i = 0; i < rows.length; i++)
      if (id === "" ? rows[i].kind === "task" : rows[i].key === key) {
        taskList.positionViewAtIndex(i, ListView.Beginning)
        return
      }
  }
  // A label: the list filtered by it, through search (`@name`, its spaces
  // escaped as Quick Add reads them).
  function searchLabel(name) {
    startSearch()
    var text = "@" + String(name).replace(/ /g, "\\ ")
    addField.text = text
    addField.cursorPosition = text.length
    query = text
  }
  // An Upcoming day: lit (the list's add goes to it), the list at its first
  // task (the day's heading when it has one), else at the next day's.
  function showDay(day) {
    if (!Model.validDate(day))
      return
    upcomingDay = day
    for (let i = 0; i < rows.length; i++)
      if (rows[i].kind === "task" && rows[i].dueDay >= day && rows[i].dueDay > store.today) {
        const header = i > 0 && rows[i - 1].kind === "header" ? i - 1 : i
        taskList.positionViewAtIndex(header, ListView.Beginning)
        return
      }
  }
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
  // This view shows the add field with why its last add failed (the
  // list's error line): the bar buttons' mark goes. Not on Settings or
  // Small's editor page, where the line is out of sight.
  // A failed add's reason nobody has seen, its draft set aside by a search:
  // the search's own edits (typing, Esc on the query, a refused paste)
  // don't end it; it comes back with the draft when the search ends.
  readonly property bool reasonKept: searching && searchDraft !== "" && store.addUnseen
  readonly property bool addErrorShown: active && store.signedIn && !editingSettings && !pageShown && fieldOpen && !searching && addError !== ""
  // Checked a call later, once the change has settled: a popup closing
  // from Settings hides the page before `active` follows, which would
  // show the line for that moment.
  function noteAddErrorSeen() {
    Qt.callLater(function () {
      if (root.addErrorShown && root.store.addUnseen)
        root.store.addUnseen = false
    })
  }
  onAddErrorShownChanged: if (addErrorShown)
    noteAddErrorSeen()
  // The add's reason at the field (its border, the strip under it) while
  // the add field is open; else on the list's error line.
  readonly property bool addErrorAtField: fieldOpen && !searching && addError !== ""
  // Yellow when the task may exist (no answer) or exists with a warning:
  // adding it again may make two. Red when it can be sent again.
  readonly property color addErrorTone: store.addErrorKind === "unknown" || store.addErrorKind === "added" ? FoamyPalette.warning : FoamyPalette.error
  // Enter sends the refused text again.
  readonly property bool addRetries: addErrorAtField && store.addErrorKind === "refused"
  // Nothing to add: Enter does nothing, the footer shows Quick Add's forms.
  readonly property bool addEmpty: adding && addField.text.trim() === "" && !suggestOpen
  readonly property bool addBusy: store.addPending
  readonly property string addDay: view === "today" ? store.today : view === "upcoming" ? (upcomingDay || Model.addDays(store.today, 1)) : view === "week" ? weekAddDay : ""
  // The Week view's add date: the day of the column the cursor was last
  // on (Overdue and Today today, Tomorrow tomorrow, Later the card's own
  // day, a pending move's). It stays when the cursor leaves the board for
  // + or the field, as Upcoming keeps its day; today until the cursor has
  // been on the board, and once the selection is cleared. Kept as the
  // column (and Later's day), so "tomorrow" is right after midnight too.
  property string weekAddColumn: ""
  property string weekAddLater: ""
  readonly property string weekAddDay: weekAddColumn === "tomorrow" ? Model.addDays(store.today, 1) : weekAddColumn === "later" ? weekAddLater : store.today
  function noteWeekDay() {
    // A draft keeps the day it was started for: its text hides the
    // placeholder that would name another.
    if (adding && addField.text !== "")
      return
    var card = weekShown && on(firstRowStop) ? weekCurrent() : null
    if (!card)
      return
    weekAddColumn = weekColumns[weekColumn].key
    weekAddLater = weekAddColumn === "later" ? card.dueDay : ""
  }
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
    // A failure that arrives while this view shows the line is seen.
    function onAddUnseenChanged() {
      if (root.store.addUnseen)
        root.noteAddErrorSeen()
    }
    // Added: what was added leaves the field, also after the popup closed
    // or a search started. Text typed after it while the add was on its
    // way (the field stays open for the next task) stays, without the
    // spaces before it; text that no longer starts with it stays whole
    // (TodoStore.sentKept, per shell: the field may be another monitor's).
    function onFieldAdded(sent, kept) {
      var text = root.field.text
      var rest = root.store.afterAdd(text, sent, kept)
      if (!root.searching && rest !== text) {
        // The caret keeps its place in what stays.
        const caret = root.field.cursorPosition
        root.field.text = rest
        root.field.cursorPosition = Math.max(0, caret - (text.length - rest.length))
      }
      root.searchDraft = root.store.afterAdd(root.searchDraft, sent, kept)
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
      return searching ? leaveSearch() : startSearch()
    // The stop is ⋯, or the gear alone while signed out (no menu entries).
    if (at === menuStop)
      return heroBand.menuButton.visible ? heroBand.openMenu(true) : root.settingsRequested()
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
    var row = keyTarget()
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
  // A moved Week card shows no Undo: Space completes it (dropping the
  // move); on a list row Space undoes a move, as its Undo does.
  function completeTask(id) {
    if (taskEditor.shownId === id)
      taskEditor.commit()
    if (weekShown && Model.has(store.moves, id))
      store.complete(id)
    else
      store.toggleComplete(id)
  }
  function openViewInTodoist() {
    store.openView(view === "week" ? "upcoming" : view, projectId)
  }
  onActivateRequested: {
    var enter = enterPressed
    enterPressed = false
    activate(enter)
  }
  onMoveRequested: function (dx, dy) {
    viewCursor.byKeys = true
    var from = viewCursor.index
    arrow(dx, dy)
    // An arrow with nowhere to go (→ on a task, ↓ on the last row) still
    // gives the keys the cursor the pointer left there: the pane shows that
    // row, as after any arrow.
    if (viewCursor.index === from)
      followPane()
  }
  function arrow(dx, dy) {
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
  // selection clears, and the pane shows the overview); then the panel.
  onCloseRequested: {
    if (weekShown && weekPaneOpen)
      weekPaneOpen = false
    else if (!weekShown && paneShown)
      clearSelection()
    else
      root.closeView()
  }
  // Tab: the next panel; in Wide, into the details pane (the task's
  // fields, or the overview's first click target).
  onTabRequested: function (direction) {
    if (paneShown && taskEditor.task)
      taskEditor.focusFirst()
    else if (!(overviewShown && overviewPane.focusFirst()))
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
    var row = keyTarget()
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
    else if (text === "d" && row && row.kind === "task" && !weekShown) {
      if (paneTarget(row))
        taskEditor.openDateMenu(true)
      else
        openDateMenu(row.id, null, true)
    } else if (text === "T" && (modifiers & Qt.ShiftModifier) && moveAllKeyActs(row))
      // Shift+t, not Caps Lock's "T" (a plain `t` there is no key, as the others).
      moveOverdueToToday()
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
      store.addErrorKind = ""
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
  // The word at the caret already is the highlighted entry ("#home" typed
  // in full): Enter adds the task instead of inserting it again.
  readonly property bool suggestTyped: suggestOpen && Model.suggestionTyped(addField.text, suggest, suggest.items[suggestIndex])
  // The list's keys while it shows: true when the key was its.
  function suggestKey(event) {
    if (!suggestOpen)
      return false
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      const last = suggest.items.length - 1
      suggestIndex = Math.max(0, Math.min(last, suggestIndex + (event.key === Qt.Key_Down ? 1 : -1)))
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && suggestTyped) {
      return false
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
        // A search's query cleared: the add's draft, set aside, is as it
        // was (still typed after the sent text, its unseen reason kept).
        if (!searching) {
          store.sentKept = false
          store.addError = ""
          store.addDraft = ""
        } else if (!reasonKept)
          store.addError = ""
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
    var draftKind = store.addErrorKind
    editingTask = ""
    paneTask = ""
    setView(next, store.lastProject)
    store.addErrorKind = draftError !== "" ? draftKind : ""
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
    if (store.addDraft === "" && !store.addPending) {
      store.addError = ""
      // No draft for the reason to come back with: nothing to see.
      store.addUnseen = false
    }
    viewCursor.reset()
    heroBand.closeMenu()
  }
  // The hold starts from the view the popup opens on (prepare sets it).
  onActiveChanged: {
    if (active) {
      prepare()
    } else {
      closed()
    }
    releaseHeight()
  }
  // The popup builds this view on its first open with `active` already true.
  // A menu of days open as the view goes: its undo hold goes too.
  Component.onDestruction: store.holdUndo(false)
  Component.onCompleted: if (active) {
    prepare()
    releaseHeight()
  }
  // When Settings hides (Back, or the reset as the popup closes), FoamyPopup
  // gives the keys the page had to foamyKeyHome (keyFocus), as focusList().
  onEditingSettingsChanged: {
    if (editingSettings) {
      heroBand.closeMenu()
      viewCursor.reset()
      settingsView.resetScroll()
      Qt.callLater(settingsView.focusBack)
    }
  }
  blocked: editingSettings || pageShown || heroBand.menuOpen || dateMenu.opened || fieldFocused || taskEditor.activeFocus || taskEditor.menuOpen || overviewPane.activeFocus
  // A minute tick for "Updated …" while the popup is open.
  FoamyWallClock {
    id: clock
    enabled: root.active
  }

  implicitWidth: wide ? Commons.Style.space(880) : FoamyStyle.popupWidth
  // 18 rows; the popup also stops at 70% of the screen (Panel.qml).
  readonly property real maxListHeight: FoamyStyle.rowHeight * 18
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
  // The suggestion list and the add's strip float over the rows; the list
  // pane reaches at least their bottom while they show, so they stay
  // inside the card (the rows' own height counts from the pane's top).
  readonly property real floatBottom: Math.max(suggestions.visible ? suggestions.y + suggestions.height : 0, addErrorStrip.visible ? addErrorStrip.y + addErrorStrip.height : 0)
  readonly property real listHeight: Math.max(stateBox.visible ? stateBox.implicitHeight : weekShown ? Math.min(weekView.implicitHeight, maxListHeight) : Math.min(rowsHeight, maxListHeight), floatBottom - content.y - FoamyStyle.gap, searching ? searchHeldHeight : 0)
  // The list pane around the rows: a gap, the error lines (when shown), and a gap.
  readonly property real listChrome: FoamyStyle.gap + (errorLine.visible ? errorLine.height + FoamyStyle.gapSmall : 0) + FoamyStyle.gap
  readonly property real railHeight: Math.min(railViews.implicitHeight + railColumn.implicitHeight + FoamyStyle.gap * 2, maxListHeight)
  // The pane (also over the Week view, which then grows to show it).
  readonly property real paneHeight: paneShown ? Math.min(taskEditor.implicitHeight, maxListHeight) : overviewShown ? Math.min(overviewPane.implicitHeight, maxListHeight) : 0
  // Wide keeps its height while it is open, as it keeps its width: the body
  // is never lower than 12 rows, and never lower than the tallest it has
  // been since the popup opened (a view or a task that needs more grows it
  // once; nothing shrinks it). The columns stay top-aligned with the spare
  // room at their bottom, so the footer does not move. Closing the popup,
  // or a change of size, lets the height go (releaseHeight).
  readonly property real bodyFloor: FoamyStyle.rowHeight * 12
  readonly property real fittedBodyHeight: Math.max(railHeight, listChrome + listHeight, paneHeight)
  property real heldBodyHeight: 0
  onFittedBodyHeightChanged: if (wide && active && fittedBodyHeight > heldBodyHeight)
    heldBodyHeight = fittedBodyHeight
  // Starts the hold again from what the body needs now.
  function releaseHeight() {
    heldBodyHeight = wide && active ? fittedBodyHeight : 0
  }
  readonly property real bodyHeight: wide ? Math.min(maxListHeight, Math.max(bodyFloor, heldBodyHeight, fittedBodyHeight)) : (tabsBox.visible ? tabsBox.height : 0) + listChrome + listHeight
  implicitHeight: editingSettings ? settingsView.implicitHeight : pageShown ? taskEditor.implicitHeight : heroBand.implicitHeight + bodyHeight + (panelFooter.visible ? panelFooter.implicitHeight : 0)

  // ---- the band ----------------------------------------------------------------------------
  // Wide's field slot: the list column less gapLarge each side, never over
  // the band's buttons; none (width -1) in Small or without the rail.
  readonly property var fieldSlot: {
    if (!wide || !rail.visible)
      return {
        x: 0,
        width: -1
      }
    var left = listArea.x + FoamyStyle.gapLarge
    var right = listArea.x + listArea.width - FoamyStyle.gapLarge
    var buttons = heroBand.titleRow.buttonsWidth + FoamyStyle.gapLarge
    if (LayoutMirroring.enabled)
      left = Math.max(left, FoamyStyle.padding + buttons)
    else
      right = Math.min(right, width - FoamyStyle.padding - buttons)
    return {
      x: left,
      width: Math.max(0, right - left)
    }
  }
  readonly property string viewTitle: view === "project" && store.model.projects[projectId] ? store.model.projects[projectId].name : ""
  readonly property string meta: {
    if (!store.signedIn || !store.loaded)
      return ""
    var counts = store.counts
    if (searching)
      return FoamyI18n.t("Search")
    // Wide with the field open: the title column ends at the rail, which
    // names the view, so the line is the count alone.
    if (wide && fieldOpen) {
      if (view === "today")
        return counts.overdue ? FoamyI18n.tn("%1 left", counts.today) + " · " + FoamyI18n.tn("%1 overdue", counts.overdue) : FoamyI18n.tn("%1 left", counts.today)
      if (view === "upcoming")
        return FoamyI18n.tn("%1 tasks in the next 7 days", counts.week)
      return FoamyI18n.tn("%1 tasks", view === "inbox" ? counts.inbox : view === "week" ? weekCount : counts.projects[projectId] || 0)
    }
    // Small: the open tab names the view, so the line says the rest (Today:
    // the date first).
    if (!wide) {
      if (view === "inbox")
        return FoamyI18n.tn("%1 tasks", counts.inbox)
      if (view === "upcoming")
        return FoamyI18n.tn("%1 tasks in the next 7 days", counts.week)
      // It starts the line: a capital, as the rows' dates (Norwegian "tor.").
      const date = Model.capitalized(formatDate(Model.dayDate(store.today), translate("ddd d MMM")))
      const leftNow = date + " · " + FoamyI18n.tn("%1 left", counts.today)
      return counts.overdue ? leftNow + " · " + FoamyI18n.tn("%1 overdue", counts.overdue) : leftNow
    }
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
    // Wide: the field over the list column, clear of the buttons (the
    // Week view's list runs under them). Band coordinates as drawn: the
    // band and the body share x 0, and the anchored list mirrors in RTL.
    fieldX: root.fieldSlot.x
    fieldWidth: root.fieldSlot.width
    settingsHasCursor: viewCursor.at(root.menuStop)
    menuHasCursor: viewCursor.at(root.menuStop)
    cursorByKeys: viewCursor.byKeys
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
      // Signed out there is no view to open: the band keeps only Settings.
      FoamyMenuItem {
        objectName: "openInTodoist"
        visible: root.store.signedIn
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
        cursorByKeys: viewCursor.byKeys
        onHoveredChanged: if (hovered && !root.fieldFocused)
          viewCursor.hover(root.addStop)
        onClicked: root.openAdd()
      },
      FoamyAction {
        id: searchAction
        objectName: "searchAction"
        visible: root.store.signedIn
        iconName: "search"
        tooltipText: FoamyI18n.t("Search")
        hasCursor: viewCursor.at(root.searchStop)
        cursorByKeys: viewCursor.byKeys
        onHoveredChanged: if (hovered && !root.fieldFocused)
          viewCursor.hover(root.searchStop)
        onClicked: {
          root.leaveField()
          root.searching ? root.leaveSearch() : root.startSearch()
        }
      }
    ]
  }
  // The band's field (the band places and sizes it): the add or search
  // text, its icon, its × (a spinner while an add is on its way), and its
  // border in the add error's tone.
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
      // The icon at the reading start, the × (or the spinner in its place)
      // at the end: padding isn't mirrored, so RTL swaps the sides.
      readonly property real startPadding: FoamyStyle.iconSize + FoamyStyle.gap * 2
      readonly property real endPadding: fieldClose.width + (parent.height - fieldClose.height)
      leftPadding: LayoutMirroring.enabled ? endPadding : startPadding
      rightPadding: LayoutMirroring.enabled ? startPadding : endPadding
      Accessible.name: fieldBox.placeholder
      onTextEdited: {
        // Typing ends the add's reason (see reasonKept for a search's).
        if (!root.reasonKept)
          root.store.addError = ""
        if (root.store.sentKept && !root.searching && !text.startsWith(root.store.pendingAddText))
          root.store.sentKept = false
        if (root.searching)
          root.query = text
        root.suggestDismissed = false
        root.updateSuggest()
      }
      // A refused paste (pasteError, a catalog key) is the newest news:
      // like typing, it ends the add's error, so the line says why.
      onPasteErrorChanged: if (pasteError !== "" && !root.reasonKept)
        root.store.addError = ""
      // An empty add field closes when its edit ends without the keys (a
      // click elsewhere, ↓ into the list). The edit's end, not the focus
      // change: the field's own right-click menu takes the keys too, and
      // its Paste needs the field open.
      onEditingFinished: if (!inputActiveFocus && root.fieldOpen && !root.searching && text === "")
        root.closeField()
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
    // The add's reason: the field's border in its tone (the strip under
    // the field says it).
    Rectangle {
      objectName: "fieldErrorBorder"
      visible: root.addErrorAtField
      anchors.fill: parent
      radius: addField.cornerRadius
      color: "transparent"
      border.width: FoamyStyle.borderWidth
      // A thin mark on the band: read on the band's fill.
      border.color: FoamyPalette.onSurface(root.addErrorTone, FoamyPalette.bandFill)
    }
    // The way out for the pointer (Esc for the keys): search ends, an add
    // is cancelled (its text goes). The spinner takes its place while an
    // add is on its way.
    FoamyAction {
      id: fieldClose
      objectName: "fieldClose"
      visible: !spinner.visible
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: (parent.height - height) / 2
      iconName: "x"
      foreground: FoamyPalette.secondaryText
      tooltipText: root.searching ? FoamyI18n.t("Close search") : FoamyI18n.t("Cancel")
      onClicked: root.cancelField()
    }
    FoamyIcon {
      id: spinner
      objectName: "addSpinner"
      visible: root.addBusy && root.adding
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: (parent.height - width) / 2
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
      value: root.searchActive ? "" : root.view
      hasCursor: root.on(root.switchStop)
      cursorByKeys: viewCursor.byKeys
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
    // Search: how many tasks it found, at the row's end (no tab is
    // selected meanwhile).
    PlainText {
      objectName: "searchCount"
      visible: root.searchActive && root.searchCount > 0
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.gapLarge + FoamyStyle.rowPadding
      anchors.verticalCenter: parent.verticalCenter
      text: FoamyI18n.tn("%1 tasks", root.searchCount)
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.caption
      color: FoamyPalette.secondaryText
    }
  }

  // ---- the body ---------------------------------------------------------------------------------
  Item {
    id: content
    visible: !root.editingSettings && !root.pageShown
    anchors.top: tabsBox.visible ? tabsBox.bottom : heroBand.bottom
    anchors.bottom: panelFooter.visible ? panelFooter.top : parent.bottom
    // Anchored, not placed by x, so RTL puts the rail on the right.
    anchors.left: parent.left
    anchors.right: parent.right

    // The rail (Wide): the views, fixed; under them "My projects", which
    // scrolls alone, so the open view is always in sight. Where the
    // projects are cut, they fade, and a hairline under the views shows
    // they pass beneath.
    Component {
      id: railRowDelegate
      Item {
        id: railRow
        required property var modelData
        required property int index
        // The entry's place in railEntries (the projects' Repeater starts
        // after the views).
        readonly property int entry: modelData.kind === "view" ? index : index + root.railViewCount
        objectName: "rail-" + (modelData.value || "label")
        width: parent ? parent.width : 0
        height: modelData.kind === "label" ? FoamyStyle.rowHeight - 4 : FoamyStyle.rowHeight - 6
        readonly property bool selected: (modelData.kind === "view" && root.view === modelData.value && !root.searchActive) || (modelData.kind === "project" && root.view === "project" && root.projectId === modelData.value && !root.searchActive)
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
          hasCursor: root.on(root.railStop) && root.railCursor === railRow.entry
          byKeys: viewCursor.byKeys
          current: railRow.selected
          onHovered: if (!root.fieldFocused) {
            viewCursor.hover(root.railStop)
            root.railCursor = railRow.entry
          }
          onClicked: {
            root.leaveField()
            root.railActivate(railRow.entry)
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
            id: railText
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
            HoverHandler {
              id: railTextHover
            }
            // Cut: the whole name on hover, as the kit's tooltips: at most
            // 320 wide, 3 lines of 200 characters, wrapped anywhere.
            PanelToolTip {
              id: railTip
              objectName: "railTip"
              visible: railTextHover.hovered && railText.truncated
              text: FoamyText.cap(railRow.modelData.text, 3, 200)
              fontFamily: FoamyStyle.fontFamily
              implicitWidth: Math.min(implicitContentWidth + leftPadding + rightPadding, Commons.Style.space(320))
              Binding {
                target: railTip.contentItem
                property: "wrapMode"
                value: Text.WrapAtWordBoundaryOrAnywhere
                when: railTip.contentItem !== null
              }
            }
          }
          PlainText {
            id: railCount
            objectName: "railCount"
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: FoamyStyle.gap
            text: railRow.modelData.count > 0 ? FoamyI18n.number(railRow.modelData.count) : ""
            wrapMode: Text.NoWrap
            font.family: FoamyStyle.monoFamily
            font.pixelSize: FoamyStyle.font.caption
            // mutedText measures under 4.5:1, and secondaryText under it
            // on the selected row's fill: there the text's own colour.
            color: railRow.modelData.urgent ? FoamyPalette.onSurface(FoamyPalette.error) : railRow.selected ? FoamyPalette.text : FoamyPalette.secondaryText
          }
        }
      }
    }
    Item {
      id: rail
      objectName: "rail"
      visible: root.wide && root.store.signedIn && root.store.loaded
      anchors.left: parent.left
      width: visible ? 156 : 0
      height: parent.height
      Column {
        id: railViews
        y: FoamyStyle.gap
        x: FoamyStyle.gap
        width: rail.width - FoamyStyle.gap * 2
        Repeater {
          model: root.railEntries.slice(0, root.railViewCount)
          delegate: railRowDelegate
        }
      }
      Flickable {
        id: railScroll
        objectName: "railProjects"
        anchors.top: railViews.bottom
        anchors.bottom: parent.bottom
        width: parent.width
        contentHeight: railColumn.implicitHeight + FoamyStyle.gap
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        FoamyWheelScroll {
          id: railWheel
          target: railScroll
        }
        Column {
          id: railColumn
          x: FoamyStyle.gap
          width: rail.width - FoamyStyle.gap * 2
          Repeater {
            id: railRows
            model: root.railEntries.slice(root.railViewCount)
            delegate: railRowDelegate
          }
        }
      }
      Rectangle {
        objectName: "railScrolledLine"
        visible: !railScroll.atYBeginning
        anchors.top: railScroll.top
        x: FoamyStyle.gap
        z: 1
        width: parent.width - FoamyStyle.gap * 2
        height: FoamyStyle.borderWidth
        color: FoamyPalette.divider
      }
      Rectangle {
        objectName: "railFadeTop"
        visible: !railScroll.atYBeginning
        anchors.top: railScroll.top
        width: parent.width
        height: FoamyStyle.padding
        gradient: Gradient {
          GradientStop {
            position: 0
            color: FoamyPalette.background
          }
          GradientStop {
            position: 1
            color: Qt.alpha(FoamyPalette.background, 0)
          }
        }
      }
      Rectangle {
        objectName: "railFadeBottom"
        visible: !railScroll.atYEnd
        anchors.bottom: railScroll.bottom
        width: parent.width
        height: FoamyStyle.padding
        gradient: Gradient {
          GradientStop {
            position: 0
            color: Qt.alpha(FoamyPalette.background, 0)
          }
          GradientStop {
            position: 1
            color: FoamyPalette.background
          }
        }
      }
    }
    QtObject {
      id: railColors
      // `surface`: what it is drawn on, when not the popup's background.
      function of(role, surface) {
        // Marks and icons on the surface: readable in a light theme too.
        return role === "error" ? FoamyPalette.onSurface(FoamyPalette.error, surface) : role === "warning" ? FoamyPalette.onSurface(FoamyPalette.warning, surface) : role === "success" ? FoamyPalette.onSurface(FoamyPalette.success, surface) : role === "info" ? FoamyPalette.onSurface(FoamyPalette.info, surface) : role === "accent" ? FoamyPalette.onSurface(FoamyPalette.accent, surface) : FoamyPalette.mutedText
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
      // Beside it, the details pane at the reading end (the Week view
      // narrows its four columns for it).
      width: content.width - (rail.visible ? rail.width + FoamyStyle.borderWidth : 0) - (root.paneOpen ? root.paneWidth + FoamyStyle.borderWidth : 0)
      height: parent.height

      // The list's space that isn't a row (the margins, the error lines,
      // the Week view's headings): under everything in it.
      FoamyClickAway {
        anchors.fill: parent
        z: -1
        onClicked: root.clearSelection()
      }

      // Lines at the top: why the last add, sync or change failed, or why
      // the band's field refused a paste (an error, whole), and that the
      // snapshot was cut (a note, while rows show).
      Column {
        id: errorLine
        readonly property string message: root.addError !== "" && !root.addErrorAtField ? root.addError : addField.pasteError !== "" ? FoamyI18n.t(addField.pasteError) : root.store.loaded ? root.store.error : ""
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
          color: FoamyPalette.onSurface(FoamyPalette.error)
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
        // The list continues past an edge: the rows fade out there.
        Rectangle {
          objectName: "listFadeTop"
          visible: !taskList.atYBeginning
          parent: taskList
          z: 2
          width: taskList.width
          height: FoamyStyle.padding
          gradient: Gradient {
            GradientStop {
              position: 0
              color: FoamyPalette.background
            }
            GradientStop {
              position: 1
              color: Qt.alpha(FoamyPalette.background, 0)
            }
          }
        }
        Rectangle {
          objectName: "listFadeBottom"
          visible: !taskList.atYEnd
          parent: taskList
          z: 2
          y: taskList.height - height
          width: taskList.width
          height: FoamyStyle.padding
          gradient: Gradient {
            GradientStop {
              position: 0
              color: Qt.alpha(FoamyPalette.background, 0)
            }
            GradientStop {
              position: 1
              color: FoamyPalette.background
            }
          }
        }
        delegate: TaskRow {
          required property var modelData
          required property int index
          entry: modelData
          titleRuns: root.searchActive && modelData.kind === "task" ? Model.matchRuns(modelData.text, root.query) : []
          heading: modelData.kind === "header" && modelData.group ? Model.upcomingHeading(modelData, root.formatDate, root.translate) : null
          trailDay: modelData.kind === "task" ? Model.trailingDay(modelData, root.formatDate, root.translate) : ""
          dateText: modelData.kind === "task" ? Model.detailDate(modelData, root.formatDate, root.translate, root.store.today) : ""
          deadlineText: modelData.kind === "task" && modelData.deadline ? Model.dayWords(modelData.deadline, root.formatDate, root.translate, root.store.today) : ""
          timeTone: modelData.kind !== "task" || modelData.dueMinutes < 0 || modelData.dueDay !== root.store.today ? "" : modelData.dueMinutes <= root.nowMinutes ? "late" : modelData.id === root.nextTimedId ? "next" : "later"
          width: ListView.view.width
          height: root.heightOf(modelData)
          hasCursor: root.stopOfRow[index] >= 0 && viewCursor.index === root.stopOfRow[index]
          byKeys: viewCursor.byKeys
          // As keyTarget(): the pointer's cursor beside another task in the
          // pane leaves the keys with the pane's task.
          keysHere: !root.paneShown || viewCursor.byKeys || root.paneTask === modelData.id || Model.has(root.store.sending, root.paneTask)
          moveAllKey: root.moveAllKeyHere
          selected: root.paneShown && modelData.kind === "task" && root.paneTask === modelData.id
          onHovered: if (!root.fieldFocused && root.stopOfRow[index] >= 0)
            viewCursor.hover(root.stopOfRow[index])
          undoable: modelData.kind === "task" && (modelData.struck || Model.has(root.store.moves, modelData.id))
          showActions: hasCursor && modelData.kind === "task" && !modelData.recurring && !modelData.unconfirmed && !modelData.struck && !Model.has(root.store.shownMoves, modelData.id) && !root.fieldFocused
          onTomorrowRequested: {
            root.leaveField()
            root.store.moveToTomorrow(modelData.id)
          }
          onDateMenuRequested: root.openDateMenu(modelData.id, dateAction, false)
          onMoveAllRequested: {
            root.leaveField()
            root.moveOverdueToToday()
          }
          onCompleteRequested: {
            root.leaveField()
            root.completeTask(modelData.id)
          }
          onUndoRequested: {
            root.leaveField()
            root.store.undo(modelData.id)
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
        narrow: root.paneShown
        today: root.store.today
        columns: root.weekColumns
        hasCursor: root.on(root.firstRowStop)
        byKeys: viewCursor.byKeys
        cursorColumn: root.weekColumn
        cursorCard: root.weekCard
        selectedId: root.weekPaneOpen ? root.paneTask : ""
        keysTaskId: {
          var target = root.weekShown ? root.keyTarget() : null
          return target && target.kind === "task" ? target.id : ""
        }
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
        // A card's move action: what Ctrl+←/→ do, for the card it is on.
        onShiftRequested: function (id, delta) {
          root.leaveField()
          root.store.shiftDue(id, delta)
        }
        onSpaceClicked: root.clearSelection()
      }

      // Signed out, loading, empty, or failed without data: one line.
      Column {
        id: stateBox
        objectName: "stateBox"
        readonly property string kind: root.store.account === "unavailable" ? "unavailable" : root.store.account === "error" ? "accountError" : root.store.account === "checking" ? "loading" : !root.store.signedIn ? "signedOut" : !root.store.loaded ? (root.store.error !== "" ? "failed" : "loading") : root.weekShown || root.rows.length ? "" : "empty"
        visible: kind !== ""
        // Wide, an empty list: its line in the middle of the column (the
        // card keeps its height, see bodyHeight).
        readonly property bool centred: root.wide && kind === "empty"
        // A y, not anchors: switching between top and centre anchors would
        // hold both for a moment and stretch the column.
        y: centred ? Math.round((parent.height - implicitHeight) / 2) : errorLine.visible ? errorLine.y + errorLine.height : 0
        width: parent.width
        topPadding: FoamyStyle.gapLarge
        bottomPadding: FoamyStyle.gapLarge
        spacing: FoamyStyle.gap
        readonly property bool failure: kind === "failed" || kind === "accountError" || kind === "unavailable"
        // The helper's code for the failure shown ("" for none).
        readonly property string code: kind === "accountError" ? root.store.accountErrorCode : kind === "failed" ? root.store.errorCode : ""
        PlainText {
          objectName: "stateText"
          x: FoamyStyle.padding
          width: parent.width - FoamyStyle.padding * 2
          horizontalAlignment: Text.AlignHCenter
          font.pixelSize: FoamyStyle.font.bodySmall
          color: stateBox.failure ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.mutedText
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
              return root.searchActive && !root.store.model.truncated ? FoamyI18n.t("No open task matches “%1”", [root.query.trim()]) : FoamyI18n.t(Model.emptyText(root.listView, root.store.model.truncated))
            default:
              return ""
            }
          }
        }
        FoamyButton {
          id: stateButton
          objectName: "stateButton"
          // A token that can't be used (Todoist refused it, or the keyring
          // holds a value that isn't one) is fixed in Settings, with a new
          // token or Sign out: Retry would only get the same refusal. Other
          // failures, such as a locked keyring, can pass: Retry.
          readonly property bool opensSettings: stateBox.kind === "signedOut" || stateBox.code === "INVALID_TOKEN"
          // No match: the query as a new task.
          readonly property bool addsQuery: stateBox.kind === "empty" && root.searchActive && root.searchDraft === ""
          visible: stateBox.kind === "signedOut" || stateBox.kind === "failed" || stateBox.kind === "accountError" || addsQuery
          anchors.horizontalCenter: parent.horizontalCenter
          text: addsQuery ? FoamyI18n.t("Add as a task") : opensSettings ? FoamyI18n.t("Open settings") : FoamyI18n.t("Retry")
          iconName: addsQuery ? "plus" : ""
          kind: stateBox.kind === "signedOut" ? "primary" : "secondary"
          hasCursor: viewCursor.at(root.firstRowStop) && !root.stops.length
          cursorByKeys: viewCursor.byKeys
          onHoveredChanged: if (hovered)
            viewCursor.hover(root.firstRowStop)
          onClicked: addsQuery ? root.addQuery() : opensSettings ? root.settingsRequested() : root.store.retry()
        }
      }
    }
  }

  // What hangs from the open field (the suggestions, the add's reason):
  // the field's rectangle in the view, and a gapSmall under it.
  readonly property rect fieldRect: Qt.rect(heroBand.x + heroBand.fieldRect.x, heroBand.y + heroBand.fieldRect.y, heroBand.fieldRect.width, heroBand.fieldRect.height)
  readonly property real hangY: fieldRect.y + fieldRect.height + FoamyStyle.gapSmall

  // Where the text's character `start` stands in the field, from its
  // start edge. `moves`: what moves it, read by the caller's binding.
  function wordOffset(start, moves) {
    const editor = addField.editorItem as Controls.TextArea
    if (!editor)
      return 0
    const at = editor.positionToRectangle(start)
    return editor.mapToItem(fieldBox, at.x, 0).x
  }
  // The suggestions: a raised menu hanging from the field over the tab row
  // and the rows. Small: as wide as the field. Wide: a menu as wide as its
  // widest row, menuWidth to 320, its glyphs under the word being typed,
  // kept inside the field's extent. The field keeps the keys.
  FontMetrics {
    id: suggestMetrics
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
  }
  FontMetrics {
    id: suggestBold
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
    font.weight: Font.DemiBold
  }
  FoamyShadow {
    visible: suggestions.visible
    z: 19
    x: suggestions.x
    y: suggestions.y
    width: suggestions.width
    height: suggestions.height
    radius: suggestions.radius
  }
  Rectangle {
    id: suggestions
    objectName: "suggestions"
    visible: root.suggestOpen
    z: 20
    // Around a row's content: the border, the menu's and the row's padding.
    readonly property real inset: FoamyStyle.borderWidth + FoamyStyle.menuPadding + FoamyStyle.rowPadding
    // The widest row: the glyph, the name (its matched part DemiBold), a
    // person's email (bodySmall, measured at body: never short).
    readonly property real natural: !root.suggestOpen ? 0 : root.suggest.items.reduce(function (most, item) {
      var end = item.matchStart + item.matchLength
      var name = suggestMetrics.advanceWidth(item.name.slice(0, item.matchStart)) + suggestBold.advanceWidth(item.name.slice(item.matchStart, end)) + suggestMetrics.advanceWidth(item.name.slice(end))
      return Math.max(most, FoamyStyle.iconSize + FoamyStyle.gap + name + (item.email ? FoamyStyle.gap + suggestMetrics.advanceWidth(item.email) : 0))
    }, 0) + inset * 2 + FoamyStyle.gapTiny
    // Where the word being typed starts in the field (the editor's own x,
    // read again as the text or the caret moves).
    // Read again as the text, the caret or the field's growth move it (a
    // narrow field scrolls its text while it grows): those are the
    // binding's dependencies, passed to wordOffset.
    readonly property real wordX: root.suggestOpen && root.wide ? root.wordOffset(root.suggest.start, [addField.cursorPosition, addField.text, heroBand.fieldProgress, fieldBox.width]) : 0
    width: root.wide ? Math.min(root.fieldRect.width, Math.max(FoamyStyle.menuWidth, Math.min(Commons.Style.space(320), natural))) : root.fieldRect.width
    x: root.wide ? Math.max(root.fieldRect.x, Math.min(root.fieldRect.x + root.fieldRect.width - width, root.fieldRect.x + wordX - inset)) : root.fieldRect.x
    y: root.hangY
    height: suggestionColumn.implicitHeight + FoamyStyle.menuPadding * 2 + FoamyStyle.borderWidth * 2
    radius: FoamyStyle.radius
    color: FoamyPalette.raisedMenuFill
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.menuBorder
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
            id: suggestionLine
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
              color: railColors.of(suggestionRow.modelData.role, FoamyPalette.raisedMenuFill)
            }
            // The name, its matched part DemiBold (plain text runs, no markup).
            Row {
              anchors.verticalCenter: parent.verticalCenter
              PlainText {
                visible: !suggestionRow.isProject
                text: suggestionRow.sigil
                wrapMode: Text.NoWrap
                // Labels' @ in the info colour, as on task rows; / and + muted.
                color: suggestionRow.modelData.kind === "label" ? FoamyPalette.onSurface(FoamyPalette.info, FoamyPalette.raisedMenuFill) : FoamyPalette.mutedText
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
              // The rest, cut with "…" where the menu ends.
              PlainText {
                objectName: "suggestionRest"
                width: Math.min(implicitWidth, Math.max(0, suggestionLine.width - (suggestionRow.isProject ? FoamyStyle.iconSize + FoamyStyle.gap : 0) - x))
                text: suggestionRow.modelData.name.slice(suggestionRow.modelData.matchStart + suggestionRow.modelData.matchLength)
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
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

  // The add's reason, at the field: a strip hanging from it on the raised
  // surface, in the reason's tone (addErrorTone), over the tab row (Small:
  // it covers the row whole, so no tab's text is cut) and never moving a
  // row. Typing ends it (as the reason).
  FoamyShadow {
    visible: addErrorStrip.visible
    z: 19
    x: addErrorStrip.x
    y: addErrorStrip.y
    width: addErrorStrip.width
    height: addErrorStrip.height
    radius: addErrorStrip.radius
  }
  Rectangle {
    id: addErrorStrip
    objectName: "addErrorStrip"
    visible: root.addErrorAtField && !root.suggestOpen && heroBand.visible
    z: 20
    x: root.fieldRect.x
    y: root.hangY
    width: root.fieldRect.width
    height: Math.max(addErrorText.implicitHeight + FoamyStyle.gap * 2, tabsBox.visible ? tabsBox.y + tabsBox.height + FoamyStyle.gapSmall - y : 0)
    radius: FoamyStyle.radius
    color: FoamyPalette.raisedMenuFill
    border.width: FoamyStyle.borderWidth
    border.color: Qt.alpha(FoamyPalette.onSurface(root.addErrorTone, FoamyPalette.raisedMenuFill), 0.6)
    FoamyIcon {
      id: addErrorIcon
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.rowPadding
      anchors.verticalCenter: parent.verticalCenter
      width: FoamyStyle.iconSize
      height: width
      name: "triangle-alert"
      color: addErrorText.color
    }
    PlainText {
      id: addErrorText
      objectName: "addErrorText"
      anchors.left: addErrorIcon.right
      anchors.leftMargin: FoamyStyle.gap
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.rowPadding
      anchors.verticalCenter: parent.verticalCenter
      text: root.addError
      font.pixelSize: FoamyStyle.font.bodySmall
      color: FoamyPalette.onSurface(root.addErrorTone, FoamyPalette.raisedMenuFill)
      Accessible.role: Accessible.AlertMessage
    }
  }

  // ---- the details pane (Wide) and the editor (the page in Small) ------------------------
  readonly property real paneWidth: Commons.Style.space(270)
  // The pane's surface at the body's reading end. Anchored, so RTL puts it
  // on the left.
  Rectangle {
    visible: root.paneOpen
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
    // The pane's Close: as Esc in the list (the pane saves on the way out).
    onCloseRequested: {
      if (root.weekShown)
        root.weekPaneOpen = false
      else
        root.clearSelection()
      root.focusList()
    }
  }
  Overview {
    id: overviewPane
    objectName: "overview"
    visible: root.overviewShown
    z: 5
    anchors.right: content.right
    y: content.y
    width: root.paneWidth
    height: content.height
    summary: root.overviewData
    today: root.store.today
    litDay: root.view === "upcoming" && !root.searchActive ? root.addDay : ""
    format: root.formatDate
    translate: root.translate
    onTaskPicked: function (id) {
      root.leaveField()
      root.selectTask(id)
    }
    onSectionPicked: function (id) {
      root.leaveField()
      root.showSection(id)
    }
    onProjectPicked: function (id) {
      root.leaveField()
      root.setView("project", id)
    }
    onLabelPicked: function (name) {
      root.searchLabel(name)
    }
    onDayPicked: function (day) {
      root.leaveField()
      root.showDay(day)
    }
    onKeysReturned: root.focusList()
  }

  // ---- the footer ------------------------------------------------------------------------
  // Wide: the pane's save, in the freshness line's place for its moment
  // ("Saving…", then "Saved"). Small's editor page says "Saving…" in its
  // own band (the footer is hidden there). A failed save shows under its field.
  readonly property string saveStatus: !wide ? "" : taskEditor.saving ? FoamyI18n.t("Saving…") : taskEditor.savedShown ? FoamyI18n.t("Saved") : ""
  // An add draft stays open while the pane edits a task: the save's status
  // takes the key hints' place for its moment, then the hints come back.
  readonly property bool keyHintsShown: adding && saveStatus === ""
  // The Week board has the keys: the footer names them (README, Keyboard).
  readonly property bool weekHintsShown: weekShown && on(firstRowStop) && !blocked && !adding
  // Wide, a list view: the task the keys act on (keyTarget), whose keys
  // the footer names; null when there is none.
  readonly property var rowHintsTask: {
    if (!wide || weekShown || adding || blocked || saveStatus !== "")
      return null
    var row = keyTarget()
    return row && row.kind === "task" ? row : null
  }
  // Its keys: Space (undoes a completion or a move in its window), e, and
  // t and d when the task can move (not a repeating one).
  readonly property var rowHints: {
    var row = rowHintsTask
    if (!row)
      return []
    var undoes = !!row.struck || Model.has(store.moves, row.id)
    var hints = [
      {
        key: "Space",
        text: undoes ? FoamyI18n.t("Undo") : FoamyI18n.t("Complete")
      },
      {
        key: "e",
        text: FoamyI18n.t("Edit")
      }
    ]
    if (!undoes && store.canMove(row.id) && store.moveRefusal(row.id) === "")
      hints.push({
        key: "t",
        text: FoamyI18n.t("Tomorrow")
      }, {
        key: "d",
        text: FoamyI18n.t("Date")
      })
    return hints
  }
  // While adding, the keys and what they do; else where the tasks come
  // from, how fresh they are, and Refresh.
  FoamyPanelFooter {
    id: panelFooter
    objectName: "footer"
    visible: !root.editingSettings && !root.pageShown && root.store.signedIn
    anchors.bottom: parent.bottom
    width: parent.width
    horizontalPadding: FoamyStyle.padding
    // Wide: its own hairline, edge to edge (footerLine), closes the columns.
    divider: !root.wide
    // footerLine covers the footer's top pixel, so the row starts `spacing`
    // under it, as under the kit's own hairline: centred, and the footer as
    // tall as Small's.
    topPadding: root.wide ? panelFooter.spacing + 1 : 0
    // A launch that failed first (until the next one works), as foamy-clock's
    // footer; else, with cached data shown after a failed sync, the time of
    // the last good one.
    status: root.saveStatus !== "" ? root.saveStatus : root.adding ? "" : root.store.launchError !== "" ? root.store.launchError : root.store.syncing && root.store.loaded && clock.date.getTime() - root.store.syncedAt > root.store.refreshSeconds * 1000 ? FoamyI18n.t("Updating…") : FoamyI18n.updatedAgo(root.store.syncedAt, clock.date.getTime())
    statusError: !root.adding && root.saveStatus === "" && root.store.launchError !== ""
    showRefresh: !root.adding
    refreshing: root.store.syncing
    refreshEnabled: root.store.signedIn && !root.store.busy
    refreshHasCursor: viewCursor.at(root.refreshStop)
    cursorByKeys: viewCursor.byKeys
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
      cursorByKeys: viewCursor.byKeys
      onHoveredChanged: if (hovered && !root.fieldFocused)
        viewCursor.hover(root.openStop)
      onClicked: {
        root.leaveField()
        root.openViewInTodoist()
      }
    }
    // An empty add field (Enter does nothing yet): Quick Add's forms, each
    // in the colour the field gives it.
    Row {
      id: addLegend
      objectName: "addLegend"
      visible: root.keyHintsShown && root.addEmpty
      anchors.verticalCenter: parent ? parent.verticalCenter : undefined
      spacing: FoamyStyle.gapSmall
      Repeater {
        model: [
          {
            token: "#",
            color: root.tokenColors.project,
            text: FoamyI18n.t("project")
          },
          {
            token: "@",
            color: root.tokenColors.label,
            text: FoamyI18n.t("label")
          },
          {
            token: "p1",
            color: root.tokenColors.priority,
            text: FoamyI18n.t("priority")
          },
          {
            // A date Quick Add reads, in the text's own colour (dates aren't coloured).
            token: FoamyI18n.t("tomorrow 9am"),
            color: FoamyPalette.text,
            text: ""
          }
        ]
        Row {
          id: legendEntry
          required property var modelData
          required property int index
          objectName: "addLegend" + index
          readonly property string label: modelData.token + (modelData.text !== "" ? " " + modelData.text : "")
          spacing: FoamyStyle.gapSmall
          PlainText {
            visible: legendEntry.index > 0
            text: "·"
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.bodySmall
            color: FoamyPalette.mutedText
          }
          PlainText {
            objectName: "legendToken"
            text: legendEntry.modelData.token
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.bodySmall
            font.weight: legendEntry.modelData.text !== "" ? Font.DemiBold : Font.Normal
            color: legendEntry.modelData.color
          }
          PlainText {
            visible: text !== ""
            text: legendEntry.modelData.text
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.bodySmall
            color: FoamyPalette.secondaryText
          }
        }
      }
    }
    // What the keys do now. Adding: Enter and Shift+Enter as "After adding
    // a task" sets them (Enter retries an add Todoist refused), Esc; while
    // the suggestion list shows, its keys (Enter adds when the word already
    // is the highlighted entry; Tab inserts then). The Week board's keys
    // while it has them; in Wide's lists, the keys of the task they act on.
    Row {
      id: keyHints
      objectName: "keyHints"
      visible: (root.keyHintsShown && !root.addEmpty) || root.weekHintsShown || root.rowHintsTask !== null
      // On the footer's line (beside the taller Todoist action in Week).
      anchors.verticalCenter: parent ? parent.verticalCenter : undefined
      spacing: FoamyStyle.gapLarge
      readonly property bool closing: root.closeAfterAdd === "close"
      readonly property string enterText: closing ? FoamyI18n.t("Add and close") : FoamyI18n.t("Add, keep typing")
      readonly property var hints: root.weekHintsShown ? [
        {
          key: "t",
          text: FoamyI18n.t("Tomorrow")
        },
        {
          keys: ["Ctrl", "←", "→"],
          text: FoamyI18n.t("Move a day")
        },
        {
          key: "Space",
          text: FoamyI18n.t("Complete")
        },
        {
          key: "↵",
          text: FoamyI18n.t("Details")
        }
      ] : root.rowHintsTask !== null ? root.rowHints : root.suggestOpen ? [
        {
          key: "↑↓",
          text: FoamyI18n.t("Choose")
        }
      ].concat(root.suggestTyped ? [
        {
          key: "↵",
          text: enterText
        },
        {
          key: "Tab",
          text: FoamyI18n.t("Insert")
        }
      ] : [
        {
          key: "↵",
          also: "Tab",
          text: FoamyI18n.t("Insert")
        }
      ]).concat([
        {
          key: "Esc",
          text: FoamyI18n.t("Close list")
        }
      ]) : [
        {
          key: "↵",
          text: root.addRetries ? FoamyI18n.t("Retry") : enterText
        },
        {
          key: "⇧↵",
          text: closing ? FoamyI18n.t("Add, keep typing") : FoamyI18n.t("Add and close")
        },
        {
          key: "Esc",
          text: FoamyI18n.t("Cancel")
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
          // Its keys: one, one and a second that does the same (`also`),
          // or a chord's (`keys`).
          readonly property var caps: modelData.keys || [modelData.key].concat(modelData.also ? [modelData.also] : [])
          spacing: FoamyStyle.gapSmall
          Repeater {
            model: hint.caps
            // The tallest part: the hint's text centres on it.
            KeyCap {
              required property string modelData
              text: modelData
            }
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

  // Wide: the footer's hairline at the card's full width, where the rail's
  // and the pane's dividers end, so it closes the three columns.
  Rectangle {
    objectName: "footerLine"
    visible: panelFooter.visible && root.wide
    anchors.top: panelFooter.top
    width: parent.width
    height: 1
    color: FoamyPalette.divider
  }

  TodoSettings {
    id: settingsView
    visible: root.editingSettings
    width: parent.width
    height: parent.height
    // Wide's page is 880, its column the settings width (the kit's wide
    // one): Back and the title, the error line and the sections in it.
    columnWidth: root.wide ? FoamyStyle.popupWidthWide - FoamyStyle.padding * 2 : width - FoamyStyle.padding * 2
    preferences: root.preferences
    prefs: root.prefs
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
