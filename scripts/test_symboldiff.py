"""Hermetic tests for `symboldiff.py`.

Every test here writes its own symbol-graph JSON into a temporary directory and
reads it back. No test builds a Swift package, so the whole file runs in well
under a second and needs no toolchain. `SymbolDiffScriptTests.swift` runs this
file, so `swift test` and CI measure it.

Run it directly with:

    python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import symboldiff  # noqa: E402  (the path above is what makes this import work)


# One symbol row, spelled the way the extractor spells it. The three fields are
# the ones the differ reads; every other field of a real row is ignored.
def a_symbol(path, kind, declaration):
    """Builds one symbol-graph row.

    - path: the dotted symbol path, as `pathComponents` joined.
    - kind: the `kind.identifier` string, such as `swift.struct`.
    - declaration: the text `declarationFragments` spells out.
    """
    return {
        "kind": {"identifier": kind, "displayName": kind},
        "identifier": {"precise": "s:" + path, "interfaceLanguage": "swift"},
        "pathComponents": path.split("."),
        "accessLevel": "public",
        "declarationFragments": [{"kind": "text", "spelling": declaration}],
    }


def write_graph(directory, filename, symbols):
    """Writes one `*.symbols.json` file holding `symbols` into `directory`."""
    body = {
        "metadata": {"formatVersion": {"major": 0, "minor": 6, "patch": 0}},
        "module": {"name": filename.split(".")[0].split("@")[0]},
        "symbols": symbols,
        "relationships": [],
    }
    Path(directory, filename).write_text(json.dumps(body), encoding="utf-8")


class GraphPathsTests(unittest.TestCase):
    """The set of files one module's public surface is spread across."""

    def test_the_extension_file_counts_and_the_neighbour_module_does_not(self):
        """The measured trap: the extractor writes `M.symbols.json` AND
        `M@Other.symbols.json`, and the true surface is the SUM. Reading only
        the first under-reports and reads like a lost symbol. A module whose
        name merely starts with `M` is a different module and must not be read.
        """
        with tempfile.TemporaryDirectory() as out:
            for name in (
                "Router.symbols.json",
                "Router@ULID.symbols.json",
                "RouterTestSupport.symbols.json",
                "RouterTestSupport@Swift.symbols.json",
                "Other.symbols.json",
            ):
                write_graph(out, name, [])
            found = [os.path.basename(p) for p in symboldiff.graph_paths(out, "Router")]
        self.assertEqual(found, ["Router.symbols.json", "Router@ULID.symbols.json"])

    def test_the_cache_keeps_the_module_asked_about_and_nothing_else(self):
        """The build emits a graph for every module it compiled, dependencies
        included — about 60 MB for one revision of this package. Only the
        module asked about is worth caching. A file that is not a symbol graph
        is left alone, because the pruning deletes.
        """
        with tempfile.TemporaryDirectory() as out:
            for name in (
                "Router.symbols.json",
                "Router@ULID.symbols.json",
                "RouterTestSupport.symbols.json",
                "MLX.symbols.json",
            ):
                write_graph(out, name, [])
            Path(out, "extracted").write_text("a commit\n", encoding="utf-8")
            symboldiff.keep_only(out, "Router")
            self.assertEqual(
                sorted(os.listdir(out)),
                ["Router.symbols.json", "Router@ULID.symbols.json", "extracted"],
            )

    def test_a_module_with_no_graph_file_is_a_named_failure(self):
        """An extraction that wrote nothing must not read as an empty surface,
        which is indistinguishable from a package that publishes nothing.
        """
        with tempfile.TemporaryDirectory() as out:
            write_graph(out, "Other.symbols.json", [])
            with self.assertRaises(symboldiff.MissingSymbolGraph):
                symboldiff.read_surface(out, "Router")


