# Retrieval eval — recall@8 (FR-D2)

| setting | fetch | cut | mean recall | hit rate |
|---|---|---|---|---|
| production | 8 | 8 | 0.633 | 0.633 |
| wide fetch, same cut | 24 | 8 | 0.633 | 0.633 |
| candidate pool | 24 | 24 | 0.800 | 0.800 |

- corpus: 12 documents, 48 chunks
- queries: 30
- embedder: lexical (lexical-hashing-384)
- wide-fetch gain: 0.000
- reranker headroom: 0.167
- gold below cut but inside pool: 5/30
- gold missing from pool: 6/30

## Cut sweep (fetch 24)

What simply returning more chunks would buy, with no reranker at all.

| cut | mean recall |
|---|---|
| 4 | 0.500 |
| 8 | 0.633 |
| 12 | 0.700 |
| 16 | 0.700 |
| 20 | 0.800 |
| 24 | 0.800 |

## Per-query gold rank in the 24-candidate window

| rank | query |
|---|---|
| 1 | How long will green coffee keep in the warehouse before it goes flat and loses sweetness? |
| 3 | What proportion of a roast should happen after the beans crack, for filter? |
| 2 | Why does espresso need a longer rest after roasting than brewed coffee? |
| 5 | My hive has already built queen cells. What is the best response now? |
| — | How do I quantify the parasite load and when is treatment justified? |
| 3 | Why would a colony die of hunger when there is still food in the box? |
| 3 | What does making the cable hang deeper cost me elsewhere in the structure? |
| 1 | If the 1940 collapse was not the wind matching a natural frequency, what was it? |
| 6 | How is rusting inside the main cable prevented on a modern span? |
| 7 | Why does some molten rock pour out quietly while other magma detonates? |
| 1 | What actually causes most of the deaths in a large explosive eruption? |
| 12 | Which volcanic threat can arrive with no eruption happening at all? |
| — | Can a vaccine be destroyed by being kept too cold rather than too warm? |
| 1 | Why can't I take coolant packs straight from the freezer and pack them? |
| 1 | The alarm logged an out-of-range reading overnight. Do I discard the stock? |
| 1 | Why is a big dish still so blurry compared with a small optical telescope? |
| 18 | How is a usable picture recovered when the array only samples part of the plane? |
| 20 | How do I make my loaf taste sharper and more vinegary rather than mild? |
| — | Why is following the timing in a bread recipe unreliable in my kitchen? |
| — | Why does day-old bread seem fresh again for a while after warming it? |
| 10 | How are suspended particles removed when they are far too small to settle out? |
| 4 | Changing where we draw our water caused a lead problem. Why? |
| 3 | Why do two typefaces set at the same nominal size look so different in scale? |
| 1 | Why do paragraphs from TeX look more evenly spaced than from a browser? |
| — | Why was working out east-west position at sea so much harder than north-south? |
| 1 | How does a measured star altitude become a line drawn on the chart? |
| 7 | Why is it harmful to charge a battery quickly when it is cold? |
| 3 | Why can't the remaining charge be judged from terminal voltage on LFP cells? |
| 20 | What allows a fire burning along the ground to get up into the treetops? |
| — | What is the main risk to people downstream once the flames are out? |
