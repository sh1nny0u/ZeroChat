"""Build a source-only Windows backend ZIP; never copy live state or ACLs."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


SERVER_DIR = Path(__file__).resolve().parents[1]


def package(destination, source=SERVER_DIR):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    selected = [source / name for name in (
        "main.py", "start.bat", "requirements.txt", ".gitignore",
        "tools/check_environment.py", "tools/data_protection.py",
        "tools/reset_admin.py", "tools/memory_model.py",
    )]
    for directory in ("routers", "services"):
        selected.extend(sorted(p for p in (source / directory).rglob("*.py") if "__pycache__" not in p.parts))
    if not all(path.is_file() for path in selected):
        raise ValueError("后端源文件不完整，未生成发布包")
    if any(path.is_symlink() or not path.resolve().is_relative_to(source) for path in selected):
        raise ValueError("发布源文件含链接或路径越界，未生成发布包")
    contents = {path.relative_to(source).as_posix(): path.read_bytes() for path in selected}
    # Public packages retain both the current license and upstream permissions.
    for name in ("LICENSE", "NOTICE", "licenses/MIT-original.txt"):
        candidates = (source / name, source.parent / name)
        license_file = next((p for p in candidates if p.is_file()), None)
        if license_file is None or license_file.is_symlink():
            raise ValueError("缺少必要许可证或版权声明，未生成发布包")
        contents[name] = license_file.read_bytes()
    manifest = {
        "format": "zerochat-windows-source", "version": 1,
        "target": "Windows x64 / Python 3.11 x64",
        "includes_runtime_data": False,
        "files": {name: hashlib.sha256(content).hexdigest() for name, content in contents.items()},
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in contents.items():
            # Bytes only: no owner, Windows ACL, venv, accounts or runtime directories.
            archive.writestr("zerochat-server/" + name, content)
        archive.writestr("zerochat-server/package-manifest.json", json.dumps(manifest, indent=2))
    with zipfile.ZipFile(destination) as archive:
        for name, expected in manifest["files"].items():
            if hashlib.sha256(archive.read("zerochat-server/" + name)).hexdigest() != expected:
                raise ValueError("发布包校验失败")
    return {"path": str(destination), "files": len(contents),
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(package(arguments.destination), ensure_ascii=False, indent=2))
