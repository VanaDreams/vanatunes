--[[
    vanatunes - your own playlist in game, for Vanadreams.

    Drop mp3 or wav files in a folder and the window lists them. Shuffle on, and it plays
    from the list wherever you are, moving to another song when one ends. The songs are
    played by Windows itself, beside the game: no game track is forced or replaced, and the
    game's own Music Volume is turned down while one plays and put back when it stops.

    Nothing plays until you are in game, so the title screen keeps its own music.

    Commands:
      /vanatunes               toggle the window
      /vanatunes play          play, or carry on after a pause
      /vanatunes pause         pause
      /vanatunes next          another song
      /vanatunes stop          stop
      /vanatunes shuffle       shuffle on or off
      /vanatunes volume 0-100  how loud
      /vanatunes rescan        read the folder again
      /vanatunes mount on|off  keep the zone music while riding a mount
]]

addon.name    = 'vanatunes';
addon.author  = 'Vanadreams';
addon.version = '0.3.8';
addon.desc    = 'Your own playlist, shuffled, wherever you are.';
addon.link    = 'https://github.com/VanaDreams/vanatunes';

require('common');
local imgui    = require('imgui');
local vd       = require('vdstyle');
local settings = require('settings');
local ffi      = require('ffi');

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------
local defaults = T{
    window_open = T{ true },
    folder      = T{ '' },       -- empty = "Vanadreams Music" on the Desktop
    shuffle     = T{ true },
    autoplay    = T{ false },    -- start playing once you are in game; off until the player asks
    volume      = T{ 60 },       -- 0-100
    skipped     = T{},           -- file names unticked in the list
    album       = '',            -- selected playlist tab
    game_music  = T{ 0 },        -- the game's own Music Volume while a song of ours plays, 0-100
    game_music_before = -1,      -- the player's Music Volume, kept while ours is turned down; -1 = not turned down
    focus_only  = T{ false },    -- only the game window you are in makes sound: the others go quiet until you switch to them
    sfx_mute    = T{ false },    -- also silence the game's sound effects while a song of ours plays
    sfx_before  = -1,            -- the player's Sound Effects volume, kept while it is silenced; -1 = not silenced
    mount_keep  = T{ true },    -- keep the zone's music while riding a mount instead of the mount song
    mount_drop  = T{ false },    -- with mount_keep: drop the mount music packet instead of emptying it
};

local cfg = settings.load(defaults);

-- ---------------------------------------------------------------------------
-- Windows audio (winmm MCI). One device at a time, always from the render thread.
--
-- The 'mpegvideo' device is DirectShow (mciqtz32 -> quartz -> msmpeg2ac3dec), which runs its
-- own decoder thread inside the game. 0.3.0 closed the old song and opened the next in the same
-- frame, straight from inside a 'status' query; the decoder's thread was still unwinding the
-- old graph, hit that re-entrancy and called __fastfail, killing the game with no stack
-- (0xC0000602 in msmpeg2ac3dec.dll, seen five times on Terry's PC in sixteen days, twice in
-- crash dumps at the same instruction). So, from 0.3.1: a song change is three steps on three
-- frames (stop, then close, then open), the device is never closed from the frame that queried
-- it, and every song gets a fresh alias so a new graph can never collide with one still closing.
-- 0.3.1 still crashed that PC, idle, mid-session: a frame (about 16ms) after a song ends or is
-- stopped is not long enough for the decoder to wind down. From 0.3.2 the steps are spaced in real
-- time (a second from stop to close, half a second from close to open), and while a song plays the
-- device is asked nothing except, in its last few seconds, whether it is over.
-- ---------------------------------------------------------------------------
ffi.cdef[[
    uint32_t mciSendStringA(const char* command, char* result, uint32_t result_len, void* callback);
    int      mciGetErrorStringA(uint32_t err, char* text, uint32_t text_len);
]];
local winmm   = ffi.load('winmm');
local mci_buf = ffi.new('char[512]');
local mci_err = ffi.new('char[256]');
local alias_n = 0;
local STOP_TO_CLOSE = 1.0;     -- seconds from a stop (or a song ending) to closing its device
local CLOSE_TO_OPEN = 0.5;     -- seconds from closing a device to opening the next song
ffi.cdef[[ void Sleep(uint32_t ms); ]];

