#!/bin/bash
# set -x 
export LANG=C

echo "Import, update geom"

sql=$(cat <<EOF
BEGIN;
update cov_mno set geom=ST_transform(atraster.geom,3857) from atraster where atraster.id=raster and cov_mno.geom is null;
COMMIT;

EOF
)
echo -e $sql|psql frq


