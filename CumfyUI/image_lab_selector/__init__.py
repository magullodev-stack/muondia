"""Image Lab's native ComfyUI controls.

Install this file at:
ComfyUI/custom_nodes/image_lab_selector/__init__.py
and restart ComfyUI. No extra dependencies.
"""

import nodes
import torch

OPTIONS = ("Z-Image Turbo", "Z-Image Base", "FLUX", "Qwen", "Kontext (con máscara)", "Kontext (sin máscara)", "Fotografía externa")
# Números fijos: el subgrafo «Salida y acabado» compara con ellos (1, 2, 4 y 5).
INDEX = {"Z-Image Turbo": 1, "FLUX": 2, "Qwen": 3, "Fotografía externa": 4, "Z-Image Base": 5, "Kontext (con máscara)": 6, "Kontext (sin máscara)": 7}

# Opciones de cada workflow. Comparten INDEX, así que el número de fuente es el mismo.
OPTIONS_GENERACION = ("Z-Image Turbo", "Z-Image Base", "FLUX", "Fotografía externa")
OPTIONS_EDICION = ("Qwen", "Kontext (con máscara)", "Kontext (sin máscara)")


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


class ImageLabSourceSelectorGeneracion(ImageLabSourceSelector):
    """Fuente para image_lab_generacion.json: Z-Image Turbo, Z-Image Base, FLUX o fotografía externa."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "fuente": (list(OPTIONS_GENERACION), {"default": "FLUX"}),
        }}

    def select(self, fuente):
        if fuente not in OPTIONS_GENERACION:
            raise ValueError(f"Image Lab: fuente desconocida: {fuente!r}")
        return (INDEX[fuente],)


class ImageLabSourceSelectorEdicion(ImageLabSourceSelector):
    """Fuente para image_lab_edicion.json: Qwen, Kontext con máscara o Kontext sin máscara."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "fuente": (list(OPTIONS_EDICION), {"default": "Qwen"}),
        }}

    def select(self, fuente):
        if fuente not in OPTIONS_EDICION:
            raise ValueError(f"Image Lab: fuente desconocida: {fuente!r}")
        return (INDEX[fuente],)


class ImageLabBackgroundSelector:
    """Método para quitar fondo en «Salida y acabado».

    Devuelve True si hay que usar BEN2 y False para BiRefNet HR matting.
    """

    METHODS = ("BiRefNet HR matting", "BEN2")

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "metodo": (list(cls.METHODS), {"default": cls.METHODS[0]}),
        }}

    RETURN_TYPES = ("BOOLEAN",)
    RETURN_NAMES = ("usar_ben2",)
    FUNCTION = "select"
    CATEGORY = "Image Lab / Interno"

    def select(self, metodo):
        if metodo not in self.METHODS:
            raise ValueError(f"Image Lab: método de fondo desconocido: {metodo!r}")
        return (metodo == "BEN2",)


class ImageLabFilenamePrefix:
    """Añade el origen de la imagen al nombre de archivo: «resultado» -> «resultado_flux»."""

    SLUGS = {
        "Z-Image Turbo": "z-image-turbo",
        "Z-Image Base": "z-image-base",
        "FLUX": "flux",
        "Qwen": "qwen",
        "Kontext (con máscara)": "kontext-con-mascara",
        "Kontext (sin máscara)": "kontext-sin-mascara",
        "Fotografía externa": "foto-externa",
    }

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "prefix": ("STRING", {"default": "image_lab/final/resultado"}),
            "fuente": (list(OPTIONS), {"default": "FLUX"}),
        }}

    RETURN_TYPES = ("STRING",)
    RETURN_NAMES = ("prefix_final",)
    FUNCTION = "build"
    CATEGORY = "Image Lab / Interno"

    def build(self, prefix, fuente):
        slug = self.SLUGS.get(fuente)
        if slug is None:
            raise ValueError(f"Image Lab: fuente desconocida: {fuente!r}")
        return (f"{prefix}_{slug}",)


class ImageLabInitialImage:
    """An image uploader with img2img and resolution toggles in one node."""

    EMPTY_IMAGE = "(sin imagen)"
    USE_IMAGE = "Usar imagen inicial"
    KEEP_SIZE = "Mantener resolución original"
    TRANSFORM = "Transformación (%)"

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
            cls.TRANSFORM: ("INT", {"default": 0, "min": 0, "max": 100, "step": 1}),
        }}

    RETURN_TYPES = ("IMAGE", "MASK", "BOOLEAN", "BOOLEAN", "INT")
    RETURN_NAMES = ("IMAGE", "MASK", "usar_imagen_inicial", "mantener_resolucion", "transformacion_pct")
    FUNCTION = "load_with_settings"
    CATEGORY = "Image Lab"

    def load_with_settings(self, image, **settings):
        use_image = bool(settings[self.USE_IMAGE])
        keep_size = bool(settings[self.KEEP_SIZE])
        transformation_pct = max(0, min(100, int(settings[self.TRANSFORM])))

        if use_image:
            if image in ("", self.EMPTY_IMAGE):
                raise ValueError("Image Lab: elige una foto o desactiva 'Usar imagen inicial'.")
            pixels, mask = nodes.LoadImage().load_image(image)
        else:
            # Placeholder: the internal txt2img switch will ignore this image.
            # Crucially, we don't try to open the input folder as a file.
            pixels = torch.zeros((1, 64, 64, 3), dtype=torch.float32)
            mask = torch.zeros((1, 64, 64), dtype=torch.float32)

        return (pixels, mask, use_image, keep_size, transformation_pct)

    @classmethod
    def VALIDATE_INPUTS(cls, image, **settings):
        # ComfyUI valida también nodos de ramas que pueden no llegar a ejecutarse.
        # Aceptar el sentinel aquí evita bloquear el workflow antes de elegir rama.
        # Si esta rama se ejecuta y necesita la imagen, load_with_settings() dará
        # el error específico, en tiempo de ejecución.
        if image in ("", cls.EMPTY_IMAGE):
            return True
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
    "ImageLabSourceSelectorGeneracion": ImageLabSourceSelectorGeneracion,
    "ImageLabSourceSelectorEdicion": ImageLabSourceSelectorEdicion,
    "ImageLabBackgroundSelector": ImageLabBackgroundSelector,
    "ImageLabFilenamePrefix": ImageLabFilenamePrefix,
    "ImageLabInitialImage": ImageLabInitialImage,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "ImageLabSourceSelector": "Image Lab · Fuente",
    "ImageLabSourceSelectorGeneracion": "Image Lab · Fuente (generación)",
    "ImageLabSourceSelectorEdicion": "Image Lab · Fuente (edición)",
    "ImageLabBackgroundSelector": "Image Lab · Método de fondo",
    "ImageLabFilenamePrefix": "Image Lab · Nombre de archivo",
    "ImageLabInitialImage": "Image Lab · Imagen inicial",
}
