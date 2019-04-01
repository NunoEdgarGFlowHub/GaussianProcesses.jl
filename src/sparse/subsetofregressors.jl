#==========================================================
 Sparse Positive Definite Matrix for Subset of Regressors
===========================================================#
"""
    Subset of Regressors sparse positive definite matrix.
"""
mutable struct SubsetOfRegsPDMat{T,M<:AbstractMatrix,PD<:AbstractPDMat{T},M2<:AbstractMatrix{T}} <: SparsePDMat{T}
    inducing::M
    ΣQR_PD::PD
    Kuu::PD
    Kuf::M2
    logNoise::Float64
end
size(a::SubsetOfRegsPDMat) = (size(a.Kuf,2), size(a.Kuf,2))
size(a::SubsetOfRegsPDMat, d::Int) = size(a.Kuf,2)
"""
    We have
        Σ ≈ Kuf' Kuu⁻¹ Kuf + σ²I
    By Woodbury
        Σ⁻¹ = σ⁻²I - σ⁻⁴ Kuf'(Kuu + σ⁻² Kuf Kuf')⁻¹ Kuf
            = σ⁻²I - σ⁻⁴ Kuf'(       ΣQR        )⁻¹ Kuf
"""
function \(a::SubsetOfRegsPDMat, x)
    return exp(-2*a.logNoise)*x - exp(-4*a.logNoise)*a.Kuf'*(a.ΣQR_PD \ (a.Kuf * x))
end
logdet(a::SubsetOfRegsPDMat) = logdet(a.ΣQR_PD) - logdet(a.Kuu) + 2*a.logNoise*size(a,1)

function wrap_cK(cK::SubsetOfRegsPDMat, inducing, ΣQR_PD, Kuu, Kuf, logNoise::Scalar)
    wrap_cK(cK, inducing, ΣQR_PD, Kuu, Kuf, logNoise.value)
end
function wrap_cK(cK::SubsetOfRegsPDMat, inducing, ΣQR_PD, Kuu, Kuf, logNoise)
    SubsetOfRegsPDMat(inducing, ΣQR_PD, Kuu, Kuf, logNoise)
end
function LinearAlgebra.tr(a::SubsetOfRegsPDMat)
    exp(2*a.logNoise)*size(a.Kuf,2) + dot(a.Kuf, a.Kuu \ a.Kuf) # TODO: there may be a shortcut here
end

#========================================
 Subset of Regressors strategy
=========================================#

struct SubsetOfRegsStrategy{M<:AbstractMatrix} <: CovarianceStrategy
    inducing::M
end

function alloc_cK(covstrat::SubsetOfRegsStrategy, nobs)
    inducing = covstrat.inducing
    ninducing = size(inducing, 2)
    Kuu  = Matrix{Float64}(undef, ninducing, ninducing)
    chol_uu = Matrix{Float64}(undef, ninducing, ninducing)
    Kuu_PD = PDMats.PDMat(Kuu, Cholesky(chol_uu, 'U', 0))
    Kuf  = Matrix{Float64}(undef, ninducing, nobs)
    ΣQR  = Matrix{Float64}(undef, ninducing, ninducing)
    chol = Matrix{Float64}(undef, ninducing, ninducing)
    cK = SubsetOfRegsPDMat(inducing, 
                            PDMats.PDMat(ΣQR, Cholesky(chol, 'U', 0)), # ΣQR_PD
                            Kuu_PD, Kuf, 42.0)
    return cK
end
function update_cK!(cK::SubsetOfRegsPDMat, x::AbstractMatrix, kernel::Kernel, 
                    logNoise::Real, data::KernelData, covstrat::SubsetOfRegsStrategy)
    inducing = covstrat.inducing
    Kuu = cK.Kuu
    Kuubuffer = mat(Kuu)
    cov!(Kuubuffer, kernel, inducing)
    Kuubuffer, chol = make_posdef!(Kuubuffer, cholfactors(cK.Kuu))
    Kuu_PD = wrap_cK(cK.Kuu, Kuubuffer, chol)
    Kuf = cov!(cK.Kuf, kernel, inducing, x)
    Kfu = Kuf'
    
    ΣQR = exp(-2*logNoise) * Kuf * Kfu + Kuu
    LinearAlgebra.copytri!(ΣQR, 'U')
    
    ΣQR, chol = make_posdef!(ΣQR, cholfactors(cK.ΣQR_PD))
    ΣQR_PD = wrap_cK(cK.ΣQR_PD, ΣQR, chol)
    return wrap_cK(cK, inducing, ΣQR_PD, Kuu_PD, Kuf, logNoise)
