pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons as Commons
import "kit"
import "Model.js" as Model
import "Edit.js" as Edit

// The task editor, one component used two ways. `mode` "page" (Small and
// Wide): a sub-view in place of the list, built like the settings page
// (the compact band with Back, the task as the title, "Saving…", Open in
// Todoist); Esc or Back returns. "pane" (Large): the details pane beside
// the list, always showing the selected task; Esc gives the keys back to
// the list (`keysReturned`).
//
// It reads like the task, after Todoist's task view: the completion ring
// and the title, the description under it, then the properties (Project,
// Date, Deadline, Priority, Labels) as captioned value rows. Every part is
// edited where it is: the title and description are quiet fields; a value
// row opens its menu, or (Date, Deadline) a one-line field in its place.
// In the Wide page the properties sit in a column of their own (`split`).
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
  // Todoist's split (the Wide page): the title and description on the
  // left, the properties in a column on a tinted surface on the right.
  property bool split: false
  // The rail's project list, for the project menu: [{id, name}].
  property var projects: []
  signal back
  signal keysReturned

  readonly property var store: TodoStore
  readonly property bool pane: mode === "pane"
  readonly property var task: taskId !== "" && store.model.byId[taskId] ? store.model.byId[taskId] : null
  // The task as the saves in flight will leave it: the choices show it.
  readonly property var base: task ? Edit.pending(task, inFlight) : null
  // The task went from the snapshot (completed or deleted elsewhere).
  readonly property bool gone: taskId !== "" && task === null
  readonly property var desc: store.description.id === taskId && taskId !== "" ? store.description : null
  readonly property bool saving: Object.keys(pending).length > 0
  // A save worked since the task was shown (the pane says "Saved").
  property bool savedOnce: false
  readonly property bool menuOpen: picker.opened
  readonly property alias contentField: contentInput
  readonly property alias dueField: dueInput
  readonly property alias deadlineField: deadlineInput
  readonly property alias descriptionField: descriptionInput
  readonly property alias backButton: pageBand.backButton
  // The one menu (project, priority or labels; one at a time).
  readonly property alias menu: picker
  readonly property alias ring: ringBox
  // Open in Todoist: in the page's band, or at the top of the pane.
  readonly property Item openButton: pane ? paneOpen : pageOpen
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
  // request's value: baselineOf() adds the saves in flight. Read
  // imperatively (dirty()), never bound, so it is mutated in place.
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
  // A text field set to what Todoist holds (no save of it in flight): it
  // is the confirmed value now (read back from the field, which may turn
  // CRLF into LF).
  function setText(key, value) {
    var input = inputOf(key)
    input.text = value
    confirmed[key] = input.text
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
        editor.savedOnce = true
        // Todoist has it, also while a newer save of the field runs: if
        // that one is refused, the field is measured against this value.
        // (The store's queue runs one job at a time, so replies come in
        // order.)
        if (input)
          editor.confirmed[save.key] = save.sent
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
    savedOnce = false
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
    commit()
    store.complete(id)
    if (!pane)
      back()
  }
  // The caret in the first field (`e`, Enter on a row in Large).
  function focusFirst() {
    if (!task)
      return
    contentInput.focusInput()
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
  // The value row (or the caption's +) opens the field, the caret at its end.
  function openField(key) {
    if (!task)
      return
    opened = key
    var input = inputOf(key)
    input.focusInput()
    input.cursorPosition = input.text.length
  }
  // The field closes (losing the keys, it saves what it holds:
  // onEditingFinished); `refocus` gives the keys to its row (Enter, Esc).
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
  readonly property string dueLabel: {
    var draft = draftOf("due")
    if (draft !== null)
      return draft.trim()
    return task ? Model.dueWords(task, formatDate, translate, store.today) : ""
  }
  readonly property string deadlineLabel: {
    var draft = draftOf("deadline")
    var day = draft !== null ? draft.trim() : task ? task.deadline || "" : ""
    return Model.dayWords(day, formatDate, translate, store.today) || day
  }
  function roleColor(role) {
    return role === "error" ? FoamyPalette.error : role === "warning" ? FoamyPalette.warning : role === "success" ? FoamyPalette.success : role === "info" ? FoamyPalette.info : role === "accent" ? FoamyPalette.accent : FoamyPalette.mutedText
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
  // The Wide page's property column, tinted edge to edge.
  readonly property real sideWidth: Commons.Style.space(240)
  implicitHeight: (pane ? paneTop.height : pageBand.implicitHeight) + Math.min(form.implicitHeight, pane ? form.implicitHeight : FoamyStyle.popupMaxHeight)

  // The page's band: Back, the task, "Saving…", Open in Todoist.
  FoamyHeroBand {
    id: pageBand
    objectName: "editorBand"
    visible: !editor.pane
    compact: true
    width: parent.width
    compactTitle: editor.task ? editor.task.text : ""
    saving: editor.saving
    onBack: editor.back()
    compactTrailing: [
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
  // The pane's top: "Saving…" or "Saved", and Open in Todoist.
  Item {
    id: paneTop
    visible: editor.pane
    width: parent.width
    height: editor.pane ? FoamyStyle.actionSize + FoamyStyle.gap * 2 : 0
    PlainText {
      objectName: "paneStatus"
      visible: editor.task !== null && text !== ""
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.padding
      anchors.verticalCenter: parent.verticalCenter
      text: editor.saving ? FoamyI18n.t("Saving…") : editor.savedOnce ? FoamyI18n.t("Saved") : ""
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.bodySmall
      color: FoamyPalette.mutedText
    }
    FoamyAction {
      id: paneOpen
      objectName: "paneOpen"
      visible: editor.task !== null
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.padding - FoamyStyle.gapSmall
      anchors.verticalCenter: parent.verticalCenter
      focusable: true
      iconName: "external-link"
      foreground: FoamyPalette.secondaryText
      tooltipText: FoamyI18n.t("Open in Todoist")
      onClicked: editor.store.openView("task", editor.taskId)
    }
  }

  // Nothing to show: no task selected (pane), or the task is gone.
  PlainText {
    objectName: "editorEmpty"
    visible: editor.task === null
    anchors.top: editor.pane ? paneTop.bottom : pageBand.bottom
    anchors.topMargin: editor.pane ? 0 : FoamyStyle.gapLarge
    x: FoamyStyle.padding
    width: parent.width - FoamyStyle.padding * 2
    horizontalAlignment: editor.pane ? Text.AlignLeft : Text.AlignHCenter
    text: editor.gone ? FoamyI18n.t("This task is no longer in Todoist.") : FoamyI18n.t("No task selected")
    font.pixelSize: FoamyStyle.font.bodySmall
    color: FoamyPalette.mutedText
  }

  // The Wide page's property column: a slightly different surface, from
  // the band to the bottom (it doesn't scroll; the properties do).
  Rectangle {
    objectName: "editorSide"
    visible: editor.split && editor.task !== null
    anchors.right: parent.right
    anchors.top: pageBand.bottom
    anchors.bottom: parent.bottom
    width: editor.sideWidth
    color: FoamyPalette.noteFill
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
    anchors.top: editor.pane ? paneTop.bottom : pageBand.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: form.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      policy: Controls.ScrollBar.AsNeeded
    }

    // One column (the title and description, then the properties), or
    // Todoist's split: two columns side by side.
    GridLayout {
      id: form
      width: scroll.width
      columns: editor.split ? 2 : 1
      columnSpacing: 0
      rowSpacing: 0

      // ---- the title and the description ----
      ColumnLayout {
        id: head
        objectName: "editorHead"
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        Layout.leftMargin: FoamyStyle.padding - FoamyStyle.gapSmall
        Layout.rightMargin: FoamyStyle.padding - FoamyStyle.gapSmall
        Layout.topMargin: editor.pane ? 0 : FoamyStyle.gapLarge
        Layout.bottomMargin: editor.split ? FoamyStyle.padding : FoamyStyle.gap
        spacing: FoamyStyle.gapSmall

        RowLayout {
          Layout.fillWidth: true
          spacing: 0
          // The ring completes, as on the list's rows: the priority's
          // colour, the check on hover or with the keys.
          Item {
            id: ringBox
            objectName: "editRing"
            readonly property color tone: editor.base ? editor.roleColor(Model.priorityRole(editor.base.priority)) : FoamyPalette.mutedText
            readonly property bool lit: ringMouse.containsMouse || activeFocus
            // As tall as the title's first line, so the ring centres on it.
            Layout.preferredWidth: editor.gutter
            Layout.preferredHeight: contentInput.topPadding + contentInput.bottomPadding + titleLine.height
            Layout.alignment: Qt.AlignTop
            activeFocusOnTab: true
            Accessible.role: Accessible.CheckBox
            Accessible.checked: false
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
              border.width: 1.5
              border.color: ringBox.tone
              color: Qt.alpha(ringBox.tone, ringBox.lit ? 0.28 : 0.12)
              FoamyIcon {
                visible: ringBox.lit
                anchors.centerIn: parent
                width: FoamyStyle.font.bodySmall
                height: width
                name: "check"
                color: ringBox.tone
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
          SafeTextArea {
            id: contentInput
            objectName: "editContent"
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            quiet: true
            minimumHeight: 0
            maximumHeight: FoamyStyle.controlHeight * 4
            font.pixelSize: FoamyStyle.font.heading
            font.weight: Font.DemiBold
            maximumLength: 1000
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Task")
            onTextEdited: editor.setError("content", "")
            onEditingFinished: editor.saveField("content")
            onKeyPressed: function (event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                event.accepted = true
                editor.saveField("content")
              } else
                editor.fieldKey("content", event)
            }
          }
        }
        ErrorLine {
          objectName: "contentError"
          Layout.leftMargin: editor.gutter
          error: editor.errorOf("content")
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
          onRetry: editor.desc && editor.desc.state === "error" ? editor.store.loadDescription(editor.taskId) : editor.retry("description")
        }
      }

      // ---- the properties ----
      // Captioned sections with hairlines between them; the value rows'
      // icons line up with the ring (one column) or the column's inset.
      ColumnLayout {
        id: props
        objectName: "editorProperties"
        readonly property real inset: editor.split ? FoamyStyle.gapLarge : FoamyStyle.padding - FoamyStyle.gap
        Layout.fillWidth: !editor.split
        Layout.preferredWidth: editor.split ? editor.sideWidth - inset * 2 : -1
        Layout.alignment: Qt.AlignTop
        Layout.leftMargin: inset
        Layout.rightMargin: inset
        Layout.topMargin: editor.split ? FoamyStyle.gapLarge : 0
        Layout.bottomMargin: FoamyStyle.padding - FoamyStyle.gap
        spacing: 0

        Section {
          id: placeSection
          objectName: "section-place"
          caption: FoamyI18n.t("Project")
          error: editor.errorOf("place")
          onRetry: editor.retry("place")
          ValueRow {
            id: placeRow
            objectName: "editPlace"
            readonly property var project: editor.base ? editor.store.model.projects[editor.base.projectId] : null
            readonly property var section: editor.base && editor.base.sectionId ? editor.store.model.sections[editor.base.sectionId] : null
            iconName: "hash"
            iconColor: editor.roleColor(project ? Model.colorRole(project.color) : "muted")
            text: (project ? project.name : "") + (section ? " › " + section.name : "")
            accessibleName: FoamyI18n.t("Project") + ": " + text
            onActivated: function (keyboard) {
              editor.openPlaceMenu(keyboard)
            }
          }
        }
        Divider {}

        // Date: Todoist's own words for it (due.string) in a one-line field.
        Section {
          id: dueSection
          objectName: "section-due"
          caption: FoamyI18n.t("Date")
          canAdd: editor.dueLabel === "" && editor.opened !== "due"
          addTip: FoamyI18n.t("Add date")
          error: editor.errorOf("due")
          onAdd: editor.openField("due")
          onRetry: editor.retry("due")
          function focusRow() {
            (dueRow.visible ? dueRow : addButton).forceActiveFocus()
          }
          ValueRow {
            id: dueRow
            objectName: "dueRow"
            visible: editor.dueLabel !== "" && editor.opened !== "due"
            iconName: "calendar"
            iconColor: editor.dayColor("due", editor.task && editor.task.due ? editor.task.due.day : "")
            text: editor.dueLabel
            accessibleName: FoamyI18n.t("Date") + ": " + text
            onActivated: editor.openField("due")
          }
          SafeTextField {
            id: dueInput
            objectName: "editDue"
            visible: editor.opened === "due"
            Layout.fillWidth: true
            Layout.preferredHeight: FoamyStyle.controlHeight
            placeholderText: FoamyI18n.t("Type a date")
            maximumLength: 400
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Date")
            onTextEdited: editor.setError("due", "")
            onEditingFinished: {
              editor.saveField("due")
              editor.closeField("due", false)
            }
            onKeyPressed: function (event) {
              editor.dateKey("due", event)
            }
          }
        }
        Divider {}

        Section {
          id: deadlineSection
          objectName: "section-deadline"
          caption: FoamyI18n.t("Deadline")
          canAdd: editor.deadlineLabel === "" && editor.opened !== "deadline"
          addTip: FoamyI18n.t("Add deadline")
          error: editor.errorOf("deadline")
          onAdd: editor.openField("deadline")
          onRetry: editor.retry("deadline")
          function focusRow() {
            (deadlineRow.visible ? deadlineRow : addButton).forceActiveFocus()
          }
          ValueRow {
            id: deadlineRow
            objectName: "deadlineRow"
            visible: editor.deadlineLabel !== "" && editor.opened !== "deadline"
            iconName: "target"
            iconColor: editor.dayColor("deadline", editor.task ? editor.task.deadline : "")
            text: editor.deadlineLabel
            accessibleName: FoamyI18n.t("Deadline") + ": " + text
            onActivated: editor.openField("deadline")
          }
          SafeTextField {
            id: deadlineInput
            objectName: "editDeadline"
            visible: editor.opened === "deadline"
            Layout.fillWidth: true
            Layout.preferredHeight: FoamyStyle.controlHeight
            placeholderText: "YYYY-MM-DD"
            maximumLength: 10
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Deadline")
            onTextEdited: editor.setError("deadline", "")
            onEditingFinished: {
              editor.saveField("deadline")
              editor.closeField("deadline", false)
            }
            onKeyPressed: function (event) {
              editor.dateKey("deadline", event)
            }
          }
        }
        Divider {}

        Section {
          id: prioritySection
          objectName: "section-priority"
          caption: FoamyI18n.t("Priority")
          error: editor.errorOf("priority")
          onRetry: editor.retry("priority")
          ValueRow {
            id: priorityRow
            objectName: "editPriority"
            // P1 is the API's 4.
            readonly property int level: editor.base ? 5 - editor.base.priority : 4
            iconName: "flag"
            iconColor: editor.roleColor(Model.priorityRole(5 - level))
            text: "P" + level
            accessibleName: FoamyI18n.t("Priority") + ": " + text
            onActivated: function (keyboard) {
              editor.openPriorityMenu(keyboard)
            }
          }
        }
        Divider {}

        Section {
          id: labelsSection
          objectName: "section-labels"
          caption: FoamyI18n.t("Labels")
          canAdd: editor.task !== null && !editor.task.labelsTruncated && editor.freeLabels.length > 0
          addTip: FoamyI18n.t("Add label")
          addName: "addLabel"
          error: editor.errorOf("labels")
          onAdd: function (keyboard) {
            editor.openLabelMenu(keyboard)
          }
          onRetry: editor.retry("labels")
          Flow {
            objectName: "editLabels"
            visible: editor.base !== null && editor.base.labels.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: FoamyStyle.gap
            Layout.rightMargin: FoamyStyle.gap
            spacing: FoamyStyle.gapSmall
            Repeater {
              model: editor.base ? editor.base.labels : []
              Rectangle {
                id: labelChip
                required property string modelData
                objectName: "label-" + modelData
                width: labelRow.implicitWidth + FoamyStyle.gap * 2
                height: FoamyStyle.controlHeight - FoamyStyle.gapSmall
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
                    wrapMode: Text.NoWrap
                    font.pixelSize: FoamyStyle.font.bodySmall
                    color: FoamyPalette.onSurface(FoamyPalette.info)
                  }
                  // ×: the label off (not while the list is cut); on the
                  // Tab path, Enter removes it.
                  FoamyAction {
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
          }
          PlainText {
            objectName: "labelsNote"
            visible: editor.task !== null && editor.task.labelsTruncated
            Layout.fillWidth: true
            Layout.leftMargin: FoamyStyle.gap
            text: FoamyI18n.t("This task has more labels than the panel keeps. Change them in Todoist.")
            font.pixelSize: FoamyStyle.font.bodySmall
            color: FoamyPalette.mutedText
          }
        }
      }
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
    openMenu(labelsSection.addButton, freeLabels.map(function (name) {
      return {
        text: name,
        iconName: "plus",
        pick: function () {
          editor.addLabel(name)
        }
      }
    }), keyboard)
  }

  // One property: its caption (with + at its end, to add a first value),
  // the value, and a failed save's error with Retry.
  component Section: ColumnLayout {
    id: section
    property string caption: ""
    property bool canAdd: false
    property string addTip: ""
    property string addName: ""
    property string error: ""
    readonly property alias addButton: plus
    default property alias content: slot.data
    signal add(bool keyboard)
    signal retry
    Layout.fillWidth: true
    spacing: FoamyStyle.gapSmall
    Item {
      Layout.fillWidth: true
      Layout.topMargin: FoamyStyle.gap
      implicitHeight: FoamyStyle.actionSize
      PlainText {
        objectName: "sectionCaption"
        anchors.left: parent.left
        anchors.leftMargin: FoamyStyle.gap
        anchors.right: plus.visible ? plus.left : parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: section.caption
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: FoamyStyle.font.bodySmall
        font.weight: Font.DemiBold
        color: FoamyPalette.secondaryText
      }
      FoamyAction {
        id: plus
        objectName: section.addName !== "" ? section.addName : "sectionAdd"
        visible: section.canAdd
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        focusable: true
        iconName: "plus"
        foreground: FoamyPalette.secondaryText
        tooltipText: section.addTip
        onClicked: section.add(activeFocus)
      }
    }
    ColumnLayout {
      id: slot
      Layout.fillWidth: true
      Layout.bottomMargin: FoamyStyle.gap
      spacing: FoamyStyle.gapSmall
    }
    ErrorLine {
      Layout.leftMargin: FoamyStyle.gap
      Layout.bottomMargin: FoamyStyle.gap
      error: section.error
      onRetry: section.retry()
    }
  }

  // A property's value: its icon and words; a click, Enter or Space
  // changes it (a menu, or the one-line field).
  component ValueRow: Rectangle {
    id: valueRow
    property string iconName: ""
    property color iconColor: FoamyPalette.secondaryText
    property string text: ""
    property string accessibleName: ""
    signal activated(bool keyboard)
    Layout.fillWidth: true
    implicitHeight: FoamyStyle.actionSize
    radius: FoamyStyle.radius
    color: valueMouse.containsMouse || activeFocus ? FoamyPalette.hoverFill : "transparent"
    border.width: activeFocus ? 1 : 0
    border.color: Commons.Color.accent
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.onPressAction: valueRow.activated(false)
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true
        valueRow.activated(true)
      }
    }
    FoamyIcon {
      id: valueIcon
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      width: FoamyStyle.iconSize
      height: width
      name: valueRow.iconName
      color: valueRow.iconColor
    }
    PlainText {
      objectName: "valueText"
      anchors.left: valueIcon.right
      anchors.leftMargin: FoamyStyle.gap
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      text: valueRow.text
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
      color: FoamyPalette.text
    }
    MouseArea {
      id: valueMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: valueRow.activated(false)
    }
  }

  // A hairline between two properties.
  component Divider: Rectangle {
    Layout.fillWidth: true
    implicitHeight: 1
    color: FoamyPalette.divider
  }

  // A failed save (or read): why, and Retry.
  component ErrorLine: RowLayout {
    id: line
    property string error: ""
    signal retry
    objectName: "fieldError"
    visible: error !== ""
    Layout.fillWidth: true
    spacing: FoamyStyle.gap
    PlainText {
      objectName: "fieldErrorText"
      Layout.fillWidth: true
      text: line.error
      font.pixelSize: FoamyStyle.font.caption
      color: Commons.Color.urgent
      Accessible.role: Accessible.AlertMessage
    }
    FoamyButton {
      objectName: "fieldRetry"
      text: FoamyI18n.t("Retry")
      onClicked: line.retry()
    }
  }
}
