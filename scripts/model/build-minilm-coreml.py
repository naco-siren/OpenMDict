#!/usr/bin/env python3
"""
build-minilm-coreml.py — M15 Phase 3.0 model acquisition.

Convert `sentence-transformers/all-MiniLM-L6-v2` to a CoreML .mlpackage
that the iOS app can run via `MLModel`. Also emits the BERT tokenizer
`vocab.txt` that the Swift WordPiece tokenizer (Apps/CLI/BodyTokenizer.swift)
needs to feed the model.

WHY a local conversion script:
    HuggingFace's `coreml-projects` org doesn't host this model (last
    checked 2026-05). The official `sentence-transformers/all-MiniLM-L6-v2`
    repo has PyTorch weights but no .mlpackage. `coremltools` handles
    the conversion in one shot — runs once on the dev machine, output
    is what the iOS app ships via ODR.

Outputs (under models/minilm/ of the current directory, or $OPENMDICT_MODEL_OUT):
    all-MiniLM-L6-v2.mlpackage    CoreML model directory (~80 MB FP32,
                                  ~45 MB FP16 if quantization is enabled)
    vocab.txt                     ~250 KB tokenizer vocabulary

Once outputs exist:
    cd OpenMDict
    .build/release/openmdict articleembed \\
        --model models/minilm/all-MiniLM-L6-v2.mlpackage \\
        --vocab models/minilm/vocab.txt \\
        --sanity

Setup (one-time):
    python3 -m venv .venv-m15-build
    source .venv-m15-build/bin/activate
    pip install coremltools sentence-transformers transformers torch numpy

    # Total disk: ~3 GB pip cache + ~500 MB site-packages.
    # Only needed for this build step — fully throwaway venv.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Importing torch + coremltools warms up several seconds — do it once
# at top level so the slow path is obvious in the trace.
print("📦 Importing toolchain (torch / transformers / coremltools)…", flush=True)
import shutil
import numpy as np
import torch
from transformers import AutoModel
from huggingface_hub import hf_hub_download
import coremltools as ct


MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
MAX_LEN = 128

# Default to `models/minilm/` relative to the current working directory so
# the script works equally well in two scenarios:
#   - local:   run from the repository root → outputs to ./models/minilm/
#   - Colab:   run from /content/   → outputs to /content/models/minilm/
# Override via `OPENMDICT_MODEL_OUT=/some/path python3 build-minilm-coreml.py`.
OUT_DIR = Path(os.environ.get("OPENMDICT_MODEL_OUT", "models/minilm")).resolve()


# ─── BERT encoder wrapper ─────────────────────────────────────────────────

class EncoderOnly(torch.nn.Module):
    """
    Strip the `return_dict=True` HuggingFace wrapper so the traced graph
    has a single tensor output (last_hidden_state, rank 3: (B, L, D)).
    The Swift-side BodyEncoder mean-pools by attention mask, so no
    Pooling layer is needed in the CoreML graph.
    """
    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, input_ids, attention_mask):
        out = self.base(input_ids=input_ids, attention_mask=attention_mask)
        return out.last_hidden_state  # (1, MAX_LEN, hidden_dim)


# ─── M15 Phase 3.1: FP16-safe attention-mask monkey-patch ───────────────
#
# Why: HuggingFace's `PreTrainedModel.get_extended_attention_mask` builds
# the additive attention mask as `(1 - mask) * torch.finfo(dtype).min`.
# For dtype=float32 that constant is -3.4e38, way past FP16's representable
# range (±65504). When coremltools later casts the traced graph to FP16
# (via `compute_precision=FLOAT16`), the constant clamps to -inf. Then at
# runtime, for an *unmasked* position where attention_mask=1, the model
# computes `(1 - 1) * -inf = 0 * -inf = NaN`, which propagates through
# softmax and poisons every output position.
#
# Fix: patch the method to use a finite sentinel (-1e4) that's safely
# representable in FP16. Quality impact is nil — softmax of (-1e4)
# vs (-3.4e38) is indistinguishable to FP32 precision (both produce
# effectively-zero attention weight at masked positions), and we're
# going to FP16 anyway.
#
# This is the alternative to running the model in `.half()` mode, which
# would also work but has two downsides: (1) some BERT ops have spotty
# FP16-on-CPU support in older torch, and (2) it forces FP16 model output
# all the way to CoreML's output tensor, requiring Swift-side FP16→FP32
# conversion. Monkey-patching keeps the Python pipeline at FP32 (CoreML
# does the FP16 cast internally), so model output stays FP32 and our
# Swift `BodyEncoder.extractRow` continues to work unchanged.

def _install_fp16_safe_mask_patch():
    """Replace PreTrainedModel.get_extended_attention_mask with a version
    using -1e4 instead of torch.finfo(dtype).min for the additive mask."""
    from transformers.modeling_utils import PreTrainedModel
    _MASK_SENTINEL = -1e4

    def _fp16_safe_get_extended_attention_mask(
        self, attention_mask, input_shape, device=None, dtype=None
    ):
        if dtype is None:
            dtype = self.dtype
        if attention_mask.dim() == 3:
            extended = attention_mask[:, None, :, :]
        elif attention_mask.dim() == 2:
            extended = attention_mask[:, None, None, :]
        else:
            raise ValueError(
                f"Wrong shape for attention_mask: {attention_mask.shape}"
            )
        extended = extended.to(dtype=dtype)
        # ↓↓↓ the only meaningful change: -1e4 instead of torch.finfo(dtype).min
        extended = (1.0 - extended) * _MASK_SENTINEL
        return extended

    PreTrainedModel.get_extended_attention_mask = (
        _fp16_safe_get_extended_attention_mask
    )
    print("   ✓ Patched PreTrainedModel.get_extended_attention_mask "
          "(FP16-safe -1e4 mask sentinel)")


# ─── Main pipeline ───────────────────────────────────────────────────────

def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"📂 Output: {OUT_DIR}")
    print()

    # 1. Tokenizer vocab → vocab.txt (used by Swift WordPiece tokenizer).
    # Bypass AutoTokenizer entirely: in newer transformers versions the
    # Fast (Rust-backed) BertTokenizerFast's save_vocabulary/save_pretrained
    # silently no-ops for vocab.txt because the Python-side machinery uses
    # the embedded vocab in tokenizer.json and doesn't need a separate
    # vocab.txt. We need vocab.txt for the Swift tokenizer, so just grab
    # it from the HF Hub directly — it's a static file in the model repo.
    print(f"📝 Fetching vocab.txt for {MODEL_NAME}…", flush=True)
    vocab_src = hf_hub_download(repo_id=MODEL_NAME, filename="vocab.txt")
    vocab_path = OUT_DIR / "vocab.txt"
    shutil.copy(vocab_src, vocab_path)
    if not vocab_path.exists():
        sys.exit(f"❌ hf_hub_download produced no file at {vocab_path}")
    print(f"   ✓ Wrote {vocab_path} ({vocab_path.stat().st_size:,} bytes)")
    print()

    # 2. Model load + wrap for single-tensor output
    print(f"📦 Loading model weights ({MODEL_NAME})…", flush=True)
    # Note: don't pass `torchscript=` or `return_dict=` as from_pretrained
    # kwargs — newer transformers (4.40+) puts them on the config object,
    # not the model __init__. Defaults (return_dict=True, torchscript=False)
    # are what we want anyway.
    #
    # `attn_implementation="eager"` forces the legacy eager-mode attention
    # path instead of SDPA (scaled-dot-product-attention). SDPA generates
    # dynamic mask ops like `new_ones` that current coremltools versions
    # don't have a converter for — traced graph fails to convert. Eager
    # mode for BERT is functionally equivalent (same numerical output)
    # but uses ops coremltools knows about.
    base = AutoModel.from_pretrained(MODEL_NAME, attn_implementation="eager")
    base.eval()

    # M15 Phase 3.1: install the FP16-safe attention-mask patch BEFORE
    # tracing. Once trace records the graph, `_MASK_SENTINEL = -1e4` is
    # baked in as a constant, surviving the later FP16 cast in coremltools.
    _install_fp16_safe_mask_patch()

    wrapper = EncoderOnly(base)
    print("   ✓ Loaded")
    print()

    # 3. Trace with dummy input. The dtypes must match what the Swift
    #    side will send. We use int32 input_ids + int32 attention_mask
    #    to keep the CoreML input description simple; the model will
    #    cast internally as needed.
    print("📐 Tracing encoder graph…", flush=True)
    dummy_ids = torch.zeros(1, MAX_LEN, dtype=torch.int32)
    dummy_mask = torch.ones(1, MAX_LEN, dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask), strict=False)
    print("   ✓ Traced")
    print()

    # 4. CoreML conversion. Settings:
    #    - convert_to="mlprogram" → newer .mlpackage format, ANE-friendly.
    #    - minimum_deployment_target=iOS15 matches the app's deployment
    #      floor; coremltools will refuse ops that need newer iOS.
    #    - compute_precision=FLOAT16 — model is now safe to FP16-quantize
    #      thanks to the Phase 3.1 attention-mask monkey-patch above
    #      (see `_install_fp16_safe_mask_patch`). The mask constant is
    #      -1e4 instead of -3.4e38, so it casts to FP16 cleanly without
    #      overflowing to -inf, and softmax stays valid. FP16 halves
    #      model size (~85 MB → ~45 MB) AND unlocks Apple Neural Engine
    #      routing on A12-A14 (the MLE5Engine refuses FP32 weights, see
    #      Phase 3.0.5 POC findings).
    print("⚙️  Converting to CoreML… (this can take 1-3 minutes)", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_LEN), dtype=np.int32),
        ],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS15,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )
    print("   ✓ Converted")
    print()

    # 5. Metadata + save
    mlmodel.short_description = (
        "sentence-transformers/all-MiniLM-L6-v2 — token-level encoder. "
        "Output: last_hidden_state (1, 128, 384). Mean-pool by "
        "attention_mask in the host app to get sentence embedding."
    )
    mlmodel.author = "OpenMDict M15 build pipeline"
    mlmodel.license = "Apache 2.0 (from sentence-transformers)"
    mlmodel.version = "1.0"

    out_path = OUT_DIR / "all-MiniLM-L6-v2.mlpackage"
    if out_path.exists():
        # ct.convert won't overwrite cleanly — remove first.
        # NB: `shutil` is imported at module top, do NOT re-import here;
        # a local `import` would mark shutil as local-scoped for the
        # entire function, shadowing the top-level import even at
        # earlier line numbers (Python scoping rule).
        shutil.rmtree(out_path)
    mlmodel.save(str(out_path))
    print(f"✅ Saved CoreML model to {out_path}")

    # Best-effort size report.
    total_bytes = sum(p.stat().st_size for p in out_path.rglob("*") if p.is_file())
    print(f"   ({total_bytes / (1024 * 1024):.1f} MB)")
    print()

    # NB: when running inside a Docker container the absolute paths above are
    # container-internal (e.g. `/work/models/...`). On the host they're
    # wherever the `-v` mount points to. Print a relative-style hint so the
    # user reaches for the right thing regardless of where they ran us.
    print("Next (from the repository root on the host):")
    print("    .build/release/openmdict articleembed \\")
    print(f"        --model ../models/minilm/{out_path.name} \\")
    print(f"        --vocab ../models/minilm/{vocab_path.name} \\")
    print("        --sanity")
    print()


if __name__ == "__main__":
    main()
