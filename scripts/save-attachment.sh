#!/bin/sh
# Writes one attachment to the downloads directory. It does not open it: a file
# the sender chose is not something to hand to a desktop handler unasked, so the
# window offers an explicit Open once the save has been reported.
#
# One line on stdin, the filename and the octets, both base64 and separated by
# a space. The octets are base64 already, which is what both providers hand
# back: Gmail sends base64url in the attachment resource and `parseRfc822`
# leaves an IMAP part encoded. The filename is the sender's too, and it is not
# an argument because every local account can read a process's arguments in
# /proc — "Biopsy results J Doe.pdf" is not something to show them. `read`
# rather than `cat`, because Quickshell's Process.write() never closes stdin
# and anything waiting for EOF would hang forever.
#
#   printf '%s %s\n' "$name_b64" "$octets_b64" | save-attachment.sh <directory>
#
# The filename is printed on success, because it is not necessarily the one
# asked for: a name already taken gets a counter, so saving the same invoice
# twice keeps both.
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

directory=${1:-}
[ -n "$directory" ] || fail 'usage: save-attachment.sh <directory>'

IFS=' ' read -r encoded payload || fail 'save-attachment.sh: no attachment on stdin'
[ -n "$payload" ] || fail 'save-attachment.sh: empty attachment'
# `printf` is a builtin, so the name reaches base64 through a pipe and is never
# an argument either.
requested=$(printf '%s' "$encoded" | base64 -d 2>/dev/null) \
  || fail 'save-attachment.sh: filename is not valid base64'
[ -n "$requested" ] || fail 'save-attachment.sh: empty filename'

# The sender chose this string. It reaches a path, so every part of it that
# could leave the directory is removed rather than escaped: a separator, the
# two traversal names, and a leading dash that would read as an option to
# whatever opens the file. What survives is one path component.
sanitize() {
  printf '%s' "$1" \
    | tr -d '\000-\037/\177' \
    | sed -e 's/^-*//' -e 's/^\.*//' -e 's/[[:space:]]\{1,\}/ /g' \
          -e 's/^ //' -e 's/ $//'
}

name=$(sanitize "$requested")

# Nothing usable was left, or the sender sent only dots and slashes.
case "$name" in
  ''|.|..) name='attachment' ;;
esac

# A very long name is a filesystem error rather than a security problem, but it
# is still a failed save. 200 bytes leaves room for the counter below inside
# every filesystem limit that matters.
if [ "${#name}" -gt 200 ]; then
  # Keep the extension, which is what decides how the file opens.
  case "$name" in
    *.*)
      extension=${name##*.}
      case "$extension" in
        *[!A-Za-z0-9]*|'') name=$(printf '%s' "$name" | cut -c1-200) ;;
        *) name="$(printf '%s' "${name%.*}" | cut -c1-$((199 - ${#extension}))).$extension" ;;
      esac
      ;;
    *) name=$(printf '%s' "$name" | cut -c1-200) ;;
  esac
fi

mkdir -p -- "$directory" || fail 'save-attachment.sh: could not create the downloads directory'

# A name already on disk gets a counter rather than overwriting: the file there
# may be something the user still wants, and an attachment is not authoritative
# about anything.
target="$directory/$name"
if [ -e "$target" ]; then
  case "$name" in
    *.*) stem=${name%.*}; suffix=".${name##*.}" ;;
    *) stem=$name; suffix='' ;;
  esac
  counter=1
  while [ -e "$directory/$stem ($counter)$suffix" ]; do
    counter=$((counter + 1))
    # A directory holding this many copies is a bug somewhere else, and the
    # loop must not be unbounded.
    [ "$counter" -le 999 ] || fail 'save-attachment.sh: too many copies of that name'
  done
  name="$stem ($counter)$suffix"
  target="$directory/$name"
fi

umask 077

# base64url is what Gmail's API returns, and `base64 -d` does not accept it.
# The two substitutions are a no-op on standard base64, so both providers go
# through the same path. Padding is restored because a stripped tail is also
# part of the url-safe form.
normalized=$(printf '%s' "$payload" | tr -- '-_' '+/' | tr -d '\n\r')
case $(( ${#normalized} % 4 )) in
  2) normalized="$normalized==" ;;
  3) normalized="$normalized=" ;;
  1) fail 'save-attachment.sh: attachment is not valid base64' ;;
esac

# Written to a temporary name in the same directory and moved into place, so a
# reader — or the user's file manager — never sees a partial file, and a decode
# that fails leaves nothing behind at all.
temporary="$target.part"
trap 'rm -f -- "$temporary"' EXIT INT TERM HUP

printf '%s' "$normalized" | base64 -d > "$temporary" 2>/dev/null \
  || fail 'save-attachment.sh: attachment is not valid base64'

# The file is the user's, not the cache's: 077 above is for the write, and this
# is what they would expect to find in their own downloads directory.
chmod 600 -- "$temporary"
mv -f -- "$temporary" "$target"
trap - EXIT INT TERM HUP

printf '%s\n' "$name"
