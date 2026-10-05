# =============================================================================
# spotify_new_releases.R  (Friday-playlist version)
#
# Goal: a finished "New releases week X YYYY" playlist every Friday morning,
# with the work spread over the week so Spotify's small quota is enough.
#
# Every day:
#   1. SPOTIFY (few requests): update the local copies of your playlists in
#      state/. Only newly added songs are fetched.
#   2. DEEZER (free, no quota): match new artists to Deezer (once per artist).
#   3. DEEZER: check ALL matched artists for releases from the last 14 days.
#   4. SPOTIFY: look up the new releases on Spotify and save their songs in
#      state/staged_tracks.csv - NOT in Spotify, so nothing appears in your
#      library during the week.
# Thursdays:
#   5a. SPOTIFY: create "New releases week X YYYY (in progress)" and add all
#       songs staged so far, leaving out songs whose exact title AND artist(s)
#       already exist in your check playlists.
# Fridays (or Saturday/Sunday, if Friday's run failed):
#   5b. SPOTIFY: add the songs staged since Thursday (mainly Friday's
#       releases), then rename the playlist to "New releases week X YYYY" -
#       the name without "(in progress)" means the playlist is finished.
# Saturday-Wednesday, with Spotify requests left over:
#   6. SPOTIFY: check artists that Deezer couldn't match directly on Spotify.
#
# Progress is saved in state/ and committed back to the repository by the
# workflow, so a run that stops early continues on the next run.
#
# Needs: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REFRESH_TOKEN
# Optional: FULL_REFRESH=true to read the playlists again from scratch.
# =============================================================================

# Load the packages. suppressPackageStartupMessages() hides their start-up
# messages so the log stays readable.
#   httr2     - sends web requests to Spotify and Deezer
#   dplyr     - filtering, combining and de-duplicating tables
#   purrr     - map()/keep()/detect() for working with lists from the APIs
#   lubridate - dates, weekdays, time zones and ISO week numbers
#   tibble    - the table format used throughout
suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(lubridate)
  library(tibble)
})

# ---- Settings ---------------------------------------------------------------
# Everything you are likely to want to change is in this section.

# Playlists whose artists you want to follow (exact names, case-sensitive).
SOURCE_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")

# Playlists used for the duplicate check (exact names). A new song is left out
# if a song with exactly the same title and artist(s) exists in any of these.
# By default the two source playlists; add more names inside c() if you like.
CHECK_PLAYLISTS <- SOURCE_PLAYLISTS

# What counts as a new release.
INCLUDE_TYPES       <- c("album", "single", "ep") # Deezer types; add "compile" for compilations
MAIN_ARTISTS_ONLY   <- FALSE   # TRUE = ignore featured artists (fewer artists to check)
CHECK_UNCERTAIN     <- FALSE   # TRUE = use "uncertain" Deezer matches as if they were certain
RELEASE_WINDOW_DAYS <- 14      # look for releases from the last N days (incl. today)

# Weekdays are numbered 1 = Monday ... 7 = Sunday.
BUILD_DAY              <- 4         # Thursday: the playlist is created ("in progress")
PUBLISH_DAY            <- 5         # Friday: the playlist is finished and renamed
CATCH_UP_DAYS          <- c(6, 7)   # Sat/Sun: finish it then if Friday's run failed
FALLBACK_DAYS          <- c(6, 7, 1, 2, 3) # Sat-Wed: check unmatched artists on Spotify
FALLBACK_INTERVAL_DAYS <- 7         # check each unmatched artist at most once a week

PLAYLIST_PUBLIC <- FALSE           # the weekly playlist is private
TIMEZONE        <- "Europe/Oslo"   # used for "today", the weekday and the week number

# Limits that keep the script within Spotify's quota and GitHub's time limit.
MAX_SPOTIFY_REQUESTS <- 200    # per run; Spotify's quota size is not published
SPOTIFY_RESERVE      <- 10     # requests always kept free at the end of a phase
SPOTIFY_PACE         <- 0.5    # seconds between Spotify requests
DEEZER_PACE          <- 0.1    # seconds between Deezer requests (limit: 50 per 5 s)
MAX_WAIT             <- 120    # stop instead of waiting longer than this (seconds)
MAX_RUNTIME_MIN      <- 300    # stop and save progress after this many minutes
MAX_ATTEMPTS         <- 3      # give up on a release not found on Spotify after N tries
STATE_DIR            <- "state" # folder where progress and playlist copies are saved

# Artists matched before this date are matched once more (except "manual" ones).
# Matches made before 2026-10-06 used a Deezer search format that returned no
# confirming songs, so none could be "matched"; this redoes them with the fixed
# search. Set it to a later date to force another full rematch.
REMATCH_BEFORE <- as.Date("2026-10-06")

# Read the FULL_REFRESH environment variable (set by the checkbox when you run
# the workflow manually). TRUE means: ignore the saved playlist copies and read
# the playlists again from the start.
FULL_REFRESH <- tolower(Sys.getenv("FULL_REFRESH", "false")) == "true"

# Base addresses of the two APIs. Request paths are added to the end of these.
API <- "https://api.spotify.com/v1"
DZ  <- "https://api.deezer.com"

# Today's date and weekday in Oslo time (GitHub's servers use UTC), the time
# the script started (for the time limit), and this week's playlist names:
#   PL_NAME          - the final name, e.g. "New releases week 42 2026"
#   PL_NAME_BUILDING - the name while it's being built (Thursday to Friday),
#                      e.g. "New releases week 42 2026 (in progress)"
# ISO weeks run Monday-Sunday, as used in Norway; isoyear() gives the right
# year for weeks that cross New Year.
TODAY            <- as_date(with_tz(now(), TIMEZONE))
WEEKDAY          <- wday(TODAY, week_start = 1)
IS_PUBLISH_DAY   <- WEEKDAY == PUBLISH_DAY
START            <- Sys.time()
PL_NAME          <- sprintf("New releases week %d %d", isoweek(TODAY), isoyear(TODAY))
PL_NAME_BUILDING <- paste(PL_NAME, "(in progress)")

# ---- General helpers --------------------------------------------------------

# "a %||% b" returns a, unless a is missing (NULL or empty), then it returns b.
# Used everywhere to supply a default when an API leaves out a field.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# norm(): lowercase and trim spaces, so names can be compared loosely when
#   matching artists and albums between Deezer and Spotify.
# clean_q(): remove double quotes from text before putting it inside a
#   search query like artist:"Name", where quotes would break the query.
# dup_key(): join title and artist into one string, used for the EXACT
#   duplicate check. The separator is an invisible character that never appears
#   in titles, so "A" + "B C" can't accidentally equal "A B" + "C".
# as_day(): turn "2026-10-02" into a date. With an explicit format, invalid
#   values like "0000-00-00" become NA instead of causing an error.
norm    <- function(x) tolower(trimws(x))
clean_q <- function(x) gsub('"', "", x, fixed = TRUE)
dup_key <- function(title, artists) paste(title, artists, sep = "\u001F")
as_day  <- function(x) as.Date(x, format = "%Y-%m-%d")

# id_chr(): turn a numeric ID from Deezer into text without scientific
# notation (as.character(100000) would give "1e+05", which isn't a valid ID).
id_chr <- function(x) if (is.null(x) || length(x) == 0) NA_character_ else format(x, scientific = FALSE, trim = TRUE)

# The first day of the release window: releases from this date until today
# count as new (a 14-day window by default).
SINCE <- TODAY - RELEASE_WINDOW_DAYS + 1

