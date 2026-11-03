#!/bin/sh
# The message-body cache: one file per message, under one directory per account.
#
# Bodies used to live inside the account's store alongside the message list,
# which meant the whole cache was held in memory and re-serialised on the GUI
# thread every time anything in it changed. As files they cost nothing to keep,
# so the cache can be deep; the price is that eviction happens out here.
#
# Eviction is least-recently-used, and mtime is what carries "used": a read
# touches the file, so a message opened every morning outlives a hundred that
# arrived overnight.
#
# It also keeps the account's list store beside them — store-<keyId>.json in
# the cache directory — as far as removing it and taking over the file it had
# before keyIds, which was named after the address. That name is the one value
# here that must not be an argument to anything, so it arrives on stdin, is
# compared in the shell, and the file is then reached by its inode.
#
# One line, read with `read` rather than `cat`: Quickshell's Process.write()
# never closes stdin, so anything waiting for EOF hangs forever.
set -eu

usage() {
  printf '%s\n' 'usage: body-cache.sh put|touch|prune|clear|retire|adopt-store|forget-store <dir> [name|keyId] [limit]' >&2
  exit 2
}

command=${1:-}
dir=${2:-}
[ -n "$command" ] && [ -n "$dir" ] || usage

# A trailing slash would make every check below look at one path and rm act on
# another: `rm -rf link/` empties whatever a symlink points at.
while :; do
  case "$dir" in
    */) dir=${dir%/} ;;
    *) break ;;
  esac
done
[ -n "$dir" ] || usage

# The caller builds names with a prefix-free escape, so a name can never contain
# a separator. Refusing one here as well means a bug up there cannot become a
# write outside the cache.
safe_name() {
  case "$1" in
    ''|*/*|.|..) return 1 ;;
  esac
  return 0
}

is_key_id() {
  case "$1" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 32 ]
}

# The list store's directory, and only that: omail under the cache home, and
# not a link to somewhere else.
# The mark a removed account's directory leaves beside it. A keyId is random and
# never made twice, so the mark can stay for good.
retired_mark() {
  printf '%s/.retired-%s' "${dir%/*}" "${dir##*/account-}"
}

store_dir() {
  case "$dir" in
    */omail) ;;
    *) usage ;;
  esac
  [ -L "$dir" ] && usage
  return 0
}

# The name the store had before keyIds, from stdin. "-" or nothing means none.
legacy_name() {
  legacy=''
  IFS= read -r legacy || true
  case "$legacy" in
    -|'') legacy=''; return 0 ;;
    account-*.json) safe_name "$legacy" || legacy='' ;;
    *) legacy='' ;;
  esac
}

# Removes one old store without its name ever reaching rm: find lists the
# directory, the shell compares, and the match is deleted by inode. A link is
# never followed and only an old store's name is ever eligible.
remove_legacy() {
  [ -n "$legacy" ] || return 0
  find "$dir" -maxdepth 1 -type f -name 'account-*.json' -printf '%i %f\n' 2>/dev/null \
    | while IFS=' ' read -r inode file; do
        [ "$file" = "$legacy" ] || continue
        find "$dir" -maxdepth 1 -type f -name 'account-*.json' -inum "$inode" -delete
      done
}

prune_dir() {
  keep=$1
  [ -d "$dir" ] || return 0
  # Newest first, then drop everything past the limit. Names carry no spaces or
  # newlines by construction, so a plain read splits them correctly.
  find "$dir" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | tail -n +"$((keep + 1))" \
    | while IFS=' ' read -r _stamp path; do
        [ -n "$path" ] && rm -f -- "$path"
      done
}

umask 077

case "$command" in
  put)
    name=${3:-}
    limit=${4:-1000}
    safe_name "$name" || usage
    IFS= read -r payload
    [ -n "$payload" ] || exit 3
    # A write the account started before it was removed must not bring its
    # directory back. Checked before, and again after: whichever side of the
    # mark this write lands, `retire` or this removes what it wrote.
    [ -e "$(retired_mark)" ] && exit 0
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    tmp="$dir/.tmp.$$"
    printf '%s\n' "$payload" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$dir/$name"
    if [ -e "$(retired_mark)" ]; then
      rm -rf -- "$dir"
      exit 0
    fi
    prune_dir "$limit"
    ;;
  touch)
    name=${3:-}
    safe_name "$name" || usage
    [ -f "$dir/$name" ] && touch -m -- "$dir/$name"
    ;;
  prune)
    prune_dir "${3:-1000}"
    ;;
  clear|retire)
    # `retire` is `clear` for an account being removed rather than signed out
    # of: it also leaves the mark `put` checks, so a write already on its way
    # cannot recreate the directory after it is gone.
    #
    # Only ever one account's directory, and only if it looks like one: an
    # account-<keyId> under omail/bodies. The parent itself — what a missing
    # key would leave — is every account's cache and is refused, and so is a
    # link, whose target is somebody else's directory.
    case "$dir" in
      */omail/bodies/account-*) ;;
      *) usage ;;
    esac
    is_key_id "${dir##*/account-}" || usage
    [ -L "$dir" ] && usage
    if [ "$command" = retire ]; then
      mkdir -p "${dir%/*}"
      : > "$(retired_mark)"
    fi
    rm -rf -- "$dir"
    ;;
  adopt-store)
    # Called once, when the store under the keyId could not be read. The old
    # file is copied in through redirections, so its name is never an
    # argument, then removed. An existing new store always wins: the old one
    # is then only an address left lying in a file name.
    key_id=${3:-}
    is_key_id "$key_id" || usage
    store_dir
    legacy_name
    [ -n "$legacy" ] || exit 0
    target="$dir/store-$key_id.json"
    if [ ! -e "$target" ] && [ -f "$dir/$legacy" ] && [ ! -L "$dir/$legacy" ]; then
      tmp="$dir/.tmp.$$"
      cat < "$dir/$legacy" > "$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$target"
      remove_legacy
      printf 'adopted\n'
      exit 0
    fi
    remove_legacy
    ;;
  forget-store)
    # Removing an account: its store, and the one from before keyIds if it is
    # still there.
    key_id=${3:-}
    is_key_id "$key_id" || usage
    store_dir
    legacy_name
    target="$dir/store-$key_id.json"
    rm -f -- "$target"
    remove_legacy
    ;;
  *)
    usage
    ;;
esac
