# Conformance Integration Tests

This folder is for tests that compare MSP against captured Linux oracle
fixtures. These tests are heavier than normal integration tests because they
load public oracle artifacts and may run many command cases.

Rules:

- Fixture loading and public-safety checks should run by default.
- Full byte-level oracle execution may be gated by an environment variable when
  it is expensive.
- Oracle expected output must come from `Conformance/ReferenceOutputs`, not
  from hand-written approximations in test code.
- Stress cases belong here when their expected behavior is captured from a real
  Linux environment.
