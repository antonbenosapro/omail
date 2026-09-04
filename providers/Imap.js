.pragma library

// What an IMAP mailbox is, as far as the panel is concerned.
//
// The protocol itself is `ImapProtocol.js` and the transport is
// `ImapClient.qml`. This file answers the same four questions `Registry.js`
// asks of every provider, and the answers differ from Gmail's in ways the
// panel has to respect rather than paper over.

var ID = "imap"
var NAME = "IMAP"
var SUMMARY = "Any standard mailbox — Fastmail, iCloud, Outlook, Zoho, your own server."
var AUTH = "password"

var CAPABILITIES = {
  // No labels: a message is in one folder. The reader hides the label strip
  // rather than showing an empty one.
  labels: false,
  // No server-side conversation id. Threading falls back to References, which
  // is what every other IMAP client does.
  threads: false,
  // Only if the server has somewhere to put it, which the client decides per
  // account from what LIST reported; this is the ceiling, not the guarantee.
  archive: true,
  // Deliberately off. IMAP can move a message to a Junk folder, but that
  // teaches the server nothing, and a "Report spam" button that quietly means
  // "move to a folder" is a promise the provider cannot keep.
  spam: false,
  star: true,
  batch: true,
  search: true,
  send: true,
  // No web UI this plugin could know the address of.
  web: false,
  // The transport carries several commands on one connection, so the STORE
  // that marks a message read rides along with the FETCH that opens it.
  fetchMarksRead: true,
  // Off, and this is the same judgement that turns `spam` off: a capability
  // the provider cannot honour is a button it must not draw.
  //
  // A message id here is `<uid>:<folder>`, and a UID is issued by the folder
  // that holds the message. Moving one to Trash therefore gives it a new id,
  // and the server reports that new UID in the tagged OK response — which the
  // transport never sees, because curl removes the tagged completion around a
  // custom IMAP request. So after a trash there is no id that names the
  // message any more: the one the panel holds addresses a UID that is gone
  // from the folder it names, and the undo would move nothing while reporting
  // success.
  //
  // Making this true means teaching the client to find the message again —
  // a SEARCH of the Trash folder for its Message-ID — and that is a fetch this
  // has no reason to make until somebody is standing behind the button. The
  // seam is here, declared off, rather than absent.
  undo: false
}

// Folders, not queries. The `folder:` DSL is read by `ImapProtocol.parseQuery`
// and by nothing else — everywhere above, these strings are opaque, handed
// back to the client that produced them and used as a cache key.
//
// The names here are fallbacks. A server that advertises SPECIAL-USE (RFC 6154)
// names its own Sent, Trash and Archive, and `ImapProtocol.resolveFolder`
// replaces the placeholder with whatever the server actually said.
var MAILBOXES = [
  { key: "inbox", label: "Inbox", icon: "inbox", query: "folder:INBOX" },
  { key: "unread", label: "Unread", icon: "unread", query: "folder:INBOX UNSEEN" },
  { key: "starred", label: "Flagged", icon: "star", query: "folder:INBOX FLAGGED" },
  { key: "sent", label: "Sent", icon: "send", query: "folder:\\Sent" },
  { key: "archive", label: "Archive", icon: "archive", query: "folder:\\Archive", optional: true },
  { key: "trash", label: "Trash", icon: "trash", query: "folder:\\Trash", optional: true }
]

// IMAP SEARCH has no free-text operator that means what a user means by typing
// words into a search box, so the text becomes a TEXT criterion — headers and
// body, the closest standard equivalent. JSON.stringify is used for the quoting
// because it escapes exactly the two characters IMAP escapes.
function searchQuery(text) {
  var value = String(text === undefined || text === null ? "" : text).trim()
  return value === "" ? "" : "folder:INBOX TEXT " + JSON.stringify(value)
}

// Selecting a folder in the sidebar. This cannot go through `searchQuery`: a
// folder wrapped in a TEXT search would look for the folder's own name inside
// the inbox rather than opening it.
function labelQuery(name) {
  var value = String(name === undefined || name === null ? "" : name).trim()
  return value === "" ? "" : "folder:" + JSON.stringify(value)
}