# stop_run(): stop the current phase with a special, named type of error.
# The run_phase() function further down recognises these types
# ("spotify_stop" and "time_stop") and handles them calmly: progress is saved
# and the script moves on or finishes, instead of crashing.
stop_run <- function(msg, class) {
  stop(structure(class = c(class, "error", "condition"),
                 list(message = msg, call = NULL)))
}

# check_time(): called regularly inside long loops. If the script has run
# longer than MAX_RUNTIME_MIN minutes, it stops the phase with a "time_stop",
# so the workflow still has time to save progress before GitHub's limit.
check_time <- function() {
  if (as.numeric(difftime(Sys.time(), START, units = "mins")) > MAX_RUNTIME_MIN) {
    stop_run("Time limit for this run reached; progress is saved and continues next run.",
             "time_stop")
  }
}

# ---- State files ------------------------------------------------------------
# The state/ folder is the script's memory between runs. All files are plain
# CSV, so you can open and edit them (e.g. fix an artist match by hand).

# Create the state/ folder if it doesn't exist yet (first run).
dir.create(STATE_DIR, showWarnings = FALSE, recursive = TRUE)

# state_path(): build the full path to a file in the state/ folder.
state_path <- function(file) file.path(STATE_DIR, file)

# read_state(): read a CSV file from state/ as a table where every column is
# text. If the file doesn't exist yet, return an empty table with the right
# columns. If a column is missing (e.g. after a script update), it's added
# with empty values, so older files keep working.
read_state <- function(file, cols) {
  path <- state_path(file)
  if (!file.exists(path)) {
    return(as_tibble(setNames(rep(list(character()), length(cols)), cols)))
  }
  df <- read.csv(path, colClasses = "character", na.strings = "",
                 fileEncoding = "UTF-8", check.names = FALSE)
  for (cl in setdiff(cols, names(df))) df[[cl]] <- NA_character_
  as_tibble(df[cols])
}

# write_state(): save a table as a CSV file in state/. Empty values are
# written as empty cells, and UTF-8 keeps names like "Røyksopp" intact.
write_state <- function(df, file) {
  write.csv(df, state_path(file), row.names = FALSE, na = "", fileEncoding = "UTF-8")
}

# The columns of each state file:
#   TRACK_COLS     - a saved copy of one playlist: one row per song
#                    (artist_ids/artist_names hold all artists, separated by "|")
#   META_COLS      - one row per saved playlist: Spotify's version code
#                    ("snapshot"), how many items are read so far, and the last
#                    song read (used to check that the list hasn't changed)
#   ARTIST_COLS    - one row per artist: the Deezer match, how it was matched,
#                    when it was last checked on Deezer, and (for artists
#                    Deezer couldn't match) when it was last checked on Spotify
#   PEND_COLS      - releases found on Deezer, not yet looked up on Spotify
#   SEEN_COLS      - releases already handled, so none is added twice
#                    (IDs start with "dz:" for Deezer or "sp:" for Spotify)
#   STAGED_COLS    - songs waiting to be added to the next weekly playlist
#   PUBLISHED_COLS - one row per weekly playlist: its Spotify ID, its status
#                    ("building" from Thursday, "done" when finished and
#                    renamed), when it was created and finished, and how many
#                    songs were added
TRACK_COLS     <- c("uri", "title", "artists", "artist_ids", "artist_names")
META_COLS      <- c("playlist_id", "name", "snapshot", "n_items", "last_uri")
ARTIST_COLS    <- c("spotify_id", "name", "deezer_id", "deezer_name", "match",
                    "matched_on", "last_checked", "sp_last_checked")
PEND_COLS      <- c("deezer_album_id", "title", "artist", "release_date", "upc",
                    "record_type", "nb_tracks", "first_track_id", "found_on", "attempts")
SEEN_COLS      <- c("release_id", "found_on")
STAGED_COLS    <- c("uri", "title", "artists", "release_id", "release_date", "staged_on")
PUBLISHED_COLS <- c("week", "playlist_id", "status", "created_on", "finished_on", "n_songs")

# Load the saved state from the previous run (empty tables on the first run).
META      <- read_state("playlists_meta.csv", META_COLS)
ARTISTS   <- read_state("artists.csv", ARTIST_COLS)
PENDING   <- read_state("pending_releases.csv", PEND_COLS)
STAGED    <- read_state("staged_tracks.csv", STAGED_COLS)

# Load the seen releases. The previous version of the script stored Deezer IDs
# in a column called deezer_album_id; those are converted to the new "dz:" form.
SEEN <- read_state("seen_releases.csv", c("release_id", "deezer_album_id", "found_on"))
# as.character() keeps the column as text even when the file is empty (ifelse()
# on an empty table returns a logical column, which bind_rows() can't combine).
SEEN$release_id <- as.character(ifelse(is.na(SEEN$release_id) & !is.na(SEEN$deezer_album_id),
                                       paste0("dz:", SEEN$deezer_album_id), SEEN$release_id))
SEEN <- SEEN[SEEN_COLS]

# Load the list of weekly playlists. Rows from the previous version of the
# script (which had no status column) are treated as finished.
PUBLISHED <- read_state("published.csv", c(PUBLISHED_COLS, "published_on"))
old_rows  <- is.na(PUBLISHED$status)
PUBLISHED$status[old_rows]      <- "done"
PUBLISHED$finished_on[old_rows] <- PUBLISHED$published_on[old_rows]
PUBLISHED <- PUBLISHED[PUBLISHED_COLS]

# save_state(): write all changing state files to disk. Called often, so little
# is lost if a run stops. Details:
#   - artists.csv is written sorted so problems come first: "not_found", then
#     artists not matched yet, "uncertain", and finally the successful matches
#     ("name", "matched", "manual"), each group alphabetically. Only the saved
#     file is sorted, not the table in memory, so loops over row numbers in
#     the script aren't disturbed.
#   - seen releases older than 180 days are dropped, so the file stays small.
save_state <- function() {
  rank <- match(ifelse(is.na(ARTISTS$match), "(none)", ARTISTS$match),
                c("not_found", "(none)", "uncertain", "name", "matched", "manual"))
  write_state(ARTISTS[order(rank, tolower(ARTISTS$name)), ], "artists.csv")
  write_state(PENDING, "pending_releases.csv")
  write_state(STAGED, "staged_tracks.csv")
  write_state(PUBLISHED, "published.csv")
  SEEN <<- SEEN |> filter(is.na(as_day(found_on)) | as_day(found_on) > TODAY - 180)
  write_state(SEEN, "seen_releases.csv")
}

# upsert_meta(): replace (or add) one playlist's row in the playlist info
# table and save it. "<<-" updates the shared META table, not a local copy.
upsert_meta <- function(row) {
  META <<- bind_rows(META[META$playlist_id != row$playlist_id, ], row)
  write_state(META, "playlists_meta.csv")
}

# pl_file(): the file name for a playlist's saved copy, based on its Spotify ID.
pl_file <- function(pid) sprintf("playlist_%s.csv", pid)

# empty_tracks(): an empty song table with the right columns. Used as a
# starting point and when there is nothing to return.
empty_tracks <- function() {
  as_tibble(setNames(rep(list(character()), length(TRACK_COLS)), TRACK_COLS))
}

# stage_tracks(): add a release's songs to the staging list for the next
# weekly playlist, skipping songs that are already staged.
stage_tracks <- function(tr, release_id, release_date) {
  if (is.null(tr) || nrow(tr) == 0) return(invisible())
  new <- tr |>
    filter(!uri %in% STAGED$uri) |>
    transmute(uri, title, artists, release_id = release_id,
              release_date = release_date, staged_on = as.character(TODAY))
  STAGED <<- bind_rows(STAGED, new)
}

