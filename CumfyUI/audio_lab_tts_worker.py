"""Qwen3-TTS worker. Runs only in the isolated AudioLab virtualenv."""

import argparse
import json
import random
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

from qwen_tts import Qwen3TTSModel


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--reference", default="")
    p.add_argument("--output", default="")
    p.add_argument("--text", default="")
    p.add_argument("--reference-text", default="")
    p.add_argument("--language", choices=("Spanish", "English", "Auto"), default="Spanish")
    p.add_argument("--model-size", choices=("0.6B", "1.7B"), default="0.6B")
    p.add_argument("--device", choices=("auto", "cpu", "gpu"), default="auto")
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--jobs-json", default="", help="Batch of dialogue segments; loads TTS model once")
    args = p.parse_args()

    if args.jobs_json:
        with open(args.jobs_json, "r", encoding="utf-8") as f:
            jobs = json.load(f)
        if not isinstance(jobs, list) or not jobs:
            raise ValueError("El plan de diálogo debe incluir al menos una frase.")
        for job in jobs:
            if not Path(job["reference"]).is_file():
                raise FileNotFoundError(job["reference"])
    else:
        if not Path(args.reference).is_file():
            raise FileNotFoundError(args.reference)
        if not args.text.strip() or not args.output:
            raise ValueError("Faltan --text y --output.")
        jobs = [{"reference": args.reference, "output": args.output, "text": args.text,
                 "reference_text": args.reference_text, "language": args.language, "seed": args.seed}]

    random.seed(args.seed)
    np.random.seed(args.seed % (2**32))
    torch.manual_seed(args.seed)
    cuda_available = torch.cuda.is_available()
    if args.device == "gpu" and not cuda_available:
        raise RuntimeError(
            "Has seleccionado GPU pero este entorno no tiene PyTorch con CUDA activo. "
            "Selecciona CPU/Auto para continuar, o instala PyTorch CUDA SOLO en AudioLab/.venv."
        )
    use_gpu = args.device == "gpu" or (args.device == "auto" and cuda_available)
    if use_gpu:
        torch.cuda.manual_seed_all(args.seed)
        dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        device = "cuda:0"
    else:
        dtype = torch.float32  # Float32 for compatibility with PyTorch CPU kernels.
        device = "cpu"
    print(f"AUDIO_LAB TTS: mode={args.device}, device={device}, dtype={dtype}", flush=True)

    repo = f"Qwen/Qwen3-TTS-12Hz-{args.model_size}-Base"
    model = Qwen3TTSModel.from_pretrained(
        repo,
        device_map=device,
        dtype=dtype,
        attn_implementation="sdpa",
    )
    for index, job in enumerate(jobs, start=1):
        text = str(job["text"]).strip()
        if not text:
            raise ValueError(f"La frase {index} está vacía.")
        seed = int(job.get("seed", args.seed + index - 1))
        random.seed(seed)
        np.random.seed(seed % (2**32))
        torch.manual_seed(seed)
        if use_gpu:
            torch.cuda.manual_seed_all(seed)
        transcript = str(job.get("reference_text", "")).strip()
        print(f"Generando diálogo {index}/{len(jobs)}...", flush=True)
        output, rate = model.generate_voice_clone(
            text=text,
            language=job.get("language", args.language),
            ref_audio=job["reference"],
            ref_text=transcript if transcript else None,
            x_vector_only_mode=not bool(transcript),
            do_sample=False,
        )
        dest = Path(job["output"])
        dest.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(dest), output[0], int(rate), subtype="PCM_16")
        print(f"Voz {index}: {dest} ({rate} Hz)", flush=True)


if __name__ == "__main__":
    main()
