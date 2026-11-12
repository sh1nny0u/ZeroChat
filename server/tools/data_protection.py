"""Create verifiable local snapshots and restore only into a new directory.

No operation deletes files or overwrites a live data directory. Stop all writers
before taking a snapshot; metadata checks detect changes, not application locks.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


SERVER = Path(__file__).resolve().parents[1]


def private_directory(path):
    path = Path(path).resolve()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name == "nt":
        identity = subprocess.check_output(
            ["whoami", "/user", "/fo", "csv", "/nh"], text=True
        )
        sid = re.search(r"S-1-[\d-]+", identity).group()
        try:
            subprocess.run(
                ["icacls", str(path), "/inheritance:r", "/grant:r",
                 f"*{sid}:(OI)(CI)F", "*S-1-5-18:(OI)(CI)F"],
                check=True, capture_output=True,
            )
        except subprocess.CalledProcessError as error:
            if error.returncode == 5:
                raise PermissionError("无法设置私有目录权限；请检查运行账号的目录权限") from None
            raise
    else:
        path.chmod(0o700)
    return path


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_child(root, relative):
    if not isinstance(relative, str) or "\\" in relative or ":" in relative:
        raise ValueError("Invalid relative path")
    parts = PurePosixPath(relative).parts
    reserved = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)),
                *(f"LPT{i}" for i in range(1, 10))}
    if (not parts or PurePosixPath(relative).as_posix() != relative or relative.startswith("/")
            or any(p in (".", "..") or p.endswith((" ", ".")) or "\0" in p
                   or p.split(".")[0].upper() in reserved for p in parts)):
        raise ValueError("Invalid relative path")
    root = Path(root).resolve()
    target = root.joinpath(*parts)
    if not target.resolve().is_relative_to(root):
        raise ValueError("Path escapes snapshot")
    if target.is_symlink() or (hasattr(target, "is_junction") and target.is_junction()):
        raise ValueError("Links are not accepted")
    return target


def new_directory(path):
    path = Path(path).absolute()
    if path.exists() or path.is_symlink():
        raise ValueError("Restore destination must not exist")
    path.mkdir(parents=True, exist_ok=False, mode=0o700)
    return private_directory(path)


def _inventory(server):
    files, directories, missing = {}, [], []
    protection = (server / "runtime" / "protection").resolve()
    for name in ("data", "config", "runtime"):
        root = server / name
        if not root.exists():
            missing.append(name)
            continue
        for path in [root, *sorted(root.rglob("*"))]:
            if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
                raise ValueError("Snapshot source contains a link")
            if path.resolve().is_relative_to(protection):
                continue
            relative = path.relative_to(server).as_posix()
            if path.is_dir():
                directories.append(relative)
            elif path.is_file():
                stat = path.stat()
                files[relative] = (stat.st_size, stat.st_mtime_ns)
    return files, directories, missing


def create_snapshot(server=SERVER, client_exports=()):
    server = Path(server).resolve()
    protection = private_directory(server / "runtime" / "protection")
    name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    destination = new_directory(protection / "backups" / name)
    before, directories, missing = _inventory(server)
    entries = []
    for relative in directories:
        (destination / "payload" / relative).mkdir(parents=True, exist_ok=True)
    sources = [(server / key, key) for key in before]
    for index, source in enumerate(client_exports):
        source = Path(source).resolve(strict=True)
        sources.append((source, f"client_exports/{index:03d}.json"))
    # Preserve pending source edits without touching the Git index.
    workspace = server.parent
    code_paths = [workspace / ".gitignore", workspace / "pubspec.lock", workspace / "AGENTS.md"]
    if (workspace / "docs").exists():
        code_paths.extend(p for p in (workspace / "docs").rglob("*") if p.is_file())
    for source in code_paths:
        if source.is_file():
            sources.append((source, "workspace/" + source.relative_to(workspace).as_posix()))
    for source, relative in sources:
        target = safe_child(destination / "payload", relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        source_hash = digest(source)
        with source.open("rb") as src, target.open("xb") as dst:
            shutil.copyfileobj(src, dst)
        if digest(target) != source_hash or digest(source) != source_hash:
            raise RuntimeError("Source changed during backup; snapshot is incomplete")
        entries.append({"path": relative, "size": target.stat().st_size, "sha256": source_hash})
    after, after_dirs, _ = _inventory(server)
    if before != after or directories != after_dirs:
        raise RuntimeError("Sources changed during backup; stop all writers and retry")
    manifest = {
        "format": "zerochat-local-snapshot", "version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "contains_credentials": True, "directories": directories,
        "missing_directories": missing, "files": entries,
        "client_exports": len(client_exports),
    }
    for key, args in (("git_head", ["rev-parse", "HEAD"]), ("git_status", ["status", "--short"])):
        result = subprocess.run(["git", "-C", str(workspace), *args], capture_output=True, text=True)
        manifest[key] = result.stdout.strip() if result.returncode == 0 else "unavailable"
    manifest_path = destination / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    (destination / "manifest.sha256").write_text(digest(manifest_path), encoding="ascii")
    verify_snapshot(destination)
    return destination


def verify_snapshot(snapshot):
    snapshot = Path(snapshot).resolve(strict=True)
    manifest_path = snapshot / "manifest.json"
    if digest(manifest_path) != (snapshot / "manifest.sha256").read_text(encoding="ascii").strip():
        raise ValueError("Manifest checksum mismatch")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != "zerochat-local-snapshot" or manifest.get("version") != 1:
        raise ValueError("Unsupported snapshot version")
    seen = set()
    for entry in manifest["files"]:
        path = safe_child(snapshot / "payload", entry["path"])
        key = str(path).casefold()
        if key in seen:
            raise ValueError("Duplicate snapshot entry")
        seen.add(key)
        if path.stat().st_size != entry["size"] or digest(path) != entry["sha256"]:
            raise ValueError("Payload checksum mismatch")
    for relative in manifest["directories"]:
        if not safe_child(snapshot / "payload", relative).is_dir():
            raise ValueError("Missing snapshot directory")
    return manifest


def restore_snapshot(snapshot, destination):
    snapshot = Path(snapshot).resolve(strict=True)
    manifest = verify_snapshot(snapshot)
    destination = new_directory(destination)
    for relative in manifest["directories"]:
        safe_child(destination, relative).mkdir(parents=True, exist_ok=True)
    for entry in manifest["files"]:
        source = safe_child(snapshot / "payload", entry["path"])
        target = safe_child(destination, entry["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        with source.open("rb") as src, target.open("xb") as dst:
            shutil.copyfileobj(src, dst)
        if digest(target) != entry["sha256"]:
            raise ValueError("Restored file checksum mismatch")
    report = {"verified": True, "files": len(manifest["files"]),
              "directories": len(manifest["directories"]), "live_data_overwritten": False}
    (destination / "restore-report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def restore_client_export(export, destination):
    """Decode a client export into a reviewable copy, never a running app."""
    data = json.loads(Path(export).read_text(encoding="utf-8"))
    if data.get("format") != "zerochat-client-export" or data.get("version") != 1:
        raise ValueError("Unsupported client export")
    if data.get("complete") is not True or not isinstance(data.get("preferences"), dict):
        raise ValueError("Incomplete client export")
    files = []
    seen = set()
    for entry in data.get("files", []):
        relative = entry["path"]
        safe_child(Path(destination) / "documents", relative)
        if relative.casefold() in seen:
            raise ValueError("Duplicate client file")
        seen.add(relative.casefold())
        content = base64.b64decode(entry["base64"], validate=True)
        if len(content) != entry["size"]:
            raise ValueError("Client file size mismatch")
        files.append((relative, content))
    for value in data["preferences"].values():
        if not isinstance(value, (str, int, float, bool, list)) or (
            isinstance(value, list) and not all(isinstance(item, str) for item in value)
        ):
            raise ValueError("Invalid preference type")
    destination = new_directory(destination)
    for relative, content in files:
        target = safe_child(destination / "documents", relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(content)
    (destination / "preferences.json").write_text(
        json.dumps(data["preferences"], ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return {"verified": True, "files": len(files), "preferences": len(data["preferences"]),
            "app_import_available": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--client-export", action="append", default=[])
    for name in ("verify", "restore", "restore-client"):
        command = commands.add_parser(name)
        command.add_argument("source", type=Path)
        if name != "verify":
            command.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.command == "create":
        print(json.dumps({"snapshot": str(create_snapshot(client_exports=args.client_export))}))
    elif args.command == "verify":
        manifest = verify_snapshot(args.source)
        print(json.dumps({"verified": True, "files": len(manifest["files"])}))
    elif args.command == "restore":
        print(json.dumps(restore_snapshot(args.source, args.destination)))
    else:
        print(json.dumps(restore_client_export(args.source, args.destination)))


if __name__ == "__main__":
    main()
