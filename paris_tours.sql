/*****************************************************************************/

DROP TABLE IF EXISTS PoI CASCADE;
CREATE TABLE PoI(PoIId integer PRIMARY KEY, Name text NOT NULL,
  Geom geometry(Point, 2154) NOT NULL, Description jsonb NOT NULL);
INSERT INTO PoI VALUES
(1, 'Le Meurice', ST_Point(650759.721, 6863028.090, 2154),
  '{"Name": "Le Meurice", "Category": "Restaurant", "TypeOfFood": "French",
  "Price": "Expensive"}'),
(2, 'Hilton Paris Opera', ST_Point(650535.108, 6864130.888, 2154),
  '{"Name": "Hilton Paris Opera", "Category": "Hotel", "Stars": 5}'),
(3, 'Pathee Opera', ST_Point(651187.252530473, 6863616.056298946, 2154),
  '{"Name": "Pathee Opera", "Category": "Entertainment", "Type": "Movie"}'),
(4, 'Holiday Inn Paris Gare de l''Est', ST_Point(653017.785, 6864194.728, 2154),
  '{"Name": "Holiday Inn Paris Gare de l''Est", "Category": "Hotel", "Stars": 3}'),
(5, 'Cafe de Flore', ST_Point(650991.685, 6861829.618, 2154),
  '{"Name": "Cafe de Flore", "Category": "Amenity", "Type": "Coffee Shop"}'),
(6, 'Le Petit Italien', ST_Point(653501.802, 6862173.661, 2154),
  '{"Name": "Le Petit Italien", "Category": "Restaurant", "TypeOfFood": "Italian",
  "Price": "Moderate"}'),
(7, 'Musee d''Orsay', ST_Point(650596.165, 6862431.229),
  '{"Name": "Musee d''Orsay", "Category": "Museum"}'),
(8, 'Musee du Louvre', ST_Point(651418.262, 6862558.827, 2154),
  '{"Name": "Musee du Louvre", "Category": "Museum"}'),
(9, 'Indy Restaurant', ST_Point(652615.100,  6863746.535, 2154),
  '{"Name": "Indy Restaurant", "Category": "Restaurant", "TypeOfFood": "Indian", 
  "Price": "Moderate"}'),
(10, 'Eiffel Tower', ST_Point(648273.589, 6862226.878, 2154),
  '{"Name": "Eiffel Tower", "Category": "Landmark"}'),
(11, 'Bistro les Artizans', ST_Point(652094.296,  6862861.220, 2154),
  '{"Name": "Bistro les Artizans", "Category": "Restaurant", "TypeOfFood": "French", 
  "Price": "Moderate"}'),
(12, 'Centre Pompidou', ST_Point(652477.201,  6862495.556, 2154),
  '{"Name": "Centre Pompidou", "Category": "Museum"}');

/*****************************************************************************/

