# Coverage map - database

This repository contains the backend for the coverage map. The web page can
be found in a separate repository at
* [coverage-website](https://github.com/rtr-tkfreq/coverage-website)

## Components

* **PostgreSQL + PostGIS** — holds the coverage data (`cov_mno`: one row per
  operator/reference/rfc_date/raster cell) and the reference raster grid
  (`atraster`: the national 100m grid, `cov_mno.raster` joins against it to
  get a geometry).
* **`cov_layer` / `cov_layer_source` / `cov_layer_obligation`** — the map's
  layer catalog: which layers exist, how they're linked, what they're
  called. See "The layer catalog" below.
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
  project file per layer (e.g. `tma.qgs` for the `TMA` layer).
  `cov_render_tiles.py` drives it headlessly through `qgis_process`, so the
  rendered output matches what you'd get from QGIS Desktop's "Raster
  Tools → Generate XYZ Tiles (Directory)" — same algorithm, just scripted.
* **PostgREST** — exposes a REST API (schema `api`) over the database:
  `layers`, `layer_obligations`, `tileurl` (which tile set is current for a
  given layer), and the `cov()` lookup function the frontend uses for point
  queries.
* **nginx** — serves the rendered tiles as static files from
  `/var/www/tiles`, and reverse-proxies the PostgREST API and the basemap.at
  background map.

## The layer catalog

Every selectable thing on the map — a real operator's coverage, or a layer
combining several operators — is a row in `cov_layer`. There's no separate
concept for "real" vs. "combined": a combined layer is just a `cov_layer` row
that also has rows in `cov_layer_source` pointing at the layers it's built
from.

```sql
-- cov_layer: one row per selectable layer
 code  | reference | visible_name           | is_default | sort_order
-------+-----------+-------------------------+------------+------------
 @all  |           | @all                    | t          | 0
 TMA   | F1/16     | T-Mobile Austria GmbH   | f          | 1
 A1TA  | F1/16     | A1 Telekom Austria AG   | f          | 2
 H3A   | F1/16     | Hutchison Drei Austria  | f          | 3

-- cov_layer_source: which layers a combined layer is built from
 layer | source
-------+--------
 @all  | TMA
 @all  | A1TA
 @all  | H3A
```

A layer with no rows in `cov_layer_source` (as `layer`) is a leaf — rendered
directly from `cov_mno`. A layer that *does* have rows there is derived — its
QGIS project combines the listed layers instead of reading `cov_mno`
directly. Adding a new combined layer (e.g. a specific-reference combination
of three particular operators) is a few `INSERT`s, not a code change:

```sql
INSERT INTO cov_layer (code, reference, visible_name, is_default, sort_order)
  VALUES ('all3600mhz', 'F7/16', 'Alle 3600 MHz', false, 99);
INSERT INTO cov_layer_source (layer, source, reference)
  VALUES ('all3600mhz', 'A1TA', 'F7/16'), ('all3600mhz', 'TMA', 'F7/16'), ('all3600mhz', 'H3A', 'F7/16');
```

`cov_layer_source` is only consumed server-side, by `cov_render_tiles.py`
(see below) — it's not exposed via the `api` schema, since which layers
*depend* on which is a rendering-orchestration detail, not something the
frontend needs.

**Obligation overlays** (e.g. "which cadastral communities is this operator
obligated to cover, and by when") are a second kind of overlay, tracked in
`cov_layer_obligation` and exposed as `api.layer_obligations`:

```sql
-- cov_layer_obligation: one row per (layer, obligation type)
 layer | type      | label_de            | label_en               | source
-------+-----------+---------------------+-------------------------+---------------------------------
 TMA   | kg        | Katastralgemeinden  | Cadastral communities   | {/obligations/kg/TMA/2025-12-31}
 TMA   | roads_bl  | Straßen B/L         | Streets B/L             | {/obligations/roads_bl}
 @all  | kg        | Katastralgemeinden  | Cadastral communities   | {/obligations/kg/A1TA/..., /obligations/kg/H3A/..., /obligations/kg/TMA/...}
```

`source` holds XYZ tile directory paths, same shape as `tileurl.url` — an
obligation overlay is rendered and served exactly like a coverage layer, just
from a different docroot subtree. Two different things share this table:
operator-and-date-specific obligations (`kg`, one dated tile set per
operator, with `@all`'s row overlaying every operator's own tile set at
once), and static reference overlays with no operator- or date-specificity
at all (`roads_bl`/`cities`/`motorways`/`railways` — same `source` on every
layer's row; currently stored once per layer, matching how the old JSON
represented it, not deduplicated into a single shared row).

`label_de`/`label_en` are real backend-owned display text, not placeholders —
the frontend reads them directly (via Angular's `LOCALE_ID`, since this app
is compiled once per locale rather than switching language at runtime; see
`frqmap.component.ts`) instead of hardcoding its own translation per
obligation `type`, which is what it did before this change and which had
already drifted from the backend's actual wording in a few cases.

The frontend reads `api.layers` (ordered by `sort_order`) to build its
operator selector, and `api.layer_obligations` for the obligation overlay
dropdown and its labels — both flat, ordinary REST resources; no JSON blob to
parse, no `null` standing in for a magic string.

## How data flows from "operator publishes an update" to "map shows it"

1. `cov_download_mno.py` runs (scheduled, e.g. daily). For each operator it
   downloads the current CSV/ZIP, hashes it against every previous run
   directory, and keeps only files that are new or changed.
2. Anything kept gets imported into `cov_mno` via `COPY`, then geometry is
   backfilled from `atraster` by matching `cov_mno.raster`. If nothing was
   new, the run exits without touching the database at all.
3. `cov_render_tiles.py` runs on its own, independent schedule. It builds two
   kinds of render targets: leaves (`LEAF_PROJECTS`, one per real
   `(operator, reference)` pair, reading `cov_mno` directly) and combined
   layers (`COMBINED_PROJECTS`, one per `cov_layer` code that genuinely
   composites several operators, e.g. `all3600mhz` — its dependency graph
   comes from `cov_layer_source`). **The condition that triggers a render**:
   - for a **leaf**, it looks for the newest `rfc_date` in `cov_mno` for
     that operator/reference that does **not** already have a matching row
     in `tileurl`;
   - for a **combined** layer, it looks at whether any of its dependencies'
     latest `tileurl` date is newer than its own latest `tileurl` date; its
     rfc_date is the max across its dependencies.
   Either way, if there's nothing new, that target is skipped. A `cov_layer`
   selection that's just an alias for a single leaf (e.g. a second reference
   of an operator that already has one) needs neither kind of target at all
   — nothing to render, it reuses the leaf's own tiles (see step 5).
4. When there is unrendered data, it runs `qgis_process` headlessly against
   that target's project (whose SQL always selects `MAX(rfc_date)` itself,
   so no per-run file patching is needed), moves the tiles under
   `/var/www/tiles/cov/<OPERATOR-OR-CODE>/<REFERENCE>/<DATE>/`, and inserts
   the corresponding `tileurl` row.
