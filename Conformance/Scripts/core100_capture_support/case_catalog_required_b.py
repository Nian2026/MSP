from __future__ import annotations

from typing import Any, Callable

CaseAdder = Callable[[str, list[tuple[str, str, dict[str, Any] | None]]], None]
FileItemFactory = Callable[[str, bytes | str, str], dict[str, Any]]

def add_required_b_cases(add: CaseAdder, add_required: CaseAdder, file_item: FileItemFactory, shell_file: dict[str, Any], source_file: dict[str, Any]) -> None:
    add_required("groups", [
        ("current", "groups", None),
        ("root-nobody-missing", "groups root nobody definitely_missing_user_12345; printf 'status:%s\\n' \"$?\"", {"commands": ["groups", "printf"]}),
    ])

    add_required("head", [
        ("lines", "seq 1 5 | head -n 2", {"commands": ["head", "seq"]}),
        ("bytes", "printf abcdef | head -c 3", {"commands": ["head", "printf"]}),
        ("negative-lines", "seq 1 5 | head -n -2", {"commands": ["head", "seq"]}),
        ("file", "seq 1 3 > nums; head nums", {"commands": ["head", "seq"]}),
        ("zero-records", "printf 'a\\0b\\0c\\0' | head -z -n 2 | od -An -tx1", {"commands": ["head", "printf", "od"]}),
        ("byte-suffix", "python3 - <<'PY' | head -c 1K | wc -c\nimport sys\nsys.stdout.buffer.write(b'x' * 1100)\nPY", {"commands": ["head", "python3", "wc"]}),
        ("multi-file-stdin-headers", "printf 'file-a\\nfile-b\\n' > nums; printf 'stdin-a\\nstdin-b\\n' | head -n 1 - nums -", {"commands": ["head", "printf"]}),
        ("file-zero-records", "python3 - <<'PY'\nopen('records.bin','wb').write(b'a\\0b\\0c\\0')\nPY\nhead -z -n 2 records.bin | od -An -tx1", {"commands": ["head", "python3", "od"]}),
    ])

    add_required("join", [
        ("default", "printf '1 apple\\n2 banana\\n' > left; printf '1 red\\n2 yellow\\n' > right; join left right", {"commands": ["join", "printf"]}),
        ("separator", "printf '1:apple\\n2:banana\\n' > left; printf '1:red\\n2:yellow\\n' > right; join -t : left right", {"commands": ["join", "printf"]}),
        ("unpairable", "printf '1 apple\\n2 banana\\n' > left; printf '1 red\\n3 green\\n' > right; join -a 1 left right", {"commands": ["join", "printf"]}),
        ("missing", "join left missing; printf 'status:%s\\n' \"$?\"", {"files": [file_item("left", "1 a\n")], "commands": ["join", "printf"]}),
        ("header-auto", "printf 'id,name,kind\\n1,A,x\\n2,B\\n' > left.csv; printf 'id,color\\n1,red\\n3,blue\\n' > right.csv; join -t , --header -a 1 -a 2 -e NA -o auto left.csv right.csv", {"commands": ["join", "printf"]}),
        ("zero-terminated", "python3 - <<'PY'\nopen('left-z','wb').write(b'1 a\\0' + b'2 b\\0')\nopen('right-z','wb').write(b'1 x\\0' + b'3 y\\0')\nPY\njoin -z left-z right-z | od -An -tx1", {"commands": ["join", "python3", "od"]}),
        ("check-order", "printf '2 b\\n1 a\\n' > left; printf '1 x\\n2 y\\n' > right; join --check-order left right; printf 'status:%s\\n' \"$?\"", {"commands": ["join", "printf"]}),
        ("whole-line-separator", "printf 'a b\\nc d\\n' > left; printf 'a b\\nx y\\n' > right; join -t '' left right", {"commands": ["join", "printf"]}),
        ("nul-field-separator", "python3 - <<'PY'\nopen('left','wb').write(b'1\\0a\\n')\nopen('right','wb').write(b'1\\0x\\n')\nPY\njoin -t '\\0' left right | od -An -tx1", {"commands": ["join", "python3", "od"]}),
        ("duplicate-cartesian", "printf '1 a\\n1 b\\n2 c\\n' > left; printf '1 x\\n1 y\\n' > right; join left right", {"commands": ["join", "printf"]}),
        ("missing-fields-empty-replacement", "printf '1 a\\n2\\n' > left; printf '1 x\\n2 y z\\n3 q\\n' > right; join -a 1 -a 2 -e NA -o '0,1.2,2.2,2.3' left right", {"commands": ["join", "printf"]}),
        ("default-disorder-warning", "printf 'a left\\nc late\\nb disorder\\n' > left; printf 'b right\\n' > right; join left right; printf 'status:%s\\n' \"$?\"", {"commands": ["join", "printf"]}),
        ("nocheck-order", "printf '2 b\\n1 a\\n' > left; printf '1 x\\n2 y\\n' > right; join --nocheck-order left right; printf 'status:%s\\n' \"$?\"", {"commands": ["join", "printf"]}),
        ("header", "printf 'id name\\n1 Ann\\n2 Bob\\n' > left; printf 'id color\\n1 red\\n2 blue\\n' > right; join --header left right", {"commands": ["join", "printf"]}),
        ("both-stdin", "printf '1 a\\n' | { join - -; printf 'status:%s\\n' \"$?\"; }", {"commands": ["join", "printf"]}),
        ("zero-terminated-unpairable", "python3 - <<'PY'\nopen('left','wb').write(b'1 a\\0' + b'2 b\\0')\nopen('right','wb').write(b'1 x\\0' + b'3 y\\0')\nPY\njoin -z -a 1 -a 2 left right | od -An -tx1", {"commands": ["join", "python3", "od"]}),
        ("invalid-byte-field", "python3 - <<'PY'\nopen('left','wb').write(bytes([0x31,0x20,0xff,0x0a]))\nopen('right','wb').write(b'1 x\\n')\nPY\njoin left right | od -An -tx1", {"commands": ["join", "python3", "od"]}),
        ("huge-duplicate-group-count", "python3 - <<'PY'\nwith open('left','w') as f:\n    for i in range(30):\n        f.write(f'1 L{i}\\n')\nwith open('right','w') as f:\n    for i in range(40):\n        f.write(f'1 R{i}\\n')\nPY\njoin left right | wc -l", {"commands": ["join", "python3", "wc"], "timeout_seconds": 10.0}),
    ])

    add_required("ldd", [
        ("version", "ldd --version | head -n 1", {"commands": ["ldd", "head"]}),
        ("plain-file", "printf plain > plain.txt; ldd plain.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["ldd", "printf"]}),
        ("missing", "ldd missing; printf 'status:%s\\n' \"$?\"", {"commands": ["ldd", "printf"]}),
    ])

    add_required("link", [
        ("file", "printf abc > src; link src hard; cat hard", {"commands": ["link", "printf", "cat"]}),
        ("existing", "printf one > src; printf two > hard; link src hard; printf 'status:%s\\n' \"$?\"; cat hard", {"commands": ["link", "printf", "cat"]}),
        ("missing", "link missing hard; printf 'status:%s\\n' \"$?\"", {"commands": ["link", "printf"]}),
    ])

    add_required("ln", [
        ("hard", "printf old > target; ln target hard; printf new > hard; cat target", {"commands": ["ln", "printf", "cat"]}),
        ("symbolic", "printf data > target; ln -s target link; readlink link; cat link", {"commands": ["ln", "printf", "readlink", "cat"]}),
        ("force", "printf one > one; printf two > two; ln -f one two; cat two", {"commands": ["ln", "printf", "cat"]}),
        ("target-dir", "mkdir d; printf a > a; ln a d; find d -type f -printf '%f:%s\\n'", {"commands": ["ln", "mkdir", "printf", "find"]}),
    ])

    add_required("ls", [
        ("default", "mkdir d; : > d/b; : > d/a; ls d", {"commands": ["ls", "mkdir", ":"]}),
        ("all", "mkdir d; : > d/.hidden; : > d/visible; ls -a d", {"commands": ["ls", "mkdir", ":"]}),
        ("recursive", "mkdir -p d/sub; : > d/sub/file; ls -R d", {"commands": ["ls", "mkdir", ":"]}),
        ("unsorted", "mkdir d; : > d/a; : > d/b; ls -U d | sort", {"commands": ["ls", "mkdir", ":", "sort"]}),
        ("missing", "ls missing; printf 'status:%s\\n' \"$?\"", {"commands": ["ls", "printf"]}),
    ])

    add_required("md5sum", [
        ("stdin", "printf hello | md5sum", {"commands": ["md5sum", "printf"]}),
        ("file", "printf hello > in.txt; md5sum in.txt", {"commands": ["md5sum", "printf"]}),
        ("check", "printf hello > in.txt; md5sum in.txt > sums; md5sum -c sums", {"commands": ["md5sum", "printf"]}),
        ("binary", "printf hello > in.txt; md5sum -b in.txt", {"commands": ["md5sum", "printf"]}),
        ("missing", "md5sum missing; printf 'status:%s\\n' \"$?\"", {"commands": ["md5sum", "printf"]}),
    ])

    add_required("sha1sum", [
        ("stdin", "printf hello | sha1sum", {"commands": ["sha1sum", "printf"]}),
        ("file", "printf hello > in.txt; sha1sum in.txt", {"commands": ["sha1sum", "printf"]}),
        ("check", "printf hello > in.txt; sha1sum in.txt > sums; sha1sum -c sums", {"commands": ["sha1sum", "printf"]}),
        ("binary", "printf hello > in.txt; sha1sum -b in.txt", {"commands": ["sha1sum", "printf"]}),
        ("missing", "sha1sum missing; printf 'status:%s\\n' \"$?\"", {"commands": ["sha1sum", "printf"]}),
    ])

    add_required("sha256sum", [
        ("stdin", "printf hello | sha256sum", {"commands": ["sha256sum", "printf"]}),
        ("file", "printf hello > in.txt; sha256sum in.txt", {"commands": ["sha256sum", "printf"]}),
        ("check", "printf hello > in.txt; sha256sum in.txt > sums; sha256sum -c sums", {"commands": ["sha256sum", "printf"]}),
        ("binary", "printf hello > in.txt; sha256sum -b in.txt", {"commands": ["sha256sum", "printf"]}),
        ("missing", "sha256sum missing; printf 'status:%s\\n' \"$?\"", {"commands": ["sha256sum", "printf"]}),
    ])

    add_required("mkdir", [
        ("simple", "mkdir d; test -d d; printf 'status:%s\\n' \"$?\"", {"commands": ["mkdir", "test", "printf"]}),
        ("parents", "mkdir -p a/b/c; find a -type d | sort", {"commands": ["mkdir", "find", "sort"]}),
        ("mode", "mkdir -m 700 d; stat -c '%a' d", {"commands": ["mkdir", "stat"]}),
        ("existing", "mkdir d; mkdir d; printf 'status:%s\\n' \"$?\"", {"commands": ["mkdir", "printf"]}),
    ])

    add_required("mktemp", [
        ("file-template", "mktemp case.XXXXXX | sed 's/[A-Za-z0-9]$/X/'", {"commands": ["mktemp", "sed"]}),
        ("directory", "mktemp -d case.XXXXXX | sed 's/[A-Za-z0-9]$/X/'", {"commands": ["mktemp", "sed"]}),
        ("tmpdir-relative", "mkdir tmp; TMPDIR=tmp mktemp case.XXXXXX | sed 's/[A-Za-z0-9]$/X/'", {"commands": ["mktemp", "mkdir", "sed"]}),
        ("dry-run", "mktemp -u case.XXXXXX | sed 's/[A-Za-z0-9]$/X/'", {"commands": ["mktemp", "sed"]}),
        ("bad-template", "mktemp bad; printf 'status:%s\\n' \"$?\"", {"commands": ["mktemp", "printf"]}),
    ])

    add_required("mv", [
        ("rename", "printf old > old; mv old new; cat new", {"commands": ["mv", "printf", "cat"]}),
        ("target-dir", "mkdir d; printf a > a; mv a d; find d -type f -printf '%f:%s\\n'", {"commands": ["mv", "mkdir", "printf", "find"]}),
        ("no-clobber", "printf old > dst; printf new > src; mv -n src dst; cat dst; test -e src; printf ' status:%s\\n' \"$?\"", {"commands": ["mv", "printf", "cat", "test"]}),
        ("missing", "mv missing dst; printf 'status:%s\\n' \"$?\"", {"commands": ["mv", "printf"]}),
    ])

    add_required("nl", [
        ("body", "printf 'a\\nb\\n' | nl -ba", {"commands": ["nl", "printf"]}),
        ("number-format", "printf 'a\\nb\\n' | nl -ba -n rz -w 3", {"commands": ["nl", "printf"]}),
        ("separator", "printf 'a\\nb\\n' | nl -ba -s ':'", {"commands": ["nl", "printf"]}),
        ("file", "printf 'x\\ny\\n' > f; nl -ba f", {"commands": ["nl", "printf"]}),
        ("sections", "printf 'intro\\n\\\\:\\\\\\:\\\\\\:\\nhead\\n\\\\:\\\\\\:\\nbody\\n\\\\:\\nfoot\\n' | nl -ha -ba -fa -w2 -s:", {"commands": ["nl", "printf"]}),
        ("no-renumber", "printf 'one\\n\\\\:\\\\\\:\\ntwo\\n' | nl -ba -p -w1 -s:", {"commands": ["nl", "printf"]}),
        ("join-blank-lines", "printf '\\n\\n\\nx\\n' | nl -ba -l2 -w1 -s:", {"commands": ["nl", "printf"]}),
        ("pattern-style", "printf 'A\\nB\\nAA\\n' | nl -bp'^A' -w1 -s:", {"commands": ["nl", "printf"]}),
    ])

    add_required("nproc", [
        ("default", "nproc", None),
        ("all", "nproc --all", None),
        ("ignore-large", "nproc --ignore=9999; printf 'status:%s\\n' \"$?\"", {"commands": ["nproc", "printf"]}),
        ("invalid", "nproc --ignore=nope; printf 'status:%s\\n' \"$?\"", {"commands": ["nproc", "printf"]}),
    ])

    add_required("numfmt", [
        ("to-si", "printf '1500\\n' | numfmt --to=si", {"commands": ["numfmt", "printf"]}),
        ("from-si", "printf '1.5K\\n' | numfmt --from=si", {"commands": ["numfmt", "printf"]}),
        ("field", "printf 'aa 1500 zz\\n' | numfmt --field=2 --to=si", {"commands": ["numfmt", "printf"]}),
        ("padding", "printf '1500\\n' | numfmt --to=si --padding=8", {"commands": ["numfmt", "printf"]}),
        ("invalid", "printf 'nope\\n' | numfmt --to=si; printf 'status:%s\\n' \"$?\"", {"commands": ["numfmt", "printf"]}),
    ])

    add_required("od", [
        ("default", "printf ABCD > bytes; od bytes", {"commands": ["od", "printf"]}),
        ("hex", "printf ABCD | od -An -tx1", {"commands": ["od", "printf"]}),
        ("skip-count", "printf ABCDEF > bytes; od -An -tx1 -j1 -N3 bytes", {"commands": ["od", "printf"]}),
        ("width", "printf ABCD | od -An -tx1 -w2", {"commands": ["od", "printf"]}),
        ("chars", "printf 'A\\n' | od -An -tc", {"commands": ["od", "printf"]}),
    ])

    add_required("paste", [
        ("files", "printf 'a\\nb\\n' > a; printf '1\\n2\\n' > b; paste a b", {"commands": ["paste", "printf"]}),
        ("delimiter", "printf 'a\\nb\\n' > a; printf '1\\n2\\n' > b; paste -d ':' a b", {"commands": ["paste", "printf"]}),
        ("serial", "printf 'a\\nb\\n' > a; paste -s a", {"commands": ["paste", "printf"]}),
        ("stdin", "printf 'a\\nb\\n' | paste -s -", {"commands": ["paste", "printf"]}),
        ("repeated-stdin", "printf 'a\\nb\\nc\\nd\\n' | paste - -", {"commands": ["paste", "printf"]}),
        ("binary-empty-delimiter", "python3 - <<'PY'\nopen('p.bin','wb').write(bytes([0xff, 0x0a, 0xfe, 0x0a]))\nPY\npaste -s -d '\\0' p.bin | od -An -tx1", {"commands": ["paste", "python3", "od"]}),
        ("delimiter-escapes", "printf 'a\\nb\\nc\\nd\\ne\\nf\\n' | paste -s -d '\\b\\f\\r\\v\\\\' - | od -An -tx1", {"commands": ["paste", "printf", "od"]}),
        ("delimiter-trailing-backslash", "printf 'a\\n' | paste -d '\\' -; printf 'status:%s\\n' \"$?\"", {"commands": ["paste", "printf"]}),
        ("zero-serial", "printf 'a\\0b\\0' | paste -z -s -d ',' - | od -An -tx1", {"commands": ["paste", "printf", "od"]}),
        ("zero-binary-serial", "python3 - <<'PY' | paste -z -s -d ':' - | od -An -tx1\nimport sys\nsys.stdout.buffer.write(bytes([0xff, 0x00, 0xfe, 0x00]))\nPY", {"commands": ["paste", "python3", "od"]}),
    ])

    add_required("pathchk", [
        ("ok", "pathchk ok dir/file; printf 'status:%s\\n' \"$?\"", {"commands": ["pathchk", "printf"]}),
        ("empty", "pathchk ''; printf 'status:%s\\n' \"$?\"", {"commands": ["pathchk", "printf"]}),
        ("posix", "pathchk -p ok_name; printf 'status:%s\\n' \"$?\"", {"commands": ["pathchk", "printf"]}),
        ("portability", "pathchk -P 'bad/name/with spaces'; printf 'status:%s\\n' \"$?\"", {"commands": ["pathchk", "printf"]}),
    ])

    add_required("printf", [
        ("string", "printf '%s\\n' ok", None),
        ("integers", "printf '%04d %#x\\n' 7 255", None),
        ("reuse-format", "printf '<%s>' a b c; printf '\\n'", {"commands": ["printf"]}),
        ("missing-argument", "printf '%s/%s\\n' only", None),
        ("invalid-number", "printf '%d\\n' nope; printf 'status:%s\\n' \"$?\"", {"commands": ["printf"]}),
    ])

    add_required("printenv", [
        ("one", "FOO=bar printenv FOO", {"commands": ["printenv"]}),
        ("many", "FOO=bar EMPTY= printenv FOO EMPTY", {"commands": ["printenv"]}),
        ("missing", "printenv DEFINITELY_MISSING; printf 'status:%s\\n' \"$?\"", {"commands": ["printenv", "printf"]}),
        ("zero", "FOO=bar printenv -0 FOO | od -An -tx1", {"commands": ["printenv", "od"]}),
    ])

    add_required("ps", [
        ("current-command", "ps -o comm= -p $$", {"commands": ["ps"]}),
        ("pid-comm-header", "ps -o pid,comm -p $$ | sed 's/[0-9][0-9]*/PID/g'", {"commands": ["ps", "sed"]}),
        ("invalid-option", "ps --definitely-invalid; printf 'status:%s\\n' \"$?\"", {"commands": ["ps", "printf"]}),
    ])

    add_required("pwd", [
        ("default", "pwd", None),
        ("logical-physical", "mkdir real; ln -s real link; cd link; pwd -L; pwd -P", {"commands": ["pwd", "mkdir", "ln", "cd"]}),
        ("invalid-option", "pwd --definitely-invalid; printf 'status:%s\\n' \"$?\"", {"commands": ["pwd", "printf"]}),
    ])

    add_required("readlink", [
        ("symlink", "printf data > target; ln -s target link; readlink link", {"commands": ["readlink", "printf", "ln"]}),
        ("canonicalize", "mkdir -p d; printf data > d/file; ln -s d linkdir; readlink -f linkdir/file", {"commands": ["readlink", "mkdir", "printf", "ln"]}),
        ("missing", "readlink missing; printf 'status:%s\\n' \"$?\"", {"commands": ["readlink", "printf"]}),
        ("no-newline", "ln -s target link; readlink -n link; printf '\\n'", {"commands": ["readlink", "ln", "printf"]}),
    ])

    add_required("realpath", [
        ("file", "printf data > file; realpath file", {"commands": ["realpath", "printf"]}),
        ("relative-to", "mkdir -p a/b; printf data > a/b/file; realpath --relative-to=a a/b/file", {"commands": ["realpath", "mkdir", "printf"]}),
        ("relative-base", "mkdir -p a/b; printf data > a/b/file; realpath --relative-base=a a/b/file", {"commands": ["realpath", "mkdir", "printf"]}),
        ("missing", "realpath missing; printf 'status:%s\\n' \"$?\"", {"commands": ["realpath", "printf"]}),
    ])

    add_required("rg", [
        ("basic", "mkdir docs; printf 'alpha\\nbeta\\n' > docs/a.txt; rg beta docs", {"commands": ["rg", "mkdir", "printf"]}),
        ("line-number", "mkdir docs; printf 'alpha\\nbeta\\n' > docs/a.txt; rg -n beta docs", {"commands": ["rg", "mkdir", "printf"]}),
        ("files", "mkdir -p docs/sub; : > docs/a.txt; : > docs/sub/b.md; rg --files docs | sort", {"commands": ["rg", "mkdir", ":", "sort"]}),
        ("glob", "mkdir docs; printf beta > docs/a.txt; printf beta > docs/b.md; rg -g '*.txt' beta docs", {"commands": ["rg", "mkdir", "printf"]}),
        ("missing", "rg beta missing; printf 'status:%s\\n' \"$?\"", {"commands": ["rg", "printf"]}),
    ])

    add_required("rm", [
        ("file", "printf data > f; rm f; test ! -e f; printf 'status:%s\\n' \"$?\"", {"commands": ["rm", "printf", "test"]}),
        ("recursive-relative", "mkdir -p d/sub; : > d/sub/file; rm -r d; test ! -e d; printf 'status:%s\\n' \"$?\"", {"commands": ["rm", "mkdir", ":", "test", "printf"]}),
        ("force-missing", "rm -f missing; printf 'status:%s\\n' \"$?\"", {"commands": ["rm", "printf"]}),
        ("directory-without-recursive", "mkdir d; rm d; printf 'status:%s\\n' \"$?\"", {"commands": ["rm", "mkdir", "printf"]}),
    ])

    add_required("sed", [
        ("substitute", "printf 'abc\\n' | sed 's/b/B/'", {"commands": ["sed", "printf"]}),
        ("script-file", "printf 's/a/A/\\n' > script.sed; printf 'abc\\n' | sed -f script.sed", {"commands": ["sed", "printf"]}),
        ("quiet-print", "printf 'a\\nb\\n' | sed -n '2p'", {"commands": ["sed", "printf"]}),
        ("in-place", "printf 'abc\\n' > f; sed -i 's/b/B/' f; cat f", {"commands": ["sed", "printf", "cat"]}),
        ("invalid-script", "printf 'abc\\n' | sed 's/[//'; printf 'status:%s\\n' \"$?\"", {"commands": ["sed", "printf"]}),
    ])

    add_required("seq", [
        ("one", "seq 3", None),
        ("reverse", "seq 3 -1 1", None),
        ("separator", "seq -s, 1 3", None),
        ("format", "seq -f 'item:%04.1f' 1 2", None),
        ("invalid", "seq nope; printf 'status:%s\\n' \"$?\"", {"commands": ["seq", "printf"]}),
    ])

    add_required("sort", [
        ("default", "printf 'b\\na\\n' | sort", {"commands": ["sort", "printf"]}),
        ("numeric", "printf '10\\n2\\n1\\n' | sort -n", {"commands": ["sort", "printf"]}),
        ("reverse", "printf 'a\\nb\\n' | sort -r", {"commands": ["sort", "printf"]}),
        ("unique", "printf 'b\\nb\\na\\n' | sort -u", {"commands": ["sort", "printf"]}),
        ("field", "printf 'b 2\\na 10\\n' | sort -k2,2n", {"commands": ["sort", "printf"]}),
        ("general-numeric", "printf 'NaN\\n10\\n2.5\\n-3\\n' | sort -g", {"commands": ["sort", "printf"]}),
        ("month", "printf 'Mar\\nJan\\nFeb\\n' | sort -M", {"commands": ["sort", "printf"]}),
        ("version", "printf 'v1.10\\nv1.2\\nv1.1\\n' | sort -V", {"commands": ["sort", "printf"]}),
        ("ignore-nonprinting", "printf 'a#\\na!\\naa\\n' | sort -i", {"commands": ["sort", "printf"]}),
        ("check-quiet", "printf 'b\\na\\n' | sort -C; printf 'status:%s\\n' \"$?\"; printf 'b\\na\\n' | sort --check=quiet; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("check-invalid", "sort --check=nope; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("stable-numeric", "printf '2 b\\n2 a\\n1 c\\n' | sort -n -s", {"commands": ["sort", "printf"]}),
        ("unique-key", "printf 'b|2\\na|2\\nc|1\\n' | sort -u -t '|' -k 2,2n", {"commands": ["sort", "printf"]}),
        ("files0-from", "printf 'delta\\nalpha\\n' > a; printf 'charlie\\nbravo\\n' > b; printf 'a\\0b\\0' > list0; sort --files0-from=list0", {"commands": ["sort", "printf"]}),
        ("files0-from-stdin", "printf 'delta\\nalpha\\n' > a; printf 'charlie\\nbravo\\n' > b; printf 'b\\0a\\0' | sort --files0-from=-", {"commands": ["sort", "printf"]}),
        ("files0-from-empty", ": > empty; sort --files0-from=empty; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", ":", "printf"]}),
        ("files0-from-mixed-operands", ": > a; printf 'a\\0' > list0; sort --files0-from=list0 a; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", ":", "printf"]}),
        ("files0-from-empty-name", ": > a; printf 'a\\0\\0' | sort --files0-from=-; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", ":", "printf"]}),
        ("files0-from-dash-member", "printf -- '-\\0' | sort --files0-from=-; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("performance-knobs", "mkdir tmpdir; printf 'b\\na\\n' | sort --batch-size=2 --parallel=2 -S 1M -T tmpdir", {"commands": ["sort", "mkdir", "printf"]}),
        ("merge-presorted", "printf 'a\\nc\\n' > left; printf 'b\\nd\\n' > right; sort --merge left right", {"commands": ["sort", "printf"]}),
        ("merge-does-not-resort-file", "printf 'b\\na\\n' > left; printf 'c\\n' > right; sort -m left right", {"commands": ["sort", "printf"]}),
        ("key-character-offset", "printf 'alpha-2\\nalpha-1\\n' | sort -k1.7,1.7", {"commands": ["sort", "printf"]}),
        ("key-delimited-character-offset", "printf 'a|b2\\na|b1\\n' | sort -t '|' -k2.2,2.2", {"commands": ["sort", "printf"]}),
        ("key-per-key-numeric", "printf 'x|10\\nx|2\\n' | sort -t '|' -k2n,2", {"commands": ["sort", "printf"]}),
        ("key-inherits-global-numeric", "printf 'x|10\\nx|2\\n' | sort -n -t '|' -k2,2", {"commands": ["sort", "printf"]}),
        ("key-global-reverse-last-resort", "printf 'x|2|b\\nx|2|a\\n' | sort -r -t '|' -k2,2n", {"commands": ["sort", "printf"]}),
        ("random-source", "printf '0123456789abcdef-extra' > seed; printf 'a\\nb\\na\\nc\\n' | sort -R --random-source=seed", {"commands": ["sort", "printf"]}),
        ("sort-word-random", "printf '0123456789abcdef-extra' > seed; printf 'alpha\\nbeta\\ngamma\\n' | sort --sort=random --random-source=seed", {"commands": ["sort", "printf"]}),
        ("random-source-alpha", "printf '0123456789abcdef-extra' > seed; printf 'alpha\\nbeta\\ngamma\\n' | sort -R --random-source=seed", {"commands": ["sort", "printf"]}),
        ("sort-word-random-abc", "printf '0123456789abcdef-extra' > seed; printf 'a\\nb\\na\\nc\\n' | sort --sort=random --random-source=seed", {"commands": ["sort", "printf"]}),
        ("debug-default-key", "printf 'b\\ta\\n' | sort --debug", {"commands": ["sort", "printf"]}),
        ("debug-check-incompatible", "printf 'a\\n' | sort -c --debug; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("debug-output-incompatible", "printf 'a\\n' | sort -o out --debug; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("buffer-size-suffix-validation", "printf 'b\\na\\n' | sort -S 10b; printf 'b\\na\\n' | sort --buffer-size=1%; sort -S 1Q; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("ordering-incompatible", "printf '1\\n2\\n' | sort -nR; printf 'status:%s\\n' \"$?\"", {"commands": ["sort", "printf"]}),
        ("output-same-as-input", "printf 'b\\na\\n' > data; sort -o data data; cat data", {"commands": ["sort", "printf", "cat"]}),
        ("long-input-stress-count", "python3 - <<'PY' | sort -n | wc -l\nfor value in range(4000, 0, -1):\n    print(value)\nPY", {"commands": ["python3", "sort", "wc"], "timeout_seconds": 10.0}),
    ])
