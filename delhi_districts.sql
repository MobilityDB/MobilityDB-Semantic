/*****************************************************************************/

SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

-------------------------------------------------------------------------------
/*
Query 5.15. Trips that traversed at least twice the same district with exactly
one different district in between.
*/

-- Overlapping patterns
DROP TABLE IF EXISTS Q5_15_Over;
CREATE TABLE Q5_15_Over AS
SELECT s.TripId, d.Pos, s.DistrictSeq[d.Pos : d.Pos + 2] AS MatchSeq
FROM TripDistrictsSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.DistrictSeq, 1) - 2) AS d(Pos)
WHERE s.DistrictSeq[d.Pos] = s.DistrictSeq[d.Pos + 2] AND
  s.DistrictSeq[d.Pos] <> s.DistrictSeq[d.Pos + 1]
ORDER BY s.TripId;

-- SELECT 9262
-- Time: 70.657 ms

-- Disjoint patterns
DROP TABLE IF EXISTS Q5_15_Disj;
CREATE TABLE Q5_15_Disj AS
WITH AllMatches AS (
  SELECT s.TripId, d.Pos, s.DistrictSeq[d.Pos:d.Pos + 2] AS MatchSeq
  FROM TripDistrictsSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.DistrictSeq, 1) - 2) AS d(Pos)
  WHERE s.DistrictSeq[d.Pos] = s.DistrictSeq[d.Pos + 2] AND
    s.DistrictSeq[d.Pos] <> s.DistrictSeq[d.Pos + 1] ),
Ranked AS (
  SELECT *, LAG(Pos) OVER (PARTITION BY TripId ORDER BY Pos) AS PrevPos
  FROM AllMatches )
SELECT TripId, Pos, MatchSeq
FROM Ranked
WHERE PrevPos IS NULL OR Pos >= PrevPos + 3
ORDER BY TripId, Pos;

-- SELECT 1906
-- Time: 71.043 ms

-- Overlapping patterns of A.*A
DROP TABLE IF EXISTS Q5_15_AnyLen;
CREATE TABLE Q5_15_AnyLen AS
SELECT s.TripId, g1.StartPos, g2.EndPos,
  s.DistrictSeq[g1.StartPos : g2.EndPos] AS MatchSeq
FROM TripDistrictsSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.DistrictSeq, 1) - 1) AS g1(StartPos)
  CROSS JOIN LATERAL generate_series(g1.StartPos + 2, array_length(s.DistrictSeq, 1)) AS g2(EndPos)
WHERE s.DistrictSeq[g1.StartPos] = s.DistrictSeq[g2.EndPos]
AND NOT EXISTS (
  SELECT 1
  FROM generate_series(g1.StartPos + 1, g2.EndPos - 1) AS d(MidPos)
  WHERE s.DistrictSeq[d.MidPos] = s.DistrictSeq[g1.StartPos] )
ORDER BY s.TripId, g1.StartPos;

-- SELECT 10201
-- Time: 251.100 ms

-------------------------------------------------------------------------------
/*
Query 5.16. Trips that traversed one district with the following development of
spatiotemporal predicates: Disjoint -> Meets -> Inside -> Meets -> Disjoint
*/

-- Overlapping patterns
DROP TABLE IF EXISTS Q5_16_Over;
CREATE TABLE Q5_16_Over AS
WITH Meets(TripId, Name, AtTimestamp) AS (
  SELECT t.TripId, d.Name, 
    lower(unnest(spans(whenTrue(tIntersects(t.Trip, d.Boundary)))))
  FROM Trips t, Districts d
  WHERE eIntersects(t.Trip, d.Boundary)
  ORDER BY t.TripId, d.Name ),
ContainedBy(TripId, Name, AtTime) AS (
  SELECT t.TripId, d.Name, 
    unnest(spans(whenTrue(tContains(d.Geom, t.Trip))))
  FROM Trips t, Districts d
  WHERE eIntersects(t.Trip, d.Geom)
  ORDER BY t.TripId, d.Name )
SELECT m1.TripId, m1.Name, m1.AtTimestamp AS StartTimestamp, c.AtTime, m2.AtTimestamp AS EndTimestamp
FROM Meets m1, ContainedBy c, Meets m2
WHERE m1.TripId = c.TripId AND m1.Name = c.Name AND
  m2.TripId = c.TripId AND m2.Name = c.Name AND
  m2.AtTimestamp = upper(c.AtTime)
ORDER BY m1.TripId, m1.Name;

/*****************************************************************************/
