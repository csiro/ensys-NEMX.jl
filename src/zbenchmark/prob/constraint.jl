# =============================================================================
# constraint.jl (LP constraint builders)
#
# Constraint builders called by `dispatch!` (ramp, FCAS trapeziums, joint
# capacity and ramping, fast start, generic/SPD constraints, tie-breaks and the
# interconnector loss interpolation).
#
# Split out of the single-file `spot_market.jl` of the reference
# implementation. The code is unchanged; only its location is. All of these
# files are `include`d into the same `ZBenchmark` module, so definition order
# across them does not matter.
# =============================================================================

# --- Ramp-rate constraints ---------------------------------------------------
# Mirrors nempy's set_unit_ramp_rate_constraints + ramp_rate_processing:
#   1. composite ramp rates for BDUs (net gen-load movement)
#   2. lesser of bid and SCADA ramp rates (NaN-tolerant fmin)
#   3. fast-start adjustments by run type
function _add_ramp_constraints!(model, m::SpotMarket, Dget, hasD, Enet, slack)
    m.ramp_bid === nothing && return
    isempty(m.ramp_bid) && return
    bid = copy(m.ramp_bid)
    ("dispatch_type" in names(bid)) || (bid.dispatch_type = fill("generator", nrow(bid)))

    scada = Dict{String,Tuple{Union{Missing,Float64},Union{Missing,Float64}}}()
    if m.ramp_scada !== nothing
        for r in eachrow(m.ramp_scada)
            scada[string(r.unit)] = (_num(r.scada_ramp_up_rate), _num(r.scada_ramp_down_rate))
        end
    end
    fmin(a, b) = ismissing(b) ? a : (ismissing(a) ? b : min(a, b))

    # Fast-start exclusions.
    excluded = Set{String}()
    adjust_up = Dict{String,Tuple{Float64,Float64}}()   # unit -> (tsem2, min_loading)
    if m.ramp_fsp !== nothing && !isempty(m.ramp_fsp)
        fsp = m.ramp_fsp
        if m.ramp_run_type == "fast_start_first_run"
            for r in eachrow(fsp)
                Int(r.current_mode) in (0, 1, 2) && push!(excluded, string(r.unit))
            end
        elseif m.ramp_run_type == "fast_start_second_run"
            for r in eachrow(fsp)
                Int(r.end_mode) in (0, 1, 2) && push!(excluded, string(r.unit))
                if ("time_since_end_of_mode_two" in names(fsp)) &&
                   !ismissing(r.time_since_end_of_mode_two)
                    adjust_up[string(r.unit)] = (float(r.time_since_end_of_mode_two),
                                                 coalesce(_num(r.min_loading), 0.0))
                end
            end
        end
    end

    # Split BDUs out for composite treatment.
    bdurows = Dict{String,Dict{String,NamedTuple}}()
    for r in eachrow(bid)
        u = string(r.unit)
        u in m.bdu_units || continue
        d = get!(bdurows, u, Dict{String,NamedTuple}())
        d[string(r.dispatch_type)] = (up=coalesce(_num(r.ramp_up_rate), Inf),
                                      dn=coalesce(_num(r.ramp_down_rate), Inf),
                                      init=coalesce(_num(r.initial_output), 0.0))
    end

    for r in eachrow(bid)
        u = string(r.unit)
        u in m.bdu_units && continue          # handled by composite constraints
        u in excluded && continue
        dt = string(r.dispatch_type)
        hasD(u, dt, "energy") || continue
        init = _num(r.initial_output); ismissing(init) && continue
        up = coalesce(_num(r.ramp_up_rate), missing)
        dn = coalesce(_num(r.ramp_down_rate), missing)
        s = get(scada, u, (missing, missing))
        up = fmin(up, s[1]); dn = fmin(dn, s[2])
        if haskey(adjust_up, u) && !ismissing(up)
            tsem2, minload = adjust_up[u]
            ramp_max = tsem2 * (up / 60.0) + minload
            up = (ramp_max - init) * (60.0 / 5.0)
        end
        E = Dget(u, dt, "energy")
        if !ismissing(up) && isfinite(up)
            @constraint(model, E - slack(m.ramp_cost) <= init + up * INTERVAL_HOURS)
        end
        if !ismissing(dn) && isfinite(dn)
            @constraint(model, E + slack(m.ramp_cost) >= init - dn * INTERVAL_HOURS)
        end
    end

    # Composite BDU ramp constraints on the NET output (gen - load).
    for (u, d) in bdurows
        u in excluded && continue
        (haskey(d, "generator") && haskey(d, "load")) || continue
        g = d["generator"]; l = d["load"]
        init = g.init          # same INITIALMW both sides (signed net MW)
        h = INTERVAL_HOURS
        # Composite up: leaving charging territory is limited by the LOAD side's
        # ramp-DOWN rate until output crosses zero (nempy's exact formula).
        up = if init >= 0.0
            g.up
        elseif l.dn == 0.0
            0.0
        elseif abs(init / l.dn) >= h
            l.dn
        else
            t_after = h - abs(init / l.dn)
            (t_after * g.up - init) / h
        end
        dn = if init <= 0.0
            l.up
        elseif g.dn == 0.0
            0.0
        elseif abs(init / g.dn) >= h
            g.dn
        else
            t_after = h - abs(init / g.dn)
            (t_after * l.up + init) / h
        end
        s = get(scada, u, (missing, missing))
        up = fmin(up, s[1]); dn = fmin(dn, s[2])
        E = Enet(u)
        if !ismissing(up) && isfinite(up)
            @constraint(model, E - slack(m.ramp_cost) <= init + up * INTERVAL_HOURS)
        end
        if !ismissing(dn) && isfinite(dn)
            @constraint(model, E + slack(m.ramp_cost) >= init - dn * INTERVAL_HOURS)
        end
    end
