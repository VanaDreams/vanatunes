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
]]

addon.name    = 'vanatunes';
addon.author  = 'Vanadreams';
addon.version = '0.3.0';
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
};

local cfg = settings.load(defaults);

-- ---------------------------------------------------------------------------
-- Windows audio (winmm MCI). One device, opened per song, always from the render thread.
-- ---------------------------------------------------------------------------
ffi.cdef[[
    uint32_t mciSendStringA(const char* command, char* result, uint32_t result_len, void* callback);
    int      mciGetErrorStringA(uint32_t err, char* text, uint32_t text_len);
]];
local winmm   = ffi.load('winmm');
local ALIAS   = 'vanatunes';
local mci_buf = ffi.new('char[512]');
local mci_err = ffi.new('char[256]');

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
    device_open   = false,
    state         = 'stopped',  -- 'playing' / 'paused' / 'stopped'
    length        = 0,          -- ms
    position      = 0,          -- ms
    next_poll     = 0,
    auto_started  = false,
    held_for_title = false,     -- paused because you left the game; carries on when you are back
    note          = '',
    pending       = T{},        -- work queued by commands, run on the render thread
    folder_shown  = T{ '' },
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
local function close_device()
    if player.device_open then mci('close ' .. ALIAS); end
    player.device_open = false;
    player.length, player.position = 0, 0;
end

local function stop_all(note)
    close_device();
    player.state = 'stopped';
    player.held_for_title = false;
    if note then player.note = note; end
end

local function apply_volume()
    if player.device_open then mci(('setaudio %s volume to %d'):format(ALIAS, math.max(0, math.min(100, cfg.volume[1])) * 10)); end
end

local function play_index(i)
    close_device();
    local t = player.tracks[i];
    if t == nil then stop_all(); return false; end
    local ok, err = mci(('open "%s" type mpegvideo alias %s'):format(t.path, ALIAS));
    if ok == nil then
        t.bad = true;
        say(('cannot play %s: %s'):format(t.name, err));
        return false;
    end
    player.device_open = true;
    player.current = i;
    mci(('set %s time format milliseconds'):format(ALIAS));
    player.length = tonumber(mci(('status %s length'):format(ALIAS))) or 0;
    apply_volume();
    mci('play ' .. ALIAS);
    player.state = 'playing';
    player.note = '';
    return true;
end

local function next_track()
    -- a song that will not open is marked and passed over; give up when none are left
    for _ = 1, math.max(1, #player.tracks) do
        local i = pick_next();
        if i == 0 then break; end
        if play_index(i) then return; end
    end
    stop_all((#player.tracks == 0) and ('No songs yet. Put mp3 or wav files in ' .. music_dir()) or 'Nothing ticked that will play.');
end

local function play_or_resume()
    if player.state == 'paused' and player.device_open then
        mci('resume ' .. ALIAS);
        player.state = 'playing';
        player.held_for_title = false;
    elseif player.state ~= 'playing' then
        next_track();
    end
end

local function pause()
    if player.state == 'playing' and player.device_open then
        mci('pause ' .. ALIAS);
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

    local t = os.clock();
    if t < player.next_poll then return; end
    player.next_poll = t + 0.25;

    local in_game = logged_in();
    sync_game_music(in_game and player.state == 'playing');
    if in_game and cfg.autoplay[1] and not player.auto_started then
        player.auto_started = true;
        if player.state == 'stopped' and #player.tracks > 0 then next_track(); end
    end
    -- back at the title screen the game's own theme plays alone
    if not in_game and player.state == 'playing' then pause(); player.held_for_title = true; end
    if in_game and player.held_for_title and player.state == 'paused' then play_or_resume(); end

    if player.device_open and player.state == 'playing' then
        player.position = tonumber(mci(('status %s position'):format(ALIAS))) or player.position;
        if mci(('status %s mode'):format(ALIAS)) == 'stopped' then next_track(); end
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
    if imgui.Begin('Vanadreams music', cfg.window_open) then
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
            local fraction = player.length > 0 and math.min(1, player.position / player.length) or 0;
            imgui.ProgressBar(fraction, { -1, 14 }, ('%s / %s'):format(clock(player.position), clock(player.length)));
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
                if not play_index(i) then next_track(); end
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
    scan();
    say(('loaded, %d song(s). /vanatunes opens the window.'):format(#player.tracks));
end);

ashita.events.register('unload', 'vanatunes_unload', function ()
    close_device();
    player.state = 'stopped';
    sync_game_music(false);   -- the player's own Music Volume back before we go
    settings.save();
end);
