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
    # Los modelos ligeros aparecen primero porque son los recomendados para 12 GB de VRAM.
    "Lexi Llama 3 8B Uncensored (Q4_K_M)": (ROOT / "models/llm/lexi-llama-3-8b-uncensored/Lexi-Llama-3-8B-Uncensored-Q4_K_M.gguf", 8192),
    "Mistral 7B Instruct v0.3 (Q4_K_M)": (ROOT / "models/llm/mistral-7b-instruct-v0.3/Mistral-7B-Instruct-v0.3.Q4_K_M.gguf", 8192),
    "Magnum v2 32B (Q4_K_M)": (ROOT / "models/llm/magnum-v2-32b/magnum-32b-v2-Q4_K_M.gguf", 32768),
    "Euryale 70B v2.1 (Q4_K_M)": (ROOT / "models/llm/euryale-70b/L3-70B-Euryale-v2.1-Q4_K_M.gguf", 8192),
    "Qwen2.5-VL 7B (Q4_K_M)": (ROOT / "models/llm/qwen2.5-vl-7b/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", 8192),
    "Qwen2.5-VL 7B Uncensored (Q4_K_M)": (ROOT / "models/llm/qwen2.5-vl-7b-abliterated/Qwen2.5-VL-7B-Instruct-abliterated.Q4_K_M.gguf", 8192),
}

