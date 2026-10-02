# =============================================================================
# spotify_new_releases.R
#
# 1. Collects all artists from two source playlists.
# 2. Finds albums/singles by those artists released in the last N days.
# 3. Creates (or reuses) a playlist called "New releases week X YYYY" and
#    adds the new tracks.
# 4. Reads the new playlist back and removes every track whose title AND
#    artist(s) exactly match a track in any of the predefined check playlists.
#
# Needs three environment variables (GitHub secrets):
#   SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REFRESH_TOKEN
# Run get_spotify_token.R once locally to get the refresh token.
# =============================================================================

suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(purrr)
  library(lubridate)
  library(tibble)
})

# ---- Settings ---------------------------------------------------------------

# Names of the two playlists whose artists you want to follow (exact names)
SOURCE_PLAYLISTS <- c("Everything everything - Part 1", "Everything everything - Part 2")

# Playlists to check for duplicates (exact names). Tracks in the new playlist
# that already exist in any of these are removed. The two source playlists
# are included by default; add more names as needed.
CHECK_PLAYLISTS <- c(SOURCE_PLAYLISTS)

LOOKBACK_DAYS   <- 7                    # how far back counts as "new"
INCLUDE_GROUPS  <- c("album", "single") # add "appears_on" or "compilation" if wanted
PLAYLIST_PUBLIC <- FALSE                # new playlist private by default
TIMEZONE        <- "Europe/Oslo"
PAGE_LIMIT      <- 50                   # lowered to 10 automatically if Spotify rejects it
MAX_ALBUM_PAGES <- 3                    # per artist and release type

API <- "https://api.spotify.com/v1"

# ---- Authentication ---------------------------------------------------------

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
  tok <- resp_body_json(resp)
  if (!is.null(tok$refresh_token) && tok$refresh_token != refresh) {
    message("Note: Spotify returned a new refresh token. If the next run fails ",
            "with an auth error, run get_spotify_token.R again and update the secret.")
  }
  tok$access_token
}

TOKEN <- get_access_token()

# ---- API helpers ------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a

sp_req <- function(path_or_url, method = "GET", body = NULL, query = list()) {
  url <- if (startsWith(path_or_url, "http")) path_or_url else paste0(API, path_or_url)
  req <- request(url) |>
    req_auth_bearer_token(TOKEN) |>
    req_method(method) |>
    req_retry(
      max_tries   = 5,
      is_transient = function(r) resp_status(r) %in% c(429, 500, 502, 503),
      after = function(r) {
        ra <- resp_header(r, "Retry-After")
        if (is.null(ra)) NA else as.numeric(ra) + 1
      }
    ) |>
    req_error(is_error = function(r) FALSE)
  if (length(query)) req <- req_url_query(req, !!!query)
  if (!is.null(body)) req <- req_body_json(req, body, auto_unbox = TRUE)
  req_perform(req)
}

safe_body <- function(resp) {
  tryCatch(resp_body_string(resp), error = function(e) "")
}

check_resp <- function(resp) {
  if (resp_status(resp) >= 400) {
    stop(sprintf("Spotify API error %s for %s\n%s",
                 resp_status(resp), resp$url, safe_body(resp)), call. = FALSE)
  }
  resp
}

# Try several endpoint paths in order (Spotify renamed some endpoints in 2026,
# e.g. /playlists/{id}/tracks -> /playlists/{id}/items). Falls through on 404/405.
sp_call <- function(paths, ...) {
  for (i in seq_along(paths)) {
    resp <- sp_req(paths[i], ...)
    if (!(resp_status(resp) %in% c(404, 405)) || i == length(paths)) break
  }
  check_resp(resp)
}

