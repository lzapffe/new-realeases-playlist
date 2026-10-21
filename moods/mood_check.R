# =============================================================================
# mood_check.R
#
# Goal: find out which mood system best recognises the mood of your
# "Semi-background songs" playlist, by comparing three systems on the same
# songs:
#   - Essentia (computer analysis of each song's 30-second Deezer preview):
#     7 yes/no moods and 56 mood/theme tags. Runs in essentia_moods.py.
#   - ReccoBeats: Spotify-style sound measures (valence, energy, ...).
#   - Last.fm: tags that listeners gave the song (or its artist).
#
# The test: your ~20 songs (the "test" group) against 20 random songs from
# Everything everything (the "random" group). A good system gives the test
# songs similar values (tight) that differ from the random songs (separate).
#
# It runs in two parts, started by the workflow:
#   Rscript moods/mood_check.R prepare
#     1. SPOTIFY (2-3 requests): read "Semi-background songs".
#     2. Pick 20 random songs from the saved Everything everything copies in
#        state/ (free).
#     3. DEEZER (free): find each song's 30-second preview, for Essentia.
#     -> moods/work/songs.csv
#   python moods/essentia_moods.py          (Essentia, see that file)
#     -> moods/work/essentia.csv
#   Rscript moods/mood_check.R compare
#     4. RECCOBEATS (free): sound measures for every song.
#     5. LAST.FM (free): the song's top tags, or the artist's if the song has
#        fewer than 2.
#     6. Put everything in one table and score each measure.
#     -> moods/results/mood_songs.csv   (one row per song, all values)
#     -> moods/results/mood_summary.csv (one row per measure, best first)
#
# Needs: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REFRESH_TOKEN and
# LASTFM_API_KEY (the same secrets as the Christmas playlists).
# =============================================================================

# Load the packages, without their start-up messages.
#   httr2 - web requests to Spotify, Deezer, ReccoBeats and Last.fm
#   dplyr - filtering, joining and summarising tables
#   purrr - map() for working with lists from the APIs
#   tibble - the table format used throughout
suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(tibble)
})

# ---- Settings ---------------------------------------------------------------

TEST_PLAYLIST  <- "Semi-background songs"   # exact name, as in Spotify
MAIN_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")
N_RANDOM       <- 20     # random comparison songs from Everything everything
RANDOM_SEED    <- 42     # same seed = same random songs on every run
MIN_TAG_COUNT  <- 10     # ignore Last.fm tags scored below this (0-100)
WORK_DIR       <- "moods/work"
RESULTS_DIR    <- "moods/results"