DROP TABLE IF EXISTS Tour CASCADE;
CREATE TABLE Tour(TourId integer, StepNo integer, PoI text, AtTime tstzspan);
INSERT INTO Tour(TourId, StepNo, PoI, AtTime) VALUES
-- Trip 1
(1, 1, 'Le Meurice', '[2025-09-09 09:00, 2025-09-09 13:00)'),
(1, 2, 'Musee d''Orsay', '[2025-09-09 14:10, 2025-09-09 17:00)'),
(1, 3, 'Le Petit Italien', '[2025-09-09 18:00, 2025-09-09 19:30)'),
(1, 4, 'Pathee Opera', '[2025-09-09 20:30, 2025-09-09 22:30:00)'),
(1, 5, 'Hilton Paris Opera', '[2025-09-09 23:30, 2025-09-10 08:30)'),
-- Trip 2
(2, 1, 'Hilton Paris Opera', '[2025-09-09 08:10, 2025-09-09 10:00)'),
(2, 2, 'Musee du Louvre', '[2025-09-09 11:10, 2025-09-09 13:00)'),
(2, 3, 'Indy Restaurant', '[2025-09-09 13:30, 2025-09-09 15:30)'),
(2, 4, 'Pathee Opera', '[2025-09-09 17:30, 2025-09-09 20:00)'),
(2, 5, 'Hilton Paris Opera', '[2025-09-09 20:30, 2025-09-10 08:30)'),
-- Trip 3
(3, 1, 'Hilton Paris Opera', '[2025-09-09 09:00, 2025-09-09 10:00)'),
(3, 2, 'Pathee Opera', '[2025-09-09 17:00, 2025-09-09 19:00)'),
(3, 3, 'Indy Restaurant', '[2025-09-09 21:30, 2025-09-09 23:30)'),
-- Trip 4
(4, 1, 'Holiday Inn Paris Gare de l''Est', '[2025-09-11 10:10, 2025-09-11 11:00)'),
(4, 2, 'Cafe de Flore', '[2025-09-11 11:10, 2025-09-11 12:00)'),
(4, 3, 'Musee du Louvre', '[2025-09-11 12:10:00, 2025-09-11 14:00)'),
(4, 4, 'Le Meurice', '[2025-09-11 15:30, 2025-09-11 17:30)'),
-- Trip 5
(5, 1, 'Eiffel Tower', '[2025-09-11 10:30, 2025-09-11 15:30)'),
(5, 2, 'Cafe de Flore', '[2025-09-11 16:00, 2025-09-11 17:00)'),
(5, 3, 'Holiday Inn Paris Gare de l''Est', '[2025-09-11 19:30, 2025-09-12 08:30)'),
-- Trip 6
(6, 1, 'Hilton Paris Opera', '[2025-09-09 09:00, 2025-09-11 10:00)'),
(6, 2, 'Musee d''Orsay', '[2025-09-11 11:10, 2025-09-11 13:00)'),
(6, 3, 'Le Meurice', '[2025-09-11 13:10, 2025-09-11 15:30)'),
(6, 4, 'Eiffel Tower', '[2025-09-11 16:00, 2025-09-11 18:00)'),
(6, 5, 'Hilton Paris Opera', '[2025-09-11 20:00, 2025-09-12 08:30)'),
-- Trip 7
(7, 1, 'Holiday Inn Paris Gare de l''Est', '[2025-09-11 09:00, 2025-09-11 10:00)'),
(7, 2, 'Cafe de Flore', '[2025-09-11 10:30, 2025-09-11 11:00)'),
(7, 3, 'Indy Restaurant', '[2025-09-11 12:30, 2025-09-11 13:30)'),
(7, 4, 'Holiday Inn Paris Gare de l''Est', '[2025-09-11 21:00, 2025-09-12 10:00)'),
-- Trip 8
(8, 1, 'Bistro les Artizans', '[2025-09-12 09:00, 2025-09-12 10:30)'),
(8, 2, 'Eiffel Tower', '[2025-09-12 11:00, 2025-09-12 12:00)'),
(8, 3, 'Bistro les Artizans', '[2025-09-12 20:00, 2025-09-12 22:00)'),
-- Trip 9
(9, 1, 'Musee d''Orsay', '[2025-09-12 09:00, 2025-09-12 10:00)'),
(9, 2, 'Le Petit Italien', '[2025-09-12 10:30, 2025-09-12 11:00)'),
-- Trip 10
(10, 1, 'Musee d''Orsay', '[2025-09-09 00:00:00+00, 2025-09-09 12:00:00+00)'),
(10, 2, 'Le Meurice', '[2025-09-09 12:30:00+00, 2025-09-09 14:00:00+00)'),
(10, 3, 'Musee du Louvre', '[2025-09-09 14:30:00+00, 2025-09-09 18:30:00+00)'),
(10, 4, 'Le Petit Italien', '[2025-09-09 19:30:00+00, 2025-09-09 21:30:00+00)'),
(10, 5, 'Musee d''Orsay', '[2025-09-13 10:00:00+00, 2025-09-13 15:00:00+00)');

/*****************************************************************************/

DROP VIEW IF EXISTS TourPoI;
CREATE VIEW TourPoI(TourId, StepNo, PoI, Geom, AtTime) AS
SELECT t.TourId, t.StepNo, p.Description, p. Geom, t.AtTime
FROM Tour t, PoI p
WHERE t.PoI = p.Name;

/*****************************************************************************/

-- TEMPORAL TABLE

DROP TABLE IF EXISTS TempTour;
CREATE TABLE TempTour(TourId integer PRIMARY KEY, Tour tjsonb,
  Location tgeompoint);
INSERT INTO TempTour(TourId, Tour, Location)
SELECT TourId,
  merge(array_agg(tjsonb(jsonb_build_object(text 'StepNo', StepNo) || PoI, 
    AtTime) ORDER BY AtTime)),
  merge(array_agg(tgeompoint(Geom, AtTime) ORDER BY AtTime)) AS Location
FROM TourPoI
GROUP BY TourId
ORDER BY TourId;

/*****************************************************************************/



