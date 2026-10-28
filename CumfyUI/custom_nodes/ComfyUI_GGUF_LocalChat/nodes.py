"""Generador GGUF local para ComfyUI: modelo, prompt y salida de texto.
Solo arranca un llama-server; no instala ni descarga modelos.
"""
import atexit
import base64
import ctypes
from datetime import datetime
import json
import io
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
LLAMA_SERVER = ROOT / "tools" / "llama.cpp" / ("llama-server.exe" if os.name == "nt" else "llama-server")
MODELOS = {
    "Magnum v2 32B (Q4_K_M)": (ROOT / "models/llm/magnum-v2-32b/magnum-32b-v2-Q4_K_M.gguf", 32768),
    "Euryale 70B v2.1 (Q4_K_M)": (ROOT / "models/llm/euryale-70b/L3-70B-Euryale-v2.1-Q4_K_M.gguf", 8192),
    "Mistral 7B Instruct v0.3 (Q4_K_M)": (ROOT / "models/llm/mistral-7b-instruct-v0.3/Mistral-7B-Instruct-v0.3.Q4_K_M.gguf", 8192),
    "Lexi Llama 3 8B Uncensored (Q4_K_M)": (ROOT / "models/llm/lexi-llama-3-8b-uncensored/Lexi-Llama-3-8B-Uncensored-Q4_K_M.gguf", 8192),
    "Qwen2.5-VL 7B (Q4_K_M)": (ROOT / "models/llm/qwen2.5-vl-7b/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", 8192),
}

MM_PROJ = {
    "Qwen2.5-VL 7B (Q4_K_M)": ROOT / "models/llm/qwen2.5-vl-7b/mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf",
}
HOST = "127.0.0.1"
PORT = 18889
LOCK = threading.RLock()
STATE = {"process": None, "configuracion": None, "log": None, "externo_pid": None}
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
    """Detiene solamente el servidor propio o uno previamente identificado como propio."""
    proc = STATE["process"]
    externo_pid = STATE["externo_pid"]
    STATE["process"] = None
    STATE["externo_pid"] = None
    STATE["configuracion"] = None
    try:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=12)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        elif externo_pid is not None:
            actual = _instancia_en_puerto()
            if (actual and actual["pid"] == externo_pid
                    and _configuracion_instancia(actual) is not None):
                _terminar_instancia_externa(actual)
    finally:
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


def _instancia_en_puerto():
    """Inspecciona el proceso que escucha en nuestro puerto, sin instalar dependencias.

    Get-NetTCPConnection/Win32_Process se usan solamente cuando ya hay un
    servidor escuchando. Si no puede comprobarse su propietario, NO se detiene.
    """
    if os.name != "nt":
        return None
    ps = (
        "$t = Get-NetTCPConnection -LocalPort " + str(PORT)
        + " -State Listen -ErrorAction SilentlyContinue | "
        + "Where-Object { $_.LocalAddress -eq '127.0.0.1' } | Select-Object -First 1; "
        + "if ($t) { $p = Get-CimInstance Win32_Process "
        + "-Filter ('ProcessId=' + $t.OwningProcess) -ErrorAction SilentlyContinue; "
        + "if ($p) { [pscustomobject]@{"
        + "pid=[int]$p.ProcessId; executable=$p.ExecutablePath; "
        + "command=$p.CommandLine} | ConvertTo-Json -Compress } }"
    )
    try:
        r = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps],
            capture_output=True, text=True, timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("No se pudo identificar el proceso del puerto 18889: " + str(exc)) from exc
    if r.returncode != 0:
        raise RuntimeError("Error consultando el proceso del puerto 18889: " + r.stderr[-400:])
    if not r.stdout.strip():
        return None
    try:
        d = json.loads(r.stdout)
        return {"pid": int(d["pid"]), "executable": d.get("executable"),
                "command": d.get("command")}
    except (ValueError, TypeError, KeyError) as exc:
        raise RuntimeError("No se pudo interpretar el proceso del puerto 18889.") from exc


def _argumentos_windows(linea):
    """Divide la línea de comandos con las reglas reales de Windows."""
    if not linea or os.name != "nt":
        return []
    argc = ctypes.c_int()
    fn = ctypes.windll.shell32.CommandLineToArgvW
    fn.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
    fn.restype = ctypes.POINTER(ctypes.c_wchar_p)
    ptr = fn(linea, ctypes.byref(argc))
    if not ptr:
        return []
    try:
        return [ptr[i] for i in range(argc.value)]
    finally:
        free = ctypes.windll.kernel32.LocalFree
        free.argtypes = [ctypes.c_void_p]
        free.restype = ctypes.c_void_p
        free(ctypes.cast(ptr, ctypes.c_void_p))


