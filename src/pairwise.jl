#===================================================================================================
  Generic pairwisematrix functions for kernels consuming two vectors
===================================================================================================#

# Row major and column major ordering are supported
MemoryOrder = Union{Type{Val{:col}},Type{Val{:row}}}

call{T}(f::RealFunction{T}, x::T, y::T) = pairwise(f, x, y)
call{T}(f::RealFunction{T}, x::AbstractArray{T}, y::AbstractArray{T}) = pairwise(f, x, y)

#================================================
  Generic Pairwise Matrix Operation
================================================#

function pairwise{T}(f::RealFunction{T}, x::AbstractArray{T}, y::AbstractArray{T})
    if (n = length(x)) != length(y)
        throw(DimensionMismatch("Arrays x and y must have the same length."))
    end
    n == 0 ? zero(T) : unsafe_pairwise(f, x, y)
end

for (order, dimension) in ((:(:row), 1), (:(:col), 2))
    isrowmajor = order == :(:row)
    @eval begin

        @inline function subvector(::Type{Val{$order}}, X::AbstractMatrix,  i::Integer)
            $(isrowmajor ? :(slice(X, i, :)) : :(slice(X, :, i)))
        end

        @inline function init_pairwisematrix{T}(
                 ::Type{Val{$order}},
                X::AbstractMatrix{T}
            )
            Array(T, size(X,$dimension), size(X,$dimension))
        end

        @inline function init_pairwisematrix{T}(
                 ::Type{Val{$order}},
                X::AbstractMatrix{T}, 
                Y::AbstractMatrix{T}
            )
            Array(T, size(X,$dimension), size(Y,$dimension))
        end

        function checkpairwisedimensions{T}(
                 ::Type{Val{$order}},
                P::Matrix{T}, 
                X::AbstractMatrix{T}
            )
            n = size(P,1)
            if size(P,2) != n
                throw(DimensionMismatch("Pernel matrix P must be square"))
            elseif size(X, $dimension) != n
                errorstring = string("Dimensions of P must match dimension ", $dimension, "of X")
                throw(DimensionMismatch(errorstring))
            end
            return n
        end

        function checkpairwisedimensions(
                 ::Type{Val{$order}},
                P::Matrix,
                X::AbstractMatrix, 
                Y::AbstractMatrix
            )
            n = size(X, $dimension)
            m = size(Y, $dimension)
            if n != size(P,1)
                errorstring = string("Dimension 1 of P must match dimension ", $dimension, "of X")
                throw(DimensionMismatch(errorstring))
            elseif m != size(P,2)
                errorstring = string("Dimension 2 of P must match dimension ", $dimension, "of Y")
                throw(DimensionMismatch(errorstring))
            end
            return (n, m)
        end

        function pairwisematrix!{T}(
                σ::Type{Val{$order}},
                P::Matrix{T}, 
                f::PairwiseFunction{T},
                X::AbstractMatrix{T},
                symmetrize::Bool
            )
            n = checkpairwisedimensions(σ, P, X)
            for j = 1:n
                xj = subvector(σ, X, j)
                for i = 1:j
                    xi = subvector(σ, X, i)
                    @inbounds P[i,j] = unsafe_pairwise(f, xi, xj)
                end
            end
            symmetrize ? LinAlg.copytri!(P, 'U', false) : P
        end

        function pairwisematrix!{T}(
                σ::Type{Val{$order}},
                P::Matrix{T}, 
                f::PairwiseFunction{T},
                X::AbstractMatrix{T},
                Y::AbstractMatrix{T},
            )
            n, m = checkpairwisedimensions(σ, P, X, Y)
            for j = 1:m
                yj = subvector(σ, Y, j)
                for i = 1:n
                    xi = subvector(σ, X, i)
                    @inbounds P[i,j] = unsafe_pairwise(f, xi, yj)
                end
            end
            P
        end
    end
end

