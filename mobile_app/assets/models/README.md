# Runtime model assets

`final_face_embedding_fp32_opset18.onnx` is the final MerLens V2 inference
model. Its SHA-256 is
`1b87df5663c9cc9bc156bdf98377a6680d66fcc3ce2d6f6a40394f3f027d196f`.
This public copy differs from the recorded export only by equal-length
redaction of private source-root strings in ONNX stack-trace metadata; graph
weights and protobuf layout were not changed.

The model is published for non-commercial research use subject to the
DigiFace-1M R-UDA boundary described in `docs/model-card.md`. YuNet and
MediaPipe Face Landmarker binaries are not included and must be obtained from
their official sources with applicable notices preserved.
