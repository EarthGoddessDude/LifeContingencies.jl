module LifeContingencies

using MortalityTables
using Transducers
using Dates
using IterTools
using QuadGK
using Yields
    
const mt = MortalityTables

export LifeContingency,
    InterestRate,
    rate,
    APV,
    disc,    
    SingleLife, Frasier, JointLife,
    LastSurvivor,
    survival,
    DiscountFactor,
    reserve_premium_net,
    disc,
    insurance,
    annuity_due,
    annuity_immediate,
    premium_net,
    omega





# 'actuarial objects' that combine multiple forms of decrements (lapse, interest, death, etc)
abstract type Life end


"""
    struct SingleLife
        mort
        issue_age::Int
        alive::Bool
        fractional_assump::MortalityTables.DeathDistribution
    end

A `Life` object containing the necessary assumptions for contingent maths related to a single life. Use with a `LifeContingency` to do many actuaral present value calculations. 

Keyword arguments:
- `mort` pass a mortality vector, which is an array of applicable mortality rates indexed by attained age
- `issue_age` is the assumed issue age for the `SingleLife` and is the basis of many contingency calculations.
- `alive` Default value is `true`. Useful for joint insurances with different status on the lives insured.
- `fractional_assump`. Default value is `Uniform()`. This is a `DeathDistribution` from the `MortalityTables.jl` package and is the assumption to use for non-integer ages/times.

# Examples
    using MortalityTables
    tbls = MortalityTables.tables()
    mort = tbls["2001 VBT Residual Standard Select and Ultimate - Male Nonsmoker, ANB"]

    SingleLife(
        mort       = mort.select[30], 
        issue_age  = 30          
    )
"""
Base.@kwdef struct SingleLife <: Life
    mort
    issue_age::Int
    alive=true
    fractional_assump = mt.Uniform()
end

""" 
    JointAssumption()

An abstract type representing the different assumed relationship between the survival of the lives on a JointLife. Available options to use include:
- `Frasier()`
"""
abstract type JointAssumption end

""" 
    Frasier()

The assumption of independnt lives in a joint life calculation.
Is a subtype of `JointAssumption`.
"""
struct Frasier <: JointAssumption end

""" 
    Contingency()

An abstract type representing the different triggers for contingent benefits. Available options to use include:
- `LastSurvivor()`
"""
abstract type Contingency end

"""
    LastSurvivor()
The contingency whereupon benefits are payable upon both lives passing.
Is a subtype of `Contingency`
"""
struct LastSurvivor <: Contingency end

# TODO: Not Implemented
# """
#     FirstToDie()
# The contingency whereupon benefits are payable upon the first life passing.

# Is a subtype of `Contingency`
# """
# struct FirstToDie <: Contingency end

"""
    struct JointLife
        lives
        contingency
        joint_assumption
    end

    A `Life` object containing the necessary assumptions for contingent maths related to a joint life insurance. Use with a `LifeContingency` to do many actuaral present value calculations. 

Keyword arguments:
- `lives` is a tuple of two `SingleLife`s
- `contingency` default is `LastSurvivor()`. It is the trigger for contingent benefits. See `?Contingency`. 
- `joint_assumption` Default value is `Frasier()`. It is the assumed relationship between the mortality of the two lives. See `?JointAssumption`. 

# Examples
    using MortalityTables
    tbls = MortalityTables.tables()
    mort = tbls["2001 VBT Residual Standard Select and Ultimate - Male Nonsmoker, ANB"]

    l1 = SingleLife(
        mort       = mort.select[30], 
        issue_age  = 30          
    )
    l2 = SingleLife(
        mort       = mort.select[30], 
        issue_age  = 30          
    )

    jl = JointLife(
        lives = (l1,l2),
        contingency = LastSurvivor(),
        joint_assumption = Frasier()
    )
"""
Base.@kwdef struct JointLife <: Life
    lives::Tuple{SingleLife,SingleLife}
    contingency::Contingency = LastSurvivor()
    joint_assumption::JointAssumption = Frasier()
end

"""
    struct LifeContingency
        life::Life
"""
struct LifeContingency
    life::Life
    int
end

Base.broadcastable(lc::LifeContingency) = Ref(lc)

