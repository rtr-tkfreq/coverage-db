#!/bin/bash
set -x
export LANG=C

echo "Downloading, importing, finalizing"
./cov_download_mno.py && ./cov_import.py && echo "DONE"

