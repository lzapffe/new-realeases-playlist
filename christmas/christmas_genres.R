# =============================================================================
# christmas_genres.R
#
# Goal: one Spotify playlist of Christmas songs per genre ("Christmas × Country",
# "Christmas × Soul", ...), with songs you don't already have.
#
# Each run:
#   1. LAST.FM (free, no Spotify quota): collect candidate songs per genre:
#      a. songs tagged with a combined tag such as "country christmas" or
#         "christmas country" (the strongest matches, used first), and
#      b. the most-tagged "christmas" songs whose ARTIST is tagged with the
#         genre (fills up the rest).
#   2. Leave out songs you already have: everything in Everything everything
#      Part 1/2 (read from the new-releases script's saved copies in state/,
#      at no cost) and in your Christmas edition (read from Spotify, a few
#      requests, only when it has changed).
#   3. SPOTIFY: find each candidate on Spotify with one search per song,
#      until each genre has SONGS_PER_PLAYLIST songs or the run's request
#      budget (MAX_SPOTIFY_REQUESTS) is used up. Every search result is saved,
#      so no song is ever searched twice.
#   4. SPOTIFY: when a genre has enough songs, create its playlist and add the
#      songs (2 requests per playlist).
# Progress is saved in christmas/state/ and committed by the workflow, so the
# next run continues where this one stopped. Run it until the log says all
# playlists are made (about five runs of 80 requests).
#
# Started by hand from the Actions tab ("Christmas genre playlists"). It
# refuses to run on Thursdays and Fridays, when the weekly new-releases
# playlist needs the shared Spotify quota.
#
# Needs: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REFRESH_TOKEN (the
# same secrets as the new-releases script) and LASTFM_API_KEY.
# =============================================================================

# Load the packages, without their start-up messages.
#   httr2 - web requests to Last.fm and Spotify
#   dplyr - filtering and combining tables
#   purrr - map() for working with lists from the APIs
#   tibble - the table format used throughout
suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(tibble)
})

# ---- Settings ---------------------------------------------------------------

# Your Christmas edition of Everything everything (exact name, as in Spotify).
# Songs in it, and in the two main Everything everything playlists, are left out.
CHRISTMAS_PLAYLIST <- "Everything everything - Christmas edition"
MAIN_PLAYLISTS     <- c("Everything everything - Part 1", "Everything everything - Part 2")

# The genres. The name is used in the playlist name ("Christmas × Country");
# the tags are the Last.fm tags that count as that genre (lowercase).
GENRES <- list(
  "Country"   = c("country", "alt-country"),
  "Bluegrass" = c("bluegrass"),
  "Folk"      = c("folk", "indie folk"),
  "Soul"      = c("soul", "neo-soul", "motown"),
  "Blues"     = c("blues"),
  "Jazz"      = c("jazz", "vocal jazz", "swing"),
  "Reggae"    = c("reggae", "ska", "dub"),
  "Celtic"    = c("celtic", "irish", "scottish"),
  "Indie"     = c("indie", "indie pop", "indie rock"),
  "Rock"      = c("rock", "classic rock", "alternative rock"),
  "Lo-fi"     = c("lo-fi", "lofi", "chillhop")
)

SONGS_PER_PLAYLIST   <- 35     # songs per genre playlist

# To EXPAND a playlist later, give its genre a bigger number here, e.g.
# MORE_SONGS <- c("Country" = 60, "Soul" = 50). The next runs continue down that
# genre's Last.fm list and add only new songs to the existing playlist; songs
# already in it are never searched or added again.
MORE_SONGS <- c()
MIN_SONGS            <- 10     # a genre with fewer than this is not made
CHRISTMAS_POOL_PAGES <- 10     # pages of 100 "christmas" songs used as filler
MIN_ARTIST_TAG       <- 20     # how strongly (0-100) an artist must be tagged
MAX_SPOTIFY_REQUESTS <- 80     # per run; keep well below the daily quota
PLAYLIST_PUBLIC      <- FALSE  # the Christmas playlists are private
BLOCKED_DAYS         <- c(4, 5) # Thursday, Friday (1 = Monday): don't run
STATE_DIR            <- "christmas/state"

# Base addresses of the two APIs.
LASTFM <- "https://ws.audioscrobbler.com/2.0/"
SP     <- "https://api.spotify.com/v1"

# ---- Safety check: not on Thursdays and Fridays -------------------------------

