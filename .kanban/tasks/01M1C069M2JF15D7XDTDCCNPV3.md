---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1cwyn9fsb9qn11pj488qsya
  text: |-
    ### Moot. The script is deleted.

    This card recorded that `symboldiff.py` measured nothing and exited 4 when
    `PACKAGE_REPO` was a relative path — the exact invocation its own README documented.

    `scripts/symboldiff.py` and everything around it are removed. See the closing comment
    on ^1y4g20q for why: the tool was never asked for, it would not have caught the
    expensive regression of that day, it never prevented a break, and it put a `python3`
    PATH dependency into the unit suite CI runs.

    There is no bug left to fix. Closing.
  timestamp: 2026-08-31T21:52:35.119567+00:00
position_column: done
position_ordinal: ffffad80
title: symboldiff.py measures nothing when PACKAGE_REPO is a relative path
---
## What

`scripts/README.md` gives the "what IS public" command with a relative repo:

```sh
python3 scripts/symboldiff.py FoundationModelsRouter . HEAD
```

Measured at 475befb, that command exits 4 and measures nothing:

```
extracting FoundationModelsRouter at HEAD (475befb)
no FoundationModelsRouter.symbols.json under ./.build/symboldiff/<commit>/symbols:
the extraction wrote nothing for that module, so its surface was never measured
```

## Why

`extract()` builds the graph directory by `os.path.join(repo, CACHE_SUBPATH, commit, "symbols")`. With `repo` given as `.`, that path is RELATIVE, and it goes onto the compiler command line as `-emit-symbol-graph-dir`. SwiftPM runs the compiler with the package directory as its working directory, which for this script is the WORKTREE it planted. So the graphs land at

```
.build/symboldiff/<commit>/source/.build/symboldiff/<commit>/symbols/
```

Measured there: 71 `*.symbols.json` files, `FoundationModelsRouter.symbols.json` among them. `read_surface` then looks in the directory the script meant, finds nothing, and raises `MissingSymbolGraph`. The worktree that holds the graphs is left standing only because the failure stops the clean-up.

An absolute `PACKAGE_REPO` works today and was the work-around card ^bbbkas1 used.

## What to do

- Resolve `repo` to an absolute path one time, where `read_arguments` builds the `Request`, so every path derived from it is absolute whatever the caller typed.
- Add a test, or a measured note in `scripts/README.md`, that the relative form works.

A second defect stands beside it and is worth the same pass: `extract()` removes the `graphs` directory before it rebuilds, but leaves the `scratch` build directory. A commit whose earlier extraction failed part way therefore builds INCREMENTALLY on the second run, the compiler is not re-invoked, and no graph is emitted at all — the same "wrote nothing" message, this time with no bad path behind it. Measured: after `rm -rf` of the whole cache entry the run still failed, and only the absolute path fixed it.

## Acceptance Criteria
- [ ] `python3 scripts/symboldiff.py FoundationModelsRouter . HEAD` prints the surface and exits 0.
- [ ] A partly-extracted cache entry re-extracts from a clean scratch rather than reporting nothing.
- [ ] `scripts/README.md` still spells the command it documents, and that command is the one measured. #tooling #scripts