class ReadSurfaceTests(unittest.TestCase):
    """What IS public, read off the symbol graph rather than off source text."""

    def test_the_surface_sums_every_file_of_the_module(self):
        """One symbol in each of the module's two files makes a surface of two.
        A reader that opened only the first file would answer one.
        """
        with tempfile.TemporaryDirectory() as out:
            write_graph(
                out,
                "Router.symbols.json",
                [a_symbol("ToolMounting", "swift.enum", "enum ToolMounting")],
            )
            write_graph(
                out,
                "Router@ULID.symbols.json",
                [a_symbol("ULID.routerKey", "swift.property", "var routerKey: String")],
            )
            surface = symboldiff.read_surface(out, "Router")
        self.assertEqual(
            sorted(path for path, _ in surface),
            ["ToolMounting", "ULID.routerKey"],
        )

    def test_a_requirement_and_its_default_are_two_declarations_of_one_slot(self):
        """A protocol requirement and its extension default share a path and a
        kind. Keeping both, duplicates included, is what makes the loss of one
        of them visible.
        """
        with tempfile.TemporaryDirectory() as out:
            write_graph(
                out,
                "Router.symbols.json",
                [
                    a_symbol("BackgroundTool.mount", "swift.property", "var mount: Bool"),
                    a_symbol("BackgroundTool.mount", "swift.property", "var mount: Bool"),
                ],
            )
            surface = symboldiff.read_surface(out, "Router")
        self.assertEqual(surface[("BackgroundTool.mount", "swift.property")],
                         ("var mount: Bool", "var mount: Bool"))


class CompareTests(unittest.TestCase):
    """The three states a change can put a symbol in."""

    def test_a_removed_member_is_reported_though_its_type_stays_public(self):
        """The break that hid longest: `SessionMailbox` stayed public while
        `makeCompletionToken()` went internal. A check that reads type names
        answers "safe" here, and this is the assertion that refutes it.
        """
        actor = a_symbol("SessionMailbox", "swift.class", "actor SessionMailbox")
        member = a_symbol(
            "SessionMailbox.makeCompletionToken()",
            "swift.type.method",
            "static func makeCompletionToken() -> String",
        )
        difference = symboldiff.compare(
            symboldiff.surface_of([actor, member]),
            symboldiff.surface_of([actor]),
        )
        self.assertEqual(
            [row.path for row in difference.removed],
            ["SessionMailbox.makeCompletionToken()"],
        )
        self.assertEqual(difference.changed, [])
        self.assertEqual(difference.added, [])

    def test_a_changed_parameter_type_keeps_the_path_and_changes_the_fragment(self):
        """A signature change that keeps every argument label does not move the
        symbol path, so it is a changed declaration rather than a removal.
        """
        before = symboldiff.surface_of(
            [a_symbol("Router.resolve(_:)", "swift.method", "func resolve(_ id: Int)")]
        )
        after = symboldiff.surface_of(
            [a_symbol("Router.resolve(_:)", "swift.method", "func resolve(_ id: String)")]
        )
        difference = symboldiff.compare(before, after)
        self.assertEqual(difference.removed, [])
        self.assertEqual(difference.added, [])
        self.assertEqual([row.path for row in difference.changed], ["Router.resolve(_:)"])
        self.assertEqual(row_declarations(difference.changed[0]),
                         (("func resolve(_ id: Int)",), ("func resolve(_ id: String)",)))

    def test_an_argument_label_that_goes_moves_the_path(self):
        """`pathComponents` carries the argument labels, so dropping one is a
        removal beside an addition rather than a changed fragment. State it,
        because the opposite is easy to assume.
        """
        before = symboldiff.surface_of(
            [a_symbol("Fold.init(a:b:)", "swift.init", "init(a: Int, b: Int)")]
        )
        after = symboldiff.surface_of(
            [a_symbol("Fold.init(a:)", "swift.init", "init(a: Int)")]
        )
        difference = symboldiff.compare(before, after)
        self.assertEqual([row.path for row in difference.removed], ["Fold.init(a:b:)"])
        self.assertEqual([row.path for row in difference.added], ["Fold.init(a:)"])

    def test_an_added_symbol_is_neither_removed_nor_changed(self):
        """An addition is the line a release note is written from, and it costs
        no consumer anything.
        """
        after = [
            a_symbol("Router", "swift.struct", "struct Router"),
            a_symbol("Router.fold()", "swift.method", "func fold()"),
        ]
        difference = symboldiff.compare(
            symboldiff.surface_of(after[:1]), symboldiff.surface_of(after)
        )
        self.assertEqual([row.path for row in difference.added], ["Router.fold()"])
        self.assertEqual(difference.removed, [])
        self.assertEqual(difference.changed, [])


