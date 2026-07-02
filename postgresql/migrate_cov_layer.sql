-- Migrates setting_options.filter (the JSON blob the frontend's operator
-- selector used to read) into the cov_layer / cov_layer_source /
-- cov_layer_obligation tables. Run by hand against production, in order:
--
--   1. Run Part 1 + Part 2 below.
--   2. Verify: SELECT * FROM cov_layer ORDER BY sort_order;
--      and check cov_layer_source / cov_layer_obligation look right.
--   3. Deploy the coverage-website change that reads /api/layers +
--      /api/layer_obligations instead of /api/settings.
--   4. Once the new frontend is live and confirmed working, run Part 3 to
--      drop the old table/view. Not before — old and new frontends can run
--      against this DB at the same time during rollout, but only if Part 3
--      hasn't run yet.
--
-- Idempotent: safe to re-run Part 1 + Part 2 (uses IF NOT EXISTS / ON
-- CONFLICT throughout).

-- ============================================================
-- Part 1: create the new tables/views (skip if already applied
-- via a fresh frq_scheme.sql load)
-- ============================================================

CREATE TABLE IF NOT EXISTS cov_layer (
    code character varying NOT NULL PRIMARY KEY,
    reference character varying,
    visible_name character varying NOT NULL,
    is_default boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0
);

-- reference is independent of source's own cov_layer.reference: a combined
-- layer can depend on a *different* reference of an operator than that
-- operator's own standalone listing uses (e.g. A1TA's own layer is F1/16,
-- but a combined F7/16 layer depending on A1TA needs A1TA's F7/16 data).
CREATE TABLE IF NOT EXISTS cov_layer_source (
    layer character varying NOT NULL REFERENCES cov_layer(code),
    source character varying NOT NULL REFERENCES cov_layer(code),
    reference character varying NOT NULL,
    PRIMARY KEY (layer, source, reference)
);

CREATE TABLE IF NOT EXISTS cov_layer_obligation (
    layer character varying NOT NULL REFERENCES cov_layer(code),
    type character varying NOT NULL,
    label_de character varying NOT NULL,
    label_en character varying NOT NULL,
    source character varying[] NOT NULL,
    PRIMARY KEY (layer, type)
);

CREATE OR REPLACE VIEW api.layers AS
 SELECT code, reference, visible_name, is_default, sort_order FROM cov_layer;

CREATE OR REPLACE VIEW api.layer_obligations AS
 SELECT layer, type, label_de, label_en, source FROM cov_layer_obligation;

GRANT SELECT ON TABLE api.layers TO web_anon;
GRANT SELECT ON TABLE api.layer_obligations TO web_anon;

