# =============================================================================
# mms_db.jl
#
# Julia port of `nempy.historical_inputs.mms_db`.
#
# AEMO publishes the "MMS Data Model" (Market Management System) as monthly
# archives of CSV files on the nemweb portal. Each archive is a zip that, when
# unzipped, contains a single CSV in AEMO's standard "C/I/D/C" report layout:
#
#     C, ...                      <- file header row
#     I, <TABLE>, <SUBTABLE>, ... <- column-name (information) row
#     D, <TABLE>, <SUBTABLE>, ... <- one or more data rows
#     ...
#     C, ...                      <- file footer row
#
# This module downloads those monthly archives, extracts the requested table,
# and loads it into a local SQLite database — exactly the role of nempy's
# `DBManager`. Data can then be queried per 5-minute dispatch interval.
#
# nemweb URL templates (verbatim from nempy):
#   PUBLIC_DVD (most tables):
#     http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/
#       MMSDM_{year}_{month_folder}/MMSDM_Historical_Data_SQLLoader/DATA/
#       PUBLIC_DVD_{table}_{year}{month_file}010000.zip
#   PUBLIC_ARCHIVE (a few very large tables, '#' separated):
#     .../PUBLIC_ARCHIVE#{table}#FILE01#{year}{month}010000.zip
# =============================================================================

# NOTE: use the https + "www" host. The bare http://nemweb.com.au host issues a
# redirect and, for some clients/networks, is the cause of repeated download
# failures. The https www host below is what AEMO actually serves files from.
const MMSDM_DVD_URL = "https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/" *
    "MMSDM_{year}_{month}/MMSDM_Historical_Data_SQLLoader/DATA/" *
    "PUBLIC_DVD_{table}_{year}{month}010000.zip"

# AEMO's nemweb returns HTTP 403 to requests without a browser-like User-Agent.
# Always send these headers with every download.
const NEMWEB_HEADERS = [
    "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " *
                    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
    "Accept" => "*/*",
]

# -----------------------------------------------------------------------------
# Table definitions.
#
# `MMSTableDef` records, for each AEMO table we need, the columns to keep and
# how rows are filtered for a particular dispatch interval. The `filter`
# field mirrors nempy's per-table "Inputs*" classes:
#
#   :settlement_date  -> filter rows where SETTLEMENTDATE == interval
#   :start_end        -> rows valid for the interval: START_DATE <= t < END_DATE
#   :effective_ver    -> latest EFFECTIVEDATE/VERSIONNO effective at/<= interval
#   :no_filter        -> static reference table (use all rows)
#
# The exact column lists below are copied 1:1 from nempy's mms_db.DBManager so
# the downloaded data matches what nempy feeds into its loaders.
# -----------------------------------------------------------------------------
struct MMSTableDef
    name::String
    columns::Vector{String}
    filter::Symbol
end

