"""
Shared helper: make yaml.safe_load / yaml.safe_dump round-trip AME Wizard's
custom YAML tags (!registryValue, !powerShell, !writeStatus, !download, etc.).

AME tags wrap either a scalar (`!writeStatus "msg"`) or a mapping (`!registryValue { path: ..., value: ... }`).
We wrap both in `AmeAction` (a dict subclass) so existing dict-based filter logic
works unchanged.
"""
from __future__ import annotations

import yaml


class AmeAction(dict):
    """Dict subclass that carries an AME YAML tag for round-trip."""

    _ame_tag: str | None = None
    _ame_scalar: str | None = None

    def __init__(self, tag, data):
        self._ame_tag = tag
        self._ame_scalar = None
        if isinstance(data, dict):
            super().__init__(data)
        elif data is None:
            super().__init__()
        else:
            super().__init__()
            self._ame_scalar = str(data)


def _construct_ame(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        data = loader.construct_scalar(node)
    elif isinstance(node, yaml.MappingNode):
        data = loader.construct_mapping(node, deep=True)
    elif isinstance(node, yaml.SequenceNode):
        data = loader.construct_sequence(node, deep=True)
    else:
        data = None
    return AmeAction(tag_suffix, data)


def _represent_ame(dumper, action: AmeAction):
    tag = "!" + (action._ame_tag or "unknown")
    if action._ame_scalar is not None:
        return dumper.represent_scalar(tag, action._ame_scalar)
    return dumper.represent_mapping(tag, dict(action))


def install():
    """Register constructors + representers on the shared SafeLoader/SafeDumper."""
    yaml.SafeLoader.add_multi_constructor("!", _construct_ame)
    yaml.SafeDumper.add_representer(AmeAction, _represent_ame)


# Install on import so any module that `import ame_yaml` picks this up.
install()
