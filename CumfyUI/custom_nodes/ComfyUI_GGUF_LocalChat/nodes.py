"""Integración local ComfyUI -> llama-server GGUF; un modelo a la vez.
Requiere llama.cpp y los GGUF ya instalados bajo la raíz de ComfyUI.
Sin dependencias de pip ni ComfyUI Manager.
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
EXE = ROOT / "tools" / "llama.cpp" / ("llama-server.exe" if os.name == "nt" else "llama-server")
MODELOS = {
    "Magnum v2 32B (Q4_K_M)": (ROOT / "models/llm/magnum-v2-32b/magnum-32b-v2-Q4_K_M.gguf", 32768),
    "Euryale 70B v2.1 (Q4_K_M)": (ROOT / "models/llm/euryale-70b/L3-70B-Euryale-v2.1-Q4_K_M.gguf", 8192),
}
HOST, PORT = "127.0.0.1", 18889
LOCK = threading.RLock()
STATE = {"process": None, "settings": None, "log": None}
LOG_PATH = ROOT / "output/gguf_chat/llama-server.log"


def _tail():
    try:
        with LOG_PATH.open("rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 7000))
            return f.read().decode("utf-8", errors="replace")[-3500:]
    except OSError:
        return "(sin registro todavía)"


def _stop():
    p = STATE["process"]
    STATE["process"] = None
    STATE["settings"] = None
    if p is not None and p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=5)
    logfile = STATE["log"]
    STATE["log"] = None
    if logfile is not None:
        logfile.close()


def _busy():
    try:
        with socket.create_connection((HOST, PORT), timeout=0.3):
            return True
    except OSError:
        return False


def _ready():
    try:
        with urllib.request.urlopen("http://%s:%s/health" % (HOST, PORT), timeout=2) as response:
            return response.status == 200
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, TimeoutError):
        return False


def _start(modelo, contexto_tokens, capas_gpu, flash_attention, cache_kv):
    ruta, nativo = MODELOS[modelo]
    if not ruta.is_file():
        raise RuntimeError("Falta GGUF: " + str(ruta))
    if not EXE.is_file():
        raise RuntimeError("Falta llama-server: " + str(EXE))
    contexto = nativo if contexto_tokens == 0 else int(contexto_tokens)
    clave = (str(ruta), contexto, capas_gpu, flash_attention, cache_kv)
    proceso = STATE["process"]
    if proceso and proceso.poll() is None and STATE["settings"] == clave and _ready():
        return
    _stop()  # libera el anterior antes de cargar otro
    if _busy():
        raise RuntimeError("Puerto local 18889 ocupado. No se reutilizan servidores desconocidos.")
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    logfile = LOG_PATH.open("w", encoding="utf-8")
    args = [str(EXE), "-m", str(ruta), "--host", HOST, "--port", str(PORT),
            "-c", str(contexto), "-ngl", str(capas_gpu), "--parallel", "1"]
    if flash_attention:
        args += ["--flash-attn", "on"]
    if cache_kv == "q8_0":
        args += ["--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
    try:
        proceso = subprocess.Popen(args, cwd=str(EXE.parent), stdout=logfile,
                                   stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except Exception:
        logfile.close()
        raise
    STATE.update(process=proceso, settings=clave, log=logfile)
    limite = time.monotonic() + 600
    while time.monotonic() < limite:
        if proceso.poll() is not None:
            error = _tail()
            _stop()
            raise RuntimeError("llama-server terminó al cargar el modelo:\n" + error)
        if _ready():
            return
        time.sleep(1)
    error = _tail()
    _stop()
    raise RuntimeError("Carga superior a 600 segundos:\n" + error)


def _generar(instrucciones, prompt, temperatura, top_p, max_tokens_salida, semilla):
    payload = {
        "model": "local",
        "messages": [{"role": "system", "content": instrucciones},
                     {"role": "user", "content": prompt}],
        "temperature": temperatura,
        "top_p": top_p,
        "max_tokens": max_tokens_salida,
        "seed": semilla,
        "stream": False,
    }
    req = urllib.request.Request(
        "http://%s:%s/v1/chat/completions" % (HOST, PORT),
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=1200) as response:
            data = json.load(response)
    except urllib.error.HTTPError as e:
        raise RuntimeError("Error HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:2500])) from e
    except Exception as e:
        raise RuntimeError("Error comunicando con llama.cpp: %s\n%s" % (e, _tail())) from e
    try:
        return data["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError) as e:
        raise RuntimeError("Respuesta inesperada de llama.cpp: " + str(data)[:1200]) from e


class GGUFLocalAdvanced:
    """Opciones de carga y memoria; separadas de los controles de generación."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "contexto_tokens": ("INT", {"default": 0, "min": 0, "max": 131072, "step": 512}),
            "capas_gpu": ("INT", {"default": 8, "min": 0, "max": 999}),
            "flash_attention": ("BOOLEAN", {"default": False}),
            "cache_kv": (["f16", "q8_0"],),
            "semilla": ("INT", {"default": -1, "min": -1, "max": 2147483647}),
        }}
    RETURN_TYPES = ("GGUF_CONFIG",)
    RETURN_NAMES = ("configuracion",)
    CATEGORY = "LLM / GGUF local"
    FUNCTION = "build"

    def build(self, contexto_tokens, capas_gpu, flash_attention, cache_kv, semilla):
        return ({
            "contexto_tokens": contexto_tokens,
            "capas_gpu": capas_gpu,
            "flash_attention": flash_attention,
            "cache_kv": cache_kv,
            "semilla": semilla,
        },)


