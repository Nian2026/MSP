# Default Theme

The Default theme is the MSP-facing version of the Readex Codex-style
markstream theme.

Required tokens:

| Token area | Target |
| --- | --- |
| Assistant surface | Open markdown body, no bubble background. |
| User surface | Subtle gray bubble using platform-neutral CSS tokens. |
| Markdown profile | `markstream-readex-fade` behavior. |
| Text | 15.5px body size and medium-light 430 weight. |
| Motion | Codex text fade and tool shimmer, with reduced-motion support. |
| Tool activity | Muted status text, folded details, stable accents. |

Apple colors such as `NSColor.labelColor.opacity(0.055)` must be converted to
CSS variables before publishing.
