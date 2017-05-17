"""
```
type MeansBands
```

Stores the means and bands of results for a particular set of outputs from the forecast step.

Specifically, forecasts can be made for any element in the Cartesian product of 4 sets:

1. `input_type`: some subset of the parameter draws from the estimation
   step. See `forecast_one` for all possible options.

2. `cond_type`: conditional type. See `forecast_one` for all possible options.

3. *product*: a particular result computed in the forecast. This could be one of
   the following:

```
  - `hist`: smoothed histories
  - `forecast`: forecasted values
  - `shockdec`: shock decompositions
  - `irf`: impulse responses
```

4. variable *class*: the category in which a particular variable, like `:y_t`,
   falls. Options are:

```
  - `state`: state (from `m.endogenous_states` or `m.endogenous_states_augmented`)
  - `obs`: observable (from `m.observables`)
  - `pseudo`: pseudoobservable (from `pseudo_measurement` equation)
  - `shock`: shock (from `m.exogenous_shocks`)
```

Note that the Cartesian product (product x class) is the set of options for
`output_vars` in the `forecast_one` function signature.

### Fields

- `metadata::Dict{Symbol,Any}`: Contains metadata keeping track of the
  `input_type`, `cond_type`, product (history, forecast, shockdec,
  etc), and variable class (observable, pseudoobservable, state, etc)
  stored in this `MeansBands` structure.
- `means::DataFrame`: a `DataFrame` of the mean of the time series
- `bands::Dict{Symbol,DataFrame}`: a `Dict` mapping variable names to
  `DataFrame`s containing confidence bands for each variable. See
  `find_density_bands` for more information.
"""
type MeansBands
    metadata::Dict{Symbol,Any}
    means::DataFrame
    bands::Dict{Symbol,DataFrame}

    function MeansBands(key, means, bands)

        if !isempty(bands)

            # assert that means and bands fields have the same keys (provide info for same products)
            @assert sort(setdiff(names(means),[:date])) == sort(collect(keys(bands)))

            # check to make sure that # of periods in all dataframes are the same
            n_periods_means = size(means,1)
            for df in values(bands)
                n_periods_bands = size(df,1)
                @assert(n_periods_means == n_periods_bands,
                        "means and bands must have same number of periods")
            end
        end

        new(key, means, bands)
    end
end

# A dummy MeansBands object
function MeansBands()
    metadata   = Dict(:class => :none, :product => :none,
                      :cond_type => :none, :para => :none,
                      :indices => Dict{Symbol, Int}(:none => 1))

    means = DataFrame(date = [Date(0)], none = [0.0])
    bands = Dict{Symbol,DataFrame}(:none => DataFrame(date = [Date(0)]))

    MeansBands(metadata, means, bands)
end

function Base.show(io::IO, mb::MeansBands)
    @printf io "MeansBands\n"
    @printf io "  class: %s\n"   get_class(mb)
    @printf io "  product: %s\n" get_product(mb)
    @printf io "  cond: %s\n"    get_cond_type(mb)
    @printf io "  para: %s\n"    get_para(mb)
    if mb.metadata[:product] != :trend && mb.metadata[:product] != :irf
        @printf io "  dates: %s - %s\n" startdate_means(mb) enddate_means(mb)
    end
    @printf io "  # of variables: %s\n" n_vars_means(mb)
    @printf io "  bands: %s\n" which_density_bands(mb, uniquify=true)
end

"""
```
Base.isempty(mb::MeansBands)
```

Returns whether the `mb` object in question is a dummy.
"""
function Base.isempty(mb::MeansBands)

    return get_class(mb) == :none && get_product(mb) == :none &&
        startdate_means(mb) == Date(0) &&
        collect(names(mb.means)) ==  [:date, :none] &&
        collect(keys(mb.bands)) ==  [:none]
end

