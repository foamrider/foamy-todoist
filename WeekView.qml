pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import qs.Ui as Ui
import "kit"
import "Model.js" as Model

// The Week view (Wide only): four columns, Overdue, Today, Tomorrow and
// Later (the seven days after tomorrow, each day under a small heading),
// from Model.weekColumns. A card is built from the list row's parts and
// sizes (TaskRow): the priority ring (complete), the task, and a detail
// line with the date (overdue: red, with the warning mark), the time in
// the mono face, the project and the repeat mark. The project elides; the
// date and the time never do. An unconfirmed completion reads as the row
// does: the title in the secondary tone, a plain ring, the refresh mark.
// The cursor's card shows two small actions, a day earlier and a day
// later (as Ctrl+←/→), over the detail line's end: the card keeps its
// height and its text stays where it is. `narrow`: the details pane
// stands beside the board, so the four columns stay but tighten (smaller
// gaps, a title on up to three lines, short day headings).
//
// The cursor is TodoView's (one stop for the whole grid); this view only
// draws it: `cursorColumn`, `cursorCard` (the card's index among the
// column's tasks, headings left out). Hover and clicks report back.
//
// Each column is a lazy ListView: Overdue can hold every task the snapshot
// keeps, so only the cards in view (and a buffer) are built. The indices
// (`card`, `cards`) come computed with the columns (Model.weekColumns).
Item {
  id: week
  property var columns: []
  property bool hasCursor: false
  // The keys moved the cursor (its accent border).
  property bool byKeys: false
  property int cursorColumn: 0
  property int cursorCard: 0
  // The task the details pane shows (its card is marked).
  property string selectedId: ""
  // The task the keys act on (TodoView.keyTarget): a move action's tooltip
  // names Ctrl+←/→ only on that card.
  property string keysTaskId: ""
  property bool narrow: false
  readonly property real columnGap: narrow ? FoamyStyle.gapSmall : FoamyStyle.gap
  signal hovered(int column, int card)
  signal clicked(int column, int card)
  signal completeRequested(string id)
  // A card's move action: a day earlier (-1) or later (1).
  signal shiftRequested(string id, int delta)
  // A click on a column's empty space (below its cards, a day heading).
  signal spaceClicked

  function formatDate(date, pattern) {
    return date.toLocaleDateString(Qt.locale(FoamyI18n.formatLocale), pattern)
  }
  function translate(key, values) {
    return FoamyI18n.t(key, values)
  }
  function title(key) {
    return key === "overdue" ? FoamyI18n.t("Overdue") : key === "today" ? FoamyI18n.t("Today") : key === "tomorrow" ? FoamyI18n.t("Tomorrow") : FoamyI18n.t("Later")
  }
  // Keeps the cursor's card in view.
  function reveal() {
    var list = columnRepeater.itemAt(cursorColumn) as WeekColumn
    if (list)
      list.reveal(cursorCard)
  }
  // The tallest column without scrolling: the view's natural height.
  readonly property real tallest: {
    var most = 0
    for (let i = 0; i < columnRepeater.count; i++) {
      const item = columnRepeater.itemAt(i) as WeekColumn
      if (item)
        most = Math.max(most, item.naturalHeight)
    }
    return most
  }
  implicitHeight: tallest
  // A card title's line (the ring and, without a detail line, the move
  // actions stand on one).
  FontMetrics {
    id: titleMetrics
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: week.columnGap
    anchors.rightMargin: week.columnGap
    spacing: week.columnGap
    Repeater {
      id: columnRepeater
      model: week.columns
      WeekColumn {}
    }
  }
  function roleColor(role) {
    // Marks on the surface: readable in a light theme too.
    return role === "error" ? FoamyPalette.onSurface(FoamyPalette.error) : role === "warning" ? FoamyPalette.onSurface(FoamyPalette.warning) : role === "accent" ? FoamyPalette.onSurface(FoamyPalette.accent) : FoamyPalette.mutedText
  }

  // One column: its title and count, then its cards (Later: under day headings).
  component WeekColumn: Item {
    id: columnItem
    required property var modelData
    required property int index
    readonly property int count: modelData.cards.length
    readonly property alias list: entriesList
    // Header, entries, padding: the column's height without scrolling (the
    // list's estimate past the cards it built, which is past the most the
    // view shows).
    readonly property real naturalHeight: head.height + entriesList.contentHeight + FoamyStyle.gap * 2
    objectName: "weekColumn-" + modelData.key
    width: (parent.width - week.columnGap * (week.columns.length - 1)) / Math.max(1, week.columns.length)
    height: parent.height
    function reveal(card) {
      if (card >= 0 && card < count)
        entriesList.positionViewAtIndex(modelData.cards[card], ListView.Contain)
    }
    Item {
      id: head
      width: parent.width
      height: FoamyStyle.rowHeight
      PlainText {
        anchors.left: parent.left
        anchors.leftMargin: FoamyStyle.rowPadding
        anchors.verticalCenter: parent.verticalCenter
        text: week.title(columnItem.modelData.key)
        wrapMode: Text.NoWrap
        font.pixelSize: FoamyStyle.font.bodySmall
        font.weight: Font.DemiBold
        color: columnItem.modelData.key === "overdue" && columnItem.count ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.text
      }
      PlainText {
        anchors.right: parent.right
        anchors.rightMargin: FoamyStyle.rowPadding
        anchors.verticalCenter: parent.verticalCenter
        objectName: "weekCount"
        text: columnItem.count ? FoamyI18n.number(columnItem.count) : ""
        wrapMode: Text.NoWrap
        font.family: FoamyStyle.monoFamily
        font.pixelSize: FoamyStyle.font.caption
        // secondaryText: mutedText measures under 4.5:1 (dark theme).
        color: FoamyPalette.secondaryText
      }
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: FoamyPalette.divider
      }
    }
    PlainText {
      visible: columnItem.count === 0
      anchors.top: head.bottom
      anchors.topMargin: FoamyStyle.gapLarge
      x: FoamyStyle.rowPadding
      width: parent.width - FoamyStyle.rowPadding * 2
      text: FoamyI18n.t("No tasks")
      font.pixelSize: FoamyStyle.font.bodySmall
      color: FoamyPalette.mutedText
    }
    ListView {
      id: entriesList
      objectName: "weekList"
      anchors.top: head.bottom
      anchors.topMargin: FoamyStyle.gap
      anchors.bottom: parent.bottom
      anchors.bottomMargin: FoamyStyle.gap
      width: parent.width
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      spacing: FoamyStyle.gapSmall
      // Enough built beyond the view for its natural height to be exact up
      // to the tallest the panel draws it.
      cacheBuffer: FoamyStyle.rowHeight * 18
      model: columnItem.modelData.entries
      Controls.ScrollBar.vertical: Controls.ScrollBar {
        policy: Controls.ScrollBar.AsNeeded
      }
      FoamyWheelScroll {
        target: entriesList
        onSpaceClicked: week.spaceClicked()
      }
      delegate: Item {
        id: entryItem
        required property var modelData
        required property int index
        readonly property bool isDay: modelData.kind === "day"
        readonly property int card: modelData.card
        objectName: isDay ? modelData.key : "card-" + modelData.id
        width: ListView.view.width
        height: isDay ? FoamyStyle.rowHeight - 8 : cardSurface.height
        // Later's day headings: the weekday and the date.
        PlainText {
          visible: entryItem.isDay
          anchors.bottom: parent.bottom
          anchors.bottomMargin: FoamyStyle.gapTiny
          x: FoamyStyle.rowPadding
          width: parent.width - x * 2
          text: !entryItem.isDay ? "" : Model.weekDayHeading(entryItem.modelData.dayKey, week.narrow, week.formatDate, week.translate)
          wrapMode: Text.NoWrap
          elide: Text.ElideRight
          font.pixelSize: FoamyStyle.font.caption
          font.weight: Font.DemiBold
          color: FoamyPalette.secondaryText
        }
        FoamyCursorSurface {
          id: cardSurface
          visible: !entryItem.isDay
          width: parent.width
          height: textColumn.implicitHeight + FoamyStyle.gap * 2
          hasCursor: week.hasCursor && week.cursorColumn === columnItem.index && week.cursorCard === entryItem.card
          byKeys: week.byKeys
          current: !entryItem.isDay && week.selectedId === entryItem.modelData.id
          onHovered: week.hovered(columnItem.index, entryItem.card)
          onClicked: week.clicked(columnItem.index, entryItem.card)
          Accessible.role: Accessible.ListItem
          Accessible.name: entryItem.isDay ? "" : entryItem.modelData.text
          readonly property var entry: entryItem.isDay ? null : entryItem.modelData
          readonly property bool struck: !!entry && entry.struck === true
          readonly property bool unconfirmed: !!entry && entry.unconfirmed === true
          // As the list's ring: its look by priority, plain while
          // unconfirmed; completed without a priority, the secondary tone;
          // the check in the ink that reads on the completed fill.
          readonly property color ringColor: !entry || unconfirmed ? FoamyPalette.mutedText : struck && entry.priorityRole === "muted" ? FoamyPalette.secondaryText : week.roleColor(entry.priorityRole)
          readonly property var ringLook: unconfirmed ? ({
              border: 1,
              fill: 0
            }) : Model.ringLook(entry ? entry.priority : 0)
          readonly property color checkInk: {
            const fill = Qt.tint(FoamyPalette.background, Qt.alpha(ringColor, Model.RING_DONE))
            return FoamyPalette.contrastRatio(FoamyPalette.text, fill) >= FoamyPalette.contrastRatio(FoamyPalette.background, fill) ? FoamyPalette.text : FoamyPalette.background
          }
          readonly property bool ringLit: ringArea.containsMouse && !unconfirmed
          // The move actions: on the cursor's card, while it can move.
          readonly property bool movable: hasCursor && !!entry && !struck && !unconfirmed
          MouseArea {
            id: ringArea
            objectName: "weekRing"
            anchors.left: parent.left
            anchors.leftMargin: FoamyStyle.gapSmall
            // Centred on the title's first line, as the row's ring.
            y: textColumn.y + (titleMetrics.height - height) / 2
            width: FoamyStyle.iconSize + FoamyStyle.gap
            height: FoamyStyle.iconSize + FoamyStyle.gap
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: week.completeRequested(entryItem.modelData.id)
            Accessible.role: Accessible.CheckBox
            Accessible.checked: cardSurface.struck
            Accessible.name: FoamyI18n.t("Complete")
            Rectangle {
              objectName: "weekRingMark"
              anchors.centerIn: parent
              width: 16
              height: 16
              radius: 8
              border.width: cardSurface.ringLook.border
              border.color: cardSurface.ringColor
              color: Qt.alpha(cardSurface.ringColor, cardSurface.struck ? Model.RING_DONE : cardSurface.ringLook.fill + (cardSurface.ringLit ? Model.RING_HOVER : 0))
              FoamyIcon {
                objectName: "weekRingCheck"
                visible: cardSurface.struck || cardSurface.ringLit
                anchors.centerIn: parent
                width: 11
                height: 11
                name: "check"
                color: cardSurface.struck ? cardSurface.checkInk : cardSurface.ringColor
              }
            }
          }
          Column {
            id: textColumn
            anchors.left: ringArea.right
            anchors.right: parent.right
            anchors.rightMargin: FoamyStyle.gap
            y: FoamyStyle.gap
            spacing: 1
            PlainText {
              id: cardText
              objectName: "cardText"
              width: parent.width
              text: cardSurface.entry ? cardSurface.entry.text : ""
              maximumLineCount: week.narrow ? 3 : 2
              elide: Text.ElideRight
              font.strikeout: cardSurface.struck
              color: cardSurface.struck ? FoamyPalette.mutedText : cardSurface.unconfirmed ? FoamyPalette.secondaryText : FoamyPalette.text
            }
            // The row's detail line: the date, the time and the repeat mark,
            // which show whole, then the project, which elides (the move
            // actions only ever cover its end).
            Row {
              id: detail
              objectName: "cardDetail"
              readonly property var entry: cardSurface.entry
              readonly property string dateText: entry && entry.dateKind ? Model.detailDate(entry, week.formatDate, week.translate, TodoStore.today) : ""
              visible: !!entry && (dateText !== "" || entry.dueTime !== "" || entry.showProject || entry.recurring || cardSurface.unconfirmed)
              width: parent.width
              spacing: FoamyStyle.gap
              clip: true
              opacity: cardSurface.struck ? FoamyStyle.disabledOpacity : 1
              // What the project may take: the rest of the line after the
              // parts that show whole and the move actions' place when they
              // show.
              readonly property real room: Math.max(0, width - [checkingMark, dateBox, timeLabel, repeatMark].reduce(function (sum, part) {
                return sum + (part.visible ? part.width + spacing : 0)
              }, 0) - (moveActions.visible ? moveActions.claim + spacing : 0))
              // Its completion was sent, the outcome unknown until the next sync.
              FoamyIcon {
                id: checkingMark
                objectName: "cardChecking"
                visible: cardSurface.unconfirmed
                anchors.verticalCenter: parent.verticalCenter
                width: FoamyStyle.font.caption
                height: width
                name: "refresh-cw"
                color: FoamyPalette.secondaryText
                HoverHandler {
                  id: checkingHover
                }
                Ui.PanelToolTip {
                  visible: checkingHover.hovered
                  text: FoamyI18n.t("Checking with Todoist…")
                }
              }
              // The date; an overdue one in red with the warning mark (only
              // the date: the rest of the line keeps its tones).
              Row {
                id: dateBox
                visible: detail.dateText !== ""
                spacing: 3
                FoamyIcon {
                  objectName: "cardLateMark"
                  visible: !!detail.entry && detail.entry.overdue
                  anchors.verticalCenter: parent.verticalCenter
                  width: FoamyStyle.font.caption
                  height: width
                  name: "triangle-alert"
                  color: cardDate.color
                }
                PlainText {
                  id: cardDate
                  objectName: "cardDate"
                  text: detail.dateText
                  wrapMode: Text.NoWrap
                  font.pixelSize: FoamyStyle.font.caption
                  color: !!detail.entry && detail.entry.overdue ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
                }
              }
              PlainText {
                id: timeLabel
                objectName: "cardTime"
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: detail.entry ? detail.entry.dueTime : ""
                wrapMode: Text.NoWrap
                font.family: FoamyStyle.monoFamily
                font.pixelSize: FoamyStyle.font.caption
                color: FoamyPalette.secondaryText
              }
              FoamyIcon {
                id: repeatMark
                objectName: "cardRepeat"
                visible: !!detail.entry && detail.entry.recurring
                anchors.verticalCenter: parent.verticalCenter
                width: FoamyStyle.font.caption
                height: width
                name: "repeat"
                color: FoamyPalette.secondaryText
              }
              // Left out when not even a letter and "…" fit (no lone hash).
              Row {
                id: projectBox
                readonly property real textRoom: detail.room - FoamyStyle.font.caption - spacing
                visible: !!detail.entry && detail.entry.showProject && textRoom >= FoamyStyle.font.caption * 1.5
                spacing: 2
                FoamyIcon {
                  objectName: "cardHash"
                  anchors.verticalCenter: parent.verticalCenter
                  width: FoamyStyle.font.caption
                  height: width
                  name: "hash"
                  color: FoamyPalette.mutedText
                }
                PlainText {
                  objectName: "cardProject"
                  text: detail.entry ? detail.entry.projectName : ""
                  wrapMode: Text.NoWrap
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, Math.max(0, projectBox.textRoom))
                  font.pixelSize: FoamyStyle.font.caption
                  color: FoamyPalette.secondaryText
                }
              }
            }
          }
          // A day earlier and a day later, over the detail line's end (on
          // the title's last line when there is none), on the card's own
          // fill so nothing under them shows through.
          Rectangle {
            id: moveActions
            objectName: "moveActions"
            visible: cardSurface.movable
            // Partly in the card's end padding: the least of the line it takes.
            anchors.right: parent.right
            anchors.rightMargin: FoamyStyle.gapTiny
            y: textColumn.y + (detail.visible ? detail.y + detail.height / 2 : cardText.height - titleMetrics.height / 2) - height / 2
            width: moveRow.width + FoamyStyle.gapTiny * 2
            height: moveRow.height
            radius: FoamyStyle.radiusSmall
            // What it takes from the detail line's end.
            readonly property real claim: width + FoamyStyle.gapTiny - FoamyStyle.gap
            color: Qt.tint(FoamyPalette.background, cardSurface.color)
            Row {
              id: moveRow
              anchors.centerIn: parent
              spacing: FoamyStyle.gapTiny
              MoveAction {
                objectName: "moveEarlier"
                delta: -1
                entry: cardSurface.entry
                iconName: "chevron-left"
                label: FoamyI18n.t("A day earlier")
                // Ctrl+← in a left-to-right panel (TodoView.chordKey).
                keys: "Ctrl+" + (LayoutMirroring.enabled ? "→" : "←")
                onHovered: week.hovered(columnItem.index, entryItem.card)
              }
              MoveAction {
                objectName: "moveLater"
                delta: 1
                entry: cardSurface.entry
                iconName: "chevron-right"
                label: FoamyI18n.t("A day later")
                keys: "Ctrl+" + (LayoutMirroring.enabled ? "←" : "→")
                onHovered: week.hovered(columnItem.index, entryItem.card)
              }
            }
          }
        }
      }
    }
  }

  // A card's small move action: a click moves its task a day (the
  // store refuses a repeating one and says why, as for the keys). Its
  // tooltip names the keys while they act on this card.
  component MoveAction: Rectangle {
    id: action
    property var entry: null
    property int delta: 0
    property string iconName: ""
    property string label: ""
    property string keys: ""
    readonly property bool lit: mouse.containsMouse
    readonly property string tip: !!entry && week.keysTaskId === entry.id ? label + " (" + keys + ")" : label
    signal hovered
    width: height
    height: FoamyStyle.font.caption + FoamyStyle.gapSmall + 2
    radius: FoamyStyle.radiusSmall
    color: lit ? Qt.tint(FoamyPalette.fieldFill, FoamyPalette.hoverFill) : FoamyPalette.fieldFill
    border.width: FoamyStyle.borderWidth
    border.color: FoamyPalette.border
    Accessible.role: Accessible.Button
    Accessible.name: tip
    Accessible.onPressAction: week.shiftRequested(action.entry.id, action.delta)
    FoamyIcon {
      anchors.centerIn: parent
      width: FoamyStyle.font.caption
      height: width
      name: action.iconName
      color: action.lit ? FoamyPalette.text : FoamyPalette.secondaryText
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: action.hovered()
      onClicked: week.shiftRequested(action.entry.id, action.delta)
    }
    Ui.PanelToolTip {
      objectName: "moveTip"
      visible: action.lit
      text: action.tip
    }
  }
}
