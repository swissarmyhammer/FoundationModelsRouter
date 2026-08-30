"""What IS public in a Swift module, and what changed between two revisions.

    symboldiff.py MODULE PACKAGE_REPO REV
    symboldiff.py MODULE PACKAGE_REPO BEFORE_REV AFTER_REV

WHAT IS PUBLIC comes first, because in Swift the access level is not always
written on the declaration line. A requirement inside a `public protocol`
carries no `public` keyword and is public anyway:

    public protocol AgentSession {
        func respond(to prompt: String) async throws -> String
    }

Two sessions read exactly that shape and reported public API as internal, and a
keyword search agrees with them. The symbol graph does not: it carries the
access level the compiler computed. So the three-argument form is not a
convenience beside the differ — it is the only reliable answer to "what does
this module publish", and the failure it prevents is a CONFIDENT WRONG ANSWER
rather than a missing one.

WHAT CHANGED is the second feature. Give a second revision and the script reads
both surfaces and states the difference. It compares two revisions of ONE
package and needs no consumer checked out, because "did my public API change?"
is the question that catches a changed signature, and "does anyone name this?"
is not.

EXIT STATUS, which is what puts this in a pre-push check:

    0  clean, or additions only. An addition is where a release note comes from.
    1  a symbol was REMOVED. It breaks a consumer today; stop.
    2  a bad call. Nothing was measured.
    3  a declaration FRAGMENT CHANGED, and nothing was removed. It breaks only a
       consumer that uses what changed; warn.
    4  the script could not measure. A build failed, or a revision names no
       commit. Never read this as clean.

A removal beside a change reports the removal, so a caller stops on 1 and warns
on 3.

HOW IT READS THE SURFACE. `swift build -Xswiftc -emit-symbol-graph` writes the
graph as part of a build SwiftPM already knows how to configure. That is the
route, rather than a hand-built `-I` list given to `swift-symbolgraph-extract`,
which needs flag archaeology and drops a symbol when the include path is stale.

The extractor writes MORE THAN ONE file for one module: `M.symbols.json` beside
`M@Other.symbols.json` for each module `M` extends. The surface is the SUM.
Reading only the first under-reports, and an under-report reads exactly like a
lost symbol. A neighbour module whose name merely starts with `M` — say
`MTestSupport` — is a different module and is never read.

Each symbol is filed under its path and kind, where the path is
`pathComponents` joined with a dot, so a MEMBER is a row of its own. That is
the whole point: of the five real breaks this package caused, four were members
of types that stayed public, and a check that reads type names alone passes all
four while measuring nothing.

WHAT THIS DOES NOT COVER:

  - It reads the PUBLIC surface only. `package` and `internal` symbols are
    absent from the graph, so a change inside them is invisible here, and so is
    a demotion from `public` to `package` seen as anything but a removal.
  - It answers about one module of one package. A break carried by a type this
    module re-exports from a dependency is that dependency's surface, not this
    one.
  - An argument LABEL that changes moves the symbol path, so it reports as a
    removal beside an addition rather than as a changed fragment. Only a change
    inside the declaration — a parameter type, a return type, a constraint —
    keeps the path and shows up as a fragment change.
  - It states nothing about who calls what. `symbolmap.py` beside this file
    answers "does this named consumer tree mention this name", by type name
    only, and it is reference material rather than a gate.
  - Behaviour is out of scope entirely. A symbol that keeps its declaration and
    changes what it does reads clean here.
  - A revision is built with the dependency versions that resolve TODAY, since
    `Package.resolved` is not tracked. A dependency that has moved can change
    an old revision's surface or stop it building.

The symbol graph of each commit is cached under `<PACKAGE_REPO>/.build/
symboldiff/<commit>/`, so the same revision is extracted once. A commit is
immutable, thus the cache never goes stale. The worktree and the build
directory are removed once the extraction succeeds, and are left standing when
a build fails so the failure can be read. The build writes a graph for every
module it compiled, dependencies included, and only the module asked about is
kept — about 1.5 MB for each revision rather than about 60 MB.

MODULE, PACKAGE_REPO and each revision are required and have no default. A
guessed module gives a clean report about a module nobody asked about, and that
reads the same as a true all-clear.
"""
import json
import os
import shutil
import subprocess
import sys
from collections import Counter, namedtuple
from glob import glob
from pathlib import Path

