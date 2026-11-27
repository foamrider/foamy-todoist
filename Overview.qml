pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons as Commons
import qs.Ui
import "kit"
import "Model.js" as Model

// Wide's details pane while no task is selected: a summary of the current
// view (Model.overview, `summary`), in the editor's look (captioned parts,
// no help text). Today: the date as the title, what is due today and
// overdue (one line; together they are the band's "left"), the next timed
// task, the day's timeline, then the deadlines of the coming week and
// tomorrow's first tasks (the lower parts: they give way first, below). A
// project, the Inbox and search: the
// sections and sub-projects (a project), when the tasks are due, the
// labels. Upcoming: the next seven days, the next deadline, the tasks
// without a date. A part with nothing to show is left out: a zero figure,
// When for an empty list. A Today with nothing left or overdue shows no
// figures.
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
  // Today with nothing left or overdue.
  readonly property bool dayClear: kind === "today" && summary.left === 0 && summary.overdue === 0
  readonly property alias scroll: scroll
  // Today's lower parts (Deadlines, then Tomorrow) show only whole, under
  // the parts above them, without scrolling the pane: on a crowded day they
  // give way, Tomorrow first, and Today's times keeps its room. Their
  // heights come from their rows (fixed), not from the parts, so whether
  // they show never feeds back into what they measure.
  readonly property real briefRowHeight: FoamyStyle.rowHeight - 6
  readonly property var deadlines: kind === "today" ? summary.deadlines : null
  readonly property var tomorrow: kind === "today" ? summary.tomorrow : null
  readonly property int deadlinesMore: deadlines ? deadlines.count - deadlines.tasks.length : 0
  readonly property real deadlinesHeight: deadlines ? captionLine.implicitHeight + deadlines.tasks.length * briefRowHeight + (deadlinesMore > 0 ? moreLine.implicitHeight : 0) : 0
  readonly property real tomorrowHeight: tomorrow ? captionLine.implicitHeight + tomorrow.tasks.length * briefRowHeight : 0
  // The bottom of the parts above (laid out first; the lower parts never
  // move them).
  readonly property real upperBottom: [dateTitle, figures, nextPart, timesPart, untimedLine].reduce(function (bottom, item) {
    return item.visible ? Math.max(bottom, item.y + item.height) : bottom
  }, 0)
  // The pane's height is the scroll's (it fills the pane).
  readonly property real room: height - topInset - FoamyStyle.gap
  readonly property bool deadlinesShown: deadlines !== null && deadlines.count > 0 && upperBottom + FoamyStyle.sectionGap + deadlinesHeight <= room
  readonly property bool tomorrowShown: tomorrow !== null && tomorrow.count > 0 && (deadlinesShown || !deadlines || deadlines.count === 0) && upperBottom + (deadlinesShown ? FoamyStyle.sectionGap + deadlinesHeight : 0) + FoamyStyle.sectionGap + tomorrowHeight <= room
  // The first caption's top: level with the list's first heading, which
  // stands at the bottom of its row less a small gap (TaskRow's header,
  // TodoView.heightOf), below the list's top margin.
  readonly property real topInset: FoamyStyle.gap + FoamyStyle.rowHeight - 6 - FoamyStyle.gapSmall - captionLine.implicitHeight
  implicitHeight: topInset + parts.implicitHeight + FoamyStyle.gap

  function roleColor(role) {
    // Marks and icons on the surface: readable in a light theme too.
    return role === "error" ? FoamyPalette.onSurface(FoamyPalette.error) : role === "warning" ? FoamyPalette.onSurface(FoamyPalette.warning) : role === "success" ? FoamyPalette.onSurface(FoamyPalette.success) : role === "info" ? FoamyPalette.onSurface(FoamyPalette.info) : role === "accent" ? FoamyPalette.onSurface(FoamyPalette.accent) : FoamyPalette.mutedText
  }
  // The first click target, with the keys (Tab from the list); false when
  // there is none. From the top, so the parts above it show when they fit;
  // then revealed (the keys may already be on it: no focus change to follow).
  function focusFirst() {
    var first = parts.nextItemInFocusChain(true)
    for (let at = first; at && at !== overview; at = at.parent)
      if (at === parts) {
        scroll.contentY = 0
        first.forceActiveFocus(Qt.TabFocusReason)
        reveal(first)
        return true
      }
    return false
  }
  // The least scroll that shows `item` (a part).
  function reveal(item) {
    const y = item.mapToItem(scroll.contentItem, 0, 0).y
    if (y < scroll.contentY)
      scroll.contentY = Math.max(0, y - FoamyStyle.gap)
    else if (y + item.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.min(scroll.contentHeight - scroll.height, y + item.height - scroll.height + FoamyStyle.gap)
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
          overview.reveal(item)
          return
        }
    }
  }
  // A caption's line height, for the top inset (not shown).
  Caption {
    id: captionLine
    visible: false
    text: "X"
  }
  // The "+N more" line's height, for the same (not shown).
  MoreLine {
    id: moreLine
    visible: false
    text: "X"
  }

  FoamyWheelScroll {
    target: scroll
  }
  Flickable {
    id: scroll
    objectName: "overviewScroll"
    anchors.fill: parent
    contentWidth: width
    contentHeight: overview.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Controls.ScrollBar.vertical: Controls.ScrollBar {
      policy: Controls.ScrollBar.AsNeeded
    }

    ColumnLayout {
      id: parts
      // The editor's side insets; the first caption level with the list's
      // first heading.
      x: FoamyStyle.padding - FoamyStyle.gapSmall
      y: overview.topInset
      width: scroll.width - x * 2
      spacing: FoamyStyle.sectionGap

      // ---- Today ----
      // The pane's title, as the editor's task title.
      PlainText {
        id: dateTitle
        objectName: "overviewDate"
        visible: overview.kind === "today"
        Layout.fillWidth: true
        Layout.leftMargin: FoamyStyle.gap
        text: overview.kind === "today" && overview.format ? Model.capitalized(overview.format(Model.dayDate(overview.today), "dddd")) + " " + overview.format(Model.dayDate(overview.today), overview.translate("d MMMM")) : ""
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: FoamyStyle.font.title
        font.weight: Font.DemiBold
      }
      // "4 due today · 2 overdue": a zero figure is left out. The numbers
      // larger, every part on the first number's baseline.
      Row {
        id: figures
        objectName: "overviewFigures"
        readonly property int due: overview.kind === "today" ? overview.summary.left : 0
        readonly property int overdue: overview.kind === "today" ? overview.summary.overdue : 0
        visible: overview.kind === "today" && !overview.dayClear
        Layout.leftMargin: FoamyStyle.gap
        Layout.topMargin: -FoamyStyle.gapSmall
        spacing: FoamyStyle.gapSmall
        PlainText {
          id: dueValue
          objectName: "figureDue"
          visible: figures.due > 0
          text: FoamyI18n.number(figures.due)
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
        }
        FigureWords {
          visible: figures.due > 0
          anchors.baseline: dueValue.baseline
          text: FoamyI18n.t("due today")
        }
        FigureWords {
          visible: figures.due > 0 && figures.overdue > 0
          anchors.baseline: dueValue.baseline
          leftPadding: FoamyStyle.gapSmall
          rightPadding: FoamyStyle.gapSmall
          text: "·"
          color: FoamyPalette.mutedText
        }
        PlainText {
          objectName: "figureOverdue"
          visible: figures.overdue > 0
          anchors.baseline: dueValue.baseline
          text: FoamyI18n.number(figures.overdue)
          wrapMode: Text.NoWrap
          font.pixelSize: FoamyStyle.font.heading
          font.weight: Font.DemiBold
          color: FoamyPalette.onSurface(FoamyPalette.error)
        }
        FigureWords {
          visible: figures.overdue > 0
          anchors.baseline: dueValue.baseline
          text: FoamyI18n.t("overdue")
        }
      }
      Part {
        id: nextPart
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
        id: timesPart
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
        id: untimedLine
        objectName: "overviewUntimed"
        visible: overview.kind === "today" && overview.summary.untimed > 0
        Layout.fillWidth: true
        Layout.leftMargin: FoamyStyle.gap
        Layout.topMargin: visible && overview.summary.blocks.length > 0 ? -FoamyStyle.gap : 0
        text: overview.kind === "today" ? FoamyI18n.tn("%1 tasks without a time", overview.summary.untimed) : ""
        font.pixelSize: FoamyStyle.font.bodySmall
        color: FoamyPalette.mutedText
      }
      // Deadlines from today to a week on, nearest first: the day in words
      // at the end, red for today (as a row's deadline).
      Part {
        objectName: "overviewDeadlines"
        visible: overview.deadlinesShown
        caption: FoamyI18n.t("Deadlines")
        spacing: 0
        Repeater {
          model: overview.deadlinesShown ? overview.deadlines.tasks : []
          BriefRow {
            required property var modelData
            objectName: "deadline-" + modelData.id
            iconName: "target"
            text: modelData.text
            trail: modelData.inDays === 0 ? FoamyI18n.t("Today") : modelData.inDays === 1 ? FoamyI18n.t("Tomorrow") : FoamyI18n.tn("in %1 days", modelData.inDays)
            trailColor: modelData.inDays === 0 ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
            iconColor: modelData.inDays === 0 ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.onSurface(FoamyPalette.accent)
            onActivated: overview.taskPicked(modelData.id)
          }
        }
        MoreLine {
          objectName: "deadlinesMore"
          visible: overview.deadlinesMore > 0
          text: FoamyI18n.tn("+%1 more", overview.deadlinesMore)
        }
      }
      // Tomorrow: its count and first two tasks, a time before a timed one.
      Part {
        objectName: "overviewTomorrow"
        visible: overview.tomorrowShown
        caption: overview.tomorrow ? FoamyI18n.tn("Tomorrow · %1 tasks", overview.tomorrow.count) : ""
        spacing: 0
        Repeater {
          model: overview.tomorrowShown ? overview.tomorrow.tasks : []
          BriefRow {
            required property var modelData
            objectName: "tomorrow-" + modelData.id
            lead: modelData.time
            text: modelData.text
            onActivated: overview.taskPicked(modelData.id)
          }
        }
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
        visible: overview.kind === "list" && overview.summary.total > 0
        caption: FoamyI18n.t("When")
        // One bar, a part per group with tasks.
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
            model: whenBar.parts
            Row {
              id: legendEntry
              required property var modelData
              readonly property string label: whenColors.label(modelData.key, modelData.count)
              spacing: FoamyStyle.gapSmall
              Rectangle {
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
          id: labelFlow
          Layout.fillWidth: true
          Layout.leftMargin: FoamyStyle.gap
          Layout.rightMargin: FoamyStyle.gap
          spacing: FoamyStyle.gapSmall
          Repeater {
            model: overview.kind === "list" ? overview.summary.labels : []
            // The editor's label chip, a click target here. At most the
            // part's width: a long name is elided (in full in the tooltip),
            // the count stays.
            Target {
              id: chip
              required property var modelData
              objectName: "labelChip-" + modelData.name
              // A popup, outside the item tree (for the tests).
              readonly property var tip: chipTip
              width: Math.min(chipName.implicitWidth + chipRow.spacing + chipCount.implicitWidth + FoamyStyle.gap * 2, labelFlow.width)
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
                  id: chipName
                  objectName: "chipName"
                  width: Math.min(implicitWidth, chip.width - FoamyStyle.gap * 2 - chipRow.spacing - chipCount.implicitWidth)
                  text: "@" + chip.modelData.name
                  wrapMode: Text.NoWrap
                  elide: Text.ElideRight
                  font.pixelSize: FoamyStyle.font.bodySmall
                  color: FoamyPalette.onSurface(FoamyPalette.info)
                }
                PlainText {
                  id: chipCount
                  objectName: "chipCount"
                  anchors.verticalCenter: parent.verticalCenter
                  text: FoamyI18n.number(chip.modelData.count)
                  wrapMode: Text.NoWrap
                  font.family: FoamyStyle.monoFamily
                  font.pixelSize: FoamyStyle.font.caption
                  color: FoamyPalette.mutedText
                }
              }
              // The full name of an elided label (plain text, as wide as the pane at most).
              PanelToolTip {
                id: chipTip
                visible: chip.hovered && chipName.truncated
                text: chipName.text
                implicitWidth: Math.min(implicitContentWidth + leftPadding + rightPadding, overview.width)
                // The host's tooltip wraps at word boundaries only; a label
                // is often one long word, so it may break anywhere.
                Binding {
                  target: chipTip.contentItem
                  property: "wrapMode"
                  value: Text.WrapAtWordBoundaryOrAnywhere
                  when: chipTip.contentItem !== null
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
                  // It stands alone: a capital, also where the locale
                  // writes the day in lower case ("ons.").
                  text: overview.format ? Model.capitalized(overview.format(Model.dayDate(dayColumn.modelData.day), "ddd")) : ""
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
      default:
        return FoamyI18n.tn("%1 without a date", count)
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
  // "+N more" under a part's rows, in line with their text.
  component MoreLine: PlainText {
    Layout.fillWidth: true
    Layout.leftMargin: FoamyStyle.gap * 2 + FoamyStyle.iconSize
    wrapMode: Text.NoWrap
    font.pixelSize: FoamyStyle.font.caption
    color: FoamyPalette.mutedText
  }
  // A task in one line (Deadlines, Tomorrow): an icon or a time (the
  // icon's room, a time's width; empty for an untimed task), its text
  // elided, and a day at the end.
  component BriefRow: Target {
    id: briefRow
    property string iconName: ""
    property string lead: ""
    property string text: ""
    property string trail: ""
    property color trailColor: FoamyPalette.secondaryText
    property color iconColor: FoamyPalette.onSurface(FoamyPalette.accent)
    Layout.fillWidth: true
    implicitHeight: overview.briefRowHeight
    Accessible.name: [lead, text, trail].filter(function (part) {
      return part !== ""
    }).join(" ")
    FoamyIcon {
      id: briefIcon
      visible: briefRow.iconName !== ""
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      width: FoamyStyle.iconSize
      height: width
      name: briefRow.iconName
      color: briefRow.iconColor
    }
    PlainText {
      id: briefLead
      objectName: "briefLead"
      visible: briefRow.iconName === ""
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      text: briefRow.lead
      wrapMode: Text.NoWrap
      font.family: FoamyStyle.monoFamily
      font.pixelSize: FoamyStyle.font.caption
      color: FoamyPalette.secondaryText
    }
    // The lead's column: as wide as "00:00", the icon's room at least.
    PlainText {
      id: leadMetrics
      visible: false
      text: "00:00"
      font.family: FoamyStyle.monoFamily
      font.pixelSize: FoamyStyle.font.caption
    }
    PlainText {
      objectName: "briefText"
      anchors.left: parent.left
      anchors.leftMargin: FoamyStyle.gap * 2 + (briefRow.iconName !== "" ? FoamyStyle.iconSize : Math.max(FoamyStyle.iconSize, leadMetrics.implicitWidth))
      anchors.right: briefTrail.left
      anchors.rightMargin: briefTrail.text !== "" ? FoamyStyle.gap : 0
      anchors.verticalCenter: parent.verticalCenter
      text: briefRow.text
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
      font.pixelSize: FoamyStyle.font.bodySmall
    }
    PlainText {
      id: briefTrail
      objectName: "briefTrail"
      anchors.right: parent.right
      anchors.rightMargin: FoamyStyle.gap
      anchors.verticalCenter: parent.verticalCenter
      text: briefRow.trail
      wrapMode: Text.NoWrap
      font.pixelSize: FoamyStyle.font.caption
      color: briefRow.trailColor
    }
  }
  // What a figure counts, beside its number.
  component FigureWords: PlainText {
    wrapMode: Text.NoWrap
    font.pixelSize: FoamyStyle.font.bodySmall
    color: FoamyPalette.secondaryText
  }
  // One click target and Tab stop (the editor's section box): the hover
  // fill (the current fill when `current`), the keys' accent ring.
  component Target: Rectangle {
    id: target
    property bool current: false
    property color rest: "transparent"
    readonly property bool hovered: hover.hovered
    readonly property bool lit: hovered || activeFocus
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
        visible: text !== ""
        width: parent.width
        text: taskTarget.detail
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: FoamyStyle.font.caption
        color: FoamyPalette.secondaryText
      }
    }
  }
  // Today's hours (Model's `rows`: an hour each, or a dashed fold of empty
  // hours), a line each, the timed tasks as blocks at their time
  // (overlapping ones side by side, without their time), and a line at now
  // under the blocks, its time in the hours' column, while it is inside.
  component Timeline: Item {
    id: timeline
    property var summary: null
    readonly property var rows: summary ? summary.rows : []
    readonly property real hourHeight: FoamyStyle.controlHeight * 0.75
    // The hours' column fits "00:00" (now's time, a fold's "18–22").
    readonly property real labelWidth: FoamyStyle.gap + labelMetrics.implicitWidth + FoamyStyle.gapSmall
    readonly property real lanesWidth: width - labelWidth - FoamyStyle.gap
    // A block stays this big to click and read, however short its time (a
    // task late in the day is cut at midnight) or narrow its lane (the
    // model keeps the lanes to Model.MAX_LANES).
    readonly property real minBlockHeight: FoamyStyle.iconSize + FoamyStyle.gapSmall
    readonly property real minBlockWidth: FoamyStyle.controlHeight
    readonly property real rangeHeight: rows.length * hourHeight
    readonly property bool nowShown: summary !== null && summary.now
    readonly property real nowY: nowShown ? yOf(summary.nowMinutes) : 0
    function blockHeight(block) {
      return Math.max(minBlockHeight, block.length / 60 * hourHeight - 2)
    }
    function yOf(minutes) {
      return Model.timelineAt(rows, minutes) * hourHeight
    }
    function clock(minutes) {
      return Model.pad(Math.floor(minutes / 60)) + ":" + Model.pad(minutes % 60)
    }
    objectName: "timeline"
    // Room below the range for a block that its least height takes past midnight.
    implicitHeight: summary ? summary.blocks.reduce(function (bottom, block) {
      return Math.max(bottom, timeline.yOf(block.minutes) + 1 + timeline.blockHeight(block))
    }, rangeHeight) + FoamyStyle.gapSmall : 0
    PlainText {
      id: labelMetrics
      visible: false
      text: "00:00"
      font.family: FoamyStyle.monoFamily
      font.pixelSize: FoamyStyle.font.caption
    }
    Repeater {
      model: timeline.rows
      Item {
        id: hourRow
        required property var modelData
        required property int index
        readonly property bool fold: modelData.fold
        objectName: (fold ? "fold-" : "hour-") + modelData.from
        y: index * timeline.hourHeight
        width: timeline.width
        height: timeline.hourHeight
        PlainText {
          objectName: "hourLabel"
          anchors.left: parent.left
          anchors.leftMargin: FoamyStyle.gap
          y: -height / 2
          // Now's time takes the place of an hour it would cover.
          visible: !timeline.nowShown || Math.abs(hourRow.y - timeline.nowY) >= height
          text: hourRow.fold ? Model.pad(hourRow.modelData.from) + "–" + Model.pad(hourRow.modelData.to - 1) : Model.pad(hourRow.modelData.from)
          wrapMode: Text.NoWrap
          font.family: FoamyStyle.monoFamily
          font.pixelSize: FoamyStyle.font.caption
          color: FoamyPalette.mutedText
        }
        Rectangle {
          visible: !hourRow.fold
          anchors.left: parent.left
          anchors.leftMargin: timeline.labelWidth
          anchors.right: parent.right
          height: 1
          color: FoamyPalette.divider
        }
        // A fold: a dashed line.
        Row {
          visible: hourRow.fold
          anchors.left: parent.left
          anchors.leftMargin: timeline.labelWidth
          anchors.right: parent.right
          spacing: FoamyStyle.gapSmall
          clip: true
          Repeater {
            model: hourRow.fold ? Math.ceil((timeline.width - timeline.labelWidth) / (FoamyStyle.gapSmall * 2)) : 0
            Rectangle {
              width: FoamyStyle.gapSmall
              height: 1
              color: FoamyPalette.divider
            }
          }
        }
      }
    }
    // Now: under the blocks, so it never crosses a task's text.
    Item {
      objectName: "nowLine"
      visible: timeline.nowShown
      anchors.left: parent.left
      anchors.right: parent.right
      y: timeline.nowY
      height: 1
      PlainText {
        objectName: "nowLabel"
        anchors.left: parent.left
        anchors.leftMargin: FoamyStyle.gap
        anchors.verticalCenter: parent.verticalCenter
        text: timeline.summary ? timeline.clock(timeline.summary.nowMinutes) : ""
        wrapMode: Text.NoWrap
        font.family: FoamyStyle.monoFamily
        font.pixelSize: FoamyStyle.font.caption
      }
      Rectangle {
        objectName: "nowRule"
        anchors.left: parent.left
        anchors.leftMargin: timeline.labelWidth
        anchors.right: parent.right
        height: 1
        color: FoamyPalette.text
      }
    }
    Repeater {
      model: timeline.summary ? timeline.summary.blocks : []
      Target {
        id: block
        required property var modelData
        // A crowded run's last lane sums up the tasks it has no room for:
        // a click selects the first of them (the list scrolls to it, the
        // rest follow it there).
        readonly property bool summed: modelData.more > 0
        // A block that shares its row's width keeps its title only.
        readonly property string label: summed ? FoamyI18n.tn("+%1 more", modelData.more) : modelData.lanes > 1 ? modelData.text : modelData.time + " " + modelData.text
        objectName: (summed ? "more-" : "block-") + modelData.id
        readonly property real laneWidth: timeline.lanesWidth / modelData.lanes
        // Anchored with a margin, so RTL mirrors the lanes too.
        anchors.left: timeline.left
        anchors.leftMargin: timeline.labelWidth + FoamyStyle.gapSmall + modelData.lane * laneWidth
        y: timeline.yOf(modelData.minutes) + 1
        width: Math.max(timeline.minBlockWidth, laneWidth - FoamyStyle.gapTiny)
        height: timeline.blockHeight(modelData)
        radius: FoamyStyle.radiusSmall
        // Opaque, over the hour lines and now. An open task keeps its full
        // strength, also once its time has passed; a completed one (still
        // undoable) is faded.
        rest: Qt.tint(FoamyPalette.background, modelData.struck ? Qt.alpha(FoamyPalette.accent, 0.08) : FoamyPalette.selectedFill)
        Accessible.name: summed ? modelData.time + " " + label : modelData.time + " " + modelData.text
        onActivated: overview.taskPicked(modelData.id)
        Rectangle {
          objectName: "blockBar"
          anchors.left: parent.left
          width: 3
          height: parent.height
          radius: 1.5
          color: block.modelData.struck ? Qt.alpha(FoamyPalette.accent, 0.5) : FoamyPalette.accent
        }
        PlainText {
          objectName: "blockText"
          anchors.left: parent.left
          anchors.leftMargin: FoamyStyle.gap
          anchors.right: parent.right
          anchors.rightMargin: FoamyStyle.gapSmall
          anchors.verticalCenter: parent.verticalCenter
          text: block.label
          wrapMode: Text.NoWrap
          elide: Text.ElideRight
          font.pixelSize: FoamyStyle.font.caption
          color: block.modelData.struck ? FoamyPalette.secondaryText : FoamyPalette.text
          font.strikeout: block.modelData.struck
        }
      }
    }
  }
}
