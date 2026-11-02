# Christmas × genre playlists

This makes 11 private playlists, such as "Christmas × Country" and "Christmas × Soul", with Christmas songs you don't have yet. The genres are country, bluegrass, folk, soul, blues, jazz, reggae, Celtic, indie, rock and lo-fi.

## How it works

1. **Last.fm (free).** For each genre, it collects songs that listeners have tagged with a combined tag, such as "country christmas" or "christmas country". These are the strongest matches, so they're used first. It then fills up with the most popular "christmas" songs whose artist is tagged with that genre.
2. **Leaving out what you have.** It skips anything already in Everything everything Part 1/2, read for free from the new-releases script's saved copies. It also skips your Christmas edition, which it reads from Spotify only when that playlist has changed.
3. **Spotify search.** It finds each song on Spotify, at one request per song. Every result is saved, so no song is searched twice.
4. **Making the playlists.** Once a genre has 35 songs, it creates the playlist and adds the songs, which takes 2 requests.

Each run uses at most **50 Spotify requests** and then stops, saving its progress in `christmas/state/`. All 11 playlists need about 400 requests, so **expect about eight runs**. The log ends with "Still to make: …" or "All playlists are made".

The script refuses to run on Wednesdays, Thursdays and Fridays. The workflow also shares a queue with the daily new-releases run, so the two never use Spotify at the same time.

## Setup (once)

All of this is done on github.com in the **new-realeases-playlist** repository.

1. **Last.fm key.**
   - Go to https://www.last.fm/api/account/create and log in, or create a free account.
   - Fill in any application name; the callback URL can stay empty.
   - Copy the **API key**. The shared secret isn't needed.
2. **Add the key as a secret.** In the repository, go to **Settings**, then **Secrets and variables**, then **Actions**. Click **New repository secret**, name it `LASTFM_API_KEY`, and paste the key.
3. **Add the script.**
   - Click **Add file**, then **Create new file**, and type the name `christmas/christmas_genres.R`. Typing the `/` creates the folder.
   - Paste the contents of [christmas_genres.R](christmas_genres.R).
   - Check `CHRISTMAS_PLAYLIST` near the top. It must be the exact name of your Christmas edition. I guessed `Everything everything - Christmas edition`.
   - Commit.
4. **Add the workflow.** Click **Add file**, then **Create new file**, name it `.github/workflows/christmas-genres.yml`, paste [christmas-genres.yml](christmas-genres.yml), and commit.
## Running it

**Don't start yet.** I'll remind you when the new-releases backlog has cleared.

When the time comes:
1. Go to **Actions**, then **Christmas genre playlists**, then **Run workflow**.
2. Pick a **Monday or Tuesday afternoon**, after the daily 10:17 run has finished. Do one run per day.
3. Repeat on the following Mondays and Tuesdays until the log says "All playlists are made".

If a genre ends with "only N songs found", add more Last.fm tags for it in `GENRES` and run again. For example, you could add "americana" for Country.

## Expanding a playlist later

To add more songs to a playlist that's already made, set a bigger number for its genre in `MORE_SONGS` near the top of the script, then run the workflow again. For example:

```r
MORE_SONGS <- c("Country" = 60, "Soul" = 50)
```

The script picks up where it left off in that genre's Last.fm list and adds only songs that aren't already in the playlist. It also skips songs you've since saved to your Christmas edition.

## Files in christmas/state/

- `picks.csv`: the songs chosen for each genre, why each was chosen (`combined tag` or `artist genre`), and when it was added to the playlist.
- `playlists.csv`: the playlists made so far.
- `searches.csv`, `artist_tags.csv` and `christmas_known.csv`: caches, so nothing is looked up twice.

To redo one genre, delete its rows from `picks.csv` and `playlists.csv` and delete the playlist in Spotify.

The code has only been checked for syntax. It hasn't been run against Last.fm or Spotify yet, so please send me the log if the first run shows an error.

## Choosing genres in Excel (added 2 November 2026)

Each run writes `christmas/genre_overview.xlsx`: one row per Last.fm tag found in the Christmas pool.

| Column | Meaning |
|---|---|
| decision | You fill it in: `include` or `exclude`. Blank = not looked at yet (these rows are at the top). |
| playlist | Optional. The playlist name for an included tag. Tags with the same name share one playlist (e.g. `americana` with playlist `Bluegrass`). Blank = the tag gets its own playlist. |
| tag | The Last.fm tag. |
| available_songs | Songs you don't have yet: combined tags ("christmas jazz") and pool songs whose artist has the tag, counted together. |
| from_combined_tags | How many of those come from the combined tags. |
| pool_artists | How many artists in the pool have the tag. |
| status | The playlist's state: made, searching, or waiting for more candidates. |

- **include:** the tag becomes (part of) a genre. Its songs are saved in `christmas/state/candidates.csv` and kept across runs and years. A genre is searched on Spotify only once it has 45 candidates (`MIN_CANDIDATES`); until then it costs no Spotify requests.
- **exclude:** the tag's songs go into the random "Christmas × Mix" playlist (only songs that aren't candidates for an included genre).
- To make the pool bigger later (e.g. next year), raise `CHRISTMAS_POOL_PAGES` (10 = 1,000 songs). New candidates are added to the saved ones.
- Songs not found on Spotify are searched again after a year (`RETRY_AFTER_DAYS`).

**Editing the file:** pull the latest version first, edit and save it in Excel, then commit and push. Don't push it while a Christmas run is going, or the run's own save can clash with yours.
