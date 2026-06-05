#!/usr/bin/env python3
import json


def parse_line(line):
    value = line.strip()
    if not value:
        return None
    separator = "=>" if "=>" in value else "->" if "->" in value else None
    if separator is None:
        return {"kind": "word", "phrase": value, "replacement": None}
    parts = [part.strip() for part in value.split(separator)]
    if len(parts) != 2 or not parts[0] or not parts[1]:
        return None
    return {"kind": "replacement", "phrase": parts[0], "replacement": parts[1]}


def dedupe(entries):
    seen = set()
    result = []
    for entry in entries:
        key = (entry["kind"], entry["phrase"].lower(), (entry.get("replacement") or "").lower())
        if key in seen:
            continue
        seen.add(key)
        result.append(entry)
    return result


def test_parse_lines():
    lines = ["DeskScribe", "desk scribe => DeskScribe", "post grass -> Postgres", "broken ->", "DeskScribe"]
    parsed = [parse_line(line) for line in lines]
    valid = dedupe([entry for entry in parsed if entry])
    invalid = [line for line, entry in zip(lines, parsed) if entry is None]
    assert valid == [
        {"kind": "word", "phrase": "DeskScribe", "replacement": None},
        {"kind": "replacement", "phrase": "desk scribe", "replacement": "DeskScribe"},
        {"kind": "replacement", "phrase": "post grass", "replacement": "Postgres"},
    ]
    assert invalid == ["broken ->"]


def test_import_export_payload():
    payload = {
        "version": 1,
        "entries": [
            {"kind": "word", "phrase": "API", "replacement": None},
            {"kind": "replacement", "phrase": "jay son", "replacement": "JSON"},
        ],
    }
    data = json.dumps(payload, sort_keys=True, indent=2)
    decoded = json.loads(data)
    assert decoded["version"] == 1
    assert decoded["entries"][1]["replacement"] == "JSON"


if __name__ == "__main__":
    test_parse_lines()
    test_import_export_payload()
    print("vocabulary codec tests passed")
