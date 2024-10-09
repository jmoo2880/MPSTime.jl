# Sets of Basis Functions
function uniform_encode(x::Float64, d::Int) # please don't use this unless it's auxilliary to some kind of splitting method
    return [1 for _ in 1:d] / d
end

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


function fourier(x::Float64, i::Integer, d::Integer)
    return cispi.(i*x) / sqrt(d)
end

function get_fourier_freqs(d)
    # for a given feature dimension d, select a fourier basis with both positive and negative terms, and with a d-dim basis a proper subset of a (d+1)-dim basis
    bound = (d-1.)/2.
    # if d-1 is odd, then select the positive term first

    hbound = ceil(Integer, bound)
    return vcat(0, [[i,-i] for i in 1:hbound]...)[1:d]
end

function fourier_encode(x::Float64, d::Integer;)
    # default fourier encoding: given the feature map dimension, chooses the basis from get_fourier_freqs
    bounds = get_fourier_freqs(d)

    return [fourier(x,i,d) for i in bounds]

end

function fourier_encode(x::Float64, nds::Integer, ds::AbstractVector{Integer})
    # specialfourier encoding: given the feature map dimension, use the basis specified by the vector ds. ds should be precomputed in some data driven manner (usually in an init function)

    return [fourier(x, d, nds) for d in ds]
end

fourier_encode(x::Float64, nds::Integer, ti::Integer, ds::AbstractVector{<:AbstractVector{<:Integer}}) = fourier_encode(x, nds, ds[ti])


function sahand(x::Float64, i::Integer,d::Integer)
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
        s = complex(0.)
    end

    return s
end

function sahand_encode(x::Float64, d::Int)
    @assert iseven(d) "Sahand encoding only supports even dimension"

    return [sahand(x,i,d) for i in 1:d]
end


function legendre(x::Float64, i::Int, d::Int)
    return Pl(x, i; norm = Val(:normalized))
end

function legendre_encode(x::Float64, d::Int; norm = true)
    # default legendre encoding: choose the first n-1 legendre polynomials

    ls = [legendre(x,i,d) for i in 0:(d-1)] 
    
    if norm # this makes 
        # make sure that |ls|^2 <= 1
        ls /= sqrt(Pl(1,d; norm = Val(:normalized)) * d)
    end

    return ls
end

function legendre_encode(x::Float64, nds::Integer, ds::AbstractVector{<:Integer}; norm = true)
    # special legendre encoding: given the feature map dimension, use the basis specified by the vector ds. ds should be precomputed in some data driven manner (usually in an init function)
    ls = [legendre(x,d,nds) for d in ds] 
    
    if norm # this makes 
        # make sure that |ls|^2 <= 1
        d = maximum(ds)
        ls /= sqrt(Pl(1,d; norm = Val(:normalized)) * d)
    end

    return ls
end

legendre_encode(x::Float64, nds::Integer, ti::Integer, ds::AbstractVector{<:AbstractVector{<:Integer}}; norm=true) = legendre_encode(x, nds, ds[ti]; norm=norm)
legendre_encode_no_norm(args...; kwargs...) = legendre_encode(args...; kwargs..., norm=false) # praise be to overriding keywords


function sahand_legendre_encode(x::Float64, d::Integer, kde::UnivariateKDE, cVecs::AbstractMatrix{<:Real})    
    f0 = sqrt.(pdf(kde, x))
    
    return [sum(c*x^(i-1) for (i,c) in enumerate(cVecs[n,:])) for n in 1:d] .*f0
        
end

# time dep version
sahand_legendre_encode(
    x::Float64, 
    d::Integer, 
    ti::Integer, 
    kdes::AbstractVector{<:UnivariateKDE}, 
    cVecs::AbstractVector{<:AbstractMatrix{<:Real}}

) = sahand_legendre_encode(x, d, kdes[ti], cVecs[ti])



#### Projection Initialisers
# sahand-legendre projections

