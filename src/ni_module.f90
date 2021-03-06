module ni_module
use ni_types, only: dp, pi, type_grid, type_fun, ni_env
use lebedev, only: lebedev_grid,&
                   get_number_of_lebedev_grid
use ni_grid, only: build_onecenter_grid,&
                   build_twocenter_grid,&
                   build_threecenter_grid,&
                   type_grid,&
                   radial_grid,&
                   allocate_grid,&
                   deallocate_grid
use spherical_harmonics, only: rry_lm
use ni_fun, only: forward_derivative_weights, spline
implicit none

type :: type_atom
   real(kind=dp), dimension(3) :: r = 0.0_dp
   integer :: z = 1
end type type_atom

public :: integration_twocenter, integration_onecenter, integration_threecenter,&
           radial_integration, qsort

contains
subroutine gauss_der(r, alpha, y, y1, y2, y3, y4, y5)
   implicit none
   ! Input
   real(kind=dp), dimension(:), intent(in) :: r
   real(kind=dp), intent(in) :: alpha
   ! Output
   real(kind=dp), dimension(size(r)) :: y, y1, y2, y3, y4, y5
   y = exp(-alpha * r**2)
   y1 = -2._dp * alpha * r * y
   y2 = (4._dp * alpha * r**2 - 2._dp) * alpha * y
   y3 = (12._dp * r - 8._dp * alpha * r**3) * alpha**2 * y
   y4 = (16._dp * alpha**4 * r**4 - 48._dp * alpha**3 * r**2 + 12._dp*alpha**2) * y
   y5 = -8._dp * (4_dp*alpha**5 * r**5 - 20._dp * alpha**4 * r**3 + 15._dp*alpha**3*r) * y
end subroutine gauss_der

! **********************************************
!> \brief Computes the radial integral of f(r)
!> \param f(n): The tabulated function at n grid points
!> \param r(n): The tabulated grid points
!> \param n: The number of radial grid points
!> \param integral: The integral's value
! **********************************************
subroutine radial_integration(f, r, n, addr2, integral)
   implicit none
   real(kind=dp), dimension(:), intent(in) :: f, r
   integer, intent(in) :: n
   logical, intent(in) :: addr2
   real(kind=dp) :: integral
   real(kind=dp), dimension(:), allocatable :: rad, wr, d2f, fun
   integer :: i

   allocate(rad(n))
   allocate(wr(n))
   allocate(d2f(n))
   allocate(fun(n))

   integral = 0.0_dp
   
   ! Put the radial grid points into `rad` and their weights into `wr`
   call radial_grid(r=rad, wr=wr, n=n, addr2=addr2, quadr=1)

   ! Create the spline
   call spline(r=r, y=f, n=size(r), yspline=d2f)
   
   ! Sum over all radial grid points
   do i=1,n
      call interpolation(gr=r, gy=f, spline=d2f, r=rad(i), y=fun(i))
   enddo
   integral = kah_sum( wr * fun )

   deallocate(rad)
   deallocate(wr)
   deallocate(d2f)
   deallocate(fun)
end subroutine radial_integration

! Compute <Y_L | f>_w^ri for all r_i
subroutine pp_projector(l, m, r, f, s, d12, p)
   implicit none
   ! Inputs
   integer, intent(in) :: l, m
   real(kind=dp), dimension(:), intent(in) :: r, f, s
   real(kind=dp), dimension(3), intent(in) :: d12
   ! Outputs
   real(kind=dp), dimension(size(r)) :: p
   ! Local variables
   real(kind=dp), dimension(:), allocatable :: ylm, funs
   real(kind=dp), dimension(3) :: gr
   real(kind=dp) :: norm
   integer :: ileb, iang, irad

   ileb = get_number_of_lebedev_grid(l=l+5)
   allocate(ylm(lebedev_grid(ileb)%n))
   do iang=1,lebedev_grid(ileb)%n
      call rry_lm(l=l, m=m, r=lebedev_grid(ileb)%r(:, iang), y=ylm(iang))
   enddo

   ! Compute the value of f at each point
   allocate(funs(lebedev_grid(ileb)%n))
   do irad=1,size(r)
      funs = 0.0_dp
      do iang=1,lebedev_grid(ileb)%n
         gr = r(irad) * lebedev_grid(ileb)%r(:, iang)
         norm = norm2( (gr-d12) )
         call interpolation(gr=r, gy=f, spline=s, r=norm, y=funs(iang))
      enddo
      p(irad) = sum(lebedev_grid(ileb)%w * ylm * funs)
   enddo
   deallocate(funs)
   deallocate(ylm)
   p = 4.0_dp * pi * p
