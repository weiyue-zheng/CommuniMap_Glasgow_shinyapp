#!/usr/bin/env python3
"""
Shiny-friendly Ask the Map query script.

Supports either:
- --zip  <embedding_bundle.zip>
or
- --prefix <path/to/prefix>

Expected embedded files:
    <prefix>_text.npy
    <prefix>_image.npy
    <prefix>_meta.json

Outputs:
- JSON results file
- Folium HTML map file
"""

import os
import io
import json
import bisect
import argparse
import tempfile
import zipfile
from pathlib import Path

import faiss
import folium
import numpy as np
import requests
import torch
from PIL import Image
from folium.plugins import HeatMap
from sentence_transformers import SentenceTransformer
from transformers import AutoProcessor, AutoModel


device = "cuda" if torch.cuda.is_available() else "cpu"


MODEL_REGISTRY = {
    "clip": {
        "type": "sentence_transformer_clip",
        "default": "sentence-transformers/clip-ViT-B-32",
    },
    "siglip": {
        "type": "siglip",
        "default": "google/siglip2-base-patch16-384",
    },
}


def normalize_rows(mat: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return mat / norms


def resolve_model_source(model_spec: str) -> str:
    p = Path(model_spec).expanduser()
    if p.exists():
        return str(p.resolve())
    return model_spec


def has_valid_image(item) -> bool:
    img = item.get("primary_image")
    return isinstance(img, str) and img.strip() != ""


def load_siglip_model(model_spec: str):
    source = resolve_model_source(model_spec)
    processor = AutoProcessor.from_pretrained(source)
    model = AutoModel.from_pretrained(source).to(device)
    model.eval()
    return processor, model


def detect_prefix_from_folder(folder: str) -> str:
    files = list(Path(folder).rglob("*"))
    text_files = [str(f) for f in files if str(f).endswith("_text.npy")]
    image_files = [str(f) for f in files if str(f).endswith("_image.npy")]
    meta_files = [str(f) for f in files if str(f).endswith("_meta.json")]

    if len(text_files) != 1:
        raise FileNotFoundError(
            f"Expected exactly one *_text.npy file in extracted bundle, found {len(text_files)}."
        )
    if len(image_files) != 1:
        raise FileNotFoundError(
            f"Expected exactly one *_image.npy file in extracted bundle, found {len(image_files)}."
        )
    if len(meta_files) != 1:
        raise FileNotFoundError(
            f"Expected exactly one *_meta.json file in extracted bundle, found {len(meta_files)}."
        )

    prefix = text_files[0].replace("_text.npy", "")
    expected_image = prefix + "_image.npy"
    expected_meta = prefix + "_meta.json"

    if image_files[0] != expected_image or meta_files[0] != expected_meta:
        raise ValueError(
            "Embedding bundle files do not share the same prefix."
        )

    return prefix


def extract_zip_and_get_prefix(zip_path: str) -> tuple[str, str]:
    tmp_dir = tempfile.mkdtemp(prefix="ask_map_bundle_")
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(tmp_dir)
    prefix = detect_prefix_from_folder(tmp_dir)
    return prefix, tmp_dir


def build_parser():
    p = argparse.ArgumentParser()

    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--prefix",
        help="Prefix for embeddings (expects <prefix>_text.npy, <prefix>_image.npy, <prefix>_meta.json).",
    )
    group.add_argument(
        "--zip",
        help="Zip bundle containing *_text.npy, *_image.npy, *_meta.json.",
    )

    p.add_argument(
        "--query",
        required=True,
        help="Natural language query.",
    )
    p.add_argument(
        "--out_json",
        required=True,
        help="Path to output JSON results.",
    )
    p.add_argument(
        "--out_map",
        required=True,
        help="Path to output Folium HTML map.",
    )
    p.add_argument(
        "--k",
        type=int,
        default=50,
        help="Number of nearest neighbours to retrieve before thresholding.",
    )
    p.add_argument(
        "--threshold",
        type=float,
        default=0.0,
        help="Minimum fused similarity score to keep a result.",
    )
    p.add_argument(
        "--w_text",
        type=float,
        default=0.7,
        help="Weight for text similarity in fusion.",
    )
    p.add_argument(
        "--w_img",
        type=float,
        default=0.3,
        help="Weight for image similarity in fusion.",
    )
    p.add_argument(
        "--vlm",
        choices=list(MODEL_REGISTRY.keys()),
        default="clip",
        help="Vision-language model family used to create the embeddings.",
    )
    p.add_argument(
        "--vl_model",
        default=None,
        help="Optional local path or model ID overriding the default VLM.",
    )
    p.add_argument(
        "--center_lat",
        type=float,
        default=55.8721,
        help="Default map center latitude.",
    )
    p.add_argument(
        "--center_lon",
        type=float,
        default=-4.2892,
        help="Default map center longitude.",
    )
    p.add_argument(
        "--zoom_start",
        type=int,
        default=12,
        help="Initial Folium zoom.",
    )

    return p


