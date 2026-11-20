#!/usr/bin/env python3
"""Fetch the pinned mobile speech models; verify before placing them in Android assets."""
import hashlib
from pathlib import Path
import urllib.request

MODELS = (
    (
        "silero_vad.onnx",
        "https://raw.githubusercontent.com/snakers4/silero-vad/"
        "be95df9152c0d7618fa1edfeb296fc3dae32376f/src/silero_vad/data/silero_vad.onnx",
        "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3",
    ),
    (
        "smart-turn-v3.2-cpu.onnx",
        "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/"
        "f766f81d3cfdf7737ac64aad813d91bbfd56bf93/smart-turn-v3.2-cpu.onnx",
        "2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f",
    ),
)


def main():
    target = Path(__file__).resolve().parents[1] / "android/app/src/main/assets/speech"
    target.mkdir(parents=True, exist_ok=True)
    for name, url, expected in MODELS:
        dest = target / name
        if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == expected:
            print(f"Verified {name}")
            continue
        part = dest.with_suffix(".onnx.part")
        digest = hashlib.sha256()
        try:
            with urllib.request.urlopen(url, timeout=60) as response, part.open("wb") as out:
                while chunk := response.read(1024 * 1024):
                    digest.update(chunk)
                    out.write(chunk)
            if digest.hexdigest() != expected:
                raise ValueError(f"SHA256 mismatch for {name}")
            part.replace(dest)
        finally:
            part.unlink(missing_ok=True)
        print(f"Downloaded and verified {name}")


if __name__ == "__main__":
    main()
