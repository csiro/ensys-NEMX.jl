

function constraint_model_current_exact(pm::_PM.AbstractBFQPModel, n::Int)
    _PM._check_missing_keys(_PM.var(pm, n), [:p,:q,:w,:ccm], typeof(pm))

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
        # JuMP.@constraint(pm.model, p[f_idx]^2 + q[f_idx]^2 <= (w[f_bus]/tm^2)*ccm[i])
    end
end



function constraint_model_current_exact(pm::_PM.AbstractBFConicModel, n::Int)
    _PM._check_missing_keys(_PM.var(pm, n), [:p,:q,:w,:ccm], typeof(pm))

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
        # JuMP.@constraint(pm.model, [w[f_bus]/tm^2, ccm[i]/2, p[f_idx], q[f_idx]] in JuMP.RotatedSecondOrderCone())
    end
end



function constraint_model_current_exact(pm::_PM.AbstractBFModel, n::Int)
    _PM._check_missing_keys(_PM.var(pm, n), [:p,:q,:w,:ccm], typeof(pm))
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

function constraint_voltage_dc_exact(pm::_PM.AbstractBFModel, n::Int = _PM.nw_id_default)
    # do nothing
end

function constraint_dc_branch_current_exact(pm::_PM.AbstractBFModel, n::Int, i::Int, f_bus, f_idx, ccm_max, p)
    p_dc_fr = _PM.var(pm, n, :p_dcgrid, f_idx)
    wdc_fr = _PM.var(pm, n, :wdc, f_bus)
    ccm = _PM.var(pm, n, :ccm, i)
    
    JuMP.@constraint(pm.model, p_dc_fr == wdc_fr * ccm * p^2)
    # JuMP.@constraint(pm.model, p_dc_fr <= wdc_fr * ccm_max * p^2)
end

function constraint_converter_current(pm::_PM.AbstractBFQPModel, n::Int,  i::Int, Umax, Imax)
    wc = _PM.var(pm, n,  :wc_ac, i)
    pconv_ac = _PM.var(pm, n,  :pconv_ac, i)
    qconv_ac = _PM.var(pm, n,  :qconv_ac, i)
    iconv = _PM.var(pm, n,  :iconv_ac, i)
    iconv_sq = _PM.var(pm, n,  :iconv_ac_sq, i)

    JuMP.@constraint(pm.model, pconv_ac^2 + qconv_ac^2 ==  wc * iconv_sq)
    # JuMP.@constraint(pm.model, pconv_ac^2 + qconv_ac^2 == (Umax)^2 * iconv^2)
    JuMP.@constraint(pm.model, iconv^2 == iconv_sq)
    # JuMP.@constraint(pm.model, iconv_sq <= iconv*Imax)
end


function constraint_conv_transformer(pm::_PM.AbstractBFQPModel, n::Int,  i::Int, rtf, xtf, acbus, tm, transformer)
    w = _PM.var(pm, n,  :w, acbus)
    itf = _PM.var(pm, n,  :itf_sq, i)
    wf = _PM.var(pm, n,  :wf_ac, i)


    ptf_fr = _PM.var(pm, n,  :pconv_tf_fr, i)
    qtf_fr = _PM.var(pm, n,  :qconv_tf_fr, i)
    ptf_to = _PM.var(pm, n,  :pconv_tf_to, i)
    qtf_to = _PM.var(pm, n,  :qconv_tf_to, i)


    if transformer
        JuMP.@constraint(pm.model,   ptf_fr + ptf_to ==  rtf*itf)
        JuMP.@constraint(pm.model,   qtf_fr + qtf_to ==  xtf*itf)
        JuMP.@constraint(pm.model,   ptf_fr^2 + qtf_fr^2 == w/tm^2 * itf)
        JuMP.@constraint(pm.model,   wf == w/tm^2 -2*(rtf*ptf_fr + xtf*qtf_fr) + (rtf^2 + xtf^2)*itf)
    else
        JuMP.@constraint(pm.model, ptf_fr + ptf_to == 0)
        JuMP.@constraint(pm.model, qtf_fr + qtf_to == 0)
        JuMP.@constraint(pm.model, wf == w )
    end
end

function constraint_conv_reactor(pm::_PM.AbstractBFQPModel, n::Int,  i::Int, rc, xc, reactor)
    pconv_ac = _PM.var(pm, n,  :pconv_ac, i)
    qconv_ac = _PM.var(pm, n,  :qconv_ac, i)
    ppr_to = - pconv_ac
    qpr_to = - qconv_ac
    ppr_fr = _PM.var(pm, n,  :pconv_pr_fr, i)
    qpr_fr = _PM.var(pm, n,  :qconv_pr_fr, i)

    wf = _PM.var(pm, n,  :wf_ac, i)
    ipr = _PM.var(pm, n,  :irc_sq, i)
    wc = _PM.var(pm, n,  :wc_ac, i)

    if reactor
        JuMP.@constraint(pm.model, ppr_fr + ppr_to == rc*ipr)
        JuMP.@constraint(pm.model, qpr_fr + qpr_to == xc*ipr)
        JuMP.@constraint(pm.model, ppr_fr^2 + qpr_fr^2 == wf * ipr)
        JuMP.@constraint(pm.model, wc == wf -2*(rc*ppr_fr + xc*qpr_fr) + (rc^2 + xc^2)*ipr)

    else
        JuMP.@constraint(pm.model, ppr_fr + ppr_to == 0)
        JuMP.@constraint(pm.model, qpr_fr + qpr_to == 0)
        JuMP.@constraint(pm.model, wc == wf)
    end
end