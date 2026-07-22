/*****************************************************************************
 * Queries over complete trips, discrete and continuous version.
 *
 * The discrete version reads table TripPoints, one row per observation. The
 * continuous version reads table Trips, one row per trip, holding the trip as
 * a temporal point and the measures as temporal values (tfloat Pm25, tjsonb
 * Weather). No value is averaged in either table, so the two versions see the
 * same information and any difference in their answers comes from the query
 * and not from the data. This is what distinguishes this file from
 * delhi_grid.sql, where the discrete version reads per-cell averages.
 *
 * Every pair of queries below is reported with the same shape, one row per
 * episode or one row per trip on both sides, so that the two counts are
 * directly comparable.
 *****************************************************************************/


SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

------------------------------------------------------------------------------

/*
Query 8. Trips where the Pm25 increases throughout the entire trip

Trip[sign(derivative(Pm25)) > 0]
*/

DROP TABLE IF EXISTS Q8;
CREATE TABLE Q8 AS
WITH Segments(TripId, T, Pm25, NextPm25) AS (
  SELECT TripId, T, Pm25, LEAD(Pm25) OVER (PARTITION BY TripId ORDER BY T)
  FROM TripPoints )
SELECT TripId, MIN(T) AS StartTime, MAX(T) AS EndTime,
  array_agg(Pm25 ORDER BY T) AS Pm25Seq
FROM Segments
WHERE NextPm25 IS NOT NULL
GROUP BY TripId
HAVING bool_and(Pm25 < NextPm25)
ORDER BY TripId, StartTime;

-- SELECT 708
-- Time: 14708.198 ms (00:14.708)

-- TEMPORAL VERSION

/* The condition is on the whole trip, and %> is the always-comparison: it
 * holds when the temporal value is greater than the argument at every instant
 * of its definition. The trend of a tfloat is a temporal value like any
 * other, so the query is a single predicate over it. The discrete version
 * must pair each observation with the next one and then require the pair
 * condition to hold for the whole group, which is what bool_and does. Both
 * return the same 708 trips. */

DROP TABLE IF EXISTS TQ8;
CREATE TABLE TQ8 AS
SELECT TripId, Pm25
FROM Trips
WHERE trend(Pm25) %> 0;

-- SELECT 708
-- Time: 1228.327 ms (00:01.228)

-------------------------------------------------------------------------------

SELECT DISTINCT TripId FROM tq8 EXCEPT SELECT DISTINCT TripId FROM q8;
-- (0 rows)

SELECT DISTINCT TripId FROM q8 EXCEPT SELECT DISTINCT TripId FROM tq8;
-- (0 rows)

-------------------------------------------------------------------------------

/*
Query 9. Trips where the Pm25 increases for at least 1.5 minutes and
then decreases for at least 1.5 minutes, such that in both episodes the Pm25
is higher than 125 and the temperature is higher than 20 degrees.

IncrPm25: Trip[sign(derivative(Pm25)) > 0]
DecrPm25: Trip[sign(derivative(Pm25)) < 0]
IncrDecrSpeed: Trip[before([IncrPm25 AND duration(IncrPm25) >= '1.5 minutes'],
  [DecrPm25 AND duration(DecrPm25) >= '1.5 minutes'])]
Trip[IncrDecrSpeed AND Pm25 > 125 AND Temperature > 20]
*/

DROP TABLE IF EXISTS Q9;
CREATE TABLE Q9 AS
WITH Segment(TripId, T, NextT, Pm25, NextPm25, Temp, NextTemp) AS (
  SELECT TripId, T, LEAD(T) OVER w, Pm25, LEAD(Pm25) OVER w,
    (Weather->>'Temperature')::numeric,
    ((LEAD(Weather) OVER w)->>'Temperature')::numeric
  FROM TripPoints
  WINDOW w AS (PARTITION BY TripId ORDER BY T) ),
