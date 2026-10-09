# M15 Phase 3.0 — Linux x86 container for converting the MiniLM
# sentence-transformer to CoreML .mlpackage.
#
# Why a container: Colab's environment has been a moving target
# (torch 2.10, transformers 5.x, etc.) that doesn't match coremltools'
# tested matrix, and PyPI dropped Intel macOS torch wheels. Pinning
# everything here gives a known-good combo that runs identically on
# any host with Docker Desktop, regardless of host OS or CPU arch.
#
# Versions are pinned to a combination empirically known to convert
# all-MiniLM-L6-v2 cleanly:
#
#   torch 2.7.0          ← coremltools 8.x's most-recent tested torch
#   transformers 4.40.0  ← still uses `attn_implementation` kwarg
#                          but pre-dates the new SDPA path that
#                          generates `new_ones` ops coremltools can't
#                          handle
#   coremltools < 9      ← latest 8.x line, knows torch 2.7
#   numpy < 2            ← coremltools/transformers/numba all dislike
#                          numpy 2.x as of 2026-05
#
# Build (one-time, ~3 min; the image is linux/amd64 on purpose — coremltools
# 8.x has no linux/aarch64 wheels, so Apple-silicon hosts run it emulated):
#   cd <your-clone>            # the directory that contains Package.swift
#   docker build --platform=linux/amd64 -t openmdict-m15-build \
#       -f scripts/model/build-minilm.Dockerfile scripts/model/
#
# Run (~2-5 min — downloads model, traces, converts):
#   docker run --rm --platform=linux/amd64 \
#     -v "$(pwd)/scripts/model:/work/scripts:ro" \
#     -v "$(pwd)/models:/work/models" \
#     openmdict-m15-build
#
# Note: the production model shipped in assets.lock.json was converted on a
# CUDA machine (torch 2.7.0+cu126, coremltools 8.3.0); a rebuild here is
# functionally equivalent but not byte-identical, so it needs a new lock
# entry and asset tag (see MAINTAINING.md).
#
# Output: $(pwd)/models/minilm/  ← .mlpackage + vocab.txt on host fs

FROM python:3.11-slim

# OS-level deps: git for huggingface_hub's git-lfs codepath (in case it falls
# back from HTTP). Slim image has neither.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Python deps — pinned. Install in one layer so the image is small and the
# pip resolver has full context to find a consistent set.
RUN pip install --no-cache-dir \
        "torch==2.7.0" \
        "transformers==4.40.0" \
        "coremltools<9" \
        "huggingface_hub" \
        "numpy<2"

WORKDIR /work

# The script is mounted at /work/scripts/ via -v at runtime, so we don't
# bake it into the image — that way edits to the script don't invalidate
# the (slow) Docker build cache.
CMD ["python", "/work/scripts/build-minilm-coreml.py"]