# Which part to run: "prepare" or "compare" (given by the workflow).
STEP <- commandArgs(trailingOnly = TRUE)[1]
if (!STEP %in% c("prepare", "compare")) stop("Run with 'prepare' or 'compare'.", call. = FALSE)
dir.create(WORK_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(RESULTS_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- Helpers ----------------------------------------------------------------

# "a %||% b" returns a, unless a is missing (NULL or empty), then b.
# num(): a number from an API reply, or NA if it's missing.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
num <- function(x) if (is.null(x)) NA_real_ else as.numeric(x)

# get_json(): one GET request to a free API (Deezer, ReccoBeats, Last.fm),
# with a short pause and up to 3 tries. Returns the reply as a list, or NULL.
get_json <- function(url, query = list(), pause = 0.25) {
  Sys.sleep(pause)
  resp <- tryCatch(
    request(url) |>
      req_url_query(!!!query) |>
      req_retry(max_tries = 3) |>
      req_error(is_error = function(r) FALSE) |>
      req_perform(),
    error = function(e) NULL)
  if (is.null(resp) || resp_status(resp) >= 400) return(NULL)
  resp_body_json(resp)
}

# ==== PART 1: prepare =========================================================
if (STEP == "prepare") {

  # ---- 1. Spotify: read the test playlist --------------------------------------
  message("== 1. Reading '", TEST_PLAYLIST, "' from Spotify")

  # Log in with the refresh token (as in the other Spotify scripts), then
  # find the playlist in your list of playlists and read its songs. Each
  # request is counted, and the script stops if Spotify says "too many
  # requests", so it can never take much of the shared quota.
  resp <- request("https://accounts.spotify.com/api/token") |>
    req_auth_basic(Sys.getenv("SPOTIFY_CLIENT_ID"), Sys.getenv("SPOTIFY_CLIENT_SECRET")) |>
    req_body_form(grant_type = "refresh_token",
                  refresh_token = Sys.getenv("SPOTIFY_REFRESH_TOKEN")) |>
    req_perform()
  token <- resp_body_json(resp)$access_token
  used  <- 0
  sp_pages <- function(url) {
    items <- list()
    while (!is.null(url)) {
      used <<- used + 1
      if (used > 10) stop("More than 10 Spotify requests needed; stopped to protect the quota.", call. = FALSE)
      Sys.sleep(0.5)
      r <- request(url) |> req_auth_bearer_token(token) |>
        req_error(is_error = function(r) FALSE) |> req_perform()
      if (resp_status(r) == 429) stop("Spotify says 'too many requests'; try another day.", call. = FALSE)
      if (resp_status(r) >= 400) stop("Spotify error ", resp_status(r), ": ", resp_body_string(r), call. = FALSE)
      page  <- resp_body_json(r)
      items <- c(items, page$items %||% list())
      url   <- page[["next"]]
    }
    items
  }
  pls <- sp_pages("https://api.spotify.com/v1/me/playlists?limit=50")
  pl  <- detect(pls, function(p) identical(p$name, TEST_PLAYLIST))
  if (is.null(pl)) stop("No playlist named '", TEST_PLAYLIST, "' in your library.", call. = FALSE)
  items  <- sp_pages(sprintf("https://api.spotify.com/v1/playlists/%s/items?limit=50", pl$id))
  tracks <- keep(compact(map(items, function(it) it$item %||% it$track)), function(t) !is.null(t$id))
  test <- tibble(
    group      = "test",
    spotify_id = map_chr(tracks, "id"),
    title      = map_chr(tracks, function(t) t$name %||% ""),
    artist     = map_chr(tracks, function(t) t$artists[[1]]$name %||% ""),
    isrc       = map_chr(tracks, function(t) t$external_ids$isrc %||% NA_character_)
  )
  message(nrow(test), " test songs read with ", used, " Spotify requests.")

  # ---- 2. Random comparison songs (free) -----------------------------------------
  message("== 2. Picking ", N_RANDOM, " random songs from Everything everything")

  # Read the new-releases script's saved copies of Everything everything,
  # leave out the test songs, and pick N_RANDOM at random. The fixed seed
  # means a re-run picks the same songs, so results can be compared.
  meta <- read.csv("state/playlists_meta.csv", colClasses = "character")
  ee <- map_dfr(meta$playlist_id[meta$name %in% MAIN_PLAYLISTS], function(id) {
    read.csv(sprintf("state/playlist_%s.csv", id), colClasses = "character", encoding = "UTF-8")
  })
  set.seed(RANDOM_SEED)
  random <- ee |>
    mutate(spotify_id = sub("spotify:track:", "", uri)) |>
    filter(!spotify_id %in% test$spotify_id) |>
    distinct(spotify_id, .keep_all = TRUE) |>
    slice_sample(n = N_RANDOM) |>
    transmute(group = "random", spotify_id, title,
              artist = sub("\\|.*$", "", artist_names),
              # the saved copies have ISRCs once the new-releases script has
              # re-read them; until then this is empty and Deezer is searched
              isrc = if ("isrc" %in% names(ee)) na_if(isrc, "") else NA_character_)

  # ---- 3. Deezer: 30-second previews (free) ----------------------------------------
  message("== 3. Finding the 30-second previews on Deezer")

  # For each song: look it up on Deezer by its ISRC (the song's international
  # code, exact) if known, otherwise search for artist + title. Keep Deezer's
  # preview link; Essentia downloads and analyses it in the next step.
  songs <- bind_rows(test, random)
  songs$preview <- map_chr(seq_len(nrow(songs)), function(i) {
    hit <- NULL
    if (!is.na(songs$isrc[i])) hit <- get_json(paste0("https://api.deezer.com/track/isrc:", songs$isrc[i]))
    if (is.null(hit$preview) || !nzchar(hit$preview %||% "")) {
      q <- sprintf('artist:"%s" track:"%s"', gsub('"', "", songs$artist[i]), gsub('"', "", songs$title[i]))
      found <- get_json("https://api.deezer.com/search", list(q = q, limit = 1))$data
      # No match with the strict search: try a plain "artist title" search.
      if (length(found) == 0) {
        found <- get_json("https://api.deezer.com/search",
                          list(q = paste(songs$artist[i], songs$title[i]), limit = 1))$data
      }
      hit <- if (length(found) > 0) found[[1]] else NULL  # still no match: no preview
    }
    hit$preview %||% NA_character_
  })
  message(sum(!is.na(songs$preview)), " of ", nrow(songs), " songs have a Deezer preview.")
  write.csv(songs, file.path(WORK_DIR, "songs.csv"), row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# ==== PART 2: compare =========================================================
if (STEP == "compare") {
  songs <- as_tibble(read.csv(file.path(WORK_DIR, "songs.csv"), colClasses = "character", encoding = "UTF-8"))

  # ---- 4. ReccoBeats: sound measures (free) ---------------------------------------
  message("== 4. Getting sound measures from ReccoBeats")

  # One request for up to 40 Spotify IDs. ReccoBeats answers with a link to
  # each Spotify song ("href"), used to match the answers back. Values run
  # from 0 to 1 (valence = how positive, energy = how intense, ...).
  rb <- map_dfr(split(songs$spotify_id, ceiling(seq_along(songs$spotify_id) / 40)), function(ids) {
    feats <- get_json("https://api.reccobeats.com/v1/audio-features",
                      list(ids = paste(ids, collapse = ",")), pause = 0.5)$content %||% list()
    map_dfr(feats, function(f) tibble(
      spotify_id          = sub(".*/track/", "", f$href %||% NA_character_),
      rb_valence          = num(f$valence),
      rb_energy           = num(f$energy),
      rb_danceability     = num(f$danceability),
      rb_acousticness     = num(f$acousticness),
      rb_instrumentalness = num(f$instrumentalness)
    ))
  }) |>
    distinct(spotify_id, .keep_all = TRUE)
  message("ReccoBeats: values for ", nrow(rb), " of ", nrow(songs), " songs.")

  # ---- 5. Last.fm: listener tags (free) -------------------------------------------
  message("== 5. Getting listener tags from Last.fm")

  # top_tags(): the tags Last.fm listeners gave a song (or an artist), scored
  # at least MIN_TAG_COUNT, lowercase. If a song has fewer than 2 tags, its
  # artist's tags are used instead; tag_source says which.
  key <- Sys.getenv("LASTFM_API_KEY")
  if (key == "") stop("Set LASTFM_API_KEY (a GitHub secret).", call. = FALSE)
  top_tags <- function(method, artist, track = NULL) {
    q <- list(method = method, artist = artist, api_key = key, format = "json", autocorrect = 1)
    if (!is.null(track)) q$track <- track
    tg <- get_json("https://ws.audioscrobbler.com/2.0/", q)$toptags$tag %||% list()
    tolower(map_chr(keep(tg, function(t) num(t$count) >= MIN_TAG_COUNT), "name"))
  }
  lfm <- map_dfr(seq_len(nrow(songs)), function(i) {
    tags <- top_tags("track.gettoptags", songs$artist[i], songs$title[i])
    src  <- "song"
    if (length(tags) < 2) { tags <- top_tags("artist.gettoptags", songs$artist[i]); src <- "artist" }
    tibble(spotify_id = songs$spotify_id[i], lfm_tags = paste(head(tags, 15), collapse = "|"),
           tag_source = if (length(tags) == 0) "none" else src)
  })
  message("Last.fm: tags for ", sum(lfm$tag_source != "none"), " of ", nrow(songs), " songs.")

  # ---- 6. Combine and score ----------------------------------------------------------
  message("== 6. Comparing the systems")

  # One table with every song and every value. Essentia's results come from
  # essentia_moods.py (empty if that step failed).
  ess_file <- file.path(WORK_DIR, "essentia.csv")
  ess <- if (file.exists(ess_file)) {
    as_tibble(read.csv(ess_file, check.names = FALSE)) |> mutate(spotify_id = as.character(spotify_id))
  } else {
    tibble(spotify_id = character())
  }
  all <- songs |>
    select(group, spotify_id, title, artist) |>
    left_join(rb, by = "spotify_id") |>
    left_join(ess, by = "spotify_id") |>
    left_join(lfm, by = "spotify_id")
  write.csv(all, file.path(RESULTS_DIR, "mood_songs.csv"), row.names = FALSE, na = "",
            fileEncoding = "UTF-8")

  # Score every number column (ReccoBeats and Essentia): how far apart the
  # test and random groups are, measured in standard deviations ("separation",
  # bigger = the system tells your songs apart better), and how spread out
  # the test songs are ("test_spread", smaller = more consistent). "coverage"
  # is the share of test songs that have a value at all.
  num_cols <- names(all)[map_lgl(all, is.numeric)]
  score_num <- map_dfr(num_cols, function(col) {
    t <- all[[col]][all$group == "test"]; r <- all[[col]][all$group == "random"]
    pooled <- sqrt((var(t, na.rm = TRUE) + var(r, na.rm = TRUE)) / 2)
    tibble(system      = if (startsWith(col, "rb_")) "ReccoBeats" else "Essentia",
           measure     = col,
           test_mean   = mean(t, na.rm = TRUE),
           random_mean = mean(r, na.rm = TRUE),
           separation  = abs(mean(t, na.rm = TRUE) - mean(r, na.rm = TRUE)) / pooled,
           test_spread = sd(t, na.rm = TRUE),
           coverage    = mean(!is.na(t)))
  })

  # Score every Last.fm tag the same way, using the share of songs that have
  # the tag (test share vs random share). Only tags on at least 3 songs count.
  has_tag <- function(tag) map_lgl(strsplit(all$lfm_tags %||% "", "|", fixed = TRUE), function(x) tag %in% x)
  tags <- unique(unlist(strsplit(all$lfm_tags[!is.na(all$lfm_tags)], "|", fixed = TRUE)))
  score_tag <- map_dfr(tags, function(tag) {
    h <- has_tag(tag)
    t <- h[all$group == "test"]; r <- h[all$group == "random"]
    if (sum(h) < 3) return(NULL)
    tibble(system = "Last.fm", measure = tag, test_mean = mean(t), random_mean = mean(r),
           separation = abs(mean(t) - mean(r)) / sqrt((var(t) + var(r)) / 2 + 1e-9),
           test_spread = NA_real_, coverage = mean(all$tag_source[all$group == "test"] != "none"))
  })

  # Save all scores, best separation first, and print the top 5 per system.
  summary <- bind_rows(score_num, score_tag) |> arrange(desc(separation))
  write.csv(summary, file.path(RESULTS_DIR, "mood_summary.csv"), row.names = FALSE, na = "")
  for (s in unique(summary$system)) {
    top <- head(filter(summary, system == s), 5)
    message("\n", s, " (coverage ", round(100 * top$coverage[1]), "% of test songs) - best measures:")
    walk(seq_len(nrow(top)), function(i) {
      message(sprintf("  %-28s test %.2f vs random %.2f  (separation %.2f)",
                      top$measure[i], top$test_mean[i], top$random_mean[i], top$separation[i]))
    })
  }
  message("\nFull results: moods/results/mood_songs.csv and moods/results/mood_summary.csv")
}
