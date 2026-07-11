#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
APP_DIR="$ROOT_DIR/Examples/iOS/MSPPlaygroundApp"
PROJECT="$APP_DIR/Project/MSPPlaygroundApp.xcodeproj"
BUILD_DIR="$APP_DIR/Project/build"
APP_BUNDLE="$BUILD_DIR/Debug-iphonesimulator/MSPPlaygroundApp.app"
BUNDLE_ID="${MSP_PLAYGROUND_FIXTURE_BUNDLE_ID:-${MSP_EXAMPLE_BUNDLE_ID_PREFIX:-com.modelshellproxy.examples}.playground}"
OUT_DIR="${MSP_PLAYGROUND_FIXTURE_OUT_DIR:-/tmp/msp-playground-fixture}"
RESET_APP="${MSP_PLAYGROUND_FIXTURE_RESET_APP:-0}"
TIMEOUT_SECONDS="${MSP_PLAYGROUND_FIXTURE_TIMEOUT_SECONDS:-60}"
FIXTURE_VARIANT="${MSP_PLAYGROUND_FIXTURE_VARIANT:-completed}"
LOCK_DIRS=("")

release_locks() {
  local lock_dir
  for lock_dir in "${LOCK_DIRS[@]}"; do
    [[ -n "$lock_dir" ]] && rm -rf "$lock_dir"
  done
  return 0
}

trap release_locks EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_ui_e2e_lock() {
  if [[ "${MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD:-0}" == "1" ]]; then
    return
  fi

  local lock_dir="$ROOT_DIR/.build/msp-conformance/locks/real-model-ui-pressure.lock"
  local lock_parent
  lock_parent="$(dirname "$lock_dir")"
  mkdir -p "$lock_parent"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_dir/pid"
    printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
    LOCK_DIRS+=("$lock_dir")
    export MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD=1
    echo "MSP UI E2E lock: $lock_dir"
    return
  fi

  local existing_pid=""
  if [[ -f "$lock_dir/pid" ]]; then
    existing_pid="$(head -n 1 "$lock_dir/pid" 2>/dev/null || true)"
  fi
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "MSP UI E2E is already running under pid $existing_pid; refusing to run concurrently" >&2
    if [[ -f "$lock_dir/context" ]]; then
      cat "$lock_dir/context" >&2
    fi
    exit 2
  fi

  echo "removing stale MSP UI E2E lock: $lock_dir" >&2
  rm -rf "$lock_dir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "failed to acquire MSP UI E2E lock: $lock_dir" >&2
    exit 2
  fi
  printf '%s\n' "$$" >"$lock_dir/pid"
  printf 'out_dir=%s\n' "$OUT_DIR" >"$lock_dir/context"
  LOCK_DIRS+=("$lock_dir")
  export MSP_REAL_MODEL_UI_PRESSURE_LOCK_HELD=1
  echo "MSP UI E2E lock: $lock_dir"
}

mkdir -p "$OUT_DIR"
acquire_ui_e2e_lock

DEVICE_ID="${MSP_PLAYGROUND_FIXTURE_DEVICE_ID:-}"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/Booted/ { print $2; exit }')"
fi
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && /Shutdown/ { print $2; exit }')"
  if [[ -z "$DEVICE_ID" ]]; then
    echo "no available iOS simulator found" >&2
    exit 2
  fi
  xcrun simctl boot "$DEVICE_ID" >/dev/null
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme MSPPlaygroundApp \
  -sdk iphonesimulator \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR/Debug-iphonesimulator" \
  build >/tmp/msp-playground-fixture-xcodebuild.log

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$RESET_APP" == "1" ]]; then
  xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl install "$DEVICE_ID" "$APP_BUNDLE"

APP_DATA="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"
EVENT_LOG="$APP_DATA/Documents/msp-playground-e2e-events.jsonl"
rm -f "$EVENT_LOG"

STDOUT_LOG="$OUT_DIR/app.stdout.log"
STDERR_LOG="$OUT_DIR/app.stderr.log"
rm -f "$STDOUT_LOG" "$STDERR_LOG"

SIMCTL_CHILD_MSP_PLAYGROUND_E2E_LOG_EVENTS=1 \
SIMCTL_CHILD_MSP_PLAYGROUND_TRANSCRIPT_VISIBLE_TEXT_PROBE=1 \
xcrun simctl launch \
  --terminate-running-process \
  --stdout="$STDOUT_LOG" \
  --stderr="$STDERR_LOG" \
  "$DEVICE_ID" \
  "$BUNDLE_ID" \
  --msp-e2e-log-events \
  --msp-probe-transcript-visible-text \
  --msp-expand-transcript-tool-details \
  --msp-transcript-fixture="$FIXTURE_VARIANT" >/tmp/msp-playground-fixture-launch.log

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if [[ -f "$EVENT_LOG" ]] && grep -q '"event":"fixture_loaded"' "$EVENT_LOG"; then
    break
  fi
  sleep 1