"""
    omega(lc::LifeContingency)
    omega(l::Life)
    omega(i::InterestRate)

# `Life`s and `LifeContingency`s

Returns the last defined time_period for both the interest rate and mortality table.
Note that this is *different* than calling `omega` on a `MortalityTable`, which will give you the last `attained_age`.

Example: if the `LifeContingency` has issue age 60, and the last defined attained age for the `MortalityTable` is 100, then `omega` of the `MortalityTable` will be `100` and `omega` of the 
`LifeContingency` will be `40`.

# `InterestRate`s

The last period that the interest rate is defined for. Assumed to be infinite (`Inf`) for 
    functional and constant interest rate types. Returns the `lastindex` of the vector if 
    a vector type.
"""
function mt.omega(lc::LifeContingency)
    # if one of the omegas is infinity, that's a Float so we need
    # to narrow the type with Int
    return Int(omega(lc.life))
end

function mt.omega(l::SingleLife)
    return mt.omega(l.mort) - l.issue_age + 1    
end

function mt.omega(l::JointLife)
    return minimum( omega.(l.lives) )    
end


###################
## COMMUTATIONS ###
###################

"""
    D(lc::LifeContingency, to_time)

``D_x`` is a retrospective actuarial commutation function which is the product of the survival and discount factor.
"""
function D(lc::LifeContingency, to_time)
    return discount(lc.int, to_time) * survival(lc,to_time)
end


"""
    l(lc::LifeContingency, to_time)

``l_x`` is a retrospective actuarial commutation function which is the survival up to a certain point in time. By default, will have a unitary basis (ie `1.0`), but you can specify `basis` keyword argument to use something different (e.g. `1000` is common in the literature.)
"""
function l(lc::LifeContingency, to_time; basis=1.0)
    return survival(lc.life,to_time) * basis
end

"""
    C(lc::LifeContingency, to_time)

``C_x`` is a retrospective actuarial commutation function which is the product of the discount factor and the difference in `l` (``l_x``).
"""
function C(lc::LifeContingency, to_time)
    discount(lc.int, to_time+1) * (l(lc,to_time) - l(lc, to_time+1))
    
end

"""
    N(lc::LifeContingency, from_time)

``N_x`` is a prospective actuarial commutation function which is the sum of the `D` (``D_x``) values from the given time to the end of the mortality table.
"""
function N(lc::LifeContingency, from_time)
    range = from_time:(omega(lc)-1)
    return foldxt(+,Map(from_time->D(lc, from_time)), range)
end

"""
    M(lc::LifeContingency, from_time)

The ``M_x`` actuarial commutation function where the `from_time` argument is `x`.
Issue age is based on the issue_age in the LifeContingency `lc`.
"""
function M(lc::LifeContingency, from_time)
    range = from_time:omega(lc)-1
    return foldxt(+,Map(from_time->C(lc, from_time)), range)
end

E(lc::LifeContingency, t, x) = D(lc,x + t) / D(lc,x)


##################
### Insurances ###
##################

   
"""
    insurance(lc::LifeContingency,from_time=0,to_time=nothing)

Life insurance for someone starting at `from_time` and lasting until `to_time`. If `to_time` is `nothing` (the default), will be insurance until the end of the mortality table or interest rates.

Issue age is based on the `issue_age` in the LifeContingency `lc`.
"""
insurance(lc::LifeContingency,to_time=nothing) = insurance(lc.life,lc,to_time)

function insurance(::SingleLife,lc::LifeContingency,to_time)
    iszero(to_time) && return 0.0 #short circuit and return 0 if there is no time elapsed
    mt = lc.life.mort
    iss_age = lc.life.issue_age
    end_age = to_time + iss_age -1
    len = end_age - iss_age
    v = discount.(lc.int,1:len+1)
    tpx =  [survival(mt,iss_age,att_age, lc.life.fractional_assump) for att_age in iss_age:end_age]
    qx =   mt[iss_age:end_age]

    sum(v .* tpx  .* qx)
end

function insurance(::SingleLife,lc::LifeContingency,::Nothing)
    mt = lc.life.mort
    iss_age = lc.life.issue_age
    end_age = omega(lc) + iss_age - 1
    len = end_age - iss_age
    v = discount.(lc.int,1:len+1)
    tpx =  [survival(mt,iss_age,att_age, lc.life.fractional_assump) for att_age in iss_age:end_age]
    qx =   mt[iss_age:end_age]

    sum(v .* tpx  .* qx)