const MMS_TABLES = Dict{String,MMSTableDef}(
    # Regional demand & supply summary (operational demand uses INITIALSUPPLY).
    "DISPATCHREGIONSUM" => MMSTableDef("DISPATCHREGIONSUM",
        ["SETTLEMENTDATE", "REGIONID", "TOTALDEMAND", "DEMANDFORECAST", "INITIALSUPPLY"],
        :settlement_date),

    # Per-unit dispatch record: initial MW, ramp rates, availability and the
    # full set of FCAS actual-availability columns (used as cross-checks).
    "DISPATCHLOAD" => MMSTableDef("DISPATCHLOAD",
        ["SETTLEMENTDATE", "DUID", "DISPATCHMODE", "AGCSTATUS", "INITIALMW", "TOTALCLEARED",
         "RAMPDOWNRATE", "RAMPUPRATE", "AVAILABILITY",
         "RAISEREGENABLEMENTMAX", "RAISEREGENABLEMENTMIN", "LOWERREGENABLEMENTMAX",
         "LOWERREGENABLEMENTMIN", "SEMIDISPATCHCAP",
         "LOWER5MIN", "LOWER60SEC", "LOWER6SEC", "LOWER1SEC",
         "RAISE5MIN", "RAISE60SEC", "RAISE6SEC", "RAISE1SEC", "LOWERREG", "RAISEREG",
         "RAISEREGAVAILABILITY", "RAISE6SECACTUALAVAILABILITY", "RAISE1SECACTUALAVAILABILITY",
         "RAISE60SECACTUALAVAILABILITY", "RAISE5MINACTUALAVAILABILITY", "RAISEREGACTUALAVAILABILITY",
         "LOWER6SECACTUALAVAILABILITY", "LOWER1SECACTUALAVAILABILITY", "LOWER60SECACTUALAVAILABILITY",
         "LOWER5MINACTUALAVAILABILITY", "LOWERREGACTUALAVAILABILITY"],
        :settlement_date),

    # Published regional reference prices. ROP = "Regional Original Price", the
    # price BEFORE any post-dispatch scaling/capping — this is what we benchmark
    # the model's recovered marginal price against.
    "DISPATCHPRICE" => MMSTableDef("DISPATCHPRICE",
        ["SETTLEMENTDATE", "REGIONID", "ROP", "RAISE6SECROP", "RAISE1SECROP", "RAISE60SECROP",
         "RAISE5MINROP", "RAISEREGROP", "LOWER6SECROP", "LOWER1SECROP", "LOWER60SECROP",
         "LOWER5MINROP", "LOWERREGROP"],
        :settlement_date),

    # Dispatchable-unit static details: region, dispatch type (generator/load),
    # loss factors and whether the unit is scheduled or semi-scheduled.
    "DUDETAILSUMMARY" => MMSTableDef("DUDETAILSUMMARY",
        ["DUID", "START_DATE", "END_DATE", "DISPATCHTYPE", "CONNECTIONPOINTID", "REGIONID",
         "TRANSMISSIONLOSSFACTOR", "DISTRIBUTIONLOSSFACTOR", "SCHEDULE_TYPE", "SECONDARY_TLF"],
        :start_end),

    "DUDETAIL" => MMSTableDef("DUDETAIL",
        ["DUID", "EFFECTIVEDATE", "VERSIONNO", "REGISTEREDCAPACITY"],
        :effective_ver),

    # --- 10-band energy/FCAS bids -------------------------------------------
    # IMPORTANT: the bid tables are DELIBERATELY NOT listed here.
    #
    # The 10 price/volume bands (PRICEBAND1..10 / BANDAVAIL1..10), FCAS
    # trapeziums, availability and ramp rates are read from the NEMDE XML case
    # files (see units.jl -> _parse_trades), exactly as nempy does. We therefore
    # never download the MMS bid tables.
    #
    # This matters for downloads: in the MMS archive the bid tables are NOT
    # named BIDDAYOFFER_D / BIDPEROFFER_D — they are PUBLIC_DVD_BIDDAYOFFER
    # (~160 MB) and PUBLIC_DVD_BIDPEROFFER1 / BIDPEROFFER2 (~3.5 GB EACH).
    # Trying to download those is what makes the input download hang/fail.
    # They are not needed; the NEMDE XML already carries every bid we use.

    # --- Interconnectors & loss model ---------------------------------------
    "INTERCONNECTOR" => MMSTableDef("INTERCONNECTOR",
        ["INTERCONNECTORID", "REGIONFROM", "REGIONTO"], :no_filter),
    "INTERCONNECTORCONSTRAINT" => MMSTableDef("INTERCONNECTORCONSTRAINT",
        ["INTERCONNECTORID", "EFFECTIVEDATE", "VERSIONNO", "FROMREGIONLOSSSHARE", "LOSSCONSTANT",
         "ICTYPE", "LOSSFLOWCOEFFICIENT", "IMPORTLIMIT", "EXPORTLIMIT"],
        :effective_ver),
    # LOSSMODEL: the MW breakpoints that define the piecewise-linear loss curve.
    "LOSSMODEL" => MMSTableDef("LOSSMODEL",
        ["INTERCONNECTORID", "EFFECTIVEDATE", "VERSIONNO", "LOSSSEGMENT", "MWBREAKPOINT"],
        :effective_ver),
    # LOSSFACTORMODEL: per-region demand coefficients of the loss equation.
    "LOSSFACTORMODEL" => MMSTableDef("LOSSFACTORMODEL",
        ["INTERCONNECTORID", "EFFECTIVEDATE", "VERSIONNO", "REGIONID", "DEMANDCOEFFICIENT"],
        :effective_ver),
    "DISPATCHINTERCONNECTORRES" => MMSTableDef("DISPATCHINTERCONNECTORRES",
        ["INTERCONNECTORID", "SETTLEMENTDATE", "MWFLOW", "MWLOSSES"], :settlement_date),
    "MNSP_INTERCONNECTOR" => MMSTableDef("MNSP_INTERCONNECTOR",
        ["INTERCONNECTORID", "LINKID", "EFFECTIVEDATE", "VERSIONNO", "FROMREGION", "TOREGION",
         "FROM_REGION_TLF", "TO_REGION_TLF", "LHSFACTOR", "MAXCAPACITY"],
        :effective_ver),

    # --- Generic / security constraints (kept for completeness; not added to
    #     the model in the Core+FCAS scope, but downloaded for parity) --------
    "DISPATCHCONSTRAINT" => MMSTableDef("DISPATCHCONSTRAINT",
        ["SETTLEMENTDATE", "CONSTRAINTID", "RHS", "GENCONID_EFFECTIVEDATE", "GENCONID_VERSIONNO",
         "LHS", "VIOLATIONDEGREE", "MARGINALVALUE"],
        :settlement_date),
    "GENCONDATA" => MMSTableDef("GENCONDATA",
        ["GENCONID", "EFFECTIVEDATE", "VERSIONNO", "CONSTRAINTTYPE", "GENERICCONSTRAINTWEIGHT"],
        :effective_ver),
)

