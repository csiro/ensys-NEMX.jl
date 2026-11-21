"""
    NEMX.ZBenchmark

Zonal (copper-plate) reconstruction of the NEM dispatch engine.

This submodule reproduces AEMO's five-minute regional dispatch from published
data: it downloads the MMS data model and the NEMDE case files, turns them into
tidy per-interval market inputs, assembles a single-interval linear program in
JuMP, and solves it. Regional energy prices come out as the duals of the demand
balance constraints and regional FCAS prices as factor-weighted sums of the
generic-constraint duals, exactly as they do in the market engine it replicates.

It is the *reference* against which the network-resolved models of
`NEMX.NBenchmark` are measured, so its default behaviour is deliberately
conservative: every behavioural switch defaults to the setting that reproduces
published prices, and none of them is changed implicitly.

# Layout

| Folder  | Contents                                                          |
|:--------|:------------------------------------------------------------------|
| `data/` | AEMO data acquisition — MMS SQLite mirror, NEMDE XML case cache, and the loader that joins them per interval |
| `core/` | Market-input classes (units, demand, interconnectors, constraints), the `SpotMarket` container and its `set_*!` API, and result extraction |
| `prob/` | The optimisation itself — constraint assembly, `dispatch!`, and post-solve pricing |

# Typical workflow

```julia
using NEMX, Dates
const ZB = NEMX.ZBenchmark

db    = ZB.DBManager("data/historical_mms.db")
cache = ZB.XMLCacheManager("data/xml_cache")
# One-off: download a month of MMS tables and a day of NEMDE case files.
ZB.populate!(db; start_year = 2025, start_month = 9, end_year = 2025, end_month = 9)
ZB.populate_by_day!(cache; start_year = 2025, start_month = 9, start_day = 2,
                           end_year = 2025, end_month = 9, end_day = 2)

loader = ZB.RawInputsLoader(cache, db)
ZB.set_interval!(loader, DateTime(2025, 9, 2, 12, 5))
market = ZB.build_spot_market(loader)          # assemble every input class
ZB.dispatch!(market)
ZB.get_energy_prices(market)                   # regional reference prices
```

`build_spot_market` is the packaged form of the assembly sequence that the
reference implementation open-coded in each of its driver scripts; see
[`build_spot_market`](@ref) for the individual steps and the flags that govern
them.

# Behavioural flags

All of these are `Ref`s set at run time, e.g. `ZB.LOSS_MODEL_FROM_XML[] = true`.
Defaults reproduce the validated benchmark; see the manual's flag reference for
the evidence behind each.

| Flag | Default | Effect |
|:-----|:--------|:-------|
| `LOSS_MODEL_FROM_XML` | `true` (env `NEMX_LOSS_XML`) | Take interconnector loss curves from the NEMDE case file rather than re-deriving them from MMS demand coefficients |
| `BDU_CROSS_SIDE_REG_LOWER_SUBTRACT` | `true` | Subtract (rather than add) the cross-side regulation term in the lower joint-capacity constraint of a bidirectional unit |
| `ZONAL_MLF_KEEP_SCALING` | `false` | Leave the energy bid stack scaled by the marginal loss factor instead of referring it to the regional reference node |
| `LAZY_LOSS_TIGHTENING` | `true` | Lazily enforce SOS2 adjacency on the loss interpolation after an LP solve |
| `LOSS_TIGHTEN_TIME_LIMIT` | `30.0` | Seconds allowed per loss-adjacency re-solve; `nothing` for no limit |
| `FCAS_DUAL_CVP_PRIORITY` | `false` | Opt-in refinement of degenerate FCAS requirement duals by CVP priority |
| `DIRECTED_UNIT_PRICE_RELAX` | `false` | Experimental dual-degeneracy resolution for directed units |
| `XML_PRICES_PRESCALED` | `true` | Treat NEMDE case-file energy prices as pre-referred to the regional node |
| `SOLVER_FACTORY` | `HiGHS.Optimizer` | Optimizer used by `dispatch!` |
"""
module ZBenchmark

using CSV
using DBInterface
using DataFrames
using Dates
using EzXML
using HTTP
using HiGHS
using JuMP
using Printf
using SQLite
using Statistics
using ZipFile

