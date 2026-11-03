# Contributing

Mere requires [Zig](https://ziglang.org/) 0.16.

```sh
zig build          # build
zig build test     # run all tests
zig fmt --check <files>
```

Design specifications are in `docs/design/`. This file describes the coding
standards. Where code has a valid reason to deviate from one, explain it in an
inline comment at that spot.

## Errors

Errors carry their cause to the person reading the message. Nothing along the
path from the failing call to the CLI may discard it.

- Return failures with `ctx.fail` or `ctx.failFmt` so each one sets a subject
  and details. Do not return a bare error tag, or `catch return Tag`, on a path
  a user can reach.
- Keep the cause in the details: the operation that failed, the path or other
  subject, and the underlying error or errno name. Details must say more than
  the error tag already does.
- Do not discard an error with `catch {}`. When ignoring one is correct, a
  comment says why.
- Propagate allocation failure as `OutOfMemory`. Do not turn it into a
  successful result with less data.
- Compose a module's error set from `errors.StandardErrors`, and map to the
  CLI vocabulary once, at the CLI boundary.
- Every error that can reach the CLI has a `getUserFriendlyMessage` entry. A
  user must never see "unknown error".
- A layer that receives an error from below keeps the lower layer's diagnostic
  context when that context already has details.
- A module that can fail for environmental reasons (namespaces, mounts,
  permissions) must be given a way to report, normally the `Context`.

## Allocators

- Take the allocator from the `Context` (`ctx.allocator`). Derive arenas from
  it. Use `ctx.getDiagArena()` for diagnostic strings.
- Do not use `std.heap.page_allocator`, `c_allocator` or a new
  general-purpose allocator in library code. If a direct allocator is
  unavoidable, such as code that runs after `fork`, say why in a comment.
- Memory from a global allocator is invisible to `std.testing.allocator`, so
  leak tests cannot see it.
- Every owned allocation has a matching `defer` or `errdefer`.

## Logging and output

- Library code reports through the `Context` (`ctx.info`, `ctx.err`,
  `ctx.debug`) and `ui.emit` events. It does not write to stdout or stderr, and
  it does not call `std.debug.print`.
- Only the CLI layer writes command output directly.
- `ctx.debug` is for diagnostics shown with `--verbose`. It is not a place to
  put information the user needs to see.

## CLI layer

`src/cli` contains no business logic. A command parses its arguments, calls a
function in the library, and formats the result. Decisions, sorting,
filesystem and process work, and anything another command or a test would want
to call belong below `src/cli`.

## Tests

- A regression test fails before the fix and passes after it. Check that it
  fails.
- Make external effects injectable instead of performing them in tests. Use
  the existing seams: `namespace_runner`, the probe seam and `DummyClient`.
- Test steps run only tests whose names match the step's filter. Name a test
  so that its step runs it, and confirm it ran.
- For allocation-failure coverage, use `std.testing.checkAllAllocationFailures`
  or the `FailingAllocator` loop already used in `kdl.zig` and
  `build_orchestrator.zig`. A failing allocator fails every allocation from the
  chosen index onward, so a swallowed early failure can pass a sweep. Document
  any conversion a sweep cannot guard.
- Before adding a helper or test pattern, search `src/` for how the repository
  already does it.

## Caches

- A cache key covers every input the cached step can read. If a step can read
  a directory, the key covers the directory's contents.
- A verified download replaces a stale cache entry. A stale entry is never
  left in place to conflict with the new one.
