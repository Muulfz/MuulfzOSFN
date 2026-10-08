"""
Compose: recursively inline !include references in an AME playbook YAML tree
and emit a single flat file that AME can consume directly.

Strategy: text-level processing. Because AME YAML uses custom tags like
!registryValue everywhere, we don't try to parse the full document with
yaml.safe_load (which doesn't know those tags). We find `!include "path"`
occurrences, load that file's `actions:` list as raw text, and splice in.

Usage:
  python tools/compose.py --input playbook/main-fortnite.yml --output dist/main-flat-fortnite.yml
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


INCLUDE_RX = re.compile(r'^(\s*)- !include\s+"([^"]+)"\s*$')


def extract_actions_block(path: pathlib.Path) -> list[str]:
    """Return the lines of the `actions:` list body from a YAML file (no header)."""
    lines = path.read_text(encoding="utf-8").splitlines()
    in_actions = False
    out: list[str] = []
    actions_indent = None
    for line in lines:
        if not in_actions:
            m = re.match(r"^(\s*)actions\s*:\s*$", line)
            if m:
                in_actions = True
                actions_indent = len(m.group(1))
            continue
        # We're in the actions list. Stop at the first non-blank line whose
        # indent is <= actions_indent (i.e., a sibling key to `actions:`).
        stripped = line.rstrip()
        if stripped == "":
            out.append(line)
            continue
        leading_spaces = len(line) - len(line.lstrip())
        if leading_spaces <= actions_indent and stripped != "":
            break
        out.append(line)
    return out


def compose(input_path: pathlib.Path, output_path: pathlib.Path) -> int:
    """Walk !include tree from input_path; write flattened YAML to output_path."""
    root_lines = input_path.read_text(encoding="utf-8").splitlines()
    root_dir = input_path.parent

    output_lines: list[str] = []
    for line in root_lines:
        m = INCLUDE_RX.match(line)
        if not m:
            output_lines.append(line)
            continue

        indent = m.group(1)
        ref = m.group(2)
        ref_path = (root_dir / ref).resolve()
        if not ref_path.is_file():
            print(f"ERR: include target not found: {ref_path}", file=sys.stderr)
            return 3

        inner = extract_actions_block(ref_path)
        # Re-indent the inner block to match the include site
        # The inner block's own indent is likely "  " (2 spaces for "- foo:").
        # We inline as-is but preserve the list-item marker alignment.
        if inner:
            output_lines.append(f"{indent}# -- inlined from {ref} --")
            for inner_line in inner:
                output_lines.append(inner_line)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(output_lines) + "\n", encoding="utf-8")
    print(f"OK: composed -> {output_path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, type=pathlib.Path)
    ap.add_argument("--output", required=True, type=pathlib.Path)
    args = ap.parse_args()
    return compose(args.input, args.output)


if __name__ == "__main__":
    sys.exit(main())
