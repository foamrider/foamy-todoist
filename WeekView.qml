pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "kit"
import "Model.js" as Model

// The Week view (Wide only): four columns, Overdue, Today, Tomorrow and
// Later (the seven days after tomorrow, each day under a small heading),
// from Model.weekColumns. A card: the priority ring (complete), the task,
// and a line with the time and the project. `narrow`: the details pane
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
  property bool narrow: false
  readonly property real columnGap: narrow ? FoamyStyle.gapSmall : FoamyStyle.gap
  signal hovered(int column, int card)
  signal clicked(int column, int card)
  signal completeRequested(string id)
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
          height: cardText.implicitHeight + cardMeta.implicitHeight + FoamyStyle.gap * 2 + 2
          hasCursor: week.hasCursor && week.cursorColumn === columnItem.index && week.cursorCard === entryItem.card
          byKeys: week.byKeys
          current: !entryItem.isDay && week.selectedId === entryItem.modelData.id
          opacity: !entryItem.isDay && entryItem.modelData.unconfirmed ? FoamyStyle.disabledOpacity : 1
          onHovered: week.hovered(columnItem.index, entryItem.card)
          onClicked: week.clicked(columnItem.index, entryItem.card)
          Accessible.role: Accessible.ListItem
          Accessible.name: entryItem.isDay ? "" : entryItem.modelData.text
          readonly property bool struck: !entryItem.isDay && entryItem.modelData.struck === true
          // Completed without a priority: the secondary tone (as the list's ring).
          readonly property color ringColor: entryItem.isDay ? FoamyPalette.mutedText : struck && entryItem.modelData.priorityRole === "muted" ? FoamyPalette.secondaryText : week.roleColor(entryItem.modelData.priorityRole)
          // As the list's ring: its look by priority, the check in the ink
          // that reads on the completed fill.
          readonly property var ringLook: Model.ringLook(entryItem.isDay ? 0 : entryItem.modelData.priority)
          readonly property color checkInk: {
            const fill = Qt.tint(FoamyPalette.background, Qt.alpha(ringColor, Model.RING_DONE))
            return FoamyPalette.contrastRatio(FoamyPalette.text, fill) >= FoamyPalette.contrastRatio(FoamyPalette.background, fill) ? FoamyPalette.text : FoamyPalette.background
          }
          MouseArea {
            id: ringArea
            objectName: "weekRing"
            anchors.left: parent.left
            anchors.leftMargin: FoamyStyle.gapSmall
            y: FoamyStyle.gapSmall
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
              width: 14
              height: 14
              radius: 7
              border.width: cardSurface.ringLook.border
              border.color: cardSurface.ringColor
              color: Qt.alpha(cardSurface.ringColor, cardSurface.struck ? Model.RING_DONE : cardSurface.ringLook.fill + (ringArea.containsMouse ? Model.RING_HOVER : 0))
              FoamyIcon {
                objectName: "weekRingCheck"
                visible: cardSurface.struck || ringArea.containsMouse
                anchors.centerIn: parent
                width: 10
                height: 10
                name: "check"
                color: cardSurface.struck ? cardSurface.checkInk : cardSurface.ringColor
              }
            }
          }
          PlainText {
            id: cardText
            objectName: "cardText"
            anchors.left: ringArea.right
            anchors.right: parent.right
            anchors.rightMargin: FoamyStyle.gap
            y: FoamyStyle.gap
            text: entryItem.isDay ? "" : entryItem.modelData.text
            maximumLineCount: week.narrow ? 3 : 2
            elide: Text.ElideRight
            font.pixelSize: FoamyStyle.font.bodySmall
            font.strikeout: cardSurface.struck
            color: cardSurface.struck ? FoamyPalette.mutedText : FoamyPalette.text
          }
          // The time (red when overdue, with its date), then the project.
          PlainText {
            id: cardMeta
            objectName: "cardMeta"
            anchors.left: cardText.left
            anchors.right: cardText.right
            anchors.top: cardText.bottom
            anchors.topMargin: 2
            text: entryItem.isDay ? "" : [entryItem.modelData.dateKind ? Model.detailDate(entryItem.modelData, week.formatDate, week.translate, TodoStore.today) : "", entryItem.modelData.dueTime, entryItem.modelData.projectName].filter(function (part) {
              return part !== ""
            }).join(" · ")
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            font.pixelSize: FoamyStyle.font.caption
            color: !entryItem.isDay && entryItem.modelData.overdue ? FoamyPalette.onSurface(FoamyPalette.error) : FoamyPalette.secondaryText
          }
        }
      }
    }
  }
}
