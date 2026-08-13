/*****************************************************************************
 * Queries over the grid tessellation of Delhi, discrete and continuous
 * version.
 *
 * The discrete version reads table TripCells, one row per visit of a trip to
 * a cell, holding the AVERAGE of the measures over the visit. The continuous
 * version reads table TripTiles, one row per visit, holding the part of the
 * trip inside the cell as a temporal point and the measures as temporal
 * values restricted to that period. The averaging is the whole difference
 * between the two tables, and it is the reason why the answers of the two
 * versions diverge much more here than in delhi_points_trips.sql, where the
 * discrete version reads the observations themselves and the two versions
 * agree almost everywhere.
 *
 * Two effects recur in the queries below and are worth naming once.
 *
 * Averaging hides what happens inside a cell. A trip whose Pm25 oscillates
 * inside a cell is seen as a single value, so a threshold crossed inside the
 * cell is invisible, and a succession of cell averages can be monotone while
 * the trip itself is not. This makes the discrete version miss episodes
 * (Query 10) and invent them (Query 9).
 *
 * The discrete version only knows the cells in which the trip was observed.
 * A cell crossed between two observations is absent from TripCells, so the
 * sequence of cells has holes. The continuous version derives the cells from
 * the trajectory and therefore lists every cell traversed. This changes the
 * answer of the pattern queries in both directions: a recovered cell creates
 * matches for a variable-length pattern (Query 13) and destroys them for a
 * fixed-length one (Query 14).
 *
 * When the condition of a query is about the whole trip rather than about one
 * cell, the tiles of a trip are merged back with mergeAgg before the
 * condition is evaluated. Evaluating it tile by tile answers a different
 * question, namely whether the condition holds within each cell separately,
 * which says nothing about the passage from one cell to the next.
 *****************************************************************************/

/*****************************************************************************/

SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

-------------------------------------------------------------------------------
/*
Query 8. Trips during which the PM2.5 increases continuously.

IncrPm25: Trip[sign(derivative(Pm25)) > 0]
Trip[IncrPm25 AND getTime(IncrPm25) = getTime(Trip)]
*/

DROP TABLE IF EXISTS GQ8;
CREATE TABLE GQ8(TripId, Cells, Pm25Seq) AS
WITH TrendPm25(TripId, CellId, Weather, Pm25, Trend) AS (
  SELECT TripId, CellId, Weather, Pm25, 
    SIGN(Pm25 - LAG(Pm25) OVER (PARTITION BY TripId ORDER BY StartTime))
  FROM TripCells ),
SelectedTrip(TripId) AS (
  SELECT TripId 
  FROM TrendPm25
  GROUP BY TripId 
  HAVING COUNT(*) >= 2 AND COUNT(*) FILTER (WHERE Trend <= 0) = 0 )
SELECT TripId, 
  array_agg(CellId ORDER BY StartTime) AS Cells,
  array_agg(ROUND(Pm25::numeric, 2) ORDER BY StartTime) AS Pm25Seq
FROM TripCells
WHERE TripId IN (SELECT TripId FROM SelectedTrip)
GROUP BY TripId
ORDER BY TripId;

-- 1102 rows
-- Time: 138.142 ms

-- TEMPORAL VERSION

-- The condition is about the whole trip, so the tiles of a trip are merged back
-- into the trip's value and the trend is taken once over it. Reading the trend
-- tile by tile answers a different question, namely whether the value increases
-- within each cell, which says nothing about the passage from one cell to the
-- next and needs the visits to be counted to compensate.

DROP TABLE IF EXISTS TGQ8;
CREATE TABLE TGQ8(TripId, Cells, Pm25Seq) AS
WITH Trip(TripId, Pm25) AS (
  SELECT TripId, mergeAgg(Pm25)
  FROM TripTiles
  GROUP BY TripId ),
SelectedTrip(TripId) AS (
  SELECT TripId
  FROM Trip
  WHERE trend(Pm25) %> 0 )
SELECT TripId, tintSeq(array_agg(tint(CellId, lower(AtTime)) ORDER BY AtTime))
  AS Cells, merge(array_agg(Pm25 ORDER BY AtTime)) AS Pm25
FROM TripTiles
WHERE TripId IN (SELECT TripId FROM SelectedTrip)
GROUP BY TripId
ORDER BY TripId;

-- SELECT 708

-- The discrete query returns 1102 trips, and only 57 of them are also in this
-- answer. Two effects of the per-visit averaging account for the difference. The
-- 651 trips that this query finds and the discrete one does not all visit a
-- single cell, so they have no consecutive pair of visits for the discrete query
-- to compare and its COUNT(*) >= 2 guard drops them; 21726 of the 27118 trips
-- visit a single cell. The 1045 trips the discrete query finds and this one does
-- not have averages that increase from cell to cell while the value falls
-- somewhere inside a cell.
--
-- Over TripPoints, where no value is averaged, the discrete query returns the
-- same 708 trips as this one, with an empty symmetric difference. See
-- delhi_load_new.sql for the two segmentation models.