end subroutine pp_projector

!  nloc                            L           L
! V     = Σ 1/Ω * Σ w (V_l(r_i) * P (alpha) * P (beta))
!         L       i                i           i
subroutine pp_nonloc(rv, v, rp1, p1, rp2, p2, d12, d13, lmax, nrad, integral)
   implicit none
   ! Input
   real(kind=dp), dimension(:), intent(in) :: rv, v, rp1, p1, rp2, p2
   real(kind=dp), dimension(3), intent(in) :: d12, d13
   integer, intent(in) :: lmax, nrad
   ! Output
   real(kind=dp) :: integral
   ! Local variables
   real(kind=dp), dimension(nrad) :: r, wr, gv, gp1, gp2, gsv, gsp1, gsp2,&
                                     proj1, proj2
   real(kind=dp), dimension(size(rv)) :: sv
   real(kind=dp), dimension(size(rp1)) :: sp1
   real(kind=dp), dimension(size(rp2)) :: sp2
   real(kind=dp), dimension((lmax+1)**2) :: integral_sub
   integer :: i, il, im, h!elp
   ! End header

   ! First we transpose the three functions to a common grid
   call radial_grid(r=r, wr=wr, n=nrad, addr2=.true., quadr=2) !2=hermite
   call spline(r=rv, y=v, n=size(rv), yspline=sv)
   call spline(r=rp1, y=p1, n=size(rp1), yspline=sp1)
   call spline(r=rp2, y=p2, n=size(rp2), yspline=sp2)

   do i=1,nrad
      call interpolation(rv , v , sv , r=r(i), y=gv(i) )
      call interpolation(rp1, p1, sp1, r=r(i), y=gp1(i))
      call interpolation(rp2, p2, sp2, r=r(i), y=gp2(i))
   enddo

   ! The interpolated functions need splines as well
   call spline(r=r, y=gv , n=size(r), yspline=gsv)
   call spline(r=r, y=gp1, n=size(r), yspline=gsp1)
   call spline(r=r, y=gp2, n=size(r), yspline=gsp2)

   ! Then we go over all L={l,m} where (l .le. lmax)
   h = 0
   do il=0,lmax
      do im=-il,+il
         h = h + 1
         ! gv – the interpolation of V_l – we can use as is
         call pp_projector(l=il, m=im, r=r, f=gp1, s=gsp1, d12=d12, p=proj1)
         call pp_projector(l=il, m=im, r=r, f=gp2, s=gsp2, d12=d13, p=proj2)
         integral_sub(h) = sum(wr * gv * proj1 * proj2)
      enddo
   enddo
   integral = kah_sum(integral_sub)
end subroutine pp_nonloc

subroutine integration_onecenter(nang, nshell, r, y, spline, quadr, integral)
   implicit none
   ! Input
   integer, intent(in) :: nang, nshell
   real(kind=dp), dimension(:), intent(in) :: r, y, spline
   integer, intent(in) :: quadr
   ! Output
   real(kind=dp) :: integral
   ! Local variables
   integer :: ileb, ngrid, i
   type(type_grid), TARGET :: grid
   type(type_grid), pointer :: pgrid
   real(kind=dp), dimension(:), allocatable :: int_i
   real(kind=dp) :: norm
   ! End header

   ileb = get_number_of_lebedev_grid(n=nang)
   ngrid = lebedev_grid(ileb)%n * nshell
   allocate(int_i(ngrid))
   int_i = 0.0_dp

   pgrid => grid
   call build_onecenter_grid(ileb=ileb, nshell=nshell, addr2=.true.,&
                             quadr=quadr, grid=pgrid)

   do i = 1, size(grid%w)
      norm = norm2( grid%r(:, i) )
      call interpolation(r, y, spline, norm, int_i(i))
   enddo

   integral = kah_sum(grid%w * int_i)

   deallocate(int_i)
   call deallocate_grid(grid=pgrid)
end subroutine integration_onecenter

