"""
Solves the exact AC-DC SCOPF master problem by including benders feasibility 
and optimality cuts
"""

function run_master_scopfcas_bf(data::Dict{String,Any}, model_type::Type{T}, solver; kwargs...) where T <: _PM.AbstractBFModel
    return _PM.solve_model(data, model_type, solver, build_master_scopfcas_bf; ref_extensions = [_PMACDC.add_ref_dcgrid!], kwargs...)
end

function build_master_scopfcas_bf(pm::_PM.AbstractPowerModel)

    _PM.variable_bus_voltage(pm)
    _PM.variable_gen_power(pm)
    _PM.variable_branch_power(pm)
    _PM.variable_branch_current(pm)
    
    variable_load_power(pm)
    variable_fcas(pm)

    

    _PMACDC.variable_active_dcbranch_flow(pm)
    _PMACDC.variable_dcbranch_current(pm)
    _PMACDC.variable_dc_converter(pm)
    _PMACDC.variable_dcgrid_voltage_magnitude(pm)

    _PM.constraint_model_current(pm)
    _PMACDC.constraint_voltage_dc(pm)

    for i in _PM.ids(pm, :ref_buses)
        _PM.constraint_theta_ref(pm, i)
    end

    for i in _PM.ids(pm, :bus)
        constraint_power_balance_ac(pm, i)
    end

    for i in _PM.ids(pm, :branch)
        _PM.constraint_power_losses(pm, i)
        _PM.constraint_voltage_magnitude_difference(pm, i)
        _PM.constraint_voltage_angle_difference(pm, i)
        _PM.constraint_thermal_limit_from(pm, i)
        _PM.constraint_thermal_limit_to(pm, i)
    end

    for i in _PM.ids(pm, :busdc)
        _PMACDC.constraint_power_balance_dc(pm, i)
    end

    for i in _PM.ids(pm, :branchdc)
        _PMACDC.constraint_ohms_dc_branch(pm, i)
        _PMACDC.constraint_dc_branch_current(pm, i)
    end

    for i in _PM.ids(pm, :convdc)
        _PMACDC.constraint_converter_losses(pm, i)
        _PMACDC.constraint_converter_current(pm, i)
        _PMACDC.constraint_conv_transformer(pm, i)
        _PMACDC.constraint_conv_reactor(pm, i)
        _PMACDC.constraint_conv_filter(pm, i)
        if pm.ref[:it][:pm][:nw][_PM.nw_id_default][:convdc][i]["islcc"] == 1
            _PMACDC.constraint_conv_firing_angle(pm, i)
        end
    end

    for service in values(fcas_services)
        constraint_fcas_target(pm, service)
        constraint_fcas_max_available(pm, service)
        constraint_fcas_energy_regulating_capacity(pm, service)
        constraint_fcas_joint_capacity(pm, service)
    end
    
    objective_min_cost(pm)

    for (i, cut) in enumerate(_PM.ref(pm, :ocuts))
        constraint_benders_ocut(pm, i)
    end

    for (i, cut) in enumerate(_PM.ref(pm, :fcuts))
        constraint_benders_fcut(pm, i)
    end

   
    

end


"""
Solves the soft AC-DC SCOPF master problem by including benders feasibility 
and optimality cuts allowing penalized violations in the nodal powre balance 
and branch thermal limit constraints.
"""

function run_master_scopfcas_bf_soft(data::Dict{String,Any}, model_type::Type{T}, solver; kwargs...) where T <: _PM.AbstractBFModel
    return _PM.solve_model(data, model_type, solver, build_master_scopfcas_bf_soft; ref_extensions = [_PMACDC.add_ref_dcgrid!], kwargs...)
end

