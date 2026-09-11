export run_mn_acdcopfcas


""
function run_mn_acdcopfcas(data::Dict{String,Any}, model_type::Type, solver; kwargs...)
    solution_processors = [solution_processor]
# `ref_add_gendc!` builds `ref(pm, :bus_gens_dc)`, which the DC power-balance
# constraints below read. PowerModelsACDC folded that into `add_ref_dcgrid!` up
# to 0.8 and split it into its own extension afterwards, so listing both keeps
# the builder working across the split rather than throwing
# `KeyError: :bus_gens_dc` at build time.
    return _PM.solve_model(data, model_type, solver, build_mn_acdcopfcas; multinetwork=true, ref_extensions=[_PMACDC.add_ref_dcgrid!, _PMACDC.ref_add_gendc!], solution_processors, kwargs...)
end

""
function build_mn_acdcopfcas(pm::_PM.AbstractPowerModel)
    for n in pm.ref[:it][:pm][:hour_ids]    #(n, network) in _PM.nws(pm)
        _PM.variable_bus_voltage(pm, nw=n)
        _PM.variable_gen_power(pm, nw=n)
        _PM.variable_branch_power(pm, nw=n)
            variable_load_power(pm, nw=n)
            variable_fcas(pm, n)
    
        _PMACDC.variable_active_dcbranch_flow(pm, nw=n)
        _PMACDC.variable_dcbranch_current(pm, nw=n)
        _PMACDC.variable_dc_converter(pm, nw=n)
        _PMACDC.variable_dcgrid_voltage_magnitude(pm, nw=n)
    # DC generators. PowerModelsACDC 0.10 made these a first-class component:
    # `constraint_power_balance_dc` now reads `var(pm, :pgdc)`, which only
    # exists once this is called. A case with no `gendc` entries — every NEM
    # case here — gets an empty variable container and an unchanged model, so
    # the call is a no-op except that it stops the DC balance constraint from
    # throwing `KeyError: :pgdc`.
    _PMACDC.variable_dcgenerator_power(pm, nw=n)
    
        _PM.constraint_model_voltage(pm, nw=n)
        _PMACDC.constraint_voltage_dc(pm, nw=n)
    
        for i in _PM.ids(pm, :ref_buses, nw=n)
            _PM.constraint_theta_ref(pm, i, nw=n)
        end

        for i in _PM.ids(pm, :gen, nw=n)
            constraint_generator_ramping(pm, i, n)
        end
    
        for i in _PM.ids(pm, :bus, nw=n)
            constraint_power_balance_ac(pm, i, nw=n)
        end
    
        for i in _PM.ids(pm, :branch, nw=n)
            _PM.constraint_ohms_yt_from(pm, i, nw=n)
            _PM.constraint_ohms_yt_to(pm, i, nw=n)
            _PM.constraint_voltage_angle_difference(pm, i, nw=n) 
            _PM.constraint_thermal_limit_from(pm, i, nw=n)
            _PM.constraint_thermal_limit_to(pm, i, nw=n)
        end

        for i in _PM.ids(pm, :busdc, nw=n)
            _PMACDC.constraint_power_balance_dc(pm, i, nw=n)
        end
        for i in _PM.ids(pm, :branchdc, nw=n)
            _PMACDC.constraint_ohms_dc_branch(pm, i, nw=n)
        end
        for i in _PM.ids(pm, :convdc, nw=n)
            _PMACDC.constraint_converter_losses(pm, i, nw=n)
            _PMACDC.constraint_converter_current(pm, i, nw=n)
            _PMACDC.constraint_conv_transformer(pm, i, nw=n)
            _PMACDC.constraint_conv_reactor(pm, i, nw=n)
            _PMACDC.constraint_conv_filter(pm, i, nw=n)
            if pm.ref[:it][:pm][:nw][n][:convdc][i]["islcc"] == 1
                _PMACDC.constraint_conv_firing_angle(pm, i, nw=n)
            end
        end
    
        for service in values(fcas_services)
            constraint_fcas_target(pm, service, n)
            constraint_fcas_max_available(pm, service, n)
            constraint_fcas_energy_regulating_capacity(pm, service, n)
            constraint_fcas_joint_capacity(pm, service, n)
        end
    end

    objective_min_cost(pm)

end