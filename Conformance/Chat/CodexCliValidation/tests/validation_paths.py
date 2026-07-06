#!/usr/bin/env python3
"""Shared filesystem locations for internal Codex CLI validation scripts."""

from __future__ import annotations

import os
import pathlib


VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = VALIDATION_DIR.parents[3]


def validation_results_root() -> pathlib.Path:
    """Return the default out-of-tree result root for validation smoke artifacts."""
    override = os.environ.get("CODEX_CHAT_VALIDATION_RESULTS_ROOT")
    if override:
        return pathlib.Path(override).expanduser().resolve()
    return REPO_ROOT / ".build" / "codex-cli-validation" / "results"
