#!/usr/bin/env python3
"""Report ``…`` DocC symbol links whose argument labels match no declaration.

A Swift declaration has exactly one symbol name, and it spells out every
parameter's *external* argument label — defaulted parameters included. A doc
link that names a different label list therefore resolves to nothing, even
though the corresponding call still compiles because the defaults let a caller
omit those arguments. That is the whole defect this script looks for: links go
stale silently when a parameter is added to a signature, and nothing in the
Swift build ever complains.

Two parsing details keep the report free of the false positives a naive scanner
produces on this codebase:

- Declarations are bound to their innermost enclosing type body, so
  ``Router/resolve(profile:reporting:)`` is checked against `Router`'s own
  members rather than against every `resolve` in the repo. `func`, `init`,
  `subscript`, and enum `case` all contribute declarations, so an enum-case or
  initializer link is resolved rather than reported as missing.
- Parameter lists are split by a bracket-matching scanner that steps over `->`
  as one token and tracks `<>` separately from `()[]{}`, so the `>` of a
  closure parameter's return type does not close a bracket and corrupt the
  depth count.

Usage:

    Scripts/check-doc-links.py [--root DIR] [DIR ...]

Prints every stale link with the declarations that share its base name, then
exits 1 if any were found and 0 otherwise, so it can gate a commit or a job.
"""

import argparse
import os
import re
import sys
from collections import defaultdict

#: A Swift identifier, the building block of every pattern below.
IDENT = r"[A-Za-z_][A-Za-z0-9_]*"

#: Keywords that open a body whose declarations belong to a named type.
TYPE_KEYWORDS = ("struct", "class", "enum", "actor", "protocol", "extension")

#: Keywords that introduce a declaration carrying an argument-label list.
DECL_RE = re.compile(r"\b(func|init|subscript|case)\b")

#: Parameter-position modifiers that precede the argument label but are not it.
MODIFIERS = ("inout", "isolated", "borrowing", "consuming", "each", "some", "any")

#: A type or extension header, capturing the name whose body follows.
TYPE_RE = re.compile(r"\b(" + "|".join(TYPE_KEYWORDS) + r")\s+(`?)(" + IDENT + r")\2")

#: The declared name after a `func` or `case` keyword, backticked or bare.
NAME_RE = re.compile(r"\s*(`?)(" + IDENT + r")\1")

#: A double-backtick DocC symbol link, the only link form this script judges.
LINK_RE = re.compile(r"``([^`\n]+)``")

#: DocC's trailing overload disambiguator, e.g. ``foo(bar:)-(String)`` or `-9a2f`.
SUFFIX_RE = re.compile(r"-(\([^)]*\)|[0-9a-z]{2,})$")

#: A symbol link with an argument list: an optional `A/B.C` path, then `name(a:b:)`.
LINK_SHAPE_RE = re.compile(
    r"^((?:" + IDENT + r"[./])*)(" + IDENT + r")\(((?:(?:" + IDENT + r"|_):)*)\)$"
)

#: DocC accepts both `.` and `/` between the components of a symbol path.
PATH_SEPARATOR_RE = re.compile(r"[./]")


def blank_noncode(text):
    """Return `text` with comments and string literals blanked, newlines kept.

    Blanking rather than deleting keeps every byte offset stable, so a match
    found in the result maps straight back onto the original source.
    """
    out = []
    index, end = 0, len(text)
    while index < end:
        char, pair = text[index], text[index:index + 2]
        if pair == "//":
            stop = text.find("\n", index)
            stop = end if stop < 0 else stop
            out.append(" " * (stop - index))
        elif pair == "/*":
            stop = _end_of_block_comment(text, index)
            out.append(_blanked(text[index:stop]))
        elif text[index:index + 3] == '"""':
            stop = text.find('"""', index + 3)
            stop = end if stop < 0 else stop + 3
            out.append(_blanked(text[index:stop]))
        elif char == '"':
            stop = _end_of_string_literal(text, index)
            out.append(" " * (stop - index))
        else:
            out.append(char)
            stop = index + 1
        index = stop
    return "".join(out)


def _blanked(segment):
    """Return `segment` with every character but its newlines replaced by a space."""
    return "".join(char if char == "\n" else " " for char in segment)


def _end_of_block_comment(text, start):
    """Return the index just past the `/* … */` comment opening at `start`."""
    depth, index, end = 1, start + 2, len(text)
    while index < end and depth:
        if text[index:index + 2] == "/*":
            depth, index = depth + 1, index + 2
        elif text[index:index + 2] == "*/":
            depth, index = depth - 1, index + 2
        else:
            index += 1
    return index


def _end_of_string_literal(text, start):
    """Return the index just past the `"…"` literal opening at `start`."""
    index, end = start + 1, len(text)
    while index < end and text[index] != '"':
        index += 2 if text[index] == "\\" else 1
    return min(index + 1, end)


