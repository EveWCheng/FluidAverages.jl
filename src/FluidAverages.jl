module FluidAverages

export ConvergeAlphaDash,
    SurroundingAverage,
    LJCalc,
    ApproachLJ

using Dierckx, QuadGK
using ProgressMeter

using Distributed
using NumericalIntegration: integrate, cumul_integrate

"""
    ConvergeAlphaDash(alpha_R, alpha, gs, g, dens ; imax=10, calc_R=alpha_R, tol=1e-6, kwds...)

Solves for the screened r-dependent polarisability α′(r) iteratively. The input
single-atom polarisability is given by vectors `alpha_R` and `alpha`, and the
pair correlation function g(r) is given by `gs` and `g`. The equations are
solved for a density `dens`.

The output is given on the mesh `calc_R` which defaults to `alpha_R`.

The iteration stops after `imax` iterations of if a difference between two
iterations is less than `tol`.

`kwds` are passed through to the `CalcAlphaDash` function, called at each
iteration. It is highly recommended to set `s_max` for this to a reasonably
large value.
k"""
function ConvergeAlphaDash(alpha_R, alpha, gs, g, dens ; imax=10, calc_R=alpha_R, tol=1e-6, kwds...)
    fL = 1 / (1 + (8/3)*pi*dens*alpha[end])

    alpha_interp = Spline1D(alpha_R, alpha, k=1, bc="nearest")

    cur = alpha_interp(calc_R)*fL

    for i in 1:imax
        new = CalcAlphaDash(alpha_R, alpha, gs, g, dens, calc_R=calc_R, alpha_prev=cur ; kwds...)
        diff = integrate(calc_R, abs.(new - cur))
        @show diff

        abs(diff) < tol && break

        cur = new
    end

    return cur
end

function CalcAlphaDash(alpha_R, alpha, gs, g, dens ; s_max=gs[end], calc_R=alpha_R, alpha_prev=:auto, show_figures=TypeFalse(), method=:inv_quadgk)
    @assert method ∈ [:quadgk, :inv_quadgk, :inv_trapz]
    
    if gs[1] == 0.
        popfirst!(gs)
        popfirst!(g)
    end

    if show_figures isa Real
        @assert show_figures ∈ calc_R
    end

    alpha_interp = Spline1D(alpha_R, alpha, k=1, bc="nearest")
    if alpha_prev == :auto
        alpha_prev = alpha_interp.(calc_R)
    end
    alpha_prev_interp = Spline1D(calc_R, alpha_prev, k=1, bc="nearest")
    g_interp = Spline1D(gs, g, k=1, bc="nearest")

    alpha_dash = similar(alpha)

    function Theta(Rsqr,ssqr,t)
        tsqr = t^2

        out = 3/2 / ssqr * (ssqr + tsqr - Rsqr) * (ssqr + Rsqr - tsqr) + (tsqr + Rsqr - ssqr)
        return out
    end

    function sintegral(s, R)
        Rsqr = R^2
        ssqr = s^2

        tmin = 0.
        tintmin = max(1e-8, tmin, abs(R - s))
        tintmax = R + s

        invt_intmin = 1/tintmin
        invt_intmax = 1/tintmax

        if method == :quadgk
            func = t -> 1/t^2 * Theta(Rsqr, ssqr, t) * alpha_prev_interp(t)
            out,err = quadgk(func, tintmin, tintmax)
        elseif method == :inv_quadgk
            func = invt -> -Theta(Rsqr, ssqr, 1/invt) * alpha_prev_interp(1/invt)
            out,err = quadgk(func, invt_intmin, invt_intmax, atol=1e-10, rtol=1e-6)
        elseif method == :inv_trapz
            dt = 0.01
            t = tintmin:dt:tintmax
            if t[end] != tintmax
                t = [t ; tintmax]
            end

            func = t -> Theta(Rsqr, ssqr, t) * alpha_prev_interp(t)
            temp = -integrate(1 ./ t, func.(t))

            return temp
        end

        out
    end

    function Rintegral(R)
        sint_min = gs[1]
        sint_max = s_max

        if method == :quadgk
            func = s -> 1/s^2 * g_interp(s) * alpha_interp(s) * sintegral(s, R)
            out,err = quadgk(func, sint_min, sint_max)
            return out
        elseif method == :inv_quadgk
            func = invs -> -g_interp(1/invs) * alpha_interp(1/invs) * sintegral(1/invs, R)

            invs_intmin = 1/gs[1]
            invs_intmax = 1/s_max
            out,err = quadgk(func, invs_intmin, invs_intmax, atol=1e-10, rtol=1e-6)
            return out
        elseif method == :inv_trapz
            smesh = range(gs[1], s_max, length=1001)
            svals = sintegral.(smesh, R)
            svals .*= g_interp.(smesh) .* alpha_interp.(smesh)

            return -integrate(1 ./ smesh, svals)
        end
    end

    alpha_dash = @showprogress pmap(Rintegral, calc_R)
    alpha_dash *= -pi*dens
    alpha_dash += alpha_interp.(calc_R)

    alpha_dash
