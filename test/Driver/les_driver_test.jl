using StaticArrays
using Test

using ClimateMachine
using ClimateMachine.Atmos
using ClimateMachine.Orientations
using ClimateMachine.Mesh.Grids
using ClimateMachine.Thermodynamics
using ClimateMachine.VariableTemplates

using CLIMAParameters
using CLIMAParameters.Planet: grav, MSLP
struct EarthParameterSet <: AbstractEarthParameterSet end
const param_set = EarthParameterSet()

function init_test!(problem, bl, state, aux, localgeo, t)
    (x, y, z) = localgeo.coord

    FT = eltype(state)
    param_set = parameter_set(bl)

    z = FT(z)
    _grav::FT = grav(param_set)
    _MSLP::FT = MSLP(param_set)

    # These constants are those used by Stevens et al. (2005)
    qref = FT(9.0e-3)
    q_pt_sfc = PhasePartition(qref)
    Rm_sfc = FT(gas_constant_air(param_set, q_pt_sfc))
    T_sfc = FT(290.4)
    P_sfc = _MSLP

    # Specify moisture profiles
    q_liq = FT(0)
    q_ice = FT(0)

    θ_liq = FT(289.0)
    q_tot = qref

    ugeo = FT(7)
    vgeo = FT(-5.5)
    u, v, w = ugeo, vgeo, FT(0)

    # Pressure
    H = Rm_sfc * T_sfc / _grav
    p = P_sfc * exp(-z / H)

    # Density, Temperature
    ts = PhaseEquil_pθq(param_set, p, θ_liq, q_tot)
    ρ = air_density(ts)

    e_kin = FT(1 / 2) * FT((u^2 + v^2 + w^2))
    e_pot = _grav * z
    E = ρ * total_energy(e_kin, e_pot, ts)

    state.ρ = ρ
    state.ρu = SVector(ρ * u, ρ * v, ρ * w)
    state.energy.ρe = E
    state.moisture.ρq_tot = ρ * q_tot

    return nothing
end

function main()
    @test_throws ArgumentError ClimateMachine.init(dsisable_gpu = true)
    ClimateMachine.init()

    FT = Float64

    # DG polynomial orders
    N = (4, 4)

    # Domain resolution and size
    Δh = FT(40)
    Δv = FT(40)
    resolution = (Δh, Δh, Δv)

    xmax = FT(320)
    ymax = FT(320)
    zmax = FT(400)

    t0 = FT(0)
    timeend = FT(10)
    CFL = FT(0.4)

    driver_config = ClimateMachine.AtmosLESConfiguration(
        "Driver test",
        N,
        resolution,
        xmax,
        ymax,
        zmax,
        param_set,
        init_test!,
    )
    ode_solver_type = ClimateMachine.ExplicitSolverType()
    solver_config = ClimateMachine.SolverConfiguration(
        t0,
        timeend,
        driver_config,
        ode_solver_type = ode_solver_type,
        Courant_number = CFL,
    )

    # Test the courant wrapper
    # by default the CFL should be less than what asked for
    CFL_nondiff = ClimateMachine.DGMethods.courant(
        ClimateMachine.Courant.nondiffusive_courant,
        solver_config,
    )
    @test CFL_nondiff < CFL
    CFL_adv = ClimateMachine.DGMethods.courant(
        ClimateMachine.Courant.advective_courant,
        solver_config,
    )
    CFL_adv_v = ClimateMachine.DGMethods.courant(
        ClimateMachine.Courant.advective_courant,
        solver_config;
        direction = VerticalDirection(),
    )
    CFL_adv_h = ClimateMachine.DGMethods.courant(
        ClimateMachine.Courant.advective_courant,
        solver_config;
        direction = HorizontalDirection(),
    )

    # compute known advective Courant number (based on initial conditions)
    ugeo_abs = FT(7)
    vgeo_abs = FT(5.5)
    Δt = solver_config.dt
    ca_h = ugeo_abs * (Δt / Δh) + vgeo_abs * (Δt / Δh)
    # vertical velocity is 0
    caᵥ = FT(0.0)
    @test isapprox(CFL_adv_v, caᵥ, atol = 10 * eps(FT))
    @test isapprox(CFL_adv_h, ca_h, atol = 0.0005)
    @test isapprox(CFL_adv, ca_h, atol = 0.0005)

    cb_test = 0
    result = ClimateMachine.invoke!(solver_config)
    # cb_test should be zero since user_info_callback not specified
    @test cb_test == 0

    result = ClimateMachine.invoke!(
        solver_config,
        user_info_callback = () -> cb_test += 1,
    )
    # cb_test should be greater than one if the user_info_callback got called
    @test cb_test > 0

    # Test that if dt is not adjusted based on final time the CFL is correct
    solver_config = ClimateMachine.SolverConfiguration(
        t0,
        timeend,
        driver_config,
        Courant_number = CFL,
        timeend_dt_adjust = false,
    )

    CFL_nondiff = ClimateMachine.DGMethods.courant(
        ClimateMachine.Courant.nondiffusive_courant,
        solver_config,
    )
    @test CFL_nondiff ≈ CFL

    # Test that if dt is not adjusted based on final time the CFL is correct
    for fixed_number_of_steps in (-1, 0, 10)
        solver_config = ClimateMachine.SolverConfiguration(
            t0,
            timeend,
            driver_config,
            Courant_number = CFL,
            fixed_number_of_steps = fixed_number_of_steps,
        )

        if fixed_number_of_steps < 0
            @test solver_config.timeend == timeend
        else
            @test solver_config.timeend ==
                  solver_config.dt * fixed_number_of_steps
            @test solver_config.numberofsteps == fixed_number_of_steps
        end
    end
end

main()
