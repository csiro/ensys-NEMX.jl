# Scripts

Everything runnable lives in `scripts/`. Nothing under `src/` executes on load.

The folder mirrors the package's three submodules, so a script sits next to the
model it drives:

```
scripts/
├── zbenchmark/   drivers for the zonal (copper-plate) reconstruction
├── nbenchmark/   drivers for the network-resolved nodal dispatch
└── opffcas/      drivers for AC/DC OPF with FCAS co-optimisation
```

Every script takes its whole configuration from the command line or the
environment — including which solver to use — and prints that configuration
before doing any work, so a result is reproducible from the log above it.

## How arguments work

The plumbing lives in `NEMX.Scripting` and is re-exported by `NEMX`, so a script
needs only `using NEMX`. There is nothing to `include`.

Three mechanisms, in decreasing order of precedence:

| Form | Example |
|:-----|:--------|
| Named option | `--solver=ipopt`, `--data-dir=/mnt/nem`, `--forms=DCP,ACP` |
| Bare flag | `--download`, `--with-lmp`, `--verbose-solver` |
| Environment variable | `NEMX_SOLVER=ipopt`, `NEMX_DATA_DIR=/mnt/nem` |

An option's environment variable is its name upper-cased, with hyphens turned
into underscores, prefixed `NEMX_`: `--out-dir` reads `NEMX_OUT_DIR`.

Bare flags are always off by default. A switch that should default to *on* is
exposed as `--no-something`, so the default is visible on the command line
rather than hidden in the file.

Positional arguments are accepted where a script documents them, and each can
equally come from an environment variable.

```@docs
NEMX.Scripting
NEMX.Scripting.script_option
NEMX.Scripting.script_flag
NEMX.Scripting.script_positional
NEMX.Scripting.script_integer
NEMX.Scripting.script_number
NEMX.Scripting.script_datetime
NEMX.Scripting.script_list
NEMX.Scripting.resolve_output_dir
NEMX.Scripting.resolve_input_dir
NEMX.Scripting.print_banner
NEMX.Scripting.print_flag_values
NEMX.Scripting.print_progress
NEMX.Scripting.environment_name
NEMX.Scripting.package_version
```

## Choosing a solver

```bash
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl --solver=highs
julia --project=. scripts/opffcas/run_opffcas.jl --nlp-solver=ipopt --lp-solver=highs
```

```@docs
NEMX.Scripting.SOLVER_CHOICES
NEMX.Scripting.select_solver
```

All three solvers are open source; nothing here needs a licence.
`--verbose-solver` lets the solver print its own progress, which is what you
want when diagnosing a bad solve.

The network-day sweep is the exception. Each formulation carries its own solver
in `NEMX.NBenchmark.FORMULATIONS`, because an LP formulation wants HiGHS and a
non-linear one wants Ipopt, and mixing them is never what you want. Change it
there rather than by flag.

## `scripts/zbenchmark/` — the zonal reconstruction

### General drivers

| Script | Purpose |
|:-------|:--------|
| `zonal_simple_example.jl` | Two units, one region, no data required. Run this first. |
| `run_zonal_benchmark.jl` | Sweep intervals and score every price against AEMO's published ROP. |
| `plot_zonal_benchmark.jl` | Figures and tables from that sweep. |
| `export_interval_csvs.jl` | Dump every market input for one interval. |
| `run_bess_event_study.jl` | Per-unit local prices, offers and binding constraints across a window. |
| `analyse_bess_event_study.jl` | The gated investigation over those results, emitting LaTeX tables. |
| `plot_bess_event_study.jl` | The event figure, with a symmetric-log price axis. |

### Named runs

These fix the arguments of a study that is referred to by name, so that
"run the July 2024 benchmark" is one command and always means the same thing.
Each is a thin wrapper: it sets defaults and includes the general driver, so
there is one implementation of the sweep rather than several. Anything given on
the command line still wins.

| Script | What it fixes |
|:-------|:--------------|
| `run_historical_dispatch_jul2024.jl` | July 2024, 10 random intervals, tag `2024_07` |
| `run_historical_dispatch_sep2025.jl` | September 2025, 10 random intervals, tag `2025_09` |
| `run_historical_dispatch_sep2025_3day.jl` | September 2025, **864 consecutive** intervals (three trading days), tag `2025_09_3day` |
| `run_bess_event_nov2025_2day.jl` | 20–21 November 2025, **576 consecutive** intervals (two days), NSW1 |

```bash
julia --project=. scripts/zbenchmark/zonal_simple_example.jl
julia --project=. scripts/zbenchmark/run_historical_dispatch_jul2024.jl --download
julia --project=. scripts/zbenchmark/run_historical_dispatch_sep2025_3day.jl
julia --project=. scripts/zbenchmark/export_interval_csvs.jl 2025-09-02T13:25
```