function build_master_scopfcas_bf_soft(pm::_PM.AbstractPowerModel)

    _PM.variable_bus_voltage(pm)
    _PM.variable_gen_power(pm)
    _PM.variable_branch_power(pm)
    _PM.variable_branch_current(pm)

    variable_load_power(pm)
    variable_fcas(pm)
    
    _PMACDC.variable_active_dcbranch_flow(pm)
    _PMACDC.variable_dcbranch_current(pm)
    _PMACDC.variable_dc_converter(pm)
    _PMACDC.variable_dcgrid_voltage_magnitude(pm)

    _PM.constraint_model_current(pm)
    _PMACDC.constraint_voltage_dc(pm)

    _PMACDCsc.variable_branch_thermal_limit_violation(pm)
    _PMACDCsc.variable_power_balance_ac_positive_violation(pm)
    _PMACDCsc.variable_power_balance_ac_negative_violation(pm)  
    
    # _PMSC.variable_c2_branch_limit_slack(pm)

    for i in _PM.ids(pm, :ref_buses)
        _PM.constraint_theta_ref(pm, i)
    end

    for i in _PM.ids(pm, :bus)
        constraint_power_balance_ac_soft(pm, i)
    end

    for i in _PM.ids(pm, :branch)
        _PM.constraint_power_losses(pm, i)
        _PM.constraint_voltage_magnitude_difference(pm, i)
        _PM.constraint_voltage_angle_difference(pm, i)
        # _PM.constraint_thermal_limit_from(pm, i)
        # _PM.constraint_thermal_limit_to(pm, i)
        constraint_thermal_limit_from_soft(pm, i)
        constraint_thermal_limit_to_soft(pm, i)
    end

    for i in _PM.ids(pm, :busdc)
        _PMACDC.constraint_power_balance_dc(pm, i)
    end

    for i in _PM.ids(pm, :branchdc)
        _PMACDC.constraint_ohms_dc_branch(pm, i)
        _PMACDC.constraint_dc_branch_current(pm, i)
    end

    for i in _PM.ids(pm, :convdc)
        _PMACDC.constraint_converter_losses(pm, i)
        _PMACDC.constraint_converter_current(pm, i)
        _PMACDC.constraint_conv_transformer(pm, i)
        _PMACDC.constraint_conv_reactor(pm, i)
        _PMACDC.constraint_conv_filter(pm, i)
        if pm.ref[:it][:pm][:nw][_PM.nw_id_default][:convdc][i]["islcc"] == 1
            _PMACDC.constraint_conv_firing_angle(pm, i)
        end
    end

    for service in values(fcas_services)
        constraint_fcas_target(pm, service)
        constraint_fcas_max_available(pm, service)
        constraint_fcas_energy_regulating_capacity(pm, service)
        constraint_fcas_joint_capacity(pm, service)
    end

    objective_min_cost_soft(pm)

    for (i, cut) in enumerate(_PM.ref(pm, :ocuts))
        constraint_benders_ocut_soft(pm, i)
    end

    for (i, cut) in enumerate(_PM.ref(pm, :fcuts))
        constraint_benders_fcut(pm, i)
    end

end

"""
Solves the exact primal bounding AC-DC SCOPF subproblem for a contingency in the inner loop
of the nonconvex benders decomposition.

"""

function run_pb_sub_scopfcas_bf(data::Dict{String,Any}, model_type::Type{T}, solver; kwargs...) where T <: _PM.AbstractBFModel
    return _PM.solve_model(data, model_type, solver, build_pb_sub_scopfcas_bf; ref_extensions = [_PMACDC.add_ref_dcgrid!], kwargs...)
end

