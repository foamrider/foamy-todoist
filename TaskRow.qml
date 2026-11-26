pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui as Ui
import "kit"
import "Model.js" as Model

// One row of the list (Model.rows): a task, a section or day header, or
// Upcoming's folded Overdue row. A task row: the priority ring (complete),
// the content, a detail line (date, project, labels, recurring) and the
// due time on the trailing end, or Undo while its completion or its move
// to another day can be undone. A moved row stays where it is, dimmed,
// its new date in the accent colour. A row whose completion is
// unconfirmed reads whole: its title in the secondary tone, a plain ring
// and a refresh mark in the time's place.
Item {
  id: row
  required property var entry
  property bool hasCursor: false
  // The keys moved the cursor here: its accent border (FoamyCursor.byKeys).
  property bool byKeys: false
  // The letter keys act on this row when it has the cursor (in Wide they
  // can be the pane's task's instead): its actions' tooltips name them then.
  property bool keysHere: true
  // Search: the title cut into runs, the query's matches bold (Model.matchRuns).
  // Runs sit in a Row, which lays them out in the layout's direction: only
  // for a left-to-right title in a left-to-right panel (else plain).
  property var titleRuns: []
  readonly property bool matched: isTask && titleRuns.length > 1 && !LayoutMirroring.enabled && !/[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]/.test(entry.text)
  // The task the Wide details pane shows.
  property bool selected: false
  property bool interactive: true
  readonly property string kind: entry ? entry.kind : ""
  readonly property bool isTask: kind === "task"
  readonly property bool struck: isTask && entry.struck === true
  readonly property bool moved: isTask && entry.moved === true
  readonly property bool unconfirmed: isTask && entry.unconfirmed === true
  // Its completion or move is still in the undo window (the view says).
  property bool undoable: false
  // The cursor row's actions in the time's place: Tomorrow, and a menu of
  // days (the view says when: a task that can move, not waiting for Undo).
  property bool showActions: false
  readonly property alias dateAction: dateAction
  signal hovered
  signal completeRequested
  signal undoRequested
  signal tomorrowRequested
  signal dateMenuRequested
  // Today's Overdue heading: its tasks to today.
  signal moveAllRequested
  signal openRequested
  signal foldRequested

  // The list sets the height (TodoView.heightOf), so it can size itself
  // without building every row.
  // Where row content (the ring, a header's title) starts: the surface's
  // inset plus its padding.
  readonly property real contentInset: FoamyStyle.gapLarge + FoamyStyle.rowPadding
  readonly property real indent: isTask ? entry.depth * (FoamyStyle.iconSize + FoamyStyle.gapLarge) : 0

  // Marks and icons on the surface (rings): readable in a light theme too.
  function roleColor(role) {
    switch (role) {
    case "error":
      return FoamyPalette.onSurface(FoamyPalette.error)
    case "warning":
      return FoamyPalette.onSurface(FoamyPalette.warning)
    case "success":
      return FoamyPalette.onSurface(FoamyPalette.success)
    case "info":
      return FoamyPalette.onSurface(FoamyPalette.info)
    case "accent":
      return FoamyPalette.onSurface(FoamyPalette.accent)
    default:
      return FoamyPalette.mutedText
    }
  }
  // The date on the detail line (Model.detailDate, from the list), the
  // deadline's day (Model.dayWords), and the tone of a time today: "late"
  // (passed), "next" (the list's next one), "later" ("" otherwise).
  property string dateText: ""
  property string deadlineText: ""
  property string timeTone: ""
  // Upcoming's group headers: {title, sub} (Model.upcomingHeading, from the
  // list), and a task's day before its time in the later groups.
  property var heading: null
  property string trailDay: ""
  readonly property bool isGroup: kind === "header" && !!entry.group
  readonly property string title: {
    if (!entry || isTask)
      return ""
    if (isGroup)
      return heading ? heading.title : ""
    if (entry.title === "overdue")
      return FoamyI18n.t("Overdue")
    if (entry.title === "today")
      return FoamyI18n.t("Today")
    return entry.title
  }

  // ---- a header -------------------------------------------------------------------
  // Upcoming's later groups have a hairline above (the row is taller then).
  Rectangle {
    objectName: "headerDivider"
    visible: row.kind === "header" && row.entry.divider === true
    x: FoamyStyle.gapLarge
    y: FoamyStyle.gap
    width: parent.width - FoamyStyle.gapLarge * 2
    height: 1
    color: FoamyPalette.divider
  }
  Item {
    id: headerRow
    objectName: "header"
    visible: row.kind === "header"
    // Starts where a task row's ring does (the surface inset plus its
    // padding); the count ends where a row's time does.
    anchors.left: parent.left
    anchors.leftMargin: row.contentInset
    anchors.right: parent.right
    anchors.rightMargin: row.contentInset
    anchors.bottom: parent.bottom
    anchors.bottomMargin: FoamyStyle.gapSmall
    height: headerTitle.implicitHeight
    readonly property bool countAtEnd: headerSub.text !== ""
    Row {
      id: headerLine
      anchors.left: parent.left
      anchors.right: moveAll.visible ? moveAll.left : headerCount.visible ? headerCount.left : parent.right
      anchors.rightMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      spacing: FoamyStyle.gap
      clip: true
      // The title takes what its mark, its count and its sub text leave,
      // and elides there (they show whole).
      readonly property real titleRoom: Math.max(0, width - [headerMark, headerCountInline, headerSub].reduce(function (sum, part) {
        return sum + (part.visible ? part.implicitWidth + spacing : 0)
      }, 0))
      FoamyIcon {
        id: headerMark
        visible: row.kind === "header" && !!row.entry.projectRole
        anchors.verticalCenter: parent.verticalCenter
        width: FoamyStyle.iconSize - 2
        height: width
        name: "hash"
        color: row.roleColor(row.entry ? row.entry.projectRole : "")
      }
      PlainText {
        id: headerTitle
        objectName: "headerTitle"
        width: Math.min(implicitWidth, headerLine.titleRoom)
        text: row.title
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: 1
        font.pixelSize: FoamyStyle.font.bodySmall
        font.weight: Font.DemiBold
        color: row.entry && row.entry.urgent ? FoamyPalette.onSurface(FoamyPalette.error) : row.isGroup ? FoamyPalette.text : FoamyPalette.secondaryText
        HoverHandler {
          id: headerTitleHover
        }
        // Cut: the whole heading on hover.
        Ui.PanelToolTip {
          objectName: "headerTitleTip"
          visible: headerTitleHover.hovered && headerTitle.truncated
          text: row.title
        }
      }
      // The count beside its word; after a date range it stays at the end.
      PlainText {
        id: headerCountInline
        objectName: "headerCountInline"
        visible: !headerRow.countAtEnd && text !== ""
        anchors.baseline: headerTitle.baseline
        text: headerCount.text
        wrapMode: Text.NoWrap
        font.family: FoamyStyle.monoFamily
        font.pixelSize: FoamyStyle.font.caption
        color: headerCount.color
      }
      PlainText {
        id: headerSub
        objectName: "headerSub"
        visible: text !== ""
        text: row.isGroup && row.heading ? row.heading.sub : ""
        wrapMode: Text.NoWrap
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.mutedText
      }
    }
    // Today's Overdue: every task in it to today (each with its Undo).
    FoamyCursorSurface {
      id: moveAll
      objectName: "moveAllToToday"
      visible: row.kind === "header" && row.entry.moveAll === true
      anchors.right: headerCount.visible ? headerCount.left : parent.right
      anchors.rightMargin: headerCount.visible ? FoamyStyle.gap : 0
      anchors.verticalCenter: parent.verticalCenter
      width: moveAllLabel.implicitWidth + FoamyStyle.gap * 2
      height: FoamyStyle.actionSize - 6
      radius: FoamyStyle.radiusSmall
      onClicked: row.moveAllRequested()
      Accessible.role: Accessible.Button
      Accessible.name: moveAllLabel.text
      HoverHandler {
        id: moveAllHover
      }
      Ui.PanelToolTip {
        objectName: "moveAllTip"
        visible: moveAllHover.hovered
        text: FoamyI18n.t("Move to today") + " (T)"
      }
      PlainText {
        id: moveAllLabel
        anchors.centerIn: parent
        text: FoamyI18n.t("Move to today")
        wrapMode: Text.NoWrap
        color: FoamyPalette.onSurface(FoamyPalette.accent)
        font.pixelSize: FoamyStyle.font.caption
        font.weight: Font.DemiBold
      }
    }
    PlainText {
      id: headerCount
      objectName: "headerCount"
      visible: headerRow.countAtEnd
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: row.entry && row.entry.count > 0 ? FoamyI18n.number(row.entry.count) : ""
      wrapMode: Text.NoWrap
      font.family: FoamyStyle.monoFamily
      font.pixelSize: FoamyStyle.font.caption
      // secondaryText: mutedText measures under 4.5:1 on the list (dark theme).
      color: row.entry && row.entry.urgent ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
    }
  }

  // ---- the folded Overdue row (Upcoming) -------------------------------------------
  FoamyCursorSurface {
    id: foldSurface
    visible: row.kind === "fold"
    x: FoamyStyle.gapLarge
    width: parent.width - FoamyStyle.gapLarge * 2
    height: FoamyStyle.rowHeight
    hasCursor: row.hasCursor
    byKeys: row.byKeys
    onHovered: row.hovered()
    onClicked: row.foldRequested()
    Accessible.role: Accessible.Button
    Accessible.name: FoamyI18n.tn("%1 overdue", row.entry && row.entry.count ? row.entry.count : 0)
    Row {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.rowPadding
      spacing: FoamyStyle.gap
      FoamyIcon {
        anchors.verticalCenter: parent.verticalCenter
        width: FoamyStyle.iconSize
        height: width
        name: row.entry && row.entry.open ? "chevron-down" : "chevron-right"
        color: FoamyPalette.secondaryText
      }
      PlainText {
        anchors.verticalCenter: parent.verticalCenter
        text: FoamyI18n.t("Overdue")
        wrapMode: Text.NoWrap
        font.weight: Font.DemiBold
        color: FoamyPalette.onSurface(FoamyPalette.error)
      }
      PlainText {
        anchors.verticalCenter: parent.verticalCenter
        text: row.entry && row.entry.count ? FoamyI18n.number(row.entry.count) : ""
        wrapMode: Text.NoWrap
        font.family: FoamyStyle.monoFamily
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.onSurface(FoamyPalette.error)
      }
    }
  }

  // ---- a task ---------------------------------------------------------------------
  FoamyCursorSurface {
    id: taskSurface
    objectName: "taskSurface"
    visible: row.isTask
    // Anchored, not placed by x, so RTL mirrors it (the indent on the right).
    anchors.left: parent.left
    anchors.leftMargin: FoamyStyle.gapLarge + row.indent
    anchors.right: parent.right
    anchors.rightMargin: FoamyStyle.gapLarge
    height: parent.height
    hasCursor: row.hasCursor
    byKeys: row.byKeys
    current: row.isTask && row.selected
    // Its details are in the pane: the bar marks it.
    currentBar: true
    cursorShape: Qt.PointingHandCursor
    onHovered: row.hovered()
    onClicked: row.openRequested()
    Accessible.role: Accessible.ListItem
    Accessible.name: row.isTask ? row.entry.text : ""

    // Unconfirmed: a plain ring (it can't be completed until Todoist says).
    // Completed without a priority: the secondary tone, as no ink reads
    // 4.5:1 on a muted fill.
    readonly property color ringColor: !row.isTask || row.unconfirmed ? FoamyPalette.mutedText : row.struck && row.entry.priorityRole === "muted" ? FoamyPalette.secondaryText : row.roleColor(row.entry.priorityRole)
    readonly property var ringLook: row.unconfirmed ? ({
        border: 1,
        fill: 0
      }) : Model.ringLook(row.isTask ? row.entry.priority : 0)
    // The check on the completed ring: the ink that reads on its fill.
    readonly property color checkInk: {
      const fill = Qt.tint(FoamyPalette.background, Qt.alpha(ringColor, Model.RING_DONE))
      return FoamyPalette.contrastRatio(FoamyPalette.text, fill) >= FoamyPalette.contrastRatio(FoamyPalette.background, fill) ? FoamyPalette.text : FoamyPalette.background
    }
    readonly property bool ringLit: ringArea.containsMouse && !row.unconfirmed
    // The ring completes; it is a larger target than it looks.
    MouseArea {
      id: ringArea
      objectName: "ring"
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.rowPadding - FoamyStyle.gapSmall
      width: FoamyStyle.iconSize + 1 + FoamyStyle.gap
      height: parent.height
      cursorShape: Qt.PointingHandCursor
      hoverEnabled: true
      onEntered: row.hovered()
      onClicked: row.completeRequested()
      Accessible.role: Accessible.CheckBox
      Accessible.checked: row.struck
      Accessible.name: FoamyI18n.t("Complete")
      Rectangle {
        id: ring
        objectName: "ringMark"
        anchors.left: parent.left
        anchors.leftMargin: FoamyStyle.gapSmall
        // On the title's line (the text block is centred in the row).
        y: textColumn.y + (titleLine.height - height) / 2
        width: 16
        height: 16
        radius: 8
        border.width: taskSurface.ringLook.border
        border.color: taskSurface.ringColor
        opacity: row.moved ? FoamyStyle.disabledOpacity : 1
        color: Qt.alpha(taskSurface.ringColor, row.struck ? Model.RING_DONE : taskSurface.ringLook.fill + (taskSurface.ringLit ? Model.RING_HOVER : 0))
        FoamyIcon {
          objectName: "ringCheck"
          visible: row.struck || taskSurface.ringLit
          anchors.centerIn: parent
          width: 11
          height: 11
          name: "check"
          color: row.struck ? taskSurface.checkInk : taskSurface.ringColor
        }
      }
    }
    Column {
      id: textColumn
      anchors.left: ringArea.right
      anchors.leftMargin: FoamyStyle.gapSmall
      anchors.right: trailing.left
      anchors.rightMargin: FoamyStyle.gap
      // One line or two, the same space above and below (the list sizes
      // the row: rowHeight, or a little more with a detail line).
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      PlainText {
        id: titleLine
        objectName: "taskText"
        visible: !row.matched
        width: parent.width
        text: row.isTask ? row.entry.text : ""
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: 1
        font.strikeout: row.struck
        color: row.struck || row.moved ? FoamyPalette.mutedText : row.unconfirmed ? FoamyPalette.secondaryText : FoamyPalette.text
      }
      // The same title in runs, the matched parts DemiBold; the run that
      // reaches the line's end is cut there.
      Row {
        id: matchLine
        objectName: "taskTextRuns"
        visible: row.matched
        width: parent.width
        Repeater {
          model: row.matched ? row.titleRuns : []
          PlainText {
            required property var modelData
            width: Math.min(implicitWidth, Math.max(0, matchLine.width - x))
            text: modelData.text
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            maximumLineCount: 1
            font.weight: modelData.bold ? Font.DemiBold : Font.Normal
            font.strikeout: row.struck
            color: row.struck ? FoamyPalette.mutedText : row.unconfirmed ? FoamyPalette.secondaryText : FoamyPalette.text
          }
        }
      }
      Row {
        id: detail
        objectName: "taskDetail"
        // The model says whether there is a line (never the children's
        // visibility, which follows this one: a reused row would keep it hidden).
        visible: row.isTask && row.entry.detail === true
        width: parent.width
        spacing: FoamyStyle.gap
        clip: true
        opacity: row.struck ? FoamyStyle.disabledOpacity : 1
        // What is left for the project and the labels (which elide, in that
        // order of claim) after the parts that show whole: the date, the
        // deadline, the assignee and the repeat mark, each with its gap.
        readonly property real room: Math.max(0, width - [dateBox, deadlineBox, assigneeLabel, repeatIcon].reduce(function (sum, part) {
          return sum + (part.visible ? part.width + spacing : 0)
        }, 0) - (labelsLabel.visible && projectLabel.visible ? spacing : 0))
        // The date; an overdue one with a warning mark (not only its colour).
        Row {
          id: dateBox
          visible: dateLabel.text !== ""
          spacing: 3
          FoamyIcon {
            objectName: "taskLateMark"
            visible: row.isTask && row.entry.overdue && !row.moved
            anchors.verticalCenter: parent.verticalCenter
            width: FoamyStyle.font.caption
            height: width
            name: "triangle-alert"
            color: dateLabel.color
          }
          PlainText {
            id: dateLabel
            objectName: "taskDate"
            // A moved row: its new day, and while Undo has the time's place
            // the time it keeps.
            text: row.moved ? (row.dateText === "" ? FoamyI18n.t("No date") : row.undoable && row.entry.dueTime !== "" ? row.dateText + " " + row.entry.dueTime : row.dateText) : row.isTask ? row.dateText : ""
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.caption
            font.weight: row.moved ? Font.DemiBold : Font.Normal
            color: row.moved ? FoamyPalette.onSurface(FoamyPalette.accent) : row.isTask && row.entry.overdue ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
          }
        }
        // The deadline: its day after the target mark, red once it is due.
        Row {
          id: deadlineBox
          objectName: "taskDeadline"
          visible: row.deadlineText !== ""
          spacing: 3
          FoamyIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: FoamyStyle.font.caption
            height: width
            name: "target"
            color: deadlineLabel.color
          }
          PlainText {
            id: deadlineLabel
            objectName: "taskDeadlineText"
            text: row.deadlineText
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.caption
            color: row.isTask && row.entry.deadlineLate ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
          }
        }
        Row {
          id: projectLabel
          visible: row.isTask && row.entry.showProject
          spacing: 2
          FoamyIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: FoamyStyle.font.caption
            height: width
            name: "hash"
            color: FoamyPalette.mutedText
          }
          PlainText {
            objectName: "taskProject"
            text: row.isTask ? row.entry.projectName : ""
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: Math.min(implicitWidth, detail.width * 0.5, detail.room)
            font.pixelSize: FoamyStyle.font.caption
            color: FoamyPalette.secondaryText
          }
        }
        PlainText {
          id: labelsLabel
          objectName: "taskLabels"
          visible: text !== ""
          text: row.isTask ? row.entry.labels.map(function (label) {
            return "@" + label
          }).join(" ") : ""
          wrapMode: Text.NoWrap
          elide: Text.ElideRight
          width: Math.min(implicitWidth, Math.max(0, detail.room - (projectLabel.visible ? projectLabel.width + detail.spacing : 0)))
          font.pixelSize: FoamyStyle.font.caption
          color: FoamyPalette.onSurface(FoamyPalette.info)
        }
        // Assigned to someone else: the person icon and their first name.
        Row {
          id: assigneeLabel
          visible: row.isTask && row.entry.assignee !== undefined && row.entry.assignee !== ""
          spacing: 2
          FoamyIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: FoamyStyle.font.caption
            height: width
            name: "user"
            color: FoamyPalette.secondaryText
          }
          PlainText {
            objectName: "taskAssignee"
            text: row.isTask && row.entry.assignee ? row.entry.assignee : ""
            wrapMode: Text.NoWrap
            font.pixelSize: FoamyStyle.font.caption
            color: FoamyPalette.secondaryText
          }
        }
        FoamyIcon {
          id: repeatIcon
          objectName: "taskRepeat"
          visible: row.isTask && row.entry.recurring
          anchors.verticalCenter: parent.verticalCenter
          width: FoamyStyle.font.caption
          height: width
          name: "repeat"
          color: FoamyPalette.secondaryText
        }
      }
    }
    Item {
      id: trailing
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.rowPadding
      // The time (or Undo, or the actions) on the title's line, as the ring.
      y: textColumn.y + (titleLine.height - height) / 2
      width: row.undoable ? undoButton.width : row.showActions ? actionsRow.implicitWidth : trailingRow.implicitWidth
      height: FoamyStyle.font.body * 1.35
      // Upcoming's later groups: the day (body font) before the time (mono).
      Row {
        id: trailingRow
        visible: !row.undoable && !row.showActions
        anchors.verticalCenter: parent.verticalCenter
        spacing: FoamyStyle.gap
        // Its completion was sent, the outcome unknown until the next sync.
        FoamyIcon {
          objectName: "taskChecking"
          visible: row.unconfirmed
          anchors.verticalCenter: parent.verticalCenter
          width: FoamyStyle.font.bodySmall
          height: width
          name: "refresh-cw"
          color: FoamyPalette.secondaryText
          HoverHandler {
            id: checkingHover
          }
          Ui.PanelToolTip {
            objectName: "taskCheckingTip"
            visible: checkingHover.hovered
            text: FoamyI18n.t("Checking with Todoist…")
          }
        }
        PlainText {
          objectName: "taskTrailDay"
          visible: text !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: row.isTask ? row.trailDay : ""
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.bodySmall
          color: FoamyPalette.secondaryText
        }
        PlainText {
          id: timeLabel
          objectName: "taskTime"
          visible: text !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: row.isTask ? row.entry.dueTime : ""
          wrapMode: Text.NoWrap
          font.family: FoamyStyle.monoFamily
          font.pixelSize: FoamyStyle.font.bodySmall
          // Today: a passed time in the error tone, the next one bright.
          color: row.isTask && (row.entry.overdue || row.timeTone === "late") ? FoamyPalette.onSurface(FoamyPalette.error) : row.timeTone === "next" ? FoamyPalette.text : FoamyPalette.secondaryText
        }
      }
      // The cursor row: Tomorrow (t) and the menu of days (d).
      Row {
        id: actionsRow
        objectName: "rowActions"
        visible: row.showActions && !row.undoable
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        FoamyAction {
          objectName: "tomorrowAction"
          iconName: "sun"
          foreground: FoamyPalette.secondaryText
          tooltipText: FoamyI18n.t("Tomorrow") + (row.keysHere ? " (t)" : "")
          onHoveredChanged: if (hovered)
            row.hovered()
          onClicked: row.tomorrowRequested()
        }
        FoamyAction {
          id: dateAction
          objectName: "dateAction"
          iconName: "calendar"
          foreground: FoamyPalette.secondaryText
          tooltipText: FoamyI18n.t("Date") + (row.keysHere ? " (d)" : "")
          onHoveredChanged: if (hovered)
            row.hovered()
          onClicked: row.dateMenuRequested()
        }
      }
      FoamyCursorSurface {
        id: undoButton
        objectName: "undo"
        visible: row.undoable
        anchors.verticalCenter: parent.verticalCenter
        width: undoLabel.implicitWidth + FoamyStyle.gap * 2
        height: FoamyStyle.actionSize - 6
        radius: FoamyStyle.radiusSmall
        onHovered: row.hovered()
        onClicked: row.undoRequested()
        Accessible.role: Accessible.Button
        Accessible.name: FoamyI18n.t("Undo")
        PlainText {
          id: undoLabel
          anchors.centerIn: parent
          text: FoamyI18n.t("Undo")
          wrapMode: Text.NoWrap
          color: FoamyPalette.onSurface(FoamyPalette.accent)
          font.pixelSize: FoamyStyle.font.bodySmall
          font.weight: Font.DemiBold
        }
      }
    }
  }
}
