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


# AUDIO_LAB 2: deterministic dialogue planning; the lip-sync renderer is a
# separate stage and is intentionally NOT claimed to exist here.
import json
import re


def _parse_dialogue(script):
    lines = [s.strip() for s in script.splitlines() if s.strip()]
    if not lines:
        raise ValueError("Escribe al menos una frase.")
    if len(lines) == 1 and not re.match(r"^[ABab](?:@[0-9.]+)?\s*:", lines[0]):
        lines = ["A: " + lines[0]]  # Keep single-speaker drafts compatible.
    if len(lines) > 40:
        raise ValueError("Máximo 40 intervenciones por vídeo.")
    turns = []
    for number, line in enumerate(lines, 1):
        m = re.fullmatch(r"([ABab])(?:@(\d+(?:\.\d+)?))?\s*:\s*(.+)", line)
        if m is None:
            raise ValueError(
                f"Diálogo línea {number}: usa 'A: texto', 'B: texto' "
                "o 'A@12.5: texto'."
            )
        start = float(m.group(2)) if m.group(2) is not None else None
        if start is not None and not (0 <= start <= 86400):
            raise ValueError(f"Inicio inválido en línea {number}.")
        turns.append({"speaker": m.group(1).upper(), "start": start,
                      "text": m.group(3).strip()})
    return turns


def _schedule_turns(turns, durations, video_duration):
    """Place automatic groups between user-fixed anchors; never cut speech."""
    minimum_gap = 0.12
    position = 0.0
    index = 0
    total = len(turns)
    while index < total:
        if turns[index]["start"] is not None:
            start = turns[index]["start"]
            if start + 1e-4 < position + (minimum_gap if index > 0 else 0):
                raise ValueError(f"El diálogo {index+1} se solapa con el anterior.")
            end = start + durations[index]
            if end > video_duration + 1e-4:
                raise ValueError(
                    f"El diálogo {index+1} termina en {end:.2f}s y "
                    f"el vídeo acaba en {video_duration:.2f}s."
                )
            turns[index]["start"] = start
            turns[index]["end"] = end
            position = end
            index += 1
            continue

        next_fixed = index
        while next_fixed < total and turns[next_fixed]["start"] is None:
            next_fixed += 1
        limit = (turns[next_fixed]["start"] if next_fixed < total
                 else video_duration)
        count = next_fixed - index
        spoken = sum(durations[index:next_fixed])
        gap = (limit - position - spoken) / (count + 1)
        if gap < minimum_gap - 1e-4:
            raise ValueError(
                f"Las frases {index+1}-{next_fixed} no caben antes de "
                f"{limit:.2f}s. Acorta el texto o cambia el vídeo."
            )
        for i in range(index, next_fixed):
            start = position + gap
            end = start + durations[i]
            turns[i]["start"] = start
            turns[i]["end"] = end
            position = end
        index = next_fixed

    return turns


