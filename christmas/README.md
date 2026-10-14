# Christmas × genre playlists

This makes 11 private playlists, such as "Christmas × Country" and "Christmas × Soul", with Christmas songs you don't have yet. The genres are country, bluegrass, folk, soul, blues, jazz, reggae, Celtic, indie, rock and lo-fi.

## How it works

1. **Last.fm (free).** For each genre, it collects songs that listeners have tagged with a combined tag, such as "country christmas" or "christmas country". These are the strongest matches, so they're used first. It then fills up with the most popular "christmas" songs whose artist is tagged with that genre.
2. **Leaving out what you have.** It skips anything already in Everything everything Part 1/2, read for free from the new-releases script's saved copies. It also skips your Christmas edition, which it reads from Spotify only when that playlist has changed.
3. **Spotify search.** It finds each song on Spotify, at one request per song. Every result is saved, so no song is searched twice.
4. **Making the playlists.** Once a genre has 35 songs, it creates the playlist and adds the songs, which takes 2 requests.

Each run uses at most **80 Spotify requests** and then stops, saving its progress in `christmas/state/`. All 11 playlists need about 400 requests, so **expect about five runs**. The log ends with "Still to make: …" or "All playlists are made".

The script refuses to run on Thursdays and Fridays. The workflow also shares a queue with the daily new-releases run, so the two never use Spotify at the same time.

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
5. **Recommended: cap the unmatched-artist check in the new-releases script.** Right now, from Saturday to Wednesday, that check uses up whatever is left of the 200 daily requests. Adding 80 for the Christmas run could then pass the roughly 300 a day at which Spotify blocked us before. In `spotify_new_releases.R`:
   - In the Settings section, below `FALLBACK_INTERVAL_DAYS`, add this line:

     ```r
     FALLBACK_MAX_REQUESTS  <- 60        # most requests the unmatched-artist check may use per run
     ```

   - In step 6, change `if (budget_left() <= SPOTIFY_RESERVE + 4) break` to:

     ```r
     if (budget_left() <= SPOTIFY_RESERVE + 4 || n_fb * 2 >= FALLBACK_MAX_REQUESTS) break
     ```

   - This also leaves room for the later Spotify projects. The unmatched artists are still checked, just more slowly.

## Running it

**Don't start yet.** I'll remind you when the new-releases backlog has cleared.

When the time comes:
1. Go to **Actions**, then **Christmas genre playlists**, then **Run workflow**.
2. Pick a **Monday, Tuesday or Wednesday afternoon**, after the daily 10:17 run has finished. Do one run per day.
3. Repeat on the following Monday to Wednesday days until the log says "All playlists are made".

If a genre ends with "only N songs found", add more Last.fm tags for it in `GENRES` and run again. For example, you could add "americana" for Country.

## Files in christmas/state/

- `picks.csv`: the songs chosen for each genre, and why each was chosen (`combined tag` or `artist genre`).
- `playlists.csv`: the playlists made so far.
- `searches.csv`, `artist_tags.csv` and `christmas_known.csv`: caches, so nothing is looked up twice.

To redo one genre, delete its rows from `picks.csv` and `playlists.csv` and delete the playlist in Spotify.

The code has only been checked for syntax. It hasn't been run against Last.fm or Spotify yet, so please send me the log if the first run shows an error.
