from __future__ import annotations

from typing import Any, Callable

CaseAdder = Callable[[str, list[tuple[str, str, dict[str, Any] | None]]], None]
FileItemFactory = Callable[[str, bytes | str, str], dict[str, Any]]

def add_required_c_cases(add: CaseAdder, add_required: CaseAdder, file_item: FileItemFactory, shell_file: dict[str, Any], source_file: dict[str, Any]) -> None:
    add_required("stat", [
        ("format", "printf abc > f; stat -c '%n %F %s %a' f", {"commands": ["stat", "printf"]}),
        ("filesystem", "stat -f -c '%T' .", {"commands": ["stat"]}),
        ("terse", "printf abc > f; stat -t f | cut -d ' ' -f 1,2", {"commands": ["stat", "printf", "cut"]}),
        ("missing", "stat missing; printf 'status:%s\\n' \"$?\"", {"commands": ["stat", "printf"]}),
    ])

    add_required("sum", [
        ("sysv", "printf abc > f; sum f", {"commands": ["sum", "printf"]}),
        ("bsd", "printf abc > f; sum -r f", {"commands": ["sum", "printf"]}),
        ("multiple", "printf a > a; printf b > b; sum a b", {"commands": ["sum", "printf"]}),
        ("missing", "sum missing; printf 'status:%s\\n' \"$?\"", {"commands": ["sum", "printf"]}),
    ])

    add_required("tac", [
        ("file", "printf 'a\\nb\\n' > f; tac f", {"commands": ["tac", "printf"]}),
        ("stdin", "printf 'a\\nb\\n' | tac", {"commands": ["tac", "printf"]}),
        ("separator", "printf 'a:b:c' | tac -s ':'", {"commands": ["tac", "printf"]}),
        ("missing", "tac missing; printf 'status:%s\\n' \"$?\"", {"commands": ["tac", "printf"]}),
    ])

    add_required("tail", [
        ("lines", "seq 1 5 | tail -n 2", {"commands": ["tail", "seq"]}),
        ("bytes", "printf abcdef | tail -c 3", {"commands": ["tail", "printf"]}),
        ("from-start", "seq 1 5 | tail -n +3", {"commands": ["tail", "seq"]}),
        ("file", "seq 1 3 > nums; tail nums", {"commands": ["tail", "seq"]}),
        ("bytes-from-start", "printf abcdef | tail -c +4", {"commands": ["tail", "printf"]}),
        ("zero-records", "printf 'a\\0b\\0c\\0' | tail -z -n 2 | od -An -tx1", {"commands": ["tail", "printf", "od"]}),
        ("byte-suffix", "python3 - <<'PY' | tail -c 1K | wc -c\nimport sys\nsys.stdout.buffer.write(b'y' * 1100)\nPY", {"commands": ["tail", "python3", "wc"]}),
        ("multi-file-stdin-headers", "printf 'file-a\\nfile-b\\n' > nums; printf 'stdin-a\\nstdin-b\\n' | tail -n 1 - nums -", {"commands": ["tail", "printf"]}),
        ("file-zero-records", "python3 - <<'PY'\nopen('records.bin','wb').write(b'a\\0b\\0c\\0')\nPY\ntail -z -n 2 records.bin | od -An -tx1", {"commands": ["tail", "python3", "od"]}),
    ])

    add_required("tee", [
        ("stdout-file", "printf 'tee\\n' | tee out; cat out", {"commands": ["tee", "printf", "cat"]}),
        ("append", "printf old > out; printf new | tee -a out; cat out", {"commands": ["tee", "printf", "cat"]}),
        ("multiple", "printf x | tee a b; printf '\\n'; cat a b", {"commands": ["tee", "printf", "cat"]}),
        ("binary-mirror", "python3 - <<'PY' | tee out | od -An -tx1; od -An -tx1 out\nimport sys\nsys.stdout.buffer.write(bytes([0xff, 0x00, 0x41]))\nPY", {"commands": ["tee", "python3", "od"]}),
        ("one-output-open-error-continues", "mkdir denied; printf data | tee denied out; printf 'status:%s\\n' \"$?\"; cat out", {"commands": ["tee", "mkdir", "printf", "cat"]}),
        ("output-error-invalid", "tee --output-error=bad out; printf 'status:%s\\n' \"$?\"", {"commands": ["tee", "printf"]}),
        ("output-error-warn", "printf x | tee --output-error=warn out; cat out", {"commands": ["tee", "printf", "cat"]}),
    ])

    add_required("test", [
        ("string", "test -n value; printf 'status:%s\\n' \"$?\"", {"commands": ["test", "printf"]}),
        ("file", ": > f; test -f f; printf 'status:%s\\n' \"$?\"", {"commands": ["test", ":", "printf"]}),
        ("integer", "test 3 -gt 2; printf 'status:%s\\n' \"$?\"", {"commands": ["test", "printf"]}),
        ("invalid", "test 1 -bad 2; printf 'status:%s\\n' \"$?\"", {"commands": ["test", "printf"]}),
    ])

    add_required("touch", [
        ("create", "touch f; stat -c '%s' f", {"commands": ["touch", "stat"]}),
        ("date", "touch -d @0 f; stat -c '%Y' f", {"commands": ["touch", "stat"]}),
        ("reference", "touch -d @0 ref; touch -r ref f; stat -c '%Y' f", {"commands": ["touch", "stat"]}),
        ("no-create", "touch -c missing; test ! -e missing; printf 'status:%s\\n' \"$?\"", {"commands": ["touch", "test", "printf"]}),
    ])

    add_required("timeout", [
        ("success", "timeout 1 printf ok", {"commands": ["timeout", "printf"]}),
        ("false-status", "timeout 1 false; printf 'status:%s\\n' \"$?\"", {"commands": ["timeout", "false", "printf"]}),
        ("expired", "timeout 0.05 sleep 1; printf 'status:%s\\n' \"$?\"", {"commands": ["timeout", "sleep", "printf"], "timeout_seconds": 2.0}),
        ("invalid-duration", "timeout bad printf hi; printf 'status:%s\\n' \"$?\"", {"commands": ["timeout", "printf"]}),
    ])

    add_required("tr", [
        ("translate", "printf abc | tr a-z A-Z", {"commands": ["tr", "printf"]}),
        ("delete", "printf 'a1b2\\n' | tr -d '0-9'", {"commands": ["tr", "printf"]}),
        ("squeeze", "printf 'aaabbb\\n' | tr -s ab", {"commands": ["tr", "printf"]}),
        ("complement", "printf 'abc123\\n' | tr -cd '0-9\\n'", {"commands": ["tr", "printf"]}),
        ("octal", "printf 'ababa\\n' | tr '\\141\\142' XY", {"commands": ["tr", "printf"]}),
        ("raw-high-bytes", "python3 - <<'PY' | tr '\\377\\376' XY | od -An -tx1\nimport sys\nsys.stdout.buffer.write(bytes([0xff, 0xfe, 0x41, 0x0a]))\nPY", {"commands": ["tr", "python3", "od"]}),
        ("delete-nul", "python3 - <<'PY' | tr -d '\\000' | od -An -tx1\nimport sys\nsys.stdout.buffer.write(bytes([0x41, 0x00, 0x42]))\nPY", {"commands": ["tr", "python3", "od"]}),
        ("repeat", "printf 'abc cab\\n' | tr abc '[X*3]'", {"commands": ["tr", "printf"]}),
        ("operand-count-delete-extra", "printf a | tr -d a b; printf 'status:%s\\n' \"$?\"", {"commands": ["tr", "printf"]}),
        ("class-lower-to-upper", "printf 'aB3 z\\n' | tr '[:lower:]' '[:upper:]'", {"commands": ["tr", "printf"]}),
        ("class-delete-alpha", "printf 'a1 B2!\\n' | tr -d '[:alpha:]'", {"commands": ["tr", "printf"]}),
        ("class-squeeze-blank", "printf 'a   b\\t\\tc\\n' | tr -s '[:blank:]' ' ' | od -An -tx1", {"commands": ["tr", "printf", "od"]}),
        ("complement-delete-squeeze", "printf 'one,,two!!three\\n' | tr -cs '[:alnum:]' '\\n'", {"commands": ["tr", "printf"]}),
        ("invalid-byte-delete-ascii", "python3 - <<'PY' | tr -d A | od -An -tx1\nimport sys\nsys.stdout.buffer.write(bytes([0xff,0x41,0x42,0x0a]))\nPY", {"commands": ["tr", "python3", "od"]}),
        ("nul-translate", "python3 - <<'PY' | tr '\\000' Z | od -An -tx1\nimport sys\nsys.stdout.buffer.write(bytes([0x41,0x00,0x42,0x00]))\nPY", {"commands": ["tr", "python3", "od"]}),
        ("repeat-octal-count", "printf 'abca\\n' | tr abc '[\\130*4]'", {"commands": ["tr", "printf"]}),
        ("equivalence-class-c-locale", "printf 'abc cab\\n' | tr '[=a=]' A", {"commands": ["tr", "printf"]}),
        ("huge-byte-stream", "python3 - <<'PY' | tr a b | wc -c\nimport sys\nsys.stdout.buffer.write(b'a' * 200000)\nPY", {"commands": ["tr", "python3", "wc"], "timeout_seconds": 10.0}),
    ])

    add_required("true", [
        ("status", "true; printf 'status:%s\\n' \"$?\"", {"commands": ["true", "printf"]}),
        ("extra", "true extra; printf 'status:%s\\n' \"$?\"", {"commands": ["true", "printf"]}),
    ])

    add_required("tty", [
        ("default", "tty; printf 'status:%s\\n' \"$?\"", {"commands": ["tty", "printf"]}),
        ("silent", "tty -s; printf 'status:%s\\n' \"$?\"", {"commands": ["tty", "printf"]}),
        ("invalid", "tty -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["tty", "printf"]}),
    ])

    add_required("type", [
        ("builtin", "type cd", {"commands": ["type"]}),
        ("kind", "type -t cd; type -t printf; type -t definitely_missing; printf 'status:%s\\n' \"$?\"", {"commands": ["type", "printf"]}),
        ("all", "type -a printf | head -n 3", {"commands": ["type", "head"]}),
    ])

    add_required("uniq", [
        ("default", "printf 'a\\na\\nb\\n' | uniq", {"commands": ["uniq", "printf"]}),
        ("count", "printf 'a\\na\\nb\\n' | uniq -c", {"commands": ["uniq", "printf"]}),
        ("duplicates", "printf 'a\\na\\nb\\n' | uniq -d", {"commands": ["uniq", "printf"]}),
        ("skip-fields", "printf '1 a\\n2 a\\n3 b\\n' | uniq -f1", {"commands": ["uniq", "printf"]}),
        ("group", "printf 'a\\na\\nb\\nc\\nc\\n' | uniq --group", {"commands": ["uniq", "printf"]}),
        ("all-repeated-separate", "printf 'a\\na\\nb\\nc\\nc\\n' | uniq --all-repeated=separate", {"commands": ["uniq", "printf"]}),
        ("group-conflict", "printf 'a\\na\\n' | uniq --group -d; printf 'status:%s\\n' \"$?\"", {"commands": ["uniq", "printf"]}),
        ("group-invalid", "uniq --group=bad; printf 'status:%s\\n' \"$?\"", {"commands": ["uniq", "printf"]}),
        ("all-repeated-invalid", "uniq --all-repeated=bad; printf 'status:%s\\n' \"$?\"", {"commands": ["uniq", "printf"]}),
    ])

    add_required("wc", [
        ("lines", "printf 'a\\nb\\n' | wc -l", {"commands": ["wc", "printf"]}),
        ("bytes", "printf abc | wc -c", {"commands": ["wc", "printf"]}),
        ("chars", "printf 'é\\n' | wc -m", {"commands": ["wc", "printf"]}),
        ("file-total", "printf a > a; printf bb > b; wc -c a b", {"commands": ["wc", "printf"]}),
        ("files0-from", "printf a > a; printf bb > b; printf 'a\\0b\\0' > list; wc -c --files0-from=list", {"commands": ["wc", "printf"]}),
        ("files0-from-stdin", "printf a > a; printf 'a\\0' | wc -c --files0-from=-", {"commands": ["wc", "printf"]}),
        ("files0-from-empty", ": > list; wc -c --files0-from=list; printf 'status:%s\\n' \"$?\"", {"commands": ["wc", ":", "printf"]}),
        ("nul-bytes", "python3 - <<'PY' | wc -c -w -l\nimport sys\nsys.stdout.buffer.write(bytes([0x41, 0x00, 0x42, 0x0a]))\nPY", {"commands": ["wc", "python3"]}),
        ("invalid-utf8", "python3 - <<'PY' | wc -m -w -c\nimport sys\nsys.stdout.buffer.write(bytes([0xff, 0x20, 0x41, 0x0a]))\nPY", {"commands": ["wc", "python3"]}),
        ("long-line-width", "python3 - <<'PY' | wc -L\nprint('x' * 10000)\nPY", {"commands": ["wc", "python3"]}),
        ("missing-present", "printf a > a; wc -c missing a; printf 'status:%s\\n' \"$?\"", {"commands": ["wc", "printf"]}),
        ("debug", "printf 'a b\\n' | wc --debug -w", {"commands": ["wc", "printf"]}),
    ])

    add_required("which", [
        ("found", "which awk; printf 'status:%s\\n' \"$?\"", {"commands": ["which", "printf"]}),
        ("all", "which -a sh | head -n 3", {"commands": ["which", "head"]}),
        ("missing", "which definitely_missing_command_12345; printf 'status:%s\\n' \"$?\"", {"commands": ["which", "printf"]}),
    ])

    add_required("xargs", [
        ("default", "printf 'a b\\n' | xargs printf '<%s>\\n'", {"commands": ["xargs", "printf"]}),
        ("batch", "seq 1 5 | xargs -n 2 printf '[%s]\\n'", {"commands": ["xargs", "seq", "printf"]}),
        ("replace", "printf 'a\\nb\\n' | xargs -I{} printf '<{}>\\n'", {"commands": ["xargs", "printf"]}),
        ("empty", "printf '' | xargs -r printf bad; printf 'status:%s\\n' \"$?\"", {"commands": ["xargs", "printf"]}),
    ])

    add_required("xxd", [
        ("plain", "printf ABCD > bytes; xxd bytes", {"commands": ["xxd", "printf"]}),
        ("postscript", "printf ABCD | xxd -p", {"commands": ["xxd", "printf"]}),
        ("columns", "printf ABCD | xxd -c 4", {"commands": ["xxd", "printf"]}),
        ("reverse", "printf 41424344 | xxd -r -p", {"commands": ["xxd", "printf"]}),
    ])

    add_required("yes", [
        ("head", "yes ok | head -n 2", {"commands": ["yes", "head"]}),
        ("default", "yes | head -n 2", {"commands": ["yes", "head"]}),
        ("help", "yes --help", None),
        ("version", "yes --version", None),
    ])