end

#==========================================
  Log-likelihood gradients
===========================================#
struct SoRPrecompute <: AbstractGradientPrecompute
    Kuu⁻¹Kuf::Matrix{Float64}
    Kuu⁻¹KufΣ⁻¹y::Vector{Float64}
    Σ⁻¹Kfu::Matrix{Float64}
    ∂Kuu::Matrix{Float64} # buffer
    ∂Kfu::Matrix{Float64} # buffer
end
function SoRPrecompute(nobs::Int, ninducing::Int)
    Kuu⁻¹Kuf = Matrix{Float64}(undef, ninducing, nobs)
    Kuu⁻¹KufΣ⁻¹y =  Vector{Float64}(undef, ninducing)
    Σ⁻¹Kfu = Matrix{Float64}(undef, nobs, ninducing)
    ∂Kuu = Matrix{Float64}(undef, ninducing, ninducing)
    ∂Kfu = Matrix{Float64}(undef, nobs, ninducing)
    return SoRPrecompute(Kuu⁻¹Kuf, Kuu⁻¹KufΣ⁻¹y, Σ⁻¹Kfu, ∂Kuu, ∂Kfu)
end

function init_precompute(covstrat::SubsetOfRegsStrategy, X, y, k)
    nobs = size(X, 2)
    ninducing = size(covstrat.inducing, 2)
    SoRPrecompute(nobs, ninducing)
end
    
