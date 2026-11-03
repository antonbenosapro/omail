import QtQuick
import Quickshell
import Quickshell.Io

import "Cache.js" as Cache

// The cache's file. Cache.js decides what the cache contains; this decides
// when it touches the disk.
//
// Writes are debounced and atomic: the whole store is one document, so a save
// during a burst of loads would otherwise rewrite it a dozen times, and a
// half-written file would read back as a corrupt cache on the next start.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME")
    || (Quickshell.env("HOME") + "/.cache")
  readonly property string directory: cacheHome + "/omail"

  required property string pluginDir
  readonly property string script: pluginDir + "/scripts/body-cache.sh"

  // One file per account. A shared file would mean every switch discarded the
  // cache of the account being switched to, which is the whole point of having
  // one. The name is the account's keyId, never its address — see
  // Cache.storeFileName — and with no key there is no file: the store lives in
  // memory until there is one.
  property string keyId: ""
  // Only for finding the file this account had before keyIds, which was named
  // after the address. That name goes to the script on stdin.
  property string accountId: ""
  readonly property string path: Cache.storeFileName(keyId) !== ""
    ? directory + "/" + Cache.storeFileName(keyId) : ""

  property var store: Cache.emptyStore()
  property bool loaded: false

  signal restored()

  function get(key) { return Cache.getQuery(store, key) }

  function putQuery(key, page) {
    store = Cache.putQuery(store, key, page, Date.now())
    scheduleSave()
  }

  function putLabels(labels) {
    store = Cache.putLabels(store, labels, Date.now())
    scheduleSave()
  }

  function putProfile(profile) {
    store = Cache.putProfile(store, profile, Date.now())
    scheduleSave()
  }

  // Called once the mailbox address is known. A cache belongs to one mailbox,
  // so a different address starts from nothing rather than showing one
  // account's mail under another's name.
  function bindAccount(email) {
    var next = Cache.forAccount(store, email)
    if (next === store) return
    if (next.account !== store.account) {
      store = next
      scheduleSave()
    }
  }

  function clear() {
    store = Cache.emptyStore()
    scheduleSave()
  }

  function scheduleSave() {
    if (loaded && path !== "") saveTimer.restart()
  }

  function open() {
    if (path === "") {
      finish(Cache.emptyStore())
      return
    }
    file.reload()
  }

  function finish(next) {
    store = next
    loaded = true
    restored()
  }

  // Whether this key has already asked for its old file. Once per key: a
  // store that will not load twice is an empty cache, not a loop.
  property bool adoptTried: false

  // The store under the keyId would not load, which on the first run after an
  // upgrade means it is still under the address. The script takes that file
  // over and removes it; anything else is a fresh, empty cache.
  function adoptLegacy() {
    // One already running answers for this key, or — for the account before
    // it — opens this one again when it exits.
    if (adopter.running) return
    var legacy = accountId !== "" ? Cache.legacyFileName(accountId) : ""
    if (adoptTried || legacy === "") {
      finish(Cache.emptyStore())
      return
    }
    adoptTried = true
    adopter.forKey = keyId
    adopter.legacyName = legacy
    adopter.command = [script, "adopt-store", directory, keyId]
    adopter.running = true
  }

  Component.onCompleted: directoryMaker.running = true

  // Switching accounts swaps the file underneath, so what is in memory belongs
  // to the account that just left. So does a save still waiting to happen:
  // run now, it would write that account's mail into this one's file. The
  // Instantiator in Service.qml rebinds an object to the next account when
  // one is removed, which is exactly this.
  onKeyIdChanged: {
    saveTimer.stop()
    loaded = false
    adoptTried = false
    store = Cache.emptyStore()
    if (directoryMaker.running) return
    open()
  }

  // The store holds the subject, sender and snippet of every message that has
  // been listed — the same mail the body files beside it are kept 0600 for. So
  // the directory is closed to everyone else: FileView writes with whatever
  // umask the shell process happens to have, and the directory is the only
  // place this can set the mode itself.
  Process {
    id: directoryMaker
    // The path arrives as an argument rather than inside the script, so nothing
    // in it can be read as shell.
    command: ["sh", "-c", "umask 077; mkdir -p \"$1\" && chmod 700 \"$1\"", "sh", root.directory]
    onExited: root.open()
  }

  Process {
    id: adopter
    property string forKey: ""
    property string legacyName: ""
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(legacyName + "\n")
      legacyName = ""
    }
    onExited: {
      // The account changed while this ran; its own open has run or will.
      if (forKey !== root.keyId) {
        if (!root.loaded) root.open()
        return
      }
      // Read the file again whatever happened: it is there if it was adopted,
      // and if not, the second failure is an empty cache, because this key
      // has asked once already.
      file.reload()
    }
  }

  FileView {
    id: file
    path: root.path
    atomicWrites: true
    printErrors: false

    onLoaded: root.finish(Cache.load(text()))
    // No cache yet is the ordinary first-run state, not an error — unless the
    // account is older than keyIds, and its store is still under its address.
    onLoadFailed: {
      if (root.path === "") return
      root.adoptLegacy()
    }
  }

  Timer {
    id: saveTimer
    interval: 800
    onTriggered: {
      if (root.path === "") return
      root.store = Cache.prune(root.store)
      file.setText(Cache.serialize(root.store))
    }
  }
}
