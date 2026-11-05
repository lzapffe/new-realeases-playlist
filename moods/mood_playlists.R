# =============================================================================
# mood_playlists.R  (mood playlists, step 2: building the playlists)
#
# Makes Spotify playlists by mood from the songs in Everything everything
# Part 1/2, using the Essentia scores from step 1 (moods/scores/scores.csv).
# You decide which playlists to make in the Excel file moods/mood_playlists.xlsx
# (one row per playlist); each run builds the rows marked build = yes.
#
# Two kinds of rows:
#   - mood rule:    songs that score high on the "high" moods and below
#                   average on the "low" moods, best first.
#   - like playlist: songs whose mood profile is closest to one of your own
#                   playlists (for example "Semi-background songs").
#
# Running a row again replaces the songs in the playlist it made before (it
# doesn't make a second one), unless you have deleted that playlist.
#
# Spotify requests: about 1 per 100 songs, plus 2 per playlist and a few to
# read your list of playlists and any "like" playlists. The run stops before
# MAX_SPOTIFY_REQUESTS. This script never writes to mood_playlists.xlsx; what
# it made is saved in moods/playlists_made.csv and moods/playlist_songs.csv.
#
# Run by the workflow "Mood playlists: build" (started by hand).
# Needs: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REFRESH_TOKEN.
# =============================================================================

# Load the packages, without their start-up messages.
#   httr2  - web requests to Spotify
#   dplyr  - filtering, ranking and combining tables
#   purrr  - working with the lists Spotify returns
#   tibble - the table format used throughout
#   readxl - reading your choices from the Excel file
suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(tibble)
  library(readxl)
})

# ---- Settings ---------------------------------------------------------------
CHOICES_FILE         <- "moods/mood_playlists.xlsx"   # you edit this one
SCORES_FILE          <- "moods/scores/scores.csv"     # from step 1
MADE_FILE            <- "moods/playlists_made.csv"    # the playlists this script made
SONGS_FILE           <- "moods/playlist_songs.csv"    # which songs each playlist got
MAIN_PLAYLISTS       <- c("Everything everything - Part 1", "Everything everything - Part 2")
MAX_SPOTIFY_REQUESTS <- 100     # per run; the run stops before this
PLAYLIST_PUBLIC      <- FALSE   # FALSE = private playlists
MIN_LIKE_SONGS       <- 5       # a "like" playlist needs at least this many scored songs
REPO_NAME            <- "new-realeases-playlist"
SP                   <- "https://api.spotify.com/v1"

# Log this run's Spotify requests in state/spotify_request_log.csv when it
# ends (shared helper, see spotify_log.R).
source("spotify_log.R")
SPOTIFY_USED <- 0
spotify_log_start("mood playlists", function() SPOTIFY_USED)

# ---- Helpers ----------------------------------------------------------------

# "a %||% b" returns a, unless a is missing (NULL or empty), then b.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# read_csv_text(): a CSV with every column as text, or NULL if it doesn't
# exist. write_csv_utf8(): save a table as CSV (UTF-8, empty = "").
read_csv_text <- function(path) {
  if (!file.exists(path)) return(NULL)
  as_tibble(read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8",
                     check.names = FALSE))
}
write_csv_utf8 <- function(df, path) {
  write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# split_list(): "aggressive, party" -> c("aggressive", "party").
split_list <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) return(character())
  trimws(tolower(strsplit(x, "[,;]")[[1]])) |> (\(v) v[nzchar(v)])()
}

# ---- Spotify ----------------------------------------------------------------

# Log in without a browser, as in the other Spotify scripts: the refresh token
# plus the app's ID and secret give a 1-hour access token.
get_access_token <- function() {
  id      <- Sys.getenv("SPOTIFY_CLIENT_ID")
  secret  <- Sys.getenv("SPOTIFY_CLIENT_SECRET")
  refresh <- Sys.getenv("SPOTIFY_REFRESH_TOKEN")
  if (any(c(id, secret, refresh) == "")) {
    stop("Set SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET and SPOTIFY_REFRESH_TOKEN.", call. = FALSE)
  }
  resp <- request("https://accounts.spotify.com/api/token") |>
    req_auth_basic(id, secret) |>
    req_body_form(grant_type = "refresh_token", refresh_token = refresh) |>
    req_perform()
  resp_body_json(resp)$access_token
}

budget_left <- function() MAX_SPOTIFY_REQUESTS - SPOTIFY_USED