def _configuracion_instancia(info):
    """Reconoce SOLO el llama-server exacto de este ComfyUI con estos GGUF."""
    if not info or not info.get("executable"):
        return None
    def norm(p):
        return os.path.normcase(os.path.abspath(p))
    if norm(info["executable"]) != norm(str(LLAMA_SERVER)):
        return None
    argv = _argumentos_windows(info.get("command"))
    try:
        def opcion(flag):
            i = argv.index(flag)
            return argv[i + 1]
        if opcion("--host") != HOST or int(opcion("--port")) != PORT:
            return None
        if int(opcion("--parallel")) != 1:
            return None
        ruta = norm(opcion("-m"))
        nombre = next((name for name, (file, _) in MODELOS.items()
                       if norm(str(file)) == ruta), None)
        if nombre is None:
            return None
        if nombre in MM_PROJ and norm(opcion("--mmproj")) != norm(str(MM_PROJ[nombre])):
            return None
        contexto = int(opcion("-c"))
        capas = int(opcion("-ngl"))
        return (nombre, contexto, capas)
    except (ValueError, IndexError, StopIteration, TypeError):
        return None


def _terminar_instancia_externa(info):
    """Comprueba de nuevo PID/ruta/argumentos antes de terminar el servidor."""
    actual = _instancia_en_puerto()
    if not actual:
        return
    if (actual["pid"] != info["pid"]
            or _configuracion_instancia(actual) is None):
        raise RuntimeError("El proceso del puerto 18889 ha cambiado: no se detiene.")
    r = subprocess.run(
        ["taskkill.exe", "/PID", str(info["pid"]), "/F"],
        capture_output=True, text=True, timeout=15,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if r.returncode != 0 and _puerto_ocupado():
        raise RuntimeError("No se pudo detener el llama-server antiguo: " + r.stderr[-400:])
    limite = time.monotonic() + 20
    while _puerto_ocupado() and time.monotonic() < limite:
        time.sleep(0.3)
    if _puerto_ocupado():
        raise RuntimeError("El puerto 18889 no se liberó tras detener llama-server.")


def _esperar_instancia_existente(info):
    """Espera que termine de cargar el servidor ya reconocido."""
    limite = time.monotonic() + 600
    while time.monotonic() < limite:
        if _salud():
            return
        if not _puerto_ocupado():
            raise RuntimeError("El llama-server anterior terminó durante la carga.")
        time.sleep(2)
    raise RuntimeError("El llama-server anterior no terminó de cargar en 10 minutos.")


def _iniciar(modelo, contexto_tokens, capas_gpu):
    gguf, contexto_nativo = MODELOS[modelo]
    contexto = contexto_nativo if contexto_tokens == 0 else contexto_tokens
    configuracion = (modelo, contexto, capas_gpu)
    if not gguf.is_file():
        raise RuntimeError(f"No existe el modelo GGUF: {gguf}")
    if not LLAMA_SERVER.is_file():
        raise RuntimeError(f"No existe llama-server.exe: {LLAMA_SERVER}")

    proc = STATE["process"]
    if proc and proc.poll() is None and STATE["configuracion"] == configuracion and _salud():
        return
    if (STATE["externo_pid"] is not None
            and STATE["configuracion"] == configuracion and _salud()):
        return
    _detener()  # Solo se detiene el servidor del modelo anterior.

    if _puerto_ocupado():
        anterior = _instancia_en_puerto()
        anterior_cfg = _configuracion_instancia(anterior)
        if anterior_cfg is None:
            desc = (f"PID {anterior['pid']}" if anterior else "proceso desconocido")
            raise RuntimeError(
                f"El puerto {PORT} pertenece a {desc}, pero no puedo verificar que "
                "sea el llama-server de este workflow. No se detiene por seguridad."
            )
        if anterior_cfg == configuracion:
            _esperar_instancia_existente(anterior)
            STATE.update(process=None, externo_pid=anterior["pid"],
                         configuracion=configuracion, log=None)
            return
        # Un modelo diferente, pero es nuestro ejecutable con nuestras rutas.
        _terminar_instancia_externa(anterior)

    OUTPUT.mkdir(parents=True, exist_ok=True)
    fh = LOG_PATH.open("w", encoding="utf-8")
    # Valores explícitos del usuario; 0 equivale al contexto nativo publicado.
    args = [str(LLAMA_SERVER), "-m", str(gguf), "--host", HOST,
            "--port", str(PORT), "-c", str(contexto), "-ngl", str(capas_gpu),
            "--parallel", "1"]
    if modelo in MM_PROJ:
        mmproj = MM_PROJ[modelo]
        if not mmproj.is_file():
            fh.close()
            raise RuntimeError(f"No existe el archivo mmproj de Qwen: {mmproj}")
        args.extend(["--mmproj", str(mmproj)])
    try:
        proc = subprocess.Popen(
            args, cwd=str(LLAMA_SERVER.parent), stdout=fh, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except Exception:
        fh.close()
        raise
    STATE.update(process=proc, externo_pid=None, configuracion=configuracion, log=fh)
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


def _responder(prompt, temperatura, max_tokens_salida, image=None):
    contenido = prompt
    if image is not None:
        # ComfyUI entrega IMAGE como tensor [batch, alto, ancho, canales], valores 0..1.
        frame = image[0].detach().cpu().numpy()
        frame = (frame * 255).clip(0, 255).astype("uint8")
        buffer = io.BytesIO()
        Image.fromarray(frame).convert("RGB").save(buffer, format="JPEG", quality=92)
        imagen_b64 = base64.b64encode(buffer.getvalue()).decode("ascii")
        contenido = [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + imagen_b64}},
        ]
    payload = {
        "messages": [{"role": "user", "content": contenido}],
        "temperature": temperatura, "top_p": 0.95,
        "max_tokens": max_tokens_salida, "stream": False,
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
            "modelo": ([nombre for nombre in MODELOS if nombre not in MM_PROJ],),
            "prompt": ("STRING", {"multiline": True, "default": ""}),
            "contexto_tokens": ("INT", {"default": 0, "min": 0, "max": 131072, "step": 512}),
            "temperatura": ("FLOAT", {"default": 0.8, "min": 0.0, "max": 2.0, "step": 0.05}),
            "max_tokens_salida": ("INT", {"default": 512, "min": 1, "max": 32768, "step": 128}),
            "capas_gpu": ("INT", {"default": 8, "min": 0, "max": 999}),
        }}

    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("respuesta",)
    FUNCTION = "generar"
    CATEGORY = "LLM / GGUF local"
    OUTPUT_NODE = True

    @classmethod
    def IS_CHANGED(cls, **kwargs):
        return float("nan")

    def generar(self, modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu, image=None):
        with LOCK:
            try:
                if not prompt.strip():
                    raise ValueError("El prompt está vacío.")
                if image is not None and modelo not in MM_PROJ:
                    raise ValueError("La entrada de imagen solo está disponible con Qwen2.5-VL 7B.")
                _iniciar(modelo, contexto_tokens, capas_gpu)
                texto = _responder(prompt, temperatura, max_tokens_salida, image=image)
                if texto.strip():
                    _guardar(texto)
                else:
                    texto = "[SIN TEXTO] El servidor terminó, pero devolvió una respuesta vacía. Revisa llama-server.log."
            except Exception as exc:
                texto = f"[ERROR DEL GENERADOR] {type(exc).__name__}: {exc}\n\nRegistro reciente de llama.cpp:\n{_registro()}"
            return {"ui": {"text": [texto]}, "result": (texto,)}


