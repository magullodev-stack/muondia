"""Timestamp-correct MMAudio sampler for ComfyUI.

Keep this node separate from Kijai's ComfyUI-MMAudio so updates do not
overwrite the fix. Install alongside that extension in custom_nodes/.
No additional Python dependencies beyond ComfyUI-MMAudio are required.
"""

import math

import torch
from torchvision.transforms import v2
import comfy.model_management as mm


def _select_frames_at_fps(images, source_fps, duration, target_fps, transform):
    """Sample at target-frame timestamps instead of slicing the first N frames.

    Frame i in the source is at time i / source_fps. The target uses time
    t = n / target_fps. Nearest-neighbor temporal sampling repeats frames
    for low-FPS source video (expected; do not invent interpolated motion).
    """
    count = int(math.floor(duration * target_fps + 1e-7))
    if count < 1:
        raise ValueError(
            f"Video demasiado corto para MMAudio: {duration:.3f} s "
            f"(se necesitan al menos {1.0 / target_fps:.3f} s)."
        )

    indices = torch.arange(count, dtype=torch.float64)
    indices = torch.floor(indices * (source_fps / target_fps) + 0.5)
    indices = indices.to(torch.int64).clamp_(0, images.shape[0] - 1)

    # These transforms include ToPILImage, so process on CPU.
    source = images.detach().cpu()
    output = []
    for index in indices.tolist():
        frame = source[index].permute(2, 0, 1)  # HWC -> CHW
        output.append(transform(frame))
    return torch.stack(output, dim=0)


def _prepare_conditions(images, source_fps, duration, use_clip):
    if images is None or images.ndim != 4 or images.shape[0] == 0:
        raise ValueError("MMAudio necesita un video con fotogramas (IMAGE).")
    if not math.isfinite(source_fps) or source_fps <= 0:
        raise ValueError("Los FPS del video deben ser mayores que cero.")
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("La duracion del video debe ser mayor que cero.")

    # Never generate conditions beyond the end of the actual source video.
    duration = min(float(duration), images.shape[0] / float(source_fps))
    if duration < 1.0 / 8.0:
        raise ValueError("El video es demasiado corto para MMAudio (menos de 0.125 s).")

    clip_transform = v2.Compose([
        v2.Resize((384, 384), interpolation=v2.InterpolationMode.BICUBIC),
        v2.ToPILImage(),
        v2.ToTensor(),
        v2.ConvertImageDtype(torch.float32),
    ])
    synch_transform = v2.Compose([
        v2.Resize(224, interpolation=v2.InterpolationMode.BICUBIC),
        v2.CenterCrop(224),
        v2.ToPILImage(),
        v2.ToTensor(),
        v2.ConvertImageDtype(torch.float32),
        v2.Normalize(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5]),
    ])

    clip_frames = None
    if use_clip:
        clip_frames = _select_frames_at_fps(
            images, source_fps, duration, 8.0, clip_transform
        ).unsqueeze(0)
    sync_frames = _select_frames_at_fps(
        images, source_fps, duration, 25.0, synch_transform
    ).unsqueeze(0)
    return clip_frames, sync_frames, duration


class MMAudioFPSSyncSampler:
    """MMAudio generation with timestamp-aware CLIP (8 Hz) and Synchformer (25 Hz)."""

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "mmaudio_model": ("MMAUDIO_MODEL",),
                "feature_utils": ("MMAUDIO_FEATUREUTILS",),
                "images": ("IMAGE",),
                "duration": ("FLOAT", {"default": 6.0, "min": 0.125, "step": 0.01}),
                "source_fps": ("FLOAT", {"default": 24.0, "min": 0.001, "step": 0.001}),
                "steps": ("INT", {"default": 25, "min": 1, "step": 1}),
                "cfg": ("FLOAT", {"default": 4.5, "step": 0.1}),
                "seed": ("INT", {"default": 0, "min": 0, "max": 0xffffffffffffffff}),
                "prompt": ("STRING", {"default": "", "multiline": True}),
                "negative_prompt": ("STRING", {"default": "", "multiline": True}),
                "mask_away_clip": ("BOOLEAN", {"default": False}),
                "force_offload": ("BOOLEAN", {"default": True}),
            },
        }

    RETURN_TYPES = ("AUDIO",)
    RETURN_NAMES = ("audio",)
    FUNCTION = "sample"
    CATEGORY = "MMAudio"

    def sample(self, mmaudio_model, feature_utils, images, duration, source_fps,
               steps, cfg, seed, prompt, negative_prompt, mask_away_clip, force_offload):
        # Reuse Kijai's exact generation and scheduler implementations rather
        # than maintaining a fork of MMAudio model code.
        import nodes

        upstream = nodes.NODE_CLASS_MAPPINGS.get("MMAudioSampler")
        if upstream is None:
            raise RuntimeError(
                "No se encontro ComfyUI-MMAudio (Kijai). Instala o activa sus nodos."
            )
        implementation = upstream.sample.__globals__
        generate = implementation["generate"]
        flow_matching = implementation["FlowMatching"]

        clip_frames, sync_frames, effective_duration = _prepare_conditions(
            images, float(source_fps), float(duration), not mask_away_clip
        )

        device = mm.get_torch_device()
        offload_device = mm.unet_offload_device()
        rng = torch.Generator(device=device)
        rng.manual_seed(int(seed))

        config = mmaudio_model.seq_cfg
        config.duration = effective_duration
        mmaudio_model.update_seq_lengths(
            config.latent_seq_len, config.clip_seq_len, config.sync_seq_len
        )
        scheduler = flow_matching(
            min_sigma=0, inference_mode="euler", num_steps=steps
        )

        feature_utils.to(device)
        mmaudio_model.to(device)
        try:
            audio = generate(
                clip_frames,
                sync_frames,
                [prompt],
                negative_text=[negative_prompt],
                feature_utils=feature_utils,
                net=mmaudio_model,
                fm=scheduler,
                rng=rng,
                cfg_strength=cfg,
            )
        finally:
            if force_offload:
                mmaudio_model.to(offload_device)
                feature_utils.to(offload_device)
                mm.soft_empty_cache()

        return ({"waveform": audio.float().cpu(), "sample_rate": 44100},)


NODE_CLASS_MAPPINGS = {
    "MMAudioFPSSyncSampler": MMAudioFPSSyncSampler,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "MMAudioFPSSyncSampler": "MMAudio Sampler · FPS synchronized",
}
