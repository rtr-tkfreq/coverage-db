#!/usr/bin/env python3
# *******************************************************************************
# * Copyright 2021-2026 Rundfunk und Telekom Regulierungs-GmbH (RTR-GmbH)
# *
# * Licensed under the Apache License, Version 2.0 (the "License");
# * you may not use this file except in compliance with the License.
# * You may obtain a copy of the License at
# *
# *   http://www.apache.org/licenses/LICENSE-2.0
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
# ******************************************************************************/
"""Render coverage tiles from cov_mno via QGIS and publish them.

For each configured (operator, reference) pair with a QGIS project template,
finds the latest rfc_date in cov_mno that doesn't yet have a `tileurl` entry,
renders XYZ tiles headlessly via `qgis_process`, moves them under the tile
docroot, and registers a new `tileurl` row so the frontend can find them.
Each project's SQL selects `rfc_date = (SELECT MAX(rfc_date) FROM ...)`
itself, so the project always reflects current data — nothing here patches
the project file before rendering.

There are two kinds of targets. A LEAF_PROJECTS entry renders one real
(operator, reference) pair directly from cov_mno — its identity is that pair,
not any particular cov_layer row (a `cov_layer` selection is just an alias
over one or more of these; see below). A COMBINED_PROJECTS entry instead
combines several leaves (e.g. "all operators" or "F7/16 from A1TA+TMA+H3A")
per its cov_layer_source rows, and is identified by its own cov_layer code,
since it publishes its own tileurl row under that code. Which layers exist
and which combine which is owned by the database (`cov_layer`/
`cov_layer_source` — see postgresql/frq_scheme.sql), not by this script:
LEAF_PROJECTS/COMBINED_PROJECTS below only map to *where a project file is
on this host*, a server-local detail that has no business being public API
data. `build_targets()` joins these with the DB at run time.

Selecting a single reference of an operator that already has another
reference under the same code (e.g. adding "TMA 3600 MHz" alongside TMA's
existing F1/16 listing) needs no combined target at all — it's a plain
LEAF_PROJECTS entry for (TMA, F7/16), plus a cov_layer_source row aliasing
a new cov_layer code to it (see api.layer_tileurl() in postgresql/frq_scheme.sql,
which resolves such aliases straight to the leaf's own tiles instead of
expecting a separate render).

A combined target's "is there new data" check looks at whether any
dependency has a newer rendered date than the combined target's own latest
`tileurl` row, and its rfc_date is the max of its dependencies' dates. Leaf
targets are always processed before targets that depend on them (see
`build_targets()`), and everything runs strictly sequentially (see
`main()`) — never in parallel.

Rendering the whole country at zoom 4-14 can take HOURS. This is deliberately
a separate script from cov_download_mno.py (which only takes minutes) so it
can run on its own, longer cron/systemd cadence without blocking imports.
Only one instance is allowed to run at a time (flock on a lockfile) since a
render can easily still be in progress when the next scheduled run fires.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

DB_NAME = "frq"
PROJECT_DIR = Path(__file__).resolve().parent
LOCK_FILE = Path("/tmp/cov_render_tiles.lock")

# Rendering parameters (override via env for testing without touching the code)
TILE_DOCROOT = Path(os.environ.get("COV_TILE_DOCROOT", "/var/www/tiles/cov"))
EXTENT = os.environ.get("COV_TILE_EXTENT", "977649.9582,1948091.0889,5838029.9512,6281289.9249[EPSG:3857]")
ZOOM_MIN = os.environ.get("COV_TILE_ZOOM_MIN", "4")
ZOOM_MAX = os.environ.get("COV_TILE_ZOOM_MAX", "14")
DPI = os.environ.get("COV_TILE_DPI", "96")
QUALITY = os.environ.get("COV_TILE_QUALITY", "75")  # JPG only, harmless for PNG

QUIET_LEVEL = 0


def log(*args, **kwargs) -> None:
    if QUIET_LEVEL < 1:
        print(*args, **kwargs)


def log_error(*args, **kwargs) -> None:
    if QUIET_LEVEL < 2:
        print(*args, **kwargs)


# --------------------------------------------------------------------------- #
# Render targets.
# --------------------------------------------------------------------------- #

@dataclass
class RenderTarget:
    operator: str
    reference: str  # e.g. "F1/16"
    project_path: Path
    # Leaf (operator, reference) pairs this target is combined from, per
    # cov_layer_source. Empty for a leaf target (reads cov_mno directly).
    depends_on: tuple[tuple[str, str], ...] = ()
    # Whether `reference` is this operator's canonical/default one (used for
    # point-info when no specific reference is requested). True for e.g.
    # TMA's F1/16, false for a secondary band like TMA's F7/16. Written to
    # tileurl.in_all, which api.cov_layer()/api.layer_tileurl() don't read
    # (they resolve via cov_layer_source instead) — kept only because the
    # column itself is still part of the live tileurl table.
    primary: bool = True


@dataclass
class LeafProject:
    project_path: Path
    primary: bool = True


# One entry per real (operator, reference) that gets rendered directly from
# cov_mno. A cov_layer selection doesn't need its own entry here just because
# it exists — most are plain aliases over one of these (or, for a combined
# layer, over several — see COMBINED_PROJECTS below). Set primary=False on
# any second reference added for an operator that already has one, so
# tileurl.in_all stays accurate for the old (deprecated, still live on
# production) api.cov() overloads.
LEAF_PROJECTS: dict[tuple[str, str], LeafProject] = {
    ("TMA", "F1/16"): LeafProject(PROJECT_DIR / "tma.qgs"),
    ("A1TA", "F1/16"): LeafProject(PROJECT_DIR / "a1ta.qgs"),
    ("H3A", "F1/16"): LeafProject(PROJECT_DIR / "h3a.qgs"),
    ("TMA", "F7/16"): LeafProject(PROJECT_DIR / "tma_3600.qgs", primary=False),
    ("A1TA", "F7/16"): LeafProject(PROJECT_DIR / "a1ta_3600.qgs", primary=False),
    ("H3A", "F7/16"): LeafProject(PROJECT_DIR / "h3a_3600.qgs", primary=False),
    # F7/16 is these four operators' own canonical reference, not a
    # secondary band — primary=True, same as TMA/A1TA/H3A's F1/16 above.
    ("LIWEST", "F7/16"): LeafProject(PROJECT_DIR / "liwest.qgs"),
    ("HGRAZ", "F7/16"): LeafProject(PROJECT_DIR / "hgraz.qgs"),
    ("SBG", "F7/16"): LeafProject(PROJECT_DIR / "sbg.qgs"),
    ("MASS", "F7/16"): LeafProject(PROJECT_DIR / "mass.qgs"),
}

# One entry per cov_layer code that combines several leaves (per
# cov_layer_source) into its own rendered/composited tile set, published
# under its own code. A layer that's just an alias for a single leaf (e.g.
# "A1TA_3600" pointing only at (A1TA, F7/16)) does NOT belong here — it
# needs no render of its own; api.layer_tileurl() resolves it straight to
# that leaf's tiles.
COMBINED_PROJECTS: dict[str, Path] = {
    "@all": PROJECT_DIR / "all.qgs",
    "all3600mhz": PROJECT_DIR / "all3600mhz.qgs",
}


# --------------------------------------------------------------------------- #
# Database helpers
# --------------------------------------------------------------------------- #

def run_psql(sql: str, dbname: str = DB_NAME) -> subprocess.CompletedProcess:
    result = subprocess.run(["psql", dbname], input=sql, text=True, capture_output=True)
    if result.stdout:
        log(result.stdout, end="")
    if result.returncode != 0:
        log_error(result.stderr, end="", file=sys.stderr)
    return result


def psql_scalar(sql: str, dbname: str = DB_NAME) -> Optional[str]:
    result = subprocess.run(["psql", "-t", "-A", "-d", dbname, "-c", sql], capture_output=True, text=True)
    if result.returncode != 0:
        log_error(result.stderr, end="", file=sys.stderr)
        return None
    value = result.stdout.strip()
    return value or None


def latest_unrendered_date(operator: str, reference: str) -> Optional[str]:
    """Newest rfc_date present in cov_mno for (operator, reference) that has no tileurl row yet."""
    sql = f"""
        SELECT rfc_date FROM cov_mno
        WHERE operator = '{operator}' AND reference = '{reference}'
          AND rfc_date NOT IN (
              SELECT date::text FROM tileurl WHERE operator = '{operator}' AND reference = '{reference}'
          )
        ORDER BY rfc_date DESC
        LIMIT 1;
    """
    return psql_scalar(sql)


def latest_tileurl_date(operator: str, reference: str) -> Optional[str]:
    """Newest rfc_date already published to tileurl for (operator, reference)."""
    sql = f"""
        SELECT date::text FROM tileurl
        WHERE operator = '{operator}' AND reference = '{reference}'
        ORDER BY date DESC
        LIMIT 1;
    """
    return psql_scalar(sql)


def pending_combined_date(target: "RenderTarget") -> Optional[str]:
    """rfc_date a derived target should render for, or None if nothing changed.

    A derived target is up to date once its own tileurl entry's date matches
    the max date across all of its dependencies. Waits (returns None) until
    every dependency has been rendered at least once.
    """
    dep_dates = [latest_tileurl_date(op, ref) for op, ref in target.depends_on]
    if any(date is None for date in dep_dates):
        return None
    combined_date = max(dep_dates)
    if latest_tileurl_date(target.operator, target.reference) == combined_date:
        return None
    return combined_date


def layer_reference(code: str) -> Optional[str]:
    """cov_layer.reference for a given layer code."""
    return psql_scalar(f"SELECT reference FROM cov_layer WHERE code = '{code}';")


def layer_dependencies(code: str) -> list[tuple[str, str]]:
    """(operator, reference) pairs `code` is combined from, per cov_layer_source.

    reference here is cov_layer_source's own reference column, not the
    source layer's cov_layer.reference — a combined layer can depend on a
    *different* reference of an operator than that operator's own standalone
    listing uses (e.g. A1TA's own layer is F1/16, but a combined F7/16 layer
    depending on A1TA needs A1TA's F7/16 data).
    """
    sql = f"SELECT source, reference FROM cov_layer_source WHERE layer = '{code}';"
    result = subprocess.run(["psql", "-t", "-A", "-F", ",", "-d", DB_NAME, "-c", sql],
                             capture_output=True, text=True)
    if result.returncode != 0:
        log_error(result.stderr, end="", file=sys.stderr)
        return []
    return [tuple(line.split(",", 1)) for line in result.stdout.strip().splitlines() if line]


def build_targets() -> list[RenderTarget]:
    """Leaf targets from LEAF_PROJECTS, then combined targets from
    COMBINED_PROJECTS joined with their dependency graph from
    cov_layer_source. Leaves first so a single sequential pass renders a
    leaf and then whatever combines it in the same run. Assumes a single
    dependency level (combined layers depend only on leaves, not on other
    combined layers).
    """
    leaves = [
        RenderTarget(operator, reference, leaf.project_path, (), leaf.primary)
        for (operator, reference), leaf in LEAF_PROJECTS.items()
    ]
    combined = [
        RenderTarget(code, layer_reference(code) or "", path, tuple(layer_dependencies(code)))
        for code, path in COMBINED_PROJECTS.items()
    ]
    return leaves + combined


def register_tileurl(operator: str, reference: str, rfc_date: str, in_all: bool) -> bool:
    """Insert a tileurl row. There is no `url` column — api.tileurl computes

    the URL from operator/reference/date (see deploy_tiles(), which must
    write files to the matching physical path). in_all is still written for
    consistency with the live tileurl table's shape, though nothing
    currently reads it — api.cov_layer()/api.layer_tileurl() resolve via
    cov_layer_source instead.
    """
    ref_sql = f"'{reference}'" if reference else "NULL"
    sql = f"""
BEGIN;
INSERT INTO tileurl(operator, reference, date, in_all)
VALUES ('{operator}', {ref_sql}, '{rfc_date}', {str(in_all).lower()});
COMMIT;
"""
    return run_psql(sql).returncode == 0


# --------------------------------------------------------------------------- #
# Render + deploy
# --------------------------------------------------------------------------- #

def render_tiles(target: RenderTarget, rfc_date: str, workdir: Path) -> Optional[Path]:
    """Run qgis_process directly against the project as-is.

    Project SQL selects `rfc_date = (SELECT MAX(rfc_date) FROM ...)` itself, so
    it always reflects current data — no per-run file patching needed. `rfc_date`
    here is only used for naming the output directory / tileurl row.
    """
    tiles_dir = workdir / "tiles"

    env = os.environ.copy()
    env["QT_QPA_PLATFORM"] = "offscreen"
    cmd = [
        "qgis_process", "run", "native:tilesxyzdirectory",
        f"--project_path={target.project_path}",
        "--",
        f"EXTENT={EXTENT}",
        f"ZOOM_MIN={ZOOM_MIN}",
        f"ZOOM_MAX={ZOOM_MAX}",
        f"DPI={DPI}",
        "TILE_FORMAT=0",  # PNG
        f"QUALITY={QUALITY}",
        f"OUTPUT_DIRECTORY={tiles_dir}",
    ]
    log(f"  Rendering {target.operator} {target.reference} {rfc_date} "
        f"(zoom {ZOOM_MIN}-{ZOOM_MAX}, this can take a long time)...")
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.returncode != 0 or not tiles_dir.is_dir():
        log_error(f"  qgis_process failed:\n{result.stdout}\n{result.stderr}")
        return None
    return tiles_dir


def deploy_tiles(tiles_dir: Path, operator: str, reference: str, rfc_date: str) -> str:
    """Move rendered tiles into the docroot, replacing any prior copy for this exact date.

    Path must match api.tileurl's computed URL exactly:
    concat('/cov/', replace(operator,'@',''), '/', coalesce(replace(reference,'/','_'),'any'), '/', date)
    — '@' stripped from the operator segment, 'any' when reference is empty/None.
    """
    op_slug = operator.replace("@", "")
    ref_slug = reference.replace("/", "_") if reference else "any"
    dest = TILE_DOCROOT / op_slug / ref_slug / rfc_date
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        import shutil
        shutil.rmtree(dest)
    tiles_dir.rename(dest)
    return f"/cov/{op_slug}/{ref_slug}/{rfc_date}"


def process_target(target: RenderTarget) -> bool:
    log(f"--- {target.operator} {target.reference} ---")

    if not target.project_path.is_file():
        log_error(f"  no project template at {target.project_path}")
        return False

    if target.depends_on:
        rfc_date = pending_combined_date(target)
    else:
        rfc_date = latest_unrendered_date(target.operator, target.reference)
    if not rfc_date:
        log("  nothing new to render")
        return True

    with tempfile.TemporaryDirectory(prefix="cov_render_") as tmp:
        tiles_dir = render_tiles(target, rfc_date, Path(tmp))
        if tiles_dir is None:
            return False

        url = deploy_tiles(tiles_dir, target.operator, target.reference, rfc_date)

        if not register_tileurl(target.operator, target.reference, rfc_date, target.primary):
            log_error(f"  tiles published to {url} but failed to register tileurl row")
            return False

        log(f"  published: {url}")
        return True


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def select_target(targets: list[RenderTarget], spec: str) -> Optional[RenderTarget]:
    """Pick the one target matching `spec` for --target, or None (with an error logged).

    spec is either "OPERATOR" (a leaf's operator, or a combined target's own
    code — e.g. "SBG" or "all3600mhz"), or "OPERATOR:REFERENCE" to disambiguate
    an operator with more than one leaf (e.g. "TMA:F7/16").
    """
    if ":" in spec:
        operator, reference = spec.split(":", 1)
        matches = [t for t in targets if t.operator == operator and t.reference == reference]
    else:
        matches = [t for t in targets if t.operator == spec]

    if not matches:
        log_error(f"no target matches {spec!r} (available: "
                  f"{', '.join(f'{t.operator}:{t.reference}' for t in targets)})")
        return None
    if len(matches) > 1:
        log_error(f"{spec!r} is ambiguous, matches: "
                  f"{', '.join(f'{t.operator}:{t.reference}' for t in matches)} — "
                  f"disambiguate with OPERATOR:REFERENCE")
        return None
    return matches[0]


def main(argv: Optional[list[str]] = None) -> int:
    global QUIET_LEVEL, TILE_DOCROOT

    parser = argparse.ArgumentParser(
        description="Render new coverage data into XYZ tiles and publish them."
    )
    parser.add_argument(
        "-q", "--quiet", action="count", default=0,
        help="suppress routine progress output; repeat (-qq) to also suppress failure details",
    )
    parser.add_argument(
        "--target", metavar="OPERATOR[:REFERENCE]",
        help="render only this one target instead of everything, e.g. --target SBG, "
             "--target TMA:F7/16, or --target all3600mhz (a combined target's own code). "
             "Bypasses the lock file too, since a scoped debug run isn't the scheduled job.",
    )
    parser.add_argument(
        "--output-dir", metavar="PATH",
        help="write tiles under PATH instead of the tile docroot (COV_TILE_DOCROOT/"
             "/var/www/tiles/cov) — for debug renders you don't want to publish live, "
             "e.g. to avoid overwriting a real render while testing.",
    )
    args = parser.parse_args(argv)
    QUIET_LEVEL = args.quiet
    if args.output_dir:
        TILE_DOCROOT = Path(args.output_dir)

    if args.target:
        target = select_target(build_targets(), args.target)
        if target is None:
            return 1
        return 0 if process_target(target) else 1

    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("Another render is already in progress, skipping this run.")
        return 0

    try:
        failures = [
            f"{t.operator} {t.reference}" for t in build_targets() if not process_target(t)
        ]
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()

    if failures:
        log_error(f"\nFailed: {', '.join(failures)}")
        return 1

    log("\ndone")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log_error("\nInterrupted.")
        sys.exit(130)
