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
    """Only user-chosen start times are allowed. Optional end is a hard cap.

    A@8.250: Frase
    B@12.000-15.000: Respuesta
    """
    lines = [(i, s.strip()) for i, s in enumerate(script.splitlines(), 1)
             if s.strip() and not s.strip().startswith("#")]
    if not lines:
        raise ValueError("Escribe un guion con tiempos, por ejemplo: A@8.250: Hola.")
    if len(lines) > 40:
        raise ValueError("Máximo 40 intervenciones por vídeo.")
    turns = []
    last_start = -1.0
    pattern = (r"([ABab])@(\d+(?:\.\d{1,3})?)"
               r"(?:-(\d+(?:\.\d{1,3})?))?\s*:\s*(.+)")
    for number, line in lines:
        m = re.fullmatch(pattern, line)
        if m is None:
            raise ValueError(
                f"Línea {number}: falta una hora de inicio válida. "
                "Usa 'A@8.250: frase' o 'B@12.000-16.000: frase'. "
                "AUDIO_LAB no elegirá el momento de hablar por ti."
            )
        start = float(m.group(2))
        window_end = float(m.group(3)) if m.group(3) else None
        if not (0 <= start <= 86400):
            raise ValueError(f"Inicio inválido en línea {number}.")
        if window_end is not None and not (start < window_end <= 86400):
            raise ValueError(f"Final del intervalo inválido en línea {number}.")
        if start <= last_start:
            raise ValueError(
                f"Línea {number}: los comienzos deben ser crecientes. "
                "Ordena las intervenciones por tiempo."
            )
        turns.append({
            "speaker": m.group(1).upper(),
            "start": start,
            "window_end": window_end,
            "text": m.group(4).strip(),
        })
        last_start = start
    return turns


def _schedule_turns(turns, durations, video_duration):
    """Respect exact user timestamps. Never distribute, slide or truncate speech."""
    prev_end = 0.0
    epsilon = 1e-4
    for index, (turn, spoken_duration) in enumerate(zip(turns, durations), 1):
        start = float(turn["start"])
        end = start + float(spoken_duration)
        limit = turn.get("window_end")
        if start < prev_end - epsilon:
            raise ValueError(
                f"Frase {index}: empieza a {start:.3f}s pero "
                f"la intervención anterior termina a {prev_end:.3f}s. "
                "No se moverán las frases automáticamente."
            )
        if limit is not None and end > float(limit) + epsilon:
            raise ValueError(
                f"Frase {index}: el audio termina en {end:.3f}s, fuera de "
                f"tu intervalo {start:.3f}-{float(limit):.3f}s. "
                "Acorta el texto o amplía el intervalo. No se acelerará la voz."
            )
        if end > video_duration + epsilon:
            raise ValueError(
                f"Frase {index}: termina en {end:.3f}s pero el vídeo acaba "
                f"en {video_duration:.3f}s. No se recortará el diálogo."
            )
        turn["end"] = end
        prev_end = end
    return turns


class AudioLabDialoguePlanner:
    """Generate A/B phrases in one isolated worker, position and pad to video."""
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "reference_a": ("AUDIO",),
                "video_duration": ("FLOAT", {"default": 20.0, "min": 0.1, "max": 86400.0}),
                "script": ("STRING", {"multiline": True, "default": "A@8.000: ¿Has oído eso?\nB@12.000: Sí, lo he oído."}),
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
        for index, turn in enumerate(turns, 1):
            if turn["start"] >= duration or (
                turn.get("window_end") is not None and turn["window_end"] > duration
            ):
                raise ValueError(
                    f"Frase {index}: el tiempo elegido queda fuera del "
                    f"vídeo de {duration:.3f}s."
                )
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
                if offset < 0 or offset + clip.numel() > length:
                    raise ValueError(
                        "El audio no cabe en el vídeo al redondear muestras; "
                        "AUDIO_LAB no moverá ni recortará la voz."
                    )
                tracks[turn["speaker"]][0, 0, offset:offset + clip.numel()] += clip
            mixed = (tracks["A"] + tracks["B"]).clamp(-1, 1)
            timeline = json.dumps({
                "video_duration": duration, "sample_rate": sample_rate,
                "turns": turns,
                "status": "timed_voice_ready_for_lip_sync",
            }, ensure_ascii=False, indent=2)
            print("AUDIO_LAB · Plan de diálogos:\n" + timeline, flush=True)
            def as_audio(wave):
                return {"waveform": wave, "sample_rate": sample_rate}
            return (as_audio(mixed), timeline,
                    as_audio(tracks["A"]), as_audio(tracks["B"]))


