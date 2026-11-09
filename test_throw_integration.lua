local file=assert(io.open('test_aim.lua','r'));local source=file:read('*a');file:close()
local boundary=assert(source:find('local total,failures=0,0',1,true))
local make_throw=assert(loadstring(source:sub(1,boundary-1)..'\nreturn throw_fixture','@aim-fixture-for-integration'))()
local Mod=assert(dofile('mod.lua'));local Aim=assert(dofile('aim.lua'))
local function fixture(late)
 local f=make_throw()
 f.ctl.view.aim_ray=function()return{x=0,y=0,z=1},{x=0,y=0.6,z=-0.8}end
 f.env.CameraManager.state='follow';f.env.CameraManager.targets={[f.player]={bias=1,look_ahead=0}}
 local native=f.throw_original
 if not late then f.env.CharacterComponent={do_throw=native}end
 local ctl=Mod.new(f.env,{enabled=true,aim=Aim,view={new=function()return f.ctl.view end}})
 ctl.local_unit=f.player;ctl:install_hooks()
 return f,ctl,native
end
local function same(v,x,y,z)
 assert(math.abs(v.x-x)<1e-9 and math.abs(v.y-y)<1e-9 and math.abs(v.z-z)<1e-9,'integrated throw direction mismatch')
end
local tests={}
function tests.character_throw_uses_the_real_aim_module_once_preserving_engine_signature_and_returns()
 local f,ctl=fixture()
 local a,b,c=f.env.CharacterComponent.do_throw(f.component,f.player,f.throw_entry,0.6,nil,'integration tail')
 same(f.throw_commands[1].payload.direction,0,0.6,-0.8)
 assert(f.seen.throw_calls==1 and a=='thrown' and b==nil and c=='throw tail')
 assert(f.seen.throw_args.tail=='integration tail' and f.seen.throw_args.entry==f.throw_entry)
 assert(f.throw_commands[1].payload.power==0.72 and f.throw_commands[1].payload.position==f.seen.throw_payload.position)
 assert(rawget(f.component,'queue_command_master')==nil)
end
function tests.throw_hook_handles_late_class_load_and_repeat_install_without_duplicate_native_command()
 local f,ctl,native=fixture(true)
 f.env.CharacterComponent={do_throw=native};ctl:install_hooks();local wrapper=f.env.CharacterComponent.do_throw
 ctl:install_hooks();assert(f.env.CharacterComponent.do_throw==wrapper)
 wrapper(f.component,f.player,f.throw_entry,0.6,nil,'late tail')
 same(f.throw_commands[1].payload.direction,0,0.6,-0.8)
 assert(f.seen.throw_calls==1 and #f.throw_commands==1)
end
function tests.integrated_off_top_remote_and_forced_drop_keep_native_throw_payload()
 for _,mode in ipairs({'off','top','remote','drop'})do
  local f,ctl=fixture();local unit=f.player;local power=0.6
  if mode=='off'then ctl.enabled=false elseif mode=='top'then ctl.view.mode='top'
  elseif mode=='remote'then unit={} elseif mode=='drop'then power=0 end
  f.env.CharacterComponent.do_throw(f.component,unit,f.throw_entry,power)
  same(f.throw_commands[1].payload.direction,0,1,1)
  assert(f.seen.throw_calls==1 and f.throw_commands[1].payload==f.seen.throw_payload,mode)
 end
end
local total,failed=0,0
for name,test in pairs(tests)do total=total+1;local good,err=pcall(test)
 if good then print('PASS '..name)else failed=failed+1;print('FAIL '..name..': '..tostring(err))end
end
print(string.format('%d integrated throw tests, %d failures',total,failed));assert(failed==0)