function build_pb_sub_scopfcas_bf(pm::_PM.AbstractPowerModel)

    _PM.variable_bus_voltage(pm)
    _PM.variable_gen_power(pm)
    _PM.variable_branch_power(pm)
    _PM.variable_branch_current(pm)
    _PM.constraint_model_current(pm)

    variable_load_power(pm)
    variable_fcas(pm)

    _PMACDC.variable_active_dcbranch_flow(pm)
    _PMACDC.variable_dcbranch_current(pm)
    _PMACDC.variable_dc_converter(pm)
    _PMACDC.variable_dcgrid_voltage_magnitude(pm)
    _PMACDC.constraint_voltage_dc(pm)           

    variable_gen_response_delta(pm, bounded=true)
    variable_load_response_delta(pm)
    # for (i,gen) in _PM.ref(pm, 0, :gen)
    #     JuMP.set_upper_bound(_PM.var(pm, 0, :delta_p, i), 1.5)
    #     JuMP.set_lower_bound(_PM.var(pm, 0, :delta_p, i), -1.5)
    # end
    



    # fix_load_variables_to_master(pm)
    for i in keys(get_dispatchable_participants(_PM.ref(pm, :load)))
        constraint_load_active_setpoint_link(pm, i)
    end

    for service in values(fcas_services)
        constraint_gen_fcas_setpoint_link(pm, service)
        # constraint_load_fcas_setpoint_link(pm, service)
    end

    for i in _PM.ids(pm, :gen)
        constraint_gen_real_setpoint_link(pm,i)
        constraint_gen_reactive_setpoint_link(pm,i)
        # println("G $i .... $(JuMP.upper_bound(_PM.var(pm, :delta_p, i)))")
        # println("G $i .... $(JuMP.lower_bound(_PM.var(pm, :delta_p, i)))")
    end

    for i in _PM.ids(pm, :ref_buses)
        _PM.constraint_theta_ref(pm, i)
    end

    for i in _PM.ids(pm, :bus)
        constraint_power_balance_ac(pm, i)
    end

    for i in _PM.ids(pm, :branch)
        _PM.constraint_power_losses(pm, i)
        _PM.constraint_voltage_magnitude_difference(pm, i)
        _PM.constraint_voltage_angle_difference(pm, i)
        _PM.constraint_thermal_limit_from(pm, i)
        _PM.constraint_thermal_limit_to(pm, i)
    end

    for i in _PM.ids(pm, :busdc)
        _PMACDC.constraint_power_balance_dc(pm, i)
    end

    for i in _PM.ids(pm, :branchdc)
        _PMACDC.constraint_ohms_dc_branch(pm, i)
        _PMACDC.constraint_dc_branch_current(pm, i)
    end

    for i in _PM.ids(pm, :convdc)
        _PMACDC.constraint_converter_losses(pm, i)
        _PMACDC.constraint_converter_current(pm, i)
        _PMACDC.constraint_conv_transformer(pm, i)
        _PMACDC.constraint_conv_reactor(pm, i)
        _PMACDC.constraint_conv_filter(pm, i)
        if pm.ref[:it][:pm][:nw][_PM.nw_id_default][:convdc][i]["islcc"] == 1
            _PMACDC.constraint_conv_firing_angle(pm, i)
        end
        constraint_conv_real_setpoint_link(pm,i)
        constraint_conv_reactive_setpoint_link(pm,i)
    end

    
    for service in values(fcas_services)
        constraint_fcas_target(pm, service)
        constraint_fcas_max_available(pm, service)
        constraint_fcas_energy_regulating_capacity(pm, service)
        constraint_fcas_joint_capacity(pm, service)
    end


    objective_min_cost(pm)

end

"""
Solves the soft primal bounding AC-DC SCOPF subproblem for a contingency in the inner loop
of the nonconvex benders decomposition allowing penalized violations in the  
nodal powre balance and branch thermal limit constraints.

"""

# function run_pb_sub_scopf_bf_soft(data::Dict{String,Any}, model_type::Type{T}, solver; kwargs...) where T <: _PM.AbstractBFModel
#     return _PM.solve_model(data, model_type, solver, build_pb_sub_scopf_bf_soft; ref_extensions = [_PMACDC.add_ref_dcgrid!], kwargs...)
# end

# function build_pb_sub_scopf_bf_soft(pm::_PM.AbstractPowerModel)

#     _PM.variable_bus_voltage(pm)
#     _PM.variable_gen_power(pm)
#     _PM.variable_branch_power(pm)
#     _PM.variable_branch_current(pm)
#     _PM.constraint_model_current(pm)

#     _PMACDC.variable_active_dcbranch_flow(pm)
#     _PMACDC.variable_dcbranch_current(pm)
#     _PMACDC.variable_dc_converter(pm)
#     _PMACDC.variable_dcgrid_voltage_magnitude(pm)
#     _PMACDC.constraint_voltage_dc(pm)  
    
#     variable_gen_response_delta(pm)

#     _PMACDCsc.variable_branch_thermal_limit_violation(pm)
#     _PMACDCsc.variable_power_balance_ac_positive_violation(pm)
#     _PMACDCsc.variable_power_balance_ac_negative_violation(pm)   

#     for i in _PM.ids(pm, :gen)
#         constraint_gen_real_setpoint_link(pm,i)
#         constraint_gen_reactive_setpoint_link(pm,i)
#     end

