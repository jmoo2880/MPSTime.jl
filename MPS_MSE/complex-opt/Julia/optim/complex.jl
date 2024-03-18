using ITensors
using Optim
using Folds
using Distributions
using LinearAlgebra: dot
include("utils.jl")


struct PState
    """Create a custom structure to store product state objects, 
    along with their associated label and type (i.e, train, test or valid)"""
    pstate::MPS
    label::Int
    id::Int
end

function complex_feature_map(x::Float64)
    s1 = exp(1im * (3π/2) * x) * cospi(0.5 * x)
    s2 = exp(-1im * (2π/2) * x) * sinpi(0.5 * x)
    return [s1, s2]
end

function sample_to_product_state(ts::Vector, site_inds::Vector{Index{Int64}})
    """Convert a SINGLE time series (ts) to a product state (mps)"""
    n_sites = length(site_inds)
    product_state = MPS(n_sites)
    for site in 1:n_sites
        # loop over each site, create an itensor and fill with encoded values
        T = ITensor(ComplexF64, site_inds[site])
        zero_state, one_state = complex_feature_map(ts[site])
        T[1] = zero_state
        T[2] = one_state
        product_state[site] = T
    end

    return product_state

end

function dataset_to_product_state(ts_dataset::Matrix, ts_labels::Vector{Int}, site_inds::Vector{Index{Int64}})
    """Convert ALL time series (ts) in a dataset to a vector of
    PStates"""
    dataset_shape = size(ts_dataset)

    all_product_states = Vector{PState}(undef, dataset_shape[1])
    for p in 1:length(all_product_states)
        time_series_as_product_state = sample_to_product_state(ts_dataset[p, :], site_inds)
        time_series_label = ts_labels[p]
        product_state = PState(time_series_as_product_state, time_series_label, p)
        all_product_states[p] = product_state
    end

    return all_product_states
end

function flatten_bond_tensor(B::ITensor)
    """Function to flatten an ITensor so that it can be fed into Optim
    as a vector. Returns flattened tensor as a high dimensional 
    vector as well as the corresponding indices for reconstruction. """
    flattened_tensor = collect(Iterators.flatten(B))
    bond_tensor_indices = inds(B)

    return flattened_tensor, bond_tensor_indices

end

function reconstruct_bond_tensor(bond_tensor_flattened::Vector, bond_tensor_indices)
    """Function to reconstruct an ITensor, given a high dimensional vector
    and ITensor indices."""
    # check that the dimensions match up
    dim_flattened_tensor = length(bond_tensor_flattened)
    dim_indices = 1
    for i in bond_tensor_indices
        dim_indices *= i.space
    end
    @assert dim_indices == dim_flattened_tensor "Dimensions of flattened tensor do not match indices."
    BT = ITensor(bond_tensor_indices)
    for (n, val) in enumerate(bond_tensor_flattened)
        BT[n] = val
    end

    return BT
end

function construct_caches(mps::MPS, training_product_states::Vector{PState}; going_left=true)
    """Function to pre-allocate tensor contractions between the MPS and the product states.
    LE stores the left environment, i.e. all accumulate contractions from site 1 to site N
    RE stores the right env., all contractions from site N to site 1."""

    # get the number of training samples to pre-allocated caches
    n_train = length(training_product_states)
    n = length(mps)
    # make the caches
    LE = Matrix{ITensor}(undef, n_train, n)
    RE = Matrix{ITensor}(undef, n_train, n)

    for i in 1:n_train 
        # get the product state for the current training sample
        ps = training_product_states[i].pstate

        if going_left
            # initialise the first contraction
            LE[i, 1] = mps[1] * ps[1]
            for j in 2:n
                LE[i, j] = LE[i, j-1] * ps[j] * mps[j]
            end
            
        else
            # going right
            RE[i, n] = ps[n] * mps[n]
            # accumulate remaining sites
            for j in n-1:-1:1
                RE[i, j] = RE[i, j+1] * ps[j] * mps[j]
            end
        end
    end

    return LE, RE

end

