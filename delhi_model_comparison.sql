-------------------------------------------------------------------------------
-- Reaching the aggregated table from the temporal one
--
-- TripCells holds, for each visit of a trip to a cell, the mean of the values
-- observed inside it. The mean is formed when the table is built and stored as
-- a number, so the table answers the question it was built for.
--
-- TripTiles holds the trip restricted to the cell, keeping the values as
-- temporal types. A query forms the mean when it asks for it, so the same
-- question is answered without the table that holds its answer.
--
-- What follows measures how near the two means are, what forming the mean at
-- the time of the query costs, and what the stored mean can no longer answer.
--
-- Delhi data set: 27118 trips, 7087728 points, 120 cells of 2500 m.
-- TripCells 70881 rows, TripTiles 50781 rows, mean Pm25 205.07, deviation 111.16.
-------------------------------------------------------------------------------

-- Q1. The mean formed at the time of the query against the stored mean

WITH stored AS (
  SELECT TripId, CellId, avg(Pm25) AS pm FROM TripCells GROUP BY TripId, CellId ),
formed AS (
  SELECT TripId, CellId, twAvg(Pm25) AS pm FROM TripTiles GROUP BY TripId, CellId, Pm25 )
SELECT count(*) AS pairs,
  round(avg(abs(stored.pm - formed.pm))::numeric, 4) AS mean_abs_diff,
  round((avg(abs(stored.pm - formed.pm)) / avg(stored.pm) * 100)::numeric, 3) AS pct_of_mean,
  round(max(abs(stored.pm - formed.pm))::numeric, 3) AS max_diff,
  round(corr(stored.pm, formed.pm)::numeric, 6) AS correlation
FROM stored JOIN formed USING (TripId, CellId);

-- 50688  2.3464  1.119  272.468  0.997519

-- The two means agree to 1.119 per cent of the measured quantity, and follow
-- each other with a correlation of 0.997519.
--
-- They are not the same mean. avg counts every observed point once, while
-- twAvg weights each value by the time it holds, so the two agree where the
-- points are evenly spread over the visit and part where they are not. The
-- weighted mean is the one that answers how much a trip was exposed.

-------------------------------------------------------------------------------

-- Q2. What forming the mean at the time of the query costs

SELECT CellId, avg(Pm25) FROM TripCells GROUP BY CellId;

-- Time: 37.839 ms, 30.556 ms, 27.748 ms

SELECT CellId, avg(twAvg(Pm25)) FROM TripTiles GROUP BY CellId;

-- Time: 877.442 ms, 727.294 ms, 685.296 ms

-- Reading a stored number is faster than forming it: 30.6 ms against 727 ms.
-- The stored number is reached in one pass over 70881 rows, where the temporal
-- mean walks the values of 50781 temporal types.
--
-- Against that, building TripCells reads the 7087728 points and takes 112401 ms
-- once, and holds one mean per visit from then on. Forming the mean when the
-- query asks costs 727 ms and holds nothing.

-------------------------------------------------------------------------------

-- Q3. What the stored mean no longer answers
--
-- TripCells keeps Pm25 as one double precision per visit, so a query reaches
-- the mean of the visit and nothing else of what was measured during it.

SELECT CellId, round(max(maxValue(Pm25))::numeric, 1) AS peak_pm25
FROM TripTiles GROUP BY CellId ORDER BY peak_pm25 DESC LIMIT 3;

--  47  1672.0
--  19  1534.0
--  56  1337.0
-- Time: 533.996 ms

-- The largest value observed anywhere is 1672.0, and the temporal model reaches
-- it in the cell where it was measured. The stored mean cannot: a peak inside a
-- visit is spread over the visit when the mean is formed, and no query over
-- TripCells recovers it.
--
-- The same holds of any question the stored table was not built for — the time
-- spent above a threshold, the value on entering the cell, the
-- deviation over the visit. The temporal model answers each of them from the
-- rows it already has.

-------------------------------------------------------------------------------

-- Q4. Where the two segmentations part
--
-- A visit of TripCells begins at the first observed point inside the cell and
-- ends at the last. A visit of TripTiles begins and ends at the crossing of the
-- boundary, which the interpolation between two observations gives.
--
-- The span sets of TripTiles are unnested below, so that a visit is compared
-- with a visit rather than with the whole of a trip in a cell.

SELECT count(*) AS only_temporal
FROM (SELECT TripId, CellId FROM TripTiles
      EXCEPT SELECT TripId, CellId FROM TripCells) a;

-- 93

SELECT count(*) AS only_aggregated
FROM (SELECT TripId, CellId FROM TripCells
      EXCEPT SELECT TripId, CellId FROM TripTiles) b;

-- 0

-- 93 pairs of a trip and a cell hold no observed point: the trip crosses the
-- cell between two observations. The cells of the aggregated model are a subset
-- of those of the temporal one.

SELECT 'aggregated' AS model, sum(EndTime - StartTime) AS total, count(*) AS visits
FROM TripCells
UNION ALL
SELECT 'temporal', sum(upper(sp) - lower(sp)), count(*)
FROM (SELECT unnest(spans(AtTime)) AS sp FROM TripTiles) s;

-- aggregated  5906:55:06  70881
-- temporal    6008:52:33  71278

WITH a AS (
  SELECT TripId, CellId, sum(EndTime - StartTime) AS dur
  FROM TripCells GROUP BY TripId, CellId ),
t AS (
  SELECT TripId, CellId, sum(upper(sp) - lower(sp)) AS dur
  FROM (SELECT TripId, CellId, unnest(spans(AtTime)) AS sp FROM TripTiles) x
  GROUP BY TripId, CellId )
SELECT count(*) FILTER (WHERE a.dur < t.dur) AS aggregated_shorter,
  count(*) FILTER (WHERE a.dur = t.dur) AS equal,
  count(*) FILTER (WHERE a.dur > t.dur) AS aggregated_longer
FROM a JOIN t USING (TripId, CellId);

-- 28962  21726  0

-- A visit bounded by observed points is contained in the visit bounded by the
-- crossings, so the difference has one direction: shorter for 28962 pairs,
-- equal for 21726, longer for none, leaving 101:57:27 of the 6008:52:33 outside
-- the aggregated model.

-------------------------------------------------------------------------------
