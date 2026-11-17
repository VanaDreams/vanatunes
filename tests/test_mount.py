"""Regression: full addon in LuaJIT with Windows/Ashita services mocked.
Run: python -m pip install lupa; python tests/test_mount.py
Requires a C compiler for a real Lua lightuserdata packet fixture.
Does not run a game client or decode audio.
"""
from pathlib import Path
import ctypes
import subprocess
import tempfile
import lupa.luajit21 as lj

ROOT = Path(__file__).resolve().parents[1]
# Make the embedded Lua API visible to our tiny lightuserdata fixture.
ctypes.CDLL(lj.__file__, mode=ctypes.RTLD_GLOBAL)
C = '''typedef struct lua_State lua_State;
extern void lua_pushlightuserdata(lua_State*, void*);
static unsigned char packet[32];
int luaopen_packet_fixture(lua_State* L) {
 lua_pushlightuserdata(L, packet); return 1;
}
'''
PRELUDE = r'''
local realffi = require('ffi')
local commands = {}
local fakeffi = setmetatable({}, {__index=realffi})
fakeffi.C = {
 GetForegroundWindow=function() return realffi.cast('void*', 1) end,
 GetCurrentProcessId=function() return 7 end,
 GetWindowThreadProcessId=function(_, pid) pid[0]=7 end,
 Sleep=function() end,
}
fakeffi.load=function(name)
 if name == 'winmm' then return {
  mciSendStringA=function(command, out)
   commands[#commands+1]=command
   local result = command:match(' length$') and '600000' or
                  command:match(' mode$') and 'playing' or ''
   realffi.copy(out, result .. '\0'); return 0
  end,
  mciGetErrorStringA=function() return 0 end,
 } end
 return {}
end
package.loaded.ffi=fakeffi
function T(t) return setmetatable(t, {__index={append=function(self,v) self[#self+1]=v end}}) end
package.preload.common=function() return true end
package.preload.imgui=function() return {} end
package.preload.vdstyle=function() return {} end
package.preload.settings=function() return {load=function(d) return d end, save=function() end} end
addon={path='test'}
local callbacks={}
ashita={events={register=function(_,name,fn) callbacks[name]=fn end}}
AshitaCore={GetMemoryManager=function() return {GetPlayer=function() return {GetLoginStatus=function() return 2 end} end} end}
struct={unpack=function(fmt,s,at) assert(fmt=='H'); return s:byte(at)+256*s:byte(at+1) end}
return {commands=commands, callbacks=callbacks, ffi=realffi}
'''
EXPOSE = '''\nreturn {player=player, cfg=cfg, game=game, play=play_or_resume, tick=tick, pause=pause, next=next_track}\n'''
TEST = r'''
local a, h, raw = ...
local ffi=h.ffi
assert(type(raw)=='userdata', 'fixture must be real lightuserdata')
local bytes=ffi.cast('uint8_t*',raw)
local function event(slot,size,id)
 for i=0,31 do bytes[i]=0xA5 end
 bytes[4]=slot; bytes[5]=0; bytes[6]=0x34; bytes[7]=0x12
 return {id=id or 0x5F,size=size or 8,data=ffi.string(bytes,32),data_modified_raw=raw,blocked=false}
end
local callback=h.callbacks.vanatunes_mount
local p,c=a.player,a.cfg
local volumes={[10]=70,[9]=80}
a.game.ok=true
a.game.get=function(id) return volumes[id] end
a.game.set=function(id,v) volumes[id]=v end
p.tracks=T{{name='Selected song.mp3',path='Selected song.mp3',album='test',on=T{true}}}
p.albums=T{{id='test',tracks=T{1}}};c.album='test'
a.play();a.tick()
assert(p.state=='playing' and p.current==1 and p.alias~=nil)
assert(p.length==600000, 'mock track length must parse as milliseconds')
assert(volumes[10]==0 and volumes[9]==80, 'custom playback must duck game music only')
local alias=p.alias; local count=#h.commands
local function same_song()
 assert(p.state=='playing' and p.current==1 and p.alias==alias and p.switch==nil)
 assert(#h.commands==count,'mount invoked audio engine')
 assert(volumes[10]==0 and volumes[9]==80, 'mount changed game-volume ducking')
end
local e=event(4);callback(e)
assert(not e.blocked and bytes[6]==0 and bytes[7]==0)
for i=0,31 do if i~=6 and i~=7 then assert(bytes[i]==e.data:byte(i+1),'changed unrelated byte') end end
same_song(); a.tick(); same_song()
-- Repeated mounts leave the selected song/device running.
for i=1,100 do callback(event(4));same_song() end
-- All short packet boundaries and non-mount slots leave bytes untouched.
for n=0,7 do e=event(4,n);callback(e);assert(ffi.string(bytes,32)==e.data);same_song() end
for _,slot in ipairs({0,1,2,3,5,255}) do e=event(slot);callback(e);assert(ffi.string(bytes,32)==e.data);same_song() end
e=event(4,8,0x0D);callback(e);assert(ffi.string(bytes,32)==e.data);same_song()
c.mount_keep[1]=false;e=event(4);callback(e);assert(not e.blocked and ffi.string(bytes,32)==e.data);same_song()
c.mount_keep[1]=true;c.mount_drop[1]=true;e=event(4);callback(e);assert(e.blocked and ffi.string(bytes,32)==e.data);same_song()
c.mount_drop[1]=false
-- Paused/stopped selections must not be started by mounting, either.
a.pause();assert(p.state=='paused');count=#h.commands
callback(event(4));assert(p.state=='paused' and p.alias==alias and #h.commands==count)
a.play();assert(p.state=='playing' and p.alias==alias)
assert(h.commands[#h.commands]=='resume '..alias)
p.state='stopped';count=#h.commands;callback(event(4));assert(p.state=='stopped' and #h.commands==count)
return 'PASS: actual full-addon callback, real lightuserdata, selected-song/device continuity, repeat mounts, packet boundaries, settings, pause/resume'
'''
with tempfile.TemporaryDirectory() as tmp:
    c=Path(tmp)/'fixture.c'; so=Path(tmp)/'fixture.so'; c.write_text(C)
    subprocess.run(['cc','-shared','-fPIC',str(c),'-o',str(so)],check=True)
    source=(ROOT/'vanatunes/vanatunes.lua').read_text()
    def run(src):
        lua=lj.LuaRuntime(unpack_returned_tuples=True)
        helpers=lua.execute(PRELUDE)
        raw=lua.eval('function(p) return assert(package.loadlib(p,"luaopen_packet_fixture"))() end')(str(so))
        addon=lua.execute(src+EXPOSE)
        return lua.execute(TEST,addon,helpers,raw)
    print(run(source))
    # Prove this test detects the original bug, rather than merely exercising a mock.
    fixed="""        -- Ashita exposes the raw buffer as userdata: cast before accessing its bytes.
        local packet = ffi.cast('uint8_t*', e.data_modified_raw);
        packet[0x06] = 0;
        packet[0x07] = 0;"""
    assert fixed in source
    old=source.replace(fixed,"        ffi.cast('uint16_t*', e.data_modified_raw + 0x06)[0] = 0;")
    try: run(old)
    except lj.LuaError as e:
        assert 'arithmetic' in str(e) and 'userdata' in str(e),e
        print('PASS: original callback fails with userdata arithmetic error')
    else: raise AssertionError('original buggy callback unexpectedly passed')