"""
```
Base.cat(mb1::MeansBands, mb2::MeansBands; out_product = Symbol(),
    forecast_string = "")
```

Concatenate 2 compatible `MeansBands` objects together by date. 2
`MeansBands` objects are defined to be compatible if the class of
variables is the same, the conditional type is the same, and the
input_type for the forecast used to create the two `MeansBands` object
is the same. Furthermore, we require that the dates covered by each
`MeansBands` object form a continguous interval.

### Inputs

- `mb1::MeansBands`
- `mb2::MeansBands`

Note that the dates in `mb1` should come chronologically first, with the dates
in `mb2` beginning 1 period after the final period in `mb1`.

### Keyword Arguments

- `out_product::Symbol`: desired product of the resulting concatenated
`MeansBands` object. This argument is required if `mb1` and `mb2` do not
represent a history and a forecast respectively
- `forecast_string::String`: desired `forecast_string` of the resulting
  concatenated `MeansBands`. This argument is recommended (but not required) if
  the `forecast_string`s of `mb1` and `mb2` do not match. If this is the case
  but `forecast_string` is not provided, `mb1`'s `forecast_string` will be used.
"""
function Base.cat(mb1::MeansBands, mb2::MeansBands;
                  out_product::Symbol = Symbol(),
                  forecast_string::String = "")

    # Assert class, cond type and para are the same
    @assert get_class(mb1) == get_class(mb2)
    @assert get_cond_type(mb1) == get_cond_type(mb2)
    @assert get_para(mb1) == get_para(mb2)

    # Assert dates are contiguous
    last_mb1_date  = enddate_means(mb1)
    first_mb2_date = startdate_means(mb2)

    @assert iterate_quarters(last_mb1_date, 1) == first_mb2_date

    # compute means field
    means = vcat(mb1.means, mb2.means)

    # compute bands field
    bands = Dict{Symbol, DataFrame}()

    mb1vars = collect(keys(mb1.bands))
    mb2vars = collect(keys(mb2.bands))
    nperiods_mb1 = length(mb1.metadata[:date_inds])
    nperiods_mb2 = length(mb2.metadata[:date_inds])

    bothvars = intersect(mb1vars, mb2vars)
    for var in union(keys(mb1.bands), keys(mb2.bands))
        bands[var] = if var in bothvars
            vcat(mb1.bands[var], mb2.bands[var])
        elseif var in setdiff(mb1vars, mb2vars)
            vcat(mb1vars[var], fill(NaN, nperiods_mb2))
        else
            vcat(fill(NaN, nperiods_mb1), mb2vars[var])
        end
    end

    # compute metadata
    # product
    mb1_product = get_product(mb1)
    mb2_product = get_product(mb2)
    product = if mb1_product == :hist && contains(string(mb2_product), "forecast")
        Symbol(string(mb1_product)*string(mb2_product))
    elseif mb1_product == mb2_product
        mb1_product
    else
        @assert !isempty(out_product) "Please supply a product name for the output MeansBands"
        out_product
    end

    # date indices
    date_indices = Dict(d::Date => i::Int for (i, d) in enumerate(means[:date]))

    # variable indices
    indices = Dict(var::Symbol => i::Int for (i, var) in enumerate(names(means)))

    # forecast string
    if isempty(forecast_string) && (mb1.metadata[:forecast_string] != mb2.metadata[:forecast_string])
        warn("No forecast_string provided: using $(mb1.metadata[:forecast_string])")
    end
    forecast_string = mb1.metadata[:forecast_string]

    metadata = Dict{Symbol, Any}(
                   :para            => get_para(mb1),
                   :cond_type       => get_cond_type(mb1),
                   :class           => get_class(mb1),
                   :product         => product,
                   :indices         => indices,
                   :forecast_string => forecast_string,
                   :date_inds       => sort(date_indices, by = x -> date_indices[x]))

    # construct the new MeansBands object and return
    MeansBands(mb1.metadata, means, bands)
end


###################################
## METADATA
###################################

"""
```
get_class(mb::MeansBands)
```
Returns the class of variables contained this `MeansBands` object (observables, pseudoobservables)
"""
get_class(mb::MeansBands) = mb.metadata[:class]

