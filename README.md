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

Input Data
----------

The directory `data` contains the input files for the hypothetical touristic dataset in Paris. Loading this dataset can be done as follows.

Storing the Paris input data in PostgreSQL can be done as follows.
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

The `data/` directory also expects the data from two-month pollution data in Delhi corresponding to the months of November and December, 2020 as well as the districts of New Delhi. The pollution data can be obtained from this [link](https://www.cse.iitd.ac.in/pollutiondata/delhi). Alternatively, you can find the data files in the following [ZIP](Delhi_Pollution_2020-Nov-Dec.zip) file. The contents of this ZIP file should be extracted into the `data/` directory.

In order to get the districts of New Delhi we need to download OSM data from New Delhi obtained from the this [link](https://geo2day.com/asia/india/national_capital_territory_of_delhi.html)
The file `national_capital_territory_of_delhi.pbf` must be located in the `data/` directory.

We load the OSM data into PostgreSQL as follows.
```bash
osm2pgsql -U <user> -W -H localhost -P 5432 -d <database> --create --slim -G --hstore data/national_capital_territory_of_delhi.pbf
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

Queries
-------

The queries can be found in the following files

*  `delhi_grid.sql`: Queries for the trips segmented by the grid, both for the discrete and the continuous approaches
*  `delhi_districts.sql`: Queries for the trips segmented by the districts, both for the discrete and the continuous approaches
*  `delhi_points_trips.sql`: Queries for the complete trajectories, both for the discrete and the continuous approaches

License
-------

The documentation of this evaluation is licensed under a [Creative Commons Attribution-Share Alike 3.0 License](https://creativecommons.org/licenses/by-sa/3.0/)
