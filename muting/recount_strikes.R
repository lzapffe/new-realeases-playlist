# =============================================================================
# recount_strikes.R  (ONE-TIME: delete this file and its workflow once the
# recount has been saved)
#
# Goal: redo the mute strikes for the two weekly playlists judged so far
# (week 41, judged 19 Oct, and week 42, judged 19 Nov) with the new rule,
# because they were counted per release under the old rule.
#
# The new rule, per weekly playlist and per artist that follows in your
# source playlists ("your artists"):
#   - you saved at least one song from that week with the artist on it
#     (as main or featured artist): strikes go back to 0,
#   - you saved none of the songs with the artist on it (main or featured):
#     +1 strike, however many songs they had that week.
# 5 strikes in a row = muted (MUTE_AFTER_MISSES in spotify_new_releases.R).
#
# Where the data comes from:
#   - The daily run deletes a week's song list from state/week_songs.csv once
#     the week is judged, but the old versions are still in the repository's
#     git history. WEEK_SOURCES below names the commit that still holds each
#     week (found 19 Nov 2026).
#   - "Saved" is checked against your source playlists as they are NOW
#     (state/playlist_<id>.csv), the same way the daily run does it: the same
#     Spotify song, or exactly the same title and artists.
#
# What it does:
#   - Starts every artist on those weeks at 0 and applies week 41, then 42.
#   - Muted artists whose new count is below 5 are unmuted.
#   - Always writes muting/recount_report.csv (one row per artist on those
#     weeks, plus anyone who had strikes before) so you can check it.
#   - Only when SAVE_RECOUNT is true: writes the new counts to
#     state/artists.csv and the muted list to state/muted_artists.csv.
#
# Safety: it stops without saving if any other week has been judged since,
# because then this recount would wipe out that week's strikes.
#
# Uses NO Spotify or Deezer requests. Needs the full git history (the
# workflow fetches it). Run from the repository's top folder.
# =============================================================================

# Load the packages. suppressPackageStartupMessages() hides their start-up
# messages so the log stays readable.
#   dplyr  - filtering, grouping and combining tables
#   purrr  - map() for working with lists
#   tibble - the table format used throughout
suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
})

# ---- Settings ---------------------------------------------------------------

# Playlists whose artists the daily run follows (same names as in
# spotify_new_releases.R).
SOURCE_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")

# Same as MUTE_AFTER_MISSES in spotify_new_releases.R.
MUTE_AFTER_MISSES <- 5

# The judged weeks, oldest first, and a commit where state/week_songs.csv
# still holds that week's songs (the last commit before it was judged).
WEEK_SOURCES <- tibble(
  week   = c("New releases week 41 2026", "New releases week 42 2026"),
  commit = c("b9a3999ac417b1f964d15eace7de07b4683c000c",
             "f63d809b1604b5c39912d8b5e7e5bd5361e62524")
)

# Save the results? Set by the workflow's "save" tick box; FALSE = report only.
SAVE <- identical(toupper(Sys.getenv("SAVE_RECOUNT")), "TRUE")

# ---- Helpers (same file format as the daily script) -------------------------

# read_csv_chr(): read a CSV file with every column as text and empty cells
# as NA, keeping names like "Røyksopp" intact.
read_csv_chr <- function(path) {
  as_tibble(read.csv(path, colClasses = "character", na.strings = "",
                     fileEncoding = "UTF-8", check.names = FALSE))
}

