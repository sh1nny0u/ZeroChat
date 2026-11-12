"""Validate installed server requirements without installing or loading user data."""
from importlib import import_module, metadata, util
from pathlib import Path
import platform
import re
import struct
import subprocess
import sys


IMPORT_MODULES = {
    "fastapi": ("fastapi",), "uvicorn": ("uvicorn", "httptools", "watchfiles", "websockets", "dotenv", "yaml"),
    "httpx": ("httpx",), "python-multipart": ("multipart",),
    "pydantic": ("pydantic", "pydantic_core"), "apscheduler": ("apscheduler",),
    "duckduckgo-search": ("duckduckgo_search",), "fastembed": ("fastembed", "onnxruntime"),
}


def base_runtime_supported():
    return (sys.version_info[:2] == (3, 11) and struct.calcsize("P") == 8
            and platform.machine().lower() in {"amd64", "x86_64"})


def check_imports():
    requirements = Path(__file__).resolve().parents[1] / "requirements.txt"
    selected = []
    for line in requirements.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([\w.-]+)", line.strip())
        if match:
            name = re.sub(r"[-_.]+", "-", match.group(1)).lower()
            selected.extend(IMPORT_MODULES.get(name, (name.replace("-", "_"),)))
    for module in dict.fromkeys(selected):
        try:
            import_module(module)
        except Exception as error:
            print(f"[错误] 依赖 {module} 无法加载（{type(error).__name__}）。")
            print("[信息] 请确认使用 Python 3.11 x64；原生 DLL 加载失败时检查 Microsoft Visual C++ x64 运行库。")
            return 1
    import sqlite3
    with sqlite3.connect(":memory:") as db:
        db.execute("CREATE VIRTUAL TABLE startup_fts_check USING fts5(content)")
    print("[信息] 后端依赖及原生运行库加载检查通过。")
    return 0


def main():
    if sys.argv[1:] == ["--base-only"]:
        if not base_runtime_supported():
            print("[错误] 当前 Windows 发布目标为 Python 3.11 x64。")
            return 1
        return 0
    print(f"[信息] 使用 Python：{sys.executable}", flush=True)
    expected_venv = Path(__file__).resolve().parents[1] / "venv"
    if sys.platform == "win32" and not base_runtime_supported():
        print("[错误] 当前 Windows 发布目标为 Python 3.11 x64。")
        return 1
    if sys.prefix == sys.base_prefix or Path(sys.prefix).resolve() != expected_venv.resolve():
        print(f"[错误] 必须使用项目虚拟环境：{expected_venv}")
        return 1
    config = expected_venv / "pyvenv.cfg"
    if not config.is_file() or not re.search(
        r"^include-system-site-packages\s*=\s*false\s*$",
        config.read_text(encoding="utf-8"),
        re.MULTILINE | re.IGNORECASE,
    ):
        print("[错误] 项目虚拟环境必须关闭全局 site-packages 继承。")
        return 1
    if sys.argv[1:] == ["--runtime-only"]:
        return 0
    if sys.argv[1:] == ["--imports-only"]:
        return check_imports()
    try:
        from pip._vendor.packaging.requirements import Requirement
        from pip._vendor.packaging.utils import canonicalize_name
    except ImportError:
        print("[错误] 项目环境缺少可用的 pip，请在可写目录重新解压干净发布包后启动。")
        return 1
    modules = {"python-multipart": "multipart", "duckduckgo-search": "duckduckgo_search"}
    problems = []
    requirements = Path(__file__).resolve().parents[1] / "requirements.txt"
    pending = []
    for line in requirements.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        pending.append(Requirement(line))
    roots = tuple(pending)
    checked = set()
    while pending:
        requirement = pending.pop()
        if requirement.marker is not None and not requirement.marker.evaluate():
            continue
        name = canonicalize_name(requirement.name)
        key = (name, str(requirement.specifier), tuple(sorted(requirement.extras)))
        if key in checked:
            continue
        checked.add(key)
        try:
            actual = metadata.version(name)
        except metadata.PackageNotFoundError:
            problems.append(f"缺少依赖：{name}")
            continue
        if not requirement.specifier.contains(actual):
            problems.append(f"{name} 版本为 {actual}，需要 {requirement.specifier}")
        if name in modules or any(canonicalize_name(r.name) == name for r in roots):
            module = modules.get(name, name.replace("-", "_"))
            if util.find_spec(module) is None:
                problems.append(f"无法导入依赖：{module}")
        for declaration in metadata.requires(name) or []:
            dependency = Requirement(declaration)
            if dependency.marker is None or any(
                dependency.marker.evaluate({"extra": extra}) for extra in {"", *requirement.extras}
            ):
                dependency.marker = None
                pending.append(dependency)
    if problems:
        for problem in problems:
            print(f"[错误] {problem}")
        return 1
    result = subprocess.run([sys.executable, "-I", "-m", "pip", "check"], check=False)
    if result.returncode:
        return 1
    print("[信息] 后端依赖检查通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
