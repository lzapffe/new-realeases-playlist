# =============================================================================
# christmas_genres.R
#
# Goal: one Spotify playlist of Christmas songs per genre ("Christmas × Country",
# "Christmas × Soul", ...), with songs you don't already have.
#
# Each run:
#   1. Leave out songs you already have: everything in Everything everything
#      Part 1/2 (read from the new-releases script's saved copies in state/,
#      at no cost) and in your Christmas edition (read from Spotify, a few
#      requests, only when it has changed). Only exact matches count.
#   2. LAST.FM (free, no Spotify quota): for every Last.fm tag in the pool,
#      count the available songs: songs tagged with a combined tag such as
#      "country christmas" or "christmas country", plus the most-tagged
#      "christmas" songs whose ARTIST has the tag. Write them to the overview
#      christmas/genre_overview.xlsx, where you mark each tag "include" or
#      "exclude" (blank = not looked at yet; blank rows are at the top).
#      Included tags become genres (grouped by the "playlist" column). Their
#      candidates are saved in christmas/state/candidates.csv and keep
#      growing over the years. Excluded tags feed the random "Mix" playlist.
#   3. SPOTIFY: for genres with at least MIN_CANDIDATES candidates, find each
#      candidate on Spotify with one search per song, until each genre has
#      SONGS_PER_PLAYLIST songs or the run's request budget
#      (MAX_SPOTIFY_REQUESTS) is used up. Every search result is saved, so no
#      song is searched twice; songs not found are tried again after a year.
#      Genres with fewer candidates cost no Spotify requests; they wait until
#      a later run (or a bigger pool) brings enough.
#   4. SPOTIFY: when a genre has enough songs, create its playlist and add the
#      songs (2 requests per playlist).
# Progress is saved in christmas/state/ and committed by the workflow, so the
# next run continues where this one stopped. Run it until the log says all
# playlists are made (about eight runs of 50 requests).
#
# Started by hand from the Actions tab ("Christmas genre playlists"). It
# only runs Saturday to Tuesday: Thursday and Friday need the shared Spotify
# quota for the weekly new-releases playlist, and skipping Wednesday means
# that even if Spotify ever blocks requests for a day, it has cleared by then.
#
# Needs: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REFRESH_TOKEN (the
# same secrets as the new-releases script) and LASTFM_API_KEY.
# =============================================================================

# Load the packages, without their start-up messages.
#   httr2 - web requests to Last.fm and Spotify
#   dplyr - filtering and combining tables
#   purrr - map() for working with lists from the APIs
#   tibble - the table format used throughout
#   readxl / writexl - read and write the Excel genre overview
suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(tibble)
  library(readxl)
  library(writexl)
})

# ---- Settings ---------------------------------------------------------------

# Your Christmas edition of Everything everything (exact name, as in Spotify).
# Songs in it, and in the two main Everything everything playlists, are left out.
CHRISTMAS_PLAYLIST <- "Everything everything - Christmas edition"
MAIN_PLAYLISTS     <- c("Everything everything - Part 1", "Everything everything - Part 2")

# The STARTING genres. Since 2 Nov 2026 the genres are chosen in the Excel
# overview (christmas/genre_overview.xlsx); this list is only used to fill in
# that file the first time it is made (each tag below is marked "include",
# with the genre name in its "playlist" column). After that, change genres in
# the Excel file, not here. The name is used in the playlist name
# ("Christmas × Country"); the tags are Last.fm tags (lowercase).
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
  "Lo-fi"     = c("lo-fi", "lofi", "chillhop"),
  # Added 2 Nov 2026 (Linn):
  "R&B"       = c("rnb", "r&b", "rhythm and blues"),
  "Acoustic"  = c("acoustic"),
  "Pop"       = c("pop")
)

# The genre overview (Excel) and the mix.
OVERVIEW_FILE        <- "christmas/genre_overview.xlsx"
OVERVIEW_MIN_ARTISTS <- 3     # a tag is listed when at least this many pool artists have it
SKIP_TAGS <- c("christmas", "xmas", "holiday", "christmas music", "christmas songs",
               "seen live")   # never listed: they say nothing about the genre
