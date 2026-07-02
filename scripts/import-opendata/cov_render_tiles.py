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

A target can also be *derived*: instead of reading cov_mno directly, its
QGIS project combines other targets (e.g. "all operators" or "F7/16 from
A1TA+TMA+H3A"). Declare this via `RenderTarget.depends_on` — a list of the
(operator, reference) pairs it's built from. This replaces the old
`tileurl.in_all`-style boolean-per-row convention with an explicit,
code-owned dependency list: a derived target's "is there new data" check
looks at whether any dependency has a newer rendered date than the derived
target's own latest `tileurl` row, and its rfc_date is the max of its
dependencies' dates. List derived targets *after* the targets they depend on
in TARGETS — everything below runs strictly sequentially in list order (see
`main()`), so a single run picks up a leaf render and then its dependent
combined render in the same pass, never in parallel.

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
# Render targets: one QGIS project template per (operator, reference).
# Extend this list as more per-operator projects are built.
# --------------------------------------------------------------------------- #

@dataclass
class RenderTarget:
    operator: str
    reference: str  # e.g. "F1/16"
    project_path: Path
    # Leaf (operator, reference) pairs this target is combined from. Empty
    # for an ordinary per-operator target. Non-empty marks this as a derived
    # target: see the module docstring.
    depends_on: tuple[tuple[str, str], ...] = ()


TARGETS = [
    RenderTarget("TMA", "F1/16", PROJECT_DIR / "tma.qgs"),
    # Add derived targets after their dependencies once a combined project
    # template exists for them, e.g.:
    # RenderTarget("@all", "F1/16", PROJECT_DIR / "all_operators.qgs",
    #              depends_on=(("A1TA", "F1/16"), ("TMA", "F1/16"), ("H3A", "F1/16"))),
    # RenderTarget("@all", "F7/16", PROJECT_DIR / "f7_16_combo.qgs",
    #              depends_on=(("A1TA", "F7/16"), ("TMA", "F7/16"), ("H3A", "F7/16"))),
]


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


def register_tileurl(operator: str, reference: str, rfc_date: str, url: str) -> bool:
    sql = f"""
BEGIN;
INSERT INTO tileurl(operator, reference, date, url) VALUES ('{operator}', '{reference}', '{rfc_date}', '{url}');
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
    """Move rendered tiles into the docroot, replacing any prior copy for this exact date."""
    ref_slug = reference.replace("/", "_")
    dest = TILE_DOCROOT / operator / ref_slug / rfc_date
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        import shutil
        shutil.rmtree(dest)
    tiles_dir.rename(dest)
    return f"/cov/{operator}/{ref_slug}/{rfc_date}"


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

        if not register_tileurl(target.operator, target.reference, rfc_date, url):
            log_error(f"  tiles published to {url} but failed to register tileurl row")
            return False

        log(f"  published: {url}")
        return True


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def main(argv: Optional[list[str]] = None) -> int:
    global QUIET_LEVEL

    parser = argparse.ArgumentParser(
        description="Render new coverage data into XYZ tiles and publish them."
    )
    parser.add_argument(
        "-q", "--quiet", action="count", default=0,
        help="suppress routine progress output; repeat (-qq) to also suppress failure details",
    )
    args = parser.parse_args(argv)
    QUIET_LEVEL = args.quiet

    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("Another render is already in progress, skipping this run.")
        return 0

    try:
        failures = [
            f"{t.operator} {t.reference}" for t in TARGETS if not process_target(t)
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
