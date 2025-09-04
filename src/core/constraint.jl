


function constraint_generator_ramping(pm::_PM.AbstractPowerModel, n::Int, i::Int, prev_hour, ΔPg_up, ΔPg_down)
    pg_n = _PM.var(pm, n, :pg, i)
    pg_n_1 = _PM.var(pm, prev_hour, :pg, i)

    JuMP.@constraint(pm.model, pg_n - pg_n_1 <= ΔPg_up)
    JuMP.@constraint(pm.model, pg_n_1 - pg_n <= ΔPg_down)
end


""

function constraint_gen_real_setpoint_link(pm::_PM.AbstractPowerModel, n::Int, i::Int, pg_master)
    pg = _PM.var(pm, n, :pg, i)
    delta_p_p = _PM.var(pm, n, :delta_p_p, i)
    delta_p_n = _PM.var(pm, n, :delta_p_n, i)

    dual_p = JuMP.@constraint(pm.model,  pg - delta_p_p + delta_p_n == pg_master)

    _PM.sol(pm, n, :gen, i)[:lm_p] = dual_p
    
end

function constraint_gen_real_setpoint_link_soft(pm::_PM.AbstractPowerModel, n::Int, i::Int, pg_master)
    pg = _PM.var(pm, n, :pg, i)
    delta_p_p = _PM.var(pm, n, :delta_p_p, i)
    delta_p_n = _PM.var(pm, n, :delta_p_n, i)
    delta_p_slack = _PM.var(pm, n, :delta_p_slack, i)
    delta_pn_slack = _PM.var(pm, n, :delta_pn_slack, i)




    dual_p = JuMP.@constraint(pm.model,  pg - delta_p_p + delta_p_n - delta_p_slack + delta_pn_slack == pg_master)

    _PM.sol(pm, n, :gen, i)[:lm_p] = dual_p
    
end

""

function constraint_gen_reactive_setpoint_link(pm::_PM.AbstractPowerModel, n::Int, i::Int, qg_master)
    qg = _PM.var(pm, n, :qg, i)
    delta_q = _PM.var(pm, n, :delta_q, i)

    dual_q = JuMP.@constraint(pm.model,  qg - delta_q == qg_master)

    _PM.sol(pm, n, :gen, i)[:lm_q] = dual_q
end

""


function constraint_load_active_setpoint_link(pm::_PM.AbstractPowerModel, n::Int, i::Int, pd_master)
    pd = _PM.var(pm, n, :pd, i)
    delta_pd = _PM.var(pm, n, :delta_pd, i)
    
    JuMP.@constraint(pm.model, pd - delta_pd == pd_master)
end 

function constraint_conv_reactive_setpoint_link(pm::_PM.AbstractPowerModel, n::Int, i::Int, qconv_ac_master)
    qconv_ac = _PM.var(pm, n, :qconv_ac, i)

    # dual_ac_q = JuMP.@constraint(pm.model,  qconv_ac == qconv_ac_master)
    # _PM.sol(pm, n, :convdc, i)[:lm_ac_q] = dual_ac_q
    _PM.sol(pm, n, :convdc, i)[:lm_ac_q] = 0
end

""

function constraint_conv_real_setpoint_link(pm::_PM.AbstractPowerModel, n::Int, i::Int, pconv_ac_master)
    pconv_ac = _PM.var(pm, n, :pconv_ac, i)

    # dual_ac_p = JuMP.@constraint(pm.model,  pconv_ac == pconv_ac_master)
    # _PM.sol(pm, n, :convdc, i)[:lm_ac_p] = dual_ac_p
    _PM.sol(pm, n, :convdc, i)[:lm_ac_p] = 0
end


function constraint_gen_fcas_setpoint_link(pm::_PM.AbstractPowerModel, service::FCASService, n::Int, i::Int, service_value_m)
    service_var = _PM.var(pm, n, Symbol("gen_$(fcas_name(service))"), i)

    dual_gen_service = JuMP.@constraint(pm.model, service_var == service_value_m)

    _PM.sol(pm, n, :gen, i)[Symbol("dual_gen_$(fcas_name(service))")] = dual_gen_service   
end

function constraint_load_fcas_setpoint_link(pm::_PM.AbstractPowerModel, service::FCASService, n::Int, i::Int, service_value_m)
    service_var = _PM.var(pm, n, Symbol("load_$(fcas_name(service))"), i)

    dual_load_service = JuMP.@constraint(pm.model, service_var == service_value_m)

    _PM.sol(pm, n, :load, i)[Symbol("dual_load_$(fcas_name(service))")] = dual_load_service
end



