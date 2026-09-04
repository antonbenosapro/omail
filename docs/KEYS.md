# Omail — Keybindings

How the keyboard works in this application, and why it is built this way.

## The model

**The keyboard belongs to the application, and the context says what a key
means where.** This is the model a TUI uses, and the one GPUI uses for actions:
a key is not owned by whichever widget happens to hold the focus — it is owned
by the app, and scoped to the contexts where it means something.

Everything follows from that:

- Every binding lives in one table, `keys/Keymap.js`. Nothing else describes a
  key. The shortcut sheet and the status-bar hints render from that table.
- `components/KeyRouter.qml` turns the table into `Shortcut` objects and reports
  what was pressed by id. `App.qml` answers with one `runShortcut` function.
- `Escape` is a binding like any other, not a `Keys.onEscapePressed` handler, so
  it does not depend on who holds the focus.

## The contexts

The window is in exactly one context at a time. `App.qml` derives it from what
is on screen, by precedence — a page is a form before it is anything else, a
draft beats reading, a query being typed beats the list underneath it:

```qml
readonly property string keyContext:
    root.showPage  ? "page"
  : root.composing ? "compose"
  : searchBar.fieldFocused ? "search"
  : root.currentView === "reader" ? "reader"
  : "list"
```

| Context | What it is | What it binds |
|---|---|---|
| `list` | The message list | The mailbox keys |
| `reader` | A message open | The mailbox keys, plus reply/forward. `j`/`k` move the cursor without opening; `o` or `Enter` opens what they landed on |
| `search` | A query being typed | `Escape`, and the modified keys |
| `compose` | A draft being written | `Escape`, `Ctrl+Return`, and the modified keys |
| `page` | Setup or settings | `Escape`, and the modified keys |

`mail` in the table below is shorthand for `list` and `reader`; `all` is every
context.

**A text-entry context binds no bare key but `Escape`.** That is the whole rule.
There is no "is the user typing" question anywhere in the code, because there is
nothing left for it to answer: if a bare letter is not bound in `compose`, it
cannot fire there, and the field gets it the way any other character arrives.

## One mechanism

**The context owns the keyboard.** Changing context moves the focus — to
whatever that context types into, or to a parked home item when the context
types into nothing:

```qml
onKeyContextChanged: Qt.callLater(applyContextFocus)
function applyContextFocus() {
  if (keyContext === "compose") compose.takeFocus()
  else if (keyContext === "search") searchBar.focusField()
  else parkKeyboard()
}
```

This is the part that has to stay one thing. When the context came from what was
on screen and the focus stayed wherever the last click left it, the two drifted:
closing a reply left its text field holding the keyboard while invisible, Qt kept
handing that field every keystroke, and `j` and `k` were simply gone for the rest
of the session. Nothing warned — the keys stopped arriving.

`ComposeView` therefore does **not** place its own focus when it opens. Opening
it changes the context, and the context moves the keyboard. One mechanism, so
the two cannot disagree.

## The bindings

Generated from `keys/Keymap.js`. `tests/test_keymap.js` asserts this table
matches it, so the two cannot drift — three hand-written copies of this list
used to exist, and they had.

<!-- BEGIN BINDINGS -->
| id | keys | contexts | action |
|---|---|---|---|
| `cursorDown` | `j`, `Down` | mail | Move down |
| `cursorUp` | `k`, `Up` | mail | Move up |
| `open` | `Return`, `o` | mail | Open the selected message |
| `backToList` | `u` | reader | Back to the list |
| `archive` | `e` | mail | Archive |
| `trash` | `d` | mail | Move to trash |
| `star` | `s` | mail | Star or unstar |
| `markRead` | `Shift+I` | mail | Mark read |
| `markUnread` | `Shift+U` | mail | Mark unread |
| `undo` | `z` | mail | Undo the last trash |
| `reply` | `r` | mail | Reply |
| `replyAll` | `a` | mail | Reply to all |
| `forward` | `f` | mail | Forward |
| `compose` | `c` | mail | Compose |
| `send` | `Ctrl+Return` | compose | Send |
| `search` | `/` | mail | Search |
| `searchAnywhere` | `Ctrl+K` | all | Search from anywhere |
| `goMailbox` | `Alt+1`, `Alt+2`, `Alt+3`, `Alt+4`, `Alt+5`, `Alt+6`, `Alt+7`, `Alt+8`, `Alt+9`, `Alt+0` | mail | Go to that mailbox |
| `switchAccount` | `Alt+A` | mail | Switch account |
| `zoomIn` | `Ctrl++`, `Ctrl+=` | mail | Zoom what you are reading in |
| `zoomOut` | `Ctrl+-` | mail | Zoom what you are reading out |
| `zoomReset` | `Ctrl+0` | mail | Reset the zoom |
| `refresh` | `F5` | all | Check for mail |
| `help` | `?`, `Ctrl+/`, `Ctrl+?` | mail | Toggle this sheet |
| `back` | `Escape` | all | Back, or close the window |
<!-- END BINDINGS -->

