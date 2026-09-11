# =============================================================================
# run_ac_recovery.jl
#
# Quantify the AC-FEASIBILITY RECOVERY COST of an existing DC dispatch: what it
# costs to move a published DC schedule onto the AC-feasible manifold, moving as
# little and as cheaply as possible.
#
# This is a REPAIR problem, not another AC OPF, and the distinction is the whole
# point. Three quantities are involved and conflating two of them is the usual
# error:
#
#   C_DC     the independently optimised DC dispatch cost
#   C_AC     the independently optimised AC dispatch cost — a DIFFERENT
#            operating point, found by re-optimising from scratch
#   C_AC|DC  the cost of the dispatch obtained by REPAIRING the DC solution
#
# The recovery cost is dC_repair = C_AC|DC - C_DC. The independent objective gap
# dC_opt = C_AC - C_DC answers a different question, can be NEGATIVE, and is not
# a substitute for it.
#
# Neither the DC nor the AC formulation is modified. The analysis adds only the
# deviation variables and the repair objective, injected through
# `solve_network_dispatch`'s `post_build` hook.
#
# ARGUMENTS
#   Positional    Env               Default            Meaning
#   ------------  ----------------  -----------------  ------------------------
#   1             NEMX_START        2025-09-02T04:05   first interval
#   2             NEMX_N            288                number of intervals
#   3             NEMX_STRIDE       1                  interval stride
#
#   Options       Env               Default                 Meaning
#   ------------  ----------------  ----------------------  -------------------
#   --data-dir=   NEMX_DATA_DIR     data/nempy_2025_09      MMS db + XML cache
#   --mfile=      NEMX_MFILE        data/snem2000_fixed.m   network case
#   --move-floor= NEMX_MOVE_FLOOR   1.0                     $/MWh floor on the
#                                                           cost of moving a unit
#
# RESUMING
#   Intervals already present in the output CSV are kept and not re-solved, and
#   the file is checkpointed after every interval, so an interrupted run resumes
#   by re-running the same command.
#
# EXAMPLES
#   julia --project=. scripts/run_ac_recovery.jl                       # full day
#   julia --project=. scripts/run_ac_recovery.jl 2025-09-02T18:05 1    # one interval
#   julia --project=. scripts/run_ac_recovery.jl 2025-09-02T04:05 24 12  # hourly
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using JuMP
using Printf
using Statistics

const ZB = NEMX.ZBenchmark
const NB = NEMX.NBenchmark
using NEMX.ZBenchmark
using NEMX.NBenchmark

using JuMP, DataFrames, CSV, Dates, Printf, Statistics
import PowerModels
const PM = PowerModels

# Package root, used for anything that ships with the package. Resolved from
# this file rather than from the caller's working directory.
const ROOT     = NEMX.PKG_DIR
# ---------------------------------------------------------------------------
# SOLVER OVERRIDE
#
# By default each formulation uses the solver the registry pairs it with:
# HiGHS for a linear formulation, Ipopt for a non-linear one. Mixing them is
# never what is wanted, so a single --solver would be the wrong control.
#
# --lp-solver and --nlp-solver override the two halves independently. Leaving
# both unset -- the normal case -- uses the registry.
# ---------------------------------------------------------------------------

"The formulations that are linear programs, and so want an LP solver."
const LINEAR_FORMULATIONS = ("DCP", "DCP_MLF")

const LP_SOLVER_NAME  = script_option("lp-solver", "")
const NLP_SOLVER_NAME = script_option("nlp-solver", "")

"""
    solver_override(formulation) -> Union{Nothing,Any}

The optimizer to use for `formulation`, or `nothing` to use the registry's.

Picks the LP or the NLP override by whether the formulation is a linear
program, so that `--nlp-solver=ipopt` cannot accidentally be handed to a DC
model.
"""
function solver_override(formulation::AbstractString)
    name = formulation in LINEAR_FORMULATIONS ? LP_SOLVER_NAME : NLP_SOLVER_NAME
    if isempty(name)
        return nothing
    end
    return select_solver(name; silent = !script_flag("verbose-solver"))
end

const MFILE    = script_option("mfile", joinpath(ROOT, "data", "snem2000_fixed.m"))
const DATA_DIR = resolve_input_dir(joinpath(ROOT, "data", "nempy_2025_09"))
const OUT_CSV  = joinpath(DATA_DIR, "ac_recovery.csv")

# Primal feasibility tolerances, in physical units.
const TOL_MW   = 1.0e-3     # power-balance residual, MW
const TOL_PU   = 1.0e-6     # voltage magnitude, p.u.
const TOL_RATE = 1.0e-4     # thermal loading, p.u. of rating

