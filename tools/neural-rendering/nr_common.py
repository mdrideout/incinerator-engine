"""Shared, deliberately small helpers for Incinerator neural-rendering tools."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

import numpy as np
import torch
from PIL import Image


SCHEMA_VERSION = 1


def require_absolute(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise ValueError(f"{label} must be an absolute path: {path}")
    return path


def create_new_directory(path: Path, label: str) -> Path:
    require_absolute(path, label)
    if path.exists():
        raise FileExistsError(f"{label} already exists; runs are immutable: {path}")
    path.mkdir(parents=True)
    return path


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent, text=True
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
            temporary.write(encoded)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        raise ValueError(f"expected an object in {path}")
    return value


def image_to_tensor(path: Path) -> torch.Tensor:
    with Image.open(path) as image:
        pixels = np.asarray(image.convert("RGB"), dtype=np.float32) / 255.0
    return torch.from_numpy(pixels).permute(2, 0, 1).contiguous()


def tensor_to_image(tensor: torch.Tensor) -> Image.Image:
    pixels = (
        tensor.detach()
        .float()
        .clamp(0.0, 1.0)
        .permute(1, 2, 0)
        .cpu()
        .numpy()
    )
    return Image.fromarray(np.rint(pixels * 255.0).astype(np.uint8), mode="RGB")


def select_device(requested: str) -> torch.device:
    if requested == "auto":
        requested = "mps" if torch.backends.mps.is_available() else "cpu"
    if requested == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("MPS was requested but is not available")
    return torch.device(requested)


def synchronize(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


def git_revision(repo_root: Path) -> str | None:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def git_worktree_record(repo_root: Path) -> dict[str, Any]:
    revision = git_revision(repo_root)
    status = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout
    diff = subprocess.run(
        ["git", "diff", "--binary", "HEAD", "--"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout
    untracked_output = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout
    untracked = [value.decode("utf-8") for value in untracked_output.split(b"\0") if value]
    fingerprint = hashlib.sha256()
    fingerprint.update((revision or "unknown").encode())
    fingerprint.update(b"\0status\0")
    fingerprint.update(status)
    fingerprint.update(b"\0diff\0")
    fingerprint.update(diff)
    untracked_files = []
    for relative in sorted(untracked):
        path = repo_root / relative
        file_digest = sha256_file(path)
        fingerprint.update(b"\0untracked\0")
        fingerprint.update(relative.encode())
        fingerprint.update(b"\0")
        fingerprint.update(file_digest.encode())
        untracked_files.append({"path": relative, "sha256": file_digest})
    return {
        "revision": revision,
        "dirty": bool(status),
        "dirty_fingerprint": f"sha256-{fingerprint.hexdigest()}",
        "status": status.decode("utf-8").splitlines(),
        "untracked_files": untracked_files,
    }


def environment_record(repo_root: Path) -> dict[str, Any]:
    freeze = subprocess.run(
        [sys.executable, "-m", "pip", "freeze", "--all"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    return {
        "captured_unix_ms": time.time_ns() // 1_000_000,
        "python": sys.version,
        "executable": sys.executable,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "torch": torch.__version__,
        "mps_available": torch.backends.mps.is_available(),
        "repository": git_worktree_record(repo_root),
        "pip_freeze": freeze,
    }


def psnr_from_mse(mse: float) -> float:
    if mse == 0.0:
        return float("inf")
    return 10.0 * float(np.log10(1.0 / mse))