def load_embeddings(prefix: str):
    text_emb_path = prefix + "_text.npy"
    img_emb_path = prefix + "_image.npy"
    meta_path = prefix + "_meta.json"

    if not os.path.exists(text_emb_path):
        raise FileNotFoundError(f"Text embedding file not found: {text_emb_path}")
    if not os.path.exists(img_emb_path):
        raise FileNotFoundError(f"Image embedding file not found: {img_emb_path}")
    if not os.path.exists(meta_path):
        raise FileNotFoundError(f"Metadata file not found: {meta_path}")

    text_embs = np.load(text_emb_path).astype("float32")
    img_embs = np.load(img_emb_path).astype("float32")

    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)

    if len(meta) != text_embs.shape[0]:
        raise ValueError("Metadata length does not match number of text embeddings.")
    if len(meta) != img_embs.shape[0]:
        raise ValueError("Metadata length does not match number of image embeddings.")

    return text_embs, img_embs, meta


def build_indices(text_embs: np.ndarray, img_embs: np.ndarray):
    text_embs_norm = normalize_rows(text_embs)
    img_embs_norm = normalize_rows(img_embs)

    index_text = faiss.IndexFlatIP(text_embs_norm.shape[1])
    index_text.add(text_embs_norm)

    index_img = faiss.IndexFlatIP(img_embs_norm.shape[1])
    index_img.add(img_embs_norm)

    return index_text, index_img


def build_query_encoders(vlm_name: str, vlm_model: str | None):
    model_info = MODEL_REGISTRY[vlm_name]
    vlm_type = model_info["type"]
    source = vlm_model if vlm_model else model_info["default"]

    if vlm_type == "sentence_transformer_clip":
        model_vlm = SentenceTransformer(resolve_model_source(source), device=device)

        def embed_query_text(q: str) -> np.ndarray:
            truncated_q = " ".join(q.split()[:50])
            vec = model_vlm.encode(
                [truncated_q],
                convert_to_numpy=True,
                normalize_embeddings=True,
                show_progress_bar=False,
            ).astype("float32")
            return vec

        return embed_query_text

    if vlm_type == "siglip":
        processor_vlm, model_vlm = load_siglip_model(source)

        def embed_query_text(q: str) -> np.ndarray:
            truncated_q = " ".join(q.split()[:50])
            inputs = processor_vlm(
                text=[truncated_q],
                padding=True,
                truncation=True,
                return_tensors="pt",
            ).to(device)

            with torch.no_grad():
                vec = model_vlm.get_text_features(**inputs)

            vec = vec / vec.norm(dim=-1, keepdim=True)
            return vec.cpu().numpy().astype("float32")

        return embed_query_text

    raise ValueError(f"Unsupported vlm type: {vlm_type}")