function loss_and_correct_per_sample(mps::MPS, product_state::PState)
    """Compute the loss for a single product state and the corresponding
    prediction. To be used with multi-threading/folds. Combine loss and
    accuracy into a single function to eliminate redundant calculations."""
    ps = product_state.pstate
    y = product_state.label # ground truth label

    yhat = 1
    num_sites = length(mps)
    # start at the terminal site and contract backwards
    for site = num_sites:-1:1
        yhat *= mps[site] * ps[site]
    end
    abs_diff_sq = norm(yhat[] - y)^2
    loss = 0.5 * abs_diff_sq

    # compare prediction to label, return 1 if correct else return 0
    pred = abs(yhat[])
    # ternery operator because i'm edgy and a Julian
    correct = (pred < 0.5 ? 0 : 1) == y ? 1.0 : 0.0

    return [loss, correct]

end

function loss_and_acc_batch(mps::MPS, pss::Vector{PState})
    """Function the loss and accuracy for an entire dataset of 
    product states using multithreading."""
    # check whether the MPS is normalised.
    if !isapprox(norm(mps), 1.0; atol=1e-2) @warn "MPS is not normalised!" end

    loss, acc = Folds.reduce(+, loss_and_correct_per_sample(mps, ps) for ps in pss)

    mean_loss = loss/length(pss)
    mean_acc = acc/length(pss)

    return mean_loss, mean_acc

end

function contract_mps_and_product_state(mps::MPS, product_state::PState)
    """Function to get the raw overlap for a single sample (for inspection).
    Returns a complex value"""
    if !isapprox(norm(mps), 1.0; atol=1e-2) @warn "MPS is not normalised!" end
    ps = product_state.pstate
    @assert length(mps) == length(ps) "Length of MPS does not match product state!"

    overlap = 1
    num_sites = length(mps)
    for site in num_sites:-1:1
        overlap *= mps[site] * ps[site]
    end

    return overlap[]

end

function get_overlaps_dataset(mps::MPS, pss::Vector{PState})
    # ASSUMES BINARY CLASSIFIER WITH CLASS 0 AND CLASS 1
    """Just print the stats, doesn't return anything"""
    overlaps_class_0 = []
    overlaps_class_1 = []

    for ps in pss
        class = ps.label
        raw_overlap = contract_mps_and_product_state(mps, ps)
        real_overlap = abs(raw_overlap)
        if class == 0
            push!(overlaps_class_0, real_overlap)
        else
            push!(overlaps_class_1, real_overlap)
        end
    end

    # get class-wise max/min/median
    c0_max, c0_min, c0_med = maximum(overlaps_class_0), minimum(overlaps_class_0), median(overlaps_class_0)
    c1_max, c1_min, c1_med = maximum(overlaps_class_1), minimum(overlaps_class_1), median(overlaps_class_1)

    results = "Class ⟨0|ψ⟩ -> Max: $c0_max \t Min: $c0_min \t Median: $c0_med" * "\n"
    results *= "Class ⟨1|ψ⟩ -> Max: $c1_max \t Min: $c1_min \t Median: $c1_med"
    println(results)


    return results

end

# write some diagnostic functions to inspect properties of the 
# MPS to see what's going on during training
function inspect_mps_site(mps::MPS, site_loc::Int)
    """Choose an MPS site and inspect its properties
    either during training, before or after."""
    @assert 0 < site_loc < length(mps) "Invalid site location."
    soi = mps[site_loc] # site of interest
    # flatten the tensor for inspection
    soi_flat = collect(Iterators.flatten(B))

    # properties to track: l1 norm, l2 norm, maximum value, minimum value
    # get l1 norm - ∑|w_i|
end


