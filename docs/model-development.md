# MerLens V2 model development

## Final model

AGILA uses **MerLens V2**, a project-authored lightweight convolutional neural
network for face embeddings. Older MobileNetV3/ImageNet planning code is not
part of this public release because it was not the final trained and evaluated
model.

MerLens V2 accepts an aligned 224 x 224 RGB face and returns a
128-dimensional, L2-normalized embedding. Its topology combines standard
convolutions, local 3 x 3 and wider 5 x 5 depthwise branches, residual paths,
channel gating, adaptive pooling, dropout, projection, batch normalization, and
output normalization. ArcFace was used only as the training head; its class
centers are not included in the deployed embedding model.

## Data and preprocessing

Training and internal validation used **DigiFace-1M**, an officially
distributed synthetic face dataset governed by Microsoft's Research Use of
Data Agreement for noncommercial research. No dataset archive, image, derived
face crop, manifest, or embedding is included here. Anyone reproducing the work
must obtain and govern the dataset independently under its current terms.

The final usable mappings contained 92,329 training identities and 5,158
identity-disjoint validation identities. YuNet detected one face and five
landmarks; a non-reflective similarity transform aligned the face to 224 x 224
before ImageNet-style channel normalization. Intended AGILA participants were
not used as model-training data.

Labeled Faces in the Wild (LFW) was used once for external evaluation with its
fixed View 2 pairs and the already locked internal threshold. LFW was not used
for training, checkpoint selection, or threshold calibration. No LFW files are
included.

## Collapse diagnosis and curriculum

Direct scaling to many active identities caused representation collapse: the
embedding space became dominated by very few directions and genuine/impostor
separation weakened. Small-set and classifier-width checks showed that the
model and ArcFace head could learn, while a 2,048-active-identity diagnostic
reproduced the collapse boundary.

The final lineage introduced deterministic nested identity stages:

1. 256 identities
2. 2,048 identities
3. 8,192 identities
4. 32,768 identities
5. 92,329 identities

Each stage retained the previous identities, model state, and existing ArcFace
centers while deterministically initializing centers for newly introduced
identities. Optimizer/scheduler transitions and random state were handled
explicitly. Advancement depended on a health gate covering finite gradients,
validation accuracy/EER, genuine-impostor separation, effective rank, first-PC
variance, and training behavior.

## Recorded results and limitations

The final Stage 5 epoch-12 internal record reported 98.42% validation accuracy,
1.58% EER, a locked cosine threshold of `0.2071264386`, effective rank 116.2992
of 128, and first-PC variance of 1.55%. These are internal synthetic-domain
results, not general real-world accuracy.

At that fixed threshold, the one-time LFW evaluation processed both images for
5,398 of 6,000 pairs and reported 73.10% accuracy, 35.20% false acceptance,
18.60% false rejection, and 26.90% balanced error. The weaker external result
shows a material synthetic-to-real generalization limitation; AGILA does not
claim universal biometric accuracy or production-grade spoof resistance.

An older internal held-out split overlapped the final training identities. It
was rejected before scoring and produced no held-out result.

## Relevant public source

```text
ai/configs/                    Final curriculum, preprocessing, and result record
ai/src/models/                 MerLens V2 and ArcFace training head
ai/src/datasets/               Dataset inventory/manifest/aligned-loader code
ai/src/preprocessing/          YuNet detection, alignment, and tensor conversion
ai/src/training/               Progressive curriculum and health-gated controller
ai/src/evaluation/             Verification metrics and fixed-threshold LFW code
ai/src/export/                 FP32 ONNX export and parity verification
ai/tests/                      Focused model-pipeline tests
```

The code is supplied for review and reproducibility. Running full training
requires separately obtained data, detector/model artifacts, suitable compute,
and careful governance; none of those private artifacts are bundled.
