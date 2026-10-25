"""ComfyUI AUDIO_LAB bridge to an isolated Qwen3-TTS Python environment.

Install this file as:
  <ComfyUI>/custom_nodes/audio_lab_nodes.py

The model and its dependencies run OUTSIDE of ComfyUI's Python environment:
  <portable_root>/AudioLab/.venv/Scripts/python.exe
  <portable_root>/AudioLab/tts_worker.py
"""

import os
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import torch


class AudioLabVoiceClone:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "reference_audio": ("AUDIO",),
                "dialogue": ("STRING", {"default": "", "multiline": True}),
                "reference_transcript": ("STRING", {"default": "", "multiline": True}),
                "language": (["Spanish", "English", "Auto"], {"default": "Spanish"}),
                "model_size": (["0.6B", "1.7B"], {"default": "0.6B"}),
                "seed": ("INT", {"default": 7, "min": 0, "max": 2147483647}),
            }
        }

    RETURN_TYPES = ("AUDIO",)
    RETURN_NAMES = ("dialogue_audio",)
    FUNCTION = "generate"
    CATEGORY = "AUDIO_LAB"

    def generate(self, reference_audio, dialogue, reference_transcript, language, model_size, seed):
        if not dialogue.strip():
            raise ValueError("Escribe un diálogo antes de generar la voz.")

        # __file__ is <portable_root>/ComfyUI/custom_nodes/audio_lab_nodes.py
        portable_root = Path(__file__).resolve().parents[2]
        lab = portable_root / "AudioLab"
        python = lab / ".venv" / "Scripts" / "python.exe"
        worker = lab / "tts_worker.py"

        if not python.is_file() or not worker.is_file():
            raise RuntimeError(
                "AUDIO_LAB no está instalado completamente. "
                "Necesita AudioLab/.venv/Scripts/python.exe y AudioLab/tts_worker.py "
                "fuera de la carpeta ComfyUI."
            )

        wave = reference_audio["waveform"]
        if wave.ndim != 3 or wave.shape[0] != 1:
            raise ValueError("La muestra vocal debe contener una sola grabación de referencia.")
        sr = int(reference_audio["sample_rate"])
        mono = wave[0].float().mean(dim=0).detach().cpu().numpy()
        if mono.size == 0 or sr <= 0:
            raise ValueError("La muestra de voz está vacía.")
        if len(mono) / sr < 2:
            raise ValueError("Utiliza una muestra vocal limpia de al menos 2 segundos.")

        lab.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="audiolab_") as temp_dir:
            temp = Path(temp_dir)
            input_wav = temp / "voice_reference.wav"
            output_wav = temp / "spoken_dialogue.wav"
            sf.write(str(input_wav), mono, sr, subtype="PCM_16")
            command = [
                str(python), str(worker),
                "--reference", str(input_wav),
                "--output", str(output_wav),
                "--text", dialogue.strip(),
                "--reference-text", reference_transcript.strip(),
                "--language", language,
                "--model-size", model_size,
                "--device", "auto",
                "--seed", str(seed),
            ]
            env = os.environ.copy()
            env["HF_HOME"] = str(lab / "hf_cache")
            env.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
            proc = subprocess.run(
                command, env=env, capture_output=True, text=True,
                errors="replace", timeout=2400,
            )
            if proc.returncode != 0:
                raise RuntimeError(
                    "Error en Qwen3-TTS (entorno aislado):\n"
                    + ((proc.stderr or "") + "\n" + (proc.stdout or ""))[-4500:]
                )
            if not output_wav.is_file():
                raise RuntimeError("Qwen3-TTS terminó sin generar el archivo WAV.")
            samples, audio_sr = sf.read(str(output_wav), always_2d=True, dtype="float32")
            if samples.shape[0] < 1:
                raise RuntimeError("Qwen3-TTS devolvió un audio vacío.")
            waveform = torch.from_numpy(np.ascontiguousarray(samples.T)).unsqueeze(0)
            return ({"waveform": waveform, "sample_rate": int(audio_sr)},)


NODE_CLASS_MAPPINGS = {"AudioLabVoiceClone": AudioLabVoiceClone}
NODE_DISPLAY_NAME_MAPPINGS = {"AudioLabVoiceClone": "AUDIO_LAB · Clonar voz (aislado)"}
