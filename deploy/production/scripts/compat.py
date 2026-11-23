#!/usr/bin/env python3
"""Checks a combination of versions against the compatibility matrix (S8.2, COMPATIBILITY.md).

    compat.py <versions file>                               versions/<environment>.env
    compat.py infra=X.Y.Z core=X.Y.Z invoicing=X.Y.Z web=X.Y.Z

Exit 0 when the combination is compatible, 1 when it isn't (each problem on stderr), 2 on a usage or
matrix error. Standard library only and Python 3.9: it runs on the operator's machine (deploy.sh) and
in CI (ci-validate.sh).
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

MATRIX = Path(__file__).resolve().parent.parent / "COMPATIBILITY.md"
SERVICES = ("infra", "core", "invoicing", "web")
START, END = "<!-- matrix:start -->", "<!-- matrix:end -->"
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
# "sales.confirmed v3" or a range, "sales.confirmed v1–v3" (en dash or hyphen)
CONTRACT = re.compile(r"^([a-z][a-z_.]*) v(\d+)(?:\s*[–-]\s*v(\d+))?$")
REQUIREMENT = re.compile(r"^(infra|core|invoicing|web)\s*(?:≥|>=)\s*(\d+\.\d+\.\d+)$")
NONE = {"", "—", "-"}

Version = tuple[int, int, int]


class MatrixError(Exception):
    pass


@dataclass
class Row:
    service: str
    version: Version
    publishes: dict[str, int] = field(default_factory=dict)
    accepts: dict[str, tuple[int, int]] = field(default_factory=dict)
    requires: dict[str, Version] = field(default_factory=dict)


def base(version: str) -> Version:
    """The X.Y.Z of a version: a pre-release counts as its base version."""
    if not SEMVER.match(version):
        raise ValueError(f"{version!r} isn't a semantic version (X.Y.Z or X.Y.Z-pre.N)")
    major, minor, patch = version.split("-", 1)[0].split(".")
    return int(major), int(minor), int(patch)


def show(version: Version) -> str:
    return ".".join(str(part) for part in version)


def items(cell: str) -> list[str]:
    return [] if cell.strip() in NONE else [item.strip() for item in cell.split(",")]


def parse_row(cells: list[str]) -> Row:
    service, version, publishes, accepts, requires = cells
    if service not in SERVICES:
        raise MatrixError(f"unknown service {service!r}")
    row = Row(service, base(version))
    for item in items(publishes):
        match = CONTRACT.match(item)
        if not match or match.group(3):
            raise MatrixError(f"{service} {version}: publishes {item!r}, expected 'topic vN'")
        row.publishes[match.group(1)] = int(match.group(2))
    for item in items(accepts):
        match = CONTRACT.match(item)
        if not match:
            raise MatrixError(f"{service} {version}: accepts {item!r}, expected 'topic vN[–vM]'")
        low = int(match.group(2))
        high = int(match.group(3) or low)
        if high < low:
            raise MatrixError(f"{service} {version}: the range of {item!r} is reversed")
        row.accepts[match.group(1)] = (low, high)
    for item in items(requires):
        match = REQUIREMENT.match(item)
        if not match:
            raise MatrixError(f"{service} {version}: requires {item!r}, expected 'service ≥ X.Y.Z'")
        row.requires[match.group(1)] = base(match.group(2))
    return row


def read_matrix(path: Path) -> dict[tuple[str, Version], Row]:
    text = path.read_text(encoding="utf-8")
    if START not in text or END not in text:
        raise MatrixError(f"{path.name} has no {START} ... {END} table")
    table = text.split(START, 1)[1].split(END, 1)[0]
    rows: dict[tuple[str, Version], Row] = {}
    lines = [line.strip() for line in table.splitlines() if line.strip().startswith("|")]
    # The header and its separator
    for line in lines[2:]:
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) != 5:
            raise MatrixError(f"expected 5 columns: {line}")
        try:
            row = parse_row(cells)
        except ValueError as error:
            raise MatrixError(str(error)) from error
        key = (row.service, row.version)
        if key in rows:
            raise MatrixError(f"{row.service} {show(row.version)} has two rows")
        rows[key] = row
    return rows


def read_versions(args: list[str]) -> dict[str, str]:
    if len(args) == 1 and "=" not in args[0]:
        pairs = []
        for line in Path(args[0]).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                name, _, value = line.partition("=")
                if name.endswith("_VERSION"):
                    pairs.append((name[: -len("_VERSION")].lower(), value.strip()))
    else:
        pairs = [tuple(arg.split("=", 1)) for arg in args]  # type: ignore[misc]
    versions = dict(pairs)
    missing = [service for service in SERVICES if service not in versions]
    extra = [service for service in versions if service not in SERVICES]
    if missing or extra:
        raise ValueError(f"expected the versions of {', '.join(SERVICES)}")
    for version in versions.values():
        base(version)
    return versions


def problems(versions: dict[str, str], matrix: dict[tuple[str, Version], Row]) -> list[str]:
    found: list[str] = []
    rows: dict[str, Row] = {}
    for service in SERVICES:
        version = versions[service]
        row = matrix.get((service, base(version)))
        if row is None:
            found.append(f"{service} {version} isn't in the matrix (COMPATIBILITY.md): add its row")
        else:
            rows[service] = row

    for producer, row in rows.items():
        for topic, published in row.publishes.items():
            consumers = {name: r.accepts[topic] for name, r in rows.items() if topic in r.accepts}
            # Without every row, a missing consumer is already reported
            if not consumers and len(rows) == len(SERVICES):
                found.append(f"{producer} {versions[producer]} publishes {topic} v{published}, which nobody here accepts")
            for consumer, (low, high) in consumers.items():
                if not low <= published <= high:
                    found.append(
                        f"{producer} {versions[producer]} publishes {topic} v{published}, "
                        f"but {consumer} {versions[consumer]} accepts v{low}–v{high}"
                    )

    for service, row in rows.items():
        for other, minimum in row.requires.items():
            if base(versions[other]) < minimum:
                found.append(
                    f"{service} {versions[service]} requires {other} ≥ {show(minimum)}, "
                    f"not {versions[other]}"
                )
    return found


def main(args: list[str]) -> int:
    if not args or args[0] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        matrix = read_matrix(MATRIX)
        versions = read_versions(args)
    except (MatrixError, ValueError, OSError) as error:
        print(f"compat.py: {error}", file=sys.stderr)
        return 2
    combination = ", ".join(f"{service} {versions[service]}" for service in SERVICES)
    found = problems(versions, matrix)
    if found:
        print(f"Not compatible: {combination}", file=sys.stderr)
        for problem in found:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"Compatible: {combination}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
