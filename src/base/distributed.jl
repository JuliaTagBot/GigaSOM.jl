"""
    save_at(worker, sym, val)

Saves value `val` to symbol `sym` at `worker`. `sym` should be quoted (or
contain a symbol). `val` gets unquoted in the processing and evaluated at the
worker, quote it if you want to pass exact command to the worker.

This is loosely based on the package ParallelDataTransfers, but made slightly
more flexible by omitting/delaying the explicit fetches etc. In particular,
`save_at` is roughly the same as `ParallelDataTransfers.sendto`, and
`get_val_from` works very much like `ParallelDataTransfers.getfrom`.

# Return value

A future with Nothing that can be fetched to see that the operation has
finished.

# Examples

    addprocs(1)
    save_at(2,:x,123)       # saves 123
    save_at(2,:x,myid())    # saves 1
    save_at(2,:x,:(myid())) # saves 2
    save_at(2,:x,:(:x))     # saves the symbol :x
                            # (just :x won't work because of unquoting)

# Note: Symbol scope

The symbols are saved in Main module on the corresponding worker. For example,
`save_at(1, :x, nothing)` _will_ erase your local `x` variable. Beware of name
collisions.
"""
function save_at(worker, sym::Symbol, val)
    remotecall(() -> Base.eval(Main, :(
        begin
            $sym = $val
            nothing
        end
    )), worker)
end

"""
    get_from(worker,val)

Get a value `val` from a remote `worker`; quoting of `val` works just as with
`save_at`. Returns a future with the requested value.
"""
function get_from(worker, val)
    remotecall(() -> Base.eval(Main, :($val)), worker)
end

"""
    get_val_from(worker,val)

Shortcut for instantly fetching the future from `get_from`.
"""
function get_val_from(worker, val)
    fetch(get_from(worker, val))
end

"""
    remove_from(worker,sym)

Sets symbol `sym` on `worker` to `nothing`, effectively freeing the data.
"""
function remove_from(worker, sym::Symbol)
    save_at(worker, sym, nothing)
end

"""
    distribute_array(sym, x::Array, pids; dim=1)::LoadedDataInfo

Distribute roughly equal parts of array `x` separated on dimension `dim` among
`pids` into a worker-local variable `sym`.

Returns the `LoadedDataInfo` structure for the distributed data.
"""
function distribute_array(sym::Symbol, x::Array, pids; dim = 1)::LoadedDataInfo
    n = length(pids)
    dims = size(x)

    for f in [
        begin
            extent = [(1:s) for s in dims]
            extent[dim] = (1+div((wid - 1) * dims[dim], n)):div(wid * dims[dim], n)
            save_at(pid, sym, x[extent...])
        end for (wid, pid) in enumerate(pids)
    ]
        fetch(f)
    end

    return LoadedDataInfo(sym, pids)
end

"""
    distribute_darray(sym, dd::DArray)::LoadedDataInfo

Distribute the distributed array parts from `dd` into worker-local variable
`sym`.

Returns the `LoadedDataInfo` structure for the distributed data.
"""
function distribute_darray(sym::Symbol, dd::DArray)::LoadedDataInfo
    for f in [save_at(pid, sym, :($localpart($dd))) for pid in dd.pids]
        fetch(f)
    end
    return LoadedDataInfo(sym, dd.pids)
end

"""
    undistribute(sym, workers)

Remove the loaded data from workers.
"""
function undistribute(sym::Symbol, workers)
    for f in [remove_from(pid, sym) for pid in workers]
        fetch(f)
    end
end

"""
    undistribute(dInfo::LoadedDataInfo)

Remove the loaded data described by `dInfo` from the corresponding workers.
"""
function undistribute(dInfo::LoadedDataInfo)
    undistribute(dInfo.val, dInfo.workers)
end

"""
    distributed_exec(val, fn, workers)

Execute a function on workers, taking `val` as a parameter. Results are not
collected. This is optimal for various side-effect-causing computations that
are not expressible with `distributed_transform`.
"""
function distributed_exec(val, fn, workers)
    for f in [get_from(pid, :(
        begin
            $fn($val)
            nothing
        end
    )) for pid in workers]
        fetch(f)
    end
end

"""
    distributed_exec(dInfo::LoadedDataInfo, fn)

Variant of `distributed_exec` that works with `LoadedDataInfo`.
"""
function distributed_exec(dInfo::LoadedDataInfo, fn)
    distributed_exec(dInfo.val, fn, dInfo.workers)
end

"""
    distributed_transform(val, fn, workers, tgt::Symbol=val)

Transform the worker-local distributed data available as `val` on `workers`
in-place, by a function `fn`. Store the result as `tgt` (default `val`)

# Example
    
    # multiply all saved data by 2
    distributed_transform(:myData, (d)->(2*d), workers())
"""
function distributed_transform(val, fn, workers, tgt::Symbol = val)::LoadedDataInfo
    for f in [save_at(pid, tgt, :($fn($val))) for pid in workers]
        fetch(f)
    end
    return LoadedDataInfo(tgt, workers)
end

"""
    distributed_transform(dInfo::LoadedDataInfo, fn, tgt::Symbol=dInfo.val)::LoadedDataInfo

Same as `distributed_transform`, but specialized for `LoadedDataInfo`.
"""
function distributed_transform(
    dInfo::LoadedDataInfo,
    fn,
    tgt::Symbol = dInfo.val,
)::LoadedDataInfo
    distributed_transform(dInfo.val, fn, dInfo.workers, tgt)
end

