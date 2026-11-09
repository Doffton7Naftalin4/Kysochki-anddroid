-- Engine APIs are external; all units and state below are synthetic.
local loaded,Actions=pcall(dofile,"actions.lua")
assert(loaded and type(Actions.new)=="function","Actions.new module must exist")
local function fixture()
    local player,weapon,friend,foreign={alive=true},{alive=true},{alive=true},{alive=true}
    local states={Idle={},Fire={},AimFire={},WalkFire={},AimWalkFire={},Dodge={},Crawl={},Downed={},Jump={},Map={}}
    local seen={calls={},batches=0,logs={}}
    local weapon_state={semi_automatic=true,fully_automatic=true,assisted_reload=false,reloadable=true,is_reloading=false,reload_time=0,rounds=7,num_mags=3}
    local equipment={wielder=player}
    local input={fire=false,fire_auto=false,reload=false}
    local character={input=input,current_state=states.Dodge,health_state={is_dead=false,is_downed=false,is_dodging=true},
        is_dead=false,is_downed=false,current_weapon=weapon,inventory_state={current_weapon=weapon},
        dive_timer=0.2,dive_get_up=false,sprint_stamina=9,mover_state={lock_direction=true,constant_movement=true,ignore_slow=true}}
    local input_state={pad_number=0,has_focus=true,input_data={is_active=true}}
    local env={KEYBOARD_MOUSE_PAD_NUMBER=0,CameraManager={state="follow",targets={[player]={}}},
        Unit={alive=function(u)return u and u.alive end},EntityAux={}}
    for name,state in pairs(states)do env["CharacterState"..name]=state end
    env.EntityAux.owned=function(u)return u==weapon end
    env.EntityAux.has_component=function(u,kind)return u==weapon and(kind=="firearm"or kind=="equipment")end
    env.EntityAux.state=function(u,kind)if u==weapon and kind=="equipment"then return equipment end end
    env.EntityAux.state_master_interface=function(u,kind)if u==weapon and kind=="weapon"then return weapon_state end end
    env.EntityAux.queue_command_master_interface=function(u,kind,command,...)
        assert(kind=="weapon");seen.calls[#seen.calls+1]={unit=u,command=command,n=select("#",...),payload=(...)}
    end
    local ctl={enabled=true,local_unit=player,view={mode="top",input_context={unit=player,state=input_state,component={current_state="game"}}}}
    function ctl:active_local_unit(manager)return self.enabled and manager.state=="follow"and manager.targets[self.local_unit]and self.local_unit or nil end
    function ctl:log(line)seen.logs[#seen.logs+1]=line end
    local entries={[player]={state=character},[friend]={state={input={fire=true,fire_auto=true,reload=true},current_state=states.Dodge,current_weapon=foreign}}}
    local component={}
    local function original(self,batch,dt,tail)
        seen.batches=seen.batches+1;seen.batch=batch;seen.component=self;seen.dt=dt;seen.tail=tail
        character.dive_timer=character.dive_timer+dt
        if seen.native then seen.native(batch)end
        return "native",nil,"tail"
    end
    return {env=env,ctl=ctl,seen=seen,player=player,weapon=weapon,foreign=foreign,entries=entries,component=component,
        character=character,input=input,input_state=input_state,weapon_state=weapon_state,equipment=equipment,states=states,
        original=original,actions=Actions.new(env,ctl,{})}
end
local function run(f)return f.actions:character_update(f.original,f.component,f.entries,0.1,"arg")end
local function commands(f,name)local out={}for _,call in ipairs(f.seen.calls)do if call.command==name then out[#out+1]=call end end return out end
local function reset(f)f.seen.calls={}end
local tests={}
function tests.dive_fire_uses_original_weapon_commands_after_one_native_batch()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true
    local a,b,c=run(f)
    local single,auto=commands(f,"firing_single"),commands(f,"firing_auto")
    assert(#single==1 and single[1].unit==f.weapon and single[1].n==0,"native single has no payload")
    assert(#auto==1 and auto[1].unit==f.weapon and auto[1].n==1 and auto[1].payload==true)
    assert(a=="native"and b==nil and c=="tail")
    assert(f.seen.batches==1 and f.seen.batch==f.entries and f.seen.component==f.component and f.seen.dt==0.1 and f.seen.tail=="arg")
end
function tests.crawl_reload_uses_native_eligibility_and_keeps_locomotion_state()
    local f=fixture();f.character.current_state=f.states.Crawl;f.input.reload=true;run(f)
    local reload=commands(f,"reload");assert(#reload==1 and reload[1].unit==f.weapon and reload[1].n==0)
    assert(f.character.current_state==f.states.Crawl and f.character.dive_timer>0.29)
    assert(f.character.health_state.is_dodging and not f.character.health_state.is_downed and f.character.sprint_stamina==9)
    assert(f.weapon_state.rounds==7 and f.weapon_state.num_mags==3,"bridge cannot write native ammunition")
end
function tests.held_semiauto_is_not_repeated_and_release_rearms_edge()
    local f=fixture();f.input.fire=true;run(f);run(f);run(f)
    assert(#commands(f,"firing_single")==1)
    f.input.fire=false;run(f);f.input.fire=true;run(f);assert(#commands(f,"firing_single")==2)
end
function tests.fire_edge_is_tracked_while_native_states_own_the_weapon()
    local f=fixture();f.character.current_state=f.states.Idle;f.input.fire=true;run(f);reset(f)
    f.character.current_state=f.states.Dodge;run(f)
    assert(#commands(f,"firing_single")==0,"held trigger on dive entry must not create another semiauto shot")
    f.input.fire=false;run(f);f.input.fire=true;run(f);assert(#commands(f,"firing_single")==1)
end
function tests.reload_wins_over_fire_and_stops_previous_auto_first()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;run(f);reset(f);f.input.reload=true;run(f)
    assert(#commands(f,"reload")==1 and #commands(f,"firing_single")==0)
    assert(f.seen.calls[1].command=="firing_auto"and f.seen.calls[1].payload==false and f.seen.calls[2].command=="reload")
end
function tests.native_reloading_blocks_fire_and_duplicate_reload()
    for _,field in ipairs({"is_reloading","reload_time"})do
        local f=fixture();f.weapon_state[field]=field=="is_reloading"and true or 0.5
        f.input.fire=true;f.input.fire_auto=true;f.input.reload=true;run(f)
        assert(#commands(f,"firing_single")==0 and #commands(f,"reload")==0)
        for _,call in ipairs(commands(f,"firing_auto"))do assert(call.payload==false)end
    end
end
function tests.nonreloadable_and_assisted_weapons_keep_native_restrictions()
    local f=fixture();f.weapon_state.reloadable=false;f.input.reload=true;run(f);assert(#commands(f,"reload")==0)
    local g=fixture();g.weapon_state.assisted_reload=true;g.input.fire=true;g.input.fire_auto=true;g.input.reload=true;run(g)
    assert(#g.seen.calls==0)
end
function tests.remote_enemy_and_nonfirearm_weapons_receive_no_extra_commands()
    local f=fixture();run(f);for _,call in ipairs(f.seen.calls)do assert(call.unit==f.weapon)end
    f.env.EntityAux.has_component=function(u,kind)return kind=="equipment"end;f.input.fire=true;f.input.reload=true;reset(f);run(f)
    assert(#f.seen.calls==0)
end
function tests.health_context_and_ownership_restrictions_fail_closed()
    for _,mutate in ipairs({function(f)f.character.health_state.is_downed=true end,function(f)f.character.is_downed=true end,
        function(f)f.character.health_state.is_dead=true end,function(f)f.character.current_seat_unit={alive=true}end,
        function(f)f.character.current_state=f.states.Jump end,function(f)f.character.current_state=f.states.Map end,
        function(f)f.input_state.pad_number=1 end,function(f)f.input_state.has_focus=false end,
        function(f)f.input_state.input_data.is_active=false end,function(f)f.input_state.character_input_disabled=true end,
        function(f)f.env.EntityAux.owned=function()return false end end,function(f)f.equipment.wielder={}end,
        function(f)f.ctl.view.input_context.component.current_state="menu"end,function(f)f.ctl.enabled=false end})do
        local f=fixture();mutate(f);f.input.fire=true;f.input.fire_auto=true;f.input.reload=true;run(f)
        assert(#f.seen.calls==0 and f.seen.batches==1)
    end
end
function tests.mod_off_and_focus_loss_stop_owned_auto_before_original()
    for _,mutate in ipairs({function(f)f.ctl.enabled=false end,function(f)f.input_state.has_focus=false end})do
        local f=fixture();f.input.fire=true;f.input.fire_auto=true;run(f);reset(f);mutate(f)
        f.seen.native=function()assert(f.seen.calls[1]and f.seen.calls[1].command=="firing_auto"and f.seen.calls[1].payload==false)end
        run(f);assert(#f.seen.calls==1)
    end
end
function tests.native_fire_handoff_is_not_cancelled_after_the_original_batch()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;run(f);reset(f)
    f.seen.native=function()
        f.character.current_state=f.states.AimFire
        f.env.EntityAux.queue_command_master_interface(f.weapon,"weapon","firing_auto",true)
    end
    run(f)
    assert(#f.seen.calls==1 and f.seen.calls[1].payload==true,"post hook cannot cancel native autofire")
end
function tests.weapon_change_stops_only_previously_owned_weapon()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;run(f);reset(f)
    f.character.current_weapon=f.foreign;f.character.inventory_state.current_weapon=f.foreign
    run(f);assert(#f.seen.calls==1 and f.seen.calls[1].unit==f.weapon and f.seen.calls[1].payload==false)
    local g=fixture();g.input.fire=true;g.input.fire_auto=true;run(g);reset(g);g.env.EntityAux.owned=function()return false end
    run(g);assert(#g.seen.calls==0,"loot transferred to another owner must not receive cleanup commands")
end
function tests.original_health_transition_has_priority_over_new_actions()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;f.input.reload=true
    f.seen.native=function()f.character.current_state=f.states.Downed;f.character.health_state.is_downed=true end
    run(f);assert(#f.seen.calls==0)
end
function tests.original_exception_is_never_retried()
    local f=fixture();local attempts=0
    local ok,problem=pcall(f.actions.character_update,f.actions,function()attempts=attempts+1;error("native failure")end,f.component,f.entries,0.1)
    assert(not ok and tostring(problem):find("native failure",1,true)and attempts==1 and #f.seen.calls==0)
end
function tests.command_exception_does_not_retry_single_or_cancel_native_update_result()
    local f=fixture();local attempts=0;f.input.fire=true
    f.env.EntityAux.queue_command_master_interface=function(_,_,command)if command=="firing_single"then attempts=attempts+1;error("queue failure")end end
    local a,b,c=run(f);run(f)
    assert(a=="native"and b==nil and c=="tail"and attempts==1 and f.seen.batches==2)
end
function tests.same_state_alias_does_not_grant_remote_entry_actions()
    local f=fixture();local remote={alive=true};f.entries[remote]={state=f.character};f.input.fire=true;f.input.fire_auto=true
    run(f);assert(#f.seen.calls==0,"ambiguous shared character state must fail closed")
end
function tests.held_reload_does_not_restart_native_duration_each_frame()
    local f=fixture();f.input.reload=true;run(f);run(f);run(f)
    assert(#commands(f,"reload")==1)
    f.input.reload=false;run(f);f.input.reload=true;run(f);assert(#commands(f,"reload")==2)
end
function tests.master_reload_state_wins_over_unreloading_slave_snapshot()
    local f=fixture();local generic=f.env.EntityAux.state
    f.env.EntityAux.state=function(unit,kind)if unit==f.weapon and kind=="weapon"then return{reloadable=true,is_reloading=false,reload_time=0}end return generic(unit,kind)end
    f.weapon_state.is_reloading=true;f.input.fire=true;f.input.fire_auto=true;run(f)
    assert(#commands(f,"firing_single")==0);for _,call in ipairs(commands(f,"firing_auto"))do assert(call.payload==false)end
end
function tests.downed_health_during_apparent_native_fire_handoff_still_stops_auto()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;run(f);reset(f)
    f.seen.native=function()f.character.current_state=f.states.AimFire;f.character.health_state.is_downed=true end
    run(f);assert(#f.seen.calls==1 and f.seen.calls[1].command=="firing_auto"and f.seen.calls[1].payload==false)
end
function tests.native_exception_with_active_auto_cleans_up_without_replaying_batch()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;run(f);reset(f)
    local attempts=0;local ok,problem=pcall(f.actions.character_update,f.actions,function()attempts=attempts+1;error("partial native failure")end,f.component,f.entries,0.1)
    assert(not ok and tostring(problem):find("partial native failure",1,true)and attempts==1)
    assert(#f.seen.calls==1 and f.seen.calls[1].payload==false)
end
function tests.pending_state_transition_prevents_dispatch_without_changing_transition()
    local f=fixture();f.input.fire=true;f.input.fire_auto=true;f.character.new_state=f.states.Downed
    run(f);assert(#f.seen.calls==0 and f.character.new_state==f.states.Downed)
end
function tests.focus_return_with_held_trigger_does_not_create_a_new_semiauto_edge()
    local f=fixture();f.input.fire=true;run(f);f.input_state.has_focus=false;run(f);reset(f)
    f.input_state.has_focus=true;run(f);assert(#commands(f,"firing_single")==0)
end
local total,failures=0,0
for name,test in pairs(tests)do total=total+1;local ok,problem=pcall(test)
    if ok then print("PASS "..name)else failures=failures+1;print("FAIL "..name..": "..tostring(problem))end
end
print(string.format("%d actions tests, %d failures",total,failures));assert(failures==0)
