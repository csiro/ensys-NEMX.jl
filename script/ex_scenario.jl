
using Revise
using PowerModels
using DataFrames
using DataFramesMeta
using NEMX



file = "./test/data/matpower/snem2000_acdc.m"
data = PowerModels.parse_file(file, validate=true, import_all=false)

gens = NEMX.get_df_from_dict(data["gen"], ["index", "gen_bus", "pmax", "startup", "shutdown", "ncost", "cost", "type"])

gens = NEMX.assign_participant(gens, "Generator", NEMX.gen_filter)
gens = NEMX.join_offers(gens, "s1")

gens_energy = NEMX.join_energy_prices(gens, "s1")
gens_energy = @orderby gens_energy :index
NEMX.gen_convert_to_pwl!(gens_energy)
NEMX.export_gen_cost(gens_energy, "s1")

gens_fcas = NEMX.join_fcas_prices(gens, "s1")
gens_fcas = @orderby gens_fcas :index
NEMX.gen_convert_to_pwl!(gens_fcas)

loads = NEMX.get_df_from_dict(data["load"], ["index", "pd"],  ["pd" => "pmax"])
loads = NEMX.assign_participant(loads, "Load", NEMX.load_filter)
loads = NEMX.join_offers(loads, "s1")

loads_energy = NEMX.join_energy_prices(loads, "s1")
loads_energy = @orderby loads_energy :index
NEMX.load_convert_to_pwl!(loads_energy)
NEMX.export_load_data(loads_energy, "s1")

load_fcas = NEMX.join_fcas_prices(loads, "s1")
load_fcas = @orderby load_fcas :index
NEMX.load_convert_to_pwl!(load_fcas)

NEMX.export_fcas_data("s1", gens_fcas, load_fcas)