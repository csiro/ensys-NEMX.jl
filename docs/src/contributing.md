# Contributing

Bug reports, questions and pull requests are all welcome. This page covers what
the code expects; [`CONTRIBUTING.md`](https://github.com/csiro/ensys-NEMX.jl/blob/main/CONTRIBUTING.md)
at the repository root has the same content.

## Reporting a problem

For anything involving a specific dispatch interval, the most useful report
includes the output of

```bash
julia --project=. scripts/zbenchmark/export_interval_csvs.jl 2025-09-02T13:25
```

which dumps every market input the model saw. That, the interval, and the flag
values printed by whichever script you ran are usually enough to reproduce a
problem without access to your data.

## Setting up

```bash
git clone https://github.com/csiro/ensys-NEMX.jl
cd NEMX.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'
```

## What the tests expect

```bash
julia --project=. -e 'using Pkg; Pkg.test()'              # ~20 s
NEMX_TEST_SLOW=1 julia --project=. -e 'using Pkg; Pkg.test()'   # + ~2.5 min
```

The default suite must stay fast enough to run on every commit. Anything slower
than a few seconds belongs behind `NEMX_TEST_SLOW`, and anything that touches the
network behind `NEMX_TEST_NETWORK`.

Tests use synthetic markets wherever the correct answer can be known by hand. A
two-unit, one-region market with a monotone offer stack has a price you can
compute on paper, so a test against it catches an error in stacking, sign
convention or dual recovery as a mismatch against arithmetic rather than against
a previous run.

Where a regression against recorded values is the right test — as for the
2000-bus OPFFCAS objectives — use a **relative** tolerance. Those objectives are
of order 10⁶, so an absolute tolerance is either meaningless or fails on the last
bit of a double.

## Where code goes

| Kind | Location |
|:-----|:---------|
| Anything importable | `src/<submodule>/<layer>/` |
| Anything runnable | `scripts/` |
| Test fixtures | `test/data/` |

Two rules follow from that, and they are what keep the structure from eroding:

**Nothing runnable in `src/`.** No `Pkg.activate`, no top-level solve, no
hard-coded path to anyone's home directory. A file under `src/` defines functions.

**Nothing in `src/` resolves a path against the working directory.** Assets
shipped with the package are found relative to `NEMX.PKG_DIR`. Anything else is
an argument.

## Style

Follow the surrounding code. Beyond that:

- Four-space indent, no tabs, 92-column soft limit.
- Every exported function carries a docstring with `# Arguments`, `# Keywords`
  where it takes them, `# Returns`, and `# Throws` where it can. The doc build is
  strict; an exported name without a docstring fails it.
- Comments explain **why**, not what. The line above a constant should say what
  breaks if it changes, not restate the constant.
- Anything that changes what a model computes is a module-level `Ref` with a
  default that reproduces the validated configuration — not a keyword threaded
  through a dozen call sites, and not a silently different default.

## The two things this package is fussy about

**Reproducibility.** A result must be reproducible from the log printed above it.
If you add a switch, add it to `print_flags` in the scripts that touch it and to
[Behavioural flags](@ref).

**Not overstating what a number means.** If a quantity is not identifiable, say
so where it is computed and report what is. If a fixture does not exercise a
path, say so in the test rather than letting a reader assume it does. If a
validation check is weaker than it looks — as the marginal-band price test is —
document why and gate on something stronger.

Both of these have caught real errors in this codebase, which is why they are
listed above the style rules rather than below them.

## Changing a behavioural default

Treat this as a change to the results, because it is. A pull request that flips
a default should say what evidence supports it, over how many intervals, and what
the effect on the benchmark error is. The existing flags' docstrings are the
model for this — including `FCAS_DUAL_CVP_PRIORITY`, which documents a rule that
was tried, measured over a thousand intervals, and rejected.

## Adding a formulation

Register it in `NEMX.NBenchmark.FORMULATIONS` with its own optimizer factory. An
LP formulation gets HiGHS, a non-linear one gets Ipopt; the registry is the one
place that decision lives.

## Documentation

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

The build is strict: a broken cross-reference or an exported name missing from
the manual fails it. Narrative pages cross-reference with `[`name`](@ref)`; the
API pages render every docstring via `@autodocs`, so a docstring should not be
placed in a `@docs` block anywhere else.
