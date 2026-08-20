#!/usr/bin/env python3
"""Read and update the organization-wide Harness set without a YAML dependency."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


HERE = Path(__file__).resolve().parent
REGISTRY = HERE / "registry.json"


def registry(path: Path = REGISTRY) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("harnesses") or []
    ids = [entry.get("id") for entry in entries]
    if not entries or any(not re.fullmatch(r"[a-z][a-z0-9-]*", str(item or "")) for item in ids):
        raise ValueError(f"{path}: invalid Harness registry")
    if len(ids) != len(set(ids)):
        raise ValueError(f"{path}: duplicate Harness id")
    return entries


def configured(path: Path) -> list[str] | None:
    if not path.is_file():
        return None
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, raw in enumerate(lines):
        match = re.match(r"^harnesses:\s*(.*?)\s*$", raw)
        if not match:
            continue
        inline = match.group(1)
        if inline:
            inline = inline.strip()
            if inline.startswith("[") and inline.endswith("]"):
                return [item.strip().strip("'\"") for item in inline[1:-1].split(",") if item.strip()]
            return [inline.strip("'\"")]
        result: list[str] = []
        for nested in lines[index + 1 :]:
            item = re.match(r"^\s{2}-\s*([a-z][a-z0-9-]*)\s*$", nested)
            if item:
                result.append(item.group(1))
                continue
            if nested.startswith(" ") or not nested.strip():
                continue
            break
        return result
    return None


def validate(values: list[str], entries: list[dict]) -> list[str]:
    known = {str(entry["id"]) for entry in entries}
    result: list[str] = []
    for value in values:
        value = value.strip().lower()
        if not value:
            continue
        if value not in known:
            raise ValueError(f"unknown Harness {value!r}; registered: {', '.join(sorted(known))}")
        if value not in result:
            result.append(value)
    if not result:
        raise ValueError("Harness set cannot be empty")
    return result


def write_config(path: Path, values: list[str]) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    output: list[str] = []
    skipping = False
    found = False
    for raw in lines:
        if re.match(r"^harnesses:\s*", raw):
            if not found:
                output.append("harnesses:")
                output.extend(f"  - {value}" for value in values)
                found = True
            skipping = True
            continue
        if skipping:
            if raw.startswith(" ") or not raw.strip():
                continue
            skipping = False
        output.append(raw)
    if not found:
        block = ["harnesses:", *(f"  - {value}" for value in values), ""]
        output = block + output
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")
    temp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("catalog", "list", "set"))
    parser.add_argument("--config", type=Path)
    parser.add_argument("--registry", type=Path, default=REGISTRY)
    parser.add_argument("--fallback", action="store_true")
    parser.add_argument("--harnesses", default="")
    args = parser.parse_args()
    entries = registry(args.registry)

    if args.command == "catalog":
        for entry in entries:
            print(
                "|".join(
                    (
                        str(entry["id"]),
                        str(entry.get("display_name") or entry["id"]),
                        "yes" if entry.get("default_selected") else "no",
                        str(entry.get("cli") or ""),
                        str(entry.get("projector") or ""),
                        str(entry.get("workflow_adapter") or ""),
                        str(entry.get("project_guidance") or ""),
                    )
                )
            )
        return 0

    if not args.config:
        parser.error("--config is required")
    current = configured(args.config)
    if args.command == "list":
        if not current and args.fallback:
            current = [str(entry["id"]) for entry in entries if entry.get("default_selected")]
        if current is None:
            return 3
        for value in validate(current, entries):
            print(value)
        return 0

    values = validate(re.split(r"[\s,]+", args.harnesses), entries)
    if not args.config.is_file():
        raise ValueError(f"configuration file does not exist: {args.config}")
    write_config(args.config, values)
    for value in values:
        print(value)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"aiworks harnesses: {exc}", file=__import__("sys").stderr)
        raise SystemExit(2)
