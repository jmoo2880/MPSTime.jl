using GenericLinearAlgebra
using ITensors
using Optim
using OptimKit
using Random
using Distributions
using DelimitedFiles
using Folds
using JLD2
using StatsBase
using Plots
using Parameters
include("summary.jl")
include("utils.jl")

struct BBOpt 
    name::String
    fl::String
    BBOpt(s::String, fl::String) = begin
        if !(s in ["Optim", "OptimKit", "CustomGD"]) 
            error("Unknown Black Box Optimiser $s, options are [CustomGD, Optim, OptimKit]")
        end
        new(s,fl)
    end
end

function BBOpt(s::String)
    if s == "CustomGD"
        return BBOpt(s, "GD")
    else
        return BBOpt(s, "CGD")
    end
end

@with_kw struct Options
    nsweeps::Int
    chi_max::Int
    cutoff::Float64
    update_iters::Int
    verbosity::Int
    dtype::DataType
    lg_iter
    bbopt
    track_cost::Bool
    eta::Float64
    rescale::Vector{Bool}
end

function Options(; nsweeps=5, chi_max=25, cutoff=1E-10, update_iters=10, verbosity=1, dtype::DataType=ComplexF64, lg_iter=KLD_iter, bbopt=BBOpt("Optim"),
    track_cost::Bool=(verbosity >=1), eta=0.01, rescale = [false, true])
    Options(nsweeps, chi_max, cutoff, update_iters, verbosity, dtype, lg_iter, bbopt, track_cost, eta, rescale)
end