Two rows are split on purpose. `search` keeps the bare `/` in the mailbox while
`searchAnywhere` reaches search from inside a draft or a form — the bare key
cannot live in a text-entry context, and the modified one should. `help` is a
mailbox action rather than a global one: the sheet lists what the mailbox
answers to, and a draft is not a mailbox.

## Why `z` undoes, and why nothing deletes

`d` moves a message to trash and asks nothing first. That is the right trade only because `z` takes it back: a confirmation interrupts every correct action to guard against the rare wrong one, and people asked the same question on every delete learn to dismiss it without reading it. Undo costs nothing until something goes wrong.

`z` is bare, which the scarce bare letters have to be earned for. It earns one on the grounds the others are spent on. It is the key a mail user already reaches for — Gmail has bound it to exactly this for twenty years — so there is nothing to learn. It sits in the far corner of the keyboard, next to nothing destructive, so no slip reaches it. And a mistake is the moment with the least patience for a modifier: an undo behind `Ctrl` is one the hand does not find while it is still surprised.

Not `Ctrl+Z`. Nothing in the mailbox is text being edited, so there is nothing to confuse it with, and the one context where `Ctrl+Z` means something else — a draft — is a text-entry context, which binds no bare key and does not bind this row at all.

The offer lives exactly as long as the notice that makes it, which is a few seconds. Once the sentence is gone the action is gone: an undo that still worked minutes later would be a message reappearing for a reason nobody could still connect to a keystroke.

And it is offered only where the provider can honour it — `undo` is a capability in `providers/Registry.js` like `archive` and `spam`, and a capability the provider does not declare is a button the panel does not draw. Gmail declares it, because a message id survives a trash. IMAP does not: a UID belongs to the folder holding the message, so moving one to Trash issues a new id, and the server reports it in the tagged OK response that curl removes before the transport ever sees it. `z` there finds nothing to take back and says nothing, which is the honest answer until the client can search Trash for the message again.

**There is no `Del`, and adding one would make this worse rather than better.** `d` is deliberate — it belongs to the bare-letter home-row set with `e`, `s`, `r`, `a`, `f`, `c`. `Del` is the key muscle memory fires *without* deliberation, and it sits beside the arrow keys that `j` and `k` are aliased to: cursoring down a list and clipping Delete would silently trash whatever was under the cursor. Every other binding here that is destructive or leaves the screen is bare-letter or modified, never a reach key. `tests/test_keymap.js` asserts nothing in the table binds `Del`, `Delete` or `Backspace`, so the reasoning cannot be lost and the key added back by someone who only read the row.

## Why the rail is numbered and not chorded

`g i`, `g s`, `g u` and `g t` used to open the mailboxes, and they were two
problems in one row.

They were a chord, and Qt puts a deadline on an unfinished one:
`styleHints.keyboardInputInterval`, 400ms here. Press `g`, think for half a
second, press `i`, and nothing happens — no mailbox, no error, no hint that a
clock had been running. Measured, not guessed:
`0ms → fires · 300ms → fires · 500ms → dead · 800ms → dead`.

And they had to be memorised. Four bindings that look like nothing on screen,
for the four places you actually go.

`Alt+1`…`Alt+0` replaces both. A modifier has no deadline, and **holding Alt
puts the digit on every row of the rail**, so there is nothing to remember —
the rail says which key opens it. The numbers run down the rail as it is drawn,
mailboxes first and then the server's labels, from `Model.sidebarSlots`, which
is the same list the badges are drawn from: the number beside a row and the row
a number opens are one fact rather than two. Past the tenth row there is simply
no number, because there is no digit left to offer.

Held Alt is the one `Keys` handler in `App.qml`, and it is not a binding — a
modifier alone cannot be a `Shortcut`, so there is nothing to route. It accepts
no event, so what follows Alt still goes where it always went, and it clears on
`activeFocus` rather than on the release: Alt+Tab takes the release with it, and
waiting for one that is not coming would paint the numbers on permanently.

`Escape` is the only bare key bound everywhere, because it is the way out of
everywhere. What it means in each place is one list in `goBack()`, in the order
the window is stacked.

## What survives an overlay

The shortcut sheet sits on top of the mailbox, and `survivesOverlay` is the
whole guard: without it a row goes dead while the sheet is up, which is why `e`
cannot archive behind it.

Four rows carry it. `help` and `back` keep their own meaning — they are how the
sheet goes away. `cursorDown` and `cursorUp` are handed to the sheet instead, to
scroll it, in `runShortcut`. A sheet taller than the window that could only be
read with a mouse would be the one screen here that contradicts the rest.

**The account switcher is not on that list, and cannot be.** It is a
`QQC.Popup`, and an open popup takes every key before the shortcut map sees it —
`focus` true or false, bare key or modified. So `Alt+A` opens it through the
table like any other key, and from there `j`, `k`, `Enter` and `o` come from a
`Keys` handler on the popup's own `contentItem`: the one place in this window
where the rule at the top of this document runs backwards.
`tests/qml/tst_popup_keys.qml` holds the Qt behaviour that makes it so, and
`Model.wrappedIndex` holds the only decision in it — the cursor wraps, where the
message list clamps.

