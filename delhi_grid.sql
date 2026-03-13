/*****************************************************************************/

SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

-------------------------------------------------------------------------------
/*
Query 5.9. Trips  where the Pm25 increases throughout the entire trip.

IncrPm25: Trip[sign(derivative(Pm25)) > 0]
Trip[IncrPm25 AND getTime(IncrPm25) = getTime(Trip)]
*/

DROP TABLE IF EXISTS GQ5_9;
CREATE TABLE GQ5_9(TripId, Cells, Pm25Seq) AS
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

DROP TABLE IF EXISTS TGQ5_9;
CREATE TABLE TGQ5_9(TripId, Cells, Pm25Seq) AS
WITH TrendPm25(TripId, CellId, Weather, Pm25, Trend) AS (
  SELECT TripId, CellId, Weather, Pm25, trend(Pm25)
  FROM TripTiles
  WHERE trend(Pm25) %> 0 ),
SelectedTrip(TripId) AS (
  SELECT TripId 
  FROM TrendPm25
  GROUP BY TripId 
  HAVING COUNT(*) >= 2 )
SELECT TripId, tintSeq(array_agg(tint(CellId, lower(AtTime)) ORDER BY AtTime))
  AS Cells, merge(array_agg(Pm25 ORDER BY AtTime)) AS Pm25
FROM TripTiles
WHERE TripId IN (SELECT TripId FROM SelectedTrip)
GROUP BY TripId
ORDER BY TripId;

-- SELECT 155
-- Time: 5431.992 ms (00:05.432)

-------------------------------------------------------------------------------
/*
5.10. Trips where the Pm25 increases for at least 1.5 minutes and
then decreases for at least 1.5 minutes, such that in both episodes the Pm25
is higher than 125 and the temperature is higher than 20 degrees.

IncrPm25: Trip[sign(derivative(Pm25)) > 0]
DecrPm25: Trip[sign(derivative(Pm25)) < 0]
IncrDecrSpeed: Trip[before([IncrPm25 AND duration(IncrPm25) >= '1.5 minutes'],
  [DecrPm25 AND duration(DecrPm25) >= '1.5 minutes'])]
Trip[IncrDecrSpeed AND Pm25 > 125 AND Temperature > 20]
*/

DROP TABLE IF EXISTS GQ5_10;
CREATE TABLE GQ5_10(TripId, EpisodeId, StartTime, EndTime, Duration, Cells,
  Trend, Pm25seq) AS
WITH TrendPm25(TripId, StartTime, EndTime, CellId, Pm25, Trend) AS (
  SELECT TripId, StartTime, EndTime, CellId, Pm25, SIGN(Pm25 -
    (LAG(Pm25) OVER (PARTITION BY TripId ORDER BY StartTime)))
  FROM TripCells ),
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

-- SELECT SELECT 3386
-- Time: 562.254 ms

-- TEMPORAL VERSION

DROP TABLE IF EXISTS TGQ5_10;
CREATE TABLE TGQ5_10(TripId, EpisodeId, AtTime, Duration, Cells,
  Trend, Pm25) AS
WITH TrendPm25(TripId, AtTime, CellId, Pm25, Trend) AS (
  SELECT TripId, AtTime, CellId, Pm25, trend(Pm25)
  FROM TripTiles ),
EpisodeStart(TripId, AtTime, CellId, Pm25, Trend, NewEpisode) AS (
  SELECT TripId, AtTime, CellId, Pm25, Trend,
    CASE
      WHEN Trend IS NULL OR Trend <> LAG(Trend) OVER
        (PARTITION BY TripId ORDER BY AtTime) THEN 1 ELSE 0
    END
  FROM TrendPm25 ),
Episode(TripId, EpisodeId, AtTime, CellId, Pm25, Trend) AS (
  SELECT TripId, SUM(NewEpisode) OVER (PARTITION BY TripId ORDER BY
    AtTime), AtTime, CellId, Pm25, Trend
  FROM EpisodeStart ),
EpisodeDuration(TripId, EpisodeId, AtTime, Trend, Cells, Pm25) AS (
  SELECT TripId, EpisodeId, spanUnion(AtTime ORDER BY AtTime),
    merge(array_agg(Trend ORDER BY Trend)),
    tintSeq(array_agg(tint(CellId, lower(AtTime)) ORDER BY AtTime)),
    merge(array_agg(Pm25 ORDER BY Pm25))
  FROM Episode
  GROUP BY TripId, EpisodeId
  HAVING duration(spanUnion(AtTime ORDER BY AtTime)) >= interval '1.5 minutes'
    AND COUNT(*) >= 2 ),
