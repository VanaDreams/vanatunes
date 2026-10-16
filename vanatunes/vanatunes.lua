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
      /vanatunes engine        which player plays the songs; 'engine mci' for the old one, 'engine auto' back
]]

addon.name    = 'vanatunes';
addon.author  = 'Vanadreams';
addon.version = '0.4.0';
addon.desc    = 'Your own playlist, shuffled, wherever you are.';
addon.link    = 'https://github.com/VanaDreams/vanatunes';

require('common');
local imgui    = require('imgui');
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
    game_music  = T{ 0 },        -- the game's own Music Volume while a song of ours plays, 0-100
    game_music_before = -1,      -- the player's Music Volume, kept while ours is turned down; -1 = not turned down
    engine      = T{ 'auto' },   -- 'auto': Media Foundation, else the old MCI player; 'mci': always the old one
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
-- The two players a song can be opened on. Both give back the same small device: stop, close,
-- pause, resume, volume, length() in ms (0 while not known yet) and over() once it has ended.
--
-- 'mf' (from 0.4.0, the default): Media Foundation's simple player (mfplay), the engine behind the
-- Windows Media Player app. It decodes with Windows' own MP3 decoder and feeds the sound card
-- from audio threads Windows runs at audio priority, so the game's busy frame loop cannot starve
-- it. Under MCI some players heard songs break up and distort a few seconds in while the same
-- file was clean in a media player. The files and the decoder were not at fault (the stock MP3
-- Decoder DMO on both PCs checked, no codec packs); MCI's DirectShow graph streams to its
-- DirectSound renderer on normal-priority threads inside the game, beside its busy frame loop.
-- It runs free-threaded (MFP_OPTION_FREE_THREADED_CALLBACK) with no callback, so it needs nothing
-- from the game's message loop.
--
-- 'mci': the DirectShow device everything used up to 0.3.3, kept only for PCs without Media
-- Foundation (Windows N editions) or when the player asks for it. Its DirectShow decoders are what
-- crashed the game on a song change (see above), so a song Media Foundation will not open is
-- skipped rather than tried on MCI.
-- ---------------------------------------------------------------------------
local function mci_open(path, vol)
    alias_n = alias_n + 1;
    local alias = ('vanatunes%d'):format(alias_n);
    local ok, err = mci(('open "%s" type mpegvideo alias %s'):format(path, alias));
    if ok == nil then return nil, err; end
    mci(('set %s time format milliseconds'):format(alias));
    local length = tonumber(mci(('status %s length'):format(alias))) or 0;
    mci(('setaudio %s volume to %d'):format(alias, vol * 10));
    mci('play ' .. alias);
    return {
        kind   = 'mci',
        stop   = function () mci('stop ' .. alias); end,
        close  = function () mci('close ' .. alias); end,
        pause  = function () mci('pause ' .. alias); end,
        resume = function () mci('resume ' .. alias); end,
        volume = function (v) mci(('setaudio %s volume to %d'):format(alias, v * 10)); end,
        length = function () return length; end,
        over   = function () return mci(('status %s mode'):format(alias)) == 'stopped'; end,
        failed = function () return false; end,
    };
end

ffi.cdef[[
    typedef struct { uint16_t vt; uint16_t r1, r2, r3; int64_t hVal; } vt_propvariant_t;
    typedef struct { void** vtbl; } vt_mfp_t;
    int32_t __stdcall MFStartup(uint32_t version, uint32_t flags);
    int32_t __stdcall MFShutdown(void);
    int32_t __stdcall MFPCreateMediaPlayer(const wchar_t* url, int32_t start, uint32_t options, void* callback, void* hwnd, vt_mfp_t** player);
    int32_t __stdcall CoInitializeEx(void* reserved, uint32_t coinit);
    void    __stdcall CoUninitialize(void);
    int     __stdcall MultiByteToWideChar(uint32_t codepage, uint32_t flags, const char* mb, int mb_len, wchar_t* wide, int wide_len);
    typedef int32_t (__stdcall* vt_mfp_call_t)(vt_mfp_t*);
    typedef int32_t (__stdcall* vt_mfp_time_t)(vt_mfp_t*, const vt_guid_t*, vt_propvariant_t*);
    typedef int32_t (__stdcall* vt_mfp_state_t)(vt_mfp_t*, int32_t*);
    typedef int32_t (__stdcall* vt_mfp_volume_t)(vt_mfp_t*, float);
]];

-- IMFPMediaPlayer methods, by their place in its vtable (mfplay.h)
local MFP = { Release = 2, Play = 3, Pause = 4, Stop = 5, GetPosition = 8, GetDuration = 9,
              GetState = 13, SetVolume = 20, Shutdown = 38 };