function construct_kerneldensity_wavefunction(xs::AbstractVector{<:Real}, range::Tuple; max_samples=max(200, 2*length(xs)), bandwidth=nothing, kwargs...)
    kdense = isnothing(bandwidth) ? kdes(xs) : kde(xs; bandwidth=bandwidth) 
    xs_samp = range(range..., max_samples) # sample the KDE more often than xs does, this helps with the frequency limits on the series expansion
    ys = pdf(kdense, xs_samp)

    wf = sqrt.(ys);
    return wf, xs_samp
end

function sahand_legendre_coeffs(xs_samp::AbstractVector{<:Real}, f0::AbstractVector{<:Real}, d::Integer)
    N=d-1
    cVecs = zeros(N+1,N+1) # rows are the n (order of f) and columns are the i (order of the polynomial in the sum to make f)
    cVecs[1,1] = 1 #c_00 is always 1

    #Build the matrix of overlaps. (This is really only a vector, but it's convenient to build it as a matrix like this)
    Mij = zeros(N+1,N+1)
    for i in 0:N, j in 0:N
        problem = SampledIntegralProblem((@. xs_samp^(i+j) * f0^2, xs_samp)...)
        s = solve(problem, TrapezoidalRule())
        Mij[i+1,j+1] = s.u
    end

    #now we iterate and get the functions
    for n in 1:N
        if n == 1
            #special case of getting the f1 function from the f0 function
            cVecs[2,1]=1 #set the first c value to 1
            cVecs[2,2] = -1/Mij[2,1] #get the second c value
            norm =  transpose(cVecs[2, 1:2]) * Mij[1:2,1:2] * cVecs[2,1:2]
            # norm = np.einsum("ij,i,j",Mij[0:2,0:2],cVecs[1,0:2],cVecs[1,0:2]) #normalise the function in terms of its c values
            cVecs[2,:] = cVecs[2,:]/sqrt(norm) # renormalise the c values
            
        else
            deltaVecTemp = zeros(n) # build the vector representing the kronecker delta on LHS of notes
            MijTemp = Mij[1,1:n] # get M_0j
            cVecTemp = cVecs[1:n,1:n] * MijTemp
            # cVecTemp = np.einsum("mj,j->m",cVecs[0:n+1,0:n+1],MijTemp) # get c_mj
        
            # Now build Mij cmj on RHS, which is the matrix we want to invert
            MijTemp = Mij[2:n+1,1:n]
            Aij = cVecs[1:n, 1:n] * transpose(MijTemp)
            # Aij = np.einsum("mj,ij->mi",cVecs[0:n+1,0:n+1],MijTemp)
        
            #now solve the problem
            inhomo = deltaVecTemp - cVecTemp #the inhomogeneous term
            cVecSol = Aij \ inhomo
            # cVecSol = np.linalg.solve(Aij, inhomo) #solve the linear problem
            cVecs[n+1,1] = 1 #set c_0 to 1
            for i in 2:n+1
                cVecs[n+1,i] = cVecSol[i-1] #use solutions to define new entries
            end
            norm = transpose(cVecs[n+1, 1:n+1]) * Mij[1:n+1, 1:n+1] * cVecs[n+1, 1:n+1]
            # norm = np.einsum("ij,i,j",Mij[0:n+2,0:n+2],cVecs[n+1,0:n+2],cVecs[n+1,0:n+2]) #Normalise the new basisfunction
            cVecs[n+1,:] = cVecs[n+1,:]/sqrt(norm) #renormalise the new basis function using the new cvecs
        end
    end
    return cVecs
end


function init_sahand_legendre_mean_only(Xs::Matrix{T}, ys::AbstractVector{<:Integer}; max_samples=max(200,size(Xs,1)), bandwidth=nothing, opts::Options) where {T <: Real}
    xs = mean(Xs; dims=2)[:]  # TS means
    kdense = isnothing(bandwidth) ? kde(xs) : kde(xs; bandwidth=bandwidth) 
    xs_samps = range(-1,1,max_samples) # sample the KDE more often than xs does, this helps with the frequency limits on the series expansion
    
    f0_oversampled = sqrt.(pdf(kdense, xs_samps))
    cVecs = sahand_legendre_coeffs(xs_samps, smooth_zero_intervals(f0_oversampled), opts.d)

    return [kdense, cVecs]