function constraint_thermal_limit_from_soft(pm::_PM.AbstractPowerModel, n::Int, i::Int, f_idx, rate_a)
    p_fr = _PM.var(pm, n, :p, f_idx)
    q_fr = _PM.var(pm, n, :q, f_idx)
    vio_fr = _PM.var(pm, n, :bf_vio_fr, i)

    JuMP.@constraint(pm.model, p_fr^2 + q_fr^2 <= rate_a^2 + vio_fr)
end

""

function constraint_thermal_limit_to_soft(pm::_PM.AbstractPowerModel, n::Int, i::Int, t_idx, rate_a)
    p_to = _PM.var(pm, n, :p, t_idx)
    q_to = _PM.var(pm, n, :q, t_idx)
    vio_to = _PM.var(pm, n, :bf_vio_to, i)

    JuMP.@constraint(pm.model, p_to^2 + q_to^2 <= rate_a^2 + vio_to)
end

"""
    constraint_fcas_max_available(pm, service, nw)

Simple constraint to ensure the calculated fcas for a generator/load is below the max fcas availability
"""
function constraint_fcas_max_available(pm::_PM.AbstractPowerModel, service::FCASService, nw::Int=_PM.nw_id_default)
    for (i, gen) in get_fcas_participants(_PM.ref(pm, nw, :gen), service)
        fcas = gen["fcas"][service.id]
        p_fcas = _PM.var(pm, nw, Symbol("gen_$(fcas_name(service))"), i)

        JuMP.@constraint(pm.model, p_fcas <= fcas["amax"])
    end

    for (i, load) in get_fcas_participants(_PM.ref(pm, nw, :load), service)
        fcas = load["fcas"][service.id]
        p_fcas = _PM.var(pm, nw, Symbol("load_$(fcas_name(service))"), i)

        JuMP.@constraint(pm.model, p_fcas <= fcas["amax"])
    end
end

"""
    constraint_fcas_energy_regulating_capacity(pm, service, nw)

Ensures that the combined energy and regulating fcas values are contained within the fcas trapezium
"""
function constraint_fcas_energy_regulating_capacity(pm::_PM.AbstractPowerModel, service::FCASRegulatingService, nw::Int=_PM.nw_id_default)
    for (i, gen) in get_fcas_participants(_PM.ref(pm, nw, :gen), service)
        pg = _PM.var(pm, nw, :pg, i)

        fcas = gen["fcas"][service.id]
        p_fcas = _PM.var(pm, nw, Symbol("gen_$(fcas_name(service))"), i)

        lower_slope = fcas["lower_slope"]
        JuMP.@constraint(pm.model, pg - (lower_slope * p_fcas) >= fcas["emin"])

        upper_slope = fcas["upper_slope"]
        JuMP.@constraint(pm.model, pg + (upper_slope * p_fcas) <= fcas["emax"])
    end

    for (i, load) in get_fcas_participants(_PM.ref(pm, nw, :load), service)
        pd = _PM.var(pm, nw, :pd, i)

        fcas = load["fcas"][service.id]
        p_fcas = _PM.var(pm, nw, Symbol("load_$(fcas_name(service))"), i)

        lower_slope = fcas["lower_slope"]
        JuMP.@constraint(pm.model, pd - (lower_slope * p_fcas) >= fcas["emin"])

        upper_slope = fcas["upper_slope"]
        JuMP.@constraint(pm.model, pd + (upper_slope * p_fcas) <= fcas["emax"])

    end
end

"do nothing, not required for contingency FCAS services"
function constraint_fcas_energy_regulating_capacity(pm::_PM.AbstractPowerModel, service::FCASContingencyService, nw::Int=_PM.nw_id_default)
end

"do nothing, not required for regulating FCAS services"
function constraint_fcas_joint_capacity(pm::_PM.AbstractPowerModel, service::FCASRegulatingService, nw::Int=_PM.nw_id_default)
end

