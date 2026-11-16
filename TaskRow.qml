import QtQuick
import "kit"

// One row of the list (Model.rows): a task, a section or day header, or
// Upcoming's folded Overdue row. A task row: the priority ring (complete),
// the content, a detail line (date, project, labels, recurring) and the
// due time on the trailing end, or Undo while the completion can be undone.
Item {
  id: row
  required property var entry
  property bool hasCursor: false
  property bool interactive: true
  readonly property string kind: entry ? entry.kind : ""
  readonly property bool isTask: kind === "task"
  readonly property bool struck: isTask && entry.struck === true
  signal hovered
  signal completeRequested
  signal openRequested
  signal foldRequested

  // The list sets the height (TodoView.heightOf), so it can size itself
  // without building every row.
  // Where row content (the ring, a header's title) starts: the surface's
  // inset plus its padding.
  readonly property real contentInset: FoamyStyle.gapLarge + FoamyStyle.rowPadding
  readonly property real indent: isTask ? entry.depth * (FoamyStyle.iconSize + FoamyStyle.gapLarge) : 0

  function roleColor(role) {
    switch (role) {
    case "error":
      return FoamyPalette.error
    case "warning":
      return FoamyPalette.warning
    case "success":
      return FoamyPalette.success
    case "info":
      return FoamyPalette.info
    case "accent":
      return FoamyPalette.accent
    default:
      return FoamyPalette.mutedText
    }
  }
  // The date on the detail line (Model.detailDate, from the list).
  property string dateText: ""
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
    Row {
      anchors.left: parent.left
      anchors.right: headerCount.left
      anchors.rightMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      spacing: FoamyStyle.gap
      clip: true
      FoamyIcon {
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
        text: row.title
        wrapMode: Text.NoWrap
        font.pixelSize: FoamyStyle.font.bodySmall
        font.weight: Font.DemiBold
        color: row.entry && row.entry.urgent ? FoamyPalette.onSurface(FoamyPalette.error) : row.isGroup ? FoamyPalette.text : FoamyPalette.secondaryText
      }
      PlainText {
        objectName: "headerSub"
        visible: text !== ""
        text: row.isGroup && row.heading ? row.heading.sub : ""
        wrapMode: Text.NoWrap
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.mutedText
      }
    }
    PlainText {
      id: headerCount
      objectName: "headerCount"
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: row.entry && row.entry.count > 0 ? FoamyI18n.number(row.entry.count) : ""
      wrapMode: Text.NoWrap
      font.family: FoamyStyle.monoFamily
      font.pixelSize: FoamyStyle.font.caption
      color: row.entry && row.entry.urgent ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.mutedText
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
    onHovered: row.hovered()
    onClicked: row.foldRequested()
    Accessible.role: Accessible.Button
    Accessible.name: FoamyI18n.tn("%1 overdue", row.entry && row.entry.count ? row.entry.count : 0)
    Row {
      anchors.verticalCenter: parent.verticalCenter
      x: FoamyStyle.rowPadding
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
    // Dimmed while its completion's outcome is unknown (it can't be acted on).
    opacity: row.isTask && row.entry.unconfirmed ? FoamyStyle.disabledOpacity : 1
    x: FoamyStyle.gapLarge + row.indent
    width: parent.width - FoamyStyle.gapLarge * 2 - row.indent
    height: parent.height
    hasCursor: row.hasCursor
    cursorShape: Qt.PointingHandCursor
    onHovered: row.hovered()
    onClicked: row.openRequested()
    Accessible.role: Accessible.ListItem
    Accessible.name: row.isTask ? row.entry.text : ""

    readonly property color ringColor: row.isTask ? row.roleColor(row.entry.priorityRole) : FoamyPalette.mutedText
    // The ring completes; it is a larger target than it looks.
    MouseArea {
      id: ringArea
      objectName: "ring"
      x: FoamyStyle.rowPadding - FoamyStyle.gapSmall
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
        x: FoamyStyle.gapSmall
        // Centred on the text block, which is centred in the row.
        y: (parent.height - height) / 2
        width: 16
        height: 16
        radius: 8
        border.width: 1.5
        border.color: taskSurface.ringColor
        color: Qt.alpha(taskSurface.ringColor, row.struck ? 0.9 : ringArea.containsMouse ? 0.28 : 0.12)
        FoamyIcon {
          visible: row.struck || ringArea.containsMouse
          anchors.centerIn: parent
          width: 11
          height: 11
          name: "check"
          color: row.struck ? FoamyPalette.onSurface(FoamyPalette.background) : taskSurface.ringColor
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
        objectName: "taskText"
        width: parent.width
        text: row.isTask ? row.entry.text : ""
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: 1
        font.strikeout: row.struck
        color: row.struck ? FoamyPalette.mutedText : FoamyPalette.text
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
        PlainText {
          id: dateLabel
          objectName: "taskDate"
          visible: text !== ""
          text: row.isTask ? row.dateText : ""
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.caption
          color: row.isTask && row.entry.overdue ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
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
            color: row.isTask ? row.roleColor(row.entry.projectRole) : FoamyPalette.mutedText
          }
          PlainText {
            objectName: "taskProject"
            text: row.isTask ? row.entry.projectName : ""
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            width: Math.min(implicitWidth, detail.width * 0.5)
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
          width: Math.min(implicitWidth, Math.max(0, detail.width - dateLabel.width - projectLabel.width - assigneeLabel.width - FoamyStyle.gap * 4 - FoamyStyle.font.caption))
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
      // The time (or Undo) centres on the text block, as the ring does.
      anchors.verticalCenter: parent.verticalCenter
      width: row.struck ? undoButton.width : trailingRow.implicitWidth
      height: FoamyStyle.font.body * 1.35
      // Upcoming's later groups: the day (body font) before the time (mono).
      Row {
        id: trailingRow
        visible: !row.struck
        anchors.verticalCenter: parent.verticalCenter
        spacing: FoamyStyle.gap
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
          color: row.isTask && row.entry.overdue ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
        }
      }
      FoamyCursorSurface {
        id: undoButton
        objectName: "undo"
        visible: row.struck
        anchors.verticalCenter: parent.verticalCenter
        width: undoLabel.implicitWidth + FoamyStyle.gap * 2
        height: FoamyStyle.actionSize - 6
        radius: FoamyStyle.radiusSmall
        onHovered: row.hovered()
        onClicked: row.completeRequested()
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