5. From that point on, nginx serves the new tiles directly as static files.
   The frontend never queries `tileurl` by operator code directly — it calls
   `api.layer_tileurl(cov_layer)`, which resolves any selected layer to the
   right tiles: its own `tileurl` row if it has one (leaves and combined
   layers both do), or — for a pure alias with no render of its own —
   straight through to its single source's tiles via `cov_layer_source`. No
   further steps needed once a render completes.

Because leaf targets are always resolved before targets that depend on them,
and everything in `cov_render_tiles.py` runs strictly sequentially — by
design, never in parallel — a single run started after several operators
publish updates at once correctly renders each changed leaf and then
whatever combined layer depends on them, in one pass.

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

## Migrating an existing (pre-`cov_layer`) installation

Everything above describes the current setup. If you're bringing an
**existing** production database up to it — one still running the old
`setting_options`-JSON-blob approach — do this once, then delete this
section; it won't apply again.

1. Run **Part 1 + Part 2** of `postgresql/migrate_cov_layer.sql` against
   production. This is purely additive: it creates
   `cov_layer`/`cov_layer_source`/`cov_layer_obligation` and `api.layers`/
   `api.layer_obligations` alongside the existing tables, and populates them
   by reading `setting_options.filter` — translating the old `operator: null`
   sentinel to the explicit code `'@all'` (matching what `tileurl.operator`
   already used), and each operator's nested `obligations` into
   `cov_layer_obligation` including their `label_de`/`label_en` (handled
   defensively — a couple of rows in the source data have `label` wrapped in
   a stray one-element array instead of a plain object; the migration
   normalizes both shapes the same way). **It does not touch or drop
   `setting_options`/`api.settings`.** The old frontend keeps working exactly
   as before, unmodified and unaware any of this happened — it never queries
   `/api/layers`, and `/api/settings` isn't touched until Part 3. Safe to run
   this step with the old frontend still live in production.
   One caveat for the transition window: this is a one-time snapshot, not a
   sync — if `setting_options.filter` is edited after running Part 1+2 (e.g.
   an operator added by hand), that edit won't appear in `cov_layer`
   automatically. Make new edits against `cov_layer`/`cov_layer_source`/
   `cov_layer_obligation` directly once you've migrated, not the old table.
