function constraint_power_balance_ac(pm::_PM.AbstractDCPModel, n::Int,  i::Int, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
    p = _PM.var(pm, n, :p)
    pg = _PM.var(pm, n, :pg)
    pd_vars = _PM.var(pm, n, :pd)
    pconv_ac = _PM.var(pm, n, :pconv_ac)
    pconv_grid_ac = _PM.var(pm, n, :pconv_tf_fr)
    v = 1

    for l in keys(pd_vars)
        if l[1] in bus_loads
            pd[l[1]] = pd_vars[l[1]]
        end
    end

    cstr_p = JuMP.@constraint(pm.model, sum(p[a] for a in bus_arcs) + sum(pconv_grid_ac[c] for c in bus_convs_ac)  == sum(pg[g] for g in bus_gens) - sum(pd[d] for d in bus_loads) - sum(gs[s] for s in bus_shunts)*v^2)

    if _IM.report_duals(pm)
        _PM.sol(pm, n, :bus, i)[:lam_kcl_r] = cstr_p
    end
end

# function constraint_power_balance_ac_mlf(pm::_PM.AbstractDCPModel, n::Int,  i::Int, bus_arcs, bus_arcs_dc, bus_gens, bus_convs_ac, bus_loads, bus_shunts, pd, qd, gs, bs)
#     p = _PM.var(pm, n, :p)
#     pg = _PM.var(pm, n, :pg)
#     pd_vars = _PM.var(pm, n, :pd)
#     pconv_ac = _PM.var(pm, n, :pconv_ac)
#     pconv_grid_ac = _PM.var(pm, n, :pconv_tf_fr)
#     v = 1

#     for l in keys(pd_vars)
#         if l[1] in bus_loads
#             pd[l[1]] = pd_vars[l[1]]
#         end
#     end
#     # *_PM.ref(pm, n, :mlf, _PM.ref(pm, n, :gen, g, "gen_bus"), "mlf")

#     cstr_p = JuMP.@constraint(pm.model, sum(p[a] for a in bus_arcs) + sum(pconv_grid_ac[c] for c in bus_convs_ac) 
#      == sum(pg[g] for g in bus_gens) 
#       - sum(pd[d]/_PM.ref(pm, n, :mlf, _PM.ref(pm, n, :load, d, "load_bus"), "mlf") for d in bus_loads) - sum(gs[s] for s in bus_shunts)*v^2)

#     if _IM.report_duals(pm)
#         _PM.sol(pm, n, :bus, i)[:lam_kcl_r] = cstr_p
#     end
# end