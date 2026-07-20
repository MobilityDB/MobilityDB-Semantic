/*****************************************************************************
 * QUERIES
 *****************************************************************************/

/*
Tours that go to the Hilton, then optionally go to a restaurant, and then go to the movies

Tour[before([Category = 'Hotel' AND Name = 'Hilton Paris Opera'],
  [Category = 'Restaurant']*, [Category = 'Entertainment' AND Type = 'Movie'])]
*/

WITH Hilton AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Hotel' AND PoI->>'Name' = 'Hilton Paris Opera' ),
Restaurant AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Restaurant' ),
Movie AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Entertainment' AND PoI->>'Type' = 'Movie' )
SELECT DISTINCT h.TourId, h.StepNo AS HiltonStep, h.PoI->>'Name' AS HiltonName,
  r.StepNo AS RestStep, r.PoI->>'Name' AS RestName,
  m.StepNo AS MovieStep, m.PoI->>'Name' AS MovieName
FROM Hilton h
JOIN Movie m ON m.TourId = h.TourId AND h.AtTime < m.AtTime
LEFT JOIN Restaurant r ON r.TourId = h.TourId AND h.AtTime < r.AtTime AND
  r.AtTime < m.AtTime
ORDER BY h.TourId, h.StepNo;

/* 
 tourid | hiltonstep |     hiltonname     | reststep |    restname     | moviestep |  moviename
--------+------------+--------------------+----------+-----------------+-----------+--------------
      2 |          1 | Hilton Paris Opera |        3 | Indy Restaurant |         4 | Pathee Opera
      3 |          1 | Hilton Paris Opera |          |                 |         2 | Pathee Opera
*/

-- TEMPORAL VERSION

WITH Hilton(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(
    getTime(atValue(Tour->>'Category', text 'Hotel')) *
    getTime(atValue(Tour->>'Name', text 'Hilton Paris Opera')))))
  FROM TempTour ),
Restaurant(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(
    getTime(atValue(Tour->>'Category', text 'Restaurant')))))
  FROM TempTour ),
Movie(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(
    getTime(atValue(Tour->>'Category', text 'Entertainment')) *
    getTime(atValue(Tour->>'Type', text 'Movie')))))
  FROM TempTour )
SELECT DISTINCT h.TourId, startValue(h.Tour->>'StepNo')::integer AS HiltonStep,
  startValue(h.Tour->>'Name') AS HiltonName,
  startValue(r.Tour->>'StepNo')::integer AS RestStep, 
  startValue(r.Tour->>'Name') AS RestName,
  startValue(m.Tour->>'StepNo')::integer AS MovieStep,
  startValue(m.Tour->>'Name') AS MovieName
FROM Hilton h
JOIN Movie m ON h.TourId = m.TourId AND h.Tour < m.Tour
LEFT JOIN Restaurant r ON r.TourId = h.TourId AND h.Tour < r.Tour AND
  r.Tour < m.Tour
ORDER BY TourId, HiltonStep;

/*
 tourid | hiltonstep |     hiltonname     | reststep |    restname     | stepno |  moviename
--------+------------+--------------------+----------+-----------------+--------+--------------
      2 |          1 | Hilton Paris Opera |        3 | Indy Restaurant |         4 | Pathee Opera
      3 |          1 | Hilton Paris Opera |          |                 |         2 | Pathee Opera
*/

/*****************************************************************************/

/*
 Tours that visit a museum and then a restaurant.

Tour[before([Category = 'Museum'],[Category = 'Restaurant'])]
*/


WITH Museum AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Museum'),
Restaurant AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Restaurant')
SELECT DISTINCT m.TourId, m.StepNo AS MuseumStep, m.PoI->>'Name' AS MuseumName,
  r.StepNo AS RestStep, r.PoI->>'Name' AS RestName
FROM Museum m, Restaurant r
WHERE m.TourId = r.TourId AND m.StepNo < r.StepNo
ORDER BY TourId, MuseumStep;
 

-- TEMPORAL VERSION

WITH Museum(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(
    getTime(atValue(Tour->>'Category', text 'Museum')))))
  FROM TempTour ),
Restaurant(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(
    getTime(atValue(Tour->>'Category', text 'Restaurant')))))
  FROM TempTour )
