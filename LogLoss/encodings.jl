using LegendrePolynomials
using StatsBase: countmap, sample
using PrettyTables

# Sets of Basis Functions

function angle_encode(x::Float64, d::Int; periods=1/4)
    @assert d == 2 "Stoudenmire Angle encoding only supports d = 2!"
    return angle_encode(x;periods=periods)
end

function angle_encode(x::Float64; periods=1/4) 
    """Function to convert normalised time series to an angle encoding."""
    @assert x <= 1.0 && x >= 0.0 "Data points must be rescaled between 1 and 0 before encoding using the angle encoder."
    s1 = cispi( 3*x/2) * cospi(2*periods* x)
    s2 = cispi(-3*x/2) * sinpi(2*periods * x)
    return [s1, s2]
 
end


function fourier(x::Float64, i::Int,d::Int)
    return cispi.(i*x) / sqrt(d)
end

function fourier_encode(x::Float64, d::Int; exclude_DC::Bool=true)
    if exclude_DC
        return [fourier(x,i,d) for i in 1:d]
    else
        return [fourier(x,i,d) for i in 0:(d-1)]
    end
end


function sahand(x::Float64, i::Int,d::Int)
    dx = 2/d # width of one interval
    interval = ceil(i/2)
    startx = (interval-1) * dx
    if startx <= x <= interval*dx
        if isodd(i)
            s = cispi(3*x/2/dx) * cospi(0.5 * (x - startx)/dx )
        else
            s = cispi(-3*x/2/dx) * sinpi(0.5 * (x - startx)/dx )
        end
    else
        s = 0 + 0im
    end

    return ComplexF64(s)
end

function sahand_encode(x::Float64, d::Int)
    @assert iseven(d) "Sahand encoding only supports even dimension"

    return [sahand(x,i,d) for i in 1:d]
end


function legendre(x::Float64,i::Int, d::Int)
    return Pl(x, i; norm = Val(:normalized))
end

function legendre_encode(x::Float64, d::Int; norm = true)
    ls = [legendre(x,i,d) for i in 1:d] 
    
    if norm # this makes 
        # make sure that |ls|^2 <= 1
        ls /= sqrt(Pl(1,d; norm = Val(:normalized)) * d)
    end

    return ls
end


function uniform_encode(x::Float64, d::Int) # please don't use this unless it's auxilliary to some kind of splitting method
    return [1 for _ in 1:d] / d
end


##################### Splitting methods
function unif_split(data::AbstractMatrix, nbins::Integer, a::Real, b::Real)
    dx = 1/nbins# width of one interval
    return collect(a:dx:b)
end

function hist_split(samples::AbstractVector, nbins::Integer, a::Real, b::Real) # samples should be a vector of timepoints at a single time (NOT a timeseries) for all sensible use cases
    npts = length(samples)
    bin_pts = Int(round(npts/nbins))

    if bin_pts == 0
        @warn("Less than one data point per bin! Putting the extra bins at x=1 and hoping for the best")
    end

    bins = fill(convert(eltype(samples), a), nbins+1) # look I'm not happy about this syntax either. Why does zeros() take a type, but not fill()?
    
    #bins[1] = a # lower bound
    j = 2
    ds = sort(samples)
    for (i,x) in enumerate(ds)
        if i % bin_pts == 0 && i < length(samples)
            if j == nbins + 1
                # This can happen if bin_pts is very small due to a small dataset, e.g. npts = 18, nbins = 8, then we can get as high as j = 10 and IndexError!
                #@warn("Only $bin_pts data point(s) per bin! This may seriously bias the encoding/lead to per performance (last bin contains $(npts - i) extra points)")
                break
            end
            bins[j] = (x + ds[i+1])/2
            j += 1
        end
    end
    if j <=  nbins
        bins[bins .== a] .= b 
        bins[1] = a
    end

    bins[end] = b # upper bound
    return bins
end

function hist_split(X_norm::AbstractMatrix, nbins::Integer, a::Real, b::Real)
    return [hist_split(samples,nbins, a, b) for samples in eachcol(X_norm)]
end