done

if [[ ! -f "$EVENT_LOG" ]]; then
  echo "event log was not created: $EVENT_LOG" >&2
  exit 1
fi

if ! grep -q '"event":"fixture_loaded"' "$EVENT_LOG"; then
  echo "fixture_loaded was not observed before timeout" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if ! grep -q "\"variant\":\"$FIXTURE_VARIANT\"" "$EVENT_LOG"; then
  echo "fixture variant '$FIXTURE_VARIANT' was not observed" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if grep -q '"event":"transcript_visible_text_probe"' "$EVENT_LOG"; then
    break
  fi
  sleep 1
done

if ! grep -q '"event":"transcript_visible_text_probe"' "$EVENT_LOG"; then
  echo "transcript visible text probe was not observed" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"contains_exec_command":"true"' "$EVENT_LOG"; then
  echo "transcript visibly leaked exec_command" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"contains_shell_json_keys":"true"' "$EVENT_LOG"; then
  echo "transcript visibly leaked shell JSON keys" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"contains_internal_shell_tool_name":"true"' "$EVENT_LOG"; then
  echo "transcript visibly leaked internal shell tool name" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"main_flow_contains_tool_stdout_sentinel":"true"' "$EVENT_LOG"; then
  echo "transcript main flow leaked tool stdout as ordinary text" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if grep -q '"main_flow_contains_tool_stderr_sentinel":"true"' "$EVENT_LOG"; then
  echo "transcript main flow leaked tool stderr as ordinary text" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

if [[ "$FIXTURE_VARIANT" == "failed" ]] \
  && grep -q '"main_flow_contains_command_not_found":"true"' "$EVENT_LOG"; then
  echo "failed fixture main flow leaked raw command error" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

sleep "${MSP_PLAYGROUND_FIXTURE_DOM_PROBE_SETTLE_SECONDS:-3}"

python3 - "$EVENT_LOG" "$FIXTURE_VARIANT" <<'PY'
import json
import statistics
import sys

event_log = sys.argv[1]
variant = sys.argv[2]