# -----------------------------------------------------------------------------
# DBManager — owns the SQLite connection and orchestrates downloads.
# -----------------------------------------------------------------------------
"""
    DBManager(db_path::String)

Create (or open) a SQLite database at `db_path` that will hold AEMO MMS tables.
Equivalent to nempy's `mms_db.DBManager(connection=...)`.
"""
mutable struct DBManager
    db_path::String
    db::SQLite.DB
    DBManager(db_path::String) = new(db_path, SQLite.DB(db_path))
end

"""
    REQUIRED_TABLES

The MMS tables the dispatch model actually needs.

All of them are small — under 10 MB for a month — so a full-month download of
this set completes in seconds. The large tables `DISPATCHLOAD` (~100 MB) and
`DISPATCHCONSTRAINT` (~150 MB) are deliberately NOT here: the model takes initial
MW and SCADA ramp rates from the NEMDE case file, so they are needed only when
comparing the model's dispatch and duals against AEMO's published ones.

Pass `tables = vcat(REQUIRED_TABLES, "DISPATCHLOAD", "DISPATCHCONSTRAINT")` to
[`populate!`](@ref) when you want them.
"""
const REQUIRED_TABLES = String[
    "DISPATCHREGIONSUM",      # regional operational demand
    "DISPATCHPRICE",          # ROP benchmark prices
    "DUDETAILSUMMARY",        # unit region / loss factor / scheduled flag
    "DUDETAIL",               # registered capacity
    "INTERCONNECTOR",         # interconnector from/to regions
    "INTERCONNECTORCONSTRAINT",  # import/export limits + loss-share
    "LOSSMODEL",              # loss-curve MW breakpoints
    "LOSSFACTORMODEL",        # per-region demand coefficients
    "MNSP_INTERCONNECTOR",    # market network service providers (links)
    "DISPATCHINTERCONNECTORRES",  # historical flows/losses (cross-check)
]

