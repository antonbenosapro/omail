import QtQuick
import Quickshell
import Quickshell.Io
import "../providers"
import "../cache"

import "../cache/Cache.js" as Cache
import "../message/Html.js" as Html
import "../providers/GmailApi.js" as Api
import "../message/Message.js" as Mail
import "../message/Draft.js" as Draft
import "../message/Calendar.js" as Calendar
import "../message/Unsubscribe.js" as Unsub
import "Model.js" as Model
import "Accounts.js" as Accounts
import "../providers/Registry.js" as Provider
import "../providers/ImapProtocol.js" as Imap
import "../providers/OAuth.js" as OAuth

// One mailbox: its sign-in, its cache, its messages. Service.qml owns a set of
// these and puts whichever is on screen in front of the views.
//
// Three rhythms drive the state:
//   - an unread poll that runs for every account, open window or not, because a
//     bar badge that only speaks for the mailbox you are looking at is worse
//     than no badge
//   - a list refresh for the account on screen, or right after an action
//   - nothing at all for the rest: a message list nobody can see is wasted
//     quota, and the cache means switching to it still paints instantly
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  property string configuredEmail: ""

  // Which mailbox this is, and whether it is the one on screen. An inactive
  // account still counts its unread mail; it just does not fetch lists or
  // bodies nobody can see.
  property string accountId: ""

  // Which mail service this mailbox is. Everything provider-specific hangs off
  // this one string: which pair of objects gets built at the bottom of the
  // file, which mailboxes the sidebar offers, and what a query means.
  property string providerId: Provider.DEFAULT_ID
  // Server settings for an IMAP account, straight off the account entry. Unused
  // by the others, and normalised before anything can dial one.
  property var imapSettings: null
  // Only the mailbox that predates multi-account may claim the old
  // client-keyed refresh token. See AuthManager.mayAdoptLegacyToken.
  property bool mayAdoptLegacyToken: true
  property bool active: false

  // Pushed down from the container, which is where the bar widget's settings
  // arrive. Kept as defaults here so an account is usable before that happens.
  readonly property var defaultSettingValues: ({
    refreshIntervalSec: 120,
    maxMessages: 25,
    defaultQuery: "in:inbox",
    notifyNewMail: "On",
    oauthPort: 9481
  })
  property var settings: defaultSettingValues

  // The window drives this; the unread poll keeps running while it is false.
  property bool windowOpen: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Reassigning the whole object is what makes the readonly settings below
  // re-evaluate. Mutating it in place would not.
  readonly property int refreshIntervalSec: Math.max(30, Math.min(3600,
    Math.floor(Number(setting("refreshIntervalSec", 120))) || 120))
  readonly property int maxMessages: Math.max(5, Math.min(100,
    Math.floor(Number(setting("maxMessages", 25))) || 25))
  readonly property string defaultQuery: String(setting("defaultQuery", "in:inbox")).trim()
  readonly property bool notifyNewMail: String(setting("notifyNewMail", "On")) !== "Off"
  readonly property int oauthPort: OAuth.normalizedPort(setting("oauthPort", OAuth.DEFAULT_PORT))

  // Built by the loaders at the bottom, so both are null for one frame while an
  // account switches provider. Every use guards for that rather than assuming.
  readonly property var auth: authLoader.item
  readonly property var api: apiLoader.item
  readonly property alias cache: cacheStore

  // The mailboxes this account has, which is a property of its provider rather
  // than of the panel. The sidebar and the tab row draw whatever is here.
  readonly property var mailboxes: Provider.mailboxes(providerId)

  // What the panel may offer for this account. A button the service cannot
  // honour is worse than a missing one: it fails after the user has committed
  // to it, with the row already moved.
  readonly property bool canArchive: Provider.can(providerId, "archive")
  readonly property bool canReportSpam: Provider.can(providerId, "spam")
  readonly property bool canStar: Provider.can(providerId, "star")
  readonly property bool hasLabels: Provider.can(providerId, "labels")
  readonly property bool canOpenOnWeb: Provider.can(providerId, "web")
  readonly property bool canSend: Provider.can(providerId, "send")
  // Whether opening a message marks it read as part of the same request. On
  // IMAP the STORE rides on the FETCH's connection; Gmail has no way to fetch
  // and modify at once, so there it stays the separate call it always was.
  readonly property bool fetchMarksRead: Provider.can(providerId, "fetchMarksRead")
  // Whether a trash here can be taken back. Off for IMAP, where a move reissues
  // the message's UID and the transport is never told the new one — so the
  // notice offers no Undo rather than one that would fail after the user had
  // committed to it.
  readonly property bool canUndo: Provider.can(providerId, "undo")
  // Whether unsent mail can be kept on the server: a Drafts mailbox, a compose
  // that saves itself, and an Escape that keeps what was written.
  readonly property bool canDraft: Provider.can(providerId, "drafts")

  // What the cache is keyed on. The page size is part of it: the same query at
  // a different size is a different result set, not a stale one.
  readonly property string cacheKey: Cache.queryKey(effectiveQuery, maxMessages)

  // ------------------------------------------------------------ mailbox

  property string mailboxKey: "inbox"
  property string searchQuery: ""
  // A query picked from a list rather than typed: a Gmail label, an IMAP
  // folder. Kept apart from `searchQuery` because that one gets shaped into a
  // search — an IMAP folder wrapped in a TEXT search would go looking for the
  // folder's own name inside the inbox.
  property string rawQuery: ""
  property var messages: []
  property var labels: []
  property var sendAsAliases: []
  property bool sendAsLoading: false
  property bool sendAsLoaded: false
  property string nextPageToken: ""
  property int resultEstimate: 0
  property bool listLoading: false
  property bool listLoaded: false
  property var listHandle: null
  property int listSerial: 0
  // Bumped by every navigation, and only by navigation. `listSerial` also
  // moves on each poll and load-more, which replace nothing the user chose;
  // this is what an answer arriving late compares against to know whether the
  // list it would change is still the one it was sent from.
  property int viewSerial: 0
  // What is on screen for `Model.survivesAction`: the mailbox, or a label or a
  // search opened over it.
  readonly property string viewKey: Model.listViewKey(mailboxKey, searchQuery, rawQuery)
  // Whether an action moves a message between folders rather than relabelling
  // it, which is what decides whether IMAP's archive leaves Flagged.
  readonly property bool movesBetweenFolders: !hasLabels

  property string selectedId: ""
  property var selectedMessage: null
  property var selectedBody: ({ text: "", source: "" })
  // Already sanitised by the time the reader sees it. Decoding uses Qt.atob
  // where it exists, which is native and skips the per-character base64 loop
  // that made this the one expensive step in opening a message.
  property string selectedHtml: ""
  // The sender's own HTML, exactly as Gmail handed it over. This is what the
  // body cache holds and what `selectedHtml` is derived from — so asking for the
  // images is a re-render rather than another trip to Gmail, and a sanitiser
  // that learns something new applies it to every message already on disk
  // rather than only to the ones fetched afterwards.
  property string sourceHtml: ""
  // The parsed document behind `selectedHtml`. The reader fits it to whatever
  // width it happens to be and rebuilds on every relayout, so handing over the
  // tree rather than the string is the difference between one parse per message
  // and one per drag step.
  property var selectedDocument: null
  // Off for every message, every time it is opened. Fetching a sender's images
  // tells them the mail was read, from which address and when, so it happens
  // only when the reader has asked — and asking covers this message alone.
  // The window's standing answer about remote images, which is where a
  // message starts. Off, and every message begins blocked and is asked about
  // one at a time.
  property bool alwaysShowImages: false
  property bool remoteImagesAllowed: false
  // The sender's images, in the order htmlToText numbers them, so a marker in
  // the plain-text body can be traced back to the picture it replaced.
  property var selectedImages: []
  property int selectedBlockedImages: 0
  // How many of the blocked ones asking would actually bring back. A message
  // whose only images are beacons or point at the local network has nothing to
  // offer, so the reader says nothing.
  property int selectedRemoteImages: 0
  property bool selectedTooHeavy: false
  property var selectedAttachments: []
  // The meeting this message carries, if it carries one. Null for nearly every
  // message, which is what makes the card cost nothing to have.
  property var selectedInvite: null
  property bool rsvpSending: false
  // What the message's own headers offer by way of getting off this list.
  property var selectedUnsubscribe: null
  property bool unsubscribing: false
  // What was actually done about this list, once something was. Non-empty is
  // also the flag that it has been: the button goes, the sentence stays, and
  // pressing it twice stops being a thing that can happen. A `note` would not
  // do — those clear themselves after a few seconds, and this is the answer to
  // a question the user may look back at the message to ask.
  property string unsubscribeDone: ""

  // Which of this account's own addresses this message arrived at.
  //
  // A mailbox with aliases is invited as one of them, and the invitation's
  // ATTENDEE line names that one — so looking for the answer under the primary
  // address finds nothing, and sending one from it would be answering for
  // somebody the organiser never invited. An unsubscribe wants the same
  // address for the same reason: a list that only ever knew the alias has no
  // reason to honour a request from an address it has never seen.
  //
  // `Api.preferredSendAs` is called rather than the `preferredSendAs` method
  // beside it so that `availableSendAsAliases` is read inside this binding,
  // where the dependency is unmistakable. It falls back to the default address
  // when the message names none of them, which is the right answer for an
  // invitation that was forwarded by hand.
  readonly property var receivedAsAlias: {
    if (!selectedMessage) return null
    var addressed = (selectedMessage.to || []).concat(selectedMessage.cc || [])
    return Api.preferredSendAs(availableSendAsAliases, addressed)
  }
  readonly property string receivedAsAddress: {
    var chosen = receivedAsAlias ? String(receivedAsAlias.email || "") : ""
    return chosen !== "" ? chosen : ownAddress
  }
  readonly property string receivedAsName: receivedAsAlias
    ? String(receivedAsAlias.displayName || "") : ""

  // Read back out of the invitation rather than remembered separately. An
  // answer that is sent rewrites this account's ATTENDEE line in the copy kept
  // on disk, so the card and the file agree — see `rememberResponse`.
  readonly property string selectedResponse: selectedInvite
    ? Calendar.responseOf(selectedInvite, receivedAsAddress) : ""
  readonly property bool canRespondToInvite: !!selectedInvite && canSend
    && Calendar.canRespond(selectedInvite, receivedAsAddress, senderAddress)
  // Who the message says it is from, and, when the invitation would be answered
  // to someone else, who that is. The card asks before sending to them.
  readonly property string senderAddress: selectedMessage && selectedMessage.from
    ? String(selectedMessage.from.email || "") : ""
  readonly property string inviteMismatch: selectedInvite
    && selectedInvite.method === "REQUEST" && String(selectedInvite.status || "") !== "CANCELLED"
    ? Calendar.replyMismatch(selectedInvite, senderAddress) : ""

  readonly property string unsubscribeLabel: unsubscribeDone !== "" ? ""
    : Unsub.label(selectedUnsubscribe, canSend)
  readonly property string unsubscribeDetail: unsubscribeDone !== "" ? unsubscribeDone
    : Unsub.explanation(selectedUnsubscribe, canSend)
  property bool detailLoading: false
  // Set once Gmail's own copy has landed, so a slower cache read knows not to
  // paint over it.
  property bool detailLive: false
  // Set once the cache has painted a complete message. A body never changes
  // after it is fetched, which is what makes the cache correct in the first
  // place — so what remains to ask the server is the one thing that does
  // change: whether the message is still unread. That is a summary fetch
  // rather than the whole message.
  property bool detailCached: false
  property var detailHandle: null
  // The invitation's own request, which only a message carrying one ever makes.
  property var inviteHandle: null
  property int detailSerial: 0

  property var profile: null
  readonly property string accountEmail: profile ? String(profile.email || "") : ""
  readonly property var availableSendAsAliases: {
    if (sendAsAliases.length > 0) return sendAsAliases
    if (accountEmail === "") return []
    return [{ email: accountEmail, displayName: "", isPrimary: true, isDefault: true }]
  }
  // The address this mailbox answers as when nothing more specific applies.
  // The profile is authoritative once it has loaded; until then the address the
  // account was configured with is what the user signed in as, and an RSVP sent
  // in that gap still has to name somebody.
  readonly property string ownAddress: accountEmail !== "" ? accountEmail : configuredEmail
  property int inboxUnread: 0
  property bool countLoading: false

  // When the list last agreed with the server. Ticked separately so the label
  // ages without anything else re-evaluating.
  property double lastSyncedMs: 0
  property int syncTick: 0
  readonly property string syncedLabel: {
    var ignored = syncTick
    if (listLoading) return "Checking for mail"
    if (lastSyncedMs <= 0) return ""
    var ago = Mail.relativeTime(new Date(lastSyncedMs), new Date())
    return ago === "now" ? "Synced just now" : "Synced " + ago + " ago"
  }

  property string lastError: ""
  property string actionStatus: ""
  property string pendingAction: ""
  property bool sending: false

  // What the notice beside `actionStatus` offers to take back, and null when it
  // offers nothing. Its lifetime is the notice's: `noticeTimer` clears both
  // together, so an Undo button cannot outlast the sentence explaining it and
  // there is no stale offer left to resurrect a message minutes later.
  //
  // Built by `act` from the row as it still stood, because after the action the
  // row is gone from the list and — on IMAP — the id that addressed it names a
  // message in another folder.
  property var undoRecord: null
  // The reverse is in flight. The button says so rather than disappearing: a
  // control that vanishes under the pointer reads as a misclick.
  property bool undoBusy: false
  readonly property string undoLabel: Model.undoActionLabel(undoRecord)
  // The file the last save wrote, offered as an explicit Open beside the notice.
  // Saving never opens anything by itself: the sender chose the file.
  property string openPath: ""
  readonly property string openLabel: openPath !== "" ? "Open..." : ""
  // Where the cursor belongs once the offer is taken: the first row it would
  // put back, as a row key, because a bare id addresses no row in a merged list.
  // Empty when the undo would not put its rows into the list on screen.
  readonly property string undoKey: Model.undoCursorKey(undoRecord, viewStamp())

  // Notifications only start once the first successful load has established
  // what was already there.
  property var seenIds: ({})
  property bool notificationsPrimed: false
  // The unread count needs a baseline of its own, separate from the message
  // cache: a mailbox that has never been opened has no cached page to prime
  // from, and would otherwise never be allowed to announce anything.
  property bool countPrimed: false
  // Mail that arrived since the list was last looked at. The bar shows a dot
  // for this and nothing else — an unread count that never reaches zero is a
  // permanent red mark, which stops meaning anything.

  readonly property string setupState: {
    // A provider with nothing behind it can never become ready, and saying so
    // here is what keeps every caller from having to ask separately.
    if (!Provider.isConnectable(providerId)) return "unavailable"
    if (!auth) return "signed_out"
    return Model.setupState({
      toolsPresent: auth.toolsPresent || !auth.toolsChecked,
      credentialsPresent: auth.credentialsPresent,
      signingIn: auth.loginBusy,
      signedIn: auth.loggedIn
    })
  }
  // `ready` gates every function that fetches, so requiring the client here is
  // what spares each of them a null check of its own. It is not redundant with
  // the sign-in state: the two loaders build in sequence, so there is a frame
  // where the account is signed in and has nothing to fetch with.
  readonly property bool ready: setupState === "ready" && !!api
  readonly property bool busy: listLoading || detailLoading || countLoading
    || (auth ? auth.sessionBusy : false) || sending || pendingAction !== ""
  // The provider decides what a mailbox and a typed search amount to: Gmail's
  // are search operators, IMAP's name a folder. Opaque from here on — it is
  // handed back to the client that produced it, and used as a cache key.
  readonly property string effectiveQuery: rawQuery !== "" ? rawQuery
    : Provider.query(providerId, mailboxKey, searchQuery, defaultQuery)
  readonly property bool hasMore: nextPageToken !== ""
  readonly property string resultSummary: Model.resultSummary(messages, resultEstimate, hasMore)
  readonly property string barTooltip: Model.barTooltip(setupState, accountEmail, inboxUnread,
    Provider.badge(providerId), Provider.authKind(providerId))

  // The setup card, in this provider's words. Assembled here rather than in the
  // view so the page stays a description of the screen.
  readonly property string setupHeadline:
    Model.setupHeadline(setupState, Provider.badge(providerId), Provider.authKind(providerId))
  readonly property string setupDetail: Model.setupDetail(setupState,
    auth ? auth.missingTools : [], Provider.unavailableReason(providerId),
    Provider.badge(providerId), Provider.authKind(providerId))
  readonly property string setupActionLabel:
    Model.setupActionLabel(setupState, Provider.badge(providerId), Provider.authKind(providerId))

  // The sign-in has three waits that look identical from outside: the helper
  // script, the browser, and Google's token endpoint. Naming which one is
  // happening is the difference between "it is working" and "it is stuck".
  readonly property string signInProgress: {
    if (!auth) return ""
    if (!auth.toolsChecked)
      return "Checking for " + auth.requiredTools.slice(0, 2).join(" and ") + "…"
    if (!auth.credentialsPresent) return ""
    // Only one of these waits on a browser. An IMAP sign-in is a form and a
    // round trip, so naming a browser there would send the user looking for a
    // window that never opened.
    if (auth.loginBusy)
      return Provider.usesOAuth(providerId)
        ? "Finish the sign-in in your browser…"
        : "Checking the mailbox…"
    if (auth.sessionBusy) return "Restoring the saved session…"
    return ""
  }

  signal listRefreshed()

  // Cancelling runs on teardown and on every mailbox switch, which are exactly
  // the moments the client may already be gone — an account being removed, or
  // a provider change swapping both loaders out. A local wrapper means none of
  // the callers has to know that.
  function abortRequest(handle) {
    if (api && handle) api.abortRequest(handle)
  }

  function clearNotice() {
    lastError = ""
    actionStatus = ""
    undoRecord = null
    openPath = ""
  }

  // One call sets the sentence and whatever it offers, so the two cannot be set
  // separately and then expire separately. A note with no record clears any
  // record still standing: the newer thing the window has to say has replaced
  // the older offer on the same line, and an Undo button beside a different
  // sentence would be lying about what it undoes.
  function note(text, record) {
    actionStatus = String(text || "")
    undoRecord = record || null
    openPath = ""
    if (actionStatus !== "") noticeTimer.restart()
  }

  function fail(text) {
    lastError = String(text || "")
    actionStatus = ""
  }

  // ------------------------------------------------------------- loading

  function refresh() {
    if (!ready) return
    refreshCounts()
    if (active && (windowOpen || !listLoaded)) loadMessages(false)
  }

  function refreshCounts() {
    if (!ready || countLoading) return
    countLoading = true
    var serial = sessionSerial
    // Counted with the same query the Unread mailbox uses, not from the INBOX
    // label. The label counts every categorised message too, which is how this
    // reached 2483 on a real account — a number that is never zero, can only be
    // reported as "999+", and cannot tell anyone whether something is waiting.
    api.listMessages(Provider.unreadQuery(providerId), 1, "", function(page, error) {
      if (serial !== root.sessionSerial) return
      root.countLoading = false
      if (error || !page) return
      var before = root.inboxUnread
      root.inboxUnread = page.estimate

      // A mailbox that gains unread mail earns a look, whether or not it is the
      // one on screen. The badge and the notification are both raised from a
      // list load, and only the active account ever performed one — so mail
      // arriving in any other mailbox went unannounced entirely, and mail
      // arriving in this one while the window was shut relied on comparing the
      // total against a single page rather than on the count actually moving.
      //
      // The first read of a session has no previous count to compare against,
      // but the cache does know which messages were already on screen — so it
      // loads once and lets the arrival check decide. Treating that first read
      // as nothing but a baseline made every shell restart a blind spot: mail
      // that landed while the shell was down would sit inside the new baseline
      // and never be announced at all. An account with no cache still says
      // nothing, because there is nothing to compare against.
      var first = !root.countPrimed
      root.countPrimed = true
      if ((first || page.estimate > before) && !root.listLoading)
        root.loadMessages(false)
    })
  }

  // Which session the answers in flight belong to. Signing out and being
  // handed a different mailbox both move it, and a reply stamped with an older
  // one is dropped: otherwise a count or a label list that was already in the
  // air lands after the sign-out and puts the old mailbox back on screen.
  property int sessionSerial: 0

  // `force` is for right after a sign-in. A profile already on screen is not
  // proof of who just signed in: re-signing in to an expired session opens
  // Google's account chooser, and picking a different account there used to
  // file that account's token and mail under this one's name.
  function loadProfile(force) {
    if (!ready || (profile && force !== true)) return
    if (!profile && cacheStore.loaded && cacheStore.store.profile) profile = cacheStore.store.profile
    var serial = sessionSerial
    api.getProfile(function(result, error) {
      if (serial !== root.sessionSerial) return
      if (error || !result) return
      // The shell can tear this account down — a reload, a removed account —
      // while the request is still in the air. The object outlives its methods
      // for a moment, so the reply has to check before it uses them.
      if (typeof cacheStore.bindAccount !== "function") return
      // A mailbox that already has a name only ever accepts that name back.
      // Only an OAuth sign-in can come back as somebody else; an IMAP profile
      // is the address the user typed.
      if (root.accountId !== "" && String(result.email || "") !== ""
          && Provider.usesOAuth(root.providerId)
          && !Accounts.isSameMailbox(root.accountId, result.email, root.providerId)) {
        root.rejectIdentity(String(result.email))
        return
      }
      root.profile = result
      if (result.email !== "") root.accountIdentified(result.email)
      // A cache belongs to one mailbox. Binding the address here is what stops
      // one account's mail from appearing under another's name.
      cacheStore.bindAccount(result.email)
      cacheStore.putProfile(result)
    })
  }

  // Signed in as the wrong account. The token just stored is under this
  // mailbox's name and is not this mailbox's, so the sign-out that drops it is
  // the whole remedy; the sentence says which account to choose next time.
  function rejectIdentity(email) {
    var expected = configuredEmail !== "" ? configuredEmail : accountId
    signOut()
    fail("That sign-in was " + email + ", not " + expected + ". Sign in again and choose "
      + expected)
  }

  function loadLabels() {
    if (!ready) return
    if (cacheStore.loaded && cacheStore.store.labels.length > 0 && labels.length === 0)
      labels = cacheStore.store.labels
    var serial = sessionSerial
    api.getLabels(function(result, error) {
      if (serial !== root.sessionSerial) return
      if (error) return
      root.labels = result
      cacheStore.putLabels(result)
    })
  }

  // Every provider exposes the same sender-list operation. Gmail reads its
  // configured send-as aliases; an IMAP mailbox returns its one account
  // address. Keeping that distinction below this object lets the compose view
  // draw one honest From control for either provider.
  function loadSendAs() {
    if (!ready || sendAsLoading || sendAsLoaded) return
    sendAsLoading = true
    var serial = sessionSerial
    api.getSendAs(function(result, error) {
      if (serial !== root.sessionSerial) return
      root.sendAsLoading = false
      // Not a notice: a sender list that did not arrive costs the user a menu,
      // not a mailbox, and a banner over the inbox would be out of proportion.
      // It is not silent either — failing quietly here is indistinguishable
      // from "this account has one address", which is a question nobody could
      // answer from the window. `sendAsLoaded` stays false, so the next time
      // this account becomes ready or active it tries again.
      if (error) {
        console.warn("omail: could not read the send-as addresses:",
          OAuth.redact(String(error)))
        return
      }
      root.sendAsAliases = result
      root.sendAsLoaded = true
    })
  }

  function preferredSendAs(recipients) {
    return Api.preferredSendAs(availableSendAsAliases, recipients)
  }

  // Paints whatever the last visit to this query left behind. Switching
  // mailboxes should never show an empty column while the network decides.
  //
  // Only when there is nothing on screen. A refresh of a list already loaded
  // used to paint the cache over it and then paint the live answer over that,
  // so every poll rebuilt the whole list twice from rows that were usually
  // identical — and the cache's copy is by definition older than what it was
  // replacing.
  function paintFromCache() {
    if (listLoaded) return true
    if (!cacheStore.loaded) return false
    var entry = cacheStore.get(cacheKey)
    if (!entry || !entry.summaries || entry.summaries.length === 0) return false

    var now = new Date()
    var restored = Cache.hydrate(entry.summaries)
    for (var i = 0; i < restored.length; i++) {
      restored[i].time = Mail.relativeTime(restored[i].date, now)
      // Stamped like every other summary. These are freshly hydrated and
      // nothing else holds them yet, so they can be written in place — and a
      // cache from before this field existed gains it on the way in.
      restored[i].accountId = root.accountId
    }

    messages = restored
    resultEstimate = entry.estimate
    nextPageToken = entry.nextPageToken
    listLoaded = true
    lastError = ""

    // Cached rows count as already seen, so the first live load does not
    // announce a mailbox the user has been looking at all along.
    var seen = {}
    for (var key in seenIds) seen[key] = true
    for (var j = 0; j < restored.length; j++) seen[restored[j].id] = true
    seenIds = seen
    // The cache is also a record of what was on screen last time, so a live
    // load on top of it can tell genuinely new mail from a first look.
    notificationsPrimed = true
    listRefreshed()
    return true
  }

  function loadMessages(append) {
    if (!ready) return
    var serial = ++listSerial
    abortRequest(listHandle)
    if (!append) {
      // Cache first: paint, then revalidate. The page tokens and the estimate
      // come back with the live answer.
      if (!paintFromCache()) {
        nextPageToken = ""
        resultEstimate = 0
      }
    }
    listLoading = true
    var token = append ? nextPageToken : ""

    listHandle = api.listMessages(effectiveQuery, maxMessages, token,
      function(page, error) {
        if (serial !== root.listSerial) return
        if (error || !page) {
          root.listLoading = false
          root.fail(error || "Gmail returned nothing")
          return
        }
        root.resultEstimate = page.estimate
        if (page.ids.length === 0) {
          root.nextPageToken = page.nextPageToken
          root.listLoading = false
          root.listLoaded = true
          if (!append) {
            root.messages = []
            // An empty answer is an answer, and it has to reach the cache. Only
            // a non-empty result was ever written back, so a mailbox that had
            // emptied kept its old rows on disk — and cache-first painted them
            // again on every visit before the live load wiped them a moment
            // later. Reading mail elsewhere made Unread do exactly that.
            cacheStore.putQuery(root.cacheKey, ({
              summaries: [],
              estimate: root.resultEstimate,
              nextPageToken: root.nextPageToken
            }))
          }
          root.lastError = ""
          root.listRefreshed()
          return
        }
        // A first page's token is settled with the merge in `applySummaries`,
        // which is the moment it is known whether loaded pages are kept.
        if (append) root.nextPageToken = page.nextPageToken
        root.fetchSummaries(page.ids, append, serial, page.nextPageToken)
      })
  }

  function fetchSummaries(ids, append, serial, pageToken) {
    api.getMessages(ids, false, function(payloads, error) {
      if (serial !== root.listSerial) return
      root.listLoading = false
      if (error && payloads.length === 0) {
        root.fail(error)
        return
      }
      var now = new Date()
      var summaries = []
      for (var i = 0; i < payloads.length; i++) summaries.push(Mail.summarize(payloads[i], now))
      root.applySummaries(summaries, append, pageToken)
      // The cache holds page one, so it keeps page one's own token whatever
      // the list on screen kept.
      if (!append) cacheStore.putQuery(root.cacheKey, ({
        summaries: summaries,
        estimate: root.resultEstimate,
        nextPageToken: String(pageToken || "")
      }))
    }, listHandle)
  }

  // Every summary is stamped with the mailbox it came from, because a unified
  // list holds several and neither provider's id is unique across them. This
  // is the one place summaries enter the list, so it is the one place that has
  // to know.
  function tagOwnership(summaries) {
    var list = Array.isArray(summaries) ? summaries : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var summary = list[i]
      if (!summary) continue
      if (String(summary.accountId || "") === root.accountId) {
        out.push(summary)
        continue
      }
      // Copied rather than mutated: a summary may still be referenced by the
      // list that is on screen, and rewriting it in place would change a row
      // Qt has already been told is unchanged.
      var copy = {}
      for (var key in summary) copy[key] = summary[key]
      copy.accountId = root.accountId
      out.push(copy)
    }
    return out
  }

  function applySummaries(rawSummaries, append, pageToken) {
    var summaries = tagOwnership(rawSummaries)
    // Decided before the merge, from the same count the merge reads, so the
    // token and the rows kept cannot disagree: more than a page listed keeps
    // the token for the page after the last one, which is the page kept.
    if (!append) nextPageToken = Model.tokenAfterFirstPage(root.messages.length,
      root.maxMessages, nextPageToken, pageToken)
    // Appended with the seam row dropped. IMAP re-runs the whole SEARCH and
    // slices it, so a message arriving between two pages pushes the boundary
    // down and the first row of the new page is the last row of the old one.
    //
    // A first page is laid over what is already listed rather than replacing
    // it. Each poll reloads page one, and replacing the list threw away every
    // page loaded since — and the marks on them, which are filtered against
    // the list. A navigation empties the list first, so there it is the page.
    var merged = append ? Model.appendPage(root.messages, summaries)
      : Model.mergeFirstPage(root.messages, summaries, root.maxMessages)
    var arrivals = append ? [] : Model.newArrivals(summaries, seenIds, notificationsPrimed)

    var seen = {}
    for (var i = 0; i < merged.length; i++) seen[merged[i].id] = true
    // Ids already seen are kept so a message that scrolls off the first page
    // does not get announced again when it comes back.
    for (var key in seenIds) seen[key] = true
    seenIds = seen
    notificationsPrimed = true

    // Assigned only when something a row draws actually differs. `messages` is
    // a plain array bound to a Repeater, so a new array identity destroys and
    // recreates every delegate — twenty-seven objects a row, three of them
    // Canvas icons and three tooltip Popups — and a poll that found nothing
    // new was doing exactly that, once per account per refresh.
    if (!Model.sameList(root.messages, merged)) messages = merged
    listLoaded = true
    lastError = ""
    lastSyncedMs = Date.now()
    listRefreshed()

    if (notifyNewMail && arrivals.length > 0) notify(arrivals)
  }

  function loadMore() {
    if (!hasMore || listLoading) return
    loadMessages(true)
  }

  // --------------------------------------------------------------- detail

  function select(id) {
    var messageId = String(id || "")
    if (messageId === "") {
      clearSelection()
      return
    }
    // Re-selecting what is already open does nothing. It used to blank every
    // body property and fetch the whole message again, so clicking the open
    // row — or answering from the list a message the list had already opened —
    // flashed the reader back to a skeleton and paid for a second fetch to
    // arrive at what was on screen.
    if (messageId === selectedId && selectedMessage) return
    selectedId = messageId
    var serial = ++detailSerial
    abortRequest(detailHandle)
    abortRequest(inviteHandle)
    inviteHandle = null
    selectedMessage = null
    selectedBody = { text: "", source: "" }
    selectedHtml = ""
    selectedDocument = null
    sourceHtml = ""
    remoteImagesAllowed = alwaysShowImages
    selectedBlockedImages = 0
    selectedRemoteImages = 0
    selectedImages = []
    selectedAttachments = []
    selectedInvite = null
    selectedUnsubscribe = null
    unsubscribeDone = ""
    detailLoading = true

    // A message that has been opened before opens from its file, usually well
    // before Gmail answers. The read is asynchronous, so the live copy can win
    // the race — in which case the cached one is simply dropped rather than
    // painted over what is already correct.
    detailLive = false
    detailCached = false
    // The fetch is started from inside this callback rather than beside it,
    // because what to ask the server for depends on what the file held and the
    // read is asynchronous. `FileView` answers exactly once either way — a hit
    // through onLoaded, a miss through onLoadFailed — so the fetch is started
    // exactly once too.
    bodyCache.read(messageId, function(cached) {
      if (serial !== root.detailSerial) return
      if (!cached) {
        root.fetchDetail(messageId, serial)
        return
      }
      // The text is read out of the cached markup rather than taken off the
      // disk beside it, on the same grounds the document is: what the cache
      // holds is the sender's HTML, so a fix to how a message reads reaches
      // every message already there instead of only the ones fetched after it.
      // Both readings come off the one parse, and the picture list comes with
      // them — a marker and the list it points into have to be numbered by the
      // same walk or a marker opens somebody else's picture.
      var reread = root.renderSource(cached.html, cached.source === "html")
      root.selectedBody = reread.plainText
        ? ({ text: reread.plainText.text, source: "html" })
        : ({ text: cached.text, source: cached.source })
      root.selectedAttachments = cached.attachments
      root.selectedImages = reread.plainText ? reread.plainText.images : cached.images
      // The invitation and the unsubscribe offer are read out of the same
      // fetch as the body and never change either, so a message opened before
      // shows its card at the same moment it shows its text rather than a
      // second later when the network agrees.
      root.selectedInvite = cached.invite
      root.selectedUnsubscribe = cached.unsubscribe
      // The row the list already has, which is the summary the reader's header
      // and toolbar are gated on. Without it the cache painted the body
      // properties into a reader still drawing its skeleton, because every
      // visible part of the reader is `visible: !!summary` — so the cache
      // saved one sanitize parse and nothing anybody could see, and the
      // message appeared only when the network answered.
      var known = Model.indexById(root.messages, messageId, root.accountId)
      var plan = Model.detailFetchPlan(true, known >= 0)
      if (plan.paintNow) {
        root.detailCached = true
        root.selectedMessage = root.messages[known]
        root.detailLoading = false
      }
      bodyCache.touch(messageId)
      root.fetchDetail(messageId, serial)
    })
  }

  // What is still worth asking the server. A body never changes once fetched,
  // which is what makes the cache correct — so after a hit the only thing left
  // that can have changed is whether the message is still unread, and that is
  // a summary fetch. On IMAP the difference is a `BODY.PEEK[HEADER]` rather
  // than a `BODY.PEEK[]` of the whole message; on Gmail it is the metadata
  // query rather than the full one.
  function fetchDetail(messageId, serial) {
    if (serial !== root.detailSerial) return
    var plan = Model.detailFetchPlan(root.detailCached, root.detailCached)
    var whole = plan.whole
    // Whether this open should also mark the message read, decided from the
    // row the list holds rather than from the answer that has not arrived. On
    // a provider that folds it, the STORE goes out on the fetch's own
    // connection; everywhere else this stays false and the separate call below
    // does it once the answer says the message really was unread.
    var known = Model.indexById(root.messages, messageId, root.accountId)
    var wasUnread = known >= 0 && root.messages[known].unread === true
    var folded = root.fetchMarksRead && wasUnread

    detailHandle = api.getMessage(messageId, whole, function(payload, error) {
      if (serial !== root.detailSerial) return
      root.detailLoading = false
      root.detailLive = true
      if (error || !payload) {
        // A message the cache already drew is on screen and correct. Saying
        // the open failed over the top of it would be a notice about nothing
        // the user can see, and would blank a reader that is working.
        if (plan.reportFailure) root.fail(error || "Could not open that message")
        return
      }
      // Stamped like every other summary. This one is built fresh from the
      // fetched message rather than taken from the list, so without this the
      // row loses its account the moment it is opened — the stripe saying
      // which mailbox it came from disappeared on read, and `replaceById`
      // fell back to matching on the id alone.
      var summary = root.tagOwnership([Mail.summarize(payload, new Date())])[0]
      root.selectedMessage = summary

      // The whole message was not asked for, so there is no body in this
      // payload to read. Everything below it — the parse, the attachments, the
      // invitation, the cache write — would be reading a message that was not
      // fetched, and would overwrite what the cache correctly drew with
      // nothing. The list row and the read flag are all this answer carries.
      if (!whole) {
        root.messages = Model.replaceById(root.messages, summary)
        root.markOpenedRead(messageId, summary, folded)
        return
      }

      var decoded = Mail.extractBody(payload.payload)
      var rawHtml = Mail.extractHtml(payload.payload)
      // Both readings of the body out of one parse. The markers in the
      // plain-text one and the pictures they stand for are numbered by the same
      // walk over the same tree, so a marker cannot open somebody else's image
      // — and it is only asked for when the text came from the HTML, because a
      // message that shipped its own text/plain part never had images in it.
      // A body never changes once fetched, which is what makes the cache
      // correct — so when the cache already painted this exact markup there is
      // nothing here to paint again, and rendering it would be a second parse
      // of the whole message to arrive at the document already on screen.
      if (rawHtml !== root.sourceHtml || root.selectedDocument === null) {
        var ready = root.renderSource(rawHtml, decoded.source === "html")
        if (ready.plainText) decoded = ({ text: ready.plainText.text, source: "html" })
        root.selectedBody = decoded
        root.selectedImages = ready.plainText ? ready.plainText.images : []
      }
      root.selectedAttachments = Mail.attachments(payload.payload)
      root.selectedInvite = Calendar.fromPayload(payload.payload)
      root.selectedUnsubscribe = Unsub.fromMessage(payload)
      // What the reader is showing, which is not `decoded` when the cache had
      // already painted this markup: that text came from `Mail.extractBody`'s
      // own flattening, and its images are numbered by a different walk than
      // the list beside it here.
      var record = ({
        text: root.selectedBody.text,
        source: root.selectedBody.source,
        html: rawHtml,
        attachments: root.selectedAttachments,
        images: root.selectedImages,
        invite: root.selectedInvite,
        unsubscribe: root.selectedUnsubscribe
      })
      bodyCache.put(messageId, record)
      // Gmail describes the calendar part rather than sending it whenever the
      // organiser's calendar named the file, which Google's own does — so the
      // meeting is one request away, and the card lands a moment after the
      // message it belongs to. The cache is written again with it, so it is
      // there at once the next time this message is opened.
      root.loadInvite(messageId, serial, Calendar.pendingPart(payload.payload), record)
      root.messages = Model.replaceById(root.messages, summary)
      root.markOpenedRead(messageId, summary, folded)
    }, folded)
  }

  // Opening a message is the one place Gmail's own clients mark it read
  // without being asked, and a reader that leaves it bold is confusing.
  //
  // Where the fetch carried the STORE, the server has already been told and
  // there is nothing to send — but the answer describes the message as it was
  // *before* that STORE, because the FETCH ran first so a BODY.PEEK would read
  // an unread message as unread. So the row is corrected here rather than left
  // showing a flag the server no longer holds.
  function markOpenedRead(messageId, summary, folded) {
    if (!summary || !summary.unread) return
    if (!folded) {
      root.act(messageId, "markRead", true)
      return
    }
    var read = Model.applyLabelChange(summary, "markRead")
    root.selectedMessage = read
    root.messages = Model.replaceById(root.messages, read)
    root.refreshCounts()
  }

  // The invitation the message pointed at. Nothing happens for the messages
  // that are not one — `pendingPart` is null unless a calendar part arrived
  // with an id in place of its octets — and the file is asked for once, at the
  // size the part already declared.
  function loadInvite(messageId, serial, part, record) {
    if (!part) return
    inviteHandle = api.getAttachment(messageId, String(part.body.attachmentId),
      function(data, error) {
        if (serial !== root.detailSerial) return
        root.inviteHandle = null
        if (error || !data) return
        var invite = Calendar.fromAttachment(part, data)
        if (!invite) return
        root.selectedInvite = invite
        record.invite = invite
        bodyCache.put(messageId, record)
      })
  }

  // The one place `selectedHtml` is set, and the only place the sender's markup
  // is parsed on the way to the screen. Everything else the reader needs to
  // know about this body comes back from the same call — how heavy it is, and
  // its plain-text reading — because each of those asked separately is another
  // parse of the whole message to work out what was just worked out.
  function renderSource(source, withPlainText) {
    sourceHtml = String(source || "")
    var ready = Html.sanitize(sourceHtml, ({
      allowRemoteImages: remoteImagesAllowed,
      withPlainText: withPlainText === true
    }))
    selectedHtml = ready.html
    selectedDocument = ready.document
    selectedBlockedImages = ready.blockedImages
    selectedRemoteImages = ready.remoteImages
    selectedTooHeavy = ready.tooHeavy
    return ready
  }

  // ------------------------------------------------------- attachments

  // Which attachment is being written, so the row can say so and a second
  // click cannot start a second write of the same file.
  property string savingAttachment: ""

  readonly property string downloadDirectory: {
    var named = Quickshell.env("XDG_DOWNLOAD_DIR")
    if (named && named !== "") return named
    return Quickshell.env("HOME") + "/Downloads"
  }

  // Save one attachment. Opening it is a separate, explicit offer.
  //
  // For IMAP this costs no request: the whole message was fetched to read it,
  // so `getAttachment` walks the MIME tree it already holds. Gmail describes a
  // part rather than sending it, so there the octets are one call away — which
  // is why this is asynchronous for both rather than only for the one that
  // needs to be.
  function saveAttachment(attachmentId) {
    var wanted = String(attachmentId || "")
    if (wanted === "" || selectedId === "" || savingAttachment !== "") return
    if (!ready) {
      fail("Sign in before saving an attachment")
      return
    }

    var record = null
    var list = Array.isArray(selectedAttachments) ? selectedAttachments : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].attachmentId) === wanted) record = list[i]
    }
    if (!record) return

    clearNotice()
    savingAttachment = wanted
    var messageId = selectedId

    api.getAttachment(messageId, wanted, function(data, error) {
      // The reader moved on. The file would still be correct, but offering to open a
      // file for a message the user has left is not what the click asked
      // for.
      if (messageId !== root.selectedId) {
        root.savingAttachment = ""
        return
      }
      if (error || !data) {
        root.savingAttachment = ""
        root.fail(error || "That attachment is no longer in the message")
        return
      }
      // The name goes in on stdin beside the octets, not as an argument: the
      // sender wrote it, and every local account can read a process's
      // arguments in /proc.
      attachmentWriter.filename = record.filename
      attachmentWriter.payload = Mail.encodeBase64(record.filename) + " " + data
      attachmentWriter.command = [root.pluginDir + "/scripts/save-attachment.sh",
        root.downloadDirectory]
      attachmentWriter.running = true
    })
  }

  Process {
    id: attachmentWriter

    property string payload: ""
    property string filename: ""
    // The saved name, which is not always the one asked for: a name already
    // taken gets a counter, and the script prints what it used.
    property string savedAs: ""

    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        var name = String(line || "").trim()
        if (name !== "") attachmentWriter.savedAs = name
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "").trim()
        // The script's own messages are prefixed with its name, which is not
        // something to show anybody.
        if (text !== "") attachmentWriter.savedAs = ""
      }
    }

    onStarted: {
      write(payload + "\n")
      payload = ""
    }

    onExited: function(code) {
      payload = ""
      root.savingAttachment = ""
      var name = savedAs !== "" ? savedAs : filename
      savedAs = ""
      if (code === 0) {
        root.note("Saved " + name + " to Downloads")
        root.openPath = Model.savedPath(root.downloadDirectory, name)
        // Counted again from here, at the longer interval the offer earns.
        noticeTimer.restart()
      } else root.fail("Could not save " + filename)
      filename = ""
    }
  }

  // Takes the Open offer beside a save notice. The path is read before it is
  // spent, and goes to the process as one argument.
  function openSaved() {
    var command = Model.openCommand(openPath)
    openPath = ""
    if (command.length > 0) Quickshell.execDetached(command)
  }

  function showRemoteImages() {
    if (remoteImagesAllowed || sourceHtml === "") return
    remoteImagesAllowed = true
    renderSource(sourceHtml)
  }

  function clearSelection() {
    detailSerial++
    abortRequest(detailHandle)
    detailHandle = null
    abortRequest(inviteHandle)
    inviteHandle = null
    selectedId = ""
    selectedMessage = null
    selectedBody = { text: "", source: "" }
    selectedHtml = ""
    selectedDocument = null
    sourceHtml = ""
    remoteImagesAllowed = false
    selectedImages = []
    selectedBlockedImages = 0
    selectedRemoteImages = 0
    selectedTooHeavy = false
    selectedAttachments = []
    selectedInvite = null
    selectedUnsubscribe = null
    unsubscribeDone = ""
    detailLoading = false
  }

  // The cursor is the list's own position and moves relative to itself.
  // `selectedId` keeps its separate meaning: which message the reader shows.
  function cursorOffset(cursorKey, delta) {
    return Model.cursorAfterOffset(messages, cursorKey, delta)
  }

  // Whether a row stays in the list on screen after `action`. The window asks
  // this too, to move its cursor the same way the list is about to move.
  function survives(action) {
    return Model.survivesAction(viewKey, action, movesBetweenFolders)
  }

  function viewStamp() {
    return Model.viewStamp(viewSerial, viewKey)
  }

  // Every address this mailbox sends as, for telling its own mail from mail
  // it received.
  function ownAddresses() {
    var out = []
    if (ownAddress !== "") out.push(ownAddress)
    var aliases = availableSendAsAliases
    for (var i = 0; i < aliases.length; i++) {
      if (aliases[i] && aliases[i].email) out.push(String(aliases[i].email))
    }
    return out
  }

  // -------------------------------------------------------------- actions

  // Every action moves the list immediately and reconciles afterwards. Waiting
  // for Google before the row moves makes the panel feel broken on a slow
  // connection, and the failure path puts the row back.
  // `restoreFolder` is only ever set by `undo`, which is the one caller that
  // knows where a message was before it was moved. Everything else acts on a
  // row that is still where it belongs, so the id already says.
  function act(id, action, quiet, restoreFolder) {
    var messageId = String(id || "")
    if (!ready || messageId === "") return
    var index = Model.indexById(messages, messageId, root.accountId)
    if (index < 0) return
    var before = messages[index]
    var updated = Model.applyLabelChange(before, action)
    var survives = root.survives(action)
    var view = viewStamp()
    // Untrashing from the Trash mailbox, where nothing recorded where the
    // message had been. Sent mail goes back to Sent rather than to INBOX.
    var folder = String(restoreFolder || "")
    if (action === "untrash" && folder === "")
      folder = Model.untrashFolder(before, ownAddresses())

    if (action === "markRead" && before.unread) inboxUnread = Math.max(0, inboxUnread - 1)
    if (action === "markUnread" && !before.unread) inboxUnread = inboxUnread + 1

    // An action the user did not ask for must never move them. Opening an
    // unread message marks it read, and being read is the very thing that
    // disqualifies it from the unread list — so evicting it there would close
    // the reader that the click had just opened. The row stays until the list
    // is next loaded, which is also what Gmail's own clients do.
    var keepOpen = quiet === true && selectedId === messageId
    var removed = !survives && !keepOpen

    if (removed) messages = Model.removeById(messages, messageId, root.accountId)
    else messages = Model.replaceById(messages, updated)
    if (selectedId === messageId) {
      if (removed) clearSelection()
      else selectedMessage = updated
    }

    // Back into the list it left, and only that one: after a navigation the
    // row belongs to a mailbox that is no longer drawn, and its index means
    // nothing in the rows that replaced it.
    function restore(error) {
      if (Model.sameView(view, root.viewStamp()))
        root.messages = Model.revertRows(root.messages,
          [Model.undoEntry(before, index)], removed)
      root.refreshCounts()
      root.fail(error)
    }

    // Taken from the row while it still had an index and a folder, which is the
    // whole reason undo can be honest: after the call the row is out of the
    // list, and on IMAP the message has moved to another folder under a UID
    // this client is never told. A record rebuilt afterwards would be a guess.
    var undo = quiet === true || !canUndo ? null
      : Model.undoRecordFor(action, [Model.undoEntry(before, index)], viewKey, view)

    pendingAction = action
    var done = function(payload, error) {
      root.pendingAction = ""
      if (error) {
        restore(error)
        return
      }
      if (!quiet) root.note(root.actionLabel(action), undo)
      root.refreshCounts()
    }

    if (action === "trash") api.trashMessage(messageId, done)
    // The folder it came from, not a guess. Untrashing moved every message to
    // INBOX once, so undoing a trash from Archive put the message somewhere it
    // had never been. Gmail names no folder and is handed none.
    else if (action === "untrash") api.untrashMessage(messageId, done, folder)
    else {
      var change = Model.labelChangesFor(action)
      if (!change) {
        pendingAction = ""
        return
      }
      api.modifyMessage(messageId, change.add, change.remove, done)
    }
  }

  // The same action over a set, in one request rather than one per message.
  // Shaped like `act` deliberately — optimistic first, reconcile after, put it
  // back on failure — because the two are one behaviour at two sizes and a
  // second shape would be a second set of bugs.
  //
  // What is different is the reporting. A batch can genuinely land on part of
  // a set: Gmail has no batch trash so that path is a request per message, and
  // `--fail-early` in the IMAP transport stops a folded sequence at its first
  // failure. So the clients hand back how many actually moved, and the notice
  // says "9 of 12 moved to trash" rather than claiming the set.
  //
  // Ids rather than keys, because this is inside one account: the account half
  // of the key was resolved at the Service boundary, which is where the set
  // was filtered to this mailbox in the first place.
  function actOnMany(ids, action) {
    var wanted = Array.isArray(ids) ? ids : []
    if (!ready || wanted.length === 0) return
    var verb = String(action || "")
    if (verb === "") return

    var beforeUnread = inboxUnread
    var survives = root.survives(verb)
    var view = viewStamp()
    var next = []
    var touched = 0
    // Every touched row with its index, for putting back on a refusal; the
    // undo offer is the same entries, kept only where undo is offered at all.
    var entries = []
    var folders = {}
    for (var i = 0; i < messages.length; i++) {
      var row = messages[i]
      if (wanted.indexOf(row.id) < 0) {
        next.push(row)
        continue
      }
      touched++
      // The entry is built here, in the same pass and before the request, for
      // the reason the single-message path builds its own early: afterwards the
      // row is out of the list, and on IMAP it carries a UID this client is
      // never told. Rebuilt later it would be a guess.
      entries.push(Model.undoEntry(row, i))
      if (verb === "untrash") folders[row.id] = Model.untrashFolder(row, ownAddresses())
      if (verb === "markRead" && row.unread) inboxUnread = Math.max(0, inboxUnread - 1)
      if (verb === "markUnread" && !row.unread) inboxUnread = inboxUnread + 1
      // The reader is showing one of these and it is about to leave the list.
      // Closing it here rather than after the request lands keeps the row and
      // what is on screen telling the same story while the network works.
      if (!survives && selectedId === row.id) clearSelection()
      if (survives) next.push(Model.applyLabelChange(row, verb))
    }
    if (touched === 0) return
    messages = next

    // Only the touched rows, and only into the list they came from: a poll
    // may have refreshed the rest meanwhile, and after a navigation none of
    // these rows belongs to what is on screen.
    function restore(error) {
      if (Model.sameView(view, root.viewStamp())) {
        root.messages = Model.revertRows(root.messages, entries, !survives)
        root.inboxUnread = beforeUnread
      }
      root.refreshCounts()
      root.fail(error)
    }

    pendingAction = verb
    var done = function(payload, error) {
      root.pendingAction = ""
      var moved = payload && payload.done !== undefined
        ? Math.max(0, Math.floor(Number(payload.done) || 0))
        : (error ? 0 : touched)
      // Nothing landed, so nothing on screen should look as though it did.
      // A partial result keeps its rows where they went: putting nine trashed
      // messages back because three failed would be a worse lie than the one
      // this is avoiding.
      if (moved === 0) {
        restore(error || "Nothing changed")
        return
      }
      if (error) root.lastError = error
      // The offer stands only when the whole set moved. After a partial the
      // record names messages that never left, and restoring those would move
      // mail the user never trashed — so the honest notice is the count alone,
      // with no button beside it.
      root.note(Model.bulkResultLabel(verb, moved, touched),
        canUndo && Model.offersUndoAfterBulk(moved, touched)
          ? Model.undoRecordFor(verb, entries, viewKey, view) : null)
      root.refreshCounts()
      // A partial failure leaves the list disagreeing with the server about
      // the messages that did not move, and only the server knows which.
      if (moved < touched) root.refresh()
    }

    if (verb === "trash") {
      api.batchTrash(wanted, done)
      return
    }
    if (verb === "untrash") {
      // No provider offers a batch untrash, so this is the one action that
      // stays a request per message. Counted the same way, so the notice reads
      // the same whichever route it took.
      var remaining = wanted.length
      var restored = 0
      var firstError = ""
      for (var u = 0; u < wanted.length; u++) {
        api.untrashMessage(wanted[u], function(payload, error) {
          if (error && firstError === "") firstError = error
          if (!error) restored++
          remaining--
          if (remaining === 0) done({ done: restored }, firstError)
        }, folders[wanted[u]] || "")
      }
      return
    }
    var change = Model.labelChangesFor(verb)
    if (!change) {
      pendingAction = ""
      messages = Model.revertRows(messages, entries, !survives)
      return
    }
    api.batchModify(wanted, change.add, change.remove, done)
  }

  // Takes back what the notice is offering to take back, and nothing else: the
  // record is the only input, so there is no "last action" to reconstruct and
  // no way for this to act on a message the offer was never about.
  //
  // Not routed through `act`, which acts on a row it can find in the list — and
  // the whole point of an undo is that the row has already left. The shape is
  // the same otherwise: put the list back first so the panel answers at once,
  // then reconcile, and take the rows out again if the server refuses.
  function undo() {
    if (!ready || undoBusy) return
    var record = undoRecord
    if (!Model.isUndoable(record)) return
    var entries = record.entries
    var reverse = record.reverse
    // Taken from another mailbox than the one on screen, the restore still
    // happens on the server — that is what was offered — but the rows are not
    // inserted into a list they were never in. A refresh afterwards shows them
    // if they do belong here.
    var view = viewStamp()
    var here = Model.undoRestoresHere(record, view)

    // The offer is spent the moment it is taken. Leaving it up would let a
    // second press ask the server to restore what it is already restoring.
    undoRecord = null
    undoBusy = true
    if (here) messages = Model.restoreEntries(messages, entries)

    var remaining = entries.length
    var firstError = ""
    var settle = function() {
      remaining--
      if (remaining > 0) return
      root.undoBusy = false
      if (firstError !== "") {
        // The server kept the message where it was put, so the list must not
        // claim otherwise. The rows go back out and the reason is shown —
        // from the list they were put into, if it is still the one on screen.
        if (here && Model.sameView(view, root.viewStamp())) {
          for (var i = 0; i < entries.length; i++) {
            root.messages = Model.removeById(root.messages, entries[i].id,
              root.accountId)
          }
        }
        root.fail(firstError)
        return
      }
      root.note(root.actionLabel(reverse))
      root.refreshCounts()
      if (!here) root.refresh()
    }

    for (var i = 0; i < entries.length; i++) {
      (function(entry) {
        var done = function(payload, error) {
          if (error && firstError === "") firstError = String(error)
          settle()
        }
        // The folder it came from travels with the entry, because the trash is
        // what destroyed that fact: on IMAP the message is in Trash now, and
        // nothing in its new address says where it had been.
        if (reverse === "untrash")
          api.untrashMessage(entry.id, done, entry.folder, entry.messageId)
        else settle()
      })(entries[i])
    }
  }

  function actionLabel(action) {
    if (action === "archive") return "Archived"
    if (action === "trash") return "Moved to trash"
    if (action === "untrash") return "Restored"
    if (action === "star") return "Starred"
    if (action === "unstar") return "Unstarred"
    if (action === "markRead") return "Marked read"
    if (action === "markUnread") return "Marked unread"
    if (action === "spam") return "Reported as spam"
    return "Done"
  }

  function toggleStar(id) {
    var index = Model.indexById(messages, id, root.accountId)
    if (index < 0) return
    act(id, messages[index].starred ? "unstar" : "star")
  }

  function toggleRead(id) {
    var index = Model.indexById(messages, id, root.accountId)
    if (index < 0) return
    act(id, messages[index].unread ? "markRead" : "markUnread")
  }

  function markAllRead() {
    if (!ready || messages.length === 0) return
    var ids = []
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].unread) ids.push(messages[i].id)
    }
    if (ids.length === 0) return
    var survives = root.survives("markRead")
    var view = viewStamp()
    var entries = []
    var next = []
    for (var j = 0; j < messages.length; j++) {
      if (messages[j].unread) entries.push(Model.undoEntry(messages[j], j))
      next.push(Model.applyLabelChange(messages[j], "markRead"))
    }
    // Only the unread rows leave a list that drops read mail; the rest were
    // already read and stay. Emptying the whole list took them with it.
    var kept = []
    for (var k = 0; k < next.length; k++) {
      if (survives || !messages[k].unread) kept.push(next[k])
    }
    messages = kept
    pendingAction = "markRead"
    api.batchModify(ids, [], ["UNREAD"], function(payload, error) {
      root.pendingAction = ""
      if (error) {
        // Back into the list it was taken from, and nowhere else.
        if (Model.sameView(view, root.viewStamp()))
          root.messages = Model.revertRows(root.messages, entries, !survives)
        root.fail(error)
        return
      }
      root.note(Model.pluralize(ids.length, "message") + " marked read")
      root.refreshCounts()
    })
  }

  // ---------------------------------------------------------------- reply

  // One entry point for every kind of outgoing message. Reply, reply-all and
  // forward differ only in what the compose window puts in the fields, which
  // is where that decision belongs.
  function send(fields) {
    if (!ready || sending) return
    var values = fields || ({})
    var body = Mail.outgoingBody(values.body)
    if (body === "") {
      fail("Write something before sending")
      return
    }
    var to = String(values.to || "").trim()
    if (to === "") {
      fail("Add a recipient first")
      return
    }
    // The display name is read back off the alias list rather than taken from
    // the compose form: the list is what `isSendAsAllowed` just checked, so the
    // name on the message cannot disagree with the address that was allowed.
    var from = String(values.from || "").trim()
    var alias = from === "" ? null : Api.sendAsFor(availableSendAsAliases, from)
    if (from !== "" && !alias) {
      fail("Choose a valid From address")
      return
    }
    sending = true
    root.dispatchSend(values.draftId, Mail.buildSendPayload({
      from: from,
      fromName: alias ? String(alias.displayName || "") : "",
      to: to,
      cc: String(values.cc || "").trim(),
      subject: String(values.subject || ""),
      body: body,
      threadId: values.threadId,
      inReplyTo: values.inReplyTo,
      references: values.references
    }), function(payload, error) {
      root.sending = false
      if (error) {
        root.fail(error)
        return
      }
      root.note(root.sentNote(payload))
      root.replySent()
    }, function(copyError) {
      // Heard after "Sent", and only when something went wrong: the message
      // has gone either way, and a copy that landed needs no sentence.
      if (copyError) root.note("Sent, but no copy was kept in Sent: " + copyError)
    })
  }

  signal replySent()

  // ---------------------------------------------------------------- drafts

  // A send from a saved draft goes through the draft, so the provider can
  // remove it as part of sending: one request on Gmail, a send and then a
  // removal on IMAP. Anything else is an ordinary send.
  //
  // `filed` hears how the Sent copy went, on a provider that files one itself
  // after the send has been answered; Gmail never calls it.
  function dispatchSend(draftId, payload, callback, filed) {
    var id = String(draftId || "")
    if (id === "") return api.sendMessage(payload, callback, filed)
    return api.sendDraft(id, payload, function(result, error) {
      if (!error) root.refreshDrafts()
      callback(result, error)
    }, filed)
  }

  // "Sent" is the whole sentence only when everything that goes with a send
  // happened. The message is gone either way, so what did not land is said
  // beside it rather than as a failure. The Sent copy is told apart, through
  // `dispatchSend`'s `filed`, because it lands after this.
  function sentNote(result) {
    var answer = result || ({})
    if (answer.draftError) return "Sent, but the draft is still in Drafts: " + answer.draftError
    return "Sent"
  }

  // A row in the list is a draft this mailbox can reopen into compose.
  function isDraft(id) {
    if (!canDraft) return false
    var index = Model.indexById(messages, id, accountId)
    return index >= 0 && messages[index].isDraft === true
  }

  // The Drafts mailbox on screen is a list of what was saved, and a save, a
  // send or a discard changes it. Only that mailbox: anywhere else nothing a
  // draft did is on screen.
  function refreshDrafts() {
    if (mailboxKey === "drafts" && searchQuery === "" && rawQuery === "") refresh()
  }

  // The stored message, as the fields a compose window is filled from, plus
  // the id a save or a send addresses — which on Gmail is the draft's and not
  // the message's, so it is asked for.
  function openDraft(id, callback) {
    var messageId = String(id || "")
    if (!ready || !canDraft || messageId === "") {
      if (typeof callback === "function") callback(null, "This mailbox cannot keep drafts")
      return
    }
    api.getMessage(messageId, true, function(payload, error) {
      if (error || !payload) {
        root.fail(error || "Could not open that draft")
        if (typeof callback === "function") callback(null, error || "Could not open that draft")
        return
      }
      var fields = Draft.fieldsFromMessage(payload)
      api.draftIdFor(messageId, function(draftId, lookupError) {
        if (lookupError || !draftId) {
          root.fail(lookupError || "That draft is no longer in the mailbox")
          if (typeof callback === "function") callback(null, lookupError)
          return
        }
        fields.draftId = draftId
        if (typeof callback === "function") callback(fields, "")
      })
    })
  }

  // Saves the window's fields as the draft `draftId` names, or as a new draft
  // when it names none. The answer's `id` is what the next save and the send
  // address: Gmail keeps one, IMAP issues a new one with every copy stored.
  //
  // The From is checked against the alias list for the same reason a send
  // checks it — a stored draft is the message Send would build.
  function saveDraft(draftId, token, fields, callback) {
    if (!ready || !canDraft) {
      if (typeof callback === "function") callback(null, "This mailbox cannot keep drafts")
      return
    }
    var values = fields || ({})
    var from = String(values.from || "").trim()
    var alias = from === "" ? null : Api.sendAsFor(availableSendAsAliases, from)
    api.saveDraft(String(draftId || ""), Draft.payload({
      from: alias ? from : "",
      fromName: alias ? String(alias.displayName || "") : "",
      to: String(values.to || "").trim(),
      cc: String(values.cc || "").trim(),
      subject: String(values.subject || ""),
      body: String(values.body || ""),
      threadId: values.threadId,
      inReplyTo: values.inReplyTo,
      references: values.references
    }, token), function(result, error) {
      if (!error) root.refreshDrafts()
      if (typeof callback === "function") callback(result, error)
    })
  }

  // Discarding a saved draft removes it from the server. A failure is said,
  // because the draft is then still sitting in Drafts after the user threw it
  // away.
  function deleteDraft(draftId, callback) {
    var id = String(draftId || "")
    if (!ready || !canDraft || id === "") {
      if (typeof callback === "function") callback("")
      return
    }
    api.deleteDraft(id, function(ignored, error) {
      if (error) root.fail("The draft could not be removed from Drafts: " + error)
      else root.refreshDrafts()
      if (typeof callback === "function") callback(error || "")
    })
  }

  // ------------------------------------------------------------------ RSVP

  // Answering an invitation is sending a mail, which is the whole reason this
  // needs no calendar API, no second OAuth scope, and works the same on IMAP
  // as on Gmail: an RFC 5546 REPLY addressed to the organiser is what every
  // calendar server is already listening for.
  //
  // Not routed through `send`: that one is the compose window's, and finishing
  // emits `replySent`, which closes it. This finishes with a card that has
  // changed its mind.
  function rsvp(response) {
    if (!ready || rsvpSending || !canRespondToInvite) return
    var answer = String(response || "")
    // The alias the invitation was addressed to, not the account's primary
    // address: the ATTENDEE line has to name the person who was invited.
    var answeringAs = receivedAsAddress
    var answeringName = receivedAsName
    var fields = Calendar.replyFields(selectedInvite,
      ({ email: answeringAs, name: answeringName }), answer)
    if (!fields) {
      fail("This invitation names no organiser to answer")
      return
    }

    // The message the answer belongs to, held so a reply that lands after the
    // reader has moved on does not mark a different message answered.
    var messageId = selectedId
    var invited = selectedInvite
    var summary = selectedMessage
    rsvpSending = true
    clearNotice()

    api.sendMessage(Mail.buildSendPayload({
      // The ATTENDEE line claims this address; the envelope has to agree, or a
      // strict organiser drops the reply as somebody answering for a third
      // party. Gmail fills a From in for itself, and the IMAP client puts the
      // account on the envelope rather than in the headers — so neither of
      // them would have written this one.
      from: answeringAs,
      fromName: answeringName,
      to: fields.to,
      subject: fields.subject,
      body: fields.body,
      calendar: fields.calendar,
      // Threaded with the invitation it answers, the way a calendar's own
      // reply is. An answer that starts a conversation of its own is one the
      // organiser reads as a second, unrelated mail.
      inReplyTo: summary ? summary.messageId : "",
      threadId: summary ? summary.threadId : ""
    }), function(payload, error) {
      root.rsvpSending = false
      if (error) {
        root.fail(error)
        return
      }
      root.note("Answer sent to " + fields.to)
      if (root.selectedId !== messageId) return
      root.rememberResponse(messageId, invited, answeringAs, answer)
    })
  }

  // The answer, written back into the copy of the invitation on disk.
  //
  // The `text/calendar` part is the organiser's document and this does not
  // rewrite it — but a message reopened tomorrow reading its own file would
  // otherwise show its buttons unanswered, after the answer had been sent and
  // had worked. Everything else in the row is what is already on screen, which
  // is what was cached a moment ago.
  function rememberResponse(messageId, invited, answeringAs, answer) {
    var updated = Calendar.withResponse(invited, answeringAs, answer)
    selectedInvite = updated
    bodyCache.put(messageId, ({
      text: selectedBody.text,
      source: selectedBody.source,
      html: sourceHtml,
      attachments: selectedAttachments,
      images: selectedImages,
      invite: updated,
      unsubscribe: selectedUnsubscribe
    }))
  }

  // ----------------------------------------------------------- unsubscribe

  // Three ways off a list, and `Unsubscribe.plan` picks between them so that
  // nothing here branches on a header. In order of how little the user has to
  // do: a POST the sender has promised is enough, a message to the address
  // they nominated, or their page in a browser.
  function unsubscribe() {
    if (unsubscribing || unsubscribeDone !== "") return
    var info = selectedUnsubscribe
    var how = Unsub.plan(info, canSend)
    if (how === "") return
    clearNotice()
    // The message the request is about. The reader can move on while the
    // request is out, and the answer must not mark whatever is open by then
    // as the one that was unsubscribed from.
    var about = selectedId

    if (how === "browser") {
      Qt.openUrlExternally(info.url)
      // What happened is that a page opened. Whether the list acted on it is
      // between the user and that page, and saying "unsubscribed" here would
      // be this panel taking credit for work it cannot see.
      unsubscribeDone = "The unsubscribe page is open in your browser"
      return
    }

    if (how === "mail") {
      if (!ready) {
        fail("Sign in before unsubscribing")
        return
      }
      unsubscribing = true
      api.sendMessage(Mail.buildSendPayload({
        // The address the newsletter was sent to. A list that only ever knew
        // an alias has no reason to act on a request from anywhere else.
        from: receivedAsAddress,
        fromName: receivedAsName,
        to: info.mail.to,
        subject: info.mail.subject,
        body: info.mail.body
      }), function(payload, error) {
        root.unsubscribing = false
        if (error) {
          root.fail(error)
          return
        }
        if (root.selectedId !== about) return
        root.unsubscribeDone = "Unsubscribe request sent to " + info.mail.to
      })
      return
    }

    postUnsubscribe(info.postUrl, about)
  }

  // The RFC 8058 one-click request: a fixed body, to an https address on the
  // public internet that this sender put in a header saying a single POST
  // would do it. `Unsubscribe.isPostableUrl` is where both of those conditions
  // are checked, and it borrows the judgement that decides whether a message
  // may load a picture.
  //
  // The reply is never read beyond its status. It is a document from whoever
  // sent the mail, and the only question being asked of it is whether the
  // address is off the list.
  //
  // `about` is the message open when it was sent; the answer only marks the
  // reader if that message is still the one open.
  function postUnsubscribe(url, about) {
    if (unsubscribePoster.running) return
    unsubscribePoster.about = String(about || "")
    unsubscribing = true
    unsubscribePoster.command = Unsub.postCommand()
    unsubscribePoster.input = Unsub.postInput(url)
    unsubscribePoster.running = true
  }

  // curl, not XMLHttpRequest: QML's request follows a redirect by itself, to
  // any host and over plain http, so a public https address that answered 307
  // sent this POST to a service on the user's own machine or network.
  Process {
    id: unsubscribePoster

    // The message open when the request went out; see postUnsubscribe.
    property string about: ""
    // The address, which goes in on stdin rather than in the command.
    property string input: ""

    stdinEnabled: true
    stdout: StdioCollector { id: posterOutput; waitForEnd: true }

    onStarted: {
      write(input)
      input = ""
    }

    onExited: function(code) {
      root.unsubscribing = false
      var status = code === 0 ? Unsub.postStatus(posterOutput.text) : 0
      if (Unsub.postSucceeded(status)) {
        if (root.selectedId === unsubscribePoster.about) root.unsubscribeDone = "Unsubscribed from this list"
        return
      }
      root.fail(status === 0
        ? "The unsubscribe request could not be sent"
        : "This list refused the unsubscribe request (" + status + ")")
    }
  }

  // -------------------------------------------------------- notifications

  function notify(arrivals) {
    var count = Array.isArray(arrivals) ? arrivals.length : 0
    if (count === 0) return
    Quickshell.execDetached(Model.notificationCommand(count,
      root.pluginDir + "/assets/omail.svg"))
  }

  // ------------------------------------------------------------ navigation

  function selectMailbox(key) {
    if (mailboxKey === key && searchQuery === "" && rawQuery === "") return
    mailboxKey = String(key || "inbox")
    searchQuery = ""
    rawQuery = ""
    viewSerial++
    clearSelection()
    messages = []
    listLoaded = false
    loadMessages(false)
  }

  function search(text) {
    var query = String(text || "").trim()
    if (query === searchQuery && rawQuery === "") return
    searchQuery = query
    // Typing in the search box leaves whatever label was selected.
    rawQuery = ""
    viewSerial++
    clearSelection()
    messages = []
    listLoaded = false
    loadMessages(false)
  }

  // A label on Gmail, a folder on IMAP. One entry point either way, because the
  // sidebar draws one kind of row.
  function selectLabel(name) {
    var query = Provider.labelQuery(providerId, name)
    if (query === "" || query === rawQuery) return
    searchQuery = ""
    rawQuery = query
    viewSerial++
    clearSelection()
    messages = []
    listLoaded = false
    loadMessages(false)
  }

  function openInBrowser(id) {
    Quickshell.execDetached(["xdg-open", Api.webMessageUrl(id, ownAddress)])
  }

  function openWebInbox() {
    Quickshell.execDetached(["xdg-open", Api.webSearchUrl(effectiveQuery, ownAddress)])
  }

  function openCloudConsole() {
    Quickshell.execDetached(["xdg-open", "https://console.cloud.google.com/auth/clients/create"])
  }

  function openConsentScreen() {
    Quickshell.execDetached(["xdg-open", "https://console.cloud.google.com/auth/overview"])
  }

  function openGmailApiPage() {
    Quickshell.execDetached(["xdg-open",
      "https://console.cloud.google.com/apis/library/gmail.googleapis.com"])
  }

  // What both providers do once they are signed in. Named rather than repeated
  // in each component, because the two sign-ins differ in everything except
  // what has to happen afterwards.
  function afterSignIn() {
    loadProfile(true)
    loadLabels()
    loadSendAs()
    refreshCounts()
    loadMessages(false)
  }

  function signIn() { if (auth) auth.beginLogin() }
  function cancelSignIn() { if (auth) auth.cancelLogin() }

  // The setup form's entry point for a password provider. Gmail has no use for
  // it — its sign-in is a browser — and returns false rather than pretending.
  function signInWithPassword(secret) {
    if (!auth || !Provider.usesPassword(providerId)) return false
    return auth.signIn(secret)
  }

  function signOut() {
    // Everything still in the air belongs to the session being ended. Without
    // this a list or a count that was already requested arrived afterwards and
    // put the signed-out mailbox back on screen.
    sessionSerial++
    listSerial++
    // A failed action that lands later must not put rows back into this list.
    viewSerial++
    abortRequest(listHandle)
    listHandle = null
    listLoading = false
    countLoading = false
    nextPageToken = ""
    if (auth) auth.logout()
    messages = []
    labels = []
    sendAsAliases = []
    sendAsLoading = false
    sendAsLoaded = false
    profile = null
    inboxUnread = 0
    listLoaded = false
    seenIds = ({})
    notificationsPrimed = false
    countPrimed = false
    cacheStore.clear()
    bodyCache.clear()
    clearSelection()
  }

  // ------------------------------------------------------------- lifecycle

  // Opening the window runs a profile read, a send-as read and a list load, and
  // becoming ready adds a count — four processes per account, launched in the
  // same tick for every account at once. Five mailboxes is twenty connections
  // opened together, and a server that rations concurrent ones refuses some of
  // them outright: that is the burst the retry and the poll stagger exist to
  // survive, arriving from the one path neither of them covered.
  //
  // So it is spread the way the poll is, by an offset derived from the account
  // id. Under a second across any number of mailboxes, because unlike the poll
  // this one is in front of somebody who has just opened the window.
  readonly property int openOffsetMs: Model.openOffsetMs(root.accountId)

  // What the burst is for, so a stagger has one thing to delay rather than a
  // handler each. Either reason may arrive first, and both may arrive before
  // the timer fires, so they accumulate into the pending set rather than
  // replacing one another.
  property bool openBurstReady: false
  property bool openBurstWindow: false

  onWindowOpenChanged: {
    if (!windowOpen) return
    clearNotice()
    if (!ready) return
    openBurstWindow = true
    openBurst.restart()
  }

  onReadyChanged: {
    if (!ready) return
    openBurstReady = true
    openBurst.restart()
  }

  function runOpenBurst() {
    var becameReady = openBurstReady
    var opened = openBurstWindow
    openBurstReady = false
    openBurstWindow = false
    if (!ready) return

    loadProfile()
    loadSendAs()
    // The count is what the bar badge reads, and it is polled whether or not
    // the window is open — so becoming ready asks for it and opening the
    // window does not need to.
    if (becameReady) refreshCounts()
    if (!active) return
    if (becameReady) loadLabels()
    if (!listLoaded) {
      // A list is worth loading only where one would be looked at. Becoming
      // ready with the window shut leaves it to the open that follows.
      if (windowOpen) loadMessages(false)
    } else if (opened) {
      refresh()
    }
  }

  Timer {
    id: openBurst
    interval: root.openOffsetMs
    repeat: false
    onTriggered: root.runOpenBurst()
  }

  // Becoming the account on screen is what earns a list.
  onActiveChanged: {
    if (!active || !ready) return
    loadLabels()
    loadSendAs()
    if (!listLoaded) loadMessages(false)
    else refresh()
  }

  // The address is only known after the first profile read, and it is what the
  // cache file and the keyring entry are named after. It reaches `accountId`
  // through `accountIdentified` and the account list, never by assigning it
  // here: an assignment breaks the binding to the list, and a host whose id no
  // longer follows its row keeps one mailbox's session after the rows move.

  // The id this object's state was built for. Hosts are kept by position, so
  // removing an account hands every host below it the next account's entry —
  // with the previous one's session, list, profile and unread count still in
  // it. Only a draft learning its own address keeps what it has; any other
  // change of id starts this mailbox from nothing.
  property string boundAccountId: ""
  // Ids assigned while the object is still being built are its first, not a
  // change: there is nothing yet to reset.
  property bool accountIdTracked: false
  Component.onCompleted: {
    boundAccountId = accountId
    accountIdTracked = true
  }

  onAccountIdChanged: {
    if (!accountIdTracked) return
    var previous = boundAccountId
    boundAccountId = accountId
    if (previous === accountId) return
    if (previous === "" && profile
        && Accounts.isSameMailbox(accountId, profile.email, providerId)) return
    resetForAccount()
  }

  function resetForAccount() {
    sessionSerial++
    listSerial++
    // A failed action that lands later must not put rows back into this list.
    viewSerial++
    abortRequest(listHandle)
    listHandle = null
    listLoading = false
    countLoading = false
    nextPageToken = ""
    resultEstimate = 0
    clearSelection()
    clearNotice()
    messages = []
    labels = []
    sendAsAliases = []
    sendAsLoading = false
    sendAsLoaded = false
    profile = null
    inboxUnread = 0
    listLoaded = false
    seenIds = ({})
    notificationsPrimed = false
    countPrimed = false
    if (auth && typeof auth.switchAccount === "function") auth.switchAccount()
  }

  signal accountIdentified(string email)

  // Which pair of objects this account actually runs on. Both loaders build the
  // same two shapes — something that signs in, and something that fetches — and
  // everything above this point calls them without knowing which it holds.
  //
  // Loaders rather than one of each kept side by side: an AuthManager probes
  // for socat and reads the keyring the moment it exists, and an IMAP account
  // has no business doing either.
  Loader {
    id: authLoader
    sourceComponent: root.providerId === "imap" ? imapAuthComponent : gmailAuthComponent
  }

  // The client takes the manager as a required property, so it cannot be built
  // until there is one.
  Loader {
    id: apiLoader
    active: !!authLoader.item
    sourceComponent: root.providerId === "imap" ? imapClientComponent : gmailClientComponent
  }

  Component {
    id: gmailAuthComponent

    AuthManager {
      pluginDir: root.pluginDir
      accountId: root.accountId
      mayAdoptLegacyToken: root.mayAdoptLegacyToken
      oauthPort: root.oauthPort
      loginHint: root.accountEmail

      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onCredentialsSaved: root.note("OAuth client saved")
      onSessionUnavailable: function(reason) { root.fail(reason) }
    }
  }

  Component {
    id: imapAuthComponent

    ImapAuth {
      pluginDir: root.pluginDir
      accountId: root.accountId
      // Normalised here rather than trusted from the file: a host that arrived
      // in a hand-edited accounts.json has to pass the same check as one the
      // user typed into the form.
      settings: Imap.normalizeSettings(root.imapSettings)

      onLoginSucceeded: {
        root.lastError = lastError
        root.afterSignIn()
      }
      onLoggedOut: root.clearNotice()
      onCredentialsSaved: root.note("Mailbox saved")
      onSessionUnavailable: function(reason) { root.fail(reason) }
    }
  }

  Component {
    id: gmailClientComponent
    GmailApiClient { auth: authLoader.item }
  }

  Component {
    id: imapClientComponent
    ImapClient {
      auth: authLoader.item
      email: root.configuredEmail
    }
  }

  CacheStore {
    id: cacheStore
    accountId: root.accountId
    // The file lands after the window is already up, so the first paint waits
    // for it rather than the other way round.
    onRestored: {
      if (!root.profile && store.profile) root.profile = store.profile
      if (root.labels.length === 0 && store.labels.length > 0) root.labels = store.labels
      if (root.messages.length === 0) root.paintFromCache()
    }
  }

  BodyCache {
    id: bodyCache
    pluginDir: root.pluginDir
    accountId: root.accountId
  }

  // The loader has to have built the manager first, which it has not when this
  // component completes.
  onAuthChanged: if (auth) auth.restoreSession()

  // Only ages the "synced" label; nothing else depends on it.
  Timer {
    interval: 30000
    running: root.ready
    repeat: true
    onTriggered: root.syncTick++
  }

  // The offer expires with the sentence that made it. Once this has fired there
  // is no undo left to press: an action taken back minutes after the fact is a
  // message reappearing for no reason anybody can still connect to a keystroke.
  Timer {
    id: noticeTimer
    interval: Model.noticeDurationMs(root.openPath !== "")
    onTriggered: {
      root.actionStatus = ""
      root.undoRecord = null
      root.openPath = ""
    }
  }

  // The unread count is one label read — cheap enough to keep running while
  // the panel is closed, which is the only way the bar badge stays honest.
  // Every account's poll runs on the same interval and starts when the shell
  // does, so without this they fire together forever — and several accounts on
  // one host is exactly the case that produced a refused connection. The offset
  // is derived from the account id so it is stable across restarts rather than
  // random, and it is only ever a fraction of the interval, so a mailbox is
  // never polled meaningfully less often than any other.
  readonly property int pollOffsetMs: Model.pollOffsetMs(root.accountId,
    root.refreshIntervalSec)

  Timer {
    id: pollStagger
    interval: root.pollOffsetMs
    running: root.ready && root.pollOffsetMs > 0
    repeat: false
    onTriggered: pollTimer.start()
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    // Started by the stagger above when there is an offset to wait out, so the
    // first poll of each account lands at a different moment.
    running: root.ready && root.pollOffsetMs === 0
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Every account polls its count, and refreshCounts loads the list for any
      // mailbox whose count has risen — that is what feeds the badge and the
      // notification. An open window keeps its own list current regardless.
      root.refreshCounts()
      if (root.active && root.windowOpen) root.loadMessages(false)
    }
  }
}
