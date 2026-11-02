# =============================================================================
# spotify_log.R  (shared helper, goes in the repository's top folder)
#
# Keeps a log of every run that uses the Spotify API, so we can learn what
# Spotify's limit is (per rolling 24 hours, per calendar day or per week).
# Each Spotify script loads this file with source("spotify_log.R") and calls
# spotify_log_start() once. When the script ends - normally, with an error or
# with quit() - one line is added to state/spotify_request_log.csv:
#
#   script, started, ended (Oslo time), weekday, requests, result,
#   retry_after_s and reason (only filled in when Spotify blocked, HTTP 429),
#   note
#
# Runs that made no Spotify requests (e.g. a Christmas run started on a
# blocked day) are not logged. The workflows commit the file with the rest.
# Uses only base R.
# =============================================================================

SPOTIFY_LOG_FILE <- "state/spotify_request_log.csv"

# All the log's working values live in one small environment, so they never
# clash with the scripts' own variable names.
SPOTIFY_LOG <- new.env()
SPOTIFY_LOG$written     <- FALSE
SPOTIFY_LOG$finished    <- FALSE
SPOTIFY_LOG$count       <- 0
SPOTIFY_LOG$retry_after <- NA_character_
SPOTIFY_LOG$reason      <- NA_character_

# oslo_time(): a time as "2026-11-02 10:20:01" in Oslo time.
oslo_time <- function(t) format(t, "%Y-%m-%d %H:%M:%S", tz = "Europe/Oslo")

# spotify_log_start(): call once at the start. "script" is the name in the log.
# "get_count" is a function that returns the script's own request counter
# (e.g. function() SPOTIFY_USED); without it, spotify_log_add() is counted.
# The line is written automatically when R stops (a "finalizer"), so even a
# run that ends with an error is logged.
spotify_log_start <- function(script, get_count = NULL) {
  SPOTIFY_LOG$script    <- script
  SPOTIFY_LOG$started   <- Sys.time()
  SPOTIFY_LOG$get_count <- get_count %||% function() SPOTIFY_LOG$count
  reg.finalizer(SPOTIFY_LOG, function(e) spotify_log_write(), onexit = TRUE)
  invisible(TRUE)
}

# spotify_log_add(): count one request (for scripts without their own counter).
spotify_log_add <- function(n = 1) SPOTIFY_LOG$count <- SPOTIFY_LOG$count + n

# spotify_log_429(): call when Spotify answers 429 ("too many requests"), with
# its Retry-After header (seconds) and, if known, its reason text.
spotify_log_429 <- function(retry_after = NA, reason = NA) {
  SPOTIFY_LOG$retry_after <- as.character(retry_after %||% NA)
  SPOTIFY_LOG$reason      <- as.character(reason %||% NA)
}

# spotify_log_done(): call as the script's very last line, so the log says
# "finished" instead of "stopped early".
spotify_log_done <- function() SPOTIFY_LOG$finished <- TRUE

# spotify_log_write(): add the line (only once per run). Called by the
# finalizer; never stops the script, even if writing fails.
spotify_log_write <- function() {
  if (isTRUE(SPOTIFY_LOG$written) || is.null(SPOTIFY_LOG$started)) return(invisible())
  SPOTIFY_LOG$written <- TRUE
  n <- tryCatch(as.integer(SPOTIFY_LOG$get_count()), error = function(e) NA_integer_)
  blocked <- !is.na(SPOTIFY_LOG$retry_after) || !is.na(SPOTIFY_LOG$reason)
  if (isTRUE(n == 0) && !blocked) return(invisible())
  result <- if (blocked) "blocked (429)" else if (SPOTIFY_LOG$finished) "finished" else "stopped early"
  row <- data.frame(
    script        = SPOTIFY_LOG$script,
    started       = oslo_time(SPOTIFY_LOG$started),
    ended         = oslo_time(Sys.time()),
    weekday       = format(SPOTIFY_LOG$started, "%A", tz = "Europe/Oslo"),
    requests      = n,
    result        = result,
    retry_after_s = SPOTIFY_LOG$retry_after,
    reason        = SPOTIFY_LOG$reason,
    note          = NA_character_
  )
  tryCatch({
    dir.create(dirname(SPOTIFY_LOG_FILE), showWarnings = FALSE, recursive = TRUE)
    new_file <- !file.exists(SPOTIFY_LOG_FILE)
    write.table(row, SPOTIFY_LOG_FILE, sep = ",", append = !new_file, col.names = new_file,
                row.names = FALSE, na = "", qmethod = "double", fileEncoding = "UTF-8")
    message(sprintf("Logged this run in %s: %s requests, %s.", SPOTIFY_LOG_FILE, n, result))
  }, error = function(e) message("Could not write the Spotify request log: ", conditionMessage(e)))
  invisible()
}
