-- Seeds the cov_layer / cov_layer_source catalog with the current real
-- production layer set: 7 operators (A1TA/TMA/H3A on F1/16,
-- LIWEST/SBG/MASS/HGRAZ on F7/16), the "all operators" combined layer, the
-- 3-operator "3600 MHz" combo (A1TA+TMA+H3A on F7/16), and each of those
-- three's F7/16 band as its own independently selectable layer. Run once
-- against a fresh install (see INSTALL.md step 5 / ansible's
-- cov_init_schema). Idempotent — safe to re-run.
--
-- Rendering all3600mhz/a1ta3600mhz/tma3600mhz/h3a3600mhz needs their QGIS
-- project templates deployed too (see INSTALL.md step 7) and
-- cov_render_tiles.py's LEAF_PROJECTS/COMBINED_PROJECTS to know about them
-- — already the case in the current version of this repo.

INSERT INTO cov_layer (code, reference, visible_name, is_default, sort_order) VALUES
  ('@all',   NULL,    '@all',                                                     true,  0),
  ('TMA',    'F1/16', 'T-Mobile Austria GmbH',                                    false, 1),
  ('A1TA',   'F1/16', 'A1 Telekom Austria AG',                                    false, 2),
  ('H3A',    'F1/16', 'Hutchison Drei Austria GmbH',                              false, 3),
  ('LIWEST', 'F7/16', 'LIWEST Kabelmedien GmbH',                                  false, 4),
  ('SBG',    'F7/16', 'Salzburg AG für Energie, Verkehr und Telekommunikation',   false, 5),
  ('MASS',   'F7/16', 'Mass Response Service GmbH',                               false, 6),
  ('HGRAZ',  'F7/16', 'Holding Graz - Kommunale Dienstleistungen GmbH',           false, 7),
  ('all3600mhz',  'F7/16', 'Alle 3600 MHz',                                       false, 99),
  ('a1ta3600mhz', 'F7/16', 'A1 Telekom Austria AG 3600 MHz',                      false, 10),
  ('tma3600mhz',  'F7/16', 'T-Mobile Austria GmbH 3600 MHz',                      false, 11),
  ('h3a3600mhz',  'F7/16', 'Hutchison Drei Austria GmbH 3600 MHz',                false, 12)
ON CONFLICT (code) DO NOTHING;

-- Every layer resolves purely through cov_layer_source (see README.md's
-- "The layer catalog") — a plain operator needs a self-referencing row,
-- '@all' needs one row per operator at that operator's own reference, and
-- the "...3600mhz" layers point at specific (operator, F7/16) leaves
-- regardless of that operator's own reference.
INSERT INTO cov_layer_source (layer, source, reference) VALUES
  ('TMA', 'TMA', 'F1/16'), ('A1TA', 'A1TA', 'F1/16'), ('H3A', 'H3A', 'F1/16'),
  ('LIWEST', 'LIWEST', 'F7/16'), ('SBG', 'SBG', 'F7/16'), ('MASS', 'MASS', 'F7/16'), ('HGRAZ', 'HGRAZ', 'F7/16'),
  ('@all', 'TMA', 'F1/16'), ('@all', 'A1TA', 'F1/16'), ('@all', 'H3A', 'F1/16'),
  ('@all', 'LIWEST', 'F7/16'), ('@all', 'SBG', 'F7/16'), ('@all', 'MASS', 'F7/16'), ('@all', 'HGRAZ', 'F7/16'),
  ('all3600mhz', 'A1TA', 'F7/16'), ('all3600mhz', 'TMA', 'F7/16'), ('all3600mhz', 'H3A', 'F7/16'),
  ('a1ta3600mhz', 'A1TA', 'F7/16'),
  ('tma3600mhz', 'TMA', 'F7/16'),
  ('h3a3600mhz', 'H3A', 'F7/16')
ON CONFLICT DO NOTHING;