probes = []
with open(event_log, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("event") != "transcript_visible_text_probe":
            continue
        probes.append(record.get("fields") or {})

if not probes:
    print("no transcript DOM probes were recorded", file=sys.stderr)
    sys.exit(1)

themes = [probe.get("chat_transcript_theme", "") for probe in probes]
if "codex" not in themes:
    print("ExampleChat transcript theme was not codex: " + ",".join(themes), file=sys.stderr)
    sys.exit(1)

latest_layout_probe = next(
    (probe for probe in reversed(probes) if probe.get("message_layouts", "").strip()),
    None,
)
if latest_layout_probe is None:
    print("no message layout probe data was recorded", file=sys.stderr)
    sys.exit(1)


def parse_layouts(raw):
    layouts = []
    for part in raw.split("|"):
        part = part.strip()
        if not part:
            continue
        pieces = part.split(":")
        if len(pieces) != 6:
            continue
        role = pieces[0] or pieces[1]
        try:
            layouts.append(
                {
                    "role": role,
                    "left": float(pieces[2]),
                    "right": float(pieces[3]),
                    "width": float(pieces[4]),
                    "center": float(pieces[5]),
                }
            )
        except ValueError:
            continue
    return layouts


layouts = parse_layouts(latest_layout_probe.get("message_layouts", ""))
layout_roles = {layout["role"] for layout in layouts}
if not {"user", "assistant"}.issubset(layout_roles):
    print(
        "message layouts did not include both user and assistant roles: "
        + latest_layout_probe.get("message_layouts", ""),
        file=sys.stderr,
    )
    sys.exit(1)

user_centers = [layout["center"] for layout in layouts if layout["role"] == "user"]
assistant_centers = [layout["center"] for layout in layouts if layout["role"] == "assistant"]
if not user_centers or not assistant_centers:
    print("could not compute user/assistant message centers", file=sys.stderr)
    sys.exit(1)
if statistics.mean(user_centers) <= statistics.mean(assistant_centers):
    print(
        "user message was not laid out to the right of assistant message: "
        + latest_layout_probe.get("message_layouts", ""),
        file=sys.stderr,
    )
    sys.exit(1)

visible_role_text = " | ".join(
    probe.get("visible_message_role_texts", "") for probe in probes
).strip()
for forbidden in ("你", "User", "Assistant", "模型", "gpt"):
    if forbidden.lower() in visible_role_text.lower():
        print("visible message role/model label leaked: " + visible_role_text, file=sys.stderr)
        sys.exit(1)

def max_int_field(name):
    values = []
    for probe in probes:
        raw = probe.get(name, "")
        try:
            values.append(int(raw))
        except (TypeError, ValueError):
            pass
    return max(values or [0])

if variant == "markdown":
    if max_int_field("katex_element_count") < 1:
        print("markdown fixture did not render KaTeX math from vendored resources", file=sys.stderr)
        sys.exit(1)
    if max_int_field("highlighted_code_element_count") < 1:
        print("markdown fixture did not render highlighted code from vendored resources", file=sys.stderr)
        sys.exit(1)
    if max_int_field("markdown_code_block_count") < 1:
        print("markdown fixture did not render a markdown code block", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

all_processing_titles = " | ".join(
    " | ".join(
        part
        for part in (
            probe.get("chat_terminal_support_line_titles", ""),
            probe.get("chat_support_line_titles", ""),
            probe.get("chat_tool_activity_item_titles", ""),
            probe.get("chat_apply_patch_activity_titles", ""),
            probe.get("chat_processing_titles", ""),
            probe.get("chat_tool_activity_titles", ""),
        )
        if part
    )
    for probe in probes
)
expected_title = {
    "completed": "已执行工作区命令",
    "running": "正在执行工作区命令",
    "thinking": "正在思考",
    "failed": "工作区命令执行失败",
    "apply_patch": "已编辑 3 个文件",
}.get(variant, "已执行工作区命令")
if expected_title not in all_processing_titles:
    print(
        f"expected ExampleChat activity title {expected_title!r} was not visible in processing blocks: "
        + all_processing_titles,
        file=sys.stderr,
    )
    sys.exit(1)
if variant == "thinking":
    if max_int_field("live_chat_processing_block_count") < 1:
        print("thinking fixture did not render a live ExampleChat processing block", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
if variant == "apply_patch":
    if max_int_field("chat_apply_patch_diff_card_count") < 1:
        print("apply_patch fixture did not render the ExampleChat apply_patch diff card", file=sys.stderr)
        sys.exit(1)
    if "已编辑 outline.md" not in all_processing_titles:
        print("apply_patch fixture did not render per-file edit rows: " + all_processing_titles, file=sys.stderr)
        sys.exit(1)
    if "changed paths" in all_processing_titles or "退出码" in all_processing_titles:
        print("apply_patch fixture leaked generic tool output text: " + all_processing_titles, file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
terminal_titles = " | ".join(
    " | ".join(
        part
        for part in (
            probe.get("chat_terminal_support_line_titles", ""),
            probe.get("chat_tool_activity_item_titles", ""),
        )
        if part
    )
    for probe in probes
)
if expected_title not in terminal_titles:
    print(
        f"expected ExampleChat shell title {expected_title!r} was not attached to a terminal support line: "
        + terminal_titles,
        file=sys.stderr,
    )
    sys.exit(1)
if "模型准备调用" in all_processing_titles or "exec_command" in all_processing_titles:
    print("internal tool preparation text leaked into tool titles: " + all_processing_titles, file=sys.stderr)
    sys.exit(1)

class_names = " | ".join(probe.get("chat_processing_class_names", "") for probe in probes)
if "readex-processing-block" not in class_names:
    print("ExampleChat processing block class was not present: " + class_names, file=sys.stderr)
    sys.exit(1)

terminal_icon_counts = []
for probe in probes:
    raw_count = probe.get("terminal_command_icon_count", "")
    try:
        terminal_icon_counts.append(int(raw_count))
    except (TypeError, ValueError):
        pass
if max(terminal_icon_counts or [0]) < 1:
    print("ExampleChat terminal command icon was not rendered", file=sys.stderr)
    sys.exit(1)

if max_int_field("tool_activity_disclosure_count") < 1:
    print("ExampleChat tool activity disclosure row was not rendered", file=sys.stderr)
    sys.exit(1)
if max_int_field("shell_execution_disclosure_count") < 1:
    print("ExampleChat shell execution disclosure was not rendered", file=sys.stderr)
    sys.exit(1)

if variant == "completed":
    if max_int_field("shell_execution_output_block_count") < 1:
        print("completed fixture did not render shell stdout in the ExampleChat tool details", file=sys.stderr)
        sys.exit(1)
    if not any(probe.get("shell_output_contains_tool_stdout_sentinel") == "true" for probe in probes):
        print("completed fixture shell stdout sentinel was not found inside tool details", file=sys.stderr)
        sys.exit(1)
if variant == "failed":
    if max_int_field("shell_execution_output_block_count") < 1:
        print("failed fixture did not render shell stderr in the ExampleChat tool details", file=sys.stderr)
        sys.exit(1)
    if not any(probe.get("shell_output_contains_tool_stderr_sentinel") == "true" for probe in probes):
        print("failed fixture shell stderr sentinel was not found inside tool details", file=sys.stderr)
        sys.exit(1)
    if not any(probe.get("shell_output_contains_command_not_found") == "true" for probe in probes):
        print("failed fixture command error was not found inside tool details", file=sys.stderr)
        sys.exit(1)
PY

if [[ "$FIXTURE_VARIANT" == "running" || "$FIXTURE_VARIANT" == "thinking" ]]; then
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if python3 - "$EVENT_LOG" >/dev/null 2>&1 <<'PY'
import json
import sys

event_log = sys.argv[1]
duration_samples = []
live_samples = 0
with open(event_log, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("event") != "transcript_visible_text_probe":
            continue
        fields = record.get("fields") or {}
        if fields.get("live_chat_processing_block_count") not in ("", "0", None):
            live_samples += 1
        raw_seconds = fields.get("chat_processing_duration_seconds", "")
        for part in raw_seconds.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                duration_samples.append(int(part))
            except ValueError:
                pass

if live_samples < 1:
    print("running fixture did not expose a live ExampleChat processing block", file=sys.stderr)
    sys.exit(1)
if len(duration_samples) < 2:
    print("running fixture did not produce repeated ExampleChat processing timer samples", file=sys.stderr)
    sys.exit(1)
if max(duration_samples) <= min(duration_samples):
    print(
        "running fixture ExampleChat processing timer did not advance: "
        + ",".join(str(value) for value in duration_samples),
        file=sys.stderr,
    )
    sys.exit(1)
PY
    then
      break
    fi
    sleep 1
  done

  python3 - "$EVENT_LOG" <<'PY'
import json
import sys

event_log = sys.argv[1]
duration_samples = []
live_samples = 0
with open(event_log, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("event") != "transcript_visible_text_probe":
            continue
        fields = record.get("fields") or {}
        if fields.get("live_chat_processing_block_count") not in ("", "0", None):
            live_samples += 1
        raw_seconds = fields.get("chat_processing_duration_seconds", "")
        for part in raw_seconds.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                duration_samples.append(int(part))
            except ValueError:
                pass

if live_samples < 1:
    print("running fixture did not expose a live ExampleChat processing block", file=sys.stderr)
    sys.exit(1)
if len(duration_samples) < 2:
    print("running fixture did not produce repeated ExampleChat processing timer samples", file=sys.stderr)
    sys.exit(1)
if max(duration_samples) <= min(duration_samples):
    print(
        "running fixture ExampleChat processing timer did not advance: "
        + ",".join(str(value) for value in duration_samples),
        file=sys.stderr,
    )
    sys.exit(1)
PY
elif [[ "$FIXTURE_VARIANT" == "markdown" ]]; then
  :
else
  python3 - "$EVENT_LOG" "$FIXTURE_VARIANT" <<'PY'
import json
import sys

event_log = sys.argv[1]
variant = sys.argv[2]
duration_samples = []
live_samples = 0
with open(event_log, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("event") != "transcript_visible_text_probe":
            continue
        fields = record.get("fields") or {}
        if fields.get("live_chat_processing_block_count") not in ("", "0", None):
            live_samples += 1
        raw_seconds = fields.get("chat_processing_duration_seconds", "")
        for part in raw_seconds.split(","):
            part = part.strip()
            if not part:
                continue
            try:
                duration_samples.append(int(part))
            except ValueError:
                pass

if live_samples:
    print(f"{variant} fixture exposed live ExampleChat processing blocks after completion", file=sys.stderr)
    sys.exit(1)
if not duration_samples:
    print(f"{variant} fixture did not expose a frozen ExampleChat processing duration", file=sys.stderr)
    sys.exit(1)
PY
fi

cp "$EVENT_LOG" "$OUT_DIR/events.jsonl"
if [[ -f /tmp/msp-playground-fixture-xcodebuild.log ]]; then
  cp /tmp/msp-playground-fixture-xcodebuild.log "$OUT_DIR/xcodebuild.log"
fi
if [[ -f /tmp/msp-playground-fixture-launch.log ]]; then
  cp /tmp/msp-playground-fixture-launch.log "$OUT_DIR/launch.log"
fi

sleep "${MSP_PLAYGROUND_FIXTURE_SETTLE_SECONDS:-2}"

SCREENSHOT="$OUT_DIR/screenshot.png"
xcrun simctl io "$DEVICE_ID" screenshot "$SCREENSHOT" >/dev/null

echo "MSPPlaygroundApp transcript fixture visual check captured"
echo "device=$DEVICE_ID"
echo "variant=$FIXTURE_VARIANT"
echo "screenshot=$SCREENSHOT"
echo "event_log=$OUT_DIR/events.jsonl"
echo "stdout=$STDOUT_LOG"
echo "stderr=$STDERR_LOG"
echo "xcodebuild_log=$OUT_DIR/xcodebuild.log"
echo "launch_log=$OUT_DIR/launch.log"
