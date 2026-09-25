# Nutrition Tracker

Native iOS 17+ nutrition log built with SwiftUI and SwiftData. It supports onboarding, editable targets, manual simple and composite foods, a daily dashboard, calendar history, camera/photo analysis review, packaged-food barcode lookup, local backup, and optional local AI model installation. Nutrition targets and image estimates are informational, not medical advice. The four tabs are Dashboard, Scan, Add Meal, and Calendar; Settings is behind the Dashboard gear.

## Interface and navigation

Every page uses an edge-to-edge background while its controls remain inside the iPhone's safe areas; content is centered and adapts to narrow screens, landscape, and larger text sizes. Editable text and numbers sit in outlined boxes with examples, labels, and units, making input areas clear. Dashboard, Scan, Add Meal, and Calendar are each one tab tap away, and a food name is ready for entry as soon as Add Meal opens. Camera, library, and barcode actions take one more tap. Food cards expose an actions menu and the native long-press menu for editing or deletion; dates, photos, pickers, and confirmation dialogs use familiar iOS patterns. Empty views explain what will appear, analysis shows progress, and failures use clear alerts or recovery actions. Photo and barcode results always lead to editable Add Meal review, and saving returns to Dashboard, so navigation stays predictable.

## Build on a Mac

Requires Xcode with the iOS 17+ SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The bundle ID is always `com.felix.NutritionTracker`.