2. It also best-effort populates `cov_layer_source` for `@all`, assuming
   every real operator contributes (the old schema had no explicit record of
   this — it only lived in the undocumented `tileurl.in_all` flag). Check
   `SELECT * FROM cov_layer_source WHERE layer = '@all';` against whatever
   `tileurl.in_all` says on production and adjust if any operator should be
   excluded.
3. Deploy the coverage-website build that reads `/api/layers` and
   `/api/layer_obligations` instead of `/api/settings` (already the current
   state of that repo as of this change — no `operator: null` handling left,
   `Operator` was renamed `Layer` throughout `frqmap.component.ts`/`.html`/
   `models.ts`, and obligation labels now come from `label_de`/`label_en`
   instead of being hardcoded per `type`). **This step is the one that
   requires the migration to have already run** — the new frontend 404s
   against `/api/layers` if Part 1+2 hasn't been applied yet.
4. Update nginx: `/api/layers`, `/api/layer_obligations`,
   `/api/rpc/cov_layer`, and `/api/rpc/layer_tileurl` need their own
   `location` blocks (see `nginx/example.com` — they're new, added alongside
   this change).
   `/api/rpc/id` was also missing a block in the checked-in fragment despite
   the frontend already calling it; a block was added for it too — confirm
   whether production nginx already has it under config not reflected in
   this repo before assuming it was actually missing.
5. Once the new frontend is live and verified, run **Part 3** of
   `postgresql/migrate_cov_layer.sql` (commented out by default — run it by
   hand) to drop `setting_options`, `api.settings`, and
   `setting_options_uid_seq`. This is the one step that breaks the *old*
   frontend, so don't run it until nothing is still pointed at the old build.
6. Delete this section from the README.

### Verifying the migration: all endpoints

Every endpoint the site depends on, with example requests against
`frq.rtr.at`, so the migration can be checked endpoint-by-endpoint rather
than just "the page loads." **Existing** ones are untouched by this
migration (nothing here was modified); **new** ones only exist once
`migrate_cov_layer.sql` and the nginx update above have both been applied.

**Existing:**

```bash
# old settings blob — stays live until Part 3 drops it
curl 'https://frq.rtr.at/api/settings'

# tile layer list — unaffected by this migration
curl 'https://frq.rtr.at/api/tileurl'
curl 'https://frq.rtr.at/api/tileurl?operator=eq.TMA&order=date.desc&limit=1'

# old point-info (in_all-based), five overloads picked by which params are sent
curl 'https://frq.rtr.at/api/rpc/cov?cov_longitude=16.37&cov_latitude=48.20'
curl 'https://frq.rtr.at/api/rpc/cov?cov_longitude=16.37&cov_latitude=48.20&cov_operator=TMA&cov_reference=F1%2F16'

# geographic/administrative info for a point (used by the frontend already)
curl 'https://frq.rtr.at/api/rpc/id?cov_longitude=16.37&cov_latitude=48.20'

# 250m raster reverse lookup, not called by the frontend as far as known
curl 'https://frq.rtr.at/api/rpc/r250?cov_r250=<raster250-id>'

# tiles are static files, not PostgREST — '@' stripped, 'any' for no reference
curl -I 'https://frq.rtr.at/cov/TMA/F1_16/2026-06-21/4/8/5.png'
curl -I 'https://frq.rtr.at/cov/all/any/2026-06-21/4/8/5.png'
```

