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
"""Download open-data mobile network / 5G coverage files from the operators.

Format: operator;reference;license;rfc_date;raster;dl_normal;ul_normal;dl_max;ul_max

- operator:  "A1TA", "TMA", "H3A", "LIWEST", "SBG", "HGRAZ", "MASS"
- reference: "F1/16" (mobile) or "F7/16" (3.5 GHz)
- license:   "CCBY4.0"
- rfc_date:  simulation date, RFC 3339 (day only), e.g. "2020-12-26"
- raster:    100m x 100m raster according to ETRS-LAEA, e.g. "100mN27285E48011"
- dl_normal/ul_normal/dl_max/ul_max: speeds in Bit/s (no decimals); zero if no coverage

Replaces the previous cov_download_mno.sh.
"""

from __future__ import annotations

import io
import os
import re
import shlex
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from datetime import date
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
        print(f"    CSV: {csv_url}")
        return fetch(csv_url, headers)
    if zip_url:
        print(f"    ZIP: {zip_url}")
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


def _normalize_delimiter(data: bytes) -> bytes:
    """Some operators occasionally deliver comma- instead of semicolon-delimited data."""
    first_line = data.split(b"\n", 1)[0]
    if b";" not in first_line and b"," in first_line:
        data = data.replace(b",", b";")
    return data


# --------------------------------------------------------------------------- #
# Per-operator fetch
# --------------------------------------------------------------------------- #

def fetch_a1(name_fragment: str, fix_reference: bool) -> bytes:
    page = fetch_text(A1_REF_URL)
    csv_url = find_link(page, rf'https://[^"\'\s]+{name_fragment}[^"\'\s]*?\.csv')
    zip_url = None
    if not csv_url:
        zip_url = find_link(page, rf'https://[^"\'\s]+{name_fragment}[^"\'\s]*?\.zip')
    data = download_csv_or_zip(csv_url, zip_url, referer=A1_REF_URL)
    return clean_a1(data, fix_reference)


def fetch_tma(ref_url: str) -> bytes:
    page = fetch_text(ref_url)
    path = find_link(page, r'content/dam/magenta_at/csv/versorgungsdaten/[^"\'\s]*?\.(?:csv|CSV)')
    if not path:
        raise RuntimeError(f"no CSV link found on {ref_url}")
    data = fetch(f"https://www.magenta.at/{path}")
    return clean_tma(data)


# --------------------------------------------------------------------------- #
# Jobs
# --------------------------------------------------------------------------- #

@dataclass
class Job:
    name: str
    fetch: Callable[[], bytes]


JOBS = [
    Job("F1_A1TA", lambda: fetch_a1("A1_Speed_Final", fix_reference=True)),
    Job("F1_TMA", lambda: fetch_tma(TMA_F1_REF_URL)),
    Job("F1_H3A", lambda: clean_h3a(fetch(H3A_F1_URL))),
    Job("F7_A1TA", lambda: fetch_a1("3500_Final", fix_reference=False)),
    Job("F7_TMA", lambda: fetch_tma(TMA_F7_REF_URL)),
    Job("F7_H3A", lambda: clean_h3a(fetch(H3A_F7_URL))),
    Job("F7_LIWEST", lambda: clean_liwest(fetch(LIWEST_URL))),
    Job("F7_HGRAZ", lambda: clean_hgraz(fetch(HGRAZ_URL))),
    Job("F7_SBG", lambda: clean_sbg(fetch(SBG_URL))),
    Job("F7_MASS", lambda: clean_mass(fetch(MASS_URL))),
]


def run(out_dir: Path) -> list[str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Saving in {out_dir}")
    if RELAY_HOST:
        print(f"Routing downloads via SSH relay: {RELAY_HOST}")

    failures = []
    for job in JOBS:
        print(f"--- {job.name} ---")
        try:
            data = job.fetch()
        except FetchError as exc:
            print("    FAILED:")
            for line in exc.debug_lines():
                print(f"      {line}")
            failures.append(job.name)
            continue
        except (ValueError, RuntimeError) as exc:
            print(f"    FAILED: {exc}")
            failures.append(job.name)
            continue

        out_path = out_dir / f"{job.name}.csv"
        out_path.write_bytes(data)

        preview = data.decode("utf-8", errors="replace").splitlines()[:2]
        for line in preview:
            print(f"    {line}")

    return failures


def main() -> int:
    out_dir = Path.home() / "open" / date.today().isoformat()
    failures = run(out_dir)

    if failures:
        print(f"\nFailed downloads: {', '.join(failures)}")
        return 1

    print("\ndone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
