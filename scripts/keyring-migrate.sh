#!/bin/sh
# Re-keys the keyring entries this plugin wrote before it named accounts by
# `keyId`, without the address ever being an argument to anything.
#
# Those entries carry the address as their "account" attribute, under the
# current service name or either of the two before it. secret-tool takes
# attributes on its command line, and every local account can read a process's
# arguments in /proc — so asking secret-tool for one by address is exactly the
# disclosure this exists to end, even once. Instead this talks to the Secret
# Service API through gdbus, whose arguments here are only a service name, a
# kind, object paths and the new attributes:
#
#   SearchItems {service, kind}    every entry of that kind, by object path
#   Properties.Get Attributes      read each one's attributes; the address is
#                                  compared here, in the shell, after it came
#                                  back on a pipe
#   Properties.Set Attributes      re-key the match in place — the secret never
#                                  moves, so there is nothing to read, store or
#                                  lose in between
#   Item.Delete                    `forget` only
#
# One line on stdin, because the address is the value that must not be an
# argument. Quickshell's Process.write() never closes stdin, hence `read`.
#
#   adopt <kind> <keyId> <account> <client-id> <0|1>
#       Re-key the entry for <account> to <keyId>. With 1, an entry from
#       before accounts existed (keyed by client alone) may be claimed when
#       there is none for <account>. Prints "adopted" when it changed one.
#   forget <kind> <account> <client-id>
#       Delete every entry still keyed by <account>.
#
# "-" stands for a field that is absent. Nothing is fatal to the caller: no
# gdbus, no Secret Service, or no match all mean "nothing to migrate", and the
# account then asks to be signed in again — which is what a missing entry has
# always meant.
set -eu

SERVICES='omail omamail omarchy-gmail'
CURRENT_SERVICE='omail'

IFS=' ' read -r mode kind first second third fourth || exit 2

case "$kind" in
  refresh-token|imap-password) ;;
  *) exit 2 ;;
esac

case "$mode" in
  adopt)
    key_id=$first; account=$second; client=$third; may_adopt=$fourth
    case "$key_id" in
      *[!0-9a-f]*|'') exit 2 ;;
    esac
    [ "${#key_id}" -eq 32 ] || exit 2
    ;;
  forget)
    account=$first; client=$second; may_adopt=0; key_id=''
    ;;
  *) exit 2 ;;
esac

# Every value that goes back into a GVariant literal below has to be plain:
# Credentials.lineField already sends "-" for anything else.
plain() {
  case "$1" in
    *"'"*|*'"'*|*'\'*|*' '*) return 1 ;;
  esac
  return 0
}
plain "$account" && plain "$client" || exit 2

command -v gdbus >/dev/null 2>&1 || exit 0

call() {
  gdbus call --session --dest org.freedesktop.secrets "$@" 2>/dev/null
}

# Every entry of this kind under one service name. Locked ones are unlocked
# first — that may put up the keyring's own prompt, which is the same prompt a
# plain lookup would — because an attribute cannot be changed on a locked item.
items() {
  found=$(call --object-path /org/freedesktop/secrets \
    --method org.freedesktop.Secret.Service.SearchItems \
    "{'service': '$1', 'kind': '$kind'}") || return 0
  case "$found" in
    *', [objectpath'*)
      command -v secret-tool >/dev/null 2>&1 \
        && secret-tool search --unlock service "$1" kind "$kind" >/dev/null 2>&1 || true
      found=$(call --object-path /org/freedesktop/secrets \
        --method org.freedesktop.Secret.Service.SearchItems \
        "{'service': '$1', 'kind': '$kind'}") || return 0
      ;;
  esac
  printf '%s\n' "$found" | grep -o "/org/freedesktop/secrets/collection/[A-Za-z0-9_/]*" || true
}

attributes_of() {
  call --object-path "$1" --method org.freedesktop.DBus.Properties.Get \
    org.freedesktop.Secret.Item Attributes || true
}

# One attribute's value, or nothing. A value GVariant had to quote differently
# (it holds a quote) reads as nothing, which is never equal to a plain field.
value_of() {
  printf '%s\n' "$1" | sed -n "s/.*'$2': '\([^']*\)'.*/\1/p" | head -n 1
}

has_attribute() {
  case "$1" in
    *"'$2': "*) return 0 ;;
  esac
  return 1
}

client_matches() {
  [ "$kind" = imap-password ] && return 0
  [ "$client" = - ] && return 0
  [ "$(value_of "$1" client-id)" = "$client" ]
}

if [ "$mode" = forget ]; then
  [ "$account" != - ] || exit 0
  for service in $SERVICES; do
    for path in $(items "$service"); do
      attrs=$(attributes_of "$path")
      [ "$(value_of "$attrs" account)" = "$account" ] || continue
      client_matches "$attrs" || continue
      call --object-path "$path" --method org.freedesktop.Secret.Item.Delete >/dev/null || true
    done
  done
  exit 0
fi

# The entry for this address, newest service name first, which is the order
# the lookups this replaces walked in. An entry already re-keyed carries a
# keyId, which is never an address, so it is never found here again.
chosen=''
if [ "$account" != - ]; then
  for service in $SERVICES; do
    for path in $(items "$service"); do
      attrs=$(attributes_of "$path")
      [ "$(value_of "$attrs" account)" = "$account" ] || continue
      client_matches "$attrs" || continue
      chosen=$path
      break 2
    done
  done
fi

# Before accounts, a Gmail token was keyed by client alone. Only the first
# mailbox may claim one, and only when it has nothing of its own.
if [ -z "$chosen" ] && [ "$may_adopt" = 1 ] && [ "$kind" = refresh-token ] && [ "$client" != - ]; then
  for service in $SERVICES; do
    for path in $(items "$service"); do
      attrs=$(attributes_of "$path")
      has_attribute "$attrs" account && continue
      [ "$(value_of "$attrs" client-id)" = "$client" ] || continue
      chosen=$path
      break 2
    done
  done
fi

[ -n "$chosen" ] || exit 0

if [ "$kind" = refresh-token ]; then
  [ "$client" != - ] || exit 0
  replacement="{'service': '$CURRENT_SERVICE', 'kind': '$kind', 'client-id': '$client', 'account': '$key_id'}"
else
  replacement="{'service': '$CURRENT_SERVICE', 'kind': '$kind', 'account': '$key_id'}"
fi

call --object-path "$chosen" --method org.freedesktop.DBus.Properties.Set \
  org.freedesktop.Secret.Item Attributes "<$replacement>" >/dev/null || exit 0
printf 'adopted\n'