subroutine integration_twocenter(l, m, nshell, d12, r1, y1, r2, y2, &
                                 spline1, spline2, integral)
   implicit none
   ! Input
   integer, dimension(2), intent(in) :: l, m, nshell
   real(kind=dp), dimension(3), intent(in) :: d12
   real(kind=dp), dimension(:), intent(in) :: r1, y1, r2, y2, &
                                              spline1, spline2
   ! Output
   real(kind=dp) :: integral
   ! Local variables
   type(type_grid), TARGET :: grid
   type(type_grid), pointer :: pgrid
   real(kind=dp), dimension(:), allocatable :: f1, f2
   real(kind=dp) :: norm, ylm
   integer, dimension(2) :: ileb
   integer :: ngrid, i

   ileb(1) = get_number_of_lebedev_grid(n=302)
   ileb(2) = get_number_of_lebedev_grid(n=302)

   ngrid = lebedev_grid(ileb(1))%n * nshell(1) + &
           lebedev_grid(ileb(2))%n * nshell(2)
   allocate(f1(ngrid))
   allocate(f2(ngrid))

   pgrid => grid
   call build_twocenter_grid(ileb=ileb, nshell=nshell, d12=d12,&
                             addr2=.true., grid=pgrid)

   do i=1,ngrid
      if (grid%w(i) .eq. 0.0_dp) cycle         
      norm = norm2( grid%r(:, i) )
      call interpolation(r1, y1, spline1, norm, f1(i))
      call rry_lm(l=l(1), m=m(1), r=grid%r(:, i)/norm, y=ylm)
      f1(i) = f1(i) * ylm

      norm = norm2( (grid%r(:, i) - d12 ) )
      call interpolation(r2, y2, spline2, norm, f2(i))
      call rry_lm(l=l(2), m=m(2), r=(grid%r(:, i)-d12)/norm, y=ylm)
      f2(i) = f2(i) * ylm
   enddo

   integral = kah_sum(grid%w * f1*f2 )

   deallocate(f1)
   deallocate(f2)
   call deallocate_grid(grid=pgrid)
end subroutine integration_twocenter

subroutine integration_threecenter(nang, nshell, d12, d13, &
                                   r1, y1, r2, y2, r3, y3, &
                                   spline1, spline2, spline3, integral)
   implicit none
   ! Input
   integer, dimension(3), intent(in) :: nang, nshell
   real(kind=dp), dimension(3), intent(in) :: d12, d13
   real(kind=dp), dimension(:), intent(in) :: r1, y1, &
                   r2, y2, r3, y3, spline1, spline2, spline3
   ! Output
   real(kind=dp) :: integral

   ! Local variables
   type(type_grid), TARGET :: grid
   type(type_grid), pointer :: pgrid
   real(kind=dp), dimension(:), allocatable :: f1, f2, f3
   real(kind=dp) :: norm
   integer, dimension(3) :: ileb
   integer :: ngrid, i

   ileb(1) = get_number_of_lebedev_grid(n=nang(1))
   ileb(2) = get_number_of_lebedev_grid(n=nang(2))
   ileb(3) = get_number_of_lebedev_grid(n=nang(3))
   ngrid = lebedev_grid(ileb(1))%n * nshell(1) + &
           lebedev_grid(ileb(2))%n * nshell(2) + &
           lebedev_grid(ileb(3))%n * nshell(3)

   allocate(f1(ngrid))
   allocate(f2(ngrid))
   allocate(f3(ngrid))

   pgrid => grid
   call build_threecenter_grid(ileb=ileb, nshell=nshell, d12=d12, d13=d13, &
                               addr2=.true., grid=pgrid)

   do i=1,ngrid
      norm = norm2( grid%r(:, i) )
      call interpolation(r1, y1, spline1, norm, f1(i))

      norm = norm2( (grid%r(:, i) - d12 ) )
      call interpolation(r2, y2, spline2, norm, f2(i))

      norm = norm2( (grid%r(:, i) - d13 ) )
      call interpolation(r3, y3, spline3, norm, f3(i))
   enddo
   integral = kah_sum(grid%w * f1*f2*f3 )

   deallocate(f1)
   deallocate(f2)
   deallocate(f3)
   call deallocate_grid(grid=pgrid)
end subroutine integration_threecenter

