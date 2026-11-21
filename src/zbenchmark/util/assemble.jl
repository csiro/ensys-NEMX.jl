# =============================================================================
# assemble.jl
#
# The packaged interval-assembly sequence.
#
# Every driver in the reference implementation open-coded the same forty lines:
# construct the four input classes, push them into a `SpotMarket` with the
# `set_*!` API in a specific order, dispatch, apply the fast-start second pass,
# and dispatch again under the over-constrained-dispatch rule. Repeating that
# sequence per script meant it could drift between scripts, and it could not be
# unit-tested without a script.
#
# It lives here instead, as two functions: `build_spot_market`, which returns an
# assembled but unsolved market, and `dispatch_interval!`, which runs the whole
# solve including both passes. The scripts call these; the tests call these.
# =============================================================================

"""
    MarketInputs

The four per-interval input classes, kept together so a caller that needs one of
them after assembly (unit info for a region map, violation prices for a report)
does not have to rebuild it.

# Fields
- `units::UnitData` — bids, availability, ramp rates and FCAS trapeziums
- `demand::DemandData` — regional operational demand
- `interconnectors::InterconnectorData` — definitions and the loss model
- `constraints::ConstraintData` — violation prices and generic (SPD) constraints
- `cvp::Dict{String,Float64}` — constraint violation prices, by category
"""
struct MarketInputs
    units::UnitData
    demand::DemandData
    interconnectors::InterconnectorData
    constraints::ConstraintData
    cvp::Dict{String,Float64}
end

"""
    build_spot_market(loader; regions = DEFAULT_REGIONS, fast_start = true)
        -> (market::SpotMarket, inputs::MarketInputs)

Assemble a `SpotMarket` for the interval `loader` is currently positioned on,
without solving it.

`loader` must already have been moved onto the interval with
[`set_interval!`](@ref); this function does not move it, so that a caller
sweeping a series controls the interval cursor itself.

# Arguments
- `loader::RawInputsLoader`: joined MMS + NEMDE source for the interval.

# Keywords
- `regions::Vector{String} = DEFAULT_REGIONS`: market regions to model. Passing
  a subset is supported but changes the problem — interconnectors to an omitted
  region are dropped, not fixed at their historical flow.
- `fast_start::Bool = true`: apply the fast-start inflexibility profiles on the
  *first* pass (`"fast_start_first_run"`). The second pass is applied by
  [`dispatch_interval!`](@ref) after the unconstrained solve, because it needs
  that solve's dispatch to classify each fast-start unit's end mode.

# Returns
A tuple of the assembled market and the input classes used to build it.

# Notes
The order of the `set_*!` calls below is the order the reference market engine
applies them and is not arbitrary: `add_fcas_trapezium_constraints!` mutates
`units` in place and must precede every FCAS getter, and the ramp constraints
must be set before the joint-ramping constraints that reuse the same SCADA
rates.
"""
function build_spot_market(loader::RawInputsLoader;
                           regions::Vector{String} = DEFAULT_REGIONS,
                           fast_start::Bool = true)
    units           = UnitData(loader)
    interconnectors = InterconnectorData(loader)
    constraints     = ConstraintData(loader)
    demand          = DemandData(loader)
    cvp             = get_constraint_violation_prices(constraints)

    market = SpotMarket(market_regions = regions,
                        unit_info = get_unit_info(units))

    # --- Offers -------------------------------------------------------------
    vb, pb = get_processed_bids(units)
    set_unit_volume_bids!(market, vb)
    set_unit_price_bids!(market, pb)

    # --- Unit-level capability ----------------------------------------------
    set_unit_bid_capacity_constraints!(market, get_unit_bid_availability(units);
                                       violation_cost = cvp["unit_capacity"])
    set_unconstrained_intermittent_generation_forecast_constraint!(
        market, get_unit_uigf_limits(units); violation_cost = cvp["uigf"])

    profiles = fast_start ? get_fast_start_profiles_for_dispatch(units) : DataFrame()
    set_unit_ramp_rate_constraints!(market, get_bid_ramp_rates(units),
                                    get_scada_ramp_rates(units);
                                    fast_start_profiles = profiles,
                                    run_type = "fast_start_first_run",
                                    violation_cost = cvp["ramp_rate"])

    # --- FCAS ---------------------------------------------------------------
    # Mutates `units`; every FCAS getter below reads what it produces.
    add_fcas_trapezium_constraints!(units)
    set_fcas_max_availability!(market, get_fcas_max_availability(units);
                               violation_cost = cvp["fcas_max_avail"])
    set_energy_and_regulation_capacity_constraints!(
        market, get_fcas_regulation_trapeziums(units);
        violation_cost = cvp["fcas_profile"])
    set_joint_ramping_constraints_reg!(
        market, get_scada_ramp_rates(units; include_initial_output = true);
        fast_start_profiles = profiles, run_type = "fast_start_first_run",
        violation_cost = cvp["fcas_profile"])
    set_joint_capacity_constraints!(market, get_contingency_services(units);
                                    violation_cost = cvp["fcas_profile"])

    # --- Network ------------------------------------------------------------
    set_interconnectors!(market, get_interconnector_definitions(interconnectors))
    losses, breakpoints = get_interconnector_loss_model(interconnectors)
    set_interconnector_losses!(market, losses, breakpoints)

    generic, unit_lhs, interconnector_lhs, region_lhs =
        get_generic_constraints(constraints)
    set_generic_constraints!(market, generic;
                             violation_cost = get_violation_costs(constraints))
    link_units_to_generic_constraints!(market, unit_lhs)
    link_interconnectors_to_generic_constraints!(market, interconnector_lhs)
    link_regions_to_generic_constraints!(market, region_lhs)

    # --- Balance and tie-break ----------------------------------------------
    set_demand_constraints!(market, get_operational_demand(demand);
                            violation_cost = cvp["regional_demand"])
    set_tie_break_constraints!(market, cvp["tiebreak"])

    return market, MarketInputs(units, demand, interconnectors, constraints, cvp)