end

# for joint, dispactch based on the type of insruance and assumption
function insurance(::JointLife,lc::LifeContingency, to_time) 
    insurance(lc.life.contingency, lc.life.joint_assumption,lc,to_time)
end

function insurance(::LastSurvivor,::Frasier,lc::LifeContingency, to_time)
    iszero(to_time) && return 0.0 #short circuit and return 0 if there is no time elapsed
    v = discount.(lc.int,1:to_time)
    tpx =  [survival(lc,t) for t in 0:to_time-1]
    qx =   [ survival(lc,t) - survival(lc,t+1) for t in 0:to_time-1]

    sum(v .* tpx  .* qx)
end

function insurance(::LastSurvivor,::Frasier,lc::LifeContingency, ::Nothing)
    to_time = omega(lc)
    v = discount.(lc.int,1:to_time)
    tpx =  [survival(lc,t) for t in 0:to_time-1]
    qx =   [ survival(lc,t) - survival(lc,t+1) for t in 0:to_time-1]

    sum(v .* tpx  .* qx)
end

"""
    annuity_due(lc::LifeContingency, npayments,start_time=0,certain=nothing)
    annuity_due(lc::LifeContingency,start_time=0,certain=nothing)

Life annuity due for the life contingency `lc` with the benefit period starting at `start_time` and ending after `npayments`. If `npayments` is omitted, will return whole life annuity due. `certain` is the length of the certain time.


To enter the `annuity_due` character, type `a` and then `\\ddot`.
    See more on how to [input unicode](https://docs.julialang.org/en/v1/manual/unicode-input/index.html)
    in Julia.

"""
annuity_due(lc::LifeContingency; start_time=0, certain=nothing) = annuity_due(lc.life,lc,start_time=start_time,certain=certain)
annuity_due(lc::LifeContingency,npayments; start_time=0, certain=nothing) = annuity_due(lc.life,lc,npayments,start_time=start_time,certain=certain)

function annuity_due(::SingleLife,lc::LifeContingency, npayments; start_time=0, certain=nothing)
    npayments -=  start_time
    npayments == 0 && return 0.0 # break and return if no payments to be made
    end_time = npayments + start_time - 1
    discount_factor = discount.(lc.int,start_time:end_time)

    if isnothing(certain)
        pmts = [survival(lc,t) for t in start_time:end_time]
    else
        pmts = [t <= certain ? 1. : survival(lc,t) for t in start_time:end_time]
    end

    return sum(discount_factor .* pmts)
end

function annuity_due(::SingleLife,lc::LifeContingency; start_time=0, certain=nothing)
    npayments = omega(lc) - start_time
    end_time = (npayments+start_time)
    discount_factor = discount.(lc.int,start_time:end_time)
    if isnothing(certain)
        pmts = [survival(lc,t) for t in start_time:end_time]
    else
        pmts = [t <= certain ? 1. : survival(lc,t) for t in start_time:end_time]
    end

    return sum(discount_factor .* pmts)
end

# for joint, dispactch based on the type of insruance and assumption
function annuity_due(::JointLife,lc::LifeContingency;start_time=0, certain=nothing) 
    return ä(lc.life.contingency,lc.life.joint_assumption,lc,start_time=start_time,certain=certain)
end

function annuity_due(::JointLife,lc::LifeContingency, npayments;start_time=0, certain=nothing) 
    return ä(lc.life.contingency,lc.life.joint_assumption,lc,npayments,start_time=start_time,certain=certain)
end

function annuity_due(::LastSurvivor,::Frasier, lc::LifeContingency, npayments;start_time=0, certain=nothing)
    npayments -=  start_time
    npayments == 0 && return 0.0
    end_time = npayments + start_time -1
    discount_factor = discount.(lc.int,start_time:end_time)
    if isnothing(certain)
        pmts = [survival(lc,t) for t in start_time:end_time]
    else
        pmts = [t <= certain ? 1. : survival(lc,t) for t in start_time:end_time]
    end
    return sum( discount_factor .* pmts )

end

function annuity_due(::LastSurvivor,::Frasier, lc::LifeContingency;start_time=0, certain=nothing)
    npayments = omega(lc) - start_time
    end_time = npayments + start_time
    discount_factor = discount.(lc.int,start_time:end_time)
    if isnothing(certain)
        pmts = [survival(lc,t) for t in start_time:end_time]
    else
        pmts = [t <= certain ? 1. : survival(lc,t) for t in start_time:end_time]
    end
    return sum( discount_factor .* pmts )