EXIT_CLEAN = 0
EXIT_REMOVED = 1
EXIT_USAGE = 2
EXIT_CHANGED = 3
EXIT_BROKEN = 4

# The two accepted argument counts, past the script name: MODULE, PACKAGE_REPO
# and one revision, or the same three plus a second revision.
ARGUMENTS_FOR_ONE_REVISION = 3
ARGUMENTS_FOR_TWO_REVISIONS = 4

# Where the cached symbol graph of each commit stands, under the package.
CACHE_SUBPATH = os.path.join(".build", "symboldiff")
# Written once the extraction of a commit has succeeded. Its absence means the
# graph beside it is partial, whatever files stand there.
STAMP_NAME = "extracted"

RULE = "=" * 70

# The request a call names, and the answer the script gives back.
Request = namedtuple("Request", "module repo before after")
Difference = namedtuple("Difference", "removed changed added")
Row = namedtuple("Row", "path kind before after")


class SymbolDiffError(Exception):
    """Every failure this script raises for itself.

    The caller turns one of these into `EXIT_BROKEN`, so a run that measured
    nothing never carries a status a reader takes for clean.
    """


class MissingSymbolGraph(SymbolDiffError):
    """No symbol-graph file for the named module stands in the directory."""


class UnknownRevision(SymbolDiffError):
    """The revision names no commit in the package repository."""


class BuildFailed(SymbolDiffError):
    """The SwiftPM build that emits the symbol graph did not succeed."""


def read_arguments(argv):
    """Reads `argv` into a `Request`. Exits 2 on a bad call, 0 on `--help`.

    Usage goes to stderr when it explains an error, and to stdout when the
    caller asked for it, so a caller that pipes the report never receives the
    usage text on the stream it reads the report from.
    """
    arguments = argv[1:]
    if not arguments or arguments[0] in ("-h", "--help"):
        asked = bool(arguments)
        print(__doc__, end="", file=sys.stdout if asked else sys.stderr)
        raise SystemExit(EXIT_CLEAN if asked else EXIT_USAGE)

    if not ARGUMENTS_FOR_ONE_REVISION <= len(arguments) <= ARGUMENTS_FOR_TWO_REVISIONS:
        print(__doc__, end="", file=sys.stderr)
        raise SystemExit(EXIT_USAGE)

    module, repo, before = arguments[0], arguments[1], arguments[2]
    after = arguments[3] if len(arguments) == ARGUMENTS_FOR_TWO_REVISIONS else None
    if not Path(repo, ".git").exists():
        print(f"PACKAGE_REPO is not a git repository: {repo}\n", file=sys.stderr)
        print(__doc__, end="", file=sys.stderr)
        raise SystemExit(EXIT_USAGE)
    return Request(module=module, repo=repo, before=before, after=after)


def graph_paths(directory, module):
    """Every symbol-graph file of `module` in `directory`, sorted.

    That is `<module>.symbols.json` and one `<module>@<extended>.symbols.json`
    for each module `module` extends. A file whose module name merely starts
    with `module` belongs to a different module and is left out.
    """
    own = os.path.join(directory, module + ".symbols.json")
    found = glob(os.path.join(directory, module + "@*.symbols.json"))
    if os.path.exists(own):
        found.append(own)
    return sorted(found)


def keep_only(directory, module):
    """Deletes every symbol graph in `directory` that is not `module`'s.

    The build emits a graph for each module it compiled, dependencies included,
    which is tens of megabytes for one revision. Only the module asked about is
    worth caching. Nothing but a `*.symbols.json` file is touched.
    """
    keeping = set(graph_paths(directory, module))
    for path in glob(os.path.join(directory, "*.symbols.json")):
        if path not in keeping:
            os.remove(path)


