# Chat Feature

This feature owns the user-facing conversation surface.

The composer accepts natural-language messages. It must not expose a shell
command input, workspace button, or command palette. Tool execution belongs to
the local `Agent` layer and appears only as timeline events such as model
progress, tool calls, processed results, and final answers.