end

# --- Regulation trapeziums (FCAS MODEL IN NEMDE section 6.3) ------------------
# BOTH slopes for every regulation trapezium (nempy adds upper AND lower):
#   upper:  E + upper_slope*R <= EnablementMax
#   lower:  E - lower_slope*R >= EnablementMin
function _add_regulation_trapeziums!(model, m::SpotMarket, Dget, hasD, Eunit, slack)
    isempty(m.reg_trapeziums) && return
    for r in eachrow(m.reg_trapeziums)
        u = string(r.unit); s = string(r.service)
        dt = ("dispatch_type" in names(m.reg_trapeziums)) ? string(r.dispatch_type) : "generator"
        maxa = coalesce(_num(r.max_availability), 0.0)
        maxa <= 0 && continue
        hasD(u, dt, s) || continue
        emin = coalesce(_num(r.enablement_min), 0.0)
        emax = coalesce(_num(r.enablement_max), 0.0)
        lbp  = coalesce(_num(r.low_break_point), 0.0)
        hbp  = coalesce(_num(r.high_break_point), 0.0)
        upper_slope = (emax - hbp) / maxa
        lower_slope = (lbp - emin) / maxa
        E = Eunit(u, dt); R = Dget(u, dt, s)
        @constraint(model, E + upper_slope * R - slack(m.fcas_profile_cost) <= emax)
        @constraint(model, E - lower_slope * R + slack(m.fcas_profile_cost) >= emin)
    end
end

