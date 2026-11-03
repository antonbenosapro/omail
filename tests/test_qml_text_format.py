#!/usr/bin/env python3
"""Every element that draws words declares, itself, that they are plain text.

Qt's default is Text.AutoText, which runs Qt.mightBeRichText() over the string
and switches to the rich text engine when it finds something tag-shaped. That
engine fetches <img src="https://..."> for real — so a subject line, a sender
name, or a snippet carrying one becomes exactly the tracking beacon the message
body is stripped of, without the body ever being opened.

This used to check only the bindings that looked untrusted, by a list of the
expressions known to carry a stranger's words, and it missed a server's [ALERT]
text. Its successor accepted any element whose body contained the word
`textFormat` — so `Text.RichText` passed, and so did a parent whose nested child
declared one. So the rule is now exact:

- Every Text, Label, TextEdit and TextArea names `textFormat: <Type>.PlainText`
  in its own body, not a child's. The only ones excused are those whose text
  is a string literal, which nobody else can write into.
- Rich text is allowed only where the line says why, with
  `// rich-text-ok: <reason>` on the `textFormat` line itself. The reader's
  message body is the one: it renders a document Html.sanitize has already
  been through.
- TextInput and TextField are not checked: they have no rich text mode.
- A repo-local wrapper — a component that takes `text` and draws it in a Text
  of its own — is covered by the rule above applying inside it; this also
  fails if one forwards `text` by alias to an element it does not check.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

ELEMENT = re.compile(r"(?<![\w.])(?:[A-Z]\w*\.)?(Text|Label|TextEdit|TextArea)\s*\{")
LITERAL = re.compile(r'^\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')\s*$', re.S)
PLAIN = re.compile(r"^[ \t]*textFormat\s*:\s*(Text|TextEdit|TextArea|Label)\.PlainText\s*$", re.M)
FORMAT = re.compile(r"^[ \t]*textFormat\s*:", re.M)
ALLOW = re.compile(r"//\s*rich-text-ok:\s*(\S.{9,})$")
ALIAS = re.compile(r"^\s*property\s+alias\s+(\w+)\s*:\s*([\w.]+)\s*$", re.M)


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


def own(masked):
    """A block body with everything inside nested braces blanked.

    What is left is the element's own property list: a child element's
    `textFormat`, or one inside a JS block, is no longer there to be found.
    """
    out = list(masked)
    depth = 0
    for k, c in enumerate(masked):
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            continue
        if depth > 0 and c != "\n":
            out[k] = " "
    return "".join(out)


def blocks(source):
    """Every checked element, as (name, start offset, body, masked body)."""
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
        yield (opening.group(1), opening.start(), source[start:index - 1],
               masked[start:index - 1])


def line_of(source, offset):
    return source.count("\n", 0, offset) + 1


def check(path, source):
    failures = []
    where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    for name, at, body, masked in blocks(source):
        mine = own(masked)
        label = "%s:%d: %s" % (where, line_of(source, at), name)
        # The binding is found in the element's own properties, so a ":" in a
        # string or a child's `text:` cannot stand in for it.
        found = re.search(r"^\s*text\s*:(.*?)(?=^\s*[\w.]+\s*:|\Z)", mine, re.S | re.M)
        if found:
            binding = body[found.start(1):found.end(1)]
            if LITERAL.match(binding):
                continue
        if PLAIN.search(mine):
            continue
        declared = FORMAT.search(mine)
        if declared:
            line_start = declared.start()
            line_end = body.find("\n", declared.end())
            line = body[line_start:len(body) if line_end < 0 else line_end]
            if ALLOW.search(line):
                continue
            failures.append("%s declares %s without `// rich-text-ok: <reason>`"
                            % (label, " ".join(line.split())))
            continue
        excerpt = " ".join(body[found.start(1):found.end(1)].split())[:60] if found else "(none)"
        failures.append("%s { text: %s } needs its own textFormat: %s.PlainText"
                        % (label, excerpt, "TextEdit" if name in ("TextEdit", "TextArea") else "Text"))

    # A wrapper that forwards `text` by alias draws it somewhere this file
    # must be able to see.
    ids = {}
    for name, at, body, masked in blocks(source):
        found = re.search(r"^\s*id\s*:\s*(\w+)\s*$", own(masked), re.M)
        if found:
            ids[found.group(1)] = name
    for alias in ALIAS.finditer(mask(source)):
        target = alias.group(2).split(".")
        if len(target) == 2 and target[1] == "text" and target[0] not in ids:
            failures.append("%s:%d: property alias %s forwards text to %s, which is not a checked element"
                            % (where, line_of(source, alias.start()), alias.group(1), alias.group(2)))
    return failures


def self_test():
    """The rule must catch what it exists to catch. Each of these is a way the
    previous check let a stranger's markup through."""
    bad = {
        "rich": 'Text { text: model.subject\n textFormat: Text.RichText }',
        "auto": 'Text { text: model.subject\n textFormat: Text.AutoText }',
        "styled": 'Label { text: model.subject\n textFormat: Text.StyledText }',
        "child": 'Text { text: model.subject\n Text { textFormat: Text.PlainText } }',
        "missing": 'TextEdit { text: model.subject }',
        "area": 'TextArea { text: model.subject }',
        "qualified": 'QQC.TextArea { text: model.subject }',
        "unjustified": 'TextEdit { text: html\n textFormat: TextEdit.RichText }',
        "short reason": 'TextEdit { text: html\n textFormat: TextEdit.RichText // rich-text-ok: ok }',
        "aliased": 'Item {\n property alias text: other.text\n Rectangle { id: other } }',
    }
    good = {
        "plain": 'Text { text: model.subject\n textFormat: Text.PlainText }',
        "edit": 'TextEdit { text: model.subject\n textFormat: TextEdit.PlainText }',
        "literal": 'Text { text: "Inbox" }',
        "justified": 'TextEdit { text: html\n textFormat: TextEdit.RichText // rich-text-ok: sanitised by Html.js }',
        "input": 'TextInput { text: model.subject }',
        "alias to checked": 'Item {\n property alias text: inner.text\n Text { id: inner\n textFormat: Text.PlainText } }',
    }
    here = ROOT / "self-test.qml"
    broken = []
    for label, source in bad.items():
        if not check(here, source):
            broken.append("self-test: %s passed and must not" % label)
    for label, source in good.items():
        if check(here, source):
            broken.append("self-test: %s failed: %s" % (label, check(here, source)))
    return broken


def main():
    failures = self_test()
    files = [
        p
        for d in ("", "account", "cache", "message", "providers", "components", "keys")
        for p in sorted((ROOT / d).glob("*.qml"))
    ]
    for path in files:
        failures += check(path, path.read_text(encoding="utf-8"))
    if failures:
        for line in failures:
            print("test_qml_text_format.py: " + line, file=sys.stderr)
        return 1
    print("test_qml_text_format.py ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