function pairwisematrix{T}(
        σ::MemoryOrder,
        f::RealFunction{T}, 
        X::AbstractMatrix{T},
        symmetrize::Bool = true
    )
    pairwisematrix!(σ, init_pairwisematrix(σ, X), f, X, symmetrize)
end

function pairwisematrix{T}(
        f::RealFunction{T},
        X::AbstractMatrix{T},
        symmetrize::Bool = true
    )
    pairwisematrix(Val{:row}, f, X, symmetrize)
end

function pairwisematrix{T}(
        σ::MemoryOrder,
        f::RealFunction{T}, 
        X::AbstractMatrix{T},
        Y::AbstractMatrix{T}
    )
    pairwisematrix!(σ, init_pairwisematrix(σ, X, Y), f, X, Y)
end

function pairwisematrix{T}(
        f::RealFunction{T},
        X::AbstractMatrix{T},
        Y::AbstractMatrix{T}
    )
    pairwisematrix(Val{:row}, f, X, Y)
end

# Identical definitions
kernel = pairwise
kernelmatrix  = pairwisematrix
kernelmatrix! = pairwisematrix!


#================================================
  PairwiseFunction Scalar/Vector Operation
================================================#

function pairwise{T}(f::PairwiseFunction{T}, x::T, y::T)
    pairwise_return(f, pairwise_aggregate(f, pairwise_initiate(f), x, y))
end

# No checks, assumes length(x) == length(y) >= 1
function unsafe_pairwise{T}(f::PairwiseFunction{T}, x::AbstractArray{T}, y::AbstractArray{T})
    s = pairwise_initiate(f)
    @simd for I in eachindex(x,y)
        @inbounds xi = x[I]
        @inbounds yi = y[I]
        s = pairwise_aggregate(f, s, xi, yi)
    end
    pairwise_return(f, s)
end


#================================================
  CompositeFunction Matrix Operation
================================================#

@inline function pairwise{T}(h::CompositeFunction{T}, x::T, y::T)
    composition(h.g, pairwise(h.f, x, y))
end

@inline function unsafe_pairwise{T}(
        h::CompositeFunction{T},
        x::AbstractArray{T},
        y::AbstractArray{T}
    )
    composition(h.g, unsafe_pairwise(h.f, x, y))
end

function rectangular_compose!{T}(g::CompositionClass{T}, P::AbstractMatrix{T})
    for i in eachindex(P)
        @inbounds P[i] = composition(g, P[i])
    end
    P
end

function symmetric_compose!{T}(g::CompositionClass{T}, P::AbstractMatrix{T}, symmetrize::Bool)
    if !((n = size(P,1)) == size(P,2))
        throw(DimensionMismatch("PairwiseFunction matrix must be square."))
    end
    for j = 1:n, i = (1:j)
        @inbounds P[i,j] = composition(g, P[i,j])
    end
    symmetrize ? LinAlg.copytri!(P, 'U') : P
end

function pairwisematrix!{T}(
        σ::MemoryOrder,
        P::Matrix{T}, 
        h::CompositeFunction{T},
        X::AbstractMatrix{T},
        symmetrize::Bool
    )
    pairwisematrix!(σ, P, h.f, X, false)
    symmetric_compose!(h.g, P, symmetrize)
end

function pairwisematrix!{T}(
        σ::MemoryOrder,
        P::Matrix{T}, 
        h::CompositeFunction{T},
        X::AbstractMatrix{T},
        Y::AbstractMatrix{T}
    )
    pairwisematrix!(σ, P, h.f, X, Y)
    rectangular_compose!(h.g, P)
end


#================================================
  PointwiseRealFunction Matrix Operation
================================================#

@inline pairwise{T}(h::AffineFunction{T}, x::T, y::T) = h.a*pairwise(h.f, x, y) + h.c

@inline function unsafe_pairwise{T}(
        h::AffineFunction{T},
        x::AbstractArray{T},
        y::AbstractArray{T}
    )
    h.a*unsafe_pairwise(h.f, x, y) + h.c
end

