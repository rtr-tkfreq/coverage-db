-- Adds an optional cov_date parameter to api.cov_layer() so a point clicked
-- while the frontend's date selector (see api.layer_tileurl /
-- migrate_layer_tileurl_all_dates.sql) has an older date selected shows
-- that same date's coverage data, instead of always today's true latest
-- regardless of what's actually displayed on the map. Omitting cov_date (or
-- passing NULL) keeps the old behavior exactly, so this is backwards
-- compatible with any caller that doesn't pass it. Matches
-- postgresql/frq_scheme.sql (which already has the current version — a
-- fresh install never needs this file). Safe to run any number of times.
--
-- Adding a parameter makes this a distinct function signature as far as
-- Postgres overload resolution is concerned — CREATE OR REPLACE FUNCTION
-- would not replace the existing 3-argument version, it would add a second
-- overload alongside it, and PostgREST would then see two candidates for a
-- 3-argument call and fail with "function is not unique". The old signature
-- must be dropped first.

DROP FUNCTION IF EXISTS api.cov_layer(double precision, double precision, character varying);

CREATE OR REPLACE FUNCTION api.cov_layer(cov_longitude double precision, cov_latitude double precision, cov_layer character varying, cov_date date DEFAULT NULL) RETURNS TABLE(operator character varying, reference character varying, license character varying, last_updated character varying, raster character varying, technology character varying, downloadkbitmax integer, uploadkbitmax integer, downloadkbitnormal integer, uploadkbitnormal integer, geojson text, centroid_x double precision, centroid_y double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
   RETURN QUERY
   WITH resolved AS (
       SELECT cls.source AS operator, cls.reference AS reference
         FROM cov_layer_source cls WHERE cls.layer = cov_layer
   ),
   current_tileurl AS (
       -- Per (operator, reference): the latest date at or before cov_date,
       -- or the true latest if cov_date is NULL.
       SELECT DISTINCT ON (tu.operator, tu.reference)
              tu.operator, tu.reference, tu.date
         FROM api.tileurl tu
        WHERE cov_date IS NULL OR tu.date <= cov_date
        ORDER BY tu.operator, tu.reference, tu.date DESC
   )
   SELECT
          m.operator::VARCHAR,
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
    WHERE ST_intersects((ST_Transform(ST_SetSRID(ST_MakePoint(cov_longitude::FLOAT, cov_latitude::FLOAT), 4326), 3857)), m.geom)
    ORDER BY m.dl_normal DESC;
END;
$_$;

GRANT EXECUTE ON FUNCTION api.cov_layer(double precision, double precision, character varying, date) TO web_anon;
