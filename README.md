Semantic Trajectories in MobilityDB
===================================

<img src="doc/images/mobilitydb-logo.svg" width="200" alt="MobilityDB Logo" />

[MobilityDB](https://github.com/ULB-CoDE-WIT/MobilityDB) is an open source software program that adds support for temporal and spatio-temporal objects to the [PostgreSQL](https://www.postgresql.org/) database and its spatial extension [PostGIS](http://postgis.net/).

This repository contains the code and the documentation for demonstrating semantic trajectories in MobilityDB using an hypothetical touristic dataset in Paris and a real-world [pollution dataset](https://www.cse.iitd.ac.in/pollutiondata/delhi) in Delhi, India.


Installing MobilityDB
---------------------

You must first install the MobilityDB extension in your system. We refer to the [MobilityDB](https://github.com/MobilityDB/MobilityDB) documentation for doing this. Please notice that the current release 1.3 of MobilityDB does **not** include the temporal JSON data type and thus it is necessary to build MobilityDB from the sources of the `master` branch. This can be done by first cloning the repository as show next. 
```
git clone https://github.com/MobilityDB/MobilityDB
```
and then building the repository. Installing MobilityDB from the precompiled packages, for example using `sudo apt install` in Linux,  does **not** work with this repository.

Touristic Dataset
-----------------

The file `paris_tours.sql` in this directory contains the data for the hypothetical touristic dataset. Storing the Paris input data in PostgreSQL can be done as follows.
```
~/src/MobilityDB-Semantic$ createdb paris
~/src/MobilityDB-Semantic$ psql paris
psql (18.3)
Type "help" for help.

paris=# CREATE EXTENSION MobilityDB CASCADE;
NOTICE:  installing required extension "postgis"
CREATE EXTENSION
paris=# \i paris_tours.sql
psql:paris_tours.sql:3: NOTICE:  table "poi" does not exist, skipping
DROP TABLE
CREATE TABLE
INSERT 0 12
psql:paris_tours.sql:38: NOTICE:  table "tour" does not exist, skipping
DROP TABLE
CREATE TABLE
INSERT 0 39
psql:paris_tours.sql:93: NOTICE:  view "tourpoi" does not exist, skipping
DROP VIEW
CREATE VIEW
psql:paris_tours.sql:103: NOTICE:  table "temptour" does not exist, skipping
DROP TABLE
CREATE TABLE
INSERT 0 10
```

The queries for both the discrete and the continuous approaches can be found in the file `paris_queries.sql`.

Pollution Dataset
-----------------

The  repository also expects the data from two-month pollution data in Delhi corresponding to November and December, 2020. The pollution data can be obtained from this [link](https://www.cse.iitd.ac.in/pollutiondata/delhi). Alternatively, the [ZIP file](https://docs.mobilitydb.com/pub/Delhi_Pollution_2020-Nov-Dec.zip) can be used for obtaining the data. The contents of this ZIP file should be extracted into the `data/` directory. Please notice that the files in [HuggingFace](https://huggingface.co/datasets/sachin-iitd/DelZhiPollDataset) have different structure than the original files and cannot be used with this repository.

The repository also expects weather data in Delhi during the corresponding period. The file `delhi_weather.csv` in this directory contains the weather data obtained from [OpenMeteo](https://open-meteo.com/) corresponding to the trajectories in the pollution data set. We downloaded hourly data comprising temperature, humidity, cloud cover, rain, and wind speed corresponding to the time period between November 1st to December 31st, 2020.

We computed the center point of the extent of the dataset as follows.
```sql
WITH Extent(MinLon, MinLat, MaxLon, MaxLat) AS (
  SELECT MIN(Lon), MIN(Lat), MAX(Lon), MAX(Lat)
  FROM DelhiInput )
SELECT MinLon + (MaxLon - MinLon) / 2 AS CenterLon,
  MinLat + (MaxLat - MinLat) / 2 AS CenterLat
FROM Extent;
-- 77.21044149999999 | 28.603272625000002
```

Then we obtained the weather data with the following REST API request.
```bash
https://open-meteo.com/en/docs/historical-weather-api?start_date=2020-11-01&end_date=2020-12-31&latitude=28.603272&
  longitude=77.210441&hourly=temperature_2m,relative_humidity_2m,cloud_cover,rain,wind_speed_10m
```
We downloaded the data into into a CSV file, and did some basic preparation of this file dropping the first three rows. For simplicity, and given the very small variation within the city, we assume that these hourly data remain uniform in all the city area considered in this study. 

The  repository also expects the data from the districts of New Delhi. In order to get this data we need to download OSM data from New Delhi obtained from the this [link](https://geo2day.com/asia/india/national_capital_territory_of_delhi.html). The file `national_capital_territory_of_delhi.pbf` must be located in the home directory.

We load the OSM data into PostgreSQL as follows.
```bash
osm2pgsql -U <user> -W -H localhost -P 5432 -d <database> --create --slim -G --hstore national_capital_territory_of_delhi.pbf
```

Then, we can execute the script that load the Delhi input data into PostgreSQL as follows.
```
~/src/MobilityDB-Semantic$ createdb delhi
~/src/MobilityDB-Semantic$ psql delhi
psql (18.3)
Type "help" for help.

delhi=# CREATE EXTENSION MobilityDB CASCADE;
NOTICE:  installing required extension "postgis"
CREATE EXTENSION
delhi=# CREATE EXTENSION hstore;
CREATE EXTENSION
delhi=# \timing
Timing is on.
delhi=# \i delhi_load.sql
DROP FUNCTION
Time: 13.130 ms
CREATE FUNCTION
Time: 6.883 ms
delhi=# select delhi_load();
NOTICE:  extension "mobilitydb" already exists, skipping
NOTICE:  extension "hstore" already exists, skipping
NOTICE:  Creating the table DelhiInput
NOTICE:  Inserting 2020-11-01_all.csv
[...]
NOTICE:  Inserting 2020-12-31_all.csv
NOTICE:  Creating tables WeatherInput and WeatherHourly
NOTICE:  Creating the table TripPoints
NOTICE:  Creating the table Trips
NOTICE:  Creating the table Grid
NOTICE:  Creating the table TripCells
NOTICE:  Creating the table TripTiles
NOTICE:  Creating the table Districts
NOTICE:  Creating tables PointDistricts and PointDistrictSeq
NOTICE:  Creating tables TripDistricts and TripDistrictsSeq
 delhi_load
------------

(1 row)

Time: 1441282.565 ms (24:01.283)
delhi=#
```

The queries can be found in the following files

*  `delhi_grid.sql`: Queries for the trips segmented by the grid, both for the discrete and the continuous approaches
*  `delhi_districts.sql`: Queries for the trips segmented by the districts, both for the discrete and the continuous approaches
*  `delhi_points_trips.sql`: Queries for the complete trajectories, both for the discrete and the continuous approaches

License
-------

The documentation of this evaluation is licensed under a [Creative Commons Attribution-Share Alike 3.0 License](https://creativecommons.org/licenses/by-sa/3.0/)
