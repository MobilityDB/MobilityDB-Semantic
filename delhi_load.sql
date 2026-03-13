-------------------------------------------------------------------------------

DROP FUNCTION IF EXISTS delhi_load;
CREATE FUNCTION delhi_load()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  filePath text = '/home/esteban/src/MobilityDB-Semantic/data/';
  fileName text;
  fileNames text[];
BEGIN
  CREATE EXTENSION IF NOT EXISTS mobilitydb CASCADE;
  CREATE EXTENSION IF NOT EXISTS hstore;

  SET TIMEZONE TO 'Asia/Kolkata';
  SET DATESTYLE TO 'ISO, YMD';

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table DelhiInput';

  DROP TABLE IF EXISTS DelhiInput;
  CREATE TABLE DelhiInput (
    Id int NOT NULL,
    UId text PRIMARY KEY,
    T timestamptz NOT NULL,
    DeviceId text NOT NULL,
    Lat double precision NOT NULL,
    Lon double precision NOT NULL,
    Pm1_0 double precision NOT NULL,
    Pm2_5 double precision NOT NULL,
    Pm10 double precision NOT NULL,
    Geom geometry,
    UNIQUE(DeviceId, T)
  );

  SELECT array_agg(f ORDER BY f) INTO fileNames
  FROM pg_ls_dir(filePath) AS f
  WHERE f ~* '^2020.*\.csv$';   -- case-insensitive regex
  FOREACH fileName IN ARRAY fileNames
  LOOP
    EXECUTE format(
      'COPY DelhiInput(Id, UId, T, DeviceId, Lat, Lon, Pm1_0, Pm2_5, Pm10) '
      'FROM %L WITH DELIMITER '','' CSV HEADER', filePath || fileName);
    RAISE NOTICE 'Inserting %', fileName;
  END LOOP;

  UPDATE DelhiInput
  SET Geom = ST_Transform(ST_Point(Lon, Lat, 4326), 7760);

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating tables WeatherInput and WeatherHourly';


  /* Compute the center point of the extent of the dataset 

  WITH Extent(MinLon, MinLat, MaxLon, MaxLat) AS (
    SELECT MIN(Lon), MIN(Lat), MAX(Lon), MAX(Lat)
    FROM DelhiInput )
  SELECT MinLon + (MaxLon - MinLon) / 2 AS CenterLon,
    MinLat + (MaxLat - MinLat) / 2 AS CenterLat
  FROM Extent;

  -- 77.21044149999999 | 28.603272625000002
  -- Time: 3490.939 ms (00:03.491)

  -- OpenMeteo should be set to automatically detect the timezone from the data,
  -- which in this case it would be Indian Standard Time or IST . Therefore, 
  -- we need to set the timezone to Asia/Koklata in PostgreSQL BEFORE loading
  -- the CSV file. We suppose that the CSV file is called delhi_weather.csv

  https://open-meteo.com/en/docs/historical-weather-api?start_date=2020-11-01&end_date=2020-12-31&latitude=28.603272&longitude=77.210441&hourly=temperature_2m,relative_humidity_2m,cloud_cover,rain,wind_speed_10m

  */

  DROP TABLE IF EXISTS WeatherInput;
  CREATE TABLE WeatherInput(T timestamptz PRIMARY KEY, Temperature float,
    Humidity float, CloudCover float, Rain float, Wind float);
  COPY WeatherInput (T, Temperature, Humidity, CloudCover, Rain, Wind)
  FROM '/home/esteban/data/delhi/delhi_weather.csv' DELIMITER ',' CSV HEADER;

  -- COPY 1464
  -- Time: 14.176 ms

  DROP TABLE IF EXISTS WeatherHourly;
  CREATE TABLE WeatherHourly(T timestamptz PRIMARY KEY,
    TimeSpan tstzspan UNIQUE, Weather jsonb);
  INSERT INTO WeatherHourly(T, TimeSpan, Weather)
  SELECT T, span(T, T + interval '1 hour'), jsonb_build_object(
    'Temperature', Temperature,  'Humidity', Humidity, 'CloudCover', CloudCover,
    'Rain', Rain, 'Wind', Wind)
  FROM WeatherInput;

  -- 1464 rows
  -- Time: 36.679 ms

  CREATE INDEX WeatherHourly_QuadTree_Idx ON WeatherHourly USING SPGIST(TimeSpan);

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table TripPoints';

  DROP TABLE IF EXISTS TripPoints;
  CREATE TABLE TripPoints(TripId integer, T timestamptz, Pm25 float,
    Geom geometry, Weather jsonb, PRIMARY KEY(TripId, T));
  INSERT INTO TripPoints
  WITH TripStart(DeviceId, T, Pm25, Geom, NewTrip) AS (
    SELECT DeviceId, T, Pm2_5, Geom,
      CASE 
        WHEN LAG(T) OVER w IS NULL OR T - LAG(T) OVER w > '5 minutes' OR
          ST_Distance(Geom, LAG(Geom) OVER w) > 1000 THEN 1
      END
    FROM DelhiInput
    WINDOW w AS (PARTITION BY DeviceId ORDER BY T) ),
  TripGroup(TripId, T, Pm25, Geom) AS (
    SELECT COUNT(NewTrip) OVER (ORDER BY DeviceId, T), T, Pm25, Geom
    FROM TripStart )
  SELECT g.TripId, g.T, g.Pm25, g.Geom, w.Weather
  FROM TripGroup g, WeatherHourly w
  WHERE date_trunc('hour', g.T) = w.T
  ORDER BY TripId;

  -- INSERT 0 7087619
  -- Time: 109295.943 ms (01:49.296)

  CREATE INDEX TripPoints_Geom_Idx ON TripPoints USING SPGIST(Geom);

  -- Time: 57454.488 ms (00:57.454)