def surface_of(symbols):
    """Files `symbols` under `(path, kind)`, each with its declarations.

    The declarations are a sorted tuple that KEEPS duplicates: a protocol
    requirement and its extension default share a path and a kind, and losing
    one of the two has to stay visible.
    """
    slots = {}
    for symbol in symbols:
        key = (".".join(symbol["pathComponents"]), symbol["kind"]["identifier"])
        spelling = "".join(part["spelling"] for part in symbol["declarationFragments"])
        slots.setdefault(key, []).append(spelling)
    return {key: tuple(sorted(spellings)) for key, spellings in slots.items()}


def read_surface(directory, module):
    """The public surface of `module`, summed over every graph file it wrote.

    Raises `MissingSymbolGraph` when no file stands there, because an empty
    surface and a failed extraction must not read the same.
    """
    paths = graph_paths(directory, module)
    if not paths:
        raise MissingSymbolGraph(
            f"no {module}.symbols.json under {directory}: the extraction wrote "
            f"nothing for that module, so its surface was never measured"
        )
    symbols = []
    for path in paths:
        with open(path, encoding="utf-8") as stream:
            symbols.extend(json.load(stream)["symbols"])
    return surface_of(symbols)


def compare(before, after):
    """The difference between two surfaces, as removed, changed and added rows."""
    removed, changed, added = [], [], []
    for path, kind in sorted(set(before) | set(after)):
        was = before.get((path, kind))
        now = after.get((path, kind))
        if now is None:
            removed.append(Row(path=path, kind=kind, before=was, after=()))
        elif was is None:
            added.append(Row(path=path, kind=kind, before=(), after=now))
        elif was != now:
            changed.append(Row(path=path, kind=kind, before=was, after=now))
    return Difference(removed=removed, changed=changed, added=added)


def exit_status(difference):
    """The process status `difference` earns. A removal wins over a change."""
    if difference.removed:
        return EXIT_REMOVED
    if difference.changed:
        return EXIT_CHANGED
    return EXIT_CLEAN


def build_command(module, source, scratch, graphs):
    """The SwiftPM command that builds `module` and emits its symbol graph."""
    return [
        "swift", "build",
        "--package-path", source,
        "--scratch-path", scratch,
        "--target", module,
        "-Xswiftc", "-emit-symbol-graph",
        "-Xswiftc", "-emit-symbol-graph-dir",
        "-Xswiftc", graphs,
    ]


def commit_of(repo, revision):
    """The full commit id `revision` names in `repo`."""
    finished = subprocess.run(
        ["git", "rev-parse", revision + "^{commit}"],
        cwd=repo, capture_output=True, text=True, check=False,
    )
    if finished.returncode != 0:
        raise UnknownRevision(
            f"{revision} names no commit in {repo}: {finished.stderr.strip()}"
        )
    return finished.stdout.strip()


def plant_worktree(repo, commit, source):
    """Puts a detached worktree of `commit` at `source`, replacing any leftover."""
    clear_worktree(repo, source)
    finished = subprocess.run(
        ["git", "worktree", "add", "--detach", source, commit],
        cwd=repo, capture_output=True, text=True, check=False,
    )
    if finished.returncode != 0:
        raise BuildFailed(
            f"could not check {commit} out at {source}: {finished.stderr.strip()}"
        )


def clear_worktree(repo, source):
    """Removes the worktree at `source` and the directory, if either stands."""
    subprocess.run(
        ["git", "worktree", "remove", "--force", source],
        cwd=repo, capture_output=True, text=True, check=False,
    )
    shutil.rmtree(source, ignore_errors=True)