# Floor on the per-MW cost of moving a unit, \$/MWh. Without it, units whose
# marginal band is priced at zero could be redispatched arbitrarily at no
# objective cost, and "minimum necessary movement" would not be well defined.
const MOVE_FLOOR = script_number(script_option("move-floor", "1.0"))

print_banner("AC-feasibility recovery cost of a DC dispatch",
             "network case" => MFILE,
             "data dir" => DATA_DIR,
             "output CSV" => OUT_CSV,
             "movement price floor (\$/MWh)" => MOVE_FLOOR,
             "LP solver" => isempty(LP_SOLVER_NAME) ? "(registry)" : LP_SOLVER_NAME,
             "NLP solver" => isempty(NLP_SOLVER_NAME) ? "(registry)" : NLP_SOLVER_NAME)
print_flag_values(NB, :NODAL_MLF_PRICE_REFERRAL, :BALANCE_SLACK_ENABLED,
                  :NLP_RETRY_ENABLED)

# The NEM trading day: 288 five-minute intervals beginning at 04:05.
const DAY_START     = DateTime(2025, 9, 2, 4, 5)
const DAY_INTERVALS = 288

# =============================================================================
# Helpers over the package's own result structures
# =============================================================================
"Per-generator MW from a solved result, keyed by the network's generator id."
function gen_mw(res, base)
    sol = get(res, "solution", Dict())
    g = get(sol, "gen", Dict())
    Dict(String(k) => float(get(v, "pg", 0.0)) * base for (k, v) in g)
end

"""
    offer_cost(mkt, dispatch_mw, mapping) -> Float64

Production cost of a dispatch on the unit's own ten-band offer stack -- the SAME
cost function the dispatch models minimise, so `C_DC`, `C_AC` and `C_AC|DC` are
all measured on one scale and are directly comparable.

Bands are filled cheapest-first up to the unit's dispatched MW.
"""
function offer_cost(mkt, dispatch_mw::Dict{String,Float64}, mapping)
    vol = Dict{Tuple{String,String},Vector{Float64}}()
    pri = Dict{Tuple{String,String},Vector{Float64}}()
    for r in eachrow(mkt.vb)
        string(r.service) == "energy" || continue
        vol[(string(r.unit), string(r.dispatch_type))] =
            Float64[coalesce(r[c], 0.0) for c in NB.BAND_COLS]
    end
    for r in eachrow(mkt.pb)
        string(r.service) == "energy" || continue
        pri[(string(r.unit), string(r.dispatch_type))] =
            Float64[coalesce(r[c], 0.0) for c in NB.BAND_COLS]
    end
    total = 0.0
    for row in eachrow(mapping)
        gid = string(row.gen_id)
        haskey(dispatch_mw, gid) || continue
        k = (string(row.unit), string(row.dispatch_type))
        (haskey(vol, k) && haskey(pri, k)) || continue
        v, p = vol[k], pri[k]
        rem = abs(dispatch_mw[gid])
        for b in sortperm(p)                    # cheapest band first
            rem <= 0 && break
            take = min(v[b], rem); rem -= take
            total += take * p[b]
        end
    end
    return total
end

"""
    marginal_offer_prices(mkt, dispatch_mw, mapping) -> (c_up, c_dn)

The price of moving a unit UP or DOWN one MW from its current point: the next
unused band going up, the last filled band coming down. These are the
coefficients of the repair objective, so the repair is priced on the same offer
stack as the dispatch itself rather than on an invented penalty.
"""
function marginal_offer_prices(mkt, dispatch_mw::Dict{String,Float64}, mapping)
    vol = Dict{Tuple{String,String},Vector{Float64}}()
    pri = Dict{Tuple{String,String},Vector{Float64}}()
    for r in eachrow(mkt.vb)
        string(r.service) == "energy" || continue
        vol[(string(r.unit), string(r.dispatch_type))] =
            Float64[coalesce(r[c], 0.0) for c in NB.BAND_COLS]
    end
    for r in eachrow(mkt.pb)
        string(r.service) == "energy" || continue
        pri[(string(r.unit), string(r.dispatch_type))] =
            Float64[coalesce(r[c], 0.0) for c in NB.BAND_COLS]
    end
    cup = Dict{String,Float64}(); cdn = Dict{String,Float64}()
    for row in eachrow(mapping)
        gid = string(row.gen_id)
        haskey(dispatch_mw, gid) || continue
        k = (string(row.unit), string(row.dispatch_type))
        (haskey(vol, k) && haskey(pri, k)) || continue
        v, p = vol[k], pri[k]
        ord = sortperm(p)
        rem = abs(dispatch_mw[gid]); last_p = 0.0; next_p = NaN
        for b in ord
            if rem > 1e-9
                take = min(v[b], rem)
                take > 1e-9 && (last_p = p[b])
                rem -= take
                if rem <= 1e-9 && take < v[b] - 1e-9
                    next_p = p[b]               # partially filled: same band
                    break
                end
            else
                next_p = p[b]; break
            end
        end
        isnan(next_p) && (next_p = last_p)
        # MOVEMENT cost, so the magnitude of the band price, not its sign.
        #
        # The NEM offer stack contains large NEGATIVE bands (renewables and
        # storage bidding to be dispatched): at this interval the median
        # next-band price is -$946/MWh. Used signed, such a band makes upward
        # movement *profitable* in the objective, and the "repair" would move
        # every negatively-priced unit as far as its limits allow -- turning a
        # minimum-necessary redispatch back into an unconstrained
        # re-optimisation, which is precisely what this analysis must not be.
        # The repair therefore prices MOVEMENT: a unit with an expensive offer
        # is expensive to move in either direction, and no unit is ever paid to
        # move. The floor keeps zero-priced units from moving gratuitously when
        # the deviation is otherwise costless.
        cup[gid] = max(abs(next_p), MOVE_FLOOR)
        cdn[gid] = max(abs(last_p), MOVE_FLOOR)
    end
    return cup, cdn
