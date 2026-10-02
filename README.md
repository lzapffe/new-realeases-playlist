# new-realeases-playlist
Looks for new releases by the artists I have in selected playlists, looks for any new releases from these artists over the past 7 days, and creates a Spotify playlist with the new releases

To use the reository, go to the developer site for Spotify to create an app and get a Client ID and client secret. Add this ID and secret as Github secrest as SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET.
Then run the script get_spotify_token.R with these variables defined in R to get the token. One way to run the script with these variables defined in R is to add the following into your R console in the same session as you run the get_spotify_token.R file:
"Sys.setenv(
  SPOTIFY_CLIENT_ID = "",
  SPOTIFY_CLIENT_SECRET = ""
)
source("get_spotify_token.R")" where you fill inn your client ID and secret. Once you exit R again, this will be forgotten again.

Copy the token you get (without any spaces before and after) and add it into github as a secret under SPOTIFY_REFRESH_TOKEN.

If the script suddenly stops working, it can be a good idea to rerun this get token script and refresh the token in Github actions.

Now that you have all the required secrets in github, it should successfully run the code every Friday to give you a Spotify playlist with the new releases of the artists you listen to, this one not capped at 30 like Spotify's Release Radar is.



The code and workflow in this repository is build with Claude's Opus 5.5 on medium effort.