def _salir():
    # No hacer fallar la salida de Python si Windows ya ha cerrado el proceso.
    try:
        _detener()
    except Exception:
        pass


class GeneradorQwenVL(GeneradorLLM):
    @classmethod
    def INPUT_TYPES(cls):
        schema = super().INPUT_TYPES()
        schema["required"]["modelo"] = (["Qwen2.5-VL 7B (Q4_K_M)"],)
        # Qwen2.5-VL 7B Q4_K_M cabe holgadamente en una GPU de 12 GB;
        # 99 capas solicita descargar todas las capas disponibles.
        schema["required"]["capas_gpu"] = ("INT", {"default": 99, "min": 0, "max": 999})
        schema["optional"] = {"image": ("IMAGE",)}
        return schema

    def generar(self, modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu, image=None):
        if image is None:
            # Sin imagen se permite usar Qwen como modelo de texto, pero la entrada queda disponible.
            return super().generar(modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu)
        return super().generar(modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu, image=image)


atexit.register(_salir)
NODE_CLASS_MAPPINGS = {
    "GGUF_GeneradorLLM": GeneradorLLM,
    "GGUF_GeneradorQwenVL": GeneradorQwenVL,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "GGUF_GeneradorLLM": "GENERADOR LLM TEXTO · Magnum / Euryale / Mistral / Lexi",
    "GGUF_GeneradorQwenVL": "GENERADOR QWEN VL · Prompt + imagen",
}
