# Typography: From Movable Type to Digital Composition

## Gutenberg's actual invention

The popular account credits Johannes Gutenberg with inventing movable type, which is wrong — Bi Sheng
cast ceramic type in eleventh-century China and Korean foundries were casting bronze type a century
before Mainz. What Gutenberg invented, around 1450, was a manufacturing system in which the pieces
were mutually dependent and none was sufficient alone. The hand mould was the centrepiece: an
adjustable two-part instrument that let a single craftsman cast thousands of identical sorts to a
consistent body height, adjusting width for each letter while holding height and depth invariant.
That dimensional consistency is what makes a page of set type lie flat and print evenly, and it is
the hard problem. Around the mould he assembled a type metal alloy of lead, tin and antimony that
melted at a workable temperature and, unusually, expanded slightly on solidifying so it filled the
matrix crisply; an oil-based ink with the body to adhere to metal, where existing water-based inks
beaded and slid off; and a press adapted from wine and paper presses to deliver even platen
pressure. The European alphabet's small character set made the economics work in a way that thousands
of Chinese characters never permitted.

## Anatomy, measurement and the point system

Type is described by a vocabulary developed over five centuries of hand composition. The baseline is
the invisible line on which characters sit; the x-height is the height of the lowercase x and it
governs apparent size far more than the nominal point size does, which is why two fonts set at eleven
point can look wildly different in scale. Ascenders rise above the x-height, descenders fall below the
baseline, and the cap height is usually slightly below the ascender line. Counters are the enclosed
interior spaces of letters like o and e; serifs are the terminal strokes that distinguish a Roman
face from a sans. Measurement descends from Pierre Simon Fournier's 1737 system, refined by
François-Ambroise Didot, with the competing Anglo-American pica point standardised at approximately
0.351 millimetres and twelve points to a pica. Digital typography rounded the point to exactly one
seventy-second of an inch. Critically, the point size measures the body the type would have occupied
in metal — not the height of any visible letter — which is why point size alone never predicts how
large a face will appear on the page.

## Hot metal composition and the Linotype

Hand composition, a compositor picking sorts one at a time from a case, ran at perhaps 1,500
characters an hour and remained the only method for four hundred years. It capped newspaper size
absolutely: a paper could print no more pages than its compositors could set overnight. Ottmar
Mergenthaler's Linotype, first installed at the New York Tribune in 1886, broke the cap by casting an
entire justified line as a single slug of type metal. The operator typed on a ninety-key keyboard,
releasing brass matrices that assembled into a line; expanding spaceband wedges justified it; molten
metal was injected to cast the slug; and the matrices were then lifted and redistributed
automatically to their magazine channels by a notch code cut into each one. Output reached five to
seven times hand speed. Monotype took a different route, separating a keyboard that punched a paper
tape from a caster that read the tape and cast individual sorts, which produced work that could be
corrected letter by letter and made it the preferred system for book and mathematical setting where
Linotype dominated newspapers.

## Phototypesetting and the loss of optical sizing

From the 1950s photocomposition replaced metal, projecting characters from a film master through a
lens onto photosensitive paper. The gains were immediate: no molten metal, no heavy formes, far
faster output, and type that could be enlarged, reduced, condensed or expanded optically from a
single master. That last capability caused a quiet regression whose effects persist. In metal, every
point size was cut separately by a punchcutter, and small sizes were deliberately drawn with larger
x-heights, sturdier hairlines, looser spacing and open counters so they held up in ink at six point,
while display sizes were drawn with fine hairlines and tight fitting. Scaling one master optically
discards all of that, so text set small from a display master goes spindly and closes up, and display
type set large from a text master looks clumsy and loose. Digital foundries reintroduced the idea as
optical size axes, and OpenType variable fonts finally made it routine again, with an optical size
axis interpolating the design continuously across the size range.

## Digital outlines, hinting and rasterisation

Digital type stores each glyph as an outline — a closed path of straight segments and curves — rather
than as a bitmap, so a single description serves every size and resolution. PostScript Type 1 used
cubic Bézier curves; TrueType used quadratic B-splines, which are cheaper to evaluate but need more
control points; OpenType unified the two under a common wrapper and added the layout tables that
support ligatures, contextual alternates, small capitals and complex non-Latin scripts. The hard
problem is rasterisation at low resolution. A screen at ninety-six pixels per inch renders ten-point
text on a grid of roughly thirteen pixels, and an outline scaled naively onto that grid produces stems
of inconsistent width and baselines that drift between adjacent letters. Hinting is the set of
instructions embedded in the font that snaps critical features to the pixel grid: TrueType hinting is
an explicit, powerful and laborious instruction language, while PostScript hinting declares
structural intent and leaves the interpreter to act on it. High-density displays have reduced the
stakes without eliminating them.

## Text setting: measure, leading and justification

Setting text well is mostly about three interacting quantities. Measure is line length, and the
durable guideline of forty-five to seventy-five characters per line exists because the eye must
travel back to find the start of the next line; too long and it loses the row, too short and the
rhythm of reading fragments. Leading — the term survives from the strips of lead inserted between
lines of metal type — is the baseline-to-baseline distance, and it must increase with measure, since a
long line needs more vertical separation to be tracked reliably. Typical body text runs at 120 to 145
percent of point size. Justification demands the most machinery. Setting flush on both margins
requires distributing slack across a line's word spaces, and doing it line by line greedily produces
rivers of white running down the page. Donald Knuth and Michael Plass published the
total-fit algorithm in 1981, which optimises breaks across the whole paragraph by minimising summed
badness with dynamic programming, and it is why TeX-set paragraphs remain visibly more even than
those set by the greedy first-fit algorithms still common in word processors and browsers.