function precompute!(precomp::SoRPrecompute, gp::GPBase) 
    cK = gp.cK
    alpha = gp.alpha
    Kuf = cK.Kuf
    Kuu = cK.Kuu

    precomp.Kuu⁻¹Kuf[:,:] = Kuu \ Kuf # Kuu⁻¹Kuf 
    precomp.Kuu⁻¹KufΣ⁻¹y[:] = vec(Kuu \ (Kuf * alpha)) # Kuu⁻¹Kuf Σ⁻1 y appears repeatedly, so pre-compute
    precomp.Σ⁻¹Kfu[:,:] = cK \ (Kuf') # TODO: reduce memory allocations
    return precomp
end
function dmll_kern!(dmll::AbstractVector, gp::GPBase, precomp::SoRPrecompute, covstrat::SubsetOfRegsStrategy)
    return dmll_kern!(dmll, gp.kernel, gp.x, gp.cK, gp.data, gp.alpha, 
                      gp.cK.Kuu, gp.cK.Kuf,
                      precomp.Kuu⁻¹Kuf, precomp.Kuu⁻¹KufΣ⁻¹y, precomp.Σ⁻¹Kfu,
                      precomp.∂Kuu, precomp.∂Kfu,
                      covstrat)
end
"""
    dmll_noise(gp::GPE, precomp::SoRPrecompute)

∂logp(Y|θ) = 1/2 y' Σ⁻¹ ∂Σ Σ⁻¹ y - 1/2 tr(Σ⁻¹ ∂Σ)

∂Σ = I for derivative wrt σ², so
∂logp(Y|θ) = 1/2 y' Σ⁻¹ Σ⁻¹ y - 1/2 tr(Σ⁻¹)
            = 1/2[ dot(α,α) - tr(Σ⁻¹) ]

Σ⁻¹ = σ⁻²I - σ⁻⁴ Kuf'(Kuu + σ⁻² Kuf Kuf')⁻¹ Kuf
    = σ⁻²I - σ⁻⁴ Kuf'(       ΣQR        )⁻¹ Kuf
"""
function dmll_noise(gp::GPE, precomp::SoRPrecompute, covstrat::SubsetOfRegsStrategy)
    nobs = gp.nobs
    cK = gp.cK
    Lk = whiten(cK.ΣQR_PD, cK.Kuf)
    return exp(2*gp.logNoise) * (
        dot(gp.alpha, gp.alpha) 
        - exp(-2*gp.logNoise) * nobs
        + exp(-4*gp.logNoise)  * dot(Lk, Lk)
        )
end

"""
    dmll_kern!(dmll::AbstractVector, k::Kernel, X::AbstractMatrix, cK::SubsetOfRegsPDMat, data::KernelData, ααinvcKI::AbstractMatrix, covstrat::SubsetOfRegsStrategy)

Derivative of the log likelihood under the Subset of Regressors (SoR) approximation.

Helpful reference: Vanhatalo, Jarno, and Aki Vehtari. 
                   "Sparse log Gaussian processes via MCMC for spatial epidemiology." 
                   In Gaussian processes in practice, pp. 73-89. 2007.

Generally, for a multivariate normal with zero mean
    ∂logp(Y|θ) = 1/2 y' Σ⁻¹ ∂Σ Σ⁻¹ y - 1/2 tr(Σ⁻¹ ∂Σ)
                    ╰───────────────╯     ╰──────────╯
                           `V`                 `T`
                       
where Σ = Kff + σ²I.

Notation: `f` is the observations, `u` is the inducing points.
          ∂X stands for ∂X/∂θ, where θ is the kernel hyperparameters.

In the SoR approximation, we replace Kff with Qff = Kfu Kuu⁻¹ Kuf

∂Σ = ∂(Qff) = ∂(Kfu Kuu⁻¹ Kuf)
            = ∂(Kfu) Kuu⁻¹ Kuf + Kfu ∂(Kuu⁻¹) Kuf + Kfu Kuu⁻¹ ∂(Kuf)

∂(Kuu⁻¹) = -Kuu⁻¹ ∂(Kuu) Kuu⁻¹  --------^

Also have pre-computed α = Σ⁻¹ y, so `V` can now be computed 
efficiency (O(nm²) I think…) by careful ordering of the matrix multiplication steps.

"""
function dmll_kern!(dmll::AbstractVector, k::Kernel, X::AbstractMatrix, cK::AbstractPDMat, data::KernelData, 
                    alpha::AbstractVector, Kuu, Kuf, Kuu⁻¹Kuf, Kuu⁻¹KufΣ⁻¹y, Σ⁻¹Kfu, ∂Kuu, ∂Kfu,
                    covstrat::SubsetOfRegsStrategy)
    dim, nobs = size(X)
    inducing = covstrat.inducing
    ninducing = size(inducing, 2)
    nparams = num_params(k)
    @assert nparams == length(dmll)
    dK_buffer = Vector{Float64}(undef, nparams)
    dmll[:] .= 0.0
    for iparam in 1:nparams
        grad_slice!(∂Kuu, k, inducing, inducing, EmptyData(), iparam)
        grad_slice!(∂Kfu, k, X, inducing,        EmptyData(), iparam)
        V =  2 * dot(alpha, ∂Kfu * (Kuu⁻¹KufΣ⁻¹y))    # = 2 y' Σ⁻¹ ∂Kfu Kuu⁻¹ Kuf Σ⁻¹y
        V -= dot(Kuu⁻¹KufΣ⁻¹y, ∂Kuu * (Kuu⁻¹KufΣ⁻¹y)) # = y' Σ⁻¹ Kfu ∂(Kuu⁻¹) Kuf Σ⁻¹ y

        T = 2 * dot(cK \ ∂Kfu, Kuu⁻¹Kuf')              # = 2 tr(Kuu⁻¹ Kuf Σ⁻¹ ∂Kfu)
        T -=    dot(Σ⁻¹Kfu',  (Kuu \ ∂Kuu) * Kuu⁻¹Kuf) # = tr(Kuu⁻¹ Kuf Σ⁻¹ Kfu Kuu⁻¹ ∂Kuu)

        # # BELOW FOR DEBUG ONLY
        # ∂Σ = ∂Kfu * Kuu⁻¹Kuf
        # @inbounds for i in 1:nobs
            # ∂Σ[i,i] *= 2
            # for j in 1:(i-1)
                # s = ∂Σ[i,j] + ∂Σ[j,i]
                # ∂Σ[i,j] = s
                # ∂Σ[j,i] = s
            # end
        # end
        # ∂Σ -= Kuu⁻¹Kuf' * ∂Kuu * Kuu⁻¹Kuf
        # Valt = alpha'*∂Σ*alpha
        # Talt = tr(cK \ ∂Σ)
        # @show V, Valt
        # @show T, Talt
        # dmll_alt = dot(ααinvcKI, ∂Σ)/2
        # @show dmll_alt, dmll[iparam]
        # # ABOVE FOR DEBUG ONLY

        dmll[iparam] = (V-T)/2
    end
    return dmll
end

"""
    See Quiñonero-Candela and Rasmussen 2005, equations 16b.
    Some derivations can be found below that are not spelled out in the paper.

    Notation: Qab = Kau Kuu⁻¹ Kub
              ΣQR = Kuu + σ⁻² Kuf Kuf'

              x: prediction (test) locations
              f: training (observed) locations
              u: inducing point locations

    We have
        Σ ≈ Kuf' Kuu⁻¹ Kuf + σ²I
    By Woodbury
        Σ⁻¹ = σ⁻²I - σ⁻⁴ Kuf'(Kuu + σ⁻² Kuf Kuf')⁻¹ Kuf
            = σ⁻²I - σ⁻⁴ Kuf'(       ΣQR        )⁻¹ Kuf

    The predictive mean can be derived (assuming zero mean function for simplicity)
    μ = Qxf (Qff + σ²I)⁻¹ y
      = Kxu Kuu⁻¹ Kuf [σ⁻²I - σ⁻⁴ Kuf' ΣQR⁻¹ Kuf] y   # see Woodbury formula above.
      = σ⁻² Kxu Kuu⁻¹ [ΣQR - σ⁻² Kuf Kfu] ΣQR⁻¹ Kuf y # factoring out common terms
      = σ⁻² Kxu Kuu⁻¹ [Kuu] ΣQR⁻¹ Kuf y               # using definition of ΣQR
      = σ⁻² Kxu ΣQR⁻¹ Kuf y                           # matches equation 16b
    
    Similarly for the posterior predictive covariance:
    Σ = Qxx - Qxf (Qff + σ²I)⁻¹ Qxf'
      = Qxx - σ⁻² Kxu ΣQR⁻¹ Kuf Qxf'                # substituting result from μ
      = Qxx - σ⁻² Kxu ΣQR⁻¹  Kuf Kfu    Kuu⁻¹ Kux   # definition of Qxf
      = Qxx -     Kxu ΣQR⁻¹ (ΣQR - Kuu) Kuu⁻¹ Kux   # using definition of ΣQR
      = Qxx - Kxu Kuu⁻¹ Kux + Kxu ΣQR⁻¹ Kux         # expanding
      = Qxx - Qxx           + Kxu ΣQR⁻¹ Kux         # definition of Qxx
      = Kxu ΣQR⁻¹ Kux                               # simplifying
"""
function predictMVN(xpred::AbstractMatrix, xtrain::AbstractMatrix, ytrain::AbstractVector, 
                    kernel::Kernel, meanf::Mean, logNoise::Real,
                    alpha::AbstractVector,
                    covstrat::SubsetOfRegsStrategy, Ktrain::SubsetOfRegsPDMat)
    ΣQR_PD = Ktrain.ΣQR_PD
    inducing = covstrat.inducing
    Kuf = Ktrain.Kuf
    
    Kux = cov(kernel, inducing, xpred)
    
    meanx = mean(meanf, xpred)
    meanf = mean(meanf, xtrain)
    alpha_u = ΣQR_PD \ (Kuf * (ytrain-meanf))
    mupred = meanx + exp(-2*logNoise) * (Kux' * alpha_u)
    
    Lck = PDMats.whiten(ΣQR_PD, Kux)
    Σpred = Lck'Lck # Kux' * (ΣQR_PD \ Kux)
    LinearAlgebra.copytri!(Σpred, 'U')
    return mupred, Σpred
end


function SoR(x::AbstractMatrix, inducing::AbstractMatrix, y::AbstractVector, mean::Mean, kernel::Kernel, logNoise::Real)
    nobs = length(y)
    covstrat = SubsetOfRegsStrategy(inducing)
    cK = alloc_cK(covstrat, nobs)
    GPE(x, y, mean, kernel, logNoise, covstrat, EmptyData(), cK)
end

