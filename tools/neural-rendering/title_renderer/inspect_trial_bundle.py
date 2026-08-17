#!/usr/bin/env python3
"""Read-only integrity inspector for the active immutable neural trial bundle."""

from __future__ import annotations

import argparse
from pathlib import Path

from title_renderer.trial_bundle import inspect


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    value = inspect(args.root)
    print("RF10_TRIAL_BUNDLE_INSPECT_PASS " + " ".join(f"{key}={value[key]}" for key in sorted(value)))


if __name__ == "__main__":
    main()