end


function init_sahand_legendre_full(Xs::Matrix{T}, ys::AbstractVector{<:Integer}; max_samples=max(200,size(Xs,1)), bandwidth=nothing, opts::Options) where {T <: Real}
    ntimepoints = size(Xs, 1)
    
    kdenses = Vector{UnivariateKDE}(undef, ntimepoints)
    cVecs = Vector{Matrix{T}}(undef, ntimepoints)

    xs_samps = range(-1,1,max_samples) # sample the KDE more often than xs does, this helps with the frequency limits on the series expansion

    for (i, xs) in enumerate(eachrow(Xs))
        kdense = isnothing(bandwidth) ? kde(xs) : kde(xs; bandwidth=bandwidth) 
        kdenses[i] = kdense

        f0_oversampled = sqrt.(pdf(kdense, xs_samps))
        cVecs[i] = sahand_legendre_coeffs(xs_samps, f0_oversampled, opts.d)
    end


    return [kdenses, cVecs]
end
# fourier series based projections
function series_expand(basis::AbstractVector{<:Function}, xs::AbstractVector{T}, ys::AbstractVector{U}, d::Integer) where {T<: Real, U <: Number}
    coeffs = []
    for f in basis
        bs = f.(xs)
        problem = SampledIntegralProblem(ys .* conj.(bs), xs)
        method = TrapezoidalRule()
        push!(coeffs, solve(problem, method).u)
    end
    return partialsortperm(abs2.(coeffs), 1:d; rev=true)
end

series_expand(f::Function, xs::AbstractVector{T}, ys::AbstractVector{U}, d::Integer; series_terms::AbstractVector{Integer}) where {T<: Real, U <: Number} = series_expand([x->f(x,n) for n in series_terms], xs, ys, d) 
series_expand(f::Function, xs::AbstractVector{T}, ys::AbstractVector{U}, d::Integer; max_series_terms::Integer=10*d) where {T<: Real, U <: Number} = series_expand(f, xs, ys, d; series_terms=0:(max_series_terms-1)) 


function project_fourier_time_independent(Xs::Matrix{T}, d::Integer; kwargs...) where {T <: Real}

    return project_fourier(mean(Xs; dims=2), d::Integer; kwargs...)
end

function project_fourier(Xs::Matrix{T}, d::Integer; kwargs...) where {T <: Real}

    return [[project_fourier(xs, d; kwargs...) for xs in eachrow(Xs)]]
end

function project_fourier(xs::AbstractVector{T}, d; max_series_terms=10*d, max_samples=max(200, 2*length(xs)), bandwidth=nothing, kwargs...) where {T <: Real}
    wf, xs_samp = construct_kerneldensity_wavefunction(xs, (-1,1); max_samples=max_samples, bandwidth=bandwidth)

    basis = [x -> cispi(n * x) for n in get_fourier_freqs(max_series_terms)]
    return series_expand(basis, xs_samp, wf, d)
end





function project_legendre_time_independent(Xs::AbstractMatrix{T}, d::Integer; kwargs...) where {T <: Real}

    return project_legendre(mean(Xs; dims=2), d; kwargs...)
end


function project_legendre(Xs::AbstractMatrix{T}, d::Integer; kwargs...) where {T <: Real}

    return [[project_legendre(xs, d; kwargs...) for xs in eachrow(Xs)]]
end

function project_legendre(xs::AbstractVector{T}, d::Integer; max_series_terms::Integer=7*d, max_samples=max(200, 2*length(xs)), bandwidth=nothing, kwargs...) where {T <: Real}
    wf, xs_samp = construct_kerneldensity_wavefunction(xs, (-1,1); max_samples=max_samples, bandwidth=bandwidth)
    basis= [x -> Pl(x,l; norm = Val(:normalized)) for l in 0:(max_series_terms-1)]
    return series_expand(basis, xs_samp, wf, d)
end

project_legendre(Xs::AbstractMatrix{<:Real}, ys::AbstractVector{<:Integer}; opts, kwargs...) = project_legendre(Xs, opts.d; kwargs...)

include("splitbases.jl")