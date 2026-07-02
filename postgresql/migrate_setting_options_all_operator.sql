-- One-off cleanup for setting_options.filter, run by hand against production
-- (not wired into cov_download_mno.py/cov_render_tiles.py or Ansible, since
-- it's a one-time content fix, not schema). Idempotent: safe to re-run.
--
-- Two independent problems this fixes:
--
-- 1. `filter.operators[].operator` uses JSON `null` to mean "all operators",
--    while `tileurl.operator` for that same combined layer is the literal
--    string '@all'. The frontend bridges this mismatch with `?? '@all'`
--    fallbacks scattered across ~4 places, and a second combined operator
--    (e.g. the F7/16 combination of A1TA+TMA+H3A) can't be added the same
--    way `null` can only ever mean one thing. This rewrites `operator: null`
--    to `operator: '@all'`, matching tileurl and making every operator entry
--    (real or combined) the same shape.
--
-- 2. `filter.bands` and `filter.timeline` are dead weight: nothing in the
--    coverage-website frontend reads them (the original "select map by
--    date" feature was never finished). Dropped here to stop them looking
--    like they do something.
--
-- After running this, the corresponding coverage-website change (already
-- applied in that repo) expects Operator.operator to always be a non-null
-- string — deploy both together.

UPDATE setting_options
SET filter = (filter - 'bands' - 'timeline')
              || jsonb_build_object(
                   'operators',
                   (
                     SELECT jsonb_agg(
                       CASE WHEN op->'operator' = 'null'::jsonb
                            THEN op || jsonb_build_object('operator', '@all')
                            ELSE op
                       END
                     )
                     FROM jsonb_array_elements(filter->'operators') AS op
                   )
                 )
WHERE filter ? 'operators';