function generate_startingMPS(chi_init, site_indices::Vector{Index{Int64}};
    num_classes = 2, random_state=nothing, dtype::DataType=ComplexF64)
    """Generate the starting weight MPS, W using values sampled from a 
    Gaussian (normal) distribution. Accepts a chi_init parameter which
    specifies the initial (uniform) bond dimension of the MPS."""
    
    if random_state !== nothing
        # use seed if specified
        Random.seed!(random_state)
        println("Generating initial weight MPS with bond dimension χ_init = $chi_init
        using random state $random_state.")
    else
        println("Generating initial weight MPS with bond dimension χ_init = $chi_init.")
    end

    W = randomMPS(dtype,site_indices, linkdims=chi_init)

    label_idx = Index(num_classes, "f(x)")

    # get the site of interest and copy over the indices at the last site where we attach the label 
    old_site_idxs = inds(W[end])
    new_site_idxs = old_site_idxs, label_idx
    new_site = randomITensor(dtype,new_site_idxs)

    # add the new site back into the MPS
    W[end] = new_site

    # normalise the MPS
    normalize!(W)

    # canonicalise - bring MPS into canonical form by making all tensors 1,...,j-1 left orthogonal
    # here we assume we start at the right most index
    last_site = length(site_indices)
    orthogonalize!(W, last_site)

    return W

end

function construct_caches(W::MPS, training_pstates::timeSeriesIterable; going_left=true, dtype::DataType=ComplexF64)
    """Function to pre-compute tensor contractions between the MPS and the product states. """

    # get the num of training samples to pre-allocate a caching matrix
    N_train = length(training_pstates) 
    # get the number of MPS sites
    N = length(W)

    # pre-allocate left and right environment matrices 
    LE = PCache(undef, N, N_train) 
    RE = PCache(undef, N, N_train)

    if going_left
        # backward direction - initialise the LE with the first site
        for i = 1:N_train
            LE[1,i] =  conj(training_pstates[i].pstate[1]) * W[1] 
        end

        for j = 2 : N
            for i = 1:N_train
                LE[j,i] = LE[j-1, i] * (conj(training_pstates[i].pstate[j]) * W[j])
            end
        end
    
    else
        # going right
        # initialise RE cache with the terminal site and work backwards
        for i = 1:N_train
            RE[N,i] = conj(training_pstates[i].pstate[N]) * W[N]
        end

        for j = (N-1):-1:1
            for i = 1:N_train
                RE[j,i] =  RE[j+1,i] * (W[j] * conj(training_pstates[i].pstate[j]))
            end
        end
    end

    @assert !isa(eltype(eltype(RE)), dtype) || !isa(eltype(eltype(LE)), dtype)  "Caches are not the correct datatype!"

    return LE, RE

end


function realise(B::ITensor, C_index::Index{Int64}; dtype::DataType=ComplexF64)
    ib = inds(B)
    inds_c = C_index,ib
    B_m = Array{dtype}(B, ib)

    out = Array{real(dtype)}(undef, 2,size(B)...)
    
    ls = eachslice(out; dims=1)
    
    ls[1] = real(B_m)
    ls[2] = imag(B_m)

    return ITensor(real(dtype), out, inds_c)
end


function complexify(B::ITensor, C_index::Index{Int64}; dtype::DataType=ComplexF64)
    ib = inds(B)
    C_index, c_inds... = ib
    B_ra = NDTensors.array(B, ib) # should return a view


    re_part = selectdim(B_ra, 1,1);
    im_part = selectdim(B_ra, 1,2);

    return ITensor(dtype, complex.(re_part,im_part), c_inds)
end


function yhat_phitilde(BT::ITensor, LEP::PCacheCol, REP::PCacheCol, 
    product_state::PState, lid::Int, rid::Int)
    """Return yhat and phi_tilde for a bond tensor and a single product state"""
    ps= product_state.pstate
    phi_tilde = conj(ps[lid] * ps[rid]) # phi tilde 


    if lid == 1
        # at the first site, no LE
        # formatted from left to right, so env - product state, product state - env
        phi_tilde *=  REP[rid+1]
    elseif rid == length(ps)
        # terminal site, no RE
        phi_tilde *= LEP[lid-1] 
    else
        # we are in the bulk, both LE and RE exist
        phi_tilde *= LEP[lid-1] * REP[rid+1]

    end


    yhat = BT * phi_tilde # NOT a complex inner product !! 

    return yhat, phi_tilde

end

function MSE_iter(BT_c::ITensor, LEP::PCacheCol, REP::PCacheCol,
    product_state::PState, lid::Int, rid::Int) 
    """In order to use Optim, we must format the function to return 
    the loss function evaluated for the sample, along with the gradient 
        of the loss function for that sample (fg)"""


    yhat, phi_tilde = yhat_phitilde(BT_c, LEP, REP, product_state, lid, rid)

    # convert the label to ITensor
    label_idx = first(inds(yhat))
    y = onehot(label_idx => (product_state.label + 1))

    diff_sq = abs2.(yhat - y)
    sum_of_sq_diff = sum(diff_sq)
    loss = 0.5 * real(sum_of_sq_diff)

    # construct the gradient - return dC/dB
    gradient = (yhat - y) * conj(phi_tilde)

    return [loss, gradient]

end




function KLD_iter(BT_c::ITensor, LEP::PCacheCol, REP::PCacheCol,
    product_state::PState, lid::Int, rid::Int) 
    """In order to use Optim, we must format the function to return 
    the loss function evaluated for the sample, along with the gradient 
        of the loss function for that sample (fg)"""


    yhat, phi_tilde = yhat_phitilde(BT_c, LEP, REP, product_state, lid, rid)

    # convert the label to ITensor
    label_idx = first(inds(yhat))
    y = onehot(label_idx => (product_state.label + 1))
    f_ln = first(yhat *y)
    loss = -log(abs2(f_ln))

    # construct the gradient - return dC/dB
    gradient = -y * conj(phi_tilde / f_ln) # mult by y to account for delta_l^lambda



    return [loss, gradient]

end

function mixed_iter(BT_c::ITensor, LEP::PCacheCol, REP::PCacheCol,
    product_state::PState, lid::Int, rid::Int; alpha=5) 

    yhat, phi_tilde = yhat_phitilde(BT_c, LEP, REP, product_state, lid, rid)

    # convert the label to ITensor
    label_idx = first(inds(yhat))
    y = onehot(label_idx => (product_state.label + 1))
    f_ln = first(yhat *y)
    log_loss = -log(abs2(f_ln))

    # construct the gradient - return dC/dB
    log_gradient = -y * conj(phi_tilde / f_ln) # mult by y to account for delta_l^lambda

    # MSE
    diff_sq = abs2.(yhat - y)
    sum_of_sq_diff = sum(diff_sq)
    MSE_loss = 0.5 * real(sum_of_sq_diff)

    # construct the gradient - return dC/dB
    MSE_gradient = (yhat - y) * conj(phi_tilde)


    return [log_loss + alpha*MSE_loss, log_gradient + alpha*MSE_gradient]

end

function loss_grad_cplx(BT::ITensor, LE::PCache, RE::PCache,
    TSs::timeSeriesIterable, lid::Int, rid::Int; lg_iter::Function=KLD_iter)
    """Function for computing the loss function and the gradient
    over all samples. Need to specify a LE, RE,
    left id (lid) and right id (rid) for the bond tensor."""
 
    loss,grad = Folds.mapreduce((LEP,REP, prod_state) -> lg_iter(BT,LEP,REP,prod_state,lid,rid),+, eachcol(LE), eachcol(RE),TSs)
    
    loss /= length(TSs)
    grad ./= length(TSs)

    return loss, grad

end

function loss_grad(BT::ITensor, LE::PCache, RE::PCache,
    TSs::timeSeriesIterable, lid::Int, rid::Int, C_index::Index{Int64}; dtype::DataType=ComplexF64, lg_iter::Function=KLD_iter)
    """Function for computing the loss function and the gradient
    over all samples. Need to specify a LE, RE,
    left id (lid) and right id (rid) for the bond tensor."""
    
    # loss, grad = Folds.reduce(+, Computeloss_gradPerSample(BT, LE, RE, prod_state, prod_state_id, lid, rid) for 
    #     (prod_state_id, prod_state) in enumerate(TSs))


    # get the complex itensor back
    BT_c = complexify(BT, C_index; dtype=dtype)

    loss, grad = loss_grad_cplx(BT_c, LE, RE, TSs, lid, rid; lg_iter=lg_iter)

    grad = realise(grad, C_index; dtype=dtype)


    return loss, grad

end

function loss_grad!(F,G,B_flat::AbstractArray, b_inds::Tuple{Vararg{Index{Int64}}}, LE::PCache, RE::PCache,
    TSs::timeSeriesIterable, lid::Int, rid::Int, C_index::Index{Int64}; dtype::DataType=ComplexF64, lg_iter::Function=KLD_iter)

    BT = itensor(real(dtype), B_flat, b_inds)
    loss, grad = loss_grad(BT, LE, RE, TSs, lid, rid, C_index; dtype=dtype, lg_iter=lg_iter)

    if !isnothing(G)
        G .= NDTensors.array(grad,b_inds)
    end

    if !isnothing(F)
        return loss
    end

end

function apply_update(BT_init::ITensor, LE::PCache, RE::PCache, lid::Int, rid::Int,
    TSs::timeSeriesIterable; iters=10, verbosity::Real=1, dtype::DataType=ComplexF64, lg_iter::Function=KLD_iter, bbopt::BBOpt=BBOpt("Optim"),
    track_cost::Bool=false, eta=0.01, rescale = [true, false])
    """Apply update to bond tensor using Optimkit"""
    # we want the loss and gradient fn to be a functon of only the bond tensor 
    # this is what optimkit updates and feeds back into the loss/grad function to re-evaluate on 
    # each iteration. 

    if rescale[1]
        normalize!(BT_init)
    end

    if bbopt.name == "CustomGD"
        BT_old = BT_init
        for i in 1:iters
            # get the gradient
            loss, grad = loss_grad_cplx(BT_old, LE, RE, TSs, lid, rid; lg_iter=lg_iter)
            #zygote_gradient_per_batch(bt_old, LE, RE, pss, lid, rid)
            # update the bond tensor
            BT_new = BT_old - eta * grad
            if verbosity >=1 && track_cost
                # get the new loss
                println("Loss at step $i: $loss")
            end

            BT_old = BT_new
        end
    else
        # break down the bond tensor to feed into optimkit
        C_index = Index(2, "C")
        bt_re = realise(BT_init, C_index; dtype=dtype)

        # flatten bond tensor into a vector and get the indices
        bt_inds = inds(bt_re)
        bt_flat = NDTensors.array(bt_re, bt_inds) # should return a view

        if bbopt.name == "Optim" 
            # create anonymous function to feed into optim, function of bond tensor only
            fgcustom! = (F,G,B) -> loss_grad!(F, G, B, bt_inds, LE, RE, TSs, lid, rid, C_index; dtype=dtype, lg_iter=lg_iter)
            # set the optimisation manfiold
            # apply optim using specified gradient descent algorithm and corresp. paramters 
            # set the manifold to either flat, sphere or Stiefel 
            if bbopt.fl == "CGD"
                method = Optim.ConjugateGradient(eta=eta)
            else
                method = Optim.GradientDescent(alphaguess=eta)
            end
            #method = Optim.LBFGS()
            res = Optim.optimize(Optim.only_fg!(fgcustom!), bt_flat; method=method, iterations = iters, 
            show_trace = (verbosity >=1),  g_abstol=1e-20)
            result_flattened = Optim.minimizer(res)

            BT_new = complexify(itensor(real(dtype), result_flattened, bt_inds), C_index; dtype=dtype)

        elseif bbopt.name == "OptimKit"

            lg = BT -> loss_grad(BT, LE, RE, TSs, lid, rid, C_index; dtype=dtype, lg_iter=lg_iter)
            if bbopt.fl == "CGD"
                alg = OptimKit.ConjugateGradient(; verbosity=verbosity, maxiter=iters)
            else
                alg = OptimKit.GradientDescent(; verbosity=verbosity, maxiter=iters)
            end
            BT_new, fx, _ = OptimKit.optimize(lg, bt_re, alg)

            BT_new = complexify(BT_new, C_index; dtype=dtype)


        else
            error("Unknown Black Box Optimiser $bbopt, options are [CustomGD, Optim, OptimKit]")
        end


    end

    if rescale[2]
        normalize!(BT_new)
    end

    if track_cost
        loss, grad = loss_grad_cplx(BT_new, LE, RE, TSs, lid, rid; lg_iter=lg_iter)
        println("Loss at site $lid*$rid: $loss")
    end

    return BT_new

end

function decomposeBT(BT::ITensor, lid::Int, rid::Int; 
    chi_max=nothing, cutoff=nothing, going_left=true, dtype::DataType=ComplexF64)
    """Decompose an updated bond tensor back into two tensors using SVD"""
    left_site_index = findindex(BT, "n=$lid")
    label_index = findindex(BT, "f(x)")


    if going_left
        # need to make sure the label index is transferred to the next site to be updated
        if lid == 1
            U, S, V = svd(BT, (left_site_index, label_index); maxdim=chi_max, cutoff=cutoff)
        else
            bond_index = findindex(BT, "Link,l=$(lid-1)")
            U, S, V = svd(BT, (left_site_index, label_index, bond_index); maxdim=chi_max, cutoff=cutoff)
        end
        # absorb singular values into the next site to update to preserve canonicalisation
        left_site_new = U * S
        right_site_new = V
        # fix tag names 
        replacetags!(left_site_new, "Link,v", "Link,l=$lid")
        replacetags!(right_site_new, "Link,v", "Link,l=$lid")
    else
        # going right, label index automatically moves to the next site
        if lid == 1
            U, S, V = svd(BT, (left_site_index); maxdim=chi_max, cutoff=cutoff)
        else
            bond_index = findindex(BT, "Link,l=$(lid-1)")
            U, S, V = svd(BT, (bond_index, left_site_index); maxdim=chi_max, cutoff=cutoff)
        end
        # absorb into next site to be updated 
        left_site_new = U
        right_site_new = S * V
        # fix tag names 
        replacetags!(left_site_new, "Link,u", "Link,l=$lid")
        replacetags!(right_site_new, "Link,u", "Link,l=$lid")
    end


    return left_site_new, right_site_new

end

function update_caches!(left_site_new::ITensor, right_site_new::ITensor, 
    LE::PCache, RE::PCache, lid::Int, rid::Int, product_states; going_left::Bool=true)
    """Given a newly updated bond tensor, update the caches."""
    num_train = length(product_states)
    num_sites = size(LE)[1]
    if going_left
        for i = 1:num_train
            if rid == num_sites
                RE[num_sites,i] = right_site_new * conj(product_states[i].pstate[rid])
            else
                RE[rid,i] = RE[rid+1,i] * right_site_new * conj(product_states[i].pstate[rid])
            end
        end

    else
        # going right
        for i = 1:num_train
            if lid == 1
                LE[1,i] = left_site_new * conj(product_states[i].pstate[lid])
            else
                LE[lid,i] = LE[lid-1,i] * conj(product_states[i].pstate[lid]) * left_site_new
            end
        end
    end

end

function fitMPS(path::String; id::String="W", opts::Options=Options())
    W_old, training_states, validation_states, testing_states = loadMPS_tests(path; id=id, dtype=opts.dtype)

    return W_old, fitMPS(W_old, training_states, validation_states, testing_states; opts=opts)...
end


function fitMPS(W::MPS, X_train::Matrix, y_train::Vector, X_val::Matrix, y_val::Vector, X_test, y_test; opts::Options=Options())

    dtype=opts.dtype
    # first, create the site indices for the MPS and product states 
    sites = get_siteinds(W)

    # now let's handle the training/validation/testing data
    # rescale using a robust sigmoid transform
    scaler = fit_scaler(RobustSigmoidTransform, X_train; positive=true);
    X_train_scaled = transform_data(scaler, X_train)
    X_val_scaled = transform_data(scaler, X_val)
    X_test_scaled = transform_data(scaler, X_test)

    # generate product states using rescaled data
    
    training_states = generate_all_product_states(X_train_scaled, y_train, "train", sites; dtype=dtype)
    validation_states = generate_all_product_states(X_val_scaled, y_val, "valid", sites; dtype=dtype)
    testing_states = generate_all_product_states(X_test_scaled, y_test, "test", sites; dtype=dtype)

    # generate the starting MPS with unfirom bond dimension chi_init and random values (with seed if provided)
    num_classes = length(unique(y_train))
    _, l_index = find_label(W)

    @assert num_classes == ITensors.dim(l_index) "Number of Classes in the training data doesn't match the dimension of the label index!"

    return fitMPS(W, training_states, validation_states, testing_states; opts=opts)
end


function fitMPS(X_train::Matrix, y_train::Vector, X_val::Matrix, y_val::Vector, X_test, y_test; random_state=nothing, chi_init=4, opts::Options=Options())

    dtype = opts.dtype
    # first, create the site indices for the MPS and product states 
    num_mps_sites = size(X_train)[2]
    sites = siteinds("S=1/2", num_mps_sites)
    


    # now let's handle the training/validation/testing data
    # rescale using a robust sigmoid transform
    scaler = fit_scaler(RobustSigmoidTransform, X_train; positive=true);
    X_train_scaled = transform_data(scaler, X_train)
    X_val_scaled = transform_data(scaler, X_val)
    X_test_scaled = transform_data(scaler, X_test)

    # generate product states using rescaled data
    
    training_states = generate_all_product_states(X_train_scaled, y_train, "train", sites; dtype=dtype)
    validation_states = generate_all_product_states(X_val_scaled, y_val, "valid", sites; dtype=dtype)
    testing_states = generate_all_product_states(X_test_scaled, y_test, "test", sites; dtype=dtype)

    # generate the starting MPS with unfirom bond dimension chi_init and random values (with seed if provided)
    num_classes = length(unique(y_train))
    #println("Using χ_init=$chi_init")
    W = generate_startingMPS(chi_init, sites; num_classes=num_classes, random_state=random_state, dtype=dtype)

    return fitMPS(W, training_states, validation_states, testing_states; opts=opts)
end




function fitMPS(W::MPS, training_states::timeSeriesIterable, validation_states::timeSeriesIterable, testing_states::timeSeriesIterable; 
     opts::Options=Options()) # optimise bond tensor)

    @unpack_Options opts # unpacks the attributes of opts into the local namespace

    println("Using $update_iters iterations per update.")
    # construct initial caches
    LE, RE = construct_caches(W, training_states; going_left=true, dtype=dtype)

    # compute initial training and validation acc/loss
    init_train_loss, init_train_acc = MSE_loss_acc(W, training_states)
    init_val_loss, init_val_acc = MSE_loss_acc(W, validation_states)
    init_test_loss, init_test_acc = MSE_loss_acc(W, testing_states)

    train_KL_div = KL_div(W, training_states)
    val_KL_div = KL_div(W, validation_states)
    init_KL_div = KL_div(W, testing_states)
    sites = siteinds(W)

    # print loss and acc

    println("Validation MSE loss: $init_val_loss | Validation acc. $init_val_acc." )
    println("Training MSE loss: $init_train_loss | Training acc. $init_train_acc." )
    println("Testing MSE loss: $init_test_loss | Testing acc. $init_test_acc." )
    println("")
    println("Validation KL Divergence: $val_KL_div.")
    println("Training KL Divergence: $train_KL_div.")
    println("Test KL Divergence: $init_KL_div.")


    running_train_loss = init_train_loss
    running_val_loss = init_val_loss
    

    # create structures to store training information
    training_information = Dict(
        "train_loss" => Float64[],
        "train_acc" => Float64[],
        "val_loss" => Float64[],
        "val_acc" => Float64[],
        "test_loss" => Float64[],
        "test_acc" => Float64[],
        "time_taken" => Float64[], # sweep duration
        "train_KL_div" => Float64[],
        "test_KL_div" => Float64[],
        "val_KL_div" => Float64[]
    )

    push!(training_information["train_loss"], init_train_loss)
    push!(training_information["train_acc"], init_train_acc)
    push!(training_information["val_loss"], init_val_loss)
    push!(training_information["val_acc"], init_val_acc)
    push!(training_information["test_loss"], init_test_loss)
    push!(training_information["test_acc"], init_test_acc)
    push!(training_information["train_KL_div"], train_KL_div)
    push!(training_information["val_KL_div"], val_KL_div)
    push!(training_information["test_KL_div"], init_KL_div)


    # initialising loss algorithms
    if typeof(lg_iter) <: AbstractArray
        @assert length(lg_iter) == nsweeps "lg_iter(::MPS,::PState)::(loss,grad) must be a loss function or an array of loss functions with length nsweeps"
    elseif typeof(lg_iter) <: Function
        lg_iter = [lg_iter for _ in 1:nsweeps]
    else
        error("lg_iter(::MPS,::PState)::(loss,grad) must be a loss function or an array of loss functions with length nsweeps")
    end

    if typeof(bbopt) <: AbstractArray
        @assert length(bbopt) == nsweeps "bbopt must be an optimiser or an array of optimisers to use with length nsweeps"
    elseif typeof(bbopt) <: BBOpt
        bbopt = [bbopt for _ in 1:nsweeps]
    else
        error("bbopt must be an optimiser or an array of optimisers to use with length nsweeps")
    end
    # start the sweep
    for itS = 1:nsweeps
        
        start = time()
        println("Using optimiser $(bbopt[itS].name) with the \"$(bbopt[itS].fl)\" algorithm")
        println("Starting backward sweeep: [$itS/$nsweeps]")

        for j = (length(sites)-1):-1:1
            #print("Bond $j")
            # j tracks the LEFT site in the bond tensor (irrespective of sweep direction)
            BT = W[j] * W[(j+1)] # create bond tensor
            BT_new = apply_update(BT, LE, RE, j, (j+1), training_states; iters=update_iters, verbosity=verbosity, 
                                    dtype=dtype, lg_iter=lg_iter[itS], bbopt=bbopt[itS],
                                    track_cost=track_cost, eta=eta, rescale = rescale) # optimise bond tensor

            # decompose the bond tensor using SVD and truncate according to chi_max and cutoff
            lsn, rsn = decomposeBT(BT_new, j, (j+1); chi_max=chi_max, cutoff=cutoff, going_left=true, dtype=dtype)
                
            # update the caches to reflect the new tensors
            update_caches!(lsn, rsn, LE, RE, j, (j+1), training_states; going_left=true)
            # place the updated sites back into the MPS
            W[j] = lsn
            W[(j+1)] = rsn
        end
    
        # add time taken for backward sweep.
        println("Backward sweep finished.")
        
        # finished a full backward sweep, reset the caches and start again
        # this can be simplified dramatically, only need to reset the LE
        LE, RE = construct_caches(W, training_states; going_left=false)
        
        println("Starting forward sweep: [$itS/$nsweeps]")

        for j = 1:(length(sites)-1)
            #print("Bond $j")
            BT = W[j] * W[(j+1)]
            BT_new = apply_update(BT, LE, RE, j, (j+1), training_states; iters=update_iters, verbosity=verbosity, 
                                    dtype=dtype, lg_iter=lg_iter[itS], bbopt=bbopt[itS],
                                    track_cost=track_cost, eta=eta, rescale=rescale) # optimise bond tensor

            lsn, rsn = decomposeBT(BT_new, j, (j+1); chi_max=chi_max, cutoff=cutoff, going_left=false, dtype=dtype)
            update_caches!(lsn, rsn, LE, RE, j, (j+1), training_states; going_left=false)
            W[j] = lsn
            W[(j+1)] = rsn
        end

        LE, RE = construct_caches(W, training_states; going_left=true)
        
        finish = time()

        time_elapsed = finish - start
        
        # add time taken for full sweep 
        println("Finished sweep $itS.")

        # compute the loss and acc on both training and validation sets
        train_loss, train_acc = MSE_loss_acc(W, training_states)
        val_loss, val_acc = MSE_loss_acc(W, validation_states)
        test_loss, test_acc = MSE_loss_acc(W, testing_states)
        train_KL_div = KL_div(W, training_states)
        val_KL_div = KL_div(W, validation_states)
        test_KL_div = KL_div(W, testing_states)

        # dot_errs = test_dot(W, testing_states)

        # if !isempty(dot_errs)
        #     @warn "Found mismatching values between inner() and MPS_contract at Sites: $dot_errs"
        # end
        println("Validation MSE loss: $val_loss | Validation acc. $val_acc." )
        println("Training MSE loss: $train_loss | Training acc. $train_acc." )
        println("Testing MSE loss: $test_loss | Testing acc. $test_acc." )
        println("")
        println("Validation KL Divergence: $val_KL_div.")
        println("Training KL Divergence: $train_KL_div.")
        println("Test KL Divergence: $test_KL_div.")

        running_train_loss = train_loss
        running_val_loss = val_loss

        push!(training_information["train_loss"], train_loss)
        push!(training_information["train_acc"], train_acc)
        push!(training_information["val_loss"], val_loss)
        push!(training_information["val_acc"], val_acc)
        push!(training_information["test_loss"], test_loss)
        push!(training_information["test_acc"], test_acc)
        push!(training_information["time_taken"], time_elapsed)
        push!(training_information["train_KL_div"], train_KL_div)
        push!(training_information["val_KL_div"], val_KL_div)
        push!(training_information["test_KL_div"], test_KL_div)
       
    end
    normalize!(W)
    println("\nMPS normalised!\n")
    # compute the loss and acc on both training and validation sets post normalisation
    train_loss, train_acc = MSE_loss_acc(W, training_states)
    val_loss, val_acc = MSE_loss_acc(W, validation_states)
    test_loss, test_acc = MSE_loss_acc(W, testing_states)
    train_KL_div = KL_div(W, training_states)
    val_KL_div = KL_div(W, validation_states)
    test_KL_div = KL_div(W, testing_states)


    println("Validation MSE loss: $val_loss | Validation acc. $val_acc." )
    println("Training MSE loss: $train_loss | Training acc. $train_acc." )
    println("Testing MSE loss: $test_loss | Testing acc. $test_acc." )
    println("")
    println("Validation KL Divergence: $val_KL_div.")
    println("Training KL Divergence: $train_KL_div.")
    println("Test KL Divergence: $test_KL_div.")

    running_train_loss = train_loss
    running_val_loss = val_loss

    push!(training_information["train_loss"], train_loss)
    push!(training_information["train_acc"], train_acc)
    push!(training_information["val_loss"], val_loss)
    push!(training_information["val_acc"], val_acc)
    push!(training_information["test_loss"], test_loss)
    push!(training_information["test_acc"], test_acc)
    push!(training_information["time_taken"], training_information["time_taken"][end]) # no time has passed
    push!(training_information["train_KL_div"], train_KL_div)
    push!(training_information["val_KL_div"], val_KL_div)
    push!(training_information["test_KL_div"], test_KL_div)
   
    return W, training_information, training_states, testing_states

end



(X_train, y_train), (X_val, y_val), (X_test, y_test) = load_splits_txt("MPS_MSE/datasets/ECG_train.txt", 
   "MPS_MSE/datasets/ECG_val.txt", "MPS_MSE/datasets/ECG_test.txt")

X_train_final = vcat(X_train, X_val)
y_train_final = vcat(y_train, y_val)


setprecision(BigFloat, 128)
Rdtype = Float64

lg_iters = [KLD_iter, KLD_iter, KLD_iter, 
            MSE_iter, MSE_iter, MSE_iter, MSE_iter, MSE_iter,
            KLD_iter, KLD_iter, KLD_iter, KLD_iter, KLD_iter]

bbopts = [BBOpt("CustomGD"), BBOpt("CustomGD"), BBOpt("CustomGD"),
          BBOpt("Optim"), BBOpt("Optim"), BBOpt("Optim"), BBOpt("Optim"), BBOpt("Optim"),
          BBOpt("CustomGD"), BBOpt("CustomGD"), BBOpt("CustomGD"), BBOpt("CustomGD"), BBOpt("CustomGD")]
nsweeps =  length(lg_iters)
verbosity = 0


opts=Options(; nsweeps=20, chi_max=20,  update_iters=9, verbosity=verbosity, dtype=Complex{Rdtype}, lg_iter=( (args...) -> mixed_iter(args...;alpha=10)), 
                bbopt=BBOpt("CustomGD"), track_cost=true, eta=0.01, rescale = [false, true])


# opts=Options(; nsweeps=5, chi_max=20,  update_iters=9, verbosity=verbosity, dtype=Complex{Rdtype}, lg_iter= ( (args...) -> mixed_iter(args...;alpha=5)), 
# bbopt=BBOpt("Optim"), track_cost=true, eta=0.01, rescale = [false, true])
opts=Options(; nsweeps=5, chi_max=13,  update_iters=1, verbosity=verbosity, dtype=Complex{Rdtype}, lg_iter=KLD_iter, 
bbopt=BBOpt("CustomGD"), track_cost=false, eta=0.2, rescale = [false, true])

# n_samples = 30
# ts_length = 100
# (X_train, y_train), (X_test, y_test) = generate_toy_timeseries(n_samples, ts_length) 
# X_val = X_test
# y_val = y_test

W, info, train_states, test_states = fitMPS(X_train, y_train, X_val, y_val, X_test, y_test; random_state=456, chi_init=4, opts=opts)


# saveMPS(W, "LogLoss/saved/loglossout.h5")

# summary = get_training_summary(W, train_states, test_states)


# plot_training_summary(info)
#saveMPS(W, "LogLoss/saved/loglossout.h5")

#plot_training_summary(info)

println("Test Loss: $(info["test_loss"]) | $(minimum(info["test_loss"][2:end-1]))")
println("Test KL Divergence: $(info["train_KL_div"]) | $(minimum(info["train_KL_div"][2:end-1]))")
println("Test KL Divergence: $(info["test_KL_div"]) | $(minimum(info["test_KL_div"][2:end-1]))")
println("Time taken: $(info["time_taken"]) | $(mean(info["time_taken"][2:end-1]))")
println("Accs: $(info["test_acc"]) | $(maximum(info["test_acc"][2:end-1]))")

