from __future__ import annotations

from typing import Any, Callable

CaseAdder = Callable[[str, list[tuple[str, str, dict[str, Any] | None]]], None]
FileItemFactory = Callable[[str, bytes | str, str], dict[str, Any]]

def add_required_a_cases(add: CaseAdder, add_required: CaseAdder, file_item: FileItemFactory, shell_file: dict[str, Any], source_file: dict[str, Any]) -> None:
    add_required(":", [
        ("baseline", ":; printf 'status:%s\\n' \"$?\"", {"commands": [":", "printf"]}),
        ("redirection", ": > touched.txt; stat -c '%s' touched.txt", {"commands": [":", "stat"]}),
    ])

    add_required("[", [
        ("numeric-true", "[ 2 -lt 3 ]; printf 'status:%s\\n' \"$?\"", {"commands": ["[", "printf"]}),
        ("string-false", "[ alpha = beta ]; printf 'status:%s\\n' \"$?\"", {"commands": ["[", "printf"]}),
        ("file-predicate", ": > f.txt; [ -f f.txt ]; printf 'status:%s\\n' \"$?\"", {"commands": ["[", ":", "printf"]}),
        ("missing-close", "[ 1 -eq 1; printf 'status:%s\\n' \"$?\"", {"commands": ["[", "printf"]}),
    ])

    add_required("[[", [
        ("string-match", "[[ value = value ]]; printf 'status:%s\\n' \"$?\"", {"commands": ["[[", "printf"]}),
        ("pattern", "[[ alpha.txt == *.txt ]]; printf 'status:%s\\n' \"$?\"", {"commands": ["[[", "printf"]}),
        ("regex", "[[ abc123 =~ ^abc[0-9]+$ ]]; printf 'status:%s\\n' \"$?\"", {"commands": ["[[", "printf"]}),
        ("numeric", "[[ 10 -gt 2 ]]; printf 'status:%s\\n' \"$?\"", {"commands": ["[[", "printf"]}),
    ])

    add_required("awk", [
        ("field-sum", "printf 'a 1\\nb 2\\n' > awk.txt; awk '{sum += $2} END {print sum}' awk.txt", {"commands": ["awk", "printf"]}),
        ("field-separator", "printf 'a:1\\nb:2\\n' | awk -F: '{print $1\"=\"$2}'", {"commands": ["awk", "printf"]}),
        ("program-file", "printf '{print NR\":\"$0}\\n' > prog.awk; printf 'x\\ny\\n' | awk -f prog.awk", {"commands": ["awk", "printf"]}),
        ("missing-file", "awk '{print}' missing.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["awk", "printf"]}),
    ])

    add_required("base64", [
        ("encode", "printf hello | base64", {"commands": ["base64", "printf"]}),
        ("decode", "printf aGVsbG8= | base64 -d", {"commands": ["base64", "printf"]}),
        ("wrap-zero", "printf abcdefghijklmnopqrstuvwxyz | base64 -w 0", {"commands": ["base64", "printf"]}),
        ("ignore-garbage", "printf 'aG Vs bG8=!!' | base64 -d -i", {"commands": ["base64", "printf"]}),
        ("invalid-decode", "printf '????' | base64 -d; printf 'status:%s\\n' \"$?\"", {"commands": ["base64", "printf"]}),
        ("file", "printf hello > in.txt; base64 in.txt", {"commands": ["base64", "printf"]}),
    ])

    add_required("basename", [
        ("simple", "basename a/b.txt", None),
        ("suffix", "basename a/b.txt .txt", None),
        ("multiple", "basename -a a/b.txt c/d.md", None),
        ("suffix-option", "basename -s .txt a/b.txt c/d.txt", None),
        ("zero", "basename -z a/b.txt | od -An -tx1", {"commands": ["basename", "od"]}),
    ])

    add_required("bc", [
        ("arithmetic", "printf '2+3*4\\n' | bc", {"commands": ["bc", "printf"]}),
        ("scale", "printf 'scale=3\\n1/8\\n' | bc", {"commands": ["bc", "printf"]}),
        ("ibase-obase", "printf 'ibase=16\\nobase=10\\nFF\\n' | bc", {"commands": ["bc", "printf"]}),
        ("expression-file", "printf '10/4\\n' > expr.bc; bc expr.bc", {"commands": ["bc", "printf"]}),
        ("syntax-error", "printf '1+\\n' | bc; printf 'status:%s\\n' \"$?\"", {"commands": ["bc", "printf"]}),
    ])

    add_required("builtin", [
        ("printf", "builtin printf 'ok\\n'", {"commands": ["builtin", "printf"]}),
        ("cd-state", "mkdir d; builtin cd d; pwd", {"commands": ["builtin", "mkdir", "pwd"]}),
        ("missing", "builtin definitely_missing_builtin; printf 'status:%s\\n' \"$?\"", {"commands": ["builtin", "printf"]}),
    ])

    add_required("cat", [
        ("file", "printf 'alpha\\n' > cat.txt; cat cat.txt", {"commands": ["cat", "printf"]}),
        ("number", "printf 'a\\nb\\n' | cat -n", {"commands": ["cat", "printf"]}),
        ("show-all", "printf 'a\\t$\\n' | cat -A", {"commands": ["cat", "printf"]}),
        ("stdin-dash-file", "printf 'stdin\\n' | cat - cat.txt", {"files": [file_item("cat.txt", "file\n")], "commands": ["cat", "printf"]}),
        ("missing", "cat missing.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["cat", "printf"]}),
        ("mixed-missing", "printf one > a; printf two > b; cat a missing b; printf 'status:%s\\n' \"$?\"", {"commands": ["cat", "printf"]}),
        ("show-all-byte-sweep", "python3 - <<'PY' > bytes.bin\nimport sys\nsys.stdout.buffer.write(bytes(range(256)))\nPY\ncat -A bytes.bin | od -An -tx1", {"commands": ["python3", "cat", "od"]}),
        ("binary-passthrough", "python3 - <<'PY' > bytes.bin\nimport sys\nsys.stdout.buffer.write(bytes([0, 1, 65, 255]))\nPY\ncat bytes.bin | od -An -tx1", {"commands": ["python3", "cat", "od"]}),
        ("rendered-huge-line", "python3 - <<'PY' > huge.txt\nprint('x' * 4096)\nPY\ncat -A huge.txt | wc -c", {"commands": ["python3", "cat", "wc"]}),
        ("large-file-short-consumer", "python3 - <<'PY' > big.txt\nfor i in range(5000):\n    print(f'line-{i:04d}')\nPY\ncat big.txt | head -n 3", {"commands": ["python3", "cat", "head"]}),
        ("closed-stdout-write-error", "printf abc > input.txt; cat input.txt >&-; printf 'status:%s\\n' \"$?\"", {"commands": ["cat", "printf"]}),
    ])

    add_required("cd", [
        ("relative", "mkdir -p d/sub; cd d/sub; pwd; printf 'status:%s\\n' \"$?\"", {"commands": ["cd", "mkdir", "pwd", "printf"]}),
        ("parent", "mkdir -p a b; cd a; cd ../b; pwd; printf 'status:%s\\n' \"$?\"", {"commands": ["cd", "mkdir", "pwd", "printf"]}),
        ("missing", "cd missing; printf 'status:%s\\n' \"$?\"", {"commands": ["cd", "printf"]}),
    ])

    add_required("chmod", [
        ("octal", ": > mode.txt; chmod 600 mode.txt; stat -c '%a' mode.txt", {"commands": ["chmod", ":", "stat"]}),
        ("symbolic", ": > mode.txt; chmod u+x,g-w mode.txt; stat -c '%a' mode.txt", {"commands": ["chmod", ":", "stat"]}),
        ("recursive-relative", "mkdir -p d/sub; : > d/file; chmod -R 700 d; stat -c '%a %n' d d/sub d/file | sort", {"commands": ["chmod", "mkdir", ":", "stat", "sort"]}),
        ("invalid-mode", ": > mode.txt; chmod nope mode.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["chmod", ":", "printf"]}),
        ("missing", "chmod 600 missing.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["chmod", "printf"]}),
    ])

    add_required("cksum", [
        ("stdin", "printf abc | cksum", {"commands": ["cksum", "printf"]}),
        ("file", "printf abc > bytes.txt; cksum bytes.txt", {"commands": ["cksum", "printf"]}),
        ("multiple", "printf a > a; printf b > b; cksum a b", {"commands": ["cksum", "printf"]}),
        ("tag", "printf abc > bytes.txt; cksum --tag bytes.txt", {"commands": ["cksum", "printf"]}),
        ("missing", "cksum missing.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["cksum", "printf"]}),
    ])

    add_required("cmp", [
        ("same", "printf abc > a; printf abc > b; cmp a b; printf 'status:%s\\n' \"$?\"", {"commands": ["cmp", "printf"]}),
        ("different", "printf abc > a; printf axc > b; cmp a b; printf 'status:%s\\n' \"$?\"", {"commands": ["cmp", "printf"]}),
        ("silent", "printf abc > a; printf axc > b; cmp -s a b; printf 'status:%s\\n' \"$?\"", {"commands": ["cmp", "printf"]}),
        ("print-bytes", "printf abc > a; printf axc > b; cmp -l a b", {"commands": ["cmp", "printf"]}),
        ("missing", "cmp a missing; printf 'status:%s\\n' \"$?\"", {"files": [file_item("a", "abc")], "commands": ["cmp", "printf"]}),
    ])

    add_required("comm", [
        ("default", "printf 'a\\nb\\n' > a; printf 'b\\nc\\n' > b; comm a b", {"commands": ["comm", "printf"]}),
        ("common-only", "printf 'a\\nb\\n' > a; printf 'b\\nc\\n' > b; comm -12 a b", {"commands": ["comm", "printf"]}),
        ("suppress-left-right", "printf 'a\\nb\\n' > a; printf 'b\\nc\\n' > b; comm -3 a b", {"commands": ["comm", "printf"]}),
        ("check-order", "printf 'b\\na\\n' > a; printf 'a\\nb\\n' > b; comm --check-order a b; printf 'status:%s\\n' \"$?\"", {"commands": ["comm", "printf"]}),
        ("total", "printf 'a\\nb\\n' > a; printf 'b\\nc\\n' > b; comm --total a b", {"commands": ["comm", "printf"]}),
        ("default-disorder-identical", "printf 'b\\na\\n' > a; printf 'b\\na\\n' > b; comm a b; printf 'status:%s\\n' \"$?\"", {"commands": ["comm", "printf"]}),
        ("total-before-disorder-status", "printf 'b\\na\\n' > a; printf 'a\\nb\\n' > b; comm --total a b; printf 'status:%s\\n' \"$?\"", {"commands": ["comm", "printf"]}),
        ("duplicate-delimiter-conflict", "printf 'a\\n' > a; printf 'a\\n' > b; comm --output-delimiter=: --output-delimiter=/ a b; printf 'status:%s\\n' \"$?\"", {"commands": ["comm", "printf"]}),
    ])

    add_required("command", [
        ("v", "command -v printf; printf 'status:%s\\n' \"$?\"", {"commands": ["command", "printf"]}),
        ("capital-v", "command -V cd; command -V definitely_missing; printf 'status:%s\\n' \"$?\"", {"commands": ["command", "printf"]}),
        ("run", "command printf 'ran\\n'", {"commands": ["command", "printf"]}),
        ("missing", "command definitely_missing_command; printf 'status:%s\\n' \"$?\"", {"commands": ["command", "printf"]}),
    ])

    add_required("cp", [
        ("file", "printf abc > src; cp src dst; cat dst", {"commands": ["cp", "printf", "cat"]}),
        ("recursive", "mkdir -p src/sub; printf x > src/sub/file; cp -R src dst; find dst -type f -printf '%p:%s\\n' | sort", {"commands": ["cp", "mkdir", "printf", "find", "sort"]}),
        ("target-dir", "mkdir dst; printf a > a; printf b > b; cp -t dst a b; find dst -type f -printf '%f:%s\\n' | sort", {"commands": ["cp", "mkdir", "printf", "find", "sort"]}),
        ("no-clobber", "printf old > dst; printf new > src; cp -n src dst; cat dst", {"commands": ["cp", "printf", "cat"]}),
        ("missing", "cp missing dst; printf 'status:%s\\n' \"$?\"", {"commands": ["cp", "printf"]}),
    ])

    add_required("cut", [
        ("fields", "printf 'a:b:c\\n' | cut -d : -f 2", {"commands": ["cut", "printf"]}),
        ("chars", "printf 'abcdef\\n' | cut -c 2-4", {"commands": ["cut", "printf"]}),
        ("bytes", "printf 'abcdef\\n' | cut -b 1,3,5", {"commands": ["cut", "printf"]}),
        ("chars-preserve-invalid-bytes", "python3 - <<'PY' | cut -c 1,3 | od -An -tx1\nimport sys\nsys.stdout.buffer.write(bytes([0xff, 0x41, 0xfe, 0x0a]))\nPY", {"commands": ["cut", "python3", "od"]}),
        ("output-delimiter-bytes", "printf 'abcdef\\n' | cut -b 1,2 --output-delimiter=:", {"commands": ["cut", "printf"]}),
        ("complement", "printf 'a:b:c\\n' | cut -d : -f 2 --complement", {"commands": ["cut", "printf"]}),
        ("file", "printf 'x:y\\n' > f; cut -d : -f 1 f", {"commands": ["cut", "printf"]}),
        ("zero-bytes", "printf 'a\\0b\\0' | cut -z -b 1 | od -An -tx1", {"commands": ["cut", "printf", "od"]}),
        ("delimiter-outside-fields", "cut -d : -b 1; printf 'status:%s\\n' \"$?\"", {"commands": ["cut", "printf"]}),
        ("only-delimited-outside-fields", "cut -s -c 1; printf 'status:%s\\n' \"$?\"", {"commands": ["cut", "printf"]}),
    ])

    add_required("date", [
        ("epoch", "date -u -d @0 '+%F %T %z %Z'", None),
        ("iso", "date -u -d @0 -Iseconds", None),
        ("rfc3339", "date -u -d @0 --rfc-3339=seconds", None),
        ("invalid-date", "date -d not-a-date; printf 'status:%s\\n' \"$?\"", {"commands": ["date", "printf"]}),
        ("format-newline", "date -u -d @0 '+year=%Y%njulian=%j'", None),
    ])

    add_required("diff", [
        ("same", "printf a > a; printf a > b; diff -s a b; printf 'status:%s\\n' \"$?\"", {"commands": ["diff", "printf"]}),
        ("different", "printf 'a\\n' > a; printf 'b\\n' > b; diff a b; printf 'status:%s\\n' \"$?\"", {"commands": ["diff", "printf"]}),
        ("unified", "printf 'a\\n' > a; printf 'b\\n' > b; diff -u a b; printf 'status:%s\\n' \"$?\"", {"commands": ["diff", "printf"]}),
        ("brief", "printf a > a; printf b > b; diff -q a b; printf 'status:%s\\n' \"$?\"", {"commands": ["diff", "printf"]}),
        ("missing", "diff a missing; printf 'status:%s\\n' \"$?\"", {"files": [file_item("a", "a")], "commands": ["diff", "printf"]}),
    ])

    add_required("dirname", [
        ("simple", "dirname a/b.txt", None),
        ("no-slash", "dirname file.txt", None),
        ("multiple", "dirname a/b.txt c/d/e.txt", None),
        ("zero", "dirname -z a/b.txt | od -An -tx1", {"commands": ["dirname", "od"]}),
    ])

    add_required("du", [
        ("bytes-file", "printf abc > f; du -b f", {"commands": ["du", "printf"]}),
        ("summarize", "mkdir d; printf abc > d/f; du -sb d", {"commands": ["du", "mkdir", "printf"]}),
        ("all", "mkdir d; printf abc > d/f; du -ab d | sort", {"commands": ["du", "mkdir", "printf", "sort"]}),
        ("missing", "du missing; printf 'status:%s\\n' \"$?\"", {"commands": ["du", "printf"]}),
    ])

    add_required("echo", [
        ("default", "echo hello world", None),
        ("no-newline", "echo -n hello; printf '\\n'", {"commands": ["echo", "printf"]}),
        ("escapes", "echo -e 'a\\tb'", None),
        ("literal-option", "echo -- -n", None),
    ])

    add_required("env", [
        ("empty", "env -i FOO=bar env | grep '^FOO='", {"commands": ["env", "grep"]}),
        ("unset", "FOO=bar env -u FOO env | grep '^FOO='; printf 'status:%s\\n' \"$?\"", {"commands": ["env", "grep", "printf"]}),
        ("command", "env FOO=bar sh -c 'printf \"%s\\n\" \"$FOO\"'", {"commands": ["env", "sh", "printf"]}),
        ("split-string", "env -S 'FOO=bar env' | grep '^FOO='", {"commands": ["env", "grep"]}),
        ("invalid-option", "env -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["env", "printf"]}),
    ])

    add_required("factor", [
        ("numbers", "factor 0 1 2 12 97 1001", None),
        ("stdin", "printf '12\\n18\\n' | factor", {"commands": ["factor", "printf"]}),
        ("invalid", "factor nope; printf 'status:%s\\n' \"$?\"", {"commands": ["factor", "printf"]}),
    ])

    add_required("false", [
        ("status", "false; printf 'status:%s\\n' \"$?\"", {"commands": ["false", "printf"]}),
        ("extra", "false extra; printf 'status:%s\\n' \"$?\"", {"commands": ["false", "printf"]}),
    ])

    add_required("file", [
        ("text", "printf 'hello\\n' > text.txt; file text.txt; file -b text.txt; file -i text.txt", {"commands": ["file", "printf"]}),
        ("binary", "python3 - <<'PY'\nopen('bin','wb').write(bytes([0,1,2,3,255]))\nPY\nfile bin; file -b bin; file --mime-type bin", {"commands": ["file", "python3"]}),
        ("directory", "mkdir d; file d", {"commands": ["file", "mkdir"]}),
        ("missing", "file missing; printf 'status:%s\\n' \"$?\"", {"commands": ["file", "printf"]}),
    ])

    add_required("find", [
        ("default", "mkdir -p docs/sub; : > docs/a.txt; find docs | sort", {"commands": ["find", "mkdir", ":", "sort"]}),
        ("type-name", "mkdir docs; : > docs/a.txt; : > docs/b.md; find docs -type f -name '*.txt' -print", {"commands": ["find", "mkdir", ":"]}),
        ("maxdepth", "mkdir -p docs/sub; : > docs/sub/a.txt; find docs -maxdepth 1 -print | sort", {"commands": ["find", "mkdir", ":", "sort"]}),
        ("printf", "mkdir docs; : > docs/a.txt; find docs -type f -printf '%f:%s:%y\\n'", {"commands": ["find", "mkdir", ":"]}),
        ("exec-plus", "mkdir docs; : > docs/a.txt; : > docs/b.txt; find docs -type f -exec printf '<%s>\\n' {} + | sort", {"commands": ["find", "mkdir", ":", "printf", "sort"]}),
    ])

    add_required("grep", [
        ("basic", "printf 'alpha\\nbeta\\n' > g.txt; grep beta g.txt", {"commands": ["grep", "printf"]}),
        ("line-number", "printf 'alpha\\nbeta\\n' | grep -n beta", {"commands": ["grep", "printf"]}),
        ("line-buffered", "printf 'alpha\\nbeta\\n' | grep --line-buffered beta", {"commands": ["grep", "printf"]}),
        ("extended", "printf 'alpha\\nbeta\\n' | grep -E 'a$|eta'", {"commands": ["grep", "printf"]}),
        ("invert", "printf 'alpha\\nbeta\\n' | grep -v beta", {"commands": ["grep", "printf"]}),
        ("quiet", "printf 'alpha\\nbeta\\n' | grep -q beta; printf 'status:%s\\n' \"$?\"", {"commands": ["grep", "printf"]}),
        ("missing", "grep beta missing; printf 'status:%s\\n' \"$?\"", {"commands": ["grep", "printf"]}),
        ("context-group-separator", "printf 'zero\\none\\ntwo\\nthree\\nfour\\nfive\\nsix\\n' > context.txt; grep -E -A1 -B1 --group-separator='***' 'one|five' context.txt", {"commands": ["grep", "printf"]}),
        ("context-no-group-separator", "printf 'zero\\none\\ntwo\\nthree\\nfour\\nfive\\nsix\\n' > context.txt; grep -E -C1 --no-group-separator 'one|five' context.txt", {"commands": ["grep", "printf"]}),
        ("digit-context", "printf 'zero\\none\\ntwo\\nthree\\n' | grep -n -1 three", {"commands": ["grep", "printf"]}),
        ("binary-files-modes", "printf 'a\\0b\\n' > bin; grep --binary-files=without-match a bin; printf 'without:%s\\n' \"$?\"; grep --binary-files=text a bin; grep --binary-files=binary a bin", {"commands": ["grep", "printf"]}),
        ("directory-methods", "mkdir d; printf 'hit\\n' > d/f; grep --directories=skip hit d; printf 'skip:%s\\n' \"$?\"; grep --directories=read hit d; printf 'read:%s\\n' \"$?\"", {"commands": ["grep", "mkdir", "printf"]}),
        ("recursive-include-exclude", "mkdir -p src/skip; printf 'hit\\n' > src/a.txt; printf 'hit\\n' > src/a.md; printf 'hit\\n' > src/skip/b.txt; grep -r --include='*.txt' --exclude-dir=skip hit src", {"commands": ["grep", "mkdir", "printf"]}),
        ("recursive-exclude-from", "mkdir src; printf 'hit\\n' > src/a.txt; printf 'hit\\n' > src/b.log; printf '*.log\\n' > patterns; grep -r --exclude-from=patterns hit src", {"commands": ["grep", "mkdir", "printf"]}),
        ("nul-records", "printf 'a\\0hit\\0b\\0' | grep -z hit | od -An -tx1", {"commands": ["grep", "printf", "od"]}),
        ("null-filename", "printf 'hit\\n' > g.txt; grep -Z -l hit g.txt | od -An -tx1", {"commands": ["grep", "printf", "od"]}),
        ("pattern-file-stdin-file", "printf 'alpha\\nbeta\\n' > haystack.txt; printf 'alpha\\n' | grep -f - haystack.txt", {"commands": ["grep", "printf"]}),
        ("pattern-file-stdin-not-reused", "printf 'alpha\\n' | grep -f -; printf 'status:%s\\n' \"$?\"", {"commands": ["grep", "printf"]}),
        ("pattern-file-stdin-explicit-dash-not-reused", "printf 'alpha\\n' | grep -f - -; printf 'status:%s\\n' \"$?\"", {"commands": ["grep", "printf"]}),
        ("recursive-exclude-from-stdin", "mkdir tree; printf 'hit\\n' > tree/a.txt; printf 'hit\\n' > tree/b.log; printf '*.log\\n' | grep -r --exclude-from=- hit tree", {"commands": ["grep", "mkdir", "printf"]}),
        ("color-always-match", "printf 'hit\\nmiss\\n' | grep --color=always hit", {"commands": ["grep", "printf"]}),
        ("color-always-prefix", "printf 'hit\\n' > g.txt; grep --color=always -nH hit g.txt", {"commands": ["grep", "printf"]}),
        ("matcher-bre-ere", "printf 'a+\\naaa\\n' | grep -G 'a+'; printf '%s\\n' '---'; printf 'a+\\naaa\\n' | grep -E 'a+'", {"commands": ["grep", "printf"]}),
        ("matcher-conflict", "printf 'a+\\naaa\\n' | grep -F -E 'a+'; printf 'first:%s\\n' \"$?\"; printf 'a+\\naaa\\n' | grep -E -F 'a+'; printf 'second:%s\\n' \"$?\"", {"commands": ["grep", "printf"]}),
        ("perl-regexp-basic", "printf 'abc123\\nabcxyz\\n' | grep -P 'abc\\d+'", {"commands": ["grep", "printf"]}),
    ])