class GGUFLocalAuto:
    """El nodo principal solo presenta controles cotidianos.
    Las opciones de memoria son un conector opcional a GGUFLocalAdvanced.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "modelo": (list(MODELOS),),
                "instrucciones": ("STRING", {"multiline": True, "default": "Responde en español."}),
                "prompt": ("STRING", {"multiline": True, "default": "Escribe tu solicitud."}),
                "temperatura": ("FLOAT", {"default": 0.8, "min": 0.0, "max": 2.0, "step": 0.05}),
                "top_p": ("FLOAT", {"default": 0.95, "min": 0.01, "max": 1.0, "step": 0.01}),
                "max_tokens_salida": ("INT", {"default": 2048, "min": 1, "max": 32768, "step": 128}),
            },
            "optional": {"configuracion": ("GGUF_CONFIG",)},
        }
    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("texto",)
    CATEGORY = "LLM / GGUF local"
    FUNCTION = "execute"
    OUTPUT_NODE = True

    @classmethod
    def IS_CHANGED(cls, **kwargs):
        return float("nan")

    def execute(self, modelo, instrucciones, prompt, temperatura, top_p,
                max_tokens_salida, configuracion=None):
        defaults = {
            "contexto_tokens": 0,  # 0 = contexto nativo definido en MODELOS
            "capas_gpu": 8,       # conservador, NO optimizado para esta GPU
            "flash_attention": False,
            "cache_kv": "f16",
            "semilla": -1,
        }
        if configuracion is not None:
            defaults.update(configuracion)
        with LOCK:
            _start(modelo, defaults["contexto_tokens"], defaults["capas_gpu"],
                   defaults["flash_attention"], defaults["cache_kv"])
            texto = _generar(instrucciones, prompt, temperatura, top_p,
                             max_tokens_salida, defaults["semilla"])
            return {"ui": {"text": [texto]}, "result": (texto,)}


class GGUFLocalSaveText:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "texto": ("STRING", {"forceInput": True}),
            "prefijo": ("STRING", {"default": "generato_llm"}),
        }}
    RETURN_TYPES = ()
    FUNCTION = "save"
    CATEGORY = "LLM / GGUF local"
    OUTPUT_NODE = True

    def save(self, texto, prefijo):
        # Evita guardar TXT al liberar el modelo (respuesta vacía).
        if not texto or not texto.strip():
            return {"ui": {"text": ["No se ha guardado ningún TXT: no hay texto generado."]}}
        carpeta = ROOT / "output/gguf_chat"
        carpeta.mkdir(parents=True, exist_ok=True)
        nombre = "".join(c for c in prefijo if c.isalnum() or c in "_-")[:45] or "generato_llm"
        archivo = carpeta / ("%s_%s_%s.txt" % (nombre, datetime.now().strftime("%Y%m%d_%H%M%S"), uuid.uuid4().hex[:6]))
        archivo.write_text(texto, encoding="utf-8")
        return {"ui": {"text": [texto]}}


atexit.register(_stop)
NODE_CLASS_MAPPINGS = {
    "GGUF_ConfigAvanzada": GGUFLocalAdvanced,
    "GGUF_LocalChatAuto": GGUFLocalAuto,
    "GGUF_SaveTextAuto": GGUFLocalSaveText,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "GGUF_ConfigAvanzada": "LLM · Configuración avanzada (opcional)",
    "GGUF_LocalChatAuto": "GGUF Local · Magnum / Euryale (autoinicio)",
    "GGUF_SaveTextAuto": "GGUF Local · Guardar TXT",
}
