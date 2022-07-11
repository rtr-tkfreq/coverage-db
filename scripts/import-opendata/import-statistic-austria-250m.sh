#!/bin/bash

set -x
export LANG=C

# import 250x250 raster of Austria into database frq

cd || exit
test -r statistic-austria-raster-at || mkdir statistic-austria-raster-at
cd statistic-austria-raster-at || exit
wget https://data.statistik.gv.at/data/OGDEXT_RASTER_1_STATISTIK_AUSTRIA_L000250_LAEA.zip || exit
unzip OGDEXT_RASTER_1_STATISTIK_AUSTRIA_L000250_LAEA.zip || exit
shp2pgsql -I -s 3035 -d STATISTIK_AUSTRIA_L000250_LAEA.shp atraster250 | psql frq > /dev/null 

