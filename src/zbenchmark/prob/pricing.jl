# =============================================================================
# pricing.jl
#
# Post-solve pricing: lazy loss-adjacency tightening, MIP re-pricing, and the
# two opt-in dual-refinement switches.
#
# Split out of the single-file `spot_market.jl` of the reference
# implementation. The code is unchanged; only its location is. All of these
# files are `include`d into the same `ZBenchmark` module, so definition order
# across them does not matter.
# =============================================================================

# region but lets it branch on the set directly, which is dramatically cheaper.
_add_sos2_native!(model, λ) = @constraint(model, λ in SOS2())

# Lazy tightening: after an LP solve, find links whose interpolation weights are
# NON-ADJACENT (the solution fabricates losses — profitable only at negative
# prices) or MNSP link pairs flowing simultaneously; add the SOS2 binaries /
# SOS1-style pair exclusivity just for those and re-solve. Repeats until clean.
"""
Diagnostic switch. `true` (default) reproduces AEMO/nempy behaviour: SOS2/SOS1
adjacency is lazily enforced on the interconnector loss interpolation. Set to
`false` ONLY to isolate the pure-LP relaxation when debugging a slow or
suspicious interval — the resulting prices are NOT benchmark-valid at negative
regional prices (that is exactly the case the tightening exists to fix).
"""
const LAZY_LOSS_TIGHTENING = Ref(true)
"Print per-iteration diagnostics from the lazy loss tightening."
const LAZY_LOSS_VERBOSE = Ref(false)

"""
Wall-clock seconds allowed for each loss-adjacency re-solve. AEMO loss curves
carry 60-120 breakpoints per link; when several links need tightening at once
(typical when regional prices go deeply negative) the resulting MIP can fail to
close. Bounding it makes the run deterministic: if the limit is hit the model
reverts to the LP relaxation for that interval and still returns valid duals,
instead of returning NaN or pricing off a poor incumbent. Set to `nothing` for
no limit.
"""
const LOSS_TIGHTEN_TIME_LIMIT = Ref{Union{Nothing,Float64}}(30.0)