class ExitStatusTests(unittest.TestCase):
    """Three states, three statuses, and the hard fail wins."""

    def test_a_surface_that_only_grew_is_clean(self):
        """An addition alone must not stop a push."""
        difference = symboldiff.Difference(removed=[], changed=[], added=[object()])
        self.assertEqual(symboldiff.exit_status(difference), symboldiff.EXIT_CLEAN)

    def test_a_removed_symbol_is_the_hard_failure(self):
        """A removal breaks a consumer today."""
        difference = symboldiff.Difference(removed=[object()], changed=[], added=[])
        self.assertEqual(symboldiff.exit_status(difference), symboldiff.EXIT_REMOVED)

    def test_a_changed_fragment_is_the_warning(self):
        """A changed fragment breaks only a consumer that uses what changed, so
        it carries a status a caller can tell apart from a removal.
        """
        difference = symboldiff.Difference(removed=[], changed=[object()], added=[])
        self.assertEqual(symboldiff.exit_status(difference), symboldiff.EXIT_CHANGED)
        self.assertNotEqual(symboldiff.EXIT_CHANGED, symboldiff.EXIT_REMOVED)
        self.assertNotEqual(symboldiff.EXIT_CHANGED, symboldiff.EXIT_USAGE)

    def test_a_removal_beside_a_change_reports_the_removal(self):
        """The caller stops on the first and warns on the second, so a run that
        holds both must stop.
        """
        difference = symboldiff.Difference(
            removed=[object()], changed=[object()], added=[]
        )
        self.assertEqual(symboldiff.exit_status(difference), symboldiff.EXIT_REMOVED)


class ArgumentTests(unittest.TestCase):
    """The call convention, which matches `symbolmap.py`."""

    def test_no_arguments_writes_usage_to_stderr_and_exits_two(self):
        """A caller that pipes the report must not receive the usage text on
        the same stream it reads the report from.
        """
        out, err, status = call_with([])
        self.assertEqual(status, symboldiff.EXIT_USAGE)
        self.assertEqual(out, "")
        self.assertEqual(err, symboldiff.__doc__)

    def test_help_writes_usage_to_stdout_and_exits_zero(self):
        """Usage a caller asked for is the answer, not an error."""
        out, err, status = call_with(["--help"])
        self.assertEqual(status, 0)
        self.assertEqual(out, symboldiff.__doc__)
        self.assertEqual(err, "")

    def test_a_package_path_that_is_no_repository_names_the_argument(self):
        """The message must say WHICH argument was wrong; there are two paths a
        caller can get wrong and one of them is the revision.
        """
        with tempfile.TemporaryDirectory() as absent:
            out, err, status = call_with(["Router", absent, "HEAD"])
        self.assertEqual(status, symboldiff.EXIT_USAGE)
        self.assertEqual(out, "")
        self.assertIn("PACKAGE_REPO is not a git repository", err)

    def test_the_one_revision_form_asks_what_is_public(self):
        """Three arguments name one revision, and that is the question the
        documentation leads with.
        """
        with tempfile.TemporaryDirectory() as repo:
            Path(repo, ".git").mkdir()
            request = symboldiff.read_arguments(["symboldiff.py", "Router", repo, "HEAD"])
        self.assertEqual(request.module, "Router")
        self.assertEqual(request.before, "HEAD")
        self.assertIsNone(request.after)

    def test_the_two_revision_form_asks_what_changed(self):
        """Four arguments name the pair the differ compares."""
        with tempfile.TemporaryDirectory() as repo:
            Path(repo, ".git").mkdir()
            request = symboldiff.read_arguments(
                ["symboldiff.py", "Router", repo, "old", "new"]
            )
        self.assertEqual((request.before, request.after), ("old", "new"))

    def test_a_fifth_argument_is_a_bad_call(self):
        """An argument the script cannot place is a mistake, not something to
        ignore quietly.
        """
        with tempfile.TemporaryDirectory() as repo:
            Path(repo, ".git").mkdir()
            out, err, status = call_with(["Router", repo, "old", "new", "extra"])
        self.assertEqual(status, symboldiff.EXIT_USAGE)
        self.assertEqual(out, "")
        self.assertEqual(err, symboldiff.__doc__)


