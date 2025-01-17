

struct PseudoBandedMatrix{T} <: AbstractMatrix{T}
    data::Array{T}
    l::Int
    u::Int
end

Base.size(A::PseudoBandedMatrix) = size(A.data)
function Base.getindex(A::PseudoBandedMatrix, j::Int, k::Int)
    l, u = bandwidths(A)
    if -l ≤ k-j ≤ u
        A.data[j, k]
    else
        zero(eltype(A.data))
    end
end
function Base.setindex!(A::PseudoBandedMatrix, v, j::Int, k::Int)
    l, u = bandwidths(A)
    if -l ≤ k-j ≤ u
        A.data[j, k] = v
    else
        error("out of band.")
    end
end

struct PseudoBandedLayout <: AbstractBandedLayout end
Base.BroadcastStyle(::Type{<:PseudoBandedMatrix}) = BandedStyle()
BandedMatrices.MemoryLayout(::Type{<:PseudoBandedMatrix}) = PseudoBandedLayout()
BandedMatrices.isbanded(::PseudoBandedMatrix) = true
BandedMatrices.bandwidths(A::PseudoBandedMatrix) = (A.l , A.u)
BandedMatrices.inbands_getindex(A::PseudoBandedMatrix, j::Int, k::Int) = A.data[j, k]
BandedMatrices.inbands_setindex!(A::PseudoBandedMatrix, v, j::Int, k::Int) = setindex!(A.data, v, j, k)
LinearAlgebra.fill!(A::PseudoBandedMatrix, v) = fill!(A.data,v)
ArrayLayouts.lmul!(β::Number, A::PseudoBandedMatrix) = (lmul!(β, A.data); A)
LinearAlgebra.lmul!(β::Number, A::PseudoBandedMatrix) = (lmul!(β, A.data); A)


