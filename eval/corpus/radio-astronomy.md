# Radio Astronomy: Instruments, Interferometry and Signal Processing

## The radio window and emission mechanisms

Earth's atmosphere is transparent across a broad band from roughly ten megahertz to about one
terahertz, and this radio window is the second great opening onto the universe after the optical one.
Below ten megahertz the ionosphere reflects incoming radiation back to space, which is why the
lowest-frequency astronomy must be done from orbit or from the lunar far side. Above a few hundred
gigahertz, water vapour and oxygen absorb strongly, which drives millimetre observatories to dry,
high sites such as the Atacama plateau. What arrives through the window comes from two distinct
physical processes. Thermal emission follows a blackbody spectrum and traces warm dust and ionised
gas, growing brighter with frequency. Non-thermal synchrotron emission, produced by relativistic
electrons spiralling in magnetic fields, has a power-law spectrum that falls with frequency and is
often strongly polarised; it dominates supernova remnants, radio galaxies and pulsars. A spectral
index measured across several frequencies separates them immediately, which is why multi-band
observation is standard practice rather than a luxury.

## Single-dish telescopes, beam and system temperature

A filled-aperture dish is characterised first by its beam. The angular resolution of any diffraction-
limited aperture is approximately the wavelength divided by the diameter, and because radio
wavelengths exceed optical ones by five or six orders of magnitude, a hundred-metre radio dish
delivers a beam of arcminutes where a modest optical telescope delivers arcseconds. This is the
central difficulty of the field and the reason interferometry was invented. Sensitivity is governed
by the system temperature, the sum of every noise contribution referred to the receiver input:
the receiver's own noise, spillover from ground radiation entering past the edge of the dish,
atmospheric emission, and the cosmic microwave background. Cryogenic cooling of the low-noise
amplifier to around twenty kelvin suppresses the dominant receiver term, which is why the front end
of every serious radio telescope sits inside a dewar. The radiometer equation ties it together:
sensitivity improves as the square root of the product of bandwidth and integration time, so a
weak source is reached either by observing wider or by observing longer.

## Interferometry and aperture synthesis

An interferometer replaces one impossible dish with many achievable ones. Two antennas separated by a
baseline receive the same wavefront at slightly different times; correlating their signals yields a
complex visibility, and the van Cittert–Zernike theorem establishes that this visibility is a single
Fourier component of the sky brightness distribution, sampled at a spatial frequency set by the
baseline length in wavelengths. An array of N antennas provides N(N−1)/2 simultaneous baselines, and
Earth's rotation sweeps each baseline through the Fourier plane over the course of an observation —
the technique called Earth-rotation aperture synthesis, which fills in coverage for free. Resolution
is then set by the longest baseline rather than by any single dish, and Very Long Baseline
Interferometry extends baselines to the diameter of the planet by recording signals against
hydrogen maser clocks and correlating them afterwards, reaching angular resolutions below a
milliarcsecond. The cost is that the array measures only the spatial frequencies its baselines
sample; short spacings missing from the centre of the plane mean smooth extended structure is
resolved out and simply absent from the data.

## Imaging, deconvolution and calibration

Because sampling of the Fourier plane is incomplete, the direct inverse transform of the visibilities
is not an image but a dirty image: the true sky convolved with the array's point spread function, the
dirty beam, which is riddled with sidelobes from unsampled gaps. Recovering a usable image requires
deconvolution, and the workhorse algorithm remains CLEAN, which iteratively locates the brightest
peak in the dirty image, subtracts a scaled copy of the dirty beam at that position, records the
component, and repeats until the residual is noise-like; the accumulated components are then restored
with a smooth Gaussian beam. Maximum-entropy methods and modern compressed-sensing approaches handle
extended emission better but have not displaced CLEAN for point-dominated fields. None of it works
without calibration. Atmospheric phase fluctuations, instrumental gain drift and bandpass shape are
tracked by periodically observing a bright unresolved calibrator of known position, interleaved with
the target every few minutes, and self-calibration then uses the target's own signal to refine the
solution once a preliminary model exists.

## Pulsars, dispersion and timing

Pulsars are rotating neutron stars whose beamed emission sweeps past Earth once per rotation,
producing pulse periods from milliseconds to seconds with a regularity that rivals atomic clocks.
Observing them is complicated by the interstellar medium, whose free electrons make propagation
frequency-dependent: lower frequencies arrive later, and the delay scales as the inverse square of
frequency multiplied by the dispersion measure, the integrated electron column density along the line
of sight. An uncorrected wide band therefore smears the pulse into invisibility, and the correction —
either incoherent dedispersion across filterbank channels or coherent dedispersion applied to the
raw voltage series — must be performed before averaging. Once corrected, individual pulses are
folded at the pulse period over minutes to hours to build a stable average profile. Timing then
proceeds by cross-correlating each observation's profile against a template to extract a time of
arrival, referring it to the solar system barycentre, and fitting a model. Residuals at the
nanosecond level are what make pulsar timing arrays sensitive to nanohertz gravitational waves.

## Radio frequency interference and spectrum management

Astronomical radio sources are extraordinarily faint — the total energy ever collected by radio
astronomy is often compared to that of a falling snowflake — and terrestrial transmitters are
overwhelmingly strong by comparison. Radio frequency interference is therefore not an occasional
nuisance but a permanent operating condition, and it comes in distinct forms requiring distinct
responses. Narrowband continuous carriers from broadcast and communication services are excised in
frequency. Impulsive broadband interference from ignition systems, power lines and switching
supplies is excised in time. Satellite downlinks are the hardest case because they move through the
beam and cannot be avoided by scheduling, and large low-orbit constellations have made this
substantially worse in the last decade. Institutional protection comes from radio quiet zones —
legally enforced areas restricting transmitters around major observatories — and from internationally
allocated protected bands, notably the 1,400 to 1,427 megahertz band reserved around the neutral
hydrogen line at 1,420 megahertz. Neither is sufficient alone, and modern correlators now excise
interference in real time before data is ever written.
