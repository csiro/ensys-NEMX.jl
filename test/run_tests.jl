using NEMX
using Test

using JuMP
using Ipopt
using Cbc
using Gurobi
using PowerModels
using PowerModelsACDC
using PowerModelsACDCsecurityconstrained


const _PM = PowerModels
const _PMACDC = PowerModelsACDC


nlp_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level"=>0) 
lp_solver = optimizer_with_attributes(Cbc.Optimizer, "logLevel"=>0)
gurobi_solver = optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => 0, "QCPDual" => 1)  # , "NonConvex" => 2, "presolve" => 0, "FeasibilityTol" => 1E-2,"OptimalityTol" => 1E-2, "MIPGap" => 0.001 "NumericFocus" => 3, , "IntFeasTol" => 1E-5, 

ENV["GUROBI_HOME"] = "/Library/gurobi952/macos_universal2"
ENV["GRB_LICENSE_FILE"] = "/Users/moh050/Library/CloudStorage/OneDrive-CSIRO/solvers/gurobi952lic/gurobi.lic"

@testset "NEMX" begin
    include("test_opfcas.jl") 
end 