@testset "Lazy Banded" begin
    @testset "Banded padded" begin
        A = _BandedMatrix((1:10)', 10, -1,1)
        x = Vcat(1:3, Zeros(10-3))
        @test MemoryLayout(x) isa PaddedLayout
        @test A*x isa Vcat{Float64,1,<:Tuple{<:Vector,<:Zeros}}
        @test length((A*x).args[1]) == length(x.args[1]) + bandwidth(A,1) == 2
        @test A*x == A*Vector(x)

        A = _BandedMatrix(randn(3,10), 10, 1,1)
        x = Vcat(randn(10), Zeros(0))
        @test A*x isa Vcat{Float64,1,<:Tuple{<:Vector,<:Zeros}}
        @test length((A*x).args[1]) == 10
        @test A*x ≈ A*Vector(x)

        A = Vcat(Zeros(1,10), brand(9,10,0,2))
        @test bandwidths(A) == (1,1)
        @test BandedMatrix(A) == Array(A) == A

        A = Hcat(Zeros(5,2), brand(5,5,1,1))
        @test bandwidths(A) == (-1,3)
        @test BandedMatrix(A) == Array(A) == A
    end

    @testset "BroadcastBanded * Padded" begin
        A = BroadcastArray(*, randn(5), brand(5,5,1,2))
        @test axes(A) == (Base.OneTo(5), Base.OneTo(5))
        B = BroadcastArray(*, randn(5,5), brand(5,5,1,2))
        b = Vcat(randn(2), Zeros(3))
        @test A*b ≈ Matrix(A)b
        @test B*b ≈ Matrix(B)b
    end

    @testset "Apply * Banded" begin
        B = brand(5,5,2,1)
        A = ApplyArray(*, B, B)
        @test A * Vcat([1,2], Zeros(3)) ≈ B*B*[1,2,0,0,0]
    end

    @testset "Banded Perturbed" begin
        n = 1000
        D = Diagonal(1:n)
        P = ApplyArray(hvcat, 2, randn(3,3), Zeros(3,n-3), Zeros(n-3,3), Zeros(n-3,n-3))
        @test isbanded(P)
        @test bandwidths(P) == (2,2)

        B = BroadcastArray(+, D, P)
        @test MemoryLayout(B) isa BroadcastBandedLayout
        @test bandwidths(B) == (2,2)

        B = BroadcastArray(+, P, D)
        @test MemoryLayout(B) isa BroadcastBandedLayout
        @test bandwidths(B) == (2,2)

        C = ApplyArray(hvcat, 2, 1, 2, 3, 4)
        @test bandwidths(C) == (1,1)
    end


    @testset "MulMatrix" begin

        @testset "MulBanded" begin
            A = brand(6,5,0,1)
            B = brand(5,5,1,0)

            M = ApplyArray(*, A)
            @test BandedMatrix(M) == copyto!(similar(A), M) == A

            M = ApplyArray(*,A,B)
            @test isbanded(M) && isbanded(Applied(M))
            @test bandwidths(M) == bandwidths(Applied(M))
            @test BandedMatrix(M) == A*B == copyto!(BandedMatrix(M), M)
            @test MemoryLayout(M) isa ApplyBandedLayout{typeof(*)}
            @test arguments(M) == (A,B)
            @test call(M) == *
            @test colsupport(M,1) == colsupport(Applied(M),1) == 1:2
            @test rowsupport(M,1) == rowsupport(Applied(M),1) == 1:2

            @test Base.BroadcastStyle(typeof(M)) isa LazyArrayStyle{2}
            @test M .+ A ≈ M .+ Matrix(A) ≈ Matrix(A) .+ M

            V = view(M,1:4,1:4)
            @test bandwidths(V) == (1,1)
            @test MemoryLayout(V) == MemoryLayout(M)
            @test M[1:4,1:4] isa BandedMatrix
            @test colsupport(V,1) == 1:2
            @test rowsupport(V,1) == 1:2

            @test MemoryLayout(view(M, [1,3], [2,3])) isa ApplyLayout{typeof(*)}

            A = brand(5,5,0,1)
            B = brand(6,5,1,0)
            @test_throws DimensionMismatch ApplyArray(*,A,B)

            A = brand(6,5,0,1)
            B = brand(5,5,1,0)
            C = brand(5,6,2,2)
            M = applied(*,A,B,C)
            @test @inferred(eltype(M)) == Float64
            @test bandwidths(M) == (3,3)
            @test M[1,1] ≈ (A*B*C)[1,1]

            M = @inferred(ApplyArray(*,A,B,C))
            @test @inferred(eltype(M)) == Float64
            @test bandwidths(M) == (3,3)
            @test BandedMatrix(M) ≈ A*B*C ≈ copyto!(BandedMatrix(M), M)

            M = ApplyArray(*, A, Zeros(5))
            @test colsupport(M,1) == colsupport(Applied(M),1)
            @test_skip colsupport(M,1) == 1:0

            @testset "inv" begin
                A = brand(6,5,0,1)
                B = brand(5,5,1,0)
                C = randn(6,2)
                M = ApplyArray(*,A,B)
                @test M \ C ≈ Matrix(M) \ C
            end

            @testset "Sym/Herm" begin
                A = brand(5,5,0,1)
                B = brand(5,5,1,0)
                M = ApplyArray(*,A,B)
                C = ApplyArray(*,A,im*B)
                @test MemoryLayout(Symmetric(M)) isa SymmetricLayout{LazyBandedLayout}
                @test MemoryLayout(Symmetric(C)) isa SymmetricLayout{LazyBandedLayout}
                @test MemoryLayout(Hermitian(M)) isa SymmetricLayout{LazyBandedLayout}
                @test MemoryLayout(Hermitian(C)) isa HermitianLayout{LazyBandedLayout}
            end
        end

        @testset "Pseudo Mul" begin
            A = PseudoBandedMatrix(rand(5, 4), 1, 2)
            B = PseudoBandedMatrix(rand(4, 4), 2, 3)
            C = PseudoBandedMatrix(zeros(5, 4), 3, 4)
            D = zeros(5, 4)

            @test (C .= applied(*, A, B)) ≈ (D .= applied(*, A, B)) ≈ A*B
        end
        @testset "MulStyle" begin
            A = brand(5,5,0,1)
            B = brand(5,5,1,0)
            C = BroadcastMatrix(*, A, 2)
            M = ApplyArray(*,A,B)
            @test M^2 isa BandedMatrix
            @test M*C isa ApplyMatrix{Float64,typeof(*)}
            @test C*M isa ApplyMatrix{Float64,typeof(*)}
        end
        @testset "Apply*Broadcast" begin
            A = randn(5,5)
            B = randn(5,5)
            C = brand(5,5,1,1)
            D = brand(5,5,1,1)
            @test ApplyArray(*, A, B) * BroadcastArray(*, A, B) ≈ (A*B) * (A .* B)
            @test ApplyArray(*, C, D) * BroadcastArray(*, A, B) ≈ (C*D) * (A .* B)
            @test ApplyArray(*, A, B) * BroadcastArray(*, C, D) ≈ (A*B) * (C .* D)
            @test BroadcastArray(*, A, B) * ApplyArray(*, A, B) ≈ (A .* B) * (A*B)
            @test BroadcastArray(*, C, D) * ApplyArray(*, A, B) ≈ (C .* D) * (A*B)
            @test BroadcastArray(*, A, B) * ApplyArray(*, C, D) ≈ (A .* B) * (C*D)

            @test ApplyArray(*, A, B) \ BroadcastArray(*, A, B) ≈ (A*B) \ (A .* B)
            @test BroadcastArray(*, A, B) \ ApplyArray(*, A, B) ≈ (A .* B) \ (A * B)
            @test BroadcastArray(*, A, B) \ BroadcastArray(*, A, B) ≈ (A .* B) \ (A .* B)
            @test BroadcastArray(*, C, D) \ BroadcastArray(*, C, D) ≈ (C .* D) \ (C .* D)
            @test ApplyArray(*, C, D) \ BroadcastArray(*, C, D) ≈ (C * D) \ (C .* D)
        end

        @testset "flatten" begin
            A = brand(5,5,1,1)
            B = brand(5,5,1,1)
            C = brand(5,5,1,1)
            @test LazyArrays.flatten(ApplyArray(*, A, ApplyArray(*, B, C))) ≈ A * B *C
        end
    end

    @testset "Eye simplifiable" begin
        A = Eye(5)
        B = brand(5,5,1,1)
        C = brand(5,5,1,1)
        D = Diagonal(Fill(2,5))
        @test simplifiable(*, A, BroadcastArray(*, B, C)) == Val(true)
        @test simplifiable(*, BroadcastArray(*, B, C), A) == Val(true)

        @test D * BroadcastArray(*, B, C) ≈ D * (B .* C)
        @test BroadcastArray(*, B, C) * D ≈ (B .* C) * D
    end

    @testset "InvMatrix" begin
        D = brand(5,5,0,0)
        L = brand(5,5,2,0)
        U = brand(5,5,0,2)
        B = brand(5,5,1,2)
    
        @test bandwidths(ApplyMatrix(inv,D)) == (0,0)
        @test bandwidths(ApplyMatrix(inv,L)) == (4,0)
        @test bandwidths(ApplyMatrix(inv,U)) == (0,4)
        @test bandwidths(ApplyMatrix(inv,B)) == (4,4)
    
        @test colsupport(ApplyMatrix(inv,D) ,3) == 3:3
        @test colsupport(ApplyMatrix(inv,L), 3) == 3:5
        @test colsupport(ApplyMatrix(inv,U), 3) == 1:3
        @test colsupport(ApplyMatrix(inv,B), 3) == 1:5
    
        @test rowsupport(ApplyMatrix(inv,D) ,3) == 3:3
        @test rowsupport(ApplyMatrix(inv,L), 3) == 1:3
        @test rowsupport(ApplyMatrix(inv,U), 3) == 3:5
        @test rowsupport(ApplyMatrix(inv,B), 3) == 1:5
    
        @test bandwidths(ApplyMatrix(\,D,B)) == (1,2)
        @test bandwidths(ApplyMatrix(\,L,B)) == (4,2)
        @test bandwidths(ApplyMatrix(\,U,B)) == (1,4)
        @test bandwidths(ApplyMatrix(\,B,B)) == (4,4)
    
        @test colsupport(ApplyMatrix(\,D,B), 3) == 1:4
        @test colsupport(ApplyMatrix(\,L,B), 4) == 2:5
        @test colsupport(ApplyMatrix(\,U,B), 3) == 1:4
        @test colsupport(ApplyMatrix(\,B,B), 3) == 1:5
    
        @test rowsupport(ApplyMatrix(\,D,B), 3) == 2:5
        @test rowsupport(ApplyMatrix(\,L,B), 2) == 1:4
        @test rowsupport(ApplyMatrix(\,U,B), 3) == 2:5
        @test rowsupport(ApplyMatrix(\,B,B), 3) == 1:5
    end
    
    @testset "Cat" begin
        A = brand(6,5,2,1)
        H = Hcat(A,A)
        @test H[1,1] == applied(hcat,A,A)[1,1] == A[1,1]
        @test isbanded(H)
        @test bandwidths(H) == (2,6)
        @test BandedMatrix(H) == BandedMatrix(H,(2,6)) == hcat(A,A) == hcat(A,Matrix(A)) == 
                hcat(Matrix(A),A) == hcat(Matrix(A),Matrix(A))
        @test hcat(A,A) isa BandedMatrix
        @test hcat(A,Matrix(A)) isa Matrix
        @test hcat(Matrix(A),A) isa Matrix
        @test isone.(H) isa BandedMatrix
        @test bandwidths(isone.(H)) == (2,6)
        @test @inferred(colsupport(H,1)) == 1:3
        @test Base.replace_in_print_matrix(H,4,1,"0") == "⋅"
    
        H = Hcat(A,A,A)
        @test isbanded(H)
        @test bandwidths(H) == (2,11)
        @test BandedMatrix(H) == hcat(A,A,A) == hcat(A,Matrix(A),A) == hcat(Matrix(A),A,A) == 
                hcat(Matrix(A),Matrix(A),A) == hcat(Matrix(A),Matrix(A),Matrix(A))
        @test hcat(A,A,A) isa BandedMatrix 
        @test isone.(H) isa BandedMatrix
        @test bandwidths(isone.(H)) == (2,11)
        
        V = Vcat(A,A)
        @test V isa VcatBandedMatrix
        @test isbanded(V)
        @test bandwidths(V) == (8,1)
        @test BandedMatrix(V) == vcat(A,A) == vcat(A,Matrix(A)) == vcat(Matrix(A),A) == vcat(Matrix(A),Matrix(A))
        @test vcat(A,A) isa BandedMatrix
        @test vcat(A,Matrix(A)) isa Matrix
        @test vcat(Matrix(A),A) isa Matrix
        @test isone.(V) isa BandedMatrix
        @test bandwidths(isone.(V)) == (8,1)
        @test Base.replace_in_print_matrix(V,1,3,"0") == "⋅"
    
        V = Vcat(A,A,A)
        @test bandwidths(V) == (14,1)
        @test BandedMatrix(V) == vcat(A,A,A) == vcat(A,Matrix(A),A) == vcat(Matrix(A),A,A) == 
                vcat(Matrix(A),Matrix(A),A) == vcat(Matrix(A),Matrix(A),Matrix(A))
        @test vcat(A,A,A) isa BandedMatrix 
        @test isone.(V) isa BandedMatrix
        @test bandwidths(isone.(V)) == (14,1)
    end

    @testset "BroadcastBanded" begin
        A = BroadcastMatrix(*, brand(5,5,1,2), brand(5,5,2,1))
        @test eltype(A) == Float64
        @test bandwidths(A) == (1,1)
        @test colsupport(A, 1) == 1:2
        @test rowsupport(A, 1) == 1:2
        @test A == broadcast(*, A.args...) == BandedMatrix(A)
        @test MemoryLayout(A) isa BroadcastBandedLayout{typeof(*)}

        @test MemoryLayout(A') isa BroadcastBandedLayout{typeof(*)}
        @test bandwidths(A') == (1,1)
        @test colsupport(A',1) == rowsupport(A', 1) == 1:2
        @test A' == BroadcastArray(A') == Array(A)' == BandedMatrix(A')

        V = view(A, 2:3, 3:5)
        @test MemoryLayout(V) isa BroadcastBandedLayout{typeof(*)}
        @test bandwidths(V) == (1,0)
        @test colsupport(V,1) == 1:2
        @test V == BroadcastArray(V) == Array(A)[2:3,3:5]
        @test bandwidths(view(A,2:4,3:5)) == (2,0)

        V = view(A, 2:3, 3:5)'
        @test MemoryLayout(V) isa BroadcastBandedLayout{typeof(*)}
        @test bandwidths(V) == (0,1)
        @test colsupport(V,1) == 1:1
        @test V == BroadcastArray(V) == Array(A)[2:3,3:5]'

        B = BroadcastMatrix(+, brand(5,5,1,2), 2)
        @test B == broadcast(+, B.args...)

        C = BroadcastMatrix(+, brand(5,5,1,2), brand(5,5,3,1))
        @test bandwidths(C) == (3,2)
        @test MemoryLayout(C) == BroadcastBandedLayout{typeof(+)}()
        @test isbanded(C) == true
        @test BandedMatrix(C) == C == copyto!(BandedMatrix(C), C)

        D = BroadcastMatrix(*, 2, brand(5,5,1,2))
        @test bandwidths(D) == (1,2)
        @test MemoryLayout(D) == BroadcastBandedLayout{typeof(*)}()
        @test isbanded(D) == true
        @test BandedMatrix(D) == D == copyto!(BandedMatrix(D), D) == 2*D.args[2]

        @testset "band" begin
            @test A[band(0)] == Matrix(A)[band(0)]
            @test B[band(0)] == Matrix(B)[band(0)]
            @test C[band(0)] == Matrix(C)[band(0)]
            @test D[band(0)] == Matrix(D)[band(0)]
        end

        @testset "non-simple" begin
            A = BroadcastMatrix(sin,brand(5,5,1,2))
            @test bandwidths(A) == (1,2)
            @test BandedMatrix(A) == Matrix(A) == A
        end

        @testset "Complex" begin
            C = BroadcastMatrix(*, 2, im*brand(5,5,2,1))
            @test MemoryLayout(C') isa ConjLayout{BroadcastBandedLayout{typeof(*)}}
        end
    end

    @testset "Cache" begin
        A = _BandedMatrix(Fill(1,3,10_000), 10_000, 1, 1)
        C = cache(A);
        @test C.data isa BandedMatrix{Int,Matrix{Int},Base.OneTo{Int}}
        @test colsupport(C,1) == rowsupport(C,1) == 1:2
        @test bandwidths(C) == bandwidths(A) == (1,1)
        @test isbanded(C) 
        resizedata!(C,1,1);
        @test C[1:10,1:10] == A[1:10,1:10]
        @test C[1:10,1:10] isa BandedMatrix
    end
    
    @testset "NaN Bug" begin
        C = BandedMatrix{Float64}(undef, (1,2), (0,2)); C.data .= NaN;
        A = brand(1,1,0,1)
        B = brand(1,2,0,2)
        C .= applied(*, A,B)
        @test C == A*B
    
        C.data .= NaN
        C .= @~ 1.0 * A*B + 0.0 * C
        @test C == A*B
    end
    
    @testset "Applied" begin
        A = brand(5,5,1,2)
        @test applied(*,Symmetric(A),A) isa Applied{MulStyle}
        B = apply(*,A,A,A)
        @test B isa BandedMatrix
        @test all(B .=== (A*A)*A)
        @test bandwidths(B) == (3,4)
    end
    
    @testset "QL tests" begin
        for T in (Float64,ComplexF64,Float32,ComplexF32)
            A=brand(T,10,10,3,2)
            Q,L=ql(A)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            @test Matrix(Q)*Matrix(L) ≈ A
            b=rand(T,10)
            @test mul!(similar(b),Q,mul!(similar(b),Q',b)) ≈ b
            for j=1:size(A,2)
                @test Q' * A[:,j] ≈ L[:,j]
            end
    
            A=brand(T,14,10,3,2)
            Q,L=ql(A)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            @test_broken Matrix(Q)*Matrix(L) ≈ A
    
            for k=1:size(A,1),j=1:size(A,2)
                @test Q[k,j] ≈ Matrix(Q)[k,j]
            end
    
            A=brand(T,10,14,3,2)
            Q,L=ql(A)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            @test Matrix(Q)*Matrix(L) ≈ A
    
            for k=1:size(Q,1),j=1:size(Q,2)
                @test Q[k,j] ≈ Matrix(Q)[k,j]
            end
    
            A=brand(T,10,14,3,6)
            Q,L=ql(A)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            @test Matrix(Q)*Matrix(L) ≈ A
    
            for k=1:size(Q,1),j=1:size(Q,2)
                @test Q[k,j] ≈ Matrix(Q)[k,j]
            end
    
            A=brand(T,100,100,3,4)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            b=rand(T,100)
            @test ql(A)\b ≈ Matrix(A)\b
            b=rand(T,100,2)
            @test ql(A)\b ≈ Matrix(A)\b
            @test_throws DimensionMismatch ql(A) \ randn(3)
            @test_throws DimensionMismatch ql(A).Q'randn(3)
    
            A=brand(T,102,100,3,4)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            b=rand(T,102)
            @test_broken ql(A)\b ≈ Matrix(A)\b
            b=rand(T,102,2)
            @test_broken ql(A)\b ≈ Matrix(A)\b
            @test_throws DimensionMismatch ql(A) \ randn(3)
            @test_throws DimensionMismatch ql(A).Q'randn(3)
    
            A=brand(T,100,102,3,4)
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            b=rand(T,100)
            @test_broken ql(A)\b ≈ Matrix(A)\b
    
            A = LinearAlgebra.Tridiagonal(randn(T,99), randn(T,100), randn(T,99))
            @test ql(A).factors ≈ ql!(Matrix(A)).factors
            @test ql(A).τ ≈ ql!(Matrix(A)).τ
            b=rand(T,100)
            @test ql(A)\b ≈ Matrix(A)\b
            b=rand(T,100,2)
            @test ql(A)\b ≈ Matrix(A)\b
            @test_throws DimensionMismatch ql(A) \ randn(3)
            @test_throws DimensionMismatch ql(A).Q'randn(3)
        end
    
        @testset "lmul!/rmul!" begin
            for T in (Float32, Float64, ComplexF32, ComplexF64)
                A = brand(T,100,100,3,4)
                Q,R = qr(A)
                x = randn(T,100)
                b = randn(T,100,2)
                @test lmul!(Q, copy(x)) ≈ Matrix(Q)*x
                @test lmul!(Q, copy(b)) ≈ Matrix(Q)*b
                @test lmul!(Q', copy(x)) ≈ Matrix(Q)'*x
                @test lmul!(Q', copy(b)) ≈ Matrix(Q)'*b
                c = randn(T,2,100)
                @test rmul!(copy(c), Q) ≈ c*Matrix(Q)
                @test rmul!(copy(c), Q') ≈ c*Matrix(Q')
    
                A = brand(T,100,100,3,4)
                Q,L = ql(A)
                x = randn(T,100)
                b = randn(T,100,2)
                @test lmul!(Q, copy(x)) ≈ Matrix(Q)*x
                @test lmul!(Q, copy(b)) ≈ Matrix(Q)*b
                @test lmul!(Q', copy(x)) ≈ Matrix(Q)'*x
                @test lmul!(Q', copy(b)) ≈ Matrix(Q)'*b
                c = randn(T,2,100)
                @test rmul!(copy(c), Q) ≈ c*Matrix(Q)
                @test rmul!(copy(c), Q') ≈ c*Matrix(Q')
            end
        end
    
        @testset "Mixed types" begin
            A=brand(10,10,3,2)
            b=rand(ComplexF64,10)
            Q,L=ql(A)
            @test L\(Q'*b) ≈ ql(A)\b ≈ Matrix(A)\b
            @test Q*L ≈ A
    
            A=brand(ComplexF64,10,10,3,2)
            b=rand(10)
            Q,L=ql(A)
            @test Q*L ≈ A
            @test L\(Q'*b) ≈ ql(A)\b ≈ Matrix(A)\b
    
            A = BandedMatrix{Int}(undef, (2,1), (4,4))
            A.data .= 1:length(A.data)
            Q, L = ql(A)
            @test_broken Q*L ≈ A
        end
    end

    @testset "Banded Vcat" begin
        A = Vcat(Zeros(1,10), brand(9,10,1,1))
        @test isbanded(A)
        @test bandwidths(A) == (2,0)
        @test MemoryLayout(A) isa ApplyBandedLayout{typeof(vcat)}
        @test BandedMatrix(A) == Array(A) == A
        @test A*A isa MulMatrix
        @test A*A ≈ BandedMatrix(A)*A ≈ A*BandedMatrix(A) ≈ BandedMatrix(A*A)
        @test A[1:5,1:5] isa BandedMatrix
    end

    @testset "Banded Hcat" begin
        A = Hcat(Zeros(10), brand(10,9,1,1))
        @test isbanded(A)
        @test bandwidths(A) == (0,2)
        @test MemoryLayout(A) isa ApplyBandedLayout{typeof(hcat)}
        @test BandedMatrix(A) == Array(A) == A
        @test A*A isa MulMatrix
        @test A*A ≈ BandedMatrix(A)*A ≈ A*BandedMatrix(A) ≈ BandedMatrix(A*A)
        @test A[1:5,1:5] isa BandedMatrix

        A = Hcat(Zeros(10,3), brand(10,9,1,1))
        @test isbanded(A)
        @test bandwidths(A) == (-2,4)
        @test MemoryLayout(A) isa ApplyBandedLayout{typeof(hcat)}
        @test BandedMatrix(A) == Array(A) == A
        @test A[1:5,1:5] isa BandedMatrix
    end

    @testset "resize" begin
        A = brand(4,5,1,1)
        @test LazyBandedMatrices.resize(A,6,5)[1:4,1:5] == A
        @test LazyBandedMatrices.resize(view(A,2:3,2:5),5,5) isa BandedMatrix
        @test LazyBandedMatrices.resize(view(A,2:3,2:5),5,5)[1:2,1:4] == A[2:3,2:5]
    end

    @testset "Lazy banded * Padded" begin
        A = _BandedMatrix(Vcat(BroadcastArray(exp, 1:5)', Ones(1,5)), 5, 1, 0)
        @test MemoryLayout(A) isa BandedColumns{LazyLayout}
        x = Vcat([1,2], Zeros(3))
        @test A*x isa Vcat
        @test A*A*x isa Vcat

        B = PaddedArray(randn(3,4),5,5)
        @test MemoryLayout(A*B) isa PaddedLayout
        @test A*B ≈ Matrix(A)Matrix(B)
        C = BandedMatrix(1 => randn(4))
        @test C*B ≈ Matrix(C)Matrix(B)
        D = BandedMatrix(-1 => randn(4))
        @test D*B ≈ Matrix(D)Matrix(B)

        B.args[2][end,:] .= 0
        C = PaddedArray(randn(3,4),5,5)
        @test muladd!(1.0, A, B, 2.0, deepcopy(C)) ≈ A*B + 2C
    end

    @testset "Lazy banded" begin
        A = _BandedMatrix(Ones{Int}(1,10),10,0,0)'
        B = _BandedMatrix((-2:-2:-20)', 10,-1,1)
        C = Diagonal( BroadcastVector(/, 2, (1:2:20)))
        C̃ = _BandedMatrix(BroadcastArray(/, 2, (1:2:20)'), 10, -1, 1)
        D = MyLazyArray(randn(10,10))
        M = ApplyArray(*,A,A)
        M̃ = ApplyArray(*,randn(10,10),randn(10,10))
        @test MemoryLayout(A) isa BandedRows{OnesLayout}
        @test MemoryLayout(B) isa BandedColumns{UnknownLayout}
        @test MemoryLayout(C) isa DiagonalLayout{LazyLayout}
        @test MemoryLayout(C̃) isa BandedColumns{LazyLayout}
        BC = BroadcastArray(*, B, permutedims(MyLazyArray(Array(C.diag))))
        @test MemoryLayout(BC) isa BroadcastBandedLayout
        @test A*BC isa MulMatrix
        @test BC*B isa MulMatrix
        @test BC*BC isa MulMatrix
        @test C*C̃ isa MulMatrix
        @test C̃*C isa MulMatrix
        @test C̃*D isa MulMatrix
        @test D*C̃ isa MulMatrix
        @test C̃*M isa MulMatrix
        @test M*C̃ isa MulMatrix
        @test C̃*M̃ isa MulMatrix
        @test M̃*C̃ isa MulMatrix
        
        L = _BandedMatrix(MyLazyArray(randn(3,10)),10,1,1)
        @test Base.BroadcastStyle(typeof(L)) isa LazyArrayStyle{2}

        @test 2 * L isa BandedMatrix
        @test L * 2 isa BandedMatrix
        @test 2 \ L isa BandedMatrix
        @test L / 2 isa BandedMatrix
    end

    @testset "Banded rot" begin
        A = brand(5,5,1,2)
        R = ApplyArray(rot180, A)
        @test MemoryLayout(R) isa BandedColumns{StridedLayout}
        @test bandwidths(R) == (2,1)
        @test BandedMatrix(R) == R == rot180(Matrix(A)) == rot180(A)

        A = brand(5,4,1,2)
        R = ApplyArray(rot180, A)
        @test MemoryLayout(R) isa BandedColumns{StridedLayout}
        @test bandwidths(R) == (3,0)
        @test BandedMatrix(R) == R == rot180(Matrix(A)) == rot180(A)
        
        A = brand(5,6,1,-1)
        R = ApplyArray(rot180, A)
        @test MemoryLayout(R) isa BandedColumns{StridedLayout}
        @test bandwidths(R) == (-2,2)
        @test BandedMatrix(R) == R == rot180(Matrix(A)) == rot180(A)

        A = brand(6,5,-1,1)
        R = ApplyArray(rot180, A)
        @test MemoryLayout(R) isa BandedColumns{StridedLayout}
        @test bandwidths(R) == (2,-2)
        @test BandedMatrix(R) == R == rot180(Matrix(A)) == rot180(A)

        B = brand(5,4,1,1)
        R = ApplyArray(rot180, ApplyArray(*, A, B))
        MemoryLayout(R) isa ApplyBandedLayout{typeof(*)}
        @test bandwidths(R) == (4,-2)
        @test R == rot180(A*B)
    end

    @testset "Triangular bandwidths" begin
        B = brand(5,5,1,2)
        @test bandwidths(ApplyArray(\, Diagonal(randn(5)), B)) == (1,2)
        @test bandwidths(ApplyArray(\, UpperTriangular(randn(5,5)), B)) == (1,4)
        @test bandwidths(ApplyArray(\, LowerTriangular(randn(5,5)), B)) == (4,2)
        @test bandwidths(ApplyArray(\, randn(5,5), B)) == (4,4)
    end

    @testset "zeros mul" begin
        A = _BandedMatrix(BroadcastVector(exp,1:10)', 10, -1,1)
        @test ArrayLayouts.mul(Zeros(5,10),A) ≡ Zeros(5,10)
        @test ArrayLayouts.mul(A,Zeros(10,5)) ≡ Zeros(10,5)
    end

    @testset "concat" begin
        @test MemoryLayout(Vcat(1,1)) isa ApplyLayout{typeof(vcat)}
        @test MemoryLayout(Vcat(1,Zeros(5),1)) isa ApplyLayout{typeof(vcat)}

        @test bandwidths(Hcat(1,randn(1,5))) == (0,5)
        @test bandwidths(Vcat(1,randn(5,1))) == (5,0)

        V = Vcat(brand(5,5,1,1), brand(4,5,0,1))
        @test arguments(view(V,:,1:3)) == (V.args[1][:,1:3], V.args[2][:,1:3])
        H = ApplyArray(hvcat, 2, 1, Hcat(1, Zeros(1,10)), Vcat(1, Zeros(10)), Diagonal(1:11))
        @test bandwidths(H) == (1,1)
        H = ApplyArray(hvcat, 2, 1, Hcat(0, Zeros(1,10)), Vcat(0, Zeros(10)), Diagonal(1:11))
        @test bandwidths(H) == (0,0)
        H = ApplyArray(hvcat, (2,2), 1, Hcat(1, Zeros(1,10)), Vcat(1, Zeros(10)), Diagonal(1:11))
        @test_broken bandwidths(H) == (1,1)

        @test bandwidths(Vcat(Diagonal(1:3), Zeros(3,3))) == (0,0)
        @test bandwidths(Hcat(1, Zeros(1,3))) == (0,0)
        c = cache(Zeros(5));
        @test bandwidths(c) == (-1,0)
    end

    @testset "invlayout * structured banded (#21)" begin
        A = randn(5,5)
        B = BroadcastArray(*, brand(5,5,1,1), 2)
        @test A * B ≈ A * Matrix(B)
        @test A \ B ≈ A \ Matrix(B)
    end


    @testset "QR" begin
        A = brand(100_000,100_000,1,1)
        F = qr(A)
        b = Vcat([1,2,3],Zeros(size(A,1)-3))
        @test F.Q'b == apply(*,F.Q',b)
    end
end