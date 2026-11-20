pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons as Commons
import "kit"
import "Model.js" as Model

// Wide's details pane while no task is selected: a summary of the current
// view (Model.overview, `summary`), in the editor's look (captioned parts,
// no help text). Today: the date, what is left and overdue, the next timed
// task and the day's timeline. A project, the Inbox and search: the
// sections and sub-projects (a project), when the tasks are due, the
// labels. Upcoming: the next seven days, the next deadline, the tasks
// without a date. A part with nothing to show is left out.
//
// Every clickable part is one click target and one Tab stop with one hover
// fill, as the editor's sections: Enter or Space does what a click does.
// TodoView acts on the signals (select a task, scroll the list, open a
// project, search a label). Esc gives the keys back to the list
// (`keysReturned`).
FocusScope {
  id: overview
  // Model.overview's result for the view (null: nothing to show).
  property var summary: null
  property string today: ""
  // Upcoming: the day the list's add goes to (lit among the seven).
  property string litDay: ""
  // The locale's date formatting and the catalog (TodoView's).
  property var format: null
  property var translate: null
  signal taskPicked(string id)
  signal sectionPicked(string id)
  signal projectPicked(string id)
  signal labelPicked(string name)
  signal dayPicked(string day)
  signal keysReturned

  readonly property string kind: summary ? summary.kind : ""
  readonly property alias scroll: scroll
  implicitHeight: parts.implicitHeight + FoamyStyle.gap * 2

  function roleColor(role) {
    return role === "error" ? FoamyPalette.error : role === "warning" ? FoamyPalette.warning : role === "success" ? FoamyPalette.success : role === "info" ? FoamyPalette.info : role === "accent" ? FoamyPalette.accent : FoamyPalette.mutedText
  }
  // The first click target, with the keys (Tab from the list); false when
  // there is none.
  function focusFirst() {
    var first = parts.nextItemInFocusChain(true)
    for (let at = first; at && at !== overview; at = at.parent)
      if (at === parts) {
        first.forceActiveFocus(Qt.TabFocusReason)
        scroll.contentY = 0
        return true
      }
    return false
  }
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) {
      event.accepted = true
      overview.keysReturned()
    }
  }
  // Focus follow, as the editor: the least scroll that shows the focused part.
  Connections {
    target: overview.Window
    function onActiveFocusItemChanged() {
      var item = overview.Window.activeFocusItem
      for (let at = item; at; at = at.parent)
        if (at === parts) {
          const y = item.mapToItem(scroll.contentItem, 0, 0).y
          if (y < scroll.contentY)
            scroll.contentY = Math.max(0, y - FoamyStyle.gap)
          else if (y + item.height > scroll.contentY + scroll.height)
            scroll.contentY = Math.min(scroll.contentHeight - scroll.height, y + item.height - scroll.height + FoamyStyle.gap)
          return
        }
    }
  }

  FoamyWheelScroll {
    target: scroll
  }
  Flickable {
    id: scroll
    objectName: "overviewScroll"
    anchors.fill: parent
    contentWidth: width
    contentHeight: parts.implicitHeight + FoamyStyle.gap * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      policy: Controls.ScrollBar.AsNeeded
    }

    ColumnLayout {
      id: parts
      // The editor's insets: the list's top margin above, so the first
      // part lines up with the list's first row.
      x: FoamyStyle.padding - FoamyStyle.gapSmall
      y: FoamyStyle.gap
      width: scroll.width - x * 2
      spacing: FoamyStyle.sectionGap

      // ---- Today ----
      Caption {
        objectName: "overviewDate"
        visible: overview.kind === "today"
        text: overview.kind === "today" && overview.format ? Model.capitalized(overview.format(Model.dayDate(overview.today), "dddd")) + " " + overview.format(Model.dayDate(overview.today), overview.translate("d MMMM")) : ""
      }
      RowLayout {
        objectName: "overviewFigures"
        visible: overview.kind === "today"
        Layout.leftMargin: FoamyStyle.gap
        spacing: FoamyStyle.padding
        Figure {
          objectName: "figureLeft"
          value: overview.kind === "today" ? overview.summary.left : 0
          label: FoamyI18n.t("left today")
        }
        Figure {
          objectName: "figureOverdue"
          value: overview.kind === "today" ? overview.summary.overdue : 0
          label: FoamyI18n.t("overdue")
          tone: FoamyPalette.onSurface(FoamyPalette.error)
        }
      }
      Part {
        objectName: "overviewNext"
        visible: overview.kind === "today" && overview.summary.next !== null
        caption: FoamyI18n.t("Next")
        TaskTarget {
          objectName: "nextTask"
          readonly property var next: overview.kind === "today" ? overview.summary.next : null
          iconName: "clock"
          text: next ? next.text : ""
          detail: next ? next.time + " · " + Model.aheadText(next.inMinutes, overview.translate) : ""
          onActivated: overview.taskPicked(next.id)
        }
      }
      Part {
        objectName: "overviewTimes"
        visible: overview.kind === "today" && overview.summary.blocks.length > 0
        caption: FoamyI18n.t("Today's times")
        Timeline {
          Layout.fillWidth: true
          // The first hour's label is centred on its line: room for its top half.
          Layout.topMargin: FoamyStyle.font.caption / 2 + FoamyStyle.gapSmall
          summary: overview.kind === "today" ? overview.summary : null
        }
      }
      PlainText {
        objectName: "overviewUntimed"
        visible: overview.kind === "today" && overview.summary.untimed > 0
        Layout.fillWidth: true
        Layout.leftMargin: FoamyStyle.gap
        Layout.topMargin: visible && overview.summary.blocks.length > 0 ? -FoamyStyle.gap : 0
        text: overview.kind === "today" ? FoamyI18n.tn("%1 tasks without a time", overview.summary.untimed) : ""
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.mutedText
      }

      // ---- a project, the Inbox, search ----
      Part {
        objectName: "overviewSections"
        visible: overview.kind === "list" && overview.summary.sections.length > 0
        caption: FoamyI18n.t("Sections")
        spacing: 0
        Repeater {
          model: overview.kind === "list" ? overview.summary.sections : []
          Target {
            id: sectionRow
            required property var modelData
            objectName: (modelData.kind === "project" ? "subproject-" : "section-") + (modelData.id || "none")
            Layout.fillWidth: true
            implicitHeight: FoamyStyle.rowHeight - 6
            Accessible.name: sectionName.text
            onActivated: modelData.kind === "project" ? overview.projectPicked(modelData.id) : overview.sectionPicked(modelData.id)
            FoamyIcon {
              id: sectionIcon
              visible: sectionRow.modelData.kind === "project"
              anchors.left: parent.left
              anchors.leftMargin: FoamyStyle.gap
              anchors.verticalCenter: parent.verticalCenter
              width: visible ? FoamyStyle.iconSize : 0
              height: FoamyStyle.iconSize
              name: "hash"
              color: overview.roleColor(sectionRow.modelData.role)
            }
            PlainText {
              id: sectionName
              anchors.left: sectionIcon.right
              anchors.leftMargin: sectionIcon.visible ? FoamyStyle.gap : 0
              anchors.right: sectionCount.left
              anchors.rightMargin: FoamyStyle.gap
              anchors.verticalCenter: parent.verticalCenter
              text: sectionRow.modelData.kind === "section" && sectionRow.modelData.id === "" ? FoamyI18n.t("(No section)") : sectionRow.modelData.name
              wrapMode: Text.NoWrap
              elide: Text.ElideRight
              font.pixelSize: FoamyStyle.font.bodySmall
            }
            PlainText {
              id: sectionCount
              anchors.right: parent.right
              anchors.rightMargin: FoamyStyle.gap
              anchors.verticalCenter: parent.verticalCenter
              text: FoamyI18n.number(sectionRow.modelData.count)
              wrapMode: Text.NoWrap
              font.family: FoamyStyle.monoFamily
              font.pixelSize: FoamyStyle.font.caption
              color: FoamyPalette.mutedText
            }
          }
        }
      }
      Part {
        objectName: "overviewWhen"
        visible: overview.kind === "list"
        caption: FoamyI18n.t("When")
        // One bar, a part per group with tasks (an empty track for none).
        Item {
          id: whenBar
          objectName: "whenBar"
          readonly property var parts: overview.kind === "list" ? overview.summary.when : []
          readonly property int total: overview.kind === "list" ? overview.summary.total : 0
          Layout.fillWidth: true
          Layout.leftMargin: FoamyStyle.gap
          Layout.rightMargin: FoamyStyle.gap
          Layout.topMargin: FoamyStyle.gapSmall
          implicitHeight: FoamyStyle.gap
          Rectangle {
            visible: whenBar.total === 0
            anchors.fill: parent
            radius: height / 2
            color: FoamyPalette.fieldFill
          }
          Row {
            anchors.fill: parent
            spacing: FoamyStyle.gapTiny
            Repeater {
              model: whenBar.parts
              Rectangle {
                required property var modelData
                objectName: "when-" + modelData.key
                width: (whenBar.width - FoamyStyle.gapTiny * (whenBar.parts.length - 1)) * modelData.count / whenBar.total
                height: parent.height
                radius: FoamyStyle.gapTiny
                color: whenColors.of(modelData.key)
              }
            }
          }
        }
        Flow {
          objectName: "whenLegend"
          Layout.fillWidth: true
          Layout.leftMargin: FoamyStyle.gap
          Layout.rightMargin: FoamyStyle.gap
          spacing: FoamyStyle.gapLarge
          Repeater {
            model: whenBar.total > 0 ? whenBar.parts : [
              {
                key: "empty",
                count: 0
              }
            ]
            Row {
              id: legendEntry
              required property var modelData
              readonly property string label: whenColors.label(modelData.key, modelData.count)
              spacing: FoamyStyle.gapSmall
              Rectangle {
                visible: legendEntry.modelData.key !== "empty"
                anchors.verticalCenter: parent.verticalCenter
                width: FoamyStyle.gap
                height: width
                radius: FoamyStyle.gapTiny
                color: whenColors.of(legendEntry.modelData.key)
              }
              PlainText {
                text: legendEntry.label
                wrapMode: Text.NoWrap
                font.pixelSize: FoamyStyle.font.caption
                color: FoamyPalette.secondaryText
              }
            }
          }
        }
      }
      Part {
        objectName: "overviewLabels"
        visible: overview.kind === "list" && overview.summary.labels.length > 0
        caption: FoamyI18n.t("Labels")
        Flow {
          Layout.fillWidth: true
          Layout.leftMargin: FoamyStyle.gap
          Layout.rightMargin: FoamyStyle.gap
          spacing: FoamyStyle.gapSmall
          Repeater {
            model: overview.kind === "list" ? overview.summary.labels : []
            // The editor's label chip, a click target here.
            Target {
              id: chip
              required property var modelData
              objectName: "labelChip-" + modelData.name
              width: chipRow.implicitWidth + FoamyStyle.gap * 2
              height: FoamyStyle.controlHeight - FoamyStyle.gapSmall
              radius: FoamyStyle.radiusSmall
              rest: FoamyPalette.fieldFill
              border.width: FoamyStyle.borderWidth
              border.color: activeFocus ? Commons.Color.accent : FoamyPalette.border
              Accessible.name: "@" + modelData.name
              onActivated: overview.labelPicked(modelData.name)
              Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: FoamyStyle.gapSmall
                PlainText {
                  text: "@" + chip.modelData.name
                  wrapMode: Text.NoWrap
                  font.pixelSize: FoamyStyle.font.bodySmall
                  color: FoamyPalette.onSurface(FoamyPalette.info)
                }
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: FoamyI18n.number(chip.modelData.count)
                  wrapMode: Text.NoWrap
                  font.family: FoamyStyle.monoFamily
                  font.pixelSize: FoamyStyle.font.caption
                  color: FoamyPalette.mutedText
                }
              }
            }
          }
        }
      }

      // ---- Upcoming ----
      Part {
        objectName: "overviewDays"
        visible: overview.kind === "upcoming"
        caption: FoamyI18n.t("Next 7 days")
        RowLayout {
          id: days
          readonly property var list: overview.kind === "upcoming" ? overview.summary.days : []
          readonly property int most: list.reduce(function (top, day) {
            return Math.max(top, day.count)
          }, 0)
          // The tallest bar; a day without tasks keeps a sliver.
          readonly property real barHeight: FoamyStyle.rowHeight * 1.5
          Layout.fillWidth: true
          spacing: FoamyStyle.gapTiny
          Repeater {
            model: days.list
            Target {
              id: dayColumn
              required property var modelData
              readonly property bool lit: modelData.day === overview.litDay
              objectName: "day-" + modelData.day
              Layout.fillWidth: true
              implicitHeight: dayStack.implicitHeight + FoamyStyle.gap * 2
              current: lit
              Accessible.name: dayLabel.text + ", " + FoamyI18n.number(modelData.count)
              onActivated: overview.dayPicked(modelData.day)
              Column {
                id: dayStack
                anchors.bottom: parent.bottom
                anchors.bottomMargin: FoamyStyle.gap
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: FoamyStyle.gapSmall
                PlainText {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: FoamyI18n.number(dayColumn.modelData.count)
                  wrapMode: Text.NoWrap
                  font.family: FoamyStyle.monoFamily
                  font.pixelSize: FoamyStyle.font.caption
                }
                // The bars stand on one line: each column's stack is as
                // tall as the tallest bar.
                Item {
                  width: FoamyStyle.iconSize
                  height: days.barHeight
                  Rectangle {
                    objectName: "dayBar"
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: days.most > 0 ? Math.max(FoamyStyle.gapTiny, days.barHeight * dayColumn.modelData.count / days.most) : FoamyStyle.gapTiny
                    radius: FoamyStyle.gapSmall
                    color: dayColumn.lit ? FoamyPalette.accent : Qt.alpha(FoamyPalette.accent, 0.4)
                  }
                }
                PlainText {
                  id: dayLabel
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: overview.format ? overview.format(Model.dayDate(dayColumn.modelData.day), "ddd") : ""
                  wrapMode: Text.NoWrap
                  font.pixelSize: FoamyStyle.font.caption
                  font.weight: dayColumn.lit ? Font.DemiBold : Font.Normal
                  color: dayColumn.lit ? FoamyPalette.text : FoamyPalette.secondaryText
                }
              }
            }
          }
        }
      }
      Part {
        objectName: "overviewDeadline"
        visible: overview.kind === "upcoming" && overview.summary.deadline !== null
        caption: FoamyI18n.t("Next deadline")
        TaskTarget {
          objectName: "deadlineTask"
          readonly property var deadline: overview.kind === "upcoming" ? overview.summary.deadline : null
          iconName: "target"
          text: deadline ? deadline.text : ""
          detail: deadline && overview.format ? Model.dayWords(deadline.day, overview.format, overview.translate, overview.today) + (deadline.inDays > 0 ? " · " + FoamyI18n.tn("in %1 days", deadline.inDays) : "") : ""
          onActivated: overview.taskPicked(deadline.id)
        }
      }
      PlainText {
        objectName: "overviewUndated"
        visible: overview.kind === "upcoming" && overview.summary.undated > 0
        Layout.fillWidth: true
        Layout.leftMargin: FoamyStyle.gap
        text: overview.kind === "upcoming" ? FoamyI18n.tn("%1 tasks have no date and don't show here", overview.summary.undated) : ""
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.mutedText
      }
    }
  }

  QtObject {
    id: whenColors
    function of(key) {
      return key === "overdue" ? FoamyPalette.error : key === "today" ? FoamyPalette.success : key === "week" ? FoamyPalette.accent : key === "later" ? FoamyPalette.info : FoamyPalette.mutedText
    }
    function label(key, count) {
      switch (key) {
      case "overdue":
        return FoamyI18n.tn("%1 overdue", count)
      case "today":
        return FoamyI18n.tn("%1 today", count)
      case "week":
        return FoamyI18n.tn("%1 this week", count)
      case "later":
        return FoamyI18n.tn("%1 later", count)
      case "none":
        return FoamyI18n.tn("%1 without a date", count)
      default:
        return FoamyI18n.tn("%1 tasks", count)
      }
    }
  }

  // A part's caption, as the editor's section captions.
  component Caption: PlainText {
    Layout.fillWidth: true
    Layout.leftMargin: FoamyStyle.gap
    wrapMode: Text.NoWrap
    elide: Text.ElideRight
    font.pixelSize: FoamyStyle.font.bodySmall
    font.weight: Font.DemiBold
    color: FoamyPalette.secondaryText
  }
  // A captioned part: the caption, then what it holds.
  component Part: ColumnLayout {
    id: part
    property string caption: ""
    default property alias content: slot.data
    Layout.fillWidth: true
    spacing: FoamyStyle.gapSmall
    Caption {
      text: part.caption
    }
    ColumnLayout {
      id: slot
      Layout.fillWidth: true
      spacing: part.spacing
    }
  }
  // A big number and what it counts.
  component Figure: Column {
    property int value: 0
    property string label: ""
    property color tone: FoamyPalette.text
    spacing: FoamyStyle.gapTiny
    PlainText {
      text: FoamyI18n.number(parent.value)
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.display
      font.weight: Font.DemiBold
      color: parent.tone
    }
    PlainText {
      text: parent.label
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.caption
      color: FoamyPalette.secondaryText
    }
  }
  // One click target and Tab stop (the editor's section box): the hover
  // fill (the current fill when `current`), the keys' accent ring.
  component Target: Rectangle {
    id: target
    property bool current: false
    property color rest: "transparent"
    readonly property bool lit: hover.hovered || activeFocus
    signal activated
    radius: FoamyStyle.radius
    // A filled target (a block over the hour lines) stays opaque when lit.
    color: current ? FoamyPalette.selectedFill : !lit ? rest : rest.a > 0 ? Qt.tint(rest, FoamyPalette.hoverFill) : FoamyPalette.hoverFill
    border.width: activeFocus ? 1 : 0
    border.color: Commons.Color.accent
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.onPressAction: target.activated()
    Keys.onPressed: function (event) {
      if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        event.accepted = true
        target.activated()
      }
    }
    HoverHandler {
      id: hover
      cursorShape: Qt.PointingHandCursor
    }
    MouseArea {
      anchors.fill: parent
      onClicked: target.activated()
    }
  }
  // A task as a click target: an icon, its text and a detail line.
  component TaskTarget: Target {
    id: taskTarget
    property string iconName: ""
    property string text: ""
    property string detail: ""
    Layout.fillWidth: true
    implicitHeight: taskLines.implicitHeight + FoamyStyle.gap * 2
    rest: FoamyPalette.fieldFill
    Accessible.name: text
    FoamyIcon {
      id: taskIcon
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      width: FoamyStyle.iconSize
      height: width
      name: taskTarget.iconName
      color: FoamyPalette.onSurface(FoamyPalette.accent)
    }
    Column {
      id: taskLines
      anchors.left: taskIcon.right
      anchors.leftMargin: FoamyStyle.gap
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      spacing: FoamyStyle.gapTiny
      PlainText {
        objectName: "targetText"
        width: parent.width
        text: taskTarget.text
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: FoamyStyle.font.bodySmall
      }
      PlainText {
        objectName: "targetDetail"
        width: parent.width
        text: taskTarget.detail
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: FoamyStyle.font.caption
        color: FoamyPalette.secondaryText
      }
    }
  }
  // Today's hours, a line each, the timed tasks as blocks at their time
  // (overlapping ones side by side), and a line at now while it is inside.
  component Timeline: Item {
    id: timeline
    property var summary: null
    readonly property real hourHeight: FoamyStyle.controlHeight * 0.75
    readonly property real labelWidth: FoamyStyle.controlHeight
    readonly property real lanesWidth: width - labelWidth - FoamyStyle.gap
    readonly property int start: summary ? summary.start : 0
    function yOf(minutes) {
      return (minutes - start * 60) / 60 * hourHeight
    }
    objectName: "timeline"
    implicitHeight: summary ? (summary.end - summary.start) * hourHeight + FoamyStyle.gapSmall : 0
    Repeater {
      model: timeline.summary ? timeline.summary.end - timeline.summary.start : 0
      Item {
        id: hourRow
        required property int index
        y: index * timeline.hourHeight
        width: timeline.width
        height: timeline.hourHeight
        PlainText {
          anchors.left: parent.left
          anchors.leftMargin: FoamyStyle.gap
          y: -height / 2
          text: (timeline.start + hourRow.index < 10 ? "0" : "") + (timeline.start + hourRow.index)
          wrapMode: Text.NoWrap
          font.family: FoamyStyle.monoFamily
          font.pixelSize: FoamyStyle.font.caption
          color: FoamyPalette.mutedText
        }
        Rectangle {
          anchors.left: parent.left
          anchors.leftMargin: timeline.labelWidth
          anchors.right: parent.right
          height: 1
          color: FoamyPalette.divider
        }
      }
    }
    Repeater {
      model: timeline.summary ? timeline.summary.blocks : []
      Target {
        id: block
        required property var modelData
        objectName: "block-" + modelData.id
        readonly property real laneWidth: timeline.lanesWidth / modelData.lanes
        // Anchored with a margin, so RTL mirrors the lanes too.
        anchors.left: timeline.left
        anchors.leftMargin: timeline.labelWidth + FoamyStyle.gapSmall + modelData.lane * laneWidth
        y: timeline.yOf(modelData.minutes) + 1
        width: laneWidth - FoamyStyle.gapTiny
        height: modelData.length / 60 * timeline.hourHeight - 2
        radius: FoamyStyle.radiusSmall
        // Opaque, over the hour lines; a past block is faded.
        rest: Qt.tint(FoamyPalette.background, modelData.past ? Qt.alpha(FoamyPalette.accent, 0.08) : FoamyPalette.selectedFill)
        Accessible.name: modelData.time + " " + modelData.text
        onActivated: overview.taskPicked(modelData.id)
        Rectangle {
          anchors.left: parent.left
          width: 3
          height: parent.height
          radius: 1.5
          color: block.modelData.past ? Qt.alpha(FoamyPalette.accent, 0.5) : FoamyPalette.accent
        }
        PlainText {
          anchors.left: parent.left
          anchors.leftMargin: FoamyStyle.gap
          anchors.right: parent.right
          anchors.rightMargin: FoamyStyle.gapSmall
          anchors.verticalCenter: parent.verticalCenter
          text: block.modelData.time + " " + block.modelData.text
          wrapMode: Text.NoWrap
          elide: Text.ElideRight
          font.pixelSize: FoamyStyle.font.caption
          color: block.modelData.past ? FoamyPalette.secondaryText : FoamyPalette.text
          font.strikeout: block.modelData.struck
        }
      }
    }
    Item {
      objectName: "nowLine"
      visible: timeline.summary !== null && timeline.summary.now
      anchors.left: parent.left
      anchors.leftMargin: timeline.labelWidth - FoamyStyle.gapSmall
      anchors.right: parent.right
      y: timeline.summary ? timeline.yOf(timeline.summary.nowMinutes) - 1 : 0
      height: 2
      z: 2
      Rectangle {
        anchors.fill: parent
        color: FoamyPalette.onSurface(FoamyPalette.error)
      }
      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: FoamyStyle.gap
        height: width
        radius: width / 2
        color: FoamyPalette.onSurface(FoamyPalette.error)
      }
    }
  }
}
