"""
Solves AC-DC SCOPF subproblems (each with a contingency) at a given operating point and 
checks for feasibility and generates beneder's feasibility or optimality cuts accordingly.
"""
function check_acdc_scopfcas_subproblems(network, model_type, optimizer, setting; cuts_limit=typemax(Int64), gen_eval_limit=typemax(Int64),
    branch_eval_limit=typemax(Int64), branchdc_eval_limit=typemax(Int64), convdc_eval_limit=typemax(Int64))    

    time_start_subproblems = time()
        
    gen_contingencies = _PMSC.calc_c1_gen_contingency_subset(network, gen_eval_limit=gen_eval_limit)
    branch_contingencies = _PMSC.calc_c1_branch_contingency_subset(network, branch_eval_limit=branch_eval_limit)
    branchdc_contingencies = _PMACDCsc.calc_branchdc_contingency_subset(network, branchdc_eval_limit=branchdc_eval_limit)   
    convdc_contingencies = _PMACDCsc.calc_convdc_contingency_subset(network, convdc_eval_limit=convdc_eval_limit)

    benders_ocuts = [];
    benders_fcuts = [];
    sub_obj = [];
    result_sub = Dict{String, Any}()
    for (i,cont) in enumerate(gen_contingencies)
     
        cont_gen = network["gen"]["$(cont.idx)"]
        pg_lost = cont_gen["pg"]
        cont_gen["gen_status"] = 0
        cont_gen["pg"] = 0.0

        try
            result_sub = run_pb_sub_scopfcas_bf(network, model_type, optimizer, setting=setting)
        catch exception
            # Memento.info(_LOGGER, "$exception")
            continue
        end
        if !(result_sub["termination_status"] == _PM.OPTIMAL || result_sub["termination_status"] == _PM.LOCALLY_SOLVED || result_sub["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
            Memento.info(_LOGGER, "primal bounding subproblem solve is infeasible in check_acdc_subproblems, status $(result_sub["termination_status"])")
            
            result_sub = run_f_sub_scopfcas_bf_soft(network, model_type, optimizer, setting=setting);
            if !(result_sub["termination_status"] == _PM.OPTIMAL || result_sub["termination_status"] == _PM.LOCALLY_SOLVED || result_sub["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
                Memento.warn(_LOGGER, "feasibility subproblem solve is infeasible in check_acdc_subproblems, status $(result_sub["termination_status"])")
                break
            else
                Memento.info(_LOGGER, "feasibility subproblem objective: $(result_sub["objective"])")
                push!(sub_obj, result_sub["objective"])
            
                if result_sub["objective"] > 0
                    # feasibility cuts
                    lm_p = Dict(parse(Int, i) => gen["lm_p"] for (i, gen) in result_sub["solution"]["gen"]);
                    lm_q = Dict(parse(Int, i) => gen["lm_q"] for (i, gen) in result_sub["solution"]["gen"]);
                    pg_sub = Dict(parse(Int, i) => gen["pg"] for (i, gen) in result_sub["solution"]["gen"]);
                    qg_sub = Dict(parse(Int, i) => gen["qg"] for (i, gen) in result_sub["solution"]["gen"]);
                    lm_ac_p = Dict(parse(Int, i) => conv["lm_ac_p"] for (i, conv) in result_sub["solution"]["convdc"]);
                    lm_ac_q = Dict(parse(Int, i) => conv["lm_ac_q"] for (i, conv) in result_sub["solution"]["convdc"]);
                    obj = result_sub["objective"];
                        
                    cut = (cont_id = cont.idx, cont_type = cont.type, obj=obj, lm_p=lm_p, lm_q=lm_q, lm_ac_p=lm_ac_p, lm_ac_q=lm_ac_q, pg_sub=pg_sub, qg_sub=qg_sub);
                    # @show cut        
                    push!(benders_fcuts, cut);
                    # feasibility cut found break
                    Memento.info(_LOGGER, "feasibility cut found for contingency $(cont.idx): $(cont.label)")
                    cont_gen["gen_status"] = 1
                    cont_gen["pg"] = pg_lost
                    break
                end
            end
        else
            Memento.info(_LOGGER, "primal bounding subproblem objective: $(result_sub["objective"])")
            push!(sub_obj, result_sub["objective"])

            # optimality cuts
            lm_p = Dict(parse(Int, i) => gen["lm_p"] for (i, gen) in result_sub["solution"]["gen"]);
            lm_q = Dict(parse(Int, i) => gen["lm_q"] for (i, gen) in result_sub["solution"]["gen"]);
            pg_sub = Dict(parse(Int, i) => gen["pg"] for (i, gen) in result_sub["solution"]["gen"]);
            qg_sub = Dict(parse(Int, i) => gen["qg"] for (i, gen) in result_sub["solution"]["gen"]);
            lm_ac_p = Dict(parse(Int, i) => conv["lm_ac_p"] for (i, conv) in result_sub["solution"]["convdc"]);
            lm_ac_q = Dict(parse(Int, i) => conv["lm_ac_q"] for (i, conv) in result_sub["solution"]["convdc"]);
            obj = result_sub["objective"];
                    
            cut = (cont_id = cont.idx, cont_type = cont.type, obj=obj, lm_p=lm_p, lm_q=lm_q, lm_ac_p=lm_ac_p, lm_ac_q=lm_ac_q, pg_sub=pg_sub, qg_sub=qg_sub);
            # @show cut        
            push!(benders_ocuts, cut);
            Memento.info(_LOGGER, "optimality cut found for contingency $(cont.idx): $(cont.label)")
        end

        cont_gen["gen_status"] = 1
        cont_gen["pg"] = pg_lost
    end
    if isempty(benders_fcuts)
        for (i,cont) in enumerate(branch_contingencies)
            cont_branch = network["branch"]["$(cont.idx)"]
            cont_branch["br_status"] = 0
            _PMACDC.fix_data!(network)
            println("contingency ... $i ... $cont")

            try
                result_sub = run_pb_sub_scopfcas_bf(network, model_type, optimizer, setting=setting)
            catch exception
                # Memento.info(_LOGGER, "$exception")
                result_sub["termination_status"] = []
                result_sub["termination_status"] = _PM.INFEASIBLE_OR_UNBOUNDED
                # continue
            end
            if !( result_sub["termination_status"] == _PM.OPTIMAL || result_sub["termination_status"] == _PM.LOCALLY_SOLVED || result_sub["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
                Memento.info(_LOGGER, "primal bounding subproblem solve is infeasible in check_acdc_subproblems, status $(result_sub["termination_status"])")

                result_sub = run_f_sub_scopfcas_bf_soft(network, model_type, optimizer, setting=setting);
                if !(result_sub["termination_status"] == _PM.OPTIMAL || result_sub["termination_status"] == _PM.LOCALLY_SOLVED || result_sub["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
                    Memento.warn(_LOGGER, "feasibility subproblem solve is infeasible in check_acdc_subproblems, status $(result_sub["termination_status"])")
                    break
                else
                    Memento.info(_LOGGER, "feasibility subproblem objective: $(result_sub["objective"])")
                    push!(sub_obj, result_sub["objective"])

                    if result_sub["objective"] > 0
                        # feasibility cuts
                        lm_p = Dict(parse(Int, i) => gen["lm_p"] for (i, gen) in result_sub["solution"]["gen"]);
                        lm_q = Dict(parse(Int, i) => gen["lm_q"] for (i, gen) in result_sub["solution"]["gen"]);
                        pg_sub = Dict(parse(Int, i) => gen["pg"] for (i, gen) in result_sub["solution"]["gen"]);
                        qg_sub = Dict(parse(Int, i) => gen["qg"] for (i, gen) in result_sub["solution"]["gen"]);
                        delta_p = Dict(parse(Int, i) => gen["delta_p_p"] - gen["delta_p_n"] for (i, gen) in result_sub["solution"]["gen"]);
                        delta_q = Dict(parse(Int, i) => gen["delta_q"] for (i, gen) in result_sub["solution"]["gen"]);
                        lm_ac_p = Dict(parse(Int, i) => conv["lm_ac_p"] for (i, conv) in result_sub["solution"]["convdc"]);
                        lm_ac_q = Dict(parse(Int, i) => conv["lm_ac_q"] for (i, conv) in result_sub["solution"]["convdc"]);
                        obj = result_sub["objective"];

                        cut = (cont_id = cont.idx, cont_type = cont.type, obj=obj, lm_p=lm_p, lm_q=lm_q, lm_ac_p=lm_ac_p, lm_ac_q=lm_ac_q, pg_sub=pg_sub, qg_sub=qg_sub, delta_p=delta_p, delta_q=delta_q);
                        # @show cut
                        push!(benders_fcuts, cut);
                        # feasibility cut found break
                        Memento.info(_LOGGER, "feasibility cut found for contingency $(cont.idx): $(cont.label)")
                        break
                    end
                end
            else
                Memento.info(_LOGGER, "primal bounding subproblem objective: $(result_sub["objective"])")
                push!(sub_obj, result_sub["objective"])

                # optimality cuts
                lm_p = Dict(parse(Int, i) => gen["lm_p"] for (i, gen) in result_sub["solution"]["gen"]);
                lm_q = Dict(parse(Int, i) => gen["lm_q"] for (i, gen) in result_sub["solution"]["gen"]);
                pg_sub = Dict(parse(Int, i) => gen["pg"] for (i, gen) in result_sub["solution"]["gen"]);
                qg_sub = Dict(parse(Int, i) => gen["qg"] for (i, gen) in result_sub["solution"]["gen"]);
                delta_p = Dict(parse(Int, i) => gen["delta_p_p"] - gen["delta_p_n"] for (i, gen) in result_sub["solution"]["gen"]);
                delta_q = Dict(parse(Int, i) => gen["delta_q"] for (i, gen) in result_sub["solution"]["gen"]);
                lm_ac_p = Dict(parse(Int, i) => conv["lm_ac_p"] for (i, conv) in result_sub["solution"]["convdc"]);
                lm_ac_q = Dict(parse(Int, i) => conv["lm_ac_q"] for (i, conv) in result_sub["solution"]["convdc"]);
                obj = result_sub["objective"];
                        
                cut = (cont_id = cont.idx, cont_type = cont.type, obj=obj, lm_p=lm_p, lm_q=lm_q, lm_ac_p=lm_ac_p, lm_ac_q=lm_ac_q, pg_sub=pg_sub, qg_sub=qg_sub, delta_p=delta_p, delta_q=delta_q);
                # @show cut        
                push!(benders_ocuts, cut);
                Memento.info(_LOGGER, "optimality cut found for contingency $(cont.idx): $(cont.label)")
            end
            
            cont_branch["br_status"] = 1
        end
    end

    time_contingencies = time() - time_start_subproblems
    Memento.info(_LOGGER, "subproblems eval time: $(time_contingencies)")            

    return (benders_fcuts=benders_fcuts, benders_ocuts=benders_ocuts, sub_obj=sub_obj)  # TODO sub_obj needed?
end

                # # check feasibility
                # pgmax = [gen["pmax"] for (g, gen) in network["gen"]]
                # pgmin = [gen["pmin"] for (g, gen) in network["gen"]]
                # qgmax = [gen["qmax"] for (g, gen) in network["gen"]]
                # qgmin = [gen["qmin"] for (g, gen) in network["gen"]]
                # pg = [gen["pg"] for (g, gen) in network["gen"]]
                # qg = [gen["qg"] for (g, gen) in network["gen"]]
                # if !(objo + sum(val * (pgmax[i] - pg[i]) for (i,val) in lmo_p) + sum(val * (qgmax[i] - qg[i]) for (i,val) in lmo_q) <=0 ||
                #      objo + sum(val * (pgmax[i] - pg[i]) for (i,val) in lmo_p) + sum(val * (qgmin[i] - qg[i]) for (i,val) in lmo_q) <=0 ||
                #      objo + sum(val * (pgmin[i] - pg[i]) for (i,val) in lmo_p) + sum(val * (qgmax[i] - qg[i]) for (i,val) in lmo_q) <=0 ||
                #      objo + sum(val * (pgmin[i] - pg[i]) for (i,val) in lmo_p) + sum(val * (qgmin[i] - qg[i]) for (i,val) in lmo_q) <=0)
                #    println("contingency $(cont.idx) is infeasible")
                # end


"""
Solves the nonconvex soft AC-DC SCOPF subproblems by including the given objective lower bound 
from the inner loop of the nonconvex benders decomposition to provide an objective upper bound 
in the outer loop.
"""


function check_nc_acdc_subproblems_soft(network, model_type, optimizer, setting; cuts_limit=typemax(Int64), gen_eval_limit=typemax(Int64),
    branch_eval_limit=typemax(Int64), branchdc_eval_limit=typemax(Int64), convdc_eval_limit=typemax(Int64))    

    time_start_subproblems = time()
        
    gen_contingencies = _PMSC.calc_c1_gen_contingency_subset(network, gen_eval_limit=gen_eval_limit)
    branch_contingencies = _PMSC.calc_c1_branch_contingency_subset(network, branch_eval_limit=branch_eval_limit)
    branchdc_contingencies = _PMACDCsc.calc_branchdc_contingency_subset(network, branchdc_eval_limit=branchdc_eval_limit)   
    convdc_contingencies = _PMACDCsc.calc_convdc_contingency_subset(network, convdc_eval_limit=convdc_eval_limit)

    
    result = [];
    for (i,cont) in enumerate(gen_contingencies)
     
        cont_gen = network["gen"]["$(cont.idx)"]
        pg_lost = cont_gen["pg"]
        cont_gen["gen_status"] = 0
        cont_gen["pg"] = 0.0

        result_sub = run_nc_sub_scopf_soft(network, model_type, optimizer, setting=setting);
        if !(result_sub["termination_status"] == _PM.OPTIMAL || result_sub["termination_status"] == _PM.LOCALLY_SOLVED || result_sub["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
            Memento.info(_LOGGER, "subproblem solve is infeasible in check_acdc_subproblems, status $(result_sub["termination_status"])")
        end
        Memento.info(_LOGGER, "nonconvex subproblem objective: $(result_sub["objective"])")
        push!(result, result_sub)


        cont_gen["gen_status"] = 1
        cont_gen["pg"] = pg_lost
    end

    for (i,cont) in enumerate(branch_contingencies)
        
            cont_branch = network["branch"]["$(cont.idx)"]
            cont_branch["br_status"] = 0
            _PMACDC.fix_data!(network)

            result_sub = run_nc_sub_scopf_soft(network, model_type, optimizer, setting=setting);
            if !(result_sub["termination_status"] == _PM.OPTIMAL || result_sub["termination_status"] == _PM.LOCALLY_SOLVED || result_sub["termination_status"] == _PM.ALMOST_LOCALLY_SOLVED)
                Memento.info(_LOGGER, "subproblem solve is infeasible in check_acdc_subproblems, status $(result_sub["termination_status"])")
            end
            Memento.info(_LOGGER, "nonconvex subproblem objective: $(result_sub["objective"])")
            push!(result, result_sub)

            
            cont_branch["br_status"] = 1
    end

    time_contingencies = time() - time_start_subproblems
    Memento.info(_LOGGER, "subproblems eval time: $(time_contingencies)")            

    return (result=result)  
end