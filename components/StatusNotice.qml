import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// What the window most needs to say, at the right of the status line — and,
// when saying it is not enough, the one thing that would change it.
//
// The same contract as `ReaderNotice`: `text`, `actionLabel`, `busy`, and an
// `activated()` signal. Deliberately the same, because they are the same idea
// in two places — a sentence the window volunteers, with an offer beside it —
// and two notices that answered to different property names would read as two
// unrelated mechanisms to anyone adding a third.
//
// What differs is only the chrome, and it has to. `ReaderNotice` is a bordered
// card the width of the message it sits above, standing until the message is
// closed; this is one line in a bar the height of a caption, sharing that line
// with the sync summary and standing for a few seconds. A card here would be
// taller than the bar containing it.
Row {
  id: root

  property string text: ""
  property string actionLabel: ""
  // While the offer is being taken. The button says so rather than
  // disappearing: a control that vanishes under the pointer reads as a
  // misclick, and this one sits under a pointer that has just clicked it.
  property bool busy: false
  property string busyLabel: ""
  // Set when the sentence is a failure rather than an event, which is the one
  // time this line is worth more than the theme's quiet foreground.
  property bool urgent: false

  required property color textColor
  required property color dimColor
  required property color urgentColor
  required property color accentColor
  required property string panelFontFamily

  signal activated()

  spacing: Style.space(6)

  // How wide this wants to be, said by the caller rather than measured back off
  // the caller's own answer: the sentence's width feeds the Row's implicitWidth,
  // so sizing the sentence from the Row's width would be a binding loop.
  //
  // The sentence gives way before the offer does. Eliding "Moved to trash" to
  // "Moved to…" still says enough to read; an elided "Und…" is a button nobody
  // can make out, and it is the half that has to be pressed.
  property real maximumWidth: 0
  readonly property real actionSpace:
    action.visible ? action.implicitWidth + root.spacing : 0

  Text {
    id: message
    anchors.verticalCenter: parent.verticalCenter
    // A subject or a sender can reach this line — "Saved <name> to Downloads"
    // names a file a stranger chose — and none of it is markup.
    textFormat: Text.PlainText
    text: root.text
    color: root.urgent ? root.urgentColor : root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    width: root.maximumWidth > 0
      ? Math.min(implicitWidth, Math.max(0, root.maximumWidth - root.actionSpace))
      : implicitWidth
    horizontalAlignment: Text.AlignRight
  }

  Button {
    id: action
    anchors.verticalCenter: parent.verticalCenter
    visible: root.actionLabel !== ""
    enabled: !root.busy
    width: implicitWidth
    height: implicitHeight
    text: root.busy && root.busyLabel !== "" ? root.busyLabel : root.actionLabel
    foreground: root.textColor
    bordered: false
    fontSize: Style.font.caption
    horizontalPadding: Style.space(6)
    verticalPadding: 0
    // Reachable by pointer here, and by its own key everywhere: the keyboard
    // does not go looking for a button on the status line, so the binding in
    // keys/Keymap.js is the offer's real front door and this is the other one.
    focusable: false
    onClicked: root.activated()
  }
}
