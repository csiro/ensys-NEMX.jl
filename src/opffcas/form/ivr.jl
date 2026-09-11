function constraint_current_balance_ac(pm::_PM.AbstractIVRModel, n::Int, i, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, bus_pd, bus_qd, bus_gs, bus_bs)
    vr = _PM.var(pm, n, :vr, i)
    vi = _PM.var(pm, n, :vi, i)

    cr =  _PM.var(pm, n, :cr)
    ci =  _PM.var(pm, n, :ci)
    cidc = _PM.var(pm, n, :cidc)

    iik_r = _PM.var(pm, n, :iik_r)
    iik_i = _PM.var(pm, n, :iik_i)

    crg = _PM.var(pm, n, :crg)
    cig = _PM.var(pm, n, :cig)

    pd_vars = _PM.var(pm, n, :pd)

    for l in keys(pd_vars)
        if l[1] in bus_loads
            bus_pd[l[1]] = pd_vars[l[1]]
        end
    end

    cstr_cr = JuMP.@constraint(pm.model, sum(cr[a] for a in bus_arcs) + sum(iik_r[c] for c in bus_convs_ac)
                                ==
                                sum(crg[g] for g in bus_gens)
                                - (sum(pd for pd in values(bus_pd))*vr + sum(qd for qd in values(bus_qd))*vi)/(vr^2 + vi^2)
                                - sum(gs for gs in values(bus_gs))*vr + sum(bs for bs in values(bus_bs))*vi 
                                )
    cstr_ci = JuMP.@constraint(pm.model, sum(ci[a] for a in bus_arcs) + sum(iik_i[c] for c in bus_convs_ac)
                                + sum(cidc[d] for d in bus_arcs_dc)
                                ==
                                sum(cig[g] for g in bus_gens)
                                - (sum(pd for pd in values(bus_pd))*vi - sum(qd for qd in values(bus_qd))*vr)/(vr^2 + vi^2)
                                - sum(gs for gs in values(bus_gs))*vi - sum(bs for bs in values(bus_bs))*vr 
                                )
    
    if _IM.report_duals(pm)
        _PM.sol(pm, n, :bus, i)[:lam_kcl_r] = cstr_cr
        _PM.sol(pm, n, :bus, i)[:lam_kcl_i] = cstr_ci
    end
end

function constraint_gen_power_real(pm::_PM.AbstractIVRModel, n::Int, i, g)
    vr  = _PM.var(pm, n, :vr, i)
    vi  = _PM.var(pm, n, :vi, i)
    
    crg = _PM.var(pm, n, :crg, g)
    cig = _PM.var(pm, n, :cig, g)

    pg  = _PM.var(pm, n, :pg, g)
    
    JuMP.@constraint(pm.model, pg == vr * crg + vi * cig)
end

function constraint_gen_power_imaginary(pm::_PM.AbstractIVRModel, n::Int, i, g)
    vr  = _PM.var(pm, n, :vr, i)
    vi  = _PM.var(pm, n, :vi, i)
    
    crg = _PM.var(pm, n, :crg, g)
    cig = _PM.var(pm, n, :cig, g)

    qg  = _PM.var(pm, n, :qg, g)
    
    JuMP.@constraint(pm.model, qg == vi * crg - vr * cig)
end