function _tighten_loss_interpolation!(model, m::SpotMarket, loss_links, obj)
    sos_cons = Any[]; sos_lams = Any[]
    (isempty(loss_links) || !LAZY_LOSS_TIGHTENING[]) && return sos_cons, sos_lams
    # CRITICAL (2025-09 fix): the adjacency MIP must be solved to (near-)exact
    # optimality. Solver DEFAULT relative gaps (HiGHS mip_rel_gap = 1e-4) are
    # relative to the FULL objective — which includes CVP penalty terms of up to
    # 1e7-1e9 — so the default tolerance permits an absolute gap of thousands of
    # dollars, far larger than the price-forming detail. The observed failure
    # mode (Sept-2025 negative-price intervals): HiGHS stops at a poor incumbent
    # whose flows differ from the optimum by hundreds of MW; the pricing pass
    # then fixes THAT incumbent's SOS2 supports and prices it (NSW1 \$299.99 vs
    # NEMDE -\$12.66; QLD raise-6s \$14,500 vs \$0.10). With an exact gap the
    # same MIP converges in seconds and reprices to within \$0.1 of NEMDE.
    # NOTE: attributes are set lazily (just before the first tightened re-solve)
    # because MOI attribute-setting invalidates the cached solution.
    gap_set = Ref(false)
    _set_exact_gap!() = begin
        gap_set[] && return
        for (attr, val) in (("mip_rel_gap", 0.0), ("mip_abs_gap", 1e-3))
            try
                set_optimizer_attribute(model, attr, val)
            catch
            end
        end
        gap_set[] = true
    end
    # ic -> [(F,z)]. F is a VariableRef for a single-variable link flow but an
    # AffExpr for an MNSP link whose flow is built from priced bands (see
    # _add_interconnectors!), hence the AbstractJuMPScalar element type.
    pair_z = Dict{String,Vector{Tuple{JuMP.AbstractJuMPScalar,VariableRef}}}()
    last_batch = Any[]   # constraints added by the most recent batch only
    for _ in 1:4
        # If a tightened solve failed (e.g. the MIP hit a limit), ROLL BACK the
        # most recent batch only — earlier converged batches remain in force —
        # and restore the last good solution rather than leaving the model in an
        # unsolved state (otherwise repricing yields NaN prices).
        if !(termination_status(model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED))
            if !isempty(last_batch)
                @warn "loss-adjacency solve did not converge ($(termination_status(model))); dropping the last adjacency batch for this interval"
                for c in last_batch
                    delete(model, c)
                    deleteat!(sos_cons, findall(x -> x === c, sos_cons))
                end
                nlam = length(sos_cons)
                length(sos_lams) > nlam && resize!(sos_lams, nlam)
                empty!(last_batch)
                optimize!(model)
            end
            return sos_cons, sos_lams
        end
        empty!(last_batch)
        # Read ALL solution values BEFORE modifying the model (any modification
        # invalidates the stored solution).
        bad_links = Any[]
        for L in loss_links
            (L.λ === nothing || L.tightened[]) && continue
            vals = value.(L.λ)
            nz = findall(v -> v > 1e-6, vals)
            adjacent = isempty(nz) || (maximum(nz) - minimum(nz) <= 1)
            adjacent || push!(bad_links, L)
        end
        byic = Dict{String,Vector{Any}}()
        for L in loss_links
            L.link != L.ic && push!(get!(byic, L.ic, Any[]), L)
        end
        bad_pairs = Any[]
        for (ic, ls) in byic
            (length(ls) > 1 && !haskey(pair_z, ic)) || continue
            count(L -> value(L.F) > 1e-4, ls) > 1 && push!(bad_pairs, (ic, ls))
        end
        if LAZY_LOSS_VERBOSE[]
            @info "lazy-tighten iteration" bad_links=length(bad_links) bad_pairs=length(bad_pairs) obj=objective_value(model)
            for L in bad_links
                @info "  bad link" ic=L.ic link=L.link nlam=length(L.λ) nbps=length(L.bps) F=value(L.F)
            end
            flush(stdout)
        end
        isempty(bad_links) && isempty(bad_pairs) && return sos_cons, sos_lams
        # Now modify. When ANY link needs tightening, enforce adjacency on ALL
        # (untightened) loss links in one shot: at negative prices the
        # fabrication typically spreads across several interconnectors, and the
        # per-link lazy iteration solved a fresh MIP per batch. One MIP with
        # every SOS2 set matches nempy's semantics (it declares SOS2 on all
        # loss weights up front) and converges in a single re-solve.
        _set_exact_gap!()
        if !isempty(bad_links)
            for L in loss_links
                (L.λ === nothing || L.tightened[]) && continue
                c = _add_sos2_native!(model, L.λ)
                push!(sos_cons, c); push!(last_batch, c)
                push!(sos_lams, L.λ)
                L.tightened[] = true
            end
        end
        for (ic, ls) in bad_pairs
            zs = Tuple{JuMP.AbstractJuMPScalar,VariableRef}[]
            for L in ls
                z = @variable(model, binary = true)
                @constraint(model, L.F <= L.hi * z)
                push!(zs, (L.F, z))
            end
            @constraint(model, sum(z for (_, z) in zs) <= 1)
            pair_z[ic] = zs
        end
        optimize!(model)
    end
    return sos_cons, sos_lams
end

# Fix integer/binary variables at their optimal values and re-solve as a pure
# LP so that dual prices become available (AEMO's pricing run). SOS2 sets are
# handled the same way: the weights that are zero at the optimum are fixed to
# zero and the SOS2 constraints are deleted, which pins the active segment and
# leaves a pure LP — exactly the restriction the binary formulation imposed.
function _reprice_if_mip!(model, sos_cons = (), sos_lams = ())
    termination_status(model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) || return
    bins = filter(is_binary,  all_variables(model))
    ints = filter(is_integer, all_variables(model))
    (isempty(bins) && isempty(ints) && isempty(sos_cons)) && return
    bin_vals = [(v, round(value(v))) for v in bins]
    int_vals = [(v, round(value(v))) for v in ints]
    # Capture the SOS2 support BEFORE touching the model (any modification
    # invalidates the stored solution).
    lam_zero = VariableRef[]
    for λ in sos_lams, v in λ
        value(v) <= 1e-9 && push!(lam_zero, v)
    end
    for (v, val) in bin_vals
        unset_binary(v);  fix(v, val; force=true)
    end
    for (v, val) in int_vals
        unset_integer(v); fix(v, val; force=true)
    end
    for c in sos_cons
        delete(model, c)
    end
    for v in lam_zero
        fix(v, 0.0; force=true)
    end
    optimize!(model)
    return
