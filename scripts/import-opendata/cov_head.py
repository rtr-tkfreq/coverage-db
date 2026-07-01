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
"""Print the first two lines of each given file, prefixed with its name.

Replaces the previous cov_head.sh.
"""

from __future__ import annotations

import sys


def print_head(path: str, lines: int = 2) -> None:
    print(f"header {path}")
    try:
        with open(path, "r", errors="replace") as f:
            for _ in range(lines):
                line = f.readline()
                if not line:
                    break
                print(line.rstrip("\n"))
    except OSError as exc:
        print(f"cov_head.py: can't read {path}: {exc.strerror}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        print(f"Usage: {sys.argv[0]} <files>")
        return 1

    for path in argv:
        print_head(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
