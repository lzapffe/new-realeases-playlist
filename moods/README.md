# Moods: mood playlists and the mood checker

This folder holds two things: the **mood playlists** project (the main one, below) and the **mood checker**, a one-time test from October 2026 (at the end).

## Mood playlists

**What this project does:** it makes new Spotify playlists by mood (for example "Happy" or "Calm") from the songs you already have in **Everything everything Part 1 and Part 2**. You decide in an Excel sheet which playlists to make. You run it by hand whenever you want a new playlist.

It has two steps:

1. **Analysis (built 2 November 2026):** every song gets mood scores from Essentia, a free tool that listens to the song's 30-second Deezer preview. Uses **no Spotify requests**.
2. **Build playlists (built 5 November 2026):** you describe a playlist in an Excel sheet and the script creates it on Spotify. This step uses Spotify requests (about 1 per 100 songs).

Why Essentia: the mood checker (below, 28 October 2026) compared three systems on your "semi background songs" playlist. Essentia was the only one with data for every song and separated your songs best (relaxed, not aggressive). ReccoBeats had no data for 17 of 41 songs, and Last.fm only had genre tags, not moods.

### Step 1: analysis

| File | Goes in the repository at | What it does |
|---|---|---|
| `mood_scores.R` | `moods/` | Picks the songs without scores (from the saved playlist copies in `state/`), then saves the new scores and writes the Excel overview. |
| `essentia_scores.py` | `moods/` | Finds each song's preview on Deezer (by ISRC, then by search) and scores it with Essentia. |
| `mood-scores.yml` | `.github/workflows/` | The workflow "Mood playlists: analysis". Started by hand. |

**How to run it:** Actions tab, "Mood playlists: analysis", then "Run workflow". Each run does up to 2,500 songs and at most about 5 hours. Run it again until the overview says nothing is left (about 4–5 runs for ~10,300 songs; *estimate*, the first run's log shows the real speed). It needs no Spotify requests, so any day is fine, and it doesn't hold up the daily run. Later runs only do songs added since.

**What it saves:**
- `moods/scores/scores.csv`: one row per song, with its scores.
- `moods/scores/no_preview.csv`: songs Deezer had no preview for. They're tried again after 180 days.
- `moods/mood_categories.xlsx`: open this in Excel. It has three sheets:
  - **progress:** songs analysed, still to do, and songs without a preview.
  - **categories:** every mood category, with the median score, the score needed for the top 25 %, 15 % and 5 %, and the 5 highest-scoring songs.
  - **scores:** every song with all its scores, to filter and sort.

### The categories

- **7 main moods:** happy, sad, aggressive, relaxed, party, acoustic, electronic.
- **56 mood/theme tags:** action, adventure, advertising, background, ballad, calm, children, christmas, commercial, cool, corporate, dark, deep, documentary, drama, dramatic, dream, emotional, energetic, epic, fast, film, fun, funny, game, groovy, happy, heavy, holiday, hopeful, inspiring, love, meditative, melancholic, melodic, motivational, movie, nature, party, positive, powerful, relaxing, retro, romantic, sad, sexy, slow, soft, soundscape, space, sport, summer, trailer, travel, upbeat, uplifting.

Each is a score from 0 to 1 per song. Some tags are about use (film, game) rather than mood, but they can still be used.

### Step 2: building playlists (built 5 November 2026)

| File | Goes in the repository at | What it does |
|---|---|---|
| `mood_playlists.xlsx` | `moods/` | **You edit this one.** One row per playlist; the "help" sheet explains the columns and lists the moods. |
| `mood_playlists.R` | `moods/` | Picks the songs for each row marked build = yes and builds the playlist on Spotify. |
| `mood-playlists.yml` | `.github/workflows/` | The workflow "Mood playlists: build". Started by hand. |

**The Excel columns** (first sheet, "playlists"):

| Column | Meaning |
|---|---|
| build | `yes` = build or update it on the next run; `no` = skip it |
| playlist name | e.g. "Calm". Keep it the same to update the same playlist later. |
| type | `mood rule` or `like playlist` |
| high | mood rule: the moods to rank by, separated by commas (`love, romantic`) |
| low | mood rule, optional: moods a song must be below average on (`aggressive, party`) |
| like playlist | like playlist: the exact name of one of your Spotify playlists |
| how many | `15%` (of your library, grows with it) or `300` (the 300 best matches) |

**How songs are picked:**
- Every score is turned into a percentile (0 = lowest in your library, 1 = highest), so main moods and small tags can be mixed fairly. A main mood wins over a tag with the same name (`happy` = the main mood).
- *Mood rule:* songs below the middle on every "low" mood, ranked by the average of their "high" moods.
- *Like playlist:* the script reads your playlist, finds its songs among the scored ones (by Spotify ID or ISRC) and ranks the other songs by how close their mood profile (all 63 categories) is to that playlist's average. The playlist's own songs are left out, and it needs at least 5 scored songs. Only songs in Everything everything have scores.
- Only songs still in Everything everything are used.

**On Spotify:** the title is the name plus the size, e.g. "Calm (top 15 %)" or "Love songs (300 songs)". The description says it's based on the Everything everything playlists, gives the rule, and names this repository. Playlists are private (`PLAYLIST_PUBLIC`). Running a row again **replaces** the songs in the playlist it made before; if you've deleted that playlist, a new one is made.

**How to run it:** fill in the Excel file, save, close Excel, commit and push. Then Actions tab, "Mood playlists: build", "Run workflow". It uses about 1 Spotify request per 100 songs plus a few per playlist: a 15 % playlist (about 1,500 songs) costs about 19, a 300-song one about 6. At most 100 per run (`MAX_SPOTIFY_REQUESTS`); a row that doesn't fit waits for the next run. Pick a day with room (see the request log).

**What it saves** (written by the workflow; don't edit): `moods/playlists_made.csv` (each playlist's Spotify ID, title, rule, size, date) and `moods/playlist_songs.csv` (the songs each playlist got, best match first).

Design notes: [Mood playlists: workflow and decision matrix](https://claude.ai/artifact/G9DivW3fsdKqV72PmWaLQw).

## Mood checker (one-time test, done)

Compared three mood systems on your "semi background songs" playlist against 20 random songs from Everything everything, to choose the system for the mood playlists. Last run 28 October 2026; Essentia was chosen.

| System | What it gives | Result |
|---|---|---|
| Essentia | 7 moods and 56 mood/theme tags, from the 30-second Deezer preview | Data for all songs; your songs stood out as relaxed and not aggressive. **Chosen.** |
| ReccoBeats | Valence, energy, danceability, acousticness, instrumentalness | No data for 17 of 41 songs; weak separation |
| Last.fm | Listener tags | Only artist genre tags, no moods |

- Files: `mood_check.R` (R, in two parts), `essentia_moods.py` (the Essentia step) and `.github/workflows/mood-check.yml` ("Mood checker", started by hand, 2–3 Spotify requests).
- Results: `moods/results/mood_summary.csv` (one row per measure, best separation first) and `mood_songs.csv` (one row per song).
- It doesn't need to be run again. Its working files are in `moods/work/`, like the mood playlist analysis (`moods/work/scores/`); the Essentia models in `moods/work/models/` are shared.
