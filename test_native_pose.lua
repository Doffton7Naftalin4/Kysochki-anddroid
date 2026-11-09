local Pose = assert(dofile("pose.lua"))
local counts={69,93,191,5,98,23,5,20,4}
local function pack(...)return{n=select("#",...),...}end
local function vec(x,y,z)return{x=x,y=y,z=z}end
local function equal(a,b)assert(a==b,tostring(a).." ~= "..tostring(b))end
local function fixture()
    local mine,friend,camera_unit,weapon={alive=true},{alive=true},{alive=true},{alive=true}
    local world,camera,other_world={},{},{}
    local states={[mine]={30,9,3,4,45,3,4,19,1},[friend]={30,9,3,4,45,3,4,19,1}}
    local seen={events={},targets={},sets={},logs={},direction=vec(0,1,0),marker=1,root=vec(10,20,1)}
    local env={Unit={},World={},CameraManager={},Vector3=vec};local classes={}
    for _,name in ipairs({"Idle","Walk","Sprint","Fire","WalkFire","Aim","AimWalk","AimFire","AimWalkFire","Dodge","Crawl","Stratagems","StratagemsThrow","Interact","Reload"})do
        classes[name]={};env["CharacterState"..name]=classes[name]
    end
    local character={current_state=classes.Aim,health_state={},current_weapon=weapon}
    env.EntityAux={owned=function(unit)return unit==weapon end,state=function(unit,name)
        if unit==weapon and name=="equipment"then return{wielder=mine,wielded=true}end
        assert(unit==mine and name=="character");return character
    end}
    env.Unit.alive=function(unit)return unit and unit.alive==true end
    env.Unit.animation_find_constraint_target=function(unit,name)assert(unit==mine and name=="hd_camera_aim");return seen.marker end
    env.Unit.animation_get_state=function(unit)return unpack(states[unit],1,seen.state_n or 9)end
    env.Unit.animation_set_state=function(unit,...)
        local values=pack(...);seen.sets[#seen.sets+1]={unit=unit,values=values}
        for i=1,values.n do if values[i]~=nil then states[unit][i]=values[i]end end
        return "set",nil,"tail"
    end
    env.Unit.animation_event=function(unit,event)
        assert(unit==mine,"private events restricted to local unit");seen.events[#seen.events+1]=event
        for i,count in ipairs(counts)do local value=states[unit][i]
            if value~=nil and event=="hd_pose_on"and value<count then states[unit][i]=value+count end
            if value~=nil and event=="hd_pose_off"and value>=count then states[unit][i]=value-count end
        end
        if event=="hd_pose_on"and seen.partial_on_error then error("partial native activation")end
    end
    env.Unit.animation_set_constraint_target=function(unit,index,target)
        assert(unit==mine and index==1);if seen.target_error then error("native target failure")end
        seen.targets[#seen.targets+1]=vec(target.x,target.y,target.z)
    end
    env.Unit.world_position=function(unit,node)if unit==mine then
        if node==0 then return seen.root end
        if node==2 then return vec(10,20,1.5)end
        if node==4 then return vec(10,21,1.5)end
        error("unknown character node")
    end;assert(unit==weapon and node==1);return vec(10,21,1)end
    env.Unit.world_rotation=function(unit,node)if unit==mine then assert(node==0);return "root"end;assert(unit==weapon and node==1);return "muzzle"end
    env.Unit.has_node=function(unit,name)return(unit==weapon and name=="j_muzzle")or(unit==mine and(name=="spine2"or name=="l_hand_attach"))end
    env.Unit.node=function(unit,name)if unit==mine then return name=="spine2"and 2 or 4 end;assert(unit==weapon and name=="j_muzzle");return 1 end
    env.Quaternion={rotate=function(rotation,v)if rotation=="root"then return v end;return seen.direction end}
    env.Unit.set_local_rotation=function()error("forbidden bone write")end
    env.World.update_unit=function()error("forbidden graph publication")end
    local view={mode="shoulder",owned={world=world,camera=camera,unit=camera_unit}}
    view.aim_ray=function()return vec(10,19,2),seen.direction end
    local ctl={enabled=true,view=view,local_unit=mine,installed={}}
    function ctl:active_local_unit()return self.enabled and self.local_unit or nil end
    function ctl:once(key,message)seen.logs[key]=seen.logs[key]or message end
    function ctl:hook(class,method,make)if type(env[class][method])=="function"and not self.installed[class..method]then env[class][method]=make(env[class][method]);self.installed[class..method]=true end end
    local pose=Pose.new(env,ctl,{});pose:install_hooks()
    return{pose=pose,env=env,ctl=ctl,seen=seen,mine=mine,friend=friend,weapon=weapon,world=world,camera=camera,other_world=other_world,view=view,character=character,classes=classes,states=states}
end
local tests={}
function tests.target_and_private_state_activation_only_for_validated_local_graph()
    local f=fixture();f.pose:before_animations(f.world)
    equal(f.seen.events[1],"hd_pose_on");equal(#f.seen.targets,1);equal(f.states[f.mine][5],143);equal(f.states[f.friend][5],45)
end
function tests.moving_aim_changes_target_without_reentering_private_states()
    local f=fixture();f.pose:before_animations(f.world);f.seen.direction=vec(0,.8,.6);f.pose:before_animations(f.world)
    equal(#f.seen.events,1);equal(#f.seen.targets,2);assert(f.seen.targets[2].z>f.seen.targets[1].z)
end
function tests.off_restores_base_states_once_and_stops_writes()
    local f=fixture();f.pose:before_animations(f.world);f.pose:toggle_diagnostic();f.pose:before_animations(f.world)
    equal(f.seen.events[2],"hd_pose_off");equal(#f.seen.events,2);equal(#f.seen.targets,1);equal(f.states[f.mine][5],45)
end
function tests.missing_graph_invalid_index_or_tuple_is_fail_closed()
    for _,change in ipairs({function(f)f.seen.marker=-1 end,function(f)f.seen.marker=0 end,function(f)f.seen.marker=2 end,function(f)f.seen.state_n=8 end,function(f)f.states[f.mine][1]=138 end,function(f)f.states[f.mine][4]=-1 end})do
        local f=fixture();change(f);f.pose:before_animations(f.world);equal(#f.seen.events,0);equal(#f.seen.targets,0);equal(f.pose:status(),"BODY OFF")
    end
end
function tests.nonfinite_or_zero_aim_never_reaches_native_storage()
    for _,direction in ipairs({vec(0,0,0),vec(0,0/0,1),vec(math.huge,1,0)})do local f=fixture();f.seen.direction=direction;f.pose:before_animations(f.world);equal(#f.seen.events,0);equal(#f.seen.targets,0)end
end
function tests.unsafe_contexts_release_private_mode()
    for _,change in ipairs({function(f)f.character.health_state.is_dead=true end,function(f)f.character.current_seat_unit={alive=true}end,function(f)f.character.current_state=f.classes.Interact end,function(f)f.view.mode="top"end,function(f)f.ctl.enabled=false end})do
        local f=fixture();f.pose:before_animations(f.world);change(f);f.pose:before_animations(f.world);equal(f.seen.events[2],"hd_pose_off");equal(f.states[f.mine][5],45)
    end
end
function tests.other_world_passes_through_and_nil_world_releases_camera_pose()
    local f=fixture();f.pose:before_animations(f.other_world);equal(#f.seen.events,0);f.pose:before_animations(f.world);f.pose:before_animations(f.other_world);equal(#f.seen.events,1);f.pose:before_animations(nil);equal(f.seen.events[2],"hd_pose_off")
end
function tests.script_and_rpc_getter_preserves_nine_base_ids_and_nil_layers()
    local f=fixture();f.states[f.mine][1]=nil;f.pose:before_animations(f.world)
    local got=pack(f.env.Unit.animation_get_state(f.mine));equal(got.n,9);equal(got[1],nil);equal(got[5],45);equal(pack(f.env.Unit.animation_get_state(f.friend))[5],45)
end
function tests.prone_setter_maps_to_current_mode_and_preserves_nil_and_native_returns()
    local f=fixture();f.pose:before_animations(f.world);local a,b,c=f.env.Unit.animation_set_state(f.mine,nil,9,3,4,46,3,4,19,1)
    equal(a,"set");equal(b,nil);equal(c,"tail");equal(f.seen.sets[1].values.n,9);equal(f.seen.sets[1].values[1],nil);equal(f.seen.sets[1].values[5],144);equal(f.states[f.mine][1],99)
    f.env.Unit.animation_set_state(f.friend,30,9,3,4,46,3,4,19,1);equal(f.seen.sets[2].values[5],46)
    f.pose:toggle_diagnostic();f.env.Unit.animation_set_state(f.mine,30,9,3,4,46,3,4,19,1);equal(f.seen.sets[3].values[5],46)
end
function tests.external_base_restore_reenters_private_mode_before_evaluation()
    local f=fixture();f.pose:before_animations(f.world);f.states[f.mine][5]=45;f.pose:before_animations(f.world);equal(f.states[f.mine][5],143);equal(f.seen.events[2],"hd_pose_on")
end
function tests.scene_render_preserve_returns_errors_and_use_no_manual_transforms()
    local f=fixture();f.pose:before_animations(f.world);local calls=0
    local a,b,c=f.pose:scene(function(w,tail)calls=calls+1;return w,nil,tail end,f.world,"tail");equal(calls,1);equal(a,f.world);equal(b,nil);equal(c,"tail")
    local ok,problem=pcall(f.pose.render,f.pose,function()error("renderer failure")end,f.world,f.camera);equal(ok,false);assert(tostring(problem):find("renderer failure",1,true))
end
function tests.muzzle_samples_translate_expire_and_reject_changed_aim()
    local f=fixture();f.pose:before_animations(f.world);f.pose:scene(function()end,f.world)
    local got=f.pose:shot_sample(f.mine,f.weapon,vec(11,20,1));assert(got);equal(got.origin.x,11);equal(got.origin.y,21)
    f.seen.direction=vec(1,0,0);equal(f.pose:shot_sample(f.mine,f.weapon,f.seen.root),nil)
    f.seen.direction=vec(0,1,0);f.pose:begin_frame();f.pose:begin_frame();equal(f.pose:shot_sample(f.mine,f.weapon,f.seen.root),nil)
end
function tests.radio_defers_to_native_pose_even_during_prone_stratagem_session()
    local f=fixture();f.pose:before_animations(f.world)
    f.character.current_state=f.classes.Stratagems;f.ctl.stratagems={prone=function()return true end}
    f.pose:before_animations(f.world);equal(f.seen.events[2],"hd_pose_off");equal(#f.seen.targets,1)
    f.character.current_state=f.classes.StratagemsThrow;f.pose:before_animations(f.world);equal(#f.seen.events,2)
end
function tests.hard_target_failure_stays_disabled_after_f10()
    local f=fixture();f.seen.target_error=true;f.pose:before_animations(f.world);equal(f.pose:status(),"BODY OFF");equal(#f.seen.events,0)
    f.seen.target_error=false;f.pose:toggle_diagnostic();f.pose:toggle_diagnostic();f.pose:before_animations(f.world);equal(#f.seen.events,0)
end
function tests.partial_native_activation_is_released_before_staying_disabled()
    local f=fixture();f.seen.partial_on_error=true;f.pose:before_animations(f.world)
    equal(f.pose:status(),"BODY OFF");equal(f.states[f.mine][5],45);equal(f.seen.events[2],"hd_pose_off")
end
function tests.partial_setter_and_trailing_nil_rpc_keep_original_argument_count()
    local f=fixture();f.pose:before_animations(f.world)
    local a,b,c=f.env.Unit.animation_set_state(f.mine,30,nil,3)
    equal(a,"set");equal(b,nil);equal(c,"tail");equal(f.seen.sets[1].values.n,3)
    equal(f.seen.sets[1].values[1],99);equal(f.seen.sets[1].values[2],nil);equal(f.seen.sets[1].values[3],194)
    equal(f.states[f.mine][5],143)
    f.env.Unit.animation_set_state(f.mine);equal(f.seen.sets[2].values.n,0)
    local ok=pcall(f.env.Unit.animation_set_state,f.mine,30,9,3,4,98,3,4,19,1)
    equal(ok,false);equal(#f.seen.sets,2)
end
function tests.target_retains_previous_safe_yaw_and_pitch_limits()
    local f=fixture();f.seen.direction=vec(1,0,2);f.pose:before_animations(f.world)
    local target=f.seen.targets[1];assert(target)
    local x,y,z=target.x-10,target.y-20,target.z-1.5
    assert(math.abs(math.atan2(x,y))<=55*math.pi/180+0.000001)
    assert(math.abs(math.atan2(z,math.sqrt(x*x+y*y)))<=math.pi/4+0.000001)
end
local function geometry_fixture()
    local f=fixture();f.seen.geometry={};f.seen.geometry_reads=0
    local indices={spine2=2,aim=3,l_hand_attach=4,r_hand_attach=5,spine4=6}
    local positions={[2]=vec(10,20,1.5),[3]=vec(10,20,2),[4]=vec(9.8,20.4,1.4),[5]=vec(10.2,20.5,1.4),[6]=vec(10,20,1.8)}
    local has_node,node,position=f.env.Unit.has_node,f.env.Unit.node,f.env.Unit.world_position
    f.env.Unit.has_node=function(unit,name)
        if unit==f.mine then return indices[name]~=nil and name~=f.seen.missing_node end
        return has_node(unit,name)
    end
    f.env.Unit.node=function(unit,name)if unit==f.mine then return indices[name]end;return node(unit,name)end
    f.env.Unit.world_position=function(unit,index)
        if unit==f.mine and index~=0 then
            -- These three points are diagnostic-only; spine2/foregrip are
            -- also read by the active per-frame observer/target producer.
            if index~=2 and index~=4 then
                assert(f.seen.scene_complete,"geometry must follow the original scene")
                f.seen.geometry_reads=f.seen.geometry_reads+1
            end
            return positions[index]
        end
        return position(unit,index)
    end
    f.ctl.log=function(_,message)f.seen.geometry[#f.seen.geometry+1]=message end
    return f
end
local function geometry_scene(f)
    return f.pose:scene(function()f.seen.scene_complete=true;return "scene",nil,"tail"end,f.world)
end
function tests.geometry_after_scene_records_nodes_ray_numeric_target_and_raw_canonical_states()
    local f=geometry_fixture();f.states[f.mine][1]=nil
    geometry_scene(f);equal(#f.seen.geometry,0);equal(f.seen.geometry_reads,0)
    local setter=f.env.Unit.animation_set_constraint_target
    f.env.Unit.animation_set_constraint_target=function(unit,index,target)f.seen.temporary_target=target;return setter(unit,index,target)end
    f.pose:before_animations(f.world);f.seen.temporary_target.x=9999
    local a,b,c=geometry_scene(f);equal(a,"scene");equal(b,nil);equal(c,"tail")
    equal(#f.seen.geometry,1);local line=f.seen.geometry[1]
    for _,text in ipairs({"Native pose geometry","body=ON","stance=standing","camera_pitch=flat","spine2=(10.000000,20.000000,1.500000)",
        "spine4=(10.000000,20.000000,1.800000)","aim=(10.000000,20.000000,2.000000)","l_hand_attach=","r_hand_attach=","muzzle=","muzzle_forward=","camera_origin=","camera_direction=",
        "root=","LAST_REQUEST=(10.000000,1020.000000,1.500000)","last_request_frame=0","last_request_unit=","raw=n=9[nil,102,194,9,143,26,9,39,5]",
        "canonical=n=9[nil,9,3,4,45,3,4,19,1]","aim_muzzle_deg="})do assert(line:find(text,1,true),text.." missing from "..line)end
    assert(not line:find("9999",1,true),"temporary vector must not be retained")
end
function tests.geometry_body_off_works_without_any_native_pose_writes()
    local f=geometry_fixture();f.pose:toggle_diagnostic()
    geometry_scene(f);geometry_scene(f)
    equal(#f.seen.geometry,1);assert(f.seen.geometry[1]:find("body=OFF",1,true))
    equal(#f.seen.events,0);equal(#f.seen.targets,0);equal(#f.seen.sets,0)
end
function tests.geometry_logs_only_once_per_stance_pitch_body_bin_twelve_total()
    local f=geometry_fixture();local calls=0
    for _,off in ipairs({false,true})do
        if off then f.pose:toggle_diagnostic()end
        for _,stance in ipairs({f.classes.Aim,f.classes.Crawl})do
            f.character.current_state=stance
            for _,pitch in ipairs({-.6,0,.6})do
                f.seen.direction=vec(0,math.cos(pitch),math.sin(pitch));f.pose:before_animations(f.world)
                local writes=#f.seen.targets
                for _=1,3 do geometry_scene(f);calls=calls+1 end
                equal(#f.seen.targets,writes)
            end
        end
    end
    equal(#f.seen.geometry,12);equal(f.seen.geometry_reads,36)
    for _=1,5 do geometry_scene(f)end
    equal(#f.seen.geometry,12);equal(f.seen.geometry_reads,36);equal(calls,36)
end
function tests.diving_scene_does_not_consume_ground_bin_then_crawl_does()
    local f=geometry_fixture();f.character.current_state=f.classes.Dodge
    f.pose:before_animations(f.world);geometry_scene(f)
    equal(f.pose.active_unit,f.mine);equal(#f.seen.events,1);equal(#f.seen.targets,1)
    equal(#f.seen.geometry,0);equal(f.seen.geometry_reads,0)
    f.character.current_state=f.classes.Crawl;f.pose:before_animations(f.world)
    geometry_scene(f);geometry_scene(f)
    equal(#f.seen.geometry,1);assert(f.seen.geometry[1]:find("stance=prone",1,true))
    equal(#f.seen.events,1);equal(#f.seen.targets,2)
end
function tests.geometry_rejects_foreign_world_nonlocal_or_unsafe_context_without_bone_reads()
    for _,change in ipairs({function(f)f.world=f.other_world end,function(f)f.ctl.enabled=false end,
        function(f)f.view.mode="top"end,function(f)f.character.health_state.is_dead=true end,
        function(f)f.character.health_state.is_downed=true end,function(f)f.character.current_seat_unit={alive=true}end,
        function(f)f.ctl.local_unit=f.friend end})do
        local f=geometry_fixture();change(f);geometry_scene(f)
        equal(#f.seen.geometry,0);equal(f.seen.geometry_reads,0);equal(#f.seen.events,0);equal(#f.seen.targets,0)
    end
end
function tests.geometry_missing_nodes_bad_getters_and_throwing_logger_cannot_interrupt_native_scene()
    local f=geometry_fixture();f.pose:toggle_diagnostic();f.seen.missing_node="aim"
    local a,b,c=geometry_scene(f);equal(a,"scene");equal(b,nil);equal(c,"tail")
    equal(#f.seen.geometry,1);assert(f.seen.geometry[1]:find("aim=unavailable",1,true))
    f=geometry_fixture();f.pose:toggle_diagnostic();local attempts=0
    f.ctl.log=function()attempts=attempts+1;error("diagnostic logger failure")end
    f.pose.native_get_state=function()error("diagnostic getter failure")end
    a,b,c=geometry_scene(f);geometry_scene(f);equal(a,"scene");equal(b,nil);equal(c,"tail");equal(attempts,1)
    equal(f.pose.disabled,false);equal(#f.seen.events,0);equal(#f.seen.targets,0)
    local ok,problem=pcall(f.pose.scene,f.pose,function()error("original scene failure")end,f.world)
    equal(ok,false);assert(tostring(problem):find("original scene failure",1,true));equal(attempts,1)
end
function tests.geometry_once_fallback_handles_invalid_node_indices_without_position_queries()
    local f=geometry_fixture();f.pose:toggle_diagnostic();f.ctl.log=nil
    f.env.Unit.node=function()return 0/0 end
    geometry_scene(f);geometry_scene(f)
    local number=0
    for _,message in pairs(f.seen.logs)do if message:find("Native pose geometry",1,true)then
        number=number+1;assert(message:find("spine2=unavailable",1,true))
    end end
    equal(number,1);equal(f.seen.geometry_reads,0);equal(#f.seen.events,0);equal(#f.seen.targets,0)
end
local function vdot(a,b)return a.x*b.x+a.y*b.y+a.z*b.z end
local function vunit(v)local n=math.sqrt(vdot(v,v));return vec(v.x/n,v.y/n,v.z/n)end
local function direction(yaw,pitch)return vec(math.sin(yaw)*math.cos(pitch),math.cos(yaw)*math.cos(pitch),math.sin(pitch))end
local function basis(v)
    v=vunit(v);local h=math.sqrt(v.x*v.x+v.y*v.y)
    return{vec(v.y/h,-v.x/h,0),v,vec(-v.x*v.z/h,-v.y*v.z/h,h)}
end
local function apply(b,v)return vec(b[1].x*v.x+b[2].x*v.y+b[3].x*v.z,b[1].y*v.x+b[2].y*v.y+b[3].y*v.z,b[1].z*v.x+b[2].z*v.y+b[3].z*v.z)end
local function inverse(b,v)return vec(vdot(b[1],v),vdot(b[2],v),vdot(b[3],v))end
local function near_vector(a,b,tolerance)
    assert(a and b,"missing modeled vector")
    assert(math.sqrt((a.x-b.x)^2+(a.y-b.y)^2+(a.z-b.z)^2)<(tolerance or 0.000001),"modeled weapon did not match requested aim")
end
local function full_fixture(offset,prone)
    local f=fixture();f.character.current_state=prone and f.classes.Crawl or f.classes.Aim
    f.seen.offset=vunit(offset);f.seen.source=direction(.3,.55);f.pivot=vec(10,20,1.5)
    f.seen.actual_reference=f.seen.source;f.seen.actual_muzzle=apply(basis(f.seen.source),f.seen.offset)
    local nodes={spine2=2,spine4=6,aim=3,l_hand_attach=4,r_hand_attach=5}
    f.env.Unit.has_node=function(unit,name)return not f.seen.missing and ((unit==f.mine and nodes[name]~=nil)or(unit==f.character.current_weapon and name=="j_muzzle"))end
    f.env.Unit.node=function(unit,name)return unit==f.mine and nodes[name]or 1 end
    f.env.Unit.world_position=function(unit,node)
        if unit==f.mine then
            if node==0 then return f.seen.root end
            if node==2 then return f.pivot end
            if node==6 then return vec(10,20,1.8)end
            local r=f.seen.actual_reference
            return vec(f.pivot.x+r.x*.6,f.pivot.y+r.y*.6,f.pivot.z+r.z*.6)
        end
        assert(unit==f.character.current_weapon and node==1)
        local r=f.seen.actual_muzzle;return vec(f.pivot.x+r.x,f.pivot.y+r.y,f.pivot.z+r.z)
    end
    f.env.Unit.world_rotation=function(unit,node)return unit==f.mine and"root"or"muzzle"end
    f.env.Quaternion.rotate=function(rotation,v)return rotation=="root"and v or f.seen.actual_muzzle end
    f.env.EntityAux.owned=function(unit)return unit==f.character.current_weapon end
    f.env.EntityAux.state=function(unit,name)
        if unit==f.mine and name=="character"then return f.character end
        assert(unit==f.character.current_weapon and name=="equipment");return{wielder=f.mine,wielded=true}
    end
    function f:evaluate()
        self.seen.scene_calls=(self.seen.scene_calls or 0)+1
        if self.pose.active_unit==self.mine then
            local t=self.seen.targets[#self.seen.targets]
            local target=vunit(vec(t.x-self.pivot.x,t.y-self.pivot.y,t.z-self.pivot.z))
            -- Actual native point-look equation, independent of its inverse:
            -- L(target) * inverse(L(raw clip source)) * raw clip gun forward.
            local source_weapon=apply(basis(self.seen.source),self.seen.offset)
            self.seen.actual_muzzle=apply(basis(target),inverse(basis(self.seen.source),source_weapon))
            self.seen.actual_reference=self.seen.override_reference or target
        else
            self.seen.actual_reference=self.seen.source
            self.seen.actual_muzzle=apply(basis(self.seen.source),self.seen.offset)
        end
        return"native-scene",nil,"tail"
    end
    function f:step(pitch,yaw)
        if pitch then self.seen.direction=direction(yaw or 0,pitch)end
        self.pose:begin_frame();self.pose:before_animations(self.world)
        local a,b,c=self.pose:scene(function()return self:evaluate()end,self.world)
        equal(a,"native-scene");equal(b,nil);equal(c,"tail")
    end
    return f
end
local standing=vec(-.344896,.841502,-.415837)
local crawling=vec(-.392411,.919316,-.029516)
function tests.adaptive_native_full_equation_matches_standing_and_prone_camera_pitch_range()
    for _,entry in ipairs({{standing,false},{crawling,true}})do
        local f=full_fixture(entry[1],entry[2]);f:step(0);f:step(0)
        near_vector(f.seen.actual_muzzle,vec(0,1,0))
        for _,pitch in ipairs({-math.pi/4,0,math.pi/4})do
            f:step(pitch,.25);near_vector(f.seen.actual_muzzle,direction(.25,pitch))
        end
        local t=f.seen.targets[#f.seen.targets];local v=vunit(vec(t.x-f.pivot.x,t.y-f.pivot.y,t.z-f.pivot.z))
        assert(math.asin(v.z)>math.pi/4,"encoded target must not be reclamped to camera pitch45")
        equal(#f.seen.events,1);equal(#f.seen.sets,0)
    end
end
function tests.adaptive_phase_changes_refresh_every_scene_and_state_change_holds_target_without_old_C()
    local f=full_fixture(standing);f:step(.2);f:step(.2)
    local prior=f.seen.targets[#f.seen.targets]
    f.states[f.mine][3]=195;f.seen.offset=vunit(crawling)
    f:step(.2);local held=f.seen.targets[#f.seen.targets]
    near_vector(vunit(vec(prior.x-10,prior.y-20,prior.z-1.5)),vunit(vec(held.x-10,held.y-20,held.z-1.5)))
    f:step(.2);near_vector(f.seen.actual_muzzle,direction(0,.2))
    f.seen.offset=vunit(standing);f:step(.2);f:step(.2)
    near_vector(f.seen.actual_muzzle,direction(0,.2));equal(#f.seen.events,1)
end
function tests.adaptive_stale_nonfinite_and_look_frame_mismatch_do_not_reuse_untrusted_C()
    local f=full_fixture(standing);f:step(0);f:step(0)
    f.pose:begin_frame();f.pose:begin_frame();f.pose:before_animations(f.world)
    local held=f.seen.targets[#f.seen.targets]
    assert(held.z>100,"expired geometry should retain last encoded direction, not defaultflat")
    f=full_fixture(standing);f.seen.override_reference=direction(10*math.pi/180,85*math.pi/180)
    f.seen.direction=direction(0,85*math.pi/180)
    -- Two pitch85 Look frames differ only0.87deg in forward but10deg in
    -- their full basis. Probe the observer with that exact boundary record.
    f:step(0);local request=f.pose.last_request
    request.x=f.pivot.x;request.y=f.pivot.y+1000*math.cos(85*math.pi/180);request.z=f.pivot.z+1000*math.sin(85*math.pi/180)
    local posted=f.seen.targets[#f.seen.targets];posted.x=request.x;posted.y=request.y;posted.z=request.z
    assert(vdot(direction(0,85*math.pi/180),f.seen.override_reference)>math.cos(math.pi/180))
    f.pose:scene(function()return f:evaluate()end,f.world)
    assert(f.pose.observer==nil,"nearvertical yaw mismatch must reject the full Look frame")
    f.seen.override_reference=vec(0/0,1,0);f:step(0)
    equal(f.pose.disabled,false);assert(f.pose.observer==nil)
end
function tests.adaptive_weapon_world_off_and_prone_reload_clear_geometry_and_recover()
    local f=full_fixture(standing,true);f:step(0);f:step(0)
    f.env.EntityAux.state_master_interface=function()return f.seen.weapon_state end
    f.seen.weapon_state={is_reloading=true};f:step(0)
    equal(f.pose.active_unit,nil);equal(f.pose.observer,nil);equal(f.pose.last_encoded,nil)
    f.seen.weapon_state={reload_time=1};f:step(0);equal(f.pose.active_unit,nil)
    f.seen.weapon_state={};f:step(0);f:step(0);near_vector(f.seen.actual_muzzle,vec(0,1,0))
    f.character.current_weapon={alive=true};f:step(0)
    local t=f.seen.targets[#f.seen.targets];assert(math.abs(t.z-f.seen.root.z)<1,"new weapon must bootstrap without old calibration")
    f:step(0);near_vector(f.seen.actual_muzzle,vec(0,1,0))
    f.pose:toggle_diagnostic();equal(f.pose.observer,nil);equal(f.pose.last_encoded,nil)
    f.pose:toggle_diagnostic();f:step(0);f:step(0)
    f.world=f.other_world;f.view.owned.world=f.world;f:step(0)
    t=f.seen.targets[#f.seen.targets];assert(math.abs(t.z-f.seen.root.z)<1,"new world must not use old calibration")
end
function tests.adaptive_unreachable_geometry_holds_target_without_private_mode_chatter_and_can_recover()
    local f=full_fixture(vec(.95,.2,.1));f:step(0);f:step(0)
    local old=f.seen.targets[#f.seen.targets]
    f:step(math.pi/4);local held=f.seen.targets[#f.seen.targets]
    near_vector(vunit(vec(old.x-10,old.y-20,old.z-1.5)),vunit(vec(held.x-10,held.y-20,held.z-1.5)))
    equal(#f.seen.events,1);equal(f.pose.disabled,false)
    f:step(0);near_vector(f.seen.actual_muzzle,vec(0,1,0))
end
function tests.standing_idle_walk_sprint_and_reload_keep_native_pose_while_aim_fire_activate()
    for _,name in ipairs({"Idle","Walk","Sprint","Reload"})do
        local f=fixture();f.character.current_state=f.classes[name];f.pose:before_animations(f.world)
        equal(#f.seen.events,0);equal(#f.seen.targets,0);equal(f.pose.disabled,false)
    end
    for _,name in ipairs({"Aim","AimWalk","AimFire","AimWalkFire","Fire","WalkFire","Dodge","Crawl"})do
        local f=fixture();f.character.current_state=f.classes[name];f.pose:before_animations(f.world)
        equal(f.seen.events[1],"hd_pose_on")
    end
end
function tests.adaptive_original_scene_error_is_preserved_once_and_discards_observation()
    local f=full_fixture(standing);f:step(0);assert(f.pose.observer)
    local calls=0
    local good,problem=pcall(f.pose.scene,f.pose,function()calls=calls+1;error("actual scene failure")end,f.world)
    equal(good,false);assert(tostring(problem):find("actual scene failure",1,true));equal(calls,1)
    equal(f.pose.observer,nil);equal(f.pose.sample,nil);equal(f.pose.disabled,false)
end
function tests.adaptive_negative_observed_projection_is_not_calibrated_and_recovers_with_valid_grip()
    local f=full_fixture(vec(.2,-.3,math.sqrt(.87)));f:step(0)
    equal(f.pose.observer,nil);f:step(.1);equal(f.pose.observer,nil);equal(f.pose.disabled,false)
    f.seen.offset=vunit(standing);f:step(.1);assert(f.pose.observer)
    f:step(.1);near_vector(f.seen.actual_muzzle,direction(0,.1));equal(#f.seen.events,1)
end
function tests.adaptive_encoded_pitch_boundary_holds_without_flipping_and_recovers()
    local c=vec(.2,.3,math.sqrt(.87));local radius=math.sqrt(c.y*c.y+c.z*c.z);local phase=math.atan2(c.z,c.y)
    local function camera_pitch(encoded_pitch)return math.asin(radius*math.sin(encoded_pitch+phase))end
    local f=full_fixture(c);local first=camera_pitch(-84.9*math.pi/180)
    f:step(first);f:step(first);near_vector(f.seen.actual_muzzle,direction(0,first))
    local a=f.seen.targets[#f.seen.targets]
    f:step(camera_pitch(-85.1*math.pi/180));local b=f.seen.targets[#f.seen.targets]
    near_vector(vec(a.x,a.y,a.z),vec(b.x,b.y,b.z));equal(#f.seen.events,1);equal(f.pose.disabled,false)
    f:step(0);near_vector(f.seen.actual_muzzle,vec(0,1,0))
end
local function recovery_fixture()
    local f=full_fixture(standing);f.seen.recovery={}
    f.ctl.log=function(_,message)
        if message:find("Native pose recovery:",1,true)then
            assert(f.seen.scene_calls and f.seen.scene_calls>0,"recovery must follow the native scene")
            f.seen.recovery[#f.seen.recovery+1]=message
        end
    end
    f.character.input={fire=false}
    return f
end
function tests.recovery_records_each_aim_fire_edge_after_scene_without_changing_the_producer()
    for _,pair in ipairs({{"Aim","AimFire"},{"AimFire","Aim"},{"AimWalk","AimWalkFire"},{"AimWalkFire","AimWalk"}})do
        local f=recovery_fixture();local control=full_fixture(standing)
        f.character.current_state=f.classes[pair[1]];control.character.current_state=control.classes[pair[1]]
        f:step(.2);control:step(.2);equal(#f.seen.recovery,0)
        f.character.current_state=f.classes[pair[2]];control.character.current_state=control.classes[pair[2]]
        f.character.input.fire=pair[2]:find("Fire",1,true)~=nil
        f:step(.2);control:step(.2)
        equal(#f.seen.recovery,1);local line=f.seen.recovery[1]
        for _,text in ipairs({"window=1","frame=2","edge="..pair[1].."->"..pair[2],"class="..pair[2],
            "fire="..tostring(f.character.input.fire),"canonical=n=9[","mode=compensated","encoded_target_direction=(",
            "camera_direction=(","muzzle_direction=(","ref_target_frame_deg=","observer_C=("})do
            assert(line:find(text,1,true),"missing recovery field: "..text)
        end
        near_vector(f.seen.targets[2],control.seen.targets[2]);near_vector(f.seen.actual_muzzle,control.seen.actual_muzzle)
        equal(#f.seen.events,#control.seen.events);equal(#f.seen.sets,0)
    end
end
function tests.recovery_is_once_per_frame_one_hundred_eighty_frames_four_windows_seven_twenty_total()
    local f=recovery_fixture();f:step(0)
    for window=1,4 do
        if window<=2 then f.character.current_state=window==1 and f.classes.AimFire or f.classes.Aim
        else
            if window==3 then f.character.current_state=f.classes.Crawl;f.character.input.fire=false;f:step(0)end
            f.character.input.fire=window==3
        end
        for _=1,180 do
            f:step(0)
            local n=#f.seen.recovery
            f.pose:scene(function()return f:evaluate()end,f.world)
            equal(#f.seen.recovery,n)
        end
        equal(#f.seen.recovery,window*180)
        for _=1,3 do f:step(0)end
        equal(#f.seen.recovery,window*180)
    end
    f.character.input.fire=true
    for _=1,30 do f:step(0)end
    equal(#f.seen.recovery,720);equal(#f.seen.events,1);equal(#f.seen.sets,0)
end
function tests.recovery_context_replacement_release_and_reload_discard_old_windows()
    for _,change in ipairs({
        function(f)f.character.current_weapon={alive=true}end,
        function(f)f.world=f.other_world;f.view.owned.world=f.world end,
        function(f)local next_state={};for k,v in pairs(f.character)do next_state[k]=v end
            f.env.EntityAux.state_master=function()return next_state end end,
        function(f)f.pose:toggle_diagnostic()end,
        function(f)f.env.EntityAux.state_master_interface=function()return{is_reloading=true}end end,
        function(f)f.character.current_state=f.classes.Stratagems end,
    })do
        local f=recovery_fixture();f:step(0);f.character.current_state=f.classes.AimFire;f:step(0)
        equal(#f.seen.recovery,1);change(f);f:step(0);equal(#f.seen.recovery,1)
        equal(f.pose.recovery_windows,1);equal(f.pose.recovery_count,1)
    end
end
function tests.recovery_foreign_scene_cannot_sample_or_cancel_the_local_window()
    local f=recovery_fixture();f:step(0);f.character.current_state=f.classes.AimFire;f:step(0)
    equal(#f.seen.recovery,1);f.pose:begin_frame()
    local calls=0;local a,b,c=f.pose:scene(function(world)calls=calls+1;equal(world,f.other_world);return"foreign",nil,"tail"end,f.other_world)
    equal(a,"foreign");equal(b,nil);equal(c,"tail");equal(calls,1);equal(#f.seen.recovery,1)
    f.pose:before_animations(f.world);f.pose:scene(function()return f:evaluate()end,f.world)
    equal(#f.seen.recovery,2)
end
function tests.recovery_logger_getter_failures_and_native_error_preserve_calls_returns_and_budget()
    local f=recovery_fixture();f:step(0);local attempts=0
    f.ctl.log=function(_,message)if message:find("Native pose recovery:",1,true)then attempts=attempts+1;error("logger failed")end end
    f.character.current_state=f.classes.AimFire
    for _=1,184 do f:step(0)end
    equal(attempts,180);equal(f.pose.disabled,false);equal(#f.seen.events,1)
    f=recovery_fixture();f:step(0);f.character.current_state=f.classes.AimFire;f.pose:begin_frame();f.pose:before_animations(f.world)
    local getter=f.pose.native_get_state;f.pose.native_get_state=function()error("diagnostic getter failed")end
    local calls=0;local a,b,c=f.pose:scene(function()calls=calls+1;return"native",nil,"tail"end,f.world)
    equal(a,"native");equal(b,nil);equal(c,"tail");equal(calls,1);equal(#f.seen.recovery,1)
    assert(f.seen.recovery[1]:find("canonical=unavailable",1,true));equal(f.pose.disabled,false)
    f.pose.native_get_state=getter
    local good,problem=pcall(f.pose.scene,f.pose,function()calls=calls+1;error("original scene failure")end,f.world)
    equal(good,false);assert(tostring(problem):find("original scene failure",1,true));equal(calls,2)
    f:step(0);equal(#f.seen.recovery,1);equal(f.pose.disabled,false)
end
function tests.recovery_retains_the_first_window_across_edges_until_late_hold_reacquisition()
    local f=recovery_fixture();f:step(0);f:step(0)
    f.character.current_state=f.classes.AimFire;f:step(0)
    f.seen.override_reference=direction(.2,.1)
    for _=1,30 do f:step(0)end
    f.character.current_state=f.classes.Aim
    for _=1,10 do f:step(0)end
    equal(f.pose.recovery_windows,1)
    local holding=f.seen.recovery[#f.seen.recovery]
    assert(holding:find("window=1",1,true));assert(holding:find("mode=holding",1,true))
    assert(holding:find("observation_reason=look_mismatch",1,true));assert(holding:find("hold_frames=",1,true))
    f.seen.override_reference=nil;f:step(0);f:step(0)
    local acquired=f.seen.recovery[#f.seen.recovery]
    assert(acquired:find("window=1",1,true));assert(acquired:find("mode=compensated",1,true))
    assert(acquired:find("observation_reason=accepted",1,true));assert(acquired:find("accepted_C=(",1,true))
    equal(f.pose.recovery_windows,1);equal(#f.seen.events,1);equal(#f.seen.sets,0)
end
function tests.recovery_prone_fire_boolean_edges_share_the_existing_window_budget()
    local f=recovery_fixture();f.character.current_state=f.classes.Crawl
    f.character.input.fire=true;f:step(0);equal(#f.seen.recovery,0)
    f.character.input.fire=false;f:step(0);equal(#f.seen.recovery,1)
    assert(f.seen.recovery[1]:find("edge=Crawl.fire=true->false",1,true))
    f.character.input.fire=true;f:step(0);equal(f.pose.recovery_windows,1)
    assert(f.seen.recovery[2]:find("edge=Crawl.fire=false->true",1,true))
    f.character.current_state=f.classes.Aim;f:step(0);equal(f.pose.recovery_windows,1);equal(#f.seen.recovery,2)
    equal(#f.seen.events,1);equal(#f.seen.sets,0)
end
function tests.recovery_producer_snapshot_copies_numeric_states_directions_and_exact_hold_reasons()
    local f=recovery_fixture();f:step(.2);f:step(.2)
    f.character.current_state=f.classes.AimFire;f:step(.2)
    local d=f.pose.last_request.diagnostic;assert(d,"producer diagnostic missing")
    equal(d.reason,"fresh");equal(d.previous_mode,"compensated");equal(d.hold_frames,0)
    equal(d.observer_age,1);assert(d.used_C and d.limited_desired and d.encoded)
    equal(d.raw_states.n,9);equal(d.raw_states[3],194);equal(d.canonical_states[3],3)
    assert(type(d.encoded_delta_deg)=="number");near_vector(d.limited_desired,direction(0,.2))
    local old_raw=d.raw_states[3];f.states[f.mine][3]=195;equal(d.raw_states[3],old_raw)
    f:step(.2);d=f.pose.last_request.diagnostic;equal(d.reason,"state_mismatch");equal(d.used_C,nil);equal(d.hold_frames,1)
    f.seen.override_reference=direction(.7,.3);f:step(.2);f:step(.2);f:step(.2)
    d=f.pose.last_request.diagnostic;equal(d.reason,"no_observer");assert(d.hold_frames>=2)
    f.seen.override_reference=nil;f:step(.2);f.pose:begin_frame();f.pose:begin_frame();f.pose:before_animations(f.world)
    equal(f.pose.last_request.diagnostic.reason,"stale")
    f=full_fixture(vec(.95,.2,.1));f:step(0);f:step(math.pi/4)
    equal(f.pose.last_request.diagnostic.reason,"no_candidate");equal(f.pose.last_request.mode,"holding")
end
function tests.recovery_after_scene_geometry_is_optional_numeric_and_never_changes_native_outcome()
    local f=recovery_fixture();f:step(.2);f:step(.2);f.character.current_state=f.classes.AimFire;f:step(.2)
    local line=f.seen.recovery[1]
    for _,text in ipairs({"producer_raw=n=9[","producer_canonical=n=9[","limited_desired=(","used_C=(","observer_age=1",
        "previous_mode=compensated","encoded_delta_deg=","reason=fresh","S=(","T=(","S_xy=","T_xy=","forward_error_deg=",
        "spine2=(","spine_right=(","spine_forward=(","spine_up=(","l_hand_attach=(","muzzle_position=(","measured_C=("})do
        assert(line:find(text,1,true),"missing expanded field: "..text)
    end
    local rotation=f.env.Unit.world_rotation;local spine_reads=0
    f.env.Unit.world_rotation=function(unit,index)if unit==f.mine and index==2 then spine_reads=spine_reads+1;error("optional spine rotation unavailable")end;return rotation(unit,index)end
    local position=f.env.Unit.world_position
    f.env.Unit.world_position=function(unit,index)if unit==f.weapon and index==1 then error("optional muzzle position unavailable")end;return position(unit,index)end
    local targets,events=#f.seen.targets,#f.seen.events
    local calls=0;local a,b,c=f.pose:scene(function()calls=calls+1;return"native",nil,"tail"end,f.world)
    equal(a,"native");equal(b,nil);equal(c,"tail");equal(calls,1);equal(spine_reads,0)
    -- Same frame does not retry optional reads; next frame logs unavailable.
    f:step(.2);line=f.seen.recovery[#f.seen.recovery]
    assert(line:find("spine_right=unavailable",1,true));assert(line:find("muzzle_position=unavailable",1,true))
    equal(spine_reads,1);f.pose:scene(function()return f:evaluate()end,f.world);equal(spine_reads,1)
    equal(#f.seen.targets,targets+1);equal(#f.seen.events,events);equal(f.pose.disabled,false)
end
local function issued_direction(f)
    local t=f.seen.targets[#f.seen.targets]
    return vunit(vec(t.x-f.pivot.x,t.y-f.pivot.y,t.z-f.pivot.z))
end
function tests.hold_tracks_thirty_degree_mouse_motion_for_132_frames_without_reacquisition_snap()
    for _,entry in ipairs({{standing,false},{crawling,true}})do
        local f=full_fixture(entry[1],entry[2]);f:step(0);f:step(0)
        f.seen.override_reference=direction(-1,.5);f:step(0)
        for frame=1,132 do
            local yaw=(math.pi/6)*frame/132
            f:step(0,yaw);equal(f.pose.last_request.mode,"holding");equal(f.pose.observer,nil)
            equal(f.pose.last_request.diagnostic.used_C,nil)
            near_vector(f.seen.actual_muzzle,direction(yaw,0))
        end
        local previous=issued_direction(f)
        f.seen.override_reference=nil;f:step(0,math.pi/6);f:step(0,math.pi/6)
        equal(f.pose.last_request.mode,"compensated");near_vector(issued_direction(f),previous)
        near_vector(f.seen.actual_muzzle,direction(math.pi/6,0))
        equal(#f.seen.events,1);equal(#f.seen.sets,0);equal(f.seen.scene_calls,137)
    end
end
function tests.hold_command_relation_handles_mixed_pitch_yaw_and_rapid_mouse_without_lag()
    for _,entry in ipairs({{standing,false},{crawling,true}})do
        local f=full_fixture(entry[1],entry[2]);f:step(-.1,-.2);f:step(-.1,-.2)
        local anchor=issued_direction(f);local relation=inverse(basis(anchor),direction(-.2,-.1))
        f.seen.override_reference=direction(-1,.5);f:step(-.1,-.2)
        for _,goal in ipairs({{55,45},{-55,-45},{45,0},{-45,35},{0,-40},{55,45}})do
            local yaw,pitch=goal[1]*math.pi/180,goal[2]*math.pi/180
            f:step(pitch,yaw);equal(f.pose.last_request.mode,"holding");equal(f.pose.observer,nil)
            local encoded=issued_direction(f)
            near_vector(apply(basis(encoded),relation),direction(yaw,pitch))
            near_vector(f.seen.actual_muzzle,direction(yaw,pitch));assert(math.abs(math.asin(encoded.z))<=85*math.pi/180)
            near_vector(f.pose.last_encoded.reference_desired,direction(yaw,pitch))
        end
        equal(#f.seen.events,1);equal(#f.seen.sets,0)
    end
end
function tests.hold_without_mouse_motion_preserves_the_previous_numeric_target()
    local f=full_fixture(standing);f:step(.1,.2);f:step(.1,.2)
    local before=issued_direction(f);f.seen.override_reference=direction(-1,.5)
    for _=1,20 do f:step(.1,.2);near_vector(issued_direction(f),before)end
    equal(f.pose.last_request.mode,"holding");equal(#f.seen.events,1);equal(#f.seen.sets,0)
end
function tests.hold_pole_domain_keeps_both_command_anchors_then_recovers_without_flip()
    local f=full_fixture(standing);f:step(0);f:step(0)
    local anchor=direction(0,80*math.pi/180);local desired=direction(0,25*math.pi/180)
    f.pose.last_encoded.direction=anchor;f.pose.last_encoded.reference_desired=desired
    f.pose.observer=nil;f.seen.override_reference=direction(-1,.5)
    f:step(math.pi/4);near_vector(issued_direction(f),anchor)
    near_vector(f.pose.last_encoded.reference_desired,desired);equal(f.pose.last_request.mode,"holding")
    f:step(24*math.pi/180);near_vector(issued_direction(f),direction(0,79*math.pi/180))
    near_vector(f.pose.last_encoded.reference_desired,direction(0,24*math.pi/180))
    assert(issued_direction(f).y>0,"transport must not cross the pole into a yaw180 endpoint")
    equal(#f.seen.events,1);equal(f.pose.disabled,false)
end
function tests.fresh_unreachable_solution_latches_world_hold_until_a_fresh_reachable_sample()
    local f=full_fixture(vec(.95,.2,.1));f:step(0);f:step(math.pi/4)
    local before=issued_direction(f);local reference=f.pose.last_encoded.reference_desired
    equal(f.pose.last_encoded.hard_hold,true);equal(f.pose.last_request.mode,"holding")
    f.pose.observer=nil;f.seen.override_reference=direction(-1,.5)
    f:step(0,.4);near_vector(issued_direction(f),before);equal(f.pose.last_encoded.hard_hold,true)
    near_vector(f.pose.last_encoded.reference_desired,reference)
    f.seen.override_reference=nil;f:step(0,.4);f:step(0,.4)
    equal(f.pose.last_request.mode,"compensated");equal(f.pose.last_encoded.hard_hold,false)
    near_vector(f.seen.actual_muzzle,direction(.4,0));equal(#f.seen.events,1)
end
function tests.hold_invalid_command_anchor_fails_soft_and_context_reset_never_reuses_it()
    for _,invalid in ipairs({false,17,vec(0,0,0),vec(0/0,1,0),vec(math.huge,0,0)})do
        local f=full_fixture(standing);f:step(0);f:step(0)
        local before=issued_direction(f);f.pose.last_encoded.reference_desired=invalid
        f.pose.observer=nil;f.seen.override_reference=direction(-1,.5)
        f:step(.1,.2);near_vector(issued_direction(f),before);equal(f.pose.disabled,false)
        f.pose:toggle_diagnostic();equal(f.pose.last_encoded,nil);f.pose:toggle_diagnostic()
        f.seen.override_reference=nil;f:step(.1,.2)
        equal(f.pose.last_request.mode,"bootstrap");near_vector(issued_direction(f),direction(.2,.1))
        near_vector(f.pose.last_encoded.reference_desired,direction(.2,.1));equal(f.pose.last_encoded.hard_hold,false)
    end
end
function tests.recovery_aim_flood_cannot_starve_two_prone_windows_and_stance_cross_closes_trace()
    local f=recovery_fixture();f:step(0)
    f.character.current_state=f.classes.AimFire;f:step(0)
    for _=1,180 do f.pose:begin_frame()end
    f.character.current_state=f.classes.Aim;f:step(0)
    for _=1,180 do f.pose:begin_frame()end
    f.character.current_state=f.classes.AimFire;f:step(0)
    equal(f.pose.recovery_windows,2);equal(#f.seen.recovery,2)
    f.character.current_state=f.classes.Crawl;f.character.input.fire=false;f:step(0)
    equal(#f.seen.recovery,2)
    f.character.input.fire=true;f:step(0)
    equal(f.pose.recovery_windows,3);equal(#f.seen.recovery,3)
    f.character.current_state=f.classes.Aim;f:step(0);equal(#f.seen.recovery,3)
    f.character.current_state=f.classes.Crawl;f.character.input.fire=false;f:step(0)
    f.character.input.fire=true;f:step(0)
    equal(f.pose.recovery_windows,4);equal(#f.seen.recovery,4)
    equal(#f.seen.events,1);equal(#f.seen.sets,0)
end
local total=0
for name,test in pairs(tests)do local ok,problem=pcall(test);if not ok then error(name..": "..tostring(problem),0)end;total=total+1 end
print("PASS native pose "..total.." tests; fixtures do not prove rendered engine behavior")
