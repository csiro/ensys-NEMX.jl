"variable controling a linear genetor responce "
function variable_gen_response_delta(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    variable_gen_active_power_response_delta(pm; nw, bounded, report)
    variable_gen_reactive_power_response_delta(pm; nw, bounded, report)
end

function variable_gen_active_power_response_delta(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    delta_p_p = _PM.var(pm, nw)[:delta_p_p] = JuMP.@variable(pm.model,
        [i in _PM.ids(pm, nw, :gen)],
        base_name="$(nw)_delta_p_p",   
    )
    delta_p_n = _PM.var(pm, nw)[:delta_p_n] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, nw, :gen)],
    base_name="$(nw)_delta_p_n",   
    )
    ub = 0.0
    lb = 0.0
    if bounded
        for (i,gen) in _PM.ref(pm, nw, :gen)
            ub = 0.0
            lb = 0.0
            if haskey(gen, "gen_R1S")
                ub += gen["gen_R1S"]
            end
            if haskey(gen, "gen_R6S")
                ub += gen["gen_R6S"]
            end
            if haskey(gen, "gen_R60S")
                ub += gen["gen_R60S"]
            end
            if haskey(gen, "gen_R5M")
                ub += gen["gen_R5M"]
            end
            if haskey(gen, "gen_RReg")
                ub += gen["gen_RReg"]
            end

            if haskey(gen, "gen_L1S")
                lb -= gen["gen_L1S"]
            end
            if haskey(gen, "gen_L6S")
                lb -= gen["gen_L6S"]
            end
            if haskey(gen, "gen_L60S")
                lb -= gen["gen_L60S"]
            end
            if haskey(gen, "gen_L5M")
                lb -= gen["gen_L5M"]
            end
            if haskey(gen, "gen_LReg")
                lb -= gen["gen_LReg"]
            end
            
            JuMP.set_upper_bound(delta_p_p[i], ub)
            JuMP.set_lower_bound(delta_p_p[i], 0)

            JuMP.set_upper_bound(delta_p_n[i], -lb)
            JuMP.set_lower_bound(delta_p_n[i], 0)
        end
    end

    report && _PM.sol_component_value(pm, nw, :gen, :delta_p_p, _PM.ids(pm, nw, :gen), delta_p_p)
    report && _PM.sol_component_value(pm, nw, :gen, :delta_p_n, _PM.ids(pm, nw, :gen), delta_p_n)
end

