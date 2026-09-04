#!/usr/bin/env bash
# The manifest is the contract with the shell. Every entry point it names has
# to exist, or the plugin loads halfway and fails at the moment the user
# clicks something.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { printf 'test_install.sh: %s\n' "$1" >&2; exit 1; }

python3 -c "import json; json.load(open('manifest.json'))" || fail "manifest.json is not valid JSON"

kinds=$(python3 -c "import json; print(' '.join(json.load(open('manifest.json'))['kinds']))")
for kind in service bar-widget panel; do
  case " $kinds " in *" $kind "*) ;; *) fail "manifest kinds must include $kind" ;; esac
done

for entry in service:Service.qml barWidget:BarWidget.qml panel:App.qml; do
  key=${entry%%:*}
  file=${entry##*:}
  declared=$(python3 -c "import json; print(json.load(open('manifest.json'))['entryPoints'].get('$key',''))")
  [ "$declared" = "$file" ] || fail "entryPoints.$key must be $file, found '$declared'"
  [ -f "$file" ] || fail "$file is declared in the manifest but does not exist"
done

[ -x install.sh ] || fail "install.sh must be executable"
grep -q 'plugin-backups' install.sh || fail "backups must not land inside the plugins directory"

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

migrate() {
  XDG_CONFIG_HOME="$1/config" XDG_CACHE_HOME="$1/cache" \
    sh scripts/migrate-storage.sh
}

# The oldest layout there has ever been is carried the whole way in one run.
# It has been renamed twice — omarchy-gmail, omamail, omail — so a machine that
# skipped the middle release must still land on the current name rather than
# stopping one step short of it.
oldest="$test_root/oldest"
mkdir -p "$oldest/config/omarchy-gmail" "$oldest/cache/omarchy-gmail"
printf 'client\n' > "$oldest/config/omarchy-gmail/credentials.json"
printf 'cache\n' > "$oldest/cache/omarchy-gmail/inbox.json"
migrate "$oldest"
[ -f "$oldest/config/omail/credentials.json" ] || fail "legacy config was not moved"
[ -f "$oldest/cache/omail/inbox.json" ] || fail "legacy cache was not moved"
[ ! -e "$oldest/config/omarchy-gmail" ] || fail "legacy config directory remains"
[ ! -e "$oldest/cache/omarchy-gmail" ] || fail "legacy cache directory remains"
[ ! -e "$oldest/config/omamail" ] || fail "the intermediate config name remains"
[ ! -e "$oldest/cache/omamail" ] || fail "the intermediate cache name remains"

# The previous name on its own.
middle="$test_root/middle"
mkdir -p "$middle/config/omamail" "$middle/cache/omamail"
printf 'client\n' > "$middle/config/omamail/credentials.json"
printf 'cache\n' > "$middle/cache/omamail/inbox.json"
migrate "$middle"
[ -f "$middle/config/omail/credentials.json" ] || fail "omamail config was not moved"
[ -f "$middle/cache/omail/inbox.json" ] || fail "omamail cache was not moved"
[ ! -e "$middle/config/omamail" ] || fail "the omamail config directory remains"
[ ! -e "$middle/cache/omamail" ] || fail "the omamail cache directory remains"

# Existing state always wins. Two stores cannot be combined without knowing
# what is in them, so a store already under the current name is never replaced
# by an older one — the newer accounts.json is the one the user has been using.
both="$test_root/both"
mkdir -p "$both/config/omamail" "$both/config/omail" \
  "$both/cache/omamail" "$both/cache/omail"
printf 'old\n' > "$both/config/omamail/accounts.json"
printf 'current\n' > "$both/config/omail/accounts.json"
printf 'old\n' > "$both/cache/omamail/inbox.json"
printf 'current\n' > "$both/cache/omail/inbox.json"
migrate "$both"
[ "$(cat "$both/config/omail/accounts.json")" = "current" ] \
  || fail "an older config store overwrote the current one"
[ "$(cat "$both/cache/omail/inbox.json")" = "current" ] \
  || fail "an older cache store overwrote the current one"
[ -e "$both/config/omamail" ] || fail "the older config store was consumed"

# Nothing to move is not an error: this runs on every install.
empty="$test_root/empty"
mkdir -p "$empty/config" "$empty/cache"
migrate "$empty"
[ ! -e "$empty/config/omail" ] || fail "migration invented a config directory"

# The keyring helper takes attribute pairs now, because keying a refresh token
# on the OAuth client alone lets two accounts sharing one client overwrite each
# other. An empty value is a secret-tool wildcard, so it is refused outright.
for bad in "" "a" "client-id "; do
  if printf 'token\n' | sh scripts/keyring-store.sh $bad >/dev/null 2>&1; then
    fail "keyring-store.sh accepted a malformed attribute list: '$bad'"
  fi
done

printf 'test_install.sh ok\n'
