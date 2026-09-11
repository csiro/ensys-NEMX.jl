# =============================================================================
# market.jl
#
# SpotMarket type, the `set_*!` input API and the module-level behaviour flags.
#
# Split out of the single-file `spot_market.jl` of the reference
# implementation. The code is unchanged; only its location is. All of these
# files are `include`d into the same `ZBenchmark` module, so definition order
# across them does not matter.
# =============================================================================

# =============================================================================
# spot_market.jl
#
# Julia port of `nempy.markets.SpotMarket` — the optimisation model.
#
# A SpotMarket assembles a single-interval linear program for the NEM energy
# (and FCAS) dispatch and solves it with HiGHS. The design mirrors nempy: you
# push inputs in with `set_*!` methods, then call `dispatch!`. Internally we
# STORE the inputs and BUILD the JuMP model fresh inside `dispatch!`.
#
# Sign conventions (verified against nempy's variable_ids.py):
#   * Variables are keyed (unit, dispatch_type, service) so BIDIRECTIONAL units
#     (BDUs) carry separate generation and load variables under one DUID.
#   * REGIONAL constraints (energy balance, regional FCAS terms): load energy
#     variables enter with coefficient -1 (they withdraw), FCAS always +1.
#   * UNIT-LEVEL constraints (capacity, ramp, trapeziums, generic TraderFactor
#     terms): coefficient -1 ONLY for the load-side ENERGY variables of BDUs;
#     ordinary scheduled loads enter unit-level constraints with +1.
#   * Load energy bids enter the objective negated (willingness to pay).
#
# Ramp rates (bid @RampUpRate and SCADA) are in MW/h; the 5-minute movement
# window is rate * (5/60), exactly as nempy computes it.
# =============================================================================

"""
    SpotMarket(; market_regions::Vector{String}, unit_info::DataFrame)

Create an empty spot-market model for the given NEM regions and unit metadata.
`unit_info` must have columns `unit, dispatch_type, region` (one row per
unit-direction; BDUs appear twice). Mirrors `markets.SpotMarket`.
"""
mutable struct SpotMarket
    regions::Vector{String}
    unit_info::DataFrame
    unit_region::Dict{String,String}
    bdu_units::Set{String}             # units with BOTH generator and load rows

    # Stored inputs (filled by set_*! calls) -----------------------------------
    volume_bids::DataFrame
    price_bids::DataFrame
    capacities::DataFrame              # unit, dispatch_type, capacity
    capacity_cost::Float64
    uigf::DataFrame
    uigf_cost::Float64
    ramp_bid::Union{Nothing,DataFrame}     # unit, dispatch_type, rates, initial_output
    ramp_scada::Union{Nothing,DataFrame}   # unit, scada rates
    ramp_fsp::Union{Nothing,DataFrame}     # fast-start profiles for ramp adjustment
    ramp_run_type::String
    ramp_cost::Float64
    fcas_maxavail::DataFrame
    fcas_maxavail_cost::Float64
    reg_trapeziums::DataFrame
    cont_trapeziums::DataFrame
    fcas_profile_cost::Float64
    joint_ramp::Union{Nothing,DataFrame}   # scada ramp rates incl. initial_output
    joint_ramp_fsp::Union{Nothing,DataFrame}
    joint_ramp_run_type::String
    fast_start::Union{Nothing,DataFrame}   # second-run inflexibility profiles
    fast_start_cost::Float64
    interconnectors::DataFrame
    losses::DataFrame                  # interconnector, link, break_point, loss
    fcas_requirements::DataFrame
    fcas_req_cost::Float64
    # Generic (network/security/FCAS-requirement) constraints --------------
    generic_rhs::DataFrame      # set, rhs, type, violation_price
    generic_unit_lhs::DataFrame # set, unit, service, factor
    generic_interc_lhs::DataFrame  # set, interconnector, factor
    generic_region_lhs::DataFrame  # set, region, service, factor
    generic_cost::Float64
    demand::DataFrame
    demand_cost::Float64
    tiebreak_cost::Float64

    # Results ------------------------------------------------------------------
    model::Union{Nothing,Model}
    unit_dispatch::DataFrame
    energy_prices::DataFrame
    fcas_prices::DataFrame
    # Instrumentation: generic constraint id ->
    #   (constraint ref, lhs expr, rhs, type, slack vars, has_region_terms)
    generic_con_refs::Dict{String,Any}
    loss_link_refs::Vector{Any}          # per-link (ic, link, F, λ, bps, losses) for diagnostics
    demand_con_refs::Dict{String,Any}    # region -> demand-balance constraint (diagnostics)
    fcas_dual_override::Dict{String,Float64}  # set -> CVP-priority refined dual
