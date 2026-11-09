-- Synthetic engine boundary tests. No game bytecode or game data is embedded.
local loaded,Aim=pcall(dofile,"aim.lua")
assert(loaded and type(Aim.new)=="function","Aim.new module must exist")
local function vec(x,y,z)return{x=x,y=y,z=z}end
local function clone(v)return vec(v.x,v.y,v.z)end
local function near(a,b)assert(math.abs(a-b)<0.000001,string.format("expected %.9f, got %.9f",b,a))end
local function same(v,x,y,z)near(v.x,x);near(v.y,y);near(v.z,z)end
local function fixture()
    local local_player,remote_player,enemy={alive=true},{alive=true},{alive=true}
    local local_weapon,remote_weapon,enemy_weapon={alive=true},{alive=true},{alive=true}
    local seen={casts={},batches=0,logs={},query_calls=0}
    local env={CameraManager={},Vector3=vec,Vector3Aux={unbox=clone,box=function(box,v)box.x=v.x;box.y=v.y;box.z=v.z;return box end},
        Unit={alive=function(u)return u and u.alive end,world_rotation=function(u,node)return {direction=u.forward or vec(0,1,0)}end},
        Quaternion={forward=function(q)return clone(q.direction)end}}
    local owners={[local_weapon]=local_player,[remote_weapon]=remote_player,[enemy_weapon]=enemy}
    env.EntityAux={has_component=function(u,c)return c=="equipment" and owners[u]~=nil end,
        state=function(u,c)if c=="equipment"then return{wielder=owners[u]}end end,
        owned=function(u)return u==local_weapon end}
    local ctl={enabled=true,local_unit=local_player,view={mode="first"}}
    function ctl:active_local_unit(manager)return self.enabled and self.local_unit.alive and self.local_unit or nil end
    function ctl:log(line)seen.logs[#seen.logs+1]=line end
    ctl.view.aim_ray=function()return vec(0,0,0),vec(0,0.7071067811865475,0.7071067811865475)end
    local entries={}
    local function add(weapon)
        local ray={}
        function ray:cast(origin,direction,distance,shot_id,tail)
            seen.casts[weapon]={origin=origin,direction=clone(direction),distance=distance,shot_id=shot_id,tail=tail,
                self=self,boxed=clone(entries[weapon].state.firedir_override)}
            return "ray",nil,"tail"
        end
        entries[weapon]={state={raycast_slave=ray,ray_source_offset=vec(0,0,0),firedir_override=vec(0,0,0),
            range=20,range_multiplier=1,attach_node=0,ignored_units={},synthetic_direction=vec(0,1,0),synthetic_origin=vec(0,0,0),rounds=7}}
    end
    add(local_weapon);add(remote_weapon);add(enemy_weapon)
    local component={world_proxy={get_world=function()return "world"end,get_physics_world=function()return "physics"end}}
    local function original(self,batch,dt,tail)
        seen.batches=seen.batches+1;seen.batch=batch;seen.component=self;seen.dt=dt;seen.tail=tail
        for weapon,entry in pairs(batch)do
            local state=entry.state
            state.rounds=state.rounds-1
            env.Vector3Aux.box(state.firedir_override,state.synthetic_direction)
            local a,b,c=state.raycast_slave:cast(state.synthetic_origin,state.synthetic_direction,100,17,"cast tail")
            assert(a=="ray"and b==nil and c=="tail","native cast returns must survive proxy")
        end
        return "update",nil,"update tail"
    end
    return {env=env,ctl=ctl,seen=seen,entries=entries,component=component,original=original,
        mine=local_weapon,remote=remote_weapon,enemy=enemy_weapon,player=local_player,aim=Aim.new(env,ctl,{})}
end
local function run(f)return f.aim:update(f.original,f.component,f.entries,0.25,"update arg")end
local tests={}
function tests.local_cast_uses_upward_camera_axis_in_one_original_batch()
    local f=fixture();local ray=f.entries[f.mine].state.raycast_slave
    local a,b,c=run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
    assert(f.seen.batches==1 and f.seen.batch==f.entries and f.seen.component==f.component and f.seen.dt==0.25 and f.seen.tail=="update arg")
    assert(a=="update"and b==nil and c=="update tail")
    assert(f.entries[f.mine].state.raycast_slave==ray and f.seen.casts[f.mine].self==ray)
    assert(f.entries[f.mine].state.rounds==6)
end
function tests.remote_and_enemy_rays_are_unchanged()
    local f=fixture();run(f)
    same(f.seen.casts[f.remote].direction,0,1,0);same(f.seen.casts[f.enemy].direction,0,1,0)
end
function tests.muzzle_origin_and_cast_arguments_are_preserved()
    local f=fixture();local origin=vec(0,0,0);f.entries[f.mine].state.synthetic_origin=origin;run(f)
    local cast=f.seen.casts[f.mine]
    assert(cast.origin==origin and cast.distance==100 and cast.shot_id==17 and cast.tail=="cast tail")
    same(cast.boxed,0,0.7071067811865475,0.7071067811865475)
end
function tests.downward_pitch_and_muzzle_parallax_converge_on_camera_target()
    local f=fixture();f.ctl.view.aim_ray=function()return vec(0,0,1),vec(0,1,0)end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.9987523388778446,0.04993761694389223)
    f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,0.7071067811865475,-0.7071067811865475)end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,-0.7071067811865475)