"""
    BDU_CROSS_SIDE_REG_LOWER_SUBTRACT

Sign of the *cross-side* regulation term in the contingency joint-capacity
LOWER constraint of a bidirectional unit (BDU).

A BDU bids energy on both a generator and a load side, and may bid the
regulation services on the side opposite to the contingency trapezium being
constrained. nempy adds that cross-side term with `+1`, which RELAXES the lower
constraint. NEMDE subtracts it: a lower service bid on *either* side consumes
the same downward headroom between the net energy target and `EnablementMin`.

Validated against the NEMDE case files themselves (120 intervals, 1 532
BDU lower/raise trapezium checks). Evaluating both signs on NEMDE's own
published `TraderSolution` targets:

| slope | sign            | violations | exactly binding |
|-------|-----------------|-----------:|----------------:|
| lower | `-1` (NEMDE)    |          0 |             381 |
| lower | `+1` (nempy)    |          0 |               0 |
| raise | `+1` (both)     |          0 |             221 |
| raise | `-1`            |          0 |               0 |

A constraint that is *exactly* binding in NEMDE's own solution is one NEMDE
enforced; the `+1` form is strictly weaker and never binds, so it cannot be the
constraint NEMDE solved. The raise slope is unaffected — our existing `+1`
there is already the binding form.

Worked example, WANDB1 at 2025-09-02 11:35 (net energy -25 MW, `EnablementMin`
-75 MW): NEMDE sets `lower_5min = 20` and `lower_reg = 30` (load side), giving
`-25 - 20 - 30 = -75`, exactly `EnablementMin`. With the `+1` sign the model
instead reaches `lower_5min = 44` (the unit's full `MaxAvail`), 24 MW of
too-cheap Queensland lower supply. Because Queensland's lower family is written
on QNI flow (`F_Q++BCDM_L5/_L6/_L60`, see below), that surplus displaced 4.67 MW
of QNI flow and moved the marginal lower-service provider, which is what
depressed the published Queensland lower prices.

`true` (default) reproduces NEMDE. Set to `false` to restore the legacy nempy
sign — required to keep the July-2024 benchmark bit-identical.
"""
const BDU_CROSS_SIDE_REG_LOWER_SUBTRACT = Ref(true)

# --- Contingency joint-capacity (FCAS MODEL IN NEMDE section 6.2) -------------
# Two constraints per contingency trapezium, WITH the regulation coupling terms
# (and the BDU load-side extensions) exactly as nempy builds them:
#   upper:  E [+E_load(BDU)] + upper_slope*C + R_up [+R_up_load(BDU)] <= emax
#   lower:  E [+E_load(BDU)] - lower_slope*C - R_dn [+R_dn_load(BDU)] >= emin
# where for a generator-tagged trapezium R_up = raise_reg and R_dn = lower_reg
# (flipped for load-tagged trapeziums). The BDU load-side energy terms enter
# through the unit-level sign convention (i.e. as -D_load).
function _add_joint_capacity!(model, m::SpotMarket, Dget, hasD, Eunit, slack)
    isempty(m.cont_trapeziums) && return
    for r in eachrow(m.cont_trapeziums)
        u = string(r.unit); s = string(r.service)
        dt = ("dispatch_type" in names(m.cont_trapeziums)) ? string(r.dispatch_type) : "generator"
        maxa = coalesce(_num(r.max_availability), 0.0)
        maxa <= 0 && continue
        hasD(u, dt, s) || continue
        emin = coalesce(_num(r.enablement_min), 0.0)
        emax = coalesce(_num(r.enablement_max), 0.0)
        lbp  = coalesce(_num(r.low_break_point), 0.0)
        hbp  = coalesce(_num(r.high_break_point), 0.0)
        upper_slope = (emax - hbp) / maxa
        lower_slope = (lbp - emin) / maxa
        C = Dget(u, dt, s)
        is_bdu = u in m.bdu_units
        other = dt == "generator" ? "load" : "generator"

        E = Eunit(u, dt)
        is_bdu && hasD(u, other, "energy") && (E = E + Eunit(u, other))

        r_up = dt == "generator" ? "raise_reg" : "lower_reg"
        r_dn = dt == "generator" ? "lower_reg" : "raise_reg"

        up_expr = E + upper_slope * C
        hasD(u, dt, r_up) && (up_expr += Dget(u, dt, r_up))
        # BDU: the load-side counterpart of the SAME reg service, coefficient +1.
        is_bdu && hasD(u, other, r_up) && (up_expr += Dget(u, other, r_up))
        @constraint(model, up_expr - slack(m.fcas_profile_cost) <= emax)

        dn_expr = E - lower_slope * C
        hasD(u, dt, r_dn) && (dn_expr -= Dget(u, dt, r_dn))
        # BDU cross-side regulation term on the LOWER slope. See
        # BDU_CROSS_SIDE_REG_LOWER_SUBTRACT above: nempy adds this term (+1),
        # which relaxes the constraint; NEMDE subtracts it (-1), because a
        # lower service bid on either side of a bidirectional unit consumes the
        # SAME downward headroom between the net energy target and EnablementMin.
        if is_bdu && hasD(u, other, r_dn)
            dn_expr += (BDU_CROSS_SIDE_REG_LOWER_SUBTRACT[] ? -1.0 : 1.0) * Dget(u, other, r_dn)
        end
        @constraint(model, dn_expr + slack(m.fcas_profile_cost) >= emin)
    end
