# =============================================================================
# result.jl
#
# Result extraction from the solved model: dispatch quantities, regional energy
# prices, and the binding generic-constraint report.
#
# Split out of the single-file `spot_market.jl` of the reference
# implementation. The code is unchanged; only its location is. All of these
# files are `include`d into the same `ZBenchmark` module, so definition order
# across them does not matter.
# =============================================================================

function _collect_results!(m::SpotMarket, D, demand_con)
    rows = NamedTuple[]
    if termination_status(m.model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)
        for (key, expr) in D
            u, dt, s = key
            push!(rows, (unit=u, dispatch_type=dt, service=s, dispatch=value(expr)))
        end
    end
    m.unit_dispatch = DataFrame(rows)

    prows = NamedTuple[]
    has_duals = (termination_status(m.model) in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED)) &&
                (dual_status(m.model) == MOI.FEASIBLE_POINT)
    for reg in m.regions
        price = (has_duals && haskey(demand_con, reg)) ? dual(demand_con[reg]) : NaN
        push!(prows, (region=reg, price=price))
    end
    m.energy_prices = DataFrame(prows)
    return
end

"""
    get_binding_generic_constraints(m::SpotMarket) -> DataFrame

Diagnostic: shadow price, solved LHS, RHS and binding status of every generic
constraint in the last solved model. The `services` column lists the FCAS (or
energy) services the constraint couples, so FCAS regional requirement prices can
be filtered directly (e.g. `filter(r -> !isempty(r.services), df)` or by the
`F_`/`D_` set-name prefix); `dual` is the marginal price (`\$/MW`) of the
requirement.
"""
function get_binding_generic_constraints(m::SpotMarket)
    rows = NamedTuple[]
    (m.model === nothing || isempty(m.generic_con_refs)) && return DataFrame(rows)
    have_duals = dual_status(m.model) == MOI.FEASIBLE_POINT
    for (set, tup) in m.generic_con_refs
        cref, lhs, rhs, typ, svs, has_region = tup[1:6]
        svc_label = length(tup) >= 7 ? tup[7] : ""
        reg_label = length(tup) >= 8 ? tup[8] : ""
        lhsval = value(lhs)
        d = have_duals ? (try dual(cref) catch; NaN end) : NaN
        # CVP-priority refinement (opt-in) replaces the solver's arbitrary dual
        # corner for degenerate FCAS requirements; every other dual is untouched.
        haskey(m.fcas_dual_override, set) && (d = m.fcas_dual_override[set])
        binds = abs(lhsval - rhs) <= 1e-4 * max(1.0, abs(rhs))
        push!(rows, (set=set, service=svc_label, region=reg_label, dual=d,
                     lhs=lhsval, rhs=rhs, type=typ, binds=binds))
    end
    return DataFrame(rows)
end

# Group a factor DataFrame into Dict(set => Vector{NamedTuple rows}).
function _group_factors(df::DataFrame, key::Symbol)
    out = Dict{String,Vector{NamedTuple}}()
    isempty(df) && return out
    for row in eachrow(df)
        push!(get!(out, string(row[key]), NamedTuple[]), copy(row))
    end
    return out
end

"""
    get_unit_dispatch(m::SpotMarket) -> DataFrame

`unit, dispatch_type, service, dispatch` (MW) for the solved interval.
"""
get_unit_dispatch(m::SpotMarket) = m.unit_dispatch

"""
    get_energy_prices(m::SpotMarket) -> DataFrame

`region, price` — the demand-constraint duals (regional reference prices).
"""
get_energy_prices(m::SpotMarket) = m.energy_prices

"""
    get_fcas_prices(m::SpotMarket) -> DataFrame

Placeholder for FCAS service marginal prices.
"""
get_fcas_prices(m::SpotMarket) = m.fcas_prices
