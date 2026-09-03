#!/bin/sh
# What save-attachment.sh writes, and where it refuses to.
#
# The filename comes off the message, which means it comes from whoever sent
# it. Most of these check that a hostile one lands inside the downloads
# directory as an ordinary file rather than anywhere else.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/scripts/save-attachment.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/omamail-attachment-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM HUP

# xdg-open must not actually run: these tests would open a viewer per case.
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/xdg-open"
chmod +x "$work/bin/xdg-open"
printf '#!/bin/sh\nexec "$@"\n' > "$work/bin/setsid"
chmod +x "$work/bin/setsid"

failures=0

# Saves $2 under the name $1 and prints the name it actually used.
save() {
  printf '%s\n' "$(printf '%s' "$2" | base64 | tr -d '\n')" \
    | PATH="$work/bin:$PATH" sh "$script" "$3" "$1" 2>/dev/null
}

check() {
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n' "$1"
    printf '       expected: %s\n' "$3"
    printf '       actual:   %s\n' "$2"
    failures=$(( failures + 1 ))
  fi
}

printf 'save-attachment.sh\n'

# ------------------------------------------------------------------ the file

dir="$work/plain"
name=$(save 'report.pdf' 'hello world' "$dir")
check 'the file keeps its name' "$name" 'report.pdf'
check 'and its contents' "$(cat "$dir/report.pdf")" 'hello world'

# The downloads directory may not exist yet on a fresh install.
check 'the directory is created' "$( [ -d "$dir" ] && echo yes )" 'yes'

# ------------------------------------------------------- a hostile filename
#
# The name reaches a path. Every one of these has to end up as a single
# component inside the directory it was given.

dir="$work/hostile"
name=$(save '../../../../etc/passwd' 'pwned' "$dir")
check 'a traversal becomes one component' "$name" 'etcpasswd'
check 'and nothing is written outside' "$(find "$work" -name passwd | wc -l | tr -d ' ')" '0'

name=$(save '/etc/shadow' 'pwned' "$dir")
check 'an absolute path becomes one component' "$name" 'etcshadow'

name=$(save '-rf' 'x' "$dir")
check 'a leading dash is dropped, so it cannot read as an option' "$name" 'rf'

name=$(save '.bashrc' 'x' "$dir")
check 'a dotfile does not stay hidden' "$name" 'bashrc'

name=$(save '...' 'x' "$dir")
check 'a name of nothing usable gets one' "$name" 'attachment'

# A newline would end the name and start something else in anything reading a
# line at a time.
name=$(save "$(printf 'a\nb.txt')" 'x' "$dir")
check 'a newline is removed rather than splitting the name' "$name" 'ab.txt'

# ------------------------------------------------------------------ collisions
#
# The file already there may be something the user still wants.

dir="$work/twice"
first=$(save 'invoice.pdf' 'one' "$dir")
second=$(save 'invoice.pdf' 'two' "$dir")
third=$(save 'invoice.pdf' 'three' "$dir")
check 'the first keeps the name' "$first" 'invoice.pdf'
check 'the second is numbered' "$second" 'invoice (1).pdf'
check 'and so is the third' "$third" 'invoice (2).pdf'
check 'the first file is untouched' "$(cat "$dir/invoice.pdf")" 'one'
check 'and the second is its own' "$(cat "$dir/invoice (1).pdf")" 'two'

# A name with no extension still counts up.
save 'README' 'a' "$dir" >/dev/null
name=$(save 'README' 'b' "$dir")
check 'a name with no extension is numbered too' "$name" 'README (1)'

# ---------------------------------------------------------------- the payload

# Gmail's API answers in base64url, which `base64 -d` does not accept, and an
# IMAP part arrives in standard base64. Both have to decode to the same bytes.
dir="$work/encoding"
standard='+/+/ABCD'
urlsafe='-_-_ABCD'
printf '%s\n' "$standard" | PATH="$work/bin:$PATH" sh "$script" "$dir" 'std.bin' >/dev/null 2>&1
printf '%s\n' "$urlsafe" | PATH="$work/bin:$PATH" sh "$script" "$dir" 'url.bin' >/dev/null 2>&1
check 'base64url decodes to the same bytes as base64' \
  "$(od -An -tx1 < "$dir/url.bin" | tr -d ' \n')" \
  "$(od -An -tx1 < "$dir/std.bin" | tr -d ' \n')"

# Unpadded is also part of the url-safe form.
printf '%s\n' 'aGk' | PATH="$work/bin:$PATH" sh "$script" "$dir" 'nopad.txt' >/dev/null 2>&1
check 'a stripped pad is restored' "$(cat "$dir/nopad.txt")" 'hi'

# A decode that fails must leave nothing behind, not a truncated file with the
# right name that something else will later try to open.
dir="$work/corrupt"
if printf '%s\n' 'not!valid!base64!' \
  | PATH="$work/bin:$PATH" sh "$script" "$dir" 'bad.bin' >/dev/null 2>&1; then
  printf '  FAIL corrupt base64 was accepted\n'
  failures=$(( failures + 1 ))
else
  printf '  ok   corrupt base64 fails\n'
fi
check 'and leaves no file behind' "$(ls "$dir" 2>/dev/null | wc -l | tr -d ' ')" '0'

# An empty request is a bug in the caller, not an empty file on disk.
dir="$work/empty"
if printf '\n' | PATH="$work/bin:$PATH" sh "$script" "$dir" 'x.bin' >/dev/null 2>&1; then
  printf '  FAIL an empty payload was accepted\n'
  failures=$(( failures + 1 ))
else
  printf '  ok   an empty payload fails\n'
fi

# ------------------------------------------------------------------- usage

if printf 'aGk\n' | sh "$script" >/dev/null 2>&1; then
  printf '  FAIL missing arguments were accepted\n'
  failures=$(( failures + 1 ))
else
  printf '  ok   missing arguments are refused\n'
fi

if [ "$failures" -ne 0 ]; then
  printf '\n%s check(s) failed\n' "$failures"
  exit 1
fi
printf 'save-attachment.sh ok\n'