end

# --- Joint ramping for regulation (FCAS MODEL IN NEMDE section 6.1) -----------
# Only units that BID the regulation service get the constraints:
#   generator raise: E + R_raise <= init + scada_up*(5/60)
#   generator lower: E - R_lower >= init - scada_down*(5/60)
#   load raise:      E - R_raise >= init - scada_up*(5/60)
#   load lower:      E + R_lower <= init + scada_down*(5/60)
#   BDU raise:       E_net + sum(R_raise) <= init + scada_up*(5/60)
#   BDU lower:       E_net - sum(R_lower) >= init - scada_down*(5/60)
function _add_joint_ramping!(model, m::SpotMarket, Dget, hasD, Eunit, Enet, slack)
    m.joint_ramp === nothing && return
    isempty(m.joint_ramp) && return
    scada = Dict{String,NamedTuple}()
    for r in eachrow(m.joint_ramp)
        scada[string(r.unit)] = (up=_num(r.scada_ramp_up_rate),
                                 dn=_num(r.scada_ramp_down_rate),
                                 init=_num(r.initial_output))
    end
    # Fast-start adjustments (same rules as the energy ramp constraints).
    excluded = Set{String}()
    adjust_up = Dict{String,Tuple{Float64,Float64}}()
    if m.joint_ramp_fsp !== nothing && !isempty(m.joint_ramp_fsp)
        fsp = m.joint_ramp_fsp
        if m.joint_ramp_run_type == "fast_start_first_run"
            for r in eachrow(fsp)
                Int(r.current_mode) in (0, 1, 2) && push!(excluded, string(r.unit))
            end
        elseif m.joint_ramp_run_type == "fast_start_second_run"
            for r in eachrow(fsp)
                Int(r.end_mode) in (0, 1, 2) && push!(excluded, string(r.unit))
                if ("time_since_end_of_mode_two" in names(fsp)) &&
                   !ismissing(r.time_since_end_of_mode_two)
                    adjust_up[string(r.unit)] = (float(r.time_since_end_of_mode_two),
                                                 coalesce(_num(r.min_loading), 0.0))
                end
            end
        end
    end

    # Units bidding each reg service, per direction.
    raise_units = Set{Tuple{String,String}}()
    lower_units = Set{Tuple{String,String}}()
    for r in eachrow(m.volume_bids)
        dt = ("dispatch_type" in names(m.volume_bids)) ? string(r.dispatch_type) : "generator"
        if string(r.service) == "raise_reg"
            any(coalesce(r[c], 0.0) >= 0.0001 for c in BAND_COLS) &&
                push!(raise_units, (string(r.unit), dt))
        elseif string(r.service) == "lower_reg"
            any(coalesce(r[c], 0.0) >= 0.0001 for c in BAND_COLS) &&
                push!(lower_units, (string(r.unit), dt))
        end
    end

    effective_up(u, s) = begin
        up = s.up
        if haskey(adjust_up, u) && !ismissing(up) && !ismissing(s.init)
            tsem2, minload = adjust_up[u]
            ramp_max = tsem2 * (up / 60.0) + minload
            up = (ramp_max - s.init) * (60.0 / 5.0)
        end
        up
    end

    done_bdu_raise = Set{String}(); done_bdu_lower = Set{String}()
    for (u, dt) in raise_units
        u in excluded && continue
        s = get(scada, u, nothing); s === nothing && continue
        (ismissing(s.init) || ismissing(s.up)) && continue
        hasD(u, dt, "raise_reg") || continue
        up = effective_up(u, s)
        rhs_up = s.init + up * INTERVAL_HOURS
        rhs_dn = s.init - up * INTERVAL_HOURS
        if u in m.bdu_units
            u in done_bdu_raise && continue
            push!(done_bdu_raise, u)
            R = Dget(u, "generator", "raise_reg") + Dget(u, "load", "raise_reg")
            @constraint(model, Enet(u) + R - slack(m.fcas_profile_cost) <= rhs_up)
        elseif dt == "generator"
            @constraint(model, Dget(u, dt, "energy") + Dget(u, dt, "raise_reg") -
                               slack(m.fcas_profile_cost) <= rhs_up)
        else
            @constraint(model, Dget(u, dt, "energy") - Dget(u, dt, "raise_reg") +
                               slack(m.fcas_profile_cost) >= rhs_dn)
        end
    end
    for (u, dt) in lower_units
        u in excluded && continue
        s = get(scada, u, nothing); s === nothing && continue
        (ismissing(s.init) || ismissing(s.dn)) && continue
        hasD(u, dt, "lower_reg") || continue
        rhs_dn = s.init - s.dn * INTERVAL_HOURS
        rhs_up = s.init + s.dn * INTERVAL_HOURS
        if u in m.bdu_units
            u in done_bdu_lower && continue
            push!(done_bdu_lower, u)
            R = Dget(u, "generator", "lower_reg") + Dget(u, "load", "lower_reg")
            @constraint(model, Enet(u) - R + slack(m.fcas_profile_cost) >= rhs_dn)
        elseif dt == "generator"
            @constraint(model, Dget(u, dt, "energy") - Dget(u, dt, "lower_reg") +
                               slack(m.fcas_profile_cost) >= rhs_dn)
        else
            @constraint(model, Dget(u, dt, "energy") + Dget(u, dt, "lower_reg") -
                               slack(m.fcas_profile_cost) <= rhs_up)
        end
    end
