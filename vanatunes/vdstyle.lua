--[[
    vdstyle: the Vanadreams look for every addon window.

    The same colours as the launcher (launcher/VanadreamsLauncher/Theme.xaml): a plum-to-night box,
    a gold rim with a dark inner line, gold buttons for the main action, dark ghost buttons for the
    rest, a gold pointer on the picked row and a small moon in the title bar.

    This file lives in addons/_shared/ and a copy sits in every Vanadreams addon folder, because the
    launcher installs each addon folder on its own. Change it here, then run
    scripts/sync-vdstyle.py so every copy (and vanatunes / grampsshop) matches.

    Use:
        local vd = require('vdstyle');
        if vd.Begin('vanagear', isOpen, flags) then
            if vd.Button('New set', nil, true) then ... end   -- true = the gold main button
            if vd.Selectable(name, picked) then ... end       -- the gold pointer on the picked row
            vd.Eyebrow('IDLE');
        end
        vd.End();

    vd.Begin / vd.End wrap imgui.Begin / imgui.End and must be paired the same way (End always runs,
    whatever Begin returned). Everything this file pushes, it pops, so other addons keep their look.
]]

require('common');
local imgui = require('imgui');

local vd = { VERSION = '1.0.0' };

-- Vanadreams tokens (0..1 rgb), the launcher's Theme.xaml values
local function hex(h, a)
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, a or 1.0 };
end
local function alpha(c, a) return { c[1], c[2], c[3], a }; end

local C = {
    night    = hex('0F0A17'),
    plum     = hex('231938'),
    velvet   = hex('33224A'),
    boxtop   = hex('3A2757'),
    boxmid   = hex('1E1531'),
    gold     = hex('D6A74C'),
    goldsoft = hex('F1CD78'),
    goldhi   = hex('FFDF94'),
    brass    = hex('9C6428'),
    cream    = hex('FFF3D2'),
    ink      = hex('2A1C0A'),
    ok       = hex('8EC29C'),
    warn     = hex('F2C94F'),
    bad      = hex('E07A6A'),
    black    = { 0, 0, 0, 1 },
};
vd.colors = C;
vd.Ok, vd.Warn, vd.Bad, vd.Gold = C.ok, C.warn, C.bad, C.goldsoft;

local function col(name) return rawget(_G, name); end

