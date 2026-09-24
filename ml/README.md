# Training

Both scripts consume prepared JSONL manifests so dataset downloads and label mapping remain explicit. See the root README for commands. Input data and checkpoints stay under ignored `ml/data`, `ml/checkpoints`, and `ml/runs`.

Model A's current export emits semantic segmentation logits. Its iOS adapter reads those logits and produces class regions, but does not yet separate multiple instances of one class or preserve masks. Confidence currently uses region area as a weak heuristic and must be calibrated before release. Model B predicts dish-level values; its first version allocates mass equally among detected classes. These are training baselines, not validated meal estimates.
