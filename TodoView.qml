pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons as Commons
import qs.Ui
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Preferences.js" as Schema
import "Model.js" as Model

// The popup: the band (the title row), the tab row (standard width) or the
// rail (wide), the add slot at the top of the list, the list, the footer,
// and the settings page in place of all of it.
//
// The add slot is a quiet "Add task" row; Enter, Space, a click or `a`
// turn it into the add field in place (the search field too, for search).
// An empty field closes when it loses the keys or on Esc; one with text
// stays open.
//
// One cursor (FoamyCursor) over the stops, in on-screen order: Search, ⋯,
// the tabs (standard) or the rail (wide), the add slot, each list row that
// does something, the footer's Refresh. Nothing has the cursor on open.
// While the field has the keys the cursor is on the add slot (no row
// highlight) and the key catcher is blocked.
PanelKeyCatcher {
  id: root
  property bool active: true
  property bool wide: false
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

  // ---- the view ---------------------------------------------------------------------
  // inbox, today, upcoming, or project (wide only).
  property string view: "today"
  property string projectId: ""
  property bool searching: false
  property string query: ""
  property bool overdueOpen: false
  // Upcoming's add chip: the day of the group the cursor was in last.
  property string upcomingDay: ""
  readonly property string listView: searching ? "search" : view
  readonly property var store: TodoStore
  readonly property var rows: Model.rows(store.model, listView, store.today, {
    struck: store.struck,
    hidden: store.sending,
    hideOthers: store.hideOthers,
    unconfirmed: store.unconfirmed,
    overdueOpen: overdueOpen,
    weekStart: weekStart,
    projectId: projectId,
    query: query
  })
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
  // The locale's date formatting and the catalog, for Model's Upcoming texts.
  function formatDate(date, pattern) {
    return date.toLocaleDateString(Qt.locale(FoamyI18n.formatLocale), pattern)
  }
  function translate(key, values) {
    return FoamyI18n.t(key, values)
  }
  function setView(next, project) {
    if (next === "project" && (!wide || !Model.validId(project)))
      return
    // Search ends with the view (its query never becomes an add draft); an
    // add draft stays, whatever changed the view.
    leaveSearch()
    view = next
    projectId = next === "project" ? project : ""
    overdueOpen = false
    upcomingDay = ""
    store.addError = ""
    store.lastView = next
    store.lastProject = projectId
    taskList.positionViewAtBeginning()
    if (viewCursor.index >= firstRowStop && viewCursor.index !== refreshStop)
      viewCursor.index = stops.length ? firstRowStop : addStop
  }
  readonly property var viewKeys: ["inbox", "today", "upcoming"]

  // ---- cursor stops ------------------------------------------------------------------
  readonly property int searchStop: 0
  readonly property int menuStop: 1
  readonly property int switchStop: wide ? -1 : 2
  readonly property int railStop: wide ? 2 : -1
  readonly property int addStop: 3
  readonly property int firstRowStop: 4
  // A state's button (Open settings, Retry) is the one stop when there are no rows.
  readonly property int rowStops: stops.length ? stops.length : stateButton.visible ? 1 : 0
  // The footer: its Todoist button, then Refresh.
  readonly property int openStop: panelFooter.visible ? firstRowStop + rowStops : -1
  readonly property int refreshStop: panelFooter.visible ? openStop + 1 : -1
  FoamyCursor {
    id: viewCursor
    count: root.firstRowStop + root.rowStops + (panelFooter.visible ? 2 : 0)
  }
  // The cursor is on `stop` (a stop the layout doesn't have is -1: never).
  function on(stop) {
    return stop >= 0 && viewCursor.index === stop
  }
  function usable(stop) {
    if (stop === searchStop)
      return searchAction.visible
    if (stop === menuStop)
      return true
    if (stop === switchStop)
      return views.visible
    if (stop === addStop)
      return addSlot.visible
    if (stop === railStop)
      return rail.visible
    return stop >= firstRowStop && stop < viewCursor.count
  }
  // Moves along the stops, skipping hidden ones; from no cursor, an arrow
  // goes to the add row (else the first row).
  function step(delta) {
    var at = viewCursor.index
    if (at < 0) {
      if (usable(addStop))
        goTo(addStop)
      else if (rowStops)
        goTo(firstRowStop)
      return
    }
    for (let next = at + delta; next >= 0 && next < viewCursor.count; next += delta)
      if (usable(next)) {
        goTo(next)
        return
      }
  }
  function goTo(stop) {
    viewCursor.index = stop
    // An open field is the add slot's stop: it takes the keys there.
    if (stop === addStop && fieldOpen)
      addField.focusInput()
    else if (addField.inputActiveFocus)
      root.forceActiveFocus()
    if (stop === railStop)
      railCursor = railIndexOfView()
    reveal()
  }
  // The add slot shows the field (add or search) instead of the add row.
  property bool fieldOpen: false
  readonly property bool fieldFocused: addField.inputActiveFocus
  onFieldFocusedChanged: {
    if (fieldFocused)
      viewCursor.index = addStop
    else if (fieldOpen && !searching && addField.text === "")
      closeField()
  }
  // The add field, open and with the keys (search mode ends).
  function openField() {
    if (!store.signedIn)
      return
    if (searching)
      leaveSearch()
    fieldOpen = true
    viewCursor.index = addStop
    addField.focusInput()
  }
  // A click outside the editor (a tab, a ring, the rail, a button) takes
  // the keys back first, so an empty field closes as it does on any blur.
  // Suggestions never call it: the field keeps the keys there.
  function leaveField() {
    if (fieldFocused)
      root.forceActiveFocus()
  }
  // Back to the add row, the cursor on it.
  function closeField() {
    var hadKeys = fieldFocused
    fieldOpen = false
    clearSuggest()
    addField.text = ""
    if (viewCursor.index === addStop || hadKeys)
      viewCursor.index = addStop
    if (hadKeys)
      root.forceActiveFocus()
  }
  function startSearch() {
    if (!store.signedIn)
      return
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
    viewCursor.index = addStop
    addField.focusInput()
  }
  // The add draft the field held when search started ("" for none).
  property string searchDraft: ""
  // Ends search. A draft from before it comes back (the field open, the
  // caret at its end, the keys); without one, back to the Add row. When
  // the popup closes (`restore` false) the field just empties.
  function leaveSearch(restore) {
    if (!searching)
      return
    searching = false
    query = ""
    var draft = searchDraft
    searchDraft = ""
    if (restore === false || draft === "") {
      addField.text = ""
      if (restore !== false)
        closeField()
      return
    }
    addField.text = draft
    addField.cursorPosition = draft.length
    fieldOpen = true
    viewCursor.index = addStop
    addField.focusInput()
  }
  // The task row under the cursor, or null.
  function cursorRow() {
    var i = viewCursor.index - firstRowStop
    return i >= 0 && i < stops.length ? rows[stops[i]] : null
  }
  function reveal() {
    var i = viewCursor.index - firstRowStop
    if (i >= 0 && i < stops.length)
      taskList.positionViewAtIndex(stops[i], ListView.Contain)
  }
  // The cursor stays on its task when the rows change (a sync, a completion
  // leaving); when that task is gone, on the row that took its place.
  property string cursorKey: ""
  Connections {
    target: viewCursor
    function onIndexChanged() {
      var row = root.cursorRow()
      root.cursorKey = row ? row.key : ""
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
      viewCursor.index = last >= firstRowStop ? last : addSlot.visible ? addStop : -1
  }

  // ---- the rail (wide) ------------------------------------------------------------------
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

  // ---- adding ---------------------------------------------------------------------------
  // The add in flight and its outcome are the store's (once per shell):
  // a popup opened on another monitor before the reply shows it too.
  readonly property string addError: store.addError
  readonly property bool addBusy: store.addPending
  readonly property string addDay: view === "today" ? store.today : view === "upcoming" ? (upcomingDay || Model.addDays(store.today, 1)) : ""
  function submit() {
    if (searching) {
      if (stops.length)
        goTo(firstRowStop)
      return
    }
    var text = addField.text
    if (text.trim() === "" || addBusy || !store.signedIn)
      return
    store.addFromField(text, addDay, view === "project" ? projectId : "")
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

  // ---- activation ------------------------------------------------------------------------
  property bool enterPressed: false
  onReturnRequested: enterPressed = true
  function activate(enter) {
    var at = viewCursor.index
    if (at === searchStop)
      return searching ? leaveSearch() : startSearch()
    if (at === menuStop)
      return heroBand.openMenu(true)
    if (on(switchStop))
      return views.activateCursor()
    if (on(railStop))
      return railActivate(railCursor)
    if (at === addStop)
      return openField()
    if (at === refreshStop)
      return store.sync()
    if (at === openStop)
      return store.openView(view, projectId)
    if (!stops.length && at === firstRowStop && stateButton.visible)
      return stateButton.clicked()
    var row = cursorRow()
    if (!row)
      return
    if (row.kind === "fold")
      overdueOpen = !overdueOpen
    else if (enter)
      store.openView("task", row.id)
    else
      store.toggleComplete(row.id)
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
        goTo(menuStop)
      else if (dx > 0)
        step(1)
      return
    }
    var row = cursorRow()
    if (dx !== 0 && (row || viewCursor.at(addStop))) {
      if (wide && dx < 0)
        goTo(railStop)
      else if (dx > 0 && row && row.kind === "fold" && !overdueOpen)
        overdueOpen = true
      return
    }
    step(dy !== 0 ? dy : dx)
  }
  onCloseRequested: root.closeView()
  onTabRequested: function (direction) {
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
      openField()
    else if (text === "/")
      startSearch()
    else if (text === "r")
      store.sync()
    else if (text === "s")
      root.settingsRequested()
    else if (text === "t" && row && row.kind === "task")
      store.moveToTomorrow(row.id)
  }
  // The field's own keys (the catcher is blocked while it has them).
  // ---- autocomplete (#project, @label) in the add field ---------------------------------------
  // Model.suggestions for the word at the caret, or null. Esc dismisses the
  // list until the text changes again.
  property var suggest: null
  property int suggestIndex: 0
  property bool suggestDismissed: false
  readonly property bool suggestOpen: suggest !== null && suggest.items.length > 0 && fieldOpen && fieldFocused && !searching
  function updateSuggest() {
    var next = fieldOpen && !searching && !suggestDismissed ? Model.suggestions(store.model, addField.text, addField.cursorPosition) : null
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
  // fires as for typing, so the chip and the error line follow.
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
  function fieldKey(event) {
    if (suggestKey(event))
      return
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    if (alt && event.key >= Qt.Key_1 && event.key <= Qt.Key_3) {
      setView(viewKeys[event.key - Qt.Key_1])
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      if (stops.length)
        goTo(firstRowStop)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      step(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      // Text: cleared. Empty: back to the add row (search ends too).
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
      submit()
      event.accepted = true
    }
  }

  // ---- open and close ------------------------------------------------------------------
  function prepare() {
    var openOn = pref("openOn")
    var next = openOn === "last" ? store.lastView : openOn
    if (next === "project" && !(wide && store.model.projects[store.lastProject]))
      next = "today"
    // The draft comes back with why its add failed (the reply may have
    // come after the popup closed); setView clears the error otherwise.
    var draftError = store.addDraft !== "" ? store.addError : ""
    setView(next, store.lastProject)
    store.addError = draftError
    fieldOpen = false
    addField.text = ""
    viewCursor.index = -1
    root.forceActiveFocus()
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
      Qt.callLater(openField)
    store.refreshIfStale(30000)
  }
  // Closing sends the completions still in their undo window at once.
  function closed() {
    store.flushCompletions()
    // The add draft outlives the popup (search text never is one).
    if (!searching)
      store.addDraft = fieldOpen ? addField.text : ""
    leaveSearch(false)
    fieldOpen = false
    clearSuggest()
    addField.text = ""
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
      Qt.callLater(function () {
        root.forceActiveFocus()
      })
  }
  blocked: editingSettings || heroBand.menuOpen || fieldFocused
  // A minute tick for "Updated …" while the popup is open.
  FoamyWallClock {
    id: clock
    enabled: root.active
  }

  implicitWidth: wide ? FoamyStyle.popupWidthWide : FoamyStyle.popupWidth
  readonly property real maxListHeight: FoamyStyle.rowHeight * 13
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
  readonly property real listHeight: Math.max(stateBox.visible ? stateBox.implicitHeight : Math.min(rowsHeight, maxListHeight), suggestions.visible ? suggestions.height : 0)
  // The list pane around the rows: a gap, the add slot, the error lines
  // (when shown), and a gap at the bottom.
  readonly property real listChrome: FoamyStyle.gap + addSlot.height + (errorLine.visible ? FoamyStyle.gap + errorLine.height + FoamyStyle.gapSmall : 0) + FoamyStyle.gap
  readonly property real bodyHeight: wide ? Math.max(Math.min(railColumn.implicitHeight + FoamyStyle.gap * 2, maxListHeight), listChrome + listHeight) : (tabsBox.visible ? tabsBox.height : 0) + listChrome + listHeight
  implicitHeight: editingSettings ? settingsView.implicitHeight : heroBand.implicitHeight + bodyHeight + (panelFooter.visible ? panelFooter.implicitHeight : 0)

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
    if (view === "project")
      return FoamyI18n.tn("%1 · %2 tasks", counts.projects[projectId] || 0, [viewTitle, FoamyI18n.number(counts.projects[projectId] || 0)])
    var left = FoamyI18n.tn("Today · %1 left", counts.today)
    return counts.overdue ? left + " · " + FoamyI18n.tn("%1 overdue", counts.overdue) : left
  }
  FoamyHeroBand {
    id: heroBand
    visible: !root.editingSettings
    width: parent.width
    title: "Todoist"
    iconName: "todoist"
    meta: root.meta
    // Search and ⋯ (Open in Todoist, then Settings).
    maxButtons: 2
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
        objectName: "openInTodoist"
        text: FoamyI18n.t("Open in Todoist")
        iconName: "external-link"
        onTriggered: root.store.openView(root.view, root.projectId)
      }
    ]
    trailing: [
      FoamyAction {
        id: searchAction
        objectName: "searchAction"
        visible: root.store.signedIn
        iconName: "search"
        tooltipText: FoamyI18n.t("Search")
        hasCursor: viewCursor.at(root.searchStop)
        onHoveredChanged: if (hovered && !root.fieldFocused)
          viewCursor.hover(root.searchStop)
        onClicked: {
          root.leaveField()
          root.searching ? root.leaveSearch() : root.startSearch()
        }
      }
    ]
  }

  // ---- the tab row (standard width) -----------------------------------------------------------
  // Under the band's hairline, full width; it draws its own bottom hairline.
  Item {
    id: tabsBox
    visible: !root.wide && !root.editingSettings && root.store.signedIn
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

  function chipDate(key) {
    var date = new Date(Number(key.slice(0, 4)), Number(key.slice(5, 7)) - 1, Number(key.slice(8, 10)), 12)
    return Qt.locale(FoamyI18n.formatLocale).dayName(date.getDay(), Locale.ShortFormat) + " " + FoamyI18n.number(date.getDate())
  }

  // ---- the body ---------------------------------------------------------------------------------
  Item {
    id: content
    visible: !root.editingSettings
    anchors.top: tabsBox.visible ? tabsBox.bottom : heroBand.bottom
    anchors.bottom: panelFooter.visible ? panelFooter.top : parent.bottom
    width: parent.width

    // The rail (wide): views, then the projects.
    Flickable {
      id: rail
      objectName: "rail"
      visible: root.wide && root.store.signedIn && root.store.loaded
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
              visible: railRow.modelData.kind === "label"
              anchors.bottom: parent.bottom
              anchors.bottomMargin: FoamyStyle.gapSmall
              x: FoamyStyle.gap
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
                anchors.verticalCenter: parent.verticalCenter
                x: FoamyStyle.gap + (railRow.modelData.depth || 0) * FoamyStyle.gapLarge
                width: FoamyStyle.iconSize
                height: width
                name: railRow.modelData.iconName || "hash"
                color: railRow.modelData.kind === "project" ? railColors.of(railRow.modelData.role) : FoamyPalette.secondaryText
              }
              PlainText {
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
      anchors.left: rail.visible ? rail.right : parent.left
      anchors.leftMargin: rail.visible ? FoamyStyle.borderWidth : 0
      anchors.right: parent.right
      height: parent.height

      // One line under the field: why the last add, sync or change failed.
      // The add slot: the "Add task" row, or the add (or search) field in
      // its place with a hint line under it.
      Column {
        id: addSlot
        objectName: "addSlot"
        visible: root.store.signedIn && !root.editingSettings
        x: FoamyStyle.gapLarge
        y: FoamyStyle.gap
        width: parent.width - FoamyStyle.gapLarge * 2
        height: visible ? implicitHeight : 0
        spacing: FoamyStyle.gapTiny
        FoamyCursorSurface {
          id: addRow
          objectName: "addRow"
          visible: !root.fieldOpen
          width: parent.width
          height: FoamyStyle.rowHeight
          hasCursor: viewCursor.at(root.addStop)
          onHovered: if (!root.fieldFocused)
            viewCursor.hover(root.addStop)
          onClicked: root.openField()
          Accessible.role: Accessible.Button
          Accessible.name: FoamyI18n.t("Add task")
          // The icon where task rows have their ring, the label where their text starts.
          FoamyIcon {
            objectName: "addRowIcon"
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: FoamyStyle.rowPadding
            width: FoamyStyle.iconSize + 1
            height: width
            name: "plus"
            color: FoamyPalette.onSurface(FoamyPalette.accent)
          }
          PlainText {
            objectName: "addRowText"
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: FoamyStyle.rowPadding + FoamyStyle.iconSize + 1 + FoamyStyle.gap
            anchors.right: keyHint.left
            anchors.rightMargin: FoamyStyle.gap
            text: FoamyI18n.t("Add task")
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            color: FoamyPalette.secondaryText
          }
          Rectangle {
            id: keyHint
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: FoamyStyle.rowPadding
            width: Math.max(height, keyHintText.implicitWidth + FoamyStyle.gap)
            height: FoamyStyle.font.caption + FoamyStyle.gap
            radius: FoamyStyle.radiusSmall
            color: "transparent"
            border.width: FoamyStyle.borderWidth
            border.color: FoamyPalette.border
            PlainText {
              id: keyHintText
              objectName: "addKeyHint"
              anchors.centerIn: parent
              text: "a"
              wrapMode: Text.NoWrap
              font.family: FoamyStyle.monoFamily
              font.pixelSize: FoamyStyle.font.caption
              color: FoamyPalette.mutedText
            }
          }
        }
        Item {
          id: fieldBox
          objectName: "fieldBox"
          visible: root.fieldOpen
          width: parent.width
          implicitHeight: FoamyStyle.controlHeight
          height: implicitHeight
          readonly property string placeholder: root.searching ? FoamyI18n.t("Search tasks") : root.view === "inbox" ? FoamyI18n.t("Add to Inbox") : root.view === "today" ? FoamyI18n.t("Add a task for today") : root.view === "upcoming" ? FoamyI18n.t("Add a task") : FoamyI18n.t("Add to %1", [root.viewTitle])
          SafeTextField {
            id: addField
            objectName: "addField"
            anchors.fill: parent
            placeholderText: fieldBox.placeholder
            translate: FoamyI18n.t
            maximumLength: 500
            hasCursor: viewCursor.at(root.addStop) && !root.fieldFocused
            leftPadding: FoamyStyle.iconSize + FoamyStyle.gap * 2
            rightPadding: chip.visible || spinner.visible ? chip.width + FoamyStyle.gap * 2 : FoamyStyle.gap
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
            x: FoamyStyle.gap + 2
            width: FoamyStyle.iconSize
            height: width
            name: root.searching ? "search" : "plus"
            color: FoamyPalette.mutedText
          }
          // The default date of what is added: Today, or Upcoming's day.
          Rectangle {
            id: chip
            objectName: "dateChip"
            visible: !root.searching && root.addDay !== "" && !spinner.visible
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: FoamyStyle.gapSmall + 1
            height: FoamyStyle.controlHeight - FoamyStyle.gap
            width: chipRow.implicitWidth + FoamyStyle.gap * 2
            radius: FoamyStyle.radiusSmall
            color: FoamyPalette.selectedFill
            Row {
              id: chipRow
              anchors.centerIn: parent
              spacing: FoamyStyle.gapSmall
              FoamyIcon {
                anchors.verticalCenter: parent.verticalCenter
                width: FoamyStyle.font.bodySmall
                height: width
                name: "calendar"
                color: FoamyPalette.onSurface(FoamyPalette.accent)
              }
              PlainText {
                objectName: "dateChipText"
                text: root.addDay === root.store.today ? FoamyI18n.t("Today") : root.addDay === Model.addDays(root.store.today, 1) ? FoamyI18n.t("Tomorrow") : root.chipDate(root.addDay)
                wrapMode: Text.NoWrap
                font.pixelSize: FoamyStyle.font.bodySmall
                color: FoamyPalette.onSurface(FoamyPalette.accent)
              }
            }
          }
          FoamyIcon {
            id: spinner
            objectName: "addSpinner"
            visible: root.addBusy
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
        // Under the add field: why the add failed, whole (wrapped; the
        // keys hide meanwhile), else the keys. Both are hidden under an
        // open suggestion list, where Enter inserts instead.
        Item {
          visible: root.fieldOpen && !root.searching
          opacity: root.suggestOpen ? 0 : 1
          width: parent.width
          height: visible ? (root.addError !== "" ? addErrorLine.implicitHeight : fieldHint.implicitHeight) : 0
          PlainText {
            id: addErrorLine
            objectName: "addErrorLine"
            visible: root.addError !== ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: FoamyStyle.rowPadding
            anchors.rightMargin: FoamyStyle.rowPadding
            text: root.addError
            wrapMode: Text.Wrap
            font.pixelSize: FoamyStyle.font.caption
            color: Commons.Color.urgent
            Accessible.role: Accessible.AlertMessage
          }
          PlainText {
            id: fieldHint
            objectName: "fieldHint"
            visible: root.addError === ""
            anchors.right: parent.right
            text: FoamyI18n.t("Enter adds · Esc closes")
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.caption
            color: FoamyPalette.mutedText
          }
        }
      }
      // Lines under the add slot: why the last sync or change failed (an
      // error), and that the snapshot was cut (a note, while rows show).
      Column {
        id: errorLine
        // An add error shows under the open field; with the field closed, here.
        readonly property string message: root.addError !== "" && !root.fieldOpen ? root.addError : root.store.loaded ? root.store.error : ""
        readonly property bool truncated: root.store.model.truncated && root.rows.length > 0
        visible: root.store.signedIn && (message !== "" || truncated)
        x: FoamyStyle.gapLarge + FoamyStyle.rowPadding
        anchors.top: addSlot.bottom
        anchors.topMargin: visible ? FoamyStyle.gap : 0
        width: parent.width - x - FoamyStyle.gapLarge
        height: visible ? implicitHeight : 0
        spacing: FoamyStyle.gapTiny
        PlainText {
          id: errorText
          objectName: "errorLine"
          visible: errorLine.message !== ""
          width: parent.width
          text: errorLine.message
          wrapMode: Text.NoWrap
          elide: Text.ElideRight
          font.pixelSize: FoamyStyle.font.bodySmall
          color: Commons.Color.urgent
          Accessible.role: Accessible.AlertMessage
        }
        PlainText {
          objectName: "truncatedLine"
          visible: errorLine.truncated
          width: parent.width
          text: FoamyI18n.t(Model.TRUNCATED_TEXT)
          wrapMode: Text.Wrap
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.mutedText
        }
      }
      ListView {
        id: taskList
        objectName: "taskList"
        anchors.top: errorLine.bottom
        anchors.topMargin: errorLine.visible ? FoamyStyle.gapSmall : 0
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
          onHovered: if (!root.fieldFocused && root.stopOfRow[index] >= 0)
            viewCursor.hover(root.stopOfRow[index])
          onCompleteRequested: {
            root.leaveField()
            root.store.toggleComplete(modelData.id)
          }
          onOpenRequested: {
            root.leaveField()
            root.store.openView("task", modelData.id)
          }
          onFoldRequested: {
            root.leaveField()
            root.overdueOpen = !root.overdueOpen
          }
        }
      }

      // The suggestions: a menu-like list dropping from the add field's
      // bottom edge over the rows, as wide as the field (above it when
      // there is no room below). The field keeps the keys.
      Rectangle {
        id: suggestions
        objectName: "suggestions"
        visible: root.suggestOpen
        z: 20
        readonly property real fieldTop: addSlot.y + fieldBox.y
        readonly property real fieldBottom: fieldTop + fieldBox.height
        readonly property bool above: fieldBottom + FoamyStyle.gapTiny + height > parent.height && fieldTop - FoamyStyle.gapTiny - height >= 0
        x: addSlot.x
        y: above ? fieldTop - FoamyStyle.gapTiny - height : fieldBottom + FoamyStyle.gapTiny
        width: addSlot.width
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

      // Signed out, loading, empty, or failed without data: one line.
      Column {
        id: stateBox
        objectName: "stateBox"
        readonly property string kind: root.store.account === "unavailable" ? "unavailable" : root.store.account === "error" ? "accountError" : root.store.account === "checking" ? "loading" : !root.store.signedIn ? "signedOut" : !root.store.loaded ? (root.store.error !== "" ? "failed" : "loading") : root.rows.length ? "" : "empty"
        visible: kind !== ""
        anchors.top: errorLine.bottom
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

  FoamyPanelFooter {
    id: panelFooter
    objectName: "footer"
    visible: !root.editingSettings && root.store.signedIn
    anchors.bottom: parent.bottom
    width: parent.width
    horizontalPadding: FoamyStyle.padding
    // A launch that failed first (until the next one works), as foamy-clock's
    // footer; else, with cached data shown after a failed sync, the time of
    // the last good one.
    status: root.store.launchError !== "" ? root.store.launchError : root.store.syncing && root.store.loaded && clock.date.getTime() - root.store.syncedAt > root.store.refreshSeconds * 1000 ? FoamyI18n.t("Updating…") : FoamyI18n.updatedAgo(root.store.syncedAt, clock.date.getTime())
    statusError: root.store.launchError !== ""
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
      iconName: "todoist"
      label: FoamyI18n.t("Todoist")
      foreground: FoamyPalette.secondaryText
      tooltipText: FoamyI18n.t("Open Todoist")
      hasCursor: root.on(root.openStop)
      onHoveredChanged: if (hovered && !root.fieldFocused)
        viewCursor.hover(root.openStop)
      onClicked: {
        root.leaveField()
        root.store.openView(root.view, root.projectId)
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