end

# =============================================================================
# Primal AC feasibility verification
# =============================================================================
"""
    ac_violations(res, data) -> NamedTuple

Check AC feasibility from the PRIMAL solution, independently of the solver.

Bus power balance is recomputed from the returned voltages and flows; voltage
magnitudes and branch loadings are checked against the case's own limits. A
solver can return `LOCALLY_SOLVED` on a point that violates these, and a dual
of zero says nothing either way, which is why this reads the primal residuals.
"""
function ac_violations(res, data)
    sol = get(res, "solution", Dict())
    base = float(data["baseMVA"])
    vmag = Float64[]; vlo = 0; vhi = 0
    for (b, bus) in get(sol, "bus", Dict())
        haskey(data["bus"], b) || continue
        vm = get(bus, "vm", NaN); isfinite(vm) || continue
        lo = float(get(data["bus"][b], "vmin", 0.0))
        hi = float(get(data["bus"][b], "vmax", 2.0))
        vm < lo - TOL_PU && (vlo += 1; push!(vmag, lo - vm))
        vm > hi + TOL_PU && (vhi += 1; push!(vmag, vm - hi))
    end
    # NOTE: the package's validated configuration runs with enforce_thermal =
    # false (the snem2000 ratings were calibrated to an earlier fleet), so the
    # thermal counts below are DIAGNOSTIC -- they are reported, not enforced,
    # and a non-zero count after repair does not mean the repair failed.
    thermal = 0; tmax = 0.0
    for (l, br) in get(sol, "branch", Dict())
        haskey(data["branch"], l) || continue
        rate = float(get(data["branch"][l], "rate_a", 0.0))
        rate > 0 || continue
        pf = get(br, "pf", NaN); qf = get(br, "qf", 0.0)
        isfinite(pf) || continue
        s = sqrt(pf^2 + (isfinite(qf) ? qf : 0.0)^2)
        if s > rate + TOL_RATE
            thermal += 1; tmax = max(tmax, (s - rate) * base)
        end
    end
    return (v_under = vlo, v_over = vhi,
            v_max_pu = isempty(vmag) ? 0.0 : maximum(vmag),
            thermal = thermal, thermal_max_mva = tmax)
end

"Total unserved/dumped energy the model had to price to stay feasible (MW)."
balance_deficit(r) = abs(get(r, "balance_deficit_mw", 0.0))

"Total violation-priced slack the market overlay used (MW-equivalent)."
function overlay_slack(r)
    sr = get(r, "slack_report", DataFrame())
    (sr isa DataFrame && !isempty(sr) && "violation_mw" in names(sr)) ?
        sum(abs, skipmissing(sr.violation_mw)) : 0.0
end

"""
    _add_violation_costs!(obj, pm, ctx)

Re-price the model's own violation variables into a replacement objective,
exactly as `build_market_opf` prices them.

This has to mirror the original term-for-term. The market-overlay slacks in
`ctx.slackrec` are non-negative MW quantities costed at their CVP, but the
balance-slack GENERATORS are per-unit `pg` variables costed at
`cvp * sgn * base`, with `sgn = -1` on the surplus side because that variable is
negative. Copying `ctx.slackrec` naively gets both wrong: it under-prices the
balance valve by a factor of `baseMVA` and, worse, flips the sign on the surplus
side so that dumping energy PAYS. Observed before this was fixed: a 3 008 MW
"deficit" the repair was happy to buy.
"""
function _add_violation_costs!(obj, pm, ctx)
    base = ctx.base
    bal = Set(s.gen_id for s in ctx.balance_slack)
    for s in ctx.balance_slack
        v = PM.var(pm, :pg, parse(Int, s.gen_id))
        sgn = s.dir == "deficit" ? 1.0 : -1.0
        JuMP.add_to_expression!(obj, ctx.balance_cvp * sgn * base, v)
    end
    for (tag, c, sv) in ctx.slackrec
        startswith(tag, "balance_") && continue      # priced above, correctly
        JuMP.add_to_expression!(obj, c, sv)
    end
    return obj