"""
```
get_product(mb::MeansBands)
```
Returns the product stored in this `MeansBands` object (history, forecast, shock decompostion, etc).
"""
get_product(mb::MeansBands) = mb.metadata[:product]

"""
```
get_cond_type(mb::MeansBands)
```
Returns the conditional type of the forecast used to create this `MeansBands` object.
"""
get_cond_type(mb::MeansBands) = mb.metadata[:cond_type]

"""
```
get_para(mb::MeansBands)
```
Returns the `input_type` from the forecast used to create this `MeansBands` object.
"""
get_para(mb::MeansBands) = mb.metadata[:para]

"""
```
get_shocks(mb::MeansBands)
```

Returns a list of shock names that are used for the shock
decomposition stored in a shock decomposition or irf MeansBands object `mb`.
"""
function get_shocks(mb::MeansBands)
    @assert get_product(mb) in [:shockdec, :irf] "Function only for shockdec or irf MeansBands objects"
    varshocks = setdiff(names(mb.means), [:date])
    unique(map(x -> Symbol(split(string(x), DSGE_SHOCKDEC_DELIM)[2]), varshocks))
end

"""
```
parse_mb_colname(s::Symbol)
```

`MeansBands` column names are saved in the format
`\$var\$DSGE_SHOCKDEC_DELIM\$shock`. `parse_mb_colname` returns (`var`,
`shock`).
"""
function parse_mb_colname(s::Symbol)
    map(Symbol, split(string(s), DSGE_SHOCKDEC_DELIM))
end

"""
```
get_variables(mb::MeansBands)
```

Returns a list of variable names that are used for the shock
decomposition stored in a shock decomposition or irf MeansBands object `mb`.
"""
function get_variables(mb::MeansBands)
    @assert get_product(mb) in [:shockdec, :irf] "Function only for shockdec or irf MeansBands objects"
    varshocks = setdiff(names(mb.means), [:date])
    unique(map(x -> Symbol(split(string(x), DSGE_SHOCKDEC_DELIM)[1]), varshocks))
end

###################################
## MEANS
###################################

"""
```
n_vars_means(mb::MeansBands)
````

Get number of variables (`:y_t`, `:OutputGap`, etc) in `mb.means`.
"""
function n_vars_means(mb::MeansBands)
    length(get_vars_means(mb))
end

"""
```
get_vars_means(mb::MeansBands)
````

Get variables (`:y_t`, `:OutputGap`, etc) in `mb.means`. Note that
`mb.metadata[:indices]` is an `OrderedDict`, so the keys will be in the correct
order.
"""
function get_vars_means(mb::MeansBands)
    collect(keys(mb.metadata[:indices]))
end


"""
```
n_periods_means(mb::MeansBands)
```

Get number of periods in `mb.means`.
"""
n_periods_means(mb::MeansBands) = size(mb.means,1)

"""
```
startdate_means(mb::MeansBands)
```

Get first period in`mb.means`. Assumes `mb.means[product]` is already sorted by
date.
"""
startdate_means(mb::MeansBands) = mb.means[:date][1]

"""
```
enddate_means(mb::MeansBands)
```

Get last period for which `mb` stores means. Assumes `mb.means[product]` is
already sorted by date.
"""
enddate_means(mb::MeansBands) = mb.means[:date][end]


"""
```
get_shockdec_means(mb::MeansBands, var::Symbol;
    shocks::Vector{Symbol} = Vector{Symbol}())
```

Return the mean value of each shock requested in the shock decomposition of a
particular variable. If `shocks` is empty, returns all shocks.
"""
function get_shockdec_means(mb::MeansBands, var::Symbol; shocks::Vector{Symbol} = Vector{Symbol}())

    # Extract the subset of columns relating to the variable `var` and the shocks listed in `shocks.`
    # If `shocks` not provided, give all the shocks
    var_cols = collect(names(mb.means))[find([contains(string(col), string(var)) for col in names(mb.means)])]
    if !isempty(shocks)
        var_cols = [col -> contains(string(col), string(shock)) ? col : nothing for shock in shocks]
    end

    # Make a new DataFrame with column the column names
    out = DataFrame()
    for col in var_cols
        shockname = split(string(col), DSGE_SHOCKDEC_DELIM)[2]
        out[Symbol(shockname)] = mb.means[col]
    end

    return out