end

function SpotMarket(; market_regions::Vector{String}, unit_info::DataFrame)
    ur = Dict(string(r.unit) => string(r.region) for r in eachrow(unit_info))
    counts = Dict{String,Set{String}}()
    if "dispatch_type" in names(unit_info)
        for r in eachrow(unit_info)
            push!(get!(counts, string(r.unit), Set{String}()), string(r.dispatch_type))
        end
    end
    bdu = Set(u for (u, s) in counts if length(s) > 1)
    empty_df() = DataFrame()
    return SpotMarket(
        market_regions, unit_info, ur, bdu,
        empty_df(), empty_df(), empty_df(), 0.0, empty_df(), 0.0,
        nothing, nothing, nothing, "no_fast_start_units", 0.0,
        empty_df(), 0.0, empty_df(), empty_df(), 0.0,
        nothing, nothing, "no_fast_start_units",
        nothing, 96_250.0,
        empty_df(), empty_df(), empty_df(), 0.0,
        empty_df(), empty_df(), empty_df(), empty_df(), 437_500.0,
        empty_df(), 0.0, 1e-6,
        nothing, empty_df(), empty_df(), empty_df(), Dict{String,Any}(), Any[],
        Dict{String,Any}(), Dict{String,Float64}(),
    )
end

# Dispatch interval length in hours (NEM = 5 minutes).
const INTERVAL_HOURS = 5 / 60

# Solver used by dispatch! — HiGHS by default; swappable (e.g. to Cbc.Optimizer,
# nempy's solver) for degeneracy comparisons: nemjl.SOLVER_FACTORY[] = Cbc.Optimizer
const SOLVER_FACTORY = Ref{Any}(HiGHS.Optimizer)

# ---------------------------------------------------------------------------
# Input setters (names mirror nempy SpotMarket methods).
# ---------------------------------------------------------------------------
"Set the 10-band volume bids (`unit, dispatch_type, service, \"1\"…\"10\"`)."
set_unit_volume_bids!(m::SpotMarket, df::DataFrame) = (m.volume_bids = df; m)

"Set the 10-band price bids (`unit, dispatch_type, service, \"1\"…\"10\"`)."
set_unit_price_bids!(m::SpotMarket, df::DataFrame) = (m.price_bids = df; m)

"Cap each unit-direction's energy dispatch at its bid-in availability (soft)."
function set_unit_bid_capacity_constraints!(m::SpotMarket, df::DataFrame; violation_cost::Real=5e3)
    m.capacities = df; m.capacity_cost = violation_cost; m
end

"Cap semi-scheduled (wind/solar) units at their UIGF forecast (soft constraint)."
function set_unconstrained_intermittent_generation_forecast_constraint!(m::SpotMarket, df::DataFrame; violation_cost::Real=5e3)
    m.uigf = df; m.uigf_cost = violation_cost; m
end

"""
    set_unit_ramp_rate_constraints!(m, ramp_rates, scada_ramp_rates;
                                    fast_start_profiles=nothing,
                                    run_type="no_fast_start_units", violation_cost)

Limit energy dispatch movement from the unit's initial output over the 5-minute
interval. `ramp_rates` are the BID ramp rates (`unit, dispatch_type,
ramp_up_rate, ramp_down_rate, initial_output`, MW/h); the binding rate is the
lesser of the bid and SCADA rates. Fast-start adjustments mirror nempy's
ramp_rate_processing: first run drops units starting in modes 0–2; second run
drops units ending in modes 0–2 and re-rates units freshly out of mode two.
"""
function set_unit_ramp_rate_constraints!(m::SpotMarket, ramp_rates::DataFrame,
        scada_ramp_rates::Union{Nothing,DataFrame}=nothing; fast_start_profiles=nothing,
        run_type::String="no_fast_start_units", violation_cost::Real=1.6e4)
    m.ramp_bid = ramp_rates
    m.ramp_scada = scada_ramp_rates
    m.ramp_fsp = fast_start_profiles
    m.ramp_run_type = run_type
    m.ramp_cost = violation_cost
    return m
end

"Cap each FCAS service at its offered max availability (soft constraint)."
function set_fcas_max_availability!(m::SpotMarket, df::DataFrame; violation_cost::Real=5e3)
    m.fcas_maxavail = df; m.fcas_maxavail_cost = violation_cost; m
end

"Add the energy↔regulation joint-capacity (regulation trapezium) constraints."
function set_energy_and_regulation_capacity_constraints!(m::SpotMarket, df::DataFrame; violation_cost::Real=5.255e3)
    m.reg_trapeziums = df; m.fcas_profile_cost = violation_cost; m
