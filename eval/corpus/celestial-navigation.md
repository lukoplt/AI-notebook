# Celestial Navigation: Instruments, Sight Reduction and Passage Planning

## The longitude problem and the marine chronometer

Latitude has been measurable since antiquity by observing the noon altitude of the sun or the
elevation of Polaris, because latitude is a direct function of a measurable angle. Longitude is a
function of time, and that made it intractable for centuries. Because the Earth rotates fifteen
degrees per hour, knowing the difference between local apparent time and the time at a reference
meridian gives longitude immediately — four seconds of clock error equals one nautical mile at the
equator. Pendulum clocks were useless at sea, where a rolling deck and changing temperature destroyed
their rate. Britain's Longitude Act of 1714 offered a prize that drew two competing solutions. The
lunar distance method used the moon's motion against the fixed stars as a natural clock, requiring an
observation of the angle between moon and a listed star and then four hours of laborious computation.
John Harrison's sea clocks solved it mechanically, and by H4 in 1761 he had a watch that kept time to
a few seconds over a transatlantic passage using a temperature-compensating bimetallic strip and an
escapement needing no lubrication. Chronometers won on practicality; lunars survived as a backup into
the nineteenth century.

## The sextant and its errors

A sextant measures the angle between two objects by double reflection, which is what makes it usable
from a moving deck: the observer sees the horizon directly through the clear half of the horizon
glass while the index mirror superimposes the reflected celestial body, and the two images move
together with the ship rather than independently. Because the light reflects twice, moving the index
arm through one degree changes the measured angle by two, so a sixty-degree arc reads a hundred and
twenty degrees. Precision instruments read to 0.1 or 0.2 minutes of arc on a micrometer drum. Three
instrument errors must be handled before any observation is trusted. Perpendicularity error, from an
index mirror not square to the frame, and side error, from a horizon glass not square, are adjusted
out with the mirror screws. Index error, the residual reading when the instrument is truly set to
zero, is measured every session against the horizon or a star and applied as a correction to every
sight rather than adjusted away. Careless index error is the largest single source of avoidable
position error in practical celestial work.

## Sight taking and the sequence of corrections

A useful sight requires a sharp horizon, which restricts practical work to twilight for stars and
planets — the window when both the body and the horizon are visible — and to any clear moment for the
sun. The observer swings the sextant gently through a small arc so the body's reflected image traces a
shallow curve, and records the altitude at the bottom of the swing, which is the moment the
instrument is truly vertical. Time is noted to the second, because a one-second error moves the
position line a quarter of a nautical mile. The raw sextant altitude is then reduced to true altitude
through an ordered sequence. Index correction comes first. Dip corrects for the observer's height of
eye above the sea, since a raised observer sees a horizon depressed below true horizontal, at roughly
one minute of arc per metre of height. Refraction, which bends light downward through the atmosphere
and makes bodies appear higher than they are, is subtracted and is large and uncertain near the
horizon. For the sun and moon, semi-diameter converts the observed limb to the centre, and for the
moon, parallax corrects for observing from Earth's surface rather than its centre.

## Sight reduction and the intercept method

Sight reduction converts a corrected altitude and a time into a line of position, and the modern
approach is the Marcq St Hilaire intercept method. The navigator begins from an assumed position,
chosen for convenience of computation rather than accuracy, and calculates what the altitude of the
body would have been from there at the observed instant — the computed altitude — along with its
azimuth. Comparing computed altitude to observed altitude gives the intercept: if the observed
altitude is greater, the vessel is closer to the body's geographical position than the assumed
position was, and the line of position is drawn that many nautical miles toward the azimuth, one
minute of arc corresponding to one nautical mile. The line of position itself is a segment of a circle
of equal altitude centred on the body's geographical position, but that circle's radius is so large
that a straight line perpendicular to the azimuth is an excellent local approximation. A single line
gives only a constraint; two or three bodies observed at different azimuths intersect in a fix, and
navigators prefer azimuths separated by sixty degrees or more because shallow crossing angles
amplify small errors enormously.

## Almanacs, tables and the running fix

Reduction needs the body's position, and that comes from the Nautical Almanac, which tabulates
Greenwich Hour Angle and declination hourly for the sun, moon, four navigational planets and
fifty-seven selected stars, with interpolation tables for the intervening minutes and seconds.
Trigonometric solution of the navigational triangle was historically done with printed tables — HO
229 and HO 249 remain in service — and today it is as often done with a calculator or a spreadsheet
implementing the same spherical trigonometry directly. Because celestial bodies are rarely available
simultaneously outside twilight, the running fix is a routine necessity: a line of position obtained
in the morning is advanced along the vessel's course and distance made good to the time of a second,
later line, and their intersection gives a fix. The technique inherits all the error of the dead
reckoning used to advance it, so a running fix over six hours in a strong, poorly known current is a
weaker position than its clean plot suggests.

## Why the skill persists in the satellite era

Satellite positioning has been dominant since the 1990s and is more accurate by two orders of
magnitude, so the argument for celestial navigation is not accuracy — it is independence. GNSS is a
received signal from a distant, low-power transmitter, and it can be jammed, spoofed or denied. It
depends on the receiver, on the vessel's electrical system, and on infrastructure controlled by
someone else. A sextant, an almanac, a watch and a set of tables constitute a positioning system that
requires no power, emits nothing, cannot be spoofed, and works anywhere the sky is visible. Several
navies restored celestial training to their academy curricula in the 2010s after a period of removing
it, explicitly citing electronic warfare and spoofing risk. For long-distance sailors the argument is
similar in shape but different in emphasis: the equipment is cheap and inert, it does not fail when
the batteries flood, and the discipline of taking and reducing a daily sun sight keeps a navigator
attentive to the dead reckoning that any electronic outage would immediately force them back onto.