end

"""
    annuity_immediate(lc::LifeContingency, npayments; start_time=0; certain=nothing)
    annuity_immediate(lc::LifeContingency; start_time=0,certain=nothing)

Life annuity immediate for the life contingency `lc` with the benefit period starting at `start_time` and ending after `npayments`. If `npayments` is omitted, will calculate the whole life immediate annuity. `certain` is the length of the certain time.


"""
function annuity_immediate(lc::LifeContingency;start_time=0, certain=nothing) 
   return annuity_due(lc,start_time=start_time,certain=certain) - 1 # eq 5.11 ALMCR 2nd ed
end

# eq 5.13 ALMCR 2nd ed
function annuity_immediate(lc::LifeContingency,npayments; start_time=0,certain=nothing) 
    x = annuity_due(lc,npayments;start_time=start_time,certain=certain)
    y = discount(lc,start_time,start_time+npayments)
    z = survival(lc,npayments)
    return x - 1 + y * z
end



"""
    premium_net(lc::LifeContingency)
    premium_net(lc::LifeContingency,to_time)

The net premium for a whole life insurance (without second argument) or a term life insurance through `to_time`.

The net premium is based on 1 unit of insurance with the death benfit payable at the end of the year and assuming annual net premiums.
"""
premium_net(lc::LifeContingency) = insurance(lc) / ä(lc)
premium_net(lc::LifeContingency,to_time) = insurance(lc,to_time) / ä(lc,to_time)

"""
     reserve_premium_net(lc::LifeContingency,time)

The net premium reserve at the end of year `time`.
"""
function  reserve_premium_net(lc::LifeContingency, time) 
    PVFB = insurance(lc) - insurance(lc,time)
    PVFP = premium_net(lc) * (ä(lc) - ä(lc,time))
    return (PVFB - PVFP) / APV(lc,time)
end

"""
    APV(lc::LifeContingency,to_time)

The **actuarial present value** which is the survival times the discount factor for the life contingency.
"""
function APV(lc::LifeContingency,to_time)
    return survival(lc,to_time) * discount(lc.int,to_time)
end

"""
    decrement(lc::LifeContingency,to_time)
    decrement(lc::LifeContingency,from_time,to_time)

Return the probablity of death for the given LifeContingency. 
"""
mt.decrement(lc::LifeContingency,from_time,to_time) = 1 - survival(lc.life,from_time,to_time)


"""
    survival(lc::LifeContingency,from_time,to_time)
    survival(lc::LifeContingency,to_time)

Return the probablity of survival for the given LifeContingency. 
"""
mt.survival(lc::LifeContingency,to_time) = survival(lc.life, 0, to_time)
mt.survival(lc::LifeContingency,from_time,to_time) = survival(lc.life, from_time, to_time)

mt.survival(l::SingleLife,to_time) = survival(l,0,to_time)
mt.survival(l::SingleLife,from_time,to_time) = survival(l.mort,l.issue_age + from_time,l.issue_age + to_time, l.fractional_assump)

mt.survival(l::JointLife,to_time) = survival(l::JointLife,0,to_time)
function mt.survival(l::JointLife,from_time,to_time) 
    return survival(l.contingency,l.joint_assumption,l::JointLife,from_time,to_time)
end

function mt.survival(ins::LastSurvivor,assump::JointAssumption,l::JointLife,from_time,to_time)
    to_time == 0 && return 1.0
    
    l1,l2 = l.lives
    ₜpₓ = survival(l1.mort,l1.issue_age + from_time,l1.issue_age + to_time,l1.fractional_assump)
    ₜpᵧ = survival(l2.mort,l2.issue_age + from_time,l2.issue_age + to_time,l2.fractional_assump)
    return ₜpₓ + ₜpᵧ - ₜpₓ * ₜpᵧ
end

Yields.discount(lc::LifeContingency,t) = discount(lc.int,t)
Yields.discount(lc::LifeContingency,t1,t2) = discount(lc.int,t1,t2)

# unexported aliases
const V = reserve_premium_net
const v = Yields.discount
const A = insurance
const a = annuity_immediate
const ä = annuity_due
const P = premium_net
const ω = omega

end # module
