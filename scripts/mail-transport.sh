#!/bin/sh
# Runs one IMAP conversation, or sends one message over SMTP, and hands the
# result back to the panel.
#
# curl is the client. It owns TLS, LOGIN, the tagged command it wraps each
# request in, and the literals in the reply; `Imap.js` owns every string that
# goes in and every decision about what comes back. Nothing in between needs a
# library the plugin would have to carry.
#
# ## Everything crosses on stdin, base64-encoded
#
# One line, fields separated by spaces:
#
#   imap <b64 url> <b64 user:password> <b64 command> [<b64 command> ...]
#   smtp <b64 url> <b64 user:password> <b64 from> <b64 message> <b64 rcpt> ...
#
# base64 rather than the values themselves, for three reasons that each bite
# once during this script's life:
#
#   - a password never reaches the process table, which is the same rule
#     keyring-store.sh follows for the refresh token
#   - a password, a folder name and an IMAP command may all contain quotes,
#     backslashes and spaces; base64 has none of those, so the field split is a
#     plain `set --` and there is no escaping to get wrong
#   - the fields arrive on one line, because Quickshell's Process.write() never
#     closes stdin and anything reading to EOF would hang forever
#
# ## And comes back base64-encoded
#
#   <curl exit code>
#   <b64 stdout>
#   <b64 stderr>
#
# The response is base64 for a different reason: IMAP measures a literal in
# octets, so the parser has to count octets. Base64 keeps the byte count exact
# across a pipe the shell would otherwise read as text, keeps binary attachment
# data intact, and guarantees no newline inside a response can be mistaken for
# the end of one.
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

decode() {
  printf '%s' "$1" | base64 -d 2>/dev/null || fail 'mail-transport.sh: bad base64 field'
}

# curl's config format quotes with "..." and escapes with a backslash. Only two
# characters need that, and both turn up in real passwords.
#
# A newline needs something else. curl's config parser is line-oriented and no
# escape re-joins a split line, so a CR or an LF inside a value does not stay
# inside it: the tail of the value becomes the next config line, and curl reads
# a line as a directive. A password containing a newline could therefore add
# `upload-file` or `output` to the request that carries it. Quoting cannot
# express such a value, so it is removed rather than escaped — no IMAP command,
# URL, address or credential may legally contain a bare CR or LF anyway.
#
# This is the transport's own guard, not the callers'. `ImapProtocol.js` strips
# or encodes every value it composes, and did so before this existed; the point
# is that a script holding a password must not depend on that being true of
# whoever calls it next. Every value that becomes a config directive passes
# through here and nothing else does — the SMTP message body is written to a
# file, so a legitimately multi-line message never reaches this function.
escape() {
  printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# One line, never wrapped and with no trailing newline of its own — the caller
# adds exactly one, so the reply is always three lines however long a message
# was. `-w 0` is not portable and both implementations wrap by default, so the
# newlines are stripped rather than suppressed.
encode() {
  base64 < "$1" | tr -d '\n'
}

IFS= read -r line || fail 'mail-transport.sh: no request on stdin'
[ -n "$line" ] || fail 'mail-transport.sh: empty request'

# The fields are base64, which contains no spaces, so splitting on them is safe
# and needs no quoting rules.
# shellcheck disable=SC2086
set -- $line
[ $# -ge 4 ] || fail 'mail-transport.sh: usage: <mode> <url> <credentials> <arg>...'

mode=$1
url=$(decode "$2")
credentials=$(decode "$3")
shift 3

case "$mode" in
  imap|smtp) ;;
  *) fail 'mail-transport.sh: mode must be imap or smtp' ;;
esac

# The URL is built and validated by Imap.js, which has already refused anything
# carrying userinfo, a port inside the host, or characters that could end the
# path. This is the second gate rather than the first: the scheme check is what
# stops a hand-edited accounts.json from pointing an authenticated client at
# file:// or at an ordinary web server.
case "$url" in
  imaps://*|imap://*|smtps://*|smtp://*) ;;
  *) fail 'mail-transport.sh: refusing a URL that is not imap(s) or smtp(s)' ;;
