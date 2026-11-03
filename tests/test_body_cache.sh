#!/bin/sh
# body-cache.sh against a throwaway cache directory.
#
# What it proves: `clear` removes one account's directory and nothing else —
# not the parent, not a link's target, however the path is spelled — and the
# list store is adopted from its old address-named file and removed again
# without that name ever being an argument to anything the script runs.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/body-cache.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/omail-body-cache-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM HUP

# Every external command the script runs logs its arguments here first.
mkdir -p "$work/spy"
for tool in find rm mv chmod cat mkdir touch sort tail; do
  real=$(command -v "$tool")
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/argv.log"\nexec "%s" "$@"\n' \
    "$tool" "$work" "$real" > "$work/spy/$tool"
  chmod +x "$work/spy/$tool"
done
: > "$work/argv.log"

run() {
  PATH="$work/spy:$PATH" sh "$script" "$@" 2>/dev/null
}

failures=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"; failures=$((failures + 1)); fi
}

K1=0123456789abcdef0123456789abcd01
K2=0123456789abcdef0123456789abcd02
cache="$work/cache/omail"
bodies="$cache/bodies"
mkdir -p "$bodies/account-$K1" "$bodies/account-$K2" "$work/victim"
: > "$bodies/account-$K1/a.json"
: > "$bodies/account-$K2/b.json"
: > "$work/victim/keep.json"

printf 'body-cache.sh\n'

# clear
run clear "$bodies/account-$K1/" || true
check 'clear removes the account directory, trailing slash or not' \
  "$([ -e "$bodies/account-$K1" ] && echo present || echo gone)" 'gone'
check 'and leaves the other account alone' \
  "$([ -e "$bodies/account-$K2/b.json" ] && echo present || echo gone)" 'present'

ln -s "$work/victim" "$bodies/account-$K1"
run clear "$bodies/account-$K1/" || true
check 'a link is refused, with a trailing slash' \
  "$([ -e "$work/victim/keep.json" ] && echo kept || echo emptied)" 'kept'
run clear "$bodies/account-$K1" || true
check 'and without one' "$([ -e "$work/victim/keep.json" ] && echo kept || echo emptied)" 'kept'
rm -f "$bodies/account-$K1"

check 'the parent is refused' \
  "$(run clear "$bodies/" >/dev/null 2>&1 && echo ran || echo refused)" 'refused'
check 'a short key is refused' \
  "$(run clear "$bodies/account-0123" >/dev/null 2>&1 && echo ran || echo refused)" 'refused'
check 'a path that climbs out is refused' \
  "$(run clear "$bodies/account-$K2/.." >/dev/null 2>&1 && echo ran || echo refused)" 'refused'
check 'and nothing it refused was removed' \
  "$([ -e "$bodies/account-$K2/b.json" ] && echo present || echo gone)" 'present'

# adopt-store: the old name is the address, and arrives on stdin.
legacy='account-jane_40example.org.json'
printf '{"version":1}\n' > "$cache/$legacy"
check 'an old store is adopted' \
  "$(printf '%s\n' "$legacy" | run adopt-store "$cache" "$K1")" 'adopted'
check 'under the keyId' "$(cat "$cache/store-$K1.json")" '{"version":1}'
check 'readable only by its owner' "$(stat -c %a "$cache/store-$K1.json")" '600'
check 'and the address-named file is gone' \
  "$([ -e "$cache/$legacy" ] && echo present || echo gone)" 'gone'
check 'asking again changes nothing' \
  "$(printf '%s\n' "$legacy" | run adopt-store "$cache" "$K1")" ''

# A store already under the keyId wins; the old file only goes away.
printf 'old\n' > "$cache/$legacy"
printf '%s\n' "$legacy" | run adopt-store "$cache" "$K1" >/dev/null
check 'an existing store is not overwritten' "$(cat "$cache/store-$K1.json")" '{"version":1}'
check 'and the old file is removed anyway' \
  "$([ -e "$cache/$legacy" ] && echo present || echo gone)" 'gone'

# A link under the old name is never followed into, nor removed through.
ln -s "$work/victim/keep.json" "$cache/account-bob_40example.org.json"
printf '%s\n' 'account-bob_40example.org.json' | run adopt-store "$cache" "$K2" >/dev/null
check 'a link is not adopted' "$([ -e "$cache/store-$K2.json" ] && echo adopted || echo no)" 'no'
check 'nor its target touched' "$([ -e "$work/victim/keep.json" ] && echo kept || echo gone)" 'kept'
rm -f "$cache/account-bob_40example.org.json"

check 'a name that is not an old store is refused' \
  "$(printf '%s\n' '../victim/keep.json' | run adopt-store "$cache" "$K2"; [ -e "$work/victim/keep.json" ] && echo kept)" 'kept'
check 'a malformed key is refused' \
  "$(printf '%s\n' "$legacy" | run adopt-store "$cache" nothex >/dev/null 2>&1 && echo ran || echo refused)" 'refused'
check 'a directory that is not the cache is refused' \
  "$(printf '%s\n' "$legacy" | run adopt-store "$work/victim" "$K1" >/dev/null 2>&1 && echo ran || echo refused)" 'refused'

# forget-store removes both names.
printf 'x\n' > "$cache/$legacy"
printf '%s\n' "$legacy" | run forget-store "$cache" "$K1"
check 'forget removes the store' "$([ -e "$cache/store-$K1.json" ] && echo present || echo gone)" 'gone'
check 'and the old one' "$([ -e "$cache/$legacy" ] && echo present || echo gone)" 'gone'
printf -- '-\n' | run forget-store "$cache" "$K2"
check 'with no old name it still runs' "$?" '0'

# retire: removing an account, with a write it started still on its way.
K3=0123456789abcdef0123456789abcd03
mkdir -p "$bodies/account-$K3"
: > "$bodies/account-$K3/c.json"
run retire "$bodies/account-$K3" || true
check 'retire removes the directory' "$([ -e "$bodies/account-$K3" ] && echo present || echo gone)" 'gone'
printf 'payload\n' | run put "$bodies/account-$K3" late.json 1000 || true
check 'a write after retire does not bring it back' \
  "$([ -e "$bodies/account-$K3" ] && echo present || echo gone)" 'gone'
printf 'payload\n' | run put "$bodies/account-$K2" fresh.json 1000 || true
check 'another account still writes' "$([ -f "$bodies/account-$K2/fresh.json" ] && echo yes || echo no)" 'yes'
run clear "$bodies/account-$K2" || true
printf 'payload\n' | run put "$bodies/account-$K2" again.json 1000 || true
check 'a sign-out (clear) leaves no mark, so the account caches again' \
  "$([ -f "$bodies/account-$K2/again.json" ] && echo yes || echo no)" 'yes'

check 'no address was an argument to anything' \
  "$(grep -c 'example' "$work/argv.log" || true)" '0'
check 'and the spies saw the commands' "$([ -s "$work/argv.log" ] && echo yes || echo no)" 'yes'

if [ "$failures" -eq 0 ]; then
  printf 'body-cache.sh ok\n'
else
  printf '\nbody-cache.sh checks failed\n'
  exit 1
fi
