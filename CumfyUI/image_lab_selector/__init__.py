"""Simple native dropdown for Image Lab's final output.
Copy this folder to ComfyUI/custom_nodes/image_lab_selector and restart ComfyUI.
No additional Python packages are required.
"""
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

NODE_CLASS_MAPPINGS = {
    "ImageLabSourceSelector": ImageLabSourceSelector,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "ImageLabSourceSelector": "Image Lab · Fuente",
}