end


function ReadFRAndGSFromBobInputs(f_filename, g_filename)
    gmat = readdlm(g_filename, skipstart=1)
    gs,g = cols(gmat)
    gheader = readline(g_filename)
    _,gmin,dens = parse.(split(gheader)[1:3])

    g[gs.<gmin] = 0.
    @assert all(g.>=0)

    fmat = readcsv(f_filename)
    fR,f = cols(fmat)

    return fR,f,gs,g,dens
end

"""This is Bob's logarithmic mesh"""
function LogMesh(N::Int, Z::Int, rho::Float64=-8.0, h::Float64=0.0625)
    logmesh = exp.(rho + (0:(N-1)) * h) / Z
end

"""Extract the dipole polarisation potential from one of Bob's large datafiles. I think this is r⁴*Vₚ."""
function ReadAlphaFromBobInput(filename)
    local mesh
    local vals
    
    open(filename) do file

        line = readline(file)
        N,h,Z,rho = split(line)[1:4] .|> parse

        line = readline(file)
        NPOT = split(line)[1] |> parse

        # Create the log mesh
        mesh = LogMesh(N, Int(Z), rho, h)
        
        count = 0
        while count < 2
            line = readline(file)
            if startswith(line, " ATOM")
                count += 1
            end
        end

        vals = zeros(N,NPOT)

        for pot_ind = 1:NPOT-2
            line = readline(file)
            i = 1
            while !isalpha(strip(line)[1])
                thisvals = split(line) .|> parse
                n = length(thisvals)
                #append!(vals, thisvals)
                @show i,n,pot_ind
                vals[i:i+n-1,pot_ind] = thisvals
                i += n

                line = readline(file)
            end
            @assert i == N+1
        end
    end

    mesh,vals
end

