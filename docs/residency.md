# Models, residency and tools

## `standard` and `flash` are always two different models

The `standard` and `flash` slots of one resolved profile never use the same
model. A synchronous tool call, for example the multitool `searchTools`, runs a
selection call on `flash` inside an open submission on `standard`. Each model
has one FIFO work queue, so one model in both slots would wait on itself.

`Router.resolve` skips, in the `flash` list, the model that `standard` chose,
and takes the next `flash` candidate. When the `standard` and `flash` lists
name only the same one model, `Router.resolve` throws before it loads a model.
Give the `flash` slot at least one candidate that is not the `standard` model.

## Residency is process-wide

The model pool and the model hold come from the core `FoundationModelsExtras`
package: `ModelPool` and `ModelHold`. `FoundationModelsRouter` exports the
name `ModelPool`, so `import FoundationModelsRouter` is sufficient to write
`ModelPool.shared` or `Router(pool: ModelPool())`.

One pool serves the whole process by default: `ModelPool.shared`. The router
is one user of that pool. The tool registry and the multitool of
`FoundationModelsExtras` are other users. All users share the same loaded
models: when two users name one model, the pool loads that model one time and
counts its weights one time. The first loader of a model wins. A later user
gets the container of that loader.

Each load of a new model and each eviction is one job in the FIFO admission
queue of the pool. `Router.resolve` measures the footprint of the pool, fits
the profile, and loads each slot in one admission job. Thus no other load and
no eviction occurs between the measurement and the loads.

Each handle of a resolved profile keeps the three model holds of its resolve.
A model stays resident while a profile, a handle of that profile, or a hold
of another user still exists anywhere in the process. There is no release
call. When the last hold of a model goes, the pool submits an eviction job. A
dropped `Router` frees nothing. Read `ModelPool.residentModelCount` to see how
many models the process holds.

The last release puts the eviction job in the admission queue of the pool in
the same step. A resolve that starts immediately after the drop of the last
reference thus runs after the eviction, and sees the freed memory. A
synchronous read of `ModelPool.residentModelCount` immediately after the drop
can still count the model, because the eviction job has not run yet. To see
the freed memory, read the footprint in an admission job:
`try await pool.admit { $0.footprint }`.

Pass a fresh pool to `Router(pool:)` to give a router an isolated pool and an
isolated budget. Pass `Router(samplingMode:)` to set the decoding strategy of
a router; two routers over one shared model each decode with their own mode.
Forks are not counted: any number of forks over one model can exist at once.

## Tool hosting comes from FoundationModelsExtras

The core `FoundationModelsExtras` package hosts the tools of a session: it
mounts each tool, runs a background tool behind a pending envelope when the
run continues past the settle period of the session, keeps the run plane of
the session, and binds the ambient `ToolContext` of each call. A host that
uses only tools, for example the multitool, thus needs no router.

The router makes, manages, compacts and records sessions, and uses that tool
hosting for each session. The tool types of Extras (`ToolContext`,
`BackgroundTool`, `ToolMount` and the related run and report types) are
aliases in `FoundationModelsRouter`. Thus `import FoundationModelsRouter` is
sufficient to write a tool, and a file that imports both modules finds one
type for each name.
