

""

function constraint_gen_real_setpoint_link(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    pg_master = _PM.ref(pm, nw, :gen, i)["pg"]

    constraint_gen_real_setpoint_link(pm, nw, i, pg_master)
end

function constraint_gen_real_setpoint_link_soft(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    pg_master = _PM.ref(pm, nw, :gen, i)["pg"]

    constraint_gen_real_setpoint_link_soft(pm, nw, i, pg_master)
end


""
function constraint_load_active_setpoint_link(pm::_PM.AbstractPowerModel, i::Int, nw::Int=_PM.nw_id_default)
    pd_master = _PM.ref(pm, nw, :load, i)["pd"]

    constraint_load_active_setpoint_link(pm, nw, i, pd_master)
end

function constraint_gen_reactive_setpoint_link(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    qg_master = _PM.ref(pm, nw, :gen, i)["qg"]

    constraint_gen_reactive_setpoint_link(pm, nw, i, qg_master)
end

""
function constraint_conv_real_setpoint_link(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    pconv_ac_master = -_PM.ref(pm, nw, :convdc, i)["P_g"]  

    constraint_conv_real_setpoint_link(pm, nw, i, pconv_ac_master)
end

""

function constraint_conv_reactive_setpoint_link(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    qconv_ac_master = -_PM.ref(pm, nw, :convdc, i)["Q_g"]  

    constraint_conv_reactive_setpoint_link(pm, nw, i, qconv_ac_master)
end

function constraint_gen_fcas_setpoint_link(pm::_PM.AbstractPowerModel, service::FCASService, nw::Int=_PM.nw_id_default)
    gens = get_fcas_participants(_PM.ref(pm, nw, :gen), service)
    for (i, gen) in gens
        gen_service_value_m = gen["gen_$(fcas_name(service))"]
        constraint_gen_fcas_setpoint_link(pm, service, nw, i, gen_service_value_m)
    end

    #     gen_R1S_master = gen["gen_R1S"]
    #     gen_L6S_master = gen["gen_L6S"]
    #     gen_R6S_master = gen["gen_R6S"]
    #     gen_L60S_master = gen["gen_L60S"]
    #     gen_R60S_master = gen["gen_R60S"]
    #     gen_L5M_master = gen["gen_L5M"]
    #     gen_R5M_master = gen["gen_R5M"]
    #     gen_LReg_master = gen["gen_LReg"]
    #     gen_RReg_master = gen["gen_RReg"]
    


    # constraint_gen_fcas_setpoint_link(pm, nw, i, gen_L1S_master, gen_R1S_master, gen_L6S_master, gen_R6S_master, gen_L60S_master, gen_R60S_master, gen_L5M_master, gen_R5M_master, gen_LReg_master, gen_RReg_master)
end
function constraint_load_fcas_setpoint_link(pm::_PM.AbstractPowerModel, service::FCASService, nw::Int=_PM.nw_id_default)
    loads = get_fcas_participants(_PM.ref(pm, nw, :load), service)
    for (i, load) in loads
        load_service_value_m = load["load_$(fcas_name(service))"]
        constraint_load_fcas_setpoint_link(pm, service, nw, i, load_service_value_m)
    end
end

function constraint_thermal_limit_from_soft(pm:: _PM.AbstractPowerModel, i::Int; nw::Int= _PM.nw_id_default)
    branch =  _PM.ref(pm, nw, :branch, i)
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    f_idx = (i, f_bus, t_bus)

    if haskey(branch, "rate_a")
        constraint_thermal_limit_from_soft(pm, nw, i, f_idx, branch["rate_a"])
    end
end

""

function constraint_thermal_limit_to_soft(pm:: _PM.AbstractPowerModel, i::Int; nw::Int= _PM.nw_id_default)
    branch =  _PM.ref(pm, nw, :branch, i)
    f_bus = branch["f_bus"]
    t_bus = branch["t_bus"]
    t_idx = (i, t_bus, f_bus)

    if haskey(branch, "rate_a")
        constraint_thermal_limit_to_soft(pm, nw, i, t_idx, branch["rate_a"])
    end
end


"""
    constraint_power_balance_ac(pm, i; nw)

Extends PowerModels constraint_power_balance_ac by replacing the static load (pd) with a 
load variable for scheduled loads.
"""
function constraint_power_balance_ac(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    bus = _PM.ref(pm, nw, :bus, i)
    bus_arcs = _PM.ref(pm, nw, :bus_arcs, i)
    bus_arcs_dc = _PM.ref(pm, nw, :bus_arcs_dc, i)
    bus_gens = _PM.ref(pm, nw, :bus_gens, i)
    bus_convs_ac = _PM.ref(pm, nw, :bus_convs_ac, i)
    bus_loads = _PM.ref(pm, nw, :bus_loads, i)
    bus_shunts = _PM.ref(pm, nw, :bus_shunts, i)

    pd = Dict{Int64,Any}(k => _PM.ref(pm, nw, :load, k, "pd") for k in bus_loads)
    qd = Dict(k => _PM.ref(pm, nw, :load, k, "qd") for k in bus_loads)

    gs = Dict(k => _PM.ref(pm, nw, :shunt, k, "gs") for k in bus_shunts)
    bs = Dict(k => _PM.ref(pm, nw, :shunt, k, "bs") for k in bus_shunts)

    constraint_power_balance_ac(pm, nw, i, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
end
function constraint_power_balance_ac_mlf(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    bus = _PM.ref(pm, nw, :bus, i)
    bus_arcs = _PM.ref(pm, nw, :bus_arcs, i)
    bus_arcs_dc = _PM.ref(pm, nw, :bus_arcs_dc, i)
    bus_gens = _PM.ref(pm, nw, :bus_gens, i)
    bus_convs_ac = _PM.ref(pm, nw, :bus_convs_ac, i)
    bus_loads = _PM.ref(pm, nw, :bus_loads, i)
    bus_shunts = _PM.ref(pm, nw, :bus_shunts, i)

    pd = Dict{Int64,Any}(k => _PM.ref(pm, nw, :load, k, "pd") for k in bus_loads)
    qd = Dict(k => _PM.ref(pm, nw, :load, k, "qd") for k in bus_loads)

    gs = Dict(k => _PM.ref(pm, nw, :shunt, k, "gs") for k in bus_shunts)
    bs = Dict(k => _PM.ref(pm, nw, :shunt, k, "bs") for k in bus_shunts)

    constraint_power_balance_ac_mlf(pm, nw, i, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
end



function constraint_power_balance_ac_soft(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    bus = _PM.ref(pm, nw, :bus, i)
    bus_arcs = _PM.ref(pm, nw, :bus_arcs, i)
    bus_arcs_dc = _PM.ref(pm, nw, :bus_arcs_dc, i)
    bus_gens = _PM.ref(pm, nw, :bus_gens, i)
    bus_convs_ac = _PM.ref(pm, nw, :bus_convs_ac, i)
    bus_loads = _PM.ref(pm, nw, :bus_loads, i)
    bus_shunts = _PM.ref(pm, nw, :bus_shunts, i)

    pd = Dict{Int64,Any}(k => _PM.ref(pm, nw, :load, k, "pd") for k in bus_loads)
    qd = Dict(k => _PM.ref(pm, nw, :load, k, "qd") for k in bus_loads)

    gs = Dict(k => _PM.ref(pm, nw, :shunt, k, "gs") for k in bus_shunts)
    bs = Dict(k => _PM.ref(pm, nw, :shunt, k, "bs") for k in bus_shunts)

    constraint_power_balance_ac_soft(pm, nw, i, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
end

function constraint_current_balance_ac(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    bus = _PM.ref(pm, nw, :bus, i)
    bus_arcs = _PM.ref(pm, nw, :bus_arcs, i)
    bus_arcs_dc = _PM.ref(pm, nw, :bus_arcs_dc, i)
    bus_gens = _PM.ref(pm, nw, :bus_gens, i)
    bus_convs_ac = _PM.ref(pm, nw, :bus_convs_ac, i)
    bus_loads = _PM.ref(pm, nw, :bus_loads, i)
    bus_shunts = _PM.ref(pm, nw, :bus_shunts, i)

    pd = Dict{Int64,Any}(k => _PM.ref(pm, nw, :load, k, "pd") for k in bus_loads)
    qd = Dict(k => _PM.ref(pm, nw, :load, k, "qd") for k in bus_loads)

    gs = Dict(k => _PM.ref(pm, nw, :shunt, k, "gs") for k in bus_shunts)
    bs = Dict(k => _PM.ref(pm, nw, :shunt, k, "bs") for k in bus_shunts)

    constraint_current_balance_ac(pm, nw, i, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
end

function constraint_gen_power(pm::_PM.AbstractIVRModel, g::Int; nw::Int=_PM.nw_id_default)
    i   = _PM.ref(pm, nw, :gen, g, "gen_bus")

    constraint_gen_power_real(pm, nw, i, g)
    constraint_gen_power_imaginary(pm, nw, i, g)
end

function constraint_generator_ramping(pm::_PM.AbstractPowerModel, i::Int, nw::Int =_PM.nw_id_default)
    if nw == 1
        nothing
    else
        previous_hour_network = get_previous_hour_network_id(pm, nw)
        gen = _PM.ref(pm, nw, :gen, i)
        Δt = _PM.ref(pm, nw, :time_interval)
        ΔPg_up = gen["Ramp_Up_Rate(MW/h)"] * Δt 
        ΔPg_down = gen["Ramp_Down_Rate(MW/h)"] * Δt
        
        constraint_generator_ramping(pm, nw, i, previous_hour_network, ΔPg_up, ΔPg_down)
    end
end


function constraint_benders_fcut(pm:: _PM.AbstractPowerModel, i::Int; nw::Int =_PM.nw_id_default)
    pconv_ac_master = Dict(i => -_PM.ref(pm, nw, :convdc, i)["P_g"] for (i,convdc) in _PM.ref(pm, nw, :convdc))      
    qconv_ac_master = Dict(i => -_PM.ref(pm, nw, :convdc, i)["Q_g"] for (i,convdc) in _PM.ref(pm, nw, :convdc)) 
    cut = _PM.ref(pm, nw, :fcuts, i)
    sub_obj = cut.obj
    gen_lm_p = cut.lm_p
    gen_lm_q = cut.lm_q
    pg_sub = cut.pg_sub
    qg_sub = cut.qg_sub
    conv_lm_p = cut.lm_ac_p
    conv_lm_q = cut.lm_ac_q

    constraint_benders_fcut(pm, nw, i, pg_sub, qg_sub, pconv_ac_master, qconv_ac_master, sub_obj, gen_lm_p, gen_lm_q, conv_lm_p, conv_lm_q)
end

""

function constraint_benders_ocut(pm:: _PM.AbstractPowerModel, i::Int; nw::Int =_PM.nw_id_default)
    pconv_ac_master = Dict(i => -_PM.ref(pm, nw, :convdc, i)["P_g"] for (i,convdc) in _PM.ref(pm, nw, :convdc))      
    qconv_ac_master = Dict(i => -_PM.ref(pm, nw, :convdc, i)["Q_g"] for (i,convdc) in _PM.ref(pm, nw, :convdc)) 
    cut = _PM.ref(pm, nw, :ocuts, i)
    sub_obj = cut.obj
    gen_lm_p = cut.lm_p
    gen_lm_q = cut.lm_q
    pg_sub = cut.pg_sub
    qg_sub = cut.qg_sub
    conv_lm_p = cut.lm_ac_p
    conv_lm_q = cut.lm_ac_q

    constraint_benders_ocut(pm, nw, i, pg_sub, qg_sub, pconv_ac_master, qconv_ac_master, sub_obj, gen_lm_p, gen_lm_q, conv_lm_p, conv_lm_q)
end

""

function constraint_benders_ocut_soft(pm:: _PM.AbstractPowerModel, i::Int; nw::Int =_PM.nw_id_default)
    pconv_ac_master = Dict(i => -_PM.ref(pm, nw, :convdc, i)["P_g"] for (i,convdc) in _PM.ref(pm, nw, :convdc))      
    qconv_ac_master = Dict(i => -_PM.ref(pm, nw, :convdc, i)["Q_g"] for (i,convdc) in _PM.ref(pm, nw, :convdc)) 
    cut = _PM.ref(pm, nw, :ocuts, i)
    sub_obj = cut.obj
    gen_lm_p = cut.lm_p
    gen_lm_q = cut.lm_q
    pg_sub = cut.pg_sub
    qg_sub = cut.qg_sub
    conv_lm_p = cut.lm_ac_p
    conv_lm_q = cut.lm_ac_q
    delta_p = cut.delta_p
    delta_q = cut.delta_q

    constraint_benders_ocut_soft(pm, nw, i, pg_sub, qg_sub, pconv_ac_master, qconv_ac_master, sub_obj, gen_lm_p, gen_lm_q, conv_lm_p, conv_lm_q, delta_p, delta_q)
end

function constraint_power_balance(pm::AbstractCPModel, i::Int, nw::Int=_PM.nw_id_default)
    bus_rr_gens = [gen["index"] for (g, gen) in _PM.ref(pm, nw, :gen) if _PM.ref(pm, nw, :bus)[gen["gen_bus"]]["area"] == _PM.ref(pm, nw, :bus, i, "area")]
    bus_rr_loads = [load["index"] for (l, load) in _PM.ref(pm, nw, :load) if _PM.ref(pm, nw, :bus)[load["load_bus"]]["area"] == _PM.ref(pm, nw, :bus, i, "area")]
    branch_intc_fr = [branch["index"] for (b, branch) in _PM.ref(pm, nw, :branch_intc) if branch["f_bus"] == i ]
    branch_intc_to = [branch["index"] for (b, branch) in _PM.ref(pm, nw, :branch_intc) if branch["t_bus"] == i ]

    pd = Dict{Int64,Any}(k => _PM.ref(pm, nw, :load, k, "pd") for k in bus_rr_loads)

    constraint_power_balance(pm, nw, i, bus_rr_gens, bus_rr_loads, pd, branch_intc_fr, branch_intc_to)
end 

function constraint_branch_intc_min_fl(pm::AbstractCPModel, i::Int, nw::Int=_PM.nw_id_default)
   imin_fl = _PM.ref(pm, nw, :branch_intc, i)["imin_fl"]
    constraint_branch_intc_min_fl(pm, nw, i, imin_fl)
end


function constraint_model_current_exact(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default)
    constraint_model_current_exact(pm, nw)
end

function constraint_voltage_dc_exact(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default)
    constraint_voltage_dc_exact(pm, nw)
end

function constraint_dc_branch_current_exact(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    vpu = 1;
    branch = _PM.ref(pm, nw, :branchdc, i)
    f_bus = branch["fbusdc"]
    t_bus = branch["tbusdc"]
    f_idx = (i, f_bus, t_bus)

    ccm_max = (_PM.comp_start_value(_PM.ref(pm, nw, :branchdc, i), "rateA", 0.0) / vpu)^2

    p = _PM.ref(pm, nw, :dcpol)
    constraint_dc_branch_current_exact(pm, nw, i, f_bus, f_idx, ccm_max, p)
end


function constraint_model_voltage(pm::_PM.AbstractPowerModel; nw::Int=_PM.nw_id_default)
    constraint_model_voltage(pm, nw)
end

function constraint_converter_current(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    conv = _PM.ref(pm, nw, :convdc, i)
    Vmax = conv["Vmmax"]
    Imax = conv["Imax"]
    constraint_converter_current(pm, nw, i, Vmax, Imax)

end

function constraint_conv_transformer(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    conv = _PM.ref(pm, nw, :convdc, i)
    constraint_conv_transformer(pm, nw, i, conv["rtf"], conv["xtf"], conv["busac_i"], conv["tm"], Bool(conv["transformer"]))
end

function constraint_conv_reactor(pm::_PM.AbstractPowerModel, i::Int; nw::Int=_PM.nw_id_default)
    conv = _PM.ref(pm, nw, :convdc, i)
    constraint_conv_reactor(pm, nw, i, conv["rc"], conv["xc"], Bool(conv["reactor"]))
end