"""
    populate!(m::DBManager; start_year, start_month, end_year, end_month,
              tables=REQUIRED_TABLES)

Download the requested MMS `tables` for each month in the inclusive range and
load them into SQLite. Defaults to the small [`REQUIRED_TABLES`](@ref) the model
needs (a few MB total). Mirrors `DBManager.populate`. Settlement-date tables are
accumulated across all months; reference/effective-version tables only need the
final month.
"""
function populate!(m::DBManager; start_year::Int, start_month::Int,
                   end_year::Int, end_month::Int, verbose::Bool=true,
                   tables::Vector{String}=REQUIRED_TABLES)
    months = _month_range(start_year, start_month, end_year, end_month)
    for tname in tables
        haskey(MMS_TABLES, tname) || (@warn "Unknown table $tname — skipping"; continue)
        tdef = MMS_TABLES[tname]
        # Settlement-date tables span the whole window; the rest only need the
        # final month's archive (it already contains the effective records).
        target_months = tdef.filter === :settlement_date ? months : [last(months)]
        first = true
        for (yr, mo) in target_months
            verbose && @info "Downloading $tname $yr-$(lpad(mo,2,'0'))"
            df = try
                _download_mms_table(tdef, yr, mo)
            catch err
                @warn "Failed to download $tname for $yr-$mo: $err"
                continue
            end
            _write_table!(m.db, tdef.name, df; replace=first)
            first = false
        end
    end
    return m
end

# Build the inclusive list of (year, month) tuples between two year/month pairs.
function _month_range(sy, sm, ey, em)
    out = Tuple{Int,Int}[]
    y, mo = sy, sm
    while (y < ey) || (y == ey && mo <= em)
        push!(out, (y, mo))
        mo == 12 ? (mo = 1; y += 1) : (mo += 1)
    end
    return out
end

# Download a single monthly archive, unzip the CSV and return the kept columns.
function _download_mms_table(tdef::MMSTableDef, year::Int, month::Int)
    # AEMO changed the MMSDM loader file naming for recent months:
    #   pre-change  (e.g. 2024_07): PUBLIC_DVD_{TABLE}_{yyyymm}010000.zip
    #   post-change (e.g. 2025_09): PUBLIC_ARCHIVE#{TABLE}#FILE01#{yyyymm}010000.zip
    # Try the legacy DVD name first (keeps all 2024 downloads byte-identical),
    # then fall back to the ARCHIVE name ('#' must be URL-encoded as %23).
    ym = string(year) * lpad(month, 2, '0')
    urls = [
        replace(MMSDM_DVD_URL, "{table}" => tdef.name,
                "{year}" => string(year), "{month}" => lpad(month, 2, '0')),
        replace(MMSDM_DVD_URL, "PUBLIC_DVD_{table}_{year}{month}010000.zip" =>
                "PUBLIC_ARCHIVE%23$(tdef.name)%23FILE01%23$(ym)010000.zip",
                "{year}" => string(year), "{month}" => lpad(month, 2, '0')),
    ]
    local resp
    for (k, url) in enumerate(urls)
        resp = HTTP.get(url, NEMWEB_HEADERS; status_exception=false, redirect=true,
                        retry=true, retries=3, request_timeout=1200, connect_timeout=120)
        if resp.status == 200
            df = _parse_mms_zip(resp.body, tdef.columns)
            @info "  $(tdef.name) $(year)-$(lpad(month,2,'0')): loaded $(size(df,1)) rows (URL form $(k == 1 ? "DVD" : "ARCHIVE"))"
            return df
        end
        k < length(urls) && @info "  $(tdef.name): HTTP $(resp.status) at legacy URL, trying ARCHIVE naming"
    end
    error("nemweb returned HTTP $(resp.status) for $(urls[end]). The data may " *
          "not be published yet, or the table/month is unavailable.")
end