local function mci(command)
    local err = winmm.mciSendStringA(command, mci_buf, 512, nil);
    if err ~= 0 then
        winmm.mciGetErrorStringA(err, mci_err, 256);
        return nil, ffi.string(mci_err);
    end
    return ffi.string(mci_buf);
end

-- ---------------------------------------------------------------------------
-- The real Desktop folder, wherever Windows keeps it (OneDrive moves it on many PCs).
-- ---------------------------------------------------------------------------
ffi.cdef[[
    typedef struct { uint32_t d1; uint16_t d2; uint16_t d3; uint8_t d4[8]; } vt_guid_t;
    int32_t SHGetKnownFolderPath(const vt_guid_t* id, uint32_t flags, void* token, wchar_t** path);
    void    CoTaskMemFree(void* p);
    int     WideCharToMultiByte(uint32_t codepage, uint32_t flags, const wchar_t* wide, int wide_len, char* out, int out_len, const char* def, int* used_def);
]];

local function desktop_dir()
    local ok, dir = pcall(function ()
        local shell32, ole32 = ffi.load('shell32'), ffi.load('ole32');
        -- FOLDERID_Desktop {B4BFCC3A-DB2C-424C-B029-7FE99A87C641}
        local id = ffi.new('vt_guid_t', { 0xB4BFCC3A, 0xDB2C, 0x424C, { 0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41 } });
        local wide = ffi.new('wchar_t*[1]');
        if shell32.SHGetKnownFolderPath(id, 0, nil, wide) ~= 0 then return nil; end
        local out = ffi.new('char[1024]');
        local n = ffi.C.WideCharToMultiByte(0, 0, wide[0], -1, out, 1024, nil, nil);   -- the ANSI code page, which is what MCI takes
        ole32.CoTaskMemFree(wide[0]);
        if n <= 1 then return nil; end
        return ffi.string(out);
    end);
    return ok and dir or nil;
end

-- ---------------------------------------------------------------------------
-- The game's own Music Volume (Main Menu > Config > Sound), setting 10 of the client's
-- configuration, read and written the way Ashita's bundled 'config' addon by atom0s does it:
-- the same two functions, found by the same two signatures.
-- ---------------------------------------------------------------------------
ffi.cdef[[
    typedef int32_t (__cdecl* vt_get_config_t)(int32_t);
    typedef int32_t (__cdecl* vt_set_config_t)(int32_t, int32_t);
]];
local GAME_MUSIC_VOLUME = 10;
local GAME_SFX_VOLUME   = 9;    -- Sound Effects, read off the client's saved settings by moving it in Config > Sound
local game = { get = nil, set = nil, ok = false };

local function find_game_config()
    local ok = pcall(function ()
        local get_ptr = ashita.memory.find(0, 0, '8B0D????????85C974??8B44240450E8????????C383C8FFC3', 0, 0);
        local set_ptr = ashita.memory.find(0, 0, '85C974??8B4424088B5424045052E8????????C383C8FFC3', -6, 0);
        if get_ptr == nil or get_ptr == 0 or set_ptr == nil or set_ptr == 0 then error('not found'); end
        game.get = ffi.cast('vt_get_config_t', get_ptr);
        game.set = ffi.cast('vt_set_config_t', set_ptr);
    end);
    game.ok = ok and game.get ~= nil and game.set ~= nil;
end

-- Whether the window in front is this game's: the addon runs inside the game's own process, so the
-- window in front is ours when it belongs to the process we are in.
ffi.cdef[[
    void*    GetForegroundWindow(void);
    uint32_t GetWindowThreadProcessId(void* hwnd, uint32_t* pid);
    uint32_t GetCurrentProcessId(void);
]];
local own_pid = nil;
local function window_in_front()
    local ok, yes = pcall(function ()
        local hwnd = ffi.C.GetForegroundWindow();
        if hwnd == nil then return false; end
        own_pid = own_pid or ffi.C.GetCurrentProcessId();
        local pid = ffi.new('uint32_t[1]');
        ffi.C.GetWindowThreadProcessId(hwnd, pid);
        return pid[0] == own_pid;
    end);
    return ok and yes;
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local EXTENSIONS = T{ mp3 = true, wav = true, wma = true, m4a = true };

