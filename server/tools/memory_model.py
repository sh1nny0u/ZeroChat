"""Explicit local CPU embedding model preparation."""
import argparse
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from services import memory_index_service as index

def prepare():
    from fastembed import TextEmbedding
    directory = Path(os.environ.get("ZEROCHAT_MODEL_DIR", str(index.RUNTIME_DIR / "models"))).resolve()
    print("模型安装位置：" + str(directory), flush=True)
    model = TextEmbedding(index.MODEL, cache_dir=str(directory), threads=4, providers=["CPUExecutionProvider"])
    assert len(next(model.embed(["验证本地中文模型"]))) == 512
    print(json.dumps({"ready": True, "model": index.MODEL, "directory": str(directory)}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare"])
    parser.parse_args()
    prepare()