------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table Trips';

  DROP TABLE IF EXISTS Trips;
  CREATE TABLE Trips(TripId integer PRIMARY KEY, Trip tgeompoint,
    Trajectory geometry, Pm25 tfloat, Weather tjsonb);
  INSERT INTO Trips
  WITH Trips(TripId, Trip, Pm25, Weather) AS (
    SELECT TripId, 
      tgeompointSeq(array_agg(tgeompoint(Geom, T) ORDER BY T)),
      tfloatSeq(array_agg(tfloat(Pm25, T) ORDER BY T)),
      tjsonbSeq(array_agg(tjsonb(Weather, T) ORDER BY T))
    FROM TripPoints
    GROUP BY TripId )
  SELECT TripId, Trip, trajectory(Trip), Pm25, Weather
  FROM Trips
  ORDER BY TripId;

  --  27118 rows
  -- Time: 53780.456 ms (00:53.780)

  CREATE INDEX Trips_Trip_Quadtree_Idx ON Trips USING SPGIST(Trip);

------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table Grid';

  DROP TABLE IF EXISTS Grid;
  CREATE TABLE Grid(CellId integer PRIMARY KEY, Box stbox, Geom geometry,
   Boundary geometry);
  INSERT INTO Grid(CellId, Box, Geom, Boundary)
  WITH MBR(Box) AS ( SELECT extent(Geom::stbox) FROM DelhiInput )
  SELECT (rec).Index, (rec).Tile, (rec).Tile::geometry, 
    ST_Boundary((rec).Tile::geometry)
  FROM ( SELECT spaceTiles(Box, 2500) AS rec FROM MBR );

  -- 120 rows
  -- Time: 2958.447 ms (00:02.958)

  CREATE INDEX Grid_Box_Quadtree_Idx ON Grid USING SPGIST(Box);
  CREATE INDEX Grid_Geom_Quadtree_Idx ON Grid USING SPGIST(Geom);

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table TripCells';

  DROP TABLE IF EXISTS TripCells;
  CREATE TABLE TripCells(TripId integer, StepNo integer, StartTime timestamptz,
    EndTime timestamptz, CellId integer, Pm25 float, Weather jsonb,
    PRIMARY KEY (TripId, CellId, StartTime));
  INSERT INTO TripCells
  WITH PointCells(TripId, T, Pm25, Geom, Weather, CellId, PrevCell) AS (
    SELECT p.TripId, p.T, p.Pm25, p.Geom, p.Weather, g.CellId, 
      LAG(CellId) OVER (PARTITION BY TripId ORDER BY T )
    FROM TripPoints p, Grid g
    WHERE g.Box @> stbox(p.Geom) ),
  StepStarts(TripId, T, Pm25, Geom, Weather, CellId, PrevCell, NewStep) AS (
    SELECT *, 
      CASE WHEN PrevCell IS NULL OR CellId <> PrevCell THEN 1 ELSE 0 END
    FROM PointCells ),
  TripSteps(TripId, StepNo, T, Pm25, Geom, Weather, CellId, PrevCell) AS (
    SELECT TripId, SUM(NewStep) OVER (PARTITION BY TripId ORDER BY T
      ROWS UNBOUNDED PRECEDING), T, Pm25, Geom, Weather, CellId, PrevCell
    FROM StepStarts )
  SELECT TripId, StepNo, MIN(T), MAX(T), MIN(CellId), /* CellId is unique in a group */
    AVG(Pm25), jsonb_build_object(
      'Temperature', AVG((Weather->>'Temperature')::float),
      'Humidity', AVG((Weather->>'Humidity')::float),
      'CloudCover', AVG((Weather->>'CloudCover')::float),
      'Rain', AVG((Weather->>'Rain')::float),
      'Wind', AVG((Weather->>'Wind')::float)) AS Weather
  FROM TripSteps
  GROUP BY TripId, StepNo
  ORDER BY TripId, StepNo;

  -- INSERT 0 70881
  -- Time: 112401.549 ms (01:52.402)

  DROP TABLE IF EXISTS TripCellsSeq;
  CREATE TABLE TripCellsSeq(TripId integer PRIMARY KEY, CellSeq int[]);
  INSERT INTO TripCellsSeq
  SELECT TripId, array_agg(CellId ORDER BY EndTime)
  FROM TripCells
  GROUP BY TripId
  ORDER BY TripId;

  -- INSERT 0 27118
  -- Time: 483.961 ms

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table TripTiles';

  -- TEMPORAL VERSION

  DROP TABLE IF EXISTS TripTiles;
  CREATE TABLE TripTiles(TripId integer, StepNo integer, AtTime tstzspanset,
    CellId integer, Trip tgeompoint, Trajectory geometry, Pm25 tfloat,
    Weather tjsonb, PRIMARY KEY (TripId, StepNo) );
  INSERT INTO TripTiles
  WITH TripCells(TripId, CellId, Trip, Pm25, Weather) AS (
    SELECT TripId, CellId, atStbox(t.Trip, g.Box, false), Pm25, Weather
    FROM Trips t, Grid g
    WHERE eIntersects(t.Trip, g.Geom) )
  SELECT TripId, ROW_NUMBER() OVER (PARTITION BY TripId ORDER BY getTime(Trip)),
    getTime(Trip), CellId, Trip, trajectory(Trip), atTime(Pm25, getTime(Trip)),
    atTime(Weather, getTime(Trip))
  FROM TripCells
  ORDER BY TripId, getTime(Trip);

  -- INSERT 0 50781
  -- Time: 208452.017 ms (03:28.452)

  DROP TABLE IF EXISTS TripTilesSeq;
  CREATE TABLE TripTilesSeq(TripId integer PRIMARY KEY, Cells tint, CellSeq int[]);
  INSERT INTO TripTilesSeq
  WITH Spans(TripId, CellId, Span) AS (
    SELECT TripId, CellId, unnest(spans(AtTime))
    FROM TripTiles )
  SELECT TripId, merge(array_agg(tint(CellId, Span) ORDER BY Span)),
    array_agg(CellId ORDER BY Span)
  FROM Spans
  GROUP BY TripId
  ORDER BY TripId;

  -- INSERT 0 27118
  -- Time: 1033.352 ms (00:01.033)

