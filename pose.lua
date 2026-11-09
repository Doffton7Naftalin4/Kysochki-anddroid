-- Experimental upper-body aim evaluated by the native animation controller.
-- Script-facing state IDs remain the original IDs for the managed local unit.
local Pose = {}
local counts = {69, 93, 191, 5, 98, 23, 5, 20, 4}
local function pack(...) return {n=select("#", ...), ...} end
local function finite(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge
end
local function xyz(value)
    if value and finite(value.x) and finite(value.y) and finite(value.z) then
        return {x=value.x,y=value.y,z=value.z}
    end
end
local function normalized(value)
    value=xyz(value)
    if not value then return nil end
    local length=math.sqrt(value.x^2+value.y^2+value.z^2)
    if not finite(length) or length<0.000001 then return nil end
    return {x=value.x/length,y=value.y/length,z=value.z/length}
end
local function valid_states(values, doubled, partial)
    if partial then
        if values.n<0 or values.n>#counts then return false end
    elseif values.n~=#counts then return false end
    for index,count in ipairs(counts) do
        local value=values[index]
        if value~=nil and (not finite(value) or value%1~=0 or value<0
            or value>=count*(doubled and 2 or 1)) then return false end
    end
    return true
end
local function dot(a,b)return a.x*b.x+a.y*b.y+a.z*b.z end
local function look(direction)
    local forward=normalized(direction)
    if not forward then return nil end
    local horizontal=math.sqrt(forward.x^2+forward.y^2)
    if horizontal<0.000001 then return nil end
    return {right={x=forward.y/horizontal,y=-forward.x/horizontal,z=0},forward=forward,
        up={x=-forward.x*forward.z/horizontal,y=-forward.y*forward.z/horizontal,z=horizontal}}
end
local function canonical(values)
    if not valid_states(values,true) then return nil end
    local result={n=9}
    for i,count in ipairs(counts)do if values[i]~=nil then result[i]=values[i]%count end end
    return result
end
local function same_states(a,b)
    if not a or not b or a.n~=9 or b.n~=9 then return false end
    for i=1,9 do if a[i]~=b[i]then return false end end
    return true
end
local function copied_states(values)
    local result={n=values.n}
    for index=1,values.n do result[index]=values[index]end
    return result
end
local function states_text(values)
    if not values then return "unavailable"end
    local parts={}
    for index=1,values.n do parts[index]=tostring(values[index])end
    return "n="..values.n.."["..table.concat(parts,",").."]"
end
local function compensated(offset,desired,previous)
    local radius=math.sqrt(offset.y^2+offset.z^2)
    if radius<0.000001 or math.abs(desired.z)>radius+0.00000001 then return nil end
    local alpha=math.asin(math.max(-1,math.min(1,desired.z/radius)))
    local phase=math.atan2(offset.z,offset.y)
    local best,score
    for _,raw in ipairs({alpha-phase,math.pi-alpha-phase})do
        local pitch=math.atan2(math.sin(raw),math.cos(raw))
        local projection=offset.y*math.cos(pitch)-offset.z*math.sin(pitch)
        -- Select the positive horizontal projection; the other algebraic
        -- branch can flip the Look frame as it crosses the principal domain.
        if math.abs(pitch)<=85*math.pi/180 and projection>0.000001 then
            local yaw=math.atan2(desired.x,desired.y)-math.atan2(offset.x,projection)
            local candidate={x=math.sin(yaw)*math.cos(pitch),y=math.cos(yaw)*math.cos(pitch),z=math.sin(pitch)}
            local closeness=dot(candidate,previous or desired)
            if not best or closeness>score then best,score=candidate,closeness end
        end
    end
    return best
end
local function command_transport(encoded,reference,desired)
    if type(encoded)~="table"or type(reference)~="table"then return nil end
    local frame=look(encoded)
    local ray=normalized(reference)
    if not frame or not ray then return nil end
    -- Preserve the relation between the last two issued commands. This is
    -- continuity during HOLD, not a fresh physical foregrip observation.
    local relation=normalized({x=dot(frame.right,ray),y=dot(frame.forward,ray),z=dot(frame.up,ray)})
    if not relation then return nil end
    return compensated(relation,desired,encoded)
end

function Pose.new(env,ctl,config)
    local pose={disabled=false,manual_off=false,frame=0,managed={},noted={},geometry_seen={},geometry_count=0,
        recovery_windows=0,recovery_count=0,recovery_group_windows={aim=0,crawl=0}}
    local safe_states={"Idle","Walk","Sprint","Fire","WalkFire","Aim","AimWalk",
        "AimFire","AimWalkFire","Dodge","Crawl"}
    local active_states={"Aim","AimWalk","AimFire","AimWalkFire","Fire","WalkFire","Dodge","Crawl"}
    local function note(key,message)
        if pose.noted[key] then return end
        pose.noted[key]=true
        if type(ctl.once)=="function" then pcall(ctl.once,ctl,"pose_"..key,message) end
    end
    local function alive(unit)
        return unit and env.Unit and type(env.Unit.alive)=="function" and env.Unit.alive(unit)==true
    end
    local function character(unit)
        local entity=env.EntityAux
        if not entity then return nil end
        if type(entity.state_master)=="function" then return entity.state_master(unit,"character") end
        if type(entity.state)=="function" then return entity.state(unit,"character") end
    end
    local function linked_weapon(unit,state)
        local weapon=state and state.current_weapon
        local entity=env.EntityAux
        if not alive(weapon) or not entity or type(entity.owned)~="function" or entity.owned(weapon)~=true
            or type(entity.state)~="function" then return nil end
        local equipment=entity.state(weapon,"equipment")
        if type(equipment)=="table" and equipment.wielder==unit and equipment.wielded==true then return weapon end
    end
    local function node(unit,name)
        local api=env.Unit
        if not unit or not api or type(api.has_node)~="function" or type(api.node)~="function"or api.has_node(unit,name)~=true then return nil end
        local index=api.node(unit,name)
        if finite(index)and index>=0 and index%1==0 then return index end
    end
    local function read_position(unit,name)
        local good,position,index=pcall(function()
            if not unit or not env.Unit or type(env.Unit.world_position)~="function"then return nil end
            local index=0
            if name then index=node(unit,name);if index==nil then return nil end end
            return xyz(env.Unit.world_position(unit,index)),index
        end)
        if good then return position,index end
    end
    local function context(world,read_only)
        local view=ctl.view
        local owned=view and view.owned
        if not ctl.enabled or (not read_only and (pose.manual_off or pose.disabled)) or not owned or owned.world~=world
            or (view.mode~="shoulder" and view.mode~="first") or not alive(owned.unit)
            or type(ctl.active_local_unit)~="function" or type(view.aim_ray)~="function" then return nil end
        local unit=ctl:active_local_unit(env.CameraManager)
        if not alive(unit) or (read_only and unit~=ctl.local_unit) then return nil end
        local state=character(unit)
        if type(state)~="table" then return nil end
        local health=state.health_state or state
        if health.is_dead or health.is_downed or state.is_dead or state.is_downed or state.do_knockdown
            or state.has_extracted or alive(state.current_seat_unit) or alive(state.current_carry_unit) then return nil end
        local allowed=false
        for _,name in ipairs(safe_states) do
            local class=env["CharacterState"..name]
            if class and state.current_state==class then allowed=true;break end
        end
        if not allowed and ((env.CharacterStateStratagems and state.current_state==env.CharacterStateStratagems)
            or (env.CharacterStateStratagemsThrow and state.current_state==env.CharacterStateStratagemsThrow)) then
            local strata=ctl.stratagems
            allowed=strata and type(strata.prone)=="function" and strata:prone(unit)==true
        end
        if not allowed then return nil end
        if read_only then return unit,state,view,owned end
        allowed=false
        for _,name in ipairs(active_states)do if env["CharacterState"..name]and state.current_state==env["CharacterState"..name]then allowed=true;break end end
        if not allowed then return nil end
        local weapon=linked_weapon(unit,state)
        if not weapon or not node(weapon,"j_muzzle")or not node(unit,"spine2")or not node(unit,"l_hand_attach")then return nil end
        local entity=env.EntityAux
        if type(entity.state_master_interface)=="function"then
            local good,weapon_state=pcall(entity.state_master_interface,weapon,"weapon")
            if not good then return nil end
            if type(weapon_state)=="table"and(weapon_state.is_reloading==true or weapon_state.assisted_reload
                or(finite(weapon_state.reload_time)and weapon_state.reload_time>0))then return nil end
        end
        return unit,state,view,owned,weapon
    end
    local function release()
        local unit=pose.active_unit
        pose.active_unit=nil;pose.sample=nil;pose.observer=nil;pose.last_encoded=nil;pose.adaptive_status=nil;pose.alignment_angle=nil
        pose.recovery_previous=nil;pose.recovery_window=nil
        pose.observation_reason=nil
        if unit then
            local managed=pose.managed[unit]
            if managed then managed.active=false end
            if alive(unit) then env.Unit.animation_event(unit,"hd_pose_off") end
            pose.managed[unit]=nil
        end
    end
    local function fail(problem)
        pose.disabled=true;pose.sample=nil
        local good,cleanup_problem=pcall(release)
        note("failure","Native upper-body pose disabled: "..tostring(problem))
        if not good then note("release_failure","Private animation release failed: "..tostring(cleanup_problem)) end
    end
    local function supported()
        local unit=env.Unit
        if not unit or not env.Vector3 or not pose.native_get_state or not env.Quaternion
            or type(env.Quaternion.rotate)~="function" then return false end
        for _,name in ipairs({"animation_find_constraint_target","animation_set_constraint_target",
            "animation_event","world_position","world_rotation"}) do
            if type(unit[name])~="function" then return false end
        end
        return true
    end
    local function limited_direction(unit,direction)
        local forward=xyz(env.Quaternion.rotate(env.Unit.world_rotation(unit,0),env.Vector3(0,1,0)))
        if not forward then return nil end
        forward=normalized({x=forward.x,y=forward.y,z=0})
        if not forward then return nil end
        local right={x=forward.y,y=-forward.x,z=0}
        local yaw=math.atan2(direction.x*right.x+direction.y*right.y,
            direction.x*forward.x+direction.y*forward.y)
        yaw=math.max(-55*math.pi/180,math.min(55*math.pi/180,yaw))
        local pitch=math.asin(math.max(-1,math.min(1,direction.z)))
        pitch=math.max(-math.pi/4,math.min(math.pi/4,pitch))
        local horizontal=math.cos(pitch)
        return {x=(forward.x*math.cos(yaw)+right.x*math.sin(yaw))*horizontal,
            y=(forward.y*math.cos(yaw)+right.y*math.sin(yaw))*horizontal,z=math.sin(pitch)}
    end
    function pose:install_hooks()
        ctl:hook("Unit","animation_get_state",function(original)
            self.native_get_state=original
            return function(unit,...)
                local values=pack(original(unit,...))
                if self.managed[unit] and alive(unit) then
                    if not valid_states(values,true) then error("Managed animation state layout changed",0) end
                    for index,count in ipairs(counts) do
                        if values[index]~=nil then values[index]=values[index]%count end
                    end
                end
                return unpack(values,1,values.n)
            end
        end)
        ctl:hook("Unit","animation_set_state",function(original)
            return function(unit,...)
                local managed=self.managed[unit]
                if not managed or not alive(unit) then return original(unit,...) end
                local values=pack(...)
                -- The native setter does no bounds checking. Reject unknown
                -- script tuples before entering its direct state-array lookup.
                if not valid_states(values,false,true) then error("Invalid managed animation state tuple",0) end
                if managed.active then
                    for index,count in ipairs(counts) do
                        if values[index]~=nil then values[index]=values[index]+count end
                    end
                end
                return original(unit,unpack(values,1,values.n))
            end
        end)
    end
    function pose:begin_frame()
        self.frame=self.frame+1
        if self.sample and self.frame-self.sample.frame>1 then self.sample=nil end
    end
    function pose:status()
        return not self.manual_off and not self.disabled and "BODY ON" or "BODY OFF"
    end
    function pose:toggle_diagnostic()
        local good,problem=pcall(release)
        self.manual_off=not self.manual_off
        if not good then fail(problem) end
        return not self.manual_off and not self.disabled
    end
    local function same_owner(value,unit,state,world,weapon)
        return value and value.unit==unit and value.state==state and value.world==world and value.weapon==weapon
    end
    local function recovery_class(state)
        for _,name in ipairs({"Aim","AimWalk","AimFire","AimWalkFire","Crawl"})do
            if env["CharacterState"..name]and state.current_state==env["CharacterState"..name]then
                return name,name=="Crawl"and"crawl"or(name=="AimFire"or name=="AimWalkFire")and"fire"or"aim"
            end
        end
    end
    local function track_recovery(unit,state,world,weapon)
        local name,kind=recovery_class(state)
        if not name then pose.recovery_previous=nil;pose.recovery_window=nil;return end
        local group=kind=="crawl"and"crawl"or"aim"
        local previous=pose.recovery_previous
        if not same_owner(previous,unit,state,world,weapon)then previous=nil;pose.recovery_window=nil end
        if previous and previous.group~=group then previous=nil;pose.recovery_window=nil end
        local window=pose.recovery_window
        if window and(pose.frame<window.frame or pose.frame-window.frame>=180)then window=nil;pose.recovery_window=nil end
        local fire=state.input and state.input.fire
        if type(fire)~="boolean"then fire=nil end
        local edge
        if previous then
            if previous.kind~="crawl"and kind~="crawl"and previous.kind~=kind then edge=previous.name.."->"..name
            elseif previous.kind=="crawl"and kind=="crawl"and previous.fire~=nil and fire~=nil and previous.fire~=fire then
                edge="Crawl.fire="..tostring(previous.fire).."->"..tostring(fire)
            end
        end
        if edge then
            if not window and pose.recovery_windows<4 and pose.recovery_count<720 and pose.recovery_group_windows[group]<2 then
                pose.recovery_windows=pose.recovery_windows+1
                pose.recovery_group_windows[group]=pose.recovery_group_windows[group]+1
                window={unit=unit,state=state,world=world,weapon=weapon,frame=pose.frame,
                    index=pose.recovery_windows,opened_edge=edge,group=group}
                pose.recovery_window=window
            end
            if window then window.edge=edge;window.edge_frame=pose.frame end
        end
        pose.recovery_previous={unit=unit,state=state,world=world,weapon=weapon,name=name,kind=kind,fire=fire,group=group}
    end
    local function snapshot_producer(request,prior_request,previous,source,used,raw,desired,encoded)
        local unit,state,world,weapon=request.unit,request.state,request.world,request.weapon
        local age=same_owner(source,unit,state,world,weapon)and pose.frame-source.frame or nil
        local reason="no_observer"
        if source then
            if not same_owner(source,unit,state,world,weapon)then reason="context_mismatch"
            elseif age<0 or age>1 then reason="stale"
            elseif not same_states(source.states,request.states)then reason="state_mismatch"
            else reason=request.mode=="compensated"and"fresh"or"no_candidate"end
        end
        local hold_frames=0
        if request.mode=="holding"then
            hold_frames=1
            if same_owner(prior_request,unit,state,world,weapon)and prior_request.mode=="holding"
                and prior_request.diagnostic and pose.frame-prior_request.frame>=0 and pose.frame-prior_request.frame<=1 then
                hold_frames=prior_request.diagnostic.hold_frames+(pose.frame==prior_request.frame and 0 or 1)
            end
        end
        local delta=previous and previous.direction and math.acos(math.max(-1,math.min(1,dot(previous.direction,encoded))))*180/math.pi
        request.diagnostic={raw_states=copied_states(raw),canonical_states=copied_states(request.states),
            previous_mode=previous and previous.mode or"none",hold_frames=hold_frames,
            limited_desired=xyz(desired),encoded=xyz(encoded),encoded_delta_deg=delta,
            used_C=used and xyz(used.offset),observer_frame=source and source.frame,observer_age=age,
            reason=reason,prior_observation_reason=pose.observation_reason or"none"}
    end
    function pose:before_animations(world)
        local owned=ctl.view and ctl.view.owned
        if world and owned and owned.world~=world then return end
        local good,problem=pcall(function()
            if not world then release();return end
            local unit,state,view,_,weapon=context(world)
            if not unit then release();return end
            if not supported() then error("Native pose API unavailable",0) end
            local _,ray=view:aim_ray(env.CameraManager)
            local direction=normalized(ray)
            if direction then direction=limited_direction(unit,direction) end
            local root=xyz(env.Unit.world_position(unit,0))
            local pivot=read_position(unit,"spine2")
            if not direction or not root or not pivot then release();return end
            if env.Unit.animation_find_constraint_target(unit,"hd_camera_aim")~=1 then
                error("Native pose graph target not loaded",0)
            end
            local raw_states=pack(self.native_get_state(unit))
            local states=canonical(raw_states)
            if not states then error("Native pose graph state layout mismatch",0) end
            if self.active_unit and self.active_unit~=unit then release() end
            local diagnostic_prior_request,diagnostic_source=self.last_request,self.observer
            local previous=self.last_encoded
            if not same_owner(previous,unit,state,world,weapon)then previous=nil;self.last_encoded=nil end
            local observed=self.observer
            if not same_owner(observed,unit,state,world,weapon)or self.frame-observed.frame<0
                or self.frame-observed.frame>1 or not same_states(observed.states,states)then
                observed=nil;self.observer=nil
            end
            local encoded,mode=direction,"bootstrap"
            local reference_desired,hard_hold=direction,false
            if observed then
                encoded=compensated(observed.offset,direction,previous and previous.direction)
                if encoded then mode="compensated"
                else
                    encoded=previous and previous.direction or direction;mode="holding"
                    hard_hold=true
                    if previous then reference_desired=previous.reference_desired end
                    note("unreachable","Native upper-body target held: no positive-projection solution inside pitch85")
                end
            elseif previous and previous.mode~="bootstrap"then
                encoded=previous.direction;mode="holding"
                reference_desired=previous.reference_desired;hard_hold=previous.hard_hold==true
                if not hard_hold then
                    local transported=command_transport(previous.direction,previous.reference_desired,direction)
                    if transported then encoded=transported;reference_desired=direction end
                end
            end
            local managed=self.managed[unit]
            if not managed then managed={active=false};self.managed[unit]=managed end
            -- Native solver compares target translation with a world-space
            -- reference composed from the current unit graph, including root.
            local x,y,z=pivot.x+encoded.x*1000,pivot.y+encoded.y*1000,pivot.z+encoded.z*1000
            local target=env.Vector3(x,y,z)
            env.Unit.animation_set_constraint_target(unit,1,target)
            -- Diagnostic snapshot of the successful request, not an assertion
            -- about the evaluated pose. Never retain temporary engine vectors.
            self.last_request={unit=unit,state=state,world=world,weapon=weapon,frame=self.frame,states=states,mode=mode,x=x,y=y,z=z}
            self.last_encoded={unit=unit,state=state,world=world,weapon=weapon,frame=self.frame,mode=mode,direction=xyz(encoded),
                reference_desired=type(reference_desired)=="table"and xyz(reference_desired)or nil,hard_hold=hard_hold}
            self.adaptive_status=mode
            if mode=="compensated"then note("compensated","Native upper-body target compensation active from a fresh aligned foregrip/muzzle sample")end
            local needs_on=not managed.active
            for index,count in ipairs(counts) do
                if raw_states[index]~=nil and raw_states[index]<count then needs_on=true end
            end
            -- Arm cleanup before the native call: a partial activation must
            -- still attempt the private OFF path if that call raises.
            managed.active=true;self.active_unit=unit
            if needs_on then env.Unit.animation_event(unit,"hd_pose_on") end
            note("native","Native upper-body controller active; no manual bone publication")
            -- Diagnostic edge tracking cannot fail or disable the controller.
            pcall(snapshot_producer,self.last_request,diagnostic_prior_request,previous,diagnostic_source,observed,raw_states,direction,encoded)
            pcall(track_recovery,unit,state,world,weapon)
        end)
        if not good then fail(problem) end
    end
    local function same_direction(a,b)
        return a and b and a.x*b.x+a.y*b.y+a.z*b.z>=math.cos(10*math.pi/180)
    end
    local function observe(world)
        local owned=ctl.view and ctl.view.owned
        if owned and world~=owned.world then return end
        pose.observer=nil;pose.alignment_angle=nil
        pose.observation_reason="inactive"
        local unit,state,_,_,weapon=context(world)
        if unit~=pose.active_unit then return end
        local request=pose.last_request
        if not same_owner(request,unit,state,world,weapon)or request.frame~=pose.frame then pose.observation_reason="request_mismatch";return end
        local states=canonical(pack(pose.native_get_state(unit)))
        if not same_states(states,request.states)then pose.observation_reason="state_mismatch";return end
        local pivot=read_position(unit,"spine2")
        local reference=read_position(unit,"l_hand_attach")
        local index=node(weapon,"j_muzzle")
        if not pivot or not reference or not index then pose.observation_reason="geometry_unavailable";return end
        local source=look({x=reference.x-pivot.x,y=reference.y-pivot.y,z=reference.z-pivot.z})
        local target=look({x=request.x-pivot.x,y=request.y-pivot.y,z=request.z-pivot.z})
        local muzzle=normalized(env.Quaternion.rotate(env.Unit.world_rotation(weapon,index),env.Vector3(0,1,0)))
        if not source or not target or not muzzle then pose.observation_reason="geometry_unavailable";return end
        -- A forward-vector gate alone is insufficient near the vertical pole:
        -- compare the entire native Look frame, including its right/up axes.
        local cosine=(dot(source.right,target.right)+dot(source.forward,target.forward)+dot(source.up,target.up)-1)/2
        local angle=math.acos(math.max(-1,math.min(1,cosine)))
        pose.alignment_angle=angle
        if angle>=math.pi/180 then
            pose.observation_reason="look_mismatch"
            note("alignment","Native upper-body calibration pending: published foregrip Look frame differs from the requested frame")
            return
        end
        local offset=normalized({x=dot(source.right,muzzle),y=dot(source.forward,muzzle),z=dot(source.up,muzzle)})
        local horizontal=math.sqrt(source.forward.x^2+source.forward.y^2)
        if not offset or offset.y*horizontal-offset.z*source.forward.z<=0.000001 then pose.observation_reason="nonpositive_projection";return end
        pose.observer={unit=unit,state=state,world=world,weapon=weapon,states=states,frame=pose.frame,offset=offset}
        pose.observation_reason="accepted"
    end
    local function vector_text(value)
        return value and string.format("(%.6f,%.6f,%.6f)",value.x,value.y,value.z) or "unavailable"
    end
    local function degrees_text(value)
        return finite(value) and string.format("%.6f",value*180/math.pi) or "unavailable"
    end
    local function diagnostic_states(unit)
        local good,values=pcall(function()
            if type(pose.native_get_state)~="function" then return nil end
            return pack(pose.native_get_state(unit))
        end)
        if not good or not values then return "getter_error","unavailable" end
        local raw,canonical={},{}
        local valid=valid_states(values,true)
        for index=1,values.n do
            raw[index]=tostring(values[index])
            if valid then canonical[index]=values[index]~=nil and tostring(values[index]%counts[index]) or "nil" end
        end
        return "n="..values.n.."["..table.concat(raw,",").."]",
            valid and ("n=9["..table.concat(canonical,",").."]") or "unavailable"
    end
    local function capture_geometry(world)
        if pose.geometry_count>=12 or pose.geometry_failed then return end
        local unit,state,view=context(world,true)
        if not unit then return end
        -- Do not spend a grounded-prone bin on a transient airborne dive.
        if env.CharacterStateDodge and state.current_state==env.CharacterStateDodge then return end
        local origin,direction=view:aim_ray(env.CameraManager)
        origin=xyz(origin);direction=normalized(direction)
        if not origin or not direction then return end
        local pitch=math.asin(math.max(-1,math.min(1,direction.z)))
        local pitch_bin=pitch< -math.pi/12 and "down" or pitch>math.pi/12 and "up" or "flat"
        local prone=env.CharacterStateCrawl and state.current_state==env.CharacterStateCrawl
        if not prone and ctl.stratagems and type(ctl.stratagems.prone)=="function" then prone=ctl.stratagems:prone(unit)==true end
        local stance=prone and "prone" or "standing"
        local body=not pose.manual_off and not pose.disabled and "ON" or "OFF"
        local managed=pose.managed[unit]
        if body=="ON" and (pose.active_unit~=unit or not managed or not managed.active) then return end
        local key=stance.."_"..pitch_bin.."_"..body
        if pose.geometry_seen[key] then return end
        -- One sample per bin, twelve total. Mark before getters/logging so
        -- optional failures cannot create a per-frame diagnostic loop.
        pose.geometry_seen[key]=true;pose.geometry_count=pose.geometry_count+1
        local root=read_position(unit)
        local spine=read_position(unit,"spine2")
        local chest=read_position(unit,"spine4")
        local aim=read_position(unit,"aim")
        local left=read_position(unit,"l_hand_attach")
        local right=read_position(unit,"r_hand_attach")
        local linked,weapon=pcall(linked_weapon,unit,state)
        if not linked then weapon=nil end
        local muzzle,index=read_position(weapon,"j_muzzle")
        local good,muzzle_forward=pcall(function()
            if not muzzle or not index then return nil end
            return normalized(env.Quaternion.rotate(env.Unit.world_rotation(weapon,index),env.Vector3(0,1,0)))
        end)
        if not good then muzzle_forward=nil end
        local reference=spine and aim and normalized({x=aim.x-spine.x,y=aim.y-spine.y,z=aim.z-spine.z})
        local angle=reference and muzzle_forward and math.acos(math.max(-1,math.min(1,
            reference.x*muzzle_forward.x+reference.y*muzzle_forward.y+reference.z*muzzle_forward.z)))
        local raw,canonical=diagnostic_states(unit)
        local request=pose.last_request
        if request and (request.unit~=unit or request.world~=world or request.state~=state) then request=nil end
        -- ON is the published final scene pose, not the solver's raw clip.
        -- OFF is the native final scene pose. LAST_REQUEST remains historical.
        local message="Native pose geometry: frame="..pose.frame.." unit="..tostring(unit).." weapon="..tostring(weapon).." body="..body
            .." pose="..(body=="ON" and "PUBLISHED" or "NATIVE").." stance="..stance.." camera_pitch="..pitch_bin
            .." camera_pitch_deg="..degrees_text(pitch).." camera_origin="..vector_text(origin).." camera_direction="..vector_text(direction)
            .." root="..vector_text(root).." spine2="..vector_text(spine).." spine4="..vector_text(chest).." aim="..vector_text(aim)
            .." l_hand_attach="..vector_text(left).." r_hand_attach="..vector_text(right)
            .." muzzle="..vector_text(muzzle).." muzzle_forward="..vector_text(muzzle_forward)
            .." aim_muzzle_deg="..degrees_text(angle)
            .." aim_pitch_deg="..degrees_text(reference and math.asin(math.max(-1,math.min(1,reference.z))))
            .." muzzle_pitch_deg="..degrees_text(muzzle_forward and math.asin(math.max(-1,math.min(1,muzzle_forward.z))))
            .." LAST_REQUEST="..vector_text(request).." last_request_unit="..(request and tostring(request.unit) or "unavailable")
            .." last_request_frame="..(request and tostring(request.frame) or "unavailable")
            .." last_request_mode="..(request and request.mode or "unavailable").." raw="..raw.." canonical="..canonical
            .." adaptive="..(pose.adaptive_status or "unavailable").." ref_target_frame_deg="..degrees_text(pose.alignment_angle)
            .." observer_C="..vector_text(pose.observer and pose.observer.offset)
        if type(ctl.log)=="function" then pcall(ctl.log,ctl,message)
        elseif type(ctl.once)=="function" then pcall(ctl.once,ctl,"pose_geometry_"..key,message) end
    end
    local function capture_recovery(world)
        local window=pose.recovery_window
        if not window or pose.recovery_count>=720 then return end
        local owned=ctl.view and ctl.view.owned
        if owned and owned.world~=world then return end
        if pose.frame<window.frame or pose.frame-window.frame>=180 then pose.recovery_window=nil;return end
        if pose.recovery_last_frame==pose.frame then return end
        local unit,state,view,_,weapon=context(world)
        local name=state and recovery_class(state)
        local group=name=="Crawl"and"crawl"or"aim"
        if not name or unit~=pose.active_unit or not same_owner(window,unit,state,world,weapon)or window.group~=group then
            pose.recovery_previous=nil;pose.recovery_window=nil;return
        end
        -- Consume before optional reads/logging. Four windows, at most 180
        -- distinct frames each, even when scene is submitted more than once.
        pose.recovery_last_frame=pose.frame;pose.recovery_count=pose.recovery_count+1
        local _,states=diagnostic_states(unit)
        local good,camera=pcall(function()
            local _,ray=view:aim_ray(env.CameraManager);return normalized(ray)
        end)
        if not good then camera=nil end
        local muzzle_good,muzzle=pcall(function()
            local index=node(weapon,"j_muzzle")
            if index==nil then return nil end
            return normalized(env.Quaternion.rotate(env.Unit.world_rotation(weapon,index),env.Vector3(0,1,0)))
        end)
        if not muzzle_good then muzzle=nil end
        local request=pose.last_request
        if not same_owner(request,unit,state,world,weapon)or request.frame~=pose.frame then request=nil end
        local encoded=pose.last_encoded
        if not same_owner(encoded,unit,state,world,weapon)or encoded.frame~=pose.frame then encoded=nil end
        local observed=pose.observer
        if not same_owner(observed,unit,state,world,weapon)or observed.frame~=pose.frame then observed=nil end
        local diagnostic=request and request.diagnostic
        local spine,spine_index=read_position(unit,"spine2")
        local left=read_position(unit,"l_hand_attach")
        local muzzle_position=read_position(weapon,"j_muzzle")
        local S=spine and left and normalized({x=left.x-spine.x,y=left.y-spine.y,z=left.z-spine.z})
        local T=spine and request and normalized({x=request.x-spine.x,y=request.y-spine.y,z=request.z-spine.z})
        local source=S and look(S)
        local measured=source and muzzle and normalized({x=dot(source.right,muzzle),y=dot(source.forward,muzzle),z=dot(source.up,muzzle)})
        local basis_good,basis=pcall(function()
            if spine_index==nil then return nil end
            local rotation=env.Unit.world_rotation(unit,spine_index)
            return {right=xyz(env.Quaternion.rotate(rotation,env.Vector3(1,0,0))),
                forward=xyz(env.Quaternion.rotate(rotation,env.Vector3(0,1,0))),
                up=xyz(env.Quaternion.rotate(rotation,env.Vector3(0,0,1)))}
        end)
        if not basis_good then basis=nil end
        local forward_error=S and T and math.acos(math.max(-1,math.min(1,dot(S,T))))
        local message="Native pose recovery: window="..window.index.." sample="..(pose.frame-window.frame+1)
            .." frame="..pose.frame.." edge="..(window.edge_frame==pose.frame and window.edge or"none")
            .." opened_edge="..window.opened_edge.." unit="..tostring(unit).." world="..tostring(world)
            .." weapon="..tostring(weapon).." class="..name.." fire="..tostring(state.input and state.input.fire)
            .." canonical="..states.." mode="..(request and request.mode or"unavailable")
            .." encoded_target_direction="..vector_text(encoded and encoded.direction)
            .." camera_direction="..vector_text(camera).." muzzle_direction="..vector_text(muzzle)
            .." ref_target_frame_deg="..degrees_text(pose.alignment_angle).." observer_C="..vector_text(observed and observed.offset)
            .." producer_raw="..states_text(diagnostic and diagnostic.raw_states)
            .." producer_canonical="..states_text(diagnostic and diagnostic.canonical_states)
            .." previous_mode="..(diagnostic and diagnostic.previous_mode or"unavailable")
            .." hold_frames="..tostring(diagnostic and diagnostic.hold_frames or"unavailable")
            .." limited_desired="..vector_text(diagnostic and diagnostic.limited_desired)
            .." used_C="..vector_text(diagnostic and diagnostic.used_C)
            .." observer_frame="..tostring(diagnostic and diagnostic.observer_frame or"unavailable")
            .." observer_age="..tostring(diagnostic and diagnostic.observer_age or"unavailable")
            .." encoded_delta_deg="..tostring(diagnostic and diagnostic.encoded_delta_deg or"unavailable")
            .." reason="..(diagnostic and diagnostic.reason or"unavailable")
            .." prior_observation_reason="..(diagnostic and diagnostic.prior_observation_reason or"unavailable")
            .." observation_reason="..(pose.observation_reason or"unavailable")
            .." accepted_C="..vector_text(observed and observed.offset).." measured_C="..vector_text(measured)
            .." S="..vector_text(S).." T="..vector_text(T)
            .." S_xy="..tostring(S and math.sqrt(S.x^2+S.y^2)or"unavailable")
            .." T_xy="..tostring(T and math.sqrt(T.x^2+T.y^2)or"unavailable")
            .." forward_error_deg="..degrees_text(forward_error).." spine2="..vector_text(spine)
            .." spine_right="..vector_text(basis and basis.right).." spine_forward="..vector_text(basis and basis.forward)
            .." spine_up="..vector_text(basis and basis.up).." l_hand_attach="..vector_text(left)
            .." muzzle_position="..vector_text(muzzle_position)
        if type(ctl.log)=="function"then pcall(ctl.log,ctl,message)
        elseif type(ctl.once)=="function"then pcall(ctl.once,ctl,"pose_recovery_"..window.index.."_"..pose.frame,message)end
    end
    local function capture(world)
        pose.sample=nil
        local unit,state,view,owned=context(world)
        if unit~=pose.active_unit then return end
        local weapon=linked_weapon(unit,state)
        if not weapon or not env.Quaternion or type(env.Quaternion.rotate)~="function"
            or type(env.Unit.has_node)~="function" or type(env.Unit.node)~="function"
            or type(env.Unit.world_rotation)~="function" or not env.Unit.has_node(weapon,"j_muzzle") then return end
        local index=env.Unit.node(weapon,"j_muzzle")
        if not finite(index) or index<0 or index%1~=0 then return end
        local origin=xyz(env.Unit.world_position(weapon,index))
        local root=xyz(env.Unit.world_position(unit,0))
        local direction=normalized(env.Quaternion.rotate(env.Unit.world_rotation(weapon,index),env.Vector3(0,1,0)))
        local _,ray=view:aim_ray(env.CameraManager)
        if not origin or not root or not same_direction(direction,normalized(ray)) then return end
        pose.sample={unit=unit,state=state,weapon=weapon,world=world,camera=owned.camera,
            origin=origin,root=root,direction=direction,frame=pose.frame}
    end
    function pose:scene(original,world,...)
        local result=pack(pcall(original,world,...))
        if not result[1] then
            self.sample=nil;self.observer=nil;self.recovery_previous=nil;self.recovery_window=nil;error(result[2],0)
        end
        local observed,observation_problem=pcall(observe,world)
        if not observed then self.observer=nil;self.observation_reason="getter_error";note("observer","Native upper-body observation skipped: "..tostring(observation_problem))end
        local good,problem=pcall(capture,world)
        if not good then self.sample=nil;note("sample","Native muzzle sample skipped: "..tostring(problem)) end
        if not pcall(capture_geometry,world) then self.geometry_failed=true end
        if not pcall(capture_recovery,world)then self.recovery_previous=nil;self.recovery_window=nil end
        return unpack(result,2,result.n)
    end
    function pose:render(original,world,camera,...)
        return original(world,camera,...)
    end
    function pose:shot_sample(unit,weapon,root)
        local good,result=pcall(function()
            local sample=self.sample
            root=xyz(root)
            if not sample or not root or self.frame-sample.frame>1 or sample.unit~=unit or sample.weapon~=weapon then return nil end
            local actual,state,view,owned=context(sample.world)
            if actual~=unit or state~=sample.state or owned.camera~=sample.camera or linked_weapon(unit,state)~=weapon then return nil end
            local _,ray=view:aim_ray(env.CameraManager)
            if not same_direction(sample.direction,normalized(ray)) then return nil end
            return {origin={x=sample.origin.x+root.x-sample.root.x,y=sample.origin.y+root.y-sample.root.y,
                z=sample.origin.z+root.z-sample.root.z},direction=xyz(sample.direction)}
        end)
        return good and result or nil
    end
    return pose
end
return Pose