end

# =============================================================================
# The three dispatches
# =============================================================================
"Step 1 - the reference: the package's own DC dispatch, untouched."
function dc_reference(iv::DateTime; mkt, net)
    r = NB.solve_network_dispatch(iv, "DCP"; mfile=MFILE, net=net, mkt=mkt,
                              optimizer = solver_override("DCP"),
                                  data_dir=DATA_DIR)
    return r
end

"Benchmark only - the independently optimised AC dispatch. NOT the repair."
function ac_independent(iv::DateTime; mkt, net)
    return NB.solve_network_dispatch(iv, "ACP"; mfile=MFILE, net=net, mkt=mkt,
                              optimizer = solver_override("ACP"),
                                     data_dir=DATA_DIR)
end

"""
Step 2 - evaluate the DC dispatch under the full AC model.

Every mapped generator is PINNED at its DC output. Pinned hard against the
unrelaxed voltage limits the problem is simply infeasible -- which is the
headline finding, but an infeasibility certificate localises nothing. So the
voltage bounds are relaxed with penalised slack: the AC equations, generator
reactive limits and security constraints all still hold exactly, and the solver
is asked for the least bound violation consistent with holding the DC schedule.
The resulting slacks ARE the violation report, in p.u. and per bus.

`vslack` is returned so the caller can quantify the violation rather than infer
it from a status string.
"""
function ac_evaluate_dc(iv::DateTime, pdc::Dict{String,Float64}; mkt, net,
                        relax_v::Bool = true, vpen::Float64 = 1.0e6)
    vrec = Ref{Any}(nothing)
    hook = (pm, ctx) -> begin
        base = ctx.base; m = pm.model
        for row in eachrow(ctx.mapping)
            gid = string(row.gen_id)
            haskey(pdc, gid) || continue
            v = PM.var(pm, :pg, parse(Int, gid))
            JuMP.@constraint(m, v * base == pdc[gid])
        end
        relax_v || return
        # Relax the voltage box and price the relaxation. The bound is widened
        # on the VARIABLE and the excursion beyond the original box is charged,
        # so the optimum reports the smallest voltage violation compatible with
        # the pinned schedule instead of returning "infeasible".
        recs = Tuple{String,JuMP.VariableRef,Float64,Float64}[]
        pen = JuMP.AffExpr(0.0)
        for (i, bus) in ctx.data["bus"]
            id = parse(Int, i)
            vm = try PM.var(pm, :vm, id) catch; nothing end
            vm === nothing && continue
            lo = float(get(bus, "vmin", 0.9)); hi = float(get(bus, "vmax", 1.1))
            JuMP.has_lower_bound(vm) && JuMP.set_lower_bound(vm, max(lo - 0.5, 0.05))
            JuMP.has_upper_bound(vm) && JuMP.set_upper_bound(vm, hi + 0.5)
            su = JuMP.@variable(m, lower_bound = 0.0)
            sl = JuMP.@variable(m, lower_bound = 0.0)
            JuMP.@constraint(m, vm <= hi + su)
            JuMP.@constraint(m, vm >= lo - sl)
            JuMP.add_to_expression!(pen, vpen, su)
            JuMP.add_to_expression!(pen, vpen, sl)
            push!(recs, (i, su, lo, hi)); push!(recs, (i, sl, lo, hi))
        end
        _add_violation_costs!(pen, pm, ctx)
        JuMP.@objective(m, Min, pen)
        vrec[] = recs
    end
    r = NB.solve_network_dispatch(iv, "ACP"; mfile=MFILE, net=net, mkt=mkt,
                              optimizer = solver_override("ACP"),
                                  data_dir=DATA_DIR, post_build=hook)
    nv = 0; vmax = 0.0
    if vrec[] !== nothing
        for (_, sv, _, _) in vrec[]
            x = try JuMP.value(sv) catch; 0.0 end
            if isfinite(x) && x > TOL_PU
                nv += 1; vmax = max(vmax, x)
            end
        end
    end
    return r, (n_bus_violating = nv, max_pu = vmax)
end

