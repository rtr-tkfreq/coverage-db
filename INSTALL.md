# Installation

Manual walkthrough of what `ansible/playbook.yml` automates. Follow this if
you're setting a host up by hand instead of running Ansible. Assumes Debian 13
(trixie); adjust codenames/paths for other distributions.

For what these components are and how they interact, see
[README.md](README.md) — this file is just the steps.

## 1. Install PostgreSQL + PostGIS (official PGDG repo)

Debian's own PostgreSQL/PostGIS packages lag behind upstream; use the PGDG
repo instead so you get current point releases.

```bash
apt install curl ca-certificates gnupg xz-utils
install -d /usr/share/postgresql-common/pgdg
curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc

cat > /etc/apt/sources.list.d/pgdg.sources << 'EOF'
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: trixie-pgdg
Components: main
Architectures: amd64
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
EOF

apt update
apt install postgresql-17 postgresql-17-postgis-3 postgresql-17-postgis-3-scripts
```

(`trixie-pgdg` follows the pattern `<codename>-pgdg`; use the codename for
whatever Debian/Ubuntu release you're actually on.)

## 2. Install QGIS (official qgis.org repo)

Same reasoning — the qgis.org repo tracks upstream releases more closely than
Debian's bundled version.

```bash
mkdir -m755 -p /etc/apt/keyrings
wget -O /etc/apt/keyrings/qgis-archive-keyring.gpg \
  https://download.qgis.org/downloads/qgis-archive-keyring.gpg

cat > /etc/apt/sources.list.d/qgis.sources << 'EOF'
Types: deb
URIs: https://qgis.org/debian
Suites: trixie
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/qgis-archive-keyring.gpg
EOF

apt update
apt install qgis python3-qgis
```

Confirmed working: this repo currently serves QGIS 4.0.3 for `trixie` (see
https://qgis.org/resources/installation-guide/ if `apt update` fails on the
qgis.sources entry — the available suites/channels can change).

**Version matters, not just "is QGIS installed":** the QGIS project files in
this repo are saved with QGIS 4.x. Loading one under an older major version
mostly *looks* fine (opens, layers query correctly) but the
`native:tilesxyzdirectory` Processing algorithm specifically was found to
hang indefinitely under QGIS 3.40 (Debian's bundled, Qt5-based build) with no
error — confirmed via direct PyQGIS rendering working fine and the hang being
specific to that one algorithm. Match major versions.

**If a host already has Debian's bundled QGIS 3.x installed**, purge it
before installing 4.x — the two can't coexist (Qt5 vs Qt6 packages conflict):

```bash
apt purge 'qgis*' 'python3-qgis*' 'libqgis*'
apt install qgis python3-qgis
```

`qgis` includes `qgis_process`, the CLI used to render tiles headlessly — no
separate package needed.

## 3. Install nginx (plain Debian is fine here)

```bash
apt install nginx
```

## 4. Build and deploy the coverage-website frontend

Node.js from the official NodeSource repo, not Debian's bundled version —
trixie's own `nodejs` package (20.19.2) is right at the edge of what this
Angular CLI version needs (`^20.19 || ^22.12 || ^24`) and was confirmed too
old for `ng build` in practice.

```bash
mkdir -m755 -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  -o /etc/apt/keyrings/nodesource.asc
chmod 644 /etc/apt/keyrings/nodesource.asc

cat > /etc/apt/sources.list.d/nodesource.sources << 'EOF'
Types: deb
URIs: https://deb.nodesource.com/node_22.x
Suites: nodistro
Components: main
Signed-By: /etc/apt/keyrings/nodesource.asc
EOF

apt update
apt install nodejs git
```

Clone, build, and deploy:

```bash
git clone git@github.com:rtr-tkfreq/coverage-website.git /opt/coverage-website
# (or the HTTPS remote if this host doesn't have SSH access to the repo)
cd /opt/coverage-website
npm ci
npx ng build --configuration production

mkdir -p /var/www/frq
cp -r dist/frq-map/. /var/www/frq/
chown -R root:www-data /var/www/frq
```

`outputPath` in `angular.json` is `dist/frq-map`, containing one
subdirectory per locale (`de/`, `en/`) directly — matches
`nginx/example.com`'s rewrite rule serving `/de/` and `/en/` as real
subpaths, so this copies straight in with no extra nesting to strip.
`nginx/example.com` (see step 9) sets `root /var/www/frq;` to serve it.

To pick up a new commit later, `git pull` in `/opt/coverage-website` and
repeat the `npm ci` / `ng build` / `cp -r` steps.

## 5. Install PostgREST

Not packaged for Debian — install the upstream static binary.

```bash
POSTGREST_VERSION=14.14   # check https://github.com/PostgREST/postgrest/releases for the current version
curl -sL "https://github.com/PostgREST/postgrest/releases/download/v${POSTGREST_VERSION}/postgrest-v${POSTGREST_VERSION}-linux-static-x86-64.tar.xz" \
  | tar -xJ -C /usr/local/sbin postgrest
chmod 755 /usr/local/sbin/postgrest

mkdir -p /etc/postgrest
cp postgrest/config /etc/postgrest/config
# edit /etc/postgrest/config: set db-uri to
#   postgres://authenticator:<password>@127.0.0.1:5432/frq
# (the password MUST match the one used for the `authenticator` role below)

cp postgrest/postgrest.service /etc/systemd/system/postgrest.service
systemctl daemon-reload
systemctl enable --now postgrest
```

## 6. Database setup

**Only do this on a fresh database** — none of this is safe to re-run against
a populated production database.

```bash
su postgres
createdb frq
psql -d frq
```

Create the roles PostgREST/QGIS need (`web_anon` for anonymous API reads,
`authenticator` for PostgREST's own login, `qgis` for the QGIS layer
connection — pick real passwords, don't use the placeholders below):

```sql
CREATE ROLE web_anon NOLOGIN;
CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'samepasswordasinpostgrest';
GRANT web_anon TO authenticator;
CREATE ROLE qgis LOGIN PASSWORD 'qgispassword';
```

Load the schema:

```bash
psql -d frq -f postgresql/frq_scheme.sql
```

Add the `geom` column — this is populated by `cov_download_mno.py`'s final
step and used directly by the QGIS layer's SQL, but it's **not** in the
checked-in schema dump (it was added out-of-band on production at some
point):

```sql
ALTER TABLE cov_mno ADD COLUMN geom geometry(MultiPolygon, 3857);
CREATE INDEX cov_mno_geom_idx ON cov_mno USING gist(geom);
```

The spatial index isn't optional in practice: without it, the QGIS layer's
bbox-filtered subquery falls back to a near-full-table scan on `cov_mno`
(confirmed via `EXPLAIN ANALYZE`: 1.6s for a *limited* query, vs 10.7ms with
the index) — on a multi-million-row table this is the difference between a
render finishing and one that looks hung.

**Set up `.pgpass` so the `qgis` role can authenticate over TCP.** The QGIS
project's PostgreSQL layer connects via `host=127.0.0.1` (TCP), which
`pg_hba.conf` requires `scram-sha-256` password auth for — unlike `psql`
invoked directly by the `postgres` OS user, which authenticates over the
local socket via peer auth and needs no password. Without this, `qgis_process`
doesn't error — it hangs indefinitely on an invisible, headless credential
dialog, which looks identical to a stuck render:

```bash
echo "127.0.0.1:5432:frq:qgis:qgispassword" >> ~/.pgpass   # run as the postgres OS user
chmod 600 ~/.pgpass
```

`frq_scheme.sql` creates `cov_layer`/`cov_layer_source`/`cov_layer_obligation`
(the layer catalog — see README.md) but doesn't seed them; a fresh install
has no selectable layers until you add some:

```bash
psql -d frq -f postgresql/seed_layers.sql
```

That's the current real production set — 7 operators (A1TA/TMA/H3A on
F1/16, LIWEST/SBG/MASS/HGRAZ on F7/16), the "all operators" combined layer,
the 3-operator "3600 MHz" combo (A1TA+TMA+H3A on F7/16), and each of those
three's F7/16 band as its own independently selectable layer — see the file
itself for exactly what it inserts. Idempotent, safe to re-run. Every layer
resolves purely through `cov_layer_source` (see README.md's "The layer
catalog"): a plain operator needs a self-referencing row, `@all` needs one
row per operator at that operator's own reference, and the `...3600mhz`
layers point at specific (operator, F7/16) leaves regardless of that
operator's own reference.

`all3600mhz`/`a1ta3600mhz`/`tma3600mhz`/`h3a3600mhz` need their QGIS project
templates deployed too (see step 8) and `cov_render_tiles.py`'s
`LEAF_PROJECTS`/`COMBINED_PROJECTS` to know about them — already the case if
you deployed the current version of this repo.

## 7. Populate `atraster` (the national 100m raster grid)

This is what `cov_mno.raster` joins against to get a geometry. One-time,
~230MB download, takes several minutes to import (single-row INSERTs via
`shp2pgsql`, not bulk COPY — expect single-digit minutes per million rows).

```bash
mkdir -p ~/statistic-austria-raster-at && cd ~/statistic-austria-raster-at
wget https://data.statistik.gv.at/data/OGDEXT_RASTER_1_STATISTIK_AUSTRIA_L000100_LAEA.zip
unzip OGDEXT_RASTER_1_STATISTIK_AUSTRIA_L000100_LAEA.zip
shp2pgsql -I -s 3035 -d *.shp atraster | psql -d frq
```

**Gotcha found while testing this:** the shapefile Statistik Austria
currently publishes has a different attribute schema than the one the
checked-in `frq_scheme.sql` and the production `api.cov()` SQL function
assume (`id`/`name` columns). The current file instead has `__gid`,
`cellcode`, `code_su`, `code_inspi` — `cellcode` (or `__gid`, identical
values) holds the same `100mN...E...`-style identifier the old `id` column
used to. Since `shp2pgsql -d` drops and recreates the table from whatever the
shapefile actually contains, **verify which column matches your
`cov_mno.raster` values after import** (`SELECT * FROM atraster LIMIT 5;`)
before relying on any SQL that joins `atraster.id = ...` — it may need to be
`atraster.cellcode = ...` instead. This affects both the final-step geom
backfill and the `api.cov()` function; check both if you re-import this data.

## 8. Deploy the scripts and QGIS project templates

```bash
mkdir -p /opt/coverage-db/scripts/import-opendata
cp scripts/import-opendata/{cov_download_mno.py,cov_render_tiles.py,cov_head.py,*.qgs} \
   /opt/coverage-db/scripts/import-opendata/
chown -R postgres:postgres /opt/coverage-db/scripts/import-opendata
chmod +x /opt/coverage-db/scripts/import-opendata/*.py
```

The scripts must run as the `postgres` OS user — they rely on `psql`'s peer
authentication (no password) and on `~` resolving to
`/var/lib/postgresql`.

## 9. nginx and tile docroot

```bash
mkdir -p /var/www/tiles
chown postgres:www-data /var/www/tiles
chmod 775 /var/www/tiles
cp nginx/example.com /etc/nginx/snippets/coverage-db.conf
```

`nginx/example.com` is a **fragment**, not a complete vhost — it has a `map`
directive that belongs in the `http {}` context and `location` blocks that
belong inside a `server {}` block. Wire it into a real server block with your
actual `server_name`/TLS config; it's not auto-included by installing it.

## 10. Systemd services

Create `/etc/systemd/system/cov-download.service`:

```ini
[Unit]
Description=Coverage DB: download + import mobile network coverage data
Wants=postgresql.service network-online.target
After=postgresql.service network-online.target

[Service]
Type=oneshot
User=postgres
WorkingDirectory=/opt/coverage-db/scripts/import-opendata
ExecStart=/opt/coverage-db/scripts/import-opendata/cov_download_mno.py -q
```

and `/etc/systemd/system/cov-download.timer`:

```ini
[Unit]
Description=Run cov-download.service on a schedule

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Then `/etc/systemd/system/cov-render.service`:

```ini
[Unit]
Description=Coverage DB: render + publish XYZ tiles via QGIS
Wants=postgresql.service
After=postgresql.service

[Service]
Type=oneshot
# rendering the whole country at these zoom levels can take hours
TimeoutStartSec=0
User=postgres
WorkingDirectory=/opt/coverage-db/scripts/import-opendata
Environment=COV_TILE_DOCROOT=/var/www/tiles/cov
Environment=COV_TILE_EXTENT=977649.9582,1948091.0889,5838029.9512,6281289.9249[EPSG:3857]
Environment=COV_TILE_ZOOM_MIN=4
Environment=COV_TILE_ZOOM_MAX=14
Environment=COV_TILE_DPI=96
Environment=COV_TILE_QUALITY=75
ExecStart=/opt/coverage-db/scripts/import-opendata/cov_render_tiles.py -q
```

and `/etc/systemd/system/cov-render.timer` (same shape as the download timer,
just offset an hour so it doesn't start at the exact same moment):

```ini
[Unit]
Description=Run cov-render.service on a schedule

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable everything:

```bash
systemctl daemon-reload
systemctl enable --now cov-download.timer cov-render.timer
```

`cov_render_tiles.py` takes a file lock (`/tmp/cov_render_tiles.lock`) so a
scheduled run that fires while a previous render is still in progress just
exits quietly instead of running two renders concurrently — safe to leave the
timer on a fixed daily schedule even though renders can take hours.

## 11. Verifying it works

```bash
# as postgres:
su postgres -c '/opt/coverage-db/scripts/import-opendata/cov_download_mno.py'
su postgres -c '/opt/coverage-db/scripts/import-opendata/cov_render_tiles.py'
```

If QGIS fails with a Qt platform plugin error (`could not connect to
display`), that's normal on a headless server — the scripts already set
`QT_QPA_PLATFORM=offscreen` internally for the render step, no extra
configuration needed. If you're testing `qgis_process` manually rather than
through the script, set it yourself:

```bash
QT_QPA_PLATFORM=offscreen qgis_process run native:tilesxyzdirectory --project_path=... -- ...
```

Check results:

```bash
psql -d frq -c "SELECT operator, reference, date, url FROM tileurl ORDER BY date DESC LIMIT 5;"
ls /var/www/tiles/cov/TMA/F1_16/
curl -I http://localhost/cov/TMA/F1_16/<date>/4/8/5.png
```

To render just one target manually instead of the full scan (useful for
testing a specific operator, e.g. a small one like SBG for a quick check,
or a combined layer like `all3600mhz` that hasn't rendered yet) use
`--target OPERATOR` or `--target OPERATOR:REFERENCE` (needed if an operator
has more than one leaf, e.g. TMA has both F1/16 and F7/16 — `--target TMA`
alone errors asking you to disambiguate). A combined target is selected by
its own code, e.g. `--target all3600mhz`. This bypasses the lock file (a
scoped debug run isn't the scheduled job) but still only renders if there's
actually new/unrendered data for that target — same trigger logic as a full
run.

```bash
su postgres -c '/opt/coverage-db/scripts/import-opendata/cov_render_tiles.py --target SBG'
```

Add `--output-dir PATH` to write tiles somewhere other than the real tile
docroot — e.g. so a debug render doesn't overwrite a real one you're
comparing against:

```bash
su postgres -c '/opt/coverage-db/scripts/import-opendata/cov_render_tiles.py --target all3600mhz --output-dir /tmp/debug-tiles'
```

## Notes

- If an operator's site blocks this host's IP, `cov_download_mno.py` supports
  routing downloads through another host via SSH: `export
  COV_RELAY_HOST=user@relayhost` (needs passwordless SSH + `curl` on the
  relay). See the script's module docstring for details.
- `cov_download_mno.py --keep-duplicates` is a debug flag: keeps files (and
  the run directory) even when identical to a previous run, and forces
  re-import of everything — relies on the database's unique constraint on
  `(operator, reference, raster, rfc_date)` to reject actual duplicates.
- Both scripts support `-q`/`-qq` for quieter cron output; `-qq` suppresses
  even failure details (exit code still reflects failures).
- `cov_render_tiles.py`'s `LEAF_PROJECTS` dict currently only has one entry
  (`(TMA, F1/16)`, using `tma.qgs`) — add an entry + matching `.qgs` project
  file for each additional real (operator, reference) you want automated
  rendering for. `COMBINED_PROJECTS` is for layers that genuinely composite
  several operators (e.g. `all3600mhz`) — a layer that's just an alias for a
  single existing leaf (e.g. a second reference of an operator that already
  has one) needs neither: `api.layer_tileurl()` resolves it straight to that
  leaf's tiles automatically once the corresponding `cov_layer_source` row
  exists.