A random sample gives an unbiased error estimate but cannot show anything that
depends on the sequence. The consecutive runs exist for ramping, storage state,
fast-start mode, and price spikes with the recovery that follows them.

## `scripts/nbenchmark/` — the network model

| Script | Purpose |
|:-------|:--------|
| `run_network_interval.jl` | One interval, several formulations, printed side by side. |
| `run_network_day.jl` | A full day; prices, decomposition and constraint ledger to CSV. |
| `run_network_day_20250902.jl` | **Named run**: the reference network day, 2025-09-02, 288 intervals, all formulations. |
| `run_ac_recovery.jl` | What it costs to make a DC dispatch AC-feasible. |
| `plot_network_day.jl` | Figures and tables from a network-day sweep. |
| `fix_snem2000_case.jl` | One-off repair of the raw 2000-bus case. |

```bash
julia --project=. scripts/nbenchmark/run_network_interval.jl 2025-09-02T12:05 DCP,ACP
julia --project=. scripts/nbenchmark/run_network_day_20250902.jl
julia --project=. scripts/nbenchmark/run_ac_recovery.jl 2025-09-02T04:05 288
```

Validate a window with `DCP` before widening the formulation list: the AC
formulations and the convex relaxations are 2000-bus non-linear programs taking
tens of seconds each, so the full list over a day is an overnight job.

## `scripts/opffcas/` — OPF with FCAS

| Script | Purpose |
|:-------|:--------|
| `run_opffcas.jl` | AC/DC OPF with FCAS across formulations, with regional price tables. |
| `run_opffcas_arpst.jl` | The same with phase-shifting transformers active. |
| `compute_marginal_loss_factors.jl` | Per-bus MLFs by finite-differencing an AC power flow. |
| `build_market_scenario.jl` | Raw AEMO bid CSVs into an OPFFCAS scenario. |

```bash
julia --project=. scripts/opffcas/run_opffcas.jl --scenario=s1
julia --project=. scripts/opffcas/build_market_scenario.jl --scenario=s1 \
      --market-dir=/data/aemo/2025-09
```

`compute_marginal_loss_factors.jl` needs `PowerModelsACDCsecurityconstrained`,
which is not in the General registry; see [Installation](@ref).

## Long runs

A 288-interval sweep across every formulation runs overnight. Three things make
that survivable.

**Checkpointing.** Results are flushed every `--checkpoint` intervals, so an
interrupted run leaves usable output. `run_ac_recovery.jl` goes further and
resumes: intervals already in its CSV are kept and not re-solved, so re-running
the same command continues where it stopped.

**Isolation.** Each interval is solved in its own `try`. One unsolvable or
malformed interval costs that interval, not the run, and appears in the failure
list at the end.

**Scratch output.** Scripts that write large result sets default `--out-dir` to a
local scratch path and copy into the project tree once, at the end. A file
rewritten every few minutes for hours is not reliably served back at its newest
version by a cloud sync client — a completed sweep has been seen leaving only its
first two thirds on disk. The final copy is also wrapped: if the data directory
is read-only or unreachable, the failure is reported and the scratch copy is
named, rather than an exception discarding hours of work.

## Writing a new script

The skeleton, in the house style:

```julia
# =============================================================================
# my_script.jl
#
# PURPOSE
#   One paragraph on what this produces and why.
#
# ARGUMENTS
#   Positional    Env            Default            Meaning
#   ------------  -------------  -----------------  ------------------------
#   1             NEMX_START     2025-09-02T04:05   first interval
#
#   Options       Env            Default            Meaning
#   ------------  -------------  -----------------  ------------------------
#   --solver=     NEMX_SOLVER    highs              highs | ipopt | scs
#
# EXAMPLES
#   julia --project=. scripts/zbenchmark/my_script.jl
# =============================================================================

using NEMX
using Dates

const ZB = NEMX.ZBenchmark

const START  = script_datetime(script_positional(1, "NEMX_START", "2025-09-02T04:05"))
const SOLVER = script_option("solver", "highs")

ZB.SOLVER_FACTORY[] = select_solver(SOLVER; silent = !script_flag("verbose-solver"))

print_banner("What this run is", "start" => START, "solver" => SOLVER)
print_flag_values(ZB, :LOSS_MODEL_FROM_XML, :ZONAL_MLF_KEEP_SCALING)

# ... the work ...
```

Three conventions to keep:

1. **Document every argument in the header**, with its environment variable and
   its default. The header is what someone reads; the body is what they read
   afterwards.
2. **Print the configuration before doing any work**, including any behavioural
   flag the script changes.
3. **Take the solver as an argument.** A hard-coded solver makes a script
   unusable to anyone without it.
