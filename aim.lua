-- Redirect local firearm rays and native grenade/flare throw directions.
-- Native batching, spread, damage callbacks, power and physics stay in charge.
local Aim={}
local function pack(...)return{n=select("#",...),...}end
local function finite(n)return type(n)=="number"and n==n and math.abs(n)<math.huge end
local function vector(v)
    if not v then return nil end
    local x,y,z=v.x,v.y,v.z
    if finite(x)and finite(y)and finite(z)then return{x=x,y=y,z=z}end
end
local function normalized(v)
    if not v then return nil end
    local length=math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
    if not finite(length)or length<0.000001 then return nil end
    return{x=v.x/length,y=v.y/length,z=v.z/length}
end
local function dot(a,b)return a.x*b.x+a.y*b.y+a.z*b.z end
local function cross(a,b)return{x=a.y*b.z-a.z*b.y,y=a.z*b.x-a.x*b.z,z=a.x*b.y-a.y*b.x}end
local function rotated(direction,from,to)
    local cosine=math.max(-1,math.min(1,dot(from,to)))
    if cosine< -0.999999 then
        local axis=normalized(cross(from,math.abs(from.x)<0.9 and{x=1,y=0,z=0}or{x=0,y=1,z=0}))
        local projection=2*dot(axis,direction)
        return normalized({x=projection*axis.x-direction.x,y=projection*axis.y-direction.y,z=projection*axis.z-direction.z})
    end
    local axis=cross(from,to)
    local first=cross(axis,direction)
    local second=cross(axis,first)
    return normalized({x=direction.x+first.x+second.x/(1+cosine),y=direction.y+first.y+second.y/(1+cosine),
        z=direction.z+first.z+second.z/(1+cosine)})
end