end

# --- FCAS requirement dual refinement (CVP priority) --------------------------
"""
Resolve dual degeneracy among FCAS requirement constraints in AEMO's favour.

Where several FCAS requirement constraints share a term (typically the same
interconnector flow) the LP pins only the SUM of their duals; the split between
them is a free parameter and the solver lands on an arbitrary corner. Observed
2025-09-04 08:20 in Queensland, whose three lower-service constraints are
structurally identical apart from the service they carry:

    F_Q++BCDM_L6  : NSW1-QLD1 flow + QLD lower_6s  >= RHS   (CVP 162 400)
    F_Q++BCDM_L60 : NSW1-QLD1 flow + QLD lower_60s >= RHS   (CVP 121 800)

Both bind, the primal is exact (400 MW each, matching NEMDE), and the duals
satisfy mu6 + mu60 = 69.63 with mu6 in [19.95, 37.63], mu60 in [32.00, 49.68].
Our solver reports (19.95, 49.68); AEMO publishes (37.63, 32.00).

AEMO's values are reproduced by allocating dual mass in DESCENDING VIOLATION
PRICE order — the constraint that is more expensive to violate takes precedence:
the highest-CVP degenerate constraint receives its maximum feasible dual (the
RIGHT derivative of the objective with respect to its right-hand side) and the
remaining degenerate constraints receive their minimum (the LEFT derivative).

Degeneracy is detected per constraint as a KINK: right and left derivatives
differ. Non-degenerate constraints keep the solver's dual untouched, so this
pass is a no-op wherever the price was already unique — which is every FCAS
constraint in the July-2024 benchmark.

!!! warning "REJECTED HYPOTHESIS — do not enable for production runs"
    This rule reproduced AEMO exactly on the interval it was derived from
    (2025-09-04 08:20) but was falsified by a 1 000-interval sweep: overall FCAS
    disparity INCREASED, Tasmania lower-regulation mismatches appeared where
    there had been none, and the Queensland lower-service mismatch persisted.
    It was over-fitted to a single interval. The kept code is a diagnostic for
    identifying degenerate FCAS requirement groups, not a pricing rule; it is
    no longer called from `dispatch!`.

    The sweep also showed why it could not have worked in general: the residual
    Queensland mismatch is NOT a dual-degeneracy problem at all (see the
    interconnector-coupling note in `_add_generic_constraints!`).

Costs two extra LP re-solves per binding FCAS requirement.
"""
const FCAS_DUAL_CVP_PRIORITY = Ref(false)
# A line `FCAS_DUAL_CVP_PRIORITY[] = true` sat here, immediately below the
# declaration and immediately below a docstring that calls the rule a rejected
# hypothesis and says not to enable it. It had no effect on any result, because
# `_refine_fcas_duals_by_cvp!` is not called from `dispatch!` — but it left the
# flag reading `true` for anyone who inspected it, which is the opposite of what
# the documentation promises. Removed.
function _refine_fcas_duals_by_cvp!(model, m::SpotMarket; eps_mw::Float64=1.0,
                                    tol::Float64=1e-6)
    empty!(m.fcas_dual_override)
    FCAS_DUAL_CVP_PRIORITY[] || return
    termination_status(model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) || return
    isempty(m.generic_con_refs) && return
    vp = Dict(string(r.set) => coalesce(_num(r.violation_price), m.generic_cost)
              for r in eachrow(m.generic_rhs) if :violation_price in propertynames(r))

    # Binding FCAS-requirement constraints (those carrying region-service terms).
    cand = Tuple{String,Any,Float64}[]        # (set, cref, cvp)
    for (set, tup) in m.generic_con_refs
        cref, lhs, rhs, typ, svs, has_region = tup[1:6]
        has_region || continue
        lv = try value(lhs) catch; continue end
        abs(lv - rhs) <= 1e-4 * max(1.0, abs(rhs)) || continue
        push!(cand, (set, cref, get(vp, set, m.generic_cost)))
    end
    isempty(cand) && return

    obj0 = objective_value(model)
    # One-sided derivatives (read every value before the next perturbation).
    deriv = Dict{String,Tuple{Float64,Float64}}()   # set -> (left, right)
    for (set, cref, _) in cand
        r0 = normalized_rhs(cref)
        d = Float64[]
        for e in (eps_mw, -eps_mw)
            set_normalized_rhs(cref, r0 + e)
            optimize!(model)
            push!(d, termination_status(model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) ?
                     (objective_value(model) - obj0) / e : NaN)
            set_normalized_rhs(cref, r0)
        end
        (isfinite(d[1]) && isfinite(d[2])) && (deriv[set] = (d[2], d[1]))  # (left, right)
    end
    optimize!(model)      # restore the unperturbed optimum

    degen = [(s, c, p) for (s, c, p) in cand
             if haskey(deriv, s) && abs(deriv[s][2] - deriv[s][1]) > tol]
    isempty(degen) && return

    # Degeneracy is LOCAL: only constraints that share a term trade dual mass
    # with one another. Group by shared interconnector or shared (region,
    # service) term and apply the CVP priority WITHIN each group — otherwise an
    # unrelated constraint elsewhere in the NEM can claim the group's top slot
    # (observed: F_MAIN+RREG_0220 stealing the QLD lower pair's allocation).
    keysets = Dict{String,Set{String}}()
    for s in first.(degen); keysets[s] = Set{String}(); end
    if m.generic_interc_lhs !== nothing && !isempty(m.generic_interc_lhs)
        for r in eachrow(m.generic_interc_lhs)
            s = string(r.set)
            haskey(keysets, s) && push!(keysets[s], "IC:" * string(r.interconnector))
        end
    end
    if m.generic_region_lhs !== nothing && !isempty(m.generic_region_lhs)
        for r in eachrow(m.generic_region_lhs)
            s = string(r.set)
            haskey(keysets, s) && push!(keysets[s], "RS:" * string(r.region) * "/" * string(r.service))
        end
    end
    # Connected components over "shares at least one term".
    parent = Dict(s => s for s in first.(degen))
    find(x) = parent[x] == x ? x : (parent[x] = find(parent[x]))
    union!(a, b) = (ra = find(a); rb = find(b); ra != rb && (parent[ra] = rb))
    sets = first.(degen)
    for i in eachindex(sets), j in (i+1):length(sets)
        isempty(intersect(keysets[sets[i]], keysets[sets[j]])) || union!(sets[i], sets[j])
    end
    groups = Dict{String,Vector{Tuple{String,Any,Float64}}}()
    for (s, c, p) in degen
        push!(get!(groups, find(s), Tuple{String,Any,Float64}[]), (s, c, p))
    end
    for (_, g) in groups
        sort!(g; by = x -> -x[3])                  # descending violation price
        for (i, (set, _, _)) in enumerate(g)
            lo, hi = deriv[set]
            m.fcas_dual_override[set] = i == 1 ? hi : lo
        end
    end
    return