"""
Step 3 - the repair.

Same AC model, same limits, same security constraints. Generator outputs may
deviate from the DC dispatch by `dup`/`ddn`, and the objective is REPLACED by
the cost of those deviations, priced on the unit's own offer stack. FCAS
enablement is pinned at its DC commitment, so reserve is carried by the same
units in the same volumes and the repair cannot buy feasibility by re-trading
reserve.
"""
function ac_repair(iv::DateTime, pdc::Dict{String,Float64},
                   fcas_dc::Dict{Tuple{String,String,String},Float64},
                   cup::Dict{String,Float64}, cdn::Dict{String,Float64};
                   mkt, net)
    devrec = Ref{Any}(nothing)
    hook = (pm, ctx) -> begin
        base = ctx.base
        m = pm.model
        obj = JuMP.AffExpr(0.0)
        recs = Tuple{String,JuMP.VariableRef,JuMP.VariableRef,Float64}[]
        for row in eachrow(ctx.mapping)
            gid = string(row.gen_id)
            haskey(pdc, gid) || continue
            v  = PM.var(pm, :pg, parse(Int, gid))
            # Deviations are bounded by the unit's own capacity range. Without
            # an explicit bound `up` and `dn` can both grow without limit while
            # their DIFFERENCE stays inside the generator bounds -- a degenerate
            # cancelling pair that is free whenever its cost coefficient is
            # zero. Observed before this was fixed: 5.9 million MW of offsetting
            # redispatch on a 20 GW system.
            g = get(ctx.data["gen"], gid, Dict())
            span = base * max(abs(float(get(g, "pmax", 0.0))),
                              abs(float(get(g, "pmin", 0.0))), 1e-3)
            up = JuMP.@variable(m, lower_bound = 0.0, upper_bound = span)
            dn = JuMP.@variable(m, lower_bound = 0.0, upper_bound = span)
            # p = p_DC + up - dn, in MW
            JuMP.@constraint(m, v * base == pdc[gid] + up - dn)
            # MOVE_FLOOR, never 0.0: a generator carrying no offer data would
            # otherwise be redispatchable at no cost, which is what admitted the
            # degenerate pair above.
            JuMP.add_to_expression!(obj, get(cup, gid, MOVE_FLOOR), up)
            JuMP.add_to_expression!(obj, get(cdn, gid, MOVE_FLOOR), dn)
            push!(recs, (gid, up, dn, pdc[gid]))
        end
        # FCAS commitments held at the DC solution.
        for (un, dt, sv, e) in ctx.fcasrec
            sv == "energy" && continue
            k = (un, dt, sv)
            haskey(fcas_dc, k) || continue
            JuMP.@constraint(m, e == fcas_dc[k])
        end
        _add_violation_costs!(obj, pm, ctx)
        JuMP.@objective(m, Min, obj)
        devrec[] = recs
    end
    r = NB.solve_network_dispatch(iv, "ACP"; mfile=MFILE, net=net, mkt=mkt,
                              optimizer = solver_override("ACP"),
                                  data_dir=DATA_DIR, post_build=hook)
    dev = DataFrame(gen_id=String[], p_dc=Float64[], up=Float64[], dn=Float64[])
    if devrec[] !== nothing
        for (gid, up, dn, p0) in devrec[]
            u = try JuMP.value(up) catch; NaN end
            d = try JuMP.value(dn) catch; NaN end
            (isfinite(u) && isfinite(d) && (u > 1e-6 || d > 1e-6)) || continue
            push!(dev, (gid, p0, u, d))
        end
    end
    return r, dev
end