-------------------------------------------------------------------------------
/*
Query 9. Trips where the Pm25 increases for at least 1.5 minutes and then
decreases for at least 1.5 minutes, such that in both episodes, the Pm25 is
higher than 125 and the temperature is higher than 20 degrees.

IncrPm25: Trip[sign(derivative(Pm25)) > 0]
DecrPm25: Trip[sign(derivative(Pm25)) < 0]
IncrDecrSpeed: Trip[before([IncrPm25 AND duration(IncrPm25) >= '1.5 minutes'],
  [DecrPm25 AND duration(DecrPm25) >= '1.5 minutes'])]
Trip[IncrDecrSpeed AND Pm25 > 125 AND Temperature > 20]
*/

DROP TABLE IF EXISTS GQ9;
CREATE TABLE GQ9(TripId, EpisodeId, StartTime, EndTime, Duration, Cells,
  Trend, Pm25seq) AS
/* The last line of the pattern restricts the trip to the parts where the Pm25
 * is higher than 125 and the temperature is higher than 20 degrees. Table
 * Rest applies that restriction before the trend is computed, so that the
 * episodes are searched in the restricted trip, as the pattern states. */
WITH Restricted(TripId, StartTime, EndTime, CellId, Pm25) AS (
  SELECT TripId, StartTime, EndTime, CellId, Pm25
  FROM TripCells
  WHERE Pm25 > 125 AND (Weather->>'Temperature')::float > 20 ),
TrendPm25(TripId, StartTime, EndTime, CellId, Pm25, Trend) AS (
  SELECT TripId, StartTime, EndTime, CellId, Pm25, SIGN(Pm25 -
    (LAG(Pm25) OVER (PARTITION BY TripId ORDER BY StartTime)))
  FROM Restricted ),
EpisodeStart(TripId, StartTime, EndTime, CellId, Pm25, Trend,
    NewEpisode) AS (
  SELECT TripId, StartTime, EndTime, CellId, Pm25, Trend,
    CASE
      WHEN Trend IS NULL OR Trend <> LAG(Trend) OVER
        (PARTITION BY TripId ORDER BY StartTime) THEN 1 ELSE 0
    END
  FROM TrendPm25 ),
Episode(TripId, EpisodeId, StartTime, EndTime, CellId, Pm25, Trend) AS (
  SELECT TripId, SUM(NewEpisode) OVER (PARTITION BY TripId ORDER BY
    StartTime), StartTime, EndTime, CellId, Pm25, Trend
  FROM EpisodeStart ),
EpisodeDuration(TripId, EpisodeId, StartTime, EndTime, Trend, Duration, Cells,
    Pm25seq) AS (
  SELECT TripId, EpisodeId, MIN(StartTime), MAX(EndTime), 
    MIN(Trend), /* Trend is the same for all episode */
    MAX(EndTime) - MIN(StartTime), array_agg(CellId ORDER BY StartTime),
    array_agg(ROUND(Pm25::numeric, 2) ORDER BY StartTime)
  FROM Episode
  GROUP BY TripId, EpisodeId
  HAVING MAX(StartTime) - MIN(StartTime) >= interval '1.5 minutes' AND
    COUNT(*) >= 2 ),
EpisodePair(TripId, IncrEpisode, DecrEpisode) AS (
  SELECT e1.TripId, e1.EpisodeId, e2.EpisodeId
  FROM EpisodeDuration e1, EpisodeDuration e2
  WHERE e1.TripId = e2.TripId AND e1.EpisodeId + 1 = e2.EpisodeId AND
    e1.Trend = 1 AND e2.Trend = -1 )
SELECT e.TripId, EpisodeId, StartTime, EndTime, Duration, Cells, Trend, Pm25seq
FROM EpisodeDuration e, EpisodePair p
WHERE e.TripId = p.TripId AND e.EpisodeId IN (p.IncrEpisode, p.DecrEpisode)
ORDER BY e.TripId;

-- SELECT 348
-- Time: 447.517 ms

-- TEMPORAL VERSION

/* The discrete version above must reconstruct the episodes with three window
 * functions: a trend, a change-of-trend flag, and a running sum that numbers
 * the groups. In the temporal version an episode is not reconstructed at all,
 * it is read off the temporal value: whenTrue(trend(Pm25) #> 0) is the time
 * when the Pm25 increases, segmentMinDuration keeps the parts of it that last
 * at least 1.5 minutes, and the sequences of the restricted trip ARE the
 * episodes. The "before" of the pattern is then the equality of the end of an
 * increasing episode with the start of a decreasing one. */

DROP TABLE IF EXISTS TGQ9;
CREATE TABLE TGQ9(TripId, EpisodeId, AtTime, Duration, Cells,
  Trend, Pm25) AS
