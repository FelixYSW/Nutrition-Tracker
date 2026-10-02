# ML pipelines

Training, evaluation and Core ML export for the app's two on-device models,
plus the nutrition reference table.

| | Model A: recognition | Model B: portion and nutrition |
|---|---|---|
| Folder | `ingredient_segmentation/` | `nutrition_estimation/` |
| Architecture | DeepLabV3 + MobileNetV3-Large, plus a multi-label presence head | MobileNetV3-Large or EfficientNet-B0, multi-task regression |
| Base data | FoodSeg103 (pixel masks) | Nutrition5k (overhead RGB, dish totals) |
| Malaysian data | Roboflow MFR 1 and 2 (boxes), Malaysia Food-11 and MF-150 (image labels) | none exists at this scale |
| App file | `IngredientSegmenter.mlpackage` | `NutritionEstimator.mlpackage` |
| Core ML outputs | `class_confidence`, `class_area` (one value per class) and a `labels` metadata entry | `mass`, `calories`, `protein`, `carbs`, `fat` |

## Accuracy: what to expect

- **Local dishes start out poorly recognised.** The public Malaysian datasets are small: low thousands of images and a few dozen classes. They extend FoodSeg103 rather than replace it.
- **Model B has not been checked on Malaysian food.** It is trained only on Nutrition5k, which was photographed from a fixed overhead rig that also captured depth. A handheld phone photo is a different domain, and a single RGB image can't pin down mass precisely. Treat its output as a first guess that the user corrects.
- **Your own corrections are how this improves.** With "Keep my corrections for future training" turned on, the app stores each prediction alongside what you actually confirmed. These records stay on the device. Turning them into training data requires an export action, which isn't built yet.

## Setup

GPU recommended. Training on CPU works but is slow.

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r ml/requirements.txt
```

Run every command from the **repository root**. The scripts are modules (`python -m ml....`).

## 1. Get the datasets

Everything goes under `ml/data/raw/` (gitignored). Never commit datasets or checkpoints.

```bash
bash ml/scripts/fetch_datasets.sh manual          # FoodSeg103 + MF-150 instructions
bash ml/scripts/fetch_datasets.sh nutrition5k     # needs gsutil
FOOD11_SLUG=<owner/dataset> bash ml/scripts/fetch_datasets.sh food11
ROBOFLOW_API_KEY=<key> MFR1_PROJECT=<ws/proj/ver> MFR2_PROJECT=<ws/proj/ver> \
    bash ml/scripts/fetch_datasets.sh roboflow
```

## 2. Build manifests

The prepare scripts write JSONL or CSV manifests to `ml/data/manifests/`. They map every raw label through `ml/config/ontology.json`. A label with no alias match stays a separate class named `raw.<dataset>.<label>` rather than being merged into something that only sounds similar. Each script prints the labels it couldn't map; add aliases for them to the ontology and run it again.

```bash
python -m ml.scripts.prepare_foodseg103 --root ml/data/raw/FoodSeg103
python -m ml.scripts.prepare_malaysian roboflow --root ml/data/raw/mfr1 --name roboflow_mfr
python -m ml.scripts.prepare_malaysian roboflow --root ml/data/raw/mfr2 --name roboflow_mfr2
python -m ml.scripts.prepare_malaysian food11  --root ml/data/raw/malaysia-food-11
python -m ml.scripts.prepare_malaysian mf150   --root ml/data/raw/MF150 --csv <labels file> \
    --image-col <col> --labels-col <col> --sep <sep>
python -m ml.scripts.prepare_nutrition5k --root ml/data/raw/nutrition5k_dataset
```

I couldn't confirm MF-150's file layout, so its loader takes column names as arguments. Check its files before running it.

## 3. Train and evaluate Model A

```bash
# Stage 1: FoodSeg103 base
python -m ml.ingredient_segmentation.train --stage base \
    --manifests ml/data/manifests/foodseg103.jsonl

# Stage 2: Malaysian fine-tune. New classes are appended to the label space,
# and existing class weights are kept.
python -m ml.ingredient_segmentation.train --stage malaysian \
    --init ml/runs/model_a_base/best.pt \
    --manifests ml/data/manifests/foodseg103.jsonl \
                ml/data/manifests/roboflow_mfr.jsonl \
                ml/data/manifests/roboflow_mfr2.jsonl \
                ml/data/manifests/malaysia_food11.jsonl \
                ml/data/manifests/mf150.jsonl \
    --source-weight foodseg103=0.3