-- Every colour the box sets. A name this Ashita's ImGui lacks is skipped, so an older or newer
-- ImGui never breaks a window.
local function palette(bgAlpha)
    return {
        { 'ImGuiCol_Text',                 C.cream },
        { 'ImGuiCol_TextDisabled',         alpha(C.cream, 0.62) },
        { 'ImGuiCol_WindowBg',             alpha(C.night, bgAlpha) },
        { 'ImGuiCol_ChildBg',              alpha(C.black, 0.26) },
        { 'ImGuiCol_PopupBg',              alpha(C.boxmid, 0.98) },
        { 'ImGuiCol_Border',               alpha(C.goldsoft, 0.24) },
        { 'ImGuiCol_BorderShadow',         alpha(C.black, 0.0) },
        { 'ImGuiCol_FrameBg',              alpha(C.black, 0.42) },
        { 'ImGuiCol_FrameBgHovered',       alpha(C.velvet, 0.85) },
        { 'ImGuiCol_FrameBgActive',        alpha(C.velvet, 1.0) },
        { 'ImGuiCol_TitleBg',              alpha(C.plum, bgAlpha) },
        { 'ImGuiCol_TitleBgActive',        alpha(C.boxtop, math.max(bgAlpha, 0.9)) },
        { 'ImGuiCol_TitleBgCollapsed',     alpha(C.plum, 0.85) },
        { 'ImGuiCol_MenuBarBg',            alpha(C.plum, 1.0) },
        { 'ImGuiCol_ScrollbarBg',          alpha(C.black, 0.30) },
        { 'ImGuiCol_ScrollbarGrab',        alpha(C.gold, 0.60) },
        { 'ImGuiCol_ScrollbarGrabHovered', alpha(C.gold, 0.80) },
        { 'ImGuiCol_ScrollbarGrabActive',  alpha(C.goldsoft, 0.95) },
        { 'ImGuiCol_CheckMark',            C.goldsoft },
        { 'ImGuiCol_SliderGrab',           C.gold },
        { 'ImGuiCol_SliderGrabActive',     C.goldsoft },
        { 'ImGuiCol_Button',               alpha(C.black, 0.38) },
        { 'ImGuiCol_ButtonHovered',        alpha(C.velvet, 0.95) },
        { 'ImGuiCol_ButtonActive',         alpha(C.gold, 0.55) },
        { 'ImGuiCol_Header',               alpha(C.goldsoft, 0.18) },
        { 'ImGuiCol_HeaderHovered',        alpha(C.goldsoft, 0.26) },
        { 'ImGuiCol_HeaderActive',         alpha(C.goldsoft, 0.36) },
        { 'ImGuiCol_Separator',            alpha(C.goldsoft, 0.34) },
        { 'ImGuiCol_SeparatorHovered',     alpha(C.goldsoft, 0.70) },
        { 'ImGuiCol_SeparatorActive',      C.goldsoft },
        { 'ImGuiCol_ResizeGrip',           alpha(C.gold, 0.22) },
        { 'ImGuiCol_ResizeGripHovered',    alpha(C.gold, 0.55) },
        { 'ImGuiCol_ResizeGripActive',     alpha(C.goldsoft, 0.85) },
        { 'ImGuiCol_Tab',                  alpha(C.velvet, 0.85) },
        { 'ImGuiCol_TabHovered',           alpha(C.gold, 0.45) },
        { 'ImGuiCol_TabSelected',          alpha(C.boxtop, 1.0) },
        { 'ImGuiCol_TabActive',            alpha(C.boxtop, 1.0) },
        { 'ImGuiCol_PlotHistogram',        C.gold },
        { 'ImGuiCol_PlotHistogramHovered', C.goldsoft },
        { 'ImGuiCol_TableHeaderBg',        alpha(C.velvet, 0.90) },
        { 'ImGuiCol_TableBorderStrong',    alpha(C.goldsoft, 0.30) },
        { 'ImGuiCol_TableBorderLight',     alpha(C.goldsoft, 0.16) },
        { 'ImGuiCol_TableRowBgAlt',        alpha(C.black, 0.16) },
        { 'ImGuiCol_TextSelectedBg',       alpha(C.gold, 0.35) },
        { 'ImGuiCol_DragDropTarget',       C.goldsoft },
    };
end

-- Shapes. Paddings and spacing stay ImGui's, so every window keeps its size and layout.
local SHAPES = {
    { 'ImGuiStyleVar_WindowRounding',    6.0 },
    { 'ImGuiStyleVar_ChildRounding',     4.0 },
    { 'ImGuiStyleVar_FrameRounding',     4.0 },
    { 'ImGuiStyleVar_PopupRounding',     4.0 },
    { 'ImGuiStyleVar_ScrollbarRounding', 3.0 },
    { 'ImGuiStyleVar_GrabRounding',      3.0 },
    { 'ImGuiStyleVar_WindowBorderSize',  0.0 },  -- the gold rim is drawn by hand, see paint()
    { 'ImGuiStyleVar_ChildBorderSize',   1.0 },
    { 'ImGuiStyleVar_FrameBorderSize',   1.0 },
    { 'ImGuiStyleVar_PopupBorderSize',   1.0 },
    { 'ImGuiStyleVar_ScrollbarSize',     10.0 },
};

local RIM = 2.0;   -- gold rim width, px

-- One frame's pushes, so End pops exactly what Begin pushed even when windows nest.
local stack = {};