# Fetch every page of a paged endpoint. Stops early if stop_fn(page_items) is TRUE.
get_all_pages <- function(paths, query = list(), max_pages = Inf, stop_fn = NULL) {
  query$limit <- query$limit %||% PAGE_LIMIT
  # First page (with endpoint fallback and automatic page-size fallback)
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

  out <- list()
  n <- 0
  repeat {
    j  <- resp_body_json(resp)
    pg <- if (!is.null(j$items)) j else j[[1]]   # some endpoints wrap the page
    items <- compact(pg$items)
    out <- c(out, items)
    n <- n + 1
    nxt <- pg$`next`
    if (is.null(nxt) || n >= max_pages) break
    if (!is.null(stop_fn) && stop_fn(items)) break
    resp <- check_resp(sp_req(nxt))
  }
  out
}

# Turn a list of Spotify track objects into a tibble
tracks_to_tibble <- function(tracks) {
  tracks <- keep(tracks, function(t) {
    !is.null(t) && identical(t$type %||% "track", "track") && !isTRUE(t$is_local)
  })
  if (length(tracks) == 0) {
    return(tibble(id = character(), uri = character(), title = character(),
                  artists = character(), artist_ids = list()))
  }
  tibble(
    id         = map_chr(tracks, function(t) t$id %||% NA_character_),
    uri        = map_chr(tracks, function(t) t$uri %||% NA_character_),
    title      = map_chr(tracks, function(t) t$name %||% NA_character_),
    # all artists, in Spotify's order, e.g. "Artist A, Artist B"
    artists    = map_chr(tracks, function(t) paste(map_chr(t$artists, "name"), collapse = ", ")),
    artist_ids = map(tracks, function(t) unlist(map(t$artists, "id")))
  ) |>
    filter(!is.na(uri))
}

playlist_paths <- function(pid) {
  c(sprintf("/playlists/%s/items", pid), sprintf("/playlists/%s/tracks", pid))
}

get_playlist_tracks <- function(pid) {
  items <- get_all_pages(playlist_paths(pid))
  # newer API responses use "item", older ones "track"
  tracks_to_tibble(map(items, function(it) it$item %||% it$track))
}

# The key used for duplicate checks: exact title + exact artist string
dup_key <- function(title, artists) paste(title, artists, sep = "\u001F")

# ---- 1. Find playlists by name ---------------------------------------------

message("Fetching your playlists ...")
my_playlists <- get_all_pages("/me/playlists")
pl_tbl <- tibble(
  id   = map_chr(my_playlists, "id"),
  name = map_chr(my_playlists, function(p) p$name %||% "")
)

find_playlist_id <- function(name) {
  ids <- pl_tbl$id[pl_tbl$name == name]
  if (length(ids) == 0) stop(sprintf("No playlist named '%s' found.", name), call. = FALSE)
  if (length(ids) > 1) warning(sprintf("Several playlists named '%s'; using the first.", name))
  ids[1]
}

# ---- 2. Collect artists from the source playlists ---------------------------

source_tracks <- map(SOURCE_PLAYLISTS, function(nm) {
  message("Reading source playlist: ", nm)
  get_playlist_tracks(find_playlist_id(nm))
}) |> bind_rows()

artist_ids <- unique(na.omit(unlist(source_tracks$artist_ids)))
message(length(artist_ids), " unique artists found.")

# ---- 3. Find new releases ---------------------------------------------------

today  <- as_date(with_tz(now(), TIMEZONE))
cutoff <- today - days(LOOKBACK_DAYS)

release_date_of <- function(album) {
  # Only albums with an exact day can be placed reliably in a one-week window
  if (!identical(album$release_date_precision, "day")) return(as.Date(NA))
  as.Date(album$release_date)
}

is_new <- function(album) {
  d <- release_date_of(album)
  !is.na(d) && d > cutoff && d <= today
}

new_albums <- list()
for (i in seq_along(artist_ids)) {
  aid <- artist_ids[i]
  if (i %% 25 == 0) message("  checked ", i, " of ", length(artist_ids), " artists")
  for (grp in INCLUDE_GROUPS) {
    albums <- get_all_pages(
      sprintf("/artists/%s/albums", aid),
      query     = list(include_groups = grp),
      max_pages = MAX_ALBUM_PAGES,
      # results are normally newest first: stop when a whole page is older than the cutoff
      stop_fn   = function(items) all(map_lgl(items, function(a) {
        d <- release_date_of(a)
        !is.na(d) && d <= cutoff
      }))
    )
    new_albums <- c(new_albums, keep(albums, is_new))
  }
}

