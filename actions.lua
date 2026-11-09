-- Add local Firearm input dispatch while native Dodge/Crawl owns locomotion.
-- No character, health, mover, ammunition, cadence or network field is written.
local Actions={}
local function pack(...)return{n=select("#",...),...}end
local function finite(value)return type(value)=="number"and value==value and math.abs(value)<math.huge end

function Actions.new(env,ctl,config)
    local actions={noted={}}
    local function note(key,message)
        if actions.noted[key]then return end
        actions.noted[key]=true
        if type(ctl.log)=="function"then pcall(ctl.log,ctl,"DIVE actions: "..message)end
    end
    local function command(weapon,name,...)
        local entity=env.EntityAux
        if not entity or type(entity.queue_command_master_interface)~="function"then return false end
        local good,problem=pcall(entity.queue_command_master_interface,weapon,"weapon",name,...)
        if not good then note("command_"..name,"native "..name.." failed: "..tostring(problem))end
        return good
    end
    local function local_owned(weapon,unit)
        local entity=env.EntityAux
        if not weapon or not unit or not env.Unit or type(env.Unit.alive)~="function"or not env.Unit.alive(weapon)
            or not entity or type(entity.owned)~="function"or type(entity.has_component)~="function"or type(entity.state)~="function"then return false end
        if entity.owned(weapon)~=true or not entity.has_component(weapon,"firearm")or not entity.has_component(weapon,"equipment")then return false end
        local equipment=entity.state(weapon,"equipment")
        return type(equipment)=="table"and equipment.wielder==unit
    end
    local function stop_auto()
        local weapon,unit=actions.auto_weapon,actions.auto_unit
        actions.auto_weapon=nil;actions.auto_unit=nil
        if not weapon then return end
        local good,owned=pcall(local_owned,weapon,unit)
        if good and owned then command(weapon,"firing_auto",false)end
    end
    local function sample(entries)
        local unit=ctl.local_unit
        local view=ctl.view
        local context=view and view.input_context
        if not unit or type(entries)~="table"or not context or context.unit~=unit or not env.Unit
            or type(env.Unit.alive)~="function"or not env.Unit.alive(unit)then return nil end
        local input_component,input_state=context.component,context.state
        if type(input_component)~="table"or(input_component.current_state~="game"and input_component.current_state~="tutorial")
            or type(input_state)~="table"or input_state.pad_number~=(env.KEYBOARD_MOUSE_PAD_NUMBER or 0)
            or not input_state.input_data or not input_state.input_data.is_active or not input_state.has_focus
            or input_state.character_input_disabled or input_state.mouse_aim_disabled or input_state.input_filter~=nil then return nil end
        local entry=entries[unit]
        local state=type(entry)=="table"and entry.state
        if type(state)~="table"or type(state.input)~="table"then return nil end
        for other,candidate in pairs(entries)do
            if other~=unit and type(candidate)=="table"and candidate.state==state then return nil end
        end
        return{unit=unit,state=state,input=state.input}
    end
    local function eligible(value)
        if not value or not ctl.enabled or type(ctl.active_local_unit)~="function"or ctl:active_local_unit(env.CameraManager)~=value.unit then return nil end
        local state=value.state
        local current=state.current_state
        if not current or(current~=env.CharacterStateDodge and current~=env.CharacterStateCrawl)or state.new_state~=nil then return nil end
        local health=state.health_state
        if type(health)~="table"or health.is_dead or health.is_downed or state.is_dead or state.is_downed or state.has_extracted or state.do_knockdown then return nil end
        if(state.current_seat_unit and env.Unit.alive(state.current_seat_unit))
            or(state.current_carry_unit and env.Unit.alive(state.current_carry_unit))then return nil end
        local weapon=state.current_weapon
        if type(state.inventory_state)~="table"or state.inventory_state.current_weapon~=weapon or not local_owned(weapon,value.unit)then return nil end
        local entity=env.EntityAux
        if type(entity.state_master_interface)~="function"then return nil end
        local weapon_state=entity.state_master_interface(weapon,"weapon")
        if type(weapon_state)~="table"or weapon_state.assisted_reload then return nil end
        return{unit=value.unit,weapon=weapon,state=weapon_state,input=value.input}
    end
    local function native_fire(value)
        local current=value and value.state.current_state
        if not current or(current~=env.CharacterStateFire and current~=env.CharacterStateWalkFire
            and current~=env.CharacterStateAimFire and current~=env.CharacterStateAimWalkFire)then return false end
        local state=value.state
        local health=state.health_state
        return type(health)=="table"and not health.is_dead and not health.is_downed and not state.is_dead
            and not state.is_downed and not state.has_extracted and not state.do_knockdown and state.new_state==nil
    end
    local function after_original(entries)
        local good,value=pcall(sample,entries)
        if not good then value=nil end
        local fire,reload=value and value.input.fire==true,value and value.input.reload==true
        local fire_edge,reload_edge=false,false
        if value then
            if actions.input_unit~=value.unit then actions.last_fire=false;actions.last_reload=false end
            fire_edge=fire and actions.last_fire~=true
            reload_edge=reload and actions.last_reload~=true
            actions.input_unit=value.unit;actions.last_fire=fire;actions.last_reload=reload
        else
            -- Focus returning with a held button must not create a new edge.
            actions.last_fire=true;actions.last_reload=true
        end
        local valid,weapon=pcall(eligible,value)
        if not valid then weapon=nil end
        if not weapon then
            if native_fire(value)and ctl.enabled then
                -- Native Fire/AimFire has already taken ownership this batch.
                actions.auto_weapon=nil;actions.auto_unit=nil
            else stop_auto()end
            return
        end
        local weapon_state=weapon.state
        local reloading=weapon_state.is_reloading or(finite(weapon_state.reload_time)and weapon_state.reload_time>0)
        if reload or reloading then
            if actions.auto_weapon then stop_auto()else command(weapon.weapon,"firing_auto",false)end
            if reload_edge and not reloading and weapon_state.reloadable then
                command(weapon.weapon,"reload")
                note("reload","local native reload during Dodge/Crawl")
            end
            return
        end
        if fire_edge then
            command(weapon.weapon,"firing_single")
            note("fire","local native fire during Dodge/Crawl")
        end
        local auto=fire and weapon.input.fire_auto==true
        if command(weapon.weapon,"firing_auto",auto)then
            actions.auto_weapon=auto and weapon.weapon or nil
            actions.auto_unit=auto and weapon.unit or nil
        end
    end
    function actions:character_update(original,component,entries,dt,...)
        if self.auto_weapon then
            local good,value=pcall(sample,entries)
            local valid,weapon=false,nil
            if good then valid,weapon=pcall(eligible,value)end
            if not valid or not weapon or weapon.weapon~=self.auto_weapon then stop_auto()end
        end
        local result=pack(pcall(original,component,entries,dt,...))
        if not result[1]then stop_auto();error(result[2],0)end
        local good,problem=pcall(after_original,entries)
        if not good then stop_auto();note("bridge_failure","bridge skipped after native update: "..tostring(problem))end
        return unpack(result,2,result.n)
    end
    return actions
end
return Actions
