"""Image Lab: a single user-facing control for ComfyUI Portable.
Requires Pillow, numpy, torch and folder_paths, already bundled with ComfyUI.
"""
import os
import numpy as np
import torch
from PIL import Image, ImageOps
import folder_paths

EMPTY = "(ninguna)"
MODELS = ("Qwen · Editar imagen", "Z-Image Turbo · Generar", "FLUX.1 Dev · Generar", "Solo refinar fotografía")

class ImageLabPanel:
    @classmethod
    def INPUT_TYPES(cls):
        root = folder_paths.get_input_directory()
        files = sorted(name for name in os.listdir(root) if os.path.isfile(os.path.join(root, name)))
        images = [EMPTY] + files
        upload = {"image_upload": True, "default": EMPTY}
        return {"required": {
            "modelo": (list(MODELS), {"default": MODELS[0]}),
            "imagen_base": (images, upload),
            "referencia_2": (images, upload),
            "referencia_3": (images, upload),
            "foto_externa": (images, upload),
            "prompt": ("STRING", {"multiline": True, "default": ""}),
            "ancho": ("INT", {"default": 1024, "min": 64, "max": 4096, "step": 64}),
            "alto": ("INT", {"default": 1024, "min": 64, "max": 4096, "step": 64}),
            "semilla": ("INT", {"default": 123456789, "min": 0, "max": 0xffffffffffffffff, "control_after_generate": True}),
        }}
    RETURN_TYPES = ("IMAGE_LAB_CONTEXT",)
    RETURN_NAMES = ("configuracion",)
    FUNCTION = "prepare"
    CATEGORY = "Image Lab"

    @classmethod
    def IS_CHANGED(cls, **kwargs):
        return float("nan")

    def _load(self, filename):
        if filename == EMPTY:
            return None, None
        path = folder_paths.get_annotated_filepath(filename)
        if not os.path.isfile(path):
            raise ValueError("No se encuentra la imagen: " + str(filename))
        with Image.open(path) as source:
            frame = ImageOps.exif_transpose(source)
            rgb = frame.convert("RGB")
            image = torch.from_numpy(np.asarray(rgb, dtype=np.float32) / 255.0)[None,]
            if "A" in frame.getbands():
                alpha = np.asarray(frame.getchannel("A"), dtype=np.float32) / 255.0
                mask = torch.from_numpy(1.0 - alpha)[None,]
            else:
                mask = torch.zeros((1, rgb.height, rgb.width), dtype=torch.float32)
        return image, mask

    def prepare(self, modelo, imagen_base, referencia_2, referencia_3,
                foto_externa, prompt, ancho, alto, semilla):
        if modelo == MODELS[0] and imagen_base == EMPTY:
            raise ValueError("Image Lab: para editar con Qwen, carga una IMAGEN BASE.")
        if modelo == MODELS[3] and foto_externa == EMPTY:
            raise ValueError("Image Lab: en SOLO REFINAR, carga una FOTO EXTERNA.")
        primary, _ = self._load(imagen_base if modelo == MODELS[0] else EMPTY)
        ref2, _ = self._load(referencia_2 if modelo == MODELS[0] else EMPTY)
        ref3, _ = self._load(referencia_3 if modelo == MODELS[0] else EMPTY)
        external, external_mask = self._load(foto_externa if modelo == MODELS[3] else EMPTY)
        context = (
            primary, ref2, ref3, external, external_mask,
            prompt, ancho, alto, semilla,
            modelo in (MODELS[1], MODELS[2]),
            modelo == MODELS[2],
            modelo == MODELS[3],
            ref2 is not None,
            ref3 is not None,
        )
        return (context,)

class ImageLabUnpack:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"context": ("IMAGE_LAB_CONTEXT",)}}
    RETURN_TYPES = ("IMAGE", "IMAGE", "IMAGE", "IMAGE", "MASK", "STRING", "INT", "INT", "INT", "BOOLEAN", "BOOLEAN", "BOOLEAN", "BOOLEAN", "BOOLEAN")
    FUNCTION = "unpack"
    CATEGORY = "Image Lab / Interno"

    def unpack(self, context):
        if len(context) != len(self.RETURN_TYPES):
            raise ValueError("Image Lab: configuración incompleta")
        return tuple(context)

NODE_CLASS_MAPPINGS = {"ImageLabPanel": ImageLabPanel, "ImageLabUnpack": ImageLabUnpack}
NODE_DISPLAY_NAME_MAPPINGS = {"ImageLabPanel": "IMAGE LAB · Panel principal", "ImageLabUnpack": "Image Lab · Desempaquetador interno"}