def match_bracket(text, open_index):
    """Return the index just past the bracket matching the one at `open_index`, or -1."""
    depth, index, end = 0, open_index, len(text)
    while index < end:
        if text[index] in "([{":
            depth += 1
        elif text[index] in ")]}":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    return -1


def scan(text):
    """Yield `(index, char, bracket_depth, angle_depth)` for each character of `text`.

    `->` is emitted as a single `-` so that the `>` of a closure parameter's
    return type is never mistaken for the close of a generic argument list.
    """
    bracket_depth, angle_depth = 0, 0
    index, end = 0, len(text)
    while index < end:
        if text[index:index + 2] == "->":
            yield index, "-", bracket_depth, angle_depth
            index += 2
            continue
        char = text[index]
        if char in "([{":
            bracket_depth += 1
        elif char in ")]}":
            bracket_depth -= 1
        elif char == "<":
            angle_depth += 1
        elif char == ">" and angle_depth:
            angle_depth -= 1
        yield index, char, bracket_depth, angle_depth
        index += 1


def split_parameters(parameters):
    """Split a parameter list on its top-level commas."""
    parts, start = [], 0
    for index, char, bracket_depth, angle_depth in scan(parameters):
        if char == "," and not bracket_depth and not angle_depth:
            parts.append(parameters[start:index])
            start = index + 1
    parts.append(parameters[start:])
    return [part.strip() for part in parts if part.strip()]


def label_separator(chunk):
    """Return the index of the `:` separating a parameter's labels from its type, or -1."""
    for index, char, bracket_depth, angle_depth in scan(chunk):
        if char == ":" and not bracket_depth and not angle_depth:
            return index
    return -1


def labels_of(parameters):
    """Return the external argument labels of `parameters`, as DocC spells them.

    An unlabeled parameter — `_ body:` in a function, or a bare associated value
    in an enum case — contributes `_`, which is what a symbol link writes.
    """
    labels = []
    for chunk in split_parameters(parameters):
        separator = label_separator(chunk)
        if separator < 0:
            labels.append("_")
            continue
        words = [w for w in chunk[:separator].replace("`", "").split() if not w.startswith("@")]
        words = [w for w in words if w not in MODIFIERS]
        labels.append(words[0] if words else "_")
    return labels


def selector(name, labels):
    """Return the symbol name spelled the way a DocC link spells it, e.g. `move(from:to:)`."""
    return "%s(%s)" % (name, "".join(label + ":" for label in labels))


def type_bodies(code):
    """Return `(start, end, name)` for every type or extension body in `code`."""
    bodies = []
    for match in TYPE_RE.finditer(code):
        brace = code.find("{", match.end())
        if brace < 0:
            continue
        end = match_bracket(code, brace)
        if end > 0:
            bodies.append((brace, end, match.group(3)))
    return bodies


def owner_at(bodies, index):
    """Return the name of the innermost type body containing `index`, or None."""
    best = None
    for start, end, name in bodies:
        if start < index < end and (best is None or start > best[0]):
            best = (start, name)
    return best[1] if best else None


def parameter_labels_at(code, index):
    """Return the labels of the parameter list starting at `index`, or None if there is none."""
    if index >= len(code) or code[index] != "(":
        return None
    end = match_bracket(code, index)
    return None if end < 0 else labels_of(code[index + 1:end - 1])


def _skip_generic_clause(code, index):
    """Return the index just past a `<…>` generic parameter clause at `index`."""
    if index >= len(code) or code[index] != "<":
        return index
    close = code.find(">", index)
    return close + 1 if close > 0 else index


def _init_selector(code, index):
    """Return the selector for the `init` whose keyword ends at `index`.

    Steps over a failable marker and any generic clause first, so `init?<T>(…)`
    reaches its parameter list.
    """
    while index < len(code) and code[index] in "?! ":
        index += 1
    index = _skip_generic_clause(code, index)
    return selector("init", parameter_labels_at(code, index) or [])


def _subscript_selector(code, index):
    """Return the selector for the `subscript` whose keyword ends at `index`."""
    paren = code.find("(", index)
    labels = parameter_labels_at(code, paren) if paren > 0 else None
    return selector("subscript", labels or [])


def _named_selector(code, index, keyword):
    """Return the selector for the `func` or `case` whose keyword ends at `index`.

    Returns None when no name follows, which is how a `case` that opens a
    pattern rather than a declaration drops out.
    """
    name_match = NAME_RE.match(code, index)
    if not name_match:
        return None
    name, index = name_match.group(2), name_match.end()
    if keyword == "func":
        index = _skip_generic_clause(code, index)
    while index < len(code) and code[index] == " ":
        index += 1
    return selector(name, parameter_labels_at(code, index) or [])


def _declared_selector(code, index, keyword):
    """Return the selector declared by `keyword` at `index`, or None if there is none."""
    if keyword == "init":
        return _init_selector(code, index)
    if keyword == "subscript":
        return _subscript_selector(code, index)
    return _named_selector(code, index, keyword)