-- Point-info lookup for a selected layer — resolves purely via
-- cov_layer_source, no special-casing for "leaf vs combined": every
-- selectable cov_layer row, including a plain single-operator one like
-- 'TMA', has its own cov_layer_source row(s) pointing at the actual
-- (operator, reference) it reads from cov_mno. This is what lets a second
-- reference of the same operator (e.g. TMA's F7/16) become its own
-- independently selectable layer with a distinct code — there is no longer
-- an assumption that cov_layer.code equals cov_mno.operator. Additive:
-- production's existing api.cov(...) overloads (which use in_all) are
-- untouched, so nothing currently depending on them breaks.
--
-- cov_mno is never pruned — it accumulates every historical rfc_date an
-- operator has ever published for a raster cell, not just the current one.
-- current_tileurl pins each (operator, reference) to its most recently
-- published date (from tileurl, which is similarly append-only) so this
-- only ever returns the data matching what's currently rendered as a tile
-- overlay, not the full history.
CREATE OR REPLACE FUNCTION api.cov_layer(cov_longitude double precision, cov_latitude double precision, cov_layer character varying) RETURNS TABLE(operator character varying, reference character varying, license character varying, last_updated character varying, raster character varying, technology character varying, downloadkbitmax integer, uploadkbitmax integer, downloadkbitnormal integer, uploadkbitnormal integer, geojson text, centroid_x double precision, centroid_y double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
   RETURN QUERY
   WITH resolved AS (
       SELECT cls.source AS operator, cls.reference AS reference
         FROM cov_layer_source cls WHERE cls.layer = cov_layer
   ),
   current_tileurl AS (
       -- api.tileurl (the view), not the base table: views run with their
       -- owner's privileges, so this needs no extra grant to web_anon —
       -- same trick production's existing api.cov() overloads already use.
       SELECT tu.operator, tu.reference, max(tu.date) AS date
         FROM api.tileurl tu
        GROUP BY tu.operator, tu.reference
   )
   SELECT
          coalesce(vn.visible_name, m.operator)::VARCHAR AS operator,
          m.reference::VARCHAR,
          m.license::VARCHAR,
          m.rfc_date::VARCHAR AS last_updated,
          m.raster::VARCHAR,
          NULL::VARCHAR AS technology,
          round(m.dl_max / 1000)::integer AS downloadKbitMax,
          round(m.ul_max / 1000)::integer AS uploadKbitMax,
          round(m.dl_normal / 1000)::integer AS downloadKbitNormal,
          round(m.ul_normal / 1000)::integer AS uploadKbitNormal,
          ST_AsGeoJSON(ST_Transform(m.geom, 4326)) AS geoJson,
          ST_X(ST_Centroid(ST_Transform(m.geom, 4326))),
          ST_Y(ST_Centroid(ST_Transform(m.geom, 4326)))
     FROM cov_mno m
     JOIN resolved r ON r.operator = m.operator AND r.reference = m.reference
     JOIN current_tileurl t ON t.operator = m.operator AND t.reference = m.reference AND t.date = m.rfc_date::date
     LEFT JOIN cov_visible_name vn ON vn.operator = m.operator
    WHERE ST_intersects((ST_Transform(ST_SetSRID(ST_MakePoint(cov_longitude::FLOAT, cov_latitude::FLOAT), 4326), 3857)), m.geom)
    ORDER BY m.dl_normal DESC;
END;
$_$;

GRANT EXECUTE ON FUNCTION api.cov_layer(double precision, double precision, character varying) TO web_anon;

-- Tile-overlay lookup for a selected layer, replacing the frontend's old
-- `tileurl?operator=eq.<code>` REST filter (which only works when the
-- layer's code IS the tileurl.operator, no longer a safe assumption).
-- Two cases, picked automatically by whether the layer has its own
-- published tiles:
--   1. The layer has its own tileurl row(s) (a real render under its own
--      code — every multi-source combined layer works this way, e.g.
--      '@all'/'all3600mhz', since compositing several operators' coverage
--      needs its own cartography, not just a pointer to one of them).
--   2. It doesn't — meaning it's a pure alias for a single underlying
--      (operator, reference), like a hypothetical "TMA 3600 MHz" pointing
--      at TMA's F7/16 data: no separate render exists or is needed, this
--      just resolves straight to that source's own tiles via
--      cov_layer_source.
-- Plain SQL function (not needed as plpgsql — single query, STABLE):
-- UNION ALL with the second branch gated on NOT EXISTS so the two cases
-- never both contribute rows.
CREATE OR REPLACE FUNCTION api.layer_tileurl(cov_layer character varying) RETURNS TABLE(operator character varying, reference character varying, date date, url character varying)
    LANGUAGE sql STABLE
    AS $$
    SELECT operator, reference, date, url FROM api.tileurl WHERE operator = cov_layer
    UNION ALL
    SELECT t.operator, t.reference, t.date, t.url
      FROM cov_layer_source cls
      JOIN api.tileurl t ON t.operator = cls.source AND t.reference = cls.reference
     WHERE cls.layer = cov_layer
       AND NOT EXISTS (SELECT 1 FROM api.tileurl WHERE operator = cov_layer)
    ORDER BY date DESC
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION api.layer_tileurl(character varying) TO web_anon;

-- Plain PL/pgSQL functions run as INVOKER by default (unlike views, which
-- run as their owner) — the function body above queries these public-schema
-- tables directly, so web_anon needs SELECT on them too, or every call
-- fails with "permission denied for table cov_layer_source" regardless of
-- the EXECUTE grant. Doesn't expose them as REST resources — PostgREST only
-- serves the `api` schema (db-schema=api), so this just lets the function
-- read them on the caller's behalf.
GRANT SELECT ON TABLE cov_layer TO web_anon;
GRANT SELECT ON TABLE cov_layer_source TO web_anon;

-- qgis needs full CRUD on the layer catalog too — same treatment as
-- setting_options/tileurl already have in production: QGIS Desktop is used
-- directly to add/edit cov_layer(_source) rows, and a combined layer's
-- QGIS project SQL can query cov_layer_source itself to know which
-- operators to include (self-updating, same pattern tma.qgs already uses
-- for rfc_date).
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE cov_layer TO qgis;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE cov_layer_source TO qgis;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE cov_layer_obligation TO qgis;

-- ============================================================
-- Part 2: migrate data out of setting_options.filter (uid = 1,
-- matching what api.settings always selected)
-- ============================================================

-- One row per operator entry. `operator: null` (the old "all operators"
-- sentinel) becomes the explicit code '@all', matching what tileurl.operator
-- already uses for that layer. Array position becomes sort_order, so the
-- dropdown order is preserved.
--
-- reference: setting_options never recorded which reference is an
-- operator's own canonical one, so this is hardcoded from what was
-- confirmed directly: A1TA/TMA/H3A publish F1/16 as their primary
-- reference, every other operator (LIWEST/SBG/MASS/HGRAZ as of this
-- writing) publishes F7/16 as theirs. If a new operator is added later that
-- doesn't fit this split, adjust the CASE below (or UPDATE cov_layer by
-- hand) before relying on it.
INSERT INTO cov_layer (code, reference, visible_name, is_default, sort_order)
SELECT
    coalesce(op->>'operator', '@all'),
    CASE
        WHEN op->>'operator' IS NULL THEN NULL  -- '@all' spans multiple references
        WHEN op->>'operator' IN ('A1TA', 'TMA', 'H3A') THEN 'F1/16'
        ELSE 'F7/16'
    END,
    op->>'label',
    coalesce((op->>'default')::boolean, false),
    (ord - 1)::integer
FROM setting_options,
     jsonb_array_elements(filter->'operators') WITH ORDINALITY AS t(op, ord)
WHERE uid = 1
ON CONFLICT (code) DO UPDATE
    SET reference = EXCLUDED.reference,
        visible_name = EXCLUDED.visible_name,
        is_default = EXCLUDED.is_default,
        sort_order = EXCLUDED.sort_order;

-- Every real (non-'@all') operator gets a self-referencing cov_layer_source
-- row: layer=code, source=code, at its own canonical reference. This is
-- what api.cov_layer() needs now that it has no leaf/combined special case
-- — a plain single-operator selection like 'TMA' resolves through
-- cov_layer_source exactly like a combined layer does, just with one row
-- pointing at itself. Without this, plain operator selection would return
-- no point-info at all.
INSERT INTO cov_layer_source (layer, source, reference)
SELECT op->>'operator', op->>'operator',
       CASE WHEN op->>'operator' IN ('A1TA', 'TMA', 'H3A') THEN 'F1/16' ELSE 'F7/16' END
FROM setting_options, jsonb_array_elements(filter->'operators') AS op
WHERE uid = 1 AND op->>'operator' IS NOT NULL
ON CONFLICT DO NOTHING;

-- Each operator's nested `obligations` array (if any) becomes rows here.
-- obl->'label' is normally a plain {de_DE, en_US} object, but at least two
-- rows in production (A1TA's and TMA's "kg" obligation) have it wrapped in a
-- one-element array instead — a pre-existing data bug, not something this
-- migration introduces. Handled defensively via jsonb_typeof so either shape
-- migrates correctly instead of silently producing a null label.
INSERT INTO cov_layer_obligation (layer, type, label_de, label_en, source)
SELECT
    coalesce(op->>'operator', '@all'),
    obl->>'type',
    CASE jsonb_typeof(obl->'label')
        WHEN 'array' THEN obl->'label'->0->>'de_DE'
        ELSE obl->'label'->>'de_DE'
    END,
    CASE jsonb_typeof(obl->'label')
        WHEN 'array' THEN obl->'label'->0->>'en_US'
        ELSE obl->'label'->>'en_US'
    END,
    ARRAY(SELECT jsonb_array_elements_text(obl->'source'))
FROM setting_options,
     jsonb_array_elements(filter->'operators') AS op,
     jsonb_array_elements(op->'obligations') AS obl
WHERE uid = 1 AND op ? 'obligations'
ON CONFLICT (layer, type) DO UPDATE
    SET label_de = EXCLUDED.label_de, label_en = EXCLUDED.label_en, source = EXCLUDED.source;

-- '@all' combines every real operator at *its own* canonical reference
-- (the CASE above) — i.e. exactly what api.cov_layer() needs to reproduce
-- "point info from all operators" as the default view. Sourced directly
-- from setting_options' operator list (not "every code currently in
-- cov_layer except @all") so re-running this script after all3600mhz (or
-- any other combined layer) already exists doesn't pull it into @all's own
-- dependency list.
INSERT INTO cov_layer_source (layer, source, reference)
SELECT '@all', op->>'operator',
       CASE WHEN op->>'operator' IN ('A1TA', 'TMA', 'H3A') THEN 'F1/16' ELSE 'F7/16' END
FROM setting_options, jsonb_array_elements(filter->'operators') AS op
WHERE uid = 1 AND op->>'operator' IS NOT NULL
ON CONFLICT DO NOTHING;

-- The F7/16 combination of A1TA+TMA+H3A ("3600 MHz") is a second,
-- independently selectable layer — distinct from those operators' own
-- (F1/16) listings. Didn't exist anywhere in the old data model, so
-- there's nothing to migrate it from.
INSERT INTO cov_layer (code, reference, visible_name, is_default, sort_order)
    VALUES ('all3600mhz', 'F7/16', 'Alle 3600 MHz', false, 99)
    ON CONFLICT (code) DO NOTHING;
INSERT INTO cov_layer_source (layer, source, reference)
    VALUES ('all3600mhz', 'A1TA', 'F7/16'), ('all3600mhz', 'TMA', 'F7/16'), ('all3600mhz', 'H3A', 'F7/16')
    ON CONFLICT DO NOTHING;

-- Rendering this layer needs its own QGIS project (querying cov_mno for
-- A1TA/TMA/H3A's F7/16 rows) and a PROJECT_PATHS entry in
-- cov_render_tiles.py — not something this migration can create.

-- ============================================================
-- Part 3: DROP THE OLD TABLE — only after the new frontend is deployed
-- and verified. Commented out on purpose; uncomment and run by hand.
-- ============================================================

-- DROP VIEW IF EXISTS api.settings;
-- DROP TABLE IF EXISTS setting_options;
-- DROP SEQUENCE IF EXISTS setting_options_uid_seq;
