#!/bin/sh
# keyring-migrate.sh against a real Secret Service: a gnome-keyring started in
# a private D-Bus session under a throwaway HOME, so nothing here can touch the
# keyring of whoever runs it.
#
# What it proves: entries keyed by address under every old service name are
# re-keyed to the keyId with their secret intact, only the first mailbox may
# claim a client-only token, nobody else's entry moves, `forget` removes what
# it should — and no address is ever an argument to gdbus or secret-tool.
#
# Skipped, not failed, where there is no keyring to start: a CI runner has no
# gnome-keyring, and the plugin's own machine does.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/keyring-migrate.sh"

for tool in dbus-run-session gnome-keyring-daemon gdbus secret-tool; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'keyring-migrate.sh skipped (no %s)\n' "$tool"
    exit 0
  fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/omail-keyring-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM HUP

# Every gdbus and secret-tool the script runs logs its arguments here first.
mkdir -p "$work/spy"
for tool in gdbus secret-tool; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/argv.log"\nexec "%s" "$@"\n' \
    "$tool" "$work" "$(command -v "$tool")" > "$work/spy/$tool"
  chmod +x "$work/spy/$tool"
done
: > "$work/argv.log"

cat > "$work/run.sh" <<'RUN'
set -eu
export HOME="$WORK/home" XDG_DATA_HOME="$WORK/data" XDG_CACHE_HOME="$WORK/cache"
export XDG_CONFIG_HOME="$WORK/config" XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"
printf 'test' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1

failures=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"; failures=$((failures + 1)); fi
}
store() {
  secret="$1"; shift
  printf '%s' "$secret" | secret-tool store --label=old "$@" 2>/dev/null
}
migrate() {
  printf '%s\n' "$1" | PATH="$WORK/spy:$PATH" sh "$SCRIPT" 2>/dev/null || true
}
K1=0123456789abcdef0123456789abcd01
K2=0123456789abcdef0123456789abcd02
K3=0123456789abcdef0123456789abcd03
K4=0123456789abcdef0123456789abcd04

# An IMAP password, under a service name two renames old.
store 'pw jane' service omarchy-gmail kind imap-password account imap:jane@example.org
check 'an old IMAP entry is re-keyed' "$(migrate "adopt imap-password $K1 imap:jane@example.org - 0")" 'adopted'
check 'and its password is under the keyId' \
  "$(secret-tool lookup service omail kind imap-password account $K1)" 'pw jane'
check 'and no longer under the address' \
  "$(secret-tool lookup service omarchy-gmail kind imap-password account imap:jane@example.org)" ''
check 'asking again changes nothing' "$(migrate "adopt imap-password $K1 imap:jane@example.org - 0")" ''

# A Gmail token keyed by address and client.
store 'tok bob' service omail kind refresh-token client-id CID account bob@example.org
store 'tok carol' service omail kind refresh-token client-id CID account carol@example.org
check 'a Gmail entry is re-keyed' "$(migrate "adopt refresh-token $K2 bob@example.org CID 0")" 'adopted'
check 'with its token' \
  "$(secret-tool lookup service omail kind refresh-token client-id CID account $K2)" 'tok bob'
check 'and the other account keeps its own' \
  "$(secret-tool lookup service omail kind refresh-token client-id CID account carol@example.org)" 'tok carol'
check 'another client is not this account' "$(migrate "adopt refresh-token $K3 carol@example.org OTHER 0")" ''

# Before accounts: a token keyed by client alone, which only the first mailbox
# may claim.
store 'tok first' service omamail kind refresh-token client-id CID2
check 'a second mailbox cannot claim it' "$(migrate "adopt refresh-token $K3 - CID2 0")" ''
check 'the first mailbox can' "$(migrate "adopt refresh-token $K4 - CID2 1")" 'adopted'
check 'and gets its token' \
  "$(secret-tool lookup service omail kind refresh-token client-id CID2 account $K4)" 'tok first'

# Forgetting removes what is still keyed by the address, and only that.
check 'forget prints nothing' "$(migrate "forget refresh-token carol@example.org CID")" ''
check 'the old entry is gone' \
  "$(secret-tool lookup service omail kind refresh-token client-id CID account carol@example.org)" ''
check 'and the re-keyed one is not touched' \
  "$(secret-tool lookup service omail kind refresh-token client-id CID account $K2)" 'tok bob'

# Refused before anything runs.
check 'a malformed keyId is refused' "$(migrate "adopt imap-password nothex imap:x@example.org - 0")" ''
check 'an unknown kind is refused' "$(migrate "adopt password $K1 imap:x@example.org - 0")" ''

check 'no address was an argument to gdbus or secret-tool' \
  "$(grep -c 'example.org' "$WORK/argv.log" || true)" '0'
check 'and gdbus was what ran' "$([ -s "$WORK/argv.log" ] && echo yes || echo no)" 'yes'
exit "$failures"
RUN

printf 'keyring-migrate.sh\n'
if WORK="$work" SCRIPT="$script" dbus-run-session -- sh "$work/run.sh" 2>/dev/null; then
  printf 'keyring-migrate.sh ok\n'
else
  printf '\nkeyring-migrate.sh checks failed\n'
  exit 1
fi