```sh
brew install xcodegen
xcodegen generate
open NutritionTracker.xcodeproj
xcodebuild test -project NutritionTracker.xcodeproj -scheme NutritionTracker -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project NutritionTracker.xcodeproj -scheme NutritionTracker -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The generated project has a shared scheme. SwiftData stores profile, targets, food, ingredients, barcode cache and optional correction records in `Library/Application Support/default.store` inside the app container. The app creates that directory before opening the store. Backup JSON is only an interchange format, not the live database. The app does not erase its database on update; model changes should use a SwiftData migration plan before changing released schemas. Uninstalling removes local data, so export a backup first.

## Nutrition and images

`NutritionTargetCalculator` uses Mifflin-St Jeor BMR, one activity multiplier, goal adjustment, weight-based protein, a fat floor, remaining carbohydrate energy, and 14 g fibre per 1,000 kcal. Exercise session counts are profile context only. Targets never recalculate automatically after profile edits; Settings has an explicit action.

Photo analysis expects two compiled Core ML models in `NutritionTracker/Resources/`: `FoodRecognition.mlmodelc` and `FoodPortion.mlmodelc`. Without Model A, the app reports that local recognition is unavailable and the user can enter food manually. Without Model B, Model A detections remain editable with placeholder portions; the result must be reviewed before saving. The photo pipeline has no production remote provider yet. Entering an API key stores it in Keychain but does not activate remote analysis.

Model A's current training export is a semantic segmentation baseline. It reads class logits into regions, but cannot distinguish two instances of the same class or retain masks. Its displayed confidence is only a preliminary heuristic. Model B is an RGB dish-level regression baseline and currently divides mass equally among recognized classes. A single RGB phone image cannot determine mass precisely. Malaysian-dish recognition and portion accuracy are unverified; users should correct estimates. Only users who enable local correction retention store the original and final results. Images are retained in Application Support only when the toggle is on. No personal images are uploaded.

The bundled `food_reference.json` starts empty because MyFCD values must be manually verified with provenance. A canonical ID with a verified row takes priority over Model B's nutrition output. Open Food Facts is used for barcode lookups only, with a local cache. For a new MyFCD entry, add its canonical ID to `ml/config/ontology.json`, fill a row in `ml/config/myfcd_reference.csv` from [MyFCD](https://myfcd.moh.gov.my/myfcdcurrent/), including source URL and verification date, then compile:

```sh
python ml/scripts/compile_reference.py
```

All quantities and totals update locally. The current day is derived from `Calendar.autoupdatingCurrent`; day change, time zone change, foreground return and a periodic foreground refresh update the Dashboard. History records are never cleared at midnight.

## Model training

Use a machine with Python 3.10+, sufficient disk, and preferably a GPU. Install dependencies:

```sh
python -m venv .venv
source .venv/bin/activate
python -m pip install -r ml/requirements.txt
```

Download [FoodSeg103](https://xiongweiwu.github.io/foodseg103.html) and [Nutrition5k](https://github.com/google-research-datasets/Nutrition5k) using each project's instructions and terms. Dataset download is deliberately manual so users accept the respective licences. Place files under ignored `ml/data/`. FoodSeg103 or Roboflow COCO exports with true polygons can be converted to a training manifest after expanding the ontology with every mapped category:

```sh
python ml/scripts/prepare_coco.py --annotations ml/data/foodseg/annotations.json --images ml/data/foodseg/images --source foodseg103 --output ml/data/foodseg/prepared --expand-ontology
CLASSES=$(python -c 'import json; print(len(json.load(open("NutritionTracker/Resources/food_labels.json"))))')
python ml/ingredient_segmentation/train.py --manifest ml/data/foodseg/prepared/manifest.jsonl --classes "$CLASSES"
python ml/ingredient_segmentation/train.py --manifest ml/data/foodseg/prepared/manifest.jsonl --classes "$CLASSES" --resume ml/checkpoints/segmentation.pt --eval-only --eval-split test
python ml/ingredient_segmentation/export.py --checkpoint ml/checkpoints/segmentation.pt --output ml/runs/FoodRecognition.mlpackage
```

The importer adds unknown FoodSeg labels as distinct IDs, avoiding accidental synonym merges, and regenerates `food_labels.json`. Review the new IDs and map true synonyms manually before training. Compile the exported package in Xcode and add it to app resources. This script reports per-class precision, recall, mask IoU, and mean mask IoU; instance mask mAP is not yet implemented. Avoid claiming segmentation quality without evaluating an untouched test split.

Prepare a Nutrition5k JSONL manifest with the official dish ID splits. Inspect your download's RGB path and supply it as a template; the converter deliberately refuses to guess a file path:

```sh
python ml/scripts/prepare_nutrition5k.py --root ml/data/nutrition5k --train-ids ml/data/nutrition5k/dish_ids/splits/train.txt --test-ids ml/data/nutrition5k/dish_ids/splits/test.txt --image-template 'imagery/realsense_overhead/{dish_id}/rgb.png' --output ml/data/nutrition5k/manifest.jsonl
```

Replace the split filenames and image template with the actual paths in the downloaded release. The manifest contains `image`, `split`, `mass_g`, `calories`, `protein`, `carbs`, and `fat` fields. Splits are dish-disjoint. Then:

```sh
python ml/nutrition_estimation/train.py --manifest ml/data/nutrition5k/manifest.jsonl
python ml/nutrition_estimation/train.py --manifest ml/data/nutrition5k/manifest.jsonl --resume ml/checkpoints/portion.pt --eval-only --eval-split test
python ml/nutrition_estimation/export.py --checkpoint ml/checkpoints/portion.pt --output ml/runs/FoodPortion.mlpackage
```

Training prints validation MAE for mass, calories, protein, carbs and fat. An RGB-only run is the baseline. Depth and segmentation input variants need independent model architecture and evaluation before use. The current repository has no trained weights. The iOS app will not silently generate predictions without models.

Potential Malaysian expansion sources include Malaysia Food-11, MF-150, and the Roboflow Malaysian Food Recognition collections. They differ in annotation type. Classification and multilabel data do not provide segmentation masks, so they cannot be passed to the COCO mask importer as segmentation ground truth. Add verified aliases and any licensed polygon masks first, then fine-tune from the FoodSeg103 checkpoint with `--resume`. Local food recognition starts weak and should be measured against a held-out Malaysian photo set. Check each dataset's usage and redistribution terms, plus model code and weights licences, before distribution. Nutrition5k's fixed rig and depth data do not validate handheld phone estimates.

## Barcode, backup, secrets and sideloading

Barcode lookup uses the [Open Food Facts product API](https://openfoodfacts.github.io/documentation/docs/Product-Opener/api/). Missing fields are treated as unknown. Settings exports a version 2 JSON file with full date precision through the native document share flow; version 1 ISO 8601 backups remain importable. Import validates a backup before replacing current records; export first if you need the previous data. Image files are not embedded in JSON backup.

An optional API key can be entered or deleted in Settings and is stored in iOS Keychain. No default key or provider is compiled into the app. Do not commit secrets, provisioning files, data, weights, or personal photos. A build-time key inside an IPA is extractable, so the workflow does not inject one.

`.github/workflows/build-ios.yml` runs on pushes to `main` and manual dispatch. Open the workflow run in GitHub Actions and download the `NutritionTracker-unsigned` artifact. It contains `NutritionTracker-unsigned.ipa`, intended for Sideloadly signing and installation with the same Apple ID, Personal Team, and bundle ID. [Apple says Personal Team provisioning expires after 7 days](https://developer.apple.com/help/account/basics/about-your-developer-account): plan to rebuild or re-sign and reinstall roughly weekly. Export data before any uninstall, which removes the app container.

## Current verification and limits

The source was authored in a Windows environment without Xcode, Swift, Python, a GPU, or dataset downloads. No iOS build, simulator test, training run, Core ML conversion, or on-device scanner validation has been performed here. The commands above and the GitHub Actions workflow are the next verification gate. CI should be treated as the first compile/test signal, not as a proven passing build.
