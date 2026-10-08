"""
Tag-filter build tool.

Reads a YAML playbook whose actions carry `_tags` and emits a filtered YAML
artifact for a given target + mode + gamepass choice.

Tag vocabulary (see spec §7):
  - tier:safe / tier:aggressive / tier:playbook-only
  - mode:console / mode:competitive / mode:hybrid / mode:any
  - preserves:gamepass            (mutually exclusive with requires:no-gamepass)
  - requires:no-gamepass          (only allowed when --gamepass strip)
  - cpu:intel / cpu:amd / cpu:any
  - gpu:nvidia-any / gpu:any

Invariants enforced at build time:
  - gamepass-preservation: action tagged requires:no-gamepass must not appear
    in a --gamepass preserve build. BUILD FAILS HARD.

Usage:
  python tools/build.py --input playbook/main.yml --output dist/MuulfzOTMZ.yml \\
                        --target personal --mode console --gamepass preserve
"""
from __future__ import annotations

import argparse
import sys
import pathlib

import yaml

# Teach yaml.safe_load/safe_dump about AME custom tags (!registryValue etc.)
from ame_yaml import install as _install_ame
_install_ame()


ALLOWED_MODES = {"console", "competitive", "hybrid"}
ALLOWED_GAMEPASS = {"preserve", "strip", "custom"}
ALLOWED_TARGETS = {"personal", "oss-script", "commercial-htpc", "commercial-esports"}

# AME ISO-injection compatibility (docs.amelabs.net/developers/iso.html):
# dynamic action types (scripts, arbitrary commands) cannot run at image time.
# They must be marked `iso: false, oobe: true` so they fire at OOBE/first-boot.
# Every other static action type is safe to run at both injection and OOBE.
DYNAMIC_AME_TAGS = {"powerShell", "run", "cmd", "download", "appx", "taskKill"}
# Tags AME confirmed do NOT support iso: true (per docs + empirical errors).
# Same set as DYNAMIC for now, kept distinct for documentation.
NO_ISO_SUPPORT = {"powerShell", "run", "cmd", "download", "appx", "software", "taskKill"}
# Tags safe to run at iso (image time).
ISO_SAFE_TAGS = {"registryValue", "registryKey", "service", "scheduledTask",
                 "file", "folder", "task"}
# Pure-display tags that have no apply-time effect -- keep default (no annotation).
DISPLAY_ONLY_TAGS = {"writeStatus"}

DEFAULT_PROFILE_DIR = pathlib.Path(__file__).parent.parent / "playbook" / "profiles"