using Polynomials
"""
    SurroundingAverage(gs,g,r,func,dens ; asymp_pot=false)

Performs a surrounding average of the function contained in the vectors `r` and
`func`. This function is assumed to be centred on each fluid atom and the
pair correlator of fluid atoms, g(s), is given in the vectors `gs` and `g` and
assumed to be of an average density `dens`.

This function is mostly useful for U₂(r) averaging. For that reason, there is
also a kwd `asymp_pot` which will fit the function to a long-range 1/r⁴ form and
use an analytical result for the integrals past the outer value of `gs`.
"""
function SurroundingAverage(gs,g,r,func,dens ; asymp_pot=false)

    func_interp = Spline1D(r,func)
    
    # Manually doing cumtrapz
    integrand = gs .* g

    terms = RunningAvg(integrand) .* diff(gs)
    terms = [0 ; terms]
    sgs_cumint = cumsum(terms)

    sgscum_spline = Spline1D(gs, sgs_cumint,k=1)
    sgscum_extrap = s -> sgs_cumint[end] + 1/2*(s^2 - gs[end]^2)
    sgscum_comb = s -> s < gs[end] ? sgscum_spline(s) : sgscum_extrap(s)
    
    function TIntegrand(r,t)
        smin = abs(r - t)
        smax = r + t

        out = t * func_interp(t) * (sgscum_comb(smax) - sgscum_comb(smin))
    end

    tmax = r[end]
    func2 = map(r) do r
        # if @printagain()
        #     println("Up to r=$r")
        # end
        2*pi*dens / r * quadgk(t -> TIntegrand(r,t), 0, tmax)[1]
    end


    if asymp_pot
        # Add on the long-range form of the polarisation potential
        coeffs = polyfit(log.(r[end-10:end]), log.(-func[end-10:end]), 1)
        @assert isapprox(coeffs[1], -4., atol=0.1)

        A = exp(coeffs[0])
        asympcorr = -4*pi*dens*A / tmax
        @show asympcorr
        @show A
        func2 .+= asympcorr
    end
    
    func2
end




# Trying PY approx

"""
    PercusYevick(N, b, pot, β, ρ ; kwds...)

Do the iterations on a Percus-Yevick solution for the g(r) pair correlator for a
fluid system with an interaction potential given by a function `pot`, an inverse
temperature of `β`=1/kT and a density of `ρ`.

The g(r) is calculated on a linear grid for speed reasons, defined by `N` grid
points and an outer limit of r=`b`.

# kwds
- `tol`: stop when integrated difference in g(r) between iterations is less than this.
- `imax`: maximum number of iterations
- `α=0.1`: the dampening term for updating g(r) from previous iteration.
- `suppress_r=0.1`: force y(r < suppress_r)=1
- `renormalise`: don't use this. Tries to conserve number of particles.
- `init`: vector used for y(r) on first iteration. Set to `:auto` for a vector of ones.
- `init_N`: if `init` is on a different grid, set this and `init` will be interpolated onto `N`.
- `ignore_kb_int`: exits the iterations gracefully if a KeyboardInterrupt occurs.
"""
function PercusYevick(N, b, pot, β, ρ ;
                      tol=1e-6,
                      imax=10^6,
                      α=0.1,
                      suppress_r=0.1,
                      renormalise=false,
                      init=:auto,
                      init_N=N,
                      ignore_kb_int=true
                      )
    local R = nothing

    if init_N == N || init == :auto
        y = init
    else
        R_old, = PYR(init_N, b)
        R,= PYR(N,b)
        y = Spline1D(R_old, init).(R)
    end

    E(Rin) = (Rin == 0 ? 0. : exp(-β*pot(Rin)))
    gfunc(y) = @. E(R) * y

    prog = ProgressThresh(tol)

    try
        for i in 1:imax
            R,new = PercusYevickWorker(N, b, y, pot, β, ρ)

            any(isnan,new) && error("Values went NaN after $i iterations!")

            if y != :auto
                # diff = integrate(R, abs.(new - y))
                # Comparing with g's since the y can have troubles converging at small R.
                new[R .< suppress_r] .= 1.
                if renormalise
                    # Conserve the number of particles
                    # extra = integrate(R, y .- 1)

                    # Actually the above wouldn't work very well. So instead,
                    # force the outer part to go to one.
                    new ./= new[end]
                end
                old_g = gfunc(y)
                new_g = gfunc(new)
                diff = integrate(R, abs.(old_g - new_g))

                update!(prog, diff)

                abs(diff) < tol && break

                y = y + α*(new-y)
            else
                y = new
            end
        end
    catch exc
        (exc isa InterruptException && ignore_kb_int) || rethrow()
        @warn "Ignoring interrupt"
    end

    g = gfunc(y)
    return R,g,y
end


