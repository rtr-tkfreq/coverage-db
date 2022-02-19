#!/bin/bash
export LANG=C
set -x 
find /var/www/tiles  -size 1246c  -exec rm  {} \;
