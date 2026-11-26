pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons as Commons
import "kit"
import "Model.js" as Model
import "Edit.js" as Edit

// The task editor, one component used two ways. `mode` "page" (Small): a
// sub-view in place of the list, built like the settings page (the compact
// band with Back, the task's place as the title, "Saving…", Open in
// Todoist); Esc or Back returns. "pane" (Wide): the details pane beside the
// list, shown while a task is selected; Esc gives the keys back to the list
// (`keysReturned`). The pane has its own header row instead of a band: the
// task's place, Open in Todoist and Close (`closeRequested`); the panel's
// footer says "Saving…", then "Saved" for a moment (`savedShown`).
//
// It reads like the task, after Todoist's task view: the completion ring
// and the title, the description under it, then the properties (Project,
// Date, Deadline, Priority, Labels), one row each: the icon in the ring's
// column, the value on the title's text edge, its caption at the row's end.
// Every part is edited where it is: the title and description are quiet
// fields; a property row (one click target, as in Todoist) opens its menu,
// or (Date, Deadline) a one-line field in its value's place.
// At rest the title reads as the list shows it (Model.plainText: a link's
// text, no Markdown marks); with the keys it holds Todoist's raw text.
//
// Each part saves on its own: a text field when it loses the keys, on
// Enter (the title, Date, Deadline) or Ctrl+Enter (the description). A save is one
// helper `update` holding only what changed (Edit.js), through the store's
// queue. Esc in a field drops its unsaved change; a failed save shows under
// its part with Retry and keeps what was typed. Choices (place, priority,
// labels) save when picked.
//
// The description isn't in the snapshot: the store fetches the shown
// task's (`TodoStore.description`, one at a time); the pane waits until
// the selection rests, so moving through the list reads only where it
// stops. Task text and descriptions only reach plain-text sinks.
FocusScope {
  id: editor
  property string taskId: ""
  property string mode: "page"
  // The rail's project list, for the project menu: [{id, name}].
  property var projects: []
  signal back
  signal keysReturned
  // The pane's Close: the selection ends, as Esc in the list.
  signal closeRequested

  readonly property var store: TodoStore
  readonly property bool pane: mode === "pane"
  readonly property var task: taskId !== "" && store.model.byId[taskId] ? store.model.byId[taskId] : null
  // The task as the saves in flight will leave it: the choices show it.
  readonly property var base: task ? Edit.pending(task, inFlight) : null
  // The task went from the snapshot (completed or deleted elsewhere).
  readonly property bool gone: taskId !== "" && task === null
  // Completed here, its Undo time running: the ring and the title show it,
  // and the header offers Undo (the row's Undo; the ring undoes too).
  readonly property bool struck: taskId !== "" && Model.has(store.struck, taskId)
  readonly property var desc: store.description.id === taskId && taskId !== "" ? store.description : null
  readonly property bool saving: Object.keys(pending).length > 0
  // A save of the shown task just worked: "Saved" in the panel's footer
  // (the pane's) for `savedNotice` ms. Long enough to read, short enough
  // that the freshness line comes back soon; no kit token is a notice time.
  readonly property int savedNotice: 2000
  readonly property bool savedShown: savedNoticeTimer.running
  readonly property alias savedTimer: savedNoticeTimer
  Timer {
    id: savedNoticeTimer
    interval: editor.savedNotice
  }
  readonly property bool menuOpen: picker.opened
  readonly property alias contentField: contentInput
  readonly property alias dueField: dueInput
  readonly property alias deadlineField: deadlineInput
  readonly property alias descriptionField: descriptionInput
  readonly property alias backButton: pageBand.backButton
  // The one menu (project, priority or labels; one at a time).
  readonly property alias menu: picker
  readonly property alias ring: ringBox
  // Open in Todoist: in the page's band, or in the pane's header.
  readonly property Item openButton: pane ? paneOpen : pageOpen
  // The page keeps the keys when a click on its empty space takes them from
  // a field (FoamyClickAway), as Esc and Back work there; the pane gives
  // them to the list's (null: the search goes on to the panel).
  readonly property Item foamyKeyHome: pane ? null : editor
  // Date and Deadline: the key whose one-line field is open ("" none).
  property string opened: ""

  // Saves in flight, {request: {key, typed, sent, fields}}: the field,
  // what it held when sent (a choice: what was picked), the field's value
  // once Todoist has it (a text field) and the `update` fields.
  // Each reply is matched to its own request, and only the newest request
  // of a field may change that field: an older reply never replaces a newer
  // draft or what a newer request sent.
  property var pending: ({})
  // Their `update` fields, oldest first (for Edit.pending).
  readonly property var inFlight: requests().map(function (request) {
    return editor.pending[request].fields
  })
  property var errors: ({})
  // Each text field's confirmed value: what Todoist held when the field
  // last followed the task (shown, or changed in Todoist while untouched),
  // or the newest save of the field that worked. Never an unconfirmed
  // request's value: baselineOf() adds the saves in flight. Replaced on
  // each change (confirm()), never mutated, so the title's rest state
  // (titleRendered) follows it.
  property var confirmed: ({})
  // What each choice (place, priority, labels) asked for last, for Retry.
  property var attempts: ({})

  // The task the fields belong to (shownId): while the editor changes task,
  // the fields still hold the old one's text, and its edits go to it.
  function current() {
    return shownId !== "" && store.model.byId[shownId] ? store.model.byId[shownId] : null
  }
  function descNow() {
    return store.description.id === shownId && shownId !== "" ? store.description : null
  }
  // The requests in flight, oldest first, and a field's newest (-1: none).
  function requests() {
    return Object.keys(pending).map(Number).sort(function (a, b) {
      return a - b
    })
  }
  function newest(key) {
    var found = -1
    for (const request of requests())
      if (pending[request].key === key)
        found = request
    return found
  }
  // current() with the saves in flight applied: what an edit is measured
  // against, so a second edit before the first reply builds on the first.
  function baseNow() {
    return Edit.pending(current(), requests().map(function (request) {
      return editor.pending[request].fields
    }))
  }
  // The description likewise: the newest one sent, else the fetched one.
  function descBase() {
    var request = newest("description")
    if (request >= 0)
      return pending[request].fields.description
    return descNow() && descNow().state === "ready" ? descNow().text : undefined
  }
  function translate(key, values) {
    return FoamyI18n.t(key, values)
  }
  function formatDate(date, pattern) {
    return date.toLocaleDateString(Qt.locale(FoamyI18n.formatLocale), pattern)
  }
  function setError(key, message) {
    var next = Object.assign({}, errors)
    if (message === "")
      delete next[key]
    else
      next[key] = message
    errors = next
  }
  function errorOf(key) {
    return Model.has(errors, key) ? errors[key] : ""
  }
  function inputOf(key) {
    return key === "content" ? contentInput : key === "due" ? dueInput : key === "deadline" ? deadlineInput : key === "description" ? descriptionInput : null
  }
  function initialOf(key) {
    return Edit.initial(baseNow(), key, descBase())
  }
  function confirm(key, value) {
    var next = Object.assign({}, confirmed)
    next[key] = value
    confirmed = next
  }
  // A text field set to what Todoist holds (no save of it in flight): it
  // is the confirmed value now (read back from the field, which may turn
  // CRLF into LF).
  function setText(key, value) {
    var input = inputOf(key)
    input.text = value
    confirm(key, input.text)
  }
  // What the field is measured against: what its newest save in flight
  // sent (typing on from it is the next change, typing back to the old
  // text is one too), else the confirmed value. A refused save thus leaves
  // the field measured against Todoist's value again, so a draft that
  // differs from it stays a change.
  function baselineOf(key) {
    var request = newest(key)
    if (request >= 0)
      return pending[request].typed
    return Model.has(confirmed, key) ? confirmed[key] : ""
  }
  // The user changed the field since its baseline.
  function touched(key) {
    var input = inputOf(key)
    var base = baselineOf(key)
    return key === "description" ? !Edit.sameDescription(input.text, base) : input.text !== base
  }
  function dirty(key) {
    var input = inputOf(key)
    if (!input || !current())
      return false
    // A cut description is read-only: never saved, or it would replace the
    // whole one.
    if (key === "description" && descTruncated())
      return false
    return touched(key)
  }
  function descTruncated() {
    return !!desc && desc.state === "ready" && desc.truncated === true
  }
  // A text field back to its baseline (and its error gone): what its save
  // in flight sent, else the task's value.
  function revert(key) {
    var input = inputOf(key)
    var request = newest(key)
    if (input && request >= 0)
      input.text = pending[request].typed
    else if (input && current())
      setText(key, initialOf(key))
    setError(key, "")
  }
  function revertAll() {
    for (const key of ["content", "due", "deadline"])
      revert(key)
    setText("description", descNow() && descNow().state === "ready" ? descNow().text : "")
    errors = ({})
    attempts = ({})
    // A refused paste's message goes with its task too: a field whose
    // text stays the same (two empty descriptions) would keep it.
    for (const key of ["content", "due", "deadline", "description"])
      inputOf(key).pasteError = ""
  }
  // Untouched fields follow the snapshot, also the one with the keys;
  // one the user changed, with a failed save's text or a save in flight
  // keeps its text (the user's edit wins when it is saved).
  function follow() {
    if (!current())
      return
    for (const key of ["content", "due", "deadline"]) {
      if (!touched(key) && errorOf(key) === "" && newest(key) < 0)
        setText(key, initialOf(key))
    }
  }

  // One field's save (Edit.change), or why it can't be sent.
  function save(key, value) {
    var task = baseNow()
    if (!task)
      return
    var result = Edit.change(task, key, value, descBase())
    if (result.error !== "") {
      setError(key, FoamyI18n.t(result.error))
      return
    }
    setError(key, "")
    // A typed date replaces this task's move still in its undo window (the
    // saved task's: when the pane changes task, taskId is already the next).
    if (key === "due")
      store.undoMove(task.id)
    if (!result.fields) {
      // Nothing to send (the text differs only in spaces at its ends or in
      // line ends): the field shows its baseline again, so it is untouched
      // and follows Todoist. Not a description that isn't read yet.
      if (inputOf(key) && (key !== "description" || descBase() !== undefined))
        revert(key)
      return
    }
    if (!inputOf(key)) {
      const asked = Object.assign({}, attempts)
      asked[key] = value
      attempts = asked
    }
    var request = store.saveTask(task.id, result.fields)
    if (request < 0)
      return
    var next = Object.assign({}, pending)
    next[request] = {
      key: key,
      typed: inputOf(key) ? String(value) : value,
      sent: inputOf(key) ? Edit.initial(Edit.pending(task, [result.fields]), key, result.fields.description) : undefined,
      fields: result.fields
    }
    pending = next
  }
  // A text field's save (blur, Enter, Ctrl+Enter, leaving the task): only
  // the user's change is sent. Untouched, the field shows the task again.
  function saveField(key) {
    if (!dirty(key)) {
      setError(key, "")
      if (current() && newest(key) < 0)
        setText(key, initialOf(key))
      return
    }
    save(key, inputOf(key).text)
  }
  // Retry under a field: a text field sends what it holds, a choice what
  // was picked last.
  function retry(key) {
    if (inputOf(key))
      save(key, inputOf(key).text)
    else if (Model.has(attempts, key))
      save(key, attempts[key])
  }
  Connections {
    target: editor.store
    function onTaskSaved(request, id, ok, message) {
      if (!Model.has(editor.pending, request))
        return
      var save = editor.pending[request]
      var rest = Object.assign({}, editor.pending)
      delete rest[request]
      editor.pending = rest
      var input = editor.inputOf(save.key)
      if (ok) {
        savedNoticeTimer.restart()
        // Todoist has it, also while a newer save of the field runs: if
        // that one is refused, the field is measured against this value.
        // (The store's queue runs one job at a time, so replies come in
        // order.)
        if (input)
          editor.confirm(save.key, save.sent)
      }
      // A newer save of the field is in flight: its reply decides what the
      // field shows (it holds this one's change too).
      if (editor.newest(save.key) > request)
        return
      if (!ok) {
        // The typed text stays; measured against the confirmed value, a
        // text that differs from it is a change (leaving the task or Retry
        // sends it). The line under the field says why.
        editor.setError(save.key, message !== "" ? message : FoamyI18n.t("Todoist didn't accept the change."))
        return
      }
      // The snapshot has the new value: the field shows it, unless typing went on.
      if (input && input.text === save.typed)
        editor.setText(save.key, editor.initialOf(save.key))
    }
    function onModelChanged() {
      editor.follow()
    }
    function onDescriptionChanged() {
      var d = editor.descNow()
      if (d && d.state === "ready" && !editor.touched("description") && editor.errorOf("description") === "" && editor.newest("description") < 0)
        editor.setText("description", d.text)
    }
  }

  // ---- which task -------------------------------------------------------------
  // A new task: the old one's changed fields are saved first and the keys
  // go back to the list (the pane), then the fields start over, the old
  // saves in flight report to the error line from now on, and the new
  // task's description is read (in the pane once the selection rests).
  property string shownId: ""
  onTaskIdChanged: show()
  Component.onCompleted: show()
  Component.onDestruction: {
    store.holdUndo(false)
    store.releaseSaves(Object.keys(pending).map(Number))
    if (shownId !== "")
      store.dropDescription()
  }
  function show() {
    if (taskId === shownId)
      return
    commit()
    // Before the fields change: a field losing the keys saves what it holds.
    if (pane && editor.activeFocus)
      keysReturned()
    store.releaseSaves(Object.keys(pending).map(Number))
    pending = ({})
    savedNoticeTimer.stop()
    shownId = taskId
    picker.close()
    opened = ""
    revertAll()
    descriptionWait.stop()
    if (taskId === "") {
      store.dropDescription()
      return
    }
    if (pane) {
      store.dropDescription()
      descriptionWait.restart()
    } else
      store.loadDescription(taskId)
  }
  Timer {
    id: descriptionWait
    interval: 300
    onTriggered: if (editor.taskId !== "" && editor.task)
      editor.store.loadDescription(editor.taskId)
  }
  // Every field with an unsaved change, saved now: the editor lets its
  // task go (another selection, Back, a view or size change, the panel
  // closing), which may take the keys only after the fields have changed.
  // A change that can't be sent (a deadline that isn't a day) goes to the
  // list's error line, as the editor's error lines go with the task.
  function commit() {
    if (!current())
      return
    for (const key of ["content", "due", "deadline", "description"]) {
      const input = inputOf(key)
      if (!input.enabled || !dirty(key))
        continue
      saveField(key)
      store.editRefused(errorOf(key))
    }
  }
  // Complete: the typed changes are saved first (a click here doesn't take
  // the keys from the field, and the task may leave the snapshot after),
  // so they reach the queue ahead of the completion.
  function completeTask() {
    var id = shownId
    if (struck) {
      store.undo(id)
      return
    }
    commit()
    store.complete(id)
    if (!pane)
      back()
  }
  // The caret in the first field (`e`, Enter on a row in Wide).
  function focusFirst() {
    if (!task)
      return
    contentInput.focusInput()
    // The caret after the title, to go on typing (it was before it).
    contentInput.cursorPosition = contentInput.length
    // The first field is at the top; it may have had the keys already, so
    // no focus change scrolls to it.
    scroll.contentY = 0
  }

  // ---- keys -----------------------------------------------------------------------
  // Esc in a field with a change drops it (the field keeps the keys); else
  // the page goes back, the pane gives the keys to the list.
  function fieldKey(key, event) {
    if (event.key === Qt.Key_Escape && (dirty(key) || errorOf(key) !== "")) {
      revert(key)
      event.accepted = true
    }
  }

  // ---- Date and Deadline: a one-line field in place of the value row ----------
  function rowOf(key) {
    return key === "due" ? dueSection : deadlineSection
  }
  // The section (its value, or its + when empty) opens the field, the caret at its end.
  function openField(key) {
    if (!task)
      return
    opened = key
    var input = inputOf(key)
    input.focusInput()
    input.cursorPosition = input.text.length
  }
  // The field closes (losing the keys, it saves what it holds:
  // onEditingFinished); `refocus` gives the keys to its section (Enter, Esc).
  function closeField(key, refocus) {
    if (opened === key)
      opened = ""
    if (refocus)
      rowOf(key).focusRow()
  }
  // Enter saves and closes (a text that can't be sent keeps the field open,
  // with why); Esc drops the change and closes.
  function dateKey(key, event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      saveField(key)
      if (errorOf(key) === "")
        closeField(key, true)
    } else if (event.key === Qt.Key_Escape) {
      event.accepted = true
      revert(key)
      closeField(key, true)
    }
  }
  // What a closed Date or Deadline row shows: a kept draft (a failed
  // save's), else the text of the save in flight, else Todoist's value in
  // the panel's words ("" when there is none).
  function draftOf(key) {
    if (errorOf(key) !== "")
      return inputOf(key).text
    var request = newest(key)
    return request >= 0 ? String(pending[request].typed) : null
  }
  // A move from the menu (waiting, or sent and not yet answered): its day.
  readonly property bool dueMoved: task !== null && Model.has(store.shownMoves, taskId)
  readonly property string movedDay: dueMoved ? store.shownMoves[taskId] : ""
  readonly property string dueLabel: {
    // A waiting move was picked after any typed date.
    var draft = Model.has(store.moves, taskId) ? null : draftOf("due")
    if (draft !== null)
      return draft.trim()
    if (dueMoved)
      return Model.dueWords({
        due: Model.movedDue(task, movedDay)
      }, formatDate, translate, store.today)
    return task ? Model.dueWords(task, formatDate, translate, store.today) : ""
  }
  readonly property string deadlineLabel: {
    var draft = draftOf("deadline")
    var day = draft !== null ? draft.trim() : task ? task.deadline || "" : ""
    return Model.dayWords(day, formatDate, translate, store.today) || day
  }
  // The task's place, "Project" or "Project › Section", as the saves in
  // flight leave it: the Project row and the page's band say it.
  readonly property var placeProject: base ? store.model.projects[base.projectId] || null : null
  readonly property string placeLabel: {
    if (!base)
      return ""
    var section = base.sectionId ? store.model.sections[base.sectionId] : null
    return (placeProject ? placeProject.name : "") + (section ? " › " + section.name : "")
  }
  // The title at rest: as the list shows it (plain text), in the field's
  // place, while the field doesn't have the keys and holds neither an
  // unsaved change nor a failed save (those show the raw text). Only when
  // that differs from the raw text; else the field shows itself.
  readonly property string titlePlain: Model.plainText(contentInput.text)
  readonly property bool titleRendered: !contentInput.inputActiveFocus && titlePlain !== contentInput.text && errorOf("content") === "" && !touched("content")
  onTitleRenderedChanged: if (titleRendered)
    contentInput.contentY = 0
  function roleColor(role) {
    // Marks and icons on the surface: readable in a light theme too.
    return role === "error" ? FoamyPalette.onSurface(FoamyPalette.error) : role === "warning" ? FoamyPalette.onSurface(FoamyPalette.warning) : role === "success" ? FoamyPalette.onSurface(FoamyPalette.success) : role === "info" ? FoamyPalette.onSurface(FoamyPalette.info) : role === "accent" ? FoamyPalette.onSurface(FoamyPalette.accent) : FoamyPalette.mutedText
  }
  // A day's colour as Todoist shows it; a draft or a save in flight: muted.
  function dayColor(key, day) {
    return draftOf(key) !== null ? FoamyPalette.mutedText : roleColor(Model.dayRole(day, store.today))
  }
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) {
      event.accepted = true
      if (editor.pane)
        editor.keysReturned()
      else
        editor.back()
    } else if (!editor.pane && event.key === (LayoutMirroring.enabled ? Qt.Key_Right : Qt.Key_Left) && pageBand.backButton.activeFocus) {
      // ← on the header (Back has the focus): back to the list.
      event.accepted = true
      editor.back()
    }
  }

  // ---- layout -------------------------------------------------------------------
  // The ring's column: the title's and the description's text line up after it.
  readonly property real ringSize: FoamyStyle.font.iconLarge
  readonly property real gutter: ringSize + FoamyStyle.gapSmall
  // From the editor's reading start: the ring's column (where the property
  // icons centre) and the title's text edge (where their values start).
  readonly property real ringEdge: FoamyStyle.padding - FoamyStyle.gapSmall
  readonly property real textEdge: ringEdge + gutter + contentInput.leftPadding
  implicitHeight: (pane ? paneHead.height : pageBand.implicitHeight) + Math.min(form.implicitHeight, pane ? form.implicitHeight : FoamyStyle.popupMaxHeight)

  // The page's band: Back, the task's place, "Saving…", Open in Todoist.
  FoamyHeroBand {
    id: pageBand
    objectName: "editorBand"
    visible: !editor.pane
    compact: true
    width: parent.width
    compactTitle: editor.placeLabel
    saving: editor.saving
    onBack: editor.back()
    compactTrailing: [
      FoamyAction {
        objectName: "pageUndo"
        visible: editor.struck
        focusable: true
        iconName: ""
        label: FoamyI18n.t("Undo")
        foreground: FoamyPalette.onSurface(FoamyPalette.accent)
        onClicked: editor.completeTask()
      },
      FoamyAction {
        id: pageOpen
        objectName: "editOpen"
        visible: editor.task !== null
        focusable: true
        iconName: "external-link"
        foreground: FoamyPalette.secondaryText
        tooltipText: FoamyI18n.t("Open in Todoist")
        onClicked: editor.store.openView("task", editor.taskId)
      }
    ]
  }
  // A click on the editor's empty space outside its scroll (the page's
  // band) takes the keys from a field and goes no further: over
  // the Week view it would reach the cards under the pane.
  FoamyClickAway {
    anchors.fill: parent
    z: -1
  }

  // The page's task is gone (the pane closes instead: TodoView.paneShown).
  PlainText {
    objectName: "editorEmpty"
    visible: editor.gone && !editor.pane
    anchors.top: pageBand.bottom
    anchors.topMargin: FoamyStyle.gapLarge
    x: FoamyStyle.padding
    width: parent.width - FoamyStyle.padding * 2
    horizontalAlignment: Text.AlignHCenter
    text: FoamyI18n.t("This task is no longer in Todoist.")
    font.pixelSize: FoamyStyle.font.bodySmall
    color: FoamyPalette.mutedText
  }

  FoamyWheelScroll {
    id: wheel
    target: scroll
  }
  // Focus follow, as FoamySettingsPage: the least scroll that shows the
  // focused control (Tab, focusFirst()), in the page and the pane.
  function keepVisible(focused) {
    // In a SafeTextArea the focused item is its inner editor, as tall as
    // the whole text and moved by the area's own scroll: the area's box is
    // what shows (the area keeps its caret in view itself).
    var item = focused
    var ancestor = focused
    while (ancestor && ancestor !== scroll.contentItem) {
      if (item === focused && ancestor instanceof SafeTextArea)
        item = ancestor
      ancestor = ancestor.parent
    }
    if (!ancestor)
      return
    var point = item.mapToItem(scroll.contentItem, 0, 0)
    var margin = FoamyStyle.gap
    if (point.y < scroll.contentY)
      scroll.contentY = Math.max(0, point.y - margin)
    else if (point.y + item.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, point.y + item.height - scroll.height + margin))
  }
  Connections {
    target: editor.Window
    function onActiveFocusItemChanged() {
      if (editor.Window.activeFocusItem)
        editor.keepVisible(editor.Window.activeFocusItem)
    }
  }
  Flickable {
    id: scroll
    objectName: "editorScroll"
    visible: editor.task !== null
    anchors.top: editor.pane ? paneHead.bottom : pageBand.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: form.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      policy: Controls.ScrollBar.AsNeeded
    }

    // One column: the title and description, then the properties.
    ColumnLayout {
      id: form
      width: scroll.width
      spacing: 0

      // ---- the title and the description ----
      ColumnLayout {
        id: head
        objectName: "editorHead"
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        Layout.leftMargin: FoamyStyle.padding - FoamyStyle.gapSmall
        Layout.rightMargin: FoamyStyle.padding - FoamyStyle.gapSmall
        // The pane: the list's top margin, so the title lines up with its
        // first row.
        Layout.topMargin: editor.pane ? FoamyStyle.gap : FoamyStyle.gapLarge
        Layout.bottomMargin: FoamyStyle.gap
        spacing: FoamyStyle.gapSmall

        RowLayout {
          Layout.fillWidth: true
          spacing: 0
          // The ring completes, as on the list's rows: the priority's
          // colour, the check on hover or with the keys.
          Item {
            id: ringBox
            objectName: "editRing"
            // Completed without a priority: the secondary tone (as the list's ring).
            readonly property string role: editor.base ? Model.priorityRole(editor.base.priority) : "muted"
            readonly property color tone: editor.struck && role === "muted" ? FoamyPalette.secondaryText : editor.roleColor(role)
            readonly property bool lit: ringMouse.containsMouse || activeFocus
            // As the list's ring: its look by priority, the check in the ink
            // that reads on the completed fill.
            readonly property var look: Model.ringLook(editor.base ? editor.base.priority : 0)
            readonly property color checkInk: {
              const fill = Qt.tint(FoamyPalette.background, Qt.alpha(tone, Model.RING_DONE))
              return FoamyPalette.contrastRatio(FoamyPalette.text, fill) >= FoamyPalette.contrastRatio(FoamyPalette.background, fill) ? FoamyPalette.text : FoamyPalette.background
            }
            // As tall as the title's first line, so the ring centres on it.
            Layout.preferredWidth: editor.gutter
            Layout.preferredHeight: contentInput.topPadding + contentInput.bottomPadding + titleLine.height
            Layout.alignment: Qt.AlignTop
            activeFocusOnTab: true
            Accessible.role: Accessible.CheckBox
            Accessible.checked: editor.struck
            Accessible.name: FoamyI18n.t("Complete")
            Accessible.onPressAction: editor.completeTask()
            Keys.onPressed: function (event) {
              if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                event.accepted = true
                editor.completeTask()
              }
            }
            FontMetrics {
              id: titleLine
              font: contentInput.font
            }
            Rectangle {
              objectName: "editRingMark"
              anchors.centerIn: parent
              width: editor.ringSize
              height: width
              radius: width / 2
              border.width: ringBox.look.border
              border.color: ringBox.tone
              color: Qt.alpha(ringBox.tone, editor.struck ? Model.RING_DONE : ringBox.look.fill + (ringBox.lit ? Model.RING_HOVER : 0))
              FoamyIcon {
                objectName: "editRingCheck"
                visible: ringBox.lit || editor.struck
                anchors.centerIn: parent
                width: FoamyStyle.font.bodySmall
                height: width
                name: "check"
                color: editor.struck ? ringBox.checkInk : ringBox.tone
              }
            }
            // The keys' ring around it.
            Rectangle {
              visible: ringBox.activeFocus
              anchors.centerIn: parent
              width: editor.ringSize + FoamyStyle.gapSmall * 2
              height: width
              radius: width / 2
              color: "transparent"
              border.width: 1
              border.color: Commons.Color.accent
            }
            MouseArea {
              id: ringMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: editor.completeTask()
            }
          }
          // The title wraps, as in Todoist; it is one line of text all the
          // same: Enter saves instead of breaking it (a pasted line break is
          // refused with why, as Todoist refuses it).
          Item {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            implicitHeight: contentInput.height
            SafeTextArea {
              id: contentInput
              objectName: "editContent"
              width: parent.width
              // At rest the rendered title sets the height; the field's own
              // text, caret and selection are see-through under it, so hover,
              // a click (the caret where it lands in the raw text) and Tab
              // reach the field as before.
              height: editor.titleRendered ? Math.min(maximumHeight, titleText.implicitHeight) : implicitHeight
              color: editor.titleRendered ? "transparent" : editor.struck ? FoamyPalette.mutedText : contentInput.foreground
              selectedTextColor: editor.titleRendered ? "transparent" : contentInput.foreground
              selectionColor: editor.titleRendered ? "transparent" : contentInput.selectionTint
              quiet: true
              minimumHeight: 0
              maximumHeight: FoamyStyle.controlHeight * 4
              // The pane is narrow: its title in the band's size.
              font.pixelSize: editor.pane ? FoamyStyle.font.title : FoamyStyle.font.heading
              font.weight: Font.DemiBold
              font.strikeout: editor.struck
              maximumLength: 1000
              translate: FoamyI18n.t
              Accessible.name: FoamyI18n.t("Task")
              onTextEdited: editor.setError("content", "")
              onPasteErrorChanged: if (pasteError !== "")
                editor.setError("content", "")
              onEditingFinished: editor.saveField("content")
              onKeyPressed: function (event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  event.accepted = true
                  editor.saveField("content")
                } else
                  editor.fieldKey("content", event)
              }
              // At rest the raw text stays at its top, so a click lands on
              // the line under it (the field scrolls to its caret otherwise).
              onContentYChanged: if (editor.titleRendered && contentY !== 0)
                contentY = 0
            }
            // The rendered title: the field's paddings, font and wrapping,
            // its lines up to the field's height (then …). The field carries
            // the name and value for assistive technology.
            PlainText {
              id: titleText
              objectName: "editTitleText"
              visible: editor.titleRendered
              width: parent.width
              leftPadding: contentInput.leftPadding
              rightPadding: contentInput.rightPadding
              topPadding: contentInput.topPadding
              bottomPadding: contentInput.bottomPadding
              text: editor.titleRendered ? editor.titlePlain : ""
              font.family: contentInput.font.family
              font.pixelSize: contentInput.font.pixelSize
              font.weight: contentInput.font.weight
              font.strikeout: contentInput.font.strikeout
              color: editor.struck ? FoamyPalette.mutedText : contentInput.foreground
              maximumLineCount: Math.max(1, Math.floor((contentInput.maximumHeight - contentInput.topPadding - contentInput.bottomPadding) / titleLine.height))
              elide: Text.ElideRight
              Accessible.ignored: true
            }
          }
        }
        ErrorLine {
          objectName: "contentError"
          Layout.leftMargin: editor.gutter
          error: editor.errorOf("content")
          pasteError: contentInput.pasteError
          onRetry: editor.retry("content")
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 0
          // The description's mark, on its first line.
          Item {
            Layout.preferredWidth: editor.gutter
            Layout.preferredHeight: descriptionInput.topPadding + descriptionInput.bottomPadding + descriptionLine.height
            Layout.alignment: Qt.AlignTop
            FontMetrics {
              id: descriptionLine
              font: descriptionInput.font
            }
            FoamyIcon {
              anchors.centerIn: parent
              width: FoamyStyle.iconSize
              height: width
              name: "text"
              color: FoamyPalette.mutedText
            }
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: FoamyStyle.gapSmall
            SafeTextArea {
              id: descriptionInput
              objectName: "editDescription"
              visible: !(editor.desc && editor.desc.state === "ready" && editor.desc.truncated)
              Layout.fillWidth: true
              quiet: true
              minimumHeight: 0
              color: FoamyPalette.secondaryText
              enabled: !!editor.desc && editor.desc.state === "ready" && !editor.descTruncated()
              placeholderText: !editor.desc || editor.desc.state === "loading" ? FoamyI18n.t("Loading…") : editor.desc.state === "error" ? "" : FoamyI18n.t("Description")
              maximumLength: 32766
              translate: FoamyI18n.t
              Accessible.name: FoamyI18n.t("Description")
              onTextEdited: editor.setError("description", "")
              onPasteErrorChanged: if (pasteError !== "")
                editor.setError("description", "")
              onEditingFinished: if (enabled)
                editor.saveField("description")
              onKeyPressed: function (event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                  editor.saveField("description")
                  event.accepted = true
                } else
                  editor.fieldKey("description", event)
              }
            }
            // Cut by the helper: read here, edited in Todoist.
            PlainText {
              objectName: "descriptionReadOnly"
              visible: !descriptionInput.visible
              Layout.fillWidth: true
              Layout.topMargin: FoamyStyle.controlPaddingY
              leftPadding: FoamyStyle.controlPaddingX
              text: editor.desc ? editor.desc.text : ""
              maximumLineCount: 8
              elide: Text.ElideRight
              color: FoamyPalette.secondaryText
            }
            PlainText {
              objectName: "descriptionNote"
              visible: !descriptionInput.visible
              Layout.fillWidth: true
              leftPadding: FoamyStyle.controlPaddingX
              text: FoamyI18n.t("Too long to edit here. Open it in Todoist.")
              font.pixelSize: FoamyStyle.font.bodySmall
              color: FoamyPalette.mutedText
            }
          }
        }
        ErrorLine {
          objectName: "descriptionError"
          Layout.leftMargin: editor.gutter
          error: editor.errorOf("description") !== "" ? editor.errorOf("description") : editor.desc && editor.desc.state === "error" ? editor.desc.error : ""
          pasteError: descriptionInput.pasteError
          onRetry: editor.desc && editor.desc.state === "error" ? editor.store.loadDescription(editor.taskId) : editor.retry("description")
        }
      }

      // ---- the properties ----
      // One row each under one hairline; the icons in the ring's column,
      // the values on the title's text edge.
      ColumnLayout {
        id: props
        objectName: "editorProperties"
        readonly property real inset: FoamyStyle.padding - FoamyStyle.gap
        // In the rows: where an icon and a value start.
        readonly property real iconX: editor.ringEdge + (editor.gutter - FoamyStyle.iconSize) / 2 - inset
        readonly property real valueX: editor.textEdge - inset
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        Layout.leftMargin: inset
        Layout.rightMargin: inset
        Layout.bottomMargin: FoamyStyle.padding - FoamyStyle.gap
        spacing: 0

        Divider {
          Layout.bottomMargin: FoamyStyle.gapSmall
        }
        Section {
          id: placeSection
          objectName: "section-place"
          caption: FoamyI18n.t("Project")
          accessibleName: FoamyI18n.t("Project") + ": " + placeRow.text
          error: editor.errorOf("place")
          onActivated: function (keyboard) {
            editor.openPlaceMenu(keyboard)
          }
          onRetry: editor.retry("place")
          ValueRow {
            id: placeRow
            objectName: "editPlace"
            iconName: "hash"
            iconColor: editor.roleColor(editor.placeProject ? Model.colorRole(editor.placeProject.color) : "muted")
            text: editor.placeLabel
          }
        }

        // Date: Todoist's own words for it (due.string) in a one-line field.
        Section {
          id: dueSection
          objectName: "section-due"
          caption: FoamyI18n.t("Date")
          // While its field is open the field has the clicks.
          active: editor.opened !== "due"
          hasValue: editor.dueLabel !== "" || editor.opened === "due"
          accessibleName: dueRow.visible ? FoamyI18n.t("Date") + ": " + dueRow.text : FoamyI18n.t("Add date")
          addText: FoamyI18n.t("Add date")
          lineHeight: editor.opened === "due" ? FoamyStyle.controlHeight : FoamyStyle.actionSize
          addIcon: "calendar"
          error: editor.errorOf("due")
          pasteError: dueInput.pasteError
          // Why its last move failed (in Small the list's line is hidden).
          note: editor.store.moveErrors[editor.taskId] || ""
          onActivated: function (keyboard) {
            editor.openDateMenu(keyboard)
          }
          onRetry: editor.retry("due")
          ValueRow {
            id: dueRow
            objectName: "dueRow"
            visible: editor.dueLabel !== "" && editor.opened !== "due"
            iconName: "calendar"
            iconColor: editor.dayColor("due", editor.dueMoved ? editor.movedDay : editor.task && editor.task.due ? editor.task.due.day : "")
            text: editor.dueLabel
          }
          SafeTextField {
            id: dueInput
            objectName: "editDue"
            visible: editor.opened === "due"
            Layout.fillWidth: true
            // Its text on the value's edge.
            Layout.leftMargin: props.valueX - leftPadding
            Layout.preferredHeight: FoamyStyle.controlHeight
            placeholderText: FoamyI18n.t("Type a date")
            maximumLength: 400
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Date")
            onTextEdited: editor.setError("due", "")
            onPasteErrorChanged: if (pasteError !== "")
              editor.setError("due", "")
            onEditingFinished: {
              editor.saveField("due")
              editor.closeField("due", false)
            }
            onKeyPressed: function (event) {
              editor.dateKey("due", event)
            }
          }
        }

        Section {
          id: deadlineSection
          objectName: "section-deadline"
          caption: FoamyI18n.t("Deadline")
          active: editor.opened !== "deadline"
          hasValue: editor.deadlineLabel !== "" || editor.opened === "deadline"
          accessibleName: deadlineRow.visible ? FoamyI18n.t("Deadline") + ": " + deadlineRow.text : FoamyI18n.t("Add deadline")
          addText: FoamyI18n.t("Add deadline")
          lineHeight: editor.opened === "deadline" ? FoamyStyle.controlHeight : FoamyStyle.actionSize
          addIcon: "target"
          error: editor.errorOf("deadline")
          pasteError: deadlineInput.pasteError
          onActivated: editor.openField("deadline")
          onRetry: editor.retry("deadline")
          ValueRow {
            id: deadlineRow
            objectName: "deadlineRow"
            visible: editor.deadlineLabel !== "" && editor.opened !== "deadline"
            iconName: "target"
            iconColor: editor.dayColor("deadline", editor.task ? editor.task.deadline : "")
            text: editor.deadlineLabel
          }
          SafeTextField {
            id: deadlineInput
            objectName: "editDeadline"
            visible: editor.opened === "deadline"
            Layout.fillWidth: true
            // Its text on the value's edge.
            Layout.leftMargin: props.valueX - leftPadding
            Layout.preferredHeight: FoamyStyle.controlHeight
            placeholderText: "YYYY-MM-DD"
            maximumLength: 10
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Deadline")
            onTextEdited: editor.setError("deadline", "")
            onPasteErrorChanged: if (pasteError !== "")
              editor.setError("deadline", "")
            onEditingFinished: {
              editor.saveField("deadline")
              editor.closeField("deadline", false)
            }
            onKeyPressed: function (event) {
              editor.dateKey("deadline", event)
            }
          }
        }

        Section {
          id: prioritySection
          objectName: "section-priority"
          caption: FoamyI18n.t("Priority")
          accessibleName: FoamyI18n.t("Priority") + ": " + priorityRow.text
          error: editor.errorOf("priority")
          onActivated: function (keyboard) {
            editor.openPriorityMenu(keyboard)
          }
          onRetry: editor.retry("priority")
          ValueRow {
            id: priorityRow
            objectName: "editPriority"
            // P1 is the API's 4.
            readonly property int level: editor.base ? 5 - editor.base.priority : 4
            iconName: "flag"
            iconColor: editor.roleColor(Model.priorityRole(5 - level))
            text: "P" + level
          }
        }

        Section {
          id: labelsSection
          objectName: "section-labels"
          caption: FoamyI18n.t("Labels")
          // A click adds a label (the chips' × remove theirs): only while
          // there is one to add.
          active: editor.task !== null && !editor.task.labelsTruncated && editor.freeLabels.length > 0
          hasValue: (editor.base !== null && editor.base.labels.length > 0) || (editor.task !== null && editor.task.labelsTruncated)
          addText: active ? FoamyI18n.t("Add label") : ""
          addIcon: "tag"
          accessibleName: FoamyI18n.t("Add label")
          error: editor.errorOf("labels")
          onActivated: function (keyboard) {
            editor.openLabelMenu(keyboard)
          }
          onRetry: editor.retry("labels")
          Item {
            visible: editor.base !== null && editor.base.labels.length > 0
            Layout.fillWidth: true
            implicitHeight: labelFlow.implicitHeight
            FoamyIcon {
              anchors.left: parent.left
              anchors.leftMargin: props.iconX
              y: (labelFlow.chipHeight - height) / 2
              width: FoamyStyle.iconSize
              height: width
              name: "tag"
              color: FoamyPalette.secondaryText
            }
            Flow {
              id: labelFlow
              objectName: "editLabels"
              readonly property real chipHeight: FoamyStyle.controlHeight - FoamyStyle.gapSmall
              anchors.left: parent.left
              anchors.leftMargin: props.valueX
              anchors.right: parent.right
              anchors.rightMargin: FoamyStyle.gap
              spacing: FoamyStyle.gapSmall
              Repeater {
                model: editor.base ? editor.base.labels : []
                Rectangle {
                  id: labelChip
                  required property string modelData
                  objectName: "label-" + modelData
                  // Never wider than the row: the name elides, the × stays.
                  width: Math.min(labelRow.implicitWidth + FoamyStyle.gap * 2, labelFlow.width)
                  height: labelFlow.chipHeight
                  radius: FoamyStyle.radiusSmall
                  color: FoamyPalette.fieldFill
                  border.width: FoamyStyle.borderWidth
                  border.color: FoamyPalette.border
                  Row {
                    id: labelRow
                    anchors.centerIn: parent
                    spacing: FoamyStyle.gapSmall
                    PlainText {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "@" + labelChip.modelData
                      width: Math.min(implicitWidth, labelFlow.width - FoamyStyle.gap * 2 - (removeLabel.visible ? removeLabel.width + labelRow.spacing : 0))
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      font.pixelSize: FoamyStyle.font.bodySmall
                      color: FoamyPalette.onSurface(FoamyPalette.info)
                    }
                    // ×: the label off (not while the list is cut); on the
                    // Tab path, Enter removes it.
                    FoamyAction {
                      id: removeLabel
                      objectName: "removeLabel"
                      visible: editor.task !== null && !editor.task.labelsTruncated
                      focusable: true
                      anchors.verticalCenter: parent.verticalCenter
                      width: FoamyStyle.iconSize + FoamyStyle.gapSmall
                      height: width
                      iconSize: FoamyStyle.font.caption
                      iconName: "x"
                      foreground: FoamyPalette.secondaryText
                      tooltipText: FoamyI18n.t("Remove %1", [labelChip.modelData])
                      onClicked: editor.removeLabel(labelChip.modelData)
                    }
                  }
                }
              }
              // After the chips, the mark that the row adds a label.
              Item {
                id: labelAdd
                objectName: "addLabel"
                visible: labelsSection.active
                width: FoamyStyle.actionSize
                height: labelFlow.chipHeight
                FoamyIcon {
                  anchors.centerIn: parent
                  width: FoamyStyle.iconSize
                  height: width
                  name: "plus"
                  color: FoamyPalette.secondaryText
                }
              }
            }
          }
          PlainText {
            objectName: "labelsNote"
            visible: editor.task !== null && editor.task.labelsTruncated
            Layout.fillWidth: true
            Layout.leftMargin: props.valueX
            Layout.rightMargin: FoamyStyle.gap
            text: FoamyI18n.t("This task has more labels than the panel keeps. Change them in Todoist.")
            font.pixelSize: FoamyStyle.font.bodySmall
            color: FoamyPalette.mutedText
          }
        }
      }
    }
  }

  // The pane's header: the task's place at the start (its mark in the
  // ring's column, the name on the title's text edge), Open in Todoist and
  // Close at the end, a hairline under it; the form scrolls below. After
  // the form in the file, so Tab reaches the task's fields first.
  Item {
    id: paneHead
    objectName: "paneHeader"
    visible: editor.pane && editor.task !== null
    width: parent.width
    height: visible ? FoamyStyle.actionSize + FoamyStyle.gapSmall * 2 + FoamyStyle.borderWidth : 0
    FoamyIcon {
      // Anchored, so a mirrored panel mirrors the header.
      anchors.left: parent.left
      anchors.leftMargin: editor.ringEdge + (editor.gutter - width) / 2
      y: (parent.height - FoamyStyle.borderWidth - height) / 2
      width: FoamyStyle.iconSize
      height: width
      name: "hash"
      color: editor.roleColor(editor.placeProject ? Model.colorRole(editor.placeProject.color) : "muted")
    }
    PlainText {
      objectName: "paneHeaderPlace"
      anchors.left: parent.left
      anchors.leftMargin: editor.textEdge
      anchors.right: paneHeadActions.left
      anchors.rightMargin: FoamyStyle.gap
      y: (parent.height - FoamyStyle.borderWidth - height) / 2
      text: editor.placeLabel
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
      font.pixelSize: FoamyStyle.font.bodySmall
      color: FoamyPalette.secondaryText
    }
    Row {
      id: paneHeadActions
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.padding - FoamyStyle.gap
      y: FoamyStyle.gapSmall
      // Completed, its Undo time running: said here, so the card keeps its
      // height (the place elides to make room).
      Item {
        visible: editor.struck
        width: completedLabel.implicitWidth + FoamyStyle.gapSmall
        height: paneOpen.height
        PlainText {
          id: completedLabel
          objectName: "paneCompleted"
          anchors.verticalCenter: parent.verticalCenter
          text: FoamyI18n.t("Completed")
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.secondaryText
        }
      }
      FoamyAction {
        objectName: "paneUndo"
        visible: editor.struck
        focusable: true
        iconName: ""
        label: FoamyI18n.t("Undo")
        foreground: FoamyPalette.onSurface(FoamyPalette.accent)
        onClicked: editor.completeTask()
      }
      FoamyAction {
        id: paneOpen
        objectName: "paneOpen"
        focusable: true
        iconName: "external-link"
        foreground: FoamyPalette.secondaryText
        tooltipText: FoamyI18n.t("Open in Todoist")
        onClicked: editor.store.openView("task", editor.taskId)
      }
      FoamyAction {
        objectName: "paneClose"
        focusable: true
        iconName: "x"
        foreground: FoamyPalette.secondaryText
        tooltipText: FoamyI18n.t("Close")
        onClicked: editor.closeRequested()
      }
    }
    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: FoamyStyle.borderWidth
      color: FoamyPalette.divider
    }
  }

  // ---- menus ----------------------------------------------------------------------
  // One menu at a time, filled when it opens: the project (and section),
  // the priority, or a label to add. A pick saves at once.
  property var menuItems: []
  Component {
    id: menuEntry
    FoamyMenuItem {
      property var pick: null
      onTriggered: if (pick)
        pick()
    }
  }
  function openMenu(anchor, entries, keyboard) {
    menuItems.forEach(function (item) {
      item.destroy()
    })
    menuItems = entries.map(function (entry) {
      return menuEntry.createObject(editor, entry)
    })
    picker.anchorItem = anchor
    picker.items = menuItems
    picker.open(keyboard)
  }
  FoamyMenu {
    id: picker
    // A pending move waits while a menu is open (the Date menu changes it).
    onAboutToOpen: editor.store.holdUndo(true)
    onClosed: editor.store.holdUndo(false)
  }
  // Each project, then its sections ("Project › Section"), the task's checked.
  function openPlaceMenu(keyboard) {
    if (!base)
      return
    var here = Edit.placeValue(base.projectId, base.sectionId)
    openMenu(placeRow, Edit.placeOptions(store.model, projects).map(function (option) {
      var project = editor.store.model.projects[option.projectId]
      return {
        text: option.label,
        iconName: "hash",
        iconColor: editor.roleColor(project ? Model.colorRole(project.color) : "muted"),
        checked: option.value === here,
        pick: function () {
          editor.save("place", option.value)
        }
      }
    }), keyboard)
  }
  // Date: the days a click moves the task to (as the list's menu: the
  // time stays, TodoStore.move), then Type a date… for Todoist's words. A
  // repeating task opens the field at once: its rule is changed in words.
  function openDateMenu(keyboard) {
    if (!task)
      return
    // A repeating task, or one that can't take a move now (completed,
    // sending): Todoist's words in the field.
    if ((task.due && task.due.recurring) || !store.canMove(taskId))
      return openField("due")
    // Its day as it stands (a pending move's): checked, so the keys start there.
    var current = Model.has(store.shownMoves, taskId) ? store.shownMoves[taskId] : task.due ? task.due.day : ""
    var day = function (text, iconName, value) {
      return {
        text: text,
        iconName: iconName,
        checked: value === current,
        pick: function () {
          // A typed draft (say a refused one) gives way to a pick that is
          // taken.
          if (editor.store.canMove(editor.taskId))
            editor.revert("due")
          editor.store.move(editor.taskId, value)
        }
      }
    }
    var today = store.today
    openMenu(dueRow.visible ? dueRow : dueSection, [day(FoamyI18n.t("Today"), "calendar", today), day(FoamyI18n.t("Tomorrow"), "sun", Model.addDays(today, 1)), day(FoamyI18n.t("Next week"), "calendar-range", Model.addDays(Model.weekEndOf(today, Qt.locale(FoamyI18n.formatLocale).firstDayOfWeek), 1)), day(FoamyI18n.t("No date"), "x", ""),
      {
        separator: true
      },
      {
        text: FoamyI18n.t("Type a date…"),
        iconName: "keyboard",
        pick: function () {
          editor.openField("due")
        }
      }
    ], keyboard)
  }
  // P1…P4 (the API's 4…1), each with its flag.
  function openPriorityMenu(keyboard) {
    if (!base)
      return
    openMenu(priorityRow, [4, 3, 2, 1].map(function (priority) {
      return {
        text: "P" + (5 - priority),
        iconName: "flag",
        iconColor: editor.roleColor(Model.priorityRole(priority)),
        checked: editor.base.priority === priority,
        pick: function () {
          editor.save("priority", priority)
        }
      }
    }), keyboard)
  }

  // ---- labels ---------------------------------------------------------------------
  // +: the personal labels the task doesn't have, in the menu.
  readonly property var freeLabels: {
    if (!base)
      return []
    var have = base.labels.map(function (name) {
      return name.toLowerCase()
    })
    return (store.model.labels || []).filter(function (label) {
      return label.personal && have.indexOf(label.name.toLowerCase()) < 0
    }).map(function (label) {
      return label.name
    })
  }
  // Each edit starts from the list the saves in flight leave.
  function removeLabel(name) {
    var task = baseNow()
    if (task)
      save("labels", task.labels.filter(function (label) {
        return label !== name
      }))
  }
  function addLabel(name) {
    var task = baseNow()
    if (task)
      save("labels", task.labels.concat([name]))
  }
  function openLabelMenu(keyboard) {
    openMenu(labelAdd.visible ? labelAdd : labelsSection, freeLabels.map(function (name) {
      return {
        text: name,
        iconName: "plus",
        pick: function () {
          editor.addLabel(name)
        }
      }
    }), keyboard)
  }

  // One property, as in Todoist: one row (taller only for more label
  // chips) and one click target with one hover fill. Its value, or when it
  // is empty what a click adds ("Add date", muted), then its caption at the
  // row's end. A click anywhere in it, or Enter or Space on its one cursor
  // stop, does what its value does (`activated`: a menu, or the one-line
  // field). The label chips' × and an open field keep their own clicks
  // (the click target lies under the content). A failed save's error and
  // Retry, or a refused paste into its field, sit under it, outside the
  // target.
  component Section: ColumnLayout {
    id: section
    property string caption: ""
    // A click target and a cursor stop now (not while its field is open,
    // nor Labels with nothing to add).
    property bool active: true
    property string accessibleName: caption
    // From the section's state, not the value's `visible`, which follows
    // the slot's own.
    property bool hasValue: true
    // An empty row: what a click adds, with its icon (else the caption alone).
    property string addText: ""
    property string addIcon: ""
    // The first line's height: a value row's, or an open field's.
    property real lineHeight: FoamyStyle.actionSize
    property string error: ""
    // Its field's pasteError (a catalog key).
    property string pasteError: ""
    property string note: ""
    default property alias content: slot.data
    signal activated(bool keyboard)
    signal retry
    function focusRow() {
      box.forceActiveFocus()
    }
    Layout.fillWidth: true
    spacing: 0
    // Layouts nest directly (no item between them), so the section's size
    // follows its content in the same pass.
    // A grid, so the row's click target (in the caption's cell) comes
    // before the value's own controls (a chip's ×) in the Tab chain.
    GridLayout {
      id: boxLayout
      Layout.fillWidth: true
      columns: 2
      columnSpacing: 0
      rowSpacing: 0
      // The caption, and the click target behind the whole row.
      Item {
        id: captionBox
        Layout.row: 0
        Layout.column: 1
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: captionText.visible ? captionText.implicitWidth + FoamyStyle.rowPadding : 0
        implicitHeight: FoamyStyle.rowHeight
        // The click target, its hover fill and its cursor stop: the whole
        // row (it reaches past this item, which doesn't clip).
        Rectangle {
          id: box
          objectName: "sectionBox"
          readonly property bool lit: section.active && (hover.hovered || activeFocus)
          x: -captionBox.x
          z: -1
          width: boxLayout.width
          height: boxLayout.height
          radius: FoamyStyle.radius
          color: lit ? FoamyPalette.hoverFill : "transparent"
          border.width: activeFocus ? 1 : 0
          border.color: Commons.Color.accent
          activeFocusOnTab: section.active
          Accessible.role: Accessible.Button
          Accessible.name: section.accessibleName
          Accessible.onPressAction: if (section.active)
            section.activated(false)
          Keys.onPressed: function (event) {
            if (section.active && (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
              event.accepted = true
              section.activated(true)
            }
          }
          // Over the chips' × too: the whole row stays lit.
          HoverHandler {
            id: hover
            enabled: section.active
            cursorShape: Qt.PointingHandCursor
          }
          MouseArea {
            objectName: "sectionClick"
            anchors.fill: parent
            enabled: section.active
            onClicked: section.activated(false)
          }
        }
        // The caption names a value; an empty row's words already do.
        PlainText {
          id: captionText
          objectName: "sectionCaption"
          visible: section.hasValue || section.addText === ""
          anchors.right: parent.right
          anchors.rightMargin: FoamyStyle.rowPadding
          anchors.verticalCenter: parent.verticalCenter
          text: section.caption
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.caption
          color: FoamyPalette.secondaryText
        }
      }
      ColumnLayout {
        id: slot
        Layout.row: 0
        Layout.column: 0
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        // The first line (a value row, a field or the chips) centres in the row.
        Layout.topMargin: (FoamyStyle.rowHeight - section.lineHeight) / 2
        Layout.bottomMargin: (FoamyStyle.rowHeight - section.lineHeight) / 2
        spacing: FoamyStyle.gapSmall
        ValueRow {
          objectName: "sectionEmpty"
          visible: !section.hasValue && section.addText !== ""
          iconName: section.addIcon
          iconColor: FoamyPalette.mutedText
          text: section.addText
          textColor: FoamyPalette.mutedText
        }
      }
    }
    ErrorLine {
      Layout.leftMargin: props.valueX
      Layout.rightMargin: FoamyStyle.gap
      Layout.bottomMargin: FoamyStyle.gap
      error: section.error
      pasteError: section.pasteError
      note: section.note
      onRetry: section.retry()
    }
  }

  // A property's value: its icon in the ring's column, its words on the
  // title's text edge (the section takes the clicks).
  component ValueRow: Item {
    id: valueRow
    property string iconName: ""
    property color iconColor: FoamyPalette.secondaryText
    property string text: ""
    property color textColor: FoamyPalette.text
    Layout.fillWidth: true
    implicitHeight: FoamyStyle.actionSize
    FoamyIcon {
      anchors.left: parent.left
      anchors.leftMargin: props.iconX
      anchors.verticalCenter: parent.verticalCenter
      width: FoamyStyle.iconSize
      height: width
      name: valueRow.iconName
      color: valueRow.iconColor
    }
    PlainText {
      objectName: "valueText"
      // Anchored, so a mirrored panel mirrors it.
      anchors.left: parent.left
      anchors.leftMargin: props.valueX
      anchors.right: parent.right
      // Apart from the caption at the row's end.
      anchors.rightMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      text: valueRow.text
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
      color: valueRow.textColor
    }
  }

  // A hairline between two properties.
  component Divider: Rectangle {
    Layout.fillWidth: true
    implicitHeight: 1
    color: FoamyPalette.divider
  }

  // A failed save (or read): why, and Retry. Else why the field refused a
  // paste (its pasteError, a catalog key), without Retry: nothing was sent
  // to try again. A refused paste ends the save's error, as typing does.
  component ErrorLine: RowLayout {
    id: line
    property string error: ""
    property string pasteError: ""
    // A message already in words, without Retry (a failed move's).
    property string note: ""
    readonly property string shown: error !== "" ? error : pasteError !== "" ? FoamyI18n.t(pasteError) : note
    signal retry
    objectName: "fieldError"
    visible: shown !== ""
    Layout.fillWidth: true
    spacing: FoamyStyle.gap
    PlainText {
      objectName: "fieldErrorText"
      Layout.fillWidth: true
      text: line.shown
      font.pixelSize: FoamyStyle.font.caption
      color: Commons.Color.urgent
      Accessible.role: Accessible.AlertMessage
    }
    FoamyButton {
      objectName: "fieldRetry"
      visible: line.error !== ""
      text: FoamyI18n.t("Retry")
      onClicked: line.retry()
    }
  }
}