function loss_and_grad_flattened_bond_tensor_single(B_flattened::Vector, B_inds::Any, product_state::PState, 
    LE::Matrix, RE::Matrix, lid::Int, rid::Int)
    """Compute the loss and gradient for a flattened bond tensor and single product state.
    Intended for multithreading, hence the `single' to distinguish it from `batch'."""

    B = reconstruct_bond_tensor(B_flattened, B_inds)
    ps = product_state.pstate
    ps_id = product_state.id
    y = product_state.label
    n = size(LE, 2) # infer mps length from LE cache
    phi_tilde = ps[lid] * ps[rid]

    if lid == 1
        # LE does not exist
        phi_tilde *= RE[ps_id, rid+1]
    elseif rid == n
        # RE does not exist
        phi_tilde *= LE[ps_id, lid-1]
    else
        phit_tilde *= LE[ps_id, lid-1] * RE[ps_id, rid+1]
    end

    yhat = B * phi_tilde
    dP = yhat[] - y
    abs_diff_sq = norm(dP)^2

    loss = 0.5 * abs_diff_sq

    grad = dP * conj(phi_tilde)

    return [loss, grad]

end

function loss_and_grad_flattened_bond_tensor_batch(B_flattened::Vector, B_inds::Any, pss::Vector{PState}, 
    LE::Matrix, RE::Matrix, lid::Int, rid::Int)
    """Compute the loss and gradient for a flattened bond tensor a batch of product states."""

    num_pstates = length(pss)

    loss, grad = Folds.reduce(+, loss_and_grad_flattened_bond_tensor_single(B_flattened, B_inds, ps, 
                                LE, RE, lid, rid) for ps in pss)

    loss_mean = loss / num_pstates
    grad_mean = grad ./ num_pstates

    return loss_mean, grad_mean

end

function fg!(F, G, B_flattened::Vector, B_inds::Any, pss::Vector{PState}, 
    LE::Matrix, RE::Matrix, lid::Int, rid::Int)

    B = reconstruct_bond_tensor(B_flattened, B_inds)

    function loss_and_grad_single(product_state::PState)
        ps = product_state.pstate
        ps_id = product_state.id
        y = product_state.label

        n = size(LE, 2) # infer mps length from LE cache

        phi_tilde = ps[lid] * ps[rid]

        if lid == 1
            # LE does not exist
            phi_tilde *= RE[ps_id, rid+1]
        elseif rid == n
            # RE does not exist
            phi_tilde *= LE[ps_id, lid-1]
        else
            phi_tilde *= LE[ps_id, lid-1] * RE[ps_id, rid+1]
        end

        yhat = B * phi_tilde
        dP = yhat[] - y
        abs_diff_sq = norm(dP)^2

        loss = 0.5 * abs_diff_sq
        grad = dP * conj(phi_tilde)

        return [loss, grad]

    end

    loss_sum, grad_sum = Folds.reduce(+, loss_and_grad_single(ps) for ps in pss)

    if G !== nothing
        G .= grad_sum ./ length(pss)
    end

    if F !== nothing
        value = loss_sum / length(pss)
        return value
    end

end

function optimise_bond_tensor(BT::ITensor, pss::Vector{PState}, LE::Matrix, RE::Matrix,
    lid::Int, rid::Int; verbose=true, maxiters=5, weights::MPS)
    """Handles all of the internal operations"""
    println("B_init norm: $(norm(BT))")
    # flatten bond tensor into a vector and get the indices
    bt_flat, bt_inds = flatten_bond_tensor(BT)
    # create anonymous function to feed into optim, function of bond tensor only
    fgcustom! = (F,G,B) -> fg!(F, G, B, bt_inds, pss, LE, RE, lid, rid)
    # set the optimisation manfiold
    # apply optim using specified gradient descent algorithm and corresp. paramters 
    # set the manifold to either flat, sphere or Stiefel 
    #manifold = MPS_Sphere(lid, rid, weights, bt_inds)
    manifold = Flat()#Sphere2()
    method = GradientDescent(; alphaguess = Optim.LineSearches.InitialHagerZhang(),
        linesearch = Optim.LineSearches.HagerZhang(), P = nothing, precondprep = (P, x) -> nothing, manifold = manifold)
    #method = Optim.LBFGS()
    res = optimize(Optim.only_fg!(fgcustom!), copy(bt_flat), method=method, iterations = maxiters, show_trace = verbose)
    result_flattened = Optim.minimizer(res)

    # delB = result_flattened - bt_flat
    # result_flattened = bt_flat + Optim.project_tangent!(Sphere2(), delB, bt_flat)
    # Optim.retract!(Sphere2(), result_flattened)

    result_as_ITensor = reconstruct_bond_tensor(result_flattened, bt_inds)

    println("B norm: $(norm(result_as_ITensor))")

    return result_as_ITensor

