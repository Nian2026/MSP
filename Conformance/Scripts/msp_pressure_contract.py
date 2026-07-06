"""Shared contract constants for MSP pressure evidence verification."""

from __future__ import annotations

import re


REQUIRED_MODEL = "gpt-5.5"
REQUIRED_PRESSURE_SUITES = [
    "host-backed",
    "exec-session",
    "mixed-backend",
    "photosorter-virtual",
    "photosorter-exec-session",
]
REQUIRED_PROMPT_FILES = {
    "host-backed": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/host-backed-linux-parity-prompts.json",
    "exec-session": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/exec-session-parity-prompts.json",
    "mixed-backend": "Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/mixed-backend-linux-parity-prompts.json",
    "photosorter-virtual": "Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-virtual-workspace-prompts.json",
    "photosorter-exec-session": "Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-exec-session-parity-prompts.json",
}
REQUIRED_SENTINELS = {
    "host-backed": [
        "PRESSURE_TASK_DONE",
        "PRESSURE_STATE_CHANGE_DONE",
        "PRESSURE_BULK_PERMISSION_DONE",
    ],
    "exec-session": [
        "EXEC_YIELD_POLL_DONE",
        "EXEC_PTY_PYTHON_DONE",
        "EXEC_INTERRUPT_DONE",
    ],
    "mixed-backend": [
        "MIXED_WORKSPACE_TASK_DONE",
        "MIXED_PYTHON_SUBPROCESS_DONE",
        "MIXED_MOVE_DELETE_BATCH_DONE",
    ],
    "photosorter-virtual": [
        "PHOTO_ROOT_DONE",
        "PHOTO_PYTHON_DONE",
        "PHOTO_STATE_BATCH_DONE",
    ],
    "photosorter-exec-session": [
        "EXEC_YIELD_POLL_DONE",
        "EXEC_PTY_PYTHON_DONE",
        "EXEC_INTERRUPT_DONE",
    ],
}
EXEC_SESSION_CONTRACT_SUITES = {"exec-session", "photosorter-exec-session"}
FORBIDDEN_PATTERNS = [
    ("host_user_path", re.compile(r"/Users/[^\s\"'<>]+")),
    ("external_volume_path", re.compile(r"/Volumes/[^\s\"'<>]+")),
    ("private_var_path", re.compile(r"/private/var/[^\s\"'<>]+")),
    ("mobile_var_path", re.compile(r"/var/mobile/[^\s\"'<>]+")),
    ("coresimulator_path", re.compile(r"CoreSimulator/Devices/[A-Fa-f0-9-]+")),
    ("app_container_path", re.compile(r"Containers/Data/Application/[A-Fa-f0-9-]+")),
    ("app_bundle_path", re.compile(r"\b(?:MSPPlaygroundApp|PhotoSorter)\.app\b")),
    ("workspace_container_path", re.compile(r"MSPPlaygroundApp/Workspace")),
    ("python_framework_path", re.compile(r"Python\.framework/[^\s\"'<>]*")),
    ("xcframework_path", re.compile(r"\.xcframework/[^\s\"'<>]*")),
    ("build_mcp_path", re.compile(r"build-mcp/[^\s\"'<>]*")),
    ("launcher_path", re.compile(r"msp-python-launcher\.py")),
    ("cpython_runtime_path", re.compile(r"msp-cpython[^\s\"'<>]*")),
    ("broker_path", re.compile(r"(?:/|\b)[^\s\"'<>]*(?:vfs|subprocess)[-_]broker[^\s\"'<>]*")),
    ("materialized_path", re.compile(r"/[^\s\"'<>]*materiali[sz]ed[^\s\"'<>]*")),
    (
        "plain_ios_sandbox_disclosure",
        re.compile(r"\bios\b[^\n\r]{0,48}\b(?:sandbox|沙盒)\b|沙盒环境", re.IGNORECASE),
    ),
    (
        "plain_sandbox_path_disclosure",
        re.compile(
            r"\bsandbox\b[^\n\r]{0,32}\b(?:path|container|directory|filesystem|file system|environment|runtime|implementation)\b|沙盒(?:路径|容器|目录|文件系统|环境|运行时|实现)",
            re.IGNORECASE,
        ),
    ),
    ("plain_msp_disclosure", re.compile(r"\bmsp(?:playground|runtime|python)?\b", re.IGNORECASE)),
    ("plain_backend_disclosure", re.compile(r"\b(?:broker|materiali[sz]ed|launcher)\b", re.IGNORECASE)),
    (
        "plain_virtual_backend_disclosure",
        re.compile(
            r"\bvirtual\b[^\n\r]{0,32}\b(?:workspace|backend|filesystem|file system|environment|runtime|path)\b|虚拟(?:工作区|后端|文件系统|环境|运行时|路径)",
            re.IGNORECASE,
        ),
    ),
    (
        "plain_host_backend_disclosure",
        re.compile(
            r"\b(?:host[- ]backed|direct[- ]host)\b(?:[^\n\r]{0,32}\b(?:workspace|backend|filesystem|file system|path|directory|runtime|profile|implementation)\b)?|\bhost\b[^\n\r]{0,16}\b(?:workspace|backend|filesystem|file system|path|directory|runtime|profile|implementation)\b|(?:真实)?宿主(?:工作区|后端|文件系统|路径|目录|运行时|配置|实现)",
            re.IGNORECASE,
        ),
    ),
    (
        "plain_photo_backend_disclosure",
        re.compile(
            r"\b(?:photokit|phasset|phfetchresult|phassetcollection|photos\.framework)\b|\b(?:asset\s+)?localidentifier\b|照片库(?:后端|实现|本地标识)|相册后端",
            re.IGNORECASE,
        ),
    ),
    ("plain_simulator_disclosure", re.compile(r"\b(?:ios\s+simulator|coresimulator|simctl|iphonesimulator)\b", re.IGNORECASE)),
    ("plain_app_container_disclosure", re.compile(r"\b(?:app|application|ios)\s+container\b|应用容器", re.IGNORECASE)),
]


def required_pressure_turn_count(name: str) -> int:
    return len(REQUIRED_SENTINELS.get(name, [])) + 1


def required_prompt_file(name: str) -> str | None:
    return REQUIRED_PROMPT_FILES.get(name)
