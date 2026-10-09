#!/usr/bin/env python3
"""
build-st-coreml.py — generalized sentence-transformer → CoreML converter.

Takes any HuggingFace sentence-transformer (or BERT-encoder-with-mean-pool)
and produces a CoreML .mlpackage suitable for use with the iOS app's
BodyEncoder. Differs from build-minilm-coreml.py in that the model id is
now a CLI arg, and we auto-derive output paths / vocab handling per
architecture (BERT-uncased vs RoBERTa vs other tokenizer formats).

Used for the M15 Phase 3.1 model survey:

    python3 scripts/build-st-coreml.py --model sentence-transformers/all-MiniLM-L6-v2
    python3 scripts/build-st-coreml.py --model sentence-transformers/all-MiniLM-L12-v2
    python3 scripts/build-st-coreml.py --model BAAI/bge-small-en-v1.5
    python3 scripts/build-st-coreml.py --model thenlper/gte-small
    python3 scripts/build-st-coreml.py --model intfloat/e5-small-v2

Designed to run inside the same Docker container as build-minilm-coreml.py
(torch 2.7, transformers 4.40, coremltools <9, numpy <2).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import shutil
import sys
from pathlib import Path

print("📦 Importing toolchain (torch / transformers / coremltools)…", flush=True)
import numpy as np
import torch
from transformers import AutoModel
from huggingface_hub import hf_hub_download
import coremltools as ct


MAX_LEN = 128


# ─── Encoder wrapper ───────────────────────────────────────────────────────

class EncoderOnly(torch.nn.Module):
    """Strip the dict wrapper so trace produces a single rank-3 tensor."""
    def __init__(self, base):
        super().__init__()
        self.base = base

    def forward(self, input_ids, attention_mask):
        out = self.base(input_ids=input_ids, attention_mask=attention_mask)
        return out.last_hidden_state  # (1, MAX_LEN, hidden_dim)


# ─── FP16-safe attention mask monkey-patch (from build-minilm-coreml.py) ──

def _install_fp16_safe_mask_patch():
    """Patches PreTrainedModel.get_extended_attention_mask to use -1e4 as
    the mask sentinel instead of torch.finfo(dtype).min. The default
    sentinel overflows during FP16 conversion → NaN softmax. -1e4 stays
    representable in FP16 and gives equivalent softmax behavior."""
    from transformers.modeling_utils import PreTrainedModel
    _MASK_SENTINEL = -1e4

    def _fp16_safe(self, attention_mask, input_shape, device=None, dtype=None):
        if dtype is None:
            dtype = self.dtype
        if attention_mask.dim() == 3:
            extended = attention_mask[:, None, :, :]
        elif attention_mask.dim() == 2:
            extended = attention_mask[:, None, None, :]
        else:
            raise ValueError(f"Wrong shape: {attention_mask.shape}")
        extended = extended.to(dtype=dtype)
        extended = (1.0 - extended) * _MASK_SENTINEL
        return extended

    PreTrainedModel.get_extended_attention_mask = _fp16_safe
    print("   ✓ Patched get_extended_attention_mask (FP16-safe)")


# ─── Main ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True,
                        help="HF model id, e.g. 'sentence-transformers/all-MiniLM-L6-v2'")
    parser.add_argument("--out-dir-base",
                        default=os.environ.get("OPENMDICT_MODEL_OUT_BASE", "models"),
                        help="Parent dir for output (default: ./models)")
    parser.add_argument("--max-len", type=int, default=MAX_LEN)
    args = parser.parse_args()

    model_id = args.model
    # Derive output dir from last segment of model id (e.g.
    # "BAAI/bge-small-en-v1.5" → "models/bge-small-en-v1.5")
    out_subdir = model_id.split("/")[-1]
    out_dir = (Path(args.out_dir_base) / out_subdir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"📂 Model:  {model_id}")
    print(f"📂 Output: {out_dir}")
    print()

    # 1. Fetch vocab.txt directly (avoids BertTokenizerFast.save_vocabulary
    # silently no-op'ing). BGE/GTE/E5/MiniLM all use BERT-uncased's
    # 30522-token WordPiece vocab — same file across all of them, but
    # download from the model's own repo for robustness.
    print(f"📝 Fetching vocab.txt for {model_id}…", flush=True)
    try:
        vocab_src = hf_hub_download(repo_id=model_id, filename="vocab.txt")
    except Exception as e:
        sys.exit(f"❌ vocab.txt not in repo (model may use a different tokenizer): {e}")
    vocab_path = out_dir / "vocab.txt"
    shutil.copy(vocab_src, vocab_path)
    print(f"   ✓ Wrote {vocab_path} ({vocab_path.stat().st_size:,} bytes)")
    print()

    # 2. Model load
    print(f"📦 Loading model weights ({model_id})…", flush=True)
    base = AutoModel.from_pretrained(model_id, attn_implementation="eager")
    base.eval()

    # 3. Install monkey-patch BEFORE trace
    _install_fp16_safe_mask_patch()

    wrapper = EncoderOnly(base)
    wrapper.eval()
    print("   ✓ Loaded")
    print()

    # 4. Trace
    print("📐 Tracing encoder graph…", flush=True)
    dummy_ids = torch.zeros(1, args.max_len, dtype=torch.int32)
    dummy_mask = torch.ones(1, args.max_len, dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask), strict=False)
    print("   ✓ Traced")
    print()

    # 5. CoreML convert
    print("⚙️  Converting to CoreML… (1-3 min)", flush=True)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, args.max_len), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, args.max_len), dtype=np.int32),
        ],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS15,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )
    print("   ✓ Converted")
    print()

    mlmodel.short_description = (
        f"Sentence-transformer encoder from {model_id}. Output: "
        f"last_hidden_state (1, {args.max_len}, hidden_dim). "
        f"Mean-pool by attention_mask in the host app."
    )
    mlmodel.author = "OpenMDict M15 Phase 3.1 model survey"

    out_path = out_dir / f"{out_subdir}.mlpackage"
    if out_path.exists():
        shutil.rmtree(out_path)
    mlmodel.save(str(out_path))
    total_bytes = sum(p.stat().st_size for p in out_path.rglob("*") if p.is_file())
    print(f"✅ Saved CoreML model to {out_path}")
    print(f"   ({total_bytes / (1024 * 1024):.1f} MB)")
    print()


if __name__ == "__main__":
    main()