NODE_CLASS_MAPPINGS["AudioLabDialoguePlanner"] = AudioLabDialoguePlanner
NODE_DISPLAY_NAME_MAPPINGS["AudioLabDialoguePlanner"] = "AUDIO_LAB · Planificar diálogos A/B"


class AudioLabSafeMix:
    """Mix full-length dialogue with Foley without cutting the last spoken word."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "foley": ("AUDIO",),
            "dialogue": ("AUDIO",),
            "video_duration": ("FLOAT", {"default": 20.0, "min": 0.1}),
        }}

    RETURN_TYPES = ("AUDIO",)
    RETURN_NAMES = ("audio_mezclado",)
    FUNCTION = "mix"
    CATEGORY = "AUDIO_LAB"

    def mix(self, foley, dialogue, video_duration):
        import comfy.audio

        sr = int(foley["sample_rate"])
        if sr <= 0 or video_duration <= 0:
            raise ValueError("Frecuencia o duración de vídeo inválida.")
        samples = round(float(video_duration) * sr)
        fw = foley["waveform"].float().cpu()
        dw = dialogue["waveform"].float().cpu()
        if fw.ndim != 3 or dw.ndim != 3 or fw.shape[0] != 1 or dw.shape[0] != 1:
            raise ValueError("AUDIO_LAB necesita pistas de audio con un solo clip.")
        if int(dialogue["sample_rate"]) != sr:
            dw = comfy.audio.resample(dw, int(dialogue["sample_rate"]), sr)
        channels = max(fw.shape[1], dw.shape[1])
        if channels not in (1, 2):
            raise ValueError("Solo se permiten pistas mono o estéreo.")
        if fw.shape[1] == 1 and channels == 2:
            fw = fw.repeat(1, 2, 1)
        if dw.shape[1] == 1 and channels == 2:
            dw = dw.repeat(1, 2, 1)
        if dw.shape[-1] > samples:
            spill = dw[..., samples:]
            if spill.numel() and torch.max(torch.abs(spill)).item() > 1e-4:
                raise ValueError("La voz excede la duración del vídeo; no se recortará.")
        result = torch.zeros((1, channels, samples), dtype=torch.float32)
        fcount = min(samples, fw.shape[-1])
        dcount = min(samples, dw.shape[-1])
        result[..., :fcount] += fw[..., :fcount]
        result[..., :dcount] += dw[..., :dcount]
        peak = float(result.abs().max().item())
        if peak > 1:
            result /= peak
        return ({"waveform": result, "sample_rate": sr},)


NODE_CLASS_MAPPINGS["AudioLabSafeMix"] = AudioLabSafeMix
NODE_DISPLAY_NAME_MAPPINGS["AudioLabSafeMix"] = "AUDIO_LAB · Mezcla segura (sin recortar voz)"


class AudioLabLipSyncMuseTalk:
    """Selective two-person lip-sync via isolated MuseTalk 1.5, NOT a passthrough."""
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "images": ("IMAGE",),
            "fps": ("FLOAT", {"default": 25.0, "min": 1.0, "max": 240.0}),
            "timeline_json": ("STRING", {"forceInput": True}),
            "voice_a": ("AUDIO",),
            "voice_b": ("AUDIO",),
            "person_a_side": (["Left", "Right"], {"default": "Left"}),
        }}

    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("images_lipsynced",)
    FUNCTION = "render"
    CATEGORY = "AUDIO_LAB"

    def render(self, images, fps, timeline_json, voice_a, voice_b, person_a_side):
        from PIL import Image

        if images.ndim != 4 or images.shape[0] < 1 or images.shape[-1] != 3:
            raise ValueError("Lip-sync necesita una secuencia IMAGE RGB (N, H, W, 3).")
        if float(fps) <= 0:
            raise ValueError("FPS del vídeo inválidos.")
        try:
            plan = json.loads(timeline_json)
            turns = plan["turns"]
        except (ValueError, KeyError, TypeError) as exc:
            raise ValueError("Falta el plan de diálogos A/B.") from exc
        if not turns or any(t.get("speaker") not in ("A", "B") for t in turns):
            raise ValueError("El plan debe contener frases de los personajes A/B.")

        root = Path(__file__).resolve().parents[2] / "AudioLab" / "lipsync"
        engine = root / ".venv" / "Scripts" / "python.exe"
        worker = root / "lipsync_worker.py"
        repo = root / "MuseTalk"
        if not engine.is_file() or not worker.is_file() or not (repo / "scripts" / "inference.py").is_file():
            raise RuntimeError(
                "Falta el motor MuseTalk 1.5 aislado. AUDIO_LAB NO ha realizado "
                "lip-sync. Instala el motor en AudioLab/lipsync sin cambiar "
                "el Python de ComfyUI."
            )
        # Fail closed: always run an actual model and validate its outputs.
        with tempfile.TemporaryDirectory(prefix="al_comfy_lip_") as folder:
            work = Path(folder)
            input_dir, output_dir = work / "in", work / "out"
            input_dir.mkdir()
            output_dir.mkdir()
            for i, frame in enumerate(images):
                arr = (frame.detach().cpu().clamp(0, 1).numpy() * 255).round().astype("uint8")
                Image.fromarray(arr, "RGB").save(input_dir / f"{i:08d}.png")
            plan_path = work / "timeline.json"
            plan_path.write_text(timeline_json, encoding="utf-8")
            def write_wav(name, audio):
                sr = int(audio["sample_rate"])
                w = audio["waveform"]
                if w.ndim != 3 or w.shape[0] != 1 or sr <= 0:
                    raise ValueError(f"Pista {name} de voz inválida.")
                mono = w[0].float().mean(dim=0).detach().cpu().numpy()
                destination = work / f"{name}.wav"
                sf.write(str(destination), mono, sr, subtype="PCM_16")
                return destination
            file_a = write_wav("voice_a", voice_a)
            file_b = write_wav("voice_b", voice_b)
            command = [
                str(engine), str(worker),
                "--frames", str(input_dir),
                "--output", str(output_dir),
                "--timeline", str(plan_path),
                "--voice-a", str(file_a),
                "--voice-b", str(file_b),
                "--fps", str(fps),
                "--a-side", person_a_side.lower(),
                "--musetalk", str(repo)
            ]
            log = work / "lipsync.log"
            with open(log, "w", encoding="utf-8", errors="replace") as log_handle:
                try:
                    process = subprocess.run(
                        command, cwd=str(root), stdout=log_handle,
                        stderr=subprocess.STDOUT, timeout=14400,
                        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                except subprocess.TimeoutExpired as exc:
                    raise RuntimeError("MuseTalk superó el tiempo máximo de procesamiento.") from exc
            if process.returncode:
                msg = log.read_text(encoding="utf-8", errors="replace")[-6000:]
                raise RuntimeError("MuseTalk no completó el lip-sync:\n" + msg)
            done = sorted(output_dir.glob("*.png"))
            if len(done) != images.shape[0]:
                raise RuntimeError(
                    f"MuseTalk devolvió {len(done)} frames, "
                    f"esperábamos {images.shape[0]}. No se exportará el vídeo."
                )
            frames = []
            for path in done:
                with Image.open(path) as im:
                    arr = np.asarray(im.convert("RGB"), dtype="float32").copy() / 255.0
                frames.append(torch.from_numpy(arr))
            result = torch.stack(frames, dim=0)
            if result.shape != images.shape:
                raise RuntimeError("El lip-sync cambió resolución o número de frames.")
            return (result,)


NODE_CLASS_MAPPINGS["AudioLabLipSyncMuseTalk"] = AudioLabLipSyncMuseTalk
NODE_DISPLAY_NAME_MAPPINGS["AudioLabLipSyncMuseTalk"] = "AUDIO_LAB · Lip-sync A/B · MuseTalk 1.5"
