# =============================================================================
# solve.jl
#
# `solve_network_dispatch`: build, solve with retry, and extract nodal prices,
# the energy/congestion/loss decomposition and the binding-constraint ledger.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================


# ---------------------------------------------------------------------------
# Solve + price extraction
# ---------------------------------------------------------------------------
"""
    solve_network_dispatch(interval, formulation; kwargs...) -> Dict{String, Any}

Build and solve the market-overlaid network dispatch for `formulation`
(a key of `FORMULATIONS`). Returns objective, solve status/time, total network
losses, per-bus LMPs, regional-reference-node prices (A9) and the mapping.
FCAS results are also returned: `"fcas_enablement"` (a DataFrame of committed
MW per `unit, dispatch_type, service`) and `"fcas_prices"` (the dual/marginal
price (`\$/MW`) of each FCAS regional requirement, keyed by generic-constraint
`set` with `service`/`region` labels; non-empty only when `include_generic`).
LMPs are the duals of the nodal real-power balance constraints; for nonlinear
formulations these are the local KKT multipliers reported by Ipopt, and for
conic relaxations the conic duals (both standard practice). Models here are
continuous, so no fix-and-reprice pass is required; if binaries are ever
added, fix them and re-solve before reading duals (as the copper-plate model
does).
"""
function solve_network_dispatch(interval::DateTime, formulation::String;
        mfile::String="./data/snem2000_fixed.m",
        data_dir::String="./data/nemx_2024_07",
        include_generic::Bool=true,
        generic_classes::Union{Nothing,Set{String}}=nothing,
        enforce_thermal::Bool=false,
        hard_down_ramp::Union{Nothing,Bool}=nothing,
        mkt=nothing, net=nothing, post_build=nothing,
        optimizer=nothing)
    haskey(FORMULATIONS, formulation) || error("unknown formulation $formulation")
    form, optf = FORMULATIONS[formulation]
    # The registry pairs each formulation with the solver that suits it: HiGHS
    # for a linear one, Ipopt for a non-linear one. `optimizer` overrides that
    # pairing for callers who need to -- a script offering --lp-solver, or a
    # study comparing two solvers on the same formulation. It is a keyword
    # rather than a module-level switch so that the choice is visible at the
    # call site and cannot leak between solves.
    opt = optimizer === nothing ? optf() : optimizer
    opt === nothing && return Dict{String, Any}(
        "formulation" => formulation,
        "status" => "SKIPPED (no SDP solver installed)",
    )

    mkt === nothing && (mkt = load_market(interval; data_dir=data_dir))
    if net === nothing
        data, meta = load_network(mfile)
    else
        data, meta = deepcopy(net[1]), net[2]
    end
    # Hard down-ramp floors: kept for DC (where they are always satisfiable),
    # relaxed to SOFT for lossy formulations (see A17). Override with the
    # hard_down_ramp kwarg.
    hd = hard_down_ramp === nothing ?
         (formulation in ("DCP", "DCP_MLF")) : hard_down_ramp
    mapping = map_participants!(data, meta, mkt; hard_down=hd)
    # DCP_MLF bounds `gamma * E`, not `E`, so the market-MW bounds written by
    # map_participants! must be carried through the same scaling.
    formulation == "DCP_MLF" && _scale_gen_bounds_for_mlf!(data, mapping, mkt)
    # Added AFTER mapping so the dummy generator ids cannot collide with a
    # mapped market unit, and so the reference nodes are known.
    bslack = _add_balance_slack!(data, mapping)
    bslack_ids = Set(s.gen_id for s in bslack)
    ties = _tie_groups(data, meta)
    iclim = Dict{String,Tuple{Float64,Float64}}()
    for sub in groupby(mkt.icdef, :interconnector)
        ic = string(first(sub.interconnector))
        lo = minimum(coalesce.(sub.min, -1e4)); hi = maximum(coalesce.(sub.max, 1e4))
        ic == "T-V-MNSP1" && (lo = -maximum(coalesce.(sub.max, 0.0)); hi = maximum(coalesce.(sub.max, 0.0)))
        iclim[ic] = (lo, hi)
    end
    ctx = (mkt=mkt, data=data, base=data["baseMVA"], mapping=mapping, ties=ties,
           iclim=iclim, include_generic=include_generic,
           generic_classes=generic_classes,
           enforce_thermal=enforce_thermal,
           use_mlf=(formulation == "DCP_MLF"),
           # Applies to EVERY formulation: the nodal study measures the effect
           # of the power-flow model, so all formulations must share one bid
           # stack, and that stack is the reference-node-referred one the zonal
           # benchmark uses. The MLF-scaled counterpart is produced separately
           # as the comparison baseline (ZONAL_MLF_KEEP_SCALING).
           mlf_referral=NODAL_MLF_PRICE_REFERRAL[],
           balance_slack=bslack,
           # NEMDE's own regional energy-deficit price, so the nodal balance is
           # violated on exactly the same terms as the copper-plate model's
           # regional demand constraint.
           balance_cvp=float(get(mkt.cvp, "regional_demand", 2_625_000.0)),
           slackrec=Vector{Tuple{String,Float64,JuMP.VariableRef}}(),
           rampdiag=Vector{Tuple{String,Float64,Float64,JuMP.VariableRef}}(),
           # FCAS extraction hooks: enablement expressions per (unit,dt,service)
           # and the generic (SPD) constraint refs whose duals are the FCAS
           # regional requirement prices.
           fcasrec=Vector{Tuple{String,String,String,JuMP.AffExpr}}(),
           genericrec=Vector{Any}(),
           # interconnector limit constraint refs for the LMP price decomposition
           ic_con=Vector{Any}())

    # --- Inspection hooks (uncomment as needed) -----------------------------
    # PM.print_summary(data)                       # mapped network: component
    #                                              # counts, buses, gens, ties
    # PM.export_matpower("mapped_network.m", data) # dump the FINAL mapped case
    #                                              # (post participant mapping,
    #                                              # load scaling, dcline fixes)
    t0 = time()
    pm = PM.instantiate_model(data, form, pm -> build_market_opf(pm, ctx);
                              setting=Dict("output"=>Dict("duals"=>true)))
    # Extension point for analyses that need the BUILT model before it is
    # solved -- adding variables, pinning existing ones, or replacing the
    # objective -- without duplicating or editing any formulation here. Used by
    # the AC-feasibility recovery workflow (analysis/ac_recovery.jl), which
    # reuses these exact AC equations, limits, security constraints and solver
    # configuration and changes only the objective. `nothing` by default, so
    # every existing call site is unaffected.
    post_build === nothing || post_build(pm, ctx)
    # JuMP.write_to_file(pm.model, "network_dispatch_model.lp")  # full LP/NLP
    # println(pm.model)                                          # (small cases)
    res = PM.optimize_model!(pm, optimizer=opt)
    first_status = string(res["termination_status"])
    n_attempts   = 1
    # One retry along a different barrier path when the solve genuinely failed.
    # NLP formulations only -- the LPs are solved exactly by HiGHS.
    if NLP_RETRY_ENABLED[] && !_solve_ok(res["termination_status"]) &&
       formulation in ("ACP", "LPACC", "SOCWR", "QCRM")
        @info "  retrying $formulation on a different barrier path" interval status=first_status
        res_retry = try
            # The optimizer MUST be re-attached with `set_optimizer`, not passed
            # to `optimize_model!`: that keyword is ignored once a model already
            # holds an optimizer (InfrastructureModels warns "Model already
            # contains optimizer" and silently re-solves with the ORIGINAL
            # settings). Passing it there made the retry a no-op - it returned
            # the identical failed solution - which is why this path is
            # regression-tested by forcing a failure rather than assumed to work.
            # Re-attaching also discards the failed iterate, so the retry starts
            # from the model's own starting point rather than warm-starting into
            # the same dead end.
            JuMP.set_optimizer(pm.model, optimizer_with_attributes(
                Ipopt.Optimizer, _IPOPT_NLP_RETRY...))
            PM.optimize_model!(pm)
        catch err
            @warn "  retry raised" err
            nothing
        end
        if res_retry !== nothing
            # Kept unconditionally: the first attempt's duals are not prices,
            # and the downstream extraction reads duals straight off the JuMP
            # model, so `res` and the model must describe the SAME solve.
            res = res_retry
            n_attempts = 2
        end
    end
    tsolve = time() - t0

    # LOSS ACCOUNTING (three distinct quantities — do not conflate):
    #  * network losses  = sum(pg) - native load. For DCP this is ONLY the
    #    explicit dcline losses (PM's dcline model has losses in EVERY
    #    formulation, incl. DCP); AC branch I2R appears here for ACP/SOC/QC.
    #  * dcline losses   = sum(pf+pt) over dclines (reported separately).
    #  * MLF-booked losses (DCP_MLF only) = (1-γ)/γ * pg per generator: the
    #    intra-regional losses booked on the BID side, invisible to the network
    #    balance — which is why DCP_MLF's "network losses" can be SMALLER than
    #    DCP's (the two solutions carry different dcline flows).
    sol = res["solution"]
    # The balance-slack generators are NOT plant: including their injection in
    # `pgen` would book a priced energy deficit as though it were network loss.
    pgen = sum(g["pg"] for (k, g) in get(sol, "gen", Dict())
               if !(k in bslack_ids); init=0.0) * data["baseMVA"]
    balance_deficit = 0.0   # MW of unserved energy (+) / dumped surplus (-)
    balance_by_region = Dict{String,Float64}()
    for s in bslack
        v = get(get(get(sol, "gen", Dict()), s.gen_id, Dict()), "pg", 0.0) * data["baseMVA"]
        abs(v) < 1e-6 && continue
        balance_deficit += v
        balance_by_region[s.region] = get(balance_by_region, s.region, 0.0) + v
    end
    pload = sum(ld["pd"] for (_, ld) in data["load"]; init=0.0) * data["baseMVA"]
    losses = pgen - pload + balance_deficit
    dcl = 0.0
    for (i, dc) in get(sol, "dcline", Dict())
        dcl += (get(dc, "pf", 0.0) + get(dc, "pt", 0.0)) * data["baseMVA"]
    end
    mlf_booked = 0.0
    if ctx.use_mlf
        γs = Dict((string(r.unit), string(r.dispatch_type)) => float(r.loss_factor)
                  for r in eachrow(mkt.unit_info))
        for r in eachrow(mapping)
            r.dispatch_type == "generator" || continue
            γ = get(γs, (string(r.unit), "generator"), 1.0)
            pg = get(get(sol["gen"], string(r.gen_id), Dict()), "pg", 0.0) * data["baseMVA"]
            γ > 0 && (mlf_booked += pg * (1 - γ) / γ)
        end
    end

    # LMPs ($/MWh): balance duals scaled from p.u.; sign normalised so that
    # the demand-weighted mean is positive under normal conditions.
    # PM balance duals are $ per p.u.-MW: divide by baseMVA for $/MWh.
    lmp = Dict{Int,Float64}()
    if haskey(sol, "bus")
        for (b, bus) in sol["bus"]
            haskey(bus, "lam_kcl_r") || continue
            lmp[parse(Int, b)] = -bus["lam_kcl_r"] / data["baseMVA"]
        end
    end
    # A9: RRN = bus of largest mapped generator per region
    rrn = Dict{String,Int}()
    for sub in groupby(mapping, :region)
        gens = sub[sub.dispatch_type .== "generator", :]
        isempty(gens) && continue
        rrn[string(first(sub.region))] = gens.bus[argmax(gens.cap_mw)]
    end
    rrn_price = Dict(r => get(lmp, b, NaN) for (r, b) in rrn)

    # ---- LMP price decomposition (A18): LMP = energy + congestion + loss ----
    # energy   = system reference price (mainland synchronous slack bus LMP);
    # congest. = inter-regional congestion rent = Σ binding interconnector-limit
    #            duals on the NEM region-tree path from the reference region;
    # loss     = residual (marginal-loss component, incl. the TAS HVDC link).
    # For an uncongested interval congestion≈0 and the RRN spread is pure loss.
    refbuses = [parse(Int, b) for (b, bus) in data["bus"] if Int(bus["bus_type"]) == 3]
    mainref = 0
    for rb in refbuses; Int(data["bus"][string(rb)]["area"]) == 5 || (mainref = rb); end
    energy = get(lmp, mainref, NaN)
    iccong = Dict{String,Float64}()
    for e in ctx.ic_con
        μhi = try JuMP.dual(e.chi) catch; 0.0 end
        μlo = try JuMP.dual(e.clo) catch; 0.0 end
        iccong[uppercase(e.ic)] = -(μhi + μlo)   # $/MWh price step across the link
    end
    _edgecong(pats) = sum((any(occursin(p, ic) for p in pats) ? μ : 0.0)
                          for (ic, μ) in iccong; init = 0.0)
    # region-tree paths to the NSW1 reference (interconnector name fragments):
    icpath = Dict("NSW1" => String[],
                  "QLD1" => ["QLD", "N-Q", "NQ"],
                  "VIC1" => ["VIC1-NSW1", "V-N", "VNI"],
                  "SA1"  => ["VIC1-NSW1", "V-N", "VNI", "V-SA", "V-S", "SA"],
                  "TAS1" => ["VIC1-NSW1", "V-N", "VNI", "T-V", "BASS", "TAS"])
    price_decomposition = DataFrame(region = String[], lmp = Float64[], energy = Float64[],
                                    congestion = Float64[], loss = Float64[])
    for (r, b) in sort(collect(rrn))
        lr = get(lmp, b, NaN)
        cg = _edgecong(get(icpath, r, String[]))
        push!(price_decomposition, (r, lr, energy, cg, lr - energy - cg))
    end
    sort!(price_decomposition, :region)

    # ---- Shadow-price ledger (A18b): the FULL set of active pricing components.
    # The RRN energy-price decomposition above is the standard energy+congestion+
    # loss split, in which the congestion term is the aggregate of ALL binding
    # network/security constraints projected onto the bus through their shift
    # factors. This ledger reports the underlying binding shadow prices by family
    # so that the interconnector-limit, network-security (thermal/voltage/
    # transient generic) and FCAS-reserve components are explicit — including
    # those (e.g. limits on a parallel MNSP link inside a meshed AC region) whose
    # shift factor onto the regional energy price is ~0 and hence do not separate
    # the regional prices, yet are genuine active constraints. FCAS-reserve duals
    # are the (locational) reserve prices; they enter energy only via the joint
    # energy-FCAS trapezium coupling, not as an additive nodal-balance term.
    icsets = Set(string(x.set) for x in eachrow(mkt.ilhs))
    # A constraint is BINDING if it sits at its bound -- a PRIMAL test on the
    # slack -- not if its multiplier happens to exceed a magnitude threshold.
    # The distinction is the whole difference between the DC and AC ledgers. An
    # interior-point method terminates with a barrier parameter that leaves
    # inactive constraints slightly off their bound carrying multipliers of
    # order mu_barrier (measured here: ~1e-5), which sail past a `|dual| > 1e-6`
    # test and inflate the active set six-fold without carrying any congestion
    # rent. Simplex has no such set, so the dual test happened to work for DC
    # and silently failed for everything else.
    #
    # Both quantities are now recorded -- `slack` and `at_bound` alongside
    # `dual` -- so a consumer can filter primally and the residue is visible
    # rather than mistaken for a price.
    binding_constraints = DataFrame(family = String[], constraint = String[],
        service = String[], region = String[], dual = Float64[], rhs = Float64[],
        lhs = Float64[], slack = Float64[], at_bound = Bool[],
        refs_interconnector = Bool[])
    _slack_of(cref, rhs) = begin
        l = try JuMP.value(cref) catch; NaN end
        (l, (isfinite(l) && isfinite(rhs)) ? abs(l - rhs) : NaN)
    end
    _at_bound(sl, rhs) = isfinite(sl) && sl <= 1e-6 * max(1.0, abs(rhs))
    for e in ctx.ic_con
        μ = -((try JuMP.dual(e.chi) catch; 0.0 end) + (try JuMP.dual(e.clo) catch; 0.0 end))
        abs(μ) > 1e-6 && push!(binding_constraints,
            ("interconnector_limit", e.ic, "", "", μ, NaN, NaN, NaN, true, true))
    end
    for rec in ctx.genericrec
        d = try JuMP.dual(rec.cref) catch; NaN end
        l, sl = _slack_of(rec.cref, rec.rhs)
        ab = _at_bound(sl, rec.rhs)
        # Keep a row if it is primally at its bound OR carries a material dual,
        # so nothing is lost and the two criteria can be compared downstream.
        (isfinite(d) && (abs(d) > 1e-6 || ab)) || continue
        cls = classify_generic(rec.set)
        fam = cls == "fcas" ? "fcas_reserve" :
              cls in ("thermal", "voltage", "transient") ? "network_security" : cls
        push!(binding_constraints,
            (fam, rec.set, rec.service, rec.region, d, rec.rhs, l, sl, ab,
             rec.set in icsets))
    end
    sort!(binding_constraints, :dual, by = abs, rev = true)

    # Slack diagnostics: labelled per-constraint violations (slack_report:
    # family:identifier, penalty $/MW, violation MW) plus the legacy
    # penalty-grouped totals (slack_by_penalty).
    sdiag = Dict{Float64,Tuple{Float64,Float64}}()
    srep = DataFrame(slack_id=String[], penalty=Float64[], violation_mw=Float64[])
    for (tag, c, v) in ctx.slackrec
        val = try JuMP.value(v) catch; 0.0 end
        val > 1e-6 || continue
        mw, cost = get(sdiag, c, (0.0, 0.0))
        sdiag[c] = (mw + val, cost + c * val)
        push!(srep, (tag, c, val))
    end
    sort!(srep, :violation_mw, rev=true)
    rampv = [(n, i, u, try JuMP.value(v) catch; 0.0 end) for (n, i, u, v) in ctx.rampdiag]

    # ---- FCAS commitments (enabled MW) and requirement prices ---------------
    # fcas_enablement: co-optimised enabled MW per (unit, dispatch_type,
    # service) — the FCAS analogue of the energy dispatch. fcas_prices: the
    # marginal price ($/MW) of each FCAS regional requirement = the dual of its
    # generic (SPD) constraint. Prices need include_generic=true (else empty),
    # and are the KKT/conic multipliers for the active formulation — the same
    # convention as the LMPs above.
    solved_ok = string(res["termination_status"]) in ("OPTIMAL", "LOCALLY_SOLVED")
    fcas_enablement = DataFrame(unit=String[], dispatch_type=String[],
                                service=String[], enabled_mw=Float64[])
    if solved_ok
        for (un, dt, sv, e) in ctx.fcasrec
            push!(fcas_enablement, (un, dt, sv, try JuMP.value(e) catch; 0.0 end))
        end
    end
    sort!(fcas_enablement, [:unit, :dispatch_type, :service])
    fcas_prices = DataFrame(set=String[], service=String[], region=String[],
                            type=String[], price=Float64[], rhs=Float64[],
                            binding=Bool[])
    for rec in ctx.genericrec
        classify_generic(rec.set) == "fcas" || continue
        d = try JuMP.dual(rec.cref) catch; NaN end
        lhsv = try JuMP.value(rec.cref) catch; NaN end
        binds = isfinite(lhsv) && abs(lhsv - rec.rhs) <= 1e-4 * max(1.0, abs(rec.rhs))
        push!(fcas_prices, (rec.set, rec.service, rec.region, rec.type,
                            d, rec.rhs, binds))
    end
    sort!(fcas_prices, :price, rev=true)

    # ---- A14: write the SOLVED state back into `data` -----------------------
    # The returned `data` is the FINAL mapped case (post participant mapping,
    # load scaling, dcline/V fixes) refreshed with this solve's operating
    # point, so it can be exported (PM.export_matpower), re-solved as a power
    # flow, or converted to a PowerSystems System without re-deriving anything.
    # Market attributes (DUID, region, MLF, initial MW, bid availability, ramp
    # rates, FCAS enablement) are attached to each generator record.
    mkt_by_gid = Dict(string(x.gen_id) => x for x in eachrow(mapping))
    mlf_all = Dict((string(x.unit), string(x.dispatch_type)) => float(x.loss_factor)
                   for x in eachrow(mkt.unit_info))
    init_all = Dict(string(x.unit) => coalesce(x.initial_output, missing)
                    for x in eachrow(mkt.scada))
    for x in eachrow(mkt.ramp)
        ismissing(x.initial_output) || (init_all[string(x.unit)] = x.initial_output)
    end
    cap_all = Dict((string(x.unit), string(x.dispatch_type)) => coalesce(x.capacity, missing)
                   for x in eachrow(mkt.avail))
    rr_all = Dict((string(x.unit), string(x.dispatch_type)) =>
                  (x.ramp_up_rate, x.ramp_down_rate) for x in eachrow(mkt.ramp))
    fcas_t = Dict{String,Float64}()
    for x in eachrow(fcas_enablement)
        fcas_t[x.unit] = get(fcas_t, x.unit, 0.0) + x.enabled_mw
    end
    for (gid, g) in data["gen"]
        sg = get(get(sol, "gen", Dict()), gid, nothing)
        if sg !== nothing
            g["pg"] = get(sg, "pg", g["pg"]); g["qg"] = get(sg, "qg", get(g, "qg", 0.0))
        end
        m = get(mkt_by_gid, gid, nothing); m === nothing && continue
        k = (string(m.unit), string(m.dispatch_type))
        g["duid"] = string(m.unit); g["dispatch_type"] = string(m.dispatch_type)
        g["region"] = string(m.region); g["map_method"] = string(m.method)
        g["mlf"] = get(mlf_all, k, 1.0)
        g["initial_mw"] = get(init_all, string(m.unit), missing)
        g["bid_max_avail_mw"] = get(cap_all, k, missing)
        rr = get(rr_all, k, (missing, missing))
        g["bid_ramp_up_mw_per_h"] = rr[1]; g["bid_ramp_down_mw_per_h"] = rr[2]
        g["dispatch_mw"] = g["pg"] * data["baseMVA"]
        g["fcas_total_mw"] = get(fcas_t, string(m.unit), 0.0)
    end
    for (b, bus) in data["bus"]
        sb = get(get(sol, "bus", Dict()), b, nothing); sb === nothing && continue
        haskey(sb, "vm") && (bus["vm"] = sb["vm"])
        haskey(sb, "va") && (bus["va"] = sb["va"])
        bus["lmp"] = get(lmp, parse(Int, b), NaN)
        bus["region"] = get(REGION_OF_AREA, Int(bus["area"]), "")
    end
    for (i, br) in data["branch"]
        sb = get(get(sol, "branch", Dict()), i, nothing); sb === nothing && continue
        for f in ("pf", "pt", "qf", "qt"); haskey(sb, f) && (br[f] = sb[f]); end
    end
    for (i, dc) in get(data, "dcline", Dict())
        sd = get(get(sol, "dcline", Dict()), i, nothing); sd === nothing && continue
        for f in ("pf", "pt", "qf", "qt"); haskey(sd, f) && (dc[f] = sd[f]); end
    end

    return Dict{String, Any}(
        "data" => data,
        "formulation" => formulation,
        "status" => string(res["termination_status"]),
        # Retry provenance: the status of the FIRST attempt and how many were
        # made, so a retry is never silent - `first_status != status` marks an
        # interval that was recovered rather than one that simply solved.
        "first_status" => first_status,
        "solve_attempts" => n_attempts,
        "objective" => get(res, "objective", NaN),
        "solve_time" => tsolve,
        "losses_mw" => losses,
        "dcline_losses_mw" => dcl,
        "mlf_booked_losses_mw" => mlf_booked,
        # Priced violation of the nodal power balance: >0 unserved energy,
        # <0 dumped surplus. Non-zero here means the interval would previously
        # have returned INFEASIBLE with no prices at all, so ALWAYS check it
        # before reading the prices of such an interval.
        "balance_deficit_mw" => balance_deficit,
        "balance_deficit_by_region" => balance_by_region,
        "lmp" => lmp,
        "rrn" => rrn,
        "rrn_price" => rrn_price,
        "price_decomposition" => price_decomposition,
        "binding_constraints" => binding_constraints,
        "mapping" => mapping,
        "slack_by_penalty" => sdiag,
        "slack_report" => srep,
        "ramp_slacks" => rampv,
        "fcas_enablement" => fcas_enablement,
        "fcas_prices" => fcas_prices,
        "result" => res,
        "ctx" => ctx,
    )
end
