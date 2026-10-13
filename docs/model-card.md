# MerLens V2 model card

## Summary

MerLens V2 is AGILA's project-authored facial-embedding CNN. It accepts an
aligned `[batch, 3, 224, 224]` float32 tensor and returns a
`[batch, 128]` L2-normalized embedding for cosine comparison.

| Field | Value |
| --- | --- |
| Artifact | `mobile_app/assets/models/final_face_embedding_fp32_opset18.onnx` |
| Format | FP32 ONNX, opset 18, dynamic batch |
| Size | 3,241,210 bytes |
| Public SHA-256 | `1b87df5663c9cc9bc156bdf98377a6680d66fcc3ce2d6f6a40394f3f027d196f` |
| Original export SHA-256 | `ec6dc4b580d6db053725933b61b78363e4701a1ee5082cbf30c0cc0e0cc347c4` |
| Historical internal-validation threshold | `0.2071264386177063` |
| Training/internal validation data | DigiFace-1M synthetic faces |
| External evaluation | LFW View 2 fixed pairs, one run without recalibration |

## Intended use and restriction

The model is provided for non-commercial research, academic review, and
reproduction of the AGILA thesis prototype. DigiFace-1M is provided under
Microsoft's Research Use of Data Agreement (R-UDA) v1.0. That agreement defines
trained AI models as Results and prohibits using the Data or Results in any
commercial offering, including a product or service.

Review the official sources before use:

- [DigiFace-1M repository](https://github.com/microsoft/DigiFace1M)
- [DigiFace-1M R-UDA v1.0](https://github.com/microsoft/DigiFace1M/blob/main/LICENSE)
- Bae et al., *DigiFace-1M: 1 Million Digital Face Images for Face Recognition*, WACV 2023

No DigiFace-1M image, archive, face crop, manifest, or embedding is included in
this repository.

The public ONNX copy redacts only private source-root strings from exporter
stack-trace metadata using equal-length byte replacements. Every other byte is
identical to the verified export; no tensor data or protobuf layout changed.

The current application separately uses provisional threshold `0.35`, pose-only
liveness, and three individual comparisons plus an aggregate comparison. The
historical locked-threshold metrics below do not establish accuracy at `0.35`.

## Performance boundary

The final internal synthetic validation record reported 98.42% accuracy and
1.58% EER. At the already locked threshold, the one-time LFW evaluation
reported 73.10% accuracy, 35.20% false acceptance, 18.60% false rejection, and
26.90% balanced error. These mixed results show a material synthetic-to-real
generalization limitation.

The model is not certified for identity, access control, surveillance, law
enforcement, safety-critical decisions, or production biometric security. It
may produce false accepts and false rejects and has not been comprehensively
validated across local demographics, devices, lighting, pose, occlusion, or
presentation attacks.

## Privacy and responsible use

Do not use the model to process facial data without an appropriate lawful basis,
consent/governance where required, security controls, retention limits, and an
independent privacy and bias review. Intended AGILA participants were not used
to train this model.