subroutine kinetic_energy(l, m, nshell, r1, y1, r2, y2, d12,&
                          spline1, spline2, integral)
   implicit none
   ! Input
   integer, dimension(2), intent(in) :: l, m, nshell
   real(kind=dp), dimension(:), intent(in) :: r1, y1, &
                                              r2, y2, spline1, spline2
   real(kind=dp), dimension(3), intent(in) :: d12
   ! Output
   real(kind=dp) :: integral
   ! Local variables
   type(type_grid), TARGET :: grid
   type(type_grid), pointer :: pgrid
   real(kind=dp), dimension(:), allocatable :: rf2, d2rf2, d2rf2_spline, f1, f2
   real(kind=dp) :: norm, ylm, df2
   integer, dimension(2) :: ileb
   integer :: ngrid, i

   ileb = get_number_of_lebedev_grid(n=590)  ! TODO
   if (all(d12 .eq. (/0._dp, 0._dp, 0._dp/))) then
      ngrid = lebedev_grid(ileb(1))%n * nshell(1)
   else
      ngrid = lebedev_grid(ileb(1))%n * nshell(1) &
               + lebedev_grid(ileb(2))%n * nshell(2)
   endif

   allocate(f1(ngrid))
   allocate(f2(ngrid))
   allocate(d2rf2(size(r2)))
   allocate(d2rf2_spline(size(r2)))

   pgrid => grid
   call build_twocenter_grid(ileb=ileb, nshell=nshell, d12=d12, addr2=.false.,&
                             grid=pgrid)
   ! < f1 | -0.5*🔺 | f2 >
   ! Laplace_r = 1/r * d_r^2(r*f2)
   rf2 = r2*y2
   ! Get the 2nd derivative d_r^2(r*f2) as well as its spline
   call spline(r2, rf2, size(r2), d2rf2)
   call spline(r2, d2rf2, size(r2), d2rf2_spline)
   d2rf2 = d2rf2/r2

   if (r2(1) .lt. epsilon(0._dp)) then
      d2rf2(1) = 0._dp
   endif

   do i=1,ngrid
      ! T = -0.5 * ∫f1*Ylm * (D_r f2(r) - l'(l'+1)*f2/r^2 ) * Yl'm'
      norm = norm2( grid%r(:, i) )
      call interpolation(r1, y1, spline1, norm, f1(i))
      call rry_lm(l=l(1), m=m(1), r=grid%r(:, i)/norm, y=ylm)
      f1(i) = f1(i) * ylm * norm**2

      norm = norm2( (grid%r(:, i) - d12) )
      call interpolation(r2, d2rf2, d2rf2_spline, norm, df2)  ! D_r f2
      call interpolation(r2, y2, spline2, norm, f2(i))        ! f2
      call rry_lm(l=l(2), m=m(2), r=(grid%r(:, i) - d12)/norm, y=ylm)

      ! (D_r f2(r) - l'(l'+1)*f2/r^2 ) * Yl'm'
      f2(i) = df2 - REAL(l(2)*(l(2)+1), dp)*f2(i)/norm**2
      f2(i) = f2(i) * ylm
   enddo

   integral = -0.5_dp*kah_sum(grid%w * f1*f2)

   deallocate(f1)
   deallocate(f2)
   deallocate(d2rf2)
   deallocate(d2rf2_spline)
   call deallocate_grid(grid=pgrid)
end subroutine kinetic_energy

