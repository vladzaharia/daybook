# Third-party notices

Daybook links native open-source libraries. Package.resolved records the exact dependency versions and revisions; the application bundle includes license files from resolved packages under Contents/Resources/Licenses.

| Library | Purpose | License / source |
| --- | --- | --- |
| WhisperKit 0.18.0 | In-process Core ML speech recognition | MIT · https://github.com/argmaxinc/WhisperKit |
| FluidAudio 0.17.7 | In-process speaker diarization | Apache-2.0 · https://github.com/FluidInference/FluidAudio |
| MLX Swift / MLX Swift LM | In-process Metal language-model inference | MIT · https://github.com/ml-explore/mlx-swift and https://github.com/ml-explore/mlx-swift-lm |
| Swift Transformers | Local tokenizers and explicit model downloads | Apache-2.0 · https://github.com/huggingface/swift-transformers |
| Swift Jinja | Chat prompt formatting | Apache-2.0 · https://github.com/huggingface/swift-jinja |
| Swift Numerics, Collections, Argument Parser | Supporting Swift components | Apache-2.0 with Swift exception · https://github.com/apple |

Model weights are downloaded separately, not bundled in the app. Their licenses are separate from library licenses. Model repository/revision details are in the catalog and installed model manifests. Qwen 2.5 1.5B and 7B are Apache-2.0; the 3B variant uses the Qwen Research license. Consult the corresponding model card before redistribution or commercial use. Whisper model weights are MIT. The diarization model repository carries Apache-2.0 metadata; its upstream components have their own model cards. No right to redistribute an unreviewed model is implied by the application code.

Daybook is an independent application, unaffiliated with Anker, Soundcore, Granola, Apple, Argmax, FluidInference, or model publishers.