function Aim.new(env,ctl,config)
    local aim={samples=0,source_records=setmetatable({},{__mode="k"})}
    local function engine_vector(value)return env.Vector3(value.x,value.y,value.z)end
    local function context()
        if not ctl.enabled or type(ctl.active_local_unit)~="function"then return nil end
        local view=ctl.view
        if not view or(view.mode~="first"and view.mode~="shoulder")or type(view.aim_ray)~="function"then return nil end
        local unit=ctl:active_local_unit(env.CameraManager)
        if not unit then return nil end
        local origin,direction,target=view:aim_ray(env.CameraManager)
        origin=vector(origin);direction=normalized(vector(direction))
        if not origin or not direction then return nil end
        -- Native Vector3 temporaries must never survive another engine call.
        return{unit=unit,origin=origin,direction=direction,target=vector(target)}
    end
    local function local_weapon(weapon,entry,sample)
        local entity,unit=env.EntityAux,env.Unit
        if not entity or type(entity.owned)~="function"or type(entity.state)~="function"or type(entity.has_component)~="function"
            or not unit or type(unit.alive)~="function"or not unit.alive(weapon)then return nil end
        if not entity.has_component(weapon,"equipment")then return nil end
        local equipment=entity.state(weapon,"equipment")
        if type(equipment)~="table"or equipment.wielder~=sample.unit then return nil end
        if entity.owned(weapon)~=true then
            if not aim.ownership_noted then
                aim.ownership_noted=true
                if type(ctl.log)=="function"then pcall(ctl.log,ctl,"Local firearm aim blocked: ownership!=true")end
            end
            return nil
        end
        local state=type(entry)=="table"and entry.state
        if type(state)~="table"or not state.raycast_slave or not state.firedir_override then return nil end
        local range=state.range==nil and 20 or state.range
        local multiplier=state.range_multiplier==nil and 1 or state.range_multiplier
        if not finite(range)or not finite(multiplier)or range<=0 or multiplier<=0 or not finite(range*multiplier)then return nil end
        local ray=state.raycast_slave
        if type(ray.cast)~="function"then return nil end
        return{weapon=weapon,state=state,ray=ray,cast=ray.cast,range=range*multiplier,sample=sample}
    end
    local function source_context(unit)
        local api,entity=env.Unit,env.EntityAux
        if not api or not entity or type(entity.state_master)~="function"then return nil end
        local character=entity.state_master(unit,"character")
        local health=type(character)=="table"and character.health_state
        if type(health)~="table"or health.is_dead or health.is_downed or character.is_dead or character.is_downed
            or character.has_extracted or character.do_knockdown
            or(character.current_seat_unit and api.alive(character.current_seat_unit))
            or(character.current_carry_unit and api.alive(character.current_carry_unit))then return nil end
        return true
    end
    local function muzzle_source(shot)
        local api,q,aux=env.Unit,env.Quaternion,env.Vector3Aux
        if type(api.world_position)~="function"or type(api.world_rotation)~="function"or not q
            or type(q.inverse)~="function"or type(q.rotate)~="function"or not aux or type(aux.box)~="function"
            or not source_context(shot.sample.unit)then return nil end
        local root=vector(api.world_position(shot.sample.unit,0));if not root then return nil end
        local origin,direction
        local pose=ctl.pose
        if pose and type(pose.shot_sample)=="function"then
            local good,value=pcall(pose.shot_sample,pose,shot.sample.unit,shot.weapon,{x=root.x,y=root.y,z=root.z})
            if good and type(value)=="table"then
                local from,axis=vector(value.origin),normalized(vector(value.direction))
                if from and axis and dot(axis,shot.sample.direction)>=0.984807753012208 then origin,direction=from,axis end
            end
        end
        if not origin then
            if type(api.has_node)~="function"or type(api.node)~="function"or api.has_node(shot.weapon,"j_muzzle")~=true then return nil end
            local node=api.node(shot.weapon,"j_muzzle")
            if not finite(node)or node<0 or node%1~=0 then return nil end
            origin=vector(api.world_position(shot.weapon,node));if not origin then return nil end
        end
        local offset=vector(q.rotate(q.inverse(api.world_rotation(shot.sample.unit,shot.state.attach_node)),
            engine_vector({x=origin.x-root.x,y=origin.y-root.y,z=origin.z-root.z})))
        if not offset then return nil end
        local boxed=aux.box({},engine_vector(offset))
        if type(boxed)~="table"or not vector(boxed)then return nil end
        return boxed,direction
    end
    local function ignored(unit,shot)
        if unit==shot.weapon or unit==shot.sample.unit then return true end
        local list=shot.state.ignored_units
        if type(list)=="table"then
            for key,value in pairs(list)do if value==unit or(key==unit and value==true)then return true end end
        else return list~=nil and list==unit end
        return false
    end
    local function camera_hit(component,shot)
        local physics,world,actor=env.PhysicsWorld,env.World,env.Actor
        if not physics or type(physics.immediate_raycast)~="function"or not actor or type(actor.unit)~="function"
            or not component.world_proxy then return nil end
        local proxy=component.world_proxy
        local physics_world
        if type(proxy.get_physics_world)=="function"then physics_world=proxy:get_physics_world()
        elseif world and type(world.physics_world)=="function"and type(proxy.get_world)=="function"then
            physics_world=world.physics_world(proxy:get_world())
        end
        if not physics_world then return nil end
        -- Confirmed native signature; rows are position,distance,normal,actor.
        local hits=physics.immediate_raycast(physics_world,engine_vector(shot.sample.origin),engine_vector(shot.sample.direction),
            shot.range,"all","collision_filter","damage_ray")
        local nearest,distance
        if type(hits)=="table"then
            for _,hit in ipairs(hits)do
                if type(hit)=="table"and finite(hit[2])and hit[2]>=0.0001 and hit[2]<=shot.range and hit[4]then
                    local good,unit=pcall(actor.unit,hit[4])
                    local position=vector(hit[1])
                    if good and unit and position and not ignored(unit,shot)and(not distance or hit[2]<distance)then
                        nearest,distance=position,hit[2]
                    end
                end
            end
        end
        return nearest
    end
    local function direction_for(component,shot,origin,direction)
        origin=vector(origin);direction=normalized(vector(direction))
        if not origin or not direction then return nil end
        local state,sample=shot.state,shot.sample
        local forward=normalized(vector(env.Quaternion.forward(env.Unit.world_rotation(sample.unit,state.attach_node))))
        local offset=vector(env.Vector3Aux.unbox(state.ray_source_offset))
        if not forward or not offset then return nil end
        -- WeaponUtility's zero-spread result is forward + .125*forward.z*up
        -- minus offset.z/range*up. Align that centre, retaining each sampled
        -- pellet's angular deviation through one rigid rotation.
        local baseline=normalized({x=forward.x,y=forward.y,z=forward.z*1.125-offset.z/shot.range})
        if not baseline then return nil end
        local target,source=sample.target,"view"
        if shot.pose_direction then
            local axis=shot.pose_direction
            target={x=origin.x+axis.x*shot.range,y=origin.y+axis.y*shot.range,z=origin.z+axis.z*shot.range}
            return rotated(direction,baseline,axis),"pose",origin,target
        end
        if not target then
            local good,hit=pcall(camera_hit,component,shot)
            if good then target=hit end
            source=target and"collision"or"range"
        end
        if not target then target={x=sample.origin.x+sample.direction.x*shot.range,
            y=sample.origin.y+sample.direction.y*shot.range,z=sample.origin.z+sample.direction.z*shot.range}end
        local axis=normalized({x=target.x-origin.x,y=target.y-origin.y,z=target.z-origin.z})
        if not axis then return nil end
        local result=rotated(direction,baseline,axis)
        return result,source,origin,target
    end
    local function diagnostic(shot,direction,source,origin,target)
        local pitch=math.asin(math.max(-1,math.min(1,shot.sample.direction.z)))
        local sign=pitch>0.0001 and 1 or pitch< -0.0001 and -1 or 0
        if aim.samples<3 or aim.last_sign~=sign then
            aim.samples=aim.samples+1;aim.last_sign=sign
            if type(ctl.log)=="function"then
                pcall(ctl.log,ctl,string.format("Local firearm aim weapon=%s origin=(%.3f,%.3f,%.3f) ray_z=%.6f pitch=%.3f target=%s(%.3f,%.3f,%.3f)",
                    tostring(shot.weapon),origin.x,origin.y,origin.z,direction.z,pitch,source,target.x,target.y,target.z))
            end
        end
    end
    function aim:update(original,component,entries,...)
        if self.busy or type(entries)~="table"then return original(component,entries,...)end
        local good,sample=pcall(context)
        if not good or not sample then return original(component,entries,...)end
        local shots,seen,shared={},{},{}
        for _,entry in pairs(entries)do
            local state=type(entry)=="table"and entry.state
            if type(state)=="table"then shared[state]=shared[state]and 2 or 1 end
        end
        for state,count in pairs(shared)do if count>1 then self.source_records[state]=nil end end
        for weapon,entry in pairs(entries)do
            local valid,shot=pcall(local_weapon,weapon,entry,sample)
            if valid and shot and shared[shot.state]==1 and not seen[shot.state]then shots[#shots+1]=shot;seen[shot.state]=true end
        end
        if #shots==0 then return original(component,entries,...)end
        for _,shot in ipairs(shots)do
            local prepared,offset,axis=pcall(muzzle_source,shot)
            if prepared and offset then
                shot.original_offset=shot.state.ray_source_offset;shot.state.ray_source_offset=offset;shot.source_changed=true;shot.pose_direction=axis
                if not axis and not self.alignment_noted then
                    self.alignment_noted=true
                    if type(ctl.log)=="function"then pcall(ctl.log,ctl,"Local muzzle origin active; visual weapon alignment pending")end
                end
            end
            shot.state.raycast_slave={cast=function(_,origin,direction,...)
                local cast_origin=vector(origin)
                local ok,value,source,from,target=pcall(direction_for,component,shot,origin,direction)
                if ok and value then
                    local made,converted=pcall(engine_vector,value)
                    if made then
                        local boxed=pcall(env.Vector3Aux.box,shot.state.firedir_override,converted)
                        if boxed then direction=converted;pcall(diagnostic,shot,value,source,from,target)end
                    end
                end
                if shot.source_changed then
                    aim.source_records[shot.state]={weapon=shot.weapon,unit=sample.unit,origin=cast_origin}
                end
                -- No pcall/retry around native cast: one shot remains one shot.
                return shot.cast(shot.ray,origin,direction,...)
            end}
        end
        self.busy=true
        local result=pack(pcall(original,component,entries,...))
        self.busy=false
        for _,shot in ipairs(shots)do
            shot.state.raycast_slave=shot.ray
            if shot.source_changed then shot.state.ray_source_offset=shot.original_offset end
            if not result[1]then self.source_records[shot.state]=nil end
        end
        if not result[1]then error(result[2],0)end
        return unpack(result,2,result.n)
    end
    function aim:callback(original,weapon,entry,...)
        local made=pack(original(weapon,entry,...))
        local callback=made[1]
        if type(callback)~="function"then return unpack(made,1,made.n)end
        local state=type(entry)=="table"and entry.state
        made[1]=function(...)
            if aim.callback_depth then
                aim.callback_depth=aim.callback_depth+1
                local result=pack(pcall(callback,...));aim.callback_depth=aim.callback_depth-1
                if not result[1]then error(result[2],0)end
                return unpack(result,2,result.n)
            end
            local valid,origin,direction,record=pcall(function()
                local record=state and aim.source_records[state]
                local sample=context()
                if not record or entry.state~=state or record.weapon~=weapon or not sample or sample.unit~=record.unit
                    or not local_weapon(weapon,entry,sample)or not source_context(sample.unit)then return nil end
                local from=vector(env.Vector3Aux.unbox(state.last_ray_from))
                local axis=normalized(vector(env.Vector3Aux.unbox(state.firedir_override)))
                local saved=record.origin
                if not from or not axis or not saved or math.abs(from.x-saved.x)+math.abs(from.y-saved.y)+math.abs(from.z-saved.z)>0.0001 then return nil end
                return from,axis,record
            end)
            local api=env.Unit
            if not valid or not origin or not direction or not api or type(api.flow_event)~="function"or type(api.set_flow_variable)~="function"then return callback(...)end
            if not aim.callback_noted then
                aim.callback_noted=true
                if type(ctl.log)=="function"then pcall(ctl.log,ctl,"Local firearm native callback wrapped; muzzle miss output available")end
            end
            local flow,set=api.flow_event,api.set_flow_variable
            local own_flow,own_set=rawget(api,"flow_event"),rawget(api,"set_flow_variable")
            local hit
            rawset(api,"set_flow_variable",function(unit,name,value,...)
                if aim.callback_depth==1 and unit==weapon and name=="hit"then hit=value end
                return set(unit,name,value,...)
            end)
            rawset(api,"flow_event",function(unit,event,...)
                if aim.callback_depth==1 and unit==weapon and event=="on_raycast"and hit==false then
                    -- The original miss branch uses a captured standing offset.
                    -- Correct only its output immediately before the native flow.
                    pcall(function()
                        local current=context()
                        if entry.state~=state or aim.source_records[state]~=record or not current or current.unit~=record.unit
                            or not source_context(current.unit)or not local_weapon(weapon,entry,current)then return end
                        set(unit,"hit_position",engine_vector({x=origin.x+direction.x*100,y=origin.y+direction.y*100,z=origin.z+direction.z*100}))
                    end)
                end
                return flow(unit,event,...)
            end)
            aim.callback_depth=1
            local result=pack(pcall(callback,...))
            aim.callback_depth=nil;rawset(api,"flow_event",own_flow);rawset(api,"set_flow_variable",own_set)
            if not result[1]then error(result[2],0)end
            return unpack(result,2,result.n)
        end
        return unpack(made,1,made.n)
    end
    local function throw_context(component,unit,entry,power)
        -- Native calls with zero power deliberately drop a grenade on health
        -- interruption/dodge. Keep that behavior and all incapacitated states.
        if type(component)~="table"or not finite(power)or power<=0 then return nil end
        local sample=context()
        if not sample or sample.unit~=unit then return nil end
        local state=type(entry)=="table"and entry.state
        local health=type(state)=="table"and state.health_state
        if type(health)~="table"or health.is_dead or health.is_downed or state.is_dead or state.is_downed
            or state.has_extracted or state.do_knockdown then return nil end
        local current=state.current_state
        if not current or(current~=env.CharacterStateThrow and current~=env.CharacterStateStratagemsThrow)then return nil end
        local entity,api=env.EntityAux,env.Unit
        if not entity or type(entity.owned)~="function"or not api or type(api.alive)~="function"
            or api.alive(unit)~=true or entity.owned(unit)~=true then return nil end
        if(state.current_seat_unit and api.alive(state.current_seat_unit))
            or(state.current_carry_unit and api.alive(state.current_carry_unit))then return nil end
        if type(component.queue_command_master)~="function"or not env.Vector3Aux
            or type(env.Vector3Aux.box)~="function"then return nil end
        return sample
    end
    local function throw_payload(payload,sample)
        if type(payload)~="table"or not finite(payload.power)or payload.power<=0
            or not vector(payload.direction)then return nil end
        local direction=env.Vector3Aux.box({},engine_vector(sample.direction))
        local copy={};for key,value in pairs(payload)do copy[key]=value end
        copy.direction=direction
        return copy
    end
    function aim:throw(original,component,unit,entry,power,...)
        if self.throw_depth then
            -- A nested original call must not inherit the outer redirection.
            self.throw_depth=self.throw_depth+1
            local result=pack(pcall(original,component,unit,entry,power,...))
            self.throw_depth=self.throw_depth-1
            if not result[1]then error(result[2],0)end
            return unpack(result,2,result.n)
        end
        local good,sample=pcall(throw_context,component,unit,entry,power)
        if not good or not sample then return original(component,unit,entry,power,...)end
        local inherited,queue=rawget(component,"queue_command_master"),component.queue_command_master
        rawset(component,"queue_command_master",function(self,target,kind,command,payload,...)
            if self==component and aim.throw_depth==1 and target==unit and kind=="inventory"and command=="throw"then
                local changed,value=pcall(throw_payload,payload,sample)
                if changed and value then
                    payload=value
                    aim.throw_samples=(aim.throw_samples or 0)+1
                    if aim.throw_samples<=6 and type(ctl.log)=="function"then
                        pcall(ctl.log,ctl,string.format("Local hand throw aim prepared: dir=(%.6f,%.6f,%.6f) power=%.6f",
                            sample.direction.x,sample.direction.y,sample.direction.z,payload.power))
                    end
                end
            end
            -- The real enqueue/consumer remains native, including errors.
            return queue(self,target,kind,command,payload,...)
        end)
        self.throw_depth=1
        local result=pack(pcall(original,component,unit,entry,power,...))
        rawset(component,"queue_command_master",inherited)
        self.throw_depth=nil
        if not result[1]then error(result[2],0)end
        return unpack(result,2,result.n)
    end
    return aim
end
return Aim
