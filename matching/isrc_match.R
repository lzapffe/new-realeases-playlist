# =============================================================================
# isrc_match.R
#
# Goal: find the right Deezer artist for the artists the daily run could not
# match for sure ("uncertain" or "not_found" in state/artists.csv), using the
# songs you already have. Uses NO Spotify requests: only the saved playlist
# copies in state/ and Deezer (free).
#
# How it works, for each of those artists:
#   1. Take your songs by that artist from the saved copies of the source
#      playlists, with their ISRC (the song's international recording code).
#      Songs where the artist is ALONE come first; songs with other artists
#      are only used when there aren't enough solo songs.
#   2. Look up each song's ISRC on Deezer. Deezer answers with the exact song
#      and every artist on it, each with their own Deezer ID.
#      - Solo song on Spotify and one artist on Deezer: that artist.
#      - Otherwise: only the Deezer artist whose name is EXACTLY the same
#        (ignoring upper/lower case). No exact name, or more than one: nothing.
#   3. Accept the Deezer artist only if:
#      - two songs point to the same Deezer artist (or, if you have just one
#        song by the artist with an ISRC, that one song does), and
#      - no song points to a different Deezer artist ("conflict").
#
# What it saves:
#   - matching/isrc_report.csv: one row per artist checked and the result.
#   - state/artists.csv: ONLY when SAVE_MATCHES is true. Accepted artists get
#     their Deezer ID and match = "matched", so the daily run checks them on
#     Deezer for new releases instead of on Spotify.
#
# Needs no secrets. Run from the repository's top folder.
# =============================================================================

# Load the packages. suppressPackageStartupMessages() hides their start-up
# messages so the log stays readable.
#   httr2 - sends web requests to Deezer
#   dplyr - filtering and combining tables
#   purrr - map()/keep() for working with lists from the API
#   tibble - the table format used throughout
suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(tibble)
})

# ---- Settings ---------------------------------------------------------------

# Playlists whose artists the daily run follows (same names as in
# spotify_new_releases.R).
SOURCE_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")

# Which artists to check: the match types the daily run couldn't use.
CHECK_TYPES <- c("uncertain", "not_found")

MAX_SONGS_PER_ARTIST <- 5   # at most this many songs looked up per artist
SONGS_NEEDED         <- 2   # songs that must agree (fewer if you have fewer songs)
DEEZER_PACE          <- 0.1 # seconds between Deezer requests (limit: 50 per 5 s)

STATE_DIR   <- "state"
REPORT_FILE <- "matching/isrc_report.csv"

# TRUE = write the accepted matches into state/artists.csv. FALSE = only write
# the report, so you can look it over first. Set by the "save matches" box
# when you start the workflow.
SAVE_MATCHES <- tolower(Sys.getenv("SAVE_MATCHES", "false")) == "true"

TODAY <- as.character(as.Date(format(Sys.time(), tz = "Europe/Oslo")))

# ---- Helpers ----------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
norm   <- function(x) tolower(trimws(x))
id_chr <- function(x) if (is.null(x) || length(x) == 0) NA_character_ else format(x, scientific = FALSE, trim = TRUE)

