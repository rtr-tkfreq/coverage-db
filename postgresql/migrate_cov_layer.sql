-- Fixes api.cov_layer() on an existing installation that still has the
-- pre-"TMA 3600 MHz redesign" version of the function (with a leaf/combined
-- fallback branch). That version is dormant rather than actively wrong as
-- long as every cov_layer row has a matching cov_layer_source row (see
-- README.md's "The layer catalog"), but it's fragile: a new layer added
-- without its cov_layer_source row would silently fall back to the old,
-- incorrect assumption that cov_layer.reference is the operator's only
-- reference. This makes api.cov_layer() resolve purely via
-- cov_layer_source, with no fallback, matching postgresql/frq_scheme.sql
-- (which already has the current version — a fresh install never needs
-- this file). Safe to run any number of times.

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
