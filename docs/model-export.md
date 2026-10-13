# MerLens V2 ONNX export

The final embedding checkpoint was exported as one inference-only FP32 ONNX
graph using opset 18 and a dynamic batch dimension. The graph accepts
`[batch, 3, 224, 224]` float32 input named `input` and returns
`[batch, 128]` unit-normalized embeddings named `embedding`.

The verified export was 3,241,210 bytes. PyTorch/ONNX parity across 42,977
validation images recorded a maximum absolute difference of approximately
`0.0000015125`, minimum row cosine similarity of approximately `0.99999976`,
and zero decision mismatches across 1,345,784 pairs at the locked threshold.
Median desktop CPU batch-one inference was approximately 4.93 ms. Export parity
shows graph equivalence; it does not establish recognition accuracy or mobile
field performance.

The verified ONNX binary is included at
`mobile_app/assets/models/final_face_embedding_fp32_opset18.onnx`. Its SHA-256
is `1b87df5663c9cc9bc156bdf98377a6680d66fcc3ce2d6f6a40394f3f027d196f`.
The original verified export hash was
`ec6dc4b580d6db053725933b61b78363e4701a1ee5082cbf30c0cc0e0cc347c4`.
For public release, 735 copies of the private source root were replaced with an
equal-length non-path marker inside exporter stack-trace metadata. A byte-level
comparison confirms every other byte is identical, preserving tensor data and
protobuf layout. Training checkpoints remain private and excluded. The public
source retains the reproducible export path:

```text
ai/src/models/checkpoint_io.py   Strict MerLens curriculum-checkpoint loader
ai/src/export/export_onnx.py  Dynamic-batch FP32 opset-18 export
ai/src/export/final_export.py Graph checks and full validation parity
ai/configs/merlens_curriculum_final.yaml  Recorded final hashes and metrics
```

With an authorized local checkpoint, aligned validation set, manifest, and
YuNet artifact, inspect the command contract with:

```powershell
python -m ai.src.export.final_export --help
```

Do not use validation or LFW data to retune the already recorded result, and do
not commit generated checkpoints, ONNX files, embeddings, reports, or images.
The single final ONNX file above is the deliberate exception. Its use is
limited to non-commercial research under the model/data boundary in
`docs/model-card.md`.