end
function tests.original_spread_deviation_is_rotated_instead_of_removed()
    local f=fixture();f.entries[f.mine].state.synthetic_direction=vec(0.6,0.8,0);run(f)
    same(f.seen.casts[f.mine].direction,0.6,0.565685424949238,0.565685424949238)
end
function tests.original_offset_drop_is_removed_before_camera_axis_rotation()
    local f=fixture();f.entries[f.mine].state.ray_source_offset=vec(0,0,1)
    f.entries[f.mine].state.synthetic_direction=vec(0,0.9987523388778446,-0.04993761694389223);run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.exact_reverse_axis_is_finite_and_normalized()
    local f=fixture();f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,-1,0)end;run(f)
    same(f.seen.casts[f.mine].direction,0,-1,0)
end
function tests.nearest_valid_camera_hit_wins_and_local_surfaces_are_ignored()
    local f=fixture();local ignored={alive=true};f.entries[f.mine].state.ignored_units={ignored}
    f.ctl.view.aim_ray=function()return vec(2,0,1),vec(0,1,0)end
    f.env.World={physics_world=function(w)assert(w=="world");return "physics"end}
    f.env.Actor={unit=function(a)return a.unit end}
    f.env.PhysicsWorld={immediate_raycast=function(p,o,d,r,mode,key,filter)
        assert(p=="physics"and mode=="all"and key=="collision_filter"and filter=="damage_ray"and r==20)
        same(o,2,0,1);same(d,0,1,0);f.seen.query_calls=f.seen.query_calls+1
        return{{vec(2,1,1),1,vec(0,0,1),{unit=f.player}},{vec(2,2,1),2,vec(0,0,1),{unit=f.mine}},
            {vec(2,3,1),3,vec(0,0,1),{unit=ignored}},{vec(2,10,1),10,vec(0,0,1),{unit={alive=true}}},
            {vec(2,5,1),5,vec(0,0,1),{unit={alive=true}}}}
    end}
    run(f);same(f.seen.casts[f.mine].direction,0.3651483716701107,0.9128709291752769,0.18257418583505536)
    assert(f.seen.query_calls==1,"only the local weapon may query camera collision")
end
function tests.camera_query_failure_uses_weapon_range_fallback()
    local f=fixture();f.env.World={physics_world=function()return "physics"end};f.env.Actor={unit=function()end}
    f.env.PhysicsWorld={immediate_raycast=function()error("query unavailable")end};run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.gates_missing_context_ownership_and_nonlocal_wielder_without_touching_rays()
    for _,mutation in ipairs({function(f)f.ctl.enabled=false end,function(f)f.ctl.view=nil end,
        function(f)f.ctl.view.aim_ray=function()return nil end end,function(f)f.env.EntityAux.owned=function()return false end end,
        function(f)f.env.EntityAux.state=function()return{wielder={}}end end,
        function(f)f.ctl.view.aim_ray=function()error("bad camera")end end,
        function(f)f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,0,0)end end,
        function(f)f.entries[f.mine].state.range_multiplier=0 end})do
        local f=fixture();mutation(f);run(f);same(f.seen.casts[f.mine].direction,0,1,0)
        assert(f.seen.batches==1)
    end