esac

# The part of a URL between the scheme and the path: host, and port if any.
authority_of() {
  authority=${1#*://}
  printf '%s' "${authority%%/*}"
}

# No userinfo. Imap.js never builds a URL with one — credentials travel as
# `user` in the config — so an "@" in the authority is a URL somebody else
# made, and it is the shape that fooled the loopback check below:
# `imap://localhost:1@evil.example/` begins with "localhost:", and curl dials
# evil.example. Refused outright rather than stripped, because a URL that was
# edited to carry one has no right reading to fall back on.
case "$(authority_of "$url")" in
  *@*) fail 'mail-transport.sh: refusing a URL with userinfo in it' ;;
esac

# The SMTP envelope. Each of these becomes `MAIL FROM:<...>` or `RCPT TO:<...>`
# and curl writes the value between the brackets as it is given, so a ">" ends
# the address and what follows is a parameter — `a@b.com> NOTIFY=NEVER` — and a
# line break is another command. ImapProtocol.js refuses such an address before
# it gets here and says why; this is the transport not depending on that, the
# same way `escape` does not depend on its callers stripping newlines.
#
# Checked before anything runs, in this shell rather than in `build_config`:
# that runs in a pipeline, where `fail` would end only the subshell and curl
# would be handed whatever config had been printed so far.
# Decoded with nothing taken off. $(...) strips trailing newlines, and an
# address checked without them is not the address that was sent.
envelope_field_safe() {
  value=$(decode "$1"; printf x)
  envelope_safe "${value%x}"
}

envelope_safe() {
  [ -n "$1" ] || return 1
  case "$1" in
    *[[:space:]]*|*[[:cntrl:]]*|*'<'*|*'>'*|*','*|*';'*|*'"'*) return 1 ;;
  esac
  return 0
}

if [ "$mode" = "smtp" ]; then
  [ $# -ge 3 ] || fail 'mail-transport.sh: smtp needs a sender, a message and a recipient'
  envelope_field_safe "$1" || fail 'mail-transport.sh: refusing a sender that is not one plain address'
  envelope_index=0
  for envelope_field in "$@"; do
    envelope_index=$(( envelope_index + 1 ))
    [ "$envelope_index" -gt 2 ] || continue
    envelope_field_safe "$envelope_field" \
      || fail 'mail-transport.sh: refusing a recipient that is not one plain address'
  done
fi

# The most a response may be, in octets, before it reaches the panel: the
# 25 MiB message cap (`MAX_MESSAGE_OCTETS` in ImapProtocol.js) plus 1 MiB for
# everything around it — the FETCH line, its flags and date, curl's own
# protocol lines. That headroom is generous: the framing of a whole page of
# list rows is a few kilobytes. Measured on curl's raw output, before it is
# base64-encoded for the pipe, so what the panel then decodes is at most a third
# larger than this.
#
# Partial fetches already keep a message under it; this is the bound on
# everything else a server might send, because the panel reads the whole reply
# into a string on the GUI thread. curl enforces it where it knows a size in
# advance; the check after it runs covers the rest, including the
# protocol-header channel curl's own limit never looks at.
max_response_octets=27262976

escaped_url=$(escape "$url")
escaped_credentials=$(escape "$credentials")

# ------------------------------------------------------- mechanism selection
#
# curl picks the "most secure" mechanism the server advertises, and it ranks
# GSSAPI above everything. A server offering GSSAPI to a machine with no
# Kerberos ticket therefore gets `AUTHENTICATE GSSAPI`, gss_init_sec_context()
# fails for want of a credential cache, and curl gives up with exit 94 rather
# than falling back — so the password is never tried at all. Axigen advertises
# exactly that set (CRAM-MD5, DIGEST-MD5, GSSAPI and no PLAIN), which is what
# made this reachable.
#
# The fix is to ask the server what it supports before authenticating and name
# a mechanism curl can actually complete. The probe is unauthenticated, so it
# costs no credentials and cannot itself fail the way the real connection did.
#
# Preference order is curl's own, minus the mechanisms that need a credential
# this machine may not have: the strongest shared secret first, plain-text
# last, and it only ever narrows what curl would have chosen from.
imap_probe='CAPABILITY'

# A plain-scheme URL to anything but this machine is STARTTLS, and required:
# `ssl-reqd` makes curl give up rather than carry on in clear when the server
# does not offer the upgrade, which is the stripping attack TLS-on-connect is
# chosen to avoid. Loopback alone may be plaintext, for a local bridge. This is
# the second gate: Imap.js only builds a plain URL for one of those two cases,
# and this keeps a password off the wire in clear even if it ever built another.
#
# The host is matched exactly, with nothing after it but an optional port of
# digits. A prefix match — "localhost:*" — also matched
# `localhost:1@evil.example`, whose host is evil.example; userinfo is refused
# above, and this does not rely on that.
is_loopback_authority() {
  for loopback_host in 127.0.0.1 localhost '[::1]'; do
    [ "$1" != "$loopback_host" ] || return 0
    case "$1" in
      "$loopback_host":*)
        loopback_port=${1#"$loopback_host":}
        case "$loopback_port" in
          ''|*[!0-9]*) ;;
          *) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

