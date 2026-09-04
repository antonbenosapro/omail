#!/usr/bin/env bash
# The shell constructs a service plugin itself and injects only four
# properties. A `required property` the shell does not know about makes the
# whole plugin fail to instantiate, with the reason buried in a console warning.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { printf 'test_service_source.sh: %s\n' "$1" >&2; exit 1; }

grep -q 'property var shell' Service.qml || fail "Service.qml must accept an injected shell"
grep -q 'property var manifest' Service.qml || fail "Service.qml must accept an injected manifest"
grep -q '__sourceDir' Service.qml || fail "pluginDir must come from manifest.__sourceDir"
grep -q 'function applySettings' Service.qml || fail "the bar widget pushes settings in via applySettings"

# Only the ROOT object's required properties matter. The shell constructs that
# object and can satisfy nothing beyond the four it injects, so one it does not
# know about makes the whole plugin fail to instantiate. A delegate deeper in
# the file is a different thing entirely: its required properties are satisfied
# by the model it belongs to.
if grep -qE '^  required property' Service.qml; then
  fail "Service.qml root must not declare required properties: the shell cannot satisfy them"
fi

# MailAccount is constructed by Service, not by the shell, so it is allowed to
# require what it needs — and it needs the plugin directory to find its scripts.
grep -q 'required property string pluginDir' account/MailAccount.qml \
  || fail "MailAccount must require the plugin directory it runs scripts from"

# The window drives this; the unread poll keeps running while it is false.
grep -q 'property bool windowOpen' Service.qml || fail "Service.qml must expose windowOpen"
if grep -q 'panelOpen' Service.qml; then
  fail "panelOpen is the old name; the window entry point sets windowOpen"
fi

# Zoom is two persisted values, and one of them has a previous name. Somebody
# upgrading has `bodyZoom` on disk from when it sized only the message body;
# that is the size they read messages at, so it has to land on readingZoom
# rather than resetting them to 1.0. The fallback is easy to drop in a later
# edit of applyWindowPrefs and nothing at runtime would complain — the zoom
# would just quietly be gone the next time they opened the window.
grep -q 'property real readingZoom' Service.qml \
  || fail "Service.qml must hold the reader's zoom as readingZoom"
grep -q 'property real listZoom' Service.qml \
  || fail "Service.qml must hold the list's zoom separately as listZoom"
grep -q 'parsed.bodyZoom' Service.qml \
  || fail "applyWindowPrefs must still read the old bodyZoom key, or an upgrade loses the zoom"
grep -q 'readingZoom: readingZoom' Service.qml \
  || fail "saveWindowPrefs must persist readingZoom"
grep -q 'listZoom: listZoom' Service.qml \
  || fail "saveWindowPrefs must persist listZoom"

# Which mailboxes the merged view draws from is per-account state on disk, in
# accounts.json beside the colour. A merging loop that asks the host list
# directly instead of asking `isMergedHost` is how an excluded mailbox's
# messages come back into the merged list — and it would look right in every
# single-account install, which is most of them.
grep -q 'function isMergedHost' Service.qml \
  || fail "Service.qml must ask Accounts which mailboxes the merged view draws from"
grep -q 'function setAccountMerged' Service.qml \
  || fail "Service.qml must expose setAccountMerged, or the setting cannot be changed"
grep -q 'property var mergedIds' Service.qml \
  || fail "the merged ids must be a property: a binding cannot depend on what a function reads"
grep -q 'Accounts.mergedIds' Service.qml \
  || fail "which mailboxes merge is Accounts.js's rule, not a local one"

printf 'test_service_source.sh ok\n'