#     for i in _PM.ids(pm, :ref_buses)
#         _PM.constraint_theta_ref(pm, i)
#     end

#     for i in _PM.ids(pm, :bus)
#         _PMACDC.constraint_power_balance_ac(pm,i)
#     end

#     for i in _PM.ids(pm, :branch)
#         _PM.constraint_power_losses(pm, i)
#         _PM.constraint_voltage_magnitude_difference(pm, i)
#         _PM.constraint_voltage_angle_difference(pm, i)
#         _PM.constraint_thermal_limit_from(pm, i)
#         _PM.constraint_thermal_limit_to(pm, i)
#     end

#     for i in _PM.ids(pm, :busdc)
#         _PMACDC.constraint_power_balance_dc(pm, i)
#     end

#     for i in _PM.ids(pm, :branchdc)
#         _PMACDC.constraint_ohms_dc_branch(pm, i)
#         _PMACDC.constraint_dc_branch_current(pm, i)
#     end

#     for i in _PM.ids(pm, :convdc)
#         _PMACDC.constraint_converter_losses(pm, i)
#         _PMACDC.constraint_converter_current(pm, i)
#         _PMACDC.constraint_conv_transformer(pm, i)
#         _PMACDC.constraint_conv_reactor(pm, i)
#         _PMACDC.constraint_conv_filter(pm, i)
#         if pm.ref[:it][:pm][:nw][_PM.nw_id_default][:convdc][i]["islcc"] == 1
#             _PMACDC.constraint_conv_firing_angle(pm, i)
#         end
#         constraint_conv_real_setpoint_link(pm,i)
#         constraint_conv_reactive_setpoint_link(pm,i)
#     end

#     # objective
#     _PMSC.objective_c1_variable_pg_cost_basecase(pm)
#     pg_cost = _PM.var(pm, :pg_cost)
#     JuMP.@objective(pm.model, Min,
#     sum( pg_cost[i] for (i, gen) in _PM.ref(pm, :gen) ) +
#     sum(
#         sum( 5E5*_PM.var(pm, :bf_vio_fr, i) for i in _PM.ids(pm, :branch) ) +
#         sum( 5E5*_PM.var(pm, :bf_vio_to, i) for i in _PM.ids(pm, :branch) ) + 
#         sum( 5E5*_PM.var(pm, :pb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) +
#         sum( 5E5*_PM.var(pm, :pb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) +
#         sum( 5E5*_PM.var(pm, :qb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) +
#         sum( 5E5*_PM.var(pm, :qb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) )
#         )
#     )

# end

"""
Solves the soft AC-DC SCOPF feasibility subproblem for a contingency in the inner 
loop of the nonconvex benders decomposition allowing penalized violations in the  
nodal powre balance and branch thermal limit constraints.

"""

function run_f_sub_scopfcas_bf_soft(data::Dict{String,Any}, model_type::Type{T}, solver; kwargs...) where T <: _PM.AbstractBFModel
    return _PM.solve_model(data, model_type, solver, build_f_sub_scopfcas_bf_soft; ref_extensions = [_PMACDC.add_ref_dcgrid!, _PMSC.ref_c1!], kwargs...)
end

