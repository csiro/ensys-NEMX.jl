export run_acdcopfcas_bf


""
function run_acdcopfcas_bf(data::Dict{String,Any}, model_type::Type{T}, solver; kwargs...) where T <: _PM.AbstractBFModel
    solution_processors = []#[solution_processor]
# `ref_add_gendc!` builds `ref(pm, :bus_gens_dc)`, which the DC power-balance
# constraints below read. PowerModelsACDC folded that into `add_ref_dcgrid!` up
# to 0.8 and split it into its own extension afterwards, so listing both keeps
# the builder working across the split rather than throwing
# `KeyError: :bus_gens_dc` at build time.
    return _PM.solve_model(data, model_type, solver, build_acdcopfcas_bf; ref_extensions=[_PMACDC.add_ref_dcgrid!, _PMACDC.ref_add_gendc!], solution_processors, kwargs...)
end

""
function build_acdcopfcas_bf(pm::_PM.AbstractPowerModel)

    _PM.variable_bus_voltage(pm)
    _PM.variable_gen_power(pm)
    _PM.variable_branch_power(pm)
    _PM.variable_branch_current(pm)

    variable_load_power(pm)
    variable_fcas(pm)

    objective_min_cost(pm)

    _PMACDC.variable_active_dcbranch_flow(pm)
    _PMACDC.variable_dcbranch_current(pm)
    _PMACDC.variable_dc_converter(pm)
    _PMACDC.variable_dcgrid_voltage_magnitude(pm)
    # DC generators. PowerModelsACDC 0.10 made these a first-class component:
    # `constraint_power_balance_dc` now reads `var(pm, :pgdc)`, which only
    # exists once this is called. A case with no `gendc` entries — every NEM
    # case here — gets an empty variable container and an unchanged model, so
    # the call is a no-op except that it stops the DC balance constraint from
    # throwing `KeyError: :pgdc`.
    _PMACDC.variable_dcgenerator_power(pm)

    constraint_model_current_exact(pm)
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
        # constraint_dc_branch_current_exact(pm, i)
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

end