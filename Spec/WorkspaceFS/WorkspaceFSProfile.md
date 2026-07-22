# WorkspaceFS Profile

WorkspaceFS is the Model Shell Proxy filesystem boundary for app sandboxes.
It is not a staging VFS. Commands run against the developer-provided workspace
directory directly, while every path first passes through MSP path resolution
and policy checks.

## Mount Contract

- A host directory is mounted as the agent-visible root path `/`.
- Agent-facing command text and command results use virtual paths only.
- Physical app sandbox paths are internal implementation details and should not
  be rendered to the agent by default.
- `..` traversal is clamped at virtual `/`; it must never create a physical path
  outside the mounted workspace.
- Implementations must reject symlink traversal that resolves outside the
  mounted workspace.

## Policy Contract

- Implementations may hide internal path components such as `.msp`.
- Hidden paths must be denied when addressed directly.
- Hidden entries should be omitted from directory listings.
- Errors returned to command layers must be expressed in virtual paths and must
  not leak host filesystem roots.

## Core Operations

The WorkspaceFS profile exposes filesystem behavior needed by POSIX-like
commands and app-specific commands:

- resolve a path from a current working directory
- stat a file, directory, symlink, or other item
- list a directory with stable ordering
- read and write file data
- read and write text through an explicit encoding
- create directories
- touch files
- recoverably remove files or directories
- copy files or directories
- move or rename files or directories

## Trash Contract

- Agent-facing remove operations must be recoverable by default.
- A remove operation makes the target disappear from the agent-visible workspace,
  but implementations should move the underlying item into hidden trash storage
  instead of physically deleting it.
- Hidden trash storage must remain an implementation detail unless the host app
  explicitly configures a virtual display root.
- A displayed trash root may preserve original parent hierarchy or flatten each
  removed item into a top-level entry. In flat mode, removed directories keep
  their own descendants, name collisions must receive deterministic unique
  display names, and the original path remains the restore destination source.
- Implementations must not expose hard-delete behavior through normal shell
  commands or ordinary WorkspaceFS remove configuration.
- Physical trash emptying must require host-app authorization that represents a
  user-confirmed destructive action.
- Restore and empty operations are host/app capabilities; they are not implied by
  POSIX-like command availability.

## Non-Goals

- WorkspaceFS does not copy files into a temporary mirror before execution.
- WorkspaceFS does not sync a staged directory back after execution.
- WorkspaceFS does not grant access outside the mounted workspace merely because
  the underlying platform can access it.