end
function tests.original_exception_restores_every_proxy_and_is_not_retried()
    local f=fixture();local ray=f.entries[f.mine].state.raycast_slave
    local attempts=0;local ok,problem=pcall(f.aim.update,f.aim,function(_,entries)
        attempts=attempts+1;assert(entries[f.mine].state.raycast_slave~=ray);error("engine failure")
    end,f.component,f.entries,0.25)
    assert(not ok and tostring(problem):find("engine failure",1,true) and attempts==1)
    assert(f.entries[f.mine].state.raycast_slave==ray)
end
function tests.native_cast_exception_restores_proxy_without_retrying_the_shot()
    local f=fixture();local ray=f.entries[f.mine].state.raycast_slave;local attempts=0
    ray.cast=function()attempts=attempts+1;error("native ray failure")end
    local ok,problem=pcall(run,f)
    assert(not ok and tostring(problem):find("native ray failure",1,true) and attempts==1)
    assert(f.entries[f.mine].state.raycast_slave==ray)
end
function tests.callback_direction_errors_fall_back_to_original_once()
    local f=fixture();f.env.Quaternion.forward=function()error("rotation API failure")end;run(f)
    same(f.seen.casts[f.mine].direction,0,1,0);assert(f.entries[f.mine].state.rounds==6)
end
function tests.logs_are_bounded_and_include_actual_direction_and_target_source()
    local f=fixture();for _=1,8 do run(f)end
    assert(#f.seen.logs==3,"steady pitch must not log every shot")
    assert(f.seen.logs[1]:find("ray_z=0.707",1,true) and f.seen.logs[1]:find("target=range",1,true))
    f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,0.7071067811865475,-0.7071067811865475)end;run(f)
    assert(#f.seen.logs==4 and f.seen.logs[4]:find("ray_z=-0.707",1,true))
end
function tests.shared_local_and_remote_state_fails_closed()
    local f=fixture();f.entries[f.remote].state=f.entries[f.mine].state;run(f)
    -- Sharing a state is ambiguous: neither entry may receive camera aim.
    same(f.seen.casts[f.mine].direction,0,1,0)
end
function tests.nested_update_restores_outer_proxy_after_error()
    local f=fixture();local ray=f.entries[f.mine].state.raycast_slave;local calls=0
    local ok,problem=pcall(f.aim.update,f.aim,function(component,entries)
        calls=calls+1
        f.aim:update(function()calls=calls+1;error("nested failure")end,component,entries)
    end,f.component,f.entries)
    assert(not ok and tostring(problem):find("nested failure",1,true) and calls==2)
    assert(f.entries[f.mine].state.raycast_slave==ray)
    run(f);same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.weapon_range_multiplier_controls_camera_convergence()
    local f=fixture();f.entries[f.mine].state.range_multiplier=2
    f.ctl.view.aim_ray=function()return vec(0,0,1),vec(0,1,0)end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.9996876464081228,0.02499219116020307)
end
function tests.explicit_view_target_takes_precedence_over_range()
    local f=fixture();f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,1,0),vec(0,1,1)end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.malformed_and_out_of_range_camera_hits_use_range_fallback()
    local f=fixture();f.env.World={physics_world=function()return "physics"end};f.env.Actor={unit=function(a)return a end}
    f.env.PhysicsWorld={immediate_raycast=function()return{{vec(1,1,1),-1,{},{}},{vec(1,1,1),21,{},{}},{vec(1,1,1),1},{"bad",1,{},{}}}end}
    run(f);same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.diagnostic_failure_cannot_cancel_or_retry_a_native_shot()
    local f=fixture();f.ctl.log=function()error("log failure")end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
    assert(f.entries[f.mine].state.rounds==6)