# mark_seen(): remember that a release has been handled.
mark_seen <- function(release_id) {
  SEEN <<- bind_rows(SEEN, tibble(release_id = release_id, found_on = as.character(TODAY)))
}

# ---- Spotify ----------------------------------------------------------------

# get_access_token(): log in to Spotify without a browser. The refresh token
# (from get_spotify_token.R) plus the app's ID and secret are exchanged for
# a short-lived access token (valid 1 hour), which every request then uses.
# Stops with a clear message if one of the three secrets is missing.
get_access_token <- function() {
  id      <- Sys.getenv("SPOTIFY_CLIENT_ID")
  secret  <- Sys.getenv("SPOTIFY_CLIENT_SECRET")
  refresh <- Sys.getenv("SPOTIFY_REFRESH_TOKEN")
  if (any(c(id, secret, refresh) == "")) {
    stop("Set SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET and SPOTIFY_REFRESH_TOKEN.",
         call. = FALSE)
  }
  resp <- request("https://accounts.spotify.com/api/token") |>
    req_auth_basic(id, secret) |>
    req_body_form(grant_type = "refresh_token", refresh_token = refresh) |>
    req_perform()
  resp_body_json(resp)$access_token
}

# Get the access token, and set up two counters:
#   SPOTIFY_USED - number of Spotify requests made in this run
#   BLOCKED      - becomes TRUE if Spotify refuses requests (HTTP 429)
TOKEN        <- get_access_token()
SPOTIFY_USED <- 0
BLOCKED      <- FALSE

# spotify_reason(): read the "reason" field Spotify includes in its error
# replies, e.g. "QUOTA_EXCEEDED", so the log shows why requests were refused.
# Looks in a few possible places, and returns "unknown" if there is none.
spotify_reason <- function(resp) {
  j <- tryCatch(resp_body_json(resp), error = function(e) NULL)
  if (is.null(j)) return("unknown")
  as.character(j$reason %||% j$error$reason %||% j$error$message %||% "unknown")
}

# budget_left(): how many Spotify requests remain in this run's budget.
budget_left <- function() MAX_SPOTIFY_REQUESTS - SPOTIFY_USED

# sp_req(): the ONE place where every Spotify request is made. It:
#   1. stops the phase if this run's request budget is used up,
#   2. counts the request and waits SPOTIFY_PACE seconds (steady pace),
#   3. sends the request with the access token,
#   4. retries automatically on temporary errors (server errors 500/502/503,
#      or a short "wait N seconds" 429) - but NOT on quota errors or waits
#      longer than MAX_WAIT,
#   5. if Spotify still refuses (429), marks BLOCKED and stops the phase with
#      a message showing Spotify's reason and requested wait.
# Other errors (like 404) are returned to the caller to handle.
# path_or_url can be a path like "/me/playlists" or a full URL (Spotify gives
# full URLs for "next page"). body is sent as JSON; query adds ?a=b&c=d.
sp_req <- function(path_or_url, method = "GET", body = NULL, query = list()) {
  if (SPOTIFY_USED >= MAX_SPOTIFY_REQUESTS) {
    stop_run(sprintf("Used the %d Spotify requests allowed per run; continuing next run.",
                     MAX_SPOTIFY_REQUESTS), "spotify_stop")
  }
  SPOTIFY_USED <<- SPOTIFY_USED + 1
  Sys.sleep(SPOTIFY_PACE)
  url <- if (startsWith(path_or_url, "http")) path_or_url else paste0(API, path_or_url)
  req <- request(url) |>
    req_auth_bearer_token(TOKEN) |>
    req_method(method) |>
    req_retry(
      max_tries = 4,
      is_transient = function(r) {
        st <- resp_status(r)
        if (st == 429) {
          wait <- suppressWarnings(as.numeric(resp_header(r, "Retry-After") %||% "0"))
          return(!is.na(wait) && wait <= MAX_WAIT && spotify_reason(r) != "QUOTA_EXCEEDED")
        }
        st %in% c(500, 502, 503)
      },
      after = function(r) {
        ra <- resp_header(r, "Retry-After")
        if (is.null(ra)) NA else as.numeric(ra) + 1
      }
    ) |>
    req_error(is_error = function(r) FALSE)
  if (length(query)) req <- req_url_query(req, !!!query)
  if (!is.null(body)) req <- req_body_json(req, body, auto_unbox = TRUE)
  resp <- req_perform(req)
  if (resp_status(resp) == 429) {
    BLOCKED <<- TRUE
    stop_run(sprintf("Spotify refused more requests (HTTP 429, reason: %s, Retry-After: %s s).",
                     spotify_reason(resp), resp_header(resp, "Retry-After") %||% "?"),
             "spotify_stop")
  }
  resp
}

# check_resp(): if a reply is an error (status 400 or higher), stop the
# script with the status code, the address and Spotify's error text, so the
# log shows exactly what went wrong. Otherwise, pass the reply through.
check_resp <- function(resp) {
  if (resp_status(resp) >= 400) {
    body <- tryCatch(resp_body_string(resp), error = function(e) "")
    stop(sprintf("Spotify API error %s for %s\n%s", resp_status(resp), resp$url, body),
         call. = FALSE)
  }
  resp
}

# sp_first(): get the FIRST page of a list from Spotify, with two fallbacks:
#   - paths can hold several addresses (new and old endpoint names, since
#     Spotify renamed some in 2026); if one gives 404/405 "not found", the
#     next is tried.
#   - if Spotify rejects the page size (status 400), it retries with 10.
sp_first <- function(paths, query = list()) {
  query$limit <- query$limit %||% 50
  resp <- NULL
  for (p in paths) {
    resp <- sp_req(p, query = query)
    if (resp_status(resp) == 400 && query$limit > 10) {
      query$limit <- 10
      resp <- sp_req(p, query = query)
    }
    if (!(resp_status(resp) %in% c(404, 405))) break
  }
  check_resp(resp)
}

# page_of(): read one page from a Spotify reply. Most replies have "items"
# at the top; some wrap the page in an extra layer (e.g. {"albums": {...}}),
# in which case the first element is used.
page_of <- function(resp) {
  j <- resp_body_json(resp)
  if (!is.null(j$items)) j else j[[1]]
}

# sp_get_all(): get ALL pages of a list (e.g. all your playlists, or all
# tracks on an album) by following Spotify's "next" link until there is none.
# compact() removes empty entries. Returns one combined list of items.
sp_get_all <- function(paths, query = list()) {
  pg  <- page_of(sp_first(paths, query))
  out <- list()
  repeat {
    out <- c(out, compact(pg$items))
    if (is.null(pg$`next`)) break
    pg <- page_of(check_resp(sp_req(pg$`next`)))
  }
  out
}

# sp_call(): send one request (e.g. POST to add songs) trying each address in
# paths until one isn't "not found" (404/405), then check for errors.
sp_call <- function(paths, ...) {
  resp <- NULL
  for (i in seq_along(paths)) {
    resp <- sp_req(paths[i], ...)
    if (!(resp_status(resp) %in% c(404, 405))) break
  }
  check_resp(resp)
}

# playlist_paths(): the two possible addresses for a playlist's songs - the
# new name (/items) first, then the old one (/tracks) as a fallback.
playlist_paths <- function(pid) {
  c(sprintf("/playlists/%s/items", pid), sprintf("/playlists/%s/tracks", pid))
}

