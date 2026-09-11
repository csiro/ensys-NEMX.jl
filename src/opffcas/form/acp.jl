function constraint_power_balance_ac(pm::_PM.AbstractACPModel, n::Int, i::Int, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
    vm = _PM.var(pm, n, :vm, i)
    p = _PM.var(pm, n, :p)
    q = _PM.var(pm, n, :q)
    pg = _PM.var(pm, n, :pg)
    qg = _PM.var(pm, n, :qg)
    pd_vars = _PM.var(pm, n, :pd)
    pconv_grid_ac = _PM.var(pm, n, :pconv_tf_fr)
    qconv_grid_ac = _PM.var(pm, n, :qconv_tf_fr)

    for l in keys(pd_vars)
        if l[1] in bus_loads
            pd[l[1]] = pd_vars[l[1]]
        end
    end

    cstr_p = JuMP.@constraint(pm.model, sum(p[a] for a in bus_arcs) + sum(pconv_grid_ac[c] for c in bus_convs_ac) == sum(pg[g] for g in bus_gens) - sum(pd[d] for d in bus_loads) - sum(gs[s] for s in bus_shunts) * vm^2)
    cstr_q = JuMP.@constraint(pm.model, sum(q[a] for a in bus_arcs) + sum(qconv_grid_ac[c] for c in bus_convs_ac) == sum(qg[g] for g in bus_gens) - sum(qd[d] for d in bus_loads) + sum(bs[s] for s in bus_shunts) * vm^2)

    if _IM.report_duals(pm)
        _PM.sol(pm, n, :bus, i)[:lam_kcl_r] = cstr_p
        _PM.sol(pm, n, :bus, i)[:lam_kcl_i] = cstr_q
    end
end


function constraint_power_balance_ac_soft(pm::_PM.AbstractACPModel, n::Int,  i::Int, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
    vm = _PM.var(pm, n,  :vm, i)
    p = _PM.var(pm, n,  :p)
    q = _PM.var(pm, n,  :q)
    pg = _PM.var(pm, n,  :pg)
    qg = _PM.var(pm, n,  :qg)
    pd_vars = _PM.var(pm, n, :pd)
    pconv_grid_ac = _PM.var(pm, n,  :pconv_tf_fr)
    qconv_grid_ac = _PM.var(pm, n,  :qconv_tf_fr)

    for l in keys(pd_vars)
        if l[1] in bus_loads
            pd[l[1]] = pd_vars[l[1]]
        end
    end

    pb_ac_pos_vio = _PM.var(pm, n, :pb_ac_pos_vio, i)
    qb_ac_pos_vio = _PM.var(pm, n, :qb_ac_pos_vio, i)
    pb_ac_neg_vio = _PM.var(pm, n, :pb_ac_neg_vio, i)
    qb_ac_neg_vio = _PM.var(pm, n, :qb_ac_neg_vio, i)

    cstr_p = JuMP.@constraint(pm.model, pb_ac_pos_vio - pb_ac_neg_vio + sum(p[a] for a in bus_arcs) + sum(pconv_grid_ac[c] for c in bus_convs_ac)  == sum(pg[g] for g in bus_gens)  - sum(pd[d] for d in bus_loads) - sum(gs[s] for s in bus_shunts)*vm^2)
    cstr_q = JuMP.@constraint(pm.model, qb_ac_pos_vio - qb_ac_neg_vio + sum(q[a] for a in bus_arcs) + sum(qconv_grid_ac[c] for c in bus_convs_ac)  == sum(qg[g] for g in bus_gens)  - sum(qd[d] for d in bus_loads) + sum(bs[s] for s in bus_shunts)*vm^2)

    if _IM.report_duals(pm)
        _PM.sol(pm, n, :bus, i)[:lam_kcl_r] = cstr_p
        _PM.sol(pm, n, :bus, i)[:lam_kcl_i] = cstr_q
    end
end