end

"""
    set_joint_ramping_constraints_reg!(m, scada_ramp_rates; fast_start_profiles,
                                       run_type, violation_cost)

Couple regulation FCAS to the unit's SCADA ramp window (FCAS MODEL IN NEMDE
section 6.1). Only units actually BIDDING the regulation service receive the
constraints. `scada_ramp_rates` needs `unit, scada_ramp_up_rate,
scada_ramp_down_rate, initial_output`.
"""
function set_joint_ramping_constraints_reg!(m::SpotMarket, scada_ramp_rates::DataFrame;
        fast_start_profiles=nothing, run_type::String="no_fast_start_units",
        violation_cost::Real=5.255e3)
    m.joint_ramp = scada_ramp_rates
    m.joint_ramp_fsp = fast_start_profiles
    m.joint_ramp_run_type = run_type
    return m
end

"Add the contingency-FCAS joint-capacity (trapezium) constraints."
function set_joint_capacity_constraints!(m::SpotMarket, df::DataFrame; violation_cost::Real=5.255e3)
    m.cont_trapeziums = df; m
end

"""
    set_fast_start_constraints!(m, profiles; violation_cost)

Apply the fast-start dispatch inflexibility profiles (second dispatch run).
`profiles` needs `unit, end_mode, time_in_end_mode, mode_two_length,
mode_four_length, min_loading`. Mirrors `set_fast_start_constraints`.
"""
function set_fast_start_constraints!(m::SpotMarket, profiles::DataFrame; violation_cost::Real=96_250.0)
    m.fast_start = profiles; m.fast_start_cost = violation_cost; m
end

"Register interconnector definitions (one row per LINK; MNSPs are split)."
set_interconnectors!(m::SpotMarket, df::DataFrame) = (m.interconnectors = df; m)

"Register the piecewise-linear loss support points (per interconnector LINK)."
function set_interconnector_losses!(m::SpotMarket, loss_functions::DataFrame, break_points::DataFrame=DataFrame())
    m.losses = loss_functions; m
end

"Add regional FCAS requirement constraints (`service, region, volume, type`)."
function set_fcas_requirements_constraints!(m::SpotMarket, df::DataFrame; violation_cost::Real=4e3)
    m.fcas_requirements = df; m.fcas_req_cost = violation_cost; m
end

# --- Generic (network / security / FCAS-requirement) constraints -----------
#
# FCAS REQUIREMENTS COUPLED TO INTERCONNECTOR FLOW
# ------------------------------------------------
# Some regional FCAS requirements are written on an interconnector flow as well
# as the regional enablement, e.g. Queensland's lower-service family
#
#     F_Q++BCDM_L6  :  NSW1-QLD1 flow + QLD lower_6s  >= RHS
#     F_Q++BCDM_L60 :  NSW1-QLD1 flow + QLD lower_60s >= RHS
#     F_Q++BCDM_L5  :  NSW1-QLD1 flow + QLD lower_5min + QLD lower_reg >= RHS
#
# When such a constraint BINDS it converts a flow error into an FCAS enablement
# error ONE FOR ONE. Measured 2025-09-02 11:35, where both models satisfy the
# same constraint at the same RHS:
#     ours  : flow -242.339 + L6 155.00  = -87.339
#     NEMDE : flow -237.669 + L6 150.33  = -87.339
# a 4.67 MW QNI flow difference became exactly 4.67 MW of extra Queensland lower
# enablement, moving the marginal FCAS provider and hence the published price.
#
# RESOLVED. This was first attributed to the interconnector loss model, on the
# reasoning that a flow error becomes an enablement error one-for-one. That was
# the wrong direction of causation: the loss curves were subsequently
# reconstructed exactly from the NEMDE demand coefficients and the QNI flow gap
# did not move. The causation runs the other way -- surplus cheap Queensland
# lower supply pushed the flow, not the reverse.
#
# The actual defect was the BDU cross-side regulation sign in the contingency
# joint-capacity lower constraint (see BDU_CROSS_SIDE_REG_LOWER_SUBTRACT). It
# let bidirectional batteries offer their full contingency-lower MaxAvail while
# simultaneously holding lower regulation, understating the cost of Queensland
# lower services. Queensland is simply where it shows up, because its lower
# family is the one written on QNI flow.
"Register the generic constraints' RHS and sense (`set, rhs, type, violation_price`)."
function set_generic_constraints!(m::SpotMarket, rhs_and_type::DataFrame; violation_cost::Real=437_500.0)
    m.generic_rhs = rhs_and_type; m.generic_cost = violation_cost; m
end

