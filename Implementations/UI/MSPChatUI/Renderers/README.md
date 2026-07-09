# Renderers

`Renderers/Default` is the built-in renderer that carries the Readex-mode visual
language. Its Readex-derived payload is private to that renderer.

New renderer contributions should create a sibling folder:

```text
Renderers/
  Default/
  MyRenderer/
    renderer.manifest.json
    runtime/
    themes/
    README.md
```

Every renderer must accept the MSP canonical timeline and runtime event model.
It may add a private adapter internally, but it must not require hosts or SDK
users to build renderer-specific payloads.
