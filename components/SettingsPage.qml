import QtQuick
import qs.Commons
import qs.Ui

// Where mailboxes are managed.
//
// Adding one used to drop the user on the first-run walkthrough, which by then
// had nothing left to ask: the client was connected and an account was already
// signed in, so the page showed a finished setup for the *other* mailbox and
// there was no way forward. Adding a mailbox belongs here, next to the ones
// that already exist, and signing it in happens on its own row rather than by
// sending the window somewhere else.
Column {
  id: root

  required property var service
  required property color textColor
  required property color dimColor
  required property color accentColor
  required property color urgentColor
  required property string panelFontFamily

  signal backRequested()
  signal clientSetupRequested()
  signal addRequested()
  signal editRequested(int index)
  signal colorChosen(int index, string color)
  signal mergedToggled(int index, bool merged)

  // The colours a mailbox may be given, and the only ones offered: a fixed set
  // keeps two mailboxes from being told apart by shades nobody can distinguish,
  // and keeps the choice to one click. Hues rather than theme values, because
  // this mark exists to separate accounts from each other and not to blend
  // into a surface.
  readonly property var accountColors: [
    "", "#e5534b", "#e2a03f", "#57ab5a", "#4c9ede", "#986ee2", "#d2649a"
  ]

  readonly property var accounts: service ? service.accountSummaries : []
  readonly property var auth: service ? service.auth : null

  // Which mailboxes the merged view draws from is a question only a window
  // with more than one mailbox has, so the switches appear with the second
  // account and not before.
  readonly property bool offersUnified: !!service && service.offersUnified
  readonly property int mergedCount: service ? service.mergedCount : 0

  spacing: Style.space(16)

  BackBar {
    textColor: root.textColor
    dimColor: root.dimColor
    panelFontFamily: root.panelFontFamily
    onActivated: root.backRequested()
  }

  Text {
    text: "Settings"
    color: root.textColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  // --------------------------------------------------------------- reading

  Text {
    text: "READING"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
  }

  Rectangle {
    width: parent.width
    implicitHeight: Math.max(imagesText.implicitHeight, imagesSwitch.implicitHeight)
      + Style.space(16)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.textColor, root.accentColor)

    Column {
      id: imagesText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: imagesSwitch.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: "Always show remote images"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        // The cost, in the words of what it actually tells whom. Off, the
        // reader asks about each message and the answer covers that one.
        text: "Loading an image tells its host that this address opened the "
          + "message, and when"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: imagesSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: !!root.service && root.service.alwaysShowImages
      foreground: root.textColor
      accent: root.accentColor
      onToggled: if (root.service) root.service.setAlwaysShowImages(!root.service.alwaysShowImages)
    }
  }

  // ------------------------------------------------------------- mailboxes

  Text {
    text: "MAILBOXES"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
  }

  // What the switches on the rows below do, said once here rather than on
  // every row. Shown only where there is a merged view to be in.
  Text {
    width: parent.width
    visible: root.offersUnified
    text: {
      var included = root.mergedCount
      var of = included === 1
        ? "All mailboxes is drawing from one mailbox, so it shows that mailbox on its own"
        : "All mailboxes is drawing from " + included + " of them"
      return of + ". A mailbox left out still has its own row above and in the switcher."
    }
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Column {
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: root.accounts

      Rectangle {
        id: row
        required property var modelData
        required property int index

        // Whether this mailbox's custom-colour field is showing.
        property bool customOpen: false

        width: parent.width
        implicitHeight: Math.max(rowText.implicitHeight, rowActions.implicitHeight)
          + Style.space(16)
          + (row.customOpen ? customColor.implicitHeight + Style.space(8) : 0)
        radius: Style.cornerRadius
        color: modelData.active
          ? Style.selectedFillFor(root.textColor, root.accentColor)
          : Style.normalFillFor(root.textColor, root.accentColor)

        Column {
          id: rowText
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.right: rowActions.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: row.modelData.email !== "" ? row.modelData.email : "New mailbox"
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: row.modelData.active
            elide: Text.ElideMiddle
          }

          Text {
            width: parent.width
            text: {
              if (row.modelData.error !== undefined && row.modelData.error !== "")
                return row.modelData.error
              if (!row.modelData.signedIn) return "Signed out"
              var count = row.modelData.unread
              var unread = count === 0 ? "No unread mail"
                : (count === 1 ? "1 unread message" : count + " unread messages")
              return row.modelData.active ? unread + " · showing now" : unread
            }
            color: row.modelData.error !== undefined && row.modelData.error !== ""
              ? root.urgentColor : root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // Shown only while the custom swatch is open, and under the row rather
        // than in it: a field wide enough to type a hex value into does not
        // fit beside seven swatches and two buttons.
        TextField {
          id: customColor
          visible: row.customOpen
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(6)
          width: Style.space(120)
          foreground: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
          placeholderText: "#4c9ede"
          onVisibleChanged: if (visible) {
            text = String(row.modelData.color || "")
            forceActiveFocus()
          }
          // Applied on Enter rather than per keystroke: "#4c9" is a valid
          // colour on the way to "#4c9ede", and painting it would make the
          // stripe flicker through whatever the user typed through.
          onAccepted: {
            root.colorChosen(row.index, text)
            row.customOpen = false
          }
        }

        Row {
          id: rowActions
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          // The colour this mailbox's messages are striped with in a merged
          // list. Swatches rather than a field: the value reaches a QML colour,
          // and a typed one that will not parse is an error rather than a
          // default.
          Repeater {
            model: root.accountColors

            Rectangle {
              required property var modelData
              required property int index

              readonly property bool chosen:
                String(row.modelData.color || "") === String(modelData)

              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              height: width
              radius: width / 2
              color: String(modelData) === "" ? "transparent" : String(modelData)
              // The chosen one is ringed in the foreground; the rest carry a
              // faint edge so an unpicked swatch is still a target, and so the
              // "no colour" one is visible at all.
              border.width: chosen ? Style.normalBorderWidth * 2 : Style.normalBorderWidth
              border.color: chosen
                ? root.textColor
                : Style.hoverBorderFor(root.textColor, root.accentColor)

              // "No colour" is a slash rather than an empty circle, which
              // would read as a colour this theme happens to draw as nothing.
              Rectangle {
                anchors.centerIn: parent
                visible: String(parent.modelData) === ""
                width: parent.width * 0.62
                height: Style.normalBorderWidth
                rotation: -45
                color: root.dimColor
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  row.customOpen = false
                  root.colorChosen(row.index, String(parent.modelData))
                }
              }
            }
          }

          // Any colour the six presets do not cover. Kept behind a swatch of
          // its own rather than always shown: a hex field beside every mailbox
          // is a lot of chrome for something most people set once.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(16)
            height: width
            radius: width / 2
            // Ringed like a chosen preset when the colour in use is not one of
            // them, so the row still says where its colour came from.
            readonly property bool holdsCustom: {
              var current = String(row.modelData.color || "")
              if (current === "") return false
              var presets = root.accountColors
              for (var i = 0; i < presets.length; i++) {
                if (String(presets[i]) === current) return false
              }
              return true
            }
            color: holdsCustom ? String(row.modelData.color) : "transparent"
            border.width: holdsCustom || row.customOpen
              ? Style.normalBorderWidth * 2 : Style.normalBorderWidth
            border.color: holdsCustom || row.customOpen
              ? root.textColor
              : Style.hoverBorderFor(root.textColor, root.accentColor)

            Text {
              anchors.centerIn: parent
              visible: !parent.holdsCustom
              textFormat: Text.PlainText
              text: "+"
              color: root.dimColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: row.customOpen = !row.customOpen
            }
          }

          // Whether All mailboxes draws from this one. A button rather than a
          // switch: the row already carries seven swatches and Edit, and a
          // switch wide enough to read beside them does not fit — and a button
          // can say in words which of the two states it is in.
          //
          // Taking out the second-to-last mailbox is allowed and is not an
          // error: it leaves one mailbox included, All mailboxes has nothing
          // to merge, and the window shows that mailbox on its own. Nothing is
          // hidden by it — every mailbox is still its own row in the switcher.
          IconTextButton {
            visible: root.offersUnified
            // The label says which state the mailbox is in, not what the
            // button would do: with a glyph and a fill saying the same thing
            // three ways over, a label that named the action would be the one
            // of the four that disagreed.
            iconName: row.modelData.merged === false ? "" : "check"
            text: row.modelData.merged === false ? "Not in All mailboxes" : "In All mailboxes"
            selected: row.modelData.merged !== false
            foreground: root.textColor
            accent: root.accentColor
            fontFamily: root.panelFontFamily
            tooltipText: row.modelData.merged === false
              ? "Include this mailbox in the All mailboxes view"
              : "Leave this mailbox out of the All mailboxes view"
            onClicked: root.mergedToggled(row.index, row.modelData.merged === false)
          }

          IconTextButton {
            text: "Edit..."
            foreground: root.textColor
            fontFamily: root.panelFontFamily
            tooltipText: "Edit this mailbox"
            onClicked: root.editRequested(row.index)
          }
        }
      }
    }
  }

  IconTextButton {
    iconName: "plus"
    text: "Add a mailbox..."
    foreground: root.textColor
    fontFamily: root.panelFontFamily
    tooltipText: "Add another mail account"
    onClicked: root.addRequested()
  }

  PanelSeparator {
    width: parent.width
    foreground: root.textColor
  }

  // ---------------------------------------------------------- oauth client

  Text {
    text: "GOOGLE OAUTH CLIENT"
    color: root.dimColor
    font.family: root.panelFontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(clientText.implicitHeight, clientButton.implicitHeight)

    Column {
      id: clientText
      anchors.left: parent.left
      anchors.right: clientButton.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: root.auth && root.auth.credentialsPresent
          ? root.auth.clientDescription : "No client yet"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
      }

      Text {
        width: parent.width
        // Every mailbox signs in through this one client, which is why adding
        // an account never asks for another.
        text: "Shared by every mailbox above"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    IconTextButton {
      id: clientButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.auth && root.auth.credentialsPresent ? "Change..." : "Set up..."
      foreground: root.dimColor
      fontFamily: root.panelFontFamily
      onClicked: root.clientSetupRequested()
    }
  }
}