SELECT DISTINCT m.TourId, startValue(m.Tour->>'StepNo')::integer AS MuseumStep,
  startValue(m.Tour->>'Name') AS MuseumName,
  startValue(r.Tour->>'StepNo')::integer AS RestStep, 
  startValue(r.Tour->>'Name') AS RestName
FROM Museum m, Restaurant r 
WHERE m.TourId = r.TourId AND m.Tour < r.Tour
ORDER BY TourId, MuseumStep;

/*****************************************************************************/

/*
Tours where the first step is a French restaurant, and the next step is any museum

Tour[before(^[Category = 'Restaurant' AND TypeOfFood = 'French'],
  [Category = 'Hotel' AND StepNo = 2])]
*/

SELECT f.TourId, f.StepNo AS FirstStep, f.PoI->>'Name' AS FirstName,
  s.StepNo AS SecondStep, s.PoI->>'Name' AS SecondName 
FROM TourPoI f, TourPoI s
WHERE f.TourId = s.TourId AND f.StepNo = 1 AND s.StepNo = 2 AND
  f.PoI @? '$ ? ( @."Category" == "Restaurant" &&
    @."TypeOfFood" == "French" )' AND
  s.PoI @? '$ ? ( @."Category" == "Museum" )'
ORDER BY f.TourId;

/*
 tourid | firststep | firstname  | secondstep |  secondname
--------+-----------+------------+------------+---------------
      1 |         1 | Le Meurice |          2 | Musee d'Orsay
*/

-- TEMPORAL VERSION

WITH FrenchRestaurant(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(Tour @? 
    '$ ? (@."StepNo" == 1 && @."Category" == "Restaurant" && 
      @."TypeOfFood" == "French" )')))) AS Tour
  FROM TempTour 
  WHERE Tour IS NOT NULL ),
Museum(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(Tour @? 
    '$ ? ( @."StepNo" == 2 && @."Category" == "Museum" )'))))
  FROM TempTour )
SELECT f.TourId, startValue(f.Tour->>'StepNo')::integer AS FirstStep, 
  startValue(f.Tour->>'Name') AS FirstName,
  startValue(s.Tour->>'StepNo')::integer AS SecondStep,
  startValue(s.Tour->>'Name') AS SecondName
FROM FrenchRestaurant f, Museum s
WHERE f.TourId = s.TourId AND f.Tour < s.Tour
ORDER BY TourId, FirstStep;

/*
 tourid | firststep | firstname  | secondstep |  secondname
--------+-----------+------------+------------+---------------
      1 |         1 | Le Meurice |          2 | Musee d'Orsay
*/

/*****************************************************************************/

/*
Tours that go to the Hilton, then optionally go to various places, and finish at any hotel

Tour[before([Category = 'Hotel' AND Name = 'Hilton Paris Opera'], [Category = 'Hotel']$)]
*/

WITH Hilton AS (
  SELECT *
  FROM TourPoI 
  WHERE PoI->>'Name' = 'Hilton Paris Opera' AND PoI->>'Category' = 'Hotel' ),
AnyHotel AS (
  SELECT *
  FROM TourPoI t1
  WHERE PoI->>'Category' = 'Hotel' AND StepNo = 
    ( SELECT MAX(StepNo) FROM TourPoI t2 WHERE t1.TourId = t2.TourId ) )
SELECT h.TourId, h.StepNo AS StartStep, h.PoI->>'Name' AS StartName,
  a.StepNo AS EndStep, a.PoI->>'Name' AS EndName 
FROM Hilton h, AnyHotel a
WHERE h.TourId = a.TourId AND h.AtTime < a.AtTime 
ORDER BY h.TourId;

/*
 tourid | startstep |     startname      | endstep |      endname
--------+-----------+--------------------+---------+--------------------
      2 |         1 | Hilton Paris Opera |       5 | Hilton Paris Opera
      6 |         1 | Hilton Paris Opera |       5 | Hilton Paris Opera
*/

-- TEMPORAL VERSION

WITH Hilton(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(
    Tour @? '$ ? (@."Category" == "Hotel" && 
      @."Name" == "Hilton Paris Opera" )'))))
  FROM TempTour ),
LastStep(TourId, StepNo) AS (
  SELECT TourId, endValue(Tour->>'StepNo')
  FROM TempTour ),
AnyHotel(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(
    Tour @? '$ ? (@."Category" == "Hotel" )'))))
  FROM TempTour ),