end

"""
    dispatch_interval!(loader; regions = DEFAULT_REGIONS, fast_start = true,
                       over_constrained_rerun = :auto,
                       energy_market_floor_price = -1000.0,
                       fcas_market_ceiling_price = 1000.0)
        -> (market::SpotMarket, inputs::MarketInputs)

Assemble and fully solve one dispatch interval, including both fast-start passes
and the over-constrained-dispatch (OCD) re-run.

This is the function a caller wants unless it needs to intervene between the
passes; [`build_spot_market`](@ref) plus manual `dispatch!` calls is the escape
hatch for that case.

# Arguments
- `loader::RawInputsLoader`: positioned on the interval via [`set_interval!`](@ref).

# Keywords
- `regions::Vector{String} = DEFAULT_REGIONS`: market regions to model.
- `fast_start::Bool = true`: run the two-pass fast-start procedure. The first
  pass solves without inflexibility profiles applied to their end modes; the
  result classifies each fast-start unit, and the second pass re-imposes ramp
  and joint-ramping constraints under `"fast_start_second_run"`. Setting this
  to `false` solves a single pass and is *not* benchmark-valid for intervals
  with a starting fast-start unit — it exists for speed in tests.
- `over_constrained_rerun::Union{Symbol,Bool} = :auto`: whether to re-price
  under the OCD rule. `:auto` follows the case file's own flag via
  [`is_over_constrained_dispatch_rerun`](@ref), which is what the market engine
  does; `true`/`false` force it either way.
- `energy_market_floor_price::Real = -1000.0`: market floor used by the OCD
  re-price.
- `fcas_market_ceiling_price::Real = 1000.0`: FCAS ceiling used by the OCD
  re-price. The energy ceiling is taken from the case file's own value of
  VoLL (`cvp["voll"]`) rather than hard-coded, so a market price cap that
  changes between financial years is picked up from the data.

# Returns
The solved market and its inputs.
"""
function dispatch_interval!(loader::RawInputsLoader;
                            regions::Vector{String} = DEFAULT_REGIONS,
                            fast_start::Bool = true,
                            over_constrained_rerun::Union{Symbol,Bool} = :auto,
                            energy_market_floor_price::Real = -1000.0,
                            fcas_market_ceiling_price::Real = 1000.0)
    market, inputs = build_spot_market(loader; regions = regions,
                                       fast_start = fast_start)
    cvp = inputs.cvp

    # --- Pass 1: unconstrained by fast-start end modes -----------------------
    dispatch!(market)

    # --- Pass 2: re-impose fast-start profiles classified from pass 1 --------
    if fast_start
        profiles = get_fast_start_profiles_for_dispatch(
            inputs.units; unconstrained_dispatch = get_unit_dispatch(market))
        if !isempty(profiles)
            set_fast_start_constraints!(
                market,
                profiles[:, [:unit, :end_mode, :time_in_end_mode, :mode_two_length,
                             :mode_four_length, :min_loading]];
                violation_cost = cvp["fast_start"])
            second = profiles[:, [:unit, :end_mode, :time_since_end_of_mode_two,
                                  :min_loading]]
            set_unit_ramp_rate_constraints!(market, get_bid_ramp_rates(inputs.units),
                                            get_scada_ramp_rates(inputs.units);
                                            fast_start_profiles = second,
                                            run_type = "fast_start_second_run",
                                            violation_cost = cvp["ramp_rate"])
            set_joint_ramping_constraints_reg!(
                market,
                get_scada_ramp_rates(inputs.units; include_initial_output = true);
                fast_start_profiles = second, run_type = "fast_start_second_run",
                violation_cost = cvp["fcas_profile"])
        end
    end

    # --- Final solve, with or without the OCD re-price ----------------------
    rerun = over_constrained_rerun === :auto ?
            is_over_constrained_dispatch_rerun(inputs.constraints) :
            Bool(over_constrained_rerun)
    if rerun
        dispatch!(market; allow_over_constrained_dispatch_re_run = true,
                  energy_market_floor_price = energy_market_floor_price,
                  energy_market_ceiling_price = cvp["voll"],
                  fcas_market_ceiling_price = fcas_market_ceiling_price)
    else
        dispatch!(market)
    end

    return market, inputs
end
