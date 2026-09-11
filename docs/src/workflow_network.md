# Network-resolved dispatch

Taking the same market inputs onto a physical network and re-solving them as an
optimal power flow.

## What changes, and what does not

The market data does not change. The offers, availabilities, ramp rates, FCAS
trapeziums, generic constraints and violation prices are the same objects the
zonal model used — `NEMX.NBenchmark` imports them from `NEMX.ZBenchmark` rather
than re-deriving them.

What changes is the balance constraint. One constraint per region becomes one per
bus, connected by a power-flow model. So each participant needs a bus, each NEM
interconnector needs a set of branches, and the price becomes locational.

## Solving

```julia
using NEMX, Dates
const NB = NEMX.NBenchmark

result = NB.solve_network_dispatch(DateTime(2025, 9, 2, 12, 5), "DCP";
                                   mfile    = "data/snem2000_fixed.m",
                                   data_dir = "data/nempy_2025_09")
```

## Formulations

| Name | Model | Solver | Cost per interval |
|:-----|:------|:-------|:------------------|
| `DCP` | `DCPPowerModel` | HiGHS | seconds |
| `DCP_MLF` | `DCPPowerModel` with MLF-scaled injections | HiGHS | seconds |
| `LPACC` | `LPACCPowerModel` | Ipopt | tens of seconds |
| `SOCWR` | `SOCWRPowerModel` | Ipopt | tens of seconds |
| `QCRM` | `QCRMPowerModel` | Ipopt | tens of seconds |
| `ACP` | `ACPPowerModel` | Ipopt | tens of seconds |

Each formulation carries its own solver in the registry, because an LP
formulation wants HiGHS and a non-linear one wants Ipopt and mixing them is never
what you want. Change a formulation's solver by editing the registry, not by
passing a flag.

Start with `DCP` to validate a window before widening the list. A 288-interval
sweep across all six is an overnight job.

## A full day

```bash
# DC only — the right first run
julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 DCP

# Everything
julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 \
      DCP,LPACC,SOCWR,QCRM,ACP

# With per-bus LMPs (~2000 rows per interval per formulation)
julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 DCP --with-lmp
```

Results are checkpointed, so an interrupted run leaves usable CSVs, and each
interval is isolated — one bad interval costs that interval, not the run.

The sweep also runs the MLF-scaled zonal reference for the same intervals, so the
nodal results have a like-for-like baseline rather than being compared against a
run with a different offer convention.

## Interpreting the output

**`network_day_prices_*.csv`** — regional reference price, losses, objective,
termination status and solve time per `(interval, formulation, region)`. Also
`first_status` and `attempts`: an interval recovered by the NLP retry is visible
as such rather than silently absorbed.

**`network_day_decomposition_*.csv`** — `lmp = energy + congestion + loss`.

**`network_day_binding_*.csv`** — every active constraint with its dual, its
family (interconnector, network security, FCAS reserve, unit capacity), and
whether it was binding on the primal.

Binding is decided on the **primal** — whether the constraint sits at its bound —
not on `|dual| > ε`. An interior-point solver returns small non-zero duals for
constraints that are merely close to active, so a dual-magnitude test admits a
near-active set that is not the active set.

## When an AC interval fails

The AC formulations on a 2000-bus network with violation-priced slacks are badly
scaled: the objective carries coefficients up to 2.6 × 10⁶. Three things in the
configuration exist to handle that, and are worth understanding before adjusting
them.

**The acceptable tolerances are tightened, not loosened.** Ipopt's defaults for
the `acceptable_*` family are `constr_viol = 1e-2` (a megawatt on a 100 MVA base)
and `dual_inf = 1e10` (no bound at all). Prices are read from the duals, so under
those defaults "solved to acceptable level" can certify numbers that look like
prices and are not. Tightening them turns some intervals from
`ALMOST_LOCALLY_SOLVED` into `NUMERICAL_ERROR` — which is the correct outcome,
because the old status was a false certificate.

**The retry changes the linear solver as well as the barrier strategy.** A retry
that changes only the strategy runs the same factorisation over the same KKT
matrix. See [Behavioural flags](@ref).

**`bound_relax_factor = 0.0` was tried and reverted.** Keeping bounds exact
sounds strictly better, but it removes the cushion Ipopt uses to step around a
bound, and cost more solves than it bought. The default relaxation is 1e-8 p.u.
— 1e-6 MW against offers quoted in whole megawatts.

If AC intervals fail on your machine and not elsewhere, the linear solver is the
first suspect. See the HSL section of [Installation](@ref).

## AC-feasibility recovery

A separate question: not "what does an AC dispatch cost?" but "what does it cost
to make *this* DC dispatch AC-feasible?"

```bash
julia --project=. scripts/nbenchmark/run_ac_recovery.jl 2025-09-02T04:05 288
```

This is a repair problem. Three quantities must be kept apart:

| | Meaning |
|:--|:--------|
| `C_DC` | the independently optimised DC dispatch cost |
| `C_AC` | the independently optimised AC dispatch cost — a **different** operating point |
| `C_AC|DC` | the cost of the dispatch obtained by **repairing** the DC solution |

The recovery cost is `ΔC_repair = C_AC|DC − C_DC`. The independent objective gap
`ΔC_opt = C_AC − C_DC` answers a different question, can be negative, and is not
a substitute for it. Neither formulation is modified: the analysis adds only
deviation variables and a repair objective, through `solve_network_dispatch`'s
`post_build` hook.

Feasibility of the repaired point is verified from the **primal constraint
residuals** — not from the termination status and not from dual magnitudes,
either of which can report success on an infeasible point.
