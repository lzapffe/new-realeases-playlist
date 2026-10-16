# =============================================================================
# find_duplicates.R
#
# Finds songs that are in "Everything everything" Part 1/2 more than once,
# using the saved copies in state/ (no Spotify requests at all).
#
#   1. Read the saved copy of each source playlist (state/playlist_<id>.csv),
#      finding the IDs by name in state/playlists_meta.csv.
#   2. Exact duplicates: same title and same artists. Capital letters, extra
#      spaces and the order of the artists don't matter.
#   3. Possible duplicates: the same song in another version, e.g.
#      "Song", "Song - Remastered 2011" and "Song (Live)". The version tags
#      ("- ..." and "(...)"/"[...]") are removed from the title, and the main
#      (first) artist must be the same. Groups that are already exact
#      duplicates in full are left out of this list.
#   4. Save both lists in duplicates/ (exact_duplicates.csv and
#      possible_duplicates.csv), one row per song, with a group number so
#      the copies of one song sit together.
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

# The playlists to check (the same names as in spotify_new_releases.R).
SOURCE_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")
STATE_DIR <- "state"
OUT_DIR   <- "duplicates"

# read_csv_utf8(): read a CSV with everything as text, keeping Ø, é, etc.
read_csv_utf8 <- function(path) {
  read.csv(path, colClasses = "character", na.strings = character(0),
           encoding = "UTF-8", check.names = FALSE)
}

# 1. Read the saved copies, adding which playlist each song is in.
meta <- read_csv_utf8(file.path(STATE_DIR, "playlists_meta.csv"))
songs <- bind_rows(lapply(SOURCE_PLAYLISTS, function(name) {
  id <- meta$playlist_id[meta$name == name][1]
  if (is.na(id)) stop("No saved copy found for '", name, "'.")
  read_csv_utf8(file.path(STATE_DIR, sprintf("playlist_%s.csv", id))) |>
    mutate(playlist = name)
}))
if (any(meta$snapshot[meta$name %in% SOURCE_PLAYLISTS] == "")) {
  message("Note: a saved copy is still being updated, so the newest songs may be missing.")
}
message("Read ", nrow(songs), " songs from ", length(SOURCE_PLAYLISTS), " playlists.")

# clean(): lower case, no punctuation, single spaces, so that "Don't Stop"
# and "dont stop " count as the same.
clean <- function(x) {
  x <- tolower(x)
  x <- gsub("[[:punct:]’‘“”]", "", x)
  trimws(gsub("\\s+", " ", x))
}

# strip_version(): remove version tags from a title: anything in brackets,
# and anything after " - " (Spotify writes "Song - Remastered 2011").
strip_version <- function(x) {
  x <- gsub("\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", "", x, perl = TRUE)
  x <- sub("\\s+-\\s+.*$", "", x)
  clean(x)
}

# sorted_artists(): the artists' Spotify IDs in alphabetical order, so the
# order on the song doesn't matter.
sorted_artists <- function(ids) {
  vapply(strsplit(ids, "|", fixed = TRUE),
         function(v) paste(sort(v), collapse = "|"), character(1))
}

songs <- songs |>
  mutate(exact_key = paste(clean(title), sorted_artists(artist_ids)),
         main_artist = sub("\\|.*$", "", artist_ids),
         loose_key = paste(strip_version(title), main_artist)) |>
  filter(title != "")   # skips local files and removed songs without data

# group_ids(): number each group of duplicates (1, 2, 3, ...).
group_ids <- function(key) match(key, unique(key))

# 2. Exact duplicates: every key that appears more than once.
exact <- songs |>
  group_by(exact_key) |> filter(n() > 1) |> ungroup() |>
  arrange(clean(artists), clean(title)) |>
  mutate(group = group_ids(exact_key)) |>
  arrange(group) |>
  mutate(same_spotify_song = duplicated(uri) | duplicated(uri, fromLast = TRUE))

# 3. Possible duplicates: same title without version tags and same main
# artist, but more than one exact version (so it's not just an exact one).
possible <- songs |>
  group_by(loose_key) |>
  filter(n() > 1, n_distinct(exact_key) > 1) |>
  ungroup() |>
  arrange(clean(artists), strip_version(title), clean(title)) |>
  mutate(group = group_ids(loose_key)) |>
  arrange(group, clean(title))

# 4. Save the lists, with only the columns that help when deleting.
save_list <- function(df, file) {
  dir.create(OUT_DIR, showWarnings = FALSE)
  out <- df |> select(group, title, artists, playlist, any_of("same_spotify_song"), uri)
  write.csv(out, file.path(OUT_DIR, file), row.names = FALSE, fileEncoding = "UTF-8")
}
save_list(exact, "exact_duplicates.csv")
save_list(possible, "possible_duplicates.csv")

message("Exact duplicates: ", n_distinct(exact$group), " songs (", nrow(exact), " rows).")
message("Possible duplicates: ", n_distinct(possible$group), " songs (", nrow(possible), " rows).")
message("Saved in ", OUT_DIR, "/exact_duplicates.csv and ", OUT_DIR, "/possible_duplicates.csv.")