LastHotel(TourId, Tour) AS (
  SELECT a.TourId, Tour
  FROM AnyHotel a, LastStep l 
  WHERE a.TourId = l.TourId AND 
    endValue(a.Tour->>'StepNo') = l.StepNo )
SELECT h.TourId, startValue(h.Tour->>'StepNo')::integer AS StartStep, 
  startValue(h.Tour->>'Name') AS StartName, 
  startValue(l.Tour->>'StepNo')::integer AS EndStep, 
  startValue(l.Tour->>'Name') AS EndName
FROM Hilton h, LastHotel l
WHERE h.TourId = l.TourId AND h.Tour < l.Tour
ORDER BY h.TourId;

/*
 tourid | startstep |     startname      | endstep |      endname
--------+-----------+--------------------+---------+--------------------
      2 |         1 | Hilton Paris Opera |       5 | Hilton Paris Opera
      6 |         1 | Hilton Paris Opera |       5 | Hilton Paris Opera
*/

/*****************************************************************************/
/* COMENTED OUT
/*****************************************************************************/

/*
Tours that go to a French restaurant, then optionally go wherever, and then go back to a hotel

Tour[before([Category = 'Restaurant' AND TypeOfFood = 'French'], [Category = 'Hotel'])]
*/

WITH FrenchRestaurant AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Restaurant' AND PoI->>'TypeOfFood' = 'French' ),
Hotel AS (
  SELECT *
  FROM TourPoI
  WHERE PoI->>'Category' = 'Hotel' )
SELECT DISTINCT f.TourId,
  f.StepNo AS FrenchRestStep, f.PoI->>'Name' AS FrenchRestName,
  h.StepNo AS HotelStep, h.PoI->>'Name' AS HotelName 
FROM FrenchRestaurant f, Hotel h
WHERE h.TourId = f.TourId AND f.AtTime < h.AtTime 
ORDER BY f.TourId;

/*
 tourid | frenchreststep | frenchrestname | hotelstep |     hotelname
--------+----------------+----------------+-----------+--------------------
      1 |              1 | Le Meurice     |         5 | Hilton Paris Opera
      6 |              3 | Le Meurice     |         5 | Hilton Paris Opera
*/

-- TEMPORAL VERSION

WITH FrenchRestaurant(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(
    Tour @? '$ ? ( @."Category" == "Restaurant" &&
      @."TypeOfFood" == "French" )'))))
  FROM TempTour ),
Hotel(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(
    Tour @? '$ ? ( @."Category" == "Hotel" )'))))
  FROM TempTour )
SELECT f.TourId, startValue(f.Tour->>'StepNo')::integer AS FrenchRestStep, 
  startValue(f.Tour->>'Name') AS FirstName, 
  startValue(h.Tour->>'StepNo')::integer AS HotelStep,
  startValue(h.Tour->>'Name') AS HotelName
FROM FrenchRestaurant f, Hotel h
WHERE f.TourId = h.TourId AND f.Tour < h.Tour
ORDER BY TourId, FrenchRestStep;

/*
 tourid | frenchreststep | firstname  | hotelstep |     hotelname
--------+----------------+------------+-----------+--------------------
      1 |              1 | Le Meurice |         5 | Hilton Paris Opera
      6 |              3 | Le Meurice |         5 | Hilton Paris Opera
*/

/*****************************************************************************/

/*
Tours that start at a place that is characterized by an attribute \textsf{price}, then go to either the Eiffel tower or a restaurant, and finish at a place that serves French food and has the same price classification as the initial place.

Tour[before(^[Price = @x],
  ( [Category = 'Restaurant'] OR [Category = 'Landmark' AND Name = 'Eiffel Tower'] ),
  [Category = 'Restaurant' AND TypeOfFood = 'French' AND Price = @x]$)]
*/

WITH StartPlace AS (
  SELECT *, PoI->>'Price' AS StartPrice
  FROM TourPoI
  WHERE PoI ? 'Price' AND StepNo = 1 ),
IntermPlace AS (
  SELECT *
  FROM TourPoI
  WHERE (PoI->>'Category' = 'Landmark' AND PoI->>'Name' = 'Eiffel Tower') OR 
    PoI->>'Category' = 'Restaurant' ),
EndPlace AS (
  SELECT *, PoI->>'Price' AS EndPrice
  FROM TourPoI t1
  WHERE PoI->>'Category' = 'Restaurant' AND PoI->>'TypeOfFood' = 'French' AND
    StepNo = ( SELECT MAX(StepNo) FROM TourPoI t2 
      WHERE t1.TourId = t2.TourId ) )
