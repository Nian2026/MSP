# PhotoSorter Local Overrides

This directory is for machine-local development inputs that should not be part
of the default open-source release surface.

Use `Local/FastVLM/` for copied FastVLM Swift source when testing local live VLM
inference. That directory is intentionally ignored by git. Build the SwiftPM
package with `PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1` to include those sources and
the MLX package products.
