import QtQuick
import Quickshell
import Quickshell.Io
import "account"

import "account/Accounts.js" as Accounts
import "account/Model.js" as Model
import "providers/Registry.js" as Provider

// Every mailbox on this machine, and whichever one is on screen.
//
// The window and the bar widget were written against a single mailbox, so this
// keeps that shape: it owns one MailAccount per account and forwards the whole
// surface to the active one. The alternative — teaching every view to say
// `service.current.messages` — spreads the account model across two dozen
// files for no gain.
//
// Every account polls its unread count. Only the active one loads lists and
// bodies: a badge that speaks for one mailbox while you have three is worse
// than no badge, but fetching mail nobody can see is just spent quota.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Injected by the shell when it constructs the service singleton. Nothing
  // else is handed over, which is why settings arrive later from the bar
  // widget rather than as a property binding.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "omamail"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : ""

  readonly property var defaultSettingValues: ({
    refreshIntervalSec: 120,
    maxMessages: 25,
    defaultQuery: "in:inbox",
    notifyNewMail: "On",
    oauthPort: 9481
  })
  property var settings: defaultSettingValues

  function applySettings(values) {
    var next = ({})
    for (var key in defaultSettingValues) next[key] = defaultSettingValues[key]
    var source = values || ({})
    for (var name in source) {
      if (source[name] === undefined || source[name] === null) continue
      next[name] = source[name]
    }
    if (JSON.stringify(next) !== JSON.stringify(settings)) settings = next
  }

  // ---------------------------------------------------------- the accounts

  property var accountList: Accounts.emptyList()
  property bool accountsLoaded: false
  property string accountsWritePayload: ""

  readonly property int accountCount: Accounts.count(accountList)
  readonly property bool hasSavedAccounts: Accounts.hasSavedAccounts(accountList)
  readonly property string activeAccountId: accountList ? accountList.activeId : ""

  // Every mailbox at once. The hosts all exist and all poll already; this
  // decides whether more than one of them loads a list, and whether `messages`
  // is one account's or all of them merged.
  readonly property bool unified: Accounts.isUnified(accountList)

  // The instance whose mailbox is on screen. Everything below forwards to it.
  property var current: null

  // A mailbox that has not signed in yet has no address, and the id every
  // account is addressed by *is* its address — so a half-added account cannot
  // be named by activeId at all. Position is what addresses it until it learns
  // its own name. Not persisted: a pending account that survives a restart is
  // just a row waiting to be signed in, and the window should come back to the
  // mailbox that actually has mail in it.
  property int activeIndex: -1

  function accountAt(index) {
    return accountHosts.objectAt(index)
  }

  function findAccount(id) {
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host && host.accountId === String(id)) return host
    }
    return null
  }

  function refreshCurrent() {
    var next = activeIndex >= 0 && activeIndex < accountHosts.count
      ? accountHosts.objectAt(activeIndex)
      : findAccount(activeAccountId)
    // A pending account has no id yet, so fall back to position: without this
    // a half-added mailbox could never be the one on screen, and setup would
    // have nothing to run in.
    if (!next && accountHosts.count > 0) next = accountHosts.objectAt(0)

    // The one line the unified view turns on. Every account is instantiated
    // and polling its unread count either way; `active` is what decides
    // whether it also loads a list, so unified means all of them do.
    var everyone = root.unified
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (!host) continue
      host.active = everyone || host === next
      if (everyone) host.windowOpen = windowOpen
    }

    // `current` stays the mailbox the window would come back to, and is what
    // compose, sign-in and the settings page still speak to. What it is not,
    // while unified, is the owner of the message being read — that is resolved
    // per message by `hostForMessage`.
    if (next === current) return
    current = next
    if (current) current.windowOpen = windowOpen
  }

  // The whole point of switching is that it is instant, which it is because
  // each account keeps its own cache on disk.
  function switchTo(id) {
    if (String(id) === activeAccountId && activeIndex < 0 && !root.unified) return
    activeIndex = -1
    accountList = Accounts.setUnified(Accounts.setActive(accountList, id), false)
    saveAccounts()
    clearSelection()
    refreshCurrent()
  }

  // Every mailbox at once, or back to the one `activeId` still names.
  function setAccountColor(index, color) {
    var next = Accounts.setColorAt(accountList, index, color)
    if (next === accountList) return
    accountList = next
    saveAccounts()
  }

  function showUnified() {
    if (root.unified) return
    activeIndex = -1
    accountList = Accounts.setUnified(accountList, true)
    saveAccounts()
    clearSelection()
    // Inbox and Unread are the only mailboxes a merged list offers: they are
    // the two every provider maps the same way. A mailbox that resolves to a
    // different folder per server, or is missing on one, would quietly draw
    // from fewer accounts than the user thinks.
    if (!Model.isUnifiedMailbox(mailboxKey)) selectMailbox("inbox")
    refreshCurrent()
    refresh()
  }

  // The switcher selects by position, because that is the only handle a mailbox
  // without an address has.
  function switchToIndex(index) {
    var accounts = accountList ? accountList.accounts : []
    if (index < 0 || index >= accounts.length) return
    if (accounts[index].id !== "") {
      switchTo(accounts[index].id)
      return
    }
    activeIndex = index
    refreshCurrent()
  }

  // The provider is chosen before the row exists, because it decides which
  // setup page the new row opens into — and, for Gmail, whether it can borrow
  // the OAuth client an existing account already set up.
  function addAccount(provider) {
    accountList = Accounts.add(accountList, ({
      email: "", clientId: "", clientSecret: "",
      provider: provider || Provider.DEFAULT_ID
    }))
    // This row is working state for the form, not an account yet. Persisting
    // it here leaves a "New account" behind when Back cancels Add; the first
    // successful configureAccount call is what saves it.
    // Switching to it is the whole point, and it has to happen before the page
    // opens: without this the setup page ran against whichever mailbox was
    // already on screen, so adding an account showed the *existing* account's
    // finished setup and there was no way through to signing a new one in.
    activeIndex = accountCount - 1
    refreshCurrent()
    accountAdded()
  }

  function discardCurrentDraft() {
    var index = activeIndex >= 0 ? activeIndex : indexOfActiveAccount()
    var next = Accounts.discardDraftAt(accountList, index)
    if (Accounts.count(next) === accountCount) return
    activeIndex = -1
    accountList = next
    refreshCurrent()
  }

  function removeAccount(id) {
    activeIndex = -1
    accountList = Accounts.remove(accountList, id)
    saveAccounts()
    refreshCurrent()
  }

  function removeAccountAt(index) {
    activeIndex = -1
    accountList = Accounts.removeAt(accountList, index)
    saveAccounts()
    refreshCurrent()
  }

  // An account learns its own address on its first profile read; until then the
  // list has a nameless row that nothing can select.
  function nameAccount(index, email) {
    var accounts = accountList.accounts
    if (index < 0 || index >= accounts.length) return
    // The id depends on the provider as well as the address — one address may
    // be a Gmail account and an IMAP account at once — so the entry's own
    // provider decides what it is about to be called.
    var named = Accounts.accountId(email, accounts[index].provider)
    if (accounts[index].id === named) return

    // Two rows cannot hold one address. Rebuilding the list would fold them
    // together and take the row being added with it, which read as the add
    // silently undoing itself. A mailbox that is already here is a duplicate,
    // not a rename, and the row that has to go is the new one.
    for (var d = 0; d < accounts.length; d++) {
      if (d === index || accounts[d].id !== named) continue
      activeIndex = -1
      accountList = Accounts.removeAt(accountList, index)
      saveAccounts()
      refreshCurrent()
      duplicateAccount(email)
      return
    }

    var updated = Accounts.emptyList()
    updated.activeId = accountList.activeId
    for (var i = 0; i < accounts.length; i++) {
      // Everything but the address is carried over rather than listed field by
      // field: a rebuild that names the fields it keeps silently drops the ones
      // added afterwards, which is how an IMAP account would come back as a
      // Gmail one the first time it learned its own name.
      updated = Accounts.add(updated, i === index
        ? withEmail(accounts[i], email) : accounts[i])
    }
    if (updated.activeId === "" || activeIndex === index)
      updated = Accounts.setActive(updated, named)
    if (activeIndex === index) activeIndex = -1
    accountList = updated
    saveAccounts()
  }

  function withEmail(entry, email) {
    var next = {}
    for (var key in entry) next[key] = entry[key]
    next.email = email
    return next
  }

  // What the IMAP setup form saves: the address, the servers, and which
  // provider this row is. Written before the password is tried, so a mailbox
  // that fails to sign in still has its settings to correct rather than an
  // empty form to fill in again.
  function configureAccount(index, values) {
    var accounts = accountList.accounts
    if (index < 0 || index >= accounts.length) return
    var raw = values || ({})

    var entry = {}
    for (var key in accounts[index]) entry[key] = accounts[index][key]
    if (raw.provider !== undefined) entry.provider = raw.provider
    if (raw.email !== undefined) entry.email = raw.email
    if (raw.imap !== undefined) entry.imap = raw.imap
    if (raw.label !== undefined) entry.label = raw.label

    var updated = Accounts.emptyList()
    updated.activeId = accountList.activeId
    for (var i = 0; i < accounts.length; i++)
      updated = Accounts.add(updated, i === index ? entry : accounts[i])

    var id = Accounts.accountId(entry.email, entry.provider)
    if (id !== "" && (updated.activeId === "" || activeIndex === index))
      updated = Accounts.setActive(updated, id)
    if (activeIndex === index) activeIndex = -1
    accountList = updated
    saveAccounts()
    refreshCurrent()
  }

  // A save that arrives while one is already running is queued, never dropped.
  // Dropping it is what made adding a mailbox undo itself: the new account was
  // never written, and the watcher then read the older file back over it.
  property bool accountsSaveQueued: false

  function saveAccounts() {
    if (!accountsLoaded) return
    if (accountsWriter.running) {
      accountsSaveQueued = true
      return
    }
    accountsSaveQueued = false
    accountsWritePayload = Accounts.serialize(accountList)
    accountsWriter.command = [pluginDir + "/scripts/config-store.sh", "accounts.json"]
    accountsWriter.running = true
  }

  function applyAccounts(raw) {
    var loaded = Accounts.load(raw)
    // First run, or an install that predates several accounts: one nameless
    // row so the existing credentials file still has somewhere to live.
    if (Accounts.count(loaded) === 0)
      loaded = Accounts.add(loaded, ({ email: "", clientId: "", clientSecret: "" }))
    // Reading back our own write must change nothing. The list is watched so
    // that an edit from outside is picked up, but every save triggers that
    // watch — and reassigning the list re-derives every account's id, which
    // resets its cache and its session. That is what made adding a mailbox
    // flicker through several states: the window was rebuilding every account
    // each time the file it had just written landed back.
    if (accountsLoaded && Accounts.serialize(loaded) === Accounts.serialize(accountList))
      return
    // What is on disk is behind what is in memory until the pending write
    // lands, so a reload now would be a straight revert.
    if (accountsWriter.running || accountsSaveQueued) return
    accountList = loaded
    accountsLoaded = true
  }

  signal accountAdded()

  // ------------------------------------------------------ window preferences
  //
  // Kept beside the account list rather than in plugin settings: those are
  // pushed in from the bar widget and are not the window's to write. Only what
  // the window cannot recompute lives here.

  property bool sidebarCollapsed: false
  // Somebody who needed the text bigger needs it bigger for their mail, not for
  // the message that made them reach for it. The same goes for reading it as
  // plain text: that is a way of reading mail, not a way of reading one.
  property real bodyZoom: 1.0
  property bool plainTextForced: false
  // Off until somebody says otherwise, and then it stays said. Loading a
  // remote image tells its host that this address opened this message, at this
  // moment — the reason the answer was once asked for one message at a time.
  // Asked for every message, it is a decision somebody makes once and should
  // not be asked to make again on the next one; the switch that turns it on is
  // in Settings, which is also the only place that can turn it back off.
  property bool alwaysShowImages: false
  property bool windowPrefsLoaded: false
  property string windowWritePayload: ""

  function applyWindowPrefs(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
    if (parsed && typeof parsed === "object") {
      sidebarCollapsed = parsed.sidebarCollapsed === true
      bodyZoom = Model.clampZoom(parsed.bodyZoom)
      plainTextForced = parsed.plainTextForced === true
      alwaysShowImages = parsed.alwaysShowImages === true
    }
    windowPrefsLoaded = true
  }

  // A toggle is written the moment it is made; a zoom is dragged, and Ctrl and
  // the wheel walk through a dozen values in a second. So the first change goes
  // out immediately and anything arriving while that write is still running
  // waits for the scrolling to stop — dropping those, which is what a bare
  // `running` guard does, loses the one value the user settled on.
  function saveWindowPrefs() {
    if (!windowPrefsLoaded) return
    if (windowWriter.running) {
      windowPrefsSettling.restart()
      return
    }
    windowPrefsSettling.stop()
    windowWritePayload = JSON.stringify({
      sidebarCollapsed: sidebarCollapsed,
      bodyZoom: bodyZoom,
      plainTextForced: plainTextForced,
      alwaysShowImages: alwaysShowImages
    })
    windowWriter.command = [pluginDir + "/scripts/config-store.sh", "window.json"]
    windowWriter.running = true
  }

  function setSidebarCollapsed(value) {
    var next = value === true
    if (next === sidebarCollapsed) return
    sidebarCollapsed = next
    saveWindowPrefs()
  }

  function setBodyZoom(value) {
    var next = Model.clampZoom(value)
    if (next === bodyZoom) return
    bodyZoom = next
    saveWindowPrefs()
  }

  function setPlainTextForced(value) {
    var next = value === true
    if (next === plainTextForced) return
    plainTextForced = next
    saveWindowPrefs()
  }

  function setAlwaysShowImages(value) {
    var next = value === true
    if (next === alwaysShowImages) return
    alwaysShowImages = next
    saveWindowPrefs()
    // The message on screen is the one the answer was given about, so it
    // answers now rather than at the next message.
    if (next && current) current.showRemoteImages()
  }
  signal duplicateAccount(string email)

  // ------------------------------------------------------------ aggregates

  property int unreadTotal: 0
  // Whether any mailbox at all is signed in. The first-run walkthrough keys on
  // this rather than on the mailbox in view: once one account works, a second
  // one that has not signed in yet is a row waiting in settings, not a reason
  // to send the whole window back to the beginning.
  property bool anyAccountReady: false

  function recount() {
    var total = 0
    var signedIn = false
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (!host) continue
      total += host.inboxUnread
      if (host.ready) signedIn = true
    }
    unreadTotal = total
    anyAccountReady = signedIn
  }

  // The bar answers for all of them: a badge that counted only the mailbox you
  // happen to be looking at would be worse than none.
  readonly property string barTooltip: {
    if (!ready) return "Omamail · Not connected"
    var suffix = unreadTotal === 0 ? "No unread mail"
      : (unreadTotal === 1 ? "1 unread message" : unreadTotal + " unread messages")
    // The address, whatever the number of mailboxes. How many are configured is
    // not something a tooltip on a mail icon is asked, and the count it used to
    // give was of mailboxes rather than of anything waiting in them.
    return (accountEmail !== "" ? accountEmail : "Omamail") + " · " + suffix
  }

  // The switcher's model: every mailbox, its count, and why it is not usable.
  readonly property var accountSummaries: {
    var out = []
    var accounts = accountList ? accountList.accounts : []
    for (var i = 0; i < accounts.length; i++) {
      var host = accountHosts.objectAt(i)
      out.push({
        id: accounts[i].id,
        email: accounts[i].email,
        provider: accounts[i].provider,
        label: Accounts.label(accounts[i]),
        unread: host ? host.inboxUnread : 0,
        active: host ? host.active : false,
        signedIn: host ? host.ready : false,
        busy: host ? host.listLoading : false,
        error: host ? host.lastError : "",
        // The stripe this account's rows carry in a merged list, and the tint
        // on its avatar everywhere else. Empty when the user has not chosen.
        color: Accounts.normalizeColor(accounts[i].color)
      })
    }
    return out
  }

  // ------------------------------------------------------------- forwarding

  property bool windowOpen: false
  onWindowOpenChanged: if (current) current.windowOpen = windowOpen

  readonly property var auth: current ? current.auth : null
  readonly property bool ready: !!current && current.ready
  readonly property string accountEmail: current ? current.accountEmail : ""
  readonly property var sendAsAliases: current ? current.availableSendAsAliases : []
  readonly property string accountAddress: {
    var accounts = accountList ? accountList.accounts : []
    var index = activeIndex >= 0 ? activeIndex : indexOfActiveAccount()
    return index >= 0 && index < accounts.length ? String(accounts[index].email || "") : ""
  }
  readonly property int inboxUnread: root.unified
    ? root.unreadTotal
    : (current ? current.inboxUnread : 0)
  // One account's list, or every account's merged newest-first.
  //
  // Sorted on `date`, which `summarize` already put on every summary, because
  // the servers answered independently and their pages interleave. The account
  // is the tiebreak so the order is total: two messages with the same
  // timestamp must not swap places between relayouts, or a row moves under
  // the pointer for no reason anyone can see.
  readonly property var messages: {
    if (!root.unified) return current ? current.messages : []
    var merged = []
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (!host || !host.ready) continue
      var list = host.messages || []
      for (var j = 0; j < list.length; j++) merged.push(list[j])
    }
    merged.sort(Model.byReceivedDescending)
    return merged
  }

  // Which mailbox a message belongs to. Every action in a unified list goes
  // through here rather than through `current`: the list holds several
  // accounts, and acting on the wrong one archives somebody else's mail.
  // The colour and the letter a row shows for the mailbox it came from. Both
  // read off the account list rather than the host, so a row keeps its stripe
  // while its account is still signing in.
  function colorForAccount(accountId) {
    return Accounts.colorFor(accountList, accountId)
  }

  // Which mailbox the open message belongs to, for a list that has to tell two
  // rows with one id apart.
  readonly property string selectedAccountId: reader ? reader.accountId : ""

  function hostForMessage(id) {
    if (!root.unified) return current
    var wanted = String(id || "")
    if (wanted === "") return current
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (!host) continue
      if (Model.indexById(host.messages, wanted, host.accountId) >= 0) return host
    }
    return current
  }

  // The mailbox whose message is open in the reader, which is the one every
  // reader-side property below has to read from.
  property var readerHost: null
  // No folder list while unified: the folders below the mailboxes are one
  // server's own, and merging two servers' would produce rows that exist for
  // some accounts and not others.
  readonly property var labels: root.unified ? [] : (current ? current.labels : [])

  // Which service the mailbox on screen is, what mailboxes it has, and what it
  // can be asked to do. Forwarded like everything else so a view never has to
  // reach past `service` to find out.
  readonly property string providerId: current ? current.providerId : Provider.DEFAULT_ID
  // The rail. While unified it shows only the mailboxes every account maps
  // the same way, so a row cannot promise mail it would silently draw from
  // fewer mailboxes than are merged.
  readonly property var mailboxes: {
    var all = current ? current.mailboxes : Provider.mailboxes(Provider.DEFAULT_ID)
    if (!root.unified) return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (Model.isUnifiedMailbox(all[i].key)) out.push(all[i])
    }
    return out
  }
  readonly property bool canArchive: !current || current.canArchive
  readonly property bool canReportSpam: !current || current.canReportSpam
  readonly property bool canStar: !current || current.canStar
  readonly property bool hasLabels: !current || current.hasLabels
  readonly property bool canOpenOnWeb: !current || current.canOpenOnWeb
  readonly property bool canSend: !current || current.canSend
  readonly property string mailboxKey: current ? current.mailboxKey : "inbox"
  readonly property string searchQuery: current ? current.searchQuery : ""
  readonly property string rawQuery: current ? current.rawQuery : ""
  // Loading while any mailbox still is, loaded only when they all are: a
  // skeleton that cleared on the first answer would be replaced by a list that
  // then grew under the pointer as the others arrived.
  readonly property bool listLoading: {
    if (!root.unified) return !!current && current.listLoading
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host && host.ready && host.listLoading) return true
    }
    return false
  }

  readonly property bool listLoaded: {
    if (!root.unified) return !!current && current.listLoaded
    var any = false
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (!host || !host.ready) continue
      if (!host.listLoaded) return false
      any = true
    }
    return any
  }
  readonly property bool hasMore: {
    if (!root.unified) return !!current && current.hasMore
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host && host.hasMore) return true
    }
    return false
  }
  readonly property string resultSummary: current ? current.resultSummary : ""
  // The reader reads from the mailbox that owns the open message, which while
  // unified is not necessarily the one `current` points at. `reader` is that
  // host, and every property below goes through it — one indirection in one
  // place rather than a unified branch in each of them.
  readonly property var reader: root.unified ? (readerHost || current) : current

  readonly property string selectedId: reader ? reader.selectedId : ""
  readonly property var selectedMessage: reader ? reader.selectedMessage : null
  readonly property var selectedBody: reader ? reader.selectedBody : ({ text: "", source: "" })
  readonly property string selectedHtml: reader ? reader.selectedHtml : ""
  readonly property var selectedDocument: reader ? reader.selectedDocument : null
  readonly property var selectedImages: reader ? reader.selectedImages : []
  readonly property int selectedBlockedImages: reader ? reader.selectedBlockedImages : 0
  readonly property int selectedRemoteImages: reader ? reader.selectedRemoteImages : 0
  readonly property bool remoteImagesAllowed: !!reader && reader.remoteImagesAllowed
  readonly property var selectedAttachments: reader ? reader.selectedAttachments : []
  readonly property bool selectedTooHeavy: !!reader && reader.selectedTooHeavy
  // The meeting inside the message, and the answer of the account it arrived
  // in — which is the account that has to send the reply.
  readonly property var selectedInvite: reader ? reader.selectedInvite : null
  readonly property string selectedResponse: reader ? reader.selectedResponse : ""
  readonly property bool canRespondToInvite: !!reader && reader.canRespondToInvite
  readonly property bool rsvpSending: !!reader && reader.rsvpSending
  // Empty when this message offers no way off a list, which is the answer for
  // everything that is not a newsletter.
  readonly property string unsubscribeLabel: reader ? reader.unsubscribeLabel : ""
  readonly property string unsubscribeDetail: reader ? reader.unsubscribeDetail : ""
  readonly property bool unsubscribing: !!reader && reader.unsubscribing
  readonly property string savingAttachment: reader ? reader.savingAttachment : ""
  readonly property bool detailLoading: !!reader && reader.detailLoading
  readonly property bool sending: !!current && current.sending
  readonly property string lastError: current ? current.lastError : ""
  readonly property string actionStatus: current ? current.actionStatus : ""
  readonly property string signInProgress: current ? current.signInProgress : ""
  readonly property string syncedLabel: current ? current.syncedLabel : ""

  function refresh() {
    if (!root.unified) {
      if (current) current.refresh()
      return
    }
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host) host.refresh()
    }
  }
  // Each mailbox pages independently — Gmail has a real page token, IMAP an
  // offset into its own search — so there is no single cursor to advance.
  // Asking every account that still has more is what a merged next page is.
  function loadMore() {
    if (!root.unified) {
      if (current) current.loadMore()
      return
    }
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host && host.hasMore) host.loadMore()
    }
  }
  // Selecting sets which mailbox the reader speaks to, and clears the
  // selection in every other one: two accounts each holding an open message
  // would otherwise both answer, and the reader would show whichever property
  // resolved first.
  function select(id) {
    var host = hostForMessage(id)
    if (!host) return
    if (root.unified) {
      for (var i = 0; i < accountHosts.count; i++) {
        var other = accountHosts.objectAt(i)
        if (other && other !== host && other.selectedId !== "") other.clearSelection()
      }
      readerHost = host
    }
    host.select(id)
  }

  function clearSelection() {
    if (root.unified) {
      for (var i = 0; i < accountHosts.count; i++) {
        var host = accountHosts.objectAt(i)
        if (host) host.clearSelection()
      }
      readerHost = null
      return
    }
    if (current) current.clearSelection()
  }
  // The notice's own button, which is the switch: what it turns on is every
  // message, and it says so.
  function showRemoteImages() { setAlwaysShowImages(true) }
  function rsvp(response) {
    var host = root.unified ? reader : current
    if (host) host.rsvp(response)
  }
  function saveAttachment(id) {
    var host = root.unified ? reader : current
    if (host) host.saveAttachment(id)
  }
  function unsubscribe() {
    var host = root.unified ? reader : current
    if (host) host.unsubscribe()
  }
  function cursorOffset(cursorId, delta) {
    return current ? current.cursorOffset(cursorId, delta) : ""
  }
  // While unified every mailbox moves together, or the merged list would be
  // one account's Inbox beside another's Unread.
  function selectMailbox(key) {
    if (!root.unified) {
      if (current) current.selectMailbox(key)
      return
    }
    clearSelection()
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host) host.selectMailbox(key)
    }
  }
  function search(text) { if (current) current.search(text) }
  function selectLabel(name) { if (current) current.selectLabel(name) }
  // Every action names a message, so every action can find its own mailbox.
  function act(id, action, quiet) {
    var host = hostForMessage(id)
    if (host) host.act(id, action, quiet)
  }
  function toggleStar(id) {
    var host = hostForMessage(id)
    if (host) host.toggleStar(id)
  }
  function markAllRead() {
    if (!root.unified) {
      if (current) current.markAllRead()
      return
    }
    for (var i = 0; i < accountHosts.count; i++) {
      var host = accountHosts.objectAt(i)
      if (host) host.markAllRead()
    }
  }
  function send(fields) { if (current) current.send(fields) }
  function preferredSendAs(recipients) {
    return current ? current.preferredSendAs(recipients) : null
  }
  function signIn() { if (current) current.signIn() }
  function cancelSignIn() { if (current) current.cancelSignIn() }
  function signOut() { if (current) current.signOut() }

  // The password providers' sign-in. Gmail's is a browser and answers false,
  // which is what lets one setup page ask without checking first.
  function signInWithPassword(secret) {
    return !!current && current.signInWithPassword(secret)
  }

  // The setup form writes back to the account row it is editing, which is the
  // one on screen. Addressed by index because that is the only handle on a row
  // that has no address yet — which is exactly the row being filled in.
  function configureCurrentAccount(values) {
    configureAccount(activeIndex >= 0 ? activeIndex : indexOfActiveAccount(), values)
  }

  // Saving a new address rebuilds the account host. Wait for that replacement
  // before asking it to sign in; calling through immediately targets the host
  // that the save has just retired, which made a failed attempt knock the user
  // out of the add flow on the next click.
  function configureCurrentAccountAndSignIn(values, secret) {
    configureCurrentAccount(values)
    Qt.callLater(function() { root.signInWithPassword(secret) })
  }

  function indexOfActiveAccount() {
    var accounts = accountList ? accountList.accounts : []
    for (var i = 0; i < accounts.length; i++) {
      if (accounts[i].id !== "" && accounts[i].id === accountList.activeId) return i
    }
    // Nothing matched by id, which is what a row still being filled in looks
    // like: it has no address yet, so it has no id to match on. The first such
    // row is the one the form is editing.
    for (var j = 0; j < accounts.length; j++) {
      if (accounts[j].id === "") return j
    }
    return -1
  }
  function openInBrowser(id) { if (current) current.openInBrowser(id) }
  function openWebInbox() { if (current) current.openWebInbox() }
  function openCloudConsole() { if (current) current.openCloudConsole() }
  function openGmailApiPage() { if (current) current.openGmailApiPage() }

  // Not forwarded to an account: the project exists whether or not anyone has
  // signed in, and the menu offers it on the setup page too.
  function openProjectPage() {
    Quickshell.execDetached(["xdg-open", "https://github.com/huacnlee/omamail"])
  }

  function openAuthorPage() {
    Quickshell.execDetached(["xdg-open", "https://x.com/huacnlee"])
  }
  function openConsentScreen() { if (current) current.openConsentScreen() }

  signal replySent()

  // ------------------------------------------------------------- instances

  // The model is a COUNT, not the array. An Instantiator rebuilds every
  // delegate when its model changes identity, and this list is reassigned
  // whole on every save — so modelling the array tore down all the accounts
  // whenever one of them learned its own address, dropping their loaded state
  // and landing in-flight callbacks on half-destroyed objects.
  Instantiator {
    id: accountHosts
    model: root.accountCount

    delegate: MailAccount {
      required property int index

      readonly property var entry: {
        var accounts = root.accountList ? root.accountList.accounts : []
        return index < accounts.length ? accounts[index] : null
      }

      pluginDir: root.pluginDir
      accountId: entry ? entry.id : ""
      configuredEmail: entry ? entry.email : ""
      // Which service this mailbox is, and — for the one that needs them — the
      // servers it talks to. Both come off the account entry, so changing an
      // account's provider in the file rebuilds it as that provider.
      providerId: entry ? entry.provider : Provider.DEFAULT_ID
      imapSettings: entry ? entry.imap : null
      // Only a Gmail account has a client-keyed refresh token to inherit, and
      // only the first one may claim it.
      mayAdoptLegacyToken: index === 0 && (!entry || entry.provider === "gmail")
      settings: root.settings
      // Every mailbox obeys the one answer: it is about what the reader is
      // willing to tell a sender, not about which account the mail came to.
      alwaysShowImages: root.alwaysShowImages

      onAccountIdentified: function(email) { root.nameAccount(index, email) }
      onReadyChanged: root.recount()
      onInboxUnreadChanged: root.recount()
      onReplySent: root.replySent()

      Component.onCompleted: Qt.callLater(root.refreshCurrent)
      Component.onDestruction: Qt.callLater(root.refreshCurrent)
    }
  }

  onActiveAccountIdChanged: refreshCurrent()
  onAccountListChanged: Qt.callLater(refreshCurrent)

  FileView {
    id: windowFile
    path: {
      var home = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
      return home + "/omamail/window.json"
    }
    printErrors: false
    onLoaded: root.applyWindowPrefs(text())
    // No file yet is the ordinary first-run state, not an error.
    onLoadFailed: root.applyWindowPrefs("")
  }

  Timer {
    id: windowPrefsSettling
    interval: 500
    onTriggered: root.saveWindowPrefs()
  }

  Process {
    id: windowWriter
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.windowWritePayload + "\n")
      root.windowWritePayload = ""
    }
    onExited: root.windowWritePayload = ""
  }

  FileView {
    id: accountsFile
    path: {
      var home = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
      return home + "/omamail/accounts.json"
    }
    watchChanges: true
    printErrors: false
    onLoaded: root.applyAccounts(text())
    onFileChanged: reload()
    // No list yet is the ordinary first-run state, not an error.
    onLoadFailed: root.applyAccounts("")
  }

  Process {
    id: accountsWriter
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.accountsWritePayload + "\n")
      root.accountsWritePayload = ""
    }
    onExited: {
      root.accountsWritePayload = ""
      if (root.accountsSaveQueued) root.saveAccounts()
    }
  }
}
