# FastVLM Model Bundle

Place the official FastVLM iOS/Apple Silicon model files in ignored
`Resources/FastVLM/model/`.
The default open-source build does not bundle these files.

The first supported bundle is `FastVLM-0.5B stage3`, matching Apple's app export layout. The app treats the model as installed only when these official bundle pieces are present:

- `model/config.json`
- `model/preprocessor_config.json`
- `model/processor_config.json`
- `model/tokenizer_config.json`
- at least one `model/*.safetensors`
- exactly one `model/*.mlpackage`, usually `fastvithd.mlpackage`

Keep the files produced by the official FastVLM app/download flow together in
this directory. Do not replace FastVLM's image preprocessing with app-specific
resize, crop, screenshot, document, or long-image rules.

Live local inference also needs the copied FastVLM Swift source under ignored
`Local/FastVLM/` and a SwiftPM build with `PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1`.