"Attach unit LHS terms (`set, unit, service, factor`) to the generic constraints."
link_units_to_generic_constraints!(m::SpotMarket, unit_lhs::DataFrame) =
    (m.generic_unit_lhs = unit_lhs; m)

"Attach interconnector LHS terms (`set, interconnector, factor`)."
link_interconnectors_to_generic_constraints!(m::SpotMarket, interconnector_lhs::DataFrame) =
    (m.generic_interc_lhs = interconnector_lhs; m)

# NON-IDENTIFIABLE DUAL: the Queensland lower 6 s / 60 s split
# ------------------------------------------------------------
# F_Q++BCDM_L6 and F_Q++BCDM_L60 are structurally IDENTICAL constraints -- one
# interconnector factor on QNI (coefficient 1) and one regional factor
# (coefficient 1), with the SAME right-hand side. The QNI flow is the only
# variable they share, so when both bind and the flow is interior its
# stationarity condition gives ONE equation in TWO multipliers: the LP pins only
# mu_L6 + mu_L60. The individual duals are pinned only when some unit is
# strictly marginal in one service; when every enabled unit sits at a bound
# (FCAS max availability, a joint-capacity limit, or an offer-band boundary) no
# such unit exists and the split is free along a segment.
#
# Measured 2025-09-04 08:20, where our PRIMAL is bit-identical to NEMDE (all ten
# enabled QLD units on both services, regional totals 400.0/400.0 MW, QNI flow
# -478.9489 vs NEMDE -478.94888):
#     admissible: mu_L6 in [19.95, 37.6286],  mu_L6 + mu_L60 = 69.6286
#     ours  19.9500 / 49.6786      NEMDE  37.6286 / 32.0000
# Both are exactly optimal; the $17.68/MW difference cancels in the sum.
#
# Over five binding intervals the SUM matches AEMO to six decimals in four (to
# $0.10 in the fifth); the split matches in two. Tie-break rules tested over
# twenty binding intervals: "mu_L60 at its lower bound" reproduces AEMO in 2,
# "mu_L6 at its lower bound" (our behaviour) in 8, neither in 10 -- and several
# published prices lie strictly INSIDE the admissible interval. The choice is a
# solver-basis artefact, not a market rule, so no rule is encoded here: doing so
# would fit the sample rather than the mechanism (cf. the rejected CVP-priority
# heuristic, which reproduced one interval and degraded a 1 000-interval sweep).
# Report these two prices JOINTLY; their sum is the identifiable quantity.
"Attach regional (FCAS) LHS terms (`set, region, service, factor`)."
link_regions_to_generic_constraints!(m::SpotMarket, region_lhs::DataFrame) =
    (m.generic_region_lhs = region_lhs; m)

"Set the regional operational demand the dispatch must balance (equality, soft)."
function set_demand_constraints!(m::SpotMarket, df::DataFrame; violation_cost::Real=2_625_000.0)
    m.demand = df; m.demand_cost = violation_cost; m
end

"""
    ZONAL_MLF_KEEP_SCALING

Suppress the marginal-loss-factor referral in the zonal energy objective.

`get_processed_bids` multiplies case-file energy prices by the unit's loss
factor, restoring connection-point prices; this engine normally divides by the
same factor, so the round trip is an exact no-op and the objective is referred
to the regional reference node. That is the validated benchmark, and it is what
`false` (the default) reproduces bit-for-bit.

Setting `true` keeps the scaled bid stack -- prices stay at the connection point
and are never referred back. This exists for ONE purpose: to generate the
MLF-scaled reference dispatch that the network-formulation study is measured
against (`scripts/nbenchmark/run_network_day.jl`). Comparing the nodal
formulations against AEMO's published ROP conflates two different things, the
error of the power-flow model and the difference between a zonal and a nodal
market; comparing them against a zonal run built on the SAME bid stack isolates
the first.

It must never be set when reproducing the benchmark itself. Nothing in
`script/run_historical_dispatch*.jl` touches it, and the default leaves those
results unchanged.
"""
const ZONAL_MLF_KEEP_SCALING = Ref(false)

"Set the tiny tie-break penalty that equalises equally-priced dispatch."
set_tie_break_constraints!(m::SpotMarket, violation_cost::Real=1e-6) = (m.tiebreak_cost = violation_cost; m)

# Convert possibly-string/missing cell to Float64.
_num(x) = ismissing(x) ? missing : (x isa Number ? float(x) :
          (tryparse(Float64, string(x)) === nothing ? missing : parse(Float64, string(x))))

_getcol(r, c, default) = (c in propertynames(r)) ? coalesce(_num(r[c]), default) : default