# Today's weekday in Oslo time. On Thursdays and Fridays the new-releases
# script needs the Spotify quota for the weekly playlist, so stop right away.
WEEKDAY <- as.POSIXlt(Sys.time(), tz = "Europe/Oslo")$wday   # 0 = Sunday
WEEKDAY <- if (WEEKDAY == 0) 7 else WEEKDAY
if (WEEKDAY %in% BLOCKED_DAYS) {
  message("Today is Thursday or Friday, when the new-releases playlist needs ",
          "the Spotify quota. Nothing was done; please run this on another day.")
  quit(save = "no", status = 0)
}

# ---- Helpers and state files --------------------------------------------------

# "a %||% b" returns a, unless a is missing (NULL or empty), then it returns b.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# norm_key(): a loose key for "the same song", used to compare Last.fm and
# Spotify names: lowercase, without anything in brackets ("(2019 Remaster)"),
# without " - Live" style endings and without punctuation, plus the main
# artist. So "Blue Christmas - 2006 Remaster" by "Elvis Presley" matches
# "Blue Christmas" by "Elvis Presley, The Jordanaires".
clean_title <- function(x) {
  x <- tolower(x)
  x <- gsub("\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", "", x)
  x <- sub("\\s+-\\s+.*$", "", x)
  trimws(gsub("[^[:alnum:] ]", "", x))
}
# target(): how many songs a genre should have: its MORE_SONGS number if it
# has one, otherwise SONGS_PER_PLAYLIST.
target <- function(g) if (g %in% names(MORE_SONGS)) MORE_SONGS[[g]] else SONGS_PER_PLAYLIST
main_artist <- function(x) trimws(tolower(sub(",.*$", "", x)))
norm_key    <- function(title, artist) paste(clean_title(title), main_artist(artist), sep = "|")

# The state folder and its files (all plain CSV, text columns):
#   searches.csv     - every Spotify search done: the song key, title, artist
#                      and the Spotify ID found (empty = not on Spotify)
#   picks.csv        - the songs chosen for each genre, and when each was
#                      added to its playlist (empty = not added yet)
#   playlists.csv    - the playlists made: genre, Spotify ID, number of songs
#   artist_tags.csv  - Last.fm tags per artist (saves Last.fm requests next run)
#   christmas_known.csv - a copy of your Christmas edition, with its version code
dir.create(STATE_DIR, recursive = TRUE, showWarnings = FALSE)
state_path <- function(f) file.path(STATE_DIR, f)