function build_f_sub_scopfcas_bf_soft(pm::_PM.AbstractPowerModel)

    _PM.variable_bus_voltage(pm)
    _PM.variable_gen_power(pm)
    _PM.variable_branch_power(pm)
    _PM.variable_branch_current(pm)

    variable_load_power(pm)
    # variable_fcas(pm)

    _PMACDC.variable_active_dcbranch_flow(pm)
    _PMACDC.variable_dcbranch_current(pm)
    _PMACDC.variable_dc_converter(pm)
    _PMACDC.variable_dcgrid_voltage_magnitude(pm)
    
    variable_gen_response_delta(pm, bounded=true)
    variable_load_response_delta(pm)

    delta_p_slack = _PM.var(pm, 0)[:delta_p_slack] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, 0, :gen)], base_name="$(0)_delta_p_slack")
    for (i,gen) in _PM.ref(pm, 0, :gen)
        JuMP.set_upper_bound(delta_p_slack[i], 5)
        JuMP.set_lower_bound(delta_p_slack[i], 0)
    end
    delta_pn_slack = _PM.var(pm, 0)[:delta_pn_slack] = JuMP.@variable(pm.model,
    [i in _PM.ids(pm, 0, :gen)], base_name="$(0)_delta_pn_slack")
    for (i,gen) in _PM.ref(pm, 0, :gen)
        JuMP.set_upper_bound(delta_pn_slack[i], 5)
        JuMP.set_lower_bound(delta_pn_slack[i], 0)
    end

    _PM.sol_component_value(pm, 0, :gen, :delta_p_slack, _PM.ids(pm, 0, :gen), delta_p_slack)
    _PM.sol_component_value(pm, 0, :gen, :delta_pn_slack, _PM.ids(pm, 0, :gen), delta_pn_slack)

    _PMACDCsc.variable_branch_thermal_limit_violation(pm)
    _PMACDCsc.variable_power_balance_ac_positive_violation(pm)
    _PMACDCsc.variable_power_balance_ac_negative_violation(pm)

    _PM.constraint_model_current(pm)
    _PMACDC.constraint_voltage_dc(pm)
    
    for (i,load) in get_dispatchable_participants(_PM.ref(pm, :load))
        constraint_load_active_setpoint_link(pm, i)
    end

    # for service in values(fcas_services)
    #     constraint_gen_fcas_setpoint_link(pm, service)
    #     # constraint_load_fcas_setpoint_link(pm, service)
    # end

    for i in _PM.ids(pm, :gen)
        constraint_gen_real_setpoint_link_soft(pm,i)
        constraint_gen_reactive_setpoint_link(pm,i)
    end

    for i in _PM.ids(pm, :ref_buses)
        _PM.constraint_theta_ref(pm, i)
    end

    for i in _PM.ids(pm, :bus)
        constraint_power_balance_ac_soft(pm, i)
    end

    for i in _PM.ids(pm, :branch)
        _PM.constraint_power_losses(pm, i)
        _PM.constraint_voltage_magnitude_difference(pm, i)
        _PM.constraint_voltage_angle_difference(pm, i)
        constraint_thermal_limit_from_soft(pm, i)
        constraint_thermal_limit_to_soft(pm, i)
    end

    for i in _PM.ids(pm, :busdc)
        _PMACDC.constraint_power_balance_dc(pm, i)
    end

    for i in _PM.ids(pm, :branchdc)
        _PMACDC.constraint_ohms_dc_branch(pm, i)
        _PMACDC.constraint_dc_branch_current(pm, i)
    end

    for i in _PM.ids(pm, :convdc)
        _PMACDC.constraint_converter_losses(pm, i)
        _PMACDC.constraint_converter_current(pm, i)
        _PMACDC.constraint_conv_transformer(pm, i)
        _PMACDC.constraint_conv_reactor(pm, i)
        _PMACDC.constraint_conv_filter(pm, i)
        if pm.ref[:it][:pm][:nw][_PM.nw_id_default][:convdc][i]["islcc"] == 1
            _PMACDC.constraint_conv_firing_angle(pm, i)
        end
        constraint_conv_real_setpoint_link(pm,i)
        constraint_conv_reactive_setpoint_link(pm,i)
    end

    # for service in values(fcas_services)
    #     constraint_fcas_target(pm, service)
    #     constraint_fcas_max_available(pm, service)
    #     constraint_fcas_energy_regulating_capacity(pm, service)
    #     constraint_fcas_joint_capacity(pm, service)
    # end


    objective_f_min_cost_soft(pm)


end

"""
Solves the nonconvex soft AC-DC SCOPF subproblem by including the given objective lower bound 
from the inner loop of the nonconvex benders decomposition allowing penalized violations in 
the nodal powre balance and branch thermal limit constraints.

"""
function run_nc_sub_scopf_soft(data::Dict{String,Any}, model_type::Type, solver; kwargs...)
    return _PM.solve_model(data, model_type, solver, build_nc_sub_scopf_soft; ref_extensions = [_PMACDC.add_ref_dcgrid!], kwargs...)
end