local function push(bgAlpha)
    local nc, nv = 0, 0;
    for _, p in ipairs(palette(bgAlpha)) do
        local id = col(p[1]);
        if id ~= nil then imgui.PushStyleColor(id, p[2]); nc = nc + 1; end
    end
    for _, s in ipairs(SHAPES) do
        local id = col(s[1]);
        if id ~= nil then imgui.PushStyleVar(id, s[2]); nv = nv + 1; end
    end
    stack[#stack + 1] = { nc, nv };
end

local function pop()
    local top = table.remove(stack);
    if top == nil then return; end
    if top[2] > 0 then imgui.PopStyleVar(top[2]); end
    if top[1] > 0 then imgui.PopStyleColor(top[1]); end
end

local function u32(c) return imgui.GetColorU32(c); end

-- The box: a plum glow fading into the night under the title bar, a gold rim with a dark inner line,
-- and the moon in the title bar. Drawn right after Begin, so the window's widgets draw over it.
-- Any trouble here (an ImGui without one of these calls) only loses the decoration, never the window.
local function paint(flags, hasClose, bgAlpha)
    local dl = imgui.GetWindowDrawList();
    local x, y = imgui.GetWindowPos();
    local w, h = imgui.GetWindowSize();
    if w == nil or h == nil or w < 8 or h < 8 then return; end
    local noTitle = bit.band(flags or 0, ImGuiWindowFlags_NoTitleBar or 0) ~= 0;
    local titleH = noTitle and 0 or imgui.GetFrameHeight();

    dl:PushClipRect({ x, y }, { x + w, y + h }, false);

    -- the glow: drawn below the title bar and left of a scroll bar, so neither gets painted over
    local top = y + titleH;
    local right = x + w - RIM;
    local okScroll, maxY = pcall(imgui.GetScrollMaxY);
    if okScroll and (maxY or 0) > 0 then right = right - imgui.GetStyle().ScrollbarSize; end
    local glowH = math.min(h - titleH - RIM, 220);
    if glowH > 4 and right > x + RIM then
        local a = 0.55 * bgAlpha;
        local glow, clear = u32(alpha(C.boxtop, a)), u32(alpha(C.boxtop, 0.0));
        dl:AddRectFilledMultiColor({ x + RIM, top }, { right, top + glowH }, glow, glow, clear, clear);
    end

    -- a gold line under the title bar
    if not noTitle then
        dl:AddLine({ x + RIM, top - 0.5 }, { x + w - RIM, top - 0.5 }, u32(alpha(C.goldsoft, 0.45)), 1.0);
    end

    -- the rim: dark outside line, gold band, dark inner line (the launcher's bevelled box)
    dl:AddRect({ x, y }, { x + w, y + h }, u32(alpha(C.black, 0.75)), 6.0, 0, 1.0);
    dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, u32(C.gold), 6.0, 0, RIM);
    dl:AddRect({ x + RIM + 1, y + RIM + 1 }, { x + w - RIM - 1, y + h - RIM - 1 }, u32(alpha(C.black, 0.55)), 4.0, 0, 1.0);

    -- the moon, at the right of the title bar, left of the close button
    if not noTitle then
        local fs = imgui.GetFontSize();
        local r = math.floor(fs * 0.30);
        local pad = imgui.GetStyle().FramePadding.x or 4;
        local cx = x + w - pad - r - 3 - (hasClose and (fs + pad * 2) or 0);
        local cy = y + titleH * 0.5;
        dl:AddCircleFilled({ cx, cy }, r + 2, u32(alpha(C.goldsoft, 0.18)), 16);
        dl:AddCircleFilled({ cx, cy }, r, u32(hex('E9C77C')), 16);
        dl:AddCircleFilled({ cx - r * 0.3, cy - r * 0.3 }, r * 0.45, u32(hex('FFF2C8')), 12);
    end

    dl:PopClipRect();
end

-- ---------------------------------------------------------------------------
-- See-through or solid: every window with a title bar has the switch at the top, beside the moon.
-- The choice is kept per window in config\addons\<addon>\vdstyle.txt, so it survives a reload
-- and an addon update.
-- ---------------------------------------------------------------------------
local SEE_ALPHA, SOLID_ALPHA = 0.55, 0.96;
local looks = nil;   -- window id -> true when see-through

local function looksFile()
    local name = (addon and addon.name) or 'vanadreams';
    local dir = ('%sconfig\\addons\\%s\\'):format(AshitaCore:GetInstallPath(), name);
    return dir, dir .. 'vdstyle.txt';
end

local function loadLooks()
    looks = {};
    pcall(function ()
        local _, path = looksFile();
        local f = io.open(path, 'r');
        if f == nil then return; end
        for line in f:lines() do
            local id, v = line:match('^(.-)=(%a+)%s*$');
            if id ~= nil then looks[id] = (v == 'see'); end
        end
        f:close();
    end);
end

local function saveLooks()
    pcall(function ()
        local dir, path = looksFile();
        if not ashita.fs.exists(dir) then ashita.fs.create_directory(dir); end
        local f = io.open(path, 'w');
        if f == nil then return; end
        for id, see in pairs(looks) do f:write(('%s=%s\n'):format(id, see and 'see' or 'solid')); end
        f:close();
    end);
end

-- ImGui's own rule: "Name##x" and "Name" differ, "Shown###id" is known by "###id".
local function windowId(title)
    local id = title:match('(###.*)$');
    return id or title;
end

function vd.IsSeeThrough(title, default)
    if looks == nil then loadLooks(); end
    local v = looks[windowId(title)];
    if v == nil then return default == true; end
    return v;
end

function vd.SetSeeThrough(title, see)
    if looks == nil then loadLooks(); end
    looks[windowId(title)] = see and true or false;
    saveLooks();
end

-- The switch: a small pill in the title bar, left of the moon. Drawn inside the title bar's clip
-- rect, then the cursor goes back where the window's content starts.
local function seeSwitch(title, hasClose, see)
    local x, y = imgui.GetWindowPos();
    local w = imgui.GetWindowSize();
    local titleH = imgui.GetFrameHeight();
    local fs = imgui.GetFontSize();
    local pad = imgui.GetStyle().FramePadding.x or 4;
    local label = see and 'solid' or 'see-through';
    local tw = imgui.CalcTextSize(label);
    local bw = tw + pad * 2;
    local moonLeft = x + w - pad - fs * 0.6 - 5 - (hasClose and (fs + pad * 2) or 0);
    local bx = moonLeft - 6 - bw;
    if bx < x + w * 0.45 then return; end     -- too narrow: the title keeps the room
    local by = y + (titleH - fs) * 0.5;

    local cx, cy = imgui.GetCursorScreenPos();
    imgui.PushClipRect({ x, y }, { x + w, y + titleH }, false);
    imgui.SetCursorScreenPos({ bx, by });
    imgui.PushStyleColor(ImGuiCol_Button, alpha(C.black, 0.35));
    imgui.PushStyleColor(ImGuiCol_Text, alpha(C.cream, 0.85));
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 12.0);
    local clicked = imgui.SmallButton(label .. '##vdstyle_see');
    imgui.PopStyleVar(1);
    imgui.PopStyleColor(2);
    if imgui.IsItemHovered() then
        imgui.SetTooltip(see and 'Make this window solid' or 'Let the game show through this window');
    end
    imgui.PopClipRect();
    imgui.SetCursorScreenPos({ cx, cy });
    if clicked then vd.SetSeeThrough(title, not see); end
