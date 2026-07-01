#!/bin/bash
set -x 
./cov_download_mno.py && ./cov_import.py

echo all done
