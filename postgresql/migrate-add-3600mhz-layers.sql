-- Adds A1TA/TMA/H3A's F7/16 band as its own independently selectable layer
-- each (distinct from their existing F1/16 listings, and from the
-- 3-operator "all3600mhz" combo). Pure aliases: no render of their own —
-- api.layer_tileurl() resolves them straight to the (A1TA|TMA|H3A, F7/16)
-- leaf renders once cov_render_tiles.py has published those (see
-- LEAF_PROJECTS in cov_render_tiles.py). Safe to re-run.

INSERT INTO cov_layer (code, reference, visible_name, is_default, sort_order) VALUES
    ('a1ta3600mhz', 'F7/16', 'A1 Telekom Austria AG 3600 MHz', false, 10),
    ('tma3600mhz',  'F7/16', 'T-Mobile Austria GmbH 3600 MHz', false, 11),
    ('h3a3600mhz',  'F7/16', 'Hutchison Drei Austria GmbH 3600 MHz', false, 12)
ON CONFLICT (code) DO NOTHING;

INSERT INTO cov_layer_source (layer, source, reference) VALUES
    ('a1ta3600mhz', 'A1TA', 'F7/16'),
    ('tma3600mhz',  'TMA',  'F7/16'),
    ('h3a3600mhz',  'H3A',  'F7/16')
ON CONFLICT DO NOTHING;