end

function decompose_bond_tensor(BT::ITensor, lid::Int; χ_max=nothing, cutoff=nothing, going_left=true)
    """Decompose an updated bond tensor back into two tensors using SVD"""
    left_site_index = findindex(BT, "n=$lid")
    #label_index = findindex(BT, "f(x)")
    if going_left
         # need to make sure the label index is transferred to the next site to be updated
         if lid == 1
            U, S, V = svd(BT, (left_site_index); maxdim=χ_max, cutoff=cutoff)
        else
            bond_index = findindex(BT, "Link,l=$(lid-1)")
            U, S, V = svd(BT, (left_site_index, bond_index); maxdim=χ_max, cutoff=cutoff)
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
            U, S, V = svd(BT, (left_site_index); maxdim=χ_max, cutoff=cutoff)
        else
            bond_index = findindex(BT, "Link,l=$(lid-1)")
            U, S, V = svd(BT, (left_site_index, bond_index); maxdim=χ_max, cutoff=cutoff)
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

function update_caches(left_site_new::ITensor, right_site_new::ITensor, 
    LE::Matrix, RE::Matrix, lid::Int, rid::Int, pss::Vector{PState}; going_left=true)
    """Given a newly updated bond tensor, update the caches."""
    num_train = length(pss)
    num_sites = size(LE)[2]
    if going_left
        for i = 1:num_train
            if rid == num_sites
                RE[i, num_sites] = right_site_new * pss[i].pstate[num_sites]
            else
                RE[i, rid] = RE[i, rid+1] * right_site_new * pss[i].pstate[rid]
            end
        end

    else
        # going right
        for i = 1:num_train
            if lid == 1
                LE[i, 1] = left_site_new * pss[i].pstate[lid]
            else
                LE[i, lid] = LE[i, lid-1] * pss[i].pstate[lid] * left_site_new
            end
        end
    end

    return LE, RE

end