MIN_CANDIDATES <- 45  # a genre is searched on Spotify only from this many candidates
                      # (about 1 in 4 is not on Spotify or is one you have)
MIX_GENRE <- "Mix"    # the playlist made at random from the tags marked "exclude"
MIX_SEED  <- 2026     # fixed, so the random order is the same on every run
RETRY_AFTER_DAYS <- 365  # songs not found on Spotify are searched again after this

SONGS_PER_PLAYLIST   <- 35     # songs per genre playlist

# To EXPAND a playlist later, give its genre a bigger number here, e.g.
# MORE_SONGS <- c("Country" = 60, "Soul" = 50). The next runs continue down that
# genre's Last.fm list and add only new songs to the existing playlist; songs
# already in it are never searched or added again.
MORE_SONGS <- c()
MIN_SONGS            <- 10     # a genre with fewer than this is not made
CHRISTMAS_POOL_PAGES <- 10     # pages of 100 "christmas" songs used as filler;
                               # raise it (e.g. to 20) for a bigger pool later
MIN_ARTIST_TAG       <- 20     # how strongly (0-100) an artist must be tagged
MAX_SPOTIFY_REQUESTS <- 50     # per run; keeps the day's total below the quota
PLAYLIST_PUBLIC      <- FALSE  # the Christmas playlists are private
BLOCKED_DAYS         <- c(3, 4, 5) # Wed, Thu, Fri (1 = Monday): don't run, so a
                                    # rare Spotify block clears before Thursday
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
  message("This doesn't run on Wednesdays, Thursdays or Fridays, to keep the ",
          "Spotify quota safe for the weekly new-releases playlist. Nothing was ",
          "done; please run it on a Monday or Tuesday.")
  quit(save = "no", status = 0)
}

# Log this run in state/spotify_request_log.csv when it ends (shared helper,
# see spotify_log.R in the repository's top folder), to learn Spotify's limit.
source("spotify_log.R")
spotify_log_start("christmas", function() SPOTIFY_USED)

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
# exact_key(): a strict key for "exactly the same song" (Linn, 2 Nov 2026): the
# title and the full artist list exactly as written, ignoring only upper and
# lower case. "Blue Christmas" by "Elvis Presley" does NOT match "Blue
# Christmas - Live" or "Blue Christmas" by "Elvis Presley, The Jordanaires".
exact_key   <- function(title, artists) paste(tolower(trimws(title)), tolower(trimws(artists)), sep = "|")

# The state folder and its files (all plain CSV, text columns):
#   searches.csv     - every Spotify search done: the song key, title, artist
#                      and the Spotify ID found (empty = not on Spotify)
#   picks.csv        - the songs chosen for each genre, and when each was
#                      added to its playlist (empty = not added yet)
#   playlists.csv    - the playlists made: genre, Spotify ID, number of songs
#   artist_tags.csv  - Last.fm tags per artist (saves Last.fm requests next run)
#   christmas_known.csv - a copy of your Christmas edition, with its version code
#   candidates.csv   - every candidate song found so far for each included
#                      genre (kept across runs and years, so small genres grow)
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
XMAS_KNOWN <- read_state("christmas_known.csv", c("uri", "key", "exact", "snapshot"))
CANDS     <- read_state("candidates.csv", c("genre", "key", "title", "artist", "source", "first_seen"))