def load_document(path: pathlib.Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def action_matches(action: dict, mode: str, gamepass: str, tags_deny: set | None = None) -> bool:
    """Return True if this action should be emitted. Raises on invariant violation."""
    tags = set(action.get("_tags", []) or [])

    # Profile tag-deny: if the action has any denied tag, drop it.
    if tags_deny and tags & tags_deny:
        return False

    # Mode gate: if the action declares any mode: tags, at least one must match.
    mode_tags = {t for t in tags if t.startswith("mode:")}
    if mode_tags:
        if f"mode:{mode}" not in mode_tags and "mode:any" not in mode_tags:
            return False

    # Game Pass invariant enforcement.
    if "requires:no-gamepass" in tags and gamepass == "preserve":
        raise ValueError(
            f"gamepass invariant violated: action tagged requires:no-gamepass "
            f"found in --gamepass preserve build. action={action}"
        )
    if "requires:no-gamepass" in tags and gamepass != "strip":
        # Custom path must have explicit opt-in; for now we keep it out.
        return False

    return True


def convert_source_tag_to_ame(action):
    """Rename our source-DSL tag names + fields to the wire format AME parses.

    AME's strict schema:
      !status:        {status: 'msg'}                   (we author as !writeStatus 'msg')
      !scheduledTask: {path: '\\path', operation: ..., data: '<xml>'}
                                                        (we author with name + xml)
    Calling AT EMIT TIME keeps the source files stable while shipping
    AME-conformant YAML.
    """
    from ame_yaml import AmeAction
    if not isinstance(action, AmeAction):
        return action

    if action._ame_tag == "writeStatus":
        msg = action._ame_scalar if action._ame_scalar is not None else action.get("status") or action.get("message") or ""
        return AmeAction("status", {"status": str(msg)})

    if action._ame_tag == "scheduledTask":
        data = dict(action)
        if "name" in data and "path" not in data:
            data["path"] = data.pop("name")
        if "xml" in data and "data" not in data:
            data["data"] = data.pop("xml")
            data.setdefault("operation", "enable")
        return AmeAction("scheduledTask", data)

    if action._ame_tag == "registryValue":
        # AME's deserializer parses REG_DWORD/REG_QWORD `data` via ulong.Parse,
        # which only accepts DECIMAL strings. Hex literals like '0x26' throw
        # FormatException. Normalize to decimal at emit time so the source
        # files can keep using human-friendly hex.
        d = dict(action)
        rtype = str(d.get("type", "")).upper()
        if rtype in ("REG_DWORD", "REG_QWORD") and "data" in d:
            raw = str(d["data"]).strip()
            if raw.lower().startswith("0x"):
                d["data"] = str(int(raw, 16))
        return AmeAction("registryValue", d)

    if action._ame_tag == "service":
        # AME's ServiceAction.startup is an int (2=Automatic, 3=Manual, 4=Disabled).
        # Source DSL uses readable strings; map them at emit time so ulong.Parse
        # doesn't blow up on 'Disabled'.
        d = dict(action)
        startup_map = {
            "automatic": 2, "auto": 2,
            "manual": 3,
            "disabled": 4,
            "boot": 0, "system": 1,
        }
        if "startup" in d:
            v = d["startup"]
            if isinstance(v, str) and v.lower() in startup_map:
                d["startup"] = startup_map[v.lower()]
        d.setdefault("operation", "change")  # startup-only entries imply change
        return AmeAction("service", d)

    if action._ame_tag == "run":
        # AME's RunAction uses 'exe' for the executable; source DSL uses 'target'.
        d = dict(action)
        if "target" in d and "exe" not in d:
            d["exe"] = d.pop("target")
        return AmeAction("run", d)

    if action._ame_tag == "powerShell" and '"' in str(action.get("command", "")):
        # AME hands `command` to powershell.exe on its command line, which eats
        # bare double quotes ("$env:X\y" arrives as $env:X\y -> parse error, the
        # whole script silently exits 1). """ survives as one literal " -- same
        # convention Atlas uses. Seen in the VM run of 2026-10-07.
        d = dict(action)
        d["command"] = str(d["command"]).replace('"', '"""')
        return AmeAction("powerShell", d)

    return action


def annotate_for_injection(action_data: dict, ame_tag: str | None) -> dict:
    """Add `iso` / `oobe` properties so the playbook is ISO-injection compatible.

    Dynamic action types (scripts, arbitrary commands) can't run at image time;
    they fire at OOBE/first-boot instead. Every other static action runs at
    both injection and OOBE (iso: true is sufficient; AME treats that as
    'run at both times'). writeStatus has no effect at image time either.

    Empirical AME limits at iso-time:
      - HKCU paths null-ref (no user hive mounted) -> defer to OOBE
      - scheduledTask enable/disable -> AME warns + skips -> defer to OOBE
        (delete IS supported at iso)
    """
    if not ame_tag:
        return action_data
    if ame_tag in DISPLAY_ONLY_TAGS:
        # Display-only status lines: skip during silent injection, show in UI apply.
        return {**action_data, "iso": False, "oobe": True}
    if ame_tag in DYNAMIC_AME_TAGS:
        return {**action_data, "iso": False, "oobe": True}
    # registryValue with HKCU path: no user hive at iso time -> OOBE only.
    if ame_tag in ("registryValue", "registryKey"):
        path = str(action_data.get("path", ""))
        if path.upper().startswith("HKCU\\") or path.upper().startswith("HKEY_CURRENT_USER\\"):
            return {**action_data, "iso": False, "oobe": True}
    # scheduledTask enable/disable: AME doesn't support at iso time.
    if ame_tag == "scheduledTask":
        op = str(action_data.get("operation", "delete"))
        if op in ("enable", "disable"):
            return {**action_data, "iso": False, "oobe": True}
    return {**action_data, "iso": True}


def filter_actions(actions: list, mode: str, gamepass: str,
                   tags_deny: set | None = None) -> list:
    from ame_yaml import AmeAction
    out = []
    for a in actions:
        if not isinstance(a, dict):
            out.append(a)
            continue
        if action_matches(a, mode, gamepass, tags_deny=tags_deny):
            cleaned_data = {k: v for k, v in a.items() if k != "_tags"}
            if isinstance(a, AmeAction):
                # For scalar-form AmeActions (e.g. `!powerShell 'cmd'`) we must
                # promote to mapping form `{command: cmd, iso: ..., oobe: ...}`
                # so the iso/oobe annotation survives round-trip. writeStatus
                # stays scalar (it has no apply-time effect; we just drop it
                # from the YAML entirely for injection builds to reduce noise).
                is_scalar = a._ame_scalar is not None
                if is_scalar and a._ame_tag in DISPLAY_ONLY_TAGS:
                    # writeStatus during silent injection has nowhere to render;
                    # keep as scalar for the UI-apply path, no annotation.
                    new = AmeAction(a._ame_tag, None)
                    new._ame_scalar = a._ame_scalar
                    out.append(new)
                elif is_scalar and a._ame_tag in DYNAMIC_AME_TAGS:
                    # Promote scalar `!powerShell "cmd"` -> mapping with command:
                    promoted = {"command": a._ame_scalar, "iso": False, "oobe": True}
                    new = AmeAction(a._ame_tag, promoted)
                    out.append(new)
                elif is_scalar:
                    # Static-tagged scalar (rare). Leave as scalar, no annotation.
                    new = AmeAction(a._ame_tag, None)
                    new._ame_scalar = a._ame_scalar
                    out.append(new)
                else:
                    annotated = annotate_for_injection(cleaned_data, a._ame_tag)
                    new = AmeAction(a._ame_tag, annotated if annotated else None)
                    out.append(new)
            else:
                out.append(cleaned_data)
    return out


VALID_REG_TYPES = {
    "REG_SZ", "REG_MULTI_SZ", "REG_EXPAND_SZ",
    "REG_DWORD", "REG_QWORD", "REG_BINARY",
    "REG_NONE", "REG_UNKNOWN",
}
VALID_REG_OPERATIONS = {"add", "delete", "set"}
VALID_SCHEDTASK_OPERATIONS = {"delete", "deleteFolder", "enable", "disable"}
VALID_SERVICE_OPERATIONS = {"change", "delete"}


def preflight_validate_annotations(actions: list) -> list[str]:
    """Catch invalid iso/oobe combinations BEFORE AME sees them.

    Rules:
      - tag in NO_ISO_SUPPORT: must NOT have iso: true
      - tag in ISO_SAFE_TAGS: iso: true OK
      - status: no apply-time effect; either way is harmless but iso: true
        is wasteful, prefer oobe: true
    """
    from ame_yaml import AmeAction
    errors: list[str] = []
    for i, a in enumerate(actions):
        if not isinstance(a, AmeAction):
            continue
        tag = a._ame_tag
        if a.get("iso") is True and tag in NO_ISO_SUPPORT:
            errors.append(f"actions[{i}] !{tag}: iso: true rejected by AME -- must be oobe: true")
    return errors


def preflight_validate(actions: list) -> list[str]:
    """Catch AME-Wizard YamlDotNet deserialization landmines BEFORE shipping.

    Each rule below corresponds to a real exception class we've hit or could
    trivially hit. Returns list of error strings; empty list = OK.
    """
    from ame_yaml import AmeAction
    errors: list[str] = []
    for i, a in enumerate(actions):
        if not isinstance(a, AmeAction):
            continue
        tag = a._ame_tag
        idx = f"actions[{i}] !{tag}"

        if tag == "registryValue":
            # path/value/type/data required for add/set; type+data omittable on delete.
            op = a.get("operation", "add")
            if op not in VALID_REG_OPERATIONS:
                errors.append(f"{idx}: operation={op!r} not in {sorted(VALID_REG_OPERATIONS)}")
            if "path" not in a:
                errors.append(f"{idx}: missing required 'path'")
            if "value" not in a:
                errors.append(f"{idx}: missing required 'value'")
            if op != "delete":
                rtype = str(a.get("type", "")).upper()
                if rtype not in VALID_REG_TYPES:
                    errors.append(f"{idx}: type={rtype!r} not in {sorted(VALID_REG_TYPES)}")
                if "data" not in a:
                    errors.append(f"{idx}: missing 'data' for operation={op}")
                # numeric types must be decimal so ulong.Parse succeeds
                if rtype in ("REG_DWORD", "REG_QWORD") and "data" in a:
                    raw = str(a["data"]).strip()
                    if not raw.isdigit():
                        errors.append(f"{idx}: REG_DWORD/REG_QWORD data={raw!r} is not decimal (AME ulong.Parse)")

        elif tag == "scheduledTask":
            op = a.get("operation")
            if op is not None and op not in VALID_SCHEDTASK_OPERATIONS:
                errors.append(f"{idx}: operation={op!r} not in {sorted(VALID_SCHEDTASK_OPERATIONS)}")
            if "path" not in a:
                errors.append(f"{idx}: missing required 'path'")
            if op == "enable" and "data" not in a:
                errors.append(f"{idx}: operation=enable requires 'data' (raw XML)")

        elif tag == "status":
            if "status" not in a:
                errors.append(f"{idx}: missing required 'status'")

        elif tag == "service":
            op = a.get("operation", "change")
            valid_ops = {"stop", "continue", "start", "pause", "delete", "change"}
            if op not in valid_ops:
                errors.append(f"{idx}: operation={op!r} not in {sorted(valid_ops)}")
            if "name" not in a:
                errors.append(f"{idx}: missing required 'name'")
            if op == "change":
                if "startup" not in a:
                    errors.append(f"{idx}: operation=change requires 'startup'")
                else:
                    s = a["startup"]
                    if not isinstance(s, int) or s not in (0, 1, 2, 3, 4):
                        errors.append(f"{idx}: startup={s!r} must be int (0=Boot 1=System 2=Auto 3=Manual 4=Disabled)")

        elif tag == "run":
            if "exe" not in a:
                errors.append(f"{idx}: missing required 'exe'")
            for k in ("timeout", "weight"):
                if k in a and not isinstance(a[k], int):
                    errors.append(f"{idx}: {k}={a[k]!r} must be int")

        elif tag == "appx":
            if "name" not in a:
                errors.append(f"{idx}: missing required 'name'")
            t = a.get("type", "family")
            if t not in ("family", "package", "app"):
                errors.append(f"{idx}: type={t!r} not in [family, package, app]")
            op = a.get("operation", "remove")
            if op not in ("remove", "clearCache"):
                errors.append(f"{idx}: operation={op!r} not in [remove, clearCache]")

    return errors


def load_profile(profile_name: str, profile_dir: pathlib.Path) -> dict:
    """Load profile overlay YAML. Returns {} if profile_name is None."""
    if not profile_name:
        return {}
    path = profile_dir / f"{profile_name}.yml"
    if not path.is_file():
        raise FileNotFoundError(f"profile not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def build(input_path: pathlib.Path, output_path: pathlib.Path,
          target: str, mode: str, gamepass: str,
          profile_name: str | None = None,
          profile_dir: pathlib.Path | None = None) -> int:
    import json

    doc = load_document(input_path)
    actions = doc.get("actions", [])

    profile = load_profile(profile_name, profile_dir or DEFAULT_PROFILE_DIR)
    tags_deny = set(profile.get("tags_deny", [])) if profile else set()

    try:
        filtered = filter_actions(actions, mode, gamepass, tags_deny=tags_deny)
    except ValueError as e:
        print(f"BUILD FAILED: {e}", file=sys.stderr)
        return 2

    # Rename source-DSL tags to AME wire format (writeStatus -> status, etc.)
    filtered = [convert_source_tag_to_ame(a) for a in filtered]

    # Pre-flight: catch every common AME deserializer landmine BEFORE shipping.
    # AME uses YamlDotNet with strict scalar parsing. Each rule below maps to
    # a real exception class we've already hit (or trivially could).
    errors = preflight_validate(filtered) + preflight_validate_annotations(filtered)
    if errors:
        for e in errors:
            print(f"PREFLIGHT FAIL: {e}", file=sys.stderr)
        return 3

    # AME Wizard's parser is strict: it accepts only title, description,
    # privilege, actions at the top level. Anything else (version, requirements,
    # features, _build_meta) makes it discard the doc as "no applicable tasks".
    # Privilege is mandatory; without it AME cannot decide applicability.
    ame_doc = {
        "title": doc.get("title", "MuulfzOTMZ Playbook"),
        "description": str(doc.get("description", "")).strip(),
        "privilege": "TrustedInstaller",
        "actions": filtered,
    }

    install_json = dict(profile.get("install_json_overrides", {})) if profile else {}
    meta = {
        "target": target,
        "mode": mode,
        "gamepass": gamepass,
        "profile": profile_name,
        "action_count": len(filtered),
        "total_count": len(actions),
        "install_json": install_json,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(ame_doc, f, sort_keys=False, allow_unicode=True)

    meta_path = output_path.with_suffix(output_path.suffix + ".meta.json")
    with meta_path.open("w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, default=str)

    print(f"OK: {len(filtered)}/{len(actions)} actions emitted to {output_path}"
          + (f" (profile={profile_name})" if profile_name else ""))
    print(f"     build meta -> {meta_path}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, type=pathlib.Path)
    ap.add_argument("--output", required=True, type=pathlib.Path)
    ap.add_argument("--target", required=True, choices=sorted(ALLOWED_TARGETS))
    ap.add_argument("--mode", required=True, choices=sorted(ALLOWED_MODES))
    ap.add_argument("--gamepass", default="preserve", choices=sorted(ALLOWED_GAMEPASS))
    ap.add_argument("--profile", default=None, help="Profile overlay name (without .yml)")
    ap.add_argument("--profile-dir", default=None, type=pathlib.Path,
                    help="Override profile directory (defaults to playbook/profiles)")
    args = ap.parse_args()

    return build(args.input, args.output, args.target, args.mode, args.gamepass,
                 profile_name=args.profile, profile_dir=args.profile_dir)


if __name__ == "__main__":
    sys.exit(main())
