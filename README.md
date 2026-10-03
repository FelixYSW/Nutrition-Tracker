# Nutrition Tracker

A native iPhone app for tracking calories and macros. It sets daily targets as ranges, logs food by hand, from a photo, or from a barcode, and shows trends over time. Data stays on the phone. The one exception is the optional AI assistant, which needs the internet.

> Targets and photo-based nutrition are **estimates**, not medical advice.

## Contents

- [What it does](#what-it-does)
- [Architecture](#architecture)
- [Build and run](#build-and-run)
- [On-device models](#on-device-models)
- [Nutrition data](#nutrition-data)
- [AI assistant (Google Gemini)](#ai-assistant-google-gemini)
- [CI: unsigned IPA from GitHub Actions](#ci-unsigned-ipa-from-github-actions)
- [Installing with Sideloadly (and the 7-day limit)](#installing-with-sideloadly-and-the-7-day-limit)
- [Backup and your data](#backup-and-your-data)
- [Licences and attribution](#licences-and-attribution)
- [Verification status](#verification-status)

## What it does

- **Onboarding** asks for your body, goal and activity details in several short steps. It then works out daily **ranges** for calories, protein, carbs, fat and fibre. You can edit either end of any range before saving.
- **Dashboard** shows today only. Each nutrient has a ring with three states:
  - *under*: shown calmly, because that's normal for most of the day
  - *within*: shown as on track
  - *over*: flagged
  
  The ring shades the target band so you can see where "in range" is at a glance.
- **Add Meal** is a list of draft foods. Each can be a simple food or a composite food made of ingredients, with minus/plus quantity controls. You can backdate a meal.
- **Scan** has three actions: Take Photo, Choose Photo, Scan Barcode. Photos go through two on-device models. Barcodes are looked up in a local cache, then Open Food Facts.
- **Calendar** shows any day's food log. A **Trends** view charts daily, weekly and monthly calories and macros against your target band.
- **Assistant** (optional, from the Dashboard nav bar) suggests what to eat with the room you have left. It can also log, edit and delete food, or summarise your trends. **Every change it proposes waits for you to confirm it.**
- **Settings** (gear icon on the Dashboard) covers profile, ranges, backup and restore, and data deletion. Neither the AI assistant nor the photo models have settings.

The app has four tabs: Dashboard, Scan, Add Meal, Calendar. Settings and the assistant open as sheets from the Dashboard.

## Architecture

SwiftUI, SwiftData, async/await, iOS 17+, iPhone only. Folders are organised by feature.

```
NutritionTracker/
  App/          entry point, root view, cross-tab router
  Models/       value types (Nutrition, NutrientRange), SwiftData entities, drafts
  Persistence/  ModelContainer + versioned migration plan, fetch helpers
  Services/
    Nutrition/  NutritionTargetCalculator, NutritionRepository, FoodOntology
    AI/         Model A/B protocols, Core ML adapters, pipeline
    Assistant/  provider-agnostic service, context builder, tools, executor
    Barcode/    Open Food Facts client, cache-first lookup
    Backup/     versioned JSON export/import
    Keychain/   built-in assistant key reader, legacy key cleanup
    Images/     photo storage and preparation
  Features/     Onboarding, Dashboard, Scan, AddMeal, Calendar, Settings, Assistant
  Components/   rings, steppers, cards, shared views, theme
  Utilities/    local-day logic, midnight observer, trend aggregation
  Resources/    ontology.json, myfcd_reference.json (+ .mlpackage models when added)
NutritionTrackerTests/
ml/             training, evaluation, Core ML export (see ml/README.md)
docs/           ARCHITECTURE.md
```

Key decisions:

- **Every save path goes through a draft.** Manual entry, photo analysis, barcodes and the assistant all produce a `FoodEntryDraft` that you review. Nothing AI-generated is saved without you seeing it.
- **No stored daily totals.** Today's figures, the Calendar and Trends all filter `FoodEntry.consumedAt` when they're shown. At local midnight the day changes and the totals start from zero; nothing is deleted. The app listens for `NSCalendarDayChanged`, time zone changes and returning to the foreground.
- **Totals are calculated, not stored.** A composite food's nutrition comes from its ingredients, and the parent quantity scales all of them.
- **Targets are ranges.** All the calculation constants live in `NutritionConstants`. Recalculating keeps any range end you edited by hand.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build and run

Requires macOS, Xcode 16+ (current XcodeGen writes a project format Xcode 15 cannot open) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate                 # creates NutritionTracker.xcodeproj (gitignored)
open NutritionTracker.xcodeproj
```

Command-line build and tests:

```bash
xcodebuild test -project NutritionTracker.xcodeproj -scheme NutritionTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15'

xcodebuild build -project NutritionTracker.xcodeproj -scheme NutritionTracker \
  -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The bundle identifier is `com.felix.NutritionTracker`. Don't change it: Sideloadly installs each new build over the existing app, and that only works while the ID stays the same.

**SwiftData** stores its database in the app's normal container. Upgrades never delete or recreate it. Schema changes go through `AppMigrationPlan` in `Persistence/AppModelContainer.swift`: add a new `VersionedSchema` and a migration stage, never a reset.

## On-device models

The app **builds and runs without any model files**. Model status isn't shown anywhere. If the recognition model is missing, tapping Take Photo or Choose Photo says "Model not available"; if only the portion model is missing, photos still work but Add Meal says the amounts are rough defaults. Barcode scanning and manual entry always work.

| Model | Expected file in the app bundle | Produces |
|---|---|---|
| A: recognition | `IngredientSegmenter.mlmodelc` (from `IngredientSegmenter.mlpackage`) | foods and ingredients, confidence, area |
| B: portion and nutrition | `NutritionEstimator.mlmodelc` (from `NutritionEstimator.mlpackage`) | mass, calories, protein, carbs, fat |

To add them, drop the `.mlpackage` files into `NutritionTracker/Resources/` and run `xcodegen generate`. Training, evaluation and export are covered in **[ml/README.md](ml/README.md)**, including:

- preparing FoodSeg103 and Nutrition5k
- the Malaysian fine-tuning sets (Malaysia Food-11, MF-150, Roboflow Malaysian Food Recognition 1 and 2)

Quick version:

```bash
pip install -r ml/requirements.txt
python -m ml.ingredient_segmentation.train --stage base --manifests ml/data/manifests/foodseg103.jsonl
python -m ml.nutrition_estimation.train --inputs rgb
python -m ml.ingredient_segmentation.export --checkpoint ml/runs/model_a_base/best.pt
python -m ml.nutrition_estimation.export   --checkpoint ml/runs/model_b_rgb_mobilenet_v3_large/best.pt
```

**Set your expectations:**

- One handheld photo can't determine portion size precisely. The app labels every portion as an estimate and always lets you correct it.
- Recognition of Malaysian dishes starts weak, because the public datasets are small.
- Model B has only been trained on Nutrition5k, so nobody has measured how well it handles local food.

`.mlpackage` files are gitignored and never committed, because this repo is public. To get them into CI builds, set a **`MODELS_URL`** repository secret to a link to a zip holding the `.mlpackage` folders. The Colab notebook produces exactly this as `NutritionTrackerModels.zip`; a Google Drive "Anyone with the link" share link works. The workflow downloads the zip before generating the project. Without the secret, CI builds the app without models.

Note: on a public repo, any signed-in GitHub user can download Actions artifacts, and the IPA contains the models.

**How photo analysis works:**

1. Prepare the image once, at 640 px on the longest edge.
2. Model A identifies the foods and how much of the plate each covers.
3. Model B estimates the mass of each.
4. Nutrition comes from the reference table wherever a food matches. Model B's own nutrition estimate is used only as the last resort.
5. Swift adds everything up.
6. The result opens in Add Meal for you to review.

Any detection below 60% confidence is flagged.

## Nutrition data

The app looks up nutrition in this order, using the first match:

1. **Your own saved foods.** Barcode products you entered by hand count as verified.
2. **Open Food Facts**, for barcodes. Results are cached locally for 90 days, and an out-of-date cache entry is still used when you're offline.
3. **MyFCD**, the Malaysian Food Composition Database (Ministry of Health), for local dishes.
4. A **generic reference** table for other foods.
5. **Model B's estimate**, as the last resort.

MyFCD has no API, so its values are copied in by hand and bundled with the app. Nothing is scraped at runtime.

```bash
# 1. Fill in per-100 g values from myfcd.moh.gov.my in ml/config/myfcd_reference.csv
# 2. Compile into the app bundle:
python ml/scripts/compile_reference.py
```

> **Current state:** the 14 MyFCD rows are **blank placeholders** waiting for real values. The 19 generic rows are typical reference figures entered by hand; spot-check them. Until MyFCD is filled in, Malaysian dishes rely on manual entry or Model B.

## AI assistant (Google Gemini)

The assistant has **no user settings**. It uses one API key built into the app at build time, and talks to Google Gemini through Gemini's OpenAI-compatible endpoint.

### Turn it on

1. Go to [Google AI Studio](https://aistudio.google.com/apikey), sign in, and choose **Create API key**. Make a new key just for this app.
2. On GitHub, open the repo, then **Settings → Secrets and variables → Actions → Secrets → New repository secret**:
   - **Name:** `ASSISTANT_API_KEY`
   - **Secret:** paste the key
3. Push a commit, or start the workflow from the Actions tab. The **"Check assistant key is in the app"** step should say *"Assistant key is built into the app."*
4. Sideload the new IPA. The ✨ icon on the Dashboard opens the assistant.

Without the secret, the app still builds, and the assistant says it isn't available.

### Optional: change model or provider (no code changes)

Add these under **Settings → Secrets and variables → Actions → Variables**. They're variables, not secrets.

| Variable | Default | Example |
|---|---|---|
| `ASSISTANT_MODEL` | `gemini-2.5-flash` | a newer Gemini model name from AI Studio |
| `ASSISTANT_BASE_URL` | `https://generativelanguage.googleapis.com/v1beta/openai` | any OpenAI-compatible API, e.g. `https://api.deepseek.com` |

Google retires model names over time. If the model returns HTTP 404, the app looks up the current list of models, switches to the newest stable Gemini Flash model, and remembers it on that phone. If you set `ASSISTANT_MODEL`, that model is always used and never auto-switched.

### How it gets into the app

`Config/AppConfig-Info.plist` maps the `ASSISTANT_*` build settings into the app's Info.plist. They're empty in `project.yml`, and CI fills them from the secret and variables through a temporary xcconfig file outside the repo, never via the command line. Xcode's `INFOPLIST_KEY_*` settings only cover keys Apple recognises, which is why the extra plist file is needed.

### Risks to be aware of

- **The key isn't secret once it's in the app.** Anyone with the IPA can read it by unzipping the file. On a public repo, **any signed-in GitHub user can download Actions artifacts**. A free-tier Gemini key limits the damage: someone who takes it hits rate limits, not a bill. **Don't turn on billing for this key.**
- **On the free tier, Google may use what you send to improve its products.** That includes your profile basics, today's targets and food log, and a 14-day trend summary. A short note in the assistant sheet says this. The assistant never sends photos (apart from a menu photo you attach yourself), your date of birth, your body-fat percentage or your target weight.
- **Free tiers are rate-limited.** When the limit is hit, the assistant says the provider is rate limiting and to try again shortly.

The only real fix for the key exposure is a small proxy server that holds the key, so the app never contains it.

The two photo models have **no remote fallback**. If a model isn't available, the app says so when you try to use a photo feature.

## CI: unsigned IPA from GitHub Actions

Workflow: [`.github/workflows/build-ios.yml`](.github/workflows/build-ios.yml). It runs on every push to `main`, and you can also start it from the Actions tab (Run workflow).

What it does:

1. Installs XcodeGen and generates the Xcode project.
2. Runs the unit tests on whichever iPhone simulator the runner has (Xcode 16, `macos-15`).
3. Builds Release for `iphoneos` with signing turned off.
4. Packages the build as `Payload/NutritionTracker.app` and zips it into `NutritionTracker-unsigned.ipa`.
5. Uploads the IPA as an artifact.

It fails with a clear message if no `.app` is produced.

To download the IPA: Actions → the latest run → **Artifacts** → `NutritionTracker-unsigned-ipa`. The artifact is a zip that contains the `.ipa`.

The IPA is deliberately unsigned; Sideloadly signs it.

## Installing with Sideloadly (and the 7-day limit)

1. Download and unzip the artifact to get `NutritionTracker-unsigned.ipa`.
2. Connect your iPhone and open Sideloadly.
3. Drag the IPA in, enter your Apple ID (a free Personal Team is fine), and start.
4. On the iPhone, trust the developer profile: Settings → General → VPN & Device Management.
5. For updates, repeat with the **same Apple ID**. The bundle ID never changes, so each build installs over the old one and keeps your data.

> **Free Apple accounts: apps stop opening 7 days after signing.** This is Apple's limit, not Sideloadly's. Once it passes, the app won't launch until you re-sign it. **Re-sideload about once a week**: set a recurring reminder, and if you want a fresh build, run the workflow first. Re-signing over the existing install keeps your data.

## Backup and your data

- **Uninstalling the app deletes its database.** Export a backup regularly.
- **To export:** Settings → Data → Export backup produces a versioned JSON file (`schemaVersion` 1) and opens the share sheet. The file contains your profile, target ranges, food entries with their ingredients, and the barcode cache. Photos and API keys are not included.
- **To import:** Settings → Data → Import backup. The file is fully checked before anything changes. A backup from a newer app version is rejected with a clear message. You then choose **Replace all data** or **Merge** (merge skips entries that are already on the phone).
- **Photo retention:** "Keep analysed photos" controls whether photos are saved after analysis. Saved photos live in Application Support, are excluded from iCloud backup, and are referenced by relative path.
- **Corrections:** "Keep my corrections for future training" stores what the models predicted next to what you confirmed. It stays on the device.

## Licences and attribution

The app credits its data sources in Settings → About → Data sources:

- MyFCD
- Open Food Facts (ODbL)
- FoodSeg103
- Nutrition5k
- Malaysia Food-11
- MF-150
- Malaysian Food Recognition 1 and 2 (Roboflow, CC BY 4.0)

Check every licence before distributing a trained model or the bundled values. See [ml/README.md](ml/README.md#licences).

## Verification status

This repository was written on Windows, **without macOS, Xcode, a GPU or a Python runtime**. As a result:

- The Swift code has **not been compiled**, and the XCTest suite has **not been run**. The first GitHub Actions run (or `xcodebuild` on a Mac) is the first real compile. Expect to fix some compiler errors.
- The Python training code has **not been run**, not even syntax-checked. Neither model has been trained, and no `.mlpackage` exists yet.
- `NutritionTracker/Resources/myfcd_reference.json` and `ontology.json` **were** generated by running a Node port of `compile_reference.py`.