def search_multimodal(
    query: str,
    meta,
    index_text,
    index_img,
    embed_query_text,
    k: int,
    threshold: float,
    w_text: float,
    w_img: float,
):
    qv_t = embed_query_text(query)
    qv_i = embed_query_text(query)

    if qv_t.shape[1] != index_text.d:
        raise ValueError(
            f"Text query dim mismatch: query has {qv_t.shape[1]}, text index expects {index_text.d}."
        )
    if qv_i.shape[1] != index_img.d:
        raise ValueError(
            f"Image query dim mismatch: query has {qv_i.shape[1]}, image index expects {index_img.d}."
        )

    D_t, I_t = index_text.search(qv_t, k)
    D_i, I_i = index_img.search(qv_i, k)

    score_text_dict = {
        int(idx): float(score)
        for idx, score in zip(I_t[0], D_t[0])
        if idx >= 0
    }
    score_img_dict = {
        int(idx): float(score)
        for idx, score in zip(I_i[0], D_i[0])
        if idx >= 0
    }

    candidate_idxs = set(score_text_dict.keys()).union(score_img_dict.keys())
    text_scores = sorted(score_text_dict.values())
    img_scores = sorted(score_img_dict.values())

    def get_percentile(score, scores_list):
        if not scores_list:
            return 0.0
        pos = bisect.bisect_left(scores_list, score)
        return 100.0 * pos / len(scores_list)

    fused = []
    for idx in candidate_idxs:
        item = meta[idx]

        if not has_valid_image(item):
            continue

        st = score_text_dict.get(idx, 0.0)
        si = score_img_dict.get(idx, 0.0)
        s = w_text * st + w_img * si

        if s < threshold:
            continue

        lat = item.get("lat")
        lon = item.get("lon")
        if lat is None or lon is None:
            continue

        fused.append(
            {
                "idx": int(idx),
                "score": float(s),
                "score_text": float(st),
                "score_img": float(si),
                "p_text": float(get_percentile(st, text_scores)),
                "p_img": float(get_percentile(si, img_scores)),
                "id": item.get("id"),
                "text": item.get("text", ""),
                "lat": float(lat),
                "lon": float(lon),
                "image": item.get("primary_image"),
            }
        )

    fused.sort(key=lambda x: x["score"], reverse=True)
    return fused[:k]


def make_map(results, out_path: str, center=None, zoom_start=12):
    if center is None:
        center = (55.8721, -4.2892)

    m = folium.Map(location=center, zoom_start=zoom_start)

    if results:
        heat_points = [(r["lat"], r["lon"]) for r in results]
        HeatMap(
            heat_points,
            radius=25,
            blur=30,
            max_zoom=13,
        ).add_to(m)

    for r in results:
        text = (r.get("text") or "")[:250].replace("\n", " ")
        img = r.get("image") or ""
        html = f"""
        <div style="width:240px;">
          <b>ID:</b> {r.get("id", "")}<br>
          <b>Score:</b> {r.get("score", 0):.3f}<br>
          <b>Text score:</b> {r.get("score_text", 0):.3f} (p: {r.get("p_text", 0):.1f}%)<br>
          <b>Image score:</b> {r.get("score_img", 0):.3f} (p: {r.get("p_img", 0):.1f}%)<br>
          <p style="font-size:11px;">{text}...</p>
          <img src="{img}" width="220">
        </div>
        """
        folium.CircleMarker(
            location=(r["lat"], r["lon"]),
            radius=5,
            fill=True,
            fill_opacity=0.85,
            color="red",
            popup=folium.Popup(html, max_width=260),
            tooltip=f"ID: {r.get('id', '')}",
        ).add_to(m)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    m.save(out_path)


def main():
    parser = build_parser()
    args = parser.parse_args()

    extracted_dir = None

    if args.zip:
        prefix, extracted_dir = extract_zip_and_get_prefix(args.zip)
    else:
        prefix = args.prefix

    text_embs, img_embs, meta = load_embeddings(prefix)
    index_text, index_img = build_indices(text_embs, img_embs)
    embed_query_text = build_query_encoders(args.vlm, args.vl_model)

    results = search_multimodal(
        query=args.query,
        meta=meta,
        index_text=index_text,
        index_img=index_img,
        embed_query_text=embed_query_text,
        k=args.k,
        threshold=args.threshold,
        w_text=args.w_text,
        w_img=args.w_img,
    )

    os.makedirs(os.path.dirname(args.out_json), exist_ok=True)
    with open(args.out_json, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)

    make_map(
        results=results,
        out_path=args.out_map,
        center=(args.center_lat, args.center_lon),
        zoom_start=args.zoom_start,
    )

    print(json.dumps({
        "status": "ok",
        "n_results": len(results),
        "out_json": args.out_json,
        "out_map": args.out_map,
        "prefix_used": prefix,
        "extracted_dir": extracted_dir,
    }))


if __name__ == "__main__":
    main()