local MFP_STATE_STOPPED, MFP_STATE_SHUTDOWN = 1, 4;
local MFP_OPTION_FREE_THREADED_CALLBACK = 1;
local MF_VERSION = 0x00020070;
local POSITION_100NS = ffi.new('vt_guid_t');   -- MFP_POSITIONTYPE_100NS is GUID_NULL
local mf = { ok = false, lib = nil, plat = nil, com = false };

local function mf_start()
    local ok = pcall(function ()
        mf.lib  = ffi.load('mfplay');
        mf.plat = ffi.load('mfplat');
        local hr = ffi.load('ole32').CoInitializeEx(nil, 2);   -- COINIT_APARTMENTTHREADED; S_FALSE (1) = already so
        mf.com = (hr == 0 or hr == 1);
        if mf.plat.MFStartup(MF_VERSION, 0) < 0 then error('MFStartup'); end
    end);
    mf.ok = ok;
end

local function mf_stop()
    if not mf.ok then return; end
    pcall(function ()
        mf.plat.MFShutdown();
        if mf.com then ffi.load('ole32').CoUninitialize(); end
    end);
    mf.ok, mf.com = false, false;
end

local function mf_open(path, vol)
    if not mf.ok then return nil, 'Media Foundation is not available'; end
    local n = ffi.C.MultiByteToWideChar(0, 0, path, -1, nil, 0);   -- the ANSI code page, as the paths are
    if n <= 0 then return nil, 'bad path'; end
    local wide = ffi.new('wchar_t[?]', n);
    ffi.C.MultiByteToWideChar(0, 0, path, -1, wide, n);
    local out = ffi.new('vt_mfp_t*[1]');
    local hr = mf.lib.MFPCreateMediaPlayer(wide, 1, MFP_OPTION_FREE_THREADED_CALLBACK, nil, nil, out);
    if hr < 0 or out[0] == nil then return nil, 'Media Foundation error 0x' .. bit.tohex(hr); end
    local p = out[0];
    ffi.cast('vt_mfp_volume_t', p.vtbl[MFP.SetVolume])(p, vol / 100);   -- SetVolume, before any sound: opening runs in the background
    local function call(i, ct, ...) return ffi.cast(ct, p.vtbl[i])(p, ...); end
    local pv = ffi.new('vt_propvariant_t');
    local st = ffi.new('int32_t[1]');
    local length, opened = 0, os.clock();
    local last_pos, still = -1, 0;

    local function time_ms(i)
        pv.vt, pv.hVal = 0, 0;
        if call(i, 'vt_mfp_time_t', POSITION_100NS, pv) < 0 or (pv.vt ~= 20 and pv.vt ~= 21) then return nil; end   -- VT_I8 / VT_UI8
        return tonumber(pv.hVal) / 10000;
    end
    local dev = { kind = 'mf' };
    dev.stop   = function () call(MFP.Stop, 'vt_mfp_call_t'); end
    dev.close  = function ()
        if p == nil then return; end
        call(MFP.Shutdown, 'vt_mfp_call_t');
        call(MFP.Release, 'vt_mfp_call_t');
        p = nil;
    end
    dev.pause  = function () call(MFP.Pause, 'vt_mfp_call_t'); end
    dev.resume = function () call(MFP.Play, 'vt_mfp_call_t'); end
    dev.volume = function (v) call(MFP.SetVolume, 'vt_mfp_volume_t', v / 100); end
    dev.length = function ()
        if length <= 0 then length = math.floor(time_ms(MFP.GetDuration) or 0); end
        return length;
    end
    -- Over when the player says it has stopped by itself, or its position has stood still at the end.
    dev.over   = function ()
        if call(MFP.GetState, 'vt_mfp_state_t', st) >= 0 and (st[0] == MFP_STATE_STOPPED or st[0] == MFP_STATE_SHUTDOWN) then return true; end
        local pos = time_ms(MFP.GetPosition) or -1;
        still = (pos == last_pos) and (still + 1) or 0;
        last_pos = pos;
        return (length > 0 and pos >= length - 100) or still >= 4;
    end
    -- Opening is done in the background: a song that has not shown a length after five seconds never opened.
    dev.failed = function () return dev.length() <= 0 and os.clock() - opened > 5; end
    return dev;
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

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local EXTENSIONS = T{ mp3 = true, wav = true, wma = true, m4a = true };

