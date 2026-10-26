"""Image Lab's native ComfyUI controls.

Install this file at:
ComfyUI/custom_nodes/image_lab_selector/__init__.py
and restart ComfyUI. No extra dependencies.
"""

import nodes
import torch

OPTIONS = ("Z-Image", "FLUX", "Qwen", "Fotografía externa")
INDEX = {name: idx + 1 for idx, name in enumerate(OPTIONS)}


class ImageLabSourceSelector:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "fuente": (list(OPTIONS), {"default": "Qwen"}),
        }}

    RETURN_TYPES = ("INT",)
    RETURN_NAMES = ("fuente_numero",)
    FUNCTION = "select"
    CATEGORY = "Image Lab / Interno"

    def select(self, fuente):
        if fuente not in INDEX:
            raise ValueError(f"Image Lab: fuente desconocida: {fuente!r}")
        return (INDEX[fuente],)


class ImageLabInitialImage:
    """An image uploader with img2img and resolution toggles in one node."""

    EMPTY_IMAGE = "(sin imagen)"
    USE_IMAGE = "Usar imagen inicial"
    KEEP_SIZE = "Mantener resolución original"

    @classmethod
    def INPUT_TYPES(cls):
        # Reuse the native LoadImage file listing and upload widget.
        # The sentinel makes prompt-only mode usable without loading a file.
        native_image = nodes.LoadImage.INPUT_TYPES()["required"]["image"]
        images = [cls.EMPTY_IMAGE]
        images.extend(name for name in native_image[0] if name != cls.EMPTY_IMAGE)
        return {"required": {
            "image": (images, {"image_upload": True, "default": cls.EMPTY_IMAGE}),
            cls.USE_IMAGE: ("BOOLEAN", {"default": False}),
            cls.KEEP_SIZE: ("BOOLEAN", {"default": False}),
        }}

    RETURN_TYPES = ("IMAGE", "MASK", "BOOLEAN", "BOOLEAN")
    RETURN_NAMES = ("IMAGE", "MASK", "usar_imagen_inicial", "mantener_resolucion")
    FUNCTION = "load_with_settings"
    CATEGORY = "Image Lab"

    def load_with_settings(self, image, **settings):
        use_image = bool(settings[self.USE_IMAGE])
        keep_size = bool(settings[self.KEEP_SIZE])

        if use_image:
            if image in ("", self.EMPTY_IMAGE):
                raise ValueError("Image Lab: elige una foto o desactiva 'Usar imagen inicial'.")
            pixels, mask = nodes.LoadImage().load_image(image)
        else:
            # Placeholder: the internal txt2img switch will ignore this image.
            # Crucially, we don't try to open the input folder as a file.
            pixels = torch.zeros((1, 64, 64, 3), dtype=torch.float32)
            mask = torch.zeros((1, 64, 64), dtype=torch.float32)

        return (pixels, mask, use_image, keep_size)

    @classmethod
    def VALIDATE_INPUTS(cls, image, **settings):
        if not settings.get(cls.USE_IMAGE, False):
            return True
        if image in ("", cls.EMPTY_IMAGE):
            return "Image Lab: selecciona una foto para utilizar como imagen inicial."
        return nodes.LoadImage.VALIDATE_INPUTS(image)

    @classmethod
    def IS_CHANGED(cls, image, **settings):
        if not settings.get(cls.USE_IMAGE, False):
            return "imagen-inicial-desactivada"
        if image in ("", cls.EMPTY_IMAGE):
            return "imagen-inicial-no-seleccionada"
        return nodes.LoadImage.IS_CHANGED(image)


NODE_CLASS_MAPPINGS = {
    "ImageLabSourceSelector": ImageLabSourceSelector,
    "ImageLabInitialImage": ImageLabInitialImage,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "ImageLabSourceSelector": "Image Lab · Fuente",
    "ImageLabInitialImage": "Image Lab · Imagen inicial",
}