function variable_gen_reactive_power_response_delta(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    delta_q = _PM.var(pm, nw)[:delta_q] = JuMP.@variable(pm.model,
        [i in _PM.ids(pm, nw, :gen)],
        base_name="$(nw)_delta_q",
        
    )

    if bounded
        for (i,gen) in _PM.ref(pm, nw, :gen)
            qmax = gen["qmax"]
            qmin = gen["qmin"]
            qg = gen["qg"]
            JuMP.set_upper_bound(delta_q[i], qmax-qg)
            JuMP.set_lower_bound(delta_q[i], qmin-qg)
        end
    end

    report && _PM.sol_component_value(pm, nw, :gen, :delta_q, _PM.ids(pm, nw, :gen), delta_q)
end


function fix_load_variables_to_master(pm::_PM.AbstractPowerModel; n::Int=_PM.nw_id_default)
    loads = get_dispatchable_participants(_PM.ref(pm, n, :load))
    for (i, load) in loads
        JuMP.fix(_PM.var(pm, n, :pd, i), load["pd"]; force = true)
    end
end 

function variable_load_response_delta(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    delta_pd = _PM.var(pm, nw)[:delta_pd] = JuMP.@variable(pm.model,
        [i in _PM.ids(pm, nw, :load)],
        base_name="$(nw)_delta_pd",
        
    )

    if bounded
        for (i,load) in _PM.ref(pm, nw, :load)
            ub = 0.0
            lb = 0.0
            if haskey(load, "load_R1S")
                ub += load["load_R1S"]
            end
            if haskey(load, "load_R6S")
                ub += load["load_R6S"]
            end
            if haskey(load, "load_R60S")
                ub += load["load_R60S"]
            end
            if haskey(load, "load_R5M")
                ub += load["load_R5M"]
            end
            if haskey(load, "load_RReg")
                ub += load["load_RReg"]
            end

            if haskey(load, "load_L1S")
                lb -= load["load_L1S"]
            end
            if haskey(load, "load_L6S")
                lb -= load["load_L6S"]
            end
            if haskey(load, "load_L60S")
                lb -= load["load_L60S"]
            end
            if haskey(load, "load_L5M")
                lb -= load["load_L5M"]
            end
            if haskey(load, "load_LReg")
                lb -= load["load_LReg"]
            end
            
            JuMP.set_upper_bound(delta_pd[i], ub)
            JuMP.set_lower_bound(delta_pd[i], lb)
        end
    end

    report && _PM.sol_component_value(pm, nw, :load, :delta_pd, _PM.ids(pm, nw, :load), delta_pd)
end
# FCAS

"""
    objective_variable_pg_cost(pm, report)

Creates generator cost variables required by the model objective function
"""
function objective_variable_pg_cost(pm::_PM.AbstractPowerModel, report::Bool=true)
    for (n, nw_ref) in _PM.nws(pm)
        price_cap = _PM.ref(pm, n, :price_cap)
        pg_cost = _PM.var(pm, n)[:pg_cost] = Dict{Int,Any}()

        gens = get_dispatchable_participants(_PM.ref(pm, n, :gen))
        for (i,gen) in gens
            pg_vars = _PM.var(pm, n, :pg, i)
            if isa(pg_vars, Array{JuMP.VariableRef})
                pmin = sum(JuMP.lower_bound.(pg_vars))
                pmax = sum(JuMP.upper_bound.(pg_vars))
            else
                pmin = gen["pmin"]
                pmax = gen["pmax"]
            end

            cost = get_cost_data(pm, gen)
            
            # points = calc_pwl_points(gen["ncost"], cost, pmin, pmax, price_cap)
            points = _PM.calc_pwl_points(gen["ncost"], cost, pmin, pmax)

            pg_cost_lambda = JuMP.@variable(pm.model,
                [j in 1:length(points)], base_name="$(n)_$(i)_pg_cost_lambda",
                lower_bound = 0.0,
                upper_bound = 1.0
            )

            JuMP.@constraint(pm.model, sum(pg_cost_lambda) == 1.0)

            pg_expr = 0.0
            pg_cost_expr = 0.0
            for (i,point) in enumerate(points)
                pg_expr += point.mw*pg_cost_lambda[i]
                pg_cost_expr += point.cost*pg_cost_lambda[i]
            end
            JuMP.@constraint(pm.model, pg_expr == sum(pg_vars))
            pg_cost[i] = pg_cost_expr
        end

        report && _PM.sol_component_value(pm, n, :gen, :pg_cost, keys(gens), pg_cost)
    end
end




"""
    objective_variable_pd_cost(pm, report)

Creates load cost variables required by the model objective function
"""
function objective_variable_pd_cost(pm::_PM.AbstractPowerModel, report::Bool=true)
    for (n, nw_ref) in _PM.nws(pm)
        price_cap = _PM.ref(pm, n, :price_cap)
        pd_cost = _PM.var(pm, n)[:pd_cost] = Dict{Int,Any}()
        pd_value = _PM.var(pm, n)[:pd_value] = Dict{Int,Any}()

        loads = get_dispatchable_participants(_PM.ref(pm, n, :load))
        for (i, load) in loads
            pd_vars = _PM.var(pm, n, :pd, i)
            pmin = sum(JuMP.lower_bound.(pd_vars))
            pmax = sum(JuMP.upper_bound.(pd_vars))
            cost = get_cost_data(pm, load)

            # points = calc_pwl_points(load["ncost"], cost, pmin, pmax, price_cap)
            points = _PM.calc_pwl_points(load["ncost"], cost, pmin, pmax)

            pd_cost_lambda = JuMP.@variable(pm.model,
                [i in 1:length(points)], base_name = "$(n)_pd_cost_lambda",
                lower_bound = 0.0,
                upper_bound = 1.0
            )
            JuMP.@constraint(pm.model, sum(pd_cost_lambda) == 1.0)

            pd_expr = 0.0
            pd_cost_expr = 0.0
            for (i, point) in enumerate(points)
                pd_expr += point.mw * pd_cost_lambda[i]
                pd_cost_expr += point.cost * pd_cost_lambda[i]
            end
            JuMP.@constraint(pm.model, pd_expr == sum(pd_vars))
            pd_cost[i] = pd_cost_expr
            pd_value[i] = pd_expr
        end

        report && _PM.sol_component_value(pm, n, :load, :pd_cost, keys(loads), pd_cost)
     end
end

function variable_load_power(pm::_PM.AbstractPowerModel; kwargs...)
    variable_load_power_real(pm; kwargs...)
end

"""
    variable_load_power_real(pm; nw, bounded, report)

Creates variables for load real/active power
"""
function variable_load_power_real(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    loads = get_dispatchable_participants(_PM.ref(pm, nw, :load))
    
    pd = _PM.var(pm, nw)[:pd] = JuMP.@variable(pm.model,
        [i in keys(loads)], base_name = "$(nw)_pd",
        start = _PM.comp_start_value(loads[i], "pd_start")
    )

    if bounded
        for (i, load) in loads
            JuMP.set_lower_bound(pd[i], load["pmin"])
            JuMP.set_upper_bound(pd[i], load["pmax"])
        end
    end

    report && _PM.sol_component_value(pm, nw, :load, :pd, keys(loads), pd)
end

"""
    objective_variable_fcas_cost(pm, report)

Creates FCAS cost variables for generators and loads that are required by the model objective function
"""
function objective_variable_fcas_cost(pm::_PM.AbstractPowerModel, report::Bool=true)
    for (n, nw_ref) in _PM.nws(pm)
        price_cap = _PM.ref(pm, n, :price_cap)
        for (s, service) in fcas_services
            service_key = service.id
            fcas_gen_cost_vars = _PM.var(pm, n)[Symbol("gen_$(fcas_name(service))_cost")] = Dict{Int,Any}()

            gens = get_fcas_participants(_PM.ref(pm, n, :gen), service)
            for (j, gen) in gens
                if !haskey(gen, "fcas_cost") || !haskey(gen["fcas_cost"], service_key)
                    fcas_gen_cost_vars[j] = 0
                    continue
                end

                fcas_cost = gen["fcas_cost"][service_key]

                fcas_vars = _PM.var(pm, n, Symbol("gen_$(fcas_name(service))"), j)
                pmin = sum(JuMP.lower_bound.(fcas_vars))
                pmax = sum(JuMP.upper_bound.(fcas_vars))

                # points = calc_pwl_points(fcas_cost["ncost"], fcas_cost["cost"], pmin, pmax, price_cap)
                points = _PM.calc_pwl_points(fcas_cost["ncost"], fcas_cost["cost"], pmin, pmax)

                cost_lambda = JuMP.@variable(pm.model,
                    [i in 1:length(points)], base_name = "$(n)_$(fcas_name(service))_cost_lambda",
                    lower_bound = 0.0,
                    upper_bound = 1.0
                )

                JuMP.@constraint(pm.model, sum(cost_lambda) == 1.0)

                expr = 0.0
                cost_expr = 0.0
                for (i, point) in enumerate(points)
                    expr += point.mw * cost_lambda[i]
                    cost_expr += point.cost * cost_lambda[i]
                end

                JuMP.@constraint(pm.model, expr == sum(fcas_vars))
                fcas_gen_cost_vars[j] = cost_expr
            end

            report && _PM.sol_component_value(pm, n, :gen, Symbol("gen_$(fcas_name(service))_cost"), keys(gens), fcas_gen_cost_vars)

            fcas_load_cost_vars = _PM.var(pm, n)[Symbol("load_$(fcas_name(service))_cost")] = Dict{Int,Any}()

            loads = get_fcas_participants(_PM.ref(pm, n, :load), service)
            for (j, load) in loads
                if !haskey(load, "fcas_cost") || !haskey(load["fcas_cost"], service_key)
                    fcas_load_cost_vars[j] = 0
                    continue
                end

                fcas_cost = load["fcas_cost"][service_key]

                fcas_vars = _PM.var(pm, n, Symbol("load_$(fcas_name(service))"), j)
                pmin = sum(JuMP.lower_bound.(fcas_vars))
                pmax = sum(JuMP.upper_bound.(fcas_vars))

                points = _PM.calc_pwl_points(fcas_cost["ncost"], fcas_cost["cost"], pmin, pmax)

                cost_lambda = JuMP.@variable(pm.model,
                    [i in 1:length(points)], base_name = "$(n)_$(fcas_name(service))_cost_lambda",
                    lower_bound = 0.0,
                    upper_bound = 1.0
                )
                JuMP.@constraint(pm.model, sum(cost_lambda) == 1.0)

                expr = 0.0
                cost_expr = 0.0
                for (i, point) in enumerate(points)
                    expr += point.mw * cost_lambda[i]
                    cost_expr += point.cost * cost_lambda[i]
                end

                JuMP.@constraint(pm.model, expr == sum(fcas_vars))
                fcas_load_cost_vars[j] = cost_expr
            end

            report && _PM.sol_component_value(pm, n, :load, Symbol("load_$(fcas_name(service))_cost"), keys(loads), fcas_load_cost_vars)            
        end
    end
end

"""
    variable_fcas(pm, nw, report)

Creates variables for all enabled FCAS participants
"""
function variable_fcas(pm::_PM.AbstractPowerModel, nw::Int=_PM.nw_id_default, report::Bool=true)
    for  (i, service) in fcas_services
        gens = get_fcas_participants(_PM.ref(pm, nw, :gen), service)
        gen_vars = _PM.var(pm, nw)[Symbol("gen_$(fcas_name(service))")] = JuMP.@variable(pm.model,
            [i in keys(gens)], base_name = "$(nw)_gen_$(fcas_name(service))", lower_bound = 0,
            start = 0.0
        )

        for (n, gen) in gens
            JuMP.set_upper_bound(gen_vars[n], gen["fcas"][service.id]["amax"])
        end

        report && _PM.sol_component_value(pm, nw, :gen, Symbol("gen_$(fcas_name(service))"), keys(gens), gen_vars)

        loads = get_fcas_participants(_PM.ref(pm, nw, :load), service)
        load_vars = _PM.var(pm, nw)[Symbol("load_$(fcas_name(service))")] = JuMP.@variable(pm.model,
            [i in keys(loads)], base_name = "$(nw)_load_$(fcas_name(service))", lower_bound = 0,
            start = 0.0
        )

        for (n, load) in loads
            JuMP.set_upper_bound(load_vars[n], load["fcas"][service.id]["amax"])
        end

        report && _PM.sol_component_value(pm, nw, :load, Symbol("load_$(fcas_name(service))"), keys(loads), load_vars)
    end
end


function variable_branch_intc_power_real(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    pb = _PM.var(pm, nw)[:pb] = JuMP.@variable(pm.model,
        [i in _PM.ids(pm, nw, :branch_intc)], base_name="$(nw)_pb",
        start = _PM.comp_start_value(_PM.ref(pm, nw, :branch_intc, i), "pb_start")
    )

    if bounded
        for (i, branch) in _PM.ref(pm, nw, :branch_intc)
            JuMP.set_lower_bound(pb[i], branch["pmin"])
            JuMP.set_upper_bound(pb[i], branch["pmax"])
        end
    end

    report && _PM.sol_component_value(pm, nw, :branch_intc, :p, _PM.ids(pm, nw, :branch_intc), pb)
end

function variable_branch_intc_min_fl(pm::_PM.AbstractPowerModel; n::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    p_pos = _PM.var(pm, n)[:p_pos] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, n, :branch_intc)], base_name="$(n)_p_pos",
    start = _PM.comp_start_value(_PM.ref(pm, n, :branch_intc, i), "p_pos_start"))

    p_neg = _PM.var(pm, n)[:p_neg] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, n, :branch_intc)], base_name="$(n)_p_neg",
    start = _PM.comp_start_value(_PM.ref(pm, n, :branch_intc, i), "p_neg_start"))

    if bounded
        for (i, branch) in _PM.ref(pm, n, :branch_intc)
            JuMP.set_lower_bound(p_pos[i], branch["min_fl"])
            JuMP.set_upper_bound(p_pos[i], branch["pmax"])
        end
    end
    if bounded
        for (i, branch) in _PM.ref(pm, n, :branch_intc)
            JuMP.set_lower_bound(p_neg[i], branch["min_fl"])
            JuMP.set_upper_bound(p_neg[i], -branch["pmin"])
        end
    end

    report && _PM.sol_component_value(pm, n, :branch_intc, :p_pos, _PM.ids(pm, n, :branch_intc), p_pos)
    report && _PM.sol_component_value(pm, n, :branch_intc, :p_neg, _PM.ids(pm, n, :branch_intc), p_neg)
    
    z_p_neg = _PM.var(pm, n)[:z_p_neg] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, n, :branch_intc)], base_name="$(n)_z_p_neg",
    binary = true,
    start = _PM.comp_start_value(_PM.ref(pm, n, :branch_intc, i), "z_p_neg_start", 1.0))

    z_p_pos = _PM.var(pm, n)[:z_p_pos] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, n, :branch_intc)], base_name="$(n)_z_p_pos",
    binary = true,
    start = _PM.comp_start_value(_PM.ref(pm, n, :branch_intc, i), "z_p_pos_start", 1.0))

    report && _PM.sol_component_value(pm, n, :branch_intc, :z_p_pos, _PM.ids(pm, n, :branch_intc), z_p_pos)
    report && _PM.sol_component_value(pm, n, :branch_intc, :z_p_neg, _PM.ids(pm, n, :branch_intc), z_p_neg)

end

function fix_variables_gen_power(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default)

    for (i, gen) in _PM.ref(pm, nw, :gen)
        JuMP.fix(_PM.var(pm, nw, :pg, i), gen["pg"]; force = true)
    end
end

"""
compute lines in m and b from from pwl cost models
data is a list of components
"""
function get_lines(data)
    lines = Dict{Int,Any}()
    for (i,comp) in data
        @assert comp["model"] == 1
        line_data = slope_intercepts(comp["cost"])
        lines[i] = line_data
        for i in 2:length(line_data)
            if line_data[i-1]["slope"] > line_data[i]["slope"]
                Memento.warn(_LOGGER, "non-convex pwl function found in points $(comp["cost"])\nlines: $(line_data)")
            end
        end
    end
    return lines
end

"""
compute m and b from points pwl points
"""
function slope_intercepts(points::Array{T,1}) where T <: Real
    line_data = []

    for i in 3:2:length(points)
        x1 = points[i-2]
        y1 = points[i-1]
        x2 = points[i-0]
        y2 = points[i+1]

        m = (y2 - y1)/(x2 - x1)
        b = y1 - m * x1

        line = Dict(
            "slope" => m,
            "intercept" => b
        )
        push!(line_data, line)
    end

    return line_data
end