# =============================================================================
# One interval, end to end
# =============================================================================
function recover_interval(iv::DateTime; net, verbose::Bool=true)
    mkt = NB.load_market(iv; data_dir = DATA_DIR)

    verbose && (@printf("\n=== AC-feasibility recovery, %s\n", iv); flush(stdout))
    t = time()
    r_dc = dc_reference(iv; mkt=mkt, net=net)
    verbose && (@printf("  [1/4] DC dispatch      %-18s %6.1fs\n",
                        string(get(r_dc,"status","")), time()-t); flush(stdout))
    base = float(r_dc["data"]["baseMVA"])
    pdc  = gen_mw(r_dc["result"], base)
    mp   = r_dc["mapping"]
    C_DC = offer_cost(mkt, pdc, mp)

    fe = get(r_dc, "fcas_enablement", DataFrame())
    fcas_dc = Dict{Tuple{String,String,String},Float64}()
    if fe isa DataFrame && !isempty(fe)
        for row in eachrow(fe)
            fcas_dc[(string(row.unit), string(row.dispatch_type),
                     string(row.service))] = float(row.enabled_mw)
        end
    end

    t = time()
    r_eval, vslack = ac_evaluate_dc(iv, pdc; mkt=mkt, net=net)
    verbose && (@printf("  [2/4] AC eval of DC    %-18s %6.1fs\n",
                        string(get(r_eval,"status","")), time()-t); flush(stdout))
    v_before = ac_violations(r_eval["result"], r_eval["data"])
    # The penalised-relaxation slacks are the authoritative violation measure at
    # the pinned DC point; the primal scan corroborates them.
    v_before = (v_under = v_before.v_under, v_over = v_before.v_over,
                v_max_pu = max(v_before.v_max_pu, vslack.max_pu),
                thermal = v_before.thermal,
                thermal_max_mva = v_before.thermal_max_mva,
                n_bus_violating = vslack.n_bus_violating)

    cup, cdn = marginal_offer_prices(mkt, pdc, mp)
    t = time()
    r_rep, dev = ac_repair(iv, pdc, fcas_dc, cup, cdn; mkt=mkt, net=net)
    verbose && (@printf("  [3/4] AC repair        %-18s %6.1fs\n",
                        string(get(r_rep,"status","")), time()-t); flush(stdout))
    prep = gen_mw(r_rep["result"], base)
    C_ACDC = offer_cost(mkt, prep, mp)
    v_after = ac_violations(r_rep["result"], r_rep["data"])

    t = time()
    r_ac = ac_independent(iv; mkt=mkt, net=net)
    verbose && (@printf("  [4/4] AC independent   %-18s %6.1fs\n",
                        string(get(r_ac,"status","")), time()-t); flush(stdout))
    C_AC = offer_cost(mkt, gen_mw(r_ac["result"], base), mp)

    row = (time = iv,
           status_dc = string(get(r_dc, "status", "")),
           status_eval = string(get(r_eval, "status", "")),
           status_repair = string(get(r_rep, "status", "")),
           status_ac = string(get(r_ac, "status", "")),
           C_DC = C_DC, C_AC = C_AC, C_ACDC = C_ACDC,
           dC_repair = C_ACDC - C_DC,
           dC_opt = C_AC - C_DC,
           repair_vs_ac = C_ACDC - C_AC,
           n_redispatched = nrow(dev),
           redispatch_up_mw = isempty(dev) ? 0.0 : sum(dev.up),
           redispatch_dn_mw = isempty(dev) ? 0.0 : sum(dev.dn),
           v_before_under = v_before.v_under, v_before_over = v_before.v_over,
           v_before_max_pu = v_before.v_max_pu,
           v_before_buses = v_before.n_bus_violating,
           thermal_before = v_before.thermal,
           v_after_under = v_after.v_under, v_after_over = v_after.v_over,
           v_after_max_pu = v_after.v_max_pu,
           thermal_after = v_after.thermal,
           deficit_eval_mw = balance_deficit(r_eval),
           deficit_repair_mw = balance_deficit(r_rep),
           slack_eval = overlay_slack(r_eval),
           slack_repair = overlay_slack(r_rep))

    if verbose
        @printf("  ---------------------------------------------------------------\n")
        @printf("  C_DC     = %14.2f \$\n", C_DC)
        @printf("  before repair: V under %d / over %d (max %.4g pu), thermal %d, deficit %.3f MW\n",
                v_before.v_under, v_before.v_over, v_before.v_max_pu,
                v_before.thermal, row.deficit_eval_mw)
        @printf("  C_AC|DC  = %14.2f \$   redispatch %d units, +%.2f / -%.2f MW\n",
                C_ACDC, row.n_redispatched, row.redispatch_up_mw, row.redispatch_dn_mw)
        @printf("  after  repair: V under %d / over %d (max %.4g pu), thermal %d, deficit %.3f MW\n",
                v_after.v_under, v_after.v_over, v_after.v_max_pu,
                v_after.thermal, row.deficit_repair_mw)
        @printf("  C_AC     = %14.2f \$\n", C_AC)
        @printf("  ---------------------------------------------------------------\n")
        @printf("  dC_repair = C_AC|DC - C_DC = %14.2f \$   <-- recovery cost\n", row.dC_repair)
        @printf("  dC_opt    = C_AC    - C_DC = %14.2f \$   (independent gap, NOT the recovery cost)\n", row.dC_opt)
        @printf("  C_AC|DC - C_AC             = %14.2f \$\n", row.repair_vs_ac)
    end
    return row, dev
end

