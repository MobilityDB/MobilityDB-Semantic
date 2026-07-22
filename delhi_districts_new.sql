/*****************************************************************************
 * Queries on the districts of Delhi, discrete and continuous version.
 *
 * The two versions of a query differ only in the sequence of districts they
 * read. Both sequences are built by the loader:
 *
 *   PointDistrictSeq.DistrictSeq   the districts of the observations of the
 *                                  trip, in order. A district is in the
 *                                  sequence only if some observation falls
 *                                  inside it.
 *   TripDistrictsSeq.DistrictSeq   the districts traversed by the trip, in
 *                                  order, obtained from tContains over the
 *                                  temporal point. A district is in the
 *                                  sequence if the trip passes through it,
 *                                  whether or not it was observed there.
 *
 * The second sequence is a projection of the temporal value
 * TripDistrictsSeq.Districts of type ttext, and can be recomputed from it:
 *
 *   SELECT TripId, array_agg(getValue(i) ORDER BY getTimestamp(i))
 *   FROM TripDistrictsSeq, unnest(instants(Districts)) AS i
 *   GROUP BY TripId;
 *
 * This is the district counterpart of the missing-cell effect of the grid
 * queries: a trip that crosses a district between two observations is absent
 * from the discrete sequence and present in the continuous one. The effect is
 * smaller here than on the grid, because districts are much larger than grid
 * cells and are therefore harder to cross unobserved, but it is the same
 * effect and it changes the answer of every query below.
 *****************************************************************************/

SET TIMEZONE TO 'Asia/Kolkata';
SET DATESTYLE TO 'ISO, YMD';

-------------------------------------------------------------------------------
/*
Query 15. Trips that traversed at least twice the same district with exactly
one different district in between.

The pattern is the regular expression A B A over the sequence of districts,
with A <> B. A pattern query does not have a single answer: it has one answer
per consumption mode, that is, per rule deciding how a match consumes the
sequence it matched. The paper states the query and shows one mode; the three
modes are given here, since they answer three different questions and the
difference between them is not a matter of implementation.

  Over     every position where the pattern holds. A B A B A contains three
           matches, at positions 1, 2 and 3, which overlap pairwise. This is
           the mode to use to count occurrences of a situation.
  Disj     the matches that do not overlap, scanning left to right and
           restarting after the end of the accepted match. A B A B A contains
           two matches, at positions 1 and 4. Note that the second one is
           A alone at position 5 in the overlapping reading; requiring
           disjointness makes the answer depend on the scan direction. This is
           the mode to use to count episodes.
  AnyLen   the relaxation of the pattern to A .* A, that is, the same district
           twice with anything in between as long as A itself does not occur
           in between. This is the mode to use to detect a return, whatever
           the length of the detour.

The three are expressed here on arrays, in both versions, because the pattern
is on the succession of districts and not on their timing. What changes
between the two versions is the array.
*/

-- Overlapping patterns
DROP TABLE IF EXISTS Q15_Over;
CREATE TABLE Q15_Over AS
SELECT s.TripId, d.Pos, s.DistrictSeq[d.Pos : d.Pos + 2] AS MatchSeq
FROM PointDistrictSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.DistrictSeq, 1) - 2) AS d(Pos)
WHERE s.DistrictSeq[d.Pos] = s.DistrictSeq[d.Pos + 2] AND
  s.DistrictSeq[d.Pos] <> s.DistrictSeq[d.Pos + 1]
ORDER BY s.TripId;

-- SELECT 8957
-- Time: 68.412 ms

-- TEMPORAL VERSION

DROP TABLE IF EXISTS TQ15_Over;
CREATE TABLE TQ15_Over AS
SELECT s.TripId, d.Pos, s.DistrictSeq[d.Pos : d.Pos + 2] AS MatchSeq
FROM TripDistrictsSeq s
CROSS JOIN LATERAL generate_series(1, array_length(s.DistrictSeq, 1) - 2) AS d(Pos)
WHERE s.DistrictSeq[d.Pos] = s.DistrictSeq[d.Pos + 2] AND
  s.DistrictSeq[d.Pos] <> s.DistrictSeq[d.Pos + 1]
ORDER BY s.TripId;

-- SELECT 9262
-- Time: 70.657 ms

/* The query text is identical, the answers are not: 8957 against 9262. The
 * 305 additional matches are the ones in which the middle district B was
 * traversed without being observed, so that the discrete sequence reads A A
 * instead of A B A and the pattern does not hold. */