end
function tests.local_ownership_rejection_logs_once_without_relaxing_guard()
    local f=fixture();f.env.EntityAux.owned=function()return false end
    for _=1,8 do run(f)end
    same(f.seen.casts[f.mine].direction,0,1,0)
    assert(#f.seen.logs==1 and f.seen.logs[1]:find("ownership!=true",1,true))
end
function tests.camera_query_prefers_native_world_proxy_physics_api()
    local f=fixture();f.env.World=nil;f.env.Actor={unit=function(a)return a end}
    f.env.PhysicsWorld={immediate_raycast=function(p)
        assert(p=="physics");return{{vec(0,2,2),2.82842712474619,vec(0,0,1),{}}}
    end}
    f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,1,0)end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.camera_query_can_use_verified_world_static_fallback()
    local f=fixture();f.component.world_proxy.get_physics_world=nil
    f.env.World={physics_world=function(w)assert(w=="world");return "physics"end};f.env.Actor={unit=function(a)return a end}
    f.env.PhysicsWorld={immediate_raycast=function(p)
        assert(p=="physics");return{{vec(0,2,2),2.82842712474619,vec(0,0,1),{}}}
    end}
    f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,1,0)end;run(f)
    same(f.seen.casts[f.mine].direction,0,0.7071067811865475,0.7071067811865475)
