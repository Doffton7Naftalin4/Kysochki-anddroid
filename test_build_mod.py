"""Exercise generated bootstrap through the actual LuaJIT 2.0.3 runtime."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / 'toolchain/LuaJIT-v2.0.3/src/luajit.exe'
SPEC = importlib.util.spec_from_file_location('build_mod', ROOT / 'build_mod.py')
builder = importlib.util.module_from_spec(SPEC)
try:
    SPEC.loader.exec_module(builder)
except FileNotFoundError:
    builder = None


class BootstrapTests(unittest.TestCase):
    def test_bootstrap_delivers_compiled_star_background_to_view(self):
        import inspect
        self.assertIn('sky_source', inspect.signature(builder.wrapper_source).parameters)
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder)
            original=builder.compile_module('calls={}; function update()end')
            view='return {new=function(env,ctl,config) assert(config.sky.marker=="star-background"); calls.sky=true; return {status=function()return "TOP"end,poll_toggle=function()end}end}'
            sky='return {marker="star-background"}'
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(original,(ROOT/'mod.lua').read_text(),None,view_source=view,sky_source=sky),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('dofile(arg[1]);assert(calls.sky and HD_CAMERA_PROTO.view and not HD_CAMERA_PROTO.enabled)',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_loads_compiled_view_module_before_original_update(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder)
            original=folder/'original.lua'; compiled=folder/'original.luac'
            original.write_text('''
calls={}
Window={set_title=function(title) calls.title=title end}
function update() assert(calls.view_poll==1); calls.update=true end
''',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            view='''return {new=function(env,controller,config)
                assert(env==_G and controller and config.version=="0.12.2")
                calls.view_loaded=true
                return {status=function() return "TOP" end,
                        poll_toggle=function() calls.view_poll=(calls.view_poll or 0)+1 end}
            end}'''
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None,view_source=view),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('dofile(arg[1]); update(); assert(calls.view_loaded and calls.update and HD_CAMERA_PROTO.view)',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_loads_compiled_aim_after_view_and_keeps_default_off(self):
        import inspect
        self.assertIn('aim_source', inspect.signature(builder.wrapper_source).parameters,
                      'bootstrap must accept a compiled aim module')
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder)
            original=folder/'original.lua'; compiled=folder/'original.luac'
            original.write_text('calls={}\nfunction update() end',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            view='return {new=function() return {status=function() return "TOP" end} end}'
            aim='''return {new=function(env,ctl,config)
                assert(ctl.view and not ctl.enabled and config.version=="0.12.2")
                calls.aim_loaded=true;return {marker="aim"}
            end}'''
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None,view_source=view,aim_source=aim),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('dofile(arg[1]); assert(calls.aim_loaded and HD_CAMERA_PROTO.aim.marker=="aim" and not HD_CAMERA_PROTO.enabled)',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_loads_compiled_pose_after_view_and_aim(self):
        import inspect
        self.assertIn('pose_source',inspect.signature(builder.wrapper_source).parameters,
                      'bootstrap must accept a compiled pose module')
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder);original=folder/'original.lua';compiled=folder/'original.luac'
            original.write_text('calls={}',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            view='return {new=function()return {status=function()return "TOP"end}end}'
            aim='return {new=function()return {marker="aim"}end}'
            pose='''return {new=function(env,ctl,config)
                assert(ctl.view and ctl.aim.marker=="aim" and not ctl.enabled and config.version=="0.12.2")
                calls.pose_loaded=true;return {marker="pose"}
            end}'''
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None,view_source=view,aim_source=aim,pose_source=pose),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('dofile(arg[1]);assert(calls.pose_loaded and HD_CAMERA_PROTO.pose.marker=="pose")',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_loads_compiled_actions_after_camera_aim_and_pose(self):
        import inspect
        self.assertIn('actions_source',inspect.signature(builder.wrapper_source).parameters,
                      'bootstrap must accept the compiled actions module')
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder);original=folder/'original.lua';compiled=folder/'original.luac'
            original.write_text('calls={}',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            view='return {new=function()return {status=function()return "TOP"end}end}'
            aim='return {new=function()return {marker="aim"}end}'
            pose='return {new=function()return {marker="pose"}end}'
            actions='''return {new=function(env,ctl,config)
                assert(ctl.view and ctl.aim.marker=="aim" and ctl.pose.marker=="pose" and not ctl.enabled and config.version=="0.12.2")
                calls.actions_loaded=true;return {marker="actions"}
            end}'''
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None,view_source=view,aim_source=aim,pose_source=pose,actions_source=actions),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('dofile(arg[1]);assert(calls.actions_loaded and HD_CAMERA_PROTO.actions.marker=="actions")',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_loads_compiled_prone_stratagems_after_actions(self):
        import inspect
        self.assertIn('stratagems_source',inspect.signature(builder.wrapper_source).parameters,
                      'bootstrap must accept the prone stratagems module')
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder);original=folder/'original.lua';compiled=folder/'original.luac'
            original.write_text('calls={}',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            actions='return {new=function()return {marker="actions"}end}'
            strata='''return {new=function(env,ctl,config)
                assert(ctl.actions.marker=="actions" and not ctl.enabled and config.version=="0.12.2")
                calls.strata_loaded=true;return {marker="strata",install_hooks=function()end}
            end}'''
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None,actions_source=actions,stratagems_source=strata),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('dofile(arg[1]);assert(calls.strata_loaded and HD_CAMERA_PROTO.stratagems.marker=="strata")',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_loads_module_when_host_only_accepts_bytecode(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder)
            original=folder/'original.lua'; compiled=folder/'original.luac'
            original.write_text(r'''
calls={}
Window={set_title=function(title) calls.title=title end}
local native_loadstring=loadstring
function loadstring(data,name)
 if data:sub(1,4)~="\27LJ\1" then return nil,"host refuses source chunks" end
 return native_loadstring(data,name)
end
function init() calls.init=true end
function update() calls.update=true end
''',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None,view_source=(ROOT/'view.lua').read_text(encoding='utf-8'),aim_source=(ROOT/'aim.lua').read_text(encoding='utf-8'),pose_source=(ROOT/'pose.lua').read_text(encoding='utf-8'),actions_source=(ROOT/'actions.lua').read_text(encoding='utf-8'),stratagems_source=(ROOT/'stratagems.lua').read_text(encoding='utf-8')),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('''
dofile(arg[1]); init(); update()
assert(HD_CAMERA_PROTO, 'module must load on a host that accepts bytecode only')
assert(not HD_CAMERA_PROTO.enabled)
assert(HD_CAMERA_PROTO.view and HD_CAMERA_PROTO.view:status()=='TOP', 'actual View must also load as bytecode')
assert(HD_CAMERA_PROTO.aim and type(HD_CAMERA_PROTO.aim.update)=='function', 'actual Aim must also load as bytecode')
assert(HD_CAMERA_PROTO.pose and type(HD_CAMERA_PROTO.pose.render)=='function', 'actual Pose must also load as bytecode')
assert(HD_CAMERA_PROTO.actions and type(HD_CAMERA_PROTO.actions.character_update)=='function', 'actual Actions must load as bytecode')
assert(HD_CAMERA_PROTO.stratagems and type(HD_CAMERA_PROTO.stratagems.install_hooks)=='function', 'actual Stratagems must load as bytecode')
assert(calls.init and calls.update)
assert(calls.title:find('OFF',1,true))
''',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_bootstrap_failure_title_preserves_error_details_after_original_init(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder)
            original=folder/'original.lua'
            compiled=folder/'original.luac'
            original.write_text('''
calls={init=0}
Window={set_title=function(title) calls.title=title end}
function init() calls.init=calls.init+1; Window.set_title('Helldivers') end
''',encoding='utf-8')
            subprocess.run([str(RUNTIME),str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),'error("module diagnostic sentinel",0)',None),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('''
dofile(arg[1]); init()
assert(calls.init==1)
assert(calls.title:find('LOAD ERROR',1,true))
assert(calls.title:find('module diagnostic sentinel',1,true), 'load error title must include the actual exception')
''',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_all_byte_values_survive_lua_literal(self):
        self.assertIsNotNone(builder, 'bootstrap builder must exist')
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            script = Path(folder) / 'literal.lua'
            output = Path(folder) / 'literal.bin'
            script.write_text('local f=assert(io.open(arg[1],"wb")); f:write(' + builder.lua_literal(bytes(range(256))) + '); f:close()', encoding='utf-8')
            subprocess.run([str(RUNTIME), str(script), str(output)], capture_output=True, check=True)
            self.assertEqual(output.read_bytes(), bytes(range(256)))

    def test_bootstrap_preserves_original_callbacks_and_installs_after_init(self):
        self.assertIsNotNone(builder, 'bootstrap builder must exist')
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            folder=Path(folder)
            original=folder/'original.lua'
            compiled=folder/'original.luac'
            original.write_text('''
calls={init=0,update=0,render=0,shutdown=0}
Window={set_title=function(title) calls.title=title end}
function init()
 calls.init=calls.init+1
 Window.set_title('Helldivers')
 InputComponent={update_masters=function() calls.input=(calls.input or 0)+1 end}
 return 'init-a',nil,'init-c'
end
function update(dt) calls.update=calls.update+1; calls.dt=dt; return 'a',nil,'c' end
function render() calls.render=calls.render+1 end
function shutdown() calls.shutdown=calls.shutdown+1 end
''',encoding='utf-8')
            subprocess.run([str(RUNTIME), str(ROOT/'toolchain/compile-bytecode.lua'),str(original),str(compiled)],capture_output=True,check=True)
            wrapped=folder/'wrapped.lua'
            wrapped.write_text(builder.wrapper_source(compiled.read_bytes(),(ROOT/'mod.lua').read_text(encoding='utf-8'),None),encoding='utf-8')
            harness=folder/'harness.lua'
            harness.write_text('''
dofile(arg[1])
assert(HD_CAMERA_PROTO and not HD_CAMERA_PROTO.enabled, 'prototype must start disabled')
local ia,ib,ic=init()
assert(ia=='init-a' and ib==nil and ic=='init-c', 'init return values must survive')
assert(calls.init==1)
assert(calls.title:find('CAMERA',1,true) and calls.title:find('OFF',1,true), 'status must be visible after original init resets the title')
assert(HD_CAMERA_PROTO.installed['InputComponent.update_masters'])
local a,b,c=update(0.125)
assert(a=='a' and b==nil and c=='c' and calls.update==1 and calls.dt==0.125)
InputComponent:update_masters({},0.1)
assert(calls.input==1)
HD_CAMERA_PROTO:set_enabled(true)
assert(calls.title:find('ON',1,true), 'toggle must publish ON')
HD_CAMERA_PROTO:set_enabled(false)
assert(calls.title:find('OFF',1,true), 'toggle must publish OFF')
render();shutdown()
assert(calls.render==1 and calls.shutdown==1)
print('BOOTSTRAP_PASS')
''',encoding='utf-8')
            result=subprocess.run([str(RUNTIME),str(harness),str(wrapped)],capture_output=True,text=True,check=True)
            self.assertIn('BOOTSTRAP_PASS',result.stdout)


if __name__=='__main__':
    unittest.main()
