# =============================================================================
# essentia_scores.py  (mood playlists, step 1: analysis)
#
# Gives each song in this run's batch Essentia's mood scores. Started by the
# workflow between the two parts of mood_scores.R (Essentia only exists for
# Python). Uses Deezer (free) and no Spotify requests at all.
#
#   1. Download Essentia's ready-made models (once per run, ~100 MB):
#      - "discogs-effnet": turns a song into a summary of its sound; all the
#        mood models below read this summary.
#      - 7 yes/no mood models: happy, sad, aggressive, relaxed, party,
#        acoustic, electronic (a score from 0 to 1 each).
#      - "mtg_jamendo_moodtheme": scores for 56 mood/theme tags (0 to 1 each).
#   2. For each song in moods/work/scores/batch.csv: look up its 30-second preview on
#      Deezer right before analysing it (preview links expire after a while),
#      first by ISRC, then by searching artist and title.
#   3. Analyse the preview and average the scores over the clip.
#   4. Write moods/work/scores/scores_new.csv (one row per analysed song) and
#      moods/work/scores/no_preview.csv (songs without a usable preview).
# Stops starting new songs after TIME_LIMIT_MIN minutes, so the workflow has
# time to save; the rest are done in the next run.
# =============================================================================

# Python's built-in modules, numpy (number arrays) and Essentia's tools.
import csv
import json
import os
import tempfile
import time
import urllib.parse
import urllib.request

import numpy as np
from essentia.standard import MonoLoader, TensorflowPredict2D, TensorflowPredictEffnetDiscogs

# Settings.
MODELS_URL = "https://essentia.upf.edu/models/"
EMBEDDING = "feature-extractors/discogs-effnet/discogs-effnet-bs64-1"
MOODS = ["happy", "sad", "aggressive", "relaxed", "party", "acoustic", "electronic"]
THEMES = "classification-heads/mtg_jamendo_moodtheme/mtg_jamendo_moodtheme-discogs-effnet-1"
MODEL_DIR = "moods/work/models"
BATCH_FILE = "moods/work/scores/batch.csv"
OUT_FILE = "moods/work/scores/scores_new.csv"
MISSING_FILE = "moods/work/scores/no_preview.csv"
TIME_LIMIT_MIN = 300     # stop starting new songs after 5 hours
DEEZER_PAUSE = 0.15      # seconds between Deezer requests (limit: 50 per 5 s)
START = time.time()


# download(): fetch a model file unless it's already there. Returns the path.
def download(path, ext):
    os.makedirs(MODEL_DIR, exist_ok=True)
    local = os.path.join(MODEL_DIR, os.path.basename(path) + ext)
    if not os.path.exists(local):
        urllib.request.urlretrieve(MODELS_URL + path + ext, local)
    return local


# output_name(): the name of a model's prediction output, from its description.
def output_name(meta, default):
    for out in meta.get("schema", {}).get("outputs", []):
        if out.get("output_purpose") == "predictions":
            return out["name"]
    return default


# deezer(): one Deezer request, returning the reply as a dict (or {} on error).
def deezer(url):
    time.sleep(DEEZER_PAUSE)
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            return json.load(r)
    except Exception:
        return {}


# find_preview(): the song's 30-second preview link on Deezer, or "".
# First by ISRC (exact), then a strict search, then a plain search.
def find_preview(song):
    isrc = (song.get("isrc") or "").strip()
    if isrc:
        hit = deezer("https://api.deezer.com/track/isrc:" + urllib.parse.quote(isrc))
        if hit.get("preview"):
            return hit["preview"]
    artist = song["artist"].replace('"', "")
    title = song["title"].replace('"', "")
    for q in (f'artist:"{artist}" track:"{title}"', f"{artist} {title}"):
        found = deezer("https://api.deezer.com/search?limit=1&q=" + urllib.parse.quote(q)).get("data") or []
        if found and found[0].get("preview"):
            return found[0]["preview"]
    return ""


# Load the models (see the top of this file).
embedder = TensorflowPredictEffnetDiscogs(
    graphFilename=download(EMBEDDING, ".pb"), output="PartitionedCall:1")
mood_models = {}
for mood in MOODS:
    path = f"classification-heads/mood_{mood}/mood_{mood}-discogs-effnet-1"
    meta = json.load(open(download(path, ".json")))
    model = TensorflowPredict2D(graphFilename=download(path, ".pb"),
                                output=output_name(meta, "model/Softmax"))
    mood_models[mood] = (model, meta["classes"].index(mood))
theme_meta = json.load(open(download(THEMES, ".json")))
theme_model = TensorflowPredict2D(graphFilename=download(THEMES, ".pb"),
                                  output=output_name(theme_meta, "model/Sigmoid"))
theme_names = theme_meta["classes"]
print(f"Loaded {len(mood_models)} mood models and {len(theme_names)} mood/theme tags.")

# Analyse the batch, one song at a time, until the time limit.
with open(BATCH_FILE, encoding="utf-8") as f:
    songs = list(csv.DictReader(f))
rows, missing = [], []
for i, song in enumerate(songs, start=1):
    if (time.time() - START) / 60 > TIME_LIMIT_MIN:
        print(f"Time limit reached after {i - 1} songs; the rest are done next run.")
        break
    preview = find_preview(song)
    if not preview:
        missing.append({"spotify_id": song["spotify_id"], "reason": "no preview on Deezer"})
        continue
    try:
        with tempfile.NamedTemporaryFile(suffix=".mp3") as tmp:
            urllib.request.urlretrieve(preview, tmp.name)
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
        missing.append({"spotify_id": song["spotify_id"], "reason": f"analysis failed: {e}"[:200]})
    if i % 100 == 0:
        mins = (time.time() - START) / 60
        print(f"  {i} of {len(songs)} songs done ({len(rows)} analysed) after {mins:.0f} minutes.")


# write_csv(): save a list of rows (dicts) as a CSV file with the given columns.
def write_csv(path, data, columns):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(data)


# Save the results for the R script to merge into the saved scores.
score_cols = ["spotify_id"] + [f"ess_{m}" for m in MOODS] + [f"tag_{n}" for n in theme_names]
write_csv(OUT_FILE, rows, score_cols)
write_csv(MISSING_FILE, missing, ["spotify_id", "reason"])
print(f"Essentia: analysed {len(rows)} songs; {len(missing)} without a usable preview; "
      f"{(time.time() - START) / 60:.0f} minutes.")