subroutine coulomb_integral(nshell, coul_n, d12, l, m,&
                            r1, y1, r2, y2, s1, s2, integral)
   implicit none
   ! Input
   integer, dimension(2), intent(in) :: nshell, l, m
   integer, intent(in) :: coul_n
   real(kind=dp), dimension(3), intent(in) :: d12
   real(kind=dp), dimension(:), intent(in) :: r1, y1, r2, y2, s1, s2
   ! Output
   real(kind=dp) :: integral
   ! Local variables
   integer :: i, j
   ! Local variables (potential)
   real(kind=dp), dimension(coul_n) :: f, gi, hi, G, H, coul_w
   real(kind=dp), dimension(:), allocatable :: coul_r, pot, pots

   ! 1: Evaluate the Coulomb potential on a radial grid around A
   ! ! the integral is purely radial => addr2=False
   allocate(coul_r(coul_n))
   allocate(pot(coul_n))
   allocate(pots(coul_n))
   call radial_grid(r=coul_r, &
                    wr=coul_w, &
                    n=coul_n, addr2=.false., quadr=1)

   do i=1,coul_n
      call interpolation(r1, y1, s1, coul_r(i), f(i))
   enddo
   gi = coul_w * coul_r**(l(1)+2) * f
   hi = coul_w * coul_r**(1-l(1)) * f

   G(coul_n) = sum(gi)
   H(coul_n) = 0.0_dp
   do j=coul_n,1,-1
      pot(j) = coul_r(j)**(-l(1)-1) * G(j) + coul_r(j)**l(1) * H(j)
      G(j-1) = G(j) - gi(j)
      H(j-1) = H(j) + hi(j)
   enddo

   pot = pot * 4.0_dp*pi/(2.0_dp*l(1)+1.0_dp)
   call spline(coul_r, pot, coul_n, pots)

   ! 2: Calculate the overlap of y2(r-d12) and the coulomb potential
   call integration_twocenter(l=l, m=m, nshell=nshell, d12=d12, &
                              r1=coul_r, y1=pot, r2=r2, y2=y2,&
                              spline1=pots, spline2=s2, integral=integral)

   deallocate(coul_r)
   deallocate(pot)
   deallocate(pots)
end subroutine coulomb_integral

subroutine coulomb_integral_grid(nang, nshell, d12, r1, y1, r2, y2, s1, s2, integral)
   implicit none
   ! Input
   integer, dimension(2), intent(in) :: nang, nshell
   real(kind=dp), dimension(3), intent(in) :: d12
   real(kind=dp), dimension(:), allocatable, intent(in) :: r1, y1, r2, y2, s1, s2
   ! Output
   real(kind=dp) :: integral
   ! Local variables
   type(type_grid), TARGET :: grid
   type(type_grid), pointer :: pgrid
   real(kind=dp), dimension(:), allocatable :: f, gi, hi, G, H
   real(kind=dp) :: norm
   integer, dimension(2) :: ileb
   integer :: i, j, l, ngrid
   ! Local variables (potential)
   real(kind=dp), dimension(:), allocatable :: coul_r, coul_w, grid_r2, pot, f1, f2
   real(kind=dp) :: temp
   integer :: coul_n 

   l = 0 ! Quantum number

   ! 1: Evaluate the Coulomb potential on the two-center grid
   ileb(1) = get_number_of_lebedev_grid(n=nang(1))
   ileb(2) = get_number_of_lebedev_grid(n=nang(2))

   ngrid = lebedev_grid(ileb(1))%n * nshell(1) + &
           lebedev_grid(ileb(2))%n * nshell(2)

   ! TODO
   ! When integrating f1 - retrieving the coulomb potential - the radial weights
   ! need to be included in order to get the right potential. After that the
   ! regular weights are used for the overlap integral
   pgrid => grid
   call build_twocenter_grid(ileb=ileb, nshell=nshell, d12=d12, &
                             addr2=.false., grid=pgrid)

   ! First we need all unique distances
   !! together with the weights
   allocate(coul_r(ngrid))
   allocate(coul_w(ngrid))
   do i=1,ngrid
      grid_r2(i) = sqrt(sum(grid%r(:, i)**2))
   enddo
   call qsort_sim2(grid_r2, grid%w)

   coul_n = 0; temp = 0._dp
   do i=1,ngrid
      if (grid_r2(i) == temp) cycle
      coul_n = coul_n + 1
      temp = grid_r2(i)
      coul_r(coul_n) = temp
      coul_w(coul_n) = grid%w(i)
   enddo

   ! Next we evaluate the coulomb potential and spline at those distances
   allocate(pot(coul_n))
   allocate(f(coul_n))
   allocate(gi(coul_n))
   allocate(hi(coul_n))
   allocate(G(coul_n))
   allocate(H(coul_n))

   do i=1,coul_n
      call interpolation(r1, y1, s1, coul_r(i), f(i))
   enddo
   gi = coul_r**(l+2) * f * coul_w
   hi = coul_r**(1-l) * f * coul_w

   G(coul_n) = sum(gi)
   H(coul_n) = 0.0_dp
   do j=coul_n,1,-1
      pot(j) = coul_r(j)**(-l-1) * G(j) + coul_r(j)**l * H(j)
      G(j-1) = G(j) - gi(j)
      H(j-1) = H(j) + hi(j)
   enddo

   pot = pot * 4.0_dp*pi/(2.0_dp*l+1.0_dp)
   deallocate(f)
   deallocate(gi)
   deallocate(hi)
   deallocate(G)
   deallocate(H)

   ! 2: Finally calculate the overlap of y2(r-d12) and the coulomb potential
   allocate(f1(ngrid))
   allocate(f2(ngrid))
   do i=1,ngrid
      ! evaluate the potential
      norm = norm2( grid%r(:, i) )
      ! Look for 
      do j=1,coul_n
         f1(i) = j
         if ( norm .eq. coul_r(j) ) then
            f1(i) = pot(j)
            exit
         endif
      enddo
      if (f1(i) .eq. j) then
         print *, 'oh noes', i, j
      endif
      ! evaluate y2 at the same point
      norm = norm2( (grid%r(:, i) - d12 ) )
      call interpolation(r2, y2, s2, norm, f2(i))
   enddo

   integral = kah_sum(grid%w * f1*f2 )

   deallocate(f1)
   deallocate(f2)
   deallocate(pot)
   deallocate(coul_r)
   deallocate(coul_w)
   call deallocate_grid(grid=pgrid)