end



###################################
## BANDS
###################################

"""
```
n_vars_bands(mb::MeansBands)
```

Get number of variables (`:y_t`, `:OutputGap`, etc) for which `mb`
stores bands for the specified `product` (`hist`, `forecast`, `shockdec`, etc).
"""
n_vars_bands(mb::MeansBands) = length(mb.bands)


"""
```
n_periods_bands(mb::MeansBands)
```

Get number of periods for which `mb` stores bands for the specified
product` (`hist`, `forecast`, `shockdec`, etc).
"""
function n_periods_bands(mb::MeansBands)
    size(mb.bands[collect(keys(mb.bands))[1]],1)
end

"""
```
startdate_bands(mb::MeansBands)
```

Get first period for which `mb` stores bands. Assumes `mb.bands` is already sorted by date.
"""
startdate_bands(mb::MeansBands) = mb.bands[collect(keys(mb.bands))][:date][1]

"""
```
enddate_bands(mb::MeansBands)
```

Get last period in `mb.bands`. Assumes `mb.bands` is already sorted by date.
"""
enddate_bands(mb::MeansBands) = mb.bands[:date][end]

"""
```
which_density_bands(mb, uniquify=false)
```

Return a list of the bands stored in mb.bands. If `uniquify = true`,
strips \"upper\" and \"lower\" band tags and returns unique list of percentage values.
"""
function which_density_bands(mb::MeansBands; uniquify=false, ordered=true)

    # extract one of the keys in mb.bands
    var  = collect(keys(mb.bands))[1]

    # get all the columns in the corresponding dataframe that aren't dates
    strs = map(string,names(mb.bands[var]))
    strs = setdiff(strs, ["date"])

    lowers = strs[map(ismatch, repmat([r"LB"], length(strs)), strs)]
    uppers = strs[map(ismatch, repmat([r"UB"], length(strs)), strs)]

    # sort
    if ordered
        sort!(lowers, rev=true)
        sort!(uppers)
    end

    # return both upper and lower bands, or just percents, as desired
    strs = if uniquify
        sort(unique([split(x, " ")[1] for x in [lowers; uppers]]))
    else
        [lowers; uppers]
    end

    return strs
end


"""
```
get_shockdec_bands(mb, var; shocks = Vector{Symbol}(), bands = Vector{Symbol}())
```

Return a `Dict{Symbol,DataFrame}` mapping shock names to bands for a particular
variable.

### Inputs

- `mb::MeansBands`
- `var::Symbol`: the variable of interest (eg the state `:y_t`, or observable
  `:obs_hours`)

### Keyword Arguments

- `shocks::Vector{Symbol}`: subset of shock names for which to return bands. If
  empty, `get_shockdec_bands` returns all bands
- `bands::Vector{Symbol}`: subset of bands stored in the DataFrames of
  `mb.bands` to return
"""
function get_shockdec_bands(mb::MeansBands, var::Symbol;
                            shocks::Vector{Symbol} = Vector{Symbol}(),
                            bands::Vector{Symbol} = Vector{Symbol}())

    @assert get_product(mb) == :shockdec

    # Extract the subset of columns relating to the variable `var` and the shocks listed in `shocks.`
    # If `shocks` not provided, give all the shocks
    var_cols = collect(keys(mb.bands))[find([contains(string(col), string(var)) for col in keys(mb.bands)])]
    if !isempty(shocks)
        var_cols = [col -> contains(string(col), string(shock)) ? col : nothing for shock in shocks]
    end

    # Extract the subset of bands we want to return. Return all bands if `bands` not provided.
    bands_keys = if isempty(bands)
        names(mb.bands[var_cols[1]])
    else
        [[Symbol("$(100x)% LB") for x in bands]; [Symbol("$(100x)% UB") for x in bands]]
    end

    # Make a new dictionary mapping shock names to bands
    out = Dict{Symbol, DataFrame}()
    for col in var_cols
        shockname = parse_mb_colname(col)[2]
        out[shockname] = mb.bands[col][bands_keys]
    end

    return out
