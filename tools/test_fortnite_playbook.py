"""Fortnite playbook: composes + builds clean, and playbook-fortnite.conf obeys AME's rules."""
import pathlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

REPO = pathlib.Path(__file__).parent.parent
CONF = ET.parse(REPO / "playbook" / "playbook-fortnite.conf").getroot()


def built_yaml() -> str:
    with tempfile.TemporaryDirectory() as tmp:
        flat, out = pathlib.Path(tmp) / "flat.yml", pathlib.Path(tmp) / "out.yml"
        for args in (["compose.py", "--input", str(REPO / "playbook" / "main-fortnite.yml"), "--output", str(flat)],
                     ["build.py", "--input", str(flat), "--output", str(out),
                      "--target", "personal", "--mode", "competitive", "--gamepass", "strip"]):
            r = subprocess.run([sys.executable, str(REPO / "tools" / args[0]), *args[1:]], capture_output=True, text=True)
            assert r.returncode == 0, r.stderr
        return out.read_text(encoding="utf-8")


def test_every_option_used_is_defined_in_conf():
    defined = {n.text for n in CONF.find("FeaturePages").iter("Name")}
    used = {m.lstrip("!") for m in re.findall(r"^\s*option: '?([!\w-]+)'?", built_yaml(), re.M)}
    assert used, "no option: fields emitted"
    assert used <= defined, f"options used but not in conf: {used - defined}"


def test_every_powershell_command_parses_as_ame_delivers_it():
    """AME passes `command` on powershell.exe's command line: \"\"\" arrives as ", a bare " is eaten.
    A parse error there exits 1 and AME only logs it as Info -- so parse them all here."""
    import shutil
    import yaml
    sys.path.insert(0, str(REPO / "tools"))
    from ame_yaml import install
    install()
    actions = yaml.safe_load(built_yaml())["actions"]
    cmds = [a["command"] for a in actions if getattr(a, "_ame_tag", None) == "powerShell"]
    assert cmds
    with tempfile.TemporaryDirectory() as tmp:
        for i, c in enumerate(cmds):
            arrived = c.replace('"""', "\0").replace('"', "").replace("\0", '"')
            (pathlib.Path(tmp) / f"{i:03}.ps1").write_text(arrived, encoding="utf-8")
        # Path goes inside the script: with -Command, trailing args do NOT become $args.
        check = (f"$f = Get-ChildItem '{tmp}' -Filter *.ps1; 'parsed ' + $f.Count; $f | ForEach-Object {{ $e = $null; "
                 "[void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e); "
                 "$e | ForEach-Object { \"$($_.Extent.File):$($_.Extent.StartLineNumber) $($_.Message)\" } }")
        pwsh = shutil.which("pwsh") or "powershell"
        r = subprocess.run([pwsh, "-NoProfile", "-Command", check], capture_output=True, text=True)
        assert r.stdout.strip() == f"parsed {len(cmds)}", r.stdout + r.stderr


def test_conf_obeys_ame_rules():
    icons = [b.get("Icon") for b in CONF.iter("BulletPoint")]
    assert sorted(icons) == ["Lock", "Privacy", "Rocket"]  # SupportsISO: exactly 3, distinct
    for page in CONF.find("FeaturePages"):
        lines = sum(page.find(t) is not None for t in ("TopLine", "BottomLine"))
        assert len(page.find("Options")) <= 4 - lines
    builds = {s.text for s in CONF.find("SupportedBuilds")}
    assert "26300" in builds and "28000" not in builds
    # Tournaments need TPM + Secure Boot: never bypass the hardware check.
    assert CONF.find("ISO/DisableHardwareRequirements").text == "false"
