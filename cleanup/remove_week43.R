# =============================================================================
# remove_week43.R  (ONE-TIME clean-up, delete on 11 November 2026)
#
# Removes the wrong-artist songs from the "New releases week 43 2026" playlist
# on Spotify. The songs are the week 43 rows of cleanup/to_delete_week42_43.csv
# (made by cleanup/wrong_artists.R; week 42 was cleaned by hand, so its rows
# are skipped).
#
#   1. Read the week 43 songs from the CSV, and the playlist's Spotify ID from
#      state/published.csv. Free.
#   2. Show how many songs the playlist has now (1 request).
#   3. Remove the songs, 100 per request (about 4 requests). Songs you already
#      deleted by hand are still in the list; Spotify should just ignore them.
#   4. Show how many songs the playlist has afterwards (1 request).
# At most 12 Spotify requests in total.
# =============================================================================

suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
})

# Settings.
WEEK                 <- "New releases week 43 2026"
LIST_FILE            <- "cleanup/to_delete_week42_43.csv"
MAX_SPOTIFY_REQUESTS <- 12
SP                   <- "https://api.spotify.com/v1"

# 1. The songs to remove and the playlist's ID, from the saved files.
to_delete <- read.csv(LIST_FILE, colClasses = "character", fileEncoding = "UTF-8") |>
  filter(week == WEEK, nzchar(uri)) |>
  distinct(uri, .keep_all = TRUE)
published <- read.csv("state/published.csv", colClasses = "character")
pid <- published$playlist_id[published$week == WEEK][1]
if (is.na(pid) || !nzchar(pid)) stop("No playlist ID for '", WEEK, "' in state/published.csv.")
message(nrow(to_delete), " songs on the list for '", WEEK, "' (playlist ", pid, ").")

# Log in to Spotify without a browser, as in the other scripts: the refresh
# token plus the app's ID and secret give a 1-hour access token.
get_access_token <- function() {
  id      <- Sys.getenv("SPOTIFY_CLIENT_ID")
  secret  <- Sys.getenv("SPOTIFY_CLIENT_SECRET")
  refresh <- Sys.getenv("SPOTIFY_REFRESH_TOKEN")
  if (any(c(id, secret, refresh) == "")) {
    stop("Set SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET and SPOTIFY_REFRESH_TOKEN.")
  }
  resp <- request("https://accounts.spotify.com/api/token") |>
    req_auth_basic(id, secret) |>
    req_body_form(grant_type = "refresh_token", refresh_token = refresh) |>
    req_perform()
  resp_body_json(resp)$access_token
}
TOKEN <- get_access_token()

# sp(): the one place where Spotify requests are made. Counts them, stops when
# the budget is used up, waits 0.5 s between requests, and stops straight away
# on "too many requests" (429). Other errors are returned to the caller.
SPOTIFY_USED <- 0
sp <- function(path, method = "GET", body = NULL) {
  if (SPOTIFY_USED >= MAX_SPOTIFY_REQUESTS) stop("Request budget used up; nothing more was sent.")
  SPOTIFY_USED <<- SPOTIFY_USED + 1
  Sys.sleep(0.5)
  req <- request(paste0(SP, path)) |>
    req_auth_bearer_token(TOKEN) |>
    req_method(method) |>
    req_error(is_error = function(r) FALSE)
  if (!is.null(body)) req <- req_body_json(req, body)
  resp <- req_perform(req)
  if (resp_status(resp) == 429) stop("Spotify said 'too many requests'. Try again tomorrow.")
  resp
}

# song_count(): how many songs the playlist has now (Spotify calls the list
# "items" in its new format and "tracks" in its old one).
song_count <- function() {
  resp <- sp(sprintf("/playlists/%s", pid))
  if (resp_status(resp) >= 400) stop("Spotify error ", resp_status(resp), ": ", resp_body_string(resp))
  pl <- resp_body_json(resp)
  pl$items$total %||% pl$tracks$total %||% NA
}

# 2. The playlist's size before.
before <- song_count()
message("Songs in the playlist before: ", before)

# 3. Remove the songs, 100 per request. Try the new address (/items) first and
# the old one (/tracks) if Spotify doesn't know it, as the other scripts do.
# The body lists the songs under both names, so either address understands it.
chunks <- split(to_delete$uri, ceiling(seq_along(to_delete$uri) / 100))
for (ch in chunks) {
  entries <- lapply(unname(ch), function(u) list(uri = u))
  body <- list(items = entries, tracks = entries)
  resp <- sp(sprintf("/playlists/%s/items", pid), method = "DELETE", body = body)
  if (resp_status(resp) == 404) {
    resp <- sp(sprintf("/playlists/%s/tracks", pid), method = "DELETE", body = list(tracks = entries))
  }
  if (resp_status(resp) >= 400) stop("Spotify error ", resp_status(resp), ": ", resp_body_string(resp))
  message("  removed a batch of ", length(ch), " songs.")
}

# 4. The playlist's size after, and the summary.
after <- song_count()
message("Songs in the playlist after: ", after, " (", before - after, " removed).")
message(sprintf("Spotify requests used this run: %d of %d.", SPOTIFY_USED, MAX_SPOTIFY_REQUESTS))