end


################################################
## EXTRACTING VARIABLES
################################################

"""
```
prepare_meansbands_table_timeseries(mb, var)
```

Returns a `DataFrame` of means and bands for a particular time series variable
(either `hist` or `forecast` of some type). Columns are sorted such that the
bands are ordered from smallest to largest, and the means are on the far
right. For example, a `MeansBands` containing 50\% and 68\% bands would be
ordered as follows: [68\% lower, 50\% lower, 50\% upper, 68\% upper, mean].

### Inputs

- `mb::MeansBands`: time-series MeansBands object
- `var::Symbol`: an economic variable stored in `mb`. If `mb` stores
  observables, `var` would be an element of `names(m.observables)`. If
  it stores pseudo-observables, `var` would be the name of a
  pseudo-observable defined in the pseudo-measurement equation.
"""
function prepare_meansbands_table_timeseries(mb::MeansBands, var::Symbol)

    @assert get_product(mb) in [:hist, :forecast, :forecast4q, :bddforecast,
         :bddforecast4q, :trend, :dettrend] "prepare_meansbands_table_timeseries can only be used for time-series products"

    @assert var in get_vars_means(mb) "$var is not stored in this MeansBands object"

    # Extract this variable from Means and bands
    means = mb.means[[:date, var]]
    bands = mb.bands[var][[:date; map(Symbol, which_density_bands(mb))]]

    # Join so mean is on far right and date is on far left
    df = join(bands, means, on = :date)
    rename!(df, var, Symbol("mean"))

    return df
end

"""
```
prepare_meansbands_table_irf(mb, var, shock)
```

Returns a `DataFrame` of means and bands for a particular impulse
response function of variable (observable, pseudoobservable, or state)
`v` to shock `s`. Columns are sorted such that the bands are ordered from
smallest to largest, and the means are on the far right. For example,
a MeansBands object containing 50\% and 68\% bands would be ordered as
follows: [68\% lower, 50\% lower, 50\% upper, 68\% upper, mean].

### Inputs
- `mb::MeansBands`: time-series MeansBands object
- `var::Symbol`: an economic variable stored in `mb`. If `mb` stores
  observables, `var` would be an element of `names(m.observables)`. If
  it stores pseudoobservables, `var` would be the name of a
  pseudoobservable defined in the pseudomeasurement equation.
"""
function prepare_meansbands_table_irf(mb::MeansBands, shock::Symbol, var::Symbol)

    @assert get_product(mb) in [:irf] "prepare_meansbands_table_irf can only be used for irfs"
    @assert var in get_vars_means(mb) "$var is not stored in this MeansBands object"

    # get the variable-shock combination we want to print
    # varshock = Symbol["$var" * DSGE_SHOCKDEC_DELIM * "$shock" for var in vars]
    varshock = Symbol("$var" * DSGE_SHOCKDEC_DELIM * "$shock")

    # extract the means and bands for this irf
    df = mb.bands[varshock][map(Symbol, which_density_bands(mb))]
    df[:mean] = mb.means[varshock]

    return df
end
function prepare_meansbands_table_irf(mb::MeansBands, shock::Symbol, vars::Vector{Symbol})

    # Print all vars by default
    if isempty(vars)
        vars = DSGE.get_variables(mb)
    end

    # Make dictionary to return
    irfs = Dict{Symbol, DataFrame}()

    # Make tables for each irf
    for var in vars
        irfs[var] = prepare_meansbands_table_irf(mb, shock, var)
    end

    return irfs
end