end

--[[
    vd.Begin(title, open, flags, opts) -> same as imgui.Begin.
    opts.seeThrough: what a window starts as before the player picks (default solid).
    opts.alpha: a fixed background opacity, 0..1, instead of the switch.
]]
function vd.Begin(title, open, flags, opts)
    local noTitle = bit.band(flags or 0, ImGuiWindowFlags_NoTitleBar or 0) ~= 0;
    local fixed = opts and opts.alpha;
    local see = (not fixed) and (not noTitle) and vd.IsSeeThrough(title, opts and opts.seeThrough);
    local bgAlpha = fixed or (see and SEE_ALPHA or SOLID_ALPHA);
    push(bgAlpha);
    local shown;
    if flags ~= nil then
        shown = imgui.Begin(title, open, flags);
    else
        shown = imgui.Begin(title, open);
    end
    if shown then
        pcall(paint, flags, open ~= nil, bgAlpha);
        if (not fixed) and (not noTitle) then pcall(seeSwitch, title, open ~= nil, see); end
    end
    return shown;
end

function vd.End()
    imgui.End();
    pop();
end

-- For a window an addon has to draw itself between its own Begin/End (rare): push before Begin,
-- vd.Pop() after End.
function vd.Push(opts) push((opts and opts.alpha) or 0.96); end
vd.Pop = pop;

