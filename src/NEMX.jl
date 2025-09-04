module NEMX

import JuMP
import PowerModels
import PowerModelsACDC
import InfrastructureModels
import PowerModelsSecurityConstrained
import PowerModelsACDCsecurityconstrained
import Memento

const _IM = InfrastructureModels
const _PM = PowerModels
const _PMACDC = PowerModelsACDC
const _PMSC = PowerModelsSecurityConstrained
const _PMACDCsc = PowerModelsACDCsecurityconstrained

using Revise
using Statistics
using DataFrames
using DataFramesMeta
using PlotlyJS


function __init__()
    global _LOGGER = Memento.getlogger(@__MODULE__)
end

const BASE_DIR = dirname(@__DIR__)


include("core/types.jl")
include("core/variable.jl")
include("core/constraint_template.jl")
include("core/constraint.jl")
include("core/objective.jl")
include("core/data.jl")

include("form/acp.jl")
include("form/dcp.jl")
include("form/lpac.jl")
include("form/shared.jl")
include("form/ivr.jl")
include("form/bf.jl")
include("form/wr.jl")

include("prob/opfcas.jl")
include("prob/opfcas_bf.jl")
include("prob/opfcas_ivr.jl")
include("prob/mn_opfcas.jl")
include("prob/scopfcas_bf.jl")

include("itr/scopfcas_bf_itr.jl")

include("eval/scopf_cont_check.jl")

include("util/sf_eval.jl")

include("vis/opfcas.jl")

include("vis/results.jl") 


end 