# tracks_to_tibble(): turn a list of Spotify track objects into a table with
# one row per song. Skips empty entries, podcast episodes and local files.
# Columns:
#   uri          - Spotify's ID for the song, used to add it to a playlist
#   title        - the song title, exactly as on Spotify
#   artists      - all artists joined as "Artist A, Artist B" (used for the
#                  exact duplicate check)
#   artist_ids   - all artist IDs joined with "|" (used to find your artists)
#   artist_names - all artist names joined with "|" ("|" inside a name is
#                  replaced by "/" so it can't break the splitting later)
tracks_to_tibble <- function(tracks) {
  tracks <- keep(tracks, function(t) {
    !is.null(t) && !is.null(t$uri) && identical(t$type %||% "track", "track") &&
      !isTRUE(t$is_local)
  })
  if (length(tracks) == 0) return(empty_tracks())
  art_names <- function(t) map_chr(t$artists, function(a) a$name %||% "")
  tibble(
    uri          = map_chr(tracks, "uri"),
    title        = map_chr(tracks, function(t) t$name %||% ""),
    artists      = map_chr(tracks, function(t) paste(art_names(t), collapse = ", ")),
    artist_ids   = map_chr(tracks, function(t) {
      paste(map_chr(t$artists, function(a) a$id %||% ""), collapse = "|")
    }),
    artist_names = map_chr(tracks, function(t) {
      paste(gsub("|", "/", art_names(t), fixed = TRUE), collapse = "|")
    })
  )
}

# item_track(): a playlist entry wraps the song in a field called "item"
# (newer API) or "track" (older API); this returns whichever exists.
# raw_uri(): the Spotify ID of a playlist entry, or "" if it has none.
# Used to remember the last song read, for the overlap check in sync_playlist().
item_track <- function(it) it$item %||% it$track
raw_uri    <- function(it) item_track(it)$uri %||% ""

# fetch_my_playlists(): get a list of all your playlists - one request per
# 50 playlists. For each: ID, name, Spotify's version code ("snapshot", which
# changes whenever the playlist changes) and the number of songs ("total").
# The snapshot is what lets the script skip unchanged playlists cheaply.
fetch_my_playlists <- function() {
  items <- sp_get_all("/me/playlists")
  tibble(
    id       = map_chr(items, "id"),
    name     = map_chr(items, function(p) p$name %||% ""),
    snapshot = map_chr(items, function(p) p$snapshot_id %||% NA_character_),
    total    = map_int(items, function(p) {
      as.integer((p$tracks %||% p$items)$total %||% NA_integer_)
    })
  )
}

# sync_playlist(): bring the saved copy of one playlist up to date, using as
# few Spotify requests as possible:
#   - If the saved version code equals Spotify's, nothing has changed:
#     zero requests.
#   - Otherwise it continues reading from where the saved copy ends (n songs
#     read so far). It first re-reads the LAST saved song (one-item overlap);
#     if that song is still in the same place, the earlier part is assumed
#     unchanged and only the new songs at the end are fetched.
#   - If the overlap doesn't match (songs removed or reordered), the list
#     has fewer songs than saved, or FULL_REFRESH is on, it reads the whole
#     playlist again from the start. A full re-read costs ~120 requests per
#     6,000 songs, so on Thursdays and Fridays it is postponed
#     (allow_full = FALSE) and the saved copy is used, keeping the budget for
#     the playlist.
#   - Progress is saved every 20 pages, and also if the Spotify budget runs
#     out, so a big first read can be spread over several runs.
#   - The version code is only saved once the whole list is read, so an
#     unfinished copy is never mistaken for a complete one.
sync_playlist <- function(pl, allow_full = TRUE) {

  # Load the saved copy and its info row (if any).
  file  <- pl_file(pl$id)
  m     <- META[META$playlist_id == pl$id, ]
  cache <- read_state(file, TRACK_COLS)

  # Decide where to start: return early if unchanged, continue from the saved
  # position, or start from scratch ("fresh"). A playlist that has never been
  # read is always read, even on Thursdays and Fridays.
  fresh <- FALSE
  n <- 0L
  last_uri <- ""
  if (nrow(m) == 1 && !FULL_REFRESH) {
    if (!is.na(m$snapshot) && identical(m$snapshot, pl$snapshot)) return(invisible())
    n <- as.integer(m$n_items %||% "0")
    last_uri <- m$last_uri %||% ""
    if (is.na(n) || (!is.na(pl$total) && n > pl$total)) fresh <- TRUE
  } else {
    fresh <- TRUE
  }
  if (fresh && nrow(m) == 1 && !allow_full) {
    message("  '", pl$name, "' needs a full re-read; postponed until Saturday.")
    return(invisible())
  }
  if (fresh) {
    n <- 0L
    last_uri <- ""
    cache <- empty_tracks()
  }

  # save_progress(): write the copy and its info row. complete = TRUE stores
  # Spotify's version code, marking the copy as finished and up to date.
  save_progress <- function(complete) {
    write_state(cache, file)
    upsert_meta(tibble(playlist_id = pl$id, name = pl$name,
                       snapshot = if (complete) pl$snapshot else NA_character_,
                       n_items = as.character(n), last_uri = last_uri))
  }

  # Everything that talks to Spotify is inside tryCatch(), so that if the
  # budget runs out or Spotify blocks, progress is saved before stopping.
  tryCatch({
    paths <- playlist_paths(pl$id)
    skip <- 0
    postponed <- FALSE

    # Get the first page: either from the last saved song (overlap check) or
    # from the start of the playlist. If the overlap doesn't match, the
    # playlist must be read from scratch - unless that's postponed (Thu/Fri).
    if (n > 0) {
      pg <- page_of(sp_first(paths, list(offset = n - 1)))
      if (length(pg$items) > 0 && identical(raw_uri(pg$items[[1]]), last_uri)) {
        skip <- 1  # the overlap matched: skip the song we already have
      } else if (!allow_full) {
        message("  '", pl$name, "' changed earlier in the list; full re-read postponed until Saturday.")
        postponed <- TRUE
      } else {
        message("  '", pl$name, "' changed earlier in the list; reading it from the start.")
        n <- 0L
        last_uri <- ""
        cache <- empty_tracks()
        pg <- page_of(sp_first(paths, list(offset = 0)))
      }
    } else {
      pg <- page_of(sp_first(paths, list(offset = 0)))
    }

    # Read page after page: add the songs to the copy, update the position
    # (n counts ALL entries, including local files, so it matches Spotify's
    # positions), and follow the "next" link until the end of the playlist.
    # Then save the copy as complete.
    if (!postponed) {
      pages <- 0
      repeat {
        items <- pg$items
        if (skip > 0) items <- items[-seq_len(skip)]
        skip <- 0
        if (length(items) > 0) {
          cache <- bind_rows(cache, tracks_to_tibble(map(items, item_track)))
          n <- n + length(items)
          last_uri <- raw_uri(items[[length(items)]])
        }
        pages <- pages + 1
        if (pages %% 20 == 0) {
          save_progress(FALSE)
          message("  '", pl$name, "': ", n, " songs read so far")
        }
        if (is.null(pg$`next`)) break
        pg <- page_of(check_resp(sp_req(pg$`next`)))
      }
      save_progress(TRUE)
      message("  '", pl$name, "' is up to date (", nrow(cache), " songs).")
    }
  }, spotify_stop = function(e) {
    # Budget used up or blocked: save what we have, then pass the stop on.
    save_progress(FALSE)
    stop(e)
  })
  invisible()
}

# sp_search(): search Spotify. type is "album" or "track"; q is a query such
# as "upc:0123456789012", "isrc:NOX001234567" or 'album:"Title" artist:"Name"'.
# Returns the albums or tracks found.
sp_search <- function(q, type, limit = 5) {
  j <- resp_body_json(check_resp(
    sp_req("/search", query = list(q = q, type = type, limit = limit))
  ))
  compact(j[[paste0(type, "s")]]$items %||% list())
}

