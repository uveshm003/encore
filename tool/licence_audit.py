"""Inventories the licence of every package pinned in pubspec.lock.

The point of this script is that the licence review in docs/licences.md is
reproducible rather than a snapshot somebody took once. It reads the LICENSE
file actually present in the resolved package in the pub cache — not pub.dev
metadata, which is a self-declared field and can disagree with the file that
ships.

    python3 tool/licence_audit.py            # table, grouped by licence
    python3 tool/licence_audit.py --markdown # the table in docs/licences.md
    python3 tool/licence_audit.py --check    # exit 1 if anything copyleft ships

--check is the one worth wiring into CI: it fails when a dependency that
reaches a shipping platform is copyleft, or when a package has no licence file
at all, which is how an obligation gets into the build without anybody noticing.
"""

import argparse
import os
import re
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUB_CACHE = os.environ.get("PUB_CACHE") or os.path.expanduser("~/.pub-cache")

# Packages that only ever reach a platform Encore does not ship. They are still
# reported, but --check does not fail on them. Keep the reason with the entry.
NOT_SHIPPED = {
    "dbus": "Linux only, via file_picker_linux; Linux is not a target",
    "file_picker_linux": "Linux only",
    "record_linux": "Linux only",
    "path_provider_linux": "Linux only",
    "windows_file_picker": "Windows only",
    "record_windows": "Windows only",
    "path_provider_windows": "Windows only",
    "win32": "Windows only",
    "file_picker_web": "web only",
    "record_web": "web only",
    "xdg_directories": "Linux only",
}

# Licence classes that carry a source-disclosure obligation of some kind.
COPYLEFT = {"GPL", "LGPL", "AGPL", "MPL-2.0", "EPL", "CDDL"}

LICENCE_TESTS = [
    # MPL is tested before the GPL family on purpose: MPL-2.0 §1.12 names the
    # GPL, LGPL and AGPL in its "Secondary License" definition, so a plain
    # substring test for those matches the MPL text itself.
    ("MPL-2.0", lambda t: "mozilla public license" in t),
    ("AGPL", lambda t: "affero general public license" in t),
    ("LGPL", lambda t: "lesser general public license" in t),
    ("GPL", lambda t: "gnu general public license" in t),
    ("Apache-2.0", lambda t: "apache license" in t and "version 2.0" in t),
    (
        "BSD-3-Clause",
        lambda t: "redistributions in binary form must reproduce" in t
        and "neither the name of" in t,
    ),
    (
        "BSD-2-Clause",
        lambda t: "redistributions in binary form must reproduce" in t
        and "neither the name of" not in t,
    ),
    (
        "Unlicense",
        lambda t: "free and unencumbered software released into the public domain" in t,
    ),
    ("MIT", lambda t: "permission is hereby granted, free of charge" in t),
    (
        "Zlib",
        lambda t: "this software is provided 'as-is'" in t
        and "altered source versions" in t,
    ),
]

LICENCE_FILENAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING")


def classify(text):
    """Names the licence from the text of the file, not from metadata."""
    flat = " ".join(text.split()).lower()
    for name, matches in LICENCE_TESTS:
        if matches(flat):
            return name
    return "UNKNOWN"


def read_lock(path):
    """Parses the package blocks out of pubspec.lock.

    Deliberately not a YAML dependency: this script has to run on a clean
    checkout with nothing installed but Python.
    """
    packages = {}
    current = None
    in_packages = False
    for line in open(path, encoding="utf-8"):
        if re.match(r"^packages:\s*$", line):
            in_packages = True
            continue
        if in_packages and re.match(r"^\w", line):
            in_packages = False
        if not in_packages:
            continue
        header = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if header:
            current = header.group(1)
            packages[current] = {}
            continue
        if current:
            field = re.match(r'^    (\w+): "?([^"\n]*?)"?\s*$', line)
            if field:
                packages[current][field.group(1)] = field.group(2)
    return packages


def find_package_dir(name, version):
    hosted = os.path.join(PUB_CACHE, "hosted")
    if not os.path.isdir(hosted):
        return None
    for host in os.listdir(hosted):
        candidate = os.path.join(hosted, host, f"{name}-{version}")
        if os.path.isdir(candidate):
            return candidate
    return None


def find_licence_file(directory):
    for name in LICENCE_FILENAMES:
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            return path
    return None


def audit():
    packages = read_lock(os.path.join(ROOT, "pubspec.lock"))
    rows = []
    for name in sorted(packages):
        entry = packages[name]
        source = entry.get("source", "?")
        version = entry.get("version", "?")
        dependency = entry.get("dependency", "?")
        ships = name not in NOT_SHIPPED and not dependency.startswith("direct dev")

        if source in ("sdk", "path"):
            # First-party or Flutter's own; covered by the Flutter BSD-3-Clause
            # licence and by this repository's own terms respectively.
            rows.append((name, version, dependency, source, "first-party/SDK", ships, None))
            continue

        directory = find_package_dir(name, version)
        if directory is None:
            rows.append((name, version, dependency, source, "NOT RESOLVED", ships, None))
            continue
        licence_file = find_licence_file(directory)
        if licence_file is None:
            rows.append((name, version, dependency, source, "NO LICENCE FILE", ships, None))
            continue
        text = open(licence_file, encoding="utf-8", errors="replace").read()
        rows.append(
            (
                name,
                version,
                dependency,
                source,
                classify(text),
                ships,
                os.path.basename(licence_file),
            )
        )
    return rows


def print_table(rows):
    width = max(len(row[0]) for row in rows)
    by_licence = defaultdict(list)
    for row in rows:
        by_licence[row[4]].append(row)
    for licence in sorted(by_licence):
        print(f"\n{licence}  ({len(by_licence[licence])})")
        print("-" * (width + 40))
        for name, version, dependency, _source, _licence, ships, _file in sorted(
            by_licence[licence]
        ):
            flag = "" if ships else f"   [not shipped: {NOT_SHIPPED.get(name, 'dev only')}]"
            print(f"  {name:<{width}}  {version:<10} {dependency:<16}{flag}")
    print()
    print(dict(Counter(row[4] for row in rows)))


def print_markdown(rows):
    print("| Package | Version | Scope | Licence |")
    print("|---------|---------|-------|---------|")
    for name, version, dependency, _source, licence, ships, _file in rows:
        scope = dependency.replace("direct ", "").replace("transitive", "transitive")
        if not ships:
            scope += " · not shipped"
        print(f"| `{name}` | {version} | {scope} | {licence} |")


def check(rows):
    problems = []
    for name, version, _dependency, _source, licence, ships, _file in rows:
        if not ships:
            continue
        if licence in COPYLEFT:
            problems.append(f"{name} {version}: {licence} reaches a shipping platform")
        if licence in ("UNKNOWN", "NO LICENCE FILE", "NOT RESOLVED"):
            problems.append(f"{name} {version}: {licence}")
    if problems:
        print("Licence check FAILED:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    shipped = sum(1 for row in rows if row[5])
    print(f"Licence check passed: {shipped} shipped packages, none copyleft, all identified.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--markdown", action="store_true", help="emit a markdown table")
    parser.add_argument("--check", action="store_true", help="fail on copyleft/unknown")
    args = parser.parse_args()

    rows = audit()
    if args.check:
        sys.exit(check(rows))
    if args.markdown:
        print_markdown(rows)
    else:
        print_table(rows)


if __name__ == "__main__":
    main()
