import QtQuick
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model

// One message in the list. Unread is carried by weight and by the dot on the
// left, never by colour alone — the accent is a theme value that some themes
// put close to the foreground.
Rectangle {
  id: root

  required property var summary
  required property color textColor
  // The ground, needed for the one glyph drawn on top of the accent rather
  // than on the panel: a check on a filled box has to read against the fill.
  required property color backgroundColor
  required property color accentColor
  required property color dimColor
  required property string panelFontFamily
  // Passed down rather than read off a service: a row draws one message and
  // has no other use for one.
  // The list keeps its own reading size, separate from the reader's: a dense
  // list beside a large message is a real way to work on a wide screen.
  property real zoom: 1.0
  property bool canArchive: true
  property bool hasCursor: false
  property bool selected: false
  // In the set the next action will act on. A third state beside the cursor
  // and the open message, and all four combinations of the three have to be
  // told apart: the cursor is an outline, the open message a fill, and this a
  // checkbox in the gutter with a bar down the leading edge. Shape, not
  // colour — some themes put the accent close to the foreground, and a row
  // that said "about to be trashed" in a hue alone would say it to nobody on
  // one of those.
  property bool marked: false
  // The mailbox this message arrived in, shown only when the list holds more
  // than one. Empty means a single-account list, where every row would carry
  // the same mark and it would say nothing.
  property string accountColor: ""

  signal activated()
  signal starToggled()
  signal archiveRequested()
  signal trashRequested()
  signal markToggled()
  signal menuRequested(real sceneX, real sceneY)

  readonly property bool hot: mouse.containsMouse || hasCursor

  width: parent ? parent.width : 0
  implicitHeight: body.implicitHeight + Style.space(14)
  radius: Style.cornerRadius
  // Three fills for three states, and a marked row keeps whichever it had —
  // its own mark is the checkbox and the bar, which sit on top of any of them.
  // A fourth fill would have had to be told apart from the other three at a
  // glance, and there is no fourth step of weight left between "quiet" and
  // "this is the one".
  color: selected
    ? Style.selectedFillFor(textColor, accentColor)
    : (marked || hot ? Style.hoverFillFor(textColor, accentColor) : "transparent")

  // The cursor is an outline. Sharing the hover fill with the mouse left the
  // two indistinguishable, so a row could be under the pointer and look
  // exactly like the row the keyboard was standing on — which matters far more
  // once a key can act on several rows at once.
  border.width: hasCursor ? 1 : 0
  border.color: hasCursor
    ? Qt.rgba(textColor.r, textColor.g, textColor.b, 0.35)
    : "transparent"

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        var scene = mapToGlobal(event.x, event.y)
        root.menuRequested(scene.x, scene.y)
      } else if (event.button === Qt.MiddleButton) {
        // Middle-click archives: the one triage action worth having without
        // moving the pointer to a button.
        root.archiveRequested()
      } else {
        root.activated()
      }
    }
  }

  // The mailbox this arrived in. A bar down the leading edge rather than a
  // badge, so a column of them reads as a column at a glance — which is the
  // whole point of it in a merged list.
  //
  // Clipped to the row's own radius: the row is rounded, and a square bar at
  // x=0 would sit outside its corners.
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(3)
    visible: root.accountColor !== ""
    color: root.accountColor !== "" ? root.accountColor : "transparent"
    radius: root.radius
    // Only the leading corners are the row's; the trailing edge of a 3px bar
    // meets the row's fill and must not round away from it.
    Rectangle {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width / 2
      color: parent.color
    }
  }

  // A marked row wears a solid bar down its leading edge as well as the box,
  // so the set reads as a block at a glance rather than as a column of small
  // ticks. It sits over the account stripe: while a set is up, which mailbox a
  // row came from is the less urgent of the two facts.
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(3)
    visible: root.marked
    color: root.accentColor
    radius: root.radius

    Rectangle {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width / 2
      color: parent.color
    }
  }

  // The unread dot and the checkbox share one slot in the gutter, so turning
  // the selection on shifts nothing: the box takes the dot's place while it is
  // relevant, and the dot comes back when it is not. Reserving a second column
  // for the boxes would have moved every row in the list sideways on the first
  // `x`, which is a lot of motion for one keystroke.
  Item {
    id: gutter
    anchors.left: parent.left
    // Ends exactly where the body's text begins, so the three columns still
    // start their content on one vertical line.
    anchors.leftMargin: Style.space(2)
    anchors.top: parent.top
    anchors.topMargin: Style.space(9)
    width: Style.space(12)
    height: Style.space(12)

    Rectangle {
      anchors.centerIn: parent
      width: Style.space(5)
      height: width
      radius: width / 2
      visible: root.summary.unread && !checkbox.visible
      color: root.accentColor
    }

    // Shown while it can be acted on: a marked row always, and any row the
    // pointer or the cursor is on, which is what says the box is there to be
    // pressed at all.
    Rectangle {
      id: checkbox
      anchors.fill: parent
      visible: root.marked || root.hot
      radius: Style.cornerRadius
      color: root.marked ? root.accentColor : "transparent"
      border.width: 1
      border.color: root.marked
        ? root.accentColor
        : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.45)

      ActionIcon {
        anchors.centerIn: parent
        name: "check"
        visible: root.marked
        // On the accent, so it reads against it whichever way round the theme
        // puts the two.
        color: root.backgroundColor
        iconSize: Style.space(10)
        strokeScale: 2.0
      }
    }

    // A 12px box is the right thing to look at and a small thing to aim at, so
    // the target is grown a little — but not past where the subject starts, or
    // clicking the beginning of a subject line would mark rather than open.
    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(2)
      enabled: checkbox.visible
      onClicked: root.markToggled()
    }
  }

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: actions.visible ? actions.left : parent.right
    // Matches the reader's content inset and the header's logo, so all three
    // columns start their text on one vertical line.
    anchors.leftMargin: Style.space(14)
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    // The subject leads. It is what the message is, and it is what you scan a
    // list for; the sender had the top line and the weight, which put the
    // emphasis on who wrote rather than on what about.
    Item {
      width: parent.width
      implicitHeight: Math.max(subject.implicitHeight, time.implicitHeight)

      Text {
        id: subject
        anchors.left: parent.left
        anchors.right: time.left
        anchors.rightMargin: Style.space(8)
        // A stranger wrote this. Qt's default AutoText switches a string that
        // looks like markup into rich text, and rich text with an <img> in it is
        // a fetch — the same beacon the message body is stripped of.
        textFormat: Text.PlainText
        text: root.summary.subject
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Model.zoomedFontSize(Style.font.body, root.zoom)
        font.bold: root.summary.unread
        elide: Text.ElideRight
      }

      Text {
        id: time
        anchors.right: parent.right
        anchors.baseline: subject.baseline
        textFormat: Text.PlainText
        text: root.summary.time
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Model.zoomedFontSize(Style.font.caption, root.zoom)
      }
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.summary.from.display
      color: root.dimColor
      font.family: root.panelFontFamily
      font.pixelSize: Model.zoomedFontSize(Style.font.bodySmall, root.zoom)
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: root.summary.snippet !== ""
      textFormat: Text.PlainText
      text: root.summary.snippet
      color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.42)
      font.family: root.panelFontFamily
      font.pixelSize: Model.zoomedFontSize(Style.font.caption, root.zoom)
      elide: Text.ElideRight
      maximumLineCount: 1
    }
  }

  // Row actions appear on hover or under the keyboard cursor. A starred
  // message keeps its star visible either way, because that is state rather
  // than an affordance.
  Row {
    id: actions
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(1)
    visible: root.hot || root.summary.starred

    IconButton {
      iconName: "star"
      filled: root.summary.starred
      tooltipText: (root.summary.starred ? "Unstar" : "Star") + " · s"
      foreground: root.summary.starred ? root.accentColor : root.dimColor
      hoverColor: root.accentColor
      iconSize: Style.font.iconSmall
      size: Style.space(24)
      fontFamily: root.panelFontFamily
      onClicked: root.starToggled()
    }

    IconButton {
      // No archive button where the account has nowhere to archive to. On IMAP
      // that is a move to a folder, and a server without one would have this
      // quietly do nothing.
      visible: root.hot && root.canArchive
      iconName: "archive"
      tooltipText: "Archive · e"
      foreground: root.dimColor
      hoverColor: root.textColor
      iconSize: Style.font.iconSmall
      size: Style.space(24)
      fontFamily: root.panelFontFamily
      onClicked: root.archiveRequested()
    }

    IconButton {
      visible: root.hot
      iconName: "trash"
      tooltipText: "Move to trash · d"
      foreground: root.dimColor
      hoverColor: root.textColor
      iconSize: Style.font.iconSmall
      size: Style.space(24)
      fontFamily: root.panelFontFamily
      onClicked: root.trashRequested()
    }
  }
}
