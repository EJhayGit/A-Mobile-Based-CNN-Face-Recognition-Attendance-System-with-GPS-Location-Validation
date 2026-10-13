# Runtime model assets

The retained MerLens V2 model is `final_face_embedding_fp32_opset18.onnx`.
SHA-256: `1b87df5663c9cc9bc156bdf98377a6680d66fcc3ce2d6f6a40394f3f027d196f`.
Its existing public metadata redaction is retained; tensor data is unchanged.
See the [model card](../../../docs/model-card.md) for research-use restrictions.

Obtain these separately from their official providers before mobile tests/builds:

| File | Official source | Recorded SHA-256 |
| --- | --- | --- |
| `face_detection_yunet_2023mar.onnx` | [OpenCV Zoo 4.10.0 YuNet](https://github.com/opencv/opencv_zoo/tree/4.10.0/models/face_detection_yunet) | `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| `face_landmarker.task` | [MediaPipe Face Landmarker](https://ai.google.dev/edge/mediapipe/solutions/vision/face_landmarker) | `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff` |

Preserve provider license/attribution notices and independently review current
terms. These detector/landmarker binaries remain excluded from Git. No facial
image, dataset, enrollment template, or training checkpoint is required in Git.
The current application does not require the former `yunet_validation.png`.