def build_symbol_graph(module, source, scratch, graphs):
    """Builds `module` at `source` and writes its symbol graph into `graphs`."""
    os.makedirs(graphs, exist_ok=True)
    command = build_command(module, source, scratch, graphs)
    finished = subprocess.run(command, capture_output=True, text=True, check=False)
    if finished.returncode != 0:
        raise BuildFailed(
            "the symbol-graph build failed:\n"
            + " ".join(command) + "\n"
            + finished.stdout + finished.stderr
        )


def extract(repo, module, revision):
    """The directory holding `module`'s symbol graph at `revision`.

    The graph of a commit is cached and reused, because a commit is immutable.
    The worktree and the build directory go once the extraction succeeds, and
    stay standing when a build fails so the failure can be read.
    """
    commit = commit_of(repo, revision)
    home = os.path.join(repo, CACHE_SUBPATH, commit)
    graphs = os.path.join(home, "symbols")
    stamp = os.path.join(home, STAMP_NAME)
    if os.path.exists(stamp):
        return graphs

    source = os.path.join(home, "source")
    scratch = os.path.join(home, "build")
    shutil.rmtree(graphs, ignore_errors=True)
    print(f"extracting {module} at {revision} ({commit[:7]})", file=sys.stderr)
    plant_worktree(repo, commit, source)
    build_symbol_graph(module, source, scratch, graphs)
    read_surface(graphs, module)
    keep_only(graphs, module)
    clear_worktree(repo, source)
    shutil.rmtree(scratch, ignore_errors=True)
    Path(stamp).write_text(commit + "\n", encoding="utf-8")
    return graphs


def print_surface(surface, module, revision):
    """Writes what IS public in `module` at `revision` on standard output."""
    print(f"what {module} publishes at {revision}")
    print()
    print(f"declarations: {sum(len(texts) for texts in surface.values())}")
    kinds = Counter(kind for _, kind in surface)
    for kind, count in sorted(kinds.items()):
        print("  %-24s %5d" % (kind, count))
    print()
    print(RULE)
    print("PUBLIC SURFACE — every symbol, members included")
    print(RULE)
    for path, kind in sorted(surface):
        print(f"\n{path}  ({kind})")
        for text in surface[(path, kind)]:
            print(f"    {text}")


def print_rows(title, rows, mark):
    """Writes one titled section of a difference, each declaration under `mark`."""
    print()
    print(RULE)
    print(f"{title} ({len(rows)})")
    print(RULE)
    for row in rows:
        print(f"\n{row.path}  ({row.kind})")
        for text in row.before:
            print(f"  {mark[0]} {text}")
        for text in row.after:
            print(f"  {mark[1]} {text}")


def print_difference(difference, module, before, after):
    """Writes what changed in `module` between the two revisions."""
    print(f"what changed in {module} between {before} and {after}")
    print()
    print(f"removed: {len(difference.removed)}"
          f"  changed: {len(difference.changed)}"
          f"  added: {len(difference.added)}")
    print_rows(
        "REMOVED — a consumer that names it breaks today",
        difference.removed, ("-", "+"),
    )
    print_rows(
        "CHANGED — it breaks a consumer that uses what changed",
        difference.changed, ("-", "+"),
    )
    print_rows(
        "ADDED — the line a release note is written from",
        difference.added, ("-", "+"),
    )


def report(request):
    """Answers `request` on standard output and returns the process status."""
    before = read_surface(
        extract(request.repo, request.module, request.before), request.module
    )
    if request.after is None:
        print_surface(before, request.module, request.before)
        return EXIT_CLEAN
    after = read_surface(
        extract(request.repo, request.module, request.after), request.module
    )
    difference = compare(before, after)
    print_difference(difference, request.module, request.before, request.after)
    return exit_status(difference)


def run(request):
    """Runs `report` and turns a failure to measure into `EXIT_BROKEN`."""
    try:
        return report(request)
    except SymbolDiffError as failure:
        print(str(failure), file=sys.stderr)
        return EXIT_BROKEN


if __name__ == "__main__":
    sys.exit(run(read_arguments(sys.argv)))
