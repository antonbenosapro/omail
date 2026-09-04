import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Menu.js" as Menu
import "../account/Model.js" as Model

// The list's right-click menu. It is a Popup rather than a child of the row
// because the list scrolls inside a clipping Flickable, which would cut the
// menu off at the column edge.
Item {
  id: root

  required property var service
  required property color textColor
  required property color urgentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  // The row this menu was raised on, account and id together. Found by id
  // alone it was the *first* row holding that id, so in a merged list the menu
  // on the second of a colliding pair read the first one's starred and unread
  // state and acted on the first one's message.
  property string messageKey: ""
  property real anchorX: 0
  property real anchorY: 0
  property int cursorIndex: -1
  readonly property var menuRows: [replyRow, replyAllRow, forwardRow, archiveRow,
    trashRow, spamRow, readRow, starRow, browserRow]
  readonly property bool opened: menu.opened
  readonly property var summary: {
    if (!service || messageKey === "") return null
    var index = Model.indexByKey(service.messages, messageKey)
    return index < 0 ? null : service.messages[index]
  }

  signal composeRequested(string mode, string key)
  signal actionRequested(string action, string key)

  // What the row *this menu is on* can be asked to do, which is not what the
  // mailbox on screen can: a merged list holds rows from several accounts, and
  // a menu drawn from `current`'s capabilities offered Archive, Report spam
  // and Open in browser over an IMAP row because a Gmail account happened to
  // be selected.
  function can(name) {
    if (!root.service) return true
    return root.service.capabilityFor(root.messageKey, name)
  }

  // How many messages a row in this menu would act on: the whole set when the
  // menu was opened on a marked row, one otherwise. The labels read from it so
  // a menu over twelve selected messages cannot say "Archive" and mean twelve.
  readonly property int actsOn: {
    if (!root.service || root.messageKey === "") return 1
    if (!Model.menuActsOnSet(root.service.markedKeys, root.messageKey)) return 1
    return Math.max(1, root.service.markedCount)
  }

  anchors.fill: parent
  z: 50

  function openAt(key, sceneX, sceneY) {
    root.messageKey = String(key || "")
    if (!root.summary) return
    var local = root.mapFromGlobal(sceneX, sceneY)
    anchorX = local.x
    anchorY = local.y
    menu.open()
  }

  function place() {
    if (!menu.visible) return
    var tall = menu.height > 0 ? menu.height : menu.implicitHeight
    var placed = Menu.position(anchorX, anchorY, menu.width, tall, root.width, root.height)
    menu.x = placed.x
    menu.y = placed.y
  }

  function selectableRows() {
    var values = []
    for (var i = 0; i < menuRows.length; i++) values.push({
      selectable: true, visible: menuRows[i].visible, enabled: menuRows[i].enabled
    })
    return values
  }
  function moveCursor(step) { cursorIndex = Menu.nextSelectable(selectableRows(), cursorIndex, step) }
  function runCursor() { if (cursorIndex >= 0) menuRows[cursorIndex].activated() }

  function close() { menu.close() }

  function run(action) {
    var key = root.messageKey
    menu.close()
    root.actionRequested(action, key)
  }

  function compose(mode) {
    var key = root.messageKey
    menu.close()
    root.composeRequested(mode, key)
  }

  QQC.Popup {
    id: menu
    width: Style.space(200)
    implicitHeight: rows.implicitHeight + Style.space(8)
    padding: Style.space(4)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: {
      root.cursorIndex = Menu.firstSelectable(root.selectableRows())
      root.place()
    }
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: Column {
      id: rows
      spacing: Style.space(2)

      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          root.moveCursor(1); event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          root.moveCursor(-1); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_O) {
          root.runCursor(); event.accepted = true
        }
      }

      MenuRow { id: replyRow; text: "Reply"; onActivated: root.compose("reply") }
      MenuRow { id: replyAllRow; text: "Reply all"; onActivated: root.compose("replyAll") }
      MenuRow { id: forwardRow; text: "Forward"; onActivated: root.compose("forward") }

      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      // Hidden rather than disabled where the provider has no such verb. IMAP
      // archives by moving to a folder that may not exist, and has no junk
      // verb the server learns anything from — a "Report spam" that quietly
      // meant "move to a folder" would be a promise this cannot keep.
      MenuRow {
        id: archiveRow
        visible: root.can("archive")
        text: Model.menuActionLabel("Archive", root.actsOn)
        onActivated: root.run("archive")
      }
      MenuRow {
        id: trashRow
        text: Model.menuActionLabel("Move to trash", root.actsOn)
        tone: root.urgentColor
        onActivated: root.run("trash")
      }
      MenuRow {
        id: spamRow
        visible: root.can("spam")
        text: "Report spam"
        tone: root.urgentColor
        onActivated: root.run("spam")
      }

      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      MenuRow {
        id: readRow
        text: root.summary && root.summary.unread ? "Mark as read" : "Mark as unread"
        onActivated: root.run(root.summary && root.summary.unread ? "markRead" : "markUnread")
      }
      MenuRow {
        id: starRow
        visible: root.can("star")
        text: root.summary && root.summary.starred ? "Unstar" : "Star"
        onActivated: root.run(root.summary && root.summary.starred ? "unstar" : "star")
      }

      MenuSeparatorLine {
        width: menu.width - menu.leftPadding - menu.rightPadding
        lineColor: root.textColor
      }

      // Only where there is a web mailbox to open. An IMAP account has no
      // address this plugin could know.
      MenuRow {
        id: browserRow
        visible: root.can("openOnWeb")
        text: "Open in browser..."
        tone: root.dimColor
        onActivated: {
          var key = root.messageKey
          menu.close()
          if (root.service) root.service.openInBrowser(key)
        }
      }
    }
  }

  component MenuRow: MenuActionRow {
    width: menu.width - menu.leftPadding - menu.rightPadding
    textColor: root.textColor
    panelFontFamily: root.panelFontFamily
    collection: root.menuRows
    cursorIndex: root.cursorIndex
  }
}
