for (i, load) in data["load"]
    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_L5M")
            load["load_L5M"] = solution["load"][i]["load_L5M"]
            load["load_L5M_cost"] = solution["load"][i]["load_L5M_cost"]
        end
    else
        load["load_L5M"] = 0.0
        load["load_L5M_cost"] = 0.0
    end

    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_R5M")
            load["load_R5M"] = solution["load"][i]["gen_R5M"]
            load["load_R5M_cost"] = solution["load"][i]["load_R5M_cost"]
        end
    else
        load["load_R5M"] = 0.0
        load["load_R5M_cost"] = 0.0
    end

    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_L6S")
            load["load_L6S"] = solution["load"][i]["load_L6S"]
            load["load_L6S_cost"] = solution["load"][i]["load_L6S_cost"]
        end
    else
        load["load_L6S"] = 0.0
        load["load_L6S_cost"] = 0.0
    end
    
    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_R6S")
            load["load_R6S"] = solution["load"][i]["load_R6S"]
            load["load_R6S_cost"] = solution["load"][i]["load_R6S_cost"]
        end
    else
        load["load_R6S"] = 0.0
        load["load_R6S_cost"] = 0.0
    end

    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_L60S")
            load["load_L60S"] = solution["load"][i]["load_L60S"]
            load["load_L60S_cost"] = solution["load"][i]["load_L60S_cost"]
        end
    else
        load["load_L60S"] = 0.0
        load["load_L60S_cost"] = 0.0 
    end

    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_R60S")
            load["load_R60S"] = solution["load"][i]["load_R60S"]
            load["load_R60S_cost"] = solution["load"][i]["load_R60S_cost"]
        end
    else
        load["load_R60S"] = 0.0
        load["load_R60S_cost"] = 0.0
    end

    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_LReg")
            load["load_LReg"] = solution["load"][i]["load_LReg"]
            load["load_LReg_cost"] = solution["load"][i]["load_LReg_cost"]
        end
    else
        load["load_LReg"] = 0.0
        load["load_LReg_cost"] = 0.0
    end

    if haskey(solution["load"], i)
        if haskey(solution["load"][i], "load_RReg")
            load["load_RReg"] = solution["load"][i]["load_RReg"]
            load["load_RReg_cost"] = solution["load"][i]["load_RReg_cost"]
        end
    else
        load["load_RReg"] = 0.0
        load["load_RReg_cost"] = 0.0
    end

    if haskey(solution["load"][i], "load_L1S")
        data["load"][i]["load_L1S"] = solution["load"][i]["load_L1S"]
        data["load"][i]["load_L1S_cost"] = solution["load"][i]["load_L1S_cost"]
    else
        data["load"][i]["load_L1S"] = 0.0
        data["load"][i]["load_L1S_cost"] = 0.0
    end
    
    if haskey(solution["load"][i], "load_R1S")
        data["load"][i]["load_R1S"] = solution["load"][i]["load_R1S"]
        data["load"][i]["load_R1S_cost"] = solution["load"][i]["load_R1S_cost"]
    else
        data["load"][i]["load_R1S"] = 0.0
        data["load"][i]["load_R1S_cost"] = 0.0
    end
end