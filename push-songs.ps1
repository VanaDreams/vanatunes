# Sends whatever has been added to, changed in or removed from this folder up to GitHub.
# Drop songs in vanatunes\music, then run this.
Set-Location $PSScriptRoot
git add -A
$changes = git status --porcelain
if (-not $changes) { "Nothing new to send."; return }
$songs = @($changes | Where-Object { $_ -match 'vanatunes/music/' }).Count
git commit -q -m ("Playlist: {0} song file(s) changed" -f $songs)
git push
"Sent. Players press Reinstall on vanatunes in the launcher to get them."