WITH Trip(TripId, Cells, Pm25, Weather) AS (
  SELECT TripId, mergeAgg(tint(CellId, AtTime)), mergeAgg(Pm25),
    mergeAgg(Weather)
  FROM TripTiles
  GROUP BY TripId ),
/* Restriction of the last line of the pattern, as in the discrete version */
Restricted (TripId, Cells, Pm25) AS (
  SELECT TripId, Cells, atTime(Pm25, whenTrue(Pm25 #> 125) *
    whenTrue(tfloat(Weather, 'Temperature', 'step') #> 20))
  FROM Trip
  WHERE whenTrue(Pm25 #> 125) IS NOT NULL AND
    whenTrue(tfloat(Weather, 'Temperature', 'step') #> 20) IS NOT NULL ),
Incr(TripId, Cells, Pm25) AS (
  SELECT TripId, Cells, unnest(sequences(atTime(Pm25,
    whenTrue(segmentMinDuration(atValue(trend(Pm25) #> 0, true),
      interval '1.5 minutes', false)))))
  FROM Restricted  ),
Decr(TripId, Pm25) AS (
  SELECT TripId, unnest(sequences(atTime(Pm25,
    whenTrue(segmentMinDuration(atValue(trend(Pm25) #< 0, true),
      interval '1.5 minutes', false)))))
  FROM Rest ),
Pair(TripId, Cells, PairNo, Incr, Decr) AS (
  SELECT i.TripId, i.Cells, ROW_NUMBER() OVER (PARTITION BY i.TripId
    ORDER BY startTimestamp(i.Pm25)), i.Pm25, d.Pm25
  FROM Incr i, Decr d
  WHERE i.TripId = d.TripId AND
    endTimestamp(i.Pm25) = startTimestamp(d.Pm25) )
SELECT p.TripId, p.PairNo, getTime(e.Pm25), duration(getTime(e.Pm25)),
  valueSet(atTime(p.Cells, getTime(e.Pm25))), e.Trend, e.Pm25
FROM Pair p, LATERAL (VALUES (1, p.Incr), (-1, p.Decr)) AS e(Trend, Pm25)
ORDER BY p.TripId, p.PairNo, e.Trend DESC;

-- SELECT 40
-- Time: 1174.895 ms

/* The two versions report the same pattern on the same trips but at very
 * different scale: 348 episodes over 149 trips in the discrete version
 * against 40 episodes over 20 trips in the temporal one. The reason is the
 * per-cell average of table TripCells. Averaging the Pm25 over a cell visit
 * removes the fluctuations inside the cell, so a trip that in reality
 * oscillates is seen as a long monotone run of cell values, and the 1.5-minute
 * increase then the 1.5-minute decrease are found where the trip has none.
 * The temporal version reads the trend of the actual curve. The complete-trip
 * version of this query in delhi_points_trips.sql, which is discrete but is
 * computed at the granularity of the observations instead of the cells,
 * confirms this: it agrees with the temporal answer, not with the 149 trips
 * found here. */

-------------------------------------------------------------------------------

/*
Query 10. Trips that have at some point a Pm25 lower than 100 and later reach
a value higher than 400, such that the elapsed time between the increase of
values is less than one minute.

StartPm25: Trip[Pm25 < 100]
EndPm25: Trip[Pm25 > 400]
Trip[before(StartPm25, EndPm25) AND 
  lower(EndPm25) - lower(StartPm25) < '1 minute']
*/

DROP TABLE IF EXISTS GQ10;
CREATE TABLE GQ10(TripId, StartTime, EndTime, Duration, Cells, Pm25seq) AS
WITH StartPm25(TripId, StartStep, StartCell, StartTime, StartPm25) AS (
  SELECT TripId, StepNo, CellId, StartTime, Pm25
  FROM TripCells c1
  WHERE StepNo = (
    SELECT MIN(StepNo)
    FROM TripCells c2
    WHERE c1.TripId = c2.Tripid AND Pm25 < 100 ) ),
EndPm25(TripId, EndStep, EndCell, EndTime, EndPm25) AS (
  SELECT TripId, StepNo, CellId, EndTime, Pm25
  FROM TripCells c1
  WHERE StepNo = (
    SELECT MIN(StepNo)
    FROM TripCells c2
    WHERE c1.TripId = c2.Tripid AND Pm25 > 400 ) ),
Episode(TripId, StartTime, EndTime, Duration) AS (
  SELECT s.TripId, StartTime, EndTime, EndTime - StartTime
  FROM StartPm25 s, EndPm25 e
  WHERE s.TripId = e.Tripid AND StartTime < EndTime AND
    EndTime - StartTime >= '1 minute' )
SELECT t.TripId, e.StartTime, e.EndTime, e.Duration,
  array_agg(t.CellId ORDER BY t.StartTime) AS Cells,
  array_agg(ROUND(t.Pm25::numeric, 2) ORDER BY t.StartTime) AS Pm25seq
FROM TripCells t, Episode e
WHERE t.TripId = e.TripId AND t.StartTime BETWEEN e.StartTime AND e.EndTime
GROUP BY t.TripId, e.StartTime, e.EndTime, e.Duration
ORDER BY TripId, StartTime;

-- SELECT 10
-- Time: 974.391 ms

-- TEMPORAL VERSION

-- The two instants are read from the value itself: whenTrue gives the extent of
-- each condition and the first span of each is the first time the trip is below
-- 100 and the first time it is above 400. The discrete query instead locates the
-- first cell whose average crosses the threshold, which is a coarser instant and
-- depends on where the grid cuts the trip.

DROP TABLE IF EXISTS TGQ10;
CREATE TABLE TGQ10(TripId, AtTime, Duration, Cells, Pm25seq) AS
WITH Trip(TripId, Pm25) AS (
  SELECT TripId, mergeAgg(Pm25)
  FROM TripTiles
  GROUP BY TripId ),
Episode(TripId, AtTime, Duration) AS (
  SELECT TripId, span(StartTime, EndTime), EndTime - StartTime
  FROM (
    SELECT TripId,
      lower(startSpan(whenTrue(Pm25 #< 100))) AS StartTime,
      lower(startSpan(whenTrue(Pm25 #> 400))) AS EndTime
    FROM Trip
    WHERE whenTrue(Pm25 #< 100) IS NOT NULL AND
      whenTrue(Pm25 #> 400) IS NOT NULL ) Crossings
  WHERE StartTime < EndTime AND EndTime - StartTime >= interval '1 minute' )
SELECT t.TripId, e.AtTime, e.Duration,
  tintSeq(array_agg(tint(CellId, lower(t.AtTime)) ORDER BY t.AtTime)),
  merge(array_agg(atTime(t.Pm25, e.AtTime) ORDER BY t.AtTime)) AS Pm25seq
FROM TripTiles t, Episode e
WHERE t.TripId = e.TripId AND t.AtTime && e.AtTime
GROUP BY t.TripId, e.AtTime, e.Duration
ORDER BY TripId, AtTime;

-------------------------------------------------------------------------------
/*
Query 11. Trips that travel all their way under a temperature higher than 25
degrees such that in at least two episodes longer than ten minutes, the Pm25
is higher than 150.

HighTemp: Trip[Temperature > 25]
TripTemp: Trip[HighTemp AND getTime(HighTemp) = getTime(Trip)]
HighPm25: Trip[TripTemp AND Pm25 > 150]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '10 minutes']
Trip[before(Episode, Episode+)]
*/

DROP TABLE IF EXISTS GQ11;
CREATE TABLE GQ11(TripId, EpisodeId, StartTime, EndTime, Duration, Cells, Pm25seq) AS
WITH TripTemp(TripId) AS (
  SELECT TripId 
  FROM TripCells
  GROUP BY TripId
  HAVING MIN((Weather->>'Temperature')::numeric) > 25 ),
LowerPm25(TripId, StartTime, EndTime, CellId, Pm25, StartEpisode) AS (
  SELECT TripId, StartTime, EndTime, CellId, Pm25,
    CASE
      WHEN Pm25 <= 150 OR LAG(Pm25) OVER
        (PARTITION BY TripId ORDER BY StartTime) <= 150
      THEN 1 ELSE 0
    END
  FROM TripCells
  WHERE TripId IN (SELECT TripId FROM TripTemp) ),
Episode(TripId, EpisodeId, StartTime, EndTime, CellId, Pm25) AS (
  SELECT TripId, SUM(StartEpisode) OVER 
    (PARTITION BY TripId ORDER BY StartTime), StartTime, EndTime, CellId, Pm25
  FROM LowerPm25 ),
Pattern(TripId, EpisodeId, StartTime, EndTime, Duration, Cells, Pm25seq) AS (
  SELECT TripId, EpisodeId, MIN(StartTime), MAX(EndTime),
    MAX(EndTime) - MIN(StartTime), array_agg(CellId ORDER BY StartTime),
    array_agg(ROUND(Pm25::numeric, 2) ORDER BY StartTime)
  FROM Episode
  WHERE Pm25 > 150
  GROUP BY TripId, EpisodeId
  HAVING MAX(EndTime) - MIN(StartTime) >= interval '10 minutes' AND
    COUNT(*) >= 2 ),
SelectedTrip(TripId) AS (
  SELECT TripId
  FROM Pattern
  GROUP BY TripId
  HAVING COUNT(*) >= 2 )
SELECT TripId, EpisodeId, StartTime, EndTime, Duration, Cells, Pm25seq
FROM Pattern 
WHERE TripId IN (SELECT TripId FROM SelectedTrip)
ORDER BY TripId, StartTime;

-- SELECT 4
-- Time: 107.508 ms

-- TEMPORAL VERSION

-- The temperature condition holds all the way when the always-predicate holds
-- over the trip, and the episodes are the maximal spans during which the Pm25
-- exceeds 150, so the ten-minute filter applies to the extent of the condition
-- rather than to the first and last visit of a run of cells.

DROP TABLE IF EXISTS TGQ11;
CREATE TABLE TGQ11(TripId, EpisodeId, AtTime, Duration, Cells, Pm25) AS
WITH Trip(TripId, Pm25, Weather) AS (
  SELECT TripId, mergeAgg(Pm25), mergeAgg(Weather)
  FROM TripTiles
  GROUP BY TripId ),
TripTemp(TripId, Pm25) AS (
  SELECT TripId, Pm25
  FROM Trip
  WHERE tfloat(Weather, 'Temperature', 'step') %> 25 ),
Episode(TripId, EpisodeId, AtTime, Pm25) AS (
  SELECT TripId, ep.ord, ep.s, atTime(Pm25, ep.s)
  FROM TripTemp,
    unnest(spans(whenTrue(Pm25 #> 150))) WITH ORDINALITY AS ep(s, ord)
  WHERE duration(ep.s) >= interval '10 minutes' ),
SelectedTrip(TripId) AS (
  SELECT TripId
  FROM Episode
  GROUP BY TripId
  HAVING COUNT(*) >= 2 )
SELECT e.TripId, e.EpisodeId, e.AtTime, duration(e.AtTime),
  (SELECT tintSeq(array_agg(tint(t.CellId, lower(t.AtTime)) ORDER BY t.AtTime))
   FROM TripTiles t WHERE t.TripId = e.TripId AND t.AtTime && e.AtTime),
  e.Pm25
FROM Episode e
WHERE e.TripId IN (SELECT TripId FROM SelectedTrip)
ORDER BY e.TripId, lower(e.AtTime);

-- The discrete query additionally requires an episode to cover at least two
-- cells (COUNT(*) >= 2), which the sentence and the pattern do not ask for: an
-- episode lasting ten minutes inside a single cell answers the question. That
-- condition compensates for measuring an episode by its first and last visit,
-- and it has no counterpart here.

-------------------------------------------------------------------------------
/*
Query 12. Trips such that there is at least a 30-minute episode where the Pm25
is higher than 300 in cloudy conditions and with humidity higher than 80%.

HighPm25: Trip[Pm25 > 300]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '30 minutes']
Trip[Episode AND CloudCover > 0 AND Humidity > 80]

*/

DROP TABLE IF EXISTS GQ12;
CREATE TABLE GQ12 AS
WITH Segment(TripId, StartTime, EndTime, Pm25, CloudCover, Humidity, Valid) AS (
  SELECT TripId, StartTime, EndTime, Pm25, (Weather->>'CloudCover')::numeric,
    (Weather->>'Humidity')::numeric,
    CASE
      WHEN Pm25 > 300 AND (Weather->>'CloudCover')::numeric > 0 AND
        (Weather->>'Humidity')::numeric > 80
      THEN 1 ELSE 0
    END 
  FROM TripCells ),
SegmentPrev(TripId, StartTime, EndTime, Pm25, CloudCover, Humidity, Valid,
    PrevValid) AS (
  SELECT *, LAG(Valid) OVER (PARTITION BY TripId ORDER BY StartTime)
  FROM Segment ),
Episode(TripId, EpisodeId, StartTime, EndTime, Pm25, CloudCover, Humidity, Valid,
    PrevValid) AS (
  SELECT TripId, SUM(CASE WHEN Valid = PrevValid THEN 0 ELSE 1 END) OVER
    (PARTITION BY TripId ORDER BY StartTime), StartTime, EndTime, Pm25,
    CloudCover, Humidity, Valid, PrevValid
  FROM SegmentPrev )
SELECT TripId, EpisodeId, MIN(StartTime) AS StartTime,
  MAX(EndTime) AS EndTime, MAX(StartTime) - MIN(StartTime) AS Duration, 
  array_agg(Pm25 ORDER BY StartTime) AS Pm25Seq,
  array_agg(CloudCover ORDER BY StartTime) AS CloudCoverSeq,
  array_agg(Humidity ORDER BY StartTime) AS HumiditySeq
FROM Episode
GROUP BY TripId, EpisodeId
HAVING MAX(EndTime) - MIN(StartTime) >= '30 minutes' AND BOOL_AND(Valid = 1)
ORDER BY TripId, StartTime;

-- SELECT 92
-- Time: 408.906 ms

-- TEMPORAL VERSION

-- The condition is a temporal Boolean, and the episodes are the maximal spans
-- during which it holds. There is no need to mark the visits, to carry the
-- previous mark, or to number the groups: the extent of the condition is
-- computed by whenTrue and split into episodes by spans, so the duration filter
-- applies to the exact extent instead of to the first and last visit times.

DROP TABLE IF EXISTS TGQ12;
CREATE TABLE TGQ12 AS
WITH Trip(TripId, Pm25, Weather) AS (
  SELECT TripId, mergeAgg(Pm25), mergeAgg(Weather)
  FROM TripTiles
  GROUP BY TripId ),
Cond(TripId, Pm25, Weather, Valid) AS (
  SELECT TripId, Pm25, Weather, (Pm25 #> 300) &
    (tfloat(Weather, 'CloudCover') #> 0) & (tfloat(Weather, 'Humidity') #> 80)
  FROM Trip )
SELECT TripId, ep.ord AS EpisodeId, lower(ep.s) AS StartTime,
  upper(ep.s) AS EndTime, duration(ep.s) AS Duration,
  atTime(Pm25, ep.s) AS Pm25,
  atTime(tfloat(Weather, 'CloudCover'), ep.s) AS CloudCover,
  atTime(tfloat(Weather, 'Humidity'), ep.s) AS Humidity
FROM Cond, unnest(spans(getTime(atValue(Valid, true)))) WITH ORDINALITY AS ep(s, ord)
WHERE duration(ep.s) >= interval '30 minutes'
ORDER BY TripId, StartTime;

-- SELECT 71, over 66 trips

-- The discrete query returns 92 episodes over 85 trips. It groups consecutive
-- visits carrying the same mark without requiring them to be contiguous in time,
-- and measures an episode from the start of its first visit to the end of its
-- last, so a gap in the observations is counted as part of the episode: 60 of
-- its 92 episodes contain such a gap. The continuous query splits at the gap and
-- keeps only the parts that last at least thirty minutes on their own.

-------------------------------------------------------------------------------
/*
Query 13. Trips that traverse at least twice the same cell with exactly one
different cell in between.

[Trips]; CellId = @c AND @c = prev(prev(@c)) AND @c <> prev(@c)
*/

-- Overlapping patterns
DROP TABLE IF EXISTS GQ13_Over;
CREATE TABLE GQ13_Over AS
SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
FROM TripCellsSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1]
ORDER BY s.TripId;

-- Disjoint patterns
DROP TABLE IF EXISTS GQ13_Disj;
CREATE TABLE GQ13_Disj AS
WITH AllMatches AS (
  SELECT s.TripId, g.Pos, s.CellSeq[g.Pos:g.Pos + 2] AS MatchSeq
  FROM TripCellsSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
  WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
  s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1] ),
Ranked AS (
  SELECT *, LAG(Pos) OVER (PARTITION BY TripId ORDER BY Pos) AS PrevPos
  FROM AllMatches )
SELECT TripId, Pos, MatchSeq
FROM Ranked
WHERE PrevPos IS NULL OR Pos >= PrevPos + 3
ORDER BY TripId, Pos;

-- Overlapping patterns of A.*A
DROP TABLE IF EXISTS GQ13_AnyLen;
CREATE TABLE GQ13_AnyLen AS
SELECT s.TripId, g1.StartPos, g2.EndPos,
  s.CellSeq[g1.StartPos : g2.EndPos] AS MatchSeq
FROM TripCellsSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 1) AS g1(StartPos)
  CROSS JOIN LATERAL generate_series(g1.StartPos + 2, array_length(s.CellSeq, 1)) AS g2(EndPos)
WHERE s.CellSeq[g1.StartPos] = s.CellSeq[g2.EndPos]
AND NOT EXISTS (
  SELECT 1
  FROM generate_series(g1.StartPos + 1, g2.EndPos - 1) AS g(MidPos)
  WHERE s.CellSeq[g.MidPos] = s.CellSeq[g1.StartPos] )
ORDER BY s.TripId, g1.StartPos;

-- SELECT 20193
-- Time: 1574.928 ms (00:01.575)

-------------------------------------------------------------------------------
-- OLD VERSIONS WITH LAG
-------------------------------------------------------------------------------
/*
Query 5.13. Trips that traversed at least twice the same cell with exactly
one different cell in between.
*/

DROP TABLE IF EXISTS GQ13;
CREATE TABLE GQ13 AS
-- Add the previous two cells to the rows
WITH CellSeq(TripId, CellId, StartTime, EndTime, Prev2Cell, Prev2StartTime,
    PrevCell, PrevStartTime) AS (
  SELECT TripId, CellId, StartTime, EndTime, LAG(CellId, 2) OVER w, 
    LAG(StartTime, 2) OVER w, LAG(CellId, 1) OVER w, LAG(StartTime, 1) OVER w
  FROM TripCells
  WINDOW w AS (PARTITION BY TripId ORDER BY StepNo) )
SELECT TripId, Prev2StartTime, EndTime, Prev2Cell, PrevCell, CellId
FROM CellSeq
WHERE Prev2Cell IS NOT NULL AND CellId = Prev2Cell AND PrevCell <> CellId
ORDER BY TripId;

-- (10478 rows)
-- Time: 137.398 ms

-- TEMPORAL VERSION

-- The traversed cells of a trip are a temporal integer, and the sequence of the
-- values it takes is TripTilesSeq.CellSeq. The pattern reads that sequence, so
-- the query is the discrete one with TripTilesSeq in place of TripCellsSeq.
-- A window over TripTiles cannot express the pattern at all: a trip has one row
-- per cell there, with its visits held in the AtTime span set, so a cell never
-- appears twice for the window to compare.

DROP TABLE IF EXISTS TGQ13;
CREATE TABLE TGQ13 AS
SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
FROM TripTilesSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
  s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1]
ORDER BY s.TripId, g.Pos;

-- SELECT 10631

-- The discrete query returns 10478 rows. The difference comes from the cells a
-- trip crosses between two observations, which belong to the continuous
-- sequence and not to the sampled one: 215 of the 27118 trips have different
-- sequences in the two approaches. delhi_grid_new.sql reports the three
-- consumption modes of this pattern over both sequences.

-------------------------------------------------------------------------------
/*
Query 14. Trips that traverse at least twice the same district with exactly
one different district in between.
*/

DROP TABLE IF EXISTS GQ14;
CREATE TABLE GQ14 AS
-- Get the three previous visited cells
WITH CellSeq(TripId, CellId, StartTime, Prev3Cell, Prev2Cell, PrevCell) AS (
  SELECT TripId, CellId, StartTime, LAG(CellId, 3) OVER w,
    LAG(CellId, 2) OVER w,  LAG(CellId, 1) OVER w
  FROM TripCells
  WINDOW w AS (PARTITION BY TripId ORDER BY StartTime) )
SELECT TripId, array_agg(Prev3Cell::text || ':' || Prev2Cell::text || ':' ||
  PrevCell::text || ':' || CellId::text ORDER BY StartTime) AS Patterns
FROM CellSeq
WHERE Prev3Cell IS NOT NULL AND Prev2Cell IS NOT NULL AND
  PrevCell IS NOT NULL AND CellId = Prev3Cell AND Prev2Cell <> PrevCell AND 
  Prev2Cell <> CellId AND PrevCell <> CellId
GROUP BY TripId
ORDER BY TripId;

-- SELECT 63
-- Time: 99.441 ms

-- The same reading as the previous query, over the four-cell pattern: the trip
-- returns to a cell after two different cells, all three distinct.

DROP TABLE IF EXISTS TGQ14;
CREATE TABLE TGQ14 AS
WITH Matches(TripId, Pos, MatchSeq) AS (
  SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 3]
  FROM TripTilesSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 3) AS g(Pos)
  WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 3] AND
    s.CellSeq[g.Pos + 1] <> s.CellSeq[g.Pos + 2] AND
    s.CellSeq[g.Pos + 1] <> s.CellSeq[g.Pos] AND
    s.CellSeq[g.Pos + 2] <> s.CellSeq[g.Pos] )
SELECT TripId, array_agg(MatchSeq[1]::text || ':' || MatchSeq[2]::text || ':' ||
  MatchSeq[3]::text || ':' || MatchSeq[4]::text ORDER BY Pos) AS Patterns
FROM Matches
GROUP BY TripId
ORDER BY TripId;

/*****************************************************************************/

/*****************************************************************************
 * APPENDIX. The cell pattern of Query 13 under the three consumption modes.
 *
 * The section below isolates the effect of the recovered cells on the pattern
 * A B A over the sequence of cells, under each of the three consumption modes
 * described in delhi_districts_new.sql. It is kept apart from the queries
 * above because it compares the two sequences of cells directly, without the
 * measures.
 *****************************************************************************/

SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

-------------------------------------------------------------------------------
-- Overlapping matches: every position at which the pattern holds. A cell that
-- closes one match may open the next, so a sequence {a,b,a,b,a} yields three.
-------------------------------------------------------------------------------

DROP TABLE IF EXISTS GP_Over;                                    -- discrete
CREATE TABLE GP_Over AS
SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
FROM TripCellsSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
  s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1]
ORDER BY s.TripId, g.Pos;

-- 10478 rows

DROP TABLE IF EXISTS TGP_Over;                                   -- continuous
CREATE TABLE TGP_Over AS
SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
FROM TripTilesSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
  s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1]
ORDER BY s.TripId, g.Pos;

-- 10631 rows

-------------------------------------------------------------------------------
-- Disjoint matches: a match may not start before the previous one has ended, so
-- the same {a,b,a,b,a} yields one.
-------------------------------------------------------------------------------

DROP TABLE IF EXISTS GP_Disj;                                    -- discrete
CREATE TABLE GP_Disj AS
WITH AllMatches AS (
  SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
  FROM TripCellsSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
  WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
    s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1] ),
Ranked AS (
  SELECT *, LAG(Pos) OVER (PARTITION BY TripId ORDER BY Pos) AS PrevPos
  FROM AllMatches )
SELECT TripId, Pos, MatchSeq
FROM Ranked
WHERE PrevPos IS NULL OR Pos >= PrevPos + 3
ORDER BY TripId, Pos;

-- 4270 rows

DROP TABLE IF EXISTS TGP_Disj;                                   -- continuous
CREATE TABLE TGP_Disj AS
WITH AllMatches AS (
  SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
  FROM TripTilesSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
  WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
    s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1] ),
Ranked AS (
  SELECT *, LAG(Pos) OVER (PARTITION BY TripId ORDER BY Pos) AS PrevPos
  FROM AllMatches )
SELECT TripId, Pos, MatchSeq
FROM Ranked
WHERE PrevPos IS NULL OR Pos >= PrevPos + 3
ORDER BY TripId, Pos;

-- 4320 rows

-------------------------------------------------------------------------------
-- Matches of arbitrary length: A X* A, where the cell does not reappear in
-- between, which is the sequence analogue of a simple cycle.
-------------------------------------------------------------------------------

DROP TABLE IF EXISTS GP_AnyLen;                                  -- discrete
CREATE TABLE GP_AnyLen AS
SELECT s.TripId, g1.StartPos, g2.EndPos,
  s.CellSeq[g1.StartPos : g2.EndPos] AS MatchSeq
FROM TripCellsSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 1) AS g1(StartPos)
CROSS JOIN LATERAL generate_series(g1.StartPos + 2, array_length(s.CellSeq, 1)) AS g2(EndPos)
WHERE s.CellSeq[g1.StartPos] = s.CellSeq[g2.EndPos]
  AND NOT EXISTS (
    SELECT 1 FROM generate_series(g1.StartPos + 1, g2.EndPos - 1) AS g(MidPos)
    WHERE s.CellSeq[g.MidPos] = s.CellSeq[g1.StartPos] )
ORDER BY s.TripId, g1.StartPos;

-- 20193 rows

DROP TABLE IF EXISTS TGP_AnyLen;                                 -- continuous
CREATE TABLE TGP_AnyLen AS
SELECT s.TripId, g1.StartPos, g2.EndPos,
  s.CellSeq[g1.StartPos : g2.EndPos] AS MatchSeq
FROM TripTilesSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 1) AS g1(StartPos)
CROSS JOIN LATERAL generate_series(g1.StartPos + 2, array_length(s.CellSeq, 1)) AS g2(EndPos)
WHERE s.CellSeq[g1.StartPos] = s.CellSeq[g2.EndPos]
  AND NOT EXISTS (
    SELECT 1 FROM generate_series(g1.StartPos + 1, g2.EndPos - 1) AS g(MidPos)
    WHERE s.CellSeq[g.MidPos] = s.CellSeq[g1.StartPos] )
ORDER BY s.TripId, g1.StartPos;

-- 20497 rows

-------------------------------------------------------------------------------
-- Where the two approaches disagree, and why
-------------------------------------------------------------------------------

-- The trips whose cell sequence differs between the approaches
SELECT count(*) AS TripsWithDifferentSequence
FROM TripCellsSeq c JOIN TripTilesSeq t USING (TripId)
WHERE c.CellSeq <> t.CellSeq;
-- 215

-- The two worked examples
SELECT c.TripId, c.CellSeq AS DiscreteSeq, t.CellSeq AS ContinuousSeq
FROM TripCellsSeq c JOIN TripTilesSeq t USING (TripId)
WHERE c.TripId IN (275, 2684)
ORDER BY c.TripId;
-- 275  | {54,64,63,73,82,83} | {54,64,63,73,72,82,83}
-- 2684 | {86,96,97,86,87}    | {86,96,97,87,86,87}

-- The cell that the sampled sequence lacks is one the trip really traverses
SELECT TripId, CellId, numSpans(AtTime) AS Visits, duration(AtTime) AS TimeInCell
FROM TripTiles
WHERE (TripId, CellId) IN ((275, 72), (2684, 87))
ORDER BY TripId;
-- 275  | 72 | 1 | 00:00:52.357513
-- 2684 | 87 | 2 | 00:07:58.355908

-- and no observation of trip 275 lies in cell 72, which is why the discrete
-- sequence skips it
SELECT count(*) AS SamplesOfTrip275InCell72
FROM TripPoints p, Grid g
WHERE p.TripId = 275 AND g.CellId = 72 AND g.Box @> stbox(p.Geom);
-- 0, out of the 691 observations of the trip

-- The matches that exist only in the continuous approach
SELECT count(*) AS ContinuousOnlyOverlappingMatches
FROM (SELECT TripId, MatchSeq FROM TGP_Over
      EXCEPT ALL
      SELECT TripId, MatchSeq FROM GP_Over) x;

-------------------------------------------------------------------------------