"""
    distributed_mapreduce(val, map, fold, workers)

Run `map`s (non-modifying transforms on the data) and `fold`s (2-to-1
reductions) on the worker-local data (in `val`s) distributed on `workers` and
return the final reduced result.

It is assumed that the fold operation is associative, but not commutative (as
in semigroups). If there are no workers, operation returns `nothing` (we don't
have a monoid to magically conjure zero elements :[ ).

In current version, the reduce step is a sequential left fold, executed in the
main process.

# Example
    # compute the mean of all distributed data
    sum,len = distributed_mapreduce(:myData,
        (d) -> (sum(d),length(d)),
        ((s1, l1), (s2, l2)) -> (s1+s2, l1+l2),
        workers())
    println(sum/len)

# Processing multiple arguments (a.k.a. "zipWith")

The `val` here does not necessarily need to refer to a symbol, you can easily
pass in a quoted tuple, which will be unquoted in the function parameter. For
example, distributed values `:a` and `:b` can be joined as such:

    distributed_mapreduce(:((a,b)),
        ((a,b)::Tuple) -> [a b],
        vcat,
        workers())
"""
function distributed_mapreduce(val, map, fold, workers)
    if isempty(workers)
        return nothing
    end

    futures = [get_from(pid, :($map($val))) for pid in workers]
    res = fetch(futures[1])

    # replace the collected futures with new empty futures to allow them to be
    # GC'd and free memory for more incoming results
    futures[1] = Future()

    for i = 2:length(futures)
        res = fold(res, fetch(futures[i]))
        futures[i] = Future()
    end
    res
end

"""
    distributed_mapreduce(dInfo::LoadedDataInfo, map, fold)

Distributed map/reduce (just as the other overload of `distributed_mapreduce`)
that works with `LoadedDataInfo`.
"""
function distributed_mapreduce(dInfo::LoadedDataInfo, map, fold)
    distributed_mapreduce(dInfo.val, map, fold, dInfo.workers)
end

"""
    distributed_mapreduce(vals::Vector, map, fold, workers)

Variant of `distributed_mapreduce` that works with more distributed variables
at once.
"""
function distributed_mapreduce(vals::Vector, map, fold, workers)
    return distributed_mapreduce(Expr(:vect, vals...), vals -> map(vals...), fold, workers)
end

"""
    distributed_mapreduce(dInfo1::LoadedDataInfo, dInfo2::LoadedDataInfo, map, fold)

Variant of `distributed_mapreduce` that works with more `LoadedDataInfo`s at
once.  The data must be distributed on the same set of workers, in the same
order.
"""
function distributed_mapreduce(dInfos::Vector{LoadedDataInfo}, map, fold)
    if (isempty(dInfos))
        return nothing
    end

    if any([dInfos[1].workers] .!= [di.workers for di in dInfos])
        @error "workers in LoadedDataInfo objects do not match" dInfos[1].workers
        error("data distribution mismatch")
    end

    return distributed_mapreduce([di.val for di in dInfos], map, fold, dInfos[1].workers)
end

"""
    distributed_collect(val::Symbol, workers, dim=1; free=false)

Collect the arrays distributed on `workers` under value `val` into an array. The
individual arrays are pasted in the dimension specified by `dim`, i.e. `dim=1`
is roughly equivalent to using `vcat`, and `dim=2` to `hcat`.

`val` must be an Array-based type; the function will otherwise fail.

If `free` is true, the `val` is undistributed after collection.

This preallocates the array for results, and is thus more efficient than e.g.
using `distributed_mapreduce` with `vcat` for folding.
"""
function distributed_collect(val::Symbol, workers, dim = 1; free = false)
    size0 = get_val_from(workers[1], :(size($val)))
    innerType = get_val_from(workers[1], :(typeof($val).parameters[1]))
    sizes = distributed_mapreduce(val, d -> size(d, dim), vcat, workers)
    ressize = [size0[i] for i = 1:length(size0)]
    ressize[dim] = sum(sizes)
    result = zeros(innerType, ressize...)
    off = 0
    for (i, pid) in enumerate(workers)
        idx = [(1:ressize[j]) for j = 1:length(ressize)]
        idx[dim] = ((off+1):(off+sizes[i]))
        result[idx...] = get_val_from(pid, val)
        off += sizes[i]
    end
    if free
        undistribute(val, workers)
    end
    return result
end

"""
    distributed_collect(dInfo::LoadedDataInfo, dim=1; free=false)

Distributed collect (just as the other overload) that works with
`LoadedDataInfo`.
"""
function distributed_collect(dInfo::LoadedDataInfo, dim = 1; free = false)
    return distributed_collect(dInfo.val, dInfo.workers, dim, free = free)
end

"""
    distributed_foreach(arr::Vector, fn, workers)

Call a function `fn` on `workers`, with a single parameter arriving from the
corresponding position in `arr`.
"""
function distributed_foreach(arr::Vector, fn, workers)
    futures = [
        remotecall(() -> Base.eval(Main, :($fn($(arr[i])))), pid)
        for (i, pid) in enumerate(workers)
    ]
    return [fetch(f) for f in futures]
end

"""
    tmpSym(s::Symbol; prefix="", suffix="_tmp")

Decorate a symbol `s` with prefix and suffix, to create a good name for a
related temporary value.
"""
function tmpSym(s::Symbol; prefix = "", suffix = "_tmp")
    return Symbol(prefix * String(s) * suffix)
end

"""
    tmpSym(dInfo::LoadedDataInfo; prefix="", suffix="_tmp")

Decorate the symbol from `dInfo` with prefix and suffix.
"""
function tmpSym(dInfo::LoadedDataInfo; prefix = "", suffix = "_tmp")
    return tmpSym(dInfo.val, prefix = prefix, suffix = suffix)
end
