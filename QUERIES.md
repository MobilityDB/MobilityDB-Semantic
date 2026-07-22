# Queries

Every query exists in two versions: a discrete one, computed from the
observations or from per-cell aggregates, and a continuous one, computed from
temporal values. The tables below map the queries of the paper to the queries
of this repository and give the size of each answer, so that a query can be
located from its label in the paper and a divergence can be recognised without
running anything.

The repository holds queries that the paper has no room for. They are marked
*repository only* and are not less important: three of them carry the clearest
evidence of the difference between the two approaches.

## Files

| File | Content |
| --- | --- |
| `delhi_load.sql` | Loads the Delhi data, builds the grid and district tessellations, the per-cell aggregates and the temporal values |
| `delhi_points_trips.sql` | Queries over complete trips. No aggregate on either side |
| `delhi_grid.sql` | Queries over the grid tessellation. The discrete side reads per-cell averages |
| `delhi_districts.sql` | Queries over the district tessellation |
| `paris_tours.sql` | Loads the Paris tours and points of interest |
| `paris_queries.sql` | Pattern queries over semantic tours |

Each file has a `_new` counterpart holding the same queries, corrected where
they did not run or did not state the query, and annotated with the reason for
each difference between the two versions.

## Complete trips — `delhi_points_trips.sql`

Neither version aggregates anything, so the two see the same information. This
is the control: the agreement here is what makes the divergences of the grid
attributable to the per-cell averaging rather than to the query language.

| Paper | Query | Discrete | Continuous | |
| --- | --- | --- | --- | --- |
| `que:point-incr` | `Q8` / `TQ8` | 708 | 708 | identical |
| `que:point-incr-decr-global` | `Q9` / `TQ9` | 38 | 40 | one trip, 2245, found only by the continuous version, which distinguishes exclusive bounds |
| `que:point-span` | `Q10` / `TQ10` | 94 | 94 | identical |
| `que:point-higher-global` | `Q11` / `TQ11` | 8 | 8 | identical |
| `que:point-weather` | `Q12` / `TQ12` | 71 | 71 | identical |

## Grid tessellation — `delhi_grid.sql`

The discrete side reads `TripCells`, holding the average of each measure over
a cell visit. Every divergence below comes from that averaging or from the
cells that hold no observation.

| Paper | Query | Discrete | Continuous | |
| --- | --- | --- | --- | --- |
| `que:grid-allincrease` | `GQ8` / `TGQ8` | 1102 | 708 | only 57 trips in common. The discrete version drops the trips that visit a single cell and accepts trips whose averages increase while the value falls inside a cell |
| `que:grid-incr-decr` | `GQ9` / `TGQ9` | 348 | 40 | 149 trips against 20. Averaging turns an oscillating trip into a long monotone run of cell values. The complete-trip version of the same query, which is discrete but not averaged, finds 19 trips and thus confirms the continuous answer |
| repository only | `GQ10` / `TGQ10` | 10 | 182 | averaging hides the threshold crossings: 5062 trips reach below 100 in the continuous version against 4338 in the discrete one, and 2950 against 1849 above 400 |
| repository only | `GQ11` / `TGQ11` | 4 | 8 | same effect on episodes of at least ten minutes |
| `que:grid-raintemphm` | `GQ12` / `TGQ12` | 92 | 71 | 85 trips against 66 |
| `que:grid_cell_patt1` | `GQ13` / `TGQ13` | 10478 | 10631 | the continuous version knows the cells traversed without an observation |
| repository only | `GQ14` / `TGQ14` | 63 | 0 | a recovered cell *destroys* a fixed-length match: `A B A` becomes `A B C A`. This is the direction opposite to `GQ13`, and it is the reason a pattern of fixed length should be avoided when the sampling is not uniform |

The appendix of `delhi_grid_new.sql` isolates the cell pattern under the three
consumption modes: 10478/10631 overlapping, 4270/4320 disjoint, 20193/20497
any-length.

## District tessellation — `delhi_districts.sql`

| Paper | Query | Discrete | Continuous | |
| --- | --- | --- | --- | --- |
| `que:point-district` | `Q15_Over` / `TQ15_Over` | 8957 | 9262 | the 305 additional matches are those whose middle district carries no observation |
| `que:point-district` | `Q15_Disj` / `TQ15_Disj` | 1891 | 1906 | the disjoint mode keeps at most one match every three positions and so understates the effect by a factor of twenty |
| `que:point-district` | `Q15_AnyLen` / `TQ15_AnyLen` | 9903 | 10201 | a recovered district can only help a variable-length pattern |
| `que:point-development` | `TQ16_Over` | — | 12551 | no discrete version exists. Of the 7087619 observations, **zero** lie on a district boundary, so the predicate Meets is never observed. Replacing it by a tolerance returns 14397, 148525 or 640954 candidate observations at 1 m, 10 m and 50 m |

## Semantic tours — `paris_queries.sql`

The nine pairs agree exactly. The interest of this file is not the divergence
but the range of pattern elements it exercises.

| Paper | Query | Rows | Pattern element |
| --- | --- | --- | --- |
| repository only | 1 | 2 | optional element, `[Restaurant]*` |
| repository only | 2 | 8 | plain succession |
| repository only | 3 | 1 | anchor on the first step, `^` |
| repository only | 4 | 2 | anchor on the last step, `$` |
| repository only | 5 | 2 | optional element in the middle |
| repository only | 6 | 1 | variable bound across two steps |
| repository only | 7 | 3 | condition on the document and on the time |
| repository only | 8 | 1 | condition on a function of the instant |
| `que:querybuf` | 9 | 2 | condition on the itinerary rather than the document |

In the continuous version the *before* of a pattern is the temporal operator
`<<#`. Comparing two temporal values with `<` returns the same answers on this
data, because temporal values are ordered by their bounding box and hence by
their period first, and the steps of a tour are disjoint; the coincidence does
not survive steps that overlap.

## Consumption modes

A pattern query has one answer per rule deciding how a match consumes the
sequence it matched. The three modes are given for the cell pattern and for
the district pattern, since they answer three different questions:

- **Over** — every position where the pattern holds. `A B A B A` has three
  overlapping matches. Use it to count occurrences.
- **Disj** — the matches that do not overlap, scanning left to right. `A B A B A`
  has two. Use it to count episodes. Note that the answer depends on the scan
  direction.
- **AnyLen** — the relaxation to `A .* A`, with `A` not occurring in between.
  Use it to detect a return, whatever the length of the detour.
