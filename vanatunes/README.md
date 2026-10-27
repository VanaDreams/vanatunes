# vanatunes

Your own playlist in game, as an Ashita v4 addon. Put songs in a folder, turn shuffle on, and it plays from the list wherever you are instead of being tied to the one tune each zone has. It moves to another song when one ends.

The songs are played by Windows itself, beside the game. No game track is forced or replaced and nothing is converted. While one of yours is playing, the game's own Music Volume is turned down for you, and it goes back to where you had it the moment yours stops.

**My music / Game music** at the top of the window switches between the two in one press.

Nothing plays until you press it, and never at the title screen, which keeps its own music.

## Install

Copy this folder to `Ashita-v4beta\addons\vanatunes\`, then in game:

```
/addon load vanatunes
```

## Use

The songs already in the addon's `music` folder appear under **VanaTunes Vol. 1**. To ship another album, make a folder directly inside `vanatunes/music`, such as `vanatunes/music/Bumper Mania/`, and put its audio files there. Its folder name becomes a playlist tab. Press **Reinstall** on the launcher's Addons page to receive new albums or songs. The launcher copies album subfolders as well as the existing songs.

Your own loose songs go in **Vanadreams Music** on your Desktop (the addon makes the folder), under **My Songs**. Make a folder inside it for each personal album; for example, `Desktop/Vanadreams Music/Road Trip/` becomes **Road Trip (Mine)**. You can also point Folder in the window at a different music location. Press **Rescan** after adding or removing folders or songs. Folders with no playable audio files do not show a tab.

`/vanatunes` opens and closes the window. Choose an album tab to play from that album; **Next** and **Shuffle** stay in the selected album. Switching tabs while music plays starts a song from the new album. The window also has My music / Game music, Play, Pause, Stop, Volume, how loud the game's music stays under yours, and the album's song list. Untick a song to leave it out; click one to play it now. Your selected album and unticked songs are remembered.

```
/vanatunes play
/vanatunes pause
/vanatunes next
/vanatunes stop
/vanatunes shuffle
/vanatunes volume 40
/vanatunes rescan
```

**Silence the game's sound effects too** (off by default) is for playing more than one character at once, or when you only want your songs. While a song of yours plays, the game's Sound Effects volume goes to 0, and it goes back to what you had when the song pauses or stops, at the title screen and when the addon unloads.

**Only the game window I am in makes sound** (off by default) is for playing the game in more than one window. Only the window in front plays its game music and sound effects, the others go quiet, and when you alt-tab the sound comes with you. It reads which window is in front and uses the game's own Music and Sound Effects volumes, and gives each back to the number you had.

**Keep the zone music while riding a mount** (on by default; untick it to hear the mount song again) stops the chocobo or mount song from taking over when you mount, so the zone's own music carries on. It changes the one music message the server sends when you mount, on your side only; nothing is sent back to the server and no game files change. If riding then leaves you with silence, also tick **Drop the mount music instead of emptying it**. `/vanatunes mount on` and `/vanatunes mount off` do the same from the chat line. It takes effect the next time you mount. The server plays no music while fishing, so there is nothing to change there.

Shuffle plays every ticked song in the selected album once before any repeats, and never the same song twice in a row.

## Settings

Kept per character by Ashita's settings library under `config\addons\vanatunes\`.

The window has a **see-through / solid** switch in its title bar, beside the moon, so the game can show through it; the choice is remembered.
