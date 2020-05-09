using Turing: Tracker

function DiffEqBase._concrete_solve(prob::DiffEqBase.AbstractSteadyStateProblem,
    alg::DiffEqBase.DEAlgorithm, u0 = prob.u0, p = prob.p, args...; kwargs...)
    solve(remake(prob,u0 = u0, p = p), alg, args...; kwargs...)
end

function turing_inference(
    prob::DiffEqBase.DEProblem,
    alg,
    t,
    data,
    priors;
    likelihood_dist_priors = [InverseGamma(2, 3)],
    likelihood = (u,p,t,σ) -> MvNormal(u, σ[1]*ones(length(u))),
    num_samples=1000, sampler = Turing.NUTS(0.65),
    syms = [Turing.@varname(theta[i]) for i in 1:length(priors)],
    sample_u0 = false,
    save_idxs = nothing, 
    progress = false, 
    kwargs...,
)
    N = length(priors)
    Turing.@model mf(x, ::Type{T} = Float64) where {T <: Real} = begin
        theta = Vector{T}(undef, length(priors))
        for i in 1:length(priors)
            theta[i] ~ NamedDist(priors[i], syms[i])
        end
        σ = Vector{T}(undef, length(likelihood_dist_priors))
        for i in 1:length(likelihood_dist_priors)
            σ[i] ~ likelihood_dist_priors[i]
        end
        nu = save_idxs === nothing ? length(prob.u0) : length(save_idxs)
        u0 = convert.(T, sample_u0 ? theta[1:nu] : prob.u0)
        p = convert.(T, sample_u0 ? theta[(nu + 1):end] : theta)
        if length(u0) < length(prob.u0)
            # assumes u is ordered such that the observed variables are in the begining, consistent with ordered theta 
            for i in length(u0):length(prob.u0)
                push!(u0, convert(T,prob.u0[i]))
            end
        end
        _saveat = isnothing(t) ? Float64[] : t
        sol = concrete_solve(prob, alg, u0, p; saveat = _saveat, progress = progress, save_idxs = save_idxs, kwargs...)
        failure = size(sol, 2) < length(_saveat)

        if failure
            S = typeof(Turing.Inference.getlogp(_varinfo))
            Turing.Inference.acclogp!(_varinfo, S(-Inf))
            return
        end
        if ndims(sol) == 1
            x ~ likelihood(sol[:], theta, Inf, σ)
        else
            for i = 1:length(t)
                x[:, i] ~ likelihood(sol[:, i], theta, sol.t[i], σ)
            end
        end
        return
    end

    # Instantiate a Model object.
    model = mf(data)
    chn = sample(model, sampler, num_samples; progress = progress)
    return chn
end
