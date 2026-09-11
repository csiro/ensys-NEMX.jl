# =============================================================================
# constraints.jl
#
# Julia port of `nempy.historical_inputs.constraints.ConstraintData`.
#
# This class supplies two things to the market:
#   1. CONSTRAINT VIOLATION PRICES — the penalty ($/MW) attached to each soft
#      constraint's slack (deficit/surplus) variable. AEMO uses a hierarchy of
#      violation prices so the solver relaxes the least important constraint
#      first. These are derived from the market price cap (VoLL) times a set of
#      published multipliers (CVP factors).
#   2. FCAS REQUIREMENTS — the regional MW that must be supplied for each FCAS
#      service (from the generic/SPD constraint framework). In the Core+FCAS
#      scope we keep the regional FCAS requirement constraints.
#
# Violation-price hierarchy (CVP factors below mirror AEMO/nempy defaults).
# =============================================================================

# Market price cap (Value of Lost Load). AEMO's 2024 VoLL is $17,500/MWh.
const MARKET_PRICE_CAP = 17_500.0

# Constraint Violation Prices in ABSOLUTE $/MW (NOT divided by anything!).
#
# CRITICAL: every violation price MUST be far larger than the market price cap
# ($17,500). A soft constraint's slack price is effectively a cap on how much the
# optimiser will "pay" to satisfy that constraint — if it is set below the
# highest bid, the optimiser simply violates the constraint (e.g. declines to
# serve demand) instead of dispatching expensive plant, which caps and collapses
# prices. AEMO scales these as multiples of VoLL; values below follow AEMO's CVP
"""
    CVP_FACTORS

Fallback constraint violation prices, as multiples of the market price cap.

The constraint violation price hierarchy decides which constraint the dispatch
breaks first when it cannot satisfy them all: a higher price means a constraint
is relaxed later. These are FALLBACKS only — the actual per-interval values come
from the NEMDE case file (see `xml_violation_prices`) and override them, so this
table matters only when a case file is unavailable.
"""
const CVP_FACTORS = Dict(
    "voll"             => MARKET_PRICE_CAP,
    "regional_demand"  => 2_625_000.0,   # energy deficit  (≈150 × VoLL): hardest
    "interconnector"   => 1_312_500.0,   # ≈75 × VoLL
    "generic_constraint" => 437_500.0,   # ≈25 × VoLL
    "ramp_rate"        => 297_500.0,     # ≈17 × VoLL
    "unit_capacity"    =>  96_250.0,     # ≈5.5 × VoLL
    "uigf"             =>  96_250.0,
    "fast_start"       =>  96_250.0,
    "fcas_max_avail"   =>  87_500.0,     # ≈5 × VoLL
    "fcas_profile"     =>  91_962.5,     # ≈5.255 × VoLL
    "fcas_requirement" =>  70_000.0,     # ≈4 × VoLL
    "tiebreak"         => 1.0e-6,        # tiny: equalises equally-priced dispatch
)

"""
    ConstraintData(loader::RawInputsLoader)

Reads constraint-related inputs for the current interval. Mirrors
`constraints.ConstraintData`. The generic (network/security/FCAS-requirement)
constraints invoked by NEMDE for the interval are parsed once at construction.
"""
mutable struct ConstraintData
    loader::RawInputsLoader
    gc::DataFrame       # set, rhs, type, violation_price
    trader::DataFrame   # set, unit, service, factor
    interc::DataFrame   # set, interconnector, factor
    region::DataFrame   # set, region, service, factor
    vprices::Dict{String,Float64}   # per-interval violation prices ($/MW)
end

function ConstraintData(loader::RawInputsLoader)
    gc, trader, interc, region = _xml_generic_constraints(loader)
    # Start from the CVP fallbacks, then override with the actual per-interval
    # violation prices read from the XML case solution.
    vp = Dict{String,Float64}(k => v for (k, v) in CVP_FACTORS)
    for (k, v) in _xml_violation_prices(loader)
        vp[k] = v
    end
    # fcas_requirement is not separately published; tie it to fcas_profile.
    haskey(vp, "fcas_requirement") || (vp["fcas_requirement"] = get(vp, "fcas_profile", 70_000.0))
    return ConstraintData(loader, gc, trader, interc, region, vp)
end

"""
    get_generic_constraints(c::ConstraintData) -> (rhs_and_type, unit_lhs,
                                                    interconnector_lhs, region_lhs)

Return the invoked generic constraints and their LHS factor tables. These bundle
nempy's `get_rhs_and_type_excluding_regional_fcas_constraints`, `get_unit_lhs`,
`get_interconnector_lhs` and the regional-FCAS terms — here kept together because
the NEMDE XML supplies them uniformly per constraint id.
"""
get_generic_constraints(c::ConstraintData) = (c.gc, c.trader, c.interc, c.region)

"""
    get_violation_costs(c::ConstraintData) -> Float64

Base violation cost for generic constraints. The per-constraint penalty actually
used is each constraint's own `violation_price` from the XML; this value is a
fallback for constraints with no published violation price.
"""
get_violation_costs(c::ConstraintData) = get(c.vprices, "generic_constraint", 437_500.0)

"""
    is_over_constrained_dispatch_rerun(c::ConstraintData) -> Bool

True when AEMO actually used the over-constrained-dispatch (OCD) rerun for this
interval. Mirrors nempy exactly: the flag is 'OCD' appearing in the loaded case
FILE NAME (AEMO publishes a `NEMSPDOutputs_..._OCD.loaded` variant only when the
rerun process ran). The previous heuristic — "any constraint carries a positive
violation price" — was true for nearly every interval and wrongly routed all
intervals through the OCD price-capping path.
"""
is_over_constrained_dispatch_rerun(c::ConstraintData) = _xml_is_ocd(c.loader)

"""
    get_constraint_violation_prices(c::ConstraintData) -> Dict{String,Float64}

Return the violation-price for each soft-constraint category. Mirrors
`get_constraint_violation_prices`. Each value is the `\$/MW` penalty applied to
that constraint's slack variable in the objective.
"""
function get_constraint_violation_prices(c::ConstraintData)
    return c.vprices
end

"""
    get_fcas_requirements(c::ConstraintData) -> DataFrame

DEPRECATED in favour of [`get_generic_constraints`](@ref). Regional FCAS
requirement constraints are now handled uniformly as generic constraints (their
`RegionFactor` terms), so this returns an empty frame to avoid double-counting.
Kept only for API parity with the earlier example.
"""
get_fcas_requirements(c::ConstraintData) =
    DataFrame(set=String[], service=String[], region=String[], volume=Float64[], type=String[])
