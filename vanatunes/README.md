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

The Vanadreams playlist comes with the addon, in its `music` folder. When songs are added to it, press Reinstall on the launcher's Addons page to get them.

Your own songs go in **Vanadreams Music** on your Desktop (the addon makes the folder), or point it at a folder you already have under Folder in the window, then press Rescan. Both lists play together. Untick what you do not want.

`/vanatunes` opens and closes the window. In it: My music / Game music, Play, Pause, Next, Stop, Shuffle, Volume, how loud the game's music stays under yours, and the list of songs. Untick a song to leave it out; click one to play it now.

```
/vanatunes play
/vanatunes pause
/vanatunes next
/vanatunes stop
/vanatunes shuffle
/vanatunes volume 40
/vanatunes rescan
```

**Silence the game's sound effects too** (off by default) is for playing more than one character at once, or when you only want your songs. While a song of yours plays, the addon runs the game's own `/mutese on`, and `/mutese off` when the song pauses or stops. If the game closes in between, the next load puts it right.

Shuffle plays every ticked song once before any repeats, and never the same song twice in a row.

## Settings

Kept per character by Ashita's settings library under `config\addons\vanatunes\`.

The window has a **see-through / solid** switch in its title bar, beside the moon, so the game can show through it; the choice is remembered.