end

# --- Fast-start dispatch inflexibility profiles --------------------------------
# end_mode 0/1: E <= 0;  end_mode 2: E == target;  end_mode 3: E >= min_loading;
# end_mode 4: E >= target. All elastic at the fast_start violation price.
function _add_fast_start_constraints!(model, m::SpotMarket, Eunit, slack)
    m.fast_start === nothing && return
    isempty(m.fast_start) && return
    for r in eachrow(m.fast_start)
        u = string(r.unit)
        em = Int(r.end_mode)
        # Fast-start inflexibility applies to the unit's dispatch MAGNITUDE in
        # its own direction: generators use the generation-side variable, and
        # load-side fast-start units (pumped-hydro pumps) use the load-side
        # variable, which is positive for consumption. Applying only to the
        # generator side left pumps entirely unconstrained (they could pump at
        # will while NEMDE held them in their startup profile).
        E = Eunit(u, "generator")
        if E isa AffExpr && isempty(E.terms)
            E = Eunit(u, "load")
        end
        (E isa AffExpr && isempty(E.terms)) && continue
        if em in (0, 1)
            @constraint(model, E - slack(m.fast_start_cost) <= 0.0)
        elseif em == 2
            float(r.mode_two_length) > 0.0 || continue     # avoid 0/0 targets
            target = (float(r.time_in_end_mode) / float(r.mode_two_length)) *
                     coalesce(_num(r.min_loading), 0.0)
            @constraint(model, E + slack(m.fast_start_cost) >= target)
            @constraint(model, E - slack(m.fast_start_cost) <= target)
        elseif em == 3
            @constraint(model, E + slack(m.fast_start_cost) >=
                               coalesce(_num(r.min_loading), 0.0))
        elseif em == 4
            # T4 == 0 means no mode-4 taper: the unit is already past its
            # inflexibility profile, so no minimum applies (0/0 otherwise).
            float(r.mode_four_length) > 0.0 || continue
            minload = coalesce(_num(r.min_loading), 0.0)
            target = minload - (float(r.time_in_end_mode) / float(r.mode_four_length)) * minload
            @constraint(model, E + slack(m.fast_start_cost) >= target)
        end
    end
end

