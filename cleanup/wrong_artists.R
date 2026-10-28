# =============================================================================
# wrong_artists.R
#
# Finds songs by "wrong" artists: a different artist with the same name as one
# of yours (e.g. the other Patricia), added before the artist check went in on
# 25 October. Uses only the saved files in state/, so no Spotify requests.
#
#   1. Your artists = every Spotify artist ID in the saved copies of
#      "Everything everything" Part 1/2 (state/playlist_<id>.csv).
#   2. A song is "wrong" when none of its artists is one of yours. Songs with a
#      collaboration or feature with one of your artists are kept. Songs with
#      no artist IDs saved are kept too (they can't be checked).
#   3. Weeks 42 and 43: the wrong songs are listed in playlist order in
#      cleanup/to_delete_week42_43.csv (nothing is removed on Spotify).
#   4. Week 44 (not built yet): the wrong songs are taken out of
#      state/staged_tracks.csv, so they are never added, and listed in
#      cleanup/removed_from_week44.csv.
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

SOURCE_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")
WEEKS     <- c("New releases week 42 2026", "New releases week 43 2026")
STATE_DIR <- "state"
OUT_DIR   <- "cleanup"

# read_state()/write_state(): the same CSV format as spotify_new_releases.R
# (everything as text, empty cells as empty, UTF-8 for names like "Røyksopp").
read_state <- function(file) {
  read.csv(file.path(STATE_DIR, file), colClasses = "character", na.strings = "",
           fileEncoding = "UTF-8", check.names = FALSE)
}
write_csv_utf8 <- function(df, path) {
  write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# split_ids(): "id1|id2" -> c("id1", "id2")
split_ids <- function(x) {
  lapply(x, function(ids) if (is.na(ids) || !nzchar(ids)) character() else strsplit(ids, "|", fixed = TRUE)[[1]])
}

# is_wrong(): TRUE when a song has artist IDs and none of them is yours.
is_wrong <- function(artist_ids, yours) {
  vapply(split_ids(artist_ids), function(ids) length(ids) > 0 && !any(ids %in% yours), logical(1))
}

# 1. Your artists, from the saved copies of the source playlists.
meta <- read_state("playlists_meta.csv")
yours <- unique(unlist(lapply(SOURCE_PLAYLISTS, function(name) {
  id <- meta$playlist_id[meta$name == name][1]
  if (is.na(id)) stop("No saved copy found for '", name, "'.")
  unlist(split_ids(read_state(sprintf("playlist_%s.csv", id))$artist_ids))
})))
message(length(yours), " artists in your source playlists.")

dir.create(OUT_DIR, showWarnings = FALSE)

# 2-3. Weeks 42 and 43: list the wrong songs in the order they were added
# (= the playlist's order).
week_songs <- read_state("week_songs.csv") |>
  filter(week %in% WEEKS)
to_delete <- week_songs |>
  filter(is_wrong(artist_ids, yours)) |>
  select(week, artists, title, release_date, uri)
write_csv_utf8(to_delete, file.path(OUT_DIR, "to_delete_week42_43.csv"))
for (wk in WEEKS) {
  message(sprintf("%s: %d of %d songs to delete.", wk,
                  sum(to_delete$week == wk), sum(week_songs$week == wk)))
}

# 4. Week 44: take the wrong songs out of the waiting list.
staged <- read_state("staged_tracks.csv")
wrong  <- is_wrong(staged$artist_ids, yours)
removed <- staged[wrong, ] |> select(artists, title, release_date, staged_on, uri)
write_csv_utf8(removed, file.path(OUT_DIR, "removed_from_week44.csv"))
write_csv_utf8(staged[!wrong, ], file.path(STATE_DIR, "staged_tracks.csv"))
message(sprintf("Week 44: %d of %d waiting songs taken out.", sum(wrong), nrow(staged)))