# sp(): the one place where Spotify requests are made. Counts each request,
# waits 0.5 s between them, and stops the run (saving what was made first) if
# Spotify says "too many requests" (429). Other errors go back to the caller.
sp <- function(path, method = "GET", query = list(), body = NULL) {
  if (budget_left() <= 0) stop("Request budget used up.", call. = FALSE)
  SPOTIFY_USED <<- SPOTIFY_USED + 1
  Sys.sleep(0.5)
  url <- if (startsWith(path, "http")) path else paste0(SP, path)
  req <- request(url) |>
    req_auth_bearer_token(TOKEN) |>
    req_method(method) |>
    req_error(is_error = function(r) FALSE)
  if (length(query) > 0) req <- req_url_query(req, !!!query)
  if (!is.null(body)) req <- req_body_json(req, body)
  resp <- req_perform(req)
  if (resp_status(resp) == 429) {
    spotify_log_429(resp_header(resp, "Retry-After"))
    save_all()
    stop("Spotify said 'too many requests'. What was made is saved; try again another day.",
         call. = FALSE)
  }
  resp
}

# sp_ok(): stop with Spotify's message if a request failed; else the reply.
sp_ok <- function(resp) {
  if (resp_status(resp) >= 400) {
    stop("Spotify error ", resp_status(resp), ": ", resp_body_string(resp), call. = FALSE)
  }
  if (!resp_has_body(resp)) return(list())   # e.g. "details changed" replies have no body
  resp_body_json(resp)
}

# sp_all(): follow Spotify's "next" links to get every item of a list.
sp_all <- function(path, query = list(limit = 50)) {
  items <- list()
  url <- path
  while (!is.null(url)) {
    page  <- sp_ok(sp(url, query = if (identical(url, path)) query else list()))
    items <- c(items, page$items %||% list())
    url   <- page[["next"]]
  }
  items
}

# create_playlist(): make a playlist and return its ID (newer address first,
# then the older /users/{id}/playlists, as in the other scripts).
create_playlist <- function(body) {
  resp <- sp("/me/playlists", method = "POST", body = body)
  if (resp_status(resp) %in% c(404, 405)) {
    me   <- sp_ok(sp("/me"))
    resp <- sp(sprintf("/users/%s/playlists", me$id), method = "POST", body = body)
  }
  sp_ok(resp)$id
}

# set_songs(): put exactly these songs in the playlist. The first 100 replace
# whatever was there (PUT); the rest are added 100 at a time (POST). Tries the
# new /items address first and the old /tracks one if Spotify doesn't know it.
set_songs <- function(pid, uris) {
  send <- function(method, chunk) {
    resp <- sp(sprintf("/playlists/%s/items", pid), method = method, body = list(uris = I(chunk)))
    if (resp_status(resp) %in% c(404, 405)) {
      resp <- sp(sprintf("/playlists/%s/tracks", pid), method = method, body = list(uris = I(chunk)))
    }
    sp_ok(resp)
  }
  chunks <- split(uris, ceiling(seq_along(uris) / 100))
  send("PUT", chunks[[1]])
  for (chunk in chunks[-1]) send("POST", chunk)
}

# ---- 1. Your choices and the scores (free) -------------------------------------
message("== 1. Reading your choices and the mood scores")

choices <- read_excel(CHOICES_FILE, sheet = 1, col_types = "text")
names(choices) <- tolower(trimws(names(choices)))
needed <- c("build", "playlist name", "type", "high", "low", "like playlist", "how many")
if (!all(needed %in% names(choices))) {
  stop("The first sheet of ", CHOICES_FILE, " needs the columns: ",
       paste(needed, collapse = ", "), ".", call. = FALSE)
}
todo <- choices |> filter(tolower(trimws(build)) == "yes", !is.na(`playlist name`))
message(nrow(todo), " playlist(s) marked build = yes.")
if (nrow(todo) == 0) quit(save = "no")

# The scores, as numbers, turned into percentiles (0 = lowest in your library,
# 1 = highest), so main moods and small tags can be compared fairly.
scores <- read_csv_text(SCORES_FILE)
if (is.null(scores)) stop("No scores yet: run 'Mood playlists: analysis' first.", call. = FALSE)
score_cols <- grep("^(ess|tag)_", names(scores), value = TRUE)
pct <- scores |>
  mutate(across(all_of(score_cols), ~ percent_rank(as.numeric(.x))))