################## Splitting Initialisers
function unif_split_init(X_norm::AbstractMatrix, y::Vector{Int}; opts::Options)
    nbins = get_nbins_safely(opts)

    bins = opts.encoding.splitmethod(X_norm, nbins, opts.encoding.range...)
    split_args = [bins, opts.aux_basis_dim, opts.encoding.basis]

    basis_args = isnothing(opts.encoding.basis.init) ? [] : opts.encoding.basis.init(X_norm, y; opts=opts)

    return [basis_args, split_args]
end

function hist_split_init(X_norm::AbstractMatrix, y::Vector{Int}; opts::Options)
    
    nbins = get_nbins_safely(opts)
    bins = opts.encoding.splitmethod(X_norm, nbins, opts.encoding.range...)
    split_args = [bins, opts.aux_basis_dim, opts.encoding.basis]

    basis_args = isnothing(opts.encoding.basis.init) ? [] : opts.encoding.basis.init(X_norm, y; opts=opts)
    
    return [basis_args, split_args]
end

function get_nbins_safely(opts)
    nbins = opts.d / opts.aux_basis_dim
    try
        convert(Int, nbins)
    catch e
        if e isa InexactError
            error("The auxilliary basis dimension ($(opts.aux_basis_dim)) must evenly divide the total feature dimension ($(opts.d))")
        else
            throw(e)
        end
    end

    return convert(Int, nbins) # try blocks have their own scope
end

################## Splitting encoding helpers
function rect(x)
    # helper used to construct the split basis. It is important that rect(0.5) returns 0.5 because if an encoded point lies exactly on a bin boundary we want enc(x) = (0,...,0, 0.5, 0.5, 0,...0)
    # (Having two 1s instead of two 0.5s would violate our normalised encoding assumption)
    return  abs(x) == 0.5 ? 0.5 : 1. * float(-0.5 <= x <= 0.5)
end

function project_onto_unif_bins(x::Float64, d::Int, basis_args::AbstractVector, split_args::AbstractVector; norm=true)
    bins::Vector{Float64}, aux_dim::Int, basis::Basis = split_args
    widths = diff(bins)

    encoding = []
    for i = 1:Int(d/aux_dim)
        auxvec = xx -> basis.encode(xx, aux_dim, basis_args...)
        #auxvec = xx -> ones(aux_dim)
        
        dx = widths[i]
        y = norm ? 1. : 1/widths[i]

        select = y * rect((x - bins[i])/dx - 0.5)
        aux_enc = select == 0 ? zeros(aux_dim) : select .* auxvec((x-bins[i])/dx) # necessary so that we don't evaluate aux basis function out of its domain
        push!(encoding, aux_enc)
    end


    return vcat(encoding...)
end


function project_onto_unif_bins(x::Float64, d::Int, ti::Int, basis_args::AbstractVector, split_args::AbstractVector; norm=true)
    # time dep version in case the aux basis is time dependent
    bins::Vector{Float64}, aux_dim::Int, basis::Basis = split_args
    widths = diff(bins)

    encoding = []
    for i = 1:Int(d/aux_dim)
        auxvec = xx -> basis.encode(xx, aux_dim, ti, basis_args...) # we know it's time dependent

        dx = widths[i]
        y = norm ? 1. : 1/widths[i]
        select = y * rect((x - bins[i])/dx - 0.5)
        aux_enc = select == 0 ? zeros(aux_dim) : select .* auxvec((x-bins[i])/dx) # necessary so that we don't evaluate aux basis function out of its domain
        push!(encoding, aux_enc)
    end


    return vcat(encoding...)
end


function project_onto_hist_bins(x::Float64, d::Int, ti::Int, basis_args::AbstractVector, split_args::AbstractVector; norm=true)
    all_bins::Vector{Vector{Float64}}, aux_dim::Int, basis::Basis = split_args
    bins = all_bins[ti]
    widths = diff(bins)

    encoding = []
    for i = 1:Int(d/aux_dim)
        if basis.istimedependent
            auxvec = xx -> basis.encode(xx, aux_dim, ti, basis_args...)
        else
            auxvec = xx -> basis.encode(xx, aux_dim, basis_args...)
        end

        dx = widths[i]
        y = norm ? 1. : 1/widths[i]
        select = y * rect((x - bins[i])/dx - 0.5)
        aux_enc = select == 0 ? zeros(aux_dim) : select .* auxvec((x-bins[i])/dx) # necessary so that we don't evaluate aux basis function out of its domain
        push!(encoding, aux_enc)
    end


    return vcat(encoding...)
