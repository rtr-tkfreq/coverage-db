# Coverage map - database

This repository contains the backend for the coverage map. The web page can
be found in a separate repository at
* [coverage-website](https://github.com/rtr-tkfreq/coverage-website)

## Components

* **PostgreSQL + PostGIS** — holds the coverage data (`cov_mno`: one row per
  operator/reference/rfc_date/raster cell) and the reference raster grid
  (`atraster`: the national 100m grid, `cov_mno.raster` joins against it to
  get a geometry).
* **`cov_download_mno.py`** (`scripts/import-opendata/`) — downloads each
  operator's open-data CSV, compares it against previous runs, discards
  anything unchanged (operators publish updates roughly every 3 months, so
  most runs see nothing new), and imports what's left into `cov_mno`. Runs in
  minutes.
* **`cov_render_tiles.py`** (`scripts/import-opendata/`) — turns new
  `cov_mno` data into map tiles: renders XYZ tiles via headless QGIS, moves
  them into the tile docroot, and registers the result in `tileurl`. Can run
  for **hours** for a full-country render, which is why it's a separate job
  from the download/import step rather than a step chained onto it.
* **QGIS** — owns the actual cartography (color ramps, symbology) via a
  project file per operator/reference (e.g. `tma.qgs` for TMA F1/16).
  `cov_render_tiles.py` drives it headlessly through `qgis_process`, so the
  rendered output matches what you'd get from QGIS Desktop's "Raster
  Tools → Generate XYZ Tiles (Directory)" — same algorithm, just scripted.
* **PostgREST** — exposes a REST API (schema `api`) over the database:
  `settings`, `tileurl` (which tile set is current for a given
  operator/reference), and the `cov()` lookup function the frontend uses for
  point queries.
* **nginx** — serves the rendered tiles as static files from
  `/var/www/tiles`, and reverse-proxies the PostgREST API and the basemap.at
  background map.

## How data flows from "operator publishes an update" to "map shows it"

1. `cov_download_mno.py` runs (scheduled, e.g. daily). For each operator it
   downloads the current CSV/ZIP, hashes it against every previous run
   directory, and keeps only files that are new or changed.
2. Anything kept gets imported into `cov_mno` via `COPY`, then geometry is
   backfilled from `atraster` by matching `cov_mno.raster`. If nothing was
   new, the run exits without touching the database at all.
3. `cov_render_tiles.py` runs on its own, independent schedule. **The
   condition that triggers a render**: for each configured
   (operator, reference) pair, it looks for the newest `rfc_date` in
   `cov_mno` that does **not** already have a matching row in `tileurl`. If
   every known `rfc_date` already has a `tileurl` entry, that
   operator/reference is skipped — nothing to do.
4. When there is an unrendered date, it patches that operator's QGIS project
   with the right `rfc_date` filter, runs `qgis_process` headlessly to
   produce XYZ tiles, moves them under `/var/www/tiles/cov/<OPERATOR>/<REFERENCE>/<DATE>/`,
   and inserts the corresponding `tileurl` row.
5. From that point on, nginx serves the new tiles directly as static files,
   and PostgREST's `/tileurl` endpoint immediately reflects the new date —
   the frontend picks it up on its next request, no further steps needed.

## Full automation

Both scripts are self-contained and idempotent, so end-to-end automation is
just running each on its own systemd timer:

* a **download timer** (e.g. daily) runs `cov_download_mno.py -q` — cheap to
  run often, since it does nothing when there's no new data;
* a **render timer** (e.g. also daily, offset by an hour) runs
  `cov_render_tiles.py -q` — safe to run on a fixed schedule even though a
  render can take hours, because it takes a lock file and simply skips a run
  that would overlap with one still in progress.

No manual trigger, no coordination between the two jobs is required — the
render job's "is there unrendered data" check *is* the hand-off between them.
Both are also runnable by hand at any time (e.g. `./cov_download_mno.py`,
`./cov_render_tiles.py`) for one-off imports or re-renders.

See `ansible/playbook.yml` for the exact systemd unit definitions this sets up.

## Installation

Two ways to get a host into this state — same end result, pick one:

* **Ansible** (recommended for repeat/reproducible deployments): run
  `ansible-playbook -i ansible/inventory.ini ansible/playbook.yml`. Installs
  PostgreSQL+PostGIS, QGIS, nginx, PostgREST, deploys the scripts and QGIS
  project templates, and sets up the systemd timers described above. Add
  `-e cov_init_schema=true` on a fresh host to also create the database,
  roles and schema (left opt-in since it would be destructive on an existing
  one).
* **Manual**: see [INSTALL.md](INSTALL.md) for the equivalent steps done by
  hand, including a couple of environment-specific gotchas found while
  setting this up (e.g. QGIS needing `QT_QPA_PLATFORM=offscreen` when
  headless, and a schema drift in the Statistik Austria raster download).

Either way, populating `atraster` (the national raster grid) is a manual,
one-time step in both paths — it uses `shp2pgsql -d`, which drops and
recreates the table, so it's deliberately not something either the Ansible
playbook or a systemd timer does automatically against a live database.

## License

Copyright 2022 Rundfunk und Telekom Regulierungs-GmbH (RTR-GmbH). This source code is licensed under the Apache license found in the LICENSE.txt file. The documentation to the project is licensed under the CC BY 4.0 license.
Trademarks and logos of RTR, TKK,  and PCK are not part of this license.