# Only songs that are still in Everything everything (from the saved copies
# in state/, free); songs you have removed since the analysis are left out.
meta   <- read.csv("state/playlists_meta.csv", colClasses = "character")
copies <- bind_rows(lapply(meta$playlist_id[meta$name %in% MAIN_PLAYLISTS], function(id) {
  read_csv_text(sprintf("state/playlist_%s.csv", id))
}))
if (!"isrc" %in% names(copies)) copies$isrc <- NA_character_
library_ids <- unique(sub("^spotify:track:", "", copies$uri))
id_by_isrc  <- copies |>
  transmute(isrc, spotify_id = sub("^spotify:track:", "", uri)) |>
  filter(!is.na(isrc)) |>
  distinct(isrc, .keep_all = TRUE)
pct <- filter(pct, spotify_id %in% library_ids)
message(nrow(pct), " songs with scores in Everything everything.")

# column_for(): a category name from the Excel file -> its score column. A
# main mood wins over a tag with the same name (e.g. "happy" = ess_happy).
column_for <- function(name) {
  name <- gsub("\\s+", "_", name)
  if (paste0("ess_", name) %in% score_cols) return(paste0("ess_", name))
  if (paste0("tag_", name) %in% score_cols) return(paste0("tag_", name))
  if (name %in% score_cols) return(name)
  NA_character_
}

# as_size(): the "how many" cell as text: "15%" for a percentage, "300" for a
# number of songs. Excel stores a cell typed as 15% as the number 0.15, so a
# number between 0 and 1 is read as a percentage too.
as_size <- function(x) {
  x <- gsub("\\s+", "", coalesce(x, ""))
  v <- suppressWarnings(as.numeric(x))
  if (!is.na(v) && v > 0 && v <= 1) return(paste0(round(v * 100, 2), "%"))
  x
}

# how_many(): "15%" -> 15 % of the scored songs; "300" -> 300 songs.
how_many <- function(x) {
  if (grepl("%$", x)) return(round(nrow(pct) * as.numeric(sub("%$", "", x)) / 100))
  suppressWarnings(as.integer(x))
}

# size_label(): the part of the title that says how big the playlist is.
size_label <- function(x) {
  if (grepl("%$", x)) sprintf("top %s %%", sub("%$", "", x)) else sprintf("%s songs", x)
}

# What earlier runs made (free). save_all() writes both files; it is also
# called if Spotify blocks the run, so nothing made is lost.
MADE  <- read_csv_text(MADE_FILE) %||%
  tibble(name = character(), playlist_id = character(), title = character(),
         rule = character(), n_songs = character(), made_on = character())
SONGS <- read_csv_text(SONGS_FILE) %||%
  tibble(name = character(), rank = character(), spotify_id = character(),
         title = character(), artist = character(), match = character())
save_all <- function() {
  write_csv_utf8(MADE, MADE_FILE)
  write_csv_utf8(SONGS, SONGS_FILE)
}

# ---- 2. Spotify: your playlists ----------------------------------------------
message("== 2. Reading your list of playlists on Spotify")
TOKEN <- get_access_token()
my_playlists <- sp_all("/me/playlists")
my_ids <- map_chr(my_playlists, function(p) p$id %||% NA_character_)
message(length(my_playlists), " playlists found (", SPOTIFY_USED, " requests).")

# ---- 3. Pick the songs and build each playlist --------------------------------
message("== 3. Building the playlists")