end

# --- Directed-unit pricing (dual-degeneracy resolution) -----------------------
"""
Resolve the dual degeneracy created by DIRECTED-unit generic constraints in
favour of NEMDE's pricing convention.

A GE generic constraint whose LHS is a single trader energy term (e.g.
`NSA_S_TB3_40`: TORRB3 energy >= 40, an SA system-strength direction) forces a
unit on. When the forced level coincides with a boundary of the unit's offer
bands, the LP has multiple optimal dual vertices: the dual mass can sit on the
direction constraint (making the directed unit's expensive band price-setting)
or on the network constraint the direction supports. NEMDE selects the vertex
in which the directed unit's forced energy is NOT price-setting — observed
2025-09-03 00:05, where NEMDE prices SA1 at `\$149.00` (rate-of-change-of-
frequency constraint dual −83.32) while the alternative vertex prices it at
`\$65.73.` Relaxing each BINDING such constraint by an infinitesimal ε in the
pricing re-solve places the directed unit strictly inside its lower band and
uniquely selects NEMDE's vertex; the primal dispatch is unchanged (ε = 0.1 kW).

EXPERIMENTAL — disabled by default. Investigation of 2025-09-03 00:05 showed
the SA multiplicity is multi-dimensional (the SVML\\_ZERO outage constraint,
V\\_S\\_NIL\\_ROCOF and the direction constraint exchange dual mass in a
2-plus-dimensional optimal face), so this one-constraint relaxation does not
reliably select NEMDE's vertex and is kept off pending a principled
lexicographic pricing rule.
"""
const DIRECTED_UNIT_PRICE_RELAX = Ref(false)