"""
    constraint_fcas_joint_capacity(pm, service, nw)

Ensures that the combined energy, regulating fcas and contingency fcas values are contained within the fcas trapezium
"""
function constraint_fcas_joint_capacity(pm::_PM.AbstractPowerModel, service::FCASContingencyService, nw::Int=_PM.nw_id_default)
    service_key = service.id

    for (i, gen) in get_fcas_participants(_PM.ref(pm, nw, :gen), service)
        pg = _PM.var(pm, nw, :pg, i)

        fcas = gen["fcas"][service_key]

        lower_regulating_enabled = fcas_enabled(fcas_services["LOWERREG"], gen)
        raise_regulating_enabled = fcas_enabled(fcas_services["RAISEREG"], gen)

        p_fcas = _PM.var(pm, nw, Symbol("gen_$(fcas_name(service))"), i)
        p_fcas_lreg = lower_regulating_enabled ? _PM.var(pm, nw, Symbol("gen_LReg"), i) : nothing
        p_fcas_rreg = raise_regulating_enabled ? _PM.var(pm, nw, Symbol("gen_RReg"), i) : nothing

        lower_slope = fcas["lower_slope"]
        if lower_regulating_enabled
            JuMP.@constraint(pm.model, pg - (lower_slope * p_fcas) - p_fcas_lreg >= fcas["emin"])
        else
            JuMP.@constraint(pm.model, pg - (lower_slope * p_fcas) >= fcas["emin"])
        end

        upper_slope = fcas["upper_slope"]
        if raise_regulating_enabled
            JuMP.@constraint(pm.model, pg + (upper_slope * p_fcas) + p_fcas_rreg <= fcas["emax"])
        else
            JuMP.@constraint(pm.model, pg + (upper_slope * p_fcas) <= fcas["emax"])
        end
    end

    for (i, load) in get_fcas_participants(_PM.ref(pm, nw, :load), service)
        pd = _PM.var(pm, nw, :pd, i)

        fcas = load["fcas"][service_key]
        lower_slope = fcas["lower_slope"]
        upper_slope = fcas["upper_slope"]

        p_fcas = _PM.var(pm, nw, Symbol("load_$(fcas_name(service))"), i)

        if fcas_enabled(fcas_services["LOWERREG"], load)
            p_fcas_lreg = _PM.var(pm, nw, Symbol("load_LReg"), i)
            JuMP.@constraint(pm.model, pd - (lower_slope * p_fcas) - p_fcas_lreg >= fcas["emin"])
        else
            JuMP.@constraint(pm.model, pd - (lower_slope * p_fcas) >= fcas["emin"])
        end

        if fcas_enabled(fcas_services["RAISEREG"], load)
            p_fcas_rreg = _PM.var(pm, nw, Symbol("load_RReg"), i)
            JuMP.@constraint(pm.model, pd + (upper_slope * p_fcas) + p_fcas_rreg <= fcas["emax"])
        else
            JuMP.@constraint(pm.model, pd + (upper_slope * p_fcas) <= fcas["emax"])
        end
    end
end

"""
    constraint_fcas_target(pm, service, nw)

Creates an equality constraint that sets an fcas service target
"""
function constraint_fcas_target(pm::_PM.AbstractPowerModel, service::FCASService, nw::Int=_PM.nw_id_default)
    fcas_targets = _PM.ref(pm, nw, :fcas_target)
    target = filter(x -> haskey(x, "service") && x["service"] == service.id, fcas_targets)
    area_gens = _PM.ref(pm, nw, :area_gens)
    bus_rr = _PM.ref(pm, nw, :bus_rr)
    area_bus = Dict(area => bus["index"] for (area, gens) in area_gens for (i,bus) in bus_rr if area == bus["area"])
 

    if length(target) > 0
        # fcas_target = first(target)
        for area in keys(area_gens)
            cstr_f = JuMP.@constraint(pm.model,
                sum(_PM.var(pm, nw, Symbol("gen_$(fcas_name(service))"), i) for i in keys(get_fcas_participants_by_area(_PM.ref(pm, nw, :gen), service, area, area_gens))) +
                sum(_PM.var(pm, nw, Symbol("load_$(fcas_name(service))"), i) for i in keys(get_fcas_participants_by_area(_PM.ref(pm, nw, :load), service, area, area_gens)))
                ==
                target_by_area(target, area)["p"])

                if _IM.report_duals(pm)
                    _PM.sol(pm, nw, :bus_rr, area_bus[area])[Symbol("lam_$(fcas_name(service))")] = cstr_f
                end
        end
    end
end


function constraint_benders_fcut(pm:: _PM.AbstractPowerModel, n::Int, i::Int, pg_sub, qg_sub, pconv_ac_master, qconv_ac_master, sub_obj, gen_lm_p, gen_lm_q, conv_lm_p, conv_lm_q)
    pg = _PM.var(pm, n, :pg)
    qg = _PM.var(pm, n, :qg)
    pconv_ac = _PM.var(pm, n, :pconv_ac)
    qconv_ac = _PM.var(pm, n, :qconv_ac)

    # JuMP.@constraint(pm.model, 0 >= sub_obj + sum(val * (pg[i] - pg_master[i]) for (i,val) in gen_lm_p) + sum(val * (qg[i] - qg_master[i]) for (i,val) in gen_lm_q) + sum(val * (pconv_ac[i] - pconv_ac_master[i]) for (i, val) in conv_lm_p) )
    JuMP.@constraint(pm.model, 0 <= sub_obj + sum(val * (pg_sub[i] - pg[i]) for (i,val) in gen_lm_p) + sum(val * (qg_sub[i] - qg[i]) for (i,val) in gen_lm_q) )
end

""


