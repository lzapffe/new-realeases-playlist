# Mood checker

This compares three mood systems on your "semi background songs" playlist to see which one best recognises the mood you hear in it:

| System | What it gives | How |
|---|---|---|
| **Essentia** | 7 yes/no moods (happy, sad, aggressive, relaxed, party, acoustic, electronic) and 56 mood/theme tags (calm, dark, dreamy, …), each scored 0–1 | Analyses each song's 30-second Deezer preview |
| **ReccoBeats** | Valence (how positive), energy, danceability, acousticness, instrumentalness, each 0–1 | Looked up by Spotify ID |
| **Last.fm** | Tags that listeners gave the song (or its artist, if the song has fewer than 2) | Looked up by artist and title |

## How it works

1. **R:** reads your test playlist from Spotify, using only 2–3 requests.
2. **R:** picks 20 random songs from Everything everything for comparison. This is free, using the saved copies, and the same 20 songs are picked every run.
3. **R:** finds each song's preview on Deezer.
4. **Python:** Essentia analyses the previews. Essentia only exists for Python, so this one step is in Python. It runs on GitHub, so you don't need to install anything.
5. **R:** gets the ReccoBeats measures and Last.fm tags, then scores every measure.

A good measure gives your test songs similar values, and values that differ from the random songs. The score for that is **separation**: how far apart the two groups are. Bigger means better, and above about 1 is clear.

## Results

The results are saved in `moods/results/` in the repository, and the best 5 measures per system are also printed at the end of the log.
- `mood_summary.csv`: one row per measure, best separation first. Columns:
  - `test_mean` and `random_mean`: the average for each group.
  - `separation`
  - `test_spread`: how consistent your songs are; smaller is better.
  - `coverage`: the share of your songs the system had data for.
- `mood_songs.csv`: one row per song, with every value from every system. Open it in Excel and filter by `group` (test or random).

## Setup (once, in the new-realeases-playlist repository)

1. Check that the `LASTFM_API_KEY` secret is there. It's the same one the Christmas playlists use.
2. Click **Add file**, then **Create new file**, and add each of these:
   - `moods/mood_check.R`, pasting [mood_check.R](mood_check.R)
   - `moods/essentia_moods.py`, pasting [essentia_moods.py](essentia_moods.py)
   - `.github/workflows/mood-check.yml`, pasting [mood-check.yml](mood-check.yml)

## Running it

Go to **Actions**, then **Mood checker**, then **Run workflow**. It takes about 5–10 minutes, mostly installing Essentia and downloading its models. It only uses 2–3 Spotify requests, so any afternoon works. Avoid Thursday and Friday mornings, when the weekly playlist is built.

If the Essentia step fails (it's marked as allowed to fail), the comparison still runs with ReccoBeats and Last.fm only. Send me the log and I'll fix it.

The code has only been checked for syntax. It hasn't been run against the real services yet, so please send me the log if anything goes wrong.
