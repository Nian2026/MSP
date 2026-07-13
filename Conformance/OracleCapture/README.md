# MSP Oracle Capture

This directory contains the oracle-first capture and validation surface for the
MSP Core100 Linux command layer, covering 100 commands.

Read in this order:

1. `DebianOracleCaptureSafetyPolicy.md`
2. `../../Docs/Standards/Core100CommandExpansionMatrix.md`
3. `Core100DebianCapturePlan.md`
4. `Core100ShellStressCases.md`

No runner should execute cases on a VPS until it enforces the safety policy and
can reject unsafe structured cases before shell execution.

The intended flow is:

1. define command and option scope;
2. define structured capture cases;
3. validate cases locally for safety;
4. run cases only inside a fresh `/tmp/msp-oracle-capture-*` case root;
5. import private raw captures into sanitized public oracle fixtures;
6. implement MSP behavior against normalized byte-level oracle outputs.

Current runner:

```sh
python3 Conformance/Scripts/core100_oracle_capture.py generate-cases
python3 Conformance/Scripts/core100_oracle_capture.py validate
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit
python3 Conformance/Scripts/core100_oracle_capture.py run-vps
```

`run-vps` must be run only after `safety-self-test` and `safety-audit` pass.
If any remote case hits a runner limit, raw artifacts are retained under
`.codex-tmp/`, but the public oracle fixture is not promoted.

`run-vps` must fail closed when SSH refuses the configured host key. Do not
disable strict host-key checking or remove known-host entries inside the runner.
For a verified host key, prefer a project-local file:

```sh
python3 Conformance/Scripts/core100_oracle_capture.py run-vps \
  --known-hosts .codex-tmp/core100-oracle-capture/known_hosts
```

If `.codex-tmp/core100-oracle-capture/known_hosts` exists, the runner uses it
by default. SSH authorization is still separate: the VPS must accept the
configured user/key before any oracle case can run. Use `--identity-file` or
`MSP_VPS_IDENTITY_FILE` when the VPS expects a key other than the default SSH
identity.
