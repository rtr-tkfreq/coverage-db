#!/bin/bash
set -x
export LANG=C

echo "Downloading, importing, finalizing"
./cov_download_mno.sh && ./cov_import_all.sh && ./cov_import_final_step.sh && echo "DONE"