# --- Regional FCAS requirement constraints ------------------------------------
function _add_fcas_requirements!(model, m::SpotMarket, D, slack)
    isempty(m.fcas_requirements) && return
    for r in eachrow(m.fcas_requirements)
        s = string(r.service); reg = string(r.region)
        vol = coalesce(_num(r.volume), 0.0)
        s == "" && continue
        total = AffExpr(0.0)
        for (key, expr) in D
            u, dt, svc = key
            svc == s || continue
            (reg == "" || get(m.unit_region, u, "") == reg) || continue
            add_to_expression!(total, 1.0, expr)
        end
        sense = (:type in propertynames(r)) ? string(r.type) : ">="
        if sense == "<="
            @constraint(model, total - slack(m.fcas_req_cost) <= vol)
        else
            @constraint(model, total + slack(m.fcas_req_cost) >= vol)
        end
    end
end

# --- Generic (network / security / FCAS-requirement) constraints ---------------
# Unit terms use the UNIT-LEVEL sign convention (BDU load energy enters as -D);
# region terms use the REGIONAL convention (ALL load energy -1, FCAS +1).
function _add_generic_constraints!(model, m::SpotMarket, D, flow_vars, slack)
    isempty(m.generic_rhs) && return
    unit_by_set   = _group_factors(m.generic_unit_lhs, :set)
    interc_by_set = _group_factors(m.generic_interc_lhs, :set)
    region_by_set = _group_factors(m.generic_region_lhs, :set)

    # (region, service) -> expression with regional signs.
    region_service = Dict{Tuple{String,String},AffExpr}()
    for (key, expr) in D
        u, dt, s = key
        reg = get(m.unit_region, u, "")
        reg == "" && continue
        e = get!(region_service, (reg, s), AffExpr(0.0))
        sgn = (s == "energy" && dt == "load") ? -1.0 : 1.0
        add_to_expression!(e, sgn, expr)
    end

    for r in eachrow(m.generic_rhs)
        set = string(r.set)
        rhs = coalesce(_num(r.rhs), 0.0)
        typ = uppercase(string(r.type))
        vcost = coalesce(_num(r.violation_price), m.generic_cost)
        vcost <= 0 && (vcost = m.generic_cost)

        lhs = AffExpr(0.0)
        for row in get(unit_by_set, set, NamedTuple[])
            u = string(row.unit); s = string(row.service)
            f = coalesce(_num(row.factor), 0.0)
            f == 0 && continue
            for dt in ("generator", "load")
                haskey(D, (u, dt, s)) || continue
                sgn = (dt == "load" && s == "energy" && u in m.bdu_units) ? -1.0 : 1.0
                add_to_expression!(lhs, f * sgn, D[(u, dt, s)])
            end
        end
        for row in get(interc_by_set, set, NamedTuple[])
            ic = string(row.interconnector); f = coalesce(_num(row.factor), 0.0)
            (f == 0 || !haskey(flow_vars, ic)) && continue
            add_to_expression!(lhs, f, flow_vars[ic])
        end
        has_region_terms = false
        rsvc = String[]; rreg = String[]   # (service, region) labels for FCAS reqs
        for row in get(region_by_set, set, NamedTuple[])
            reg = string(row.region); s = string(row.service)
            f = coalesce(_num(row.factor), 0.0)
            (f == 0 || !haskey(region_service, (reg, s))) && continue
            add_to_expression!(lhs, f, region_service[(reg, s)])
            has_region_terms = true
            push!(rsvc, s); push!(rreg, reg)
        end
        isempty(lhs.terms) && continue
        svc_label = join(sort(unique(rsvc)), ",")   # e.g. "raise_reg" ("" if none)
        reg_label = join(sort(unique(rreg)), ",")

        sv1 = slack(vcost)
        local cref
        if typ == "GE" || typ == ">="
            cref = @constraint(model, lhs + sv1 >= rhs)
            m.generic_con_refs[set] = (cref, lhs, rhs, typ, (sv1,), has_region_terms, svc_label, reg_label)
        elseif typ == "EQ" || typ == "="
            sv2 = slack(vcost)
            cref = @constraint(model, lhs + sv1 - sv2 == rhs)
            m.generic_con_refs[set] = (cref, lhs, rhs, typ, (sv1, sv2), has_region_terms, svc_label, reg_label)
        else  # LE (default)
            cref = @constraint(model, lhs - sv1 <= rhs)
            m.generic_con_refs[set] = (cref, lhs, rhs, typ, (sv1,), has_region_terms, svc_label, reg_label)
        end
    end
