# vanatunes

Your own playlist in game, as an Ashita v4 addon. Put songs in a folder, turn shuffle on, and it plays from the list wherever you are instead of being tied to the one tune each zone has. It moves to another song when one ends.

The songs are played by Windows itself, beside the game. No game track is forced or replaced, nothing is converted, and the zone's own music carries on underneath: turn Music down in the game's sound config if you only want your own.

Nothing plays until you are in game, so the title screen keeps its own music.

## Install

Copy this folder to `Ashita-v4beta\addons\vanatunes\`, then in game:

```
/addon load vanatunes
```

## Use

The Vanadreams playlist comes with the addon, in its `music` folder. When songs are added to it, press Reinstall on the launcher's Addons page to get them.

Your own songs go in `Ashita-v4beta\config\vanatunes\music\` (the addon makes the folder), or point it at a folder you already have under Folder in the window, then press Rescan. Both lists play together. Untick what you do not want.

`/vanatunes` opens and closes the window. In it: Play, Pause, Next, Stop, Shuffle, Volume, and the list of songs. Untick a song to leave it out; click one to play it now.

```
/vanatunes play
/vanatunes pause
/vanatunes next
/vanatunes stop
/vanatunes shuffle
/vanatunes volume 40
/vanatunes rescan
```

Shuffle plays every ticked song once before any repeats, and never the same song twice in a row.

## Settings

Kept per character by Ashita's settings library under `config\addons\vanatunes\`.
