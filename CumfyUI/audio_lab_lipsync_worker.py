"""AUDIO_LAB MuseTalk 1.5 compositor, runs in isolated MuseTalk Python 3.10 venv.

Expected assets: frames directory 00000000.png etc; voices WAV with already
scheduled speech; timeline JSON; output frames directory.
A and B identities are anchored by their LEFT/RIGHT position in the first
frame containing exactly two faces. Refuse ambiguous scenes instead of
silently altering the wrong face.
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
import soundfile as sf


def run(args, cwd=None, env=None):
    p = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                       capture_output=True, text=True, errors="replace")
    if p.returncode:
        raise RuntimeError(
            f"Falló comando ({p.returncode}): {' '.join(map(str,args[:4]))}\n"
            + ((p.stderr or "") + "\n" + (p.stdout or ""))[-3500:])
    return p


def find_ffmpeg():
    exe = shutil.which("ffmpeg")
    if exe:
        return Path(exe).resolve()
    try:
        import imageio_ffmpeg
        exe = Path(imageio_ffmpeg.get_ffmpeg_exe())
        if exe.is_file():
            return exe
    except ImportError:
        pass
    raise RuntimeError("Instala FFmpeg (ffmpeg.exe) y añádelo a PATH.")


def faces_in_image(detector, frame):
    h, w = frame.shape[:2]
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    out = detector.process(rgb)
    found = []
    for det in out.detections or []:
        b = det.location_data.relative_bounding_box
        x1 = max(0, round(b.xmin * w))
        y1 = max(0, round(b.ymin * h))
        x2 = min(w, round((b.xmin+b.width) * w))
        y2 = min(h, round((b.ymin+b.height) * h))
        if x2 - x1 >= 28 and y2 - y1 >= 28:
            found.append((x1,y1,x2,y2))
    if len(found) > 2:
        raise ValueError("Hay más de dos rostros detectados. AUDIO_LAB admite hasta dos.")
    return found


def center(box):
    return np.array(((box[0]+box[2])/2, (box[1]+box[3])/2), dtype=float)


def track_faces(image_paths, side, used):
    with mp.solutions.face_detection.FaceDetection(
        model_selection=1, min_detection_confidence=0.55
    ) as detector:
        all_found = []
        for i, path in enumerate(image_paths):
            frame = cv2.imread(str(path))
            if frame is None:
                raise RuntimeError(f"No se puede leer el fotograma {path}.")
            all_found.append(faces_in_image(detector, frame))
    first = cv2.imread(str(image_paths[0]))
    height, width = first.shape[:2]
    if "B" in used:
        anchors = [(i, boxes) for i,boxes in enumerate(all_found) if len(boxes)==2]
        if not anchors:
            raise ValueError(
                "Para asignar A/B automáticamente necesito un fotograma con "
                "las dos caras visibles. No cambiaré la cara equivocada."
            )
        pivot, boxes = anchors[0]
        ordered = sorted(boxes, key=lambda b:center(b)[0])
        if side == "right":
            ordered.reverse()
        seeds = {"A":ordered[0], "B":ordered[1]}
    else:
        anchors = [(i,boxes) for i,boxes in enumerate(all_found) if boxes]
        if not anchors:
            raise ValueError("No se ha detectado ningún rostro en el vídeo.")
        pivot, boxes = anchors[0]
        seeds = {"A":max(boxes, key=lambda b:(b[2]-b[0])*(b[3]-b[1]))}

    tracks = {who:[None]*len(image_paths) for who in seeds}
    for who,box in seeds.items():
        tracks[who][pivot] = box

    def extend(indices):
        prev = seeds.copy()
        for i in indices:
            boxes = all_found[i]
            # Assign each face to at most one identity using distance to prior
            candidates = []
            for who, last in prev.items():
                for k,b in enumerate(boxes):
                    d = np.linalg.norm(center(last)-center(b))
                    limit = max(width,height)*0.18
                    if d <= limit:
                        candidates.append((d,who,k))
            candidates.sort()
            assigned_who, assigned_box = set(), set()
            for d,who,k in candidates:
                if who not in assigned_who and k not in assigned_box:
                    assigned_who.add(who)
                    assigned_box.add(k)
                    tracks[who][i] = boxes[k]
                    prev[who] = boxes[k]
            if len(seeds)==2 and len(boxes)==2 and len(assigned_who)<2:
                raise ValueError(
                    f"Seguimiento A/B ambiguo en fotograma {i}. "
                    "Hay que resolver la identidad, no intercambiar rostros."
                )
    extend(range(pivot+1,len(image_paths)))
    extend(range(pivot-1,-1,-1))
    return tracks, width, height


def crop_geometry(box, width, height):
    x1,y1,x2,y2 = box
    length = max(int(max(x2-x1,y2-y1)*2.05), 256)
    length = min(length, width, height)
    cx,cy = center(box)
    x = min(max(0, int(round(cx-length/2))), width-length)
    y = min(max(0, int(round(cy-length/2))), height-length)
    return x,y,length


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeline", required=True)
    parser.add_argument("--voice-a", required=True)
    parser.add_argument("--voice-b", required=True)
    parser.add_argument("--fps", type=float, required=True)
    parser.add_argument("--a-side", choices=["left","right"], default="left")
    parser.add_argument("--musetalk", required=True)
    args = parser.parse_args()

    source = sorted(Path(args.frames).glob("*.png"))
    if not source:
        raise ValueError("No hay fotogramas de entrada.")
    if args.fps <= 0:
        raise ValueError("FPS inválidos.")

    repo = Path(args.musetalk).resolve()
    model = repo/"models"/"musetalkV15"/"unet.pth"
    config = repo/"models"/"musetalkV15"/"musetalk.json"
    whisper = repo/"models"/"whisper"
    if not model.is_file() or not config.is_file() or not (whisper/"pytorch_model.bin").is_file():
        raise RuntimeError("Faltan los modelos MuseTalk 1.5. Ejecuta la descarga oficial de pesos.")
    try:
        timeline = json.loads(Path(args.timeline).read_text(encoding="utf-8"))
        turns = timeline["turns"]
    except (KeyError,ValueError,TypeError) as exc:
        raise ValueError(f"Plan de diálogo inválido: {exc}") from exc
    if not turns:
        raise ValueError("No se recibió ningún diálogo.")
    used = {t["speaker"] for t in turns}
    if not used.issubset({"A","B"}):
        raise ValueError("Solo se admiten los personajes A y B.")
    # No silent changes to timing made by the lip-sync backend.
    for turn in turns:
        if not (0 <= float(turn["start"]) < float(turn["end"]) <= len(source)/args.fps+0.15):
            raise ValueError("Hay una frase fuera de la duración del vídeo.")

    tracks,width,height=track_faces(source,args.a_side,used)
    ffmpeg=find_ffmpeg()
    output=Path(args.output)
    output.mkdir(parents=True,exist_ok=True)
    for i,src in enumerate(source):
        shutil.copy2(src,output/f"{i:08d}.png")

    audio_sources={"A":Path(args.voice_a),"B":Path(args.voice_b)}
    # Existing clip voice tracks are already positioned on the full timeline.
    with tempfile.TemporaryDirectory(prefix="al_ls_",dir=str(repo.parent)) as work_path:
        work=Path(work_path)
        for index,turn in enumerate(turns):
            who=turn["speaker"]
            start=max(0,round(float(turn["start"])*args.fps))
            stop=min(len(source),math.ceil(float(turn["end"])*args.fps))
            if stop<=start:
                raise ValueError(f"Frase {index+1} demasiado corta.")
            missing=[i for i in range(start,stop) if tracks[who][i] is None]
            if missing:
                raise ValueError(
                    f"El rostro {who} no es visible durante toda la frase {index+1}. "
                    f"Faltan {len(missing)} fotogramas. Se necesita revisar ese plano."
                )
            turn_dir=work/f"turn_{index:03d}"
            crops=turn_dir/"crops"
            crops.mkdir(parents=True)
            geometries=[]
            for j,i in enumerate(range(start,stop)):
                src=cv2.imread(str(source[i]))
                x,y,s=crop_geometry(tracks[who][i],width,height)
                geometries.append((x,y,s))
                fragment=src[y:y+s,x:x+s]
                cv2.imwrite(str(crops/f"{j:08d}.png"),fragment)
            audio,sr=sf.read(str(audio_sources[who]),always_2d=True,dtype="float32")
            from_sample=max(0,round(float(turn["start"])*sr))
            to_sample=min(len(audio),round(float(turn["end"])*sr))
            segment=audio[from_sample:to_sample]
            if len(segment)<sr*0.12:
                raise ValueError(f"Audio demasiado corto en frase {index+1}.")
            speech=turn_dir/"speech.wav"
            sf.write(str(speech),segment,sr,subtype="PCM_16")
            video=turn_dir/"face.mp4"
            run([ffmpeg,"-y","-v","error","-framerate",f"{args.fps:.8f}",
                 "-i",str(crops/"%08d.png"),"-an","-c:v","libx264",
                 "-pix_fmt","yuv420p","-crf","18",str(video)])
            job=turn_dir/"job.yaml"
            job.write_text(
                'task_0:\n  video_path: "'+video.as_posix()+'"\n'
                '  audio_path: "'+speech.as_posix()+'"\n',
                encoding="utf-8")
            results=turn_dir/"results"
            results.mkdir()
            env=os.environ.copy()
            env["PATH"]=str(ffmpeg.parent)+os.pathsep+env.get("PATH","")
            run([
                sys.executable,"-m","scripts.inference",
                "--inference_config",str(job),
                "--result_dir",str(results),
                "--unet_model_path",str(model),
                "--unet_config",str(config),
                "--whisper_dir",str(whisper),
                "--version","v15","--use_float16","--batch_size","4",
                "--ffmpeg_path",str(ffmpeg.parent),
            ],cwd=str(repo),env=env)
            movie=results/"v15"/"face_speech.mp4"
            if not movie.is_file() or movie.stat().st_size<1024:
                raise RuntimeError("MuseTalk no produjo el MP4 de la frase "
                                   f"{index+1}. Revisa sus logs.")
            rendered=turn_dir/"rendered"
            rendered.mkdir()
            run([ffmpeg,"-y","-v","error","-i",str(movie),
                 "-vsync","0",str(rendered/"%08d.png")])
            pieces=sorted(rendered.glob("*.png"))
            if abs(len(pieces)-(stop-start))>2:
                raise RuntimeError(
                    f"MuseTalk entregó {len(pieces)} fotogramas, "
                    f"esperábamos {stop-start}; no alteraré la duración."
                )
            if not pieces:
                raise RuntimeError("MuseTalk no devolvió fotogramas.")
            for j,i in enumerate(range(start,stop)):
                frame=cv2.imread(str(output/f"{i:08d}.png"))
                lip=cv2.imread(str(pieces[min(j,len(pieces)-1)]))
                if lip is None:
                    raise RuntimeError("Fotograma de MuseTalk ilegible.")
                x,y,size=geometries[j]
                patch=cv2.resize(lip,(size,size),interpolation=cv2.INTER_LINEAR)
                # Preserve the original surroundings and blend crop boundaries.
                alpha=np.ones((size,size),dtype=np.float32)
                edge=max(8,int(size*0.07))
                ramp=np.linspace(0,1,edge,dtype=np.float32)
                alpha[:edge,:]*=ramp[:,None]
                alpha[-edge:,:]*=ramp[::-1,None]
                alpha[:,:edge]*=ramp[None,:]
                alpha[:,-edge:]*=ramp[None,::-1]
                base=frame[y:y+size,x:x+size]
                merged=patch.astype(np.float32)*alpha[:,:,None]+base.astype(np.float32)*(1-alpha[:,:,None])
                frame[y:y+size,x:x+size]=merged.clip(0,255).astype(np.uint8)
                cv2.imwrite(str(output/f"{i:08d}.png"),frame)
            print(f"AUDIO_LAB Lip-sync: frase {index+1}/{len(turns)} "
                  f"rostro {who} fotogramas {start}-{stop}.",flush=True)
    print("AUDIO_LAB: lip-sync completado, sin cambiar duración ni FPS.",flush=True)


if __name__=="__main__":
    main()
