# Workspace Drawer

This feature owns the full-screen workspace surface and its drag interaction.

Gesture contract:

- Drag right from the left edge to reveal the workspace from the left.
- Drag left to hide it.
- The conversation remains the primary surface.
- The workspace presents the MSP workspace root `/`.
- Host sandbox paths must not be shown by default.

This feature should compose `Features/Files` for the actual file tree content.
It should not own WorkspaceFS itself; filesystem setup belongs in `Workspace/`.