python -m ml.ingredient_segmentation.evaluate \
    --checkpoint ml/runs/model_a_malaysian/best.pt \
    --manifests ml/data/manifests/foodseg103.jsonl ml/data/manifests/roboflow_mfr.jsonl \
    --split val
```

How the different label types are used:

- **FoodSeg103 masks** train both heads at full weight.
- **Roboflow boxes** are filled in as coarse masks and count at half weight.
- **Image-level labels** (Food-11, MF-150) train only the presence head.

The evaluation script reports:

- mIoU and per-class IoU, from samples with real masks only.
- Per-class precision, recall and AP, plus macro mAP, from the presence head.
- A separate mAP for Malaysian classes (IDs starting `my.`).

COCO "mask mAP" applies to instance segmentation. This model does semantic segmentation, so IoU and presence AP are the honest equivalents.

## 4. Train and evaluate Model B

```bash
python -m ml.nutrition_estimation.train --inputs rgb

# Optional comparisons (spec section 20). These variants can't ship in V1:
python -m ml.nutrition_estimation.pseudo_masks --checkpoint ml/runs/model_a_base/best.pt --out ml/data/n5k_masks
python -m ml.nutrition_estimation.train --inputs rgb,seg --seg-dir ml/data/n5k_masks
python -m ml.nutrition_estimation.train --inputs rgb,depth
python -m ml.nutrition_estimation.train --inputs rgb,seg,depth --seg-dir ml/data/n5k_masks

python -m ml.nutrition_estimation.evaluate --checkpoint ml/runs/model_b_rgb_mobilenet_v3_large/best.pt --split test
```

The evaluation reports MAE for mass, calories, protein, carbs and fat, both in real units and as a percentage of the mean. Monocular depth (spec section 21) needs no code changes: generate depth PNGs with any monocular depth model, name each `<dish_id>.png`, and pass `--depth-dir`.

## 5. Export to Core ML and install in the app

```bash
python -m ml.ingredient_segmentation.export --checkpoint ml/runs/model_a_malaysian/best.pt
python -m ml.nutrition_estimation.export   --checkpoint ml/runs/model_b_rgb_mobilenet_v3_large/best.pt

cp -R ml/exports/IngredientSegmenter.mlpackage NutritionTracker/Resources/
cp -R ml/exports/NutritionEstimator.mlpackage  NutritionTracker/Resources/
xcodegen generate
```

Xcode compiles each `.mlpackage` to an `.mlmodelc` with the same base name. The app looks for exactly `IngredientSegmenter.mlmodelc` and `NutritionEstimator.mlmodelc` in its bundle. If either is missing, the app still builds and runs: it shows "local model unavailable" and offers manual entry or the remote fallback.

`*.mlpackage` is gitignored, so models never go into Git. A CI build therefore ships without them unless you change that. See the root README.

## Nutrition reference table (MyFCD)

MyFCD has no bulk download or API, so its values are copied in by hand:

1. Look up each dish in `ml/config/myfcd_reference.csv` on [myfcd.moh.gov.my](https://myfcd.moh.gov.my).
2. Fill in the per-100 g values and the MyFCD food code.
3. Compile:

```bash
python ml/scripts/compile_reference.py
```

The compile step merges the MyFCD rows with `generic_reference.csv`; MyFCD wins where both have the same ID. It checks every ID against the ontology and writes `NutritionTracker/Resources/myfcd_reference.json` and `ontology.json`. Rows with blank values are skipped and listed in the output.

**Current state:** all 14 MyFCD rows are blank placeholders. The 19 generic rows are typical reference figures that were entered by hand and should be spot-checked. Until the MyFCD rows are filled in, Malaysian dishes fall through to Model B's estimate or to manual entry.

## Licences

Check every licence before distributing a model trained on these datasets.

| Source | Use here | Notes |
|---|---|---|
| FoodSeg103 | Model A base | Research-use terms; check them before any distribution |
| Nutrition5k (Google) | Model B | See the dataset's licence on its GitHub/GCS page |
| Malaysia Food-11 (Kaggle) | Model A fine-tune | Licence varies by uploader; check the dataset page |
| MF-150 (IEEE DataPort) | Model A fine-tune | IEEE DataPort terms |
| Malaysian Food Recognition 1 and 2 (Roboflow) | Model A fine-tune | CC BY 4.0: attribution required |
| MyFCD (Ministry of Health Malaysia) | Reference table | Check terms before redistributing values |
| torchvision models and weights | Both | BSD-3-Clause |
| Ultralytics YOLO (not used) | — | AGPL-3.0; check carefully if you swap it in |