end
local function throw_fixture()
    local f=fixture();local commands={};local old_owned=f.env.EntityAux.owned
    f.env.EntityAux.owned=function(unit)return unit==f.player or old_owned(unit)end
    f.env.CharacterStateThrow={};f.env.CharacterStateStratagemsThrow={}
    f.throw_entry={state={current_state=f.env.CharacterStateThrow,health_state={is_dead=false,is_downed=false}}}
    local parent={queue_command_master=function(self,unit,kind,command,payload,tail)
        commands[#commands+1]={self=self,unit=unit,kind=kind,command=command,payload=payload,tail=tail}
        return"queued",nil,"queue tail"
    end}
    f.component=setmetatable({},{__index=parent});f.throw_commands=commands;f.throw_parent=parent
    f.throw_original=function(self,unit,entry,power,direction,tail)
        f.seen.throw_calls=(f.seen.throw_calls or 0)+1
        f.seen.throw_args={self=self,unit=unit,entry=entry,power=power,direction=direction,tail=tail}
        direction=direction or vec(0,1,0);direction.z=1 -- original native forced upward arc
        f.seen.throw_payload={direction=clone(direction),position=vec(4,5,6),power=power*1.2,native_field="unchanged"}
        local a,b,c=self:queue_command_master(unit,"inventory","throw",f.seen.throw_payload,"native queue arg")
        assert(a=="queued"and b==nil and c=="queue tail")
        return"thrown",nil,"throw tail"
    end
    return f
end
local function throw(f,power,direction,tail)
    return f.aim:throw(f.throw_original,f.component,f.player,f.throw_entry,power or 0.6,direction,tail or"throw arg")
end
function tests.throw_uses_fresh_camera_pitch_without_changing_native_power_origin_or_returns()
    local f=throw_fixture();local a,b,c=throw(f)
    assert(f.seen.throw_calls==1 and a=="thrown"and b==nil and c=="throw tail")
    local call=f.throw_commands[1];same(call.payload.direction,0,0.7071067811865475,0.7071067811865475)
    assert(call.self==f.component and call.unit==f.player and call.kind=="inventory"and call.command=="throw"
        and call.tail=="native queue arg"and call.payload~=f.seen.throw_payload
        and call.payload.position==f.seen.throw_payload.position and call.payload.power==0.72 and call.payload.native_field=="unchanged")
    same(f.seen.throw_payload.direction,0,1,1);same(call.payload.position,4,5,6)
    assert(f.seen.throw_args.entry==f.throw_entry and f.seen.throw_args.tail=="throw arg"
        and rawget(f.component,"queue_command_master")==nil)
    f.ctl.view.aim_ray=function()return vec(0,0,0),vec(0,0.6,-0.8)end;throw(f)
    same(f.throw_commands[2].payload.direction,0,0.6,-0.8)
    assert(f.seen.throw_calls==2)
end
function tests.stratagem_throw_uses_same_direction_bridge_and_zero_power_drop_is_unchanged()
    local f=throw_fixture();f.throw_entry.state.current_state=f.env.CharacterStateStratagemsThrow;throw(f)
    same(f.throw_commands[1].payload.direction,0,0.7071067811865475,0.7071067811865475)
    throw(f,0);same(f.throw_commands[2].payload.direction,0,1,1)
    assert(f.throw_commands[2].payload==f.seen.throw_payload and f.throw_commands[2].payload.power==0)
    throw(f,-0.5);same(f.throw_commands[3].payload.direction,0,1,1)
    assert(f.throw_commands[3].payload==f.seen.throw_payload and f.throw_commands[3].payload.power==-0.6)
end
function tests.throw_gates_local_owner_health_state_context_and_supported_throw_states()
    local mutations={function(f)f.ctl.enabled=false end,function(f)f.ctl.view.mode="top"end,
        function(f)f.ctl.view.aim_ray=function()return nil end end,function(f)f.env.EntityAux.owned=function()return false end end,
        function(f)f.throw_entry.state.health_state.is_dead=true end,function(f)f.throw_entry.state.health_state.is_downed=true end,
        function(f)f.throw_entry.state.is_dead=true end,function(f)f.throw_entry.state.is_downed=true end,
        function(f)f.throw_entry.state.has_extracted=true end,function(f)f.throw_entry.state.do_knockdown=true end,
        function(f)f.throw_entry.state.current_seat_unit={alive=true}end,function(f)f.throw_entry.state.current_carry_unit={alive=true}end,
        function(f)f.throw_entry.state.current_state={}end,function(f)f.throw_entry.state.health_state=nil end,
        function(f)f.ctl.view.aim_ray=function()error("camera unavailable")end end}
    for i,mutation in ipairs(mutations)do local f=throw_fixture();mutation(f);throw(f)
        assert(f.seen.throw_calls==1 and f.throw_commands[1].payload==f.seen.throw_payload,"throw gate "..i)
        same(f.throw_commands[1].payload.direction,0,1,1)
    end
end
function tests.throw_does_not_change_remote_or_other_commands_emitted_by_original()
    local f=throw_fixture();local payload={direction=vec(1,0,1),position=vec(1,2,3),power=0.5}
    f.throw_original=function(self,unit)
        self:queue_command_master({},"inventory","throw",payload)
        self:queue_command_master(unit,"inventory","prepare_throw",payload)
        self:queue_command_master(unit,"throwable","thrown",payload)
    end
    throw(f);assert(#f.throw_commands==3)
    for _,command in ipairs(f.throw_commands)do assert(command.payload==payload)end
    local calls=0;f.aim:throw(function()calls=calls+1 end,f.component,{},f.throw_entry,0.5)
    assert(calls==1)
end
function tests.throw_exception_restores_inherited_queue_without_retry_or_leaked_guard()
    local f=throw_fixture();local calls=0
    local good,problem=pcall(f.aim.throw,f.aim,function(self)calls=calls+1
        assert(rawget(self,"queue_command_master")~=nil);error("native throw failure")
    end,f.component,f.player,f.throw_entry,0.5)
    assert(not good and tostring(problem):find("native throw failure",1,true)and calls==1)
    assert(rawget(f.component,"queue_command_master")==nil and f.component.queue_command_master==f.throw_parent.queue_command_master)
    throw(f);same(f.throw_commands[1].payload.direction,0,0.7071067811865475,0.7071067811865475)
end
function tests.throw_nested_calls_are_not_redirected_by_outer_scope_and_queue_error_is_not_retried()
    local f=throw_fixture();local original=f.throw_original
    f.throw_original=function(self,unit,entry,power)
        f.aim:throw(original,self,unit,entry,power)
        return original(self,unit,entry,power)
    end
    throw(f);same(f.throw_commands[1].payload.direction,0,1,1)
    same(f.throw_commands[2].payload.direction,0,0.7071067811865475,0.7071067811865475)
    local attempts=0;f.component.queue_command_master=function()attempts=attempts+1;error("native queue failure")end
    local queue=f.component.queue_command_master
    local good,problem=pcall(throw,f)
    assert(not good and tostring(problem):find("native queue failure",1,true)and attempts==1 and f.component.queue_command_master==queue)
end
function tests.throw_conversion_failure_preserves_payload_once()
    local f=throw_fixture();f.env.Vector3=function()error("vector unavailable")end;throw(f)
    assert(f.seen.throw_calls==1 and f.throw_commands[1].payload==f.seen.throw_payload)
end
function tests.throw_never_keeps_engine_vector_temporaries_between_api_calls()
    local f=throw_fixture();local camera_direction=vec(0,0.6,-0.8)
    f.ctl.view.aim_ray=function()return vec(0,0,0),camera_direction end
    local owned=f.env.EntityAux.owned;f.env.EntityAux.owned=function(unit)
        camera_direction.x=99;camera_direction.y=99;camera_direction.z=99;return owned(unit)
    end
    throw(f);same(f.throw_commands[1].payload.direction,0,0.6,-0.8)
end
local function source_fixture()
    local f=fixture();f.player.position=vec(4,5,0);f.muzzle=vec(3.8,5.6,0.45);f.yaw=0
    f.character={health_state={},current_state={}};f.env.EntityAux.state_master=function(u,c)if u==f.player and c=="character"then return f.character end end
    local function rotate(q,v)local c,s=math.cos(q.yaw or 0),math.sin(q.yaw or 0);return vec(v.x*c-v.y*s,v.x*s+v.y*c,v.z)end
    f.env.Quaternion.rotate=rotate;f.env.Quaternion.inverse=function(q)return{yaw=-(q.yaw or 0)}end
    f.env.Quaternion.forward=function(q)return rotate(q,vec(0,1,0))end
    f.env.Unit.world_rotation=function(u,node)return{yaw=u==f.player and f.yaw or 0}end
    f.env.Unit.has_node=function(u,n)return u==f.mine and n=="j_muzzle"end
    f.env.Unit.node=function(u,n)assert(u==f.mine and n=="j_muzzle");return 17 end
    f.env.Unit.world_position=function(u,n)if u==f.mine and n==17 then return clone(f.muzzle)end;return clone(u.position or vec(10,10,0))end
    f.entries={[f.mine]=f.entries[f.mine]};f.offset=vec(0,0,1.5)
    local state=f.entries[f.mine].state;state.ray_source_offset=f.offset;state.last_ray_from=vec(0,0,0)
    f.original=function(component,entries,...)
        f.seen.batches=f.seen.batches+1
        for weapon,entry in pairs(entries)do
            local s=entry.state;local root=f.env.Unit.world_position(f.player,0);local q=f.env.Unit.world_rotation(f.player,s.attach_node)
            local o=f.env.Quaternion.rotate(q,f.env.Vector3Aux.unbox(s.ray_source_offset));local origin=vec(root.x+o.x,root.y+o.y,root.z+o.z)
            local d=f.env.Quaternion.forward(q);d.z=d.z*1.125-s.ray_source_offset.z/(s.range*(s.range_multiplier or 1))
            local n=math.sqrt(d.x*d.x+d.y*d.y+d.z*d.z);d=vec(d.x/n,d.y/n,d.z/n)
            f.env.Vector3Aux.box(s.firedir_override,d);s.rounds=s.rounds-1
            s.raycast_slave:cast(origin,d,100,17,"cast tail");f.env.Vector3Aux.box(s.last_ray_from,origin)
        end
        return"native",nil,"tail"
    end
    return f
end
function tests.native_source_formula_uses_muzzle_and_last_ray_box_without_mutating_shared_default()
    for _,yaw in ipairs({0,1.1})do
        local f=source_fixture();f.yaw=yaw;local s=f.entries[f.mine].state;local ray=s.raycast_slave
        local a,b,c=run(f);same(f.seen.casts[f.mine].origin,3.8,5.6,0.45);same(s.last_ray_from,3.8,5.6,0.45)
        same(f.offset,0,0,1.5);assert(s.ray_source_offset==f.offset and s.raycast_slave==ray and s.rounds==6)
        assert(a=="native"and b==nil and c=="tail"and f.seen.batches==1)
    end
end
function tests.source_offset_restores_after_native_failure_and_invalid_muzzle_keeps_previous_aim()
    local f=source_fixture();local s=f.entries[f.mine].state;local calls=0
    local ok,problem=pcall(f.aim.update,f.aim,function()calls=calls+1;assert(s.ray_source_offset~=f.offset);error("native fail")end,f.component,f.entries)
    assert(not ok and tostring(problem):find("native fail",1,true)and calls==1 and s.ray_source_offset==f.offset);same(f.offset,0,0,1.5)
    for _,mutate in ipairs({function(x)x.env.Unit.has_node=nil end,function(x)x.env.Unit.has_node=function()return false end end,
        function(x)x.env.Unit.world_position=function()error("node unavailable")end end,
        function(x)x.character.health_state.is_downed=true end})do
        f=source_fixture();mutate(f)
        local original=f.original;if not f.env.Unit.has_node or f.character.health_state.is_downed then run(f);same(f.seen.casts[f.mine].origin,4,5,1.5)
        else f.aim:update(function()assert(f.entries[f.mine].state.ray_source_offset==f.offset)end,f.component,f.entries)end
    end
end
function tests.validated_pose_sample_controls_actual_source_and_direction_with_numeric_root()
    local f=source_fixture();f.ctl.pose={shot_sample=function(_,unit,weapon,root)
        assert(unit==f.player and weapon==f.mine);same(root,4,5,0)
        return{origin=vec(4.1,5.3,0.5),direction=vec(0,0.8,0.6)}
    end}
    run(f);same(f.seen.casts[f.mine].origin,4.1,5.3,0.5);same(f.seen.casts[f.mine].direction,0,0.8,0.6)
    local g=source_fixture();g.ctl.pose={shot_sample=function()return{origin=vec(0/0,0,0),direction=vec(0,0,0)}end};run(g)
    same(g.seen.casts[g.mine].origin,3.8,5.6,0.45)
end
local function callback_fixture()
    local f=source_fixture();f.seen.flow={};f.seen.variables={};f.seen.callbacks=0;f.seen.factories=0
    f.flow_parent={set_flow_variable=function(unit,name,value)f.seen.variables[name]=type(value)=="table"and clone(value)or value end,
        flow_event=function(unit,event)f.seen.flow[#f.seen.flow+1]={unit=unit,event=event,position=clone(f.seen.variables.hit_position)};return"flow",nil,"tail"end}
    setmetatable(f.env.Unit,{__index=f.flow_parent})
    f.factory=function(weapon,entry,component,offset,tag)
        f.seen.factories=f.seen.factories+1;assert(weapon==f.mine and entry==f.entries[f.mine]and component==f.component and offset==f.offset and tag=="factory tail")
        return function(hit,id)
            f.seen.callbacks=f.seen.callbacks+1;f.env.Unit.set_flow_variable(weapon,"hit_position",hit and vec(9,8,7)or vec(0,0,999))
            f.env.Unit.set_flow_variable(weapon,"hit",hit);f.env.Unit.set_flow_variable(weapon,"hit_normal",vec(0,0,1))
            f.env.Unit.flow_event(weapon,"on_raycast");return"callback",nil,id
        end,nil,"factory return"
    end
    return f
end
function tests.miss_callback_corrects_only_local_output_before_single_native_flow_and_preserves_factory_returns()
    local f=callback_fixture();local callback,gap,tail=f.aim:callback(f.factory,f.mine,f.entries[f.mine],f.component,f.offset,"factory tail")
    assert(gap==nil and tail=="factory return"and f.seen.factories==1);run(f)
    local a,b,c=callback(false,17);assert(a=="callback"and b==nil and c==17 and f.seen.callbacks==1 and #f.seen.flow==1)
    local cast=f.seen.casts[f.mine];same(f.seen.flow[1].position,cast.origin.x+cast.direction.x*100,cast.origin.y+cast.direction.y*100,cast.origin.z+cast.direction.z*100)
    callback(true,18);same(f.seen.flow[2].position,9,8,7)
    assert(rawget(f.env.Unit,"flow_event")==nil and rawget(f.env.Unit,"set_flow_variable")==nil)
end
function tests.miss_callback_stale_context_and_native_failures_never_redirect_or_retry()
    for _,kind in ipairs({"off","owner","stateptr","alias","native","setter","midcall"})do
        local f=callback_fixture();if kind=="alias"then f.muzzle=vec(4,5,1.5)end
        local callback=f.aim:callback(f.factory,f.mine,f.entries[f.mine],f.component,f.offset,"factory tail");run(f)
        if kind=="off"then f.ctl.enabled=false elseif kind=="owner"then f.ctl.local_unit={alive=true}
        elseif kind=="stateptr"then local replacement={};for k,v in pairs(f.entries[f.mine].state)do replacement[k]=v end;f.entries[f.mine].state=replacement
        elseif kind=="alias"then f.entries[f.remote]={state=f.entries[f.mine].state};run(f)
        elseif kind=="native"then f.flow_parent.flow_event=function()error("flow failed")end
        elseif kind=="midcall"then local setter=f.flow_parent.set_flow_variable;f.flow_parent.set_flow_variable=function(unit,key,value)
            if key=="hit"then f.ctl.enabled=false end;return setter(unit,key,value)
        end
        else local setter=f.flow_parent.set_flow_variable;f.flow_parent.set_flow_variable=function(unit,key,value)
            if key=="hit_position"and value.z~=999 then error("corrector failed")end;return setter(unit,key,value)
        end end
        local good,problem=pcall(callback,false,17);assert(f.seen.callbacks==1 and f.seen.factories==1)
        if kind=="native"then assert(not good and tostring(problem):find("flow failed",1,true))else assert(good)end
        if kind=="off"or kind=="owner"or kind=="stateptr"or kind=="alias"or kind=="setter"or kind=="midcall"then same(f.seen.flow[1].position,0,0,999)end
        assert(rawget(f.env.Unit,"flow_event")==nil and rawget(f.env.Unit,"set_flow_variable")==nil)
    end
end
function tests.miss_callback_nested_same_weapon_and_health_changes_never_inherit_outer_redirection()
    local f=callback_fixture();local native=f.factory;local nested,inside
    f.factory=function(...)
        local original=select(1,native(...))
        return function(...)
            if not inside then inside=true;nested(false,19);inside=false end
            return original(...)
        end
    end
    nested=f.aim:callback(f.factory,f.mine,f.entries[f.mine],f.component,f.offset,"factory tail");run(f)
    nested(false,17);assert(#f.seen.flow==2);same(f.seen.flow[1].position,0,0,999)
    local cast=f.seen.casts[f.mine];same(f.seen.flow[2].position,cast.origin.x+cast.direction.x*100,cast.origin.y+cast.direction.y*100,cast.origin.z+cast.direction.z*100)
    for _,flag in ipairs({"is_dead","is_downed"})do
        local g=callback_fixture();local cb=g.aim:callback(g.factory,g.mine,g.entries[g.mine],g.component,g.offset,"factory tail");run(g)
        g.character.health_state[flag]=true;cb(false,17);same(g.seen.flow[1].position,0,0,999)
    end
end
local total,failures=0,0
for name,test in pairs(tests)do total=total+1;local ok,problem=pcall(test)
    if ok then print("PASS "..name)else failures=failures+1;print("FAIL "..name..": "..tostring(problem))end
end
print(string.format("%d aim tests, %d failures",total,failures));assert(failures==0)