/*

select TripId, Cells from TripTempCell WHERE numInstants(Cells) > 2 order by numInstants(Cells) limit 10;
 tripid |                                              cells
--------+-------------------------------------------------------------------------------------------------
    228 | [47@2020-11-12 01:03:30+01, 46@2020-11-12 01:06:14.297877+01, 45@2020-11-12 01:10:17.344984+01]
    207 | [38@2020-11-11 16:05:26+01, 48@2020-11-11 16:11:42.843841+01, 47@2020-11-11 16:14:37.918549+01]
    214 | [86@2020-11-11 16:56:37+01, 87@2020-11-11 17:09:33.380065+01, 97@2020-11-11 17:09:37.199314+01]
    223 | [47@2020-11-11 23:34:36+01, 46@2020-11-11 23:35:32.324437+01, 56@2020-11-12 00:12:18.621897+01]
     10 | [48@2020-11-04 13:57:05+01, 47@2020-11-04 13:57:05.068142+01, 46@2020-11-04 14:02:27.056248+01]
     12 | [35@2020-11-04 14:21:20+01, 34@2020-11-04 14:23:14.061347+01, 44@2020-11-04 14:25:36.772452+01]
      7 | [46@2020-11-03 23:46:27+01, 47@2020-11-04 05:07:57.931644+01, 57@2020-11-04 05:43:49.520672+01]
    240 | [45@2020-11-12 06:29:10+01, 46@2020-11-12 06:35:59.332971+01, 47@2020-11-12 06:43:52.2121+01]
    200 | [63@2020-11-11 13:14:30+01, 64@2020-11-11 13:14:41.904839+01, 54@2020-11-11 13:15:30.718188+01]
    252 | [38@2020-11-12 13:05:41+01, 48@2020-11-12 13:10:36.704281+01, 47@2020-11-12 13:13:32.237116+01]
(10 rows)

select TripId, numInstants(Cells) from TripTempCell order by numInstants(Cells) DESC limit 10;
 tripid | numinstants
--------+-------------
      4 |          21
    879 |          20
    816 |          18
    805 |          18
    355 |          18
    813 |          18
    347 |          18
    788 |          18
    790 |          18
    810 |          18
(10 rows)
*/

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating the table Districts';

  DROP TABLE IF EXISTS Districts;
  CREATE TABLE Districts(OsmId bigint PRIMARY KEY, Name text, AdminLevel text, 
    Geom geometry, Boundary geometry);
  INSERT INTO Districts(OsmId, Name, AdminLevel, Geom, Boundary)
  WITH DistrictsInput(OsmId, Name, AdminLevel, Geom) AS (
    SELECT osm_id, name, admin_level, ST_Transform(way, 7760)
    FROM planet_osm_polygon
    WHERE boundary = 'administrative' AND admin_level = '5' AND name IS NOT NULL ),
  DistrictsAgg(OsmId, Name, AdminLevel, Geom) AS (
    SELECT OsmId, name, AdminLevel, ST_Collect(Geom)
    FROM DistrictsInput
    GROUP BY OsmId, Name, AdminLevel )
  SELECT OsmId, Name, AdminLevel, Geom, ST_Boundary(Geom)
  FROM DistrictsAgg
  ORDER BY OsmId;

  -- INSERT 0 11
  -- Time: 87.969 ms

  CREATE INDEX Districts_Geom_Quadtree_Idx ON Districts USING SPGIST(Geom);

  /*
  delhi=# SELECT OsmId, Name, AdminLevel FROM Districts ORDER BY Name;
    osmid   |       name       | adminlevel
  ----------+------------------+------------
   -1942443 | Central Delhi    | 5
   -1942588 | East Delhi       | 5
   -2763541 | New Delhi        | 5
   -1942605 | North Delhi      | 5
   -1942602 | North East Delhi | 5
   -1942609 | North West Delhi | 5
   -3560206 | Shahdara         | 5
   -1942663 | South Delhi      | 5
   -3588253 | South East Delhi | 5
   -1942625 | South West Delhi | 5
   -1942620 | West Delhi       | 5
  (11 rows)
  */

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating tables PointDistricts and PointDistrictSeq';

  DROP TABLE IF EXISTS PointDistricts;
  CREATE TABLE PointDistricts(TripId integer, StepNo integer, StartTime timestamptz,
    EndTime timestamptz, Name text, Pm25 float, Weather jsonb,
    PRIMARY KEY (TripId, Name, StartTime));
  INSERT INTO PointDistricts
  WITH PointDistrictsRaw(TripId, T, Pm25, Geom, Weather, Name, PrevDistr) AS (
    SELECT p.TripId, p.T, p.Pm25, p.Geom, p.Weather, d.Name, 
      LAG(Name) OVER (PARTITION BY TripId ORDER BY T )
    FROM TripPoints p, Districts d
    WHERE ST_Contains(d.Geom, p.Geom) ),
  StepStarts(TripId, T, Pm25, Geom, Weather, Name, PrevDistr, NewStep) AS (
    SELECT *, 
      CASE WHEN PrevDistr IS NULL OR Name <> PrevDistr THEN 1 ELSE 0 END
    FROM PointDistrictsRaw ),
  TripSteps(TripId, StepNo, T, Pm25, Geom, Weather, Name, PrevDistr) AS (
    SELECT TripId, SUM(NewStep) OVER (PARTITION BY TripId ORDER BY T
      ROWS UNBOUNDED PRECEDING), T, Pm25, Geom, Weather, Name, PrevDistr
    FROM StepStarts )
  SELECT TripId, StepNo, MIN(T), MAX(T), MIN(Name), /* Name is unique in a group */
    AVG(Pm25), jsonb_build_object(
      'Temperature', AVG((Weather->>'Temperature')::float),
      'Humidity', AVG((Weather->>'Humidity')::float),
      'CloudCover', AVG((Weather->>'CloudCover')::float),
      'Rain', AVG((Weather->>'Rain')::float),
      'Wind', AVG((Weather->>'Wind')::float)) AS Weather
  FROM TripSteps
  GROUP BY TripId, StepNo
  ORDER BY TripId, StepNo;

  -- INSERT 0 41644
  -- Time: 70620.539 ms (01:10.621)

  DROP TABLE IF EXISTS PointDistrictSeq;
  CREATE TABLE PointDistrictSeq(TripId integer PRIMARY KEY, DistrictSeq text[]);
  INSERT INTO PointDistrictSeq
  SELECT TripId, array_agg(Name ORDER BY EndTime)
  FROM PointDistricts
  GROUP BY TripId
  ORDER BY TripId;

  -- INSERT 0 27114
  -- Time: 184.656 ms

  /*

  delhi=# select distinct array_length(DistrictSeq, 1) from tripdistrictsseq order by 1 desc limit 10;
   array_length
  --------------
             79
             75
             72
             71
             69
             65
             63
             59
             51
             47
  (10 rows)

  */