for (i in seq_len(nrow(todo))) {
  row  <- todo[i, ]
  name <- trimws(row$`playlist name`)
  type <- tolower(trimws(coalesce(row$type, "")))
  size <- as_size(row$`how many`)
  n    <- suppressWarnings(how_many(size))
  if (is.na(n) || n < 1) { message("  ", name, ": 'how many' must be like 15% or 300; skipped."); next }

  if (type == "mood rule") {
    # Mood rule: the average percentile of the "high" moods, among the songs
    # that are below the middle (50th percentile) on every "low" mood.
    high_names <- split_list(row$high)
    low_names  <- split_list(row$low)
    high <- map_chr(high_names, column_for)
    low  <- map_chr(low_names, column_for)
    bad  <- c(high_names[is.na(high)], low_names[is.na(low)])
    if (length(bad) > 0) { message("  ", name, ": unknown mood(s) ", paste(bad, collapse = ", "), "; skipped."); next }
    if (length(high) == 0) { message("  ", name, ": needs at least one 'high' mood; skipped."); next }
    cand <- pct
    for (col in low) cand <- filter(cand, .data[[col]] < 0.5)
    cand <- cand |> mutate(match = rowMeans(across(all_of(high))))
    rule <- paste0("high: ", paste(high_names, collapse = ", "),
                   if (length(low_names)) paste0("; low: ", paste(low_names, collapse = ", ")) else "")

  } else if (type == "like playlist") {
    # Like playlist: read your playlist, find its songs among the scored ones
    # (by Spotify ID, or by ISRC for another version of the same recording),
    # and rank the other songs by how close their mood profile (all
    # categories, as percentiles) is to that playlist's average profile.
    ref_name <- trimws(coalesce(row$`like playlist`, ""))
    ref <- detect(my_playlists, function(p) identical(p$name, ref_name))
    if (is.null(ref)) { message("  ", name, ": no playlist named '", ref_name, "' found; skipped."); next }
    items  <- sp_all(sprintf("/playlists/%s/items", ref$id))
    tracks <- keep(compact(map(items, function(it) it$item %||% it$track)), function(t) !is.null(t$id))
    ref_ids  <- map_chr(tracks, "id")
    ref_isrc <- map_chr(tracks, function(t) t$external_ids$isrc %||% NA_character_)
    ref_ids  <- unique(c(ref_ids, id_by_isrc$spotify_id[id_by_isrc$isrc %in% ref_isrc]))
    ref_rows <- filter(pct, spotify_id %in% ref_ids)
    message("  ", name, ": '", ref_name, "' has ", length(tracks), " songs; ", nrow(ref_rows),
            " of them have scores.")
    if (nrow(ref_rows) < MIN_LIKE_SONGS) {
      message("  ", name, ": fewer than ", MIN_LIKE_SONGS, " scored songs to compare with; skipped.")
      next
    }
    profile <- colMeans(as.matrix(ref_rows[score_cols]))
    m    <- as.matrix(pct[score_cols])
    dist <- sqrt(rowSums((m - matrix(profile, nrow(m), length(profile), byrow = TRUE))^2))
    # The songs already in that playlist are left out ("more like" = new ones).
    cand <- pct |> mutate(match = 1 - dist / max(dist)) |> filter(!spotify_id %in% ref_ids)
    rule <- paste0("closest in mood to '", ref_name, "'")

  } else {
    message("  ", name, ": type must be 'mood rule' or 'like playlist'; skipped.")
    next
  }

  picks <- cand |> arrange(desc(match)) |> head(n)
  if (nrow(picks) == 0) { message("  ", name, ": no songs match; skipped."); next }

  # Enough requests left? Songs (1 per 100) + details/creation (2) + margin.
  cost <- ceiling(nrow(picks) / 100) + 3
  if (budget_left() < cost) {
    message("  ", name, ": needs about ", cost, " requests, only ", budget_left(),
            " left; run again another day.")
    next
  }

  # Title, description (Spotify allows 300 characters, no line breaks).
  title <- sprintf("%s (%s)", name, size_label(size))
  desc  <- substr(sprintf("Mood playlist based on the Everything everything playlists. Rule: %s; %s. Made by the %s repository.",
                          rule, size_label(size), REPO_NAME), 1, 300)

  # The playlist this row made before, if you haven't deleted it: update it.
  # Otherwise make a new one.
  pid <- MADE$playlist_id[MADE$name == name][1]
  if (!is.na(pid) && pid %in% my_ids) {
    sp_ok(sp(sprintf("/playlists/%s", pid), method = "PUT",
             body = list(name = title, description = desc, public = PLAYLIST_PUBLIC)))
    action <- "updated"
  } else {
    pid <- create_playlist(list(name = title, description = desc, public = PLAYLIST_PUBLIC))
    action <- "made"
  }
  set_songs(pid, paste0("spotify:track:", picks$spotify_id))

  # Save what was made, replacing this row's earlier record.
  MADE <- bind_rows(filter(MADE, name != !!name),
                    tibble(name = name, playlist_id = pid, title = title, rule = rule,
                           n_songs = as.character(nrow(picks)), made_on = as.character(Sys.Date())))
  SONGS <- bind_rows(filter(SONGS, name != !!name),
                     tibble(name = name, rank = as.character(seq_len(nrow(picks))),
                            spotify_id = picks$spotify_id, title = picks$title,
                            artist = picks$artist, match = as.character(round(picks$match, 3))))
  save_all()
  message("  ", action, " '", title, "' with ", nrow(picks), " songs (", SPOTIFY_USED, " requests so far).")
}

save_all()
message(sprintf("Spotify requests used this run: %d of %d.", SPOTIFY_USED, MAX_SPOTIFY_REQUESTS))
spotify_log_done()