function basic_sweep(num_sweeps::Int; χ_max::Int=10, cutoff=nothing, binary::Bool=true)

    Random.seed!(454)
    s = siteinds("S=1/2", 20)

    mps = randomMPS(ComplexF64, s; linkdims=4)
    # last_site = length(site_indices)
    orthogonalize!(mps, 1) # orthogonalise to first site

    Random.seed!(2896798)
    if binary
        samples, labels = generate_training_data(100, 20)
        all_pstates = dataset_to_product_state(samples, labels, s)
        samples_train, labels_train = generate_training_data(100, 20)
        all_pstates = dataset_to_product_state(samples_train, labels_train, s)

    else
        (X_train, y_train), (X_val, y_val), (X_test, y_test) = GenerateToyDataset(20, 100)
        scaler = fitScaler(RobustSigmoidTransform, X_train; positive=true);
        X_train_scaled = transformData(scaler, X_train)
        all_pstates = dataset_to_product_state(X_train_scaled, y_train, s)
    end

    @assert all(isapprox.([norm(ps.pstate) for ps in all_pstates], 1)) # input data encodings are correctly normalised

    #(X_train, y_train), (X_val, y_val), (X_test, y_test) = GenerateToyDataset(20, 100)
    #scaler = fitScaler(RobustSigmoidTransform, X_train; positive=true);
    #X_train_scaled = transformData(scaler, X_train)
    #X_test_scaled = transformData(scaler, X_test)

    #all_pstates = dataset_to_product_state(X_train_scaled, y_train, s)
    

    LE, RE = construct_caches(mps, all_pstates; going_left=false)

    init_loss, init_acc = loss_and_acc_batch(mps, all_pstates)

    loss_per_sweep = [init_loss]
    acc_per_sweep = [init_acc]
    norm_per_sweep = [norm(mps)]
    ovlap_per_sweep = [get_overlaps_dataset(mps, all_pstates)]

    for sweep in 1:num_sweeps
        for i = 1:length(mps) - 1
            BT = mps[i] * mps[(i+1)]
            BT_new = optimise_bond_tensor(BT, all_pstates, LE, RE, (i), (i+1); weights=mps)
            left_site_new, right_site_new = decompose_bond_tensor(BT_new, (i); χ_max=χ_max, cutoff=cutoff, going_left=false)
            LE, RE = update_caches(left_site_new, right_site_new, LE, RE, (i), (i+1), all_pstates; going_left=false)
            mps[i] = left_site_new
            mps[(i+1)] = right_site_new
        end

        LE, RE = construct_caches(mps, all_pstates; going_left=true)

        for j = (length(mps)-1):-1:1
            BT = mps[j] * mps[(j+1)]
            BT_new = optimise_bond_tensor(BT, all_pstates, LE, RE, (j), (j+1); weights=mps)
            left_site_new, right_site_new = decompose_bond_tensor(BT_new, (j); χ_max=χ_max, cutoff=cutoff, going_left=true)
            LE, RE = update_caches(left_site_new, right_site_new, LE, RE, (j), (j+1), all_pstates; going_left=true)
            mps[j] = left_site_new
            mps[(j+1)] = right_site_new
        end

        LE, RE = construct_caches(mps, all_pstates; going_left=false)
        loss_sweep, acc_sweep = loss_and_acc_batch(mps, all_pstates)
        push!(norm_per_sweep,norm(mps))
        push!(ovlap_per_sweep, get_overlaps_dataset(mps, all_pstates))

        push!(loss_per_sweep, loss_sweep)
        push!(acc_per_sweep, acc_sweep)

        println("Sweep $sweep finished. Loss: $loss_sweep | Acc: $acc_sweep.")

    end

    # test_loss, test_acc = loss_and_acc_batch(mps, all_test_pstates)
    #println("Final test acc: $test_acc | test loss: $test_loss")

    return mps, all_pstates, loss_per_sweep, acc_per_sweep, norm_per_sweep, ovlap_per_sweep

end


# BT_new = reconstruct_bond_tensor(flat_bt, bt_inds)
# s = siteinds("S=1/2", 5)
# mps = randomMPS(ComplexF64, s)
# samples, labels = generate_training_data(1000, 5)
# pstates = dataset_to_product_state(samples, labels, s)
# bt = mps[4] * mps[5]
# bt_flat, bt_inds = flatten_bond_tensor(bt)
# LE, RE = construct_caches(mps,pstates; going_left=true)
#loss_and_grad_flattened_bond_tensor_single(bt_flat, bt_inds, pstates[1], LE, RE, 1, 2)
#loss_and_grad_flattened_bond_tensor_batch(bt_flat, bt_inds, pstates, LE, RE, 1, 2)
#F_result = Vector{Float64}(undef, 1)  # Placeholder for loss
#G_result = similar(bt_flat)  # Placeholder for gradient
#fg!(F_result, G_result, bt_flat, bt_inds, pstates, LE, RE, 1, 2)
#test_fg!(bt_flat, bt_inds, pstates, LE, RE, 1, 2)
#fgnew! = make_fg!(bt_inds, pstates, LE, RE, 1, 2)
#optimClosure = createOptimClosure(bt_inds, pstates, LE, RE, 1, 2)
#fgnew! = (F,G,B) -> fg!(F, G, B, bt_inds, pstates, LE, RE, 1, 2)
#new_func! = optim_closure(bt_flat, bt_inds, pstates, LE, RE, 1, 2)

#@time Optim.optimize(Optim.only_fg!(fgnew!), bt_flat, Optim.ConjugateGradient())

# new_bt = optimise_bond_tensor(bt, pstates, LE, RE, 4, 5; maxiters=10, eta=0.9)

mps, all_pstates, loss_per_sweep, acc_per_sweep, norm_per_sweep, ovlap_per_sweep = basic_sweep(2; binary=true);

println("Accs: $acc_per_sweep")
println("Norms: $norm_per_sweep")
for ov in ovlap_per_sweep
    println(ov)
end