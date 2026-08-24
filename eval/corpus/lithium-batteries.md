# Lithium-Ion Batteries: Cell Chemistry, Degradation and Pack Engineering

## Cell architecture and the intercalation principle

A lithium-ion cell stores energy by moving lithium ions between two host lattices rather than by
consuming either electrode, and that reversible intercalation is what distinguishes it from primary
chemistries. During discharge, lithium leaves the graphite anode, travels through a liquid
electrolyte of lithium hexafluorophosphate dissolved in organic carbonates, crosses a porous polymer
separator, and inserts into the layered oxide cathode, while the compensating electron travels the
external circuit and does the useful work. Charging drives the process backwards. The separator is
purely mechanical and electrically insulating, and its integrity is the last line of defence against
an internal short. Format matters more than it appears: cylindrical cells such as the 18650 and 21700
have a rigid steel can that contains internal pressure well and dissipates heat radially; prismatic
cells pack more densely into a rectangular volume; pouch cells achieve the highest gravimetric energy
by discarding the rigid enclosure entirely, but they swell as gas evolves and require external
compression to maintain even electrode contact.

## Cathode chemistries and their trade-offs

Almost every meaningful property of a cell is set by the cathode. Lithium cobalt oxide, the original
commercial chemistry, offers high volumetric energy and remains common in small consumer electronics,
but it is thermally fragile and cobalt is expensive and ethically fraught. Nickel-manganese-cobalt and
nickel-cobalt-aluminium chemistries dominate automotive traction, and the industry's steady move
toward higher nickel content — from a balanced third-third-third ratio toward eighty or ninety
percent nickel — raises specific energy and cuts cobalt, at the cost of reduced thermal stability and
greater moisture sensitivity in manufacturing. Lithium iron phosphate takes the opposite position:
roughly twenty to thirty percent lower energy density, but an olivine structure with strong
phosphorus-oxygen bonds that does not release oxygen on overheating, giving markedly better thermal
safety, several thousand cycles of life, and a bill of materials free of both cobalt and nickel. Its
flat discharge voltage curve is an operational nuisance, because state of charge cannot be inferred
accurately from terminal voltage across most of the usable range.

## The solid electrolyte interphase and calendar ageing

On the first charge, electrolyte decomposes at the graphite surface and deposits a thin passivating
film called the solid electrolyte interphase. This layer is essential and paradoxical: it conducts
lithium ions while blocking electrons, which halts further electrolyte decomposition, and a cell
without it would consume its electrolyte within a few cycles. Formation of a good interphase is why
manufacturing includes a slow, carefully controlled first-charge step that occupies expensive factory
time. But the layer continues to thicken slowly for the cell's whole life, consuming cyclable lithium
and raising internal resistance, and this proceeds whether or not the cell is used. That is calendar
ageing, and its rate is governed by temperature and by state of charge. Storage at high state of
charge holds the anode at a low potential that accelerates electrolyte reduction, and elevated
temperature accelerates everything according to an Arrhenius relationship, so a cell stored full at
forty Celsius can lose more capacity in a year than one cycled daily at a moderate temperature and
kept near half charge.

## Cycle ageing, lithium plating and fast charging

Cycling adds mechanical degradation on top of calendar ageing. Electrode particles expand and contract
with each intercalation cycle — graphite by about ten percent, silicon-containing anodes by several
hundred — and the resulting stress cracks particles, exposes fresh surface that grows more interphase,
and gradually loses electrical contact between active material and the conductive matrix. The most
dangerous cycling failure is lithium plating, which occurs when lithium arrives at the anode faster
than it can intercalate into the graphite lattice and instead deposits as metallic lithium on the
surface. It is promoted by low temperature, where solid-state diffusion is slow, by high charge
current, and by charging at high state of charge when the lattice is already nearly full. Plated
lithium partly becomes electrically isolated dead lithium and partly grows dendrites that can pierce
the separator. This is why competent fast-charging strategies taper current aggressively above
roughly sixty percent state of charge and refuse to fast charge a cold pack until it has been warmed.

## Thermal runaway and pack-level safety

Thermal runaway is a self-sustaining exothermic cascade with a well-characterised sequence. Above
roughly 80 to 120 Celsius the interphase begins to decompose exothermically; the exposed anode then
reacts with electrolyte, releasing more heat; around 150 to 200 Celsius the separator melts and
allows internal shorting; and in nickel-rich layered cathodes the material releases oxygen above
roughly 200 Celsius, which oxidises the flammable carbonate electrolyte inside a sealed can. Each
step raises temperature and accelerates the next, and once started the reaction cannot be stopped by
external cooling — the cell must be allowed to consume itself while its neighbours are protected.
Pack design therefore concentrates on propagation resistance rather than on prevention alone: cell
spacing and thermal barriers, directed venting so hot gas leaves the pack without impinging on
adjacent cells, current interrupt devices and positive temperature coefficient elements inside
cylindrical cells, and fusible links on individual cell tabs. Lithium iron phosphate packs are
substantially easier to make propagation-resistant because the cathode does not supply oxygen.

## Battery management, balancing and state estimation

A pack is a series-parallel array whose weakest series element bounds the whole, and the battery
management system exists to keep that from destroying the pack. Its non-negotiable duty is
protection: no cell may exceed its upper voltage limit, drop below its lower limit, or operate
outside its temperature window, and the system must be able to open a contactor. Its second duty is
balancing, because manufacturing spread and uneven thermal exposure cause cells to drift apart in
state of charge over hundreds of cycles; passive balancing bleeds charge from the highest cells
through resistors, while active balancing shuttles it to lower cells more efficiently at greater
cost and complexity. Its third duty is estimation. State of charge is inferred by combining coulomb
counting, which integrates current accurately but drifts without reference, with open-circuit
voltage correction, which is absolute but requires rest and is nearly useless on the flat plateau of
lithium iron phosphate; many systems now run a Kalman filter over an equivalent circuit model. State
of health tracks capacity fade and internal resistance growth, and it is what determines whether a
pack is fit for its original duty or ready for a second life in stationary storage.