function _relax_directed_unit_constraints_for_pricing!(model, m::SpotMarket; eps_mw::Float64=1e-4)
    DIRECTED_UNIT_PRICE_RELAX[] || return
    termination_status(model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) || return
    isempty(m.generic_con_refs) && return
    (m.generic_unit_lhs === nothing || isempty(m.generic_unit_lhs)) && return
    # sets with exactly ONE unit LHS term and NO interconnector/region terms
    ucount = Dict{String,Int}()
    for r in eachrow(m.generic_unit_lhs)
        ucount[string(r.set)] = get(ucount, string(r.set), 0) + 1
    end
    other = Set{String}()
    for df in (m.generic_interc_lhs, m.generic_region_lhs)
        (df === nothing || isempty(df)) && continue
        for r in eachrow(df); push!(other, string(r.set)); end
    end
    # Read all values BEFORE modifying (modification invalidates the solution).
    to_relax = Tuple{Any,Float64}[]
    for (set, tup) in m.generic_con_refs
        cref, lhs, rhs, typ = tup[1], tup[2], tup[3], tup[4]
        (typ == "GE" || typ == ">=") || continue
        get(ucount, set, 0) == 1 || continue
        set in other && continue
        lv = try value(lhs) catch; continue end
        abs(lv - rhs) <= 1e-4 * max(1.0, abs(rhs)) || continue   # binding only
        push!(to_relax, (cref, float(rhs)))
    end
    isempty(to_relax) && return
    for (cref, rhs) in to_relax
        set_normalized_rhs(cref, normalized_rhs(cref) - eps_mw)
    end
    optimize!(model)
    return
end

# --- OCD rerun -------------------------------------------------------------------
# nempy: if any recovered price breaches the market ceiling/floor AND a generic
# (or FCAS-requirement) constraint is violated, relax each violated constraint's
# RHS by (violation + 0.01) in the violated direction and re-price. No clamping.
function _ocd_re_run!(model, m::SpotMarket, D, demand_con; floor, ceiling, fcas_ceiling)
    termination_status(model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) || return
    isempty(m.energy_prices) && return
    prices = m.energy_prices.price
    energy_violated = any(p -> isfinite(p) && p >= ceiling, prices) ||
                      any(p -> isfinite(p) && p <= floor, prices)
    # FCAS-requirement constraints live among the generic constraints (they are
    # the ones with region LHS terms); check their duals against the ceiling.
    fcas_violated = false
    if dual_status(model) == MOI.FEASIBLE_POINT
        for (set, tup) in m.generic_con_refs
            cref, lhs, rhs, typ, svs, has_region = tup[1:6]
            has_region || continue
            d = try dual(cref) catch; 0.0 end
            abs(d) >= fcas_ceiling && (fcas_violated = true; break)
        end
    end
    (energy_violated || fcas_violated) || return

    adjusted = false
    for (set, tup) in m.generic_con_refs
        cref, lhs, rhs, typ, svs, has_region = tup[1:6]
        viol = sum(value(sv) for sv in svs)
        viol > 1e-4 || continue
        if typ == "GE" || typ == ">="
            set_normalized_rhs(cref, rhs - (viol + 0.01))
        elseif typ == "EQ" || typ == "="
            # relax towards the active slack's direction
            v1 = value(svs[1]); v2 = length(svs) > 1 ? value(svs[2]) : 0.0
            set_normalized_rhs(cref, v1 >= v2 ? rhs - (v1 + 0.01) : rhs + (v2 + 0.01))
        else
            set_normalized_rhs(cref, rhs + (viol + 0.01))
        end
        adjusted = true
    end
    adjusted || return
    optimize!(model)
    _collect_results!(m, D, demand_con)
    return
end

# --- Result extraction -------------------------------------------------------