EpisodePair(TripId, IncrEpisode, DecrEpisode) AS (
  SELECT e1.TripId, e1.EpisodeId, e2.EpisodeId
  FROM EpisodeDuration e1, EpisodeDuration e2
  WHERE e1.TripId = e2.TripId AND e1.EpisodeId + 1 = e2.EpisodeId AND
    startValue(e1.Trend) = 1 AND startValue(e2.Trend) = -1 )
SELECT e.TripId, EpisodeId, AtTime, duration(AtTime), Cells, Trend, Pm25
FROM EpisodeDuration e, EpisodePair p
WHERE e.TripId = p.TripId AND e.EpisodeId IN (p.IncrEpisode, p.DecrEpisode)
ORDER BY e.TripId;

-------------------------------------------------------------------------------

/*
Query 5.11. Trips that have at some point the \textsf{Pm25} lower than 100 and
later reach a value higher than 400, such that the elapsed time between
the increase of values in less than 1 minute.

StartPm25: Trip[Pm25 < 100]
EndPm25: Trip[Pm25 > 400]
Trip[before(StartPm25, EndPm25) AND
  lower(EndPm25) - lower(StartPm25) < '1 minute']
*/

DROP TABLE IF EXISTS GQ5_11;
CREATE TABLE GQ5_11(TripId, StartTime, EndTime, Duration, Cells, Pm25seq) AS
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

DROP TABLE IF EXISTS TGQ5_11;
CREATE TABLE TGQ5_11(TripId, AtTime, Duration, Cells, Pm25seq) AS
WITH StartPm25(TripId, StartStep, StartCell, StartTime, StartPm25) AS (
  SELECT TripId, StepNo, CellId, lower(AtTime), Pm25
  FROM TripTiles c1
  WHERE StepNo = (
    SELECT MIN(StepNo)
    FROM TripTiles c2
    WHERE c1.TripId = c2.Tripid AND Pm25 ?< 100 ) ),
EndPm25(TripId, EndStep, EndCell, EndTime, EndPm25) AS (
  SELECT TripId, StepNo, CellId, upper(AtTime), Pm25
  FROM TripTiles c1
  WHERE StepNo = (
    SELECT MIN(StepNo)
    FROM TripTiles c2
    WHERE c1.TripId = c2.Tripid AND Pm25 ?> 400 ) ),
Episode(TripId, AtTime, Duration) AS (
  SELECT s.TripId, span(StartTime, EndTime), duration(span(StartTime, EndTime))
  FROM StartPm25 s, EndPm25 e
  WHERE s.TripId = e.Tripid AND StartTime < EndTime AND
    EndTime - StartTime >= '1 minute' )
SELECT t.TripId, e.AtTime, e.Duration,
  tintSeq(array_agg(tint(CellId, lower(t.AtTime)) ORDER BY t.AtTime)),
  array_agg(ROUND(t.Pm25, 2) ORDER BY t.AtTime) AS Pm25seq
FROM TripTiles t, Episode e
WHERE t.TripId = e.TripId AND t.AtTime && e.AtTime
GROUP BY t.TripId, e.AtTime, e.Duration
ORDER BY TripId, AtTime;

-------------------------------------------------------------------------------
/*
Query 5.12. Trips that travel all their way under a temperature higher than
25 degrees and such that at in at least two episodes longer than thirty minutes,
the Pm25 is higher than 150.
*/

DROP TABLE IF EXISTS GQ5_12;
CREATE TABLE GQ5_12(TripId, EpisodeId, StartTime, EndTime, Duration, Cells, Pm25seq) AS
WITH TripTemp(TripId) AS (
  SELECT TripId 
  FROM TripCells
  GROUP BY TripId
  HAVING MIN((Weather->>'Temperature')::numeric) > 25 ),
