#!/bin/bash
set -x 
./cov_download_mno.sh && ./cov_import_all.sh && ./cov_import_final_step.sh

echo all done