local player = {
    tracks        = T{},        -- { name, path, on = T{ bool }, bad = false }
    albums        = T{},        -- { id, name, tracks = T{ indexes } }
    select_tab_on_draw = true,
    bag           = T{},        -- shuffle: indexes still to play this round
    current       = 0,
    alias         = nil,        -- the open MCI device's alias, nil when none is open
    state         = 'stopped',  -- 'playing' / 'paused' / 'stopped'
    length        = 0,          -- ms
    played_ms     = 0,          -- ms of the song heard up to the last pause
    since         = nil,        -- os.clock() when it last started sounding, nil while it is not
    next_poll     = 0,
    auto_started  = false,
    held_for_title = false,     -- paused because you left the game; carries on when you are back
    note          = '',
    pending       = T{},        -- work queued by commands, run on the render thread
    folder_shown  = T{ '' },
    -- a song change in steps, well apart in time, so the decoder is never torn down while it unwinds
    switch        = nil,        -- { step = 'stop'|'close'|'open', index = n (0: open nothing), at = os.clock() } or nil
    in_front      = nil,        -- whether this game's window was in front at the last look; nil = not looked yet
    ended         = false,      -- the device reported the song over; picked up next frame
};

local function say(msg)
    print(('\30\08[vanatunes]\30\01 %s'):format(msg));
end

local function logged_in()
    return AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() == 2;
end

-- The player's own songs: the folder typed in the window, else "Vanadreams Music" on the Desktop,
-- else (no Desktop to be found) config\vanatunes\music under the Ashita folder.
local default_dir = nil;
local function music_dir()
    local dir = cfg.folder[1];
    if dir == nil or #dir == 0 then
        if default_dir == nil then
            local desktop = desktop_dir();
            default_dir = desktop and (desktop:gsub('[\\/]+$', '') .. '\\Vanadreams Music\\')
                                   or ('%sconfig\\vanatunes\\music\\'):format(AshitaCore:GetInstallPath());
        end
        dir = default_dir;
    end
    if dir:sub(-1) ~= '\\' and dir:sub(-1) ~= '/' then dir = dir .. '\\'; end
    return dir;
end

-- the songs shipped with the addon
local function shipped_dir()
    return ('%s\\music\\'):format((addon.path:gsub('[\\/]+$', '')));
end

local function clock(ms)
    local s = math.floor((ms or 0) / 1000);
    return ('%d:%02d'):format(math.floor(s / 60), s % 60);
end

-- ---------------------------------------------------------------------------
-- the list
-- ---------------------------------------------------------------------------
local function save_skipped()
    local skipped = T{};
    for _, t in ipairs(player.tracks) do if not t.on[1] then skipped:append(t.id); end end
    cfg.skipped = skipped;
    settings.save();
end

-- Enumerate only immediate subfolders. The API used for song files does not distinguish a
-- folder from a file, so ask Windows for the directory attribute here.
ffi.cdef[[
    typedef struct {
        uint32_t attributes, created_low, created_high, accessed_low, accessed_high;
        uint32_t written_low, written_high, size_high, size_low, reserved0, reserved1;
        char name[260], alternate[14];
    } vt_find_data_t;
    void* __stdcall FindFirstFileA(const char* pattern, vt_find_data_t* data);
    int __stdcall FindNextFileA(void* handle, vt_find_data_t* data);
    int __stdcall FindClose(void* handle);
]];
local kernel32 = ffi.load('kernel32');
local function subfolders(dir)
    local result = T{};
    local data = ffi.new('vt_find_data_t');
    local handle = kernel32.FindFirstFileA(dir .. '*', data);
    if handle == ffi.cast('void*', -1) then return result; end
    repeat
        local name = ffi.string(data.name);
        if name ~= '.' and name ~= '..' and bit.band(data.attributes, 0x10) ~= 0 then
            result:append(name);
        end
    until kernel32.FindNextFileA(handle, data) == 0;
    kernel32.FindClose(handle);
    table.sort(result, function (a, b) return a:lower() < b:lower(); end);
    return result;
