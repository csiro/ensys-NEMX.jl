

function objective_min_cost(pm::_PM.AbstractPowerModel; kwargs...)
    model = check_gen_cost_models(pm)

    if model == 1
        return objective_pwl(pm; kwargs...)
    else
        Memento.error(_LOGGER, "Only cost models of types 1 are supported at this time, given cost model type of $(model)")
    end

end

function objective_pwl(pm::_PM.AbstractPowerModel; kwargs...)
    objective_variable_pg_cost(pm; kwargs...)
    objective_variable_pd_cost(pm; kwargs...)
    objective_variable_fcas_cost(pm; kwargs...)

    obj_expr = JuMP.@expression(pm.model, 
    sum(
        sum(_PM.var(pm, n, :pg_cost, i) for (i,gen) in nw_ref[:gen]) +
        sum(_PM.var(pm, n, Symbol("gen_$(fcas_name(fcas_service))_cost"), gen) for fcas_service = values(fcas_services) for gen = keys(get_fcas_participants(nw_ref[:gen], fcas_service))) +
        sum(_PM.var(pm, n, Symbol("load_$(fcas_name(fcas_service))_cost"), load) for fcas_service = values(fcas_services) for load = keys(get_fcas_participants(nw_ref[:load], fcas_service))) -
        sum(_PM.var(pm, n, :pd_cost, i) for (i,load) in get_dispatchable_participants(nw_ref[:load]))
    for (n, nw_ref) in _PM.nws(pm))
    )

    return JuMP.@objective(pm.model, Max, obj_expr)
end

# function objective_sos(pm::_PM.AbstractPowerModel; kwargs...)
#     for (n, nw_ref) in _PM.nws(pm)
#         pg_cost = _PM.var(pm, n)[:pg_cost] = JuMP.@variable(pm.model, [i in _PM.ids(pm, n, :gen)], base_name="$(n)_pg_cost")
        
#         gens = get_dispatchable_participants(_PM.ref(pm, n, :gen))
#         for (i,gen) in gens
#             pg_var = _PM.var(pm, n, :pg, i)
#             pg_band = get_cost_data(pm, gen)[1:2:end]
#             cost_band = get_cost_data(pm, gen)[2:2:end]
#             ncost = gen["ncost"]
#             # x = _PM.var(pm, n)[:x] = JuMP.@variable(pm.model, [1:1:ncost], base_name="$(n)_$(i)_x", lower_bound = 0.0, upper_bound = 1.0)
#             x = _PM.var(pm, n)[:x] = JuMP.@variable(pm.model, [1:1:ncost], base_name="$(n)_$(i)_x", binary = true)

#             JuMP.@constraint(pm.model, sum([x[i] for i in 1:1:ncost]) == 1.0)
#             JuMP.@constraint(pm.model, pg_cost[i] == sum(x[j]*cost_band[j] for j in 1:1:ncost))
#             # JuMP.@constraint(pm.model, [x[i] for i in 1:1:ncost] in JuMP.SOS1())
#             JuMP.@constraint(pm.model, pg_var <= sum(x[i] * sum(pg_band[1:i]) for i in 1:1:ncost))
#             # coeffs = [0.0; cumsum(pg_band[1:ncost-1])]
#             # JuMP.@constraint(pm.model, pg_var >= sum(x[i] * coeffs[i] for i in 1:ncost))
#         end
#          _PM.sol_component_value(pm, n, :gen, :pg_cost, keys(gens), pg_cost)
#     end


#     # objective_variable_pg_cost(pm; kwargs...)
#     objective_variable_pd_cost(pm; kwargs...)
#     objective_variable_fcas_cost(pm; kwargs...)

#     obj_expr = JuMP.@expression(pm.model, 
#     sum(
#         sum(_PM.var(pm, n, :pg_cost, i) for (i,gen) in nw_ref[:gen]) +
#         sum(_PM.var(pm, n, Symbol("gen_$(fcas_name(fcas_service))_cost"), gen) for fcas_service = values(fcas_services) for gen = keys(get_fcas_participants(nw_ref[:gen], fcas_service))) +
#         sum(_PM.var(pm, n, Symbol("load_$(fcas_name(fcas_service))_cost"), load) for fcas_service = values(fcas_services) for load = keys(get_fcas_participants(nw_ref[:load], fcas_service))) -
#         sum(_PM.var(pm, n, :pd_cost, i) for (i,load) in get_dispatchable_participants(nw_ref[:load]))
#     for (n, nw_ref) in _PM.nws(pm))
#     )

#     return JuMP.@objective(pm.model, Max, obj_expr)
# end




function objective_min_cost_soft(pm::_PM.AbstractPowerModel; kwargs...)
    model = check_gen_cost_models(pm)

    if model == 1
        return objective_pwl_soft(pm; kwargs...)
    else
        Memento.error(_LOGGER, "Only cost models of types 1 are supported at this time, given cost model type of $(model)")
    end

end

