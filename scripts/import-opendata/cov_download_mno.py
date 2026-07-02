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
"""Download open-data mobile network coverage files and import them into Postgres.

Format: operator;reference;license;rfc_date;raster;dl_normal;ul_normal;dl_max;ul_max

- operator:  "A1TA", "TMA", "H3A", "LIWEST", "SBG", "HGRAZ", "MASS"
- reference: "F1/16" (mobile) or "F7/16" (3.5 GHz)
- license:   "CCBY4.0"
- rfc_date:  simulation date, RFC 3339 (day only), e.g. "2020-12-26"
- raster:    100m x 100m raster according to ETRS-LAEA, e.g. "100mN27285E48011"
- dl_normal/ul_normal/dl_max/ul_max: speeds in Bit/s (no decimals); zero if no coverage

Each run downloads into its own ~/open/YYYY-MM-DD_HH-MM-SS directory, then compares
the new files against every previous run directory: files identical to an earlier
run (operators publish updates roughly every 3 months, so most daily runs see no
change) are redundant and get deleted, since their data is already in the database.
If nothing is left afterwards, the run directory is removed too and the import step
is skipped entirely. Only genuinely new/changed files get imported — unless
--keep-duplicates is given, in which case every file is kept and (re-)imported,
relying on the database to reject rows with an already-known rfc_date.

Replaces the previous cov_download_mno.sh, cov_import_mno.sh, cov_import_all.sh and
cov_import_final_step.sh.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import shlex
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
TIMEOUT = 60  # per-read socket timeout for direct (urllib) downloads, not a total-transfer cap
RELAY_CONNECT_TIMEOUT = 30  # curl --connect-timeout when using an SSH relay
RELAY_MAX_TIME = 1800  # curl --max-time when using an SSH relay — some CSVs are 600MB+ uncompressed,
                        # and the SSH hop adds overhead, so this must be generous
DEBUG_HEADERS = ("server", "via", "x-cache", "cf-ray", "x-akamai-request-id", "x-amz-cf-id", "x-request-id")

# If set (e.g. "user@relayhost"), every download is done as `ssh RELAY_HOST curl ...`
# instead of a direct connection from this machine — useful when an operator has
# blocked this host's IP. Requires passwordless SSH (key-based) and curl on the
# relay host. Configure via: export COV_RELAY_HOST=user@relayhost
RELAY_HOST = os.environ.get("COV_RELAY_HOST") or None

A1_REF_URL = "https://www.a1.net/versorgungsdaten-gemaess-auflagen"
TMA_F1_REF_URL = "https://www.magenta.at/unternehmen/rechtliches/versorgungsdaten_mba2020"
TMA_F7_REF_URL = "https://www.magenta.at/unternehmen/rechtliches/versorgungsdaten"
H3A_F1_URL = "https://www.drei.at/media/common/info/netzabdeckung/h3a-versorgung-rohdaten-700-1500-2100.csv"
H3A_F7_URL = "https://www.drei.at/media/common/info/netzabdeckung/h3a-versorgung-rohdaten.csv"
LIWEST_URL = "https://www.liwest.at/fileadmin/data-transfer/Import/rtr/rtr_f716.CSV"
HGRAZ_URL = "https://raw.githubusercontent.com/GrazNewRadio/Versorgungskarte/main/GrazNewRadio_Versorgungskarte.csv"
SBG_URL = "https://www.salzburg-ag.at/content/dam/web18/dokumente/cablelink/internet/RohdatenSalzburgAG3_GHz.csv"
MASS_URL = "https://www.massresponse.com/versorgungsdaten3-5ghz/OpenDataRasterdatenMASS.csv"

DB_NAME = "frq"
RUN_DIR_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$")

# Set by main() from -q/--quiet (repeatable: -q, -qq). 0 = normal, 1 = routine
# progress output suppressed, 2 = failure/warning details suppressed too (exit
# code still reflects failures either way).
QUIET_LEVEL = 0


def log(*args, **kwargs) -> None:
    if QUIET_LEVEL < 1:
        print(*args, **kwargs)


def log_error(*args, **kwargs) -> None:
    if QUIET_LEVEL < 2:
        print(*args, **kwargs)


# --------------------------------------------------------------------------- #
# HTTP helpers
# --------------------------------------------------------------------------- #

class FetchError(RuntimeError):
    """A failed HTTP request, carrying enough detail to debug *why* it failed."""

    def __init__(self, url: str, status: Optional[int], reason: str,
                 headers: Optional[dict] = None, body: bytes = b""):
        self.url = url
        self.status = status
        self.reason = reason
        self.headers = headers or {}
        self.body = body
        super().__init__(f"{status if status is not None else '?'} {reason} — URL: {url}")

    def debug_lines(self) -> list[str]:
        lines = [f"URL:    {self.url}", f"Status: {self.status} {self.reason}"]
        interesting = {k: v for k, v in self.headers.items() if k.lower() in DEBUG_HEADERS}
        if interesting:
            lines.append("Headers: " + ", ".join(f"{k}={v}" for k, v in interesting.items()))
        if self.body:
            snippet = self.body.decode("utf-8", errors="replace").strip().replace("\n", " ")[:300]
            if snippet:
                lines.append(f"Body:   {snippet}")
        return lines


def _default_headers(extra_headers: Optional[dict] = None) -> dict:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "de-AT,de;q=0.9,en;q=0.8",
    }
    if extra_headers:
        headers.update(extra_headers)
    return headers


def fetch(url: str, extra_headers: Optional[dict] = None) -> bytes:
    if RELAY_HOST:
        return _fetch_via_ssh_relay(url, RELAY_HOST, extra_headers)

    req = Request(url, headers=_default_headers(extra_headers))
    try:
        with urlopen(req, timeout=TIMEOUT) as resp:
            return resp.read()
    except HTTPError as exc:
        body = exc.read(2000) if exc.fp else b""
        raise FetchError(url, exc.code, exc.reason, dict(exc.headers or {}), body) from exc
    except URLError as exc:
        raise FetchError(url, None, str(exc.reason)) from exc


def _fetch_via_ssh_relay(url: str, relay: str, extra_headers: Optional[dict] = None) -> bytes:
    """Run curl on `relay` over ssh, so the request appears to come from that host."""
    marker = "___COV_HTTP_STATUS___"
    curl_cmd = [
        "curl", "-sS", "-L",
        "--connect-timeout", str(RELAY_CONNECT_TIMEOUT),
        "--max-time", str(RELAY_MAX_TIME),
    ]
    for key, value in _default_headers(extra_headers).items():
        curl_cmd += ["-H", f"{key}: {value}"]
    curl_cmd += ["-w", f"\n{marker}:%{{http_code}}", url]
    remote_cmd = " ".join(shlex.quote(part) for part in curl_cmd)

    proc = subprocess.run(
        ["ssh", relay, remote_cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=RELAY_MAX_TIME + 60,
    )
    if proc.returncode != 0:
        raise FetchError(
            url, None, f"ssh relay {relay} exited {proc.returncode}",
            body=proc.stderr[:2000],
        )

    marker_bytes = f"\n{marker}:".encode()
    idx = proc.stdout.rfind(marker_bytes)
    if idx == -1:
        raise FetchError(url, None, f"could not parse curl output via relay {relay}", body=proc.stdout[:2000])

    body = proc.stdout[:idx]
    status_str = proc.stdout[idx + len(marker_bytes):].decode(errors="replace").strip()
    status = int(status_str) if status_str.isdigit() else None
    if status is not None and status >= 400:
        raise FetchError(url, status, f"HTTP error via relay {relay}", body=body[:2000])
    return body


def fetch_text(url: str) -> str:
    return fetch(url).decode("utf-8", errors="replace")


def find_link(page: str, pattern: str) -> Optional[str]:
    match = re.search(pattern, page)
    return match.group(0) if match else None


def extract_zip_csv(data: bytes) -> bytes:
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        names = zf.namelist()
        if len(names) != 1:
            raise ValueError(f"expected exactly one file in zip, got {names}")
        return zf.read(names[0])


def download_csv_or_zip(csv_url: Optional[str], zip_url: Optional[str],
                         referer: Optional[str] = None) -> bytes:
    headers = {"Referer": referer} if referer else None
    if csv_url:
        log(f"    CSV: {csv_url}")
        return fetch(csv_url, headers)
    if zip_url:
        log(f"    ZIP: {zip_url}")
        return extract_zip_csv(fetch(zip_url, headers))
    raise RuntimeError("no CSV or ZIP link found on reference page")


# --------------------------------------------------------------------------- #
# Per-operator cleanup (mirrors the sed/cut steps of the old bash script)
# --------------------------------------------------------------------------- #

def clean_a1(data: bytes, fix_reference: bool) -> bytes:
    # A1 wraps text fields in typographic quotes (0x93/0x94) plus a stray 0x22.
    data = data.replace(b"\x93", b"").replace(b"\x94", b"").replace(b"\x22", b"")
    if fix_reference:
        # older exports mislabeled the F1/16 reference as F5/22-2
        data = data.replace(b"F5/22-2", b"F1/16")
    return data


def clean_tma(data: bytes) -> bytes:
    data = data.replace(b'"', b"")
    return _normalize_delimiter(data)


def clean_h3a(data: bytes) -> bytes:
    return _normalize_delimiter(data)


def clean_liwest(data: bytes) -> bytes:
    return data


def clean_hgraz(data: bytes) -> bytes:
    # drop rows with no coverage at all (dl_normal=ul_normal=dl_max=ul_max=0)
    lines = data.split(b"\n")
    header, rows = lines[0], lines[1:]
    kept = [r for r in rows if not r.rstrip(b"\r").endswith(b";0;0;0;0")]
    return header + b"\n" + b"\n".join(kept)


def clean_sbg(data: bytes) -> bytes:
    # drop any trailing columns beyond the 9 defined ones, normalize line endings
    lines = data.replace(b"\r", b"").split(b"\n")
    out = [b";".join(line.split(b";")[:9]) for line in lines if line]
    return _normalize_delimiter(b"\n".join(out) + b"\n")


def clean_mass(data: bytes) -> bytes:
    return data


def _strip_bom(data: bytes) -> bytes:
    """Some operators prefix their file with a UTF-8 BOM (EF BB BF) on the header line."""
    return data[3:] if data.startswith(b"\xef\xbb\xbf") else data


def _normalize_delimiter(data: bytes) -> bytes:
    """Some operators occasionally deliver comma- instead of semicolon-delimited data."""
    first_line = data.split(b"\n", 1)[0]
    if b";" not in first_line and b"," in first_line:
        data = data.replace(b",", b";")
    return data


# --------------------------------------------------------------------------- #
# Per-operator fetch
# --------------------------------------------------------------------------- #

def fetch_a1_raw(name_fragment: str) -> bytes:
    page = fetch_text(A1_REF_URL)
    csv_url = find_link(page, rf'https://[^"\'\s]+{name_fragment}[^"\'\s]*?\.csv')
    zip_url = None
    if not csv_url:
        zip_url = find_link(page, rf'https://[^"\'\s]+{name_fragment}[^"\'\s]*?\.zip')
    return download_csv_or_zip(csv_url, zip_url, referer=A1_REF_URL)


def fetch_tma_raw(ref_url: str) -> bytes:
    page = fetch_text(ref_url)
    path = find_link(page, r'content/dam/magenta_at/csv/versorgungsdaten/[^"\'\s]*?\.(?:csv|CSV)')
    if not path:
        raise RuntimeError(f"no CSV link found on {ref_url}")
    return fetch(f"https://www.magenta.at/{path}")


# --------------------------------------------------------------------------- #
# Jobs (defines the canonical operator/file order used throughout)
# --------------------------------------------------------------------------- #

@dataclass
class Job:
    name: str
    fetch: Callable[[], bytes]  # returns the raw, as-downloaded bytes (saved as "<name>.csv.raw")
    clean: Callable[[bytes], bytes]  # transforms raw bytes into the final "<name>.csv"


JOBS = [
    Job("F1_A1TA", lambda: fetch_a1_raw("A1_Speed_Final"), lambda data: clean_a1(data, fix_reference=True)),
    Job("F1_TMA", lambda: fetch_tma_raw(TMA_F1_REF_URL), clean_tma),
    Job("F1_H3A", lambda: fetch(H3A_F1_URL), clean_h3a),
    Job("F7_A1TA", lambda: fetch_a1_raw("3500_Final"), lambda data: clean_a1(data, fix_reference=False)),
    Job("F7_TMA", lambda: fetch_tma_raw(TMA_F7_REF_URL), clean_tma),
    Job("F7_H3A", lambda: fetch(H3A_F7_URL), clean_h3a),
    Job("F7_LIWEST", lambda: fetch(LIWEST_URL), clean_liwest),
    Job("F7_HGRAZ", lambda: fetch(HGRAZ_URL), clean_hgraz),
    Job("F7_SBG", lambda: fetch(SBG_URL), clean_sbg),
    Job("F7_MASS", lambda: fetch(MASS_URL), clean_mass),
]


# --------------------------------------------------------------------------- #
# Download (cov_download_mno.sh)
# --------------------------------------------------------------------------- #

def download_all(out_dir: Path) -> list[str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    log(f"Saving in {out_dir}")
    if RELAY_HOST:
        log(f"Routing downloads via SSH relay: {RELAY_HOST}")

    failures = []
    for job in JOBS:
        log(f"--- {job.name} ---")
        try:
            raw = job.fetch()
        except FetchError as exc:
            log_error("    FAILED:")
            for line in exc.debug_lines():
                log_error(f"      {line}")
            failures.append(job.name)
            continue
        except (ValueError, RuntimeError) as exc:
            log_error(f"    FAILED: {exc}")
            failures.append(job.name)
            continue

        # kept alongside the cleaned .csv for documentation/debugging
        (out_dir / f"{job.name}.csv.raw").write_bytes(raw)

        try:
            data = job.clean(raw)
        except (ValueError, RuntimeError) as exc:
            log_error(f"    FAILED to clean: {exc}")
            failures.append(job.name)
            continue

        data = _strip_bom(data)

        out_path = out_dir / f"{job.name}.csv"
        out_path.write_bytes(data)

        preview = data.decode("utf-8", errors="replace").splitlines()[:2]
        for line in preview:
            log(f"    {line}")

    return failures


# --------------------------------------------------------------------------- #
# Dedupe against previous run directories
# --------------------------------------------------------------------------- #

def _previous_run_dirs(root: Path, exclude: Path) -> list[Path]:
    if not root.is_dir():
        return []
    dirs = [d for d in root.iterdir() if d.is_dir() and d != exclude and RUN_DIR_RE.match(d.name)]
    return sorted(dirs, key=lambda d: d.name, reverse=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _files_identical(a: Path, b: Path) -> bool:
    return a.stat().st_size == b.stat().st_size and _sha256(a) == _sha256(b)


def dedupe(out_dir: Path, root: Path, remove_duplicates: bool) -> list[str]:
    """Compare each downloaded file in `out_dir` against every previous run directory.

    Operators publish updates roughly every 3 months, so most daily runs produce
    byte-identical files to the previous run — those are redundant (already
    imported) and get deleted when `remove_duplicates` is set.

    Normally, returns only the operator names (without ".csv") of files that are
    new/changed, since those are the only ones that should be (re-)imported. With
    `remove_duplicates=False` (--keep-duplicates, a debug option), every file is
    both kept on disk *and* returned for import — the database is expected to
    reject re-importing an already-known rfc_date, so this is a safe way to force
    a full re-import attempt.
    """
    if not out_dir.is_dir():
        return []

    previous_dirs = _previous_run_dirs(root, exclude=out_dir)
    log(f"\nComparing against {len(previous_dirs)} previous run director{'y' if len(previous_dirs) == 1 else 'ies'}...")

    new_or_changed = []
    all_present = []
    for csv_path in sorted(out_dir.glob("*.csv")):
        all_present.append(csv_path.stem)
        match = next(
            (prev_dir / csv_path.name for prev_dir in previous_dirs
             if (prev_dir / csv_path.name).is_file() and _files_identical(csv_path, prev_dir / csv_path.name)),
            None,
        )

        if match is None:
            log(f"  kept:    {csv_path.name} (new or changed)")
            new_or_changed.append(csv_path.stem)
        elif remove_duplicates:
            csv_path.unlink()
            raw_path = csv_path.with_name(csv_path.name + ".raw")
            if raw_path.is_file():
                raw_path.unlink()
            log(f"  removed: {csv_path.name} (unchanged since {match.parent.name})")
        else:
            log(f"  kept:    {csv_path.name} (unchanged since {match.parent.name}; --keep-duplicates set, will still attempt import)")

    if remove_duplicates and not any(out_dir.iterdir()):
        out_dir.rmdir()
        log(f"No new or changed files — removed empty directory {out_dir}")
    else:
        log(f"Directory kept: {out_dir}")

    return new_or_changed if remove_duplicates else all_present


# --------------------------------------------------------------------------- #
# Import (cov_import_mno.sh / cov_import_all.sh)
# --------------------------------------------------------------------------- #

def run_psql(sql: str, dbname: str = DB_NAME) -> subprocess.CompletedProcess:
    """Run a SQL script through the psql CLI, mirroring `echo -e $sql | psql <dbname>`.

    -v ON_ERROR_STOP=1 is not optional here: without it, psql's default exit
    code is 0 even when a statement inside the script errors (the failing
    statement just gets skipped, e.g. leaving a BEGIN;...;COMMIT; block to
    ROLLBACK instead — silently). Callers check returncode == 0 to decide
    success; without this flag that check is meaningless.
    """
    result = subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", dbname], input=sql, text=True, capture_output=True)
    if result.stdout:
        log(result.stdout, end="")
    if result.returncode != 0:
        log_error(result.stderr, end="", file=sys.stderr)
    return result


def import_mno(csv_dir: Path, name: str) -> bool:
    """COPY a single operator CSV (e.g. "F1_A1TA") into cov_mno. Returns True on success."""
    csv_path = csv_dir / f"{name}.csv"

    if not (csv_path.is_file() and os.access(csv_path, os.R_OK)):
        log_error(f"Skipping {name}: {csv_path} not readable")
        return False

    log(f"Import for {name}")
    sql = f"""
