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
"""Import the downloaded mobile network / 5G coverage CSVs into Postgres.

Replaces cov_import_mno.sh, cov_import_all.sh and cov_import_final_step.sh.
Each original script is kept as its own function here; `main()` wires them
together the same way all.sh / cov_all.sh did.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Optional

DB_NAME = "frq"
OPEN_DATA_ROOT = Path("/var/lib/postgresql/open")

# order matches the original cov_import_all.sh
MNO_FILES = [
    "F1_A1TA",
    "F1_TMA",
    "F1_H3A",
    "F7_A1TA",
    "F7_TMA",
    "F7_H3A",
    "F7_MASS",
    "F7_LIWEST",
    "F7_HGRAZ",
    "F7_SBG",
]


def run_psql(sql: str, dbname: str = DB_NAME) -> subprocess.CompletedProcess:
    """Run a SQL script through the psql CLI, mirroring `echo -e $sql | psql <dbname>`."""
    result = subprocess.run(["psql", dbname], input=sql, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.returncode != 0:
        print(result.stderr, end="", file=sys.stderr)
    return result


# --------------------------------------------------------------------------- #
# cov_import_mno.sh
# --------------------------------------------------------------------------- #

def import_mno(name: str, day: Optional[date] = None) -> bool:
    """COPY a single operator CSV (e.g. "F1_A1TA") into cov_mno. Returns True on success."""
    day = day or date.today()
    csv_path = OPEN_DATA_ROOT / day.isoformat() / f"{name}.csv"

    if csv_path.is_file():
        print(f"{csv_path}: {csv_path.stat().st_size} bytes")

    if not (csv_path.is_file() and os.access(csv_path, os.R_OK)):
        print(f"Skipping {name}: {csv_path} not readable")
        return False

    print(f"Import for {name}")
    sql = f"""
BEGIN;

COPY cov_mno(operator,reference,license,rfc_date,raster,dl_normal,ul_normal,dl_max,ul_max)
FROM '{csv_path}'
DELIMITER ';'
CSV HEADER;

COMMIT;
"""
    return run_psql(sql).returncode == 0


# --------------------------------------------------------------------------- #
# cov_import_all.sh
# --------------------------------------------------------------------------- #

def import_all(day: Optional[date] = None) -> list[str]:
    """Import every known operator file for `day`. Returns the list of names that failed."""
    failures = []
    for name in MNO_FILES:
        if not import_mno(name, day):
            failures.append(name)
    return failures


# --------------------------------------------------------------------------- #
# cov_import_final_step.sh
# --------------------------------------------------------------------------- #

def import_final_step() -> bool:
    """Backfill geom for newly imported rows from the atraster lookup table."""
    print("Import, update geom")
    sql = """
BEGIN;
update cov_mno set geom=ST_transform(atraster.geom,3857) from atraster where atraster.id=raster and cov_mno.geom is null;
COMMIT;
"""
    return run_psql(sql).returncode == 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _parse_date(value: str) -> date:
    return datetime.strptime(value, "%Y-%m-%d").date()


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command")

    mno_parser = subparsers.add_parser("mno", help="import a single operator CSV")
    mno_parser.add_argument("name", help='e.g. "F1_A1TA"')
    mno_parser.add_argument("--date", type=_parse_date, default=None)

    all_parser = subparsers.add_parser("all", help="import every operator CSV")
    all_parser.add_argument("--date", type=_parse_date, default=None)

    subparsers.add_parser("final-step", help="backfill geom for newly imported rows")

    args = parser.parse_args(argv)

    if args.command == "mno":
        return 0 if import_mno(args.name, args.date) else 1

    if args.command == "all":
        failures = import_all(args.date)
        if failures:
            print(f"\nFailed imports: {', '.join(failures)}")
            return 1
        return 0

    if args.command == "final-step":
        return 0 if import_final_step() else 1

    # no subcommand: run the full pipeline, same as all.sh / cov_all.sh
    failures = import_all()
    ok = import_final_step()
    if failures:
        print(f"\nFailed imports: {', '.join(failures)}")
    return 0 if (not failures and ok) else 1


if __name__ == "__main__":
    sys.exit(main())