SELECT DISTINCT s.TourId, s.StepNo AS StartStep, s.PoI->>'Name' AS StartName,
  i.StepNo AS IntermStep, i.PoI->>'Name' AS IntermName,
  e.StepNo AS EndStep, e.PoI->>'Name' AS EndName
FROM StartPlace s, IntermPlace i, EndPlace e
WHERE s.TourId = i.TourId AND s.AtTime < i.AtTime AND
  i.TourId = e.TourId AND i.AtTime < e.AtTime AND s.StartPrice = e.EndPrice
ORDER BY s.TourId;

/*
 tourid | startstep |      startname      | intermstep |  intermname  | endstep |       endname
--------+-----------+---------------------+------------+--------------+---------+---------------------
      8 |         1 | Bistro les Artizans |          2 | Eiffel Tower |       3 | Bistro les Artizans
*/

-- TEMPORAL VERSION

WITH StartPlace(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(getTime(Tour->>'Price'))))
  FROM TempTour 
  WHERE getTime(Tour->>'Price') IS NOT NULL ),
IntermediateStep(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(Tour @? '$ ? ( 
    (@."Category" == "Restaurant") ||
    (@."Category" == "Landmark" && @."Name" == "Eiffel Tower") )'))))
  FROM TempTour ),
EndPlace(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(Tour @?
    '$ ? (@."Category" == "Restaurant" && @."TypeOfFood" == "French")'))))
  FROM TempTour )
SELECT s.TourId, startValue(s.Tour->>'StepNo')::integer AS StartStep,
  startValue(s.Tour->>'Name') AS StartName,
  startValue(i.Tour->>'StepNo')::integer AS IntermStep, 
  startValue(i.Tour->>'Name') AS IntermName,
  startValue(e.Tour->>'StepNo')::integer AS EndStep, 
  startValue(e.Tour->>'Name') AS EndName
FROM StartPlace s, IntermediateStep i, EndPlace e
WHERE s.TourId = i.TourId AND s.Tour < i.Tour AND
  e.TourId = s.TourId AND i.Tour < e.Tour AND
  startValue(s.Tour)->>'Price' = startValue(e.Tour)->>'Price'
ORDER BY TourId, StartStep;

/*
 tourid | startstep |      startname      | intermstep |  intermname  | endstep |       endname
--------+-----------+---------------------+------------+--------------+---------+---------------------
      8 |         1 | Bistro les Artizans |          2 | Eiffel Tower |       3 | Bistro les Artizans
*/


/*****************************************************************************/

/*
Tours that go to a restaurant in the morning during the third quarter of any year

Tour[Category = 'Restaurant' AND lower(AtTime) = @t AND Hour(@t) < 12 AND
  Month(@t) >= 7 AND Month(@t) <= 12 ]
*/

SELECT TourId, StepNo AS RestStep, PoI->>'Name' AS RestName
FROM TourPoI
WHERE PoI->>'Category' = 'Restaurant' AND
  EXTRACT(HOUR FROM lower(AtTime)) < 12 AND
  EXTRACT(MONTH FROM lower(AtTime)) BETWEEN 7 AND 9
ORDER BY TourId, StepNo;

/*
 tourid | reststep |      restname
--------+----------+---------------------
      1 |        1 | Le Meurice
      8 |        1 | Bistro les Artizans
      9 |        2 | Le Petit Italien
*/

-- TEMPORAL VERSION

WITH Restaurant(TourId, Tour) AS (
  SELECT TourId, atTime(Tour, unnest(spans(whenTrue(
    Tour @? '$ ? ( @."Category" == "Restaurant" )'))))
  FROM TempTour )
SELECT TourId, startValue(Tour->>'StepNo')::integer AS RestStep, 
  startValue(Tour->>'Name') AS RestName
FROM Restaurant
WHERE EXTRACT(HOUR FROM startTimestamp(Tour)) < 12 AND
  EXTRACT(MONTH FROM startTimestamp(Tour)) BETWEEN 7 AND 9;

/*
 tourid | reststep |      restname
--------+----------+---------------------
      1 |        1 | Le Meurice
      8 |        1 | Bistro les Artizans
      9 |        2 | Le Petit Italien
*/

/*****************************************************************************/