-- Disjoint patterns
DROP TABLE IF EXISTS Q15_Disj;
CREATE TABLE Q15_Disj AS
WITH AllMatches AS (
  SELECT s.TripId, d.Pos, s.DistrictSeq[d.Pos:d.Pos + 2] AS MatchSeq
  FROM PointDistrictSeq s
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

-- SELECT 1891
-- Time: 69.905 ms

-- TEMPORAL VERSION

DROP TABLE IF EXISTS TQ15_Disj;
CREATE TABLE TQ15_Disj AS
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

/* 1891 against 1906. The gap is much smaller than in the overlapping mode,
 * 15 instead of 305, because the disjoint mode keeps at most one match every
 * three positions and most of the matches that the continuous sequence adds
 * fall inside a stretch that already contained an accepted match. Reporting
 * only the disjoint answer would therefore understate the effect of the
 * unobserved districts by a factor of twenty. */

-- Overlapping patterns of A.*A
DROP TABLE IF EXISTS Q15_AnyLen;
CREATE TABLE Q15_AnyLen AS
SELECT s.TripId, g1.StartPos, g2.EndPos,
  s.DistrictSeq[g1.StartPos : g2.EndPos] AS MatchSeq
FROM PointDistrictSeq s
  CROSS JOIN LATERAL generate_series(1, array_length(s.DistrictSeq, 1) - 1) AS g1(StartPos)
  CROSS JOIN LATERAL generate_series(g1.StartPos + 2, array_length(s.DistrictSeq, 1)) AS g2(EndPos)
WHERE s.DistrictSeq[g1.StartPos] = s.DistrictSeq[g2.EndPos]
AND NOT EXISTS (
  SELECT 1
  FROM generate_series(g1.StartPos + 1, g2.EndPos - 1) AS d(MidPos)
  WHERE s.DistrictSeq[d.MidPos] = s.DistrictSeq[g1.StartPos] )
ORDER BY s.TripId, g1.StartPos;

-- SELECT 9903
-- Time: 244.318 ms

-- TEMPORAL VERSION

DROP TABLE IF EXISTS TQ15_AnyLen;
CREATE TABLE TQ15_AnyLen AS
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

/* 9903 against 10201. The relaxed pattern is the one for which the two
 * sequences differ the most in relative terms, and its direction is the
 * opposite of the one observed on the grid for the fixed-length pattern: a
 * district recovered in the middle of a stretch breaks a fixed-length match
 * A B A, since the sequence becomes A B C A, but it can only help a variable
 * length match A .* A. A fixed-length pattern and a variable-length pattern
 * therefore react to the same missing observation in opposite ways, which is
 * a reason to prefer the relaxed form when the sampling rate is not uniform. */

-------------------------------------------------------------------------------
/*
Query 16. Trips that traversed one district with the following development of
spatiotemporal predicates: Disjoint -> Meets -> Inside -> Meets -> Disjoint

This query has no discrete version.

The development requires the instant at which the trip is on the boundary of
the district, that is, the instant at which the predicate Meets holds. That
instant is a property of the movement, not of the observations, and it is not
in the data: over the 7087619 observations of the 27114 trips, the number that
lie on a district boundary is

  SELECT count(*) FROM TripPoints p, Districts d
  WHERE ST_Intersects(d.Boundary, p.Geom);
  -- 0

so a discrete version of the query returns the empty answer. The usual way out
is to replace Meets by a proximity test with a tolerance, which does return an
answer, but an arbitrary one:

  ST_DWithin(d.Boundary, p.Geom, 1)    14397 observations
  ST_DWithin(d.Boundary, p.Geom, 10)  148525 observations
  ST_DWithin(d.Boundary, p.Geom, 50)  640954 observations

The tolerance is not a property of the query, it is a repair of the sampling,
and every answer it produces has to be read together with the value chosen. In
the continuous version the predicate is evaluated on the movement itself:
tIntersects(Trip, Boundary) is a temporal Boolean whose true periods are the
instants of contact with the boundary, and whenTrue returns them exactly.
*/

-- Overlapping patterns
DROP TABLE IF EXISTS TQ16_Over;
CREATE TABLE TQ16_Over AS
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
SELECT m1.TripId, m1.Name, m1.AtTimestamp AS EnterTime, c.AtTime AS InsideTime,
  m2.AtTimestamp AS LeaveTime
FROM Meets m1, ContainedBy c, Meets m2
WHERE m1.TripId = c.TripId AND m1.Name = c.Name AND
  m2.TripId = c.TripId AND m2.Name = c.Name AND
  m1.AtTimestamp = lower(c.AtTime) AND m2.AtTimestamp = upper(c.AtTime)
ORDER BY m1.TripId, m1.Name;

-- SELECT 12551
-- Time: 68901.744 ms (01:08.902)

/* The five predicates of the development are read off two temporal Booleans.
 * The Disjoint at both ends needs no test: the trip is outside the district
 * before it meets its boundary and after it meets it again, since the period
 * during which it is inside is bounded by the two contacts. The pattern is
 * thus the equality of the first Meets with the beginning of the containment
 * and of the second Meets with its end, which is what the two last conditions
 * state. */

/*****************************************************************************/
