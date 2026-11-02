# =============================================================================
# mood_scores.R  (mood playlists, step 1: analysis)
#
# Gives every song in Everything everything Part 1/2 Essentia's mood scores,
# a batch per run, and writes an Excel overview of the mood categories.
# Uses no Spotify requests: the songs come from the new-releases script's
# saved playlist copies (state/playlist_<id>.csv), the previews from Deezer.
#
# Run by the workflow "Mood playlists: analysis" in two parts, with the
# Python script essentia_scores.py in between:
#   Rscript moods/mood_scores.R prepare
#     - lists the songs that have no scores yet and writes the next batch
#       (BATCH_SIZE songs) to moods/work/scores/batch.csv
#   python moods/essentia_scores.py
#     - finds each preview on Deezer and analyses it with Essentia
#   Rscript moods/mood_scores.R save
#     - adds the new scores to moods/scores/scores.csv, notes songs without a
#       preview in moods/scores/no_preview.csv, and writes the Excel overview
#       moods/mood_categories.xlsx
# Run it again until the overview's "progress" sheet says nothing is left.
# Later runs only analyse songs added to Everything everything since.
# =============================================================================

# Load the packages, without their start-up messages.
#   dplyr   - filtering and combining tables
#   writexl - writing the Excel overview
suppressPackageStartupMessages({
  library(dplyr)
  library(writexl)
})

# ---- Settings ---------------------------------------------------------------
MAIN_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")
BATCH_SIZE     <- 2500   # songs per run (the Python step also stops after 5 hours)
RETRY_DAYS     <- 180    # songs without a preview are tried again after this
STATE_DIR      <- "moods/scores"
WORK_DIR       <- "moods/work/scores"
OVERVIEW_FILE  <- "moods/mood_categories.xlsx"

