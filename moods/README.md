# Tone playlists

**What this project does:** it makes new Spotify playlists by mood (for example "Happy" or "Calm") from the songs you already have in **Everything everything Part 1 and Part 2**. You decide in an Excel sheet which playlists to make. You run it by hand whenever you want a new playlist.

It has two steps:

1. **Analysis (built 2 November 2026):** every song gets mood scores from Essentia, a free tool that listens to the song's 30-second Deezer preview. Uses **no Spotify requests**.
2. **Build playlists (not built yet):** you describe a playlist in an Excel sheet and the script creates it on Spotify. This step uses Spotify requests (about 1 per 100 songs), so it waits until there is room after the Christmas runs.

Why Essentia: the mood checker (`moods/`, 28 October 2026) compared three systems on your "semi background songs" playlist. Essentia was the only one with data for every song and separated your songs best (relaxed, not aggressive). ReccoBeats had no data for 17 of 41 songs, and Last.fm only had genre tags, not moods.

## Step 1: analysis

| File | Goes in the repository at | What it does |
|---|---|---|
| `tone_scores.R` | `tones/` | Picks the songs without scores (from the saved playlist copies in `state/`), then saves the new scores and writes the Excel overview. |
| `essentia_scores.py` | `tones/` | Finds each song's preview on Deezer (by ISRC, then by search) and scores it with Essentia. |
| `tones-analysis.yml` | `.github/workflows/` | The workflow "Tone playlists: analysis". Started by hand. |

**How to run it:** Actions tab, "Tone playlists: analysis", then "Run workflow". Each run does up to 2,500 songs and at most about 5 hours. Run it again until the overview says nothing is left (about 4–5 runs for ~10,300 songs; *estimate*, the first run's log shows the real speed). It needs no Spotify requests, so any day is fine, and it doesn't hold up the daily run. Later runs only do songs added since.

**What it saves:**
- `tones/state/scores.csv`: one row per song, with its scores.
- `tones/state/no_preview.csv`: songs Deezer had no preview for. They're tried again after 180 days.
- `tones/categories_overview.xlsx`: open this in Excel. It has three sheets:
  - **progress:** songs analysed, still to do, and songs without a preview.
  - **categories:** every mood category, with the median score, the score needed for the top 25 %, 15 % and 5 %, and the 5 highest-scoring songs.
  - **scores:** every song with all its scores, to filter and sort.

## The categories

- **7 main moods:** happy, sad, aggressive, relaxed, party, acoustic, electronic.
- **56 mood/theme tags:** action, adventure, advertising, background, ballad, calm, children, christmas, commercial, cool, corporate, dark, deep, documentary, drama, dramatic, dream, emotional, energetic, epic, fast, film, fun, funny, game, groovy, happy, heavy, holiday, hopeful, inspiring, love, meditative, melancholic, melodic, motivational, movie, nature, party, positive, powerful, relaxing, retro, romantic, sad, sexy, slow, soft, soundscape, space, sport, summer, trailer, travel, upbeat, uplifting.

Each is a score from 0 to 1 per song. Some tags are about use (film, game) rather than mood, but they can still be used.

## Step 2: building playlists (planned, not built)

You'll fill in an Excel sheet with one row per playlist. Each run builds only the rows marked **build = yes**.

| Column | Meaning |
|---|---|
| build | yes / no |
| playlist name | e.g. "Calm" |
| type | *mood rule* (a mood we define from the categories, e.g. "relaxed high, aggressive low") or *like playlist* (the songs whose mood profile is closest to one of your playlists) |
| rule or reference playlist | the rule, or the name of your playlist |
| how many | a percentage of your library ("15%") or a number of songs ("300", the best matches) |

Agreed so far:
- The playlist **title** includes the mood and the number or percentage, e.g. "Calm (top 15 %)".
- The **description** says that it's based on the Everything everything playlists, which repository made it (new-realeases-playlist), and the rule used.

Design notes: [Tone playlists: workflow and decision matrix](https://claude.ai/artifact/G9DivW3fsdKqV72PmWaLQw).
