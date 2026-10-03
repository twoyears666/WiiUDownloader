#!/usr/bin/env bash
#
# Fetch the Wii U title database from napi.v10lator.de and convert the Go
# literal payload into the JSON consumed by WiiUCore (Resources/titles.json).
#
# The endpoint returns a Go source fragment where every record looks roughly
# like:
#     {Name: "Super Mario 3D World", TitleID: 0x0005000010144F00, Region: 0x2, ...}
#
# Field order is not guaranteed and numeric values may be hexadecimal (0x...) or
# decimal, so the parser below extracts each field independently and skips any
# record it cannot fully understand.

set -euo pipefail

URL='https://napi.v10lator.de/db?t=go'
USER_AGENT='NUSspliBuilder/2.1'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT="${IOS_DIR}/WiiUCore/Sources/WiiUCore/Resources/titles.json"

TMP_RAW="$(mktemp -t title_db_raw.XXXXXX)"
trap 'rm -f "${TMP_RAW}"' EXIT

echo "Downloading title database from ${URL} ..."
if ! curl --http1.1 -fsS -H "User-Agent: ${USER_AGENT}" "${URL}" -o "${TMP_RAW}"; then
    echo "Error: failed to download the title database from ${URL}." >&2
    echo "       Check your network connection or the endpoint availability." >&2
    exit 1
fi

if [ ! -s "${TMP_RAW}" ]; then
    echo "Error: the downloaded title database is empty (${URL})." >&2
    exit 1
fi

python3 - "${TMP_RAW}" "${OUTPUT}" <<'PY'
import json
import os
import re
import sys

raw_path = sys.argv[1]
out_path = sys.argv[2]

with open(raw_path, "r", encoding="utf-8", errors="replace") as handle:
    text = handle.read()


def to_int(value):
    """Parse a Go numeric literal (hex with 0x prefix, or decimal)."""
    cleaned = value.strip().replace("_", "")
    if cleaned[:2].lower() == "0x":
        return int(cleaned, 16)
    return int(cleaned, 10)


def unescape(value):
    """Decode a Go string body; falls back to the raw text on failure."""
    try:
        return json.loads('"' + value + '"')
    except Exception:
        return value


def leaf_records(source):
    """Yield the body of every innermost brace block that has no nested braces."""
    stack = []
    for index, char in enumerate(source):
        if char == "{":
            stack.append(index)
        elif char == "}" and stack:
            start = stack.pop()
            body = source[start + 1:index]
            if "{" not in body:
                yield body


# Capture the whole value token and let to_int() validate it, so a malformed
# literal (e.g. "0xZZ") is rejected instead of being partially matched.
VALUE = r"([^,\s}]+)"
NAME_RE = re.compile(r'\bName\s*:\s*"((?:[^"\\]|\\.)*)"')
TITLE_ID_RE = re.compile(r"\bTitleID\s*:\s*" + VALUE)
REGION_RE = re.compile(r"\bRegion\s*:\s*" + VALUE)
KEY_RE = re.compile(r"\bKey\s*:\s*" + VALUE)
CATEGORY_RE = re.compile(r"\bCategory\s*:\s*" + VALUE)
VERSION_RE = re.compile(r"\bVersion\s*:\s*" + VALUE)

entries = []
for body in leaf_records(text):
    name_match = NAME_RE.search(body)
    title_id_match = TITLE_ID_RE.search(body)
    region_match = REGION_RE.search(body)
    key_match = KEY_RE.search(body)
    category_match = CATEGORY_RE.search(body)
    version_match = VERSION_RE.search(body)

    if not all((name_match, title_id_match, region_match,
                key_match, category_match, version_match)):
        continue

    try:
        title_id = to_int(title_id_match.group(1))
        region = to_int(region_match.group(1))
        key = to_int(key_match.group(1))
        category = to_int(category_match.group(1))
        version = to_int(version_match.group(1))
    except ValueError:
        continue

    entries.append({
        "name": unescape(name_match.group(1)),
        "titleID": format(title_id & 0xFFFFFFFFFFFFFFFF, "016x"),
        "region": region,
        "key": key,
        "category": category,
        "version": version,
    })

if not entries:
    sys.stderr.write(
        "Error: no title entries could be parsed from the downloaded payload.\n"
    )
    sys.exit(1)

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(entries, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

print("Wrote {} title entries to {}".format(len(entries), out_path))
PY

echo "Done."