function constraint_benders_ocut(pm:: _PM.AbstractPowerModel, n::Int, i::Int, pg_sub, qg_sub, pconv_ac_master, qconv_ac_master, sub_obj, gen_lm_p, gen_lm_q, conv_lm_p, conv_lm_q)
    pg = _PM.var(pm, n, :pg)
    qg = _PM.var(pm, n, :qg)
    pconv_ac = _PM.var(pm, n, :pconv_ac)
    qconv_ac = _PM.var(pm, n, :qconv_ac)

    objective_variable_pg_cost(pm; kwargs...)
    objective_variable_pd_cost(pm; kwargs...)
    objective_variable_fcas_cost(pm; kwargs...)

    obj_expr = JuMP.@expression(pm.model, 
        sum(
            sum( _PM.var(pm, n, :pg_cost, i) for (i,gen) in nw_ref[:gen]) +
            sum(_PM.var(pm, n, Symbol("gen_$(fcas_name(fcas_service))_cost"), gen) for fcas_service = values(fcas_services) for gen = keys(get_fcas_participants(nw_ref[:gen], fcas_service))) +
            sum(_PM.var(pm, n, Symbol("load_$(fcas_name(fcas_service))_cost"), load) for fcas_service = values(fcas_services) for load = keys(get_fcas_participants(nw_ref[:load], fcas_service))) -
            sum( _PM.var(pm, n, :pd_cost, i) for (i,load) in get_dispatchable_participants(nw_ref[:load]))
    for (n, nw_ref) in _PM.nws(pm))
    ) 

    # JuMP.@constraint(pm.model, obj_expr >= sub_obj + sum(val * (pg[i] - pg_master[i]) for (i,val) in gen_lm_p) + sum(val * (qg[i] - qg_master[i]) for (i,val) in gen_lm_q) + sum(val * (pconv_ac[i] - pconv_ac_master[i]) for (i, val) in conv_lm_p))
    JuMP.@constraint(pm.model, obj_expr >= sub_obj + sum(val * (pg[i] - pg_sub[i]) for (i,val) in gen_lm_p) + sum(val * (qg[i] - qg_sub[i]) for (i,val) in gen_lm_q) )
end

""

function constraint_benders_ocut_soft(pm:: _PM.AbstractPowerModel, n::Int, i::Int, pg_sub, qg_sub, pconv_ac_master, qconv_ac_master, sub_obj, gen_lm_p, gen_lm_q, conv_lm_p, conv_lm_q, delta_p, delta_q)
    pg = _PM.var(pm, n, :pg)
    qg = _PM.var(pm, n, :qg)
    pconv_ac = _PM.var(pm, n, :pconv_ac)
    qconv_ac = _PM.var(pm, n, :qconv_ac)

    # delta_p = _PM.var(pm, n, :delta_p)
    # delta_q = _PM.var(pm, n, :delta_q)

    # objective_variable_pg_cost(pm)
    # objective_variable_pd_cost(pm)
    # objective_variable_fcas_cost(pm)

    

    obj_expr = JuMP.@expression(pm.model, 
    sum(
        sum( _PM.var(pm, n, :pg_cost, i) for (i,gen) in nw_ref[:gen]) +
        sum( _PM.var(pm, n, Symbol("gen_$(fcas_name(fcas_service))_cost"), gen) for fcas_service = values(fcas_services) for gen = keys(get_fcas_participants(nw_ref[:gen], fcas_service))) +
        sum( _PM.var(pm, n, Symbol("load_$(fcas_name(fcas_service))_cost"), load) for fcas_service = values(fcas_services) for load = keys(get_fcas_participants(nw_ref[:load], fcas_service))) -
        sum( _PM.var(pm, n, :pd_cost, i) for (i,load) in get_dispatchable_participants(nw_ref[:load])) -
        sum( 1E5*_PM.var(pm, n, :pb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) -
        sum( 1E5*_PM.var(pm, n, :pb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) -
        sum( 1E5*_PM.var(pm, n, :qb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) -
        sum( 1E5*_PM.var(pm, n, :qb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) -
        sum( 5E5*_PM.var(pm, n, :bf_vio_fr, i) for i in _PM.ids(pm, :branch) ) -
        sum( 5E5*_PM.var(pm, n, :bf_vio_to, i) for i in _PM.ids(pm, :branch) ) 
    for (n, nw_ref) in _PM.nws(pm))
                               )  

    # JuMP.@constraint(pm.model, obj_expr >= sub_obj + sum(val * (pg[i] - pg_master[i]) for (i,val) in gen_lm_p) + sum(val * (qg[i] - qg_master[i]) for (i,val) in gen_lm_q) + sum(val * (pconv_ac[i] - pconv_ac_master[i]) for (i, val) in conv_lm_p))
    JuMP.@constraint(pm.model, obj_expr <= (sub_obj + sum(val * (pg[i] - (pg_sub[i]-delta_p[i])) for (i,val) in gen_lm_p) + sum(val * (qg[i] - (qg_sub[i]-delta_q[i])) for (i,val) in gen_lm_q) ))
end