function build_nc_sub_scopf_soft(pm::_PM.AbstractPowerModel)
    _PM.variable_bus_voltage(pm)
    _PM.variable_gen_power(pm)
    _PM.variable_branch_power(pm)

    _PMACDC.variable_active_dcbranch_flow(pm)
    _PMACDC.variable_dcbranch_current(pm)
    _PMACDC.variable_dc_converter(pm)
    _PMACDC.variable_dcgrid_voltage_magnitude(pm)

    _PMACDCsc.variable_branch_thermal_limit_violation(pm)
    _PMACDCsc.variable_power_balance_ac_positive_violation(pm)
    _PMACDCsc.variable_power_balance_ac_negative_violation(pm) 

    # _PM.objective_min_fuel_cost(pm)

    _PM.constraint_model_voltage(pm)
    _PMACDC.constraint_voltage_dc(pm)


    for i in _PM.ids(pm, :gen)
        # constraint_gen_real_setpoint_link(pm,i)
        # constraint_gen_reactive_setpoint_link(pm,i)
    end

    for i in _PM.ids(pm, :ref_buses)
        _PM.constraint_theta_ref(pm, i)
    end

    for i in _PM.ids(pm, :bus)
        # _PMACDC.constraint_power_balance_ac(pm, i)
        constraint_power_balance_ac_soft(pm, i)
    end

    for i in _PM.ids(pm, :branch)
        _PM.constraint_ohms_yt_from(pm, i)
        _PM.constraint_ohms_yt_to(pm, i)
        _PM.constraint_voltage_angle_difference(pm, i) 
        # _PM.constraint_thermal_limit_from(pm, i)
        # _PM.constraint_thermal_limit_to(pm, i)
        constraint_thermal_limit_from_soft(pm, i)
        constraint_thermal_limit_to_soft(pm, i)
    end
    for i in _PM.ids(pm, :busdc)
        _PMACDC.constraint_power_balance_dc(pm, i)
    end
    for i in _PM.ids(pm, :branchdc)
        _PMACDC.constraint_ohms_dc_branch(pm, i)
    end
    for i in _PM.ids(pm, :convdc)
        _PMACDC.constraint_converter_losses(pm, i)
        _PMACDC.constraint_converter_current(pm, i)
        _PMACDC.constraint_conv_transformer(pm, i)
        _PMACDC.constraint_conv_reactor(pm, i)
        _PMACDC.constraint_conv_filter(pm, i)
        if pm.ref[:it][:pm][:nw][_PM.nw_id_default][:convdc][i]["islcc"] == 1
            _PMACDC.constraint_conv_firing_angle(pm, i)
        end
        # constraint_conv_real_setpoint_link(pm,i)
        constraint_conv_reactive_setpoint_link(pm,i)
    end

    # objective
    _PMSC.objective_c1_variable_pg_cost_basecase(pm)
    pg_cost = _PM.var(pm, :pg_cost)
   
    obj_expr = JuMP.@expression(pm.model,
    sum( pg_cost[i] for (i, gen) in _PM.ref(pm, :gen) ) +
    sum(
        sum( 5E5*_PM.var(pm, :bf_vio_fr, i) for i in _PM.ids(pm, :branch) ) +
        sum( 5E5*_PM.var(pm, :bf_vio_to, i) for i in _PM.ids(pm, :branch) ) + 
        sum( 5E5*_PM.var(pm, :pb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) +
        sum( 5E5*_PM.var(pm, :pb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) +
        sum( 5E5*_PM.var(pm, :qb_ac_pos_vio, i) for i in _PM.ids(pm, :bus) ) +
        sum( 5E5*_PM.var(pm, :qb_ac_neg_vio, i) for i in _PM.ids(pm, :bus) ) #+
        # sum( 5E5*(_PM.var(pm, :pg, i) - _PM.ref(pm, :gen, i, "pg")) for i in _PM.ids(pm, :gen) ) +
        # sum( 5E5*(_PM.var(pm, :qg, i) - _PM.ref(pm, :gen, i, "qg")) for i in _PM.ids(pm, :gen) )
        )
    )
    

    JuMP.@objective(pm.model, Min, obj_expr)

    # Setting a lower bound   
    JuMP.@constraint(pm.model, obj_expr >= _PM.ref(pm, :soc_master_obj))


end