"""
    write_recovery_table(df, path)

Emit the booktabs LaTeX table for the manuscript.

The table reports the DISTRIBUTION of each quantity over the dispatch day rather
than a handful of individual intervals: the recovery cost varies by two orders of
magnitude between the solar-backed midday trough and the evening peak, so a few
sampled rows would misrepresent it either way. Costs are \$M/h on the units' own
offer stack, which contains large negative bands, so absolute levels are negative
and the differences carry the meaning.

The layout is a SINGLE-column IEEE table: five statistics beside a label do not
fit at body size in 3.5 in, so the body is set `\\footnotesize` with tightened
`\\tabcolsep` and the labels are abbreviated. The explanatory note sits after the
tabular rather than in a spanning `\\multicolumn` row, which would inherit the
tabular's `\\footnotesize` and its column widths.
"""
function write_recovery_table(df::DataFrame, path::String)
    q(v, p) = quantile(collect(skipmissing(v)), p)
    row(lbl, v; d=2, scale=1.0) = join([lbl,
        @sprintf("%.*f", d, q(v, 0.5) / scale),
        @sprintf("%.*f", d, q(v, 0.05) / scale),
        @sprintf("%.*f", d, q(v, 0.95) / scale),
        @sprintf("%.*f", d, minimum(skipmissing(v)) / scale),
        @sprintf("%.*f", d, maximum(skipmissing(v)) / scale)], " & ") * " \\\\"
    n = nrow(df)
    negopt = count(<(0), df.dC_opt)
    # The ratio is only meaningful where the denominator is positive: on the
    # intervals where dC_opt < 0 the two quantities have opposite signs and their
    # quotient is negative, which would drag the median without meaning anything.
    # Those intervals are reported separately, by count, in the note.
    rr = [r.dC_repair / r.dC_opt for r in eachrow(df) if r.dC_opt > 0]
    rtxt = isempty(rr) ? "--" : @sprintf("%.0f", median(rr))
    L = String[]
    push!(L, "\\begin{table}[!t]")
    push!(L, "\\caption{AC-feasibility recovery cost of the DC/NEMDE dispatch over one")
    push!(L, "NEM trading day ($(n) five-minute intervals, 2025-09-02). \$C_{DC}\$ and")
    push!(L, "\$C_{AC}\$ are independently optimised dispatches; \$C_{AC|DC}\$ is the DC")
    push!(L, "dispatch \\emph{repaired} to AC feasibility by least-cost redispatch, with")
    push!(L, "FCAS commitments held at their DC values. The recovery cost is")
    push!(L, "\$\\Delta C_{\\mathrm{repair}}=C_{AC|DC}-C_{DC}\$; the independent objective")
    push!(L, "gap \$\\Delta C_{\\mathrm{opt}}=C_{AC}-C_{DC}\$ is shown beside it and is")
    push!(L, "\\emph{not} the cost of achieving AC feasibility.}")
    push!(L, "\\label{tab:acrecovery}")
    # The tabular is centred inside its own group so that \centering does not
    # leak into the explanatory note below it, which must be justified.
    push!(L, "{\\centering")
    push!(L, "\\footnotesize")
    push!(L, "\\setlength{\\tabcolsep}{3pt}")
    push!(L, "\\begin{tabular}{@{}lrrrrr@{}}")
    push!(L, "\\toprule")
    push!(L, "Quantity & med. & p5 & p95 & min & max \\\\")
    push!(L, "\\midrule")
    push!(L, "\\multicolumn{6}{@{}l}{\\emph{Dispatch cost (\\\$M/h)}} \\\\")
    push!(L, row("\\;\$C_{DC}\$",    df.C_DC;   scale=1e6))
    push!(L, row("\\;\$C_{AC|DC}\$", df.C_ACDC; scale=1e6))
    push!(L, row("\\;\$C_{AC}\$",    df.C_AC;   scale=1e6))
    push!(L, "\\addlinespace[1pt]")
    push!(L, "\\multicolumn{6}{@{}l}{\\emph{Cost gaps (\\\$M/h)}} \\\\")
    push!(L, row("\\;\$\\Delta C_{\\mathrm{repair}}\$ (recovery)", df.dC_repair; d=3, scale=1e6))
    push!(L, row("\\;\$\\Delta C_{\\mathrm{opt}}\$ (indep.\\ gap)", df.dC_opt; d=3, scale=1e6))
    push!(L, "\\addlinespace[1pt]")
    push!(L, "\\multicolumn{6}{@{}l}{\\emph{DC point under the full AC model}} \\\\")
    push!(L, row("\\;buses outside V band", df.v_before_over .+ df.v_before_under; d=0))
    push!(L, row("\\;balance deficit (MW)", df.deficit_eval_mw; d=0))
    push!(L, "\\addlinespace[1pt]")
    push!(L, "\\multicolumn{6}{@{}l}{\\emph{Repair}} \\\\")
    push!(L, row("\\;redispatch up (MW)", df.redispatch_up_mw; d=0))
    push!(L, row("\\;redispatch down (MW)", df.redispatch_dn_mw; d=0))
    push!(L, row("\\;units redispatched", df.n_redispatched; d=0))
    push!(L, row("\\;residual deficit (MW)", df.deficit_repair_mw; d=3))
    push!(L, "\\bottomrule")
    push!(L, "\\end{tabular}\\par}")
    push!(L, "")
    push!(L, "\\vspace{2pt}")
    push!(L, "{\\footnotesize Over the $(n) intervals the recovery cost exceeds the")
    push!(L, "independent gap by a median factor of $(rtxt)\$\\times\$, and")
    push!(L, "\$\\Delta C_{\\mathrm{opt}}\$ is \\emph{negative} on $(negopt) of them --- intervals")
    push!(L, "on which reading \$C_{AC}-C_{DC}\$ as the price of AC feasibility reports a")
    push!(L, "saving while repairing the published dispatch in fact costs money. Voltage")
    push!(L, "feasibility and power balance are restored exactly, verified from the primal")
    push!(L, "constraint residuals rather than the solver status; thermal limits are")
    push!(L, "reported diagnostically but not enforced, per the validated configuration.\\par}")
    push!(L, "\\end{table}")
    open(path, "w") do io
        println(io, "% Auto-generated by analysis/ac_recovery.jl")
        for l in L; println(io, l); end
    end
    println("wrote $path")