Crossing(TripId, T, NextT, Pm25, NextPm25, Temp, NextTemp, CrossT) AS (
  SELECT *,
    CASE
      WHEN (Pm25 < 125 AND 125 < nextPm25)
        THEN T + (NextT - T) * (125 - Pm25) / (nextPm25 - Pm25) 
      WHEN (Pm25 > 125 AND 125 > nextPm25)
        THEN T + (NextT - T) * (Pm25 - 125) / (Pm25 - nextPm25)
    END
  FROM Segment
  WHERE NextT IS NOT NULL ),
ClippedSegment(TripId, T, NextT, Pm25, NextPm25, Temp, NextTemp) AS (
  SELECT TripId,
    /* Clipped start and end time */
    CASE WHEN Pm25 > 125 THEN T ELSE CrossT END, 
    CASE WHEN NextPm25 > 125 THEN NextT ELSE CrossT END,
    /* Clipped start and end value */
    GREATEST(Pm25, 125), GREATEST(NextPm25, 125),
    /* For illustration purposes temperature is not interpolated */
    Temp, NextTemp 
  FROM Crossing
  WHERE GREATEST(Pm25, nextPm25) > 125 ),
TrendPm25(TripId, T, NextT, Pm25, NextPm25, Temp, NextTemp, Trend) AS (
  SELECT TripId, T, NextT, Pm25, NextPm25, Temp, NextTemp,
    SIGN(nextPm25 - Pm25)
  FROM ClippedSegment
  WINDOW w AS (PARTITION BY TripId ORDER BY T) ),
EpisodeStart(TripId, T, NextT, Pm25, NextPm25, Temp, NextTemp, Trend,
    NewEpisode) AS (
  SELECT *,
    CASE
      WHEN Trend = LAG(Trend) OVER (PARTITION BY TripId ORDER BY T)
        THEN 0 ELSE 1
    END
  FROM TrendPm25 ),
Episode(TripId, EpisodeId, T, NextT, Pm25, NextPm25, Temp, NextTemp, Trend) AS (
  SELECT TripId, SUM(NewEpisode) OVER (PARTITION BY TripId ORDER BY T), 
    T, NextT, Pm25, NextPm25, Temp, NextTemp, Trend
  FROM EpisodeStart ),
EpisodeTime(TripId, EpisodeId, Trend, StartTime, EndTime, StartPm25, EndPm25,
    StartTemp, EndTemp, Duration) AS (
  SELECT TripId, EpisodeId, Trend, MIN(T), MAX(NextT), MIN(Pm25),
    MAX(NextPm25), MIN(Temp), MAX(NextTemp), MAX(NextT) - MIN(T)
  FROM Episode
  GROUP BY TripId, EpisodeId, Trend
  HAVING MAX(NextT) - MIN(T) >= '1.5 minutes' AND
    bool_and(LEAST(NextTemp, Temp) > 20) ),
Pattern(TripId, IncrEpisode, DecrEpisode) AS (
  SELECT r1.TripId, r1.EpisodeId AS IncrEpisode, r2.EpisodeId AS DecrEpisode
  FROM EpisodeTime r1, EpisodeTime r2
  WHERE r1.TripId = r2.TripId AND r1.Trend = 1 AND r2.Trend = -1 AND
    r1.EndTime = r2.StartTime )
SELECT e.TripId, e.EpisodeId, e.Trend, e.StartTime, e.EndTime, e.Duration,
  e.StartPm25, e.EndPm25, e.StartTemp, e.EndTemp
FROM EpisodeTime e, Pattern s
WHERE s.TripId = e.TripId AND e.EpisodeId IN (s.IncrEpisode, s.DecrEpisode)
ORDER BY e.TripId, e.EpisodeId;

-- SELECT 38
-- Time: 50162.970 ms (00:50.163)

-- TEMPORAL VERSION