"""
```
prepare_means_table_shockdec(mb_shockdec::MeansBands, mb_trend::MeansBands,
           mb_dettrend::MeansBands, var::Symbol; [shocks = Vector{Symbol}()],
           [mb_forecast = MeansBands()], [mb_hist = MeansBands()])
```

Returns a `DataFrame` representing a detrended shock decompostion for
the variable `var`. The columns of this dataframe represent the
contributions of each shock in `shocks` (or all shocks, if the keyword
argument is omitted) and the deterministic trend.

### Inputs
- `mb_shockdec::MeansBands`: a `MeansBands` object for a shock decomposition
- `mb_trend::MeansBands`: a `MeansBands` object for a trend  product.
- `mb_dettrend::MeansBands`: a `MeansBands` object for a deterministic trend
  product.
- `var::Symbol`: name of economic variable for which to return the means and bands table

### Keyword Arguments
- `shocks::Vector{Symbol}`: If `mb` is a shock decomposition, this is
  an optional list of shocks to print to the table. If omitted, all
  shocks will be printed.
- `mb_forecast::MeansBands`: a `MeansBands` object for a forecast.
- `mb_hist::MeansBands`: a `MeansBands` object for smoothed states.
"""
function prepare_means_table_shockdec(mb_shockdec::MeansBands, mb_trend::MeansBands,
                                      mb_dettrend::MeansBands, var::Symbol;
                                      shocks::Vector{Symbol} = Vector{Symbol}(),
                                      mb_forecast::MeansBands = MeansBands(),
                                      mb_hist::MeansBands = MeansBands())

    @assert get_product(mb_shockdec) == :shockdec "The first argument must be a MeansBands object for a shockdec"
    @assert get_product(mb_trend)    == :trend    "The second argument must be a MeansBands object for a trend"
    @assert get_product(mb_dettrend) == :dettrend "The third argument must be a MeansBands object for a deterministic trend"

    # Print all shocks by default
    if isempty(shocks)
        shocks = DSGE.get_shocks(mb_shockdec)
    end

    # get the variable-shock combinations we want to print
    varshocks = Symbol["$var" * DSGE_SHOCKDEC_DELIM * "$shock" for shock in shocks]

    # fetch the columns corresponding to varshocks
    df_shockdec = mb_shockdec.means[union([:date], varshocks)]
    df_trend    = mb_trend.means[[:date, var]]
    df_dettrend = mb_dettrend.means[[:date, var]]

    # line up dates between trend, dettrend and shockdec
    df_shockdec = join(df_shockdec, df_trend, on = :date, kind = :inner)
    rename!(df_shockdec, var, :trend)
    df_shockdec = join(df_shockdec, df_dettrend, on = :date, kind = :inner)
    rename!(df_shockdec, var, :dettrend)

    # de-trend each shock's contribution and add to the output dataframe
    df = DataFrame(date = df_shockdec[:date])
    for col in setdiff(names(df_shockdec), [:date, :trend])
        df[col] = df_shockdec[col] - df_shockdec[:trend]
    end

    # add the de-trended deterministic trend
    df_shockdec[:dettrend] = df_shockdec[:dettrend] - df_shockdec[:trend]

    # rename columns to just the shock names
    map(x -> rename!(df, x, parse_mb_colname(x)[2]), setdiff(names(df), [:date, :trend, :dettrend]))

    # last, if mb_forecast and mb_hist are passed in, add the
    # detrended time series mean of var to the table
    if !isempty(mb_forecast) && !isempty(mb_hist)

        mb_timeseries = cat(mb_hist, mb_forecast)

        # truncate to just the dates we want
        startdate = df[:date][1]
        enddate   = df[:date][end]
        df_mean   = mb_timeseries.means[startdate .<= mb_timeseries.means[:date] .<= enddate, [:date, var]]

        df_shockdec = join(df_shockdec, df_mean, on = :date, kind = :inner)
        df[:detrendedMean] = df_shockdec[var] - df_shockdec[:trend]
    end

    return df
end