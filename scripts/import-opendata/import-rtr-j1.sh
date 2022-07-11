#!/bin/bash

set -x
export LANG=C

# import RTR's F1/16 appendix J1 (relevant cadastral communities) into database frq

cd || exit
mkdir rtr-j1
cd rtr-j1 || exit
wget https://www.rtr.at/TKP/was_wir_tun/telekommunikation/spectrum/procedures/Multibandauktion_700-1500-2100MHz_2020/Anhang-J1_relevante_katastralgemeinden.gpkg || exit
ogr2ogr -f PostgreSQL "PG:dbname=frq" Anhang-J1_relevante_katastralgemeinden.gpkg -nln rtr-j1
 

