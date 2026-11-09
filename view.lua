-- A separate render camera owns close views. Never write the game's camera.
local View={}
local function pack(...)return {n=select("#",...),...}end
local function clone(value)local out={}for key,item in pairs(value)do out[key]=item end return out end
local function finite(value)return type(value)=="number" and value==value and math.abs(value)<math.huge end
local function number(value)return finite(value) and value or 0 end
local function length_xy(value)return value and number(value.x)^2+number(value.y)^2 or 0 end
local filter_groups={invert=true,switch=true,combine=true,set_static=true,remove_static=true}
local function filter_kind(filter)
    if filter==nil or filter==false then return "neutral"end
    if type(filter)~="table"then return "unknown"end
    -- Native remove_static restores controls but retains all five empty maps.
    local active=false
    for name in pairs(filter_groups)do
        local group=rawget(filter,name)
        if type(group)~="table"then return "unknown"end
        if next(group)~=nil then active=true end
    end
    for name in pairs(filter)do if not filter_groups[name]then return "unknown"end end
    return active and "active"or"neutral"
end

function View.new(env,ctl,config)
    config=config or {}
    local view={mode="top",yaw=0,pitch=0,render_ready=false,ray_ready=false}
    local labels={top="TOP",shoulder="SHOULDER",first="FIRST"}
    local sensitivity=finite(config.mouse_sensitivity)and config.mouse_sensitivity or 0.0025
    if config.sky then view.sky=config.sky.new(env,ctl,config)end
    function view:note(key,message)
        if type(ctl.once)=="function"then pcall(ctl.once,ctl,"view_"..key,message)end
    end
    function view:status()
        if type(ctl.camera_target)=="function"then
            local good,target=pcall(ctl.camera_target,ctl,env.CameraManager)
            if good and target and target~=ctl.local_unit then return "VEHICLE TOP"end
        end
        local label=labels[self.mode]
        label=self.mode~="top" and self.fallback and label.." (TOP FALLBACK)" or label
        if self.mode~="top"and self.sky then
            local good,status=pcall(self.sky.status,self.sky)
            if good and type(status)=="string"then label=label.." | "..status end
        end
        return label
    end
    function view:restore_cursor()
        if self.cursor_visibility~=nil then
            local cursor=env.CursorManager
            if cursor and type(cursor.set_show_cursor)=="function"then pcall(cursor.set_show_cursor,cursor,self.cursor_visibility)end
            self.cursor_visibility=nil
        end
    end
    function view:world(manager)
        return manager.viewport:get_world_proxy():get_world()
    end
    function view:clear_sky(manager)
        if not self.sky then return end
        local good,world=pcall(self.world,self,manager)
        local cleared,problem=pcall(self.sky.release,self.sky,good and world or nil)
        if not cleared then self:note("sky_release",tostring(problem))end
    end
    function view:release(manager)
        local owned=self.owned
        self.owned=nil;self.desired=nil;self.render_ready=false;self.ray_ready=false
        self:restore_cursor()
        self:clear_sky(manager)
        if not owned then return end
        -- Another world may already have destroyed its units. Do not call a
        -- stale world's API; world teardown owns that cleanup.
        local good,current_world=pcall(self.world,self,manager)
        if good and current_world==owned.world then
            pcall(function()
                if env.Unit.alive(owned.unit)then env.World.destroy_unit(owned.world,owned.unit)end
            end)
        end
    end
    function view:fail_closed(manager,key,problem)
        self.mode="top";self.fallback=nil;self.look_unit=nil;ctl.enabled=false
        self:release(manager)
        self:note(key,"Close view disabled: "..tostring(problem))
    end
    function view:poll_toggle()
        if self.sky then
            local good,problem=pcall(self.sky.poll_toggle,self.sky)
            if not good then self:note("sky_toggle",tostring(problem))end
        end
        local keyboard=env.Keyboard
        if not keyboard or type(keyboard.button_index)~="function" or type(keyboard.button)~="function"then return end
        local good,down=pcall(function()return keyboard.button(keyboard.button_index("f9"))>=0.5 end)
        if not good then return end
        if down and not self.key_down then
            local previous=self.mode
            self.mode=self.mode=="top" and "shoulder" or self.mode=="shoulder" and "first" or "top"
            if previous=="top"then self.look_unit=nil end
            self.fallback=nil
            if not ctl.enabled then ctl:set_enabled(true)end
            if self.mode=="top"then self.render_ready=false;self.ray_ready=false;self:restore_cursor()end
            if type(ctl.log)=="function"then pcall(ctl.log,ctl,"View selected: "..labels[self.mode])end
        end
        self.key_down=down
    end
    function view:supported(manager)
        local camera,unit,q,world=env.Camera,env.Unit,env.Quaternion,env.World
        if not camera or not unit or not q or not world or not env.Vector3 or not env.Vector3Aux or not env.QuaternionAux then return false end
        for _,name in ipairs({"set_local_position","set_local_rotation","set_vertical_fov","set_near_range"})do
            if type(camera[name])~="function"then return false end
        end
        return type(unit.alive)=="function" and type(unit.world_position)=="function" and type(unit.world_rotation)=="function" and type(unit.camera)=="function"
            and type(world.spawn_unit)=="function" and type(world.destroy_unit)=="function" and type(world.update_unit)=="function"
            and type(q.forward)=="function" and type(q.look)=="function"
            and type(env.Vector3Aux.box)=="function" and type(env.Vector3Aux.unbox)=="function"
            and type(env.QuaternionAux.box)=="function" and type(env.QuaternionAux.unbox)=="function"
            and type(manager)=="table" and type(manager.camera)=="function" and type(manager.camera_unit)=="function"
    end
    function view:map_open(unit)
        local character=env.CharacterComponent
        if not character or type(character.get_hud_state)~="function"then return false end
        local good,hud=pcall(character.get_hud_state,unit)
        return good and hud=="map"
    end
    function view:context_allowed(manager,component,state,allow_map,display_only)
        if self.mode=="top" or not ctl.enabled then return nil,"top or disabled"end
        if not self:supported(manager)then return nil,"camera API unavailable"end
        local unit=ctl:active_local_unit(manager)
        if not unit then return nil,"local target unavailable"end
        if type(component)~="table" or(component.current_state~="game" and component.current_state~="tutorial")then return nil,"outside gameplay"end
        if type(state)~="table" or state.pad_number~=(env.KEYBOARD_MOUSE_PAD_NUMBER or 0)then return nil,"keyboard/mouse only"end
        if not state.input_data or not state.input_data.is_active or not state.has_focus then return nil,"inactive input"end
        if state.character_input_disabled or state.mouse_aim_disabled then return nil,"input restricted"end
        local filter=filter_kind(state.input_filter)
        -- Only camera submission may display through a known active filter.
        if filter=="unknown"or(filter=="active"and not display_only)then return nil,"input restricted"end
        if not env.EntityAux or type(env.EntityAux.state)~="function"then return nil,"character API unavailable"end
        local character=env.EntityAux.state(unit,"character")
        if type(character)~="table"then return nil,"character state unavailable"end
        local health=character.health_state or character
        if health.is_dead or health.is_downed or character.is_dead or character.is_downed then return nil,"dead or downed"end
        if character.current_seat_unit and env.Unit.alive(character.current_seat_unit)then return nil,"seated"end
        if not allow_map and self:map_open(unit)then return nil,"map"end
        return unit
    end
    function view:check_context(manager,component,state,allow_map,display_only)
        local good,unit,reason=pcall(self.context_allowed,self,manager,component,state,allow_map,display_only)
        if not good then self:note("context",tostring(unit));return nil,"context API error"end
        return unit,reason
    end
    function view:restore(manager)
        local previous=self.render_ready
        self.render_ready=false
        local context=self.input_context
        if not context or not self:check_context(manager,context.component,context.state)then self.ray_ready=false;self:restore_cursor()end
        if not context or not self:check_context(manager,context.component,context.state,true,true)then self:clear_sky(manager)end
        -- Original camera was never changed; no pose/FOV restoration is needed.
        return previous
    end
    function view:ensure_camera(manager)
        local world=self:world(manager)
        local source_camera,source_unit=manager:camera(),manager:camera_unit()
        local owned=self.owned
        if owned and owned.world==world and owned.viewport==manager.viewport and owned.source_camera==source_camera
            and owned.source_unit==source_unit and env.Unit.alive(owned.unit)then return owned end
        self:release(manager)
        local unit=env.World.spawn_unit(world,"core/units/camera")
        if not unit then error("Dedicated camera unit was not created",0)end
        local good,camera=pcall(env.Unit.camera,unit,"camera")
        if not good or not camera then
            pcall(env.World.destroy_unit,world,unit)
            error("Dedicated camera object unavailable: "..tostring(camera),0)
        end
        self.owned={world=world,unit=unit,camera=camera,viewport=manager.viewport,source_camera=source_camera,source_unit=source_unit}
        if type(env.Camera.set_projection_type)=="function" and env.Camera.PERSPECTIVE~=nil then env.Camera.set_projection_type(camera,env.Camera.PERSPECTIVE)end
        if type(env.Camera.far_range)=="function" and type(env.Camera.set_far_range)=="function"then
            local far=env.Camera.far_range(source_camera)
            if finite(far) and far>1 then env.Camera.set_far_range(camera,far)end
        end
        self:note("dedicated_created","Dedicated core camera created; original camera preserved")
        return self.owned
    end
    function view:write_pose(owned)
        local desired=self.desired
        env.Camera.set_local_position(owned.camera,owned.unit,env.Vector3Aux.unbox(desired.position))
        env.Camera.set_local_rotation(owned.camera,owned.unit,env.QuaternionAux.unbox(desired.rotation))
        env.Camera.set_vertical_fov(owned.camera,desired.fov)
        env.Camera.set_near_range(owned.camera,desired.near)
        env.World.update_unit(owned.world,owned.unit)
    end
    function view:camera_ray(unit)
        local root=env.Unit.world_position(unit,0)
        local rootx,rooty,rootz=root and root.x,root and root.y,root and root.z
        if not finite(rootx) or not finite(rooty) or not finite(rootz) or not finite(self.yaw) or not finite(self.pitch)then
            error("Close view transform unavailable",0)
        end
        -- Snapshot before querying another native transform: temporary vectors
        -- must not be retained across engine calls or animation updates.
        root=nil
        local sx,sy=-math.sin(self.yaw),math.cos(self.yaw)
        -- Root-relative, view-yaw clearance keeps the eye ahead of the body
        -- instead of placing it in the forward-leaning head when running.
        -- Standing keeps its root profile. Prone below may read the native
        -- head transform; neither skeleton nor mesh visibility is written.
        local distance,height,right=self.mode=="first" and 0.85 or -3.2,self.mode=="first" and 1.55 or 1.6,self.mode=="first" and 0 or 0.55
        local x,y,z=rootx,rooty,rootz
        local good,prone=pcall(function()
            local radio=ctl.stratagems
            if radio and type(radio.prone)=="function"and radio:prone(unit)then return true end
            local master=env.EntityAux and env.EntityAux.state_master
            if type(master)~="function"then return false end
            local character=master(unit,"character")
            local current=type(character)=="table"and character.current_state
            return current~=nil and((env.CharacterStateDodge~=nil and current==env.CharacterStateDodge)
                or(env.CharacterStateCrawl~=nil and current==env.CharacterStateCrawl))
        end)
        if good and prone then
            local valid,head=pcall(function()
                if type(env.Unit.has_node)~="function"or type(env.Unit.node)~="function"or not env.Unit.has_node(unit,"head")then return nil end
                local node=env.Unit.node(unit,"head")
                if not finite(node)or node<=0 or node~=math.floor(node)then return nil end
                local value=env.Unit.world_position(unit,node)
                if value and finite(value.x)and finite(value.y)and finite(value.z)then return{x=value.x,y=value.y,z=value.z}end
            end)
            head=valid and head or nil
            if self.mode=="first"then
                distance,height=0.4,0.45
                if head then x,y,z=head.x,head.y,math.max(head.z+0.05,rootz+0.25);height=0 end
            else
                height=head and math.max(head.z-rootz+0.3,0.75)or 0.8
            end
        end
        local position=env.Vector3(x+sx*distance+sy*right,y+sy*distance-sx*right,z+height)
        local direction=env.Vector3(sx*math.cos(self.pitch),sy*math.cos(self.pitch),math.sin(self.pitch))
        return position,direction
    end
    function view:aim_ray(manager)
        if not self.ray_ready then return nil end
        local context=self.input_context
        local unit=self:check_context(manager,context and context.component,context and context.state)
        if not unit then return nil end
        -- A map may preserve the close camera, but must never enable firing.
        local good,position,direction=pcall(function()
            if env.CharacterComponent and type(env.CharacterComponent.get_hud_state)=="function"
                and env.CharacterComponent.get_hud_state(unit)=="map"then return nil end
            return self:camera_ray(unit)
        end)
        if not good then self:note("aim_ray",tostring(position));return nil end
        return position,direction
    end
    function view:update_pose(unit,owned)
        local position,direction=self:camera_ray(unit)
        self.desired={position=env.Vector3Aux.box({},position),rotation=env.QuaternionAux.box({},env.Quaternion.look(direction,env.Vector3(0,0,1))),
            fov=math.rad(self.mode=="first" and 75 or 65),near=0.06}
        self:write_pose(owned)
    end
    function view:draw_reticle(manager,unit,owned)
        local context=self.input_context
        local gui=context and context.component and context.component.cursor_gui
        if not gui or not env.Gui or type(env.Gui.bitmap_uv)~="function" or not env.Vector2 or not env.Color
            or type(env.Camera.world_to_screen)~="function"then return end
        local good,problem=pcall(function()
            local width,height,left,top=manager.viewport:window()
            left,top=left or 0,top or 0
            local origin,direction=self:aim_ray(manager)
            if not origin or not direction then return end
            -- Copy native temporaries before optional rig/weapon API calls.
            local ox,oy,oz,dx,dy,dz=origin.x,origin.y,origin.z,direction.x,direction.y,direction.z
            local pose=ctl.pose
            if pose and type(pose.shot_sample)=="function"then
                local valid,sample=pcall(function()
                    local entity=env.EntityAux
                    local getter=entity and(entity.state_master or entity.state)
                    if type(getter)~="function"then return nil end
                    local character=getter(unit,"character")
                    local weapon=type(character)=="table"and character.current_weapon
                    if not weapon or not env.Unit.alive(weapon)then return nil end
                    local root=env.Unit.world_position(unit,0)
                    local copy={x=root.x,y=root.y,z=root.z}
                    return pose:shot_sample(unit,weapon,copy)
                end)
                local a,b=valid and type(sample)=="table"and sample.origin,valid and type(sample)=="table"and sample.direction
                if a and b and finite(a.x)and finite(a.y)and finite(a.z)and finite(b.x)and finite(b.y)and finite(b.z)then
                    local length=math.sqrt(b.x*b.x+b.y*b.y+b.z*b.z)
                    if finite(length)and length>0.000001 then
                        ox,oy,oz,dx,dy,dz=a.x,a.y,a.z,b.x/length,b.y/length,b.z/length
                    end
                end
            end
            local target=env.Vector3(ox+dx*20,oy+dy*20,oz+dz*20)
            local screen=env.Camera.world_to_screen(owned.camera,target,width,height)
            if not screen or not finite(screen.x) or not finite(screen.y) or not finite(screen.z) or screen.y<=0
                or screen.x<0 or screen.x>width or screen.z<0 or screen.z>height then return end
            env.Gui.bitmap_uv(gui,"cursor_game",env.Vector2(0,0),env.Vector2(1,1),
                env.Vector3(screen.x+left-12,screen.z+top-12,100),env.Vector2(24,24),env.Color(255,255,255,255))
        end)
        if not good then self:note("reticle",tostring(problem))end
    end
    function view:apply(manager,dt)
        local context=self.input_context
        local unit,reason=self:check_context(manager,context and context.component,context and context.state,true,true)
        if not unit then self.render_ready=false;self.ray_ready=false;self.fallback=self.mode~="top" and reason or nil;self:clear_sky(manager);return false end
        local good,problem=pcall(function()
            self:initialize_look(unit)
            local owned=self:ensure_camera(manager)
            self:update_pose(unit,owned)
            self.render_ready=true;self.ray_ready=not self:map_open(unit)and filter_kind(context.state.input_filter)=="neutral"
        end)
        if not good then self:fail_closed(manager,"apply",problem);return false end
        self.fallback=nil
        self:note("active_"..self.mode,"Dedicated camera active: "..self.mode)
        return true
    end
    function view:commit_render(manager,world,source_camera)
        local owned=self.owned
        if not self.render_ready or not owned or owned.world~=world or owned.source_camera~=source_camera then return nil end
        if manager.viewport~=owned.viewport or manager:camera()~=source_camera or manager:camera_unit()~=owned.source_unit then return nil end
        local context=self.input_context
        local unit=self:check_context(manager,context and context.component,context and context.state,true,true)
        if not unit or not env.Unit.alive(owned.unit)then self:restore(manager);return nil end
        self.ray_ready=self.ray_ready and filter_kind(context.state.input_filter)=="neutral"
        -- Animation/movement can advance after CameraManager.update. Sample
        -- root/head again so render never reuses the previous animated pose.
        self:update_pose(unit,owned)
        if self.sky then
            local good,problem=pcall(function()
                self.sky:draw(owned.world,owned.camera,owned.viewport,
                    env.Vector3Aux.unbox(self.desired.position),self.yaw,self.pitch,self.desired.fov)
            end)
            if not good then self:note("sky_draw",tostring(problem));self:clear_sky(manager)end
        end
        self:draw_reticle(manager,unit,owned)
        self.render_samples=(self.render_samples or 0)+1
        if self.render_samples<=3 and type(ctl.log)=="function"then
            pcall(ctl.log,ctl,"Dedicated render selected: "..self.mode.." sample="..self.render_samples)
        end
        return owned.camera
    end
    function view:initialize_look(unit)
        if self.look_unit~=unit then
            local direction=env.Quaternion.forward(env.Unit.world_rotation(unit,0))
            if length_xy(direction)<=0.000001 then error("Local forward vector unavailable",0)end
            self.yaw=math.atan2(-number(direction.x),number(direction.y))
            self.pitch=0
            self.look_unit=unit
        end
    end
    function view:rotate_movement(value,spin)
        local x,y,z=number(value.x),number(value.y),number(value.z)
        local delta=self.yaw-number(spin)
        return env.Vector3Aux.box({},env.Vector3(x*math.cos(delta)-y*math.sin(delta),x*math.sin(delta)+y*math.cos(delta),z))
    end
    function view:adapt_payload(kind,command,value,state,manager)
        if kind=="mover" and command=="set_movement" and value then return self:rotate_movement(value,manager.follow_spin)end
        if kind~="character" or command~="input" or type(value)~="table"then return value end
        local output=clone(value)
        if value.movement then output.movement=self:rotate_movement(value.movement,manager.follow_spin)end
        local input=state.input_data
        local aiming=length_xy(value.aim)>0.000001 or input.aiming_pressed or number(input.fire_button)>0 or number(input.throw)>0
            or value.fire or value.fire_auto or value.throw or number(value.fire_amount)>0 or number(value.throw_amount)>0
        if aiming then output.aim={x=-math.sin(self.yaw),y=math.cos(self.yaw),z=0}end
        return output
    end
    function view:input(original,component,entries,dt,...)
        local manager=env.CameraManager
        local entry=type(entries)=="table" and entries[ctl.local_unit]
        local state=type(entry)=="table" and entry.state
        self.input_context={component=component,state=state,unit=ctl.local_unit}
        local unit,reason=self:check_context(manager,component,state,true)
        if unit and self:map_open(unit)then
            self.ray_ready=false;self.fallback=nil
            self:restore_cursor()
            self:note("map_close","Native map open; close camera retained and look paused")
            return original(component,entries,dt,...)
        end
        if not unit then
            self.ray_ready=false
            self.fallback=self.mode~="top" and reason or nil
            self:restore_cursor()
            return original(component,entries,dt,...)
        end
        local prepared,problem=pcall(function()
            self:initialize_look(unit)
            local delta=state.input_data.mouse_delta
            if delta then
                self.yaw=self.yaw-number(delta.x)*sensitivity
                self.pitch=math.max(-math.pi/3,math.min(math.pi/3,self.pitch-number(delta.y)*sensitivity))
            end
        end)
        if not prepared or type(component.queue_command_master)~="function"then
            self:fail_closed(manager,"input_prepare",problem or "queue API unavailable")
            return original(component,entries,dt,...)
        end
        local original_queue,owned_queue,mouse_disabled=component.queue_command_master,rawget(component,"queue_command_master"),state.mouse_aim_disabled
        rawset(component,"queue_command_master",function(self,target,kind,command,payload,...)
            if target==unit and ctl.enabled then
                local adapted,value=pcall(view.adapt_payload,view,kind,command,payload,state,manager)
                if adapted then payload=value else view:fail_closed(manager,"input_payload",value)end
            end
            return original_queue(self,target,kind,command,payload,...)
        end)
        state.mouse_aim_disabled=true
        local result=pack(pcall(original,component,entries,dt,...))
        state.mouse_aim_disabled=mouse_disabled
        rawset(component,"queue_command_master",owned_queue)
        if not result[1]then error(result[2],0)end
        self.fallback=nil
        self.ray_ready=true
        self:note("input_active","Camera-relative input active")
        local cursor=env.CursorManager
        if cursor and type(cursor.is_shown)=="function" and type(cursor.set_show_cursor)=="function"then
            if self.cursor_visibility==nil then local good,shown=pcall(cursor.is_shown,cursor);if good and type(shown)=="boolean"then self.cursor_visibility=shown end end
            if self.cursor_visibility~=nil then pcall(cursor.set_show_cursor,cursor,false)end
        end
        return unpack(result,2,result.n)
    end
    return view
end
return View
