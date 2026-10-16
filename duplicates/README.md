# Duplicate finder

This finds songs that appear more than once across "Everything everything" Part 1 and Part 2. It reads only the saved copies in `state/`, so it uses **no Spotify requests** and can run any day.

## The two lists

- **`exact_duplicates.csv`:** same title and same artists. Capital letters, punctuation and the order of the artists don't matter.
  - `same_spotify_song = TRUE` means the exact same Spotify track was added twice.
  - `FALSE` means two releases of the same recording, for example the single and the album version. Keeping one is usually enough.
- **`possible_duplicates.csv`:** the same song in another version, such as Acoustic, Live, a Remix or Remastered. The version tag (anything in brackets or after " - ") is ignored, and the first artist must be the same. Many of these are versions you may want on purpose, so check this list by eye.

In both lists, rows with the same `group` number are copies of one song. Open the files in Excel and filter or sort by `group`.

## Setup (once, in the new-realeases-playlist repository)

Click **Add file**, then **Create new file**, and add:
- `duplicates/find_duplicates.R`, pasting [find_duplicates.R](find_duplicates.R)
- `.github/workflows/find-duplicates.yml`, pasting [find-duplicates.yml](find-duplicates.yml)

## Running it

The first lists (16 Oct) are in `results-16oct/`.

Go to **Actions**, then **Duplicate finder**, then **Run workflow**. It takes 1–2 minutes, and the lists appear in `duplicates/` in the repository.

You can also run it in RStudio after `git pull`: open the repository folder as the working directory and run `source("duplicates/find_duplicates.R")`.

## When you delete songs

Removing songs makes the daily script re-read that playlist part, which costs about 50–60 Spotify requests once. So delete all duplicates on the same day, and not on a Thursday or Friday, just like with the delete list.
