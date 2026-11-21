# =============================================================================
# market_opf.jl
#
# `build_market_opf`: the market overlay on a PowerModels OPF -- offers, FCAS
# co-optimisation, generic constraints and the violation-priced slacks.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================


function build_market_opf(pm::PM.AbstractPowerModel, ctx)
    # ---- standard OPF skeleton (as PowerModels.build_opf) ------------------
    PM.variable_bus_voltage(pm)
    PM.variable_gen_power(pm)
    # NOTE: branch-flow variables carry the thermal ratings as HARD BOUNDS at
    # creation; with enforce_thermal=false they must be created unbounded or
    # the snem2000 ratings silently bind anyway (they pinned ~2 GW of coal
    # below its down-ramp window in early runs).
    PM.variable_branch_power(pm; bounded=ctx.enforce_thermal)
    PM.variable_dcline_power(pm)
    PM.constraint_model_voltage(pm)
    for i in PM.ids(pm, :ref_buses); PM.constraint_theta_ref(pm, i); end
    for i in PM.ids(pm, :bus); PM.constraint_power_balance(pm, i); end
    for i in PM.ids(pm, :branch)
        PM.constraint_ohms_yt_from(pm, i); PM.constraint_ohms_yt_to(pm, i)
        PM.constraint_voltage_angle_difference(pm, i)
        # Thermal limits are optional: snem2000 ratings were calibrated to an
        # earlier fleet snapshot; with the July-2024 fleet mapped on, intact
        # ratings force multi-GW redispatch away from the market solution
        # (surfacing as ramp/FCAS violation slack). enforce_thermal=false keeps
        # only the aggregate interconnector limits (the market's own network
        # representation) — the validated sanity configuration.
        if ctx.enforce_thermal
            PM.constraint_thermal_limit_from(pm, i); PM.constraint_thermal_limit_to(pm, i)
        end
    end
    for i in PM.ids(pm, :dcline); PM.constraint_dcline_power_losses(pm, i); end

    model = pm.model
    mkt = ctx.mkt; base = ctx.base
    obj = AffExpr(0.0)
    # Every violation variable is RECORDED with a human-readable label
    # "family:identifier" (unit/dt/service, interconnector, or constraint set)
    # so result.slack_report pinpoints WHERE the model is being violated.
    slack(c, tag::String="untagged") = begin
        s = @variable(model, lower_bound=0.0)
        add_to_expression!(obj, c, s)
        push!(ctx.slackrec, (tag, float(c), s))
        s
    end

    # ---- power-balance violation pricing ------------------------------------
    # The dummy reference-node generators added by `_add_balance_slack!` are
    # already inside PM's balance for EVERY formulation (that is the point of
    # expressing them as generators rather than as bespoke constraints). All
    # that is left is to price them, at the same regional energy-deficit CVP
    # NEMDE uses, so they are a genuine last resort and their use is reported.
    for s in ctx.balance_slack
        v = PM.var(pm, :pg, parse(Int, s.gen_id))
        # `deficit` injects (pg >= 0) and `surplus` absorbs (pg <= 0); the sign
        # makes both contribute +CVP * |MW| and keeps the objective linear.
        sgn = s.dir == "deficit" ? 1.0 : -1.0
        add_to_expression!(obj, ctx.balance_cvp * sgn * base, v)
        push!(ctx.slackrec, ("balance_" * s.dir * ":" * s.region,
                             float(ctx.balance_cvp), v))
    end

    # ---- band variables and pg linkage --------------------------------------
    x = Dict{Tuple{String,String,String,Int},VariableRef}()
    E = Dict{Tuple{String,String,String},AffExpr}()   # MW per (unit,dt,service)
    genid = Dict((r.unit, r.dispatch_type) => r.gen_id for r in eachrow(ctx.mapping))
    mlf = Dict((string(r.unit), string(r.dispatch_type)) => float(r.loss_factor)
               for r in eachrow(mkt.unit_info))
    pl = Dict{Tuple{String,String,String},Vector{Float64}}()
    for r in eachrow(mkt.pb)
        pl[(string(r.unit), string(r.dispatch_type), string(r.service))] = _band_vols(r)
    end
    for r in eachrow(mkt.vb)
        un = string(r.unit); dt = string(r.dispatch_type); sv = string(r.service)
        haskey(genid, (un, dt)) || continue
        vols = _band_vols(r); prices = get(pl, (un, dt, sv), zeros(10))
        dir = (sv == "energy" && dt == "load") ? -1.0 : 1.0
        # MLF PRICE REFERRAL (see NODAL_MLF_PRICE_REFERRAL). `mkt.pb` carries
        # CONNECTION-POINT energy prices, because get_processed_bids has already
        # multiplied the case-file prices by lambda. The zonal engine divides
        # that back out, so its objective is in reference-node terms; the nodal
        # model does not, so its objective is in connection-point terms. Which
        # is correct depends on whether the formulation can move energy from the
        # connection point to the reference node -- see the flag's docstring.
        lam = (sv == "energy" && ctx.mlf_referral) ? get(mlf, (un, dt), 1.0) : 1.0
        (lam > 0) || (lam = 1.0)
        e = AffExpr(0.0)
        for b in 1:10
            vols[b] < 1e-4 && continue
            v = @variable(model, lower_bound=0.0, upper_bound=vols[b])
            x[(un, dt, sv, b)] = v
            add_to_expression!(e, v)
            add_to_expression!(obj, dir * prices[b] / lam, v)
        end
        E[(un, dt, sv)] = e
    end
    # Record FCAS enablement expressions (every non-energy service) so the
    # solved committed MW can be read into the result dict post-optimise.
    for ((un, dt, sv), e) in E
        sv == "energy" && continue
        push!(ctx.fcasrec, (un, dt, sv, e))
    end
    Eg(un, dt, sv) = get(E, (un, dt, sv), AffExpr(0.0))
    # pg linkage (MW; DCP_MLF scales generator injections by MLF, A8)
    for ((un, dt), gid) in genid
        haskey(E, (un, dt, "energy")) || continue
        γ = ctx.use_mlf && dt != "load" ? get(mlf, (un, dt), 1.0) : 1.0
        pgv = PM.var(pm, :pg, parse(Int, gid))
        sgn = dt == "load" ? -1.0 : 1.0
        @constraint(model, pgv * base == sgn * γ * E[(un, dt, "energy")])
    end

    # ---- capacity / UIGF -----------------------------------------------------
    for r in eachrow(mkt.avail)
        k = (string(r.unit), string(r.dispatch_type), "energy")
        haskey(E, k) || continue
        @constraint(model, E[k] - slack(mkt.cvp["unit_capacity"], "capacity:"*k[1]*"/"*k[2]) <= coalesce(r.capacity, 0.0))
    end
    for r in eachrow(mkt.uigf)
        k = (string(r.unit), "generator", "energy")
        haskey(E, k) || continue
        @constraint(model, E[k] - slack(mkt.cvp["uigf"], "uigf:"*k[1]) <= coalesce(r.capacity, 0.0))
    end

    # ---- ramp constraints (bid ∧ SCADA, MW/h; net for BDU pairs) ------------
    scada = Dict(string(r.unit) => (r.scada_ramp_up_rate, r.scada_ramp_down_rate,
                                    r.initial_output) for r in eachrow(mkt.scada))
    fmin(a, b) = ismissing(b) ? a : (ismissing(a) ? b : min(a, b))
    bdu = Set(un for ((un, dt), _) in genid
              if haskey(genid, (un, "generator")) && haskey(genid, (un, "load")))
    done = Set{String}()
    for r in eachrow(mkt.ramp)
        un = string(r.unit); dt = string(r.dispatch_type)
        haskey(E, (un, dt, "energy")) || continue
        init = coalesce(r.initial_output, missing); ismissing(init) && continue
        s = get(scada, un, (missing, missing, missing))
        up = fmin(r.ramp_up_rate, s[1]); dn = fmin(r.ramp_down_rate, s[2])
        # ZERO-ramp (frozen) units are pinned by their hard bounds in
        # map_participants! to min(initial, MaxAvail). Adding the soft ramp
        # constraint on top would re-introduce the very CVP penalty the pin
        # exists to avoid (init - 0 = init > MaxAvail = the pinned bound).
        if (!ismissing(up) && up == 0) || (!ismissing(dn) && dn == 0)
            continue
        end
        expr = un in bdu ? (un in done ? nothing :
               (push!(done, un); Eg(un, "generator", "energy") - Eg(un, "load", "energy"))) :
               E[(un, dt, "energy")]
        expr === nothing && continue
        if !ismissing(up) && isfinite(up)
            s1 = slack(mkt.cvp["ramp_rate"], "ramp_up:"*un*"/"*dt)
            @constraint(model, expr - s1 <= init + up * TAU)
            push!(ctx.rampdiag, (un * "/" * dt * "/up", init, float(up), s1))
        end
        if !ismissing(dn) && isfinite(dn)
            s2 = slack(mkt.cvp["ramp_rate"], "ramp_dn:"*un*"/"*dt)
            @constraint(model, expr + s2 >= init - dn * TAU)
            push!(ctx.rampdiag, (un * "/" * dt * "/dn", init, float(dn), s2))
        end
    end

    # ---- FCAS: max availability, trapeziums (both slopes + reg coupling) ----
    for r in eachrow(mkt.maxav)
        k = (string(r.unit), string(r.dispatch_type), string(r.service))
        haskey(E, k) || continue
        @constraint(model, E[k] - slack(mkt.cvp["fcas_max_avail"], "fcas_max:"*k[1]*"/"*k[3]) <= coalesce(r.max_availability, 0.0))
    end
    Ehat(un, dt) = (dt == "load" && un in bdu ? -1.0 : 1.0) * Eg(un, dt, "energy")
    for r in eachrow(mkt.regtrap)
        un = string(r.unit); dt = string(r.dispatch_type); sv = string(r.service)
        A = coalesce(r.max_availability, 0.0); A <= 0 && continue
        haskey(E, (un, dt, sv)) || continue
        su = (r.enablement_max - r.high_break_point) / A
        sl = (r.low_break_point - r.enablement_min) / A
        @constraint(model, Ehat(un, dt) + su*E[(un,dt,sv)] - slack(mkt.cvp["fcas_profile"], "regtrap_hi:"*un*"/"*sv) <= r.enablement_max)
        @constraint(model, Ehat(un, dt) - sl*E[(un,dt,sv)] + slack(mkt.cvp["fcas_profile"], "regtrap_lo:"*un*"/"*sv) >= r.enablement_min)
    end
    for r in eachrow(mkt.conttrap)
        un = string(r.unit); dt = string(r.dispatch_type); sv = string(r.service)
        A = coalesce(r.max_availability, 0.0); A <= 0 && continue
        haskey(E, (un, dt, sv)) || continue
        su = (r.enablement_max - r.high_break_point) / A
        sl = (r.low_break_point - r.enablement_min) / A
        other = dt == "generator" ? "load" : "generator"
        Ee = Ehat(un, dt) + (un in bdu ? Ehat(un, other) : AffExpr(0.0))
        rup = dt == "generator" ? "raise_reg" : "lower_reg"
        rdn = dt == "generator" ? "lower_reg" : "raise_reg"
        upx = Ee + su*E[(un,dt,sv)] + Eg(un,dt,rup) + (un in bdu ? Eg(un,other,rup) : AffExpr(0.0))
        @constraint(model, upx - slack(mkt.cvp["fcas_profile"], "jointcap_hi:"*un*"/"*sv) <= r.enablement_max)
        dnx = Ee - sl*E[(un,dt,sv)] - Eg(un,dt,rdn) + (un in bdu ? Eg(un,other,rdn) : AffExpr(0.0))
        @constraint(model, dnx + slack(mkt.cvp["fcas_profile"], "jointcap_lo:"*un*"/"*sv) >= r.enablement_min)
    end
    # joint ramping (reg bidders only)
    for ((un, dt, sv), e) in E
        sv in ("raise_reg", "lower_reg") || continue
        s = get(scada, un, (missing, missing, missing))
        (ismissing(s[3]) || ismissing(sv == "raise_reg" ? s[1] : s[2])) && continue
        init = s[3]
        if sv == "raise_reg"
            rhs = init + s[1] * TAU
            if dt == "generator"
                @constraint(model, Eg(un,dt,"energy") + e - slack(mkt.cvp["fcas_profile"], "jointramp:"*un*"/raise") <= rhs)
            else
                @constraint(model, Eg(un,dt,"energy") - e + slack(mkt.cvp["fcas_profile"], "jointramp:"*un*"/raise") >= init - s[1]*TAU)
            end
        else
            rhs = init - s[2] * TAU
            if dt == "generator"
                @constraint(model, Eg(un,dt,"energy") - e + slack(mkt.cvp["fcas_profile"], "jointramp:"*un*"/lower") >= rhs)
            else
                @constraint(model, Eg(un,dt,"energy") + e - slack(mkt.cvp["fcas_profile"], "jointramp:"*un*"/lower") <= init + s[2]*TAU)
            end
        end
    end

    # ---- aggregate interconnector flows and limits (A5) ---------------------
    ic_flow = Dict{String,AffExpr}()
    for (ic, elems) in ctx.ties
        from_area = IC_FROM[ic]
        f = AffExpr(0.0)
        for (kind, id, fb, tb) in elems
            fa = Int(ctx.data["bus"][string(fb)]["area"])
            sgn = fa == from_area ? 1.0 : -1.0
            if kind == "branch"
                br = ctx.data["branch"][id]
                add_to_expression!(f, sgn * base,
                    PM.var(pm, :p, (parse(Int, id), br["f_bus"], br["t_bus"])))
            else
                dc = ctx.data["dcline"][id]
                add_to_expression!(f, sgn * base,
                    PM.var(pm, :p_dc, (parse(Int, id), dc["f_bus"], dc["t_bus"])))
            end
        end
        ic_flow[ic] = f
        lim = get(ctx.iclim, ic, nothing); lim === nothing && continue
        chi = @constraint(model, f - slack(mkt.cvp["interconnector"], "iclimit_hi:"*ic) <= lim[2])
        clo = @constraint(model, f + slack(mkt.cvp["interconnector"], "iclimit_lo:"*ic) >= lim[1])
        # capture refs + the from-area so the price decomposition can attribute
        # the inter-regional congestion rent (dual) to the correct direction.
        push!(ctx.ic_con, (ic=ic, from_area=from_area, chi=chi, clo=clo))
    end

    # ---- generic constraints (A6) -------------------------------------------
    if ctx.include_generic
        ub = Dict{String,Vector{NamedTuple}}(); ibs = Dict{String,Vector{NamedTuple}}()
        rb = Dict{String,Vector{NamedTuple}}()
        for r in eachrow(mkt.ulhs); push!(get!(ub, string(r.set), NamedTuple[]), copy(r)); end
        for r in eachrow(mkt.ilhs); push!(get!(ibs, string(r.set), NamedTuple[]), copy(r)); end
        for r in eachrow(mkt.rlhs); push!(get!(rb, string(r.set), NamedTuple[]), copy(r)); end
        regsvc = Dict{Tuple{String,String},AffExpr}()
        regof = Dict(string(r.unit) => string(r.region) for r in eachrow(mkt.unit_info))
        for ((un, dt, sv), e) in E
            rg = get(regof, un, ""); rg == "" && continue
            k = (rg, sv); a = get!(regsvc, k, AffExpr(0.0))
            add_to_expression!(a, (sv == "energy" && dt == "load") ? -1.0 : 1.0, e)
        end
        for r in eachrow(mkt.gc)
            set = string(r.set); rhs = coalesce(r.rhs, 0.0)
            # Class filter: when the physical network is enforced, thermal-class
            # constraints are the ones it replaces (see classify_generic).
            ctx.generic_classes === nothing ||
                classify_generic(set) in ctx.generic_classes || continue
            vc = coalesce(r.violation_price, mkt.gccost); vc <= 0 && (vc = mkt.gccost)
            lhs = AffExpr(0.0)
            for t in get(ub, set, NamedTuple[])
                for dt in ("generator", "load")
                    haskey(E, (string(t.unit), dt, string(t.service))) || continue
                    sgn = (dt == "load" && string(t.service) == "energy" &&
                           string(t.unit) in bdu) ? -1.0 : 1.0
                    add_to_expression!(lhs, t.factor * sgn, E[(string(t.unit), dt, string(t.service))])
                end
            end
            for t in get(ibs, set, NamedTuple[])
                haskey(ic_flow, string(t.interconnector)) || continue
                add_to_expression!(lhs, t.factor, ic_flow[string(t.interconnector)])
            end
            for t in get(rb, set, NamedTuple[])
                haskey(regsvc, (string(t.region), string(t.service))) || continue
                add_to_expression!(lhs, t.factor, regsvc[(string(t.region), string(t.service))])
            end
            isempty(lhs.terms) && continue
            ty = uppercase(string(r.type))
            cref = if ty == "GE"
                @constraint(model, lhs + slack(vc, "generic:"*set) >= rhs)
            elseif ty == "EQ"
                @constraint(model, lhs + slack(vc, "generic:"*set) - slack(vc, "generic:"*set) == rhs)
            else
                @constraint(model, lhs - slack(vc, "generic:"*set) <= rhs)
            end
            # Keep the ref + a (region,service) label so the FCAS requirement
            # duals can be surfaced as regional FCAS prices after the solve.
            rbrows = get(rb, set, NamedTuple[])
            svlabel = isempty(rbrows) ? "" :
                      join(sort(unique(string(t.service) for t in rbrows)), ",")
            rglabel = isempty(rbrows) ? "" :
                      join(sort(unique(string(t.region) for t in rbrows)), ",")
            push!(ctx.genericrec, (set=set, service=svlabel, region=rglabel,
                                   type=ty, rhs=float(rhs), cref=cref))
        end
    end

    @objective(model, Min, obj)
    return
end
