-- Reuse the native radio/flare states from voluntary Crawl.
-- Code recognition, health, flare creation, cooldowns and uses stay native.
local Stratagems={}
local function pack(...)return{n=select("#",...),...}end
local function finite(n)return type(n)=="number"and n==n and math.abs(n)<math.huge end
local binding_functions={button=true,pressed=true,released=true,sc_button=true,axis=true,filter=true}

function Stratagems.new(env,ctl,config)
    local bridge={noted={},trace_count=0,trace_last={}}
    local function note(key,message)
        if bridge.noted[key]then return end
        bridge.noted[key]=true
        if type(ctl.log)=="function"then pcall(ctl.log,ctl,"Prone stratagems: "..message)end
    end
    local function healthy(state)
        local health=state and state.health_state
        return type(health)=="table"and not health.is_dead and not health.is_downed and not state.is_dead and not state.is_downed
            and not state.has_extracted and not state.do_knockdown
    end
    local function animation_context(dirty)
        if not ctl.enabled then return false,"off"end
        if env.Window and type(env.Window.has_focus)=="function"and env.Window.has_focus()~=true then return false,"window"end
        if ctl.local_unit~=dirty.unit then return false,"local"end
        if not env.Unit or type(env.Unit.alive)~="function"or env.Unit.alive(dirty.unit)~=true then return false,"unit"end
        if type(ctl.active_local_unit)~="function"or ctl:active_local_unit(env.CameraManager)~=dirty.unit then return false,"active"end
        if dirty.world and(not ctl.view or not ctl.view.owned or ctl.view.owned.world~=dirty.world)then return false,"world"end
        local entity,state=env.EntityAux,dirty.state
        if not entity or type(entity.state_master)~="function"or entity.state_master(dirty.unit,"character")~=state then return false,"masterptr"end
        if not healthy(state)then return false,"health"end
        local current=state.current_state
        if not current or(current~=env.CharacterStateStratagems and current~=env.CharacterStateStratagemsThrow
            and current~=env.CharacterStateCrawl)then return false,"state"end
        if type(state.input)~="table"or state.input.dodge~=true or state.dive_get_up then return false,"released"end
        if(state.current_seat_unit and env.Unit.alive(state.current_seat_unit))
            or(state.current_carry_unit and env.Unit.alive(state.current_carry_unit))then return false,"seat_carry"end
        local context=ctl.view and ctl.view.input_context
        local input=context and context.state
        local component=context and context.component
        if not context or context.unit~=dirty.unit or type(input)~="table"or input.pad_number~=(env.KEYBOARD_MOUSE_PAD_NUMBER or 0)or not input.has_focus
            or not input.input_data or not input.input_data.is_active or input.character_input_disabled or input.mouse_aim_disabled
            or input.input_filter~=nil or type(component)~="table"or(component.current_state~="game"and component.current_state~="tutorial")then
            return false,"input"
        end
        return true
    end
    local function discard_animation(reason)
        bridge.animation_dirty=nil
        note("animation_skip_"..reason,"native animation cache refresh skipped: "..reason)
    end
    local function cleanup_animation()
        local dirty=bridge.animation_dirty
        if not dirty then return end
        local good,allowed,reason=pcall(animation_context,dirty)
        if not good or not allowed then discard_animation(good and reason or"context_error")end
    end
    local function mark_animation(session,reason)
        local dirty={unit=session.unit,state=session.state,world=session.world,reason=reason,ttl=8}
        local good,allowed=pcall(animation_context,dirty)
        if good and allowed then bridge.animation_dirty=dirty end
    end
    local animation_boundaries={radio_activate=true,radio_deactivate=true,grenade_pull=true,grenade_throw=true}
    local function graph_snapshot(unit)
        local good,value=pcall(function()
            local api=env.Unit
            if not api or type(api.animation_get_state)~="function"then return"unavailable"end
            if type(api.alive)~="function"or api.alive(unit)~=true then return"unit_unavailable"end
            local result=pack(api.animation_get_state(unit));local values={}
            for i=1,result.n do values[i]=tostring(result[i])end
            return"n="..result.n.."["..table.concat(values,",").."]"
        end)
        return good and value or"getter_error"
    end
    local function graph_layers(unit)
        local api=env.Unit
        if not api or type(api.animation_get_state)~="function"then return nil end
        local values=pack(api.animation_get_state(unit))
        -- Pinned HD1 player controller: nine layers; fullbody is the fifth.
        if values.n~=9 then return nil end
        local counts={69,93,191,5,98,23,5,20,4}
        for i=1,values.n do
            local value=values[i]
            if value~=nil and(not finite(value)or value<0 or value>=counts[i]or value%1~=0)then return nil end
        end
        return values
    end
    local function capture_prone_layer(session)
        if not env.Unit or type(env.Unit.animation_set_state)~="function"then return nil end
        local good,allowed=pcall(animation_context,session)
        if not good or not allowed then return nil end
        local values=graph_layers(session.unit)
        if values and(values[5]==45 or values[5]==46)then return values[5]end
    end
    local function restore_prone_layer(session,prone)
        if prone~=45 and prone~=46 then return false end
        local valid,allowed=pcall(animation_context,session)
        if not valid or not allowed then return true end
        local api=env.Unit
        if not api or type(api.animation_set_state)~="function"then return false end
        local values=graph_layers(session.unit)
        if not values then return false end
        if values[5]==45 or values[5]==46 then return true end
        if values[5]~=9 and values[5]~=10 and values[5]~=11 then return false end
        local checked,still_allowed=pcall(animation_context,session)
        if not checked or not still_allowed then return true end
        -- Keep CURRENT other layers, not the pre-radio arm/weapon snapshot.
        -- Native setter is used by CharacterComponent.rpc_animation_state.
        values[5]=prone
        local applied=pcall(api.animation_set_state,session.unit,unpack(values,1,values.n))
        if(bridge.graph_pairs or 0)<6 then
            bridge.graph_pairs=(bridge.graph_pairs or 0)+1
            local actual=graph_snapshot(session.unit)
            if type(ctl.log)=="function"then pcall(ctl.log,ctl,"Prone stratagems graph snapshot: target="..prone
                .." actual="..actual.." status="..(applied and"restored"or"setter_error"))end
        end
        -- An attempted setter is authoritative even if it raised after a
        -- partial native write. Never retry it or follow with dive events.
        return true
    end
    local function graph_reentry(session)
        local valid,allowed,reason=pcall(animation_context,session)
        if not valid or not allowed then return end
        local api=env.Unit
        if type(api.animation_event)~="function"or type(api.has_animation_event)~="function"then
            note("graph_api","local graph reentry skipped: event API unavailable");return
        end
        local queried,supported=pcall(function()
            return api.has_animation_event(session.unit,"roll_forward")==true and api.has_animation_event(session.unit,"roll_forward_idle")==true
        end)
        if not queried or not supported then note("graph_events","local graph reentry skipped: native events unavailable");return end
        local capture=(bridge.graph_pairs or 0)<6
        local before
        if capture then bridge.graph_pairs=(bridge.graph_pairs or 0)+1;before=graph_snapshot(session.unit)end
        -- Direct local graph events only. The original radio event has already
        -- completed its native RPC/Unit/flow path. Never call Dodge handlers.
        local first=pcall(api.animation_event,session.unit,"roll_forward")
        local status="first_error"
        if first then
            local checked,still_allowed=pcall(animation_context,session)
            if checked and still_allowed then
                local second=pcall(api.animation_event,session.unit,"roll_forward_idle")
                status=second and"dispatched"or"second_error"
            else status="context_changed"end
        end
        if capture then
            local after=graph_snapshot(session.unit)
            if type(ctl.log)=="function"then pcall(ctl.log,ctl,"Prone stratagems graph: before="..before.." after="..after.." status="..status)end
        end
        if status=="dispatched"then note("graph_reentry","local prone graph reentry dispatched after native radio_activate")
        else note("graph_failure_"..status,"local prone graph reentry stopped: "..status)end
    end
    local function animation_factory(session)
        return function(original)
            return function(unit,event,...)
                local prone
                if unit==session.unit and event=="radio_activate"then
                    local good,value=pcall(capture_prone_layer,session)
                    if good then prone=value end
                end
                local result=pack(original(unit,event,...))
                if unit==session.unit and animation_boundaries[event]then
                    mark_animation(session,event)
                    if event=="radio_activate"then
                        local checked,handled=pcall(restore_prone_layer,session,prone)
                        if not checked or not handled then
                            local good=pcall(graph_reentry,session)
                            if not good then note("graph_error","local graph reentry skipped after an API error")end
                        end
                    end
                end
                return unpack(result,1,result.n)
            end
        end
    end
    local function trace(stage,unit,entry,next_state)
        -- Observation only. Even a failing getter/logger must not interrupt
        -- the native state handler or change the command/event sequence.
        pcall(function()
            if bridge.trace_count>=40 or type(ctl.log)~="function"then return end
            local state=type(entry)=="table"and entry.state
            if type(state)~="table"then return end
            local input=type(state.input)=="table"and state.input or{}
            local source=state.input_state
            if type(source)~="table"or type(source.input_data)~="table"then
                local context=ctl.view and ctl.view.input_context
                source=context and context.unit==unit and context.state or nil
            end
            local raw=type(source)=="table"and source.input_data
            local raw_dodge,focus,active,window_focus
            if type(raw)=="table"then raw_dodge=raw.dodge_pressed;active=raw.is_active end
            if type(source)=="table"then focus=source.has_focus end
            if env.Window and type(env.Window.has_focus)=="function"then
                local good,value=pcall(env.Window.has_focus)
                if good then window_focus=value else window_focus="error"end
            end
            local health=type(state.health_state)=="table"and state.health_state or{}
            local function name(value)return type(value)=="table"and value.name or nil end
            local sticky
            if stage=="flow:start"or stage=="crawl:return"then
                local rebinder=env.InputRebinder
                if rebinder and type(rebinder.get)=="function"then
                    local bindings=rebinder:get("keyboard_mouse")
                    if type(bindings)=="table"then for _,binding in ipairs(bindings)do
                        if type(binding)=="table"and binding.output_name=="dodge_pressed"then
                            if type(binding.input)=="table"then sticky=binding.input.start_sticky end;break
                        end
                    end end
                end
            end
            local line="stage="..stage.." current="..tostring(name(state.current_state)).." pending="..tostring(name(state.new_state))
                .." next="..tostring(name(next_state)).." input_dodge="..tostring(input.dodge)
                .." raw_dodge="..tostring(raw_dodge).." focus="..tostring(focus).." window_focus="..tostring(window_focus)
                .." active="..tostring(active)
                .." health_dodge="..tostring(health.is_dodging).." dive_get_up="..tostring(state.dive_get_up)
                .." dive_timer="..tostring(state.dive_timer).." start_sticky="..tostring(sticky)
            if bridge.trace_last[stage]==line then return end
            bridge.trace_last[stage]=line;bridge.trace_count=bridge.trace_count+1
            ctl:log("Prone stratagems trace: "..line)
        end)
    end
    local function return_observer(unit,entry)
        local watch=bridge.return_observer
        if not watch then return nil end
        local good,valid=pcall(function()
            if ctl.local_unit~=watch.unit or not env.Unit or type(env.Unit.alive)~="function"or env.Unit.alive(watch.unit)~=true
                or not healthy(watch.state)or watch.state.current_state~=env.CharacterStateCrawl then return false end
            if watch.world and(not ctl.view or not ctl.view.owned or ctl.view.owned.world~=watch.world)then return false end
            if unit==watch.unit and type(entry)=="table"and entry.state~=watch.state then return false end
            return true
        end)
        if not good or not valid then bridge.return_observer=nil;return nil end
        return watch
    end
    local function cleanup(unit,entry)
        local session=bridge.session
        if not session then return end
        local same=ctl.local_unit==session.unit and env.Unit and type(env.Unit.alive)=="function"
        local reason=ctl.local_unit~=session.unit and"local"or"unit_api"
        if same then local good,alive=pcall(env.Unit.alive,session.unit);same=good and alive==true;reason=good and"unit_dead"or"unit_error"end
        if same and ctl.enabled and type(ctl.active_local_unit)=="function"then
            local good,active=pcall(ctl.active_local_unit,ctl,env.CameraManager);same=good and active==session.unit;reason=good and"active"or"active_error"
        end
        if same and session.world then
            local owned=ctl.view and ctl.view.owned
            same=owned~=nil and owned.world==session.world;reason="world"
        end
        if same and unit==session.unit and type(entry)=="table"and entry.state~=session.state then same=false;reason="stateptr"end
        if not same then
            -- Teardown or a new local master owns any old pending flare. Do
            -- not cancel, throw or issue commands against that old world/unit.
            bridge.session=nil
            trace("cleanup:"..reason,session.unit,{state=session.state})
            note("stale","old local/world session released without touching its flare")
        end
    end
    local function session_for(unit,entry)
        cleanup(unit,entry)
        local session=bridge.session
        return session and session.unit==unit and type(entry)=="table"and entry.state==session.state and session or nil
    end
    local function invoke(overrides,original,...)
        local snapshots={}
        for _,spec in ipairs(overrides)do
            local object,key,factory=spec[1],spec[2],spec[3]
            snapshots[#snapshots+1]={object=object,key=key,owned=rawget(object,key)}
            rawset(object,key,factory(object[key]))
        end
        local result=pack(pcall(original,...))
        for i=#snapshots,1,-1 do local saved=snapshots[i];rawset(saved.object,saved.key,saved.owned)end
        if not result[1]then error(result[2],0)end
        return unpack(result,2,result.n)
    end
    local function reset_names()
        local rebinder=env.InputRebinder
        local classes=env.InputFilterClasses
        if not rebinder or type(rebinder.get)~="function"or type(classes)~="table"then return nil end
        local list=rebinder:get("keyboard_mouse")
        if type(list)~="table"or #list==0 then return nil end
        local rows=0
        for key in pairs(list)do
            if not finite(key)or key<1 or key%1~=0 or key>#list then return nil end
            rows=rows+1
        end
        if rows~=#list then return nil end
        local names,seen={},{}
        for _,binding in ipairs(list)do
            if type(binding)~="table"or not binding_functions[binding.func]
                or type(binding.output_name)~="string"or binding.output_name==""then return nil end
            if binding.func=="filter"then
                if type(binding.key)~="string"or binding.key==""or type(binding.input)~="table"then return nil end
                local class=classes[binding.key]
                if type(class)~="table"then return nil end
                local resettable=type(class.reset)=="function"
                if(binding.output_name=="dodge_pressed"or binding.output_name=="stratagems_pressed")and(binding.key~="FilterSticky"or not resettable)then return nil end
                if not seen[binding.output_name]then
                    seen[binding.output_name]=true
                    -- Native reset_all_filters skips stateless classes. A named
                    -- reset_filter calls :reset directly, so preserve that guard.
                    if resettable and binding.output_name~="dodge_pressed"then names[#names+1]=binding.output_name end
                end
            end
        end
        if not seen.dodge_pressed or not seen.stratagems_pressed then return nil end
        return names
    end
    local function ready(unit,entry)
        if not ctl.enabled or type(ctl.active_local_unit)~="function"or ctl:active_local_unit(env.CameraManager)~=unit then return nil end
        local context=ctl.view and ctl.view.input_context
        local input=context and context.state
        local component=context and context.component
        if not context or context.unit~=unit or type(component)~="table"or(component.current_state~="game"and component.current_state~="tutorial")
            or type(input)~="table"or input.pad_number~=(env.KEYBOARD_MOUSE_PAD_NUMBER or 0)or not input.has_focus
            or not input.input_data or not input.input_data.is_active or input.character_input_disabled or input.mouse_aim_disabled
            or input.input_filter~=nil then return nil end
        local state=type(entry)=="table"and entry.state
        if type(state)~="table"or not healthy(state)or state.new_state~=nil or state.current_state~=env.CharacterStateCrawl
            or type(state.input)~="table"or not state.input.stratagems or not state.input.dodge or state.dive_get_up then return nil end
        local unit_api,entity,sm,sub=env.Unit,env.EntityAux,env.CharacterStateMachine,env.CharacterSubstateMachine
        if not unit_api or type(unit_api.alive)~="function"or not unit_api.alive(unit)
            or(state.current_seat_unit and unit_api.alive(state.current_seat_unit))
            or(state.current_carry_unit and unit_api.alive(state.current_carry_unit))then return nil end
        if not entity or type(entity.queue_command_master)~="function"or type(entity.command_master_immediately)~="function"
            or not sm or type(sm.change_state)~="function"or type(sm.animation_event)~="function"
            or not sub or type(sub.change_state)~="function"then return nil end
        for _,name in ipairs({"CharacterStateCrawl","CharacterStateStratagems","CharacterStateStratagemsThrow"})do
            local class=env[name]
            if not class or type(class.on_enter)~="function"or type(class.update)~="function"or type(class.on_exit)~="function"then return nil end
        end
        if not env.CharacterSubstateCrawl then return nil end
        local info=entry.settings and entry.settings.character_info
        if not info or not finite(info.move_speed_crawl)or info.move_speed_crawl<0 then return nil end
        local names=reset_names()
        if not names then note("bindings","skipped: complete native filter list unavailable");return nil end
        local owned=ctl.view and ctl.view.owned
        return{unit=unit,state=state,resets=names,crawl_speed=info.move_speed_crawl,world=owned and owned.world}
    end
    local function command_factory(session,skip_all)
        return function(original)
            return function(unit,kind,command,payload,...)
                if unit==session.unit and kind=="input"then
                    if command=="reset_filter"and payload=="dodge_pressed"then return end
                    if skip_all and command=="reset_all_filters"then
                        for _,name in ipairs(session.resets)do original(unit,kind,"reset_filter",name)end
                        return
                    end
                end
                return original(unit,kind,command,payload,...)
            end
        end
    end
    local function overlays(session,remap_idle)
        local list={{env.CharacterSubstateMachine,"change_state",function(original)
            return function(unit,entry,next_state,...)
                if unit==session.unit and entry.state==session.state and(next_state==env.CharacterSubstateIdle
                    or next_state==env.CharacterSubstateWalk or next_state==env.CharacterSubstateJog)then next_state=env.CharacterSubstateCrawl end
                return original(unit,entry,next_state,...)
            end
        end},{env.CharacterStateMachine,"animation_event",animation_factory(session)}}
        if remap_idle then list[#list+1]={env.CharacterStateMachine,"change_state",function(original)
            return function(unit,entry,next_state,...)
                if unit==session.unit and entry.state==session.state and healthy(session.state)and next_state==env.CharacterStateIdle then
                    next_state=env.CharacterStateCrawl
                end
                return original(unit,entry,next_state,...)
            end
        end}end
        return list
    end
    local function clamp_speed(session,kind)
        local speed=session.state.wanted_move_speed
        if finite(speed)and speed>0 then session.state.wanted_move_speed=kind=="radio"and 0 or math.min(speed,session.crawl_speed)end
    end
    function bridge:prone(unit)
        cleanup()
        local session=self.session
        if not session or session.unit~=unit or not healthy(session.state)or not env.Unit or type(env.Unit.alive)~="function"
            or(session.state.current_state~=env.CharacterStateStratagems and session.state.current_state~=env.CharacterStateStratagemsThrow)then return false end
        local good,alive=pcall(env.Unit.alive,unit)
        return good and alive==true or false
    end
    function bridge:crawl_update(original,unit,entry,dt,component,...)
        return_observer(unit,entry)
        cleanup(unit,entry)
        local result=pack(original(unit,entry,dt,component,...))
        local watch=return_observer(unit,entry)
        if watch and unit==watch.unit and entry.state==watch.state then
            trace("crawl:return",unit,entry)
            watch.remaining=watch.remaining-1
            if watch.remaining<=0 or watch.state.new_state~=nil then self.return_observer=nil end
        end
        if not self.session then
            local good,session=pcall(ready,unit,entry)
            if good and session then
                self.session=session
                self.return_observer=nil
                trace("flow:start",unit,entry)
                local changed,problem=pcall(env.CharacterStateMachine.change_state,unit,entry,env.CharacterStateStratagems)
                if not changed then self.session=nil;error(problem,0)end
                note("active","native radio/flare lifecycle entered from voluntary Crawl; visual posture pending")
            elseif not good then note("prepare","skipped after native Crawl update: "..tostring(session))end
        end
        return unpack(result,1,result.n)
    end
    function bridge:crawl_exit(original,unit,entry,next_state,...)
        local session=session_for(unit,entry)
        if not session or not healthy(session.state)or next_state~=env.CharacterStateStratagems then return original(unit,entry,next_state,...)end
        local list={{env.CharacterStateMachine,"animation_event",function(native)
            return function(target,event,...)
                if target==unit and event=="no_animation_fullbody"then return end
                return native(target,event,...)
            end
        end},{env.EntityAux,"command_master_immediately",command_factory(session,false)},
            {env.EntityAux,"queue_command_master",command_factory(session,false)}}
        return invoke(list,original,unit,entry,next_state,...)
    end
    function bridge:enter(kind,original,unit,entry,...)
        local session=session_for(unit,entry)
        if not session or not healthy(session.state)then return original(unit,entry,...)end
        local result=pack(invoke(overlays(session,false),original,unit,entry,...))
        clamp_speed(session,kind)
        trace(kind..":enter",unit,entry)
        note(kind,"native "..kind.." lifecycle active; visual posture pending")
        return unpack(result,1,result.n)
    end
    function bridge:update(kind,original,unit,entry,...)
        local session=session_for(unit,entry)
        if not session then return original(unit,entry,...)end
        if not ctl.enabled then note("drain","disabled: waiting for the native radio/flare lifecycle to finish")end
        if not healthy(session.state)then return original(unit,entry,...)end
        local result=pack(invoke(overlays(session,true),original,unit,entry,...))
        clamp_speed(session,kind)
        if kind=="radio"then trace("radio:update",unit,entry)end
        return unpack(result,1,result.n)
    end
    function bridge:exit(kind,original,unit,entry,next_state,...)
        local session=session_for(unit,entry)
        if not session then return original(unit,entry,next_state,...)end
        local preserve=healthy(session.state)and(next_state==env.CharacterStateCrawl or next_state==env.CharacterStateStratagemsThrow)
        local list={{env.CharacterStateMachine,"animation_event",animation_factory(session)}}
        if preserve and kind=="radio"then
            list[#list+1]={env.EntityAux,"queue_command_master",command_factory(session,true)}
            list[#list+1]={env.EntityAux,"command_master_immediately",command_factory(session,true)}
        end
        local result=pack(pcall(invoke,list,original,unit,entry,next_state,...))
        trace(kind..":exit",unit,entry,next_state)
        if result[1]and preserve and next_state==env.CharacterStateCrawl then
            self.return_observer={unit=unit,state=session.state,world=session.world,remaining=3}
            mark_animation(session,"return_crawl")
        end
        if next_state~=env.CharacterStateStratagems and next_state~=env.CharacterStateStratagemsThrow or not result[1]then self.session=nil end
        if not result[1]then error(result[2],0)end
        return unpack(result,2,result.n)
    end
    function bridge:animation_update(original,component,unit,entry,...)
        cleanup_animation()
        local dirty=self.animation_dirty
        if not dirty or unit~=dirty.unit then return original(component,unit,entry,...)end
        local good,state,reason=pcall(function()
            local slave=type(entry)=="table"and entry.state
            if type(slave)~="table"or not env.EntityAux or type(env.EntityAux.state)~="function"
                or env.EntityAux.state(unit,"character")~=slave then return nil,"slaveptr"end
            local health=slave.health_state
            if not healthy(slave)then return nil,"slave_health"end
            if type(health)~="table"or health.is_dodging~=true then return nil,"defer"end
            return slave
        end)
        if not good then discard_animation("slave_error")
        elseif not state then
            if reason=="defer"then
                dirty.ttl=dirty.ttl-1
                if dirty.ttl<=0 then discard_animation("mirror_timeout")end
            else discard_animation(reason)end
        else
            -- The native helper selects crawl/crawl_stop from the ACTUAL slave
            -- health/mover state. Re-evaluate its stale event cache once after
            -- the action graph changed; never synthesize an animation event.
            local previous=rawget(state,"wanted_substate_animation")
            rawset(state,"wanted_substate_animation",nil)
            self.animation_dirty=nil
            local result=pack(pcall(original,component,unit,entry,...))
            if not result[1]then
                if rawget(state,"wanted_substate_animation")==nil then rawset(state,"wanted_substate_animation",previous)end
                error(result[2],0)
            end
            pcall(function()
                note("animation_refresh_"..dirty.reason,"native animation cache refreshed after "..dirty.reason..": "..tostring(rawget(state,"wanted_substate_animation")))
            end)
            return unpack(result,2,result.n)
        end
        return original(component,unit,entry,...)
    end
    function bridge:install_hooks()
        cleanup_animation()
        return_observer()
        cleanup()
        if type(ctl.hook)~="function"then return end
        ctl:hook("CharacterStateCrawl","update",function(original)return function(...)return bridge:crawl_update(original,...)end end)
        ctl:hook("CharacterStateCrawl","on_exit",function(original)return function(...)return bridge:crawl_exit(original,...)end end)
        ctl:hook("CharacterComponent","handle_animation_updates",function(original)return function(...)return bridge:animation_update(original,...)end end)
        for _,item in ipairs({{name="CharacterStateStratagems",kind="radio"},{name="CharacterStateStratagemsThrow",kind="throw"}})do
            local kind=item.kind
            for _,phase in ipairs({"on_enter","update","on_exit"})do
                local method=phase=="on_enter"and"enter"or phase=="on_exit"and"exit"or"update"
                ctl:hook(item.name,phase,function(original)return function(...)return bridge[method](bridge,kind,original,...)end end)
            end
        end
    end
    return bridge
end
return Stratagems