--[[
    vd.Button(label, size, primary) -> clicked.
    primary = true: the gold pill with dark words, for a window's main action (Play, New set, Repeat, Bid).
    Otherwise the dark ghost pill with a gold line, for everything else.
]]
function vd.Button(label, size, primary)
    local nc = 0;
    if primary then
        imgui.PushStyleColor(ImGuiCol_Button, C.gold);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, C.goldsoft);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, C.goldhi);
        imgui.PushStyleColor(ImGuiCol_Text, C.ink);
        imgui.PushStyleColor(ImGuiCol_Border, alpha(C.brass, 0.9));
        nc = 5;
    end
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 12.0);
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 12, 3 });
    local clicked;
    if size ~= nil then clicked = imgui.Button(label, size); else clicked = imgui.Button(label); end
    imgui.PopStyleVar(2);
    if nc > 0 then imgui.PopStyleColor(nc); end
    return clicked;
end

-- The small button (a header's "solid / see-through" toggle).
function vd.SmallButton(label)
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 12.0);
    local clicked = imgui.SmallButton(label);
    imgui.PopStyleVar(1);
    return clicked;
end

--[[
    vd.Selectable(label, selected, flags, size) -> clicked.
    A list row with the gold pointer (the launcher's hand) on the picked row, and a faint one on hover.
]]
local POINTER = 12;
function vd.Selectable(label, selected, flags, size)
    local x, y = imgui.GetCursorScreenPos();
    local h = imgui.GetTextLineHeight();
    imgui.SetCursorPosX(imgui.GetCursorPosX() + POINTER);
    local clicked;
    if size ~= nil then
        clicked = imgui.Selectable(label, selected, flags or 0, size);
    elseif flags ~= nil then
        clicked = imgui.Selectable(label, selected, flags);
    else
        clicked = imgui.Selectable(label, selected);
    end
    local hovered = imgui.IsItemHovered();
    if selected or hovered then
        pcall(function ()
            local dl = imgui.GetWindowDrawList();
            local c = selected and C.goldsoft or alpha(C.goldsoft, 0.45);
            local my = y + h * 0.5;
            dl:AddTriangleFilled({ x + 2, my - h * 0.32 }, { x + 2, my + h * 0.32 }, { x + POINTER - 3, my }, u32(c));
        end);
    end
    return clicked;
end

-- A small gold heading, the launcher's eyebrow.
function vd.Eyebrow(text) imgui.TextColored(C.goldsoft, text); end

-- Quiet text (the launcher's Mist).
function vd.Muted(text) imgui.TextDisabled(text); end

-- A coloured status word: vd.Status('HQ1', vd.Ok).
function vd.Status(text, c) imgui.TextColored(c or C.cream, text); end

return vd;