MM_PROJ = {
    "Qwen2.5-VL 7B (Q4_K_M)": ROOT / "models/llm/qwen2.5-vl-7b/mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf",
    "Qwen2.5-VL 7B Uncensored (Q4_K_M)": ROOT / "models/llm/qwen2.5-vl-7b-abliterated/Qwen2.5-VL-7B-Instruct-abliterated.mmproj-Q8_0.gguf",
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
            "contexto_tokens": ("INT", {"default": 4096, "min": 0, "max": 131072, "step": 512}),
            "temperatura": ("FLOAT", {"default": 0.7, "min": 0.0, "max": 2.0, "step": 0.05}),
            "max_tokens_salida": ("INT", {"default": 1024, "min": 1, "max": 32768, "step": 128}),
            # Con Lexi 8B como modelo predeterminado, solicitamos todas las capas en GPU.
            # Magnum 32B y Euryale 70B requieren reducir este valor en equipos de 12 GB.
            "capas_gpu": ("INT", {"default": 99, "min": 0, "max": 999}),
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
        schema["required"]["modelo"] = (["Qwen2.5-VL 7B Uncensored (Q4_K_M)"],)
        schema["required"]["contexto_tokens"] = ("INT", {"default": 4096, "min": 0, "max": 131072, "step": 512})
        schema["required"]["temperatura"] = ("FLOAT", {"default": 0.3, "min": 0.0, "max": 2.0, "step": 0.05})
        schema["required"]["max_tokens_salida"] = ("INT", {"default": 2048, "min": 1, "max": 32768, "step": 128})
        # Qwen VL 7B Q4_K_M + mmproj Q8_0: solicita todas las capas en la GPU.
        schema["required"]["capas_gpu"] = ("INT", {"default": 99, "min": 0, "max": 999})
        schema["optional"] = {"image": ("IMAGE",)}
        return schema

    def generar(self, modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu, image=None):
        if image is None:
            # Sin imagen se permite usar Qwen como modelo de texto, pero la entrada queda disponible.
            return super().generar(modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu)
        return super().generar(modelo, prompt, contexto_tokens, temperatura, max_tokens_salida, capas_gpu, image=image)



class ImageLabFinalizerSingleInput:
    """Finalizador de Image Lab con una única entrada IMAGE."""

    @classmethod
    def INPUT_TYPES(cls):
        import folder_paths
        modelos = folder_paths.get_filename_list("upscale_models")
        if not modelos:
            modelos = ["4xNomos2_hq_dat2.pth"]
        return {"required": {
            "image": ("IMAGE",),
            "value": ("INT", {"default": 2, "min": 2, "max": 4, "step": 1}),
            "model_name": (modelos,),
            "value_1": ("BOOLEAN", {"default": False}),
            "value_2": ("BOOLEAN", {"default": False}),
            "filename_prefix": ("STRING", {"default": "image_lab/final/resultado"}),
        }}

    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("image",)
    FUNCTION = "process"
    CATEGORY = "Image Lab"
    OUTPUT_NODE = True

    @staticmethod
    def _first_output(value):
        # Admite tanto los nodos legacy (tuplas) como NodeOutput de ComfyUI reciente.
        for _ in range(4):
            if hasattr(value, "result"):
                value = value.result
                continue
            if isinstance(value, dict) and "result" in value:
                value = value["result"]
                continue
            if isinstance(value, (tuple, list)):
                if not value:
                    raise RuntimeError("Un nodo interno de ComfyUI devolvió una salida vacía.")
                value = value[0]
                continue
            break
        return value

    @classmethod
    def _upscale(cls, image, model_name, scale):
        import torch.nn.functional as F
        import nodes as comfy_nodes

        mappings = getattr(comfy_nodes, "NODE_CLASS_MAPPINGS", {})
        loader_cls = mappings.get("UpscaleModelLoader")
        upscale_cls = mappings.get("ImageUpscaleWithModel")
        if loader_cls is None or upscale_cls is None:
            raise RuntimeError("No están disponibles los nodos integrados UpscaleModelLoader e ImageUpscaleWithModel.")
        model = cls._first_output(loader_cls().load_model(model_name))
        enlarged = cls._first_output(upscale_cls().upscale(model, image))
        target_h = int(image.shape[1]) * int(scale)
        target_w = int(image.shape[2]) * int(scale)
        if int(enlarged.shape[1]) != target_h or int(enlarged.shape[2]) != target_w:
            enlarged = F.interpolate(
                enlarged.movedim(-1, 1),
                size=(target_h, target_w),
                mode="bicubic",
                align_corners=False,
            ).movedim(1, -1).clamp(0.0, 1.0)
        return enlarged

    @staticmethod
    def _remove_background(image):
        import numpy as np
        import torch
        try:
            from rembg import remove
        except ImportError as exc:
            raise RuntimeError(
                "La opción 'Quitar fondo' requiere el paquete Python rembg en el entorno de ComfyUI."
            ) from exc

        frames = []
        for frame in image.detach().cpu().clamp(0, 1).numpy():
            array = (frame * 255.0).round().astype("uint8")
            pil_image = Image.fromarray(array).convert("RGBA")
            result = remove(pil_image)
            if not isinstance(result, Image.Image):
                result = Image.open(io.BytesIO(result))
            result = result.convert("RGBA")
            frames.append(torch.from_numpy(np.asarray(result).copy()).float() / 255.0)
        return torch.stack(frames).to(image.device)

    @staticmethod
    def _save_png(image, filename_prefix):
        import numpy as np
        import folder_paths

        output_root = Path(folder_paths.get_output_directory()).resolve()
        prefix = str(filename_prefix or "image_lab/final/resultado").replace("\\", "/")
        parts = [part for part in prefix.split("/") if part not in ("", ".", "..")]
        if not parts:
            parts = ["resultado"]
        filename_base = parts[-1]
        subfolder_parts = parts[:-1]
        output_folder = output_root.joinpath(*subfolder_parts).resolve()
        if output_root not in output_folder.parents and output_folder != output_root:
            raise RuntimeError("La ruta de guardado sale de la carpeta output.")
        output_folder.mkdir(parents=True, exist_ok=True)
        relative_subfolder = "/".join(subfolder_parts)

        images_ui = []
        frames = image.detach().cpu().clamp(0, 1).numpy()
        for frame in frames:
            array = (frame * 255.0).round().astype("uint8")
            if array.shape[-1] == 1:
                array = array[..., 0]
            pil_image = Image.fromarray(array)
            index = 1
            while True:
                filename = f"{filename_base}_{index:05d}.png"
                target = output_folder / filename
                if not target.exists():
                    break
                index += 1
            pil_image.save(target, format="PNG")
            images_ui.append({
                "filename": filename,
                "subfolder": relative_subfolder,
                "type": "output",
            })
        return images_ui

    def process(self, image, value, model_name, value_1, value_2, filename_prefix):
        processed = image
        if value_1:
            processed = self._upscale(processed, model_name, value)
        if value_2:
            processed = self._remove_background(processed)
        images = self._save_png(processed, filename_prefix)
        return {"ui": {"images": images}, "result": (processed,)}




class ImageLabInitialImageOptional:
    """Cargador Image Lab que acepta no seleccionar imagen en ramas inactivas."""

    @classmethod
    def INPUT_TYPES(cls):
        import folder_paths
        available = sorted(folder_paths.get_filename_list("input"))
        choices = ["(sin imagen)"] + [name for name in available if name != "(sin imagen)"]
        return {"required": {
            "image": (choices, {"image_upload": True}),
            "Usar imagen inicial": ("BOOLEAN", {"default": False}),
            "Mantener resolución original": ("BOOLEAN", {"default": True}),
            "Transformación (%)": ("INT", {"default": 0, "min": 0, "max": 100, "step": 1}),
        }}

    RETURN_TYPES = ("IMAGE", "MASK", "BOOLEAN", "BOOLEAN", "INT")
    RETURN_NAMES = ("IMAGE", "MASK", "usar_imagen_inicial", "mantener_resolucion", "transformacion_pct")
    FUNCTION = "load"
    CATEGORY = "Image Lab"

    @classmethod
    def VALIDATE_INPUTS(cls, image, **kwargs):
        # The sentinel is intentional: an unused branch must remain valid with no image.
        if image in (None, "", "(sin imagen)"):
            return True
        import folder_paths
        if image not in folder_paths.get_filename_list("input"):
            return f"La imagen '{image}' no está en la carpeta input de ComfyUI."
        return True

    def load(self, image, **kwargs):
        import numpy as np
        import torch
        import folder_paths
        from PIL import ImageOps

        use_initial = bool(kwargs.get("Usar imagen inicial", False))
        keep_resolution = bool(kwargs.get("Mantener resolución original", True))
        transform_pct = int(kwargs.get("Transformación (%)", 0) or 0)

        if image in (None, "", "(sin imagen)"):
            if use_initial:
                raise RuntimeError("Esta rama requiere una imagen inicial. Selecciona una imagen o desactiva 'Usar imagen inicial'.")
            # Placeholder valid only when a branch explicitly disables image-to-image.
            blank = torch.zeros((1, 64, 64, 3), dtype=torch.float32)
            mask = torch.zeros((1, 64, 64), dtype=torch.float32)
            return (blank, mask, use_initial, keep_resolution, transform_pct)

        path = folder_paths.get_annotated_filepath(image)
        if not folder_paths.exists_annotated_filepath(image):
            raise FileNotFoundError(f"No existe la imagen de entrada: {image}")
        with Image.open(path) as opened:
            pil = ImageOps.exif_transpose(opened).copy()

        if "A" in pil.getbands():
            rgba = pil.convert("RGBA")
            arr = np.asarray(rgba, dtype=np.float32) / 255.0
            rgb = arr[..., :3]
            # ComfyUI mask convention: transparent pixels are 1.
            alpha_mask = 1.0 - arr[..., 3]
            mask = torch.from_numpy(alpha_mask.copy()).float().unsqueeze(0)
        else:
            rgb = np.asarray(pil.convert("RGB"), dtype=np.float32) / 255.0
            mask = torch.zeros((1, rgb.shape[0], rgb.shape[1]), dtype=torch.float32)

        image_tensor = torch.from_numpy(np.asarray(rgb).copy()).float().unsqueeze(0)
        return (image_tensor, mask, use_initial, keep_resolution, transform_pct)


class ImageLabBranchHub:
    """Nodo maestro de Image Lab: cuatro entradas y cuatro salidas pass-through."""

    INPUT_NAMES = ("qwen_image", "z_image", "flux_image", "external_image")
    OUTPUT_NAMES = ("QWEN", "Z-IMAGE", "FLUX", "FOTO EXTERNA")

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "optional": {
                "qwen_image": ("IMAGE", {"lazy": True}),
                "z_image": ("IMAGE", {"lazy": True}),
                "flux_image": ("IMAGE", {"lazy": True}),
                "external_image": ("IMAGE", {"lazy": True}),
            },
            "hidden": {
                "prompt": "PROMPT",
                "unique_id": "UNIQUE_ID",
            },
        }

    RETURN_TYPES = ("IMAGE", "IMAGE", "IMAGE", "IMAGE")
    RETURN_NAMES = OUTPUT_NAMES
    FUNCTION = "pasar"
    CATEGORY = "Image Lab"
    OUTPUT_NODE = False

    @classmethod
    def _connected_outputs(cls, prompt, unique_id):
        """Encuentra qué outputs del nodo están conectados a otros nodos del workflow."""
        connected = set()
        if not isinstance(prompt, dict):
            return connected
        current_id = str(unique_id)
        for node in prompt.values():
            if not isinstance(node, dict):
                continue
            inputs = node.get("inputs", {})
            if not isinstance(inputs, dict):
                continue
            for value in inputs.values():
                if not isinstance(value, (tuple, list)) or len(value) != 2:
                    continue
                if str(value[0]) != current_id:
                    continue
                try:
                    output_index = int(value[1])
                except (TypeError, ValueError):
                    continue
                if 0 <= output_index < 4:
                    connected.add(output_index)
        return connected

    def check_lazy_status(self, prompt=None, unique_id=None,
                          qwen_image=None, z_image=None, flux_image=None,
                          external_image=None):
        values = {
            "qwen_image": qwen_image,
            "z_image": z_image,
            "flux_image": flux_image,
            "external_image": external_image,
        }
        needed = []
        for output_index in self._connected_outputs(prompt, unique_id):
            input_name = self.INPUT_NAMES[output_index]
            if values[input_name] is None:
                needed.append(input_name)
        return needed

    def pasar(self, qwen_image=None, z_image=None, flux_image=None,
              external_image=None, prompt=None, unique_id=None):
        # Cada salida corresponde únicamente a su entrada. Las ramas no conectadas
        # downstream permanecen lazy y no se evalúan.
        return (qwen_image, z_image, flux_image, external_image)


atexit.register(_salir)
NODE_CLASS_MAPPINGS = {
    "GGUF_GeneradorLLM": GeneradorLLM,
    "GGUF_GeneradorQwenVL": GeneradorQwenVL,
    "ImageLabFinalizerSingleInput": ImageLabFinalizerSingleInput,
    "ImageLabBranchHub": ImageLabBranchHub,
    "ImageLabInitialImageOptional": ImageLabInitialImageOptional,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "GGUF_GeneradorLLM": "GENERADOR LLM TEXTO · Magnum / Euryale / Mistral / Lexi",
    "GGUF_GeneradorQwenVL": "GENERADOR QWEN VL ABLITERATED · Prompt + imagen",
    "ImageLabFinalizerSingleInput": "SALIDA Y ACABADO · Una sola entrada de imagen",
    "ImageLabBranchHub": "NODO MAESTRO · Qwen / Z-Image / FLUX / Foto externa",
    "ImageLabInitialImageOptional": "Imagen inicial · Opcional",
}