end subroutine coulomb_integral_grid

subroutine derivative_point(r, y, r0, y1)
   implicit none
   ! Input
   real(kind=dp), dimension(:), intent(in) :: r, y
   real(kind=dp), intent(in) :: r0
   ! Output
   real(kind=dp) :: y1
   ! Local variables
   real(kind=dp), dimension(3,3,5) :: coeff
   integer :: low, upper, high

   call bisection(r=r, r0=r0, low=low, upper=upper)
   high = low + 5
   if (high .gt. size(r)) high = size(r)

   call forward_derivative_weights(order=2, x0=r0, r=r(low:high), coeff=coeff)
   y1 = sum( coeff(1,2,1:3) * y(low:low+2) )  ! 2nd order accuracy
   ! this will crash/yield 0 if we want the derivative at the end points
end subroutine derivative_point


! Given a function `gy` on a grid `gr` and a requested
! function value y(r) interpolates the function value `y` using `spline`
subroutine interpolation(gr, gy, spline, r, y, yprime)
   ! Input
   real(kind=dp), dimension(:), intent(in) :: gr, gy
   real(kind=dp), dimension(size(gr)), intent(in) :: spline
   real(kind=dp), intent(in) :: r
   ! Output
   real(kind=dp) :: y
   real(kind=dp), OPTIONAL :: yprime
   ! Local variables
   integer :: low, upper
   real(kind=dp) :: A, B, C, D, h

   ! find the closest grid point by bisection
   call bisection(r=gr, r0=r, low=low, upper=upper)

   if (gy(low) .eq. 0._dp .and. gy(upper) .eq. 0._dp) then
      y = 0._dp
   elseif (gr(upper) .eq. r) then
      y = gy(upper)
      if (present(yprime)) call derivative_point(r=gr, y=gy, r0=r, y1=yprime)
   else if (gr(low) .eq. r) then
      y = gy(low)
      if (present(yprime)) call derivative_point(r=gr, y=gy, r0=r, y1=yprime)
   else if ((gr(upper) .gt. r) .and. (gr(low) .lt. r)) then
      h = gr(upper)-gr(low)
      A = (gr(upper)-r)/h
      B = (r-gr(low))/h
      C = (A**3.0_dp-A) * (h**2.0_dp)/6.0_dp
      D = (B**3.0_dp-B) * (h**2.0_dp)/6.0_dp
      y = A*gy(low) + B*gy(upper) + C*spline(low) + D*spline(upper)
      if (abs(y) .gt. 1.e15_dp) then
         print *, r
         print *, y
         print *, gr(upper), gr(low), gy(upper), gy(low)
         print *, spline(low), spline(upper)
         print *, A, B, C, D
         print *, "End interpolation output"
      endif
      ! y = A*gy(low) + B*gy(upper)
      if (present(yprime)) then
      yprime = ( gy(upper)-gy(low) )/h - (3._dp*A**2-1._dp)*h/6._dp*spline(low)&
                                       + (3._dp*B**2-1._dp)*h/6._dp*spline(upper)
      endif
   else if (gr(upper) .lt. r) then
      ! If the supplied r is higher than maxval(gr)
      y = gy(upper)
      if (present(yprime)) yprime = 0.0_dp
      ! print *, 'Extrapolation up!'
   else if (gr(low) .gt. r) then
      ! If the supplied r is lower than minval(gr)
      y = gy(low)
      if (present(yprime)) call derivative_point(r=gr, y=gy, r0=r, y1=yprime)
      ! print *, 'Extrapolation!'
   endif
