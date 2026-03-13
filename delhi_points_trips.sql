
SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

------------------------------------------------------------------------------

/*
Query 5.8. Trips where the Pm25 increases throughout the entire trip

Trip[sign(derivative(Pm25)) > 0]
*/

DROP TABLE IF EXISTS Q5_8;
CREATE TABLE Q5_8 AS
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

DROP TABLE IF EXISTS TQ5_8;
CREATE TABLE TQ5_8 AS
SELECT TripId, Pm25
FROM Trips
WHERE trend(Pm25) %> 0;

-- SELECT 708
-- Time: 1228.327 ms (00:01.228)

-------------------------------------------------------------------------------

SELECT DISTINCT TripId FROM tq5_8 EXCEPT SELECT DISTINCT TripId FROM q5_8;
-- (0 rows)

SELECT DISTINCT TripId FROM q5_8 EXCEPT SELECT DISTINCT TripId FROM tq5_8;
-- (0 rows)

-------------------------------------------------------------------------------

/*
5.9. Trips where the Pm25 increases for at least 1.5 minutes and
then decreases for at least 1.5 minutes, such that in both episodes the Pm25
is higher than 125 and the temperature is higher than 20 degrees.

IncrPm25: Trip[sign(derivative(Pm25)) > 0]
DecrPm25: Trip[sign(derivative(Pm25)) < 0]
IncrDecrSpeed: Trip[before([IncrPm25 AND duration(IncrPm25) >= '1.5 minutes'],
  [DecrPm25 AND duration(DecrPm25) >= '1.5 minutes'])]
Trip[IncrDecrSpeed AND Pm25 > 125 AND Temperature > 20]
*/

DROP TABLE IF EXISTS Q5_9;
CREATE TABLE Q5_9 AS
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