end



###################################################################################
function encode_TS(sample::Vector, site_indices::Vector{Index{Int64}}, encoding_args::AbstractVector; opts::Options=Options())
    """Function to convert a single normalised sample to a product state
    with local dimension 2, as specified by the feature map."""

    n_sites = length(site_indices) # number of mps sites
    product_state = MPS(opts.dtype,site_indices; linkdims=1)
    
    
    # check that the number of sites matches the length of the time series
    if n_sites !== length(sample)
        error("Number of MPS sites: $n_sites does not match the time series length: $(length(sample))")
    end

    for j=1:n_sites

        if opts.encoding.istimedependent
            states = opts.encoding.encode(sample[j], opts.d, j, encoding_args...)
        else
            states = opts.encoding.encode(sample[j], opts.d, encoding_args...)
        end

        product_state[j] = ITensor(opts.dtype, states, site_indices[j])
    end

    return product_state

end

function encode_dataset(X_norm::AbstractMatrix, y::Vector{Int}, type::String, 
    site_indices::Vector{Index{Int64}}; opts::Options=Options(), balance_classes=opts.encoding.isbalanced, rng=MersenneTwister(1234))
    """"Convert an entire dataset of normalised time series to a corresponding 
    dataset of product states"""

    types = ["train", "test", "valid", "test_enc"]
    if type in types
        println("Initialising $type states.")
    else
        error("Invalid dataset type. Must be train, test, or valid.")
    end

    # check data is in the expected range first
    a,b = opts.encoding.range
    name = opts.encoding.name
    if all((a .<= X_norm) .& (X_norm .<= b)) == false
        error("Data must be rescaled between $a and $b before a $name encoding.")
    end

    # check class balance
    cm = countmap(y)
    balanced = all(i-> i == first(values(cm)), values(cm))
    if !balanced
        println("Classes are not Balanced:")
        pretty_table(cm, header=["Class", "Count"])
    end

    # handle the encoding initialisation
    if isnothing(opts.encoding.init)
        encoding_args = []
    elseif !balanced && balance_classes
        min_s = minimum(values(cm))
        println("Balancing Encoding initialisation by cutting to $min_s samples in each class!\n")
        Xns = []
        ys = []
        for k in keys(cm)
            Xn = X_norm[y .== k,:]
            Xn = Xn[sample(rng, 1:end, min_s; replace=false),:] # randomly select min_s samples from this class
            push!(Xns, Xn)
            push!(ys, fill(k, min_s))
        end
        X_balanced = vcat(Xns...)
        ys = vcat(ys...)

        # re-randomise the order, almost certainly not necessary but it's a good safety precaution
        ord = shuffle(rng, 1:length(ys))
        X_balanced = X_balanced[ord,:] 
        ys = ys[ord]

        encoding_args = opts.encoding.init(X_balanced, ys; opts=opts)
    else
        encoding_args = opts.encoding.init(X_norm, y; opts=opts)
    end


    num_ts = size(X_norm)[1]
    # pre-allocate
    

    if type !== "test_enc"

        all_product_states = timeSeriesIterable(undef, num_ts)
        for i=1:num_ts
            sample_pstate = encode_TS(X_norm[i, :], site_indices, encoding_args; opts=opts)
            sample_label = y[i]
            product_state = PState(sample_pstate, sample_label, type)
            all_product_states[i] = product_state
        end
       
    else # a test encoding used to plot the basis being used if "test_run"=true
        a,b = opts.encoding.range
        num_ts *= 10 # increase resolution for plotting
        #num_samples = size(X_norm,2)
        stp = (b-a)/(num_ts-1)
        X_norm = Matrix{Float64}(undef, num_ts, size(X_norm,2))
        for col in eachcol(X_norm)
            col[:] = collect(a:stp:b)
        end

        all_product_states = timeSeriesIterable(undef, num_ts)

        for i=1:num_ts
            sample_pstate = encode_TS(X_norm[i, :], site_indices, encoding_args; opts=opts)
            sample_label = true # irrelevent
            product_state = PState(sample_pstate, sample_label, type)
            all_product_states[i] = product_state
        end

    end

    return all_product_states

end;