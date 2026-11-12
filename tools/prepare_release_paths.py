"""Map the generated Flutter plugin registry to a neutral package URI.

Run after flutter pub get and before flutter build --no-pub. Only generated
.dart_tool/package_config.json is changed; application source is untouched.
"""
import json
from pathlib import Path


def prepare(root=None):
    root = Path(root or Path(__file__).resolve().parents[1]).resolve()
    path = root / ".dart_tool/package_config.json"
    config = json.loads(path.read_text(encoding="utf-8"))
    package = {
        "name": "zerochat_generated",
        "rootUri": (root / ".dart_tool/flutter_build").as_uri() + "/",
        "packageUri": "",
        "languageVersion": "3.10",
    }
    config["packages"] = [entry for entry in config["packages"] if entry["name"] != package["name"]]
    config["packages"].append(package)
    path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    print("Generated plugin registry uses a neutral package URI for release.")


if __name__ == "__main__":
    prepare()