BEGIN;

COPY cov_mno(operator,reference,license,rfc_date,raster,dl_normal,ul_normal,dl_max,ul_max)
FROM '{csv_path}'
DELIMITER ';'
CSV HEADER;

COMMIT;
"""
    return run_psql(sql).returncode == 0


def import_all(csv_dir: Path, names: list[str]) -> list[str]:
    """Import the given operator files from `csv_dir`. Returns the names that failed."""
    failures = []
    for name in names:
        if not import_mno(csv_dir, name):
            failures.append(name)
    return failures


# --------------------------------------------------------------------------- #
# Final step (cov_import_final_step.sh)
# --------------------------------------------------------------------------- #

def import_final_step() -> bool:
    """Backfill geom for newly imported rows from the atraster lookup table."""
    log("Import, update geom")
    sql = """
BEGIN;
update cov_mno set geom=ST_transform(atraster.geom,3857) from atraster where atraster.id=raster and cov_mno.geom is null;
COMMIT;
"""
    return run_psql(sql).returncode == 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def main(argv: Optional[list[str]] = None) -> int:
    global QUIET_LEVEL

    parser = argparse.ArgumentParser(
        description="Download open-data mobile network coverage files and import them into Postgres."
    )
    parser.add_argument(
        "--keep-duplicates", action="store_true",
        help="debug option: keep files (and the run directory) even if identical to a "
             "previous run, and attempt to import all of them regardless — relies on "
             "the database rejecting a re-import of an already-known rfc_date",
    )
    parser.add_argument(
        "-q", "--quiet", action="count", default=0,
        help="suppress routine progress output; repeat (-qq) to also suppress failure "
             "details — the exit code still reflects failures either way",
    )
    args = parser.parse_args(argv)
    QUIET_LEVEL = args.quiet

    root = Path.home() / "open"
    out_dir = root / datetime.now().strftime("%Y-%m-%d_%H-%M-%S")

    download_failures = download_all(out_dir)
    kept = dedupe(out_dir, root, remove_duplicates=not args.keep_duplicates)

    if not kept:
        log("\nNo new or changed data since the last run — skipping import.")
        if download_failures:
            log_error(f"Failed downloads: {', '.join(download_failures)}")
            return 1
        log("done")
        return 0

    import_failures = import_all(out_dir, kept)
    final_ok = import_final_step()

    if download_failures:
        log_error(f"\nFailed downloads: {', '.join(download_failures)}")
    if import_failures:
        log_error(f"Failed imports: {', '.join(import_failures)}")

    if download_failures or import_failures or not final_ok:
        return 1

    log("\ndone")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log_error("\nInterrupted.")
        sys.exit(130)
