# =============================================================================
# dispatch.jl
#
# `dispatch!`: assemble the JuMP model from the stored inputs and solve it.
#
# Split out of the single-file `spot_market.jl` of the reference
# implementation. The code is unchanged; only its location is. All of these
# files are `include`d into the same `ZBenchmark` module, so definition order
# across them does not matter.
# =============================================================================

# ===========================================================================
# dispatch! — assemble the JuMP model from stored inputs and solve it.
# ===========================================================================
"""
    dispatch!(m::SpotMarket; allow_over_constrained_dispatch_re_run=false, kwargs...)

Build the LP from all inputs set so far, solve with HiGHS, and store dispatch
quantities and regional energy prices (the demand-constraint duals). With
`allow_over_constrained_dispatch_re_run=true` the OCD rerun is replicated: if a
recovered price violates the market ceiling/floor AND a generic constraint is
violated, the violated constraints' RHS are relaxed by (violation + 0.01) and
the LP is re-priced — exactly nempy's procedure (no price clamping).
"""
function dispatch!(m::SpotMarket; allow_over_constrained_dispatch_re_run::Bool=false,
                   energy_market_floor_price::Real=-1000.0,
                   energy_market_ceiling_price::Real=17500.0,
                   fcas_market_ceiling_price::Real=1000.0,
                   sos2_losses::Bool=false, binary_losses::Bool=false)
    # Loss-interpolation adjacency: nempy always solves a MIP with SOS2 sets on
    # the loss weights (and SOS1 on MNSP link pairs). The convex-combination LP
    # relaxation is NOT tight when a region's price goes NEGATIVE — the
    # optimiser then profits from fabricating extra interconnector losses by
    # mixing non-adjacent breakpoints (this is what set SA1 to -100 instead of
    # -110.74 on 2024-07-26 13:45). A full MIP is slow, so we solve the LP and
    # then LAZILY add segment-selection binaries only for links whose weights
    # came back non-adjacent (or MNSP pairs flowing simultaneously), re-solving
    # until clean — usually zero or one tiny MIP. Prices come from the final
    # model with any binaries fixed (nempy's linearised pricing run).
    model = Model(SOLVER_FACTORY[])
    set_silent(model)
    empty!(m.generic_con_refs)

    # --- Decision variables for each (unit, dispatch_type, service, band) ----
    units_key(r) = (string(r.unit),
                    ("dispatch_type" in names(parent(r))) ? string(r.dispatch_type) : "generator",
                    string(r.service))
    vol_lookup = Dict{Tuple{String,String,String},Vector{Float64}}()
    price_lookup = Dict{Tuple{String,String,String},Vector{Float64}}()
    for r in eachrow(m.volume_bids)
        vol_lookup[units_key(r)] = Float64[coalesce(r[c], 0.0) for c in BAND_COLS]
    end
    for r in eachrow(m.price_bids)
        price_lookup[units_key(r)] = Float64[coalesce(r[c], 0.0) for c in BAND_COLS]
    end

    # Loss factors for referring energy bid costs to the regional node —
    # (see ZONAL_MLF_KEEP_SCALING for the one case in which this is skipped)
    # nempy: cost = (load_flip(price)) / loss_factor. The incoming price bids
    # are the XML prices multiplied by the loss factor (see get_processed_bids),
    # so this reproduces nempy's objective coefficients bit-for-bit.
    lf = Dict{Tuple{String,String},Float64}()
    if "loss_factor" in names(m.unit_info)
        for r in eachrow(m.unit_info)
            dt = ("dispatch_type" in names(m.unit_info)) ? string(r.dispatch_type) : "generator"
            lf[(string(r.unit), dt)] = coalesce(_num(r.loss_factor), 1.0)
        end
    end

    x = Dict{Tuple{String,String,String,Int},VariableRef}()
    xcost = Dict{Tuple{String,String,String,Int},Float64}()
    D = Dict{Tuple{String,String,String},AffExpr}()
    obj = AffExpr(0.0)
    for (key, vols) in vol_lookup
        u, dt, s = key
        prices = get(price_lookup, key, zeros(N_BANDS))
        # A load's energy bid is willingness-to-PAY: it enters the
        # cost-minimising objective negated (mirrors objective_function.bids).
        dir = (s == "energy" && dt == "load") ? -1.0 : 1.0
        λ = get(lf, (u, dt), 1.0)
        expr = AffExpr(0.0)
        for b in 1:N_BANDS
            vb = vols[b]
            vb < 0.0001 && continue           # nempy drops bands < 0.0001 MW
            v = @variable(model, lower_bound = 0.0, upper_bound = vb)
            x[(u, dt, s, b)] = v
            add_to_expression!(expr, v)
            # ZONAL_MLF_KEEP_SCALING: when set, the `/ λ` referral is SKIPPED,
            # leaving the connection-point-scaled bid stack that
            # get_processed_bids produced. Default `false` reproduces the
            # validated benchmark exactly; the flag exists solely to build the
            # MLF-scaled reference series the nodal study is measured against
            # (see network/scripts/run_network_day.jl) and must never be set
            # when the benchmark itself is being run.
            cost = if s == "energy"
                ZONAL_MLF_KEEP_SCALING[] ? (dir * prices[b]) : (dir * prices[b]) / λ
            else
                dir * prices[b]
            end
            xcost[(u, dt, s, b)] = cost
            add_to_expression!(obj, cost, v)
        end
        D[key] = expr
    end

    Dget(u, dt, s) = get(D, (u, dt, s), AffExpr(0.0))
    hasD(u, dt, s) = haskey(D, (u, dt, s))

    # Unit-level ENERGY expression with nempy's sign convention: -1 for the
    # load side of BDUs, +1 otherwise.
    function Eunit(u, dt)
        sgn = (dt == "load" && u in m.bdu_units) ? -1.0 : 1.0
        return sgn * Dget(u, dt, "energy")
    end
    # Net energy of a unit across both directions (gen - load for BDUs).
    Enet(u) = Dget(u, "generator", "energy") - Dget(u, "load", "energy")

    # --- Soft-constraint slack helper ---------------------------------------
    function slack(cost)
        sv = @variable(model, lower_bound = 0.0)
        add_to_expression!(obj, cost, sv)
        return sv
    end

    # --- Per-region energy balance -------------------------------------------
    # Regional convention: generators +, ALL loads -, interconnector injections.
    region_balance = Dict{String,AffExpr}(r => AffExpr(0.0) for r in m.regions)
    for (key, expr) in D
        u, dt, s = key
        s == "energy" || continue
        reg = get(m.unit_region, u, "")
        haskey(region_balance, reg) || continue
        add_to_expression!(region_balance[reg], dt == "load" ? -1.0 : 1.0, expr)
    end

    # --- Interconnectors with per-link piecewise-linear losses ---------------
    # (loss_links stashed on m.loss_link_refs after construction for diagnostics)
    flow_vars, loss_links = _add_interconnectors!(model, m, region_balance, obj;
                                      sos2_losses=sos2_losses, binary_losses=binary_losses)
    empty!(m.loss_link_refs); append!(m.loss_link_refs, loss_links)

    # --- Demand equality constraints (their duals are the energy prices) -----
    demand_con = Dict{String,ConstraintRef}()
    demand_map = Dict(string(r.region) => r.demand for r in eachrow(m.demand))
    for reg in m.regions
        d = get(demand_map, reg, 0.0)
        deficit = slack(m.demand_cost)      # not enough generation
        surplus = slack(m.demand_cost)      # too much generation
        con = @constraint(model, region_balance[reg] + deficit - surplus == d)
        demand_con[reg] = con
    end

    # --- Unit bid capacity limits (per unit-direction, unit-level signs) -----
    for r in eachrow(m.capacities)
        u = string(r.unit)
        dt = ("dispatch_type" in names(m.capacities)) ? string(r.dispatch_type) : "generator"
        cap = coalesce(_num(r.capacity), 0.0)
        hasD(u, dt, "energy") || continue
        # BID AVAILABILITY caps CONSUMPTION for load-side offers: the unit-level
        # sign convention (Eunit = -E_load for BDUs) would make the load-side
        # constraint "-E_load <= cap" — vacuously true — letting a BDU with zero
        # energy availability charge freely (Sept-2025: SNB01/MREHA1 charged
        # 250/100 MW that NEMDE held at 0, over-pricing every region). NEMDE
        # bounds the BDU energy target in [-LoadAvail, +GenAvail], so apply the
        # cap to the RAW dispatch of the offer's own direction.
        @constraint(model, Dget(u, dt, "energy") - slack(m.capacity_cost) <= cap)
    end

    # --- UIGF limits (semi-scheduled wind/solar; generator side) -------------
    for r in eachrow(m.uigf)
        u = string(r.unit); cap = coalesce(_num(r.capacity), 0.0)
        hasD(u, "generator", "energy") || continue
        @constraint(model, Dget(u, "generator", "energy") - slack(m.uigf_cost) <= cap)
    end

    # --- Ramp-rate limits -----------------------------------------------------
    _add_ramp_constraints!(model, m, Dget, hasD, Enet, slack)

    # --- FCAS max-availability caps -------------------------------------------
    for r in eachrow(m.fcas_maxavail)
        u = string(r.unit); s = string(r.service)
        dt = ("dispatch_type" in names(m.fcas_maxavail)) ? string(r.dispatch_type) : "generator"
        cap = coalesce(_num(r.max_availability), 0.0)
        hasD(u, dt, s) || continue
        @constraint(model, Dget(u, dt, s) - slack(m.fcas_maxavail_cost) <= cap)
    end

    # --- FCAS trapezium constraints (regulation + contingency) ---------------
    _add_regulation_trapeziums!(model, m, Dget, hasD, Eunit, slack)
    _add_joint_capacity!(model, m, Dget, hasD, Eunit, slack)

    # --- Joint ramping constraints for regulation -----------------------------
    _add_joint_ramping!(model, m, Dget, hasD, Eunit, Enet, slack)

    # --- Fast-start dispatch inflexibility profiles ---------------------------
    _add_fast_start_constraints!(model, m, Eunit, slack)

    # --- Regional FCAS requirement constraints --------------------------------
    _add_fcas_requirements!(model, m, D, slack)

    # --- Generic (network / security / FCAS-requirement) constraints ---------
    _add_generic_constraints!(model, m, D, flow_vars, slack)

    # --- Tie-break constraints (nempy's set_tie_break_constraints) ------------
    _add_tie_break_constraints!(model, m, x, xcost, vol_lookup, slack)

    # --- Solve -----------------------------------------------------------------
    @objective(model, Min, obj)
    optimize!(model)
    # Lazily enforce SOS2 adjacency / SOS1 link exclusivity where the LP
    # relaxation exploited them (negative-price loss fabrication).
    sos_cons, sos_lams = _tighten_loss_interpolation!(model, m, loss_links, obj)
    # A MILP has no duals: fix integers/SOS2 supports at their optima and
    # re-solve the LP.
    _reprice_if_mip!(model, sos_cons, sos_lams)
    # Dual-degeneracy resolution for DIRECTED units (NEMDE convention): see
    # _relax_directed_unit_constraints_for_pricing!.
    _relax_directed_unit_constraints_for_pricing!(model, m)
    # NOTE: the CVP-priority FCAS dual refinement is deliberately NOT called
    # here. It was falsified by a 1 000-interval sweep (see
    # `_refine_fcas_duals_by_cvp!`); it remains available as a diagnostic only.
    empty!(m.fcas_dual_override)
    m.model = model

    empty!(m.demand_con_refs); merge!(m.demand_con_refs, demand_con)
    _collect_results!(m, D, demand_con)

    # --- Over-constrained-dispatch (OCD) rerun --------------------------------
    if allow_over_constrained_dispatch_re_run
        _ocd_re_run!(model, m, D, demand_con;
                     floor=float(energy_market_floor_price),
                     ceiling=float(energy_market_ceiling_price),
                     fcas_ceiling=float(fcas_market_ceiling_price))
    end
    return m
end
