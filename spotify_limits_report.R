# =============================================================================
# spotify_limits_report.R  (run by hand in R, from the repository's folder)
#
# Reads the Spotify request log (state/spotify_request_log.csv) and writes an
# Excel report, state/spotify_limits_report.xlsx, to help work out Spotify's
# limit. Sheets:
#   runs    - every logged run, plus the requests in the 24 hours, the same
#             calendar day and the 7 days up to the end of that run
#   days    - requests per calendar day (Oslo time)
#   blocks  - the runs Spotify blocked (429), with the same three totals
#   summary - the highest totals that were NOT blocked, and the lowest totals
#             that WERE blocked, for each kind of window
# How to read it: if blocks always come at about the same 24-hour total, the
# limit is probably a rolling 24 hours; if they line up with the calendar-day
# total, it is per day; if they are scattered, it seems fluid.
# Uses no API at all. Needs the packages dplyr and writexl.
#
# Run it with: Rscript spotify_limits_report.R   (or source() it in RStudio)
# =============================================================================

# Load the packages.
suppressPackageStartupMessages({
  library(dplyr)
  library(writexl)
})

LOG_FILE    <- "state/spotify_request_log.csv"
REPORT_FILE <- "state/spotify_limits_report.xlsx"

# Read the log and turn the times into real times (Oslo). A run's requests are
# counted at its end time: runs take about 30 minutes, so this is close enough
# for 24-hour, daily and weekly windows.
log <- read.csv(LOG_FILE, colClasses = "character", na.strings = "", encoding = "UTF-8") |>
  mutate(started  = as.POSIXct(started, tz = "Europe/Oslo"),
         ended    = as.POSIXct(ended, tz = "Europe/Oslo"),
         requests = as.integer(requests),
         day      = as.Date(format(ended, "%Y-%m-%d", tz = "Europe/Oslo"))) |>
  arrange(ended)

# total_before(): for each run, the sum of requests of all runs that ended in
# the window of this length up to (and including) this run's end.
total_before <- function(ends, req, hours) {
  vapply(seq_along(ends), function(i) {
    in_window <- ends <= ends[i] & ends > ends[i] - hours * 3600
    sum(req[in_window], na.rm = TRUE)
  }, numeric(1))
}

# The runs sheet: each run with its three totals.
runs <- log |>
  mutate(last_24_hours  = total_before(ended, requests, 24),
         same_day       = ave(requests, day, FUN = function(x) cumsum(ifelse(is.na(x), 0, x))),
         last_7_days    = total_before(ended, requests, 24 * 7),
         blocked        = result == "blocked (429)")

# The days sheet: totals per calendar day.
days <- runs |>
  group_by(day, weekday = format(day, "%A")) |>
  summarise(runs = n(), requests = sum(requests, na.rm = TRUE),
            blocked = any(blocked), .groups = "drop")

# The blocks sheet: only the blocked runs.
blocks <- runs |>
  filter(blocked) |>
  select(script, started, ended, requests, last_24_hours, same_day, last_7_days,
         retry_after_s, reason, note)

# The summary sheet: per window, the highest total that went fine and the
# lowest total at which Spotify blocked. If the second is empty, there has
# been no block yet, so the limit is only known to be above the first.
window_summary <- function(col, label) {
  ok  <- runs[[col]][!runs$blocked]
  bad <- runs[[col]][runs$blocked]
  tibble(window = label,
         highest_without_block = if (length(ok)) max(ok) else NA_real_,
         lowest_with_block     = if (length(bad)) min(bad) else NA_real_,
         blocks                = length(bad))
}
summary_sheet <- bind_rows(
  window_summary("last_24_hours", "rolling 24 hours"),
  window_summary("same_day", "calendar day (Oslo)"),
  window_summary("last_7_days", "rolling 7 days")
)

# Write the Excel file (times as text, so Excel shows them as written).
fmt <- function(df) mutate(df, across(where(~ inherits(.x, "POSIXct")),
                                      ~ format(.x, "%Y-%m-%d %H:%M", tz = "Europe/Oslo")))
write_xlsx(list(summary = summary_sheet,
                runs    = fmt(select(runs, -day)),
                days    = days,
                blocks  = fmt(blocks)),
           REPORT_FILE)
message("Report written to ", REPORT_FILE, " (", nrow(runs), " runs, ",
        sum(runs$blocked), " blocks).")
