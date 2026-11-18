# Matching: fix the Deezer match for unsure artists

**What this does:** the daily new-releases run looks for new releases on Deezer, which is free. For that, every artist in Everything everything needs a Deezer match. About 520 artists don't have a sure one: 407 are "uncertain" (Deezer has several artists with that name) and 113 are "not_found". The daily run checks those on Spotify with its leftover requests instead, which is slow and fills Saturday to Wednesday.

This script finds the right Deezer artist through your own songs, using **no Spotify requests**:

1. For each unsure artist, it takes your songs by them from the saved playlist copies in `state/`, with each song's ISRC (the song's international recording code). **Songs where the artist is alone come first.** Songs with other artists are only used when there aren't enough solo songs.
2. It looks up each ISRC on Deezer, which gives the exact song and every artist on it.
   - A solo song on Spotify that has one artist on Deezer gives that artist.
   - Otherwise it only takes the Deezer artist with exactly the same name. No exact name, or two with the same name, gives nothing.
3. A match is accepted only when **two songs agree** (one song if that's all you have by the artist) and **no song points to a different artist**.

Accepted artists get `match = "matched"` in `state/artists.csv`. From then on the daily run checks them on Deezer, and the Spotify leftover check gets smaller.

## Files

| File | Goes in the repository at | What it does |
|---|---|---|
| `isrc_match.R` | `matching/` | The script. |
| `isrc-match.yml` | `.github/workflows/` | The workflow "Artist matching: ISRC". Started by hand. |

## How to run it

It uses no Spotify requests, so any day is fine. It shares the queue with the daily run, so if you start it while the daily run is going, it waits.

1. **Report first:** Actions tab, "Artist matching: ISRC", "Run workflow", and leave "save matches" unticked. It takes roughly 10–15 minutes (*estimate*). Nothing in `state/` changes.
2. Pull, and open `matching/isrc_report.csv` in Excel. Check a few rows (see below).
3. **Save:** run it again with "save matches" ticked. This writes the accepted matches into `state/artists.csv`.
4. Pull again before you change anything else in the repository.

## The report

One row per artist checked, sorted by result:

| Column | Meaning |
|---|---|
| `result` | `matched` (accepted), `only one song agrees` (not accepted: only one of two or more songs was found), `conflict` (songs point to different Deezer artists, not accepted), `not found`, or `no songs with ISRC` |
| `deezer_id`, `deezer_name` | The Deezer artist found (two IDs with " / " for a conflict) |
| `name_differs` | TRUE when the Deezer name isn't exactly the Spotify name. Only possible for solo songs. Worth a look. |
| `changed_artist` | TRUE when the match is a different Deezer artist than the old "uncertain" guess |
| `solo_songs`, `songs_checked`, `songs_agreeing` | How many of your songs were solo, looked up, and agreed |
| `notes` | What happened with each song looked up |

To fix a single artist by hand afterwards, edit their row in `state/artists.csv` and set `match` to `manual`, as before.

## What to expect afterwards

- The next daily run checks the newly matched artists on Deezer for releases from the last 14 days. That's free, but any new releases it finds are looked up on Spotify, so that run may use a few more requests than usual.
- The leftover Spotify check gets smaller, which frees room Monday to Wednesday.
- The daily run tries "uncertain" and "not_found" artists again on Deezer every 60 days. Matched artists are left alone.

## Changelog

- **18 November 2026:** built. Solo songs first and an exact-name rule for songs with other artists, as Linn asked.