DROP TABLE IF EXISTS TQ5_9;
CREATE TABLE TQ5_9 AS
WITH RestTrips(TripId, Pm25) AS (
  SELECT TripId, atTime(Pm25, whenTrue(Pm25 #> 125) * 
    whenTrue(tfloat(Weather, 'Temperature', 'step') #> 20))
  FROM Trips
  WHERE whenTrue(Pm25 #> 125) IS NOT NULL AND
    whenTrue(tfloat(Weather, 'Temperature', 'step') #> 20) IS NOT NULL ),
IncrPm25(TripId, Pm25) AS (
  SELECT TripId, unnest(sequences(atTime(Pm25, 
    whenTrue(segmentMinDuration(atValues(trend(Pm25) #> 0, true),
      interval '1.5 minute', false)))))
  FROM RestTrips ),
DecrPm25(TripId, Pm25) AS (
  SELECT TripId, unnest(sequences(atTime(Pm25,
    whenTrue(segmentMinDuration(atValues(trend(Pm25) #< 0, true),
      interval '1.5 minute', false)))))
  FROM RestTrips )
SELECT i.TripId, i.Pm25 AS IncrPm25, d.Pm25 AS DecrPm25
FROM IncrPm25 i, DecrPm25 d
WHERE i.TripId = d.TripId AND endTimestamp(i.Pm25) = startTimestamp(d.Pm25)
ORDER BY TripId, IncrPm25;

-- SELECT 20
-- Time: 2836.859 ms (00:02.837)

-------------------------------------------------------------------------------

SELECT DISTINCT TripId FROM q5_9 EXCEPT SELECT DISTINCT TripId FROM tq5_9 ORDER BY 1;
(0 rows)

SELECT DISTINCT TripId FROM tq5_9 EXCEPT SELECT DISTINCT TripId FROM q5_9 ORDER BY 1;
   2245
(1 row)

/*
The missing trip in q5_9 is 2245 and it is not considered in the non-temporal 
version since the latter does not differentiate to exclusive bounds as shown next.

q5_9: Content of Episodes where tripid = 2245
 tripid | phaseid |             t             |           nextt           | pm25 | nextpm25 | temp | nexttemp | trend
--------+---------+---------------------------+---------------------------+------+----------+------+----------+-------
   2245 |     164 | 2020-12-02 17:56:02+05:30 | 2020-12-02 17:56:05+05:30 |  188 |      183 | 20.3 |     20.3 |    -1
   2245 |     164 | 2020-12-02 17:56:05+05:30 | 2020-12-02 18:00:34+05:30 |  183 |      174 | 20.3 |       20 |    -1

select t.tripid, atTime(weather, Incr) as Incr, atTime(weather, Decr) as decr from trips t, tq5_9 q where t.tripid = 2245 and q.tripid = 2245;
 tripid |                                                                                                       incr                                                                                                       |                                                                                                       decr                                 
--------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------+------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
   2245 | [{"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 17:54:28+05:30, {"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 17:56:02+05:30) | [{"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 17:56:02+05:30, {"Rain": 0, "Wind": 8, "Humidity": 54, "CloudCover": 0, "Temperature": 20.3}@2020-12-02 18:00:34+05:30)
(1 row)
*/

-------------------------------------------------------------------------------

/*
Query 5.10. Trips that have at some point the \textsf{Pm25} lower than 100 and
later reach a value higher than 400, such that the elapsed time between
the increase of values in less than thirty minutes.

StartPm25: Trip[Pm25 < 100]
EndPm25: Trip[Pm25 > 400]
Trip[before(StartPm25, EndPm25) AND
  lower(EndPm25) - lower(StartPm25) < interval '30 minutes']
*/

DROP TABLE IF EXISTS Q5_10;
CREATE TABLE Q5_10 AS
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

DROP TABLE IF EXISTS TQ5_10;
CREATE TABLE TQ5_10 AS
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

SELECT DISTINCT tripid FROM tq5_10 EXCEPT SELECT DISTINCT tripid FROM q5_10 ORDER BY 1 LIMIT 5;
(0 rows)

SELECT DISTINCT tripid FROM q5_10 EXCEPT SELECT DISTINCT tripid FROM tq5_10 ORDER BY 1 LIMIT 5;
(0 rows)

-------------------------------------------------------------------------------
 
/*
Query 5.11. Trips that travel all their way under a temperature higher than
25 degrees and such that at in at least two episodes longer than ten minutes,
the \textsf{Pm25} is higher than 150.

HighTemp: Trip[Temperature > 25]
TripTemp: Trip[HighTemp AND getTime(HighTemp) = getTime(Trip)]
HighPm25: Trip[TripTemp AND Pm25 > 150]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '10 minutes']
Trip[before(Episode, Episode+)]
*/

DROP TABLE IF EXISTS Q5_11;
CREATE TABLE Q5_11 AS
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

DROP TABLE IF EXISTS TQ5_11;
CREATE TABLE TQ5_11 AS
WITH SelectedTrips(TripId, Pm25, AtTime) AS (
  SELECT TripId, Pm25, unnest(spans(whenTrue(Pm25 #> 150)))
  FROM Trips
  WHERE tfloat(Weather, 'Temperature', 'step') %> 25 AND
    whenTrue(Pm25 #> 150) IS NOT NULL )
SELECT TripId, array_agg(AtTime) FILTER (WHERE Duration(AtTime) > '10 minutes')
FROM SelectedTrips
WHERE Duration(AtTime) > '10 minutes'
GROUP BY TripId
HAVING COUNT(*) > 1;

-- SELECT 4
-- Time: 189.536 ms

-------------------------------------------------------------------------------

SELECT DISTINCT tripid FROM tq5_11 EXCEPT SELECT DISTINCT tripid FROM q5_11 ORDER BY 1 LIMIT 5;
-- (0 rows)

SELECT DISTINCT tripid FROM q5_11 EXCEPT SELECT DISTINCT tripid FROM tq5_11 ORDER BY 1 LIMIT 5;
-- (0 rows)

-------------------------------------------------------------------------------
/*
Query 5.12. Trips such that there is at least a 30-minutes phase where
Pm25 was continuously higher than 300 in cloudy conditions, and
with Humidity higher than 80%.

HighTemp: Trip[Temperature > 25]
TripTemp: Trip[HighTemp AND getTime(HighTemp) = getTime(Trip)]
HighPm25: Trip[TripTemp AND Pm25 > 150]
Episode: Trip[HighPm25 AND duration(HighPm25) > interval '30 minutes']
Trip[before(Episode, Episode+)]
*/

DROP TABLE IF EXISTS Q5_12;
CREATE TABLE Q5_12 AS
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

DROP TABLE IF EXISTS TQ5_12;
CREATE TABLE TQ5_12 AS
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

SELECT DISTINCT tripid FROM tq5_12 EXCEPT SELECT DISTINCT tripid FROM q5_12 ORDER BY 1 LIMIT 5;
-- (0 rows)

SELECT DISTINCT tripid FROM q5_12 EXCEPT SELECT DISTINCT tripid FROM tq5_12 ORDER BY 1 LIMIT 5;
-- (0 rows)

-------------------------------------------------------------------------------

