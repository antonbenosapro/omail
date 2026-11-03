#!/usr/bin/env python3
"""Every Text whose words are not a literal in the source must name its format.

Qt's default is Text.AutoText, which runs Qt.mightBeRichText() over the string
and switches to the rich text engine when it finds something tag-shaped. That
engine fetches <img src="https://..."> for real — so a subject line, a sender
name, or a snippet carrying one becomes exactly the tracking beacon the message
body is stripped of, without the body ever being opened.

This used to check only the bindings that looked untrusted, by a list of the
expressions known to carry a stranger's words. The list missed one: a server's
[ALERT] text, which a message body could forge, reached an account's error line
through a property the list did not name. So the rule is now the other way
round — any Text whose words are computed says what format they are, and the
only ones excused are string literals, which nobody else can write into.

The reader's own TextEdit is the one deliberate exception: it renders a
document that Html.sanitize has already been through.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# What a message, an account or Google can put words into.
_UNUSED = re.compile(
    r"\b(summary\s*\.|\.subject\b|\.snippet\b|\.from\b|\.display\b|\.email\b"
    r"|modelData\s*\.\s*filename\b|formatAddressList\b|lastError\b"
    r"|root\s*\.\s*requested\b|subjectField\s*\.\s*text\b)")

ELEMENT = re.compile(r"\b(Text|Label)\s*\{")
LITERAL = re.compile(r'^\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')\s*$', re.S)


def mask(source):
    """The source with strings and comments blanked to spaces, lengths kept.

    A regex over string literals alone was not enough: an apostrophe in a
    comment ("doesn't") opened a string that ran to the next one and took the
    braces in between with it, so whole Text elements were never examined —
    which is how an account-error label showing server text went unchecked.
    """
    out = list(source)
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif c in "\"'`":
            j = i + 1
            while j < n and source[j] != c:
                j += 2 if source[j] == "\\" else 1
            j = min(n, j + 1)
        else:
            i += 1
            continue
        for k in range(i, j):
            if out[k] != "\n":
                out[k] = " "
        i = j
    return "".join(out)


def blocks(source):
    """Every Text/Label element body, as (name, text) pairs."""
    masked = mask(source)
    for opening in ELEMENT.finditer(masked):
        start = opening.end()
        depth = 1
        index = start
        while index < len(masked) and depth:
            if masked[index] == "{":
                depth += 1
            elif masked[index] == "}":
                depth -= 1
            index += 1
        yield opening.group(1), source[start:index - 1], masked[start:index - 1]


def main():
    failures = []
    files = [
        p
        for d in ("", "account", "cache", "message", "providers", "components", "keys")
        for p in sorted((ROOT / d).glob("*.qml"))
    ]
    for path in files:
        source = path.read_text(encoding="utf-8")
        for name, body, masked in blocks(source):
            # The binding is found in the masked body, so a ":" inside a string
            # or a comment cannot end it early.
            found = re.search(r"^\s*text\s*:(.*?)(?=^\s*[\w.]+\s*:|\Z)",
                              masked, re.S | re.M)
            if not found:
                continue
            binding = body[found.start(1):found.end(1)]
            # A string literal is the one binding nobody else can write into.
            if LITERAL.match(binding):
                continue
            if "textFormat" not in masked:
                excerpt = " ".join(binding.split())[:60]
                failures.append("%s: %s { text: %s } needs a textFormat"
                                % (path.relative_to(ROOT), name, excerpt))
    if failures:
        for line in failures:
            print("test_qml_text_format.py: " + line, file=sys.stderr)
        return 1
    print("test_qml_text_format.py ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
