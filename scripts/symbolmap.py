"""Map every FoundationModelsRouter symbol that a consumer package names.

Reads the router at a revision, collects each type-level declaration with its
access level, then searches the consumer tree for each name.

    symbolmap.py [PROVIDER_REPO] CONSUMER_REPO [REV] [SOURCES_SUBPATH]
    symbolmap.py CONSUMER_REPO

REV is the provider revision to read, and it defaults to HEAD. SOURCES_SUBPATH
is the provider subdirectory the declarations are read from, and it defaults to
Sources.

This argument order matches the copy in FoundationModelsRanker, so the two
tracked copies take the same command line. Do not let them diverge.

REFERENCE MATERIAL, NOT A GATE. This matches TYPE NAMES ONLY, so a member of a
public type that goes internal is invisible to it. Four of the five real breaks
this package has caused were members, thus this script reads clean on them. See
task ^1y4g20q: the check to trust reads the symbol graph, which carries members.

CONSUMER_REPO has no default on purpose. A guessed consumer gives a clean report
about a package nobody asked about, and that is not different from a true
all-clear.
"""
import re
import subprocess
import sys
from pathlib import Path

# The repository that holds this script: <repo>/scripts/symbolmap.py.
# `resolve()` comes first, because `__file__` is relative under a relative call.
DEFAULT_PROVIDER = str(Path(__file__).resolve().parents[1])
ROUTER = DEFAULT_PROVIDER
CONSUMER = None
REV = "HEAD"
SOURCES = "Sources"


def read_arguments(argv):
    """Sets the four globals from `argv`. Exits 2 on a bad call, 0 on --help.

    One argument names the consumer, and the provider stays this repository.
    Two or more keep the documented positional order.
    """
    global ROUTER, CONSUMER, REV, SOURCES
    args = argv[1:]
    # Usage goes to stderr when it explains an error, and to stdout when the
    # caller asked for it. A caller that pipes the report must not receive the
    # usage text on the same stream.
    if not args or args[0] in ("-h", "--help"):
        asked = bool(args)
        print(__doc__, end="", file=sys.stdout if asked else sys.stderr)
        raise SystemExit(0 if asked else 2)

    if len(args) == 1:
        ROUTER, CONSUMER, rest = DEFAULT_PROVIDER, args[0], []
    else:
        ROUTER, CONSUMER, rest = args[0], args[1], args[2:]

    if rest:
        REV = rest[0]
    if len(rest) > 1:
        SOURCES = rest[1]

    for name, path in (("PROVIDER_REPO", ROUTER), ("CONSUMER_REPO", CONSUMER)):
        if not Path(path, ".git").exists():
            print(f"{name} is not a git repository: {path}\n", file=sys.stderr)
            print(__doc__, end="", file=sys.stderr)
            raise SystemExit(2)

DECL = re.compile(
    r"^\s*(?:@\w+\s+)*(public|open|package|internal|private|fileprivate)?\s*"
    r"(?:final\s+)?(actor|class|struct|enum|protocol|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)


def run(args, cwd):
    """The standard output of `args` run in `cwd`, as text.

    A command that fails gives "", because a git grep that matches nothing
    exits 1 with an empty standard output. An empty answer is the answer here,
    so the call never raises.
    """
    return subprocess.run(
        args, cwd=cwd, capture_output=True, text=True, check=False
    ).stdout


def router_types():
    """Every type the router declares at REV, as name -> (access, kind, file)."""
    files = run(
        ["git", "ls-tree", "-r", "--name-only", REV, "--", SOURCES],
        ROUTER,
    ).split()
    found = {}
    for path in files:
        if not path.endswith(".swift"):
            continue
        for line in run(["git", "show", f"{REV}:{path}"], ROUTER).splitlines():
            hit = DECL.match(line)
            if not hit:
                continue
            access, kind, name = hit.group(1), hit.group(2), hit.group(3)
            access = access or "internal"
            # A private type is unreachable from any other module, thus a name
            # that matches one is always a different type of the same name.
            if access in ("private", "fileprivate"):
                continue
            # A name declared public anywhere wins over a nested internal one.
            if name in found and found[name][0] in ("public", "open"):
                continue
            found[name] = (access, kind, path)
    return found


def consumer_hits(names):
    """name -> list of "path:line" the consumer names it on, tracked files only."""
    out = {}
    for name in names:
        text = run(
            [
                "git", "grep", "-n", "-w", name, "--",
                "Sources", "Tests", "IntegrationTests/Tests", "IntegrationTests/Package.swift",
                "Package.swift",
            ],
            CONSUMER,
        )
        lines = [ln for ln in text.splitlines() if ln.strip()]
        # Drop pure comment lines: the symbol must be named in code somewhere.
        code = [
            ln for ln in lines
            if not re.match(r"^[^:]+:\d+:\s*(///|//|\*)", ln)
        ]
        if code:
            out[name] = code
    return out


def self_declared(name):
    """True when the consumer declares this name itself, so the hit is ambiguous.

    The trailing class is spelled out rather than written `\\b`: git greps with
    POSIX regular expressions, where `\\b` is not a word boundary.
    """
    text = run(
        ["git", "grep", "-nE",
         r"(actor|class|struct|enum|protocol|typealias) " + name + r"([^A-Za-z0-9_]|$)",
         "--", "Sources", "Tests", "IntegrationTests/Tests"],
        CONSUMER,
    )
    return bool(text.strip())


def main():
    """Prints the three-section report on stdout: breaks, ambiguous, safe.

    Returns None, so the process ends with status 0 whatever the report holds.
    The script is reference material and not a gate, thus a break waiting is a
    line to read and never a failing status.
    """
    types = router_types()
    hits = consumer_hits(sorted(types))
    rows = []
    for name, sites in sorted(hits.items()):
        access, kind, path = types[name]
        rows.append((name, access, kind, path, sites, self_declared(name)))

    breaks = [r for r in rows if r[1] not in ("public", "open") and not r[5]]
    safe = [r for r in rows if r[1] in ("public", "open") and not r[5]]
    ambiguous = [r for r in rows if r[5]]

    print("router type declarations at %s: %d" % (REV, len(types)))
    print("named by the consumer: %d" % len(rows))
    print()
    print("=" * 70)
    print("BREAKS WAITING — the consumer names it, the router does not publish it")
    print("=" * 70)
    for name, access, kind, path, sites, _ in breaks:
        print("\n%s  (%s %s, %s)" % (name, access, kind, path))
        for site in sites:
            print("    %s" % site)
    print()
    print("=" * 70)
    print("AMBIGUOUS — the consumer also declares this name itself; check by hand")
    print("=" * 70)
    for name, access, kind, path, sites, _ in ambiguous:
        print("  %-34s router: %s %s" % (name, access, kind))
    print()
    print("=" * 70)
    print("SAFE — public at the router tip (%d)" % len(safe))
    print("=" * 70)
    for name, access, kind, path, sites, _ in safe:
        print("  %-34s %-9s %-9s %d site(s)" % (name, access, kind, len(sites)))


if __name__ == "__main__":
    read_arguments(sys.argv)
    sys.exit(main())
