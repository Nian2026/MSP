from __future__ import annotations

from typing import Any, Callable

CaseAdder = Callable[[str, list[tuple[str, str, dict[str, Any] | None]]], None]
FileItemFactory = Callable[[str, bytes | str, str], dict[str, Any]]

def add_system_encoding_cases(add: CaseAdder, add_required: CaseAdder, file_item: FileItemFactory, shell_file: dict[str, Any], source_file: dict[str, Any]) -> None:
    add("shuf", [
        ("random-source", "printf 'a\\nb\\nc\\n' > in.txt; printf '0123456789abcdef' > random.bin; shuf --random-source=random.bin in.txt", {"commands": ["shuf", "printf"]}),
        ("head-count", "printf 'a\\nb\\nc\\n' | shuf --random-source=<(printf 0123456789abcdef) -n 2", {"commands": ["shuf", "printf"]}),
        ("input-range", "printf '0123456789abcdef' > random.bin; shuf --random-source=random.bin -i 1-5", {"commands": ["shuf", "printf"]}),
        ("repeat", "printf '0123456789abcdef' > random.bin; shuf --random-source=random.bin -r -n 5 -e a b", {"commands": ["shuf", "printf"]}),
        ("echo", "printf '0123456789abcdef' > random.bin; shuf --random-source=random.bin -e one two three", {"commands": ["shuf", "printf"]}),
        ("zero", "shuf -n 0 -e a b; printf 'status:%s\\n' \"$?\"", {"commands": ["shuf", "printf"]}),
        ("missing", "shuf missing; printf 'status:%s\\n' \"$?\"", {"commands": ["shuf", "printf"]}),
        ("invalid-range", "shuf -i bad; printf 'status:%s\\n' \"$?\"", {"commands": ["shuf", "printf"]}),
        ("output-file", "printf '0123456789abcdef' > random.bin; printf 'a\\nb\\nc\\n' | shuf --random-source=random.bin -o out.txt; cat out.txt", {"commands": ["shuf", "printf", "cat"]}),
        ("stdin", "printf '0123456789abcdef' > random.bin; printf 'a\\nb\\nc\\n' | shuf --random-source=random.bin", {"commands": ["shuf", "printf"]}),
        ("invalid-option", "shuf -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["shuf", "printf"]}),
        ("space-path", "printf 'a\\nb\\n' > 'a b'; printf '0123456789abcdef' > random.bin; shuf --random-source=random.bin 'a b'", {"commands": ["shuf", "printf"]}),
    ])

    add("tsort", [
        ("dag", "printf 'a b\\nb c\\n' | tsort", {"commands": ["tsort", "printf"]}),
        ("cycle", "printf 'a b\\nb a\\n' | tsort; printf 'status:%s\\n' \"$?\"", {"commands": ["tsort", "printf"]}),
        ("odd", "printf 'a b c\\n' | tsort; printf 'status:%s\\n' \"$?\"", {"commands": ["tsort", "printf"]}),
        ("repeat", "printf 'a b\\na b\\nb c\\n' | tsort", {"commands": ["tsort", "printf"]}),
        ("file", "printf 'a b\\nb c\\n' > graph.txt; tsort graph.txt", {"commands": ["tsort", "printf"]}),
        ("missing", "tsort missing; printf 'status:%s\\n' \"$?\"", {"commands": ["tsort", "printf"]}),
        ("empty", "tsort < empty.txt; printf 'status:%s\\n' \"$?\"", {"files": [file_item("empty.txt", "")], "commands": ["tsort", "printf"]}),
        ("self", "printf 'a a\\n' | tsort; printf 'status:%s\\n' \"$?\"", {"commands": ["tsort", "printf"]}),
        ("space-node", "printf 'a b\\nc d\\n' | tsort", {"commands": ["tsort", "printf"]}),
        ("invalid-option", "tsort -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["tsort", "printf"]}),
    ])

    add("uname", [
        ("default", "uname", None),
        ("all", "uname -a", None),
        ("kernel", "uname -s", None),
        ("nodename", "uname -n", None),
        ("release", "uname -r", None),
        ("machine", "uname -m", None),
        ("processor", "uname -p", None),
        ("combined", "uname -srm", None),
        ("invalid", "uname -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["uname", "printf"]}),
        ("version", "uname -v", None),
    ])

    add("whoami", [
        ("default", "whoami", None),
        ("invalid", "whoami -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["whoami", "printf"]}),
        ("extra", "whoami extra; printf 'status:%s\\n' \"$?\"", {"commands": ["whoami", "printf"]}),
        ("env-independent", "USER=custom whoami", {"commands": ["whoami"]}),
    ])

    add("id", [
        ("default", "id", None),
        ("u", "id -u", None),
        ("g", "id -g", None),
        ("capital-g", "id -G", None),
        ("un", "id -un", None),
        ("gn", "id -gn", None),
        ("groups-name", "id -Gn", None),
        ("real", "id -ru; id -rg", None),
        ("zero-user", "id root; printf 'status:%s\\n' \"$?\"", {"commands": ["id", "printf"]}),
        ("missing-user", "id definitely_missing_user_12345; printf 'status:%s\\n' \"$?\"", {"commands": ["id", "printf"]}),
        ("invalid-option", "id -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["id", "printf"]}),
        ("name-with-u", "id -nu", None),
        ("context", "id -Z; true", {"commands": ["id", "true"]}),
        ("lookup", "command -v id; type id", {"commands": ["id", "command", "type"]}),
    ])

    add("hostname", [
        ("default", "hostname", None),
        ("short", "hostname -s; printf 'status:%s\\n' \"$?\"", {"commands": ["hostname", "printf"]}),
        ("fqdn", "hostname -f; printf 'status:%s\\n' \"$?\"", {"commands": ["hostname", "printf"]}),
        ("domain", "hostname -d; printf 'status:%s\\n' \"$?\"", {"commands": ["hostname", "printf"]}),
        ("invalid-option", "hostname -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["hostname", "printf"]}),
        ("setter-forbidden-shape", "hostname --help | head -n 3", {"commands": ["hostname", "head"]}),
    ])

    add("sleep", [
        ("zero", "sleep 0; printf done\\n", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("fraction", "sleep 0.01; printf done\\n", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("suffix", "sleep 0.01s; printf done\\n", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("multiple", "sleep 0 0.01; printf done\\n", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("invalid", "sleep nope; printf 'status:%s\\n' \"$?\"", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("missing", "sleep; printf 'status:%s\\n' \"$?\"", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("tiny", "sleep .001; printf tiny\\n", {"commands": ["sleep", "printf"], "timeout_seconds": 2}),
        ("timeout-safe", "timeout 0.05 sleep 1; printf 'status:%s\\n' \"$?\"", {"commands": ["sleep", "timeout", "printf"], "timeout_seconds": 2}),
    ])

    add("base32", [
        ("encode", "printf hello | base32", {"commands": ["base32", "printf"]}),
        ("decode", "printf NBSWY3DP | base32 -d", {"commands": ["base32", "printf"]}),
        ("wrap", "printf abcdefghijklmnopqrstuvwxyz | base32 -w 16", {"commands": ["base32", "printf"]}),
        ("file", "printf hello > in.txt; base32 in.txt", {"commands": ["base32", "printf"]}),
        ("multiple", "printf a > a; printf b > b; base32 a b", {"commands": ["base32", "printf"]}),
        ("ignore-garbage", "printf 'NB SWY3DP!!' | base32 -d -i", {"commands": ["base32", "printf"]}),
        ("invalid-decode", "printf '????' | base32 -d; printf 'status:%s\\n' \"$?\"", {"commands": ["base32", "printf"]}),
        ("missing", "base32 missing; printf 'status:%s\\n' \"$?\"", {"commands": ["base32", "printf"]}),
        ("zero-wrap", "printf hello | base32 -w 0", {"commands": ["base32", "printf"]}),
        ("space-path", "printf hello > 'a b'; base32 'a b'", {"commands": ["base32", "printf"]}),
    ])

    add("basenc", [
        ("base64", "printf hello | basenc --base64", {"commands": ["basenc", "printf"]}),
        ("base64url", "printf 'hello?' | basenc --base64url", {"commands": ["basenc", "printf"]}),
        ("base32", "printf hello | basenc --base32", {"commands": ["basenc", "printf"]}),
        ("base16", "printf hello | basenc --base16", {"commands": ["basenc", "printf"]}),
        ("decode-base64", "printf aGVsbG8= | basenc --base64 -d", {"commands": ["basenc", "printf"]}),
        ("decode-base16", "printf 68656C6C6F | basenc --base16 -d", {"commands": ["basenc", "printf"]}),
        ("wrap", "printf abcdefghijklmnopqrstuvwxyz | basenc --base64 -w 12", {"commands": ["basenc", "printf"]}),
        ("file", "printf hello > in.txt; basenc --base64 in.txt", {"commands": ["basenc", "printf"]}),
        ("multiple", "printf a > a; printf b > b; basenc --base64 a b", {"commands": ["basenc", "printf"]}),
        ("invalid-encoding", "basenc --base999; printf 'status:%s\\n' \"$?\"", {"commands": ["basenc", "printf"]}),
        ("invalid-decode", "printf '????' | basenc --base64 -d; printf 'status:%s\\n' \"$?\"", {"commands": ["basenc", "printf"]}),
        ("ignore-garbage", "printf 'aG Vs bG8=!!' | basenc --base64 -d -i", {"commands": ["basenc", "printf"]}),
        ("base2msbf", "printf '\\200' | basenc --base2msbf | head -c 16; printf '\\n'", {"commands": ["basenc", "printf", "head"]}),
        ("space-path", "printf hello > 'a b'; basenc --base64 'a b'", {"commands": ["basenc", "printf"]}),
    ])

    add("sha512sum", [
        ("stdin", "printf hello | sha512sum", {"commands": ["sha512sum", "printf"]}),
        ("file", "printf hello > in.txt; sha512sum in.txt", {"commands": ["sha512sum", "printf"]}),
        ("multiple", "printf a > a; printf b > b; sha512sum a b", {"commands": ["sha512sum", "printf"]}),
        ("check-ok", "printf hello > in.txt; sha512sum in.txt > sums; sha512sum -c sums", {"commands": ["sha512sum", "printf"]}),
        ("check-fail", "printf hello > in.txt; sha512sum in.txt > sums; printf x >> in.txt; sha512sum -c sums; printf 'status:%s\\n' \"$?\"", {"commands": ["sha512sum", "printf"]}),
        ("missing", "sha512sum missing; printf 'status:%s\\n' \"$?\"", {"commands": ["sha512sum", "printf"]}),
        ("binary", "printf hello > in.txt; sha512sum -b in.txt", {"commands": ["sha512sum", "printf"]}),
        ("text", "printf hello > in.txt; sha512sum -t in.txt", {"commands": ["sha512sum", "printf"]}),
        ("zero", ": > empty; sha512sum empty", {"commands": ["sha512sum", ":"]}),
        ("space-path", "printf hello > 'a b'; sha512sum 'a b'", {"commands": ["sha512sum", "printf"]}),
    ])

    add("b2sum", [
        ("stdin", "printf hello | b2sum", {"commands": ["b2sum", "printf"]}),
        ("file", "printf hello > in.txt; b2sum in.txt", {"commands": ["b2sum", "printf"]}),
        ("multiple", "printf a > a; printf b > b; b2sum a b", {"commands": ["b2sum", "printf"]}),
        ("length", "printf hello > in.txt; b2sum -l 256 in.txt", {"commands": ["b2sum", "printf"]}),
        ("check-ok", "printf hello > in.txt; b2sum in.txt > sums; b2sum -c sums", {"commands": ["b2sum", "printf"]}),
        ("check-fail", "printf hello > in.txt; b2sum in.txt > sums; printf x >> in.txt; b2sum -c sums; printf 'status:%s\\n' \"$?\"", {"commands": ["b2sum", "printf"]}),
        ("missing", "b2sum missing; printf 'status:%s\\n' \"$?\"", {"commands": ["b2sum", "printf"]}),
        ("binary", "printf hello > in.txt; b2sum -b in.txt", {"commands": ["b2sum", "printf"]}),
        ("zero", ": > empty; b2sum empty", {"commands": ["b2sum", ":"]}),
        ("space-path", "printf hello > 'a b'; b2sum 'a b'", {"commands": ["b2sum", "printf"]}),
    ])
