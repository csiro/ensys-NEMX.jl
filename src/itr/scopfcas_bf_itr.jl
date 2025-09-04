
"""
Solves an AC-DC SCOPF problem based on nonconvex benders decomposition iteratively 
checking for violated contingencies and resolving until a fixed-point is reached 
allowing penalized violations in the nodal powre balance and branch thermal limit
constraints. 
"""

function run_scopfcas_bf_ncbenders_cuts(network::Dict{String,<:Any}, model_type::Type, optimizer_in, optimizer_out, setting; max_iter::Int=100, time_limit::Float64=Inf)
    results = Dict{String, Any}()
    time_start = time()

    network["fcuts"] = [];
    network["ocuts"] = [];
    ub = 0.0
    lb = 0.0
    # initiallize solve
    result = run_master_scopfcas_bf_soft(network, model_type, optimizer_in, setting=setting);
    if !(result["termination_status"] == _PM.OPTIMAL || result["termination_status"] == _PM.LOCALLY_SOLVED || result["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
        Memento.warn(_LOGGER, "initial master problem solve failed in run_scopf_acdc_benders_cuts with status $(result["termination_status"])")
    end
    Memento.info(_LOGGER, "initial master problem objective: $(result["objective"])")
    _PM.update_data!(network, result["solution"]);
    update_fcas!(network, result["solution"]);
    _PMACDCsc.update_data_converter_setpoints!(network, result["solution"]);
    ub = result["objective"]

    outer_iteration = 1
    inner_iteration = 1
    while outer_iteration > 0

        # inner iterations
        cuts_found = 1
        while cuts_found > 0  # && inner_iteration <= max_iter
            time_start_iteration = time()

            cuts = check_acdc_scopfcas_subproblems(network, model_type, optimizer_in, setting)

            # convergence check
            # if sum(cuts.sub_obj[val] for val in eachindex(cuts.sub_obj)) < 0.1
            #     Memento.info(_LOGGER, "bender's decoposition converged, fixed-point reached")
            #     lb = ub
            #     break
            # end
            if isempty(cuts.benders_fcuts) && sum( ((cut.obj - lb)/cut.obj) for cut in cuts.benders_ocuts) < 0.1
                Memento.info(_LOGGER, "bender's decoposition converged, fixed-point reached")
                lb = ub
                break
            end

            time_iteration = time() - time_start_iteration
            time_remaining = time_limit - (time() - time_start)
            if time_remaining < time_iteration
                Memento.warn(_LOGGER, "insufficent time for next iteration, time remaining $(time_remaining), estimated iteration time $(time_iteration)")
                break
            end
            if inner_iteration >= max_iter
                Memento.warn(_LOGGER, "maximum iterations reached $(max_iter), terminating fixed-point early")
                break
            end

            cuts_found = length(cuts.benders_fcuts) + length(cuts.benders_ocuts)
            if cuts_found <= 0
                Memento.info(_LOGGER, "no benders cuts found acdc scopf fixed-point reached")
                break
            else
                Memento.info(_LOGGER, "found $(cuts_found) benders cuts")
            end

            append!(network["fcuts"], cuts.benders_fcuts)
            append!(network["ocuts"], cuts.benders_ocuts)
            Memento.info(_LOGGER, "active benders ocuts: $(length(network["ocuts"]))")
            Memento.info(_LOGGER, "active benders fcuts: $(length(network["fcuts"]))")
            
            if !(isempty(network["fcuts"]))
                network["ocuts"] = []
            end     
                
            # master solve
            result = run_master_scopfcas_bf_soft(network, model_type, optimizer_in, setting=setting);
            if !(result["termination_status"] == _PM.OPTIMAL || result["termination_status"] == _PM.LOCALLY_SOLVED || result["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
                Memento.warn(_LOGGER, "master problem solve failed in run_scopf_acdc_benders_cuts with status $(result["termination_status"]), terminating fixed-point early")
                break
            end
            Memento.info(_LOGGER, "master problem objective: $(result["objective"])")
            if sum(bus["pb_ac_pos_vio"] + bus["pb_ac_neg_vio"] + bus["qb_ac_pos_vio"] + bus["qb_ac_neg_vio"] for (i, bus) in result["solution"]["bus"]) > 0.001
                cont_id = network["fcuts"][length(network["fcuts"])].cont_id
                cont_type = network["fcuts"][length(network["fcuts"])].cont_type
                for cont in network["gen_contingencies"] 
                    if cont.idx == cont_id && cont.type == cont_type
                        Memento.warn(_LOGGER, "generator contingency $(cont.idx):$(cont.label) is unsecure")
                        filter!(e -> e ≠ cont, network["gen_contingencies"])
                        deleteat!(network["fcuts"], length(network["fcuts"]))
                    end
                end
                for cont in network["branch_contingencies"] 
                    if cont.idx == cont_id && cont.type == cont_type
                        Memento.warn(_LOGGER, "branch contingency $(cont.idx):$(cont.label) is unsecure")
                        filter!(e -> e ≠ cont, network["branch_contingencies"])
                        deleteat!(network["fcuts"], length(network["fcuts"]))
                    end
                end
            else
                _PM.update_data!(network, result["solution"]);
                update_fcas!(network, result["solution"]);
                _PMACDCsc.update_data_converter_setpoints!(network, result["solution"]);
                lb = result["objective"]
            end


            inner_iteration += 1
        end
        results["inner_iterations"] = inner_iteration
        results["final"] = result 

        # check nonlinear subproblems
        _PM.update_data!(network, results["final"]["solution"]);
        _PMACDCsc.update_data_converter_setpoints!(network, results["final"]["solution"]);
        network["soc_master_obj"] = results["final"]["objective"]

        result_nc_sub = check_nc_acdc_subproblems_soft(network, _PM.ACPPowerModel, optimizer_out, setting)
        argmin_result = select_argmin_solution(result_nc_sub);
        _PM.update_data!(network, argmin_result["solution"]);
        _PMACDCsc.update_data_converter_setpoints!(network, argmin_result["solution"]);

        # convergence check
        if sum( ((r["objective"] - lb)/r["objective"]) for r in result_nc_sub) < 0.1
            Memento.info(_LOGGER, "nonconvex benders decoposition converged, fixed-point reached")
            break
        end
        ub = argmin_result["objective"]
        outer_iteration += 1

    end
    results["outer_iterations"] = outer_iteration
    return results
end