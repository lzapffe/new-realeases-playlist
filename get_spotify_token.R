# Run this ONCE on your own computer to get a refresh token.
# Before running:
#   1. Create an app at https://developer.spotify.com/dashboard (Web API).
#   2. Add this exact Redirect URI in the app settings:  http://127.0.0.1:8888/callback
#   3. Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET, e.g. in ~/.Renviron
# A browser window opens; log in and approve. The refresh token is printed.
# Store it as the GitHub secret SPOTIFY_REFRESH_TOKEN. Never commit it.

library(httr2)

client <- oauth_client(
  id        = Sys.getenv("SPOTIFY_CLIENT_ID"),
  secret    = Sys.getenv("SPOTIFY_CLIENT_SECRET"),
  token_url = "https://accounts.spotify.com/api/token",
  name      = "spotify-new-releases"
)

token <- oauth_flow_auth_code(
  client,
  auth_url     = "https://accounts.spotify.com/authorize",
  scope        = paste("playlist-read-private", "playlist-read-collaborative",
                       "playlist-modify-private", "playlist-modify-public"),
  redirect_uri = "http://127.0.0.1:8888/callback",
  pkce         = FALSE  # standard flow: the refresh token stays valid between runs
)

cat("\nYour refresh token:\n", token$refresh_token, "\n")
