#!/bin/bash

set -x
export LANG=C

# import 100x100 raster of Austria into database frq

cd || exit
mkdir statistic-austria-raster-at
cd statistic-austria-raster-at || exit
wget http://data.statistik.gv.at/data/OGDEXT_RASTER_1_STATISTIK_AUSTRIA_L000100_LAEA.zip || exit
unzip OGDEXT_RASTER_1_STATISTIK_AUSTRIA_L000100_LAEA.zip || exit
shp2pgsql -I -s 3035 -d STATISTIK_AUSTRIA_L000100_LAEA.shp atraster | psql frq > /dev/null 

