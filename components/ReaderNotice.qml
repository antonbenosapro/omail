import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model

// A line above the message saying why it does not look the way the sender
// meant it to, and offering the one thing that would change that.
//
// There are three of these and they stack, which is the reason this is a type
// rather than three near-identical rectangles: they have to be the same height,
// the same fill and the same distance apart, or a message that trips two of
// them looks like a bug rather than like two answers to two questions.
Rectangle {
  id: root

  property string text: ""
  property string actionLabel: ""
  // While the action is in flight. The button says so rather than disappearing,
  // because a control that vanishes under the pointer reads as a misclick.
  property bool busy: false
  property string busyLabel: ""
  // The reader's. A notice is about the message, and somebody who needed the
  // message bigger needs the sentence about it bigger too.
  property real zoom: 1.0
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property string panelFontFamily

  signal activated()

  // Grows with its text rather than clipping it: thirty pixels holds a caption
  // at 1.0 and not one at 2.5.
  implicitHeight: Math.max(Style.space(30), label.implicitHeight + Style.space(12),
    action.visible ? action.implicitHeight + Style.space(8) : 0)
  radius: Style.cornerRadius
  color: Style.normalFillFor(root.textColor, root.accentColor)
  border.width: 1
  border.color: Style.normalBorderFor(root.textColor, root.accentColor)

  Text {
    id: label
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.right: action.visible ? action.left : parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    // A stranger's mail decides when this shows but never what it says, so the
    // string is this app's own — plain text all the same, because the rule
    // that every Text in the reader declares its format has no exceptions
    // worth remembering.
    textFormat: Text.PlainText
    text: root.text
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Model.zoomedFontSize(Style.font.caption, root.zoom)
    elide: Text.ElideRight
  }

  Button {
    id: action
    visible: root.actionLabel !== ""
    enabled: !root.busy
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: implicitWidth
    height: implicitHeight
    text: root.busy && root.busyLabel !== "" ? root.busyLabel : root.actionLabel
    foreground: root.textColor
    bordered: false
    fontSize: Model.zoomedFontSize(Style.font.caption, root.zoom)
    horizontalPadding: Style.space(8)
    verticalPadding: Style.space(2)
    focusable: true
    onClicked: root.activated()
  }
}