def collect_declarations(code, declarations, owners):
    """Record every declared selector in `code`, keyed by its innermost enclosing type."""
    bodies = type_bodies(code)
    for match in DECL_RE.finditer(code):
        owner = owner_at(bodies, match.start())
        owners.add(owner)
        symbol = _declared_selector(code, match.end(), match.group(1))
        if symbol is not None:
            declarations.add((owner, symbol))


def collect_links(text):
    """Yield `(line, raw, qualifier, base, selector)` for each ``…`` link with a label list."""
    for match in LINK_RE.finditer(text):
        raw = match.group(1).strip()
        shape = LINK_SHAPE_RE.match(SUFFIX_RE.sub("", raw))
        if not shape:
            continue
        path = [part for part in PATH_SEPARATOR_RE.split(shape.group(1)) if part]
        base, arguments = shape.group(2), shape.group(3)
        labels = [label for label in arguments.split(":") if label]
        line = text.count("\n", 0, match.start()) + 1
        yield line, raw, (path[-1] if path else None), base, selector(base, labels)


def _contained_path(root, directory):
    """Return `directory` resolved under `root`, refusing anything that escapes it.

    Raises:
        ValueError: If the resolved path is outside `root` — a `..` segment, an
            absolute path, or a symlink pointing away.
    """
    root_path = os.path.realpath(root)
    resolved = os.path.realpath(os.path.join(root_path, directory))
    if resolved != root_path and not resolved.startswith(root_path + os.sep):
        raise ValueError("%s resolves outside the root %s" % (directory, root_path))
    return resolved


def swift_files(root, directories):
    """Return every `.swift` file under `directories`, each resolved within `root`.

    Raises:
        ValueError: If any of `directories` resolves outside `root`.
    """
    paths = []
    for directory in directories:
        for dirpath, _, names in os.walk(_contained_path(root, directory)):
            paths += [os.path.join(dirpath, n) for n in sorted(names) if n.endswith(".swift")]
    return sorted(paths)


def base_name(symbol):
    """Return the part of a selector before its argument list."""
    return symbol[:symbol.index("(")]


def find_stale_links(texts, declarations, owners):
    """Return `(stale, unresolved)` reports for every link that names no declaration.

    A link lands in `stale` when its base name is declared in the pool it should
    resolve against but with different labels — the defect worth fixing. It
    lands in `unresolved` when the pool has no such name at all, which usually
    means the link points at another module and needs a human to read it.
    """
    everywhere = {symbol for _, symbol in declarations}
    by_owner = defaultdict(set)
    for owner, symbol in declarations:
        by_owner[owner].add(symbol)

    stale, unresolved = [], []
    for path in sorted(texts):
        for line, raw, qualifier, base, symbol in collect_links(texts[path]):
            pool = everywhere if qualifier is None else by_owner.get(qualifier, everywhere)
            if symbol in pool:
                continue
            siblings = sorted(s for s in pool if base_name(s) == base)
            resolvable = qualifier is None or qualifier in owners
            if resolvable and siblings:
                stale.append((path, line, raw, siblings))
            else:
                unresolved.append(
                    (path, line, raw, sorted(s for s in everywhere if base_name(s) == base))
                )
    return stale, unresolved


def report(stale, unresolved, link_count, declaration_count):
    """Print both buckets and return the process exit status."""
    print("symbol links scanned: %d   declarations indexed: %d" % (link_count, declaration_count))
    print("\n=== STALE: the base name is declared here, this argument list is not ===")
    for path, line, raw, candidates in stale:
        print("%s:%d  ``%s``\n    declared: %s" % (path, line, raw, ", ".join(candidates)))
    print("total stale: %d" % len(stale))
    print("\n=== UNRESOLVED HERE: another module, or a member this type does not have ===")
    for path, line, raw, candidates in unresolved:
        nearby = ", ".join(candidates) if candidates else "(no declaration of that name anywhere)"
        print("%s:%d  ``%s``\n    nearby: %s" % (path, line, raw, nearby))
    print("total unresolved here: %d" % len(unresolved))
    return 1 if stale or unresolved else 0


def main(argv):
    """Scan the requested directories and report every symbol link that resolves to nothing."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".", help="Repository root to resolve paths against.")
    parser.add_argument(
        "directories",
        nargs="*",
        default=["Sources", "Tests"],
        help="Directories under the root to scan. Defaults to Sources and Tests.",
    )
    args = parser.parse_args(argv)

    try:
        paths = swift_files(args.root, args.directories)
    except ValueError as error:
        parser.error(str(error))

    texts = {}
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            texts[path] = handle.read()

    declarations, owners = set(), set()
    for path in sorted(texts):
        collect_declarations(blank_noncode(texts[path]), declarations, owners)

    stale, unresolved = find_stale_links(texts, declarations, owners)
    link_count = sum(1 for text in texts.values() for _ in collect_links(text))
    return report(stale, unresolved, link_count, len(declarations))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
