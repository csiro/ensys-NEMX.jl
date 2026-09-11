# Architecture

## The idea

A zonal market model and a nodal one normally differ in two ways at once: the
network representation, and the market data each was built from. Any difference
between their prices is then uninterpretable, because two things changed.

NEMX is built to change one. The zonal reconstruction and the network model
consume the *same* per-interval objects — the same offer stacks, availabilities,
ramp rates, FCAS trapeziums, generic constraints and violation prices. The
network model does not re-derive them; it imports them:

```julia
# src/nbenchmark/NBenchmark.jl
using ..ZBenchmark
```

so a difference in price is attributable to the network representation and to
nothing else. Everything about the layout follows from wanting that property to
be true and to stay true.

## Package layout

```
NEMX.jl/
├── src/
│   ├── NEMX.jl                 top-level module; includes the three below
│   ├── zbenchmark/             zonal (copper-plate) reconstruction
│   │   ├── data/               AEMO acquisition: MMS mirror, NEMDE cache, loader
│   │   ├── core/               input classes, SpotMarket, set_*! API, results
│   │   ├── prob/               constraint assembly, dispatch!, pricing
│   │   └── util/               price recovery, the packaged assembly sequence
│   ├── nbenchmark/             network-resolved nodal dispatch
│   │   ├── core/               solver config, case loading, participant mapping
│   │   └── prob/               market overlay on an OPF, solve, compare
│   └── opffcas/                AC/DC OPF with FCAS co-optimisation
│       ├── core/               types, variables, constraints, objectives, data
│       ├── form/               formulation-specific methods
│       ├── prob/               problem builders
│       ├── scopf/              security-constrained (opt-in; see Installation)
│       ├── util/, vis/         helpers and plotting
├── scripts/                    everything runnable
├── test/                       the suite, plus small fixtures
├── docs/                       this manual
└── data/                       market data and outputs (not in git)
```

Two rules are worth stating explicitly, because they are what keep the structure
from eroding.

**Nothing runnable lives in `src/`.** A file under `src/` defines functions and
nothing else — no `Pkg.activate`, no top-level solve, no hard-coded path to
someone's home directory. Anything you run is in `scripts/`.

**Nothing in `src/` resolves a path against the working directory.** Assets that
ship with the package are found relative to the package root
(`NEMX.PKG_DIR`), so behaviour does not depend on where Julia was
started. Anything that reads or writes elsewhere takes it as an argument.

## The three submodules

### `NEMX.ZBenchmark`

The data path runs `data/` → `core/` → `prob/`:

1. **`data/`** mirrors AEMO's MMS data model into SQLite and caches the NEMDE
   case files, one per five-minute interval. `RawInputsLoader` joins the two and
   is positioned on an interval with `set_interval!`.
2. **`core/`** turns that into the per-interval quantities the optimisation
   consumes — `UnitData`, `DemandData`, `InterconnectorData`, `ConstraintData` —
   and holds the `SpotMarket` container together with its `set_*!` API.
3. **`prob/`** assembles the JuMP model, solves it, and prices it.

Regional energy prices are the duals of the demand balance constraints. Regional
FCAS prices are factor-weighted sums of generic-constraint duals, because FCAS
requirements are not separate objects in the model — they are SPD generic
constraints carrying `RegionFactor` terms.

### `NEMX.NBenchmark`

`core/` loads a MATPOWER case with its NEM side tables, maps each participant
DUID onto a bus, and groups branches into interconnector tie-lines. `prob/`
overlays the market on a PowerModels OPF: offers become generator cost curves,
FCAS enablement becomes variables and trapezium constraints, generic constraints
become linear constraints on the network variables, and each is given the
violation price the case file assigns it.

Because the power-flow model comes from PowerModels, the whole formulation
family is available on one market problem — see [`FORMULATIONS`](@ref NEMX.NBenchmark.FORMULATIONS).

### `NEMX.OPFFCAS`

This one is a modelling library rather than a reconstruction. It extends
PowerModels and PowerModelsACDC with the variables, constraints and objectives
needed to co-optimise energy against the eight-to-ten FCAS products on an AC/DC
network, following PowerModels' own conventions: `core/` declares, `form/`
specialises per formulation, `prob/` assembles.

## Conventions

### Sign conventions

These are the ones that cause bugs if they drift, so they are stated once and
adhered to everywhere.

| Where | Generation | Load |
|:------|:-----------|:-----|
| Regional balance | `+1` | `-1` for **all** loads |
| Unit-level constraints (capacity, ramp, trapeziums, generic `TraderFactor` terms) | `+1` | `-1` for the load side of a **bidirectional unit** only; an ordinary scheduled load enters with `+1` |
| Objective | offer price | negated — a load's offer is a willingness to **pay** |

The consequence that trips people up: for a load, offer bands fill from the
**highest** price down, and a band is taken while its price *exceeds* the unit's
local price. A \$0/MWh band is the most conservative offer a generator can make
short of the floor, and an aggressive one for a load.

### Units

Ramp rates are MW/h and the movement window is `rate × (5/60)`. Interval length
lives in one constant, [`TAU`](@ref NEMX.NBenchmark.TAU); treating the rates as
MW/min opens the window by a factor of sixty.

Prices are \$/MWh for energy and \$/MW for FCAS. Offers arrive referred to the
regional reference node and are restored to the connection point on ingestion,
then referred back in the objective — see [Prices and duals](@ref).

### Switching model behaviour

Anything that changes what the model computes is a module-level `Ref`, not an
argument threaded through twenty call sites, and its default reproduces the
validated configuration. See [Behavioural flags](@ref) for the full list.

## Package-level utilities

```@docs
NEMX.PKG_DIR
NEMX.version
```

