# Coverage map - database
This repository contains installation instructions for the backend of the coverage 
map. The web page can be found in a separate repository at
* [coverage-website](https://github.com/rtr-tkfreq/coverage-website) 

The backend consists of the following components:
* Postgresql database
* Postgrest RESTful API
* nginx
* QGIS

This documentation is based on Debian 11. It should be possible to use other
and/or newer flavors of Linux, but configuration might vary.

## GIT
Install GIT
```bash
    apt git
```

## Postgresql
Install the following package
```bash
    apt install postgresql postgresql-13-postgis-3 postgis
```
Tune postgresql settings (specific values depend on RAM and number of CPUs).
/etc/postgresql/<version>/main/postgresql.conf
```
    # 128GB RAM
    shared_buffers = 5000MB
    work_mem = 50MB
    temp_buffers = 80MB
    # 64 cores
    max_worker_processes = 32
    max_parallel_workers_per_gather = 32
```
Allow access for postgrest and qgis
/etc/postgresql/<version>/main/pg_hba.conf
```
# allow access for postgrest
host    frq     authenticator   <IP of postgrest>/32   md5
# allow access for qgis
host	frq		all		        <IP of qgis>/32		   md5

```
Edit IP accordingly

Restart the database 
```bash
    service postgresql restart
```
## Clone repository
```bash
    su postgres
    cd
    mkdir git
    cd git
    git clone https://github.com/rtr-tkfreq/coverage-db
```


### Create the `frq` database and add `qgis` user
```bash
    su postgres
    cd
    psql
    CREATE DATABASE frq;
    -- password to be replaced
    create user qgis with encrypted password '************';
    grant all privileges on database frq to qgis;
    quit
```

### Add Postgrest user `web_anon` 
```bash
    su postgres
    cd
    psql frq
    create schema api;
    create role web_anon nologin;
    grant usage on schema api to web_anon;
    create role authenticator noinherit login password 'samepasswordasinpostgrest';
    grant web_anon to authenticator;
```
Change password accordingly.

### Add Postgis extensions:
```bash
    su postgres
    cd
    psql frq
    CREATE EXTENSION postgis;
    CREATE EXTENSION postgis_topology;
    CREATE EXTENSION postgis_raster;
```

### Import Austrian raster
Depending on processing performance of the machine, this import of approx. 5 GB of raster data might take several minutes.
```bash
    su postgres
    cd
    mkdir opendata
    cd opendata
    ~/git/coverage/scripts/import-opendata/import-statistic-austria.sh
    # check result
    psql frq
    SELECT pg_size_pretty( pg_total_relation_size('atraster') );
    quit    
```
The resulting raster table is approx. 2,4 GB.

### Import SQL
```bash
    su postgres
    # import tileurl
    psql frq < ~/git/coverage/postgresql/frq_tileurl.sql
    # import setting_options
    psql frq < ~/git/coverage/postgresql/frq_setting_options.sql
    # import cov_mno scheme
    psql frq < ~/git/coverage/postgresql/frq_cov_mno.sql
    # import cov_visible_name
    psql frq < ~/git/coverage/postgresql/frq_cov_visible_name.sql
    # import function cov
    psql frq < ~/git/coverage/postgresql/frq_fn_cov.sql
    quit 
```

## Postgrest

### Download Postgrest

[Postgrest](https://postgrest.org/) is not available as Debian package, but must be downloaded from Github: 
```bash
    cd /opt
    mkdir postgrest
    cd postgrest
    # download from https://github.com/PostgREST/postgrest/releases/latest
    # tar xJf postgrest-<version>-<platform>.tar.xz
    wget https://github.com/PostgREST/postgrest/releases/download/v9.0.0/postgrest-v9.0.0-linux-static-x64.tar.xz
    tar xJf <file>
    ln -s postgrest /usr/local/sbin
```
#### Configure Postgrest
```bash
    cd /etc
    mkdir postgrest
    cd postgrest
    cp ~postgres/git/coverage/postgrest/config .
```
Edit config and replace dummy IP and password.

### Add systemd service
```bash
    cd /lib/systemd/system/
    cp ~postgres/git/coverage/postgrest/postgrest.service .
    systemctl daemon-reload
    systemctl start postgrest.service
    systemctl enable postgrest.service 
```

## Nginx
Nginx is used to provide access to static tiles (created with QGIS),
the REST-API provided by Postgrest and tile from basemap.at.

Install Nginx and Certbot
```bash
    apt install nginx certbot python3-certbot-nginx
```
The details of nginx configuration are site specific, the relevant fragment 
can be found under nginx/example.com.

The file "dummy.png" is used when no tiles are available (e.g. outside boundaries).

## QGIS
Install QGIS
```bash
    apt install qgis
```
As an alternative you might follow https://qgis.org/en/site/forusers/alldownloads.html and 
install the latest version of QGIS.

QGIS can be used to render tiles using 'Raster tools/Generate XYZ tiles'.