# upc_variants(): barcodes are written with 12 digits (UPC) or 13 (EAN) - the
# same barcode with or without a leading zero. Deezer and Spotify don't always
# use the same form, so this returns both versions to try. Non-digits are
# removed; an empty or missing barcode gives nothing to try.
upc_variants <- function(u) {
  if (is.null(u) || is.na(u)) return(character())
  u <- gsub("\\D", "", u)
  if (!nzchar(u)) return(character())
  v <- u
  if (nchar(u) == 12) v <- c(u, paste0("0", u))
  if (nchar(u) == 13 && startsWith(u, "0")) v <- c(u, substring(u, 2))
  unique(v)
}

# find_spotify_album(): find the Spotify album for a release found on Deezer.
#   1. Search by barcode (exact - the same release on both services).
#   2. If that finds nothing, search by album title and artist, and accept a
#      result only if both the title and one of the artists match (ignoring
#      upper/lower case).
# Returns the Spotify album ID, or NA if it isn't (yet) on Spotify.
find_spotify_album <- function(row) {
  for (u in upc_variants(row$upc)) {
    hits <- sp_search(paste0("upc:", u), "album", limit = 1)
    if (length(hits) > 0) return(hits[[1]]$id)
  }
  hits <- sp_search(sprintf('album:"%s" artist:"%s"',
                            clean_q(row$title), clean_q(row$artist)), "album", limit = 5)
  hit <- detect(hits, function(a) {
    norm(a$name %||% "") == norm(row$title) &&
      any(norm(map_chr(a$artists, function(x) x$name %||% "")) == norm(row$artist))
  })
  if (is.null(hit)) NA_character_ else hit$id
}

# lookup_release(): get the Spotify songs for one release found on Deezer,
# using as few Spotify requests as possible:
#   - One-song releases (most singles): get the song's ISRC (the song's
#     international recording code) from Deezer for free, then find that
#     exact recording on Spotify with ONE search. Saves a request per single.
#   - Everything else, or if the ISRC search finds nothing: find the album
#     (find_spotify_album) and get its track list - usually two requests.
# Returns a song table, or NULL if the release isn't (yet) on Spotify.
lookup_release <- function(row) {
  if (identical(row$nb_tracks, "1") && !is.na(row$first_track_id)) {
    isrc <- dz_get(sprintf("/track/%s", row$first_track_id))$isrc %||% NA_character_
    if (!is.na(isrc) && nzchar(isrc)) {
      hits <- sp_search(paste0("isrc:", isrc), "track", limit = 1)
      if (length(hits) > 0) return(tracks_to_tibble(hits[1]))
    }
  }
  sid <- find_spotify_album(row)
  if (is.na(sid)) return(NULL)
  tracks_to_tibble(sp_get_all(sprintf("/albums/%s/tracks", sid)))
}

# create_playlist(): create a new playlist in your library and return its ID.
# Tries the newer address (/me/playlists) first, then the older one
# (/users/{your id}/playlists) if Spotify doesn't recognise it.
create_playlist <- function(name, description) {
  body <- list(name = name, public = PLAYLIST_PUBLIC, description = description)
  resp <- sp_req("/me/playlists", method = "POST", body = body)
  if (resp_status(resp) %in% c(404, 405)) {
    me   <- resp_body_json(check_resp(sp_req("/me")))
    resp <- sp_req(sprintf("/users/%s/playlists", me$id), method = "POST", body = body)
  }
  id <- resp_body_json(check_resp(resp))$id
  message("Created playlist '", name, "'.")
  id
}

# add_staged(): add the staged songs to a playlist, after removing duplicates:
#   1. within the staged songs (same Spotify song twice, or the same title
#      and artists twice, e.g. a single that is also on an album),
#   2. songs whose exact title AND artists exist in a check playlist (these
#      are listed in the log),
#   3. if read_existing is TRUE: songs already in the playlist (e.g. added on
#      Thursday, or by a run that stopped halfway).
# Songs are added 100 at a time, the most Spotify accepts per request; I()
# makes sure even a single song is sent as a list. Returns the number added.
add_staged <- function(pid, read_existing) {
  check_tr   <- bind_rows(PL_DATA[CHECK_PLAYLISTS])
  check_keys <- unique(dup_key(check_tr$title, check_tr$artists))
  pub <- STAGED |>
    distinct(uri, .keep_all = TRUE) |>
    distinct(title, artists, .keep_all = TRUE) |>
    mutate(key = dup_key(title, artists))
  dups <- pub |> filter(key %in% check_keys)
  if (nrow(dups) > 0) {
    message("Leaving out ", nrow(dups), " song(s) already in your playlists:")
    walk2(dups$title, dups$artists, function(t, a) message("  - ", t, " (", a, ")"))
  }
  pub <- pub |> filter(!key %in% check_keys)
  if (read_existing && nrow(pub) > 0) {
    existing <- tracks_to_tibble(map(sp_get_all(playlist_paths(pid)), item_track))
    pub <- pub |>
      filter(!uri %in% existing$uri,
             !key %in% dup_key(existing$title, existing$artists))
  }
  if (nrow(pub) > 0) {
    chunks <- split(pub$uri, ceiling(seq_along(pub$uri) / 100))
    walk(chunks, function(ch) {
      sp_call(playlist_paths(pid), method = "POST", body = list(uris = I(unname(ch))))
    })
  }
  message("Added ", nrow(pub), " song(s).")
  nrow(pub)
}

# set_week_status(): update this week's row in published.csv (and save it):
# the playlist ID, the status ("building" or "done"), the date it was created
# (kept from the first time) and finished, and the running total of songs
# added ("added" is added to the previous total).
set_week_status <- function(pid, status, added = 0) {
  row  <- PUBLISHED[PUBLISHED$week == PL_NAME, ]
  prev <- if (nrow(row) > 0) suppressWarnings(as.integer(row$n_songs[1])) else 0L
  if (is.na(prev)) prev <- 0L
  new <- tibble(
    week        = PL_NAME,
    playlist_id = as.character(pid),
    status      = status,
    created_on  = if (nrow(row) > 0 && !is.na(row$created_on[1])) row$created_on[1] else as.character(TODAY),
    finished_on = if (status == "done") as.character(TODAY) else NA_character_,
    n_songs     = as.character(prev + added)
  )
  PUBLISHED <<- bind_rows(PUBLISHED[PUBLISHED$week != PL_NAME, ], new)
  write_state(PUBLISHED, "published.csv")
}

# ---- Deezer -----------------------------------------------------------------

# dz_get(): the one place where Deezer requests are made. Deezer needs no
# login. It waits DEEZER_PACE seconds before each request and tries up to
# 5 times:
#   - network problems, server errors or 429: wait 5 s and retry,
#   - Deezer's own speed-limit error (code 4, "Quota limit exceeded" - Deezer
#     allows about 50 requests per 5 seconds): wait 6 s and retry,
#   - other Deezer errors (e.g. "no data"): return NULL.
# On success it returns the reply as a list.
dz_get <- function(path, query = list()) {
  for (attempt in 1:5) {
    Sys.sleep(DEEZER_PACE)
    req <- request(paste0(DZ, path)) |>
      req_timeout(30) |>
      req_error(is_error = function(r) FALSE)
    if (length(query)) req <- req_url_query(req, !!!query)
    resp <- tryCatch(req_perform(req), error = function(e) NULL)
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
      if (identical(as.integer(j$error$code %||% 0), 4L)) {  # "Quota limit exceeded"
        Sys.sleep(6)
        next
      }
      return(NULL)                                           # e.g. no data
    }
    return(j)
  }
  NULL
}