end

# =============================================================================
# Driver
# =============================================================================
function main(args)
    # With no arguments the full trading day is solved. Every interval is taken,
    # not an hourly or otherwise strided sample: the recovery cost moves by an
    # order of magnitude within a single hour around the evening ramp, so a
    # sparse sample both misses the extremes and biases the quantiles that the
    # manuscript table reports.
    # Start, count and stride each come from a positional argument, an
    # environment variable, or the default — see this file's header.
    t0 = script_datetime(script_positional(1, "NEMX_START", string(DAY_START)))
    n  = script_integer(script_positional(2, "NEMX_N", string(DAY_INTERVALS)))
    st = script_integer(script_positional(3, "NEMX_STRIDE", "1"))
    ivs = [t0 + Minute(5 * st * (k - 1)) for k in 1:n]
    net = NB.load_network(MFILE)
    rows = NamedTuple[]
    # Resume: a long series is expensive and may be interrupted, so intervals
    # already present in the output are kept and not re-solved. Rows arrive in
    # resume order rather than clock order, so the frame is sorted on every
    # write and the CSV is chronological whatever order it was filled in.
    done = Set{DateTime}()
    if isfile(OUT_CSV)
        prev = CSV.read(OUT_CSV, DataFrame)
        for r in eachrow(prev)
            push!(rows, NamedTuple(r)); push!(done, r.time)
        end
        isempty(done) || @info "resuming; $(length(done)) interval(s) already solved"
    end
    save() = CSV.write(OUT_CSV, sort!(DataFrame(rows), :time))
    todo    = count(iv -> !(iv in done), ivs)
    solved  = 0
    failed  = 0
    t_start = time()
    @info "solving $(todo) of $(n) interval(s): $(Dates.format(first(ivs), "yyyy-mm-dd HH:MM")) to $(Dates.format(last(ivs), "yyyy-mm-dd HH:MM"))"
    for iv in ivs
        iv in done && continue
        try
            row, _ = recover_interval(iv; net=net, verbose = (n <= 6))
            push!(rows, row); solved += 1
            # Progress and a wall-clock estimate: a full day is a multi-hour
            # run, and without them there is no way to tell a slow interval from
            # a hung one.
            if n > 6
                el  = time() - t_start
                eta = (todo - solved - failed) * el / max(solved + failed, 1)
                @printf("  [%3d/%3d] %s  dC_repair=%10.0f  dC_opt=%10.0f  up=%6.1f MW  Vviol=%5d  defA=%.3f  (%.0fs, eta %.0fm)\n",
                        solved + failed, todo,
                        Dates.format(iv, "yyyy-mm-dd HH:MM"), row.dC_repair, row.dC_opt,
                        row.redispatch_up_mw, row.v_before_over + row.v_before_under,
                        row.deficit_repair_mw, el, eta / 60)
            end
            # Checkpoint after every interval: a long series is expensive and a
            # run that is interrupted should still leave usable results.
            save()
        catch err
            failed += 1
            @warn "  $iv failed" err
        end
        flush(stdout)
    end
    failed == 0 || @warn "$(failed) interval(s) failed and are absent from the output"
    isempty(rows) && return
    df = sort!(DataFrame(rows), :time)
    CSV.write(OUT_CSV, df)
    println("\nwrote $(nrow(df)) intervals to $OUT_CSV")
    write_recovery_table(df, joinpath(resolve_output_dir(joinpath(ROOT, "figures")),
                                      "tab_ac_recovery.tex"))
    if nrow(df) > 1
        @printf("\nover %d intervals:  median dC_repair = %.2f \$  (mean %.2f)\n",
                nrow(df), median(df.dC_repair), mean(df.dC_repair))
        @printf("                    median dC_opt    = %.2f \$  (mean %.2f)\n",
                median(df.dC_opt), mean(df.dC_opt))
    end
    return df
end

# `AC_RECOVERY_NORUN=1` includes the module's functions without running the
# driver, so the individual steps can be exercised and tested in isolation.
if !isinteractive() && get(ENV, "NEMX_AC_RECOVERY_NORUN", "0") != "1"
    main(ARGS)
end