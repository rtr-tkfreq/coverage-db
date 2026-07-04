-- Makes api.layer_tileurl() return every published date for a layer,
-- newest first, instead of only the single latest one — tileurl
-- accumulates one row per date a target has ever been rendered for (old
-- dates' tiles are never deleted), so the frontend can now offer a date
-- selector when more than one is available. Matches
-- postgresql/frq_scheme.sql (which already has the current version — a
-- fresh install never needs this file). Safe to run any number of times.
--
-- The frontend still defaults to the first (newest) row, so this is
-- backwards compatible with any client that only ever reads index 0.

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
    ORDER BY date DESC;
$$;