end

# --- Tie-break constraints ------------------------------------------------------
# nempy (unit_constraints.tie_break_constraints): for every UNIQUE pair of
# energy bid bands from DIFFERENT units at the SAME objective cost, in the SAME
# region and with the SAME dispatch_type:
#     x_i/vol_i - x_j/vol_j + d1 - d2 = 0,   d1,d2 penalised at the tie-break cost.
function _add_tie_break_constraints!(model, m::SpotMarket, x, xcost, vol_lookup, slack)
    m.tiebreak_cost > 0 || return
    # Group energy bid bands by their EXACT objective cost (post load-flip and
    # loss-factor division — matching nempy's merge on the 'cost' column), the
    # unit's region and the dispatch type.
    groups = Dict{Tuple{Float64,String,String},Vector{Tuple{String,Int,VariableRef,Float64}}}()
    for ((u, dt, s, b), v) in x
        s == "energy" || continue
        vols = get(vol_lookup, (u, dt, s), nothing); vols === nothing && continue
        vol = vols[b]; vol >= 0.0001 || continue
        p = get(xcost, (u, dt, s, b), 0.0)
        reg = get(m.unit_region, u, "")
        push!(get!(groups, (p, reg, dt), Tuple{String,Int,VariableRef,Float64}[]),
              (u, b, v, vol))
    end
    # nempy dedups pairs by the SORTED string id [unit_x, band_x, unit_y, band_y]
    # — so e.g. (A,1,B,2) and (A,2,B,1) collapse into one constraint.
    for (_, members) in groups
        n = length(members)
        n < 2 && continue
        sort!(members, by = t -> (t[1], t[2]))
        seen = Set{NTuple{4,String}}()
        for i in 1:(n-1), j in (i+1):n
            ui, bi, vi, voli = members[i]
            uj, bj, vj, volj = members[j]
            ui == uj && continue              # only bids from DIFFERENT units
            name = (sort([ui, string(bi), uj, string(bj)])...,)
            name in seen && continue
            push!(seen, name)
            @constraint(model,
                vi / voli - vj / volj + slack(m.tiebreak_cost) - slack(m.tiebreak_cost) == 0)
        end
    end
    return
end