end subroutine interpolation

   subroutine read_nfun(fn, gridax, gridf)
      CHARACTER(len=*) :: fn
      real(kind=dp), dimension(:), allocatable :: gridax, gridf
      integer :: dim, i

      open(unit=100, file=fn)
      read(100, *) dim
      if (.not. allocated(gridax)) then
         allocate(gridax(dim))
      endif
      if (.not. allocated(gridf)) then
         allocate(gridf(dim))
      endif
      do i=1, dim
         read(100, *) gridax(i), gridf(i)
      enddo
      close(100)
   end subroutine read_nfun

subroutine bisection(r, r0, low, upper)
   implicit none
   ! Input
   real(kind=dp), dimension(:), intent(in) :: r
   real(kind=dp), intent(in) :: r0
   ! Output
   integer :: low, upper
   ! Local variables
   integer :: mid

   low = 1
   upper = size(r)
   do while (upper .gt. low+1)
      mid = NINT((low+upper)/2.0_dp)
      if (r(mid) .gt. r0) then
         upper = mid
      else
         low = mid
      endif
      if (r(low) .eq. r0) upper = low 
      if (r(upper) .eq. r0) low = upper 
   enddo
end subroutine bisection

recursive subroutine qsort(arr)
   implicit none
   ! Input
   real(kind=dp), dimension(:) :: arr
   ! real(kind=dp), dimension(:, :) :: brr
   ! Local variables
   integer :: first, last, i, j
   ! real(kind=dp), dimension(3) :: temp_arr
   real(kind=dp) :: a, temp

   first = 1
   last = size(arr, 1)
   a = arr( (first+last)/2 )
   i = first
   j = last

   do
      do while (arr(i) .lt. a)
         i = i+1
      enddo
      do while (arr(j) .gt. a)
         j = j-1
      enddo
      if (j .le. i) exit
      temp = arr(i); arr(i) = arr(j); arr(j) = temp;
      ! temp_arr = brr(i, :); brr(i, :) = brr(j, :); brr(j, :) = temp_arr;
      i = i+1
      j = j-1
   enddo

   if (first .lt. (i-1)) call qsort( arr(first:i-1))!, brr(first:i-1, :) )
   if ((j+1) .lt. last) call qsort( arr(j+1:last))!, brr(j+1:last, :) )
end subroutine qsort

recursive subroutine qsort_sim2(arr, brr)
   implicit none
   ! Input
   real(kind=dp), dimension(:) :: arr
   real(kind=dp), dimension(:) :: brr
   ! Local variables
   integer :: first, last, i, j
   real(kind=dp) :: a, temp

   first = 1
   last = size(arr, 1)
   a = arr( (first+last)/2 )
   i = first
   j = last

   do
      do while (arr(i) .lt. a)
         i = i+1
      enddo
      do while (arr(j) .gt. a)
         j = j-1
      enddo
      if (j .le. i) exit
      temp = arr(i); arr(i) = arr(j); arr(j) = temp;
      temp = brr(i); brr(i) = brr(j); brr(j) = temp;
      i = i+1
      j = j-1
   enddo

   if (first .lt. (i-1)) call qsort_sim2( arr(first:i-1), brr(first:i-1) )
   if ((j+1) .lt. last) call qsort_sim2( arr(j+1:last), brr(j+1:last) )
end subroutine qsort_sim2

function kah_sum(arr)
   implicit none
   real(kind=dp), dimension(:) :: arr
   real(kind=dp) :: sum, c, t, kah_sum
   integer :: i

   sum = arr(1)
   c = 0._dp

   do i=2, size(arr)
      t = sum + arr(i)
      if (abs(sum) .ge. abs(arr(i))) then
         c = c + (sum-t) + arr(i)
      else
         c = c + (arr(i)-t) + sum
      endif
      sum = t
   enddo
   kah_sum = sum + c
end function kah_sum

end module ni_module
