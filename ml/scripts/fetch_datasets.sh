#!/usr/bin/env bash
# Download the training datasets into ml/data/raw/ (gitignored).
#
# Only datasets with a scriptable, terms-compatible download are fetched here.
# FoodSeg103 and MF-150 require accepting terms / logging in, so this script
# prints instructions for them instead of working around that.
#
# Check every dataset's licence before using a model trained on it in anything
# you distribute - see ml/README.md, "Licences".
#
# Usage:
#   bash ml/scripts/fetch_datasets.sh nutrition5k
#   FOOD11_SLUG=owner/dataset bash ml/scripts/fetch_datasets.sh food11   # needs ~/.kaggle/kaggle.json
#   ROBOFLOW_API_KEY=... bash ml/scripts/fetch_datasets.sh roboflow
#   bash ml/scripts/fetch_datasets.sh manual            # FoodSeg103 / MF-150 steps
set -euo pipefail

RAW="$(cd "$(dirname "$0")/.." && pwd)/data/raw"
mkdir -p "$RAW"

nutrition5k() {
  # Public Google Cloud bucket (~180 GB in full). Only the overhead imagery,
  # metadata and split files are needed for Model B.
  command -v gsutil >/dev/null || { echo "Install the Google Cloud SDK for gsutil."; exit 1; }
  local dest="$RAW/nutrition5k_dataset"
  mkdir -p "$dest/imagery"
  gsutil -m cp -r gs://nutrition5k_dataset/nutrition5k_dataset/metadata "$dest/"
  gsutil -m cp -r gs://nutrition5k_dataset/nutrition5k_dataset/dish_ids "$dest/"
  gsutil -m cp -r gs://nutrition5k_dataset/nutrition5k_dataset/imagery/realsense_overhead "$dest/imagery/"
}

food11() {
  command -v kaggle >/dev/null || { echo "pip install kaggle, then add ~/.kaggle/kaggle.json"; exit 1; }
  # owner/dataset slug from the Malaysia Food-11 Kaggle page URL. Not guessed here.
  : "${FOOD11_SLUG:?Set FOOD11_SLUG=owner/dataset from the Kaggle page URL}"
  kaggle datasets download -d "$FOOD11_SLUG" -p "$RAW/malaysia-food-11" --unzip
}

roboflow() {
  : "${ROBOFLOW_API_KEY:?Set ROBOFLOW_API_KEY (free Roboflow account)}"
  # Workspace/project/version for each set, as shown on Roboflow Universe.
  # Fill these in from the dataset pages; they are not guessed here.
  : "${MFR1_PROJECT:?Set MFR1_PROJECT=workspace/project/version for Malaysian Food Recognition}"
  : "${MFR2_PROJECT:?Set MFR2_PROJECT=workspace/project/version for Malaysian Food Recognition 2}"
  python - "$RAW" <<'PY'
import os, sys
from roboflow import Roboflow
raw = sys.argv[1]
rf = Roboflow(api_key=os.environ["ROBOFLOW_API_KEY"])
for env, folder in (("MFR1_PROJECT", "mfr1"), ("MFR2_PROJECT", "mfr2")):
    workspace, project, version = os.environ[env].split("/")
    rf.workspace(workspace).project(project).version(int(version)).download(
        "coco", location=os.path.join(raw, folder))
PY
}

manual() {
  cat <<EOF
FoodSeg103 (Model A base set)
  1. Follow the download link on https://xiongweiwu.github.io/foodseg103.html
     (the archive is password-protected; the password is given on that page
     after agreeing to its research-use terms).
  2. Extract so that $RAW/FoodSeg103/category_id.txt exists.
  3. python -m ml.scripts.prepare_foodseg103 --root $RAW/FoodSeg103

MF-150 (Multilabel Malaysian Foods Dataset for Ingredient Detection)
  1. Download from IEEE DataPort (free IEEE account required).
  2. Extract to $RAW/MF150 and locate its label table.
  3. python -m ml.scripts.prepare_malaysian mf150 --root $RAW/MF150 \\
         --csv <labels file> --image-col <column> --labels-col <column> --sep <separator>
EOF
}

case "${1:-}" in
  nutrition5k) nutrition5k ;;
  food11) food11 ;;
  roboflow) roboflow ;;
  manual) manual ;;
  *) echo "usage: $0 {nutrition5k|food11|roboflow|manual}"; exit 2 ;;
esac
