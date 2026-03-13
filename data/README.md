Semantic Trajectories in MobilityDB
===================================

<img src="../doc/images/mobilitydb-logo.svg" width="200" alt="MobilityDB Logo" />

[MobilityDB](https://github.com/ULB-CoDE-WIT/MobilityDB) is an open source software program that adds support for temporal and spatio-temporal objects to the [PostgreSQL](https://www.postgresql.org/) database and its spatial extension [PostGIS](http://postgis.net/).

This repository contains the code and the documentation for demonstrating semantic trajectories in MobilityDB using an hypothetical touristic dataset in Paris and a real-world [pollution dataset](https://www.cse.iitd.ac.in/pollutiondata/delhi) in Delhi, India.

Touristic Dataset
-----------------

The file `paris_tours.sql` in this directory contains the data for the hypothetical touristic dataset.


Pollution Dataset
-----------------

The dataset is available at the following [link](https://www.cse.iitd.ac.in/pollutiondata/delhi). For faster processing we use two-month data corresponding to the months of November and December, 2020. The [ZIP file](https://docs.mobilitydb.com/pub/Delhi_Pollution_2020-Nov-Dec.zip) can be used for obtaining the data. The CSV file should be extracted into this `data` directory. 

Please notice that the files in [HuggingFace](https://huggingface.co/datasets/sachin-iitd/DelhiPollDataset) have different structure than the original files and cannot be used with this repository.

The file `delhi_weather.csv` in this directory contains the weather data obtained from [OpenMeteo](https://open-meteo.com/) corresponding to the trajectories in the pollution data set. We downloaded hourly data comprising temperature, humidity, cloud cover, rain, and wind speed corresponding to the time period between November 1st to December 31st, 2020.

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