# read_state()/write_state(): the same CSV format as the daily run.
read_state <- function(path) {
  read.csv(path, colClasses = "character", na.strings = "",
           fileEncoding = "UTF-8", check.names = FALSE)
}
write_state <- function(df, path) {
  write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# dz_get(): one Deezer request, with up to 5 tries for network problems and
# Deezer's speed-limit error (code 4). Returns NULL if Deezer has no data
# (for example, an ISRC it doesn't know).
dz_get <- function(path) {
  for (attempt in 1:5) {
    Sys.sleep(DEEZER_PACE)
    resp <- tryCatch(
      request(paste0("https://api.deezer.com", path)) |>
        req_timeout(30) |>
        req_error(is_error = function(r) FALSE) |>
        req_perform(),
      error = function(e) NULL)
    if (is.null(resp) || resp_status(resp) >= 500 || resp_status(resp) == 429) {
      Sys.sleep(5)
      next
    }
    j <- tryCatch(resp_body_json(resp, check_type = FALSE), error = function(e) NULL)
    if (is.null(j)) {
      Sys.sleep(5)
      next
    }
    if (!is.null(j$error)) {
      if (identical(as.integer(j$error$code %||% 0), 4L)) {
        Sys.sleep(6)
        next
      }
      return(NULL)
    }
    return(j)
  }
  NULL
}

# deezer_artist_for_song(): look up one song by ISRC on Deezer and return the
# Deezer artist (id and name) that is your artist, or a reason why not.
deezer_artist_for_song <- function(isrc, name, solo) {
  tr <- dz_get(paste0("/track/isrc:", isrc))
  if (is.null(tr) || is.null(tr$id)) {
    return(list(id = NA_character_, dz_name = NA_character_, why = "song not on Deezer"))
  }
  people <- tr$contributors %||% list(tr$artist)
  if (solo && length(people) == 1) {
    return(list(id = id_chr(people[[1]]$id), dz_name = people[[1]]$name %||% NA_character_,
                why = "solo song"))
  }
  same <- keep(people, function(p) norm(p$name %||% "") == norm(name))
  ids  <- unique(map_chr(same, function(p) id_chr(p$id)))
  if (length(ids) == 1) {
    return(list(id = ids, dz_name = same[[1]]$name, why = "exact name"))
  }
  list(id = NA_character_, dz_name = NA_character_,
       why = if (length(ids) == 0) "no artist with that name on the song" else "several artists with that name")
}

# ---- Read the saved data ----------------------------------------------------

artists_path <- file.path(STATE_DIR, "artists.csv")
ARTISTS <- read_state(artists_path)
META    <- read_state(file.path(STATE_DIR, "playlists_meta.csv"))

pl_ids <- META$playlist_id[META$name %in% SOURCE_PLAYLISTS]
if (length(pl_ids) == 0) stop("No saved copies of the source playlists found in state/.")
songs <- bind_rows(lapply(pl_ids, function(pid) {
  read_state(file.path(STATE_DIR, sprintf("playlist_%s.csv", pid)))
}))
songs <- songs |>
  filter(!is.na(isrc), nzchar(isrc), !is.na(artist_ids)) |>
  distinct(isrc, .keep_all = TRUE)

# One row per song and artist on it, with "solo" = the artist is alone on it.
ids_split <- strsplit(songs$artist_ids, "|", fixed = TRUE)
song_artists <- tibble(
  spotify_id = unlist(ids_split),
  isrc       = rep(songs$isrc, lengths(ids_split)),
  solo       = rep(lengths(ids_split) == 1, lengths(ids_split))
)

todo <- ARTISTS |> filter(match %in% CHECK_TYPES)
message(nrow(todo), " artists to check (", paste(CHECK_TYPES, collapse = " or "), ").")
message(if (SAVE_MATCHES) "Accepted matches WILL be saved in state/artists.csv."
        else "Report only: state/artists.csv is not changed.")

# ---- Check each artist ------------------------------------------------------

report <- vector("list", nrow(todo))
for (k in seq_len(nrow(todo))) {
  a <- todo[k, ]
  mine <- song_artists |>
    filter(spotify_id == a$spotify_id) |>
    arrange(desc(solo))                       # solo songs first
  n_solo <- sum(mine$solo)
  mine <- head(mine, MAX_SONGS_PER_ARTIST)
  needed <- min(SONGS_NEEDED, nrow(mine))

  found <- character()
  dz_names <- character()
  notes <- character()
  for (s in seq_len(nrow(mine))) {
    r <- deezer_artist_for_song(mine$isrc[s], a$name, mine$solo[s])
    notes <- c(notes, r$why)
    if (!is.na(r$id)) {
      found <- c(found, r$id)
      dz_names[r$id] <- r$dz_name
    }
    if (length(unique(found)) > 1) break                       # conflict: stop
    if (needed > 0 && length(found) >= needed) break           # enough songs agree
  }

  ids <- unique(found)
  result <- if (nrow(mine) == 0) "no songs with ISRC"
    else if (length(ids) > 1) "conflict"
    else if (length(ids) == 1 && length(found) >= needed) "matched"
    else if (length(ids) == 1) "only one song agrees"
    else "not found"
  dz_id   <- if (result %in% c("matched", "only one song agrees", "conflict")) paste(ids, collapse = " / ") else NA_character_
  dz_name <- if (!is.na(dz_id)) paste(unname(dz_names[ids]), collapse = " / ") else NA_character_

  report[[k]] <- tibble(
    spotify_id     = a$spotify_id,
    name           = a$name,
    old_match      = a$match,
    old_deezer_id  = a$deezer_id,
    result         = result,
    deezer_id      = dz_id,
    deezer_name    = dz_name,
    name_differs   = if (result == "matched") norm(dz_name) != norm(a$name) else NA,
    changed_artist = if (result == "matched") !identical(a$deezer_id, dz_id) else NA,
    solo_songs     = n_solo,
    songs_checked  = length(notes),
    songs_agreeing = if (length(ids) == 1) length(found) else 0L,
    notes          = paste(unique(notes), collapse = "; ")
  )
  if (k %% 50 == 0) message("  checked ", k, " of ", nrow(todo))
}
report <- bind_rows(report)

# ---- Save -------------------------------------------------------------------

message("Results:")
print(table(report$result))

order_res <- c("matched", "only one song agrees", "conflict", "not found", "no songs with ISRC")
report <- report[order(match(report$result, order_res), tolower(report$name)), ]
dir.create(dirname(REPORT_FILE), showWarnings = FALSE, recursive = TRUE)
write_state(report, REPORT_FILE)
message("Report saved in ", REPORT_FILE)

if (SAVE_MATCHES) {
  ok <- report |> filter(result == "matched")
  i  <- match(ok$spotify_id, ARTISTS$spotify_id)
  ARTISTS$deezer_id[i]    <- ok$deezer_id
  ARTISTS$deezer_name[i]  <- ok$deezer_name
  ARTISTS$match[i]        <- "matched"
  ARTISTS$matched_on[i]   <- TODAY
  ARTISTS$last_checked[i] <- NA   # so the daily run checks them on Deezer next time

  # Same order as the daily run writes it: problems first, then matches.
  rank <- match(ifelse(is.na(ARTISTS$match), "(none)", ARTISTS$match),
                c("not_found", "(none)", "uncertain", "name", "matched", "manual"))
  write_state(ARTISTS[order(rank, tolower(ARTISTS$name)), ], artists_path)
  message(nrow(ok), " matches saved in state/artists.csv.")
}