end

local function scan()
    local dir = music_dir();
    if not ashita.fs.exists(dir) then ashita.fs.create_directory(dir); end
    local playing_path = player.tracks[player.current] and player.tracks[player.current].path or nil;
    local switching_path = player.switch and player.tracks[player.switch.index]
                           and player.tracks[player.switch.index].path or nil;
    local skipped = {};
    for _, name in ipairs(cfg.skipped) do skipped[name] = true; end

    -- Root files remain valid playlists for existing installs. Each direct subfolder is an album.
    local found = T{};
    local albums = T{};
    local function add_album(id, label, path)
        if not ashita.fs.exists(path) then return; end
        local album = { id = id, name = label, tracks = T{} };
        for _, name in ipairs(ashita.fs.get_dir(path, '.*', false) or {}) do
                local ext = name:match('%.([^%.\\/]+)$');
                if ext and EXTENSIONS[ext:lower()] then
                    local track_id = id .. '/' .. name:lower();
                    found:append({ id = track_id, album = id, name = name, path = path .. name,
                                   on = T{ not skipped[track_id] and not skipped[name] }, bad = false });
                    album.tracks:append(#found);
                end
        end
        if #album.tracks > 0 then albums:append(album); end
    end
    local shipped = shipped_dir();
    add_album('shipped/root', 'VanaTunes Vol. 1', shipped);
    for _, name in ipairs(subfolders(shipped)) do
        add_album('shipped/' .. name:lower(), name, shipped .. name .. '\\');
    end
    add_album('mine/root', 'My Songs', dir);
    for _, name in ipairs(subfolders(dir)) do
        add_album('mine/' .. name:lower(), name .. ' (Mine)', dir .. name .. '\\');
    end
    -- Sorting the tracks within each album leaves album order predictable.
    for _, album in ipairs(albums) do
        table.sort(album.tracks, function (a, b) return found[a].name:lower() < found[b].name:lower(); end);
    end
    player.albums = albums;
    local selected = nil;
    for _, album in ipairs(albums) do
        if album.id == cfg.album then selected = album; break; end
    end
    if not selected then
        selected = albums[1];
        cfg.album = selected and selected.id or '';
        settings.save();
    end

    player.tracks = found;
    player.bag = T{};
    player.current = 0;
    for i, t in ipairs(found) do if t.path == playing_path then player.current = i; end end
    if player.switch and player.switch.index ~= 0 then
        player.switch.index = 0;
        for i, t in ipairs(found) do if t.path == switching_path then player.switch.index = i; break; end end
    end
    player.select_tab_on_draw = true;
    player.folder_shown[1] = dir;
    player.note = (#found == 0) and ('No songs yet. Put mp3 or wav files in ' .. dir)
               or (player.state == 'stopped' and 'Press My music to start the playlist.' or '');
end

local function playable(i)
    local t = player.tracks[i];
    return t ~= nil and t.album == cfg.album and t.on[1] and not t.bad;
end

-- Shuffle plays every ticked song once before any repeats, and never the same song twice in a row.
local function pick_next()
    local album = nil;
    for _, a in ipairs(player.albums) do if a.id == cfg.album then album = a; break; end end
    local indexes = album and album.tracks or T{};
    local n = #indexes;
    if n == 0 then return 0; end
    if cfg.shuffle[1] then
        if #player.bag == 0 then
            for _, i in ipairs(indexes) do if playable(i) and i ~= player.current then player.bag:append(i); end end
            if #player.bag == 0 and playable(player.current) then player.bag:append(player.current); end
        end
        while #player.bag > 0 do
            local i = table.remove(player.bag, math.random(#player.bag));
            if playable(i) then return i; end
        end
        return 0;
    end
    for step = 1, n do
        local current_slot = 0;
        for slot, index in ipairs(indexes) do if index == player.current then current_slot = slot; break; end end
        local i = indexes[((current_slot + step - 1) % n) + 1];
        if playable(i) then return i; end
    end
    return 0;
end

-- ---------------------------------------------------------------------------
-- playing
-- ---------------------------------------------------------------------------
local function device_stop()
    if player.alias then mci('stop ' .. player.alias); end
end

local function device_close()
    if player.alias then mci('close ' .. player.alias); end
    player.alias = nil;
    player.length = 0;
    player.played_ms, player.since = 0, nil;
end

-- Where the song is, by our own clock: the device is not asked, so it is left alone while it plays.
local function position_ms()
    local ms = player.played_ms;
    if player.since then ms = ms + (os.clock() - player.since) * 1000; end
    if player.length > 0 then ms = math.min(ms, player.length); end
    return ms;
end

local function clock_run()  if player.since == nil then player.since = os.clock(); end end
local function clock_hold() player.played_ms = position_ms(); player.since = nil; end

-- Opens a song on a brand-new alias. Only ever called with no device open (device_close first).
local function device_open(i)
    local t = player.tracks[i];
    if t == nil then return false; end
    alias_n = alias_n + 1;
    local alias = ('vanatunes%d'):format(alias_n);
    local ok, err = mci(('open "%s" type mpegvideo alias %s'):format(t.path, alias));
    if ok == nil then
        t.bad = true;
        say(('cannot play %s: %s'):format(t.name, err));
        return false;
    end
    player.alias = alias;
    player.current = i;
    mci(('set %s time format milliseconds'):format(alias));
    player.length = tonumber(mci(('status %s length'):format(alias))) or 0;
    mci(('setaudio %s volume to %d'):format(alias, math.max(0, math.min(100, cfg.volume[1])) * 10));
    mci('play ' .. alias);
    player.played_ms, player.since = 0, nil;
    clock_run();
    player.state = 'playing';
    player.note = '';
    player.ended = false;
    return true;
end

-- Stops now; run_switch closes the device later, once the decoder has had time to wind down.
local function stop_all(note)
    player.ended = false;
    if player.alias then
        if player.switch == nil or player.switch.step == 'stop' then
            device_stop();
            clock_hold();
            player.switch = { step = 'close', index = 0, at = os.clock() + STOP_TO_CLOSE };
        else
            player.switch.index = 0;   -- already winding down: keep its timing, open nothing after
        end
    else
        player.switch = nil;
    end
    player.state = 'stopped';
    player.held_for_title = false;
    if note then player.note = note; end
end

local function apply_volume()
    if player.alias and player.state ~= 'stopped' and not player.switch then
        mci(('setaudio %s volume to %d'):format(player.alias, math.max(0, math.min(100, cfg.volume[1])) * 10));
    end
end

-- Which song to play next, marking and passing over any that will not open.
local function choose_playable()
    for _ = 1, math.max(1, #player.tracks) do
        local i = pick_next();
        if i == 0 then return 0; end
        if playable(i) then return i; end
    end
    return 0;
end

-- Ask for a song. It starts over the next second or so: stop now, close a second later, open half
-- a second after that. Nothing is torn down inside the frame that asked, and never straight after a stop.
local function begin_switch(i)
    if i == 0 then
        stop_all((#player.tracks == 0) and ('No songs yet. Put mp3 or wav files in ' .. music_dir()) or 'Nothing ticked that will play.');
        return;
    end
    player.ended = false;
    player.note = '';
    -- a change already under way keeps its timing and just takes the new song
    if player.switch then player.switch.index = i; return; end
    player.switch = { step = player.alias and 'stop' or 'open', index = i, at = os.clock() };
end

local function next_track()
    begin_switch(choose_playable());
end

local function select_album(id)
    if cfg.album == id then return; end
    cfg.album = id;
    player.bag = T{};
    settings.save();
    if player.state == 'playing' or player.switch then next_track(); end
    if player.state == 'paused' then stop_all('Press Play to start this album.'); end
end

local function play_index(i)
    if playable(i) or (player.tracks[i] and not player.tracks[i].bad) then begin_switch(i); else next_track(); end
end

-- One step of a pending song change, taken only once its time has come. Called every frame from tick().
local function run_switch()
    local sw = player.switch;
    if sw == nil or os.clock() < sw.at then return; end
    if sw.step == 'stop' then
        device_stop();
        clock_hold();
        sw.step, sw.at = 'close', os.clock() + STOP_TO_CLOSE;
    elseif sw.step == 'close' then
        device_close();
        sw.step, sw.at = 'open', os.clock() + CLOSE_TO_OPEN;
    else
        player.switch = nil;
        if sw.index == 0 then return; end   -- it was a stop: nothing to open
        if not device_open(sw.index) then
            -- that one will not open: pick another, the same careful way
            local i = choose_playable();
            if i ~= 0 then player.switch = { step = 'open', index = i, at = os.clock() };
            else stop_all('Nothing ticked that will play.'); end
        end
    end
end

local function play_or_resume()
    if player.switch then
        -- stopped and still winding down: play once the old device is closed
        if player.switch.index == 0 then
            local i = choose_playable();
            if i ~= 0 then player.switch.index = i; player.note = ''; end
        end
        return;
    end
    if player.state == 'paused' and player.alias then
        mci('resume ' .. player.alias);
        clock_run();
        player.state = 'playing';
        player.held_for_title = false;
    elseif player.state ~= 'playing' then
        next_track();
    end
end

local function pause()
    if player.state == 'playing' and player.alias and not player.switch then
        mci('pause ' .. player.alias);
        clock_hold();
        player.state = 'paused';
    end
end

-- The game's Music and Sound Effects volumes. A volume is only ever turned down, and the player's own
-- number is kept in the settings file while it is, so a crash is put right the next time the addon
-- loads. want = nil gives the player's number back.
local function set_volume(id, before_key, want)
    if want ~= nil then
        if cfg[before_key] == -1 then
            cfg[before_key] = game.get(id);
            settings.save();
        end
        want = math.min(want, cfg[before_key]);
        if game.get(id) ~= want then game.set(id, want); end
    elseif cfg[before_key] ~= -1 then
        game.set(id, cfg[before_key]);
        cfg[before_key] = -1;
        settings.save();
    end
end

-- While a song of ours is sounding the game's Music Volume is turned down to cfg.game_music, and its
-- Sound Effects to 0 if the player asked for that; in a window that is not in front, with the
-- 'only the window I am in' box ticked, both go to 0. The moment none of that applies they go back.
local function sync_game_sound(ours_is_sounding, in_front)
    if not game.ok then return; end
    local hush = cfg.focus_only[1] and not in_front;
    set_volume(GAME_MUSIC_VOLUME, 'game_music_before',
               hush and 0 or (ours_is_sounding and math.max(0, math.min(100, cfg.game_music[1])) or nil));
    set_volume(GAME_SFX_VOLUME, 'sfx_before',
               (hush or (ours_is_sounding and cfg.sfx_mute[1])) and 0 or nil);
end

-- Riding a mount makes the server send one music packet (0x05F) for the mount slot (4) with the
-- chocobo or mount song. With "keep the zone music" ticked, the track number in that packet is
-- emptied as it arrives (or the packet dropped), so the zone music carries on. Nothing is sent
-- to the server.
local MUSIC_PACKET, SLOT_MOUNT = 0x05F, 4;

ashita.events.register('packet_in', 'vanatunes_mount', function (e)
    if not cfg.mount_keep[1] or e.id ~= MUSIC_PACKET or e.size < 8 then return; end
    if struct.unpack('H', e.data, 0x04 + 1) ~= SLOT_MOUNT then return; end
    if cfg.mount_drop[1] then
        e.blocked = true;
    else
        ffi.cast('uint16_t*', e.data_modified_raw + 0x06)[0] = 0;
    end
end);

local function tick()
    while #player.pending > 0 do table.remove(player.pending, 1)(); end

    -- A song change moves on only when its time has come, so stop, close and open are well apart.
    run_switch();

    -- The song the device said was over has stopped by itself: the change starts at the close,
    -- a second from now, not inside the poll that heard it.
    if player.ended and not player.switch then
        player.ended = false;
        local i = choose_playable();
        clock_hold();
        player.switch = { step = 'close', index = i, at = os.clock() + STOP_TO_CLOSE };
        if i == 0 then player.state = 'stopped'; player.note = 'Nothing ticked that will play.'; end
    end

    -- alt-tabbing is picked up on the very next frame, so the sound moves with you
    local front = window_in_front();
    if front ~= player.in_front then
        player.in_front = front;
        sync_game_sound(logged_in() and player.state == 'playing', front);
    end

    local t = os.clock();
    if t < player.next_poll then return; end
    player.next_poll = t + 0.5;

    local in_game = logged_in();
    sync_game_sound(in_game and player.state == 'playing', front);
    if in_game and cfg.autoplay[1] and not player.auto_started then
        player.auto_started = true;
        if player.state == 'stopped' and #player.tracks > 0 then next_track(); end
    end
    -- back at the title screen the game's own theme plays alone
    if not in_game and player.state == 'playing' then pause(); player.held_for_title = true; end
    if in_game and player.held_for_title and player.state == 'paused' then play_or_resume(); end

    -- The device is asked whether the song is over only in its last few seconds (or when its length
    -- is unknown), and never while a change is under way. The rest of the song it is left alone.
    if player.alias and player.state == 'playing' and not player.switch then
        if player.length <= 0 or position_ms() >= player.length - 3000 then
            if mci(('status %s mode'):format(player.alias)) == 'stopped' then player.ended = true; end
        end
    end
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------
ashita.events.register('command', 'vanatunes_cmd', function (e)
    local args = e.command:args();
    if #args == 0 or args[1] ~= '/vanatunes' then return; end
    e.blocked = true;
    local sub = (args[2] or ''):lower();
    if sub == 'play' then player.pending:append(play_or_resume);
    elseif sub == 'pause' then player.pending:append(pause);
    elseif sub == 'next' then player.pending:append(next_track);
    elseif sub == 'stop' then player.pending:append(function () stop_all(''); end);
    elseif sub == 'rescan' then player.pending:append(function () scan(); say(('%d song(s) in %d album(s)'):format(#player.tracks, #player.albums)); end);
    elseif sub == 'shuffle' then
        cfg.shuffle[1] = not cfg.shuffle[1]; player.bag = T{}; settings.save();
        say('shuffle ' .. (cfg.shuffle[1] and 'on' or 'off'));
    elseif sub == 'mount' then
        local on = (args[3] or ''):lower();
        if on == 'on' or on == 'off' then cfg.mount_keep[1] = (on == 'on'); settings.save(); end
        say('zone music while riding a mount: ' .. (cfg.mount_keep[1] and 'kept' or 'off') .. '. Takes effect the next time you mount.');
    elseif sub == 'volume' then
        local v = tonumber(args[3]);
        if v == nil then say('volume is ' .. cfg.volume[1]); return; end
        cfg.volume[1] = math.max(0, math.min(100, math.floor(v))); settings.save();
        player.pending:append(apply_volume);
    else
        cfg.window_open[1] = not cfg.window_open[1];
    end
end);

-- ---------------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------------
ashita.events.register('d3d_present', 'vanatunes_present', function ()
    tick();
    if not cfg.window_open[1] then return; end
    imgui.SetNextWindowSize({ 380, 0 }, ImGuiCond_FirstUseEver);
    if vd.Begin(('vanatunes %s###vanatunes'):format(addon.version), cfg.window_open) then
        local now_playing = player.tracks[player.current];

        -- Which music you are hearing, one press either way.
        local ours = player.state == 'playing';
        if imgui.RadioButton('My music', ours) and not ours then play_or_resume(); end
        imgui.SameLine();
        if imgui.RadioButton('Game music', not ours) and ours then pause(); end
        if not game.ok then
            imgui.TextDisabled("Could not reach the game's Music Volume: turn it down yourself in Config > Sound.");
        end
        imgui.Separator();

        if player.state == 'playing' then
            if vd.Button('Pause', { 80, 26 }, true) then pause(); end
        else
            if vd.Button('Play', { 80, 26 }, true) then play_or_resume(); end
        end
        imgui.SameLine();
        if vd.Button('Next', { 80, 26 }) then next_track(); end
        imgui.SameLine();
        if vd.Button('Stop', { 80, 26 }) then stop_all(''); end

        if now_playing and player.state ~= 'stopped' then
            vd.Eyebrow(now_playing.name);
            local at = position_ms();
            local fraction = player.length > 0 and math.min(1, at / player.length) or 0;
            imgui.ProgressBar(fraction, { -1, 14 }, ('%s / %s'):format(clock(at), clock(player.length)));
        else
            imgui.TextDisabled(player.state == 'stopped' and 'Stopped' or '');
        end
        if player.note ~= '' then imgui.TextDisabled(player.note); end

        imgui.Separator();
        local changed = false;
        if imgui.Checkbox('Shuffle', cfg.shuffle) then player.bag = T{}; changed = true; end
        imgui.SameLine();
        changed = imgui.Checkbox('Start when I am in game', cfg.autoplay) or changed;
        if imgui.SliderInt('Volume', cfg.volume, 0, 100) then apply_volume(); changed = true; end
        if game.ok then
            changed = imgui.SliderInt('Game music under mine', cfg.game_music, 0, 100) or changed;
        end
        if imgui.Checkbox('Silence the game\'s sound effects too', cfg.sfx_mute) then changed = true; end
        if imgui.Checkbox('Only the game window I am in makes sound', cfg.focus_only) then changed = true; end
        if cfg.focus_only[1] then imgui.TextDisabled('For several game windows: alt-tab and the sound comes with you.'); end
        if imgui.Checkbox('Keep the zone music while riding a mount', cfg.mount_keep) then changed = true; end
        if cfg.mount_keep[1] and imgui.Checkbox('Drop the mount music instead of emptying it', cfg.mount_drop) then changed = true; end
        if changed then settings.save(); end

        imgui.Separator();
        local album = nil;
        for _, a in ipairs(player.albums) do if a.id == cfg.album then album = a; break; end end
        imgui.Text(('%d album(s)'):format(#player.albums));
        imgui.SameLine();
        if vd.Button('Rescan') then scan(); end
        if imgui.BeginTabBar('vanatunes_albums', ImGuiTabBarFlags_None) then
            for _, a in ipairs(player.albums) do
                local flags = (player.select_tab_on_draw and a.id == cfg.album)
                              and ImGuiTabItemFlags_SetSelected or 0;
                if imgui.BeginTabItem(a.name .. '##' .. a.id, nil, flags) then
                    if not player.select_tab_on_draw then select_album(a.id); end
                    album = a;
                    imgui.EndTabItem();
                end
            end
            imgui.EndTabBar();
            player.select_tab_on_draw = false;
        end
        imgui.Text(('%d song(s) in this album'):format(album and #album.tracks or 0));
        imgui.BeginChild('vanatunes_songs', { 0, 200 }, ImGuiChildFlags_Borders);
        for _, i in ipairs(album and album.tracks or {}) do
            local t = player.tracks[i];
            if imgui.Checkbox('##on' .. i, t.on) then player.bag = T{}; save_skipped(); end
            imgui.SameLine();
            if vd.Selectable(t.name .. (t.bad and '  (will not play)' or '') .. '##song' .. i, i == player.current and player.state ~= 'stopped') then
                play_index(i);
            end
        end
        imgui.EndChild();

        if imgui.CollapsingHeader('Folder') then
            imgui.TextDisabled('Songs are read from:');
            imgui.TextWrapped(player.folder_shown[1]);
            if imgui.InputText('Another folder', cfg.folder, 260) then settings.save(); end
            imgui.TextDisabled('Leave it empty for the folder above, then Rescan.');
        end
    end
    vd.End();
end);

-- ---------------------------------------------------------------------------
-- load / unload
-- ---------------------------------------------------------------------------
ashita.events.register('load', 'vanatunes_load', function ()
    math.randomseed(os.time());
    find_game_config();
    sync_game_sound(false, true);   -- anything left turned down by a crash
    scan();
    say(('loaded, %d song(s). /vanatunes opens the window.'):format(#player.tracks));
end);

ashita.events.register('unload', 'vanatunes_unload', function ()
    -- the device has to go before we do; still, stop it first and give the decoder a moment
    if player.alias then
        if player.switch == nil or player.switch.step == 'stop' then device_stop(); end
        ffi.C.Sleep(300);
        device_close();
    end
    player.switch = nil;
    player.state = 'stopped';
    sync_game_sound(false, true);   -- the player's own Music and Sound Effects volumes back before we go
    settings.save();
end);