**New:**

```bash
# replaces /api/settings' operator list — flat, ordered
curl 'https://frq.rtr.at/api/layers?order=sort_order.asc'
# expect rows like: {"code":"TMA","reference":"F1/16","visible_name":"T-Mobile Austria GmbH","is_default":false,"sort_order":2}

# replaces /api/settings' nested obligations arrays
curl 'https://frq.rtr.at/api/layer_obligations'
curl 'https://frq.rtr.at/api/layer_obligations?layer=eq.TMA'
# expect rows like: {"layer":"TMA","type":"kg","label_de":"Katastralgemeinden","label_en":"Cadastral communities","source":["/obligations/kg/TMA/2025-12-31"]}

# replaces /api/rpc/cov for the frontend's point-info click — one function,
# works for any selected layer via cov_layer_source resolution
curl 'https://frq.rtr.at/api/rpc/cov_layer?cov_longitude=16.37&cov_latitude=48.20&cov_layer=%40all'   # %40 = '@'
curl 'https://frq.rtr.at/api/rpc/cov_layer?cov_longitude=16.37&cov_latitude=48.20&cov_layer=TMA'
curl 'https://frq.rtr.at/api/rpc/cov_layer?cov_longitude=16.37&cov_latitude=48.20&cov_layer=all3600mhz'

# replaces /api/tileurl?operator=eq... for the frontend's map overlay —
# resolves any selected layer to its own tiles if it has them, else falls
# through to its single source's tiles (a pure alias with no render of its own)
curl 'https://frq.rtr.at/api/rpc/layer_tileurl?cov_layer=TMA'
curl 'https://frq.rtr.at/api/rpc/layer_tileurl?cov_layer=all3600mhz'
# returns [] (empty array, not an error) if nothing has ever been rendered
# for that layer OR any of its sources yet — that's the "map doesn't
# update when I select this layer" symptom, and it's expected until a real
# render exists somewhere in the resolution chain
```

**Checklist after running the migration on production:**

1. `/api/layers?order=sort_order.asc` returns every real operator (not just
   what's in this repo's sample data), correct `is_default`, and `reference`
   set to F1/16 for A1TA/TMA/H3A and F7/16 for the rest — verify any operator
   not covered by that split explicitly.
2. `/api/layer_obligations` returns every obligation with a clean (not
   array-wrapped) `label_de`/`label_en`, including the A1TA/TMA `kg` rows
   that had the buggy shape in the source JSON.
3. `SELECT * FROM cov_layer_source WHERE layer = '@all' ORDER BY source;` —
   exactly the real operator list, each at its correct reference. Also check
   `SELECT * FROM cov_layer_source WHERE layer = source;` — every real
   operator should have a self-referencing row (layer=source=its own code);
   without one, plain single-operator selection returns no point-info at all
   (`api.cov_layer()` has no leaf/combined special case, it resolves purely
   through `cov_layer_source`).
4. `/api/rpc/cov_layer?...&cov_layer=%40all` at a point with known
   multi-operator coverage returns one row per operator, matching what
   `/api/rpc/cov` (old, no operator param) returns for the same point.
5. `/api/rpc/layer_tileurl?cov_layer=<code>` returns a non-empty array for
   every layer that has ever had a render — either its own or, for a pure
   alias, its single source's. An empty result for a layer you expect to
   have tiles means nothing has actually been rendered anywhere in its
   resolution chain yet — check `tileurl` directly for the relevant
   operator/reference before assuming the API is broken.
6. `/api/settings` and `/api/rpc/cov` (old ones) still work unchanged —
   confirms an old frontend, if still deployed anywhere, isn't broken.

## License

Copyright 2022 Rundfunk und Telekom Regulierungs-GmbH (RTR-GmbH). This source code is licensed under the Apache license found in the LICENSE.txt file. The documentation to the project is licensed under the CC BY 4.0 license.
Trademarks and logos of RTR, TKK,  and PCK are not part of this license.