# save_all(): write every state file. Called after each step and at the end.
save_all <- function() {
  write_state(CANDS, "candidates.csv")
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
    spotify_log_429(resp_header(resp, "Retry-After"))
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
known_keys  <- norm_key(main$title, main$artists)
known_exact <- exact_key(main$title, main$artists)
known_uris <- main$uri

# Your Christmas edition: find it in your playlist list (1-2 requests). It is
# read again only if its version code ("snapshot") changed since last time, or
# if the saved copy is from before the "exact" column was added (one re-read).
my_pl <- sp_all("/me/playlists")
if (is.null(my_pl)) stop("Spotify budget used up while reading your playlists.", call. = FALSE)
xmas <- detect(my_pl, function(p) identical(p$name, CHRISTMAS_PLAYLIST))
if (is.null(xmas)) stop("No playlist named '", CHRISTMAS_PLAYLIST, "' found. ",
                        "Check CHRISTMAS_PLAYLIST in the settings.", call. = FALSE)
if (nrow(XMAS_KNOWN) == 0 || !identical(XMAS_KNOWN$snapshot[1], xmas$snapshot_id) ||
    any(is.na(XMAS_KNOWN$exact))) {
  items <- sp_all(sprintf("/playlists/%s/items", xmas$id))
  if (is.null(items)) stop("Spotify budget used up while reading your Christmas playlist.", call. = FALSE)
  tracks <- compact(map(items, function(it) it$item %||% it$track))
  tracks <- keep(tracks, function(t) !is.null(t$uri))
  XMAS_KNOWN <- tibble(
    uri      = map_chr(tracks, "uri"),
    key      = norm_key(map_chr(tracks, function(t) t$name %||% ""),
                        map_chr(tracks, function(t) t$artists[[1]]$name %||% "")),
    exact    = exact_key(map_chr(tracks, function(t) t$name %||% ""),
                         map_chr(tracks, function(t) paste(map_chr(t$artists, function(a) a$name %||% ""),
                                                            collapse = ", "))),
    snapshot = xmas$snapshot_id %||% NA_character_
  )
  message("Read your Christmas edition: ", nrow(XMAS_KNOWN), " songs.")
}
known_keys <- unique(c(known_keys, XMAS_KNOWN$key))
known_uris <- unique(c(known_uris, XMAS_KNOWN$uri))
known_exact <- unique(c(known_exact, XMAS_KNOWN$exact))
# Only exact matches count as "already have" (Linn, 2 Nov 2026): a song is left
# out if its exact title + artists (free check, step 2) or its Spotify ID (step 3)
# is in your playlists, so other versions (live, remaster, remix) of songs you
# have can still be picked.
message(length(known_exact), " songs you already have (exact title and artists) will be left out.")
save_all()

# ---- 2. Last.fm: the genre overview and the candidate songs ------------------------
message("== 2. Collecting Christmas songs per genre from Last.fm")

# The shared pool: the most-tagged "christmas" songs on Last.fm, with each
# artist's strong tags (saved in artist_tags.csv, so mostly free after the
# first run).
pool <- tag_tracks("christmas", CHRISTMAS_POOL_PAGES) |>
  mutate(key = norm_key(title, artist)) |>
  distinct(key, .keep_all = TRUE)
pool$tags <- map(pool$artist, artist_tags)
message(nrow(pool), " songs in the 'christmas' pool.")

# 2a. Your decisions, read from the Excel overview: one row per tag, with
# "include" or "exclude" in the decision column (blank = not looked at yet)
# and, optionally, a playlist name that groups several tags into one genre.
# The first time, when the file doesn't exist yet, the tags in GENRES are
# filled in as "include", with their genre as the playlist name.
xl_col <- function(df, name) {
  if (name %in% names(df)) as.character(df[[name]]) else rep(NA_character_, nrow(df))
}
if (file.exists(OVERVIEW_FILE)) {
  old <- read_excel(OVERVIEW_FILE, col_types = "text")
  decisions <- tibble(tag      = tolower(trimws(xl_col(old, "tag"))),
                      decision = tolower(trimws(coalesce(xl_col(old, "decision"), ""))),
                      playlist = trimws(coalesce(xl_col(old, "playlist"), "")))
} else {
  decisions <- tibble(tag      = unlist(GENRES, use.names = FALSE),
                      decision = "include",
                      playlist = rep(names(GENRES), lengths(GENRES)))
}
decisions <- decisions |>
  filter(!is.na(tag), nzchar(tag)) |>
  distinct(tag, .keep_all = TRUE)

# 2b. The tags to list: every tag that at least OVERVIEW_MIN_ARTISTS pool
# artists have, plus every tag you have already decided on.
tag_artists <- map2_dfr(pool$artist, pool$tags, function(a, t) {
  if (length(t) == 0) NULL else tibble(artist = a, tag = t)
}) |>
  distinct()
artist_count <- count(tag_artists, tag, name = "pool_artists")
list_tags <- union(artist_count$tag[artist_count$pool_artists >= OVERVIEW_MIN_ARTISTS],
                   decisions$tag)
list_tags <- setdiff(list_tags[nzchar(list_tags)], SKIP_TAGS)
message(length(list_tags), " tags in the overview.")

# 2c. The available songs for each tag, counting both sources as one list:
#   a. songs with a combined tag ("<tag> christmas" or "christmas <tag>",
#      2 Last.fm requests), strongest first,
#   b. pool songs whose artist has the tag.
# Songs you already have (exact title and artists) and duplicates are left out.
tag_songs <- map(setNames(list_tags, list_tags), function(t) {
  combined <- bind_rows(tag_tracks(paste(t, "christmas")), tag_tracks(paste("christmas", t))) |>
    mutate(source = "combined tag")
  filler <- pool |>
    filter(map_lgl(tags, function(x) t %in% x)) |>
    select(title, artist) |>
    mutate(source = "artist genre")
  bind_rows(combined, filler) |>
    mutate(key = norm_key(title, artist)) |>
    filter(nzchar(key), !exact_key(title, artist) %in% known_exact) |>
    distinct(key, .keep_all = TRUE)
})

# 2d. The genres: every tag marked "include", grouped by its playlist name
# (a blank playlist name means the tag gets its own playlist, e.g. "Gospel").
inc <- decisions |>
  filter(decision == "include", tag %in% list_tags) |>
  mutate(genre = ifelse(nzchar(playlist), playlist, tools::toTitleCase(tag)))
genre_tags <- split(inc$tag, inc$genre)
excluded   <- intersect(decisions$tag[decisions$decision == "exclude"], list_tags)

# 2e. Each genre's candidates: the combined-tag songs of all its tags first,
# then the artist-genre ones. Earlier runs' candidates (candidates.csv) are
# kept and added at the end, so a small genre keeps growing over the years
# (for example when CHRISTMAS_POOL_PAGES is raised for a bigger pool).
CANDIDATES <- map(setNames(names(genre_tags), names(genre_tags)), function(g) {
  now <- bind_rows(tag_songs[genre_tags[[g]]]) |>
    arrange(source != "combined tag") |>
    distinct(key, .keep_all = TRUE)
  before <- CANDS |>
    filter(genre == g, !key %in% now$key) |>
    select(title, artist, source, key)
  bind_rows(now, before)
})

# 2f. The mix: songs from the tags marked "exclude" that aren't candidates for
# any included genre, in a fixed random order. Made only if any tag is excluded.
if (length(excluded) > 0) {
  in_genres <- unique(unlist(map(CANDIDATES, "key")))
  mix <- bind_rows(tag_songs[excluded]) |>
    distinct(key, .keep_all = TRUE) |>
    filter(!key %in% in_genres) |>
    mutate(source = "mix (excluded tags)")
  set.seed(MIX_SEED)
  CANDIDATES[[MIX_GENRE]] <- mix[sample(nrow(mix)), ]
}

# Save every genre's candidates (new ones get today's date), so they are
# remembered for later runs and years.
for (g in names(CANDIDATES)) {
  new_c <- CANDIDATES[[g]] |>
    filter(!key %in% CANDS$key[CANDS$genre == g]) |>
    transmute(genre = g, key, title, artist, source, first_seen = as.character(Sys.Date()))
  CANDS <- bind_rows(CANDS, new_c)
}

# Genres to work on: those without a playlist yet, plus made ones whose target
# was raised in MORE_SONGS. Only those with at least MIN_CANDIDATES candidates
# are searched on Spotify; the others wait for more candidates (no Spotify cost).
todo_genres <- keep(names(CANDIDATES), function(g) {
  !g %in% MADE$genre || sum(PICKS$genre == g) < target(g)
})
search_genres <- keep(todo_genres, function(g) nrow(CANDIDATES[[g]]) >= MIN_CANDIDATES)
walk(todo_genres, function(g) {
  message("  ", g, ": ", nrow(CANDIDATES[[g]]), " candidates",
          if (g %in% search_genres) "" else sprintf(" (waiting: searched from %d)", MIN_CANDIDATES))
})

# write_overview(): (re)write the Excel overview. One row per tag: your
# decision, the playlist name, the available songs (both sources together),
# how many of them come from combined tags, how many pool artists have the tag,
# and the state of its playlist. Blank decisions come first (biggest first),
# then "include" (by playlist), then "exclude". Your decisions are kept.
genre_status <- function(g) {
  if (is.na(g) || !nzchar(g)) return("")
  n_cand  <- nrow(CANDIDATES[[g]] %||% tibble())
  n_added <- sum(PICKS$genre == g & !is.na(PICKS$added_on))
  if (g %in% MADE$genre) return(sprintf("playlist made (%d songs)", n_added))
  if (n_cand < MIN_CANDIDATES) return(sprintf("waiting: %d of %d candidates", n_cand, MIN_CANDIDATES))
  sprintf("searching: %d of %d songs found", sum(PICKS$genre == g), target(g))
}
write_overview <- function() {
  ov <- tibble(tag = list_tags) |>
    left_join(decisions, by = "tag") |>
    left_join(artist_count, by = "tag") |>
    left_join(select(inc, tag, genre), by = "tag") |>
    mutate(decision          = coalesce(decision, ""),
           playlist          = coalesce(playlist, ""),
           available_songs   = map_int(tag, function(t) nrow(tag_songs[[t]])),
           from_combined_tags = map_int(tag, function(t) sum(tag_songs[[t]]$source == "combined tag")),
           pool_artists      = coalesce(pool_artists, 0L),
           status            = map_chr(genre, genre_status),
           order             = match(decision, c("", "include", "exclude"))) |>
    mutate(order = coalesce(order, 4L)) |>
    arrange(order, if_else(decision == "include", playlist, ""), desc(available_songs)) |>
    select(decision, playlist, tag, available_songs, from_combined_tags, pool_artists, status)
  write_xlsx(ov, OVERVIEW_FILE)
}
write_overview()
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
# searched (for this or another genre) cost nothing, except that a song not
# found on Spotify is searched again once RETRY_AFTER_DAYS have passed. Songs
# whose Spotify ID is one you already have are skipped too. Only genres with
# enough candidates (search_genres) are searched. Stops when the budget is used
# up, keeping 6 requests for making playlists.
for (g in search_genres) {
  cand <- CANDIDATES[[g]]
  for (i in seq_len(nrow(cand))) {
    if (sum(PICKS$genre == g) >= target(g)) break
    key <- cand$key[i]
    if (key %in% PICKS$key[PICKS$genre == g]) next
    prev  <- which(SEARCHES$key == key)
    uri   <- SEARCHES$uri[prev][1]
    stale <- length(prev) > 0 && is.na(uri) &&
      isTRUE(as.Date(SEARCHES$searched_on[prev[1]]) <= Sys.Date() - RETRY_AFTER_DAYS)
    if (length(prev) == 0 || stale) {
      if (budget_left() <= 6) break
      if (stale) SEARCHES <- SEARCHES[-prev, ]   # forget the old "not found"
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
for (g in search_genres) {
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

# Genres with too few songs even after searching all their candidates are
# reported. They keep collecting candidates in later runs and years.
for (g in setdiff(search_genres, MADE$genre)) {
  if (all(CANDIDATES[[g]]$key %in% SEARCHES$key) && sum(PICKS$genre == g) < MIN_SONGS) {
    message("  ", g, ": only ", sum(PICKS$genre == g), " songs found on Spotify; it waits for more candidates.")
  }
}

# ---- Summary ------------------------------------------------------------------------
# Update the Excel overview's status column, save everything, and report.
write_overview()
save_all()
waiting <- setdiff(todo_genres, search_genres)
left <- keep(search_genres, function(g) {
  !g %in% MADE$genre || any(PICKS$genre == g & is.na(PICKS$added_on))
})
message(sprintf("Spotify requests used this run: %d of %d.", SPOTIFY_USED, MAX_SPOTIFY_REQUESTS))
if (length(waiting) > 0) {
  message("Waiting for more candidates (no Spotify requests): ", paste(waiting, collapse = ", "), ".")
}
if (length(left) == 0) {
  message("All playlists with enough candidates are made. Check the overview for new tags.")
} else {
  message("Still to make: ", paste(left, collapse = ", "), ". Run again on a Monday or Tuesday.")
}

# Mark the run as finished in the Spotify request log.
spotify_log_done()
