# ModelShellProxy Integration Tests

These tests exercise the public `ModelShellProxy` facade and the composed shell
runtime. They are intentionally separate from module unit tests because they
verify how parser, workspace filesystem, command registry, streams, and agent
contracts behave together.

Directory map:

- `AgentContract`: model-visible API contracts, especially `exec_command`
  plain-text compatibility.
- `StandardFixtures`: MSP fixture suites that assert the required command list
  and profile-level parity cases.
- `ShellLanguage`: expansion, script execution, shell state, and shell built-in
  composition through the facade.
- `Pipelines`: pipeline semantics, streaming, early close, and command
  composition.
- `Redirection`: file descriptor and redirection behavior across commands.
- `WorkspaceFS`: workspace root mapping, path normalization, and filesystem
  parity behavior.
- `Conformance`: Debian/VPS oracle runners and public fixture safety checks.
- `Support`: test-only helpers shared by this integration target.

Keep tests here only when they need the public facade or multiple modules. A
single command implementation test should live under `Tests/Swift/Unit`.
