import QtQuick
import QtQuick.Controls
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../message/Message.js" as Mail
import "../message/Draft.js" as Draft

// Composing takes over the whole content area of the one window rather than
// opening a second one: Omarchy's panel mechanism would give an extra window
// its own region, which is not what a reply is. Two mail accounts would
// justify two windows; a reply does not.
//
// Compose, reply, reply-all and forward are the same form with different
// starting values, so `begin()` fills the fields and everything after that is
// one code path.
Item {
  id: root

  required property var service
  required property color textColor
  required property color backgroundColor
  required property color accentColor
  required property color dimColor
  required property color dimmerColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  readonly property int formInset: Style.space(18)
  readonly property int formLabelWidth: Style.space(52)
  readonly property int formLabelGap: Style.space(10)

  property bool opened: false
  property string mode: "new"
  property string threadId: ""
  property string inReplyTo: ""
  // The parent's References, which the reply extends with the parent itself.
  property string references: ""
  property bool ccVisible: false
  property string fromEmail: ""
  property var replyRecipients: []
  property bool fromWasChosen: false

  // ----------------------------------------------------------- the draft
  //
  // What the server holds of this compose, and whether the window has moved
  // on from it. `draftId` is the copy a save replaces and a send removes —
  // Gmail's draft id, or the IMAP message id of the copy last stored.
  // `draftAccount` is the mailbox it lives in, held rather than followed: the
  // compose's account is whichever is on screen once this closes, and a save
  // landing after that must still reach the right one.
  property string draftId: ""
  property string draftToken: ""
  property string draftAccount: ""
  // The fields as they stood when the compose was filled in or last saved.
  // Dirty is "differs from this", not "has text in it": a reply opens with a
  // quote nobody has written yet.
  property string baseline: ""
  property bool draftSaving: false
  // Close once the save in flight lands — Escape on a compose with something
  // in it keeps it rather than throwing it away.
  property bool closeAfterSave: false
  // Send was pressed while a save was in the air. The send waits for it and
  // goes out as the copy that save stored: sent at once, it would name the
  // copy before, and the one landing after would be a draft of a message
  // already gone.
  property bool sendAfterSave: false
  property bool confirmingDiscard: false
  property string draftNotice: ""
  // Bumped whenever the compose is emptied, so a save answering for a compose
  // that has since been sent or discarded can tell it is too late.
  property int session: 0

  readonly property string currentSnapshot: snapshotNow()
  readonly property bool dirty: opened && currentSnapshot !== baseline
  readonly property bool canDraft: !!service && service.canDraft
  readonly property bool sendingNow: sendAfterSave
    || (!!service && (service.composeSending || service.sending))

  readonly property var fromAliases: {
    if (!root.service || !Array.isArray(root.service.sendAsAliases)) return []
    return root.service.sendAsAliases
  }

  readonly property string title: {
    if (mode === "reply") return "Reply"
    if (mode === "replyAll") return "Reply all"
    if (mode === "forward") return "Forward"
    if (mode === "draft") return "Draft"
    return "New message"
  }

  function reset() {
    autosave.stop()
    session++
    draftId = ""
    draftToken = ""
    draftAccount = ""
    draftSaving = false
    closeAfterSave = false
    sendAfterSave = false
    confirmingDiscard = false
    draftNotice = ""
    fromMenu.close()
    toField.text = ""
    ccField.text = ""
    subjectField.text = ""
    bodyEdit.text = ""
    mode = "new"
    threadId = ""
    inReplyTo = ""
    references = ""
    ccVisible = false
    fromEmail = ""
    replyRecipients = []
    fromWasChosen = false
  }

  function selectPreferredFrom() {
    var choice = root.service ? root.service.preferredSendAs(replyRecipients) : null
    fromEmail = choice ? String(choice.email || "") : ""
  }

  function chooseFrom(email) {
    fromEmail = String(email || "")
    fromWasChosen = true
    fromMenu.close()
  }

  function placeFromMenu() {
    if (!fromMenu.visible) return
    var global = fromButton.mapToGlobal(0, 0)
    var at = root.mapFromGlobal(global.x, global.y)
    var tall = fromMenu.height > 0 ? fromMenu.height : fromMenu.implicitHeight
    var x = Math.max(0, Math.min(at.x, root.width - fromMenu.width))
    var y = at.y + fromButton.height
    if (y + tall > root.height) y = at.y - tall
    if (y + tall > root.height) y = root.height - tall
    if (y < 0) y = 0
    fromMenu.x = x
    fromMenu.y = y
  }

  // Everyone on the original, To and Cc, except whoever the reply already goes
  // To and this mailbox under any of its addresses. "This mailbox" is the one
  // that received the message, not the one on screen — stripping the wrong
  // address left the replier on their own reply-all and dropped somebody who
  // belonged on it.
  function otherRecipients(summary) {
    var own = [root.service ? root.service.composeEmail : ""].concat(root.fromAliases)
    return Mail.replyAllCc(summary, own).join(", ")
  }

  function begin(nextMode, summary, bodyText) {
    reset()
    mode = String(nextMode || "new")
    opened = true

    if (summary && mode !== "new") {
      var replyTo = summary.replyTo && summary.replyTo.email
        ? summary.replyTo.email : summary.from.email
      threadId = summary.threadId
      inReplyTo = summary.messageId
      references = String(summary.references || "")
      // Cc as well as To: an alias is just as often the address a thread
      // copied you on as the one it was sent to, and answering from the
      // account's default instead is how a thread ends up split in two.
      if (mode === "reply" || mode === "replyAll") {
        replyRecipients = (Array.isArray(summary.to) ? summary.to : [])
          .concat(Array.isArray(summary.cc) ? summary.cc : [])
      }

      if (mode === "forward") {
        subjectField.text = Mail.forwardSubject(summary.subject)
      } else {
        toField.text = replyTo
        subjectField.text = Mail.replySubject(summary.subject)
        if (mode === "replyAll") {
          ccField.text = otherRecipients(summary)
          ccVisible = ccField.text !== ""
        }
      }
      bodyEdit.text = "\n\n" + Mail.quoteBody(summary, String(bodyText || ""))
    }

    selectPreferredFrom()
    startDraft("")

    // Focus is not placed here. Opening this changes the window's key context,
    // and the context is what moves the keyboard — one mechanism, so the two
    // cannot disagree about where the typing goes.
  }

  // Read straight off the fields rather than through the binding above, so a
  // value taken just after the fields were filled is the filled one.
  function snapshotNow() {
    return Draft.snapshot({
      from: root.fromEmail, to: toField.text, cc: ccField.text,
      subject: subjectField.text, body: bodyEdit.text
    })
  }

  // The draft this compose saves to, and the state it is compared against.
  // Called once the fields are filled, so an untouched compose is clean.
  function startDraft(token) {
    draftToken = Draft.token(token) || Draft.newToken(Date.now(), Math.random())
    draftAccount = root.service ? root.service.composeAccountId : ""
    baseline = snapshotNow()
  }

  // A saved draft, back in the window. Its threading headers come with it, so
  // a reply begun yesterday still threads under the message it answers.
  function beginDraft(fields) {
    var values = fields || ({})
    reset()
    mode = "draft"
    opened = true
    toField.text = String(values.to || "")
    ccField.text = String(values.cc || "")
    ccVisible = ccField.text !== ""
    subjectField.text = String(values.subject || "")
    bodyEdit.text = String(values.body || "")
    threadId = String(values.threadId || "")
    inReplyTo = String(values.inReplyTo || "")
    // Declared with the rest of the threading state; a draft that answered a
    // deep thread keeps the whole chain rather than only its parent.
    references = String(values.references || "")
    var stored = String(values.from || "")
    // The address it was written from, when this account may still send as
    // it; otherwise the same choice a new message would make.
    if (stored !== "" && root.fromAliases.some(function(alias) {
          return String(alias.email || "").toLowerCase() === stored.toLowerCase()
        })) {
      fromEmail = stored
      fromWasChosen = true
    } else {
      selectPreferredFrom()
    }
    startDraft(values.token)
    draftId = String(values.draftId || "")
  }

  // Where the keyboard goes when composing becomes the context. A reply starts
  // in the body above the quote; a new message starts at the address.
  function takeFocus() {
    if (mode === "draft" && toField.text !== "") {
      bodyEdit.forceActiveFocus()
      bodyEdit.cursorPosition = 0
    } else if (mode === "reply" || mode === "replyAll") {
      bodyEdit.forceActiveFocus()
      bodyEdit.cursorPosition = 0
    } else {
      toField.forceActiveFocus()
    }
  }

  // Every way out of a draft: this view's own Back, Discard, the window's
  // Escape, and the send that succeeded. The window is told because only the
  // window knows where the draft was raised from.
  signal closed()

  function finish() {
    reset()
    opened = false
    closed()
  }

  function fields() {
    return ({
      from: root.fromEmail,
      to: toField.text,
      cc: ccField.text,
      subject: subjectField.text,
      body: bodyEdit.text,
      threadId: root.mode === "forward" ? "" : root.threadId,
      inReplyTo: root.mode === "forward" ? "" : root.inReplyTo,
      references: root.mode === "forward" ? "" : root.references
    })
  }

  // Stores what the window holds. Never while a send is in flight: the send is
  // what this compose is becoming, and a copy landing after it would be a
  // draft of a message already gone.
  function saveDraft() {
    if (!service || !canDraft || draftSaving || sendingNow) return
    if (!dirty) {
      if (closeAfterSave) finish()
      return
    }
    autosave.stop()
    var serial = session
    var snap = snapshotNow()
    var account = draftAccount
    var replacing = draftId
    draftSaving = true
    draftNotice = "Saving draft"
    service.saveDraft(account, replacing, draftToken, fields(), function(result, error) {
      if (!root) return
      if (serial !== root.session) {
        // The compose was sent or discarded while this was in the air, so the
        // copy it stored is one nobody wants. Only a copy this save created:
        // an update of the same Gmail draft is already accounted for by the
        // send or the discard that closed the window.
        var stored = result ? String(result.id || "") : ""
        if (stored !== "" && stored !== replacing && root.service)
          root.service.deleteDraft(account, stored)
        return
      }
      root.draftSaving = false
      var sendNext = root.sendAfterSave
      root.sendAfterSave = false
      if (error) {
        // The window stays open with the words still in it. Closing it would
        // be the data loss this exists to prevent.
        root.closeAfterSave = false
        root.draftNotice = "Draft not saved: " + error
        // A failed save left the copy before it in place, and `draftId` still
        // names that one, so the send removes it as it goes.
        if (sendNext) root.submit()
        return
      }
      if (result && result.id) root.draftId = String(result.id)
      root.baseline = snap
      root.draftNotice = "Draft saved"
      if (sendNext) {
        // Sent as the copy just stored. A send that fails leaves it in Drafts.
        root.submit()
      } else if (root.closeAfterSave) {
        // Anything typed while the save was in the air goes too.
        if (root.dirty) root.saveDraft()
        else root.finish()
      } else if (root.dirty) {
        autosave.restart()
      }
    })
  }

  // The one way out of a compose that is not a send: Escape, Back, and
  // anything else in the window that leaves it. Answers whether the compose
  // closed now — false when it is saving first, asking first, or sending.
  function leave() {
    if (confirmingDiscard) {
      // Escape on the question is "no": keep writing.
      confirmingDiscard = false
      return false
    }
    var plan = Draft.closePlan({ sending: sendingNow, saving: draftSaving, dirty: dirty,
      canDraft: canDraft })
    if (plan === "ignore") return false
    if (plan === "close") {
      finish()
      return true
    }
    if (plan === "confirm") {
      confirmingDiscard = true
      return false
    }
    closeAfterSave = true
    if (plan === "save") saveDraft()
    return false
  }

  // Throwing the message away, which is asked about first whenever there is
  // something to lose — and which takes the saved draft with it.
  function discard() {
    var plan = Draft.discardPlan({ sending: sendingNow, dirty: dirty, saved: draftId !== "" })
    if (plan === "ignore") return
    if (plan === "close") finish()
    else confirmingDiscard = true
  }

  function confirmDiscard() {
    if (sendingNow) return
    var id = draftId
    var account = draftAccount
    if (id !== "" && service) service.deleteDraft(account, id)
    finish()
  }

  function submit() {
    if (!service) return
    autosave.stop()
    confirmingDiscard = false
    if (draftSaving) {
      sendAfterSave = true
      return
    }
    service.send(({
      from: root.fromEmail,
      to: toField.text,
      cc: ccField.text,
      subject: subjectField.text,
      body: bodyEdit.text,
      // A forward starts a new conversation; a reply must stay in the old one.
      threadId: root.mode === "forward" ? "" : root.threadId,
      inReplyTo: root.mode === "forward" ? "" : root.inReplyTo,
      references: root.mode === "forward" ? "" : root.references,
      // A saved draft is sent as itself, so it leaves Drafts as it goes — but
      // only through the mailbox it was saved in. A compose whose account
      // changed under it sends plainly and leaves that draft where it is.
      draftId: root.service.composeAccountId === root.draftAccount ? root.draftId : ""
    }))
  }

  anchors.fill: parent
  // Only while it is actually in use. A component that declares `focus: true`
  // owns the window's focus even when invisible — Qt does not exclude hidden
  // items — and an owner that accepts keys is a sink. This swallowed every
  // Escape in the window, which is why Esc looked intermittent: whether it
  // worked depended on where the user had last clicked.
  focus: root.opened

  onFromAliasesChanged: {
    if (!opened || fromWasChosen) return
    // The account's aliases arriving is not the user writing anything, so a
    // compose that was clean stays clean.
    var clean = !dirty
    selectPreferredFrom()
    if (clean) baseline = snapshotNow()
  }

  // Saved a moment after typing pauses, rather than on every key. Compared
  // here rather than read off `dirty`, whose own binding may not have caught
  // up with this change yet.
  onCurrentSnapshotChanged: {
    if (opened && currentSnapshot !== baseline && canDraft && !draftSaving && !sendingNow)
      autosave.restart()
  }

  Timer {
    id: autosave
    interval: Draft.AUTOSAVE_MS
    repeat: false
    onTriggered: root.saveDraft()
  }

  // ----------------------------------------------------------- header
  //
  // One compact title band. Back is the exit path and the title names the
  // draft; splitting them into two stacked bands gave one short decision the
  // hierarchy of a whole settings page.
  Item {
    id: head
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: Style.space(44)

    BackBar {
      id: backBar
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      textColor: root.textColor
      dimColor: root.dimColor
      panelFontFamily: root.panelFontFamily
      onActivated: root.leave()
    }

    Row {
      id: titleRow
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      PanelSectionHeader {
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        foreground: root.textColor
        fontFamily: root.panelFontFamily
      }
    }

    PanelSeparator {
      anchors.bottom: parent.bottom
      width: parent.width
      foreground: root.textColor
    }
  }

  // ----------------------------------------------------------- fields
  //
  // A label column wide enough for the longest of To / Cc / Subject keeps
  // the three inputs aligned without a grid.

  Column {
    id: fields
    anchors.top: head.bottom
    anchors.left: parent.left
    anchors.right: parent.right

    Item {
      width: parent.width
      implicitHeight: fromButton.implicitHeight + Style.space(14)

      Text {
        id: fromLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "From"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
      }

      // Sized to the address rather than to the row: a full-width trigger puts
      // the chevron a screen away from the name it belongs to. The extra width
      // is the room the chevron is drawn into, over the button's own trailing
      // padding, so the two read as one control.
      Button {
        id: fromButton
        readonly property real trailing: root.fromAliases.length > 1
          ? Style.font.iconSmall + Style.spacing.controlGap : 0

        anchors.left: fromLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth + trailing,
          parent.width - fromLabel.width - Style.space(46))
        text: root.fromEmail
        foreground: root.textColor
        accent: root.accentColor
        background: Style.normalFillFor(root.textColor, root.accentColor)
        bordered: true
        fontFamily: root.panelFontFamily
        fontSize: Style.font.bodySmall
        verticalPadding: Style.spacing.inputPaddingY
        leftAlign: true
        selected: fromMenu.opened
        enabled: root.fromAliases.length > 1
        onClicked: fromMenu.opened ? fromMenu.close() : fromMenu.open()

        // The kit's own chevron is a font glyph, which at this size renders
        // thinner than every other mark in the window. This is the app's drawn
        // set, at the size the rest of the icons use.
        ActionIcon {
          anchors.right: parent.right
          anchors.rightMargin: fromButton.horizontalPadding
          anchors.verticalCenter: parent.verticalCenter
          visible: root.fromAliases.length > 1
          name: "chevronDown"
          iconSize: Style.font.iconSmall
          color: root.dimColor
        }
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      width: parent.width
      // The field plus the same breathing room it carries inside itself, so
      // its border is not crowded against the rules above and below. Derived
      // rather than a fixed height: the field grows with the theme's font
      // scale, and a fixed row would scale that growth a second time.
      implicitHeight: toField.implicitHeight + Style.space(14)

      Text {
        id: toLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "To"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
      }

      Button {
        id: ccToggle
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        text: "Cc"
        foreground: root.ccVisible ? root.textColor : root.dimColor
        bordered: false
        fontSize: Style.font.caption
        onClicked: root.ccVisible = !root.ccVisible
      }

      TextField {
        id: toField
        anchors.left: toLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: ccToggle.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        placeholderText: "recipient@example.com"
        onAccepted: subjectField.forceActiveFocus()
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      visible: root.ccVisible
      width: parent.width
      // The field plus the same breathing room it carries inside itself, so
      // its border is not crowded against the rules above and below. Derived
      // rather than a fixed height: the field grows with the theme's font
      // scale, and a fixed row would scale that growth a second time.
      implicitHeight: ccField.implicitHeight + Style.space(14)

      Text {
        id: ccLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Cc"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: ccField
        anchors.left: ccLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        onAccepted: subjectField.forceActiveFocus()
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }

    Item {
      width: parent.width
      // The field plus the same breathing room it carries inside itself, so
      // its border is not crowded against the rules above and below. Derived
      // rather than a fixed height: the field grows with the theme's font
      // scale, and a fixed row would scale that growth a second time.
      implicitHeight: subjectField.implicitHeight + Style.space(14)

      Text {
        id: subjectLabel
        anchors.left: parent.left
        anchors.leftMargin: root.formInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.formLabelWidth
        horizontalAlignment: Text.AlignRight
        text: "Subject"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: subjectField
        anchors.left: subjectLabel.right
        anchors.leftMargin: root.formLabelGap
        anchors.right: parent.right
        anchors.rightMargin: Style.space(18)
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        placeholderText: "Subject"
        onAccepted: bodyEdit.forceActiveFocus()
      }

      PanelSeparator {
        anchors.bottom: parent.bottom
        width: parent.width
        foreground: root.textColor
      }
    }
  }

  QQC.Popup {
    id: fromMenu
    width: Math.min(Style.space(360), root.width - Style.space(36))
    implicitHeight: Math.min(fromRows.implicitHeight + Style.space(8), Style.space(260))
    padding: Style.space(4)
    modal: false
    focus: opened
    z: 50
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.placeFromMenu()
    onOpened: root.placeFromMenu()
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: ListView {
      id: fromRows
      implicitHeight: contentHeight
      clip: true
      model: root.fromAliases

      delegate: Rectangle {
        id: fromRow
        required property var modelData

        width: fromMenu.width - fromMenu.leftPadding - fromMenu.rightPadding
        implicitHeight: Style.space(42)
        radius: Style.cornerRadius
        color: root.fromEmail.toLowerCase() === String(modelData.email || "").toLowerCase()
          ? Style.selectedFillFor(root.textColor, root.accentColor)
          : (fromHover.hovered
            ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")

        Column {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(9)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(9)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: String(fromRow.modelData.email || "")
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: root.fromEmail.toLowerCase()
              === String(fromRow.modelData.email || "").toLowerCase()
            elide: Text.ElideMiddle
          }

          Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: String(fromRow.modelData.displayName || "")
            color: root.dimColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        HoverHandler { id: fromHover }
        TapHandler { onTapped: root.chooseFrom(fromRow.modelData.email) }
      }
    }
  }

  // ------------------------------------------------------------- body
  //
  // The kit has no multi-line field, so this is a TextEdit on the plain
  // window ground; the rows above already carry the structure.
  Flickable {
    id: bodyFlick
    anchors.top: fields.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: actions.top
    anchors.leftMargin: Style.space(18)
    anchors.rightMargin: Style.space(18)
    anchors.topMargin: Style.space(12)
    contentWidth: width
    contentHeight: bodyEdit.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    TextEdit {
      id: bodyEdit
      width: bodyFlick.width
      // Tall enough to fill the visible area even when the draft is short.
      // A TextEdit sized to its text leaves the space below it belonging to
      // the Flickable, so clicking into the empty part of a mostly-empty
      // message does nothing at all.
      height: Math.max(implicitHeight, bodyFlick.height)
      selectByMouse: true
      wrapMode: TextEdit.Wrap
      textFormat: TextEdit.PlainText
      color: root.textColor
      selectionColor: Style.selectionFillFor(root.textColor, root.accentColor)
      selectedTextColor: root.textColor
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // ---------------------------------------------------------- actions

  Item {
    id: actions
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: Style.space(52)

    PanelSeparator {
      anchors.top: parent.top
      width: parent.width
      foreground: root.textColor
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(18)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      visible: !root.confirmingDiscard

      IconTextButton {
        iconName: "send"
        tooltipText: "Send · Ctrl+Enter"
        text: root.sendAfterSave || (root.service && root.service.sending) ? "Sending" : "Send"
        foreground: root.textColor
        fontFamily: root.panelFontFamily
        enabled: !!root.service && !root.service.sending && !root.sendAfterSave
        onClicked: root.submit()
      }

      Button {
        text: "Discard"
        foreground: root.dimColor
        bordered: false
        fontSize: Style.font.bodySmall
        enabled: !root.sendingNow
        onClicked: root.discard()
      }
    }

    // The question, asked where the button was rather than in a dialog of its
    // own. Escape answers it "keep editing", which is the answer that loses
    // nothing.
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(18)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      visible: root.confirmingDiscard

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.draftId !== "" ? "Discard this draft and delete it from Drafts?"
          : root.canDraft ? "Discard this message?"
          : "This mailbox cannot keep drafts. Discard this message?"
        color: root.textColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        text: "Discard"
        foreground: root.textColor
        bordered: true
        fontSize: Style.font.bodySmall
        onClicked: root.confirmDiscard()
      }

      Button {
        text: "Keep editing"
        foreground: root.dimColor
        bordered: false
        fontSize: Style.font.bodySmall
        onClicked: root.confirmingDiscard = false
      }
    }

    // What became of the last save. Words, not a colour: a failed save is
    // the one state here somebody has to act on.
    Text {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(18)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width / 2)
      visible: !root.confirmingDiscard && root.draftNotice !== ""
      textFormat: Text.PlainText
      text: root.draftNotice
      color: root.dimColor
      elide: Text.ElideRight
      font.family: root.panelFontFamily
      font.pixelSize: Style.font.caption
    }
  }

}