"""
    populate_from_local!(m::DBManager, folder::String; tables=keys(MMS_TABLES))

Load MMS tables from MANUALLY-downloaded files instead of the network. Point
`folder` at a directory containing AEMO's `PUBLIC_DVD_<TABLE>_YYYYMM010000.CSV`
files (unzipped) and/or the original `.zip` archives. Each recognised table is
parsed and written to SQLite. Use this when automated download is blocked — see
MANUAL_DOWNLOAD.md.
"""
function populate_from_local!(m::DBManager, folder::String;
                              tables=collect(keys(MMS_TABLES)), verbose::Bool=true)
    isdir(folder) || error("Folder does not exist: $folder")
    files = readdir(folder; join=true)
    for tname in tables
        haskey(MMS_TABLES, tname) || continue
        tdef = MMS_TABLES[tname]
        # Match PUBLIC_DVD_<TABLE>_*.CSV or .zip (case-insensitive, exact table).
        pat = Regex("PUBLIC_DVD_" * tdef.name * "_\\d+\\.(csv|zip)\$", "i")
        matches = filter(f -> occursin(pat, basename(f)), files)
        isempty(matches) && (verbose && @warn "No local file for $tname in $folder"; continue)
        for path in matches
            verbose && @info "Loading local $tname from $(basename(path))"
            df = if endswith(lowercase(path), ".zip")
                _parse_mms_zip(read(path), tdef.columns)
            else
                _parse_mms_csv(read(path, String), tdef.columns)
            end
            _write_table!(m.db, tdef.name, df; replace=true)
        end
    end
    return m
end

# Parse AEMO's C/I/D CSV layout out of a zip archive in memory.
function _parse_mms_zip(zip_bytes::Vector{UInt8}, keep_columns::Vector{String})
    r = ZipFile.Reader(IOBuffer(zip_bytes))
    try
        f = first(r.files)               # each MMS archive holds one CSV file
        raw = read(f, String)
        return _parse_mms_csv(raw, keep_columns)
    finally
        close(r)
    end
end

"""
    _parse_mms_csv(raw::String, keep_columns) -> DataFrame

Decode AEMO's report-format CSV. The header ("I") row gives the column names;
the data ("D") rows hold the values. Only `keep_columns` are returned.
"""
function _parse_mms_csv(raw::String, keep_columns::Vector{String})
    header::Union{Nothing,Vector{String}} = nothing
    rows = Vector{Vector{String}}()
    for line in split(raw, '\n')
        isempty(line) && continue
        cells = _split_csv_line(line)
        tag = strip(cells[1])
        if tag == "I"            # information / header row defines columns
            header = String.(strip.(cells))
        elseif tag == "D"        # data row
            push!(rows, String.(strip.(cells)))
        end
        # "C" rows (control/header/footer) are ignored.
    end
    header === nothing && return DataFrame()
    # Map requested column names to positions in the AEMO header row.
    idx = Dict(name => i for (i, name) in enumerate(header))
    df = DataFrame()
    for col in keep_columns
        haskey(idx, col) || continue
        j = idx[col]
        df[!, col] = [(j <= length(r) ? r[j] : "") for r in rows]
    end
    return df
end

# Minimal CSV splitter handling AEMO's double-quoted text fields.
function _split_csv_line(line::AbstractString)
    out = String[]
    buf = IOBuffer()
    inq = false
    for ch in line
        if ch == '"'
            inq = !inq
        elseif ch == ',' && !inq
            push!(out, String(take!(buf)))
        else
            print(buf, ch)
        end
    end
    push!(out, String(take!(buf)))
    return out
end

# Persist a DataFrame into SQLite, appending to or replacing the table.
function _write_table!(db::SQLite.DB, name::String, df::DataFrame; replace::Bool)
    isempty(df) && return
    if replace
        SQLite.drop!(db, name; ifexists=true)
    end
    SQLite.load!(df, db, name)
    return
end