-------------------------------------------------------------------------------

  RAISE NOTICE 'Creating tables TripDistricts and TripDistrictsSeq';

  -- TEMPORAL VERSION

  DROP TABLE IF EXISTS TripDistricts;
  CREATE TABLE TripDistricts(TripId integer, StepNo integer, AtTime tstzspanset,
    Name text, Trip tgeompoint, Trajectory geometry, Pm25 tfloat,
    Weather tjsonb, PRIMARY KEY (TripId, StepNo) );
  INSERT INTO TripDistricts
  WITH TripDistricts(TripId, Name, Trip, Pm25, Weather) AS (
    SELECT TripId, Name, atGeometry(t.Trip, d.Geom), Pm25, Weather
    FROM Trips t, Districts d
    WHERE eIntersects(t.Trip, d.Geom) )
  SELECT TripId, ROW_NUMBER() OVER (PARTITION BY TripId ORDER BY getTime(Trip)),
    getTime(Trip), Name, Trip, trajectory(Trip), atTime(Pm25, getTime(Trip)),
    atTime(Weather, getTime(Trip))
  FROM TripDistricts
  ORDER BY TripId, getTime(Trip);

  -- INSERT 0 31756
  -- Time: 119488.270 ms (01:59.488)

  /* 
    The following query is more elaborated than the corresponding TripTilesSeq
    since there atGeometry does not have a parameter borderInc as in atStbox and
    thus we need to convert the closed spans by opening to the right and adding
    the last instant
  */

  DROP TABLE IF EXISTS TripDistrictsSeq;
  CREATE TABLE TripDistrictsSeq(TripId integer PRIMARY KEY, Districts ttext, DistrictSeq text[]);
  INSERT INTO TripDistrictsSeq
  WITH Spans(TripId, Name, Span) AS (
    SELECT TripId, Name, unnest(spans(AtTime))
    FROM TripDistricts ),
  DistrNames(TripId, NameSeq) AS (
    SELECT TripId, array_agg(Name ORDER BY Seq)
    FROM (
      SELECT TripId, Name, ROW_NUMBER() OVER w AS Seq, LAG(Name) OVER w AS PrevVal
      FROM Spans
      WINDOW w AS (PARTITION BY TripId ORDER BY Span) ) d
    WHERE Name IS DISTINCT FROM PrevVal
    GROUP BY TripId ),
  DistrPeriods(TripId, Name) AS (
    SELECT TripId, ttext(Name, span(lower(Span), upper(Span), true, 
      CASE WHEN lower(Span) = upper(Span) THEN true ELSE false END))
    FROM Spans ),
  EndDistrict(TripId, Inst) AS (
    SELECT DISTINCT ON (TripId) TripId, ttext(Name, upper(Span))
    FROM Spans
    ORDER BY TripId, Span DESC ),
  TripDistricts(TripId, Name) AS (
    SELECT d.TripId, merge(array_agg(Name ORDER BY Name)) Name
    FROM DistrPeriods d
    GROUP BY TripId )
  SELECT d.TripId, merge(Name, Inst), NameSeq
  FROM TripDistricts d, EndDistrict e, DistrNames n
  WHERE d.TripId = e.TripId AND d.TripId = n.TripId
  ORDER BY TripId, Name;

  -- INSERT 0 27114
  -- Time: 631.475 ms

  /*

  delhi=# select TripId, Districts from TripDistrictsSeq WHERE numInstants(Districts) > 2 order by numInstants(Districts) limit 3;
   tripid |                                                           districts                                           
  --------+------------------------------------------------------------------------------------------------------------------------------------------------     12 | [South Delhi@2020-11-04 18:51:20+05:30, New Delhi@2020-11-04 18:51:36.189174+05:30, New Delhi@2020-11-04 19:05:45+05:30]
       35 | [West Delhi@2020-11-05 07:15:56+05:30, New Delhi@2020-11-05 07:16:47.318143+05:30, New Delhi@2020-11-05 07:16:48+05:30]
       65 | [South East Delhi@2020-11-06 05:42:16+05:30, New Delhi@2020-11-06 05:42:21.771428+05:30, New Delhi@2020-11-06 05:44:21+05:30]
  (3 rows)

  delhi=# select TripId, numInstants(Districts) from TripDistrictsSeq order by numInstants(Districts) DESC limit 10;
   tripid | numinstants
   tripid | numinstants
  --------+-------------
     3876 |          80
     3871 |          76
     2769 |          75
     3874 |          74
     3849 |          70
     3869 |          70
     6711 |          66
    25447 |          66
     2768 |          62
     3860 |          52
  (10 rows)
  */

------------------------------------------------------------------------------------------------

END $$;

------------------------------------------------------------------------------------------------
