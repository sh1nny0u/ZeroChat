"""Paths shared by runtime services and isolated verification processes."""
import os
import sys
from pathlib import Path

ROOT_DIR = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parents[1]
DATA_DIR = Path(os.environ.get("ZEROCHAT_DATA_DIR", str(ROOT_DIR / "data"))).resolve()
CONFIG_DIR = Path(os.environ.get("ZEROCHAT_CONFIG_DIR", str(ROOT_DIR / "config"))).resolve()
RUNTIME_DIR = Path(os.environ.get("ZEROCHAT_RUNTIME_DIR", str(ROOT_DIR / "runtime"))).resolve()