function rectangular_affine!{T}(P::AbstractMatrix{T}, a::T, c::T)
    for i in eachindex(P)
        @inbounds P[i] = a*P[i] + c
    end
    P
end

function symmetric_affine!{T}(P::AbstractMatrix{T}, a::T, c::T, symmetrize::Bool)
    if !((n = size(P,1)) == size(P,2))
        throw(DimensionMismatch("symmetric_affine! matrix must be square."))
    end
    for j = 1:n, i = (1:j)
        @inbounds P[i,j] = a*P[i,j] + c
    end
    symmetrize ? LinAlg.copytri!(P, 'U') : P
end

function pairwisematrix!{T}(
        σ::MemoryOrder,
        P::Matrix{T},
        h::AffineFunction{T},
        X::AbstractMatrix{T},
        symmetrize::Bool = true
    )
    pairwisematrix!(σ, P, h.f, X, false)
    symmetric_affine!(P, h.a.value, h.c.value, symmetrize)
end

function pairwisematrix!{T}(
        σ::MemoryOrder,
        P::Matrix{T},
        h::AffineFunction{T},
        X::AbstractMatrix{T},
        Y::AbstractMatrix{T}
    )
    pairwisematrix!(σ, P, h.f, X, Y)
    rectangular_affine!(P, h.a.value, h.c.value)
end

for (f_obj, scalar_op, identity, scalar) in (
        (:FunctionProduct, :*, :1, :a),
        (:FunctionSum,     :+, :0, :c)
    )
    @eval begin

        @inline function pairwise{T}(h::$f_obj{T}, x::T, y::T)
            $scalar_op(pairwise(h.f, x, y), pairwise(h.g, x, y), h.$scalar)
        end

        @inline function unsafe_pairwise{T}(
                h::$f_obj{T},
                x::AbstractArray{T},
                y::AbstractArray{T}
            )
            $scalar_op(unsafe_pairwise(h.f, x, y), unsafe_pairwise(h.g, x, y), h.$scalar)
        end

        function pairwisematrix!{T}(
                σ::MemoryOrder,
                P::Matrix{T},
                h::$f_obj{T},
                X::AbstractMatrix{T},
                symmetrize::Bool = true
            )
            pairwisematrix!(σ, P, h.f, X, false)
            broadcast!($scalar_op, P, P, pairwisematrix!(σ, similar(P), h.g, X, false))
            if h.$scalar != $identity
                broadcast!($scalar_op, P, h.$scalar)
            end
            symmetrize ? LinAlg.copytri!(P, 'U') : P
        end

        function pairwisematrix!{T}(
                σ::MemoryOrder,
                P::Matrix{T},
                h::$f_obj{T},
                X::AbstractMatrix{T},
                Y::AbstractMatrix{T}
            )
            pairwisematrix!(σ, P, h.f, X, Y)
            broadcast!($scalar_op, P, P, pairwisematrix!(σ, similar(P), h.g, X, Y))
            h.$scalar == $identity ? P : broadcast!($scalar_op, P, h.$scalar)
        end
    end
end


#================================================
  Centering matrix
================================================#

# Centralize a kernel matrix P
#=
function centerkernelmatrix!{T<:AbstractFloat}(P::Matrix{T})
    (n = size(P, 1)) == size(P, 2) || throw(DimensionMismatch("Pernel matrix must be square"))
    μ_row = zeros(T,n)
    μ = zero(T)
    @inbounds for j = 1:n
        @simd for i = 1:n
            μ_row[j] += P[i,j]
        end
        μ += μ_row[j]
        μ_row[j] /= n
    end
    μ /= n^2
    @inbounds for j = 1:n
        @simd for i = 1:n
            P[i,j] += μ - μ_row[i] - μ_row[j]
        end
    end
    P
end
centerkernelmatrix{T<:AbstractFloat}(P::Matrix{T}) = centerkernelmatrix!(copy(P))
=#


#===================================================================================================
  ScalarProduct and SquaredDistance using BLAS/Built-In methods
===================================================================================================#