## The cursor

`cursorKey` is where the keyboard is. `selectedKey` is what the reader shows.
They are two different things, and conflating them was the first bug in this
area: movement was anchored on the opened message, so in the list — where
nothing is open — every step resolved to the first row, and `j` moved once and
then stopped.

Both are *row keys* rather than message ids: the account and the id together, built by `Model.rowKey` and read back by `Model.keyId` and `Model.keyAccountId`. A bare id addresses no row in a merged list, where two IMAP accounts on one server can each hold `5:INBOX` — the cursor could not walk past the first of them, and an action on the second acted on the first. Every function below takes and returns a key.

Three rules, all in `account/Model.js` so the node tests reach them:

- **`cursorAfterOffset`** — moving. Anchored on the cursor itself, clamped at
  both ends, and starting from the end the move came from when there is no
  cursor yet, so `j` opens at the top and `k` at the bottom.
- **`cursorAfterRemoval`** — the row the cursor is on is about to leave, because
  it was archived or trashed. The cursor takes its place: the row below, or the
  row above at the end. Worked out *before* the action, while the row still has
  neighbours.
- **`cursorAfterReload`** — the whole list was replaced, by a mailbox switch, a
  search, or a refresh. A cursor whose message survived keeps its place; one
  whose message is gone starts at the top.

The last two exist because a cursor pointing at a message that is not listed
cannot be found, and `cursorAfterOffset` restarts at the top from there. Every
"the cursor jumped back to the first row" report is that.

The list is a `Column` of rows inside a `Flickable`, not a `ListView` — the
panel already owns a scroller, and nesting a second gives every wheel event two
plausible targets. So there is no `positionViewAtIndex`, and keyboard movement
has to scroll the list itself: **`Model.contentYToReveal`** decides where the
scroller goes, leaving it alone while the row is already visible so stepping one
row does not drag the list under someone reading it. It is called from
`moveCursor`, not from `cursorKey` changing, because hovering a row moves the
cursor too and scrolling under the pointer fights the mouse.

## The mouse

The mouse does not move the keyboard's cursor. A row draws its own hover
(`MessageRow.hot`), clicking one opens it, and right-clicking one sets the
cursor explicitly before opening its menu — but hovering does nothing to
`cursorKey`.

That is not a preference. Qt re-reports hover when content moves under a
pointer that has not moved, and the list scrolls to follow the keyboard. With
hover writing `cursorKey`, pressing `j` moved the cursor, the scroll brought a
different row under the still pointer, and the cursor snapped back to it — so
`j` and `k` stuck on whichever rows the mouse was resting near.
`tests/qml/tst_hover_under_scroll.qml` pins the Qt behaviour that makes this so.

## Adding a key

1. Add a row to `BINDINGS` in `keys/Keymap.js`. Name the contexts it means
   something in — that is the guard, and there is no other. A `display` string
   is how the sheet shows a range instead of enumerating every key.
2. Add a case to `runShortcut` in `App.qml`. The second argument is the
   sequence that fired, which is how a row of several keys tells them apart —
   read it with `slotFor`, never by parsing the string.
3. Add the row to the table above. The test will tell you if you forget.

That is all. The shortcut sheet and the status hints pick it up on their own.

## Why it looks like this

Four things were found by running the code rather than reading it. Each cost a
release-shaped bug, and each is now pinned by a test.

**A `Repeater` builds no `Shortcut`s.** A `Shortcut` is a `QtObject` and a
`Repeater` only builds `Item`s, so a `Repeater` creates nothing at all and every
key goes silently dead. `KeyRouter` uses an `Instantiator`.

**`FloatingWindow` does not forward `activeFocusItem`.** Quickshell's window is a
proxy; reading `window.activeFocusItem` gives `undefined`, which reads as falsy
and quietly passes every guard built on it. The attached `Window.activeFocusItem`
is the one that works.

**`forceActiveFocus()` on a `FocusScope` is a no-op.** It re-elects that scope's
current focus item — which is the field you are trying to leave. Parking the
keyboard has to land on a plain `Item`.

**A window `Shortcut` beats a focused item's `Keys` handler.** A local
`Keys.onEscapePressed` looks live and never runs. `SearchBar` had one; what it
did lives in `goBack()` now.

And one thing that is *not* a problem, recorded because it was assumed to be:
Qt already gives a focused `TextInput` the bare keys before any `Shortcut` sees
them. Typing a letter into a visible field never fired a shortcut. The old
hand-written "is the user typing" guard was not holding that line, and removing
it changed no behaviour.

## Not here

**User-configurable bindings.** The table makes it possible — the rows are data
— but nothing has asked for it, and a config file for bindings needs a merge
story and a conflict story this does not need.
