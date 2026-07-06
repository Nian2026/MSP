# Files Feature

This feature owns the workspace and photo-library browser content.

It renders virtual MSP workspace paths such as `/`, `/notes.md`, and
`/docs/file.txt`, plus PhotoSorter virtual media paths such as `/图库` and
`/相册`. These paths are app-owned workspace references, not host filesystem
paths or raw Photos framework identifiers.

It does not own the left-side drag interaction; that belongs to
`Features/WorkspaceDrawer`.
