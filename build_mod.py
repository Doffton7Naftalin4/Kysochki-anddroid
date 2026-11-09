"""Build the self-contained experimental bootstrap; never install it here."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
from package import patcher

ROOT=Path(__file__).resolve().parent
GAME=Path(r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers')
RUNTIME=ROOT/'toolchain/LuaJIT-v2.0.3/src/luajit.exe'
VERSION='0.12.2'


def lua_literal(value: bytes) -> str:
    return '"'+''.join(f'\\{byte:03d}' for byte in value)+'"'


def compile_module(source: str) -> bytes:
    with tempfile.TemporaryDirectory(dir=ROOT) as folder:
        directory=Path(folder).resolve()
        if not directory.is_relative_to(ROOT):
            raise ValueError('Compiler temporary directory outside prototype workspace')
        source_path=directory/'module.lua'
        output_path=directory/'module.luac'
        source_path.write_text(source,encoding='utf-8')
        subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(source_path),str(output_path)],capture_output=True,check=True)
        bytecode=output_path.read_bytes()
        if not bytecode.startswith(b'\x1bLJ\x01'):
            raise ValueError('Module compiler did not emit LuaJIT 2.0 bytecode')
        return bytecode


def wrapper_source(original: bytes, mod_source: str, log_path: str | None, *, view_source: str | None = None, aim_source: str | None = None, pose_source: str | None = None, actions_source: str | None = None, stratagems_source: str | None = None, sky_source: str | None = None) -> str:
    original_literal=lua_literal(original)
    module_literal=lua_literal(compile_module(mod_source))
    view_literal=lua_literal(compile_module(view_source)) if view_source is not None else 'nil'
    aim_literal=lua_literal(compile_module(aim_source)) if aim_source is not None else 'nil'
    pose_literal=lua_literal(compile_module(pose_source)) if pose_source is not None else 'nil'
    actions_literal=lua_literal(compile_module(actions_source)) if actions_source is not None else 'nil'
    stratagems_literal=lua_literal(compile_module(stratagems_source)) if stratagems_source is not None else 'nil'
    sky_literal=lua_literal(compile_module(sky_source)) if sky_source is not None else 'nil'
    log_literal=lua_literal(log_path.encode('utf-8')) if log_path else 'nil'
    return f'''-- Preserved original boot, then reversible experimental callbacks.
local function diagnostic_title(message)
    if Window and type(Window.set_title)=="function" then pcall(Window.set_title,message) end
end
diagnostic_title("HELLDIVERS | HD CAMERA v{VERSION} BOOT")
local original = assert(loadstring({original_literal}, "@hd-original-boot"))
original()
local original_init,original_update=init,update
local function pack(...) return {{n=select("#",...),...}} end
local ok,err=pcall(function()
    local function compiled_module(data,tag)
        if data==nil then return nil end
        local chunk,problem=loadstring(data,tag)
        if type(chunk)~="function" then error("Module bytecode load failed in "..tag..": "..tostring(problem),0) end
        return chunk()
    end
    local Mod=compiled_module({module_literal},"@hd-camera-module")
    local View=compiled_module({view_literal},"@hd-view-module")
    local Aim=compiled_module({aim_literal},"@hd-aim-module")
    local Pose=compiled_module({pose_literal},"@hd-pose-module")
    local Actions=compiled_module({actions_literal},"@hd-actions-module")
    local Stratagems=compiled_module({stratagems_literal},"@hd-stratagems-module")
    local Sky=compiled_module({sky_literal},"@hd-sky-module")
    local controller=Mod.new(_G,{{enabled=false,version="{VERSION}",log_path={log_literal},view=View,aim=Aim,pose=Pose,actions=Actions,stratagems=Stratagems,sky=Sky}})
    HD_CAMERA_PROTO=controller
    local function safe_hooks(force_status)
        local good,problem=pcall(function() controller:install_hooks() end)
        if not good then controller:set_enabled(false); controller:once("hook_failure",problem) end
        controller:publish_status(force_status)
    end
    if type(original_init)=="function" then
        init=function(...)
            local result=pack(original_init(...))
            safe_hooks(true)
            return unpack(result,1,result.n)
        end
    end
    if type(original_update)=="function" then
        update=function(...)
            local good,problem=pcall(function() controller:poll_toggle() end)
            if not good then controller:once("toggle_failure",problem) end
            safe_hooks()
            return original_update(...)
        end
    end
    controller:log("BOOTSTRAP LOADED v{VERSION}; DISABLED by default; F8 camera/separation, F9 TOP-SHOULDER-FIRST, F10 BODY test; experimental local firearm 3D aim")
end)
if not ok then
    print("[HD_CAMERA_PROTO] Bootstrap inactive: "..tostring(err))
    if type(original_init)=="function" then
        init=function(...)
            local result=pack(original_init(...))
            local detail=tostring(err):gsub("[%c]"," "):sub(1,240)
            diagnostic_title("HELLDIVERS | HD CAMERA v{VERSION} LOAD ERROR: "..detail)
            return unpack(result,1,result.n)
        end
    end
end
'''


def build(original_path: Path | None = None) -> dict:
    original_path=original_path or GAME/'contents'/patcher.ARCHIVE_NAME
    original_archive=original_path.read_bytes()
    if patcher.digest(original_archive)!=patcher.ORIGINAL_SHA256:
        raise ValueError('Build requires the pinned unmodified archive')
    original_boot=patcher.boot_bytecode(patcher.decode_archive(original_archive))
    output=ROOT/'build'/('v'+VERSION)
    output.mkdir(parents=True,exist_ok=True)
    log_dir=ROOT/'logs'
    log_dir.mkdir(exist_ok=True)
    source=output/'bootstrap.lua'
    bytecode=output/'bootstrap.luac'
    source.write_text(wrapper_source(original_boot,(ROOT/'mod.lua').read_text(encoding='utf-8'),str(log_dir/'prototype.log'),view_source=(ROOT/'view.lua').read_text(encoding='utf-8'),aim_source=(ROOT/'aim.lua').read_text(encoding='utf-8'),pose_source=(ROOT/'pose.lua').read_text(encoding='utf-8'),actions_source=(ROOT/'actions.lua').read_text(encoding='utf-8'),stratagems_source=(ROOT/'stratagems.lua').read_text(encoding='utf-8'),sky_source=(ROOT/'sky.lua').read_text(encoding='utf-8')),encoding='utf-8')
    subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(source),str(bytecode)],check=True)
    receipt=patcher.build_candidate(original_path,bytecode,output/'candidate.archive')
    receipt.update({'runtime_version':'LuaJIT 2.0.3','module_format':'LuaJIT bytecode version 1','module_sha256':hashlib.sha256((ROOT/'mod.lua').read_bytes()).hexdigest(),
                    'view_sha256':hashlib.sha256((ROOT/'view.lua').read_bytes()).hexdigest(),'aim_sha256':hashlib.sha256((ROOT/'aim.lua').read_bytes()).hexdigest(),'pose_sha256':hashlib.sha256((ROOT/'pose.lua').read_bytes()).hexdigest(),'actions_sha256':hashlib.sha256((ROOT/'actions.lua').read_bytes()).hexdigest(),'stratagems_sha256':hashlib.sha256((ROOT/'stratagems.lua').read_bytes()).hexdigest(),
                    'sky_sha256':hashlib.sha256((ROOT/'sky.lua').read_bytes()).hexdigest(),
                    'status':'built, not installed or runtime verified','scope':'on-foot experimental private testing'})
    (output/'build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    return receipt


if __name__=='__main__':
    print(json.dumps(build(),indent=2))
