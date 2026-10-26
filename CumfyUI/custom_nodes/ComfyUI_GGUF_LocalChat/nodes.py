"""Generador GGUF local para ComfyUI: modelo, prompt y salida de texto.
Solo arranca un llama-server; no instala ni descarga modelos.
"""
import atexit
from datetime import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
LLAMA_SERVER = ROOT / "tools" / "llama.cpp" / ("llama-server.exe" if os.name == "nt" else "llama-server")
MODELOS = {
    "Magnum v2 32B (Q4_K_M)": (ROOT / "models/llm/magnum-v2-32b/magnum-32b-v2-Q4_K_M.gguf", 32768),
    "Euryale 70B v2.1 (Q4_K_M)": (ROOT / "models/llm/euryale-70b/L3-70B-Euryale-v2.1-Q4_K_M.gguf", 8192),
}
HOST = "127.0.0.1"
PORT = 18889
LOCK = threading.RLock()
STATE = {"process": None, "modelo": None, "log": None}
OUTPUT = ROOT / "output" / "gguf_chat"
LOG_PATH = OUTPUT / "llama-server.log"


def _registro():
    try:
        with LOG_PATH.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 5000))
            return fh.read().decode("utf-8", errors="replace")[-2500:]
    except OSError:
        return "No se ha creado todavía el registro de llama.cpp."


def _detener():
    proc = STATE["process"]
    STATE["process"] = None
    STATE["modelo"] = None
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=12)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    fh = STATE["log"]
    STATE["log"] = None
    if fh is not None:
        fh.close()


def _puerto_ocupado():
    try:
        with socket.create_connection((HOST, PORT), timeout=0.5):
            return True
    except OSError:
        return False


def _salud():
    try:
        with urllib.request.urlopen(f"http://{HOST}:{PORT}/health", timeout=3) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError, TimeoutError):
        return False


def _iniciar(modelo):
    gguf, contexto_nativo = MODELOS[modelo]
    if not gguf.is_file():
        raise RuntimeError(f"No existe el modelo GGUF: {gguf}")
    if not LLAMA_SERVER.is_file():
        raise RuntimeError(f"No existe llama-server.exe: {LLAMA_SERVER}")

    proc = STATE["process"]
    if proc and proc.poll() is None and STATE["modelo"] == modelo and _salud():
        return
    _detener()  # Nunca se mantienen Magnum y Euryale simultáneamente.
    if _puerto_ocupado():
        raise RuntimeError(
            f"El puerto {PORT} ya está ocupado, posiblemente por otro llama-server. "
            "Cierra la instancia antigua antes de ejecutar otra vez."
        )

    OUTPUT.mkdir(parents=True, exist_ok=True)
    fh = LOG_PATH.open("w", encoding="utf-8")
    # Parámetros iniciales documentados: contexto declarado por el GGUF,
    # 8 capas en GPU (estimación conservadora, NO optimizada).
    args = [str(LLAMA_SERVER), "-m", str(gguf), "--host", HOST,
            "--port", str(PORT), "-c", str(contexto_nativo), "-ngl", "8",
            "--parallel", "1"]
    try:
        proc = subprocess.Popen(
            args, cwd=str(LLAMA_SERVER.parent), stdout=fh, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except Exception:
        fh.close()
        raise
    STATE.update(process=proc, modelo=modelo, log=fh)
    plazo = time.monotonic() + 600
    while time.monotonic() < plazo:
        if proc.poll() is not None:
            details = _registro()
            _detener()
            raise RuntimeError("llama.cpp terminó durante la carga:\n" + details)
        if _salud():
            return
        time.sleep(1)
    details = _registro()
    _detener()
    raise RuntimeError("No terminó de cargar en 10 minutos:\n" + details)


def _responder(prompt):
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.8, "top_p": 0.95,
        "max_tokens": 2048, "stream": False,
    }
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/v1/chat/completions",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=1200) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        info = exc.read().decode("utf-8", errors="replace")[:2000]
        raise RuntimeError(f"llama-server respondió HTTP {exc.code}: {info}") from exc
    try:
        answer = result["choices"][0]["message"]["content"]
        if not isinstance(answer, str):
            raise TypeError("Respuesta no textual")
        return answer
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError("Respuesta inesperada de llama.cpp: " + str(result)[:1200]) from exc


def _guardar(texto):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    name = f"generador_llm_{datetime.now():%Y%m%d_%H%M%S}_{uuid.uuid4().hex[:6]}.txt"
    (OUTPUT / name).write_text(texto, encoding="utf-8")


class GeneradorLLM:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "modelo": (list(MODELOS.keys()),),
            "prompt": ("STRING", {"multiline": True, "default": "Hola, ¿estás ahí?"}),
        }}

    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("respuesta",)
    FUNCTION = "generar"
    CATEGORY = "LLM / GGUF local"
    OUTPUT_NODE = True

    @classmethod
    def IS_CHANGED(cls, **kwargs):
        return float("nan")

    def generar(self, modelo, prompt):
        with LOCK:
            try:
                if not prompt.strip():
                    raise ValueError("El prompt está vacío.")
                _iniciar(modelo)
                texto = _responder(prompt)
                if texto.strip():
                    _guardar(texto)
                else:
                    texto = "[SIN TEXTO] El servidor terminó, pero devolvió una respuesta vacía. Revisa llama-server.log."
            except Exception as exc:
                texto = f"[ERROR DEL GENERADOR] {type(exc).__name__}: {exc}\n\nRegistro reciente de llama.cpp:\n{_registro()}"
            return {"ui": {"text": [texto]}, "result": (texto,)}


atexit.register(_detener)
NODE_CLASS_MAPPINGS = {"GGUF_GeneradorLLM": GeneradorLLM}
NODE_DISPLAY_NAME_MAPPINGS = {"GGUF_GeneradorLLM": "GENERADOR LLM · Magnum / Euryale"}