# write_csv_chr(): save a table the same way the daily script does (empty
# values as empty cells, UTF-8).
write_csv_chr <- function(df, path) {
  write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# dup_key(): the "same title and same artists" key, exactly as in the daily
# script, so a saved album version of a single also counts as saved.
dup_key <- function(title, artists) paste(title, artists, sep = "\u001F")

# old_week_songs(): read state/week_songs.csv as it was in one commit, and
# keep only the rows of one week. Stops with a clear message if git can't
# find that commit (e.g. the history wasn't fetched).
old_week_songs <- function(commit, wk) {
  tmp <- tempfile(fileext = ".csv")
  status <- system2("git", c("show", paste0(commit, ":state/week_songs.csv")),
                    stdout = tmp, stderr = FALSE)
  if (!identical(status, 0L) || !file.exists(tmp) || file.size(tmp) == 0) {
    stop("Could not read state/week_songs.csv from commit ", commit,
         ". Is the full git history there (fetch-depth: 0 in the workflow)?")
  }
  read_csv_chr(tmp) |> filter(week == wk)
}

# ---- 1. Safety check: only weeks 41 and 42 may be judged --------------------

published <- read_csv_chr("state/published.csv")
judged    <- published$week[!is.na(published$judged_on)]
extra     <- setdiff(judged, WEEK_SOURCES$week)
if (length(extra) > 0) {
  stop("Another week has been judged since the recount was written (",
       paste(extra, collapse = ", "), "). Nothing was changed. ",
       "Ask Claude to add that week to WEEK_SOURCES first.")
}

# ---- 2. Your saved songs (the source playlists, as they are now) ------------

# Find each source playlist's saved copy through playlists_meta.csv, and
# warn if a copy has fewer songs than Spotify reported (not fully read).
meta <- read_csv_chr("state/playlists_meta.csv")
src  <- map(SOURCE_PLAYLISTS, function(nm) {
  row <- meta |> filter(name == nm)
  if (nrow(row) == 0) stop("No saved copy found for '", nm, "'.")
  df <- read_csv_chr(sprintf("state/playlist_%s.csv", row$playlist_id[1]))
  if (!is.na(row$n_items[1]) && nrow(df) < as.integer(row$n_items[1])) {
    message("Warning: the copy of '", nm, "' has ", nrow(df), " of ",
            row$n_items[1], " songs, so a few saves may be missed.")
  }
  df
}) |> bind_rows()

saved_uris <- src$uri
saved_keys <- dup_key(src$title, src$artists)

# "Your artists" = every artist ID that appears in the source playlists.
my_ids <- unique(unlist(strsplit(src$artist_ids[!is.na(src$artist_ids)], "|", fixed = TRUE)))
my_ids <- my_ids[nzchar(my_ids)]
message(nrow(src), " saved songs and ", length(my_ids), " artists in your source playlists.")

# ---- 3. Recount, week by week -----------------------------------------------

# strikes: the running count per artist (name = Spotify artist ID), starting
# at 0 for everyone. results: what happened to each artist in each week.
strikes <- setNames(numeric(0), character(0))
results <- list()

for (w in seq_len(nrow(WEEK_SOURCES))) {
  wk    <- WEEK_SOURCES$week[w]
  songs <- old_week_songs(WEEK_SOURCES$commit[w], wk)
  if (nrow(songs) == 0) stop("No songs found for '", wk, "' in its commit.")

  # Was each song saved, and who is on it?
  songs$saved <- songs$uri %in% saved_uris | dup_key(songs$title, songs$artists) %in% saved_keys
  ids <- strsplit(ifelse(is.na(songs$artist_ids), "", songs$artist_ids), "|", fixed = TRUE)

  # One row per song and artist, only your artists, then one row per artist:
  # was any song with them saved?
  per_artist <- tibble(spotify_id = as.character(unlist(ids)),
                       saved      = rep(songs$saved, lengths(ids))) |>
    filter(spotify_id %in% my_ids) |>
    group_by(spotify_id) |>
    summarise(saved = any(saved), .groups = "drop")

  # Apply the rule: saved -> 0, not saved -> +1.
  before <- strikes[per_artist$spotify_id]
  before[is.na(before)] <- 0
  after  <- ifelse(per_artist$saved, 0, before + 1)
  strikes[per_artist$spotify_id] <- after

  results[[wk]] <- tibble(spotify_id = per_artist$spotify_id,
                          result = ifelse(per_artist$saved, "saved", "strike"))
  message(sprintf("%s: %d songs, %d saved; %d artist(s) saved, %d strike(s).",
                  wk, nrow(songs), sum(songs$saved), sum(per_artist$saved),
                  sum(!per_artist$saved)))
}

# ---- 4. Compare with the current counts and build the report ----------------

artists  <- read_csv_chr("state/artists.csv")
old_miss <- suppressWarnings(as.integer(artists$misses))
old_miss[is.na(old_miss)] <- 0L

# Everyone on the two weeks gets the recounted number; everyone else keeps
# what they have (it should be 0 or empty, since only these weeks were judged).
on_weeks <- artists$spotify_id %in% names(strikes)
new_miss <- old_miss
new_miss[on_weeks] <- as.integer(strikes[artists$spotify_id[on_weeks]])

# Muted artists below the limit are unmuted.
was_muted <- !is.na(artists$muted_on)
unmute    <- was_muted & new_miss < MUTE_AFTER_MISSES

# One column per week with that week's result for the artist.
report <- tibble(spotify_id = artists$spotify_id, name = artists$name,
                 old_strikes = old_miss)
for (wk in names(results)) {
  col <- sub("New releases ", "", wk)
  report[[col]] <- results[[wk]]$result[match(report$spotify_id, results[[wk]]$spotify_id)]
}
report$new_strikes <- new_miss
report$was_muted   <- was_muted
report$unmuted     <- unmute
report <- report[on_weeks | old_miss > 0 | was_muted, ] |>
  arrange(desc(new_strikes), name)

dir.create("muting", showWarnings = FALSE)
write_csv_chr(report, "muting/recount_report.csv")

# Summary in the log.
message("\nRecount result (strikes in a row):")
print(table(new_strikes = report$new_strikes))
message(sum(report$old_strikes != report$new_strikes), " artist(s) get a different count.")
if (any(unmute)) message("Unmuted: ", paste(artists$name[unmute], collapse = ", "))
message("Report saved in muting/recount_report.csv.")

# ---- 5. Save (only when asked) ----------------------------------------------

if (SAVE) {
  # Write the counts as text, like the daily script, and clear the mute
  # details of the unmuted artists.
  changed <- on_weeks & (old_miss != new_miss | is.na(artists$misses))
  artists$misses[changed]        <- as.character(new_miss[changed])
  artists$muted_on[unmute]       <- NA
  artists$songs_at_mute[unmute]  <- NA
  write_csv_chr(artists, "state/artists.csv")

  # Refresh the read-only list of muted artists, the same way the daily
  # script does (newest first).
  muted <- artists[!is.na(artists$muted_on), c("spotify_id", "name", "muted_on", "misses")]
  write_csv_chr(muted[order(muted$muted_on, decreasing = TRUE), ], "state/muted_artists.csv")
  message("Saved: new counts in state/artists.csv, ", sum(unmute), " artist(s) unmuted.")
} else {
  message("Report only: nothing in state/ was changed. Run again with 'save' ticked to save.")
}
