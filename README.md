# NEMX.jl

[![CI](https://github.com/ghulam41/NEMX.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/ghulam41/NEMX.jl/actions/workflows/CI.yml)
[![Documentation](https://github.com/ghulam41/NEMX.jl/actions/workflows/Documentation.yml/badge.svg)](https://ghulam41.github.io/NEMX.jl/dev/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Market dispatch and network-constrained optimal power flow for the Australian
National Electricity Market, in Julia.

NEMX does three things, which share a data layer and a set of conventions but
are useful separately:

- **reconstructs** AEMO's five-minute regional dispatch from published data,
  closely enough to reproduce its prices;
- **lifts** the identical market inputs onto a physical network model and
  re-solves them as an optimal power flow, across the whole PowerModels
  formulation family, yielding nodal prices and an exact energy / congestion /
  loss decomposition;
- **models** AC/DC optimal power flow with co-optimised frequency control
  ancillary services.

The second of these is the point of the package. Because the market inputs are
held fixed and only the network representation changes, any difference in price
is attributable to that change and to nothing else — which is what makes the
comparison worth making.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/ghulam41/NEMX.jl")
```

Julia 1.10 or later. Every solver the package needs is open source — HiGHS for
linear and mixed-integer problems, Ipopt for non-linear ones, SCS for conic
relaxations — so nothing here requires a licence.

## Sixty-second start

```julia
using NEMX, DataFrames
const ZB = NEMX.ZBenchmark

# Two generators, one region, ten-band offers.
row(u, v) = (; unit = u, dispatch_type = "generator", service = "energy",
             (Symbol(string(i)) => (i <= length(v) ? v[i] : 0.0) for i in 1:10)...)

volumes = DataFrame([row("A", [20.0, 20.0, 5.0]), row("B", [50.0, 30.0, 10.0])])
prices  = DataFrame([row("A", [50.0, 60.0, 100.0]), row("B", [50.0, 55.0, 80.0])])
info    = DataFrame(unit = ["A", "B"], region = ["NSW1", "NSW1"],
                    dispatch_type = ["generator", "generator"],
                    loss_factor = [1.0, 1.0])

market = ZB.SpotMarket(market_regions = ["NSW1"], unit_info = info)
ZB.set_unit_volume_bids!(market, volumes)
ZB.set_unit_price_bids!(market, prices)
ZB.set_demand_constraints!(market, DataFrame(region = ["NSW1"], demand = [120.0]))
ZB.dispatch!(market)

ZB.get_unit_dispatch(market)   # A = 40 MW, B = 80 MW
ZB.get_energy_prices(market)   # NSW1 = $60/MWh, the marginal band's price
```

Or run the same thing as a script, which also prints the local prices:

```bash
julia --project=. scripts/zbenchmark/zonal_simple_example.jl
```

## The three submodules

| Submodule | Folder | What it does |
|:----------|:-------|:-------------|
| `NEMX.ZBenchmark` | `src/zbenchmark/` | Zonal (copper-plate) reconstruction of the five-minute NEM dispatch. Downloads AEMO's MMS tables and NEMDE case files, assembles a single-interval LP, and recovers regional energy and FCAS prices as its duals. |
| `NEMX.NBenchmark` | `src/nbenchmark/` | The same market inputs on a physical network, re-solved as an OPF under DC, LPAC, SOC, QC and AC formulations. Yields nodal prices, an energy/congestion/loss decomposition and an active-constraint ledger. |
| `NEMX.OPFFCAS` | `src/opffcas/` | AC/DC optimal power flow with co-optimised FCAS, built on PowerModels and PowerModelsACDC. Polar, rectangular-current, branch-flow and relaxed formulations, plus multi-network problems. |

They are separate modules rather than one flat namespace so that a name defined
for one cannot silently collide with a name defined for another.

## Working with real market data

Both benchmark models read AEMO's published data. The download is built in and
idempotent — a month already mirrored, or a day already cached, is skipped:

```bash
# Ten pseudo-random September-2025 intervals, downloading what is missing
julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl random 10 --download \
      --year=2025 --month=9
```

Budget roughly 1.5 GB per day of NEMDE case files and a few hundred megabytes
for a month of MMS tables. Nothing requires the data to live inside the package
— every script takes `--data-dir`. See [`data/README.md`](data/README.md).

Then lift the same intervals onto the network:

```bash
# One trading day, DC only — the right first run to validate a window
julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 DCP

# Every formulation, an overnight job
julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 \
      DCP,LPACC,SOCWR,QCRM,ACP
```

## Scripts

Everything runnable lives in `scripts/`, never in `src/`. The folder mirrors the
package's three submodules, so a driver sits next to the model it drives:

```
scripts/zbenchmark/   the zonal reconstruction
scripts/nbenchmark/   the network-resolved nodal dispatch
scripts/opffcas/      AC/DC OPF with FCAS co-optimisation
```

Each script takes its whole configuration from command-line options, bare flags
or environment variables — including which solver to use — and prints that
configuration before doing any work, so a result is reproducible from the log
above it. The plumbing lives in `NEMX.Scripting` and is re-exported by `NEMX`,
so a script needs only `using NEMX`; there is nothing to `include`.

**Zonal reconstruction**

| Script | What it does |
|:-------|:-------------|
| `zbenchmark/zonal_simple_example.jl` | Two units, one region. Runs anywhere, needs no data. |
| `zbenchmark/run_zonal_benchmark.jl` | Sweep intervals and score every price against AEMO's published ROP. |
| `zbenchmark/run_historical_dispatch_jul2024.jl` | Named run: the July 2024 benchmark. |
| `zbenchmark/run_historical_dispatch_sep2025.jl` | Named run: the September 2025 benchmark. |
| `zbenchmark/run_historical_dispatch_sep2025_3day.jl` | Named run: 864 consecutive intervals, three trading days. |
| `zbenchmark/run_bess_event_study.jl` | Per-unit local prices, offers and binding constraints. |
| `zbenchmark/run_bess_event_nov2025_2day.jl` | Named run: the 20–21 November 2025 battery event, two days. |
| `zbenchmark/analyse_bess_event_study.jl` | The gated investigation over those results. |
| `zbenchmark/plot_bess_event_study.jl` | The event figure, symmetric-log price axis. |
| `zbenchmark/plot_zonal_benchmark.jl` | Benchmark figures and tables. |
| `zbenchmark/export_interval_csvs.jl` | Dump every market input for one interval. |

**Network dispatch**

| Script | What it does |
|:-------|:-------------|
| `nbenchmark/run_network_interval.jl` | One interval, several formulations, side by side. |
| `nbenchmark/run_network_day.jl` | A full day; prices, decomposition and constraint ledger. |
| `nbenchmark/run_network_day_20250902.jl` | Named run: the reference network day. |
| `nbenchmark/run_ac_recovery.jl` | What it costs to make a DC dispatch AC-feasible. |
| `nbenchmark/plot_network_day.jl` | Network-day figures and tables. |
| `nbenchmark/fix_snem2000_case.jl` | One-off repair of the raw 2000-bus case. |

**OPF with FCAS**

| Script | What it does |
|:-------|:-------------|
| `opffcas/run_opffcas.jl` | AC/DC OPF with FCAS across formulations, with price tables. |
| `opffcas/run_opffcas_arpst.jl` | The same with phase-shifting transformers active. |
| `opffcas/compute_marginal_loss_factors.jl` | Per-bus MLFs by finite differencing. |
| `opffcas/build_market_scenario.jl` | Raw AEMO bid CSVs into an OPFFCAS scenario. |

Every script's header documents each argument, each flag and its default. Start
there rather than reading the body.

## Tests

```julia
using Pkg; Pkg.test("NEMX")
```

Around twenty seconds by default. Two switches widen it:

```bash
NEMX_TEST_SLOW=1     # + AC and IVR regressions on the 2000-bus case (~2.5 min)
NEMX_TEST_NETWORK=1  # + tests that download from AEMO
```

The OPFFCAS tests are regressions against objective values recorded from the
reference implementation, reproduced to relative 1e-8 — the objective of a
2000-bus co-optimised dispatch is sensitive to nearly every coefficient in the
model, so that agreement is a strong statement about the whole pipeline.

## Documentation

Full manual: <https://ghulam41.github.io/NEMX.jl/dev/>. It covers installation,
the data-acquisition workflow, the architecture, a reference for every
behavioural flag, and the API of each submodule. Build it locally with:

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

## Reproducibility

Every model here is deterministic given its inputs. Behavioural switches are
module-level `Ref`s whose defaults reproduce a validated configuration; nothing
in the package changes one implicitly, so a result is reproducible from the flag
values recorded beside it.

Where a quantity is not identifiable, the package says so rather than picking a
value. The Queensland lower 6 s and 60 s FCAS prices are the standing example:
their constraints are structurally identical, so the dispatch pins only the SUM
of their duals and the split between them is a solver artefact. The benchmark
scores the sum.

## Optional components

**HSL linear solvers.** Ipopt's default MUMPS factorisation is the component
most implicated in machine-dependent AC failures. If a CoinHSL build is unpacked
at `vendor/coinhsl/lib/`, or pointed at by `NEMX_HSLLIB`, the primary AC solve
uses MA57 and the retry uses MUMPS, so the second attempt is genuinely
independent of the first. HSL is licensed by STFC and is not redistributable, so
it is discovered at run time and its absence is not an error.

**Security-constrained problems.** `src/opffcas/scopf/` needs
`PowerModelsACDCsecurityconstrained`, which is not in the General registry. It is
therefore not on the default load path, so `Pkg.add` and `Pkg.test` work with
registered dependencies only. Install that package and call
`NEMX.OPFFCAS.load_security_constrained!()` to enable them.

## Citing

If you use NEMX in published work, please cite it. See [`CITATION.bib`](CITATION.bib).

## Contributing

Bug reports, questions and pull requests are welcome — see
[`CONTRIBUTING.md`](CONTRIBUTING.md) for how the code is laid out, what the
tests expect, and the conventions to follow.

## Acknowledgements

The zonal reconstruction follows the modelling approach of
[nempy](https://github.com/UNSW-CEEM/nempy) (Gorman, Bruce and MacGill, 2022).
The network layer is built on
[PowerModels.jl](https://github.com/lanl-ansi/PowerModels.jl) and
[PowerModelsACDC.jl](https://github.com/Electa-Git/PowerModelsACDC.jl). Market
data is AEMO's, published through NEMWeb.

## License

See — [`LICENSE`](LICENSE).