# -----------------------------------------------------------------------------
# Query helpers — pull a table filtered to a single dispatch interval.
# -----------------------------------------------------------------------------
"""
    get_table(m::DBManager, name::String; interval=nothing) -> DataFrame

Return rows of an MMS table, filtered to `interval` (an `AbstractString` such
as "2024/07/01 12:35:00", or a `DateTime`) according to that table's filter
rule. With `interval === nothing` the whole table is returned.
"""
function get_table(m::DBManager, name::String; interval=nothing)
    haskey(MMS_TABLES, name) || error("Unknown MMS table: $name")
    tdef = MMS_TABLES[name]
    # Per-interval tables: push the filter into SQL — materialising the whole
    # month (millions of rows for DISPATCHLOAD) into a DataFrame first is slow.
    if interval !== nothing && tdef.filter === :settlement_date
        t = _to_datetime(interval)
        key = Dates.format(t, dateformat"yyyy/mm/dd HH:MM:SS")
        return DataFrame(DBInterface.execute(m.db,
            "SELECT * FROM \"$name\" WHERE SETTLEMENTDATE = '$key'"))
    end
    df = DataFrame(DBInterface.execute(m.db, "SELECT * FROM \"$name\""))
    interval === nothing && return df
    t = _to_datetime(interval)
    if tdef.filter === :settlement_date
        return _filter_settlementdate(df, t)
    elseif tdef.filter === :start_end
        return _filter_start_end(df, t)
    elseif tdef.filter === :effective_ver
        return _filter_effective_version(df, t)
    else
        return df   # :no_filter
    end
end

# Parse AEMO time strings ("YYYY/MM/DD HH:MM:SS") or pass through a DateTime.
function _to_datetime(x)
    x isa DateTime && return x
    s = replace(String(x), "/" => "-")
    return DateTime(s, dateformat"yyyy-mm-dd HH:MM:SS")
end

_parse_aemo_dt(s) = ismissing(s) || s == "" ? missing :
    DateTime(replace(String(s), "/" => "-")[1:min(19, end)], dateformat"yyyy-mm-dd HH:MM:SS")

function _filter_settlementdate(df, t)
    "SETTLEMENTDATE" in names(df) || return df
    keep = [(!ismissing(d) && d == t) for d in _parse_aemo_dt.(df.SETTLEMENTDATE)]
    return df[keep, :]
end

function _filter_start_end(df, t)
    sd = _parse_aemo_dt.(df.START_DATE)
    ed = _parse_aemo_dt.(df.END_DATE)
    keep = [(!ismissing(s) && s <= t) && (ismissing(e) || t < e) for (s, e) in zip(sd, ed)]
    return df[keep, :]
end

# Keep records at the latest EFFECTIVEDATE/VERSIONNO that is effective at or
# before the interval, per key entity. CRITICAL: tables like LOSSMODEL hold
# MANY rows per (INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO) — one per loss
# segment/breakpoint — so we must keep ALL rows at the winning (date,version),
# not a single row. (Collapsing to one row destroyed the loss curve and left
# interconnectors lossless.)
function _filter_effective_version(df, t)
    "EFFECTIVEDATE" in names(df) || return df
    eff = _parse_aemo_dt.(df.EFFECTIVEDATE)
    valid = [(!ismissing(e) && e <= t) for e in eff]
    df2 = df[valid, :]
    isempty(df2) && return df2
    # Group by the primary ENTITY key only (not REGIONID/segment), so a group is
    # a whole interconnector/unit/constraint whose latest version we then keep in
    # full (all its segments/regions).
    keycols = intersect(["INTERCONNECTORID", "DUID", "GENCONID", "LINKID"], names(df2))
    isempty(keycols) && (keycols = intersect(["REGIONID"], names(df2)))
    isempty(keycols) && return df2
    df2 = copy(df2)
    df2.__eff = _parse_aemo_dt.(df2.EFFECTIVEDATE)
    df2.__ver = [tryparse(Float64, string(v)) === nothing ? 0.0 : parse(Float64, string(v))
                 for v in df2.VERSIONNO]
    gdf = groupby(df2, keycols)
    out = combine(gdf) do sub
        # Winning (effectivedate, versionno) for this entity.
        best = maximum(collect(zip(sub.__eff, sub.__ver)))
        sub[[(e, v) == best for (e, v) in zip(sub.__eff, sub.__ver)], :]
    end
    return select(out, Not([:__eff, :__ver]))
end