function squared_distance!{T<:AbstractFloat}(G::Matrix{T}, xᵀx::Vector{T}, symmetrize::Bool)
    if !((n = length(xᵀx)) == size(G,1) == size(G,2))
        throw(DimensionMismatch("Gramian matrix must be square."))
    end
    @inbounds for j = 1:n, i = (1:j)
        G[i,j] = xᵀx[i] - 2G[i,j] + xᵀx[j]
    end
    symmetrize ? LinAlg.copytri!(G, 'U') : G
end

function squared_distance!{T<:AbstractFloat}(G::Matrix{T}, xᵀx::Vector{T}, yᵀy::Vector{T})
    if size(G,1) != length(xᵀx)
        throw(DimensionMismatch("Length of xᵀx must match rows of G"))
    elseif size(G,2) != length(yᵀy)
        throw(DimensionMismatch("Length of yᵀy must match columns of G"))
    end
    @inbounds for I in CartesianRange(size(G))
        G[I] = xᵀx[I[1]] - 2G[I] + yᵀy[I[2]]
    end
    G
end

for (order, dimension) in ((:(:row), 1), (:(:col), 2))
    isrowmajor = order == :(:row)
    @eval begin

        function dotvectors!{T<:AbstractFloat}(
                 ::Type{Val{$order}},
                xᵀx::Vector{T},
                X::Matrix{T}
            )
            if !(size(X,$dimension) == length(xᵀx))
                errorstring = string("Dimension mismatch on dimension ", $dimension)
                throw(DimensionMismatch(errorstring))
            end
            fill!(xᵀx, zero(T))
            for I in CartesianRange(size(X))
                xᵀx[I.I[$dimension]] += X[I]^2
            end
            xᵀx
        end

        @inline function dotvectors{T<:AbstractFloat}(σ::Type{Val{$order}}, X::Matrix{T})
            dotvectors!(σ, Array(T, size(X,$dimension)), X)
        end

        function gramian!{T<:AbstractFloat}(
                 ::Type{Val{$order}},
                G::Matrix{T},
                X::Matrix{T},
                symmetrize::Bool
            )
            LinAlg.syrk_wrapper!(G, $(isrowmajor ? 'N' : 'T'), X)
            symmetrize ? LinAlg.copytri!(G, 'U') : G
        end

        @inline function gramian!{T<:AbstractFloat}(
                 ::Type{Val{$order}}, 
                G::Matrix{T}, 
                X::Matrix{T}, 
                Y::Matrix{T}
            )
            LinAlg.gemm_wrapper!(G, $(isrowmajor ? 'N' : 'T'), $(isrowmajor ? 'T' : 'N'), X, Y)
        end

        @inline function pairwisematrix!{T}(
                σ::Type{Val{$order}},
                P::Matrix{T}, 
                f::ScalarProduct{T},
                X::Matrix{T},
                symmetrize::Bool
            )
            gramian!(σ, P, X, symmetrize)
        end

        @inline function pairwisematrix!{T}(
                σ::Type{Val{$order}},
                P::Matrix{T}, 
                f::ScalarProduct{T},
                X::Matrix{T},
                Y::Matrix{T},
            )
            gramian!(σ, P, X, Y)
        end

        function pairwisematrix!{T}(
                σ::Type{Val{$order}},
                P::Matrix{T}, 
                f::SquaredEuclidean{T},
                X::Matrix{T},
                symmetrize::Bool
            )
            gramian!(σ, P, X, false)
            xᵀx = dotvectors(σ, X)
            squared_distance!(P, xᵀx, symmetrize)
        end

        function pairwisematrix!{T}(
                σ::Type{Val{$order}},
                P::Matrix{T}, 
                f::SquaredEuclidean{T},
                X::Matrix{T},
                Y::Matrix{T},
            )
            gramian!(σ, P, X, Y)
            xᵀx = dotvectors(σ, X)
            yᵀy = dotvectors(σ, Y)
            squared_distance!(P, xᵀx, yᵀy)
        end
    end
end
