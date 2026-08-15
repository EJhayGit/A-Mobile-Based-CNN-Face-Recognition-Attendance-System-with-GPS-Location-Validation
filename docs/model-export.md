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

The checkpoint and ONNX binary are intentionally omitted. The training data
agreement and model-artifact redistribution boundary require a separate rights
review before public distribution. The public source retains the reproducible
export path:

```text
ai/src/models/checkpoint.py   Strict MerLens curriculum-checkpoint loader
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
