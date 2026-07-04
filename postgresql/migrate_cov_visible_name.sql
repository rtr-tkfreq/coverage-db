-- Stops api.cov_layer() from resolving its operator field through
-- cov_visible_name. That table is still populated on production, but the
-- frontend no longer trusts api.cov_layer()'s operator field as a display
-- name directly — it looks it up against cov_layer.code to get cov_layer's
-- own visible_name instead (see getOperatorByLabel() in
-- coverage-website/src/app/frqmap/frqmap.component.ts). Since
-- cov_visible_name.visible_name is a human-readable string, not a
-- cov_layer.code, coalescing through it made that lookup fail — silently
-- rendering a blank operator name in the point-info panel — for every
-- operator that has a cov_visible_name row. Matches postgresql/frq_scheme.sql
-- (which already has the current version — a fresh install never needs this
-- file). Safe to run any number of times.
--
-- Deliberately does NOT touch the cov_visible_name table itself: its
-- visible_name_long column is still used by api.id() (production-only, not
-- part of this repo — see the comment on cov_visible_name in frq_scheme.sql),
-- so the table stays. Only the now-unused visible_name column's read site is
-- being removed, not the column or table.

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
       SELECT tu.operator, tu.reference, max(tu.date) AS date
         FROM api.tileurl tu
        GROUP BY tu.operator, tu.reference
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