/*
Tours that go to two places, where the second one having moderate prices, at the same part of the day, e.g., both of them during the morning

Tour[before([lower(AtTime) = @t AND PartOfDay(@t) = @p], 
  [lower(AtTime) = @t AND Price = 'Moderate' AND PartOfDay(@t) = @p])]
*/

WITH DayPart AS (
 SELECT *,
    CASE
      WHEN EXTRACT(HOUR FROM lower(AtTime)) BETWEEN 8 AND 11
        THEN 'Morning'
      WHEN EXTRACT(HOUR FROM lower(AtTime)) BETWEEN 12 AND 17
        THEN 'Afternoon'
      WHEN EXTRACT(HOUR FROM lower(AtTime)) BETWEEN 18 AND 23
        THEN 'Evening'
      ELSE 'Night'
    END AS partOfDay
  FROM TourPoI )
SELECT DISTINCT f.TourId, f.StepNo AS FirstStep, f.Poi->>'Name' AS FirstName,
  s.StepNo AS SecondStep, s.Poi->>'Name' AS SecondName,
  f.partOfDay AS partOfDay
FROM DayPart f, DayPart s
WHERE f.TourId = s.TourId AND f.AtTime < s.AtTime AND
  s.PoI->>'Price' = 'Moderate' AND f.partOfDay = s.partOfDay
ORDER BY f.TourId;

/*
 tourid | firststep |   firstname   | secondstep |    secondname    | partofday
--------+-----------+---------------+------------+------------------+-----------
      9 |         1 | Musee d'Orsay |          2 | Le Petit Italien | Morning
*/

-- TEMPORAL VERSION

WITH Step(TourId, Tour) AS (
  SELECT TourId, unnest(segments(Tour))
  FROM TempTour ),
DayPart AS (
 SELECT *,
    CASE
      WHEN EXTRACT(HOUR FROM lower(AtTime)) BETWEEN 8 AND 11
        THEN 'Morning'
      WHEN EXTRACT(HOUR FROM lower(AtTime)) BETWEEN 12 AND 17
        THEN 'Afternoon'
      WHEN EXTRACT(HOUR FROM lower(AtTime)) BETWEEN 18 AND 23
        THEN 'Evening'
      ELSE 'Night'
    END AS partOfDay
  FROM Step )
... 
-- Continue as the non-temporal above
-- I haven't found another way to write a temporal version of the above query

/*****************************************************************************/

/*
Tours that go to a place with moderate prices within 1,000m of the `Centre Pompidou'

Tour[Price = 'Moderate' AND ST_DWithin(Geom, ST_Buffer('Centre Pompidou', 1000)]
*/

SELECT DISTINCT t.TourId, t.StepNo, t.PoI->>'Name' AS StepName,
  ST_Distance(t.Geom, p.Geom) AS Distance
FROM TourPoI t, PoI p
WHERE t.PoI->>'Price' = 'Moderate' AND p.Name = 'Centre Pompidou' AND
  ST_DWithin(t.Geom, p.Geom, 1000)
ORDER BY t.TourId;

/*
 tourid | stepno |      stepname       |     distance
--------+--------+---------------------+-------------------
      8 |      1 | Bistro les Artizans | 529.4585913198313
      8 |      3 | Bistro les Artizans | 529.4585913198313
*/

-- TEMPORAL VERSION

WITH ModeratePrices(TourId, Tour, Location) AS (
  SELECT TourId, atTime(Tour, unnest(spans(atValue(Tour->>'Price',
    text 'Moderate')))), Location
  FROM TempTour 
  WHERE atValue(Tour->>'Price', text 'Moderate') IS NOT NULL )
SELECT TourId, startValue(Tour->>'StepNo')::integer AS StepNo,
  startValue(Tour->>'Name') AS StepName, 
  ST_Distance(startValue(m.Location), ST_Centroid(p.BufferGeom)) AS Distance
FROM ModeratePrices m, PoI p
WHERE p.Name = 'Centre Pompidou' AND
  ST_DWithin(valueAtTimestamp(m.Location, startTimestamp(Tour)), p.Geom, 1000)
ORDER BY TourId, Tour;

/*
 tourid | stepno |      stepname       |     distance
--------+--------+---------------------+-------------------
      8 |      1 | Bistro les Artizans | 529.4585913198313
      8 |      3 | Bistro les Artizans | 529.4585913198313
*/

/*****************************************************************************/



