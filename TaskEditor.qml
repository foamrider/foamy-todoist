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
// (the compact band with Back, the task as the title, "Saving…"); Esc or
// Back returns. "pane" (Large): the details pane beside the list, always
// showing the selected task under a "Task" caption; Esc gives the keys
// back to the list (`keysReturned`).
//
// Each field saves on its own: when it loses the keys, on Enter (one-line
// fields) or Ctrl+Enter (the description). A save is one helper `update`
// holding only what changed (Edit.js), through the store's queue. Esc in
// a field drops its unsaved change; a failed save shows under the field
// with Retry and keeps what was typed. Choices (place, priority, labels)
// save when picked.
//
// The description isn't in the snapshot: the store fetches the shown
// task's (`TodoStore.description`, one at a time); the pane waits until
// the selection rests, so moving through the list reads only where it
// stops. Task text and descriptions only reach plain-text sinks.
FocusScope {
  id: editor
  property string taskId: ""
  property string mode: "page"
  // The form's columns: 2 in the Wide page (Date | Deadline, Project |
  // Section, Priority | Labels), else 1 (one place dropdown, "Project › Section").
  property int columns: 1
  // The rail's project list, for the place dropdowns: [{id, name}].
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
  readonly property bool menuOpen: labelPicker.opened
  readonly property alias contentField: contentInput
  readonly property alias dueField: dueInput
  readonly property alias deadlineField: deadlineInput
  readonly property alias descriptionField: descriptionInput
  readonly property alias backButton: pageBand.backButton
  readonly property alias labelMenu: labelPicker

  // Saves in flight, {request: {key, typed, fields}}: the field, what it
  // held when sent (a choice: what was picked) and the `update` fields.
  // Each reply is matched to its own request, and only the newest request
  // of a field may change that field: an older reply never replaces a newer
  // draft or what a newer request sent.
  property var pending: ({})
  // Their `update` fields, oldest first (for Edit.pending).
  readonly property var inFlight: requests().map(function (request) {
    return editor.pending[request].fields
  })
  property var errors: ({})
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
  function dirty(key) {
    var input = inputOf(key)
    return !!input && !!current() && input.text !== initialOf(key)
  }
  // A text field back to the task's value (and its error gone).
  function revert(key) {
    var input = inputOf(key)
    if (input && current())
      input.text = initialOf(key)
    setError(key, "")
  }
  function revertAll() {
    for (const key of ["content", "due", "deadline"])
      revert(key)
    descriptionInput.text = descNow() && descNow().state === "ready" ? descNow().text : ""
    errors = ({})
    attempts = ({})
  }
  // Fields that don't have the keys follow the snapshot, unless they hold
  // an unsaved change or a failed save's text.
  function follow() {
    if (!current())
      return
    for (const key of ["content", "due", "deadline"]) {
      const input = inputOf(key)
      if (!input.inputActiveFocus && errorOf(key) === "" && newest(key) < 0)
        input.text = initialOf(key)
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
    if (!result.fields)
      return
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
      fields: result.fields
    }
    pending = next
  }
  function saveField(key) {
    save(key, inputOf(key).text)
  }
  // Retry under a field: a text field sends what it holds, a choice what
  // was picked last.
  function retry(key) {
    if (inputOf(key))
      saveField(key)
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
      if (ok)
        editor.savedOnce = true
      // A newer save of the field is in flight: its reply decides what the
      // field shows (it holds this one's change too).
      if (editor.newest(save.key) > request)
        return
      if (!ok) {
        // The typed text stays; the line under the field says why.
        editor.setError(save.key, message !== "" ? message : FoamyI18n.t("Todoist didn't accept the change."))
        return
      }
      // The snapshot has the new value: the field shows it, unless typing went on.
      var input = editor.inputOf(save.key)
      if (input && input.text === save.typed)
        input.text = editor.initialOf(save.key)
    }
    function onModelChanged() {
      editor.follow()
    }
    function onDescriptionChanged() {
      var d = editor.descNow()
      if (d && d.state === "ready" && !descriptionInput.inputActiveFocus && editor.errorOf("description") === "" && editor.newest("description") < 0)
        descriptionInput.text = d.text
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
    labelPicker.close()
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
  // The caret in the first field (`e`, Enter on a row in Large).
  function focusFirst() {
    if (task)
      contentInput.focusInput()
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
  implicitHeight: (pane ? paneCaption.height : pageBand.implicitHeight) + Math.min(form.implicitHeight, pane ? form.implicitHeight : FoamyStyle.popupMaxHeight)

  // The page's band: Back, the task, "Saving…".
  FoamyHeroBand {
    id: pageBand
    objectName: "editorBand"
    visible: !editor.pane
    compact: true
    width: parent.width
    compactTitle: editor.task ? editor.task.text : ""
    saving: editor.saving
    onBack: editor.back()
  }
  // The pane's caption: "Task", and "Saving…" or "Saved".
  Item {
    id: paneCaption
    visible: editor.pane
    width: parent.width
    height: editor.pane ? FoamyStyle.rowHeight + FoamyStyle.gap : 0
    PlainText {
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.padding
      anchors.bottom: parent.bottom
      anchors.bottomMargin: FoamyStyle.gapSmall
      text: FoamyI18n.t("Task")
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.bodySmall
      font.weight: Font.DemiBold
      color: FoamyPalette.secondaryText
    }
    PlainText {
      objectName: "paneStatus"
      visible: editor.task !== null && text !== ""
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.padding
      anchors.bottom: parent.bottom
      anchors.bottomMargin: FoamyStyle.gapSmall
      text: editor.saving ? FoamyI18n.t("Saving…") : editor.savedOnce ? FoamyI18n.t("Saved") : ""
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.bodySmall
      color: FoamyPalette.mutedText
    }
  }

  // Nothing to show: no task selected (pane), or the task is gone.
  PlainText {
    objectName: "editorEmpty"
    visible: editor.task === null
    anchors.top: editor.pane ? paneCaption.bottom : pageBand.bottom
    anchors.topMargin: FoamyStyle.gapLarge
    x: FoamyStyle.padding
    width: parent.width - FoamyStyle.padding * 2
    horizontalAlignment: editor.pane ? Text.AlignLeft : Text.AlignHCenter
    text: editor.gone ? FoamyI18n.t("This task is no longer in Todoist.") : FoamyI18n.t("No task selected")
    font.pixelSize: FoamyStyle.font.bodySmall
    color: FoamyPalette.mutedText
  }

  FoamyWheelScroll {
    id: wheel
    target: scroll
  }
  Flickable {
    id: scroll
    visible: editor.task !== null
    anchors.top: editor.pane ? paneCaption.bottom : pageBand.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    contentWidth: width
    contentHeight: form.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      policy: Controls.ScrollBar.AsNeeded
    }

    ColumnLayout {
      id: form
      x: FoamyStyle.padding
      width: scroll.width - FoamyStyle.padding * 2
      spacing: FoamyStyle.gapLarge
      // A top and bottom margin inside the scroll.
      Item {
        Layout.preferredHeight: editor.pane ? 0 : FoamyStyle.gapSmall
      }

      FieldBlock {
        label: FoamyI18n.t("Task")
        error: editor.errorOf("content")
        onRetry: editor.retry("content")
        SafeTextField {
          id: contentInput
          objectName: "editContent"
          Layout.fillWidth: true
          Layout.preferredHeight: FoamyStyle.controlHeight
          maximumLength: 1000
          translate: FoamyI18n.t
          Accessible.name: FoamyI18n.t("Task")
          onTextEdited: editor.setError("content", "")
          onEditingFinished: editor.saveField("content")
          onKeyPressed: function (event) {
            editor.fieldKey("content", event)
          }
        }
      }

      GridLayout {
        Layout.fillWidth: true
        columns: editor.columns
        columnSpacing: FoamyStyle.gapLarge
        rowSpacing: FoamyStyle.gapLarge

        FieldBlock {
          label: FoamyI18n.t("Date")
          trailing: editor.task ? Model.dueWords(editor.task, editor.formatDate, editor.translate, editor.store.today) : ""
          hint: FoamyI18n.t("Type it as in Todoist; Todoist reads the date.")
          error: editor.errorOf("due")
          onRetry: editor.retry("due")
          SafeTextField {
            id: dueInput
            objectName: "editDue"
            Layout.fillWidth: true
            Layout.preferredHeight: FoamyStyle.controlHeight
            maximumLength: 400
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Date")
            onTextEdited: editor.setError("due", "")
            onEditingFinished: editor.saveField("due")
            onKeyPressed: function (event) {
              editor.fieldKey("due", event)
            }
          }
        }
        FieldBlock {
          label: FoamyI18n.t("Deadline")
          error: editor.errorOf("deadline")
          onRetry: editor.retry("deadline")
          SafeTextField {
            id: deadlineInput
            objectName: "editDeadline"
            Layout.fillWidth: true
            Layout.preferredHeight: FoamyStyle.controlHeight
            placeholderText: "YYYY-MM-DD"
            maximumLength: 10
            translate: FoamyI18n.t
            Accessible.name: FoamyI18n.t("Deadline")
            onTextEdited: editor.setError("deadline", "")
            onEditingFinished: editor.saveField("deadline")
            onKeyPressed: function (event) {
              editor.fieldKey("deadline", event)
            }
          }
        }

        // One column: one dropdown of "Project › Section"; two: Project | Section.
        FieldBlock {
          label: editor.columns > 1 ? FoamyI18n.t("Project") : FoamyI18n.t("Project and section")
          error: editor.errorOf("place")
          onRetry: editor.retry("place")
          FoamyDropdown {
            id: placeInput
            objectName: "editPlace"
            Layout.fillWidth: true
            showLabel: false
            Accessible.name: FoamyI18n.t("Project")
            value: editor.base ? (editor.columns > 1 ? Edit.placeValue(editor.base.projectId, "") : Edit.placeValue(editor.base.projectId, editor.base.sectionId)) : ""
            options: editor.base ? (editor.columns > 1 ? editor.projects.map(function (project) {
                return {
                  value: Edit.placeValue(project.id, ""),
                  label: project.name
                }
              }) : Edit.placeOptions(editor.store.model, editor.projects)) : []
            onChanged: function (value) {
              // Two columns: another project goes to its root; the same
              // one keeps its section (that is the Section dropdown's).
              if (editor.columns > 1 && editor.base && Edit.parsePlace(value).projectId === editor.base.projectId)
                return
              editor.save("place", value)
            }
          }
        }
        FieldBlock {
          visible: editor.columns > 1
          label: FoamyI18n.t("Section")
          FoamyDropdown {
            objectName: "editSection"
            Layout.fillWidth: true
            showLabel: false
            Accessible.name: FoamyI18n.t("Section")
            value: editor.base ? Edit.placeValue(editor.base.projectId, editor.base.sectionId) : ""
            options: editor.base && editor.columns > 1 ? Edit.placeOptions(editor.store.model, editor.projects, editor.base.projectId, FoamyI18n.t("No section")) : []
            onChanged: function (value) {
              editor.save("place", value)
            }
          }
        }

        FieldBlock {
          label: FoamyI18n.t("Priority")
          error: editor.errorOf("priority")
          onRetry: editor.retry("priority")
          Row {
            objectName: "editPriority"
            spacing: FoamyStyle.gapSmall
            Repeater {
              // P1 is the API's 4.
              model: [4, 3, 2, 1]
              Rectangle {
                id: chip
                required property int modelData
                required property int index
                readonly property bool chosen: editor.base !== null && editor.base.priority === modelData
                readonly property color tone: chip.roleColor(Model.priorityRole(modelData))
                function roleColor(role) {
                  return role === "error" ? FoamyPalette.error : role === "warning" ? FoamyPalette.warning : role === "accent" ? FoamyPalette.accent : FoamyPalette.mutedText
                }
                objectName: "priority-p" + (index + 1)
                width: FoamyStyle.controlHeight + FoamyStyle.gap
                height: FoamyStyle.controlHeight - FoamyStyle.gapSmall
                radius: FoamyStyle.radiusSmall
                color: chosen ? Qt.alpha(tone, 0.22) : chipMouse.containsMouse || activeFocus ? FoamyPalette.hoverFill : "transparent"
                border.width: FoamyStyle.borderWidth
                border.color: chosen || activeFocus ? tone : FoamyPalette.border
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.checked: chosen
                Accessible.name: "P" + (index + 1)
                Keys.onPressed: function (event) {
                  if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    editor.save("priority", chip.modelData)
                    event.accepted = true
                  }
                }
                PlainText {
                  anchors.centerIn: parent
                  text: "P" + (chip.index + 1)
                  wrapMode: Text.NoWrap
                  font.family: FoamyStyle.monoFamily
                  font.pixelSize: FoamyStyle.font.bodySmall
                  font.weight: chip.chosen ? Font.DemiBold : Font.Normal
                  color: FoamyPalette.onSurface(chip.tone)
                }
                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: editor.save("priority", chip.modelData)
                }
              }
            }
          }
        }

        FieldBlock {
          label: FoamyI18n.t("Labels")
          error: editor.errorOf("labels")
          onRetry: editor.retry("labels")
          hint: editor.task && editor.task.labelsTruncated ? FoamyI18n.t("This task has more labels than the panel keeps. Change them in Todoist.") : ""
          Flow {
            objectName: "editLabels"
            Layout.fillWidth: true
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
                  // ×: the label off (not while the list is cut).
                  FoamyAction {
                    objectName: "removeLabel"
                    visible: editor.task !== null && !editor.task.labelsTruncated
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
            FoamyButton {
              id: addLabelButton
              objectName: "addLabel"
              visible: editor.task !== null && !editor.task.labelsTruncated && editor.freeLabels.length > 0
              height: FoamyStyle.controlHeight - FoamyStyle.gapSmall
              focusable: true
              text: FoamyI18n.t("+ label")
              onClicked: editor.openLabelMenu(activeFocus)
            }
          }
        }
      }

      FieldBlock {
        label: FoamyI18n.t("Description")
        error: editor.errorOf("description") !== "" ? editor.errorOf("description") : editor.desc && editor.desc.state === "error" ? editor.desc.error : ""
        hint: editor.desc && editor.desc.state === "ready" && editor.desc.truncated ? FoamyI18n.t("Too long to edit here. Open it in Todoist.") : ""
        onRetry: editor.desc && editor.desc.state === "error" ? editor.store.loadDescription(editor.taskId) : editor.retry("description")
        SafeTextArea {
          id: descriptionInput
          objectName: "editDescription"
          visible: !(editor.desc && editor.desc.state === "ready" && editor.desc.truncated)
          Layout.fillWidth: true
          Layout.preferredHeight: height
          enabled: !!editor.desc && editor.desc.state === "ready"
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
          text: editor.desc ? editor.desc.text : ""
          maximumLineCount: 8
          elide: Text.ElideRight
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.secondaryText
        }
      }

      Flow {
        Layout.fillWidth: true
        spacing: FoamyStyle.gap
        FoamyButton {
          objectName: "editComplete"
          focusable: true
          text: FoamyI18n.t("Complete")
          iconName: "check"
          onClicked: {
            editor.store.complete(editor.taskId)
            if (!editor.pane)
              editor.back()
          }
        }
        FoamyButton {
          objectName: "editOpen"
          focusable: true
          text: FoamyI18n.t("Open in Todoist")
          iconName: "external-link"
          onClicked: editor.store.openView("task", editor.taskId)
        }
      }
      Item {
        Layout.preferredHeight: FoamyStyle.padding - FoamyStyle.gapLarge
      }
    }
  }

  // ---- labels ---------------------------------------------------------------------
  // "+ label": the personal labels the task doesn't have, in a menu.
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
  property var labelItems: []
  Component {
    id: labelItem
    FoamyMenuItem {
      property string labelName: ""
      text: labelName
      iconName: "plus"
      onTriggered: editor.addLabel(labelName)
    }
  }
  function openLabelMenu(keyboard) {
    labelItems.forEach(function (item) {
      item.destroy()
    })
    labelItems = freeLabels.map(function (name) {
      return labelItem.createObject(editor, {
        labelName: name
      })
    })
    labelPicker.items = labelItems
    labelPicker.open(keyboard)
  }
  FoamyMenu {
    id: labelPicker
    anchorItem: addLabelButton
  }

  // One field: its label (and, on the end, the panel's words for its
  // value), the control, a hint, and a failed save's error with Retry.
  component FieldBlock: ColumnLayout {
    id: block
    property string label: ""
    property string trailing: ""
    property string hint: ""
    property string error: ""
    default property alias control: slot.data
    signal retry
    Layout.fillWidth: true
    Layout.alignment: Qt.AlignTop
    spacing: FoamyStyle.gapSmall
    RowLayout {
      Layout.fillWidth: true
      spacing: FoamyStyle.gap
      PlainText {
        Layout.fillWidth: true
        text: block.label
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.secondaryText
      }
      PlainText {
        objectName: "fieldWords"
        visible: text !== ""
        text: block.trailing
        wrapMode: Text.NoWrap
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.mutedText
      }
    }
    ColumnLayout {
      id: slot
      Layout.fillWidth: true
      spacing: 0
    }
    PlainText {
      visible: block.hint !== ""
      Layout.fillWidth: true
      text: block.hint
      font.pixelSize: FoamyStyle.font.caption
      color: FoamyPalette.mutedText
    }
    RowLayout {
      objectName: "fieldError"
      visible: block.error !== ""
      Layout.fillWidth: true
      spacing: FoamyStyle.gap
      PlainText {
        objectName: "fieldErrorText"
        Layout.fillWidth: true
        text: block.error
        font.pixelSize: FoamyStyle.font.caption
        color: Commons.Color.urgent
        Accessible.role: Accessible.AlertMessage
      }
      FoamyButton {
        objectName: "fieldRetry"
        text: FoamyI18n.t("Retry")
        onClicked: block.retry()
      }
    }
  }
}