# read_state(): read a state file as text columns, or an empty table with the
# given columns if it doesn't exist yet. write_state(): save it.
read_state <- function(f, cols) {
  if (!file.exists(state_path(f))) {
    return(as_tibble(setNames(rep(list(character()), length(cols)), cols)))
  }
  df <- as_tibble(read.csv(state_path(f), colClasses = "character", na.strings = ""))
  for (c in setdiff(cols, names(df))) df[[c]] <- NA_character_
  df[cols]
}
write_state <- function(df, f) {
  write.csv(df, state_path(f), row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

SEARCHES  <- read_state("searches.csv", c("key", "title", "artist", "uri", "searched_on"))
PICKS     <- read_state("picks.csv", c("genre", "key", "uri", "title", "artist", "source", "added_on"))
MADE      <- read_state("playlists.csv", c("genre", "playlist_id", "n_songs", "made_on"))
ART_TAGS  <- read_state("artist_tags.csv", c("artist", "tags"))
XMAS_KNOWN <- read_state("christmas_known.csv", c("uri", "key", "snapshot"))

# save_all(): write every state file. Called after each step and at the end.
save_all <- function() {
  write_state(SEARCHES, "searches.csv")
  write_state(PICKS, "picks.csv")
  write_state(MADE, "playlists.csv")
  write_state(ART_TAGS, "artist_tags.csv")
  write_state(XMAS_KNOWN, "christmas_known.csv")
}

# ---- Last.fm ------------------------------------------------------------------

# Read the Last.fm key and stop with a clear message if it's missing.
LASTFM_KEY <- Sys.getenv("LASTFM_API_KEY")
if (LASTFM_KEY == "") stop("Set LASTFM_API_KEY (a GitHub secret).", call. = FALSE)

# lfm(): one Last.fm request. Waits 0.25 s first (Last.fm asks for at most a
# few requests per second) and retries up to 3 times on errors. Returns the
# reply as a list, or NULL if Last.fm has no data (e.g. an unknown tag).
lfm <- function(method, ...) {
  for (attempt in 1:3) {
    Sys.sleep(0.25)
    resp <- tryCatch(
      request(LASTFM) |>
        req_url_query(method = method, api_key = LASTFM_KEY, format = "json", ...) |>
        req_error(is_error = function(r) FALSE) |>
        req_perform(),
      error = function(e) NULL)
    if (!is.null(resp) && resp_status(resp) == 200) {
      body <- resp_body_json(resp)
      if (is.null(body$error)) return(body)
      if (!body$error %in% c(8, 11, 16, 29)) return(NULL)  # 8/11/16/29 = temporary
    }
    Sys.sleep(5)
  }
  NULL
}

# tag_tracks(): the top songs for one Last.fm tag, as a table of title and
# artist in Last.fm's order (most tagged first). pages x 100 songs.
tag_tracks <- function(tag, pages = 1) {
  map_dfr(seq_len(pages), function(p) {
    tr <- lfm("tag.gettoptracks", tag = tag, limit = 100, page = p)$tracks$track %||% list()
    tibble(title  = map_chr(tr, function(t) t$name %||% ""),
           artist = map_chr(tr, function(t) t$artist$name %||% ""))
  }) |>
    filter(nzchar(title), nzchar(artist))
}

# artist_tags(): an artist's strongest Last.fm tags (count >= MIN_ARTIST_TAG),
# lowercase. Cached in artist_tags.csv, so each artist is asked only once.
artist_tags <- function(artist) {
  hit <- ART_TAGS$tags[ART_TAGS$artist == artist]
  if (length(hit) > 0) return(strsplit(hit[1] %||% "", "|", fixed = TRUE)[[1]])
  tg <- lfm("artist.gettoptags", artist = artist)$toptags$tag %||% list()
  tags <- tolower(map_chr(keep(tg, function(t) as.numeric(t$count %||% 0) >= MIN_ARTIST_TAG),
                          function(t) t$name %||% ""))
  ART_TAGS <<- bind_rows(ART_TAGS, tibble(artist = artist, tags = paste(tags, collapse = "|")))
  tags
}

# ---- Spotify ------------------------------------------------------------------

# Log in to Spotify without a browser, exactly as in spotify_new_releases.R:
# the refresh token plus the app's ID and secret give a 1-hour access token.
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
TOKEN <- get_access_token()

# SPOTIFY_USED counts this run's requests. budget_left() is what remains.
SPOTIFY_USED <- 0
budget_left  <- function() MAX_SPOTIFY_REQUESTS - SPOTIFY_USED

# sp(): the one place where Spotify requests are made. It refuses when the
# budget is used up, waits 0.5 s between requests, and stops the whole run
# (saving progress first) if Spotify says "too many requests" (429), so the
# shared quota isn't pushed further. Other errors are returned to the caller.
sp <- function(path, method = "GET", query = list(), body = NULL) {
  if (budget_left() <= 0) return(NULL)
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
    save_all()
    stop("Spotify said 'too many requests'. Progress is saved; try again on another day.",
         call. = FALSE)
  }
  resp
}

# sp_ok(): stop with Spotify's error message if a request failed.
sp_ok <- function(resp) {
  if (resp_status(resp) >= 400) {
    stop("Spotify error ", resp_status(resp), ": ", resp_body_string(resp), call. = FALSE)
  }
  resp_body_json(resp)
}

# sp_all(): follow Spotify's "next" links to get every item of a list (e.g.
# all your playlists, all songs in a playlist). Stops early if the budget
# runs out, returning NULL so a half-read list is never used.
sp_all <- function(path, query = list(limit = 50)) {
  items <- list()
  url <- path
  while (!is.null(url)) {
    resp <- sp(url, query = if (identical(url, path)) query else list())
    if (is.null(resp)) return(NULL)
    page  <- sp_ok(resp)
    items <- c(items, page$items %||% list())
    url   <- page[["next"]]
  }
  items
}

# create_playlist(): create a playlist and return its ID. Tries the newer
# address (/me/playlists) first, then the older /users/{id}/playlists, as in
# the new-releases script. add_songs(): add songs (up to 100), trying the new
# /items address first and the old /tracks one if Spotify doesn't know it.
create_playlist <- function(body) {
  resp <- sp("/me/playlists", method = "POST", body = body)
  if (resp_status(resp) %in% c(404, 405)) {
    me   <- sp_ok(sp("/me"))
    resp <- sp(sprintf("/users/%s/playlists", me$id), method = "POST", body = body)
  }
  sp_ok(resp)$id
}
add_songs <- function(pid, uris) {
  resp <- sp(sprintf("/playlists/%s/items", pid), method = "POST", body = list(uris = I(uris)))
  if (resp_status(resp) %in% c(404, 405)) {
    resp <- sp(sprintf("/playlists/%s/tracks", pid), method = "POST", body = list(uris = I(uris)))
  }
  sp_ok(resp)
}

# ---- 1. Songs you already have --------------------------------------------------
message("== 1. Songs you already have")

# Everything everything Part 1/2: read the new-releases script's saved copies
# (state/playlist_<id>.csv), found by name in state/playlists_meta.csv. Free.
meta  <- read.csv("state/playlists_meta.csv", colClasses = "character")
main  <- map_dfr(meta$playlist_id[meta$name %in% MAIN_PLAYLISTS], function(id) {
  read.csv(sprintf("state/playlist_%s.csv", id), colClasses = "character", encoding = "UTF-8")
})
known_keys <- norm_key(main$title, main$artists)
known_uris <- main$uri

# Your Christmas edition: find it in your playlist list (1-2 requests). It is
# read again only if its version code ("snapshot") changed since last time.
my_pl <- sp_all("/me/playlists")
if (is.null(my_pl)) stop("Spotify budget used up while reading your playlists.", call. = FALSE)
xmas <- detect(my_pl, function(p) identical(p$name, CHRISTMAS_PLAYLIST))
if (is.null(xmas)) stop("No playlist named '", CHRISTMAS_PLAYLIST, "' found. ",
                        "Check CHRISTMAS_PLAYLIST in the settings.", call. = FALSE)
if (nrow(XMAS_KNOWN) == 0 || !identical(XMAS_KNOWN$snapshot[1], xmas$snapshot_id)) {
  items <- sp_all(sprintf("/playlists/%s/items", xmas$id))
  if (is.null(items)) stop("Spotify budget used up while reading your Christmas playlist.", call. = FALSE)
  tracks <- compact(map(items, function(it) it$item %||% it$track))
  tracks <- keep(tracks, function(t) !is.null(t$uri))
  XMAS_KNOWN <- tibble(
    uri      = map_chr(tracks, "uri"),
    key      = norm_key(map_chr(tracks, function(t) t$name %||% ""),
                        map_chr(tracks, function(t) t$artists[[1]]$name %||% "")),
    snapshot = xmas$snapshot_id %||% NA_character_
  )
  message("Read your Christmas edition: ", nrow(XMAS_KNOWN), " songs.")
}
known_keys <- unique(c(known_keys, XMAS_KNOWN$key))
known_uris <- unique(c(known_uris, XMAS_KNOWN$uri))
message(length(known_keys), " songs you already have will be left out.")
save_all()

# ---- 2. Last.fm: candidate songs per genre ----------------------------------------
message("== 2. Collecting Christmas songs per genre from Last.fm")

# The shared filler pool: the most-tagged "christmas" songs on Last.fm.
pool <- tag_tracks("christmas", CHRISTMAS_POOL_PAGES) |>
  mutate(key = norm_key(title, artist)) |>
  distinct(key, .keep_all = TRUE)
message(nrow(pool), " songs in the 'christmas' pool.")

# For each genre not yet made, build the ordered candidate list:
#   a. songs with a combined tag ("<genre tag> christmas" or "christmas <genre
#      tag>"), strongest first,
#   b. pool songs whose artist is tagged with one of the genre's tags,
# then remove songs you already have and duplicates.
# Genres to work on: those without a playlist yet, plus made ones whose
# target was raised in MORE_SONGS and that have fewer songs than that.
todo_genres <- keep(names(GENRES), function(g) {
  !g %in% MADE$genre || sum(PICKS$genre == g) < target(g)
})
CANDIDATES <- map(setNames(todo_genres, todo_genres), function(g) {
  tags <- GENRES[[g]]
  combined <- map_dfr(tags, function(t) {
    bind_rows(tag_tracks(paste(t, "christmas")), tag_tracks(paste("christmas", t)))
  }) |>
    mutate(source = "combined tag")
  filler <- pool |>
    filter(map_lgl(artist, function(a) any(artist_tags(a) %in% tags))) |>
    select(title, artist) |>
    mutate(source = "artist genre")
  bind_rows(combined, filler) |>
    mutate(key = norm_key(title, artist)) |>
    filter(nzchar(key), !key %in% known_keys) |>
    distinct(key, .keep_all = TRUE)
})
walk2(names(CANDIDATES), CANDIDATES, function(g, c) message("  ", g, ": ", nrow(c), " candidates"))
save_all()

# ---- 3. Spotify: find the songs ---------------------------------------------------
message("== 3. Finding the songs on Spotify (budget: ", budget_left(), " requests)")

# find_on_spotify(): one search for a song, keeping the first result whose
# artists include the Last.fm artist (ignoring case). The result (a Spotify
# ID, or empty if not found) is saved in searches.csv, so it is never searched
# again. Returns the ID, or NA.
find_on_spotify <- function(title, artist, key) {
  q <- sprintf('track:"%s" artist:"%s"', gsub('"', "", title), gsub('"', "", artist))
  resp <- sp("/search", query = list(q = q, type = "track", limit = 5))
  if (is.null(resp)) return(NULL)  # budget used up
  items <- sp_ok(resp)$tracks$items %||% list()
  hit <- detect(items, function(t) {
    tolower(artist) %in% tolower(map_chr(t$artists, function(a) a$name %||% ""))
  })
  uri <- if (is.null(hit)) NA_character_ else hit$uri
  SEARCHES <<- bind_rows(SEARCHES, tibble(key = key, title = title, artist = artist,
                                          uri = uri, searched_on = as.character(Sys.Date())))
  uri
}

# Fill each genre in turn until it has its target number of songs. Songs already
# searched (for this or another genre) cost nothing. Songs whose Spotify ID is
# one you already have are skipped too. Stops when the budget is used up,
# keeping 6 requests for making playlists.
for (g in todo_genres) {
  cand <- CANDIDATES[[g]]
  for (i in seq_len(nrow(cand))) {
    if (sum(PICKS$genre == g) >= target(g)) break
    key <- cand$key[i]
    if (key %in% PICKS$key[PICKS$genre == g]) next
    uri <- SEARCHES$uri[SEARCHES$key == key][1]
    if (!key %in% SEARCHES$key) {
      if (budget_left() <= 6) break
      uri <- find_on_spotify(cand$title[i], cand$artist[i], key)
    }
    if (is.na(uri) || uri %in% known_uris || uri %in% PICKS$uri[PICKS$genre == g]) next
    PICKS <- bind_rows(PICKS, tibble(genre = g, key = key, uri = uri, title = cand$title[i],
                                     artist = cand$artist[i], source = cand$source[i],
                                     added_on = NA_character_))
  }
  message("  ", g, ": ", sum(PICKS$genre == g), " of ", target(g), " songs found")
  save_all()
}

# ---- 4. Spotify: make the finished playlists --------------------------------------
message("== 4. Making the finished playlists")

# A genre is finished when it has its target number of songs, or when all
# its candidates have been searched and it has at least MIN_SONGS. For each
# one, the songs not added yet are added (1 request per 100):
#   - no playlist yet: create it first (1 request),
#   - playlist already made (expanding): add only the new songs to it.
for (g in todo_genres) {
  n <- sum(PICKS$genre == g)
  searched_all <- all(CANDIDATES[[g]]$key %in% c(SEARCHES$key, PICKS$key[PICKS$genre == g]))
  finished <- n >= target(g) || (searched_all && n >= MIN_SONGS)
  new  <- which(PICKS$genre == g & is.na(PICKS$added_on))
  if (!finished || length(new) == 0) next
  if (budget_left() < 4) { message("  ", g, ": no requests left; done next run."); next }
  name <- paste("Christmas ×", g)
  pid  <- MADE$playlist_id[MADE$genre == g][1]
  if (is.na(pid)) {
    body <- list(name = name, public = PLAYLIST_PUBLIC,
                 description = sprintf("%s Christmas songs you didn't have yet, found via Last.fm tags.", g))
    pid  <- create_playlist(body)
    MADE <- bind_rows(MADE, tibble(genre = g, playlist_id = pid, n_songs = "0",
                                   made_on = as.character(Sys.Date())))
    message("  made '", name, "'.")
  }
  add_songs(pid, PICKS$uri[new])
  PICKS$added_on[new] <- as.character(Sys.Date())
  MADE$n_songs[MADE$genre == g] <- as.character(sum(PICKS$genre == g & !is.na(PICKS$added_on)))
  message("  added ", length(new), " song(s) to '", name, "'.")
  save_all()
}

# Genres with too few songs even after searching everything are reported, so
# you can add more tags for them in the settings.
for (g in setdiff(todo_genres, MADE$genre)) {
  if (all(CANDIDATES[[g]]$key %in% SEARCHES$key) && sum(PICKS$genre == g) < MIN_SONGS) {
    message("  ", g, ": only ", sum(PICKS$genre == g), " songs found; add more tags in GENRES.")
  }
}

# ---- Summary ------------------------------------------------------------------------
save_all()
left <- keep(names(GENRES), function(g) {
  !g %in% MADE$genre || any(PICKS$genre == g & is.na(PICKS$added_on))
})
message(sprintf("Spotify requests used this run: %d of %d.", SPOTIFY_USED, MAX_SPOTIFY_REQUESTS))
if (length(left) == 0) {
  message("All playlists are made. You don't need to run this again.")
} else {
  message("Still to make: ", paste(left, collapse = ", "), ". Run again on another Monday-Wednesday.")
}