/* An episode is a maximal period during which a condition holds. In the
 * temporal version it is not reconstructed: whenTrue(trend(Pm25) #> 0) is
 * the time when the Pm25 increases, segmentMinDuration keeps the parts of it
 * lasting at least 1.5 minutes, and the sequences of the restricted trip are
 * the episodes. The before of the pattern is the equality of the end of an
 * increasing episode with the start of a decreasing one.
 *
 * The discrete version needs, in this order: a window function to reach the
 * next observation, an interpolation to find where the trip crosses the 125
 * threshold between two observations, a clipping of the segments to that
 * threshold, a second window function for the trend, a third for the change
 * of trend, a running sum to number the episodes, and a self join for the
 * before. The interpolation is the part worth noting: the discrete version
 * has to compute by hand, in SQL, the linear interpolation that the temporal
 * type applies by definition. */

DROP TABLE IF EXISTS TQ9;
CREATE TABLE TQ9 AS
WITH RestTrips(TripId, Pm25) AS (
  SELECT TripId, atTime(Pm25, whenTrue(Pm25 #> 125) * 
    whenTrue(tfloat(Weather, 'Temperature', 'step') #> 20))
  FROM Trips
  WHERE whenTrue(Pm25 #> 125) IS NOT NULL AND
    whenTrue(tfloat(Weather, 'Temperature', 'step') #> 20) IS NOT NULL ),
IncrPm25(TripId, Pm25) AS (
  SELECT TripId, unnest(sequences(atTime(Pm25, 
    whenTrue(segmentMinDuration(atValue(trend(Pm25) #> 0, true),
      interval '1.5 minute', false)))))
  FROM RestTrips ),
DecrPm25(TripId, Pm25) AS (
  SELECT TripId, unnest(sequences(atTime(Pm25,
    whenTrue(segmentMinDuration(atValue(trend(Pm25) #< 0, true),
      interval '1.5 minute', false)))))
  FROM RestTrips ),
Pattern(TripId, PairNo, Incr, Decr) AS (
  SELECT i.TripId, ROW_NUMBER() OVER (PARTITION BY i.TripId
    ORDER BY startTimestamp(i.Pm25)), i.Pm25, d.Pm25
  FROM IncrPm25 i, DecrPm25 d
  WHERE i.TripId = d.TripId AND
    endTimestamp(i.Pm25) = startTimestamp(d.Pm25) )
/* One row per episode, as in the discrete version, so that the two answers
 * are directly comparable */
SELECT p.TripId, p.PairNo, e.Trend, startTimestamp(e.Pm25) AS StartTime,
  endTimestamp(e.Pm25) AS EndTime, duration(getTime(e.Pm25)) AS Duration,
  startValue(e.Pm25) AS StartPm25, endValue(e.Pm25) AS EndPm25
FROM Pattern p, LATERAL (VALUES (1, p.Incr), (-1, p.Decr)) AS e(Trend, Pm25)
ORDER BY p.TripId, p.PairNo, e.Trend DESC;

-- SELECT 40
-- Time: 2914.077 ms (00:02.914)

-------------------------------------------------------------------------------

SELECT DISTINCT TripId FROM q9 EXCEPT SELECT DISTINCT TripId FROM tq9 ORDER BY 1;
(0 rows)

SELECT DISTINCT TripId FROM tq9 EXCEPT SELECT DISTINCT TripId FROM q9 ORDER BY 1;
   2245
(1 row)

/*
The missing trip in q9 is 2245 and it is not considered in the non-temporal 
version since the latter does not differentiate to exclusive bounds as shown next.

q9: Content of Episodes where tripid = 2245
 tripid | phaseid |             t             |           nextt           | pm25 | nextpm25 | temp | nexttemp | trend
--------+---------+---------------------------+---------------------------+------+----------+------+----------+-------
   2245 |     164 | 2020-12-02 17:56:02+05:30 | 2020-12-02 17:56:05+05:30 |  188 |      183 | 20.3 |     20.3 |    -1
   2245 |     164 | 2020-12-02 17:56:05+05:30 | 2020-12-02 18:00:34+05:30 |  183 |      174 | 20.3 |       20 |    -1

select t.tripid, atTime(weather, Incr) as Incr, atTime(weather, Decr) as decr from trips t, tq9 q where t.tripid = 2245 and q.tripid = 2245;
 tripid |                                                                                                       incr                                                                                                       |                                                                                                       decr                                 
--------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
   2245 | [{"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 17:54:28+05:30, {"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 17:56:02+05:30) | [{"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 17:56:02+05:30, {"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 18:00:34+05:30)
(1 row)
*/

-------------------------------------------------------------------------------

/*
Query 10. Trips that have at some point the \textsf{Pm25} lower than 100 and
later reach a value higher than 400, such that the elapsed time between
the increase of values in less than thirty minutes.

StartPm25: Trip[Pm25 < 100]
EndPm25: Trip[Pm25 > 400]
Trip[before(StartPm25, EndPm25) AND
  lower(EndPm25) - lower(StartPm25) < interval '30 minutes']
*/

DROP TABLE IF EXISTS Q10;
CREATE TABLE Q10 AS
WITH StartPm25 AS (
  SELECT TripId, MIN(T) AS StartTime
  FROM TripPoints
  WHERE pm25 < 100
  GROUP BY TripId ),
EndPm25 AS (
  SELECT p.TripId, MIN(T) AS EndTime
  FROM TripPoints p, StartPm25 s
  WHERE p.TripId = s.TripId AND p.T >= s.StartTime AND pm25 > 400
  GROUP BY p.TripId )
SELECT p.TripId, s.StartTime, e.EndTime,
  array_agg(p.pm25 ORDER BY p.T) AS Pm25Seq
FROM TripPoints p, StartPm25 s, EndPm25 e
WHERE p.TripId = s.TripId AND s.TripId = e.TripId AND 
  s.StartTime < e.EndTime AND p.T BETWEEN s.StartTime AND e.EndTime AND 
  EndTime - StartTime < '30 minutes'
GROUP BY p.TripId, s.StartTime, e.EndTime
ORDER BY p.TripId;

-- SELECT 94
-- Time: 923.409 ms

-- TEMPORAL VERSION

/* The two versions return the same 94 trips. The temporal version states the
 * query in the order in which it is read: the time when the Pm25 is below
 * 100, the time when it is above 400, and the first before the second. */

DROP TABLE IF EXISTS TQ10;
CREATE TABLE TQ10 AS
WITH StartPm25(TripId, StartTime, Pm25) AS (
  SELECT TripId, lower(whenTrue(Pm25 #< 100)),
    afterTimestamp(Pm25, lower(whenTrue(Pm25 #< 100)), false)
  FROM Trips
  WHERE whenTrue(Pm25 #< 100) IS NOT NULL ),
StartEndPm25(TripId, StartTime, EndTime) AS (
  SELECT TripId, StartTime, lower(whenTrue(Pm25 #> 400))
  FROM StartPm25
  WHERE whenTrue(Pm25 #> 400) IS NOT NULL )
SELECT t.TripId, atTime(Pm25, span(startTime, endTime))
FROM Trips t, StartEndPm25 m
WHERE t.TripId = m.TripId AND startTime < endTime and
  EndTime - StartTime < interval '30 minutes' 
ORDER BY TripId;

-- SELECT SELECT 94
-- Time: 1517.324 ms (00:01.517)

-------------------------------------------------------------------------------

SELECT DISTINCT tripid FROM tq10 EXCEPT SELECT DISTINCT tripid FROM q10 ORDER BY 1 LIMIT 5;
(0 rows)

SELECT DISTINCT tripid FROM q10 EXCEPT SELECT DISTINCT tripid FROM tq10 ORDER BY 1 LIMIT 5;
(0 rows)

-------------------------------------------------------------------------------
 
/*
Query 11. Trips that travel all their way under a temperature higher than
25 degrees and such that at in at least two episodes longer than ten minutes,
the \textsf{Pm25} is higher than 150.

HighTemp: Trip[Temperature > 25]
TripTemp: Trip[HighTemp AND getTime(HighTemp) = getTime(Trip)]
HighPm25: Trip[TripTemp AND Pm25 > 150]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '10 minutes']
Trip[before(Episode, Episode+)]
*/

DROP TABLE IF EXISTS Q11;
CREATE TABLE Q11 AS
WITH TripTemp(TripId) AS (
  SELECT TripId 
  FROM TripPoints
  GROUP BY TripId
  HAVING MIN((Weather->>'Temperature')::numeric) > 25 ),
LowerPm25(TripId, T, Pm25, StartEpisode) AS (
  SELECT TripId, T, Pm25,
    CASE
      WHEN Pm25 <= 150 OR LAG(Pm25) OVER
        (PARTITION BY TripId ORDER BY T) <= 150
      THEN 1 ELSE 0
    END
  FROM TripPoints
  WHERE TripId IN (SELECT TripId FROM TripTemp) ),
Episode(TripId, EpisodeId, T, Pm25) AS (
  SELECT TripId, SUM(StartEpisode) OVER (PARTITION BY TripId ORDER BY T),
    T, Pm25
  FROM LowerPm25 ),
Pattern(TripId, EpisodeId, StartTime, EndTime, Duration, NumPoints) AS (
  SELECT TripId, EpisodeId, MIN(T), MAX(T), MAX(T) - MIN(T), COUNT(*)
  FROM Episode
  WHERE Pm25 > 150
  GROUP BY TripId, EpisodeId
  HAVING MAX(T) - MIN(T) >= interval '10 minutes' AND COUNT(*) >= 2 ),
SelectedTrip(TripId) AS (
  SELECT TripId
  FROM Pattern
  GROUP BY TripId
  HAVING COUNT(*) >= 2 )
SELECT TripId, EpisodeId, StartTime, EndTime, Duration
FROM Pattern 
WHERE TripId IN (SELECT TripId FROM SelectedTrip)
ORDER BY TripId, StartTime;

-- SELECT 8
-- Time: 3244.155 ms (00:03.244)

-- TEMPORAL VERSION

/* The episodes are the spans of whenTrue(Pm25 #> 150): the discrete version
 * must build them with a change-of-state flag and a running sum, and must
 * additionally require COUNT(*) >= 2 to discard the episodes reduced to a
 * single observation, which is meaningless for a temporal value. The result is
 * reported per episode, as in the discrete version, so that the two answers
 * are directly comparable. */

/* The episodes are the spans of whenTrue(Pm25 #> 150): the discrete version
 * must build them with a change-of-state flag and a running sum, and must
 * additionally require COUNT(*) >= 2 to discard the episodes reduced to a
 * single observation, which is meaningless for a temporal value. The always
 * comparison %> gives the condition on the temperature over the whole trip
 * without a grouping. */

DROP TABLE IF EXISTS TQ11;
CREATE TABLE TQ11 AS
WITH Episode(TripId, AtTime) AS (
  SELECT TripId, unnest(spans(whenTrue(Pm25 #> 150)))
  FROM Trips
  WHERE tfloat(Weather, 'Temperature', 'step') %> 25 AND
    whenTrue(Pm25 #> 150) IS NOT NULL ),
Pattern(TripId, AtTime) AS (
  SELECT TripId, AtTime
  FROM Episode
  WHERE duration(AtTime) >= interval '10 minutes' )
SELECT TripId, ROW_NUMBER() OVER (PARTITION BY TripId ORDER BY AtTime)
    AS EpisodeId,
  lower(AtTime) AS StartTime, upper(AtTime) AS EndTime,
  duration(AtTime) AS Duration
FROM Pattern
WHERE TripId IN (SELECT TripId FROM Pattern GROUP BY TripId
  HAVING COUNT(*) >= 2 )
ORDER BY TripId, AtTime;

-- SELECT 8
-- Time: 201.043 ms

/* The two versions agree exactly: the same 8 episodes over the same 4 trips.
 * The temporal query is the one that states the query, the discrete one is
 * the one that reconstructs the episodes. */

-------------------------------------------------------------------------------

SELECT DISTINCT tripid FROM tq11 EXCEPT SELECT DISTINCT tripid FROM q11 ORDER BY 1 LIMIT 5;
-- (0 rows)

SELECT DISTINCT tripid FROM q11 EXCEPT SELECT DISTINCT tripid FROM tq11 ORDER BY 1 LIMIT 5;
-- (0 rows)

-------------------------------------------------------------------------------
/*
Query 12. Trips such that there is at least a 30-minutes phase where
Pm25 was continuously higher than 300 in cloudy conditions, and
with Humidity higher than 80%.

HighTemp: Trip[Temperature > 25]
TripTemp: Trip[HighTemp AND getTime(HighTemp) = getTime(Trip)]
HighPm25: Trip[TripTemp AND Pm25 > 150]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '30 minutes']
Trip[before(Episode, Episode+)]
*/

DROP TABLE IF EXISTS Q12;
CREATE TABLE Q12 AS
WITH Segments AS (
  SELECT TripId, T, Pm25, (Weather->>'CloudCover')::numeric AS CloudCover,
    (Weather->>'Humidity')::numeric AS Humidity,
    CASE
      WHEN Pm25 > 300 AND (Weather->>'CloudCover')::numeric > 0 AND
        (Weather->>'Humidity')::numeric > 80
      THEN 1 ELSE 0
    END AS Valid
  FROM TripPoints ),
SegmentsPrev AS (
  SELECT *, LAG(Valid) OVER (PARTITION BY TripId ORDER BY T) AS PrevValid
  FROM Segments ),
Episodes AS (
  SELECT *, SUM(CASE WHEN Valid = PrevValid THEN 0 ELSE 1 END) OVER
    (PARTITION BY TripId ORDER BY T) AS EpisodeId
  FROM SegmentsPrev )
SELECT TripId, EpisodeId, MIN(T) AS StartTime, MAX(T) AS EndTime,
  MAX(T) - MIN(T) AS Duration, array_agg(Pm25 ORDER BY T) AS Pm25Seq,
  array_agg(CloudCover ORDER BY T) AS CloudCoverSeq,
  array_agg(Humidity ORDER BY T) AS HumiditySeq
FROM Episodes
GROUP BY TripId, EpisodeId
HAVING MAX(T) - MIN(T) >= '30 minutes' AND BOOL_AND(Valid = 1)
ORDER BY TripId, StartTime;

-- SELECT 71
-- Time: 35210.968 ms (00:35.211)

-- TEMPORAL VERSION

/* The condition combines three temporal Booleans with &, the temporal and,
 * and the episodes are the spans of the result. The discrete version has to
 * evaluate the three conditions per observation and then group the
 * observations that satisfy all three into episodes. */

DROP TABLE IF EXISTS TQ12;
CREATE TABLE TQ12 AS
WITH SelectedTripsTime(TripId, Time) AS (
  SELECT TripId, unnest(spans(whenTrue(Pm25 #> 300) * 
    whenTrue(tfloat(Weather, 'CloudCover', 'step') #> 0) * 
    whenTrue(tfloat(Weather, 'Humidity', 'step') #> 80)))
  FROM Trips
  WHERE whenTrue(Pm25 #> 300) IS NOT NULL AND
    whenTrue(tfloat(Weather, 'CloudCover', 'step') #> 0) IS NOT NULL AND
    whenTrue(tfloat(Weather, 'Humidity', 'step') #> 80) IS NOT NULL )
SELECT d.TripId, atTime(d.Pm25, t.Time) AS Pm25, t.Time, 
  duration(t.time) AS Duration
FROM Trips d, SelectedTripsTime t
WHERE d.TripId = t.TripId AND duration(Time) >= '30 minutes'
ORDER BY TripId, Time;

-- SELECT 71
-- Time: 2094.793 ms (00:02.095)

-------------------------------------------------------------------------------

SELECT DISTINCT tripid FROM tq12 EXCEPT SELECT DISTINCT tripid FROM q12 ORDER BY 1 LIMIT 5;
-- (0 rows)

SELECT DISTINCT tripid FROM q12 EXCEPT SELECT DISTINCT tripid FROM tq12 ORDER BY 1 LIMIT 5;
-- (0 rows)

-------------------------------------------------------------------------------