tls_directive() {
  case "$1" in
    imaps://*|smtps://*) return 0 ;;
  esac
  if is_loopback_authority "$(authority_of "$1")"; then
    return 0
  fi
  printf 'ssl-reqd\n'
}

# The server root for $url, with any mailbox path removed. Everything through
# the host and port is kept; what follows the first "/" after it is not.
probe_root() {
  # Shell parameter expansion rather than sed: the value is a URL, and every
  # character sed would take as a delimiter can legitimately appear in one.
  root=$1
  scheme=${root%%://*}
  rest=${root#*://}
  authority=${rest%%/*}
  if [ "$mode" = "imap" ]; then
    printf '%s://%s/' "$scheme" "$authority"
  else
    printf '%s://%s' "$scheme" "$authority"
  fi
}

# Whether GSSAPI could possibly succeed. A ticket may exist under a ccache the
# environment names rather than the default file, so this asks klist rather
# than looking for /tmp/krb5cc_$(id -u). No klist means no Kerberos worth
# trying. `-s` is a silent yes/no in both MIT and Heimdal.
have_kerberos_ticket() {
  command -v klist >/dev/null 2>&1 || return 1
  klist -s >/dev/null 2>&1
}

# The advertised mechanisms, uppercased and space-padded so a match on
# " NAME " cannot hit a prefix of a longer one.
run_probe() {
  if [ "$mode" = "imap" ]; then
    curl --config - --globoff --silent --show-error --max-filesize "$max_response_octets" \
      --max-time 20 --connect-timeout 20 <<PROBE 2>&1
url = "$1"
noproxy = "*"
$(tls_directive "$1")
request = "$imap_probe"
PROBE
  else
    curl --config - --globoff --silent --show-error --verbose --max-filesize "$max_response_octets" \
      --max-time 20 --connect-timeout 20 <<PROBE 2>&1
url = "$1"
noproxy = "*"
$(tls_directive "$1")
PROBE
  fi
}

advertised_mechanisms() {
  # The probe asks the server root rather than the mailbox in $url: a path
  # makes curl SELECT the folder before running the request, which needs the
  # login this probe exists to make work ("curl: (67) Select failed").
  probe_url=$(escape "$(probe_root "$url")")

  # IMAP puts the untagged CAPABILITY reply on stdout; ESMTP never reaches
  # stdout at all and its 250-AUTH line is only visible in curl's verbose
  # protocol trace on stderr. Both channels are kept, so one pass over the
  # text covers the two shapes.
  #
  # Retried once, because a server that throttles concurrent connections
  # answers some of them with nothing at all. Several accounts on one host
  # open their connections together at startup, and a probe that came back
  # empty would name no mechanism — which puts curl back on its own ranking,
  # back onto GSSAPI, and back to the exit 94 this whole function exists to
  # avoid. An empty answer is therefore retried rather than believed.
  # What a server offers changes about as often as the server is rebuilt, so
  # the answer is cached per host and every later connection reads the file
  # instead of opening a socket. That is what keeps several accounts on one
  # host from probing in parallel at startup — the case that produced the
  # empty answers in the first place.
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omail/capabilities"
  cache_file="$cache_dir/$(printf '%s|%s' "$mode" "$probe_url" | md5sum | cut -d' ' -f1)"
  if [ -s "$cache_file" ]; then
    cat "$cache_file"
    return 0
  fi

  probe_out=$(run_probe "$probe_url") || true
  case "$probe_out" in
    *AUTH*) ;;
    *)
      # A server that throttles concurrent connections answers some of them
      # with nothing at all, and an empty answer names no mechanism — which
      # puts curl back on its own ranking, back onto GSSAPI, and back to the
      # exit 94 this function exists to avoid. So it is retried rather than
      # believed.
      sleep 1
      probe_out=$(run_probe "$probe_url") || true
      ;;
  esac

  # IMAP answers `* CAPABILITY ... AUTH=CRAM-MD5 ...`; ESMTP answers
  # `250-AUTH PLAIN LOGIN CRAM-MD5`. Both reach us through curl's verbose
  # protocol lines, so one pass over the text covers the two shapes.
  found=" $(
    printf '%s' "$probe_out" \
      | tr -c 'A-Za-z0-9=-' ' ' \
      | tr 'a-z' 'A-Z' \
      | sed -e 's/AUTH=/ /g' \
      | tr ' ' '\n' \
      | grep -Ex 'CRAM-MD5|DIGEST-MD5|GSSAPI|NTLM|PLAIN|LOGIN|OAUTHBEARER|XOAUTH2' \
      | sort -u \
      | tr '\n' ' '
  )"

  # Only a real answer is cached. An empty one is what a throttled connection
  # returns, and writing that would make one bad moment permanent.
  case "$found" in
    *[A-Z]*)
      if mkdir -p "$cache_dir" 2>/dev/null; then
        # Written whole and moved into place, so a reader never sees half a
        # line: several of these run at once by design.
        temporary="$cache_file.$$"
        if printf '%s' "$found" > "$temporary" 2>/dev/null; then
          mv -f "$temporary" "$cache_file" 2>/dev/null || rm -f "$temporary"
        fi
      fi
      ;;
  esac

  printf '%s' "$found"
}

# The mechanism to name. Empty leaves curl's own ranking alone, which is only
# safe when GSSAPI cannot be what it picks.
choose_mechanism() {
  mechanisms=$(advertised_mechanisms)

  for candidate in CRAM-MD5 DIGEST-MD5 PLAIN LOGIN; do
    case "$mechanisms" in
      *" $candidate "*) printf '%s' "$candidate"; return 0 ;;
    esac
  done

  # Nothing usable was named — either the server offers only GSSAPI, or the
  # probe came back empty twice and we know nothing at all.
  #
  # Saying nothing here is not neutral. curl would rank GSSAPI first among
  # whatever the server actually advertises, and without a ticket that is the
  # exit 94 this function exists to prevent. So a ticket gets GSSAPI named,
  # and no ticket falls back to the mechanisms every IMAP and SMTP server
  # implements: naming one curl cannot use is a clean "Login denied" the user
  # can act on, where silence is a transport that dies with no message at all.
  if have_kerberos_ticket; then
    case "$mechanisms" in
      *" GSSAPI "*) printf 'GSSAPI'; return 0 ;;
    esac
  fi

  # Otherwise there is nothing honest to name: either the server offers only
  # mechanisms this machine cannot complete, or the probe never answered. A
  # guess would be wrong on the servers this exists for — the one that started
  # this offers no PLAIN at all — so curl keeps its own choice and a GSSAPI
  # attempt fails loudly rather than silently.
  return 0
}

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/omail.XXXXXX") || fail 'mail-transport.sh: no temporary directory'
trap 'rm -rf "$work"' EXIT INT TERM HUP

# OAuth carries a bearer token rather than a password, and curl selects the
# right mechanism from the option that supplies it. Probing would be wasted
# work and naming a password mechanism would be wrong, so the sign-in path is
# left exactly as it was.
mechanism=''
case "$credentials" in
  *:*) mechanism=$(choose_mechanism) ;;
esac

# The config is written to curl's own stdin rather than to a file: it carries
# the password, and a file holding one would be on disk for as long as curl
# took to read it. `build_config` prints it; the pipeline below is what feeds
# it in without it ever being written down.
build_config() {
if [ "$mode" = "smtp" ]; then
  [ $# -ge 3 ] || fail 'mail-transport.sh: smtp needs a sender, a message and a recipient'
  sender=$(decode "$1")
  shift 2

  printf 'url = "%s"\n' "$escaped_url"
  printf 'noproxy = "*"\n'
  tls_directive "$url"
  printf 'user = "%s"\n' "$escaped_credentials"
  [ -z "$mechanism" ] || printf 'login-options = "AUTH=%s"\n' "$mechanism"
  printf 'mail-from = "%s"\n' "$(escape "$sender")"
  for recipient in "$@"; do
    printf 'mail-rcpt = "%s"\n' "$(escape "$(decode "$recipient")")"
  done
  # The message is the one value too large to be an argument, and curl uploads
  # from a file rather than from a string — stdin is already carrying this
  # config. It lands in the 0700 directory the trap removes on any exit.
  printf 'upload-file = "%s"\n' "$(escape "$work/message")"
else
  # IMAP: one section per command, so a sequence — search a folder, then fetch
  # what came back — runs on a single connection. curl reuses the connection
  # across sections to the same host, so the TLS handshake and the LOGIN are
  # paid for once rather than once per command. `--next` resets almost every
  # option, which is why the URL and the credentials are repeated in each
  # section rather than set once at the top.
  first=1
  for argument in "$@"; do
    [ "$first" = "1" ] || printf 'next\n'
    first=0
    printf 'url = "%s"\n' "$escaped_url"
    tls_directive "$url"
    # Desktop HTTP/SOCKS proxy settings are for web traffic. In particular,
    # Omarchy's local SOCKS proxy accepts the IMAPS socket and then drops its
    # TLS handshake, which curl reports as error 35. Direct mail transport also
    # keeps account credentials from being offered through an unrelated proxy.
    # Repeated because `next` resets this curl option with the rest.
    printf 'noproxy = "*"\n'
    printf 'user = "%s"\n' "$escaped_credentials"
    # Repeated for the same reason the URL is: `next` resets it.
    [ -z "$mechanism" ] || printf 'login-options = "AUTH=%s"\n' "$mechanism"
    printf 'request = "%s"\n' "$(escape "$(decode "$argument")")"
  done
fi
}

# The SMTP body has to be on disk before curl starts, because the config it is
# named in is what stdin is carrying.
if [ "$mode" = "smtp" ]; then
  decode "$2" > "$work/message"
fi

# curl is the last stage, so `$?` is curl's own exit code rather than the
# config builder's.
#
# `--fail-early` is load-bearing, not tidiness. A sequence arrives here as
# `--next` sections on one connection, and several of those sequences are not
# idempotent: an archive on a server without MOVE is COPY, then STORE
# +\Deleted, then UID EXPUNGE. Without the flag curl runs every remaining
# section after one fails and exits with the code of the *last* transfer — so a
# COPY answered `NO [TRYCREATE]` was followed by the STORE and the EXPUNGE, curl
# exited 0, and the message was deleted without ever being copied. The panel
# said archived. With the flag curl stops at the first failing section and
# reports it, which is the only thing that makes a partly failed sequence read
# as a failure.
#
# Retried once on a transport failure, because a server that limits concurrent
# connections drops some of a burst outright — several accounts refreshing
# together, or a list load beside an unread poll. curl reports those as 35,
# 52, 55 or 56 depending on where the connection died, and none of them means
# the request was wrong: the same command succeeds a moment later. A dropped
# list load otherwise reached the panel as a page with messages missing from
# it, which is indistinguishable from mail that is not there.
#
# Only the transport is retried. A server that answered NO answered, and
# sending it again would be asking a question already settled.
#
# `--globoff` because nothing here is a URL pattern. curl reads "[1-9]" and
# "{a,b}" in a URL as a range to expand into several transfers, and a mailbox
# name may hold either — so a folder called "[Gmail]" or "{work,home}" could
# turn one request into several, each carrying the password.
run_curl() {
  build_config "$@" | curl \
    --config - \
    --globoff \
    --max-filesize "$max_response_octets" \
    --fail-early \
    --silent \
    --show-error \
    --dump-header "$work/headers" \
    --max-time 60 \
    --connect-timeout 20 \
    > "$work/out" 2> "$work/err"
}

# Backed off rather than retried once. A server that rations connections does
# not recover within a fixed second: several accounts on one host open their
# connections together, and the refusal outlasts any single pause. Measured
# against the host this exists for, a dozen attempts a second apart were all
# refused while a longer wait was answered — so the gap grows, and the last
# attempt is made several seconds after the first rather than one.
#
# Bounded, because a transport that keeps trying is a panel that never says
# anything. Four attempts over roughly seven seconds is long enough to cross a
# throttle window and short enough that a genuinely dead host still reports.
set +e
attempt=1
while : ; do
  run_curl "$@"
  status=$?
  # 3 is not here. It is a malformed URL, which is the same the next time and
  # the time after: retrying it spends seven seconds to reach the identical
  # answer while the panel shows nothing. The rest are connection-level and
  # say nothing about whether the request was right.
  case "$status" in
    35|52|55|56) ;;
    *) break ;;
  esac
  [ "$attempt" -lt 4 ] || break
  # 1, 2, 4 seconds. Doubling keeps the early retry quick for a single dropped
  # connection while still reaching a useful total for a throttled one.
  sleep_for=1
  n=1
  while [ "$n" -lt "$attempt" ]; do
    sleep_for=$(( sleep_for * 2 ))
    n=$(( n + 1 ))
  done
  sleep "$sleep_for"
  attempt=$(( attempt + 1 ))
  : > "$work/headers"
done
set -e

if [ "$mode" = "imap" ] && [ ! -s "$work/out" ] && [ -s "$work/headers" ]; then
  # libcurl recognises only a single numeric UID as a BODY FETCH. A legal IMAP
  # sequence-set is treated as a generic custom request, whose response is
  # delivered through curl's protocol-header callback instead of stdout.
  # A single UID BODY FETCH is recognised by libcurl and its complete response
  # stays on stdout; prefer that whenever it exists because the header channel
  # then contains only a partial protocol preamble.
  reply="$work/headers"
else
  reply="$work/out"
fi

# Over the cap, the reply is dropped and the request answers as curl does when
# its own limit fires: 63, which the panel turns into the too-large message.
reply_octets=$(wc -c < "$reply" | tr -d ' ')
if [ "${reply_octets:-0}" -gt "$max_response_octets" ]; then
  status=63
  : > "$reply"
  printf 'curl: (63) Maximum file size exceeded\n' > "$work/err"
fi

printf '%s\n' "$status"
encode "$reply"
printf '\n'
encode "$work/err"
printf '\n'
