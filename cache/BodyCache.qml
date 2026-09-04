import QtQuick
import Quickshell
import Quickshell.Io

import "Cache.js" as Cache

// Message bodies on disk, one file per message.
//
// A body never changes once fetched, so a hit is always correct — which makes
// this the cache worth keeping deep. It is deliberately not held in memory: a
// thousand bodies is tens of megabytes, and keeping them in the account's store
// meant re-serialising all of it on the GUI thread whenever anything else in
// the store moved.
//
// Reads are therefore asynchronous, and the caller has to cope with the answer
// arriving after the network's. That is the right trade: the alternative is
// reading a file synchronously on the thread that paints.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir

  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME")
    || (Quickshell.env("HOME") + "/.cache")

  // One directory per account, named the way the account's store file is, so
  // the two can be matched by eye and neither can leave the cache directory.
  property string accountId: ""
  readonly property string directory: cacheHome + "/omail/bodies/"
    + Cache.bodyDirName(accountId)

  readonly property string script: pluginDir + "/scripts/body-cache.sh"

  // ------------------------------------------------------------------ read

  property var pendingCallback: null

  function read(id, callback) {
    var name = Cache.bodyFileName(id)
    if (name === "") {
      if (typeof callback === "function") callback(null)
      return
    }
    pendingCallback = callback
    var wanted = directory + "/" + name
    // Setting the same path again does not reload on its own, and reopening the
    // message you just closed has to hit the file rather than the last answer.
    if (reader.path === wanted) reader.reload()
    else reader.path = wanted
  }

  function deliver(body) {
    var callback = pendingCallback
    pendingCallback = null
    if (typeof callback === "function") callback(body)
  }

  // A hit is a use, and mtime is what eviction sorts on, so the file has to be
  // stamped. Detached because nothing waits on the result.
  function touch(id) {
    var name = Cache.bodyFileName(id)
    if (name === "") return
    Quickshell.execDetached([script, "touch", directory, name])
  }

  FileView {
    id: reader
    printErrors: false
    onLoaded: root.deliver(Cache.parseBody(text()))
    // Never cached, or cached under an account that has since been removed.
    onLoadFailed: root.deliver(null)
  }

  // ----------------------------------------------------------------- write

  // At most one write runs at a time, and only the newest queued body is kept:
  // they are independent files, but a burst would otherwise start a process per
  // message. Opening messages faster than the disk can keep up should cost a
  // cache miss, never a pile of processes.
  property var writeQueue: []

  // What was last written to each file this session, so an unchanged body is
  // not written again. A body never changes once fetched, so the record handed
  // over is usually byte-for-byte what is already on disk — and writing it
  // anyway is a process, plus the `find | sort` over up to a thousand files
  // that eviction does, for a file that would come back identical.
  //
  // Keyed on the file name and holding only the serialised string, so it costs
  // what the bodies opened this session cost rather than what the cache holds.
  property var lastWritten: ({})

  // Named "put" rather than "write" so it cannot be confused — by a reader or
  // by QML's scope resolution — with the Process.write() below.
  function put(id, body) {
    var name = Cache.bodyFileName(id)
    if (name === "") return
    var payload = Cache.serializeBody(body)
    if (lastWritten[name] === payload) return
    // Recorded before the write rather than after it: two puts of the same
    // body queued together would otherwise both run, which is the burst this
    // exists to stop.
    var seen = {}
    for (var key in lastWritten) seen[key] = lastWritten[key]
    seen[name] = payload
    lastWritten = seen
    var next = writeQueue.slice()
    next.push(({ name: name, payload: payload }))
    writeQueue = next
    drain()
  }

  function drain() {
    if (writer.running || writeQueue.length === 0) return
    var job = writeQueue[0]
    writeQueue = writeQueue.slice(1)
    writer.payload = job.payload
    writer.command = [script, "put", directory, job.name, String(Cache.MAX_BODIES)]
    writer.running = true
  }

  function clear() {
    writeQueue = []
    lastWritten = ({})
    Quickshell.execDetached([script, "clear", directory])
  }

  // The account this cache belongs to changed, so the directory did: what was
  // written under the old one says nothing about what is on disk under the new.
  onAccountIdChanged: lastWritten = ({})

  Process {
    id: writer
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    onExited: {
      payload = ""
      root.drain()
    }
  }
}