local player = {
    tracks        = T{},        -- { name, path, on = T{ bool }, bad = false }
    bag           = T{},        -- shuffle: indexes still to play this round
    current       = 0,
    dev           = nil,        -- the open device (see mci_open / mf_open), nil when none is open
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
    for _, t in ipairs(player.tracks) do if not t.on[1] then skipped:append(t.name); end end
    cfg.skipped = skipped;
    settings.save();
end

local function scan()
    local dir = music_dir();
    if not ashita.fs.exists(dir) then ashita.fs.create_directory(dir); end
    local playing_path = player.tracks[player.current] and player.tracks[player.current].path or nil;
    local skipped = {};
    for _, name in ipairs(cfg.skipped) do skipped[name] = true; end

    -- The player's own folder first, then the songs that came with the addon (addons\vanatunes\music,
    -- which the launcher fills from the vanatunes repo). A name in both is listed once, the player's.
    local found = T{};
    local seen = {};
    for _, from in ipairs({ dir, shipped_dir() }) do
        if ashita.fs.exists(from) then
            for _, name in ipairs(ashita.fs.get_dir(from, '.*', false) or {}) do
                local ext = name:match('%.([^%.\\/]+)$');
                if ext and EXTENSIONS[ext:lower()] and not seen[name:lower()] then
                    seen[name:lower()] = true;
                    found:append({ name = name, path = from .. name, on = T{ not skipped[name] }, bad = false });
                end
            end
        end
    end
    table.sort(found, function (a, b) return a.name:lower() < b.name:lower(); end);

    player.tracks = found;
    player.bag = T{};
    player.current = 0;
    for i, t in ipairs(found) do if t.path == playing_path then player.current = i; end end
    player.folder_shown[1] = dir;
    player.note = (#found == 0) and ('No songs yet. Put mp3 or wav files in ' .. dir)
               or (player.state == 'stopped' and 'Press My music to start the playlist.' or '');
end

local function playable(i)
    local t = player.tracks[i];
    return t ~= nil and t.on[1] and not t.bad;
end

-- Shuffle plays every ticked song once before any repeats, and never the same song twice in a row.
local function pick_next()
    local n = #player.tracks;
    if n == 0 then return 0; end
    if cfg.shuffle[1] then
        if #player.bag == 0 then
            for i = 1, n do if playable(i) and i ~= player.current then player.bag:append(i); end end
            if #player.bag == 0 and playable(player.current) then player.bag:append(player.current); end
        end
        while #player.bag > 0 do
            local i = table.remove(player.bag, math.random(#player.bag));
            if playable(i) then return i; end
        end
        return 0;
    end
    for step = 1, n do
        local i = ((player.current - 1 + step) % n) + 1;
        if playable(i) then return i; end
    end
    return 0;
end

-- ---------------------------------------------------------------------------
-- playing
-- ---------------------------------------------------------------------------
local function device_stop()
    if player.dev then player.dev.stop(); end
end

local function device_close()
    if player.dev then player.dev.close(); end
    player.dev = nil;
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

local function volume_pct() return math.max(0, math.min(100, cfg.volume[1])); end

-- Opens a song on Media Foundation, or on MCI only when Media Foundation is missing or the player
-- asked for it (/vanatunes engine mci). A song Media Foundation will not open is skipped, never
-- handed to MCI: files DirectShow chokes on are what crashed the game on a song change.
-- Only ever called with no device open (device_close first).
local function device_open(i)
    local t = player.tracks[i];
    if t == nil then return false; end
    local dev, err;
    if cfg.engine[1] ~= 'mci' and mf.ok then
        dev, err = mf_open(t.path, volume_pct());
    else
        dev, err = mci_open(t.path, volume_pct());
    end
    if dev == nil then
        t.bad = true;
        say(('cannot play %s: %s'):format(t.name, err));
        return false;
    end
    player.dev = dev;
    player.current = i;
    player.length = dev.length();
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
    if player.dev then
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
    if player.dev and player.state ~= 'stopped' and not player.switch then
        player.dev.volume(volume_pct());
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
    player.switch = { step = player.dev and 'stop' or 'open', index = i, at = os.clock() };
end

local function next_track()
    begin_switch(choose_playable());
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
    if player.state == 'paused' and player.dev then
        player.dev.resume();
        clock_run();
        player.state = 'playing';
        player.held_for_title = false;
    elseif player.state ~= 'playing' then
        next_track();
    end
end

local function pause()
    if player.state == 'playing' and player.dev and not player.switch then
        player.dev.pause();
        clock_hold();
        player.state = 'paused';
    end
end

-- While a song of ours is sounding the game's Music Volume is turned down to cfg.game_music;
-- the moment ours is not sounding (paused, stopped, title screen, unloaded) it goes back to what
-- the player had. What they had is kept in the settings file, so a crash with the music turned
-- down is put right the next time the addon loads.
local function sync_game_music(ours_is_sounding)
    if not game.ok then return; end
    if ours_is_sounding then
        local want = math.max(0, math.min(100, cfg.game_music[1]));
        if cfg.game_music_before == -1 then
            cfg.game_music_before = game.get(GAME_MUSIC_VOLUME);
            settings.save();
        end
        want = math.min(want, cfg.game_music_before);   -- turned down, never up
        if game.get(GAME_MUSIC_VOLUME) ~= want then game.set(GAME_MUSIC_VOLUME, want); end
    elseif cfg.game_music_before ~= -1 then
        game.set(GAME_MUSIC_VOLUME, cfg.game_music_before);
        cfg.game_music_before = -1;
        settings.save();
    end
end

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

    local t = os.clock();
    if t < player.next_poll then return; end
    player.next_poll = t + 0.5;

    local in_game = logged_in();
    sync_game_music(in_game and player.state == 'playing');
    if in_game and cfg.autoplay[1] and not player.auto_started then
        player.auto_started = true;
        if player.state == 'stopped' and #player.tracks > 0 then next_track(); end
    end
    -- back at the title screen the game's own theme plays alone
    if not in_game and player.state == 'playing' then pause(); player.held_for_title = true; end
    if in_game and player.held_for_title and player.state == 'paused' then play_or_resume(); end

    -- The device is asked whether the song is over only in its last few seconds (or, on MCI, when its
    -- length is unknown), and never while a change is under way. The rest of the song it is left alone.
    -- Media Foundation opens in the background, so its length is picked up once it is known; a song it
    -- never opens is marked and skipped.
    local dev = player.dev;
    if dev and player.state == 'playing' and not player.switch then
        if dev.kind == 'mf' and player.length <= 0 then
            player.length = dev.length();
            if player.length <= 0 and dev.failed() then
                local t = player.tracks[player.current];
                if t then t.bad = true; end
                say(('cannot play %s: Windows could not open it; skipping it.'):format(t and t.name or 'that song'));
                next_track();
            end
        elseif player.length <= 0 or position_ms() >= player.length - 3000 then
            if dev.over() then player.ended = true; end
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
    elseif sub == 'engine' then
        local want = (args[3] or ''):lower();
        if want == 'mci' or want == 'auto' then
            cfg.engine[1] = want; settings.save();
            for _, t in ipairs(player.tracks) do t.bad = false; end
            say(('engine %s: from the next song.'):format(want));
        else
            say(('engine %s (Media Foundation %s); playing on %s'):format(cfg.engine[1], mf.ok and 'available' or 'not available',
                player.dev and player.dev.kind or 'nothing'));
        end
    elseif sub == 'rescan' then player.pending:append(function () scan(); say(('%d song(s) in %s'):format(#player.tracks, music_dir())); end);
    elseif sub == 'shuffle' then
        cfg.shuffle[1] = not cfg.shuffle[1]; player.bag = T{}; settings.save();
        say('shuffle ' .. (cfg.shuffle[1] and 'on' or 'off'));
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
    if imgui.Begin(('vanatunes %s###vanatunes'):format(addon.version), cfg.window_open) then
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
            if imgui.Button('Pause', { 80, 26 }) then pause(); end
        else
            if imgui.Button('Play', { 80, 26 }) then play_or_resume(); end
        end
        imgui.SameLine();
        if imgui.Button('Next', { 80, 26 }) then next_track(); end
        imgui.SameLine();
        if imgui.Button('Stop', { 80, 26 }) then stop_all(''); end

        if now_playing and player.state ~= 'stopped' then
            imgui.Text(now_playing.name);
            if player.dev and player.dev.kind == 'mci' then imgui.SameLine(); imgui.TextDisabled('(old player)'); end
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
        if changed then settings.save(); end

        imgui.Separator();
        imgui.Text(('%d song(s)'):format(#player.tracks));
        imgui.SameLine();
        if imgui.Button('Rescan') then scan(); end
        imgui.BeginChild('vanatunes_songs', { 0, 200 }, ImGuiChildFlags_Borders);
        for i, t in ipairs(player.tracks) do
            if imgui.Checkbox('##on' .. i, t.on) then player.bag = T{}; save_skipped(); end
            imgui.SameLine();
            if imgui.Selectable(t.name .. (t.bad and '  (will not play)' or '') .. '##song' .. i, i == player.current and player.state ~= 'stopped') then
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
    imgui.End();
end);

-- ---------------------------------------------------------------------------
-- load / unload
-- ---------------------------------------------------------------------------
ashita.events.register('load', 'vanatunes_load', function ()
    math.randomseed(os.time());
    find_game_config();
    mf_start();
    scan();
    say(('loaded, %d song(s). /vanatunes opens the window.'):format(#player.tracks));
end);

ashita.events.register('unload', 'vanatunes_unload', function ()
    -- the device has to go before we do; still, stop it first and give the decoder a moment
    if player.dev then
        if player.switch == nil or player.switch.step == 'stop' then device_stop(); end
        ffi.C.Sleep(300);
        device_close();
    end
    player.switch = nil;
    player.state = 'stopped';
    mf_stop();
    sync_game_music(false);   -- the player's own Music Volume back before we go
    settings.save();
end);