# match_artist(): find the Deezer artist that corresponds to one of your
# Spotify artists. Done once per artist; the result is saved in artists.csv.
#   1. Search Deezer's artists for the name (plain text: Deezer's field syntax,
#      like artist:"Name", often returns nothing) and keep only EXACT name
#      matches (ignoring upper/lower case). None -> "not_found".
#   2. Confirm the match: search Deezer's songs for "<artist> <one of your songs
#      by this artist>". If a result's artist is one of the candidates ->
#      "matched" (most reliable, also tells apart artists with the same name).
#   3. If not confirmed but there is only one artist with that name -> "name".
#   4. Several same-named artists and no confirmation -> pick the one with
#      most fans, but mark it "uncertain" (checked on Spotify instead, unless
#      CHECK_UNCERTAIN is TRUE).
match_artist <- function(name, sample_title) {
  res   <- dz_get("/search/artist", list(q = clean_q(name), limit = 25))
  cands <- keep(res$data %||% list(), function(a) norm(a$name %||% "") == norm(name))
  if (length(cands) == 0) {
    return(list(deezer_id = NA_character_, deezer_name = NA_character_, match = "not_found"))
  }
  ids <- map_chr(cands, function(a) id_chr(a$id))

  # Confirm with one of your own songs by this artist
  if (nzchar(sample_title)) {
    tr  <- dz_get("/search/track", list(q = paste(clean_q(name), clean_q(sample_title)), limit = 25))
    hit <- detect(tr$data %||% list(), function(t) id_chr(t$artist$id) %in% ids)
    if (!is.null(hit)) {
      return(list(deezer_id = id_chr(hit$artist$id), deezer_name = hit$artist$name,
                  match = "matched"))
    }
  }

  # Not confirmed: accept a single exact name, otherwise mark as uncertain
  if (length(cands) == 1) {
    return(list(deezer_id = ids[1], deezer_name = cands[[1]]$name, match = "name"))
  }
  fans <- map_dbl(cands, function(a) as.numeric(a$nb_fan %||% 0))
  i <- which.max(fans)
  list(deezer_id = ids[i], deezer_name = cands[[i]]$name, match = "uncertain")
}

# deezer_new_releases(): get an artist's releases from Deezer (up to 5 pages
# of 100, enough even for very prolific artists) and keep only those that:
#   - were released between SINCE and today, and
#   - are one of the types in INCLUDE_TYPES (album/single/ep).
deezer_new_releases <- function(did) {
  out <- list()
  idx <- 0
  for (page in 1:5) {
    j <- dz_get(sprintf("/artist/%s/albums", did), list(limit = 100, index = idx))
    items <- j$data %||% list()
    out <- c(out, items)
    if (is.null(j$`next`) || length(items) == 0) break
    idx <- idx + length(items)
  }
  keep(out, function(a) {
    d <- as_day(a$release_date %||% NA_character_)
    !is.na(d) && d >= SINCE && d <= TODAY && (a$record_type %||% "") %in% INCLUDE_TYPES
  })
}

# ---- Running the phases -----------------------------------------------------

# Flags that record why a run stopped early:
#   SPOTIFY_STOPPED - Spotify budget used up or blocked: skip later Spotify work
#   TIME_STOPPED    - time limit reached: skip the remaining phases
SPOTIFY_STOPPED <- FALSE
TIME_STOPPED    <- FALSE

# run_phase(): run one block of the script. If it stops with a "spotify_stop"
# or "time_stop" (see stop_run), print the reason, set the matching flag and
# carry on, instead of crashing. Any other error still stops the script, so
# real bugs are visible. The block runs in the main script's environment, so
# changes it makes (e.g. to ARTISTS or PENDING) are kept.
run_phase <- function(expr) {
  tryCatch({
    force(expr)
    invisible(TRUE)
  }, spotify_stop = function(e) {
    message("Spotify: ", conditionMessage(e))
    SPOTIFY_STOPPED <<- TRUE
    invisible(FALSE)
  }, time_stop = function(e) {
    message(conditionMessage(e))
    TIME_STOPPED <<- TRUE
    invisible(FALSE)
  })
}

# spotify_ok(): TRUE if Spotify can still be used in this run.
spotify_ok <- function() !SPOTIFY_STOPPED && !TIME_STOPPED && !is.null(MY_PL)

# Your list of Spotify playlists; filled in phase 1. Stays NULL if Spotify
# can't be reached, in which case the saved copies are used.
MY_PL <- NULL

# playlist_id_for(): find a playlist's Spotify ID from its name. Uses your
# current playlist list if it was fetched (stopping with an error if the name
# doesn't exist, so a typo in the settings is caught). If Spotify couldn't be
# reached, it falls back to the names saved from earlier runs.
playlist_id_for <- function(nm) {
  if (!is.null(MY_PL)) {
    ids <- MY_PL$id[MY_PL$name == nm]
    if (length(ids) == 0) stop(sprintf("No playlist named '%s' found.", nm), call. = FALSE)
    if (length(ids) > 1) warning(sprintf("Several playlists named '%s'; using the first.", nm))
    return(ids[1])
  }
  ids <- META$playlist_id[META$name == nm]
  if (length(ids) > 0) ids[1] else NA_character_
}

# What should happen to this week's playlist today? WEEK_STATUS is "none"
# (not created yet), "building" (created, "(in progress)") or "done".
#   BUILD_DUE  - Thursday, and not created yet: create it with the songs
#                staged so far.
#   FINISH_DUE - not finished yet, and it's Friday - or Saturday/Sunday if
#                Friday's run failed. On the weekend this only happens if the
#                playlist was started on Thursday or there are songs staged on
#                or before this week's Friday, so starting the script on a
#                weekend doesn't create a playlist right away.
this_friday <- TODAY - (WEEKDAY - PUBLISH_DAY)
week_row    <- PUBLISHED[PUBLISHED$week == PL_NAME, ]
WEEK_STATUS <- if (nrow(week_row) > 0) week_row$status[1] else "none"
BUILD_DUE   <- WEEK_STATUS == "none" && WEEKDAY == BUILD_DAY
FINISH_DUE  <- WEEK_STATUS != "done" && (
  IS_PUBLISH_DAY ||
    (WEEKDAY %in% CATCH_UP_DAYS &&
       (WEEK_STATUS == "building" ||
          any(as_day(STAGED$staged_on) <= this_friday, na.rm = TRUE)))
)
PLAYLIST_DUE <- BUILD_DUE || FINISH_DUE

# publish_reserve(): how many Spotify requests must be kept free on days when
# the playlist is built or finished: creating it (up to 2), reading what's
# already in it (a few), renaming it (1), and one "add" request per 100 songs
# (with room for some more songs).
publish_reserve <- function() {
  if (PLAYLIST_DUE) SPOTIFY_RESERVE + 8 + ceiling((nrow(STAGED) + 100) / 100) else SPOTIFY_RESERVE
}

message(sprintf("Today: %s (weekday %d). This week's playlist: '%s' (status: %s)%s",
                TODAY, WEEKDAY, PL_NAME, WEEK_STATUS,
                if (BUILD_DUE) " - to be created today." else
                  if (FINISH_DUE) " - to be finished today." else "."))

