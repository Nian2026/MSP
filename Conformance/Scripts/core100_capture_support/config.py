from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_CASES = ROOT / "Conformance" / "OracleCapture" / "Core100CaptureCases.generated.json"
DEFAULT_OUTPUT = ROOT / "Conformance" / "ReferenceOutputs" / "MSPV1Core100Debian12Oracle" / "noninteractive-cases.json"
DEFAULT_RAW_DIR = ROOT / ".codex-tmp" / "core100-oracle-capture"
DEFAULT_KNOWN_HOSTS = DEFAULT_RAW_DIR / "known_hosts"

CASE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
COMMAND_NAME_RE = re.compile(r"^[A-Za-z0-9_.:+\[\]-]+$")
SAFE_RELATIVE_PATH_RE = re.compile(r"^[A-Za-z0-9._/@+=,:% -]+$")
REMOTE_RUN_ROOT_PREFIX = "/tmp/msp-oracle-capture-"
MAX_CASES_PER_RUN = 1000
MAX_COMMAND_LINE_BYTES = 16 * 1024
MAX_STDIN_BYTES = 64 * 1024
MAX_FIXTURE_DIRECTORIES = 512
MAX_FIXTURE_FILES = 512
MAX_FIXTURE_FILE_BYTES = 1024 * 1024
MAX_STDOUT_BYTES = 512 * 1024
MAX_STDERR_BYTES = 512 * 1024
MAX_FILE_CONTENT_BYTES = 64 * 1024
MAX_FILE_TREE_RECORDS = 4096
MAX_FILE_TREE_BYTES = 8 * 1024 * 1024
MAX_CREATED_FILE_BYTES = 4 * 1024 * 1024
FORBIDDEN_PATTERNS = [
    r"\bsudo\b",
    r"\bsu\b",
    r"\bdoas\b",
    r"\bsystemctl\b",
    r"\bservice\b",
    r"\bmount\b",
    r"\bumount\b",
    r"\bmkfs\b",
    r"\bfdisk\b",
    r"\bparted\b",
    r"\bdd\s+[^;\n]*\bof=/dev/",
    r"\bdd\s+[^;\n]*\bif=/dev/",
    r">\s*/dev/",
    r"\bchmod\s+-R\s+/",
    r"\bchown\b",
    r"\bchgrp\b",
    r"\brm\s+-[A-Za-z]*r[A-Za-z]*f[A-Za-z]*\s+/",
    r"\brm\s+-[A-Za-z]*f[A-Za-z]*r[A-Za-z]*\s+/",
    r"\brm\s+-[A-Za-z]*r[A-Za-z]*\s+/",
    r"\bfind\s+/\s+[^;\n]*-delete\b",
    r"\bfind\s+/\s+[^;\n]*-exec\s+rm\b",
    r"(?<![A-Za-z0-9_./\\-])curl(?![A-Za-z0-9_./-])",
    r"(?<![A-Za-z0-9_./\\-])wget(?![A-Za-z0-9_./-])",
    r"(?<![A-Za-z0-9_./\\-])nc(?![A-Za-z0-9_./-])",
    r"(?<![A-Za-z0-9_./\\-])ncat(?![A-Za-z0-9_./-])",
    r"(?<![A-Za-z0-9_./\\-])telnet(?![A-Za-z0-9_./-])",
    r"\bssh\b",
    r"\bscp\b",
    r"\brsync\b",
]
FORBIDDEN_ABSOLUTE_PREFIXES = [
    "/bin",
    "/boot",
    "/dev",
    "/etc",
    "/home",
    "/lib",
    "/lib64",
    "/media",
    "/mnt",
    "/opt",
    "/proc",
    "/root",
    "/run",
    "/sbin",
    "/srv",
    "/sys",
    "/usr",
    "/var",
]
ALLOWED_ABSOLUTE_SNIPPETS = {
    "/bin/sh",
    "/bin/bash",
    "/usr/bin/env",
}
