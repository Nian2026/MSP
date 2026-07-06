from __future__ import annotations

from typing import Any, Callable

CaseAdder = Callable[[str, list[tuple[str, str, dict[str, Any] | None]]], None]
FileItemFactory = Callable[[str, bytes | str, str], dict[str, Any]]

def add_shell_builtin_cases(add: CaseAdder, add_required: CaseAdder, file_item: FileItemFactory, shell_file: dict[str, Any], source_file: dict[str, Any]) -> None:
    add("export", [
        ("list", "export | sort | head -n 5", None),
        ("print", "export -p | sort | head -n 5", None),
        ("assignment-child", "export FOO=bar; env | grep '^FOO='", {"commands": ["export", "env", "grep"]}),
        ("multiple", "export A=1 B=two; env | grep -E '^(A|B)=' | sort", {"commands": ["export", "env", "grep", "sort"]}),
        ("remove-export", "export FOO=bar; export -n FOO; env | grep '^FOO='; printf 'status:%s\\n' \"$?\"", {"commands": ["export", "env", "grep", "printf"]}),
        ("invalid-identifier", "export BAD-NAME=1; printf 'status:%s\\n' \"$?\"", {"commands": ["export", "printf"]}),
        ("function-name", "f(){ :; }; export -f f; printf 'status:%s\\n' \"$?\"", {"commands": ["export", "printf", ":"]}),
        ("empty-value", "export EMPTY=; env | grep '^EMPTY='", {"commands": ["export", "env", "grep"]}),
        ("append-value", "X=a; export X+=b; printf '%s\\n' \"$X\"", {"commands": ["export", "printf"]}),
        ("readonly-diagnostic", "readonly R=1; export R=2; printf 'status:%s\\n' \"$?\"", {"commands": ["export", "printf"]}),
        ("command-lookup", "command -v export; type export", {"commands": ["export", "command", "type"]}),
        ("subshell-isolation", "(export SUB=1); env | grep '^SUB='; printf 'status:%s\\n' \"$?\"", {"commands": ["export", "env", "grep", "printf"]}),
    ])

    add("unset", [
        ("variable", "FOO=bar; unset FOO; printf '<%s>\\n' \"$FOO\"", {"commands": ["unset", "printf"]}),
        ("function", "gone(){ echo bad; }; unset -f gone; gone; printf 'status:%s\\n' \"$?\"", {"commands": ["unset", "printf"]}),
        ("array", "arr=(a b c); unset 'arr[1]'; printf '%s/%s/%s\\n' \"${arr[0]}\" \"${arr[1]}\" \"${arr[2]}\"", {"commands": ["unset", "printf"]}),
        ("associative", "declare -A m=([x]=1 [y]=2); unset 'm[x]'; printf '%s/%s\\n' \"${m[x]}\" \"${m[y]}\"", {"commands": ["unset", "declare", "printf"]}),
        ("missing", "unset DOES_NOT_EXIST; printf 'status:%s\\n' \"$?\"", {"commands": ["unset", "printf"]}),
        ("invalid-option", "unset -Z FOO; printf 'status:%s\\n' \"$?\"", {"commands": ["unset", "printf"]}),
        ("v-option", "FOO=bar; unset -v FOO; printf '<%s>\\n' \"$FOO\"", {"commands": ["unset", "printf"]}),
        ("multiple", "A=1 B=2; unset A B; printf '<%s><%s>\\n' \"$A\" \"$B\"", {"commands": ["unset", "printf"]}),
        ("readonly", "readonly RO=1; unset RO; printf 'status:%s\\n' \"$?\"", {"commands": ["unset", "printf"]}),
        ("lookup", "command -v unset; type unset", {"commands": ["unset", "command", "type"]}),
    ])

    add("set", [
        ("positional", "set -- alpha 'two words'; printf '%s/%s/%s\\n' \"$#\" \"$1\" \"$2\"", {"commands": ["set", "printf"]}),
        ("option-flags", "set -efu -o pipefail; printf '%s\\n' \"$-\"; set +e +f +u +o pipefail; printf '%s\\n' \"$-\"", {"commands": ["set", "printf"]}),
        ("nounset", "set -u; printf '%s\\n' \"${MISSING:-fallback}\"; echo \"$MISSING\"; echo after", {"commands": ["set", "printf", "echo"]}),
        ("noglob", "touch a.txt; set -f; printf '<%s>\\n' *.txt", {"commands": ["set", "touch", "printf"]}),
        ("pipefail", "set -o pipefail; false | true; printf 'status:%s\\n' \"$?\"", {"commands": ["set", "false", "true", "printf"]}),
        ("show-options", "set -o | grep -E 'errexit|nounset|pipefail' | sort", {"commands": ["set", "grep", "sort"]}),
        ("invalid-option", "set -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["set", "printf"]}),
        ("dash-positional", "set -- x y; printf '%s:%s:%s\\n' \"$#\" \"$1\" \"$2\"", {"shell": "sh", "commands": ["set", "printf"]}),
        ("empty-positional", "set --; printf '%s\\n' \"$#\"", {"commands": ["set", "printf"]}),
        ("errexit-subshell", "(set -e; false; echo bad); printf 'status:%s\\n' \"$?\"", {"commands": ["set", "false", "echo", "printf"]}),
        ("double-dash", "set -- -a -- -b; printf '%s|%s|%s\\n' \"$1\" \"$2\" \"$3\"", {"commands": ["set", "printf"]}),
        ("plus-o", "set +o | head -n 3", {"commands": ["set", "head"]}),
        ("lookup", "command -v set; type set", {"commands": ["set", "command", "type"]}),
        ("xtrace-smoke", "set -x; echo xtrace 2>trace.err; set +x; cat trace.err | head -n 2", {"commands": ["set", "echo", "cat", "head"]}),
    ])

    add("read", [
        ("default", "printf 'alpha beta\\n' | { read a b; printf '%s/%s\\n' \"$a\" \"$b\"; }", {"commands": ["read", "printf"]}),
        ("raw", "printf 'a\\\\b\\n' | { read -r x; printf '%s\\n' \"$x\"; }", {"commands": ["read", "printf"]}),
        ("delimiter", "printf 'ab:cd:ef' | { read -d : x; printf '%s\\n' \"$x\"; }", {"commands": ["read", "printf"]}),
        ("nchars", "printf 'abcdef' | { read -n 3 x; printf '%s\\n' \"$x\"; }", {"commands": ["read", "printf"]}),
        ("ifs", "printf 'a,b,c\\n' | { IFS=, read x y z; printf '%s/%s/%s\\n' \"$x\" \"$y\" \"$z\"; }", {"commands": ["read", "printf"]}),
        ("eof", "{ read x; printf 'status:%s value:%s\\n' \"$?\" \"$x\"; } < empty.txt", {"files": [file_item("empty.txt", "")], "commands": ["read", "printf"]}),
        ("u-fd", "printf 'fdline\\n' > in.txt; exec 3<in.txt; read -u 3 x; printf '%s\\n' \"$x\"", {"commands": ["read", "printf"]}),
        ("closed-fd", "exec 3<&-; read -u 3 x; printf 'status:%s\\n' \"$?\"", {"commands": ["read", "printf"]}),
        ("array-a", "printf 'one two\\n' | { read -a arr; printf '%s/%s/%s\\n' \"${arr[0]}\" \"${arr[1]}\" \"${#arr[@]}\"; }", {"commands": ["read", "printf"]}),
        ("prompt-noninteractive", "printf 'value\\n' | { read -p 'Prompt:' x; printf '%s\\n' \"$x\"; }", {"commands": ["read", "printf"]}),
        ("timeout-zero", "read -t 0 x < empty.txt; printf 'status:%s\\n' \"$?\"", {"files": [file_item("empty.txt", "")], "commands": ["read", "printf"]}),
        ("lookup", "command -v read; type read", {"commands": ["read", "command", "type"]}),
        ("dash-read", "printf 'a b\\n' | { read x y; printf '%s/%s\\n' \"$x\" \"$y\"; }", {"shell": "sh", "commands": ["read", "printf"]}),
        ("invalid-option", "read -Z x; printf 'status:%s\\n' \"$?\"", {"commands": ["read", "printf"]}),
        ("newline-backslash", "printf 'a\\\\\\nb\\n' | { read x; printf '%s\\n' \"$x\"; }", {"commands": ["read", "printf"]}),
        ("multiple-lines", "printf 'one\\ntwo\\n' | { read a; read b; printf '%s/%s\\n' \"$a\" \"$b\"; }", {"commands": ["read", "printf"]}),
    ])

    add("source", [
        ("dot-state", ". ./script.env; pwd; printf '%s\\n' \"$VAR_FROM_SOURCE\"", {"directories": ["sub"], "files": [shell_file], "commands": ["source", "pwd", "printf"]}),
        ("source-state", "source ./source.sh; mark ok; printf '%s\\n' \"$VALUE\"", {"files": [source_file], "commands": ["source", "printf"]}),
        ("args", "printf 'printf \"%s/%s/%s\\\\n\" \"$0\" \"$1\" \"$2\"\\n' > args.sh; source args.sh one two", {"commands": ["source", "printf"]}),
        ("missing", "source missing.sh; printf 'status:%s\\n' \"$?\"", {"commands": ["source", "printf"]}),
        ("return", "printf 'echo before\\nreturn 7\\necho after\\n' > r.sh; source r.sh; printf 'status:%s\\n' \"$?\"", {"commands": ["source", "printf"]}),
        ("nested", "printf 'INNER=1\\n' > inner.sh; printf 'source inner.sh\\n' > outer.sh; source outer.sh; printf '%s\\n' \"$INNER\"", {"commands": ["source", "printf"]}),
        ("fd", "printf 'printf fd >&3\\n' > fd.sh; source fd.sh 3>out.txt; cat out.txt", {"commands": ["source", "cat"]}),
        ("lookup", "command -v source; type source; command -v .; type .", {"commands": ["source", "command", "type"]}),
        ("syntax-error", "printf 'if true; then\\n' > bad.sh; source bad.sh; printf 'status:%s\\n' \"$?\"", {"commands": ["source", "printf", "true"]}),
        ("cwd", "mkdir sub; printf 'cd sub\\n' > cd.sh; source cd.sh; pwd", {"commands": ["source", "mkdir", "pwd"]}),
        ("function-return", "printf 'return 3\\n' > ret.sh; f(){ source ret.sh; printf after; }; f; printf ' status:%s\\n' \"$?\"", {"commands": ["source", "printf"]}),
        ("dash-dot", ". ./script.env; pwd", {"shell": "sh", "directories": ["sub"], "files": [shell_file], "commands": ["source", "pwd"]}),
    ])

    add("alias", [
        ("list-empty", "alias", None),
        ("set-list", "alias ll='printf alias-ok\\\\n'; alias ll", {"commands": ["alias", "printf"]}),
        ("expand", "shopt -s expand_aliases; alias hi='printf hi\\\\n'; hi", {"commands": ["alias", "printf"]}),
        ("quote", "alias spaced='printf \"two words\\\\n\"'; alias spaced", {"commands": ["alias", "printf"]}),
        ("multiple", "alias a='echo a' b='echo b'; alias a b", {"commands": ["alias", "echo"]}),
        ("missing", "alias missing; printf 'status:%s\\n' \"$?\"", {"commands": ["alias", "printf"]}),
        ("invalid-name", "alias 'bad-name=value'; printf 'status:%s\\n' \"$?\"", {"commands": ["alias", "printf"]}),
        ("not-expanded-noninteractive", "alias hi='printf hi\\\\n'; hi; printf 'status:%s\\n' \"$?\"", {"commands": ["alias", "printf"]}),
        ("function-body", "alias greet='printf greet\\\\n'; f(){ shopt -s expand_aliases; greet; }; f", {"commands": ["alias", "printf"]}),
        ("lookup", "command -v alias; type alias", {"commands": ["alias", "command", "type"]}),
        ("overwrite", "alias x='echo one'; alias x='echo two'; alias x", {"commands": ["alias", "echo"]}),
        ("reserved-word", "alias if='echo bad'; printf 'status:%s\\n' \"$?\"", {"commands": ["alias", "printf"]}),
    ])

    add("unalias", [
        ("one", "alias a='echo a'; unalias a; alias a; printf 'status:%s\\n' \"$?\"", {"commands": ["alias", "unalias", "printf"]}),
        ("many", "alias a='echo a' b='echo b'; unalias a b; alias a b; printf 'status:%s\\n' \"$?\"", {"commands": ["alias", "unalias", "printf"]}),
        ("all", "alias a='echo a' b='echo b'; unalias -a; alias", {"commands": ["alias", "unalias", "echo"]}),
        ("missing", "unalias missing; printf 'status:%s\\n' \"$?\"", {"commands": ["unalias", "printf"]}),
        ("invalid-option", "unalias -Z; printf 'status:%s\\n' \"$?\"", {"commands": ["unalias", "printf"]}),
        ("lookup", "command -v unalias; type unalias", {"commands": ["unalias", "command", "type"]}),
        ("expanded-after-remove", "shopt -s expand_aliases; alias hi='printf hi\\\\n'; unalias hi; hi; printf 'status:%s\\n' \"$?\"", {"commands": ["unalias", "alias", "printf"]}),
        ("no-args", "unalias; printf 'status:%s\\n' \"$?\"", {"commands": ["unalias", "printf"]}),
    ])

    add("umask", [
        ("default", "umask", None),
        ("p", "umask -p", None),
        ("symbolic-output", "umask -S", None),
        ("octal-side-effect", "umask 077; : > f.txt; mkdir d; stat -c '%a %n' f.txt d | sort", {"commands": ["umask", ":", "mkdir", "stat", "sort"]}),
        ("symbolic-mode", "umask u=rw,g=r,o=; umask; : > f.txt; stat -c '%a' f.txt", {"commands": ["umask", ":", "stat"]}),
        ("invalid-octal", "umask 888; printf 'status:%s\\n' \"$?\"", {"commands": ["umask", "printf"]}),
        ("invalid-symbolic", "umask z+r; printf 'status:%s\\n' \"$?\"", {"commands": ["umask", "printf"]}),
        ("pipeline-isolation", "umask 077; umask 000 | cat; umask", {"commands": ["umask", "cat"]}),
        ("lookup", "command -v umask; type umask", {"commands": ["umask", "command", "type"]}),
        ("dash", "umask 022; umask", {"shell": "sh"}),
        ("too-many", "umask 022 033; printf 'status:%s\\n' \"$?\"", {"commands": ["umask", "printf"]}),
        ("file-after-reset", "umask 077; umask 022; : > f.txt; stat -c '%a' f.txt", {"commands": ["umask", ":", "stat"]}),
    ])

    add("rmdir", [
        ("empty", "mkdir a; rmdir a; test ! -e a; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "mkdir", "test", "printf"]}),
        ("nonempty", "mkdir a; : > a/file; rmdir a; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "mkdir", ":", "printf"]}),
        ("parents", "mkdir -p a/b/c; rmdir -p a/b/c; find . -maxdepth 3 -print | sort", {"commands": ["rmdir", "mkdir", "find", "sort"]}),
        ("ignore-nonempty", "mkdir a; : > a/file; rmdir --ignore-fail-on-non-empty a; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "mkdir", ":", "printf"]}),
        ("missing", "rmdir missing; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "printf"]}),
        ("multiple", "mkdir a b; rmdir a b; find . -maxdepth 1 -print | sort", {"commands": ["rmdir", "mkdir", "find", "sort"]}),
        ("dash-path", "mkdir -- -d; rmdir -- -d; test ! -e ./-d; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "mkdir", "test", "printf"]}),
        ("invalid-option", "rmdir -Z a; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "printf"]}),
        ("verbose", "mkdir a; rmdir -v a", {"commands": ["rmdir", "mkdir"]}),
        ("parent-nonempty", "mkdir -p a/b; : > a/file; rmdir -p a/b; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "mkdir", ":", "printf"]}),
        ("symlink", "mkdir target; ln -s target link; rmdir link; printf 'status:%s\\n' \"$?\"", {"commands": ["rmdir", "mkdir", "ln", "printf"]}),
        ("space", "mkdir 'space dir'; rmdir 'space dir'; test ! -e 'space dir'", {"commands": ["rmdir", "mkdir", "test"]}),
    ])

    add("unlink", [
        ("file", ": > f.txt; unlink f.txt; test ! -e f.txt; printf 'status:%s\\n' \"$?\"", {"commands": ["unlink", ":", "test", "printf"]}),
        ("missing", "unlink missing; printf 'status:%s\\n' \"$?\"", {"commands": ["unlink", "printf"]}),
        ("dir", "mkdir d; unlink d; printf 'status:%s\\n' \"$?\"", {"commands": ["unlink", "mkdir", "printf"]}),
        ("extra", ": > a; : > b; unlink a b; printf 'status:%s\\n' \"$?\"", {"commands": ["unlink", ":", "printf"]}),
        ("no-operand", "unlink; printf 'status:%s\\n' \"$?\"", {"commands": ["unlink", "printf"]}),
        ("dash-path", ": > ./-x; unlink -- -x; test ! -e ./-x", {"commands": ["unlink", ":", "test"]}),
        ("symlink", ": > target; ln -s target link; unlink link; test -e target && test ! -e link; printf 'status:%s\\n' \"$?\"", {"commands": ["unlink", "ln", "test", "printf"]}),
        ("space", ": > 'a b'; unlink 'a b'; test ! -e 'a b'", {"commands": ["unlink", ":", "test"]}),
    ])

    add("truncate", [
        ("create", "truncate -s 5 f.bin; stat -c '%s' f.bin", {"commands": ["truncate", "stat"]}),
        ("no-create", "truncate -c -s 5 missing.bin; printf 'status:%s\\n' \"$?\"; test ! -e missing.bin", {"commands": ["truncate", "printf", "test"]}),
        ("shrink", "printf abcdef > f; truncate -s 3 f; wc -c < f; cat f", {"commands": ["truncate", "printf", "wc", "cat"]}),
        ("grow", "printf abc > f; truncate -s 6 f; stat -c '%s' f; od -An -tx1 f", {"commands": ["truncate", "printf", "stat", "od"]}),
        ("relative-plus", "printf abc > f; truncate -s +2 f; stat -c '%s' f", {"commands": ["truncate", "printf", "stat"]}),
        ("relative-minus", "printf abcdef > f; truncate -s -2 f; stat -c '%s' f", {"commands": ["truncate", "printf", "stat"]}),
        ("suffix-k", "truncate -s 1K f; stat -c '%s' f", {"commands": ["truncate", "stat"]}),
        ("reference", "printf abcdef > ref; truncate -r ref f; stat -c '%s' f", {"commands": ["truncate", "printf", "stat"]}),
        ("missing-size", "truncate f; printf 'status:%s\\n' \"$?\"", {"commands": ["truncate", "printf"]}),
        ("invalid-size", "truncate -s nope f; printf 'status:%s\\n' \"$?\"", {"commands": ["truncate", "printf"]}),
        ("multiple", "truncate -s 2 a b; stat -c '%n:%s' a b | sort", {"commands": ["truncate", "stat", "sort"]}),
        ("io-blocks", "truncate -o -s 1 f; stat -c '%s' f", {"commands": ["truncate", "stat"]}),
        ("space-path", "truncate -s 4 'a b'; stat -c '%s' 'a b'", {"commands": ["truncate", "stat"]}),
        ("invalid-option", "truncate -Z f; printf 'status:%s\\n' \"$?\"", {"commands": ["truncate", "printf"]}),
    ])
