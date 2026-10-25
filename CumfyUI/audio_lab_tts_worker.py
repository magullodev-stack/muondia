"""Qwen3-TTS worker. Runs only in the isolated AudioLab virtualenv."""

import argparse
import random
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

from qwen_tts import Qwen3TTSModel


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--reference", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--reference-text", default="")
    p.add_argument("--language", choices=("Spanish", "English", "Auto"), default="Spanish")
    p.add_argument("--model-size", choices=("0.6B", "1.7B"), default="0.6B")
    p.add_argument("--seed", type=int, default=7)
    args = p.parse_args()

    if not Path(args.reference).is_file():
        raise FileNotFoundError(args.reference)

    random.seed(args.seed)
    np.random.seed(args.seed % (2**32))
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)
        dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        device = "cuda:0"
    else:
        raise RuntimeError(
            "El entorno Python aislado no detecta CUDA. "
            "Instala PyTorch CUDA en AudioLab/.venv; no cambies el Python de ComfyUI."
        )

    repo = f"Qwen/Qwen3-TTS-12Hz-{args.model_size}-Base"
    model = Qwen3TTSModel.from_pretrained(
        repo,
        device_map=device,
        dtype=dtype,
        attn_implementation="sdpa",
    )
    transcript = args.reference_text.strip()
    output, rate = model.generate_voice_clone(
        text=args.text,
        language=args.language,
        ref_audio=args.reference,
        ref_text=transcript if transcript else None,
        x_vector_only_mode=(not bool(transcript)),
        do_sample=False,
    )
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    sf.write(args.output, output[0], int(rate), subtype="PCM_16")
    print(f"Generated voice: {args.output} ({rate} Hz)")


if __name__ == "__main__":
    main()