class ModuleNameTests(unittest.TestCase):
    """The MODULE argument, which becomes a path, a glob and a command word."""

    def test_a_name_that_is_no_identifier_is_a_bad_call(self):
        """MODULE is joined into the cache path, into a glob pattern and onto
        the build command line. A name carrying a separator, a `..` or a glob
        character reaches a file the extraction never wrote, so it is refused
        before any of the three is built.
        """
        with tempfile.TemporaryDirectory() as repo:
            Path(repo, ".git").mkdir()
            for bad in ("../../etc/passwd", "/etc/passwd", "Router*", "", "1Router"):
                with self.subTest(module=bad):
                    out, err, status = call_with([bad, repo, "HEAD"])
                    self.assertEqual(status, symboldiff.EXIT_USAGE)
                    self.assertEqual(out, "")
                    self.assertIn("MODULE", err)

    def test_a_swift_module_name_is_accepted(self):
        """The name of a real module of this package passes, so the check
        refuses a bad call rather than every call.
        """
        with tempfile.TemporaryDirectory() as repo:
            Path(repo, ".git").mkdir()
            request = symboldiff.read_arguments(
                ["symboldiff.py", "FoundationModelsRouter", repo, "HEAD"]
            )
        self.assertEqual(request.module, "FoundationModelsRouter")

    def test_each_site_that_builds_from_the_name_checks_it_first(self):
        """`read_arguments` is the front door and it is not the only way in:
        this file is imported, and each of these is called directly. Every
        site that puts MODULE into a path, a glob pattern or a command word
        checks the name itself, so validating the argument alone is not what
        the check rests on.
        """
        escaping = "../../etc/passwd"
        with tempfile.TemporaryDirectory() as out:
            sites = {
                "graph_paths": lambda: symboldiff.graph_paths(out, escaping),
                "keep_only": lambda: symboldiff.keep_only(out, escaping),
                "read_surface": lambda: symboldiff.read_surface(out, escaping),
                "build_command": lambda: symboldiff.build_command(
                    escaping, "/s", "/b", "/g"
                ),
            }
            for name, site in sites.items():
                with self.subTest(site=name), self.assertRaises(
                    symboldiff.NotAModuleName
                ):
                    site()

    def test_a_refused_name_is_a_failure_to_measure_rather_than_a_clean_run(self):
        """A caller that reaches past `read_arguments` still must not read a
        refusal as an all-clear, so the leaf guard raises the error class
        `run` turns into `EXIT_BROKEN`.
        """
        self.assertTrue(
            issubclass(symboldiff.NotAModuleName, symboldiff.SymbolDiffError)
        )


class FailureStatusTests(unittest.TestCase):
    """A run that measured nothing must not read as a clean run."""

    def test_a_revision_that_names_no_commit_is_a_measured_failure(self):
        """The whole point of this script is that a confident wrong answer is
        the failure it prevents. A run that could not read a surface therefore
        carries a status of its own, told apart from every real state.
        """
        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "--quiet", repo], check=True)
            request = symboldiff.Request(
                module="Router", repo=repo, before="no-such-revision", after=None
            )
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                status = symboldiff.run(request)
        self.assertEqual(status, symboldiff.EXIT_BROKEN)
        self.assertIn("no-such-revision", err.getvalue())
        for real in (
            symboldiff.EXIT_CLEAN,
            symboldiff.EXIT_REMOVED,
            symboldiff.EXIT_USAGE,
            symboldiff.EXIT_CHANGED,
        ):
            self.assertNotEqual(symboldiff.EXIT_BROKEN, real)


class BuildCommandTests(unittest.TestCase):
    """The extraction, which is the SwiftPM route rather than a `-I` list."""

    def test_the_command_is_the_swiftpm_symbol_graph_route(self):
        """A hand-built `-I` list given to `swift-symbolgraph-extract` needs
        flag archaeology and carries the stale-extract trap. SwiftPM emits the
        graph as part of a build it already knows how to configure.
        """
        command = symboldiff.build_command("Router", "/s", "/b", "/g")
        self.assertEqual(
            command,
            [
                "swift", "build",
                "--package-path", "/s",
                "--scratch-path", "/b",
                "--target", "Router",
                "-Xswiftc", "-emit-symbol-graph",
                "-Xswiftc", "-emit-symbol-graph-dir",
                "-Xswiftc", "/g",
            ],
        )


def row_declarations(row):
    """The before and after declaration tuples of one changed row."""
    return (row.before, row.after)


def call_with(arguments):
    """Runs `read_arguments` over `arguments` and measures both streams.

    Returns the standard output text, the standard error text, and the exit
    status. The script name stands in front of `arguments`, the way a shell
    passes it.
    """
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            symboldiff.read_arguments(["symboldiff.py"] + arguments)
            status = 0
        except SystemExit as stop:
            status = stop.code
    return out.getvalue(), err.getvalue(), status


if __name__ == "__main__":
    unittest.main()
