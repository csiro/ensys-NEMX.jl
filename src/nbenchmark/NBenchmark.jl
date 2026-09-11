"""
    NEMX.NBenchmark

Network-resolved (nodal) dispatch driven by the *same* market inputs as the
zonal benchmark.

The design idea is a consistency-preserving lift. `NEMX.ZBenchmark`
solves the market on a copper plate, one balance constraint per region.
`NBenchmark` takes the identical per-interval offers, availabilities, ramp
rates, FCAS trapeziums and generic constraints, attaches every participant to a
bus of a physical network model, and re-solves the same market problem as an
optimal power flow. Because only the network representation changes, any
difference in price is attributable to that change and to nothing else.

The power-flow model is supplied by PowerModels, so the whole family of
formulations is available on one market problem: an exact DC model, the AC
model, and the convex relaxations between them.

# Layout

| Folder  | Contents                                                        |
|:--------|:----------------------------------------------------------------|
| `core/` | Solver configuration and the formulation registry, MATPOWER case loading, participant-to-bus mapping, offer-stack and constraint helpers |
| `prob/` | `build_market_opf` (the market overlay on a PowerModels OPF), `solve_network_dispatch` (solve, retry, price extraction) and `compare_formulations` |

# Formulations

[`FORMULATIONS`](@ref) maps a name to a `(PowerModels model type, optimizer
factory)` pair:

| Name | Model | Notes |
|:-----|:------|:------|
| `"DCP"` | `DCPPowerModel` | Linear DC, solved with HiGHS |
| `"DCP_MLF"` | `DCPPowerModel` | DC with injections scaled by marginal loss factors |
| `"LPACC"` | `LPACCPowerModel` | LP AC approximation, cold-start |
| `"SOCWR"` | `SOCWRPowerModel` | Second-order-cone relaxation in the W space |
| `"QCRM"` | `QCRMPowerModel` | Quadratic-convex relaxation |
| `"ACP"` | `ACPPowerModel` | Full AC in polar coordinates, solved with Ipopt |

# Typical workflow

```julia
using NEMX, Dates
const NB = NEMX.NBenchmark

result = NB.solve_network_dispatch(DateTime(2025, 9, 2, 12, 5), "DCP";
                                   mfile    = "data/snem2000_fixed.m",
                                   data_dir = "data/nempy_2025_09")
result.prices          # nodal and regional-reference prices
result.decomposition   # energy / congestion / loss components
result.binding         # active-constraint ledger
```

# Behavioural flags

| Flag | Default | Effect |
|:-----|:--------|:-------|
| `NODAL_MLF_PRICE_REFERRAL` | `true` | Refer offer prices to the regional reference node by dividing by the unit's marginal loss factor, matching the zonal objective |
| `BALANCE_SLACK_ENABLED` | `true` | Add CVP-priced one-sided slack generators at each regional reference node so an infeasible interval prices rather than fails |
| `NLP_RETRY_ENABLED` | `true` | On a failed AC solve, retry once with a different barrier strategy *and* a different linear solver |

# Optional HSL linear solver

Ipopt's default MUMPS factorisation is the component most implicated in
machine-dependent AC failures. If a CoinHSL build is unpacked at
`<package root>/vendor/coinhsl/lib/`, or pointed at by `ENV["NEMX_HSLLIB"]`, the
primary AC solve uses MA57 and the retry uses MUMPS, making the second attempt
genuinely independent of the first. HSL is licensed by STFC and is not
redistributable, so it is discovered at run time and its absence is not an
error — the package falls back to MUMPS throughout.
"""
module NBenchmark

using CSV
using DataFrames
using Dates
using HiGHS
using Ipopt
using JuMP
using PowerModels
using SCS
using Statistics

using ..ZBenchmark
# `BAND_COLS` is the ten offer-band column names. It is internal to the zonal
# benchmark's data layer rather than part of its public API, so it is imported
# by name instead of being exported from there.
import ..ZBenchmark: BAND_COLS

const PM = PowerModels

# PowerModels emits an INFO line per solve; over a 288-interval sweep that is
# noise, and callers that want it can raise the level themselves.
function __init__()
    PowerModels.silence()
    return nothing
end

# ---------------------------------------------------------------------------
# Configuration, case data and the market-to-network mapping.
# ---------------------------------------------------------------------------
include("core/config.jl")       # HSL discovery, Ipopt options, FORMULATIONS
include("core/network.jl")      # MATPOWER case + NEM side tables
include("core/market_data.jl")  # per-interval market inputs (from ZBenchmark)
include("core/mapping.jl")      # participant -> bus, interconnector tie groups
include("core/bids.jl")         # offer stacks, MLF bound scaling, balance slack

# ---------------------------------------------------------------------------
# The optimisation.
# ---------------------------------------------------------------------------
include("prob/market_opf.jl")   # build_market_opf: market overlay on an OPF
include("prob/solve.jl")        # solve_network_dispatch: solve and price
include("prob/compare.jl")      # compare_formulations: one interval, many models

export load_network, load_market, map_participants!, solve_network_dispatch,
       compare_formulations, classify_generic, build_market_opf,
       FORMULATIONS, PKG_ROOT, hsl_library_path,
       NODAL_MLF_PRICE_REFERRAL, BALANCE_SLACK_ENABLED, NLP_RETRY_ENABLED,
       AREA_OF_REGION, REGION_OF_AREA, TAU

end # module NBenchmark
