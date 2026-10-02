"""Maps raw dataset labels onto canonical ontology IDs (spec section 22).

Every dataset names things differently. A raw label that matches an ontology
alias becomes that canonical ID; anything else becomes
``raw.<dataset>.<slug>`` so it stays a distinct class instead of being merged
into something that merely sounds similar. Promote a raw class by adding an
alias to ml/config/ontology.json and re-running the prepare script.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ONTOLOGY_PATH = ROOT / "ml" / "config" / "ontology.json"
BACKGROUND = "background"
_BACKGROUND_ALIASES = {"background", "_background_", "bg", "other", "unlabeled"}


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.strip().lower()).strip("_")


class LabelMapper:
    def __init__(self, path: Path = ONTOLOGY_PATH) -> None:
        data = json.loads(path.read_text(encoding="utf-8"))
        self.aliases: dict[str, str] = {}
        self.canonical_ids: set[str] = set()
        for entry in data["entries"]:
            cid = entry["canonicalID"]
            self.canonical_ids.add(cid)
            for alias in [cid, entry["displayName"], *entry.get("aliases", [])]:
                self.aliases[alias.strip().lower()] = cid
                self.aliases[slug(alias)] = cid
        self.unmapped: dict[str, set[str]] = {}

    def map(self, dataset: str, raw: str) -> str:
        key = raw.strip().lower()
        if key in _BACKGROUND_ALIASES:
            return BACKGROUND
        hit = self.aliases.get(key) or self.aliases.get(slug(raw))
        if hit:
            return hit
        self.unmapped.setdefault(dataset, set()).add(raw)
        return f"raw.{dataset}.{slug(raw)}"

    def report(self) -> str:
        if not self.unmapped:
            return "Every label mapped to a canonical ID."
        lines = ["Labels kept as raw classes (add aliases to ontology.json to map them):"]
        for dataset, labels in sorted(self.unmapped.items()):
            lines.append(f"  {dataset}: {len(labels)} -> " + ", ".join(sorted(labels)[:25])
                         + (" ..." if len(labels) > 25 else ""))
        return "\n".join(lines)