"""The linearly-spaced grid used, and an extension to twice the number of grid points."""
function PYR(N,b)
    extRlist = LinRange(0,2*b,2N+1)
    Rlist = filter(<=(b), extRlist)

    return Rlist,extRlist
end
function PercusYevickWorker(N, b, y, pot, β, ρ)
    Rlist,extRlist = PYR(N,b)

    if y == :auto
        y = ones(length(Rlist))
    end

    yext = [y ; ones(length(extRlist) - length(Rlist))]
    
    x = yext .* extRlist

    E = @. exp(-β*pot(extRlist))
    E[1] = 0.

    function sintegral(Rind)
        integrand = map(eachindex(Rlist)) do sind
            out = (1 - E[sind]) * x[sind]
            tmin_ind = abs(sind-Rind) + 1
            tmax_ind = (sind-1+Rind-1) + 1
            out *= (x[tmax_ind]*E[tmax_ind] + sign(sind-Rind)*x[tmin_ind]*E[tmin_ind] - 2*Rlist[sind])
        end

        out = integrate(Rlist, integrand)
        out = 1 - 2π*ρ*out
    end

    # dx = @showprogress pmap(sintegral, eachindex(Rlist))
    dx = sintegral.(eachindex(Rlist))
    x = cumul_integrate(Rlist, dx)

    y = x./Rlist
    y[1] = 1.

    Rlist,y
end


"""
    LJCalc(β,ρ ; maxpot_val=Inf, maxR=Inf, kwds...)

Do a `PercusYevick` iteration with the Lennard-Jones potential. `β` and `ρ` are to
be in LJ units. The potential is capped to the maximum value `maxpot_val` and is
truncated (but not shifted) after `maxR`.

Other kwds are passed to `PercusYevick`.
"""
function LJCalc(β,ρ, ;
                N=101,
                b=10,
                α=0.1,
                maxpot_val=Inf,
                maxR = Inf,
                kwds...)
    pot = R -> 4*(1/R^12 - 1/R^6)

    maxpot = R -> R > maxR ? 0. : min(pot(R), maxpot_val / β)

    R,g,y = PercusYevick(N, b, maxpot, β, ρ ; α=α, kwds...)

    return R,g,y
end

"""
    ApproachLJ(β_in, ρ, N, Nfinal=N)

Calculate a `PercusYevick` iteration solution to the Lennard-Jones problem at
`β_in` and `ρ`. If there are convergence issues, the function will move to a
higher temperature to find a solution which does converge, and then uses that
solution as an initial guess for the desired temperature.
"""
function ApproachLJ(β_in, ρ, N, Nfinal=N ;
                    safe_β=1/1.5,
                    β_step=β_in - safe_β,
                    β_step_adjust=true,
                    kwds...)
    y = :auto
    R = nothing
    local g
    # for β in [(safe_β:β_step:β_in) ; β_in]
    last_β = min(safe_β, β_in)
    while last_β < β_in
        β = last_β + β_step
        β = min(β, β_in)

        @show β
        try
            R,g,y = LJCalc(β,ρ, N=N ; ignore_kb_int=false, init=y, kwds...)
        catch exc
            (exc isa ErrorException && occursin("NaN", exc.msg)) || rethrow()
            β_step /= 2.5
            if β_step < 0.001
                @error "β_step got too small. Maybe this is in the coexistence region?" β_step last_β β 1/β ρ
                error("Break")
            end
            @info "Adjusting β_step to be smaller" β_step
            continue
        end

        last_β = β
    end

    if Nfinal != N || R == nothing
        R,g,y = LJCalc(β_in,ρ, N=Nfinal ; ignore_kb_int=false, init=y, init_N=N, kwds...)
    end
        

    return R,g,y
end

using Requires

function __init__()
    @require PercusYevickSSF="ae029012-a4dd-5104-9daa-d747884805df" include("analytic_comp.jl")
end

end # module
