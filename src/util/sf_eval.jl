"""
Sorts the objective values in ascending order and returns.
"""

function select_argmin_solution(result)
    X = []
    Y = []
    for r in result
        push!(X, r["objective"])
        push!(Y, r)
    end
    X = sort(X)
    perm = sortperm(X)
    Y[perm]
    return Y[1]
end