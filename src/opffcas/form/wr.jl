function variable_branch_current(pm::_PM.AbstractWRModel; kwargs...)
    _PM.variable_buspair_current_magnitude_sqr(pm; kwargs...)
end
function variable_buspair_current_magnitude_sqr(pm::_PM.AbstractWRModel; nw::Int=_PM.nw_id_default, bounded::Bool=true, report::Bool=true)
    branch = _PM.ref(pm, nw, :branch)

    ccm = _PM.var(pm, nw)[:ccm] = JuMP.@variable(pm.model,
        [i in _PM.ids(pm, nw, :branch)], base_name="$(nw)_ccm",
        start = _PM.comp_start_value(branch[i], "ccm_start")
    )

    if bounded
        bus = _PM.ref(pm, nw, :bus)
        for (i, b) in branch
            rate_a = Inf
            if haskey(b, "rate_a")
                rate_a = b["rate_a"]
            end
            ub = ((rate_a*b["tap"])/(bus[b["f_bus"]]["vmin"]))^2

            JuMP.set_lower_bound(ccm[i], 0.0)
            if !isinf(ub)
                JuMP.set_upper_bound(ccm[i], ub)
            end
        end
    end

    report && _PM.sol_component_value(pm, nw, :branch, :ccm, _PM.ids(pm, nw, :branch), ccm)
end


function constraint_model_current_exact(pm::_PM.AbstractWRModel, n::Int)
    # _PM._check_missing_keys(_PM.var(pm, n), [:p,:q,:w,:ccm], typeof(pm))

    p  = _PM.var(pm, n, :p)
    q  = _PM.var(pm, n, :q)
    w  = _PM.var(pm, n, :w)
    ccm = _PM.var(pm, n, :ccm)

    for (i,branch) in _PM.ref(pm, n, :branch)
        f_bus = branch["f_bus"]
        t_bus = branch["t_bus"]
        f_idx = (i, f_bus, t_bus)
        tm = branch["tap"]

        JuMP.@constraint(pm.model, p[f_idx]^2 + q[f_idx]^2 == (w[f_bus]/tm^2)*ccm[i])
    end
end



function constraint_voltage_dc_exact(pm::_PM.AbstractWRModel; nw::Int = _PM.nw_id_default)
    wdc = _PM.var(pm, nw, :wdc)
    wdcr = _PM.var(pm, nw, :wdcr)

    for (i,j) in _PM.ids(pm, nw, :buspairsdc)
        JuMP.@constraint(pm.model, wdcr[(i,j)]^2 == wdc[i]*wdc[j])
        # JuMP.@constraint(pm.model, wdcr[(i,j)]^2 <= wdc[i]*wdc[j])
    end
end

function constraint_voltage_dc_exact(pm::_PM.AbstractWRConicModel; nw::Int = _PM.nw_id_default)
    wdc = _PM.var(pm, nw, :wdc)
    wdcr = _PM.var(pm, nw, :wdcr)

    for (i,j) in _PM.ids(pm, nw, :buspairsdc)
        JuMP.@constraint(pm.model, wdcr[(i,j)]^2 <= wdc[i]*wdc[j])
        # relaxation_complex_product_conic(pm.model, wdc[i], wdc[j], wdcr[(i,j)])
    end
end

function constraint_dc_branch_current_exact(pm::_PM.AbstractWRModel, n::Int, f_bus, f_idx, ccm_max, p)
    p_dc_fr = _PM.var(pm, n, :p_dcgrid, f_idx)
    wdc_fr = _PM.var(pm, n, :wdc, f_bus)

    JuMP.@constraint(pm.model, p_dc_fr == wdc_fr * ccm_max * p^2)
    # JuMP.@constraint(pm.model, p_dc_fr <= wdc_fr * ccm_max * p^2)
end

function constraint_model_voltage(pm::_PM.AbstractWRModel, n::Int)
    _PM._check_missing_keys(_PM.var(pm, n), [:w,:wr,:wi], typeof(pm))

    w  = _PM.var(pm, n,  :w)
    wr = _PM.var(pm, n, :wr)
    wi = _PM.var(pm, n, :wi)

    for (i,j) in _PM.ids(pm, n, :buspairs)
        JuMP.@constraint(pm.model, wr[(i,j)]^2 + wi[(i,j)]^2 == w[i] * w[j])
        # _IM.relaxation_complex_product(pm.model, w[i], w[j], wr[(i,j)], wi[(i,j)])
    end
end