# The same album can be found via several artists
new_albums <- new_albums[!duplicated(map_chr(new_albums, "id"))]
message(length(new_albums), " new releases found between ", cutoff + 1, " and ", today, ".")

new_tracks <- map(new_albums, function(al) {
  tracks_to_tibble(get_all_pages(sprintf("/albums/%s/tracks", al$id)))
}) |>
  bind_rows()

# Remove duplicates within the new list itself (e.g. a single that is also on a new album)
if (nrow(new_tracks) > 0) {
  new_tracks <- new_tracks |>
    distinct(uri, .keep_all = TRUE) |>
    distinct(title, artists, .keep_all = TRUE)
}
message(nrow(new_tracks), " new tracks to add.")

# ---- 4. Create (or reuse) this week's playlist and add tracks ---------------

week_no  <- isoweek(today)
week_yr  <- isoyear(today)
pl_name  <- sprintf("New releases week %d %d", week_no, week_yr)

create_playlist <- function(name) {
  body <- list(
    name        = name,
    public      = PLAYLIST_PUBLIC,
    description = sprintf("New releases from my followed playlists, created %s.", today)
  )
  resp <- sp_req("/me/playlists", method = "POST", body = body)
  if (resp_status(resp) %in% c(404, 405)) {
    me   <- resp_body_json(check_resp(sp_req("/me")))
    resp <- sp_req(sprintf("/users/%s/playlists", me$id), method = "POST", body = body)
  }
  resp_body_json(check_resp(resp))$id
}

add_tracks <- function(pid, uris) {
  if (length(uris) == 0) return(invisible())
  chunks <- split(uris, ceiling(seq_along(uris) / 100))
  walk(chunks, function(ch) {
    sp_call(playlist_paths(pid), method = "POST", body = list(uris = I(unname(ch))))
  })
}

# Replace the full contents of a playlist (used for removing duplicates)
replace_tracks <- function(pid, uris) {
  first <- head(uris, 100)
  sp_call(playlist_paths(pid), method = "PUT", body = list(uris = I(unname(first))))
  add_tracks(pid, uris[-seq_along(first)])
}

if (pl_name %in% pl_tbl$name) {
  new_pid <- find_playlist_id(pl_name)
  message("Playlist '", pl_name, "' already exists; adding only missing tracks.")
  already <- get_playlist_tracks(new_pid)$uri
} else if (nrow(new_tracks) > 0) {
  new_pid <- create_playlist(pl_name)
  message("Created playlist '", pl_name, "'.")
  already <- character()
} else {
  message("No new releases this week; no playlist created.")
  quit(save = "no", status = 0)
}

add_tracks(new_pid, setdiff(new_tracks$uri, already))

# ---- 5. Remove duplicates against the predefined playlists ------------------

message("Checking for duplicates ...")
check_names <- setdiff(unique(CHECK_PLAYLISTS), pl_name)
check_tracks <- map(check_names, function(nm) get_playlist_tracks(find_playlist_id(nm))) |>
  bind_rows()
check_keys <- unique(dup_key(check_tracks$title, check_tracks$artists))

final_tracks <- get_playlist_tracks(new_pid) |>
  mutate(key = dup_key(title, artists), is_dup = key %in% check_keys)

dups <- filter(final_tracks, is_dup)

if (nrow(dups) > 0) {
  message("Removing ", nrow(dups), " duplicate(s):")
  walk2(dups$title, dups$artists, function(t, a) message("  - ", t, " (", a, ")"))
  keep_uris <- final_tracks$uri[!final_tracks$is_dup]
  replace_tracks(new_pid, keep_uris)
} else {
  message("No duplicates found.")
}

# ---- Summary ---------------------------------------------------------------

n_final <- sum(!final_tracks$is_dup)
message(sprintf("Done: '%s' now has %d track(s).", pl_name, n_final))
if (n_final == 0) message("The playlist is empty; you may want to delete it in Spotify.")
