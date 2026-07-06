# Debian Oracle Capture Safety Policy

This policy is mandatory for every MSP oracle capture run against a VPS,
container, or local Linux machine. Oracle capture exists to learn Linux
observable behavior, not to test destructive power on a real host.

## Non-Negotiable Rule

Every case must run inside a fresh, runner-owned temporary case root. The
runner may create and delete only paths under that root. It must never write to,
delete from, chmod, chown, mount, query, restart, or probe real system service
paths.

Allowed case root pattern:

```text
/tmp/msp-oracle-capture-<run-id>/<case-id>/case-root
```

The capture fixture may normalize that physical path to `<CASE_ROOT>` or to the
MSP virtual workspace root `/`, but the real VPS path must remain random and
isolated for safety.

## Forbidden Host Paths

No case may write, delete, chmod, chown, truncate, install into, or otherwise
mutate any of these paths, even for negative tests:

```text
/
/bin
/boot
/dev
/etc
/home
/lib
/lib64
/media
/mnt
/opt
/proc
/root
/run
/sbin
/srv
/sys
/tmp except the runner-owned /tmp/msp-oracle-capture-* subtree
/usr
/var
```

Read-only probes of `/bin/sh`, `/usr/bin/env`, and tool version commands are
allowed only in the runner prologue, not inside arbitrary command cases.

## Forbidden Command Patterns

The static validator must reject a case when the command text, setup script, or
cleanup script contains any of these patterns outside quoted fixture content:

```text
sudo
su
doas
systemctl
service
launchctl
mount
umount
mkfs
fdisk
parted
dd of=/dev/
dd if=/dev/
> /dev/
chmod -R /
chown
chgrp
rm -rf /
rm -fr /
rm -r /
find / -delete
find / -exec rm
curl | sh
wget | sh
ssh
scp
rsync
```

The validator must also reject absolute output paths unless they begin with the
current case root.

## Path Rules

1. Case commands should use relative paths.
2. Absolute paths are allowed only when produced by the runner from the current
   case root.
3. `..` is forbidden in command paths, fixture paths, setup paths, and expected
   side-effect paths.
4. Symlinks may point only within the case root.
5. The runner must refuse cleanup unless the target begins with
   `/tmp/msp-oracle-capture-` and contains the current run id.
6. The runner must refuse to follow symlinks during cleanup.
7. Physical host paths in stdout/stderr/file-tree records must be retained in
   private raw artifacts and normalized before public fixtures are written.

## Dangerous Command Equivalence

Some commands need negative-path coverage. Use safe equivalents inside the case
root instead of destructive host-level samples:

| Real danger to avoid | Safe oracle sample |
| --- | --- |
| `rm -rf /` | `rm -rf missing-subtree` or `rm -r protected-dir` inside case root |
| `rmdir /` | `rmdir nonempty-dir` inside case root |
| `chmod -R /` | `chmod invalid-mode file.txt` or `chmod -R 000 local-tree` inside case root |
| `dd of=/dev/sda` | `dd if=input.bin of=out.bin bs=4 count=2` inside case root |
| `truncate -s 10G /var/log/...` | `truncate -s 1K local.bin` inside case root |
| `install -o root -g root` | `install -m 755 src bin/tool` inside case root |
| `hostname new-name` | invalid/unsupported option sample; setting host name is forbidden |

Never capture the literal host-danger command to learn its diagnostic. If a
diagnostic requires a truly dangerous operand, mark the case deferred and write
the reason.

## Resource Limits

Every case must run with limits:

- wall clock timeout per command;
- total stdout and stderr byte cap for private raw artifacts;
- total file-tree byte cap;
- maximum file count;
- maximum created file size;
- maximum pipeline length;
- maximum command-line byte length selected per stress tier;
- maximum `sleep` duration;
- no network access unless a later network command pack explicitly owns that
  policy.

If a case hits a limit, the capture must record `limit_exceeded` and must not be
promoted to a conformance oracle until reviewed.

## Runner Required Checks

Before execution, the runner must:

1. parse the structured case file;
2. create a unique run root under `/tmp/msp-oracle-capture-*`;
3. create a unique case root under that run root;
4. materialize fixture files under the case root only;
5. run static deny-list validation;
6. run path-prefix validation;
7. run command-category validation;
8. record tool versions;
9. execute without elevated privileges;
10. execute with resource limits.

The local gate for this policy is:

```text
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit --cases Conformance/OracleCapture/Core100CaptureCases.generated.json
```

`run-vps` may be used only after both commands pass. If the remote runner hits
any stdout, stderr, file-tree, file-count, or file-size limit, the raw evidence
may be retained for debugging, but the normalized oracle fixture must not be
promoted.

After execution, the runner must:

1. capture stdout, stderr, exit code, elapsed time, signal, and limit state;
2. capture file-tree diff, modes, symlink targets, and selected content hashes;
3. normalize physical paths to `<CASE_ROOT>` and related placeholders;
4. retain private raw bytes separately from public fixtures;
5. cleanup only the runner-owned run root after prefix validation;
6. fail closed if cleanup validation is uncertain.

## Review Gates

A new oracle capture batch is accepted only when:

1. the safety validator reports zero violations;
2. every case declares its command class and covered commands;
3. no command mutates outside its case root;
4. no forbidden host path appears in public fixtures;
5. no dangerous literal command is present;
6. byte-level stdout/stderr and file-tree data are base64-safe;
7. normalized output clearly distinguishes stable Linux behavior from host
   implementation details.