class AudioLabDialoguePlanner:
    """Generate A/B phrases in one isolated worker, position and pad to video."""
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "reference_a": ("AUDIO",),
                "video_duration": ("FLOAT", {"default": 20.0, "min": 0.1, "max": 86400.0}),
                "script": ("STRING", {"multiline": True, "default": "A: ¿Has oído eso?\nB: Sí, lo he oído."}),
                "transcript_a": ("STRING", {"multiline": True, "default": ""}),
                "transcript_b": ("STRING", {"multiline": True, "default": ""}),
                "language": (["Spanish", "English", "Auto"], {"default": "Spanish"}),
                "model_size": (["0.6B", "1.7B"], {"default": "0.6B"}),
                "seed": ("INT", {"default": 7, "min": 0, "max": 2147483647}),
            },
            "optional": {"reference_b": ("AUDIO",)},
        }

    RETURN_TYPES = ("AUDIO", "STRING", "AUDIO", "AUDIO")
    RETURN_NAMES = ("dialogue_audio", "timeline_json", "voice_A", "voice_B")
    FUNCTION = "generate"
    CATEGORY = "AUDIO_LAB"

    def generate(self, reference_a, video_duration, script, transcript_a,
                 transcript_b, language, model_size, seed, reference_b=None):
        duration = float(video_duration)
        if not (0.1 <= duration <= 86400):
            raise ValueError("La duración del vídeo no es válida.")
        turns = _parse_dialogue(script)
        if any(t["speaker"] == "B" for t in turns) and reference_b is None:
            raise ValueError(
                "El guion contiene frases de B. Conecta una muestra de voz B "
                "al nodo AUDIO_LAB, o usa únicamente líneas A:."
            )

        root = Path(__file__).resolve().parents[2] / "AudioLab"
        python = root / ".venv" / "Scripts" / "python.exe"
        worker = root / "tts_worker.py"
        if not python.is_file() or not worker.is_file():
            raise RuntimeError("Falta el entorno AudioLab aislado o su tts_worker.py.")
        refs = {"A": reference_a, "B": reference_b}
        with tempfile.TemporaryDirectory(prefix="audiolab_dialogue_") as td:
            folder = Path(td)
            reference_paths = {}
            for person in {t["speaker"] for t in turns}:
                ref = refs[person]
                wave = ref["waveform"]
                if wave.ndim != 3 or wave.shape[0] != 1:
                    raise ValueError(f"Muestra {person}: debe contener un solo audio.")
                rate = int(ref["sample_rate"])
                mono = wave[0].float().mean(dim=0).detach().cpu().numpy()
                if rate <= 0 or mono.size < rate * 2:
                    raise ValueError(f"Muestra {person}: necesita 2 segundos de voz.")
                destination = folder / f"reference_{person}.wav"
                sf.write(str(destination), mono, rate, subtype="PCM_16")
                reference_paths[person] = str(destination)

            jobs = []
            for i, turn in enumerate(turns):
                person = turn["speaker"]
                jobs.append({
                    "reference": reference_paths[person],
                    "output": str(folder / f"part_{i:03d}.wav"),
                    "text": turn["text"],
                    "reference_text": transcript_a if person == "A" else transcript_b,
                    "language": language,
                    "seed": int(seed) + i,
                })
            jobs_path = folder / "jobs.json"
            jobs_path.write_text(json.dumps(jobs, ensure_ascii=False), encoding="utf-8")
            env = os.environ.copy()
            env["HF_HOME"] = str(root / "hf_cache")
            env.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
            completed = subprocess.run(
                [str(python), str(worker), "--jobs-json", str(jobs_path),
                 "--model-size", model_size, "--language", language,
                 "--device", "auto", "--seed", str(seed)],
                env=env, capture_output=True, text=True, errors="replace",
                timeout=7200,
            )
            if completed.returncode != 0:
                raise RuntimeError(
                    "Qwen3-TTS no pudo generar las frases:\n"
                    + ((completed.stderr or "") + "\n"
                       + (completed.stdout or ""))[-5000:]
                )
            clips = []
            sample_rate = None
            for job in jobs:
                if not Path(job["output"]).is_file():
                    raise RuntimeError("Qwen3-TTS no entregó todas las frases.")
                samples, sr = sf.read(job["output"], always_2d=True, dtype="float32")
                if sample_rate is None:
                    sample_rate = int(sr)
                elif sample_rate != int(sr):
                    raise RuntimeError("Qwen3-TTS devolvió frecuencias de voz diferentes.")
                clip = torch.from_numpy(np.ascontiguousarray(samples.mean(axis=1)))
                if clip.numel() < 1:
                    raise RuntimeError("Una frase generada no contiene audio.")
                clips.append(clip)

            _schedule_turns(turns, [clip.numel() / sample_rate for clip in clips], duration)
            length = round(duration * sample_rate)
            tracks = {"A": torch.zeros((1, 1, length), dtype=torch.float32),
                      "B": torch.zeros((1, 1, length), dtype=torch.float32)}
            for turn, clip in zip(turns, clips):
                offset = round(turn["start"] * sample_rate)
                if offset + clip.numel() > length:
                    # Rounding to output sample boundaries, never truncate speech.
                    offset = length - clip.numel()
                if offset < 0:
                    raise ValueError("La frase generada supera la duración del vídeo.")
                tracks[turn["speaker"]][0, 0, offset:offset + clip.numel()] += clip
            mixed = (tracks["A"] + tracks["B"]).clamp(-1, 1)
            timeline = json.dumps({
                "video_duration": duration, "sample_rate": sample_rate,
                "turns": turns,
                "status": "audio_only_no_lip_sync",
            }, ensure_ascii=False, indent=2)
            print("AUDIO_LAB · Plan de diálogos:\n" + timeline, flush=True)
            def as_audio(wave):
                return {"waveform": wave, "sample_rate": sample_rate}
            return (as_audio(mixed), timeline,
                    as_audio(tracks["A"]), as_audio(tracks["B"]))


NODE_CLASS_MAPPINGS["AudioLabDialoguePlanner"] = AudioLabDialoguePlanner
NODE_DISPLAY_NAME_MAPPINGS["AudioLabDialoguePlanner"] = "AUDIO_LAB · Planificar diálogos A/B"
