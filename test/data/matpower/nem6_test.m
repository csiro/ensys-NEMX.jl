% nem6_test.m
%
% A six-bus, three-region synthetic NEM-shaped MATPOWER case, used by the NEMX
% test suite. It is NOT a model of anything real; it exists so that the network
% layer (case parsing, side-table extraction, area/region mapping, participant
% attachment and a DC power flow) can be exercised in under a second, without
% shipping the 1.4 MB 2000-bus case or downloading anything.
%
% Layout, chosen to give every mapping rule something to bite on:
%
%   area 1 = NSW1   buses 1 (ref, load) and 2 (generation)
%   area 2 = VIC1   buses 3 (load) and 4 (generation)
%   area 3 = QLD1   buses 5 (ref-eligible, load) and 6 (generation + storage)
%
%   AC branches   1-2, 3-4, 5-6 within areas; 2-3 ties NSW1 to VIC1
%   DC line       1-5, standing in for a controllable NSW1-QLD1 link
%
% `mpc.gen_data` and `mpc.storage_data` carry the `duid` column the NEM side
% tables use, so `load_network` has DUIDs to map participants onto.

function mpc = nem6_test
mpc.version = '2';
mpc.baseMVA = 100.0;

%% bus_i type Pd Qd Gs Bs area Vm Va baseKV zone Vmax Vmin
mpc.bus = [
	1	3	120.0	20.0	0.0	0.0	1	1.0	0.0	330.0	1	1.10	0.90;
	2	2	  0.0	 0.0	0.0	0.0	1	1.0	0.0	330.0	1	1.10	0.90;
	3	1	 90.0	15.0	0.0	0.0	2	1.0	0.0	330.0	1	1.10	0.90;
	4	2	  0.0	 0.0	0.0	0.0	2	1.0	0.0	330.0	1	1.10	0.90;
	5	1	 60.0	10.0	0.0	0.0	3	1.0	0.0	330.0	1	1.10	0.90;
	6	2	  0.0	 0.0	0.0	0.0	3	1.0	0.0	330.0	1	1.10	0.90;
];

%% bus Pg Qg Qmax Qmin Vg mBase status Pmax Pmin Pc1 Pc2 Qc1min Qc1max Qc2min Qc2max ramp_agc ramp_10 ramp_30 ramp_q apf
mpc.gen = [
	2	100.0	0.0	 60.0	-60.0	1.0	100.0	1	200.0	0.0	0	0	0	0	0	0	0	0	0	0	0;
	4	 80.0	0.0	 50.0	-50.0	1.0	100.0	1	150.0	0.0	0	0	0	0	0	0	0	0	0	0	0;
	6	 90.0	0.0	 50.0	-50.0	1.0	100.0	1	180.0	0.0	0	0	0	0	0	0	0	0	0	0	0;
];

%% model startup shutdown ncost c2 c1 c0
mpc.gencost = [
	2	0.0	0.0	3	0.0	40.0	0.0;
	2	0.0	0.0	3	0.0	55.0	0.0;
	2	0.0	0.0	3	0.0	70.0	0.0;
];

%% fbus tbus r x b rateA rateB rateC ratio angle status angmin angmax
mpc.branch = [
	1	2	0.002	0.020	0.03	250.0	250.0	250.0	0.0	0.0	1	-30.0	30.0;
	3	4	0.002	0.020	0.03	250.0	250.0	250.0	0.0	0.0	1	-30.0	30.0;
	5	6	0.002	0.020	0.03	250.0	250.0	250.0	0.0	0.0	1	-30.0	30.0;
	2	3	0.004	0.040	0.06	120.0	120.0	120.0	0.0	0.0	1	-30.0	30.0;
];

%% fbus tbus status Pf Pt Qf Qt Vf Vt Pmin Pmax QminF QmaxF QminT QmaxT loss0 loss1
mpc.dcline = [
	1	5	1	0.0	0.0	0.0	0.0	1.0	1.0	-80.0	80.0	-30.0	30.0	-30.0	30.0	0.0	0.02;
];

%% model startup shutdown ncost c1 c0
mpc.dclinecost = [
	2	0.0	0.0	2	0.0	0.0;
];

%% storage_bus ps qs energy energy_rating charge_rating discharge_rating charge_efficiency discharge_efficiency thermal_rating qmin qmax r x p_loss q_loss status
mpc.storage = [
	6	0.0	0.0	40.0	100.0	50.0	50.0	0.95	0.95	50.0	-25.0	25.0	0.0	0.0	0.0	0.0	1;
];

%column_names%	duid	fuel	name
mpc.gen_data = {
	'NSWGEN1'	'Coal'	'NSW Generator 1'
	'VICGEN1'	'Gas'	'VIC Generator 1'
	'QLDGEN1'	'Gas'	'QLD Generator 1'
};

%column_names%	duid	area	name
mpc.storage_data = {
	'QLDBESS1'	3	'QLD Battery 1'
};