LowerPm25(TripId, StartTime, EndTime, CellId, Pm25, StartEpisode) AS (
  SELECT TripId, StartTime, EndTime, CellId, Pm25,
    CASE
      WHEN whenTrue(Pm25 #> 150)
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

DROP TABLE IF EXISTS TGQ5_12;
CREATE TABLE TGQ5_12(TripId, EpisodeId, AtTime, Duration, Cells, Pm25) AS
WITH TripTemp(TripId) AS (
  SELECT TripId 
  FROM TripTiles
  WHERE tfloat(Weather, 'Temperature', 'step') %> 25 ),
LowerPm25(TripId, AtTime, CellId, Pm25, StartEpisode) AS (
  SELECT TripId, AtTime, CellId, Pm25,
    CASE
      WHEN Pm25 <= 150 OR LAG(Pm25) OVER
        (PARTITION BY TripId ORDER BY StartTime) <= 150
      THEN 1 ELSE 0
    END
  FROM TripTiles
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

-------------------------------------------------------------------------------
/*
Query 5.13.
Trips such that there is at least a 30-minute episode where the \textsf{Pm25}
is higher than 300 in cloudy conditions and with humidity higher than 80\%.

HighPm25: Trip[Pm25 > 300]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '30 minutes']
Trip[Episode AND CloudCover > 0 AND Humidity > 80]

*/

DROP TABLE IF EXISTS Q5_13;
CREATE TABLE Q5_13 AS
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

DROP TABLE IF EXISTS TQ5_13;
CREATE TABLE Q5_13 AS
WITH Segment(TripId, StartTime, EndTime, Pm25, CloudCover, Humidity, Valid) AS (
  SELECT TripId, StartTime, EndTime, Pm25, (Weather->>'CloudCover')::numeric,
    (Weather->>'Humidity')::numeric,
    CASE
      WHEN Pm25 > 300 AND (Weather->>'CloudCover')::numeric > 0 AND
        (Weather->>'Humidity')::numeric > 80
      THEN 1 ELSE 0
    END 
  FROM TripTiles ),
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

-------------------------------------------------------------------------------
/*
Query 5.14. Trips that traversed at least twice the same cell with exactly
one different cell in between.
*/

-- Overlapping patterns
DROP TABLE IF EXISTS Q5_14_Over;
CREATE TABLE Q5_14 AS
SELECT s.TripId, g.Pos, s.CellSeq[g.Pos : g.Pos + 2] AS MatchSeq
FROM TripCellsSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.CellSeq, 1) - 2) AS g(Pos)
WHERE s.CellSeq[g.Pos] = s.CellSeq[g.Pos + 2] AND
s.CellSeq[g.Pos] <> s.CellSeq[g.Pos + 1]
ORDER BY s.TripId;

-- Disjoint patterns
DROP TABLE IF EXISTS Q5_14_Disj;
CREATE TABLE Q5_14_Disj AS
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
DROP TABLE IF EXISTS Q5_14_AnyLen;
CREATE TABLE Q5_14_AnyLen AS
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
Query 5.14. Trips that traversed at least twice the same cell with exactly
one different cell in between.
*/

DROP TABLE IF EXISTS Q5_14;
CREATE TABLE Q5_14 AS
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

DROP TABLE IF EXISTS TQ5_14;
CREATE TABLE TQ5_14 AS
WITH CellSeq(TripId, StepNo, CellId, AtTime, Prev2Cell, PrevCell) AS (
  SELECT TripId, StepNo, CellId, AtTime, LAG(CellId, 2) OVER w, 
    LAG(CellId, 1) OVER w
  FROM TripTiles
  WINDOW w AS (PARTITION BY TripId ORDER BY StepNo) )
SELECT TripId, Prev2Cell, PrevCell, CellId
FROM CellSeq
WHERE Prev2Cell IS NOT NULL AND PrevCell IS NOT NULL AND
  CellId = Prev2Cell AND PrevCell <> CellId
ORDER BY TripId;

-------------------------------------------------------------------------------
/*
Query 5.15. Trips that traversed at least twice the same cell with exactly
two different cells in between. In this case we are asking for patterns like
A -> B -> C -> A, with the following constraints:
• The first and last cells are the same
• There are exactly two cells in between, such the two middle cells are both
different, that is B <> C, B <> A, C <> A
*/

DROP TABLE IF EXISTS Q5_15;
CREATE TABLE Q5_15 AS
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

DROP TABLE IF EXISTS TQ5_15;
CREATE TABLE TQ5_15 AS

DROP TABLE IF EXISTS TQ5_15;
CREATE TABLE TQ5_15 AS
-- Get the three previous visited cells
WITH CellSeq(TripId, CellId, AtTime, Prev3Cell, Prev2Cell, PrevCell) AS (
  SELECT TripId, CellId, AtTime, LAG(CellId, 3) OVER w,
    LAG(CellId, 2) OVER w, LAG(CellId, 1) OVER w
  FROM TripTiles
  WHERE TripId = 1704
  WINDOW w AS (PARTITION BY TripId ORDER BY AtTime) )
SELECT TripId, array_agg(Prev3Cell::text || ':' || Prev2Cell::text || ':' ||
  PrevCell::text || ':' || CellId::text ORDER BY AtTime) AS Patterns
FROM CellSeq
WHERE Prev3Cell IS NOT NULL AND Prev2Cell IS NOT NULL AND 
  PrevCell IS NOT NULL AND CellId = Prev3Cell AND Prev2Cell <> PrevCell AND 
  Prev2Cell <> CellId AND PrevCell <> CellId
GROUP BY TripId
ORDER BY TripId;

/*****************************************************************************/
