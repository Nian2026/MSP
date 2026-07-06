#!/usr/bin/env python3
"""Verify an MSP final exec-session release gate report and evidence chain."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

from final_gate_verifier_support.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
