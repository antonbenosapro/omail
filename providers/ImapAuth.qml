import QtQuick
import Quickshell
import Quickshell.Io

import "ImapProtocol.js" as Imap
import "Credentials.js" as Credentials

// An IMAP account's sign-in, which is a server address and a password.
//
// It is the counterpart to `AuthManager`, and deliberately the same shape from
// outside: `MailAccount` asks either of them whether it is `loggedIn`, and asks
// for a credential with one call whose callback takes `(value, error)`. What
// differs is everything inside — there is no browser, no token to refresh and
// nothing that expires.
//
// Where the secret lives follows the same rule as the refresh token: GNOME
// Keyring, written over stdin so it never reaches the process table, and keyed
// by account so two mailboxes cannot overwrite each other.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir

  // Which mailbox this signs in. Unlike Gmail's, an IMAP account knows its own
  // address from the moment it is created — the user typed it — so this is set
  // before anything is asked of the server rather than after a profile read.
  property string accountId: ""

  // Server settings, pushed down from the account entry. Held as the validated
  // shape rather than as whatever was in the file.
  property var settings: Imap.normalizeSettings(null)

  readonly property bool configured: Imap.validateSettings(settings).ok

  // The password, once the keyring has answered. Held in this process for as
  // long as the account exists, exactly as the access token is: every request
  // needs it, and a keyring round trip per request would be both slow and a
  // stream of authorisation prompts on some setups.
  property string password: ""
  property bool passwordChecked: false
  readonly property bool loggedIn: configured && password !== ""

  // The same three names `AuthManager` exposes, because `MailAccount` reads
  // them without knowing which provider it has.
  readonly property bool credentialsPresent: configured
  property bool loginBusy: false
  readonly property bool sessionBusy: secretLookup.running || keyringStore.running
  property string lastError: ""

  // Nothing here needs a browser or a helper that Omarchy might not ship —
  // secret-tool is the only tool, and curl is checked by the client.
  readonly property var requiredTools: ["secret-tool", "curl"]
  property var missingTools: []
  property bool toolsChecked: false
  readonly property bool toolsPresent: toolsChecked && missingTools.length === 0

  property var credentialWaiters: []
  property bool lookupHandled: false
  property string pendingPassword: ""

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)
  signal credentialsSaved()

  function safeError(value) {
    return Imap.redact(String(value || ""))
  }

  function finishWaiters(value, error) {
    var pending = credentialWaiters.slice()
    credentialWaiters = []
    for (var i = 0; i < pending.length; i++) {
      try { pending[i](value || "", safeError(error)) }
      catch (e) { /* consumers own their callback errors */ }
    }
  }

  // The one entry point the transport uses. Hands back "user:password" — the
  // single field curl wants — rather than the two halves, so nothing
  // downstream has to know how they are joined.
  function withCredentials(callback) {
    if (typeof callback !== "function") return
    if (!configured) {
      callback("", "Add this mailbox's server settings first")
      return
    }
    if (password !== "") {
      callback(settings.username + ":" + password, "")
      return
    }
    if (passwordChecked) {
      callback("", "No password saved for this mailbox. Sign in again")
      return
    }

    var next = credentialWaiters.slice()
    next.push(callback)
    credentialWaiters = next
    if (secretLookup.running) return
    startSecretLookup()
  }

  function restoreSession() {
    if (!configured) {
      passwordChecked = true
      return
    }
    if (secretLookup.running) return
    startSecretLookup()
  }

  // The service name the keyring entry was written under has been renamed, so
  // the lookup falls back through the old names exactly as the Gmail manager's
  // does. Without this an IMAP account is the one that loses its credential to
  // a rename: a refresh token can be obtained again from a browser, while this
  // is the user's own password and only they can type it back in.
  //
  // Stage 0 is the current service name; each stage after it is one old name,
  // newest first.
  property int secretLookupStage: 0
  readonly property int lastSecretLookupStage: Credentials.renamedServiceCount()
  property var renamedAttributesToClear: []

  function secretLookupAttributes(stage) {
    return stage <= 0
      ? Credentials.imapKeyringAttributes(accountId)
      : Credentials.renamedImapKeyringAttributes(accountId, stage - 1)
  }

  function startSecretLookup() {
    secretLookupStage = -1
    renamedAttributesToClear = []
    startNextSecretLookup()
  }

  function startNextSecretLookup() {
    lookupHandled = false
    while (secretLookupStage < lastSecretLookupStage) {
      secretLookupStage++
      var attributes = secretLookupAttributes(secretLookupStage)
      // An account with no address is not addressable under any service name,
      // so every stage hands back nothing and the walk ends without asking
      // secret-tool anything — a lookup with no attributes would match every
      // entry this plugin ever wrote.
      if (attributes.length) {
        secretLookup.command = ["secret-tool", "lookup"].concat(attributes)
        secretLookup.running = true
        return
      }
    }
    handleSecretLookup("")
  }

  function handleSecretLookup(line) {
    if (lookupHandled) return
    lookupHandled = true
    var value = String(line || "")
    if (value === "" && secretLookupStage < lastSecretLookupStage) {
      startNextSecretLookup()
      return
    }
    passwordChecked = true
    if (value === "") {
      finishWaiters("", "No password saved for this mailbox. Sign in again")
      // Only a mailbox that is otherwise ready to go is worth complaining
      // about: an account still being typed into has no password by design.
      if (configured) sessionUnavailable("Sign in to this mailbox")
      return
    }
    password = value
    // Found under an old service name: rewrite it under the current one and
    // drop the old entry, so the fallback runs once per machine rather than on
    // every start.
    if (secretLookupStage > 0) {
      renamedAttributesToClear = secretLookupAttributes(secretLookupStage)
      storePassword()
    }
    finishWaiters(settings.username + ":" + password, "")
    loginSucceeded()
  }

  // Called by the setup page once the user has filled the form in. The password
  // is verified by using it — a mailbox that answers a NOOP is a mailbox that
  // will answer everything else — rather than by being written down first and
  // failing silently later.
  function signIn(secret) {
    var value = String(secret || "")
    if (value === "") {
      lastError = "Enter the password for this mailbox"
      return false
    }
    var check = Imap.validateSettings(settings)
    if (!check.ok) {
      lastError = check.error
      return false
    }
    lastError = ""
    loginBusy = true
    pendingPassword = value
    verifyRequested(settings, settings.username + ":" + value)
    return true
  }

  // The client owns the transport, so it performs the check and reports back.
  signal verifyRequested(var settings, string credentials)

  function completeSignIn(ok, error) {
    loginBusy = false
    if (!ok) {
      pendingPassword = ""
      lastError = safeError(error) || "The server rejected that username or password"
      return
    }
    password = pendingPassword
    pendingPassword = ""
    passwordChecked = true
    lastError = ""
    // A draft account has no address yet, so there is no key to write the
    // password under — and the keyring refuses to invent one. It learns its
    // real id a moment later, from the profile read that signing in just made
    // possible, so the write waits for the name and `onAccountIdChanged`
    // performs it. Until then the password lives only in this process.
    if (Credentials.secretDisposition(accountId) === Credentials.STORE_WHEN_NAMED)
      storeWhenNamed = true
    else storePassword()
    loginSucceeded()
  }

  function storePassword() {
    var attributes = Credentials.imapKeyringAttributes(accountId)
    if (attributes.length === 0 || password === "") return
    keyringWriteSecret = password
    keyringStore.command = [pluginDir + "/scripts/keyring-store.sh"].concat(attributes)
    keyringStore.running = true
  }

  property string keyringWriteSecret: ""

  function logout() {
    password = ""
    pendingPassword = ""
    passwordChecked = true
    var attributes = Credentials.imapKeyringAttributes(accountId)
    if (attributes.length > 0) {
      keyringClear.command = ["secret-tool", "clear"].concat(attributes)
      keyringClear.running = true
    }
    loggedOut()
  }

  // Kept so `MailAccount` can call the same thing on either provider. An IMAP
  // password does not expire, so there is nothing to invalidate — but a server
  // that has started rejecting it should not be asked a hundred more times
  // with the same value.
  function invalidateAccessToken() {
    password = ""
    passwordChecked = false
  }

  // The Gmail manager has these; an IMAP account reaches neither, and
  // `MailAccount` should not have to ask which provider it holds before
  // calling one.
  function beginLogin() { /* the setup form drives sign-in, not a browser */ }
  function cancelLogin() { loginBusy = false }

  onAccountIdChanged: {
    // An account signed in before it had a name is the one case where the
    // password in memory belongs to *this* mailbox rather than the previous
    // one: a new account is added with an empty address, and only learns its
    // id from the first profile read — which cannot happen until it is signed
    // in. Now that there is a name, the write that was waiting for one runs.
    if (storeWhenNamed && password !== "") {
      storeWhenNamed = false
      storePassword()
      return
    }
    storeWhenNamed = false
    // Otherwise a different mailbox has a different password. Dropping the one
    // in memory is what stops an account rename from leaving the previous
    // account's credential in front of the new one's server.
    password = ""
    passwordChecked = false
    lookupHandled = false
  }

  // Set when a sign-in succeeded before the account had an address, and read
  // once by the rename that gives it one. False at every other moment, so a
  // genuine switch between accounts still drops the password.
  property bool storeWhenNamed: false

  Component.onCompleted: {
    toolProbe.command = ["sh", "-c",
      "for tool in secret-tool curl; do command -v \"$tool\" >/dev/null 2>&1 || echo \"$tool\"; done"]
    toolProbe.running = true
  }

  Process {
    id: toolProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var missing = String(text || "").split("\n")
        var found = []
        for (var i = 0; i < missing.length; i++) {
          var name = missing[i].trim()
          if (name) found.push(name)
        }
        root.missingTools = found
        root.toolsChecked = true
      }
    }
  }

  Process {
    id: secretLookup
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleSecretLookup(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      // No entry is not an error: it is what a mailbox that has never been
      // signed in to looks like.
      if (!root.lookupHandled) root.handleSecretLookup("")
    }
  }

  Process {
    id: keyringStore
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.keyringWriteSecret + "\n")
      root.keyringWriteSecret = ""
    }
    onExited: function(exitCode) {
      root.keyringWriteSecret = ""
      if (exitCode !== 0)
        root.lastError = "Signed in, but the password could not be saved. "
          + "You may need to enter it again after a restart"
      // The old entry goes only after the new one is safely written. A clear
      // that ran first would leave a failed write with no password anywhere.
      if (exitCode === 0 && root.renamedAttributesToClear.length && !keyringClear.running) {
        keyringClear.command = ["secret-tool", "clear"].concat(root.renamedAttributesToClear)
        root.renamedAttributesToClear = []
        keyringClear.running = true
      }
    }
  }

  Process {
    id: keyringClear
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }
}
