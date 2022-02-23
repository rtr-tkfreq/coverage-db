#!/bin/bash
# set -x 
export LANG=C

DATE=`date '+%Y-%m-%d'`

ls -l /var/lib/postgresql/open/${DATE}/${1}.csv

test -r /var/lib/postgresql/open/${DATE}/${1}.csv || exit

echo "Import for ${1}"

sql=$(cat <<EOF
BEGIN;


COPY cov_mno(operator,reference,license,rfc_date,raster,dl_normal,ul_normal,dl_max,ul_max)
FROM '/var/lib/postgresql/open/${DATE}/${1}.csv'
DELIMITER ';'
CSV HEADER;

COMMIT;

EOF
)
echo -e $sql|psql frq