# --- Interconnectors (per-link flows and losses) --------------------------------
# Each LINK L: withdraw flf*L from its from_region, inject tlf*L into its
# to_region. The interconnector's NET flow (positive direction) is sum(gcf*L)
# and is what generic constraints reference. The loss curve is applied PER LINK
# in the link's own flow domain (breakpoints already multiplied by gcf by the
# input loader) and allocated between the LINK's from/to regions by
# from_region_loss_share (1.0 for the Basslink links, so BLNKTAS losses land in
# TAS1 and BLNKVIC losses in VIC1 — matching nempy).
function _add_interconnectors!(model, m::SpotMarket, region_balance, obj;
                               sos2_losses::Bool=false, binary_losses::Bool=false)
    flow_vars = Dict{String,AffExpr}()
    # Both values are always returned, including on the early exit: `dispatch!`
    # destructures the result, so returning `flow_vars` alone here threw a
    # `BoundsError` on any market with no interconnectors at all. That never
    # happens on real NEM data — every interval carries the five interconnectors
    # — which is why it survived; it does happen for a single-region synthetic
    # market, which is exactly what the smallest example and the unit tests use.
    isempty(m.interconnectors) && return flow_vars, NamedTuple[]
    loss_by_link = Dict{String,DataFrame}()
    if !isempty(m.losses)
        key = ("link" in names(m.losses)) ? :link : :interconnector
        for sub in groupby(m.losses, key)
            loss_by_link[string(first(sub[!, key]))] = sort(DataFrame(sub), :break_point)
        end
    end

    # Per-link records for the lazy SOS2/SOS1 tightening pass.
    loss_links = NamedTuple[]

    for r in eachrow(m.interconnectors)
        ic = string(r.interconnector)
        link = (:link in propertynames(r)) ? string(r.link) : ic
        fr = string(r.from_region); tr = string(r.to_region)
        (fr in m.regions && tr in m.regions) || continue
        lo = coalesce(_num(r.min), -1e6); hi = coalesce(_num(r.max), 1e6)
        flf = _getcol(r, :from_region_loss_factor, 1.0)
        tlf = _getcol(r, :to_region_loss_factor, 1.0)
        gcf = _getcol(r, :generic_constraint_factor, 1.0)
        share = _getcol(r, :from_region_loss_share, 0.5)
        # A16: MNSP links are MARKET PARTICIPANTS. When the link carries an
        # offer, build its flow from PRICED bands (F = sum of band dispatches,
        # each costed in the objective) instead of a free variable bounded by
        # registered capacity. Without this the link flows on inter-regional
        # spread alone, over-stating flow and collapsing price separation.
        ob = (:offer_bands in propertynames(r)) ? r.offer_bands : Float64[]
        op = (:offer_prices in propertynames(r)) ? r.offer_prices : Float64[]
        local F
        if !isempty(ob) && sum(ob) > 0
            F = AffExpr(0.0)
            for b in 1:min(length(ob), N_BANDS)
                ob[b] < 1e-4 && continue
                v = @variable(model, lower_bound = 0.0, upper_bound = ob[b])
                add_to_expression!(F, v)
                add_to_expression!(obj, (b <= length(op) ? op[b] : 0.0), v)
            end
            @constraint(model, F <= hi)
        else
            F = @variable(model, lower_bound = lo, upper_bound = hi)
        end
        add_to_expression!(region_balance[fr], -flf, F)
        add_to_expression!(region_balance[tr],  tlf, F)
        net = get!(flow_vars, ic, AffExpr(0.0))
        add_to_expression!(net, gcf, F)
        flow_vars[ic] = net

        λ = nothing; bps = Float64[]; losses = Float64[]
        if haskey(loss_by_link, link)
            lt = loss_by_link[link]
            bps = collect(Float64, lt.break_point); losses = collect(Float64, lt.loss)
            n = length(bps)
            if n >= 2
                λ = @variable(model, [1:n], lower_bound = 0.0, upper_bound = 1.0)
                @constraint(model, sum(λ) == 1)
                @constraint(model, F == sum(λ[k] * bps[k] for k in 1:n))
                Loss = sum(λ[k] * losses[k] for k in 1:n)
                if binary_losses
                    _add_sos2_binaries!(model, λ, n)
                elseif sos2_losses
                    @constraint(model, λ in MOI.SOS2(collect(1.0:n)))
                end
                haskey(region_balance, fr) && add_to_expression!(region_balance[fr], -share, Loss)
                haskey(region_balance, tr) && add_to_expression!(region_balance[tr], -(1.0 - share), Loss)
            else
                λ = nothing
            end
        end
        push!(loss_links, (ic=ic, link=link, F=F, hi=hi, λ=λ, bps=bps, losses=losses,
                           tightened=Ref(binary_losses)))
    end
    return flow_vars, loss_links
end

# Segment-selection binaries enforcing SOS2 adjacency on interpolation weights.
function _add_sos2_binaries!(model, λ, n::Int)
    nseg = n - 1
    y = @variable(model, [1:nseg], Bin)
    @constraint(model, sum(y) == 1)
    @constraint(model, λ[1] <= y[1])
    for k in 2:(n-1)
        @constraint(model, λ[k] <= y[k-1] + y[k])
    end
    @constraint(model, λ[n] <= y[nseg])
    return y
end

# NATIVE SOS2 adjacency (preferred). The explicit segment-selection formulation
# above needs one binary per segment; AEMO loss curves carry 60-120 breakpoints
# per link, so tightening several links at once produced 300+ binaries and a MIP
# that HiGHS could not close (observed 2025-09-02 14:05: TIME_LIMIT ->
# NO_SOLUTION -> NaN prices, or a poor incumbent priced at \$299.99/MWh against
# NEMDE's -\$12.66/MWh). A native SOS2 set gives the solver the same feasible