# ---------------------------------------------------------------------------
# Data acquisition: AEMO's published MMS tables and NEMDE case files.
# ---------------------------------------------------------------------------
include("data/mms_db.jl")      # MMS data model mirrored into SQLite
include("data/xml_cache.jl")   # NEMDE XML case-file cache and parser
include("data/loaders.jl")     # RawInputsLoader: joins the two, per interval

# ---------------------------------------------------------------------------
# Market inputs: the per-interval quantities the optimisation consumes.
# ---------------------------------------------------------------------------
include("core/units.jl")            # bids, availability, ramp rates, FCAS trapeziums
include("core/demand.jl")           # regional operational demand
include("core/interconnectors.jl")  # definitions and the loss model
include("core/constraint_data.jl")  # violation prices and generic (SPD) constraints

# ---------------------------------------------------------------------------
# The optimisation: container, constraint assembly, solve, pricing, results.
# ---------------------------------------------------------------------------
include("core/market.jl")      # SpotMarket type, set_*! API, behavioural flags
include("prob/constraint.jl")  # constraint builders called by dispatch!
include("prob/dispatch.jl")    # dispatch!: build the JuMP model and solve it
include("prob/pricing.jl")     # loss-adjacency tightening and dual refinement
include("core/result.jl")      # dispatch quantities, prices, binding constraints

include("util/prices.jl")      # price recovery, published-price comparison, local prices
include("util/assemble.jl")    # build_spot_market / dispatch_interval!: the packaged sequence

# --- Data acquisition -------------------------------------------------------
export DBManager, populate!, populate_from_local!, get_table, REQUIRED_TABLES
export XMLCacheManager, populate_by_day!, load_interval!
export RawInputsLoader, set_interval!

# --- Market-input classes ---------------------------------------------------
export UnitData, DemandData, InterconnectorData, ConstraintData
export get_unit_info, get_processed_bids, get_unit_bid_availability,
       get_unit_uigf_limits, get_bid_ramp_rates, get_scada_ramp_rates,
       get_fcas_max_availability, get_fcas_regulation_trapeziums,
       get_contingency_services, add_fcas_trapezium_constraints!,
       get_fast_start_profiles_for_dispatch, get_initial_unit_output
export get_operational_demand
export get_interconnector_definitions, get_interconnector_loss_model
export get_constraint_violation_prices, get_fcas_requirements,
       get_generic_constraints, get_violation_costs,
       is_over_constrained_dispatch_rerun

# --- Model -------------------------------------------------------------------
export SpotMarket, MarketInputs, build_spot_market, dispatch_interval!,
       set_unit_volume_bids!, set_unit_price_bids!,
       set_unit_bid_capacity_constraints!,
       set_unconstrained_intermittent_generation_forecast_constraint!,
       set_unit_ramp_rate_constraints!,
       set_fast_start_constraints!,
       set_tie_break_constraints!,
       set_fcas_max_availability!,
       set_energy_and_regulation_capacity_constraints!,
       set_joint_ramping_constraints_reg!,
       set_joint_capacity_constraints!,
       set_interconnectors!, set_interconnector_losses!,
       set_fcas_requirements_constraints!,
       set_generic_constraints!, link_units_to_generic_constraints!,
       link_interconnectors_to_generic_constraints!,
       link_regions_to_generic_constraints!,
       set_demand_constraints!,
       dispatch!, get_unit_dispatch, get_energy_prices, get_fcas_prices,
       get_binding_generic_constraints

# --- Price recovery and comparison ------------------------------------------
export DEFAULT_REGIONS, SERVICE_ROP_COL, get_regional_fcas_prices,
       get_published_rops, unit_constraint_terms, local_prices,
       as_float, column_or_nan

# --- Behavioural flags -------------------------------------------------------
export LOSS_MODEL_FROM_XML, BDU_CROSS_SIDE_REG_LOWER_SUBTRACT,
       ZONAL_MLF_KEEP_SCALING, LAZY_LOSS_TIGHTENING, LAZY_LOSS_VERBOSE,
       LOSS_TIGHTEN_TIME_LIMIT, FCAS_DUAL_CVP_PRIORITY,
       DIRECTED_UNIT_PRICE_RELAX, XML_PRICES_PRESCALED, SOLVER_FACTORY

end # module ZBenchmark