STEP <- commandArgs(trailingOnly = TRUE)[1]
if (!STEP %in% c("prepare", "save")) stop("Run with 'prepare' or 'save'.", call. = FALSE)
dir.create(STATE_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(WORK_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- Helpers ----------------------------------------------------------------

# read_csv_text(): read a CSV with every column as text, or NULL if the file
# doesn't exist. write_csv_utf8(): save a table as CSV (UTF-8, empty = "").
read_csv_text <- function(path) {
  if (!file.exists(path)) return(NULL)
  as_tibble(read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8",
                     check.names = FALSE))
}
write_csv_utf8 <- function(df, path) {
  write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# The songs in Everything everything Part 1/2, from the saved copies (free).
# One row per song: Spotify ID, title, first artist and ISRC (for Deezer).
meta  <- read.csv("state/playlists_meta.csv", colClasses = "character")
copies <- bind_rows(lapply(meta$playlist_id[meta$name %in% MAIN_PLAYLISTS], function(id) {
  read_csv_text(sprintf("state/playlist_%s.csv", id))
}))
if (!"isrc" %in% names(copies)) copies$isrc <- NA_character_
songs <- copies |>
  transmute(spotify_id = sub("^spotify:track:", "", uri),
            title,
            artist = sub("\\|.*$", "", coalesce(artist_names, artists)),
            isrc) |>
  filter(!is.na(spotify_id), nzchar(spotify_id)) |>
  distinct(spotify_id, .keep_all = TRUE)

# The saved results so far: the scores, and the songs without a preview.
scores  <- read_csv_text(file.path(STATE_DIR, "scores.csv"))
missing <- read_csv_text(file.path(STATE_DIR, "no_preview.csv")) %||%
  tibble(spotify_id = character(), reason = character(), checked_on = character())

# ==== PART 1: prepare =========================================================
if (STEP == "prepare") {

  # Songs still to do: no scores yet, and not a "no preview" song that was
  # checked within the last RETRY_DAYS days.
  recent_missing <- missing$spotify_id[as.Date(missing$checked_on) > Sys.Date() - RETRY_DAYS]
  todo <- songs |>
    filter(!spotify_id %in% (scores$spotify_id %||% character()),
           !spotify_id %in% recent_missing)
  batch <- head(todo, BATCH_SIZE)
  write_csv_utf8(batch, file.path(WORK_DIR, "batch.csv"))
  message(nrow(songs), " songs in Everything everything; ",
          length(scores$spotify_id), " already have scores; ",
          nrow(todo), " still to do. This run's batch: ", nrow(batch), " songs.")
}

# ==== PART 2: save ============================================================
if (STEP == "save") {

  # 1. Add the new scores (with title, artist and today's date) to the saved
  #    ones. A song analysed again replaces its old row.
  new <- read_csv_text(file.path(WORK_DIR, "scores_new.csv"))
  if (!is.null(new) && nrow(new) > 0) {
    new <- songs |>
      select(spotify_id, title, artist) |>
      inner_join(new, by = "spotify_id") |>
      mutate(scored_on = as.character(Sys.Date()), .after = artist)
    scores <- bind_rows(filter(scores %||% new[0, ], !spotify_id %in% new$spotify_id), new)
    write_csv_utf8(scores, file.path(STATE_DIR, "scores.csv"))
  }
  message(nrow(new %||% tibble()), " new songs analysed; ", nrow(scores %||% tibble()), " in total.")

  # 2. Note the songs without a usable preview, with today's date, so they
  #    are skipped until RETRY_DAYS have passed.
  miss_new <- read_csv_text(file.path(WORK_DIR, "no_preview.csv"))
  if (!is.null(miss_new) && nrow(miss_new) > 0) {
    missing <- bind_rows(filter(missing, !spotify_id %in% miss_new$spotify_id),
                         mutate(miss_new, checked_on = as.character(Sys.Date())))
    write_csv_utf8(missing, file.path(STATE_DIR, "no_preview.csv"))
  }

  # 3. The Excel overview. Only written when there are scores.
  if (!is.null(scores) && nrow(scores) > 0) {
    num_cols <- grep("^(ess|tag)_", names(scores), value = TRUE)
    sc <- mutate(scores, across(all_of(num_cols), as.numeric))

    # Sheet "categories": one row per category, with where its scores lie in
    # your library and the 5 songs that score highest. "top 15 % from" is the
    # score a song needs to be in the top 15 % for that category.
    categories <- bind_rows(lapply(num_cols, function(col) {
      x   <- sc[[col]]
      top <- sc |> arrange(desc(.data[[col]])) |> head(5)
      tibble(category        = sub("^(ess|tag)_", "", col),
             kind            = if (startsWith(col, "ess_")) "main mood" else "mood/theme tag",
             column          = col,
             median          = round(median(x, na.rm = TRUE), 3),
             `top 25 % from` = round(quantile(x, 0.75, na.rm = TRUE), 3),
             `top 15 % from` = round(quantile(x, 0.85, na.rm = TRUE), 3),
             `top 5 % from`  = round(quantile(x, 0.95, na.rm = TRUE), 3),
             highest         = round(max(x, na.rm = TRUE), 3),
             `top 5 songs`   = paste(sprintf("%s - %s", top$artist, top$title), collapse = "; "))
    })) |>
      arrange(kind != "main mood", category)

    # Sheet "progress": how far the analysis has come.
    no_prev  <- sum(songs$spotify_id %in% missing$spotify_id & !songs$spotify_id %in% sc$spotify_id)
    progress <- tibble(
      what  = c("songs in Everything everything", "analysed", "no preview on Deezer (retried later)",
                "still to do", "last updated"),
      value = c(nrow(songs), sum(songs$spotify_id %in% sc$spotify_id), no_prev,
                nrow(songs) - sum(songs$spotify_id %in% sc$spotify_id) - no_prev,
                format(Sys.time(), "%Y-%m-%d %H:%M", tz = "Europe/Oslo")))

    # Sheet "scores": every analysed song with all its scores, for browsing
    # and filtering in Excel.
    write_xlsx(list(progress = mutate(progress, value = as.character(value)),
                    categories = categories,
                    scores = sc),
               OVERVIEW_FILE)
    message("Overview written to ", OVERVIEW_FILE, ".")
  }
}