# The main script. Everything is inside tryCatch(..., finally = ...), so the
# state is always saved at the end - even if a real error stops the script.
tryCatch({

  # == 1. Spotify: bring the local copies of your playlists up to date ========

  # Get your list of playlists (with version codes and song counts).
  message("== 1. Updating local copies of your playlists")
  run_phase(MY_PL <- fetch_my_playlists())

  # Look up the IDs of all playlists the script needs, and update each saved
  # copy (skipped if Spotify is unreachable or the budget is used up). On
  # Thursdays and Fridays, full re-reads are postponed so the budget goes to
  # the playlist.
  needed <- unique(c(SOURCE_PLAYLISTS, CHECK_PLAYLISTS))
  pl_ids <- setNames(map_chr(needed, playlist_id_for), needed)
  for (nm in needed) {
    if (is.na(pl_ids[[nm]]) || !spotify_ok()) next
    run_phase(sync_playlist(MY_PL[MY_PL$id == pl_ids[[nm]], ][1, ],
                            allow_full = !(WEEKDAY %in% c(BUILD_DAY, PUBLISH_DAY)) ||
                              FULL_REFRESH))
  }

  # Load the saved copies, and note which copies are complete (fully read at
  # least once). Only complete copies are trusted for the duplicate check.
  PL_DATA  <- map(needed, function(nm) {
    if (is.na(pl_ids[[nm]])) empty_tracks() else read_state(pl_file(pl_ids[[nm]]), TRACK_COLS)
  }) |> setNames(needed)
  complete <- map_lgl(needed, function(nm) {
    m <- META[META$playlist_id %in% pl_ids[[nm]], ]
    nrow(m) == 1 && !is.na(m$snapshot)
  }) |> setNames(needed)

  # == 2. Deezer: match new artists ============================================
  message("== 2. Matching artists to Deezer")

  # Build a table of all artists in the source playlists: split each song's
  # "|"-joined artist IDs and names into one row per artist. pos is the
  # artist's position on the song (1 = main artist), used for
  # MAIN_ARTISTS_ONLY. sample_title is one of your songs by that artist, used
  # to confirm the Deezer match. Songs where IDs and names don't line up are
  # skipped. Each artist is kept once.
  src <- bind_rows(PL_DATA[SOURCE_PLAYLISTS])
  if (nrow(src) > 0) {
    ids <- strsplit(src$artist_ids, "|", fixed = TRUE)
    nms <- strsplit(src$artist_names, "|", fixed = TRUE)
    ok  <- lengths(ids) == lengths(nms)
    art <- tibble(
      spotify_id   = unlist(ids[ok]),
      name         = unlist(nms[ok]),
      pos          = unlist(map(ids[ok], seq_along)),
      sample_title = rep(src$title[ok], lengths(ids[ok]))
    ) |>
      filter(nzchar(spotify_id))
    if (MAIN_ARTISTS_ONLY) art <- filter(art, pos == 1)
    art <- distinct(art, spotify_id, .keep_all = TRUE)
  } else {
    art <- tibble(spotify_id = character(), name = character(), sample_title = character())
  }
  message(nrow(art), " unique artists in your source playlists.")

  # Add artists not seen before to the artist table (without a match yet), and
  # make a lookup from artist ID to one of your songs by that artist.
  new_art <- art |> filter(!spotify_id %in% ARTISTS$spotify_id)
  if (nrow(new_art) > 0) {
    ARTISTS <- bind_rows(ARTISTS, tibble(spotify_id = new_art$spotify_id, name = new_art$name))
  }
  sample_titles <- setNames(art$sample_title, art$spotify_id)

  # Decide which artists need matching:
  #   - those never matched,
  #   - those that were "not_found" or "uncertain" more than 60 days ago
  #     (Deezer's catalogue changes, so they get another try), and
  #   - any non-manual match made before REMATCH_BEFORE (a one-time redo after
  #     the search fix; it happens once, since the new match gets today's date).
  # "manual" rows are never touched.
  matched_on <- as_day(ARTISTS$matched_on)
  to_match <- which(
    ARTISTS$spotify_id %in% art$spotify_id & (
      is.na(ARTISTS$match) |
        (ARTISTS$match %in% c("not_found", "uncertain") &
           (is.na(matched_on) | matched_on <= TODAY - 60)) |
        (ARTISTS$match %in% c("not_found", "uncertain", "name", "matched") &
           !is.na(matched_on) & matched_on < REMATCH_BEFORE)
    )
  )
  message(length(to_match), " artists to match.")

  # Match them one by one, saving progress every 200 artists. Stops calmly if
  # the time limit is reached; the rest are matched in the next run.
  run_phase({
    for (k in seq_along(to_match)) {
      check_time()
      i <- to_match[k]
      m <- match_artist(ARTISTS$name[i], sample_titles[[ARTISTS$spotify_id[i]]] %||% "")
      ARTISTS$deezer_id[i]   <- m$deezer_id
      ARTISTS$deezer_name[i] <- m$deezer_name
      ARTISTS$match[i]       <- m$match
      ARTISTS$matched_on[i]  <- as.character(TODAY)
      if (k %% 200 == 0) {
        save_state()
        message("  matched ", k, " of ", length(to_match))
      }
    }
  })

  # Save, and print how many artists have each match type.
  save_state()
  print(table(ARTISTS$match, useNA = "ifany"))

  # == 3. Deezer: look for new releases ========================================
  if (!TIME_STOPPED) {
    message("== 3. Checking artists for new releases on Deezer (since ", SINCE, ")")

    # Find the artists to check: in your source playlists, matched to Deezer
    # with an accepted match type, and not already checked today (in case the
    # workflow runs twice in a day). Several Spotify artists can share one
    # Deezer artist, so each Deezer ID is checked once.
    ok_types <- c("matched", "name", "manual", if (CHECK_UNCERTAIN) "uncertain")
    due <- ARTISTS |>
      filter(spotify_id %in% art$spotify_id, !is.na(deezer_id), match %in% ok_types) |>
      group_by(deezer_id) |>
      summarise(done_today = any(last_checked %in% as.character(TODAY)), .groups = "drop") |>
      filter(!done_today)
    message(nrow(due), " artists to check.")

    # Check each artist. For each release in the window that hasn't been seen
    # before, get its details from Deezer (barcode, main artist, number of
    # songs and the first song's ID) and add it to the pending list, to be
    # looked up on Spotify in phase 4. Then record today as the artist's last
    # check. Progress is saved every 250 artists.
    run_phase({
      for (k in seq_len(nrow(due))) {
        check_time()
        did <- due$deezer_id[k]
        for (a in deezer_new_releases(did)) {
          rid <- paste0("dz:", id_chr(a$id))
          if (rid %in% SEEN$release_id) next
          det <- dz_get(sprintf("/album/%s", id_chr(a$id)))
          PENDING <- bind_rows(PENDING, tibble(
            deezer_album_id = id_chr(a$id),
            title          = a$title %||% "",
            artist         = det$artist$name %||% "",
            release_date   = a$release_date %||% "",
            upc            = as.character(det$upc %||% NA_character_),
            record_type    = a$record_type %||% "",
            nb_tracks      = as.character(det$nb_tracks %||% NA_character_),
            first_track_id = id_chr(pluck(det, "tracks", "data", 1, "id")),
            found_on       = as.character(TODAY),
            attempts       = "0"
          ))
          mark_seen(rid)
          message("  new: ", det$artist$name %||% "?", " - ", a$title %||% "?",
                  " (", a$release_date %||% "?", ")")
        }
        ARTISTS$last_checked[ARTISTS$deezer_id %in% did] <- as.character(TODAY)
        if (k %% 250 == 0) {
          save_state()
          message("  checked ", k, " of ", nrow(due))
        }
      }
    })
    save_state()
    message(nrow(PENDING), " releases waiting to be looked up on Spotify.")
  }

  # == 4. Spotify: look up new releases and stage their songs ==================
  message("== 4. Looking up new releases on Spotify")

  # Go through the pending releases, oldest first, while enough of the budget
  # is left (on Thursdays and Fridays, enough is kept free for the playlist).
  # Each release found is staged for the next weekly playlist and removed from
  # the pending list. A release not found is tried again in later runs, and
  # dropped after MAX_ATTEMPTS tries (some releases never come to Spotify).
  # done/gave_up are filled during the loop and applied afterwards, so even if
  # the phase stops halfway, finished lookups aren't repeated.
  done    <- character()
  gave_up <- character()
  if (!spotify_ok()) {
    message("Skipped: no Spotify requests available in this run.")
  } else {
    run_phase({
      for (i in order(PENDING$found_on, PENDING$release_date)) {
        if (budget_left() <= publish_reserve() + 4) {
          message("Stopping lookups to keep requests free; the rest continue next run.")
          break
        }
        check_time()
        row <- PENDING[i, ]
        tr  <- lookup_release(row)
        if (!is.null(tr)) {
          stage_tracks(tr, paste0("dz:", row$deezer_album_id), row$release_date)
          done <- c(done, row$deezer_album_id)
        } else {
          tries <- as.integer(row$attempts %||% "0") + 1
          PENDING$attempts[i] <- as.character(tries)
          if (tries >= MAX_ATTEMPTS) {
            message("  not found on Spotify, skipped: ", row$artist, " - ", row$title)
            gave_up <- c(gave_up, row$deezer_album_id)
          }
        }
      }
    })
  }
  PENDING <- PENDING |>
    filter(!deezer_album_id %in% c(done, gave_up),
           is.na(as_day(found_on)) | as_day(found_on) > TODAY - 30)
  save_state()
  message(length(done), " release(s) looked up; ", nrow(STAGED),
          " song(s) staged for the next playlist; ", nrow(PENDING), " release(s) still pending.")

  # == 5. Spotify: build (Thursday) or finish (Friday) this week's playlist ==
  if (PLAYLIST_DUE) {
    message("== 5. ", if (BUILD_DUE) "Creating '" else "Finishing '", PL_NAME, "'")

    # Only continue if Spotify is usable and the duplicate-check playlists have
    # been fully read at least once (so no duplicates slip through).
    # Otherwise the songs stay staged and the next run tries again.
    if (!spotify_ok()) {
      message("Postponed: no Spotify requests available; the next run will try again.")
    } else if (!all(complete[CHECK_PLAYLISTS])) {
      message("Postponed: the duplicate-check playlists are not fully read yet.")
    } else {
      run_phase({

        # Find this week's playlist, if it exists: first from published.csv,
        # otherwise by name in your library (in case an earlier run created it
        # but stopped before saving its ID).
        pid <- PUBLISHED$playlist_id[PUBLISHED$week == PL_NAME][1]
        if (is.na(pid)) pid <- MY_PL$id[MY_PL$name %in% c(PL_NAME, PL_NAME_BUILDING)][1]
        existed <- !is.na(pid)

        if (BUILD_DUE) {
          # Thursday: create the playlist with the "(in progress)" name and
          # add everything staged so far. If nothing is staged yet, wait -
          # Friday's run then creates it.
          if (!existed && nrow(STAGED) == 0) {
            message("Nothing staged yet; the playlist will be created on Friday.")
          } else {
            if (!existed) {
              pid <- create_playlist(PL_NAME_BUILDING,
                                     "Being built - the last songs are added on Friday.")
              set_week_status(pid, "building")
            }
            n <- add_staged(pid, read_existing = existed)
            STAGED <- STAGED[0, ]
            set_week_status(pid, "building", added = n)
          }
        } else {
          # Friday (or the weekend, if Friday failed): add the songs staged
          # since Thursday, then rename the playlist to its final name. If
          # Thursday's run didn't create it, it's created now. If there are
          # no songs at all this week, no playlist is made.
          if (!existed && nrow(STAGED) == 0) {
            message("No new songs this week; no playlist created.")
            set_week_status(NA_character_, "done")
          } else {
            if (!existed) {
              pid <- create_playlist(PL_NAME_BUILDING, "Being built.")
              set_week_status(pid, "building")
            }
            n <- add_staged(pid, read_existing = existed)
            STAGED <- STAGED[0, ]
            set_week_status(pid, "building", added = n)
            total <- PUBLISHED$n_songs[PUBLISHED$week == PL_NAME][1]
            sp_call(sprintf("/playlists/%s", pid), method = "PUT",
                    body = list(name = PL_NAME,
                                description = sprintf("Complete: %s new songs. Finished %s.",
                                                      total, TODAY)))
            set_week_status(pid, "done")
            message("Finished and renamed to '", PL_NAME, "' (", total, " songs).")
          }
        }
      })
      save_state()
    }
  }

  # == 6. Spotify: check artists Deezer couldn't match (Sat-Wed) ==============
  # With requests left over, artists that Deezer couldn't match ("not_found",
  # and "uncertain" unless CHECK_UNCERTAIN) are checked directly on Spotify,
  # those checked longest ago first, each at most once a week. Not on Thursdays
  # and Fridays, to keep Spotify's quota free for Friday's playlist.
  if (WEEKDAY %in% FALLBACK_DAYS && spotify_ok() && !PLAYLIST_DUE) {
    message("== 6. Checking unmatched artists on Spotify (with leftover requests)")
    fb_types <- c("not_found", if (!CHECK_UNCERTAIN) "uncertain")
    fb <- ARTISTS |>
      filter(spotify_id %in% art$spotify_id, match %in% fb_types) |>
      mutate(sl = as_day(sp_last_checked)) |>
      filter(is.na(sl) | sl <= TODAY - FALLBACK_INTERVAL_DAYS) |>
      arrange(!is.na(sl), sl)
    message(nrow(fb), " unmatched artists due for a Spotify check.")
    n_fb <- 0

    # For each artist: get the newest singles and the newest albums (one
    # request each, 10 per request - Spotify lists the newest first). Keep
    # releases from the window with an exact release day that haven't been
    # seen, get their songs and stage them. Then record today's check.
    run_phase({
      for (k in seq_len(nrow(fb))) {
        if (budget_left() <= SPOTIFY_RESERVE + 4) break
        check_time()
        sid <- fb$spotify_id[k]
        for (grp in c("single", "album")) {
          pg <- page_of(sp_first(sprintf("/artists/%s/albums", sid),
                                 list(include_groups = grp, limit = 10)))
          for (al in compact(pg$items)) {
            if (!identical(al$release_date_precision, "day")) next
            d <- as_day(al$release_date)
            if (is.na(d) || d < SINCE || d > TODAY) next
            rid <- paste0("sp:", al$id)
            if (rid %in% SEEN$release_id) next
            stage_tracks(tracks_to_tibble(sp_get_all(sprintf("/albums/%s/tracks", al$id))),
                         rid, al$release_date)
            mark_seen(rid)
            message("  new (via Spotify): ", fb$name[k], " - ", al$name %||% "?",
                    " (", al$release_date, ")")
          }
        }
        ARTISTS$sp_last_checked[ARTISTS$spotify_id == sid] <- as.character(TODAY)
        n_fb <- n_fb + 1
      }
    })
    message(n_fb, " unmatched artist(s) checked on Spotify.")
    save_state()
  }

}, finally = {
  # Always runs last: save the state and report how much of the Spotify
  # budget this run used.
  save_state()
  message(sprintf("Spotify requests used this run: %d of %d.", SPOTIFY_USED, MAX_SPOTIFY_REQUESTS))
})

# If Spotify blocked requests, end with an error status, so the run shows as
# failed (red) in GitHub and you notice. Progress is saved either way, and the
# workflow's "Save progress" step still commits it.
if (BLOCKED) {
  message("Spotify blocked further requests. Progress is saved; the next run will continue.")
  quit(save = "no", status = 1)
}