function objective_pwl_soft(pm::_PM.AbstractPowerModel; kwargs...)
    objective_variable_pg_cost(pm; kwargs...)
    objective_variable_pd_cost(pm; kwargs...)
    objective_variable_fcas_cost(pm; kwargs...)

    obj_expr = JuMP.@expression(pm.model, 
        sum(
            sum( _PM.var(pm, n, :pg_cost, i) for (i,gen) in nw_ref[:gen]) +
            sum( _PM.var(pm, n, Symbol("gen_$(fcas_name(fcas_service))_cost"), gen) for fcas_service = values(fcas_services) for gen = keys(get_fcas_participants(nw_ref[:gen], fcas_service))) +
            sum( _PM.var(pm, n, Symbol("load_$(fcas_name(fcas_service))_cost"), load) for fcas_service = values(fcas_services) for load = keys(get_fcas_participants(nw_ref[:load], fcas_service))) -
            sum( _PM.var(pm, n, :pd_cost, i) for (i,load) in get_dispatchable_participants(nw_ref[:load])) -
            sum( 5E6*_PM.var(pm, n, :pb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) -
            sum( 5E6*_PM.var(pm, n, :pb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) -
            sum( 5E6*_PM.var(pm, n, :qb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) -
            sum( 5E6*_PM.var(pm, n, :qb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) -
            sum( 5E6*_PM.var(pm, n, :bf_vio_fr, i) for i in _PM.ids(pm, :branch) ) -
            sum( 5E6*_PM.var(pm, n, :bf_vio_to, i) for i in _PM.ids(pm, :branch) ) 
    for (n, nw_ref) in _PM.nws(pm))
    )


    return JuMP.@objective(pm.model, Max, obj_expr)
end


function objective_pb_min_cost(pm::_PM.AbstractPowerModel; kwargs...)
    model = check_gen_cost_models(pm)

    if model == 1
        return objective_pb_pwl(pm; kwargs...)
    else
        Memento.error(_LOGGER, "Only cost models of types 1 are supported at this time, given cost model type of $(model)")
    end

end

function objective_pb_pwl(pm::_PM.AbstractPowerModel; kwargs...)
    objective_variable_pg_cost(pm; kwargs...)
    objective_variable_pd_cost(pm; kwargs...)

    obj_expr = JuMP.@expression(pm.model, 
        sum(
            sum( _PM.var(pm, n, :pg_cost, i)  +
                 _PM.ref(pm, n, :gen, i, "gen_R1S_cost") + 
                 _PM.ref(pm, n, :gen, i, "gen_L1S_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_R6S_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_L6S_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_R60S_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_L60S_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_R5M_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_L5M_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_RReg_cost") +
                 _PM.ref(pm, n, :gen, i, "gen_LReg_cost")            
            for (i,gen) in nw_ref[:gen] ) +
        sum(    _PM.ref(pm, n, :load, i, "load_R1S_cost") + 
                _PM.ref(pm, n, :load, i, "load_L1S_cost") +
                _PM.ref(pm, n, :load, i, "load_R6S_cost") +
                _PM.ref(pm, n, :load, i, "load_L6S_cost") +
                _PM.ref(pm, n, :load, i, "load_R60S_cost") +
                _PM.ref(pm, n, :load, i, "load_L60S_cost") +
                _PM.ref(pm, n, :load, i, "load_R5M_cost") +
                _PM.ref(pm, n, :load, i, "load_L5M_cost") +
                _PM.ref(pm, n, :load, i, "load_RReg_cost") +
                _PM.ref(pm, n, :load, i, "load_LReg_cost")            
            for (i,load) in nw_ref[:load] ) -
            sum( _PM.var(pm, n, :pd_cost, i) for (i,load) in get_dispatchable_participants(nw_ref[:load]))
            for (n, nw_ref) in _PM.nws(pm)  )
    )


    return JuMP.@objective(pm.model, Max, obj_expr)
end

function objective_f_min_cost_soft(pm::_PM.AbstractPowerModel; kwargs...)
    model = check_gen_cost_models(pm)

    if model == 1
        return objective_f_pwl_soft(pm; kwargs...)
    else
        Memento.error(_LOGGER, "Only cost models of types 1 are supported at this time, given cost model type of $(model)")
    end

end

function objective_f_pwl_soft(pm::_PM.AbstractPowerModel; kwargs...)

    obj_expr = JuMP.@expression(pm.model,  
        sum(sum( 5E5*_PM.var(pm, n, :pb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) +
            sum( 5E5*_PM.var(pm, n, :pb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) +
            sum( 5E5*_PM.var(pm, n, :qb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) +
            sum( 5E5*_PM.var(pm, n, :qb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) +
            sum( 5E5*_PM.var(pm, n, :bf_vio_fr, i) for i in _PM.ids(pm, :branch) ) +
            sum( 5E5*_PM.var(pm, n, :bf_vio_to, i) for i in _PM.ids(pm, :branch) ) +
            sum( 1E1*_PM.var(pm, n, :delta_p_slack, i) for i in _PM.ids(pm, :gen)) +
            sum( 1E1*_PM.var(pm, n, :delta_pn_slack, i) for i in _PM.ids(pm, :gen))
    for (n, nw_ref) in _PM.nws(pm))
    )

    return JuMP.@objective(pm.model, Min, obj_expr)
end


"""
Checks that all generator cost models are of the same type
"""
function check_gen_cost_models(pm::_PM.AbstractPowerModel)
    model = nothing

    for (n, nw_ref) in _PM.nws(pm)
        for (i,gen) in nw_ref[:gen]
            if haskey(gen, "cost")
                if model == nothing
                    model = gen["model"]
                else
                    if gen["model"] != model
                        Memento.error(_LOGGER, "cost models are inconsistent, the typical model is $(model) however model $(gen["model"]) is given on generator $(i)")
                    end
                end
            else
                Memento.error(_LOGGER, "no cost given for generator $(i)")
            end
        end
    end

    return model
end