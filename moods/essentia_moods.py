# =============================================================================
# essentia_moods.py
#
# The Essentia step of the mood checker (Essentia only exists for Python).
# Started by the workflow between the two parts of mood_check.R.
#
#   1. Download Essentia's ready-made models (once per run, ~100 MB):
#      - "discogs-effnet": turns a song into a summary of its sound
#        (an "embedding"); all mood models below read this summary.
#      - 7 yes/no mood models: happy, sad, aggressive, relaxed, party,
#        acoustic, electronic. Each gives a score from 0 to 1.
#      - "mtg_jamendo_moodtheme": scores for 56 mood/theme tags (calm, dark,
#        dreamy, emotional, ...), each from 0 to 1.
#   2. For each song in moods/work/songs.csv: download its 30-second Deezer
#      preview, analyse it, and average the scores over the clip.
#   3. Save one row per song in moods/work/essentia.csv, with columns
#      "ess_happy", ..., and "tag_calm", "tag_dark", ...
# Songs without a preview, or whose preview fails, are left out (the R script
# then shows them as empty).
# =============================================================================

# Python's built-in modules for CSV files, JSON, downloads and temporary files,
# plus numpy (number arrays) and Essentia's analysis tools.
import csv
import json
import os
import tempfile
import urllib.request

import numpy as np
from essentia.standard import MonoLoader, TensorflowPredict2D, TensorflowPredictEffnetDiscogs

# Where the models are published, and the ones used here.
MODELS_URL = "https://essentia.upf.edu/models/"
EMBEDDING = "feature-extractors/discogs-effnet/discogs-effnet-bs64-1"
MOODS = ["happy", "sad", "aggressive", "relaxed", "party", "acoustic", "electronic"]
THEMES = "classification-heads/mtg_jamendo_moodtheme/mtg_jamendo_moodtheme-discogs-effnet-1"
MODEL_DIR = "moods/work/models"
SONGS_FILE = "moods/work/songs.csv"
OUT_FILE = "moods/work/essentia.csv"


# download(): fetch a model file (.pb = the model, .json = its description,
# including the class names) unless it's already there. Returns the path.
def download(path, ext):
    os.makedirs(MODEL_DIR, exist_ok=True)
    local = os.path.join(MODEL_DIR, os.path.basename(path) + ext)
    if not os.path.exists(local):
        urllib.request.urlretrieve(MODELS_URL + path + ext, local)
    return local


# output_name(): the name of a model's prediction output, read from its .json
# description (falls back to the usual name if the description lacks it).
def output_name(meta, default):
    for out in meta.get("schema", {}).get("outputs", []):
        if out.get("output_purpose") == "predictions":
            return out["name"]
    return default


# Load the models. The embedding model's output "PartitionedCall:1" is the
# sound summary that the mood models read.
embedder = TensorflowPredictEffnetDiscogs(
    graphFilename=download(EMBEDDING, ".pb"), output="PartitionedCall:1")

# For each yes/no mood: the model, and which of its two outputs means "yes"
# (e.g. "happy" rather than "non_happy"), found from the class names.
mood_models = {}
for mood in MOODS:
    path = f"classification-heads/mood_{mood}/mood_{mood}-discogs-effnet-1"
    meta = json.load(open(download(path, ".json")))
    model = TensorflowPredict2D(graphFilename=download(path, ".pb"),
                                output=output_name(meta, "model/Softmax"))
    mood_models[mood] = (model, meta["classes"].index(mood))

# The 56 mood/theme tags: one model with one score per tag.
theme_meta = json.load(open(download(THEMES, ".json")))
theme_model = TensorflowPredict2D(graphFilename=download(THEMES, ".pb"),
                                  output=output_name(theme_meta, "model/Sigmoid"))
theme_names = theme_meta["classes"]
print(f"Loaded {len(mood_models)} mood models and {len(theme_names)} mood/theme tags.")

# Analyse each song: download the preview to a temporary file, load it as
# mono audio at 16 kHz (what the models expect), make the sound summary, and
# average each model's scores over the whole clip.
rows = []
with open(SONGS_FILE, encoding="utf-8") as f:
    songs = list(csv.DictReader(f))
for song in songs:
    if not song.get("preview"):
        continue
    try:
        with tempfile.NamedTemporaryFile(suffix=".mp3") as tmp:
            urllib.request.urlretrieve(song["preview"], tmp.name)
            audio = MonoLoader(filename=tmp.name, sampleRate=16000, resampleQuality=4)()
        emb = embedder(audio)
        row = {"spotify_id": song["spotify_id"]}
        for mood, (model, yes) in mood_models.items():
            row[f"ess_{mood}"] = round(float(np.mean(model(emb), axis=0)[yes]), 3)
        themes = np.mean(theme_model(emb), axis=0)
        for name, score in zip(theme_names, themes):
            row[f"tag_{name}"] = round(float(score), 3)
        rows.append(row)
    except Exception as e:  # one bad preview shouldn't stop the others
        print(f"  skipped {song['artist']} - {song['title']}: {e}")

# Save the results (one row per song).
with open(OUT_FILE, "w", newline="", encoding="utf-8") as f:
    if rows:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
print(f"Essentia: analysed {len(rows)} of {len(songs)} songs.")
