from pathlib import Path
import argparse
import hashlib
import json
import zipfile


SNAPSHOT_SHA256 = "f56b42e7e753143b1da4f64e12baf67724d48cef055eb46f9d49eddb4665f5b3"
RULESET_IDS = ("ublock-filters", "easylist", "easyprivacy", "adguard-mobile", "jpn-1")


def update_snapshot(staging: Path, snapshot: Path) -> None:
    if hashlib.sha256(snapshot.read_bytes()).hexdigest() != SNAPSHOT_SHA256:
        raise ValueError("network snapshot SHA-256 mismatch")

    details_path = staging / "rulesets/ruleset-details.json"
    details = json.loads(details_path.read_bytes())
    replacements = {}
    with zipfile.ZipFile(snapshot) as archive:
        for ruleset_id in RULESET_IDS:
            path = f"rulesets/main/{ruleset_id}.json"
            data = archive.read(path)
            rules = json.loads(data)
            for rule in rules:
                resource = rule["action"].get("redirect", {}).get("extensionPath")
                if resource and not (staging / resource.lstrip("/")).is_file():
                    raise ValueError(f"missing redirect resource: {resource}")
            entry = next(item for item in details if item["id"] == ruleset_id)
            entry["rules"]["plain"] = len(rules)
            entry["rules"]["total"] = len(rules) + entry["rules"]["regex"]
            replacements[path] = data

    for path, data in replacements.items():
        (staging / path).write_bytes(data)
    details_path.write_text(json.dumps(details, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("staging", type=Path)
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    update_snapshot(args.staging, args.snapshot)
