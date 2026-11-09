-- A distant default-material world GUI: no environment, lighting or unit writes.
local Sky={}
local function finite(v)return type(v)=="number"and v==v and math.abs(v)<math.huge end
local function constructor(value)
    local kind=type(value)
    -- Native constructors may have protected callable-table metatables.
    -- Validate the actual call inside draw's pcall instead of inspecting them.
    return kind=="function"or kind=="table"or kind=="userdata"
end
local function supported(env)
    for _,entry in ipairs({{"World","create_world_gui"},{"World","destroy_gui"},
        {"Gui","move"},{"Gui","rect"},{"Camera","near_range"},{"Camera","far_range"},
        {"Matrix4x4","identity"},{"Matrix4x4","from_quaternion"},{"Matrix4x4","set_translation"},
        {"Quaternion","look"}})do
        if type(env[entry[1]])~="table"or type(env[entry[1]][entry[2]])~="function"then return false end
    end
    return constructor(env.Vector2)and constructor(env.Vector3)and constructor(env.Color)
end
local function starfield()
    local stars={}
    -- Fixed spherical directions and appearance; never touch the game's RNG.
    for i=1,2048 do
        local z=1-2*(i-.5)/2048
        local radial=math.sqrt(1-z*z);local angle=i*2.399963229728653
        local value=((i*1103515245+12345)%2147483647)/2147483647
        local variation=((i*16807)%104729)/104729
        stars[i]={x=radial*math.cos(angle),y=radial*math.sin(angle),z=z,
            size=.0007+.0013*variation,brightness=150+math.floor(105*variation),glow=value>.96}
    end
    return stars
end
function Sky.new(env,ctl,config)
    config=config or{}
    local sky={enabled=config.sky_enabled~=false}
    local stars=starfield()
    -- Diagnostic only: fixed labels, scalar snapshots, at most 16 log attempts.
    local diagnostic_labels,diagnostic_count,toggle_count={},0,0
    local function scalar(value)
        local kind=type(value)
        if kind=="string"then return(value:gsub("[%c%s]","_"):sub(1,160))end
        if kind=="number"then return string.format("%.9g",value)end
        if kind=="boolean"or kind=="nil"then return tostring(value)end
        return"<"..kind..">"
    end
    local function diagnostic(label,...)
        if diagnostic_labels[label]or diagnostic_count>=16 then return end
        diagnostic_labels[label]=true;diagnostic_count=diagnostic_count+1
        local fields={"Sky diagnostic "..label}
        for i=1,select("#",...),2 do
            fields[#fields+1]=scalar(select(i,...)).."="..scalar(select(i+1,...))
        end
        local line=table.concat(fields," ")
        if type(ctl.log)=="function"then pcall(ctl.log,ctl,line)
        elseif type(ctl.once)=="function"then pcall(ctl.once,ctl,"sky_diagnostic_"..label,line)end
    end
    local function note(self,message)
        if self.noted then return end;self.noted=true
        if type(ctl.once)=="function"then pcall(ctl.once,ctl,"sky_unavailable",message)
        elseif type(ctl.log)=="function"then pcall(ctl.log,ctl,message)end
    end
    function sky:status()
        return self.disabled and"STARS UNAVAILABLE"or(self.enabled and"STARS ON"or"STARS OFF")
    end
    function sky:release(current_world)
        local owned=self.owned;self.owned=nil
        -- Caller supplies the current valid world. Teardown owns stale worlds.
        if not owned or owned.world~=current_world or current_world==nil then return end
        local good,problem=pcall(function()env.World.destroy_gui(current_world,owned.gui)end)
        if not good then
            diagnostic("ERROR","reason","error","stage","release","message",problem)
            self.disabled=true;note(self,"Star background unavailable: "..tostring(problem))
        end
    end
    local function fail(self,world,problem)
        diagnostic("ERROR","reason","error","stage","draw","message",problem)
        self.disabled=true;self:release(world)
        note(self,"Star background unavailable: "..tostring(problem))
        return false
    end
    function sky:poll_toggle()
        local keyboard=env.Keyboard
        if not keyboard or type(keyboard.button_index)~="function"or type(keyboard.button)~="function"then return end
        local good,down=pcall(function()return keyboard.button(keyboard.button_index("f11"))>=.5 end)
        if not good then return end
        if down and not self.key_down and ctl.enabled and not self.disabled then
            self.enabled=not self.enabled
            toggle_count=toggle_count+1
            if toggle_count<=2 then diagnostic("F11_"..toggle_count,"reason","toggle","sky_enabled",self.enabled)end
            if not self.enabled then
                local view=ctl.view;local owned=view and view.owned
                self:release(owned and owned.world)
            end
        end
        self.key_down=down
    end
    function sky:draw(world,camera,viewport,position,yaw,pitch,fov)
        local view=ctl.view;local active=view and view.owned
        local function entry()
            diagnostic("ENTRY","sky_enabled",self.enabled,"fatal",not not self.disabled,"mod_enabled",ctl.enabled,
                "mode",view and view.mode,"render_ready",view and view.render_ready,"active_present",active~=nil,
                "world_match",active~=nil and active.world==world,"camera_match",active~=nil and active.camera==camera,
                "viewport_match",active~=nil and active.viewport==viewport,"position_type",type(position),
                "Vector2_type",type(env.Vector2),"Vector3_type",type(env.Vector3),"Color_type",type(env.Color))
        end
        if self.disabled or not self.enabled or not ctl.enabled or not view or not view.render_ready
            or(view.mode~="shoulder"and view.mode~="first")then
            entry()
            diagnostic("REJECT_gate","reason","gate","sky_enabled",self.enabled,"fatal",not not self.disabled,
                "mod_enabled",ctl.enabled,"mode",view and view.mode,"render_ready",view and view.render_ready)
            self:release(active and active.world or world);return false
        end
        if not active or active.world~=world or active.camera~=camera or active.viewport~=viewport then
            entry()
            diagnostic("REJECT_ownership","reason","ownership","active_present",active~=nil,
                "world_match",active~=nil and active.world==world,"camera_match",active~=nil and active.camera==camera,
                "viewport_match",active~=nil and active.viewport==viewport)
            return false
        end
        -- Snapshot the incoming engine temporary before any other native call.
        if type(position)~="table"and type(position)~="userdata"and type(position)~="vector3"then
            entry()
            diagnostic("REJECT_position_type","reason","position_type","position_type",type(position))
            self:release(world);return false
        end
        local valid,x,y,z=pcall(function()return position.x,position.y,position.z end)
        entry() -- Printing may call the engine; numeric position is already copied.
        if not valid then return fail(self,world,x)end
        if not finite(x)or not finite(y)or not finite(z)or not finite(yaw)or not finite(pitch)
            or math.abs(pitch)>=math.pi/2-.0001 or not finite(fov)or fov<=.001 or fov>=math.pi-.001 then
            diagnostic("REJECT_parameters","reason","parameters","x",x,"y",y,"z",z,"yaw",yaw,"pitch",pitch,"fov",fov)
            self:release(world);return false
        end
        if not supported(env)then return fail(self,world,"native GUI API unavailable")end
        local good,result=pcall(function()
            if type(viewport.window)~="function"then error("viewport dimensions unavailable",0)end
            local width,height=viewport:window()
            local near,far=env.Camera.near_range(camera),env.Camera.far_range(camera)
            diagnostic("CLIP","width",width,"height",height,"near",near,"far",far,
                "width_finite",finite(width),"height_finite",finite(height),"near_finite",finite(near),"far_finite",finite(far),
                "x",x,"y",y,"z",z,"yaw",yaw,"pitch",pitch,"fov",fov)
            if not finite(width)or not finite(height)or width<=0 or height<=0
                or not finite(near)or not finite(far)or near<=0 or far<=near then
                diagnostic("REJECT_clip_dims","reason","clip_dims","width",width,"height",height,"near",near,"far",far)
                return false
            end
            local distance=far*.995
            if distance<=near then
                diagnostic("REJECT_inside_far","reason","inside_far","distance",distance,"near",near,"far",far)
                return false
            end
            local halfheight=distance*math.tan(fov*.5)*1.015
            local halfwidth=halfheight*width/height
            if not finite(halfheight)or not finite(halfwidth)or halfheight<=0 or halfwidth<=0 then
                diagnostic("REJECT_frustum","reason","frustum","halfwidth",halfwidth,"halfheight",halfheight,"distance",distance,"fov",fov)
                return false
            end
            local sy,cy,sp,cp=math.sin(yaw),math.cos(yaw),math.sin(pitch),math.cos(pitch)
            local fx,fy,fz=-sy*cp,cy*cp,sp
            local px,py,pz=x+fx*distance,y+fy*distance,z+fz*distance
            if not finite(px)or not finite(py)or not finite(pz)then
                diagnostic("REJECT_world_position","reason","world_position","plane_x",px,"plane_y",py,"plane_z",pz)
                return false
            end
            if self.owned and self.owned.world~=world then self:release(world)end
            if not self.owned then
                -- Omitting material/shadow_caster keeps the native default depth pass.
                local gui=env.World.create_world_gui(world,env.Matrix4x4.identity(),1,1,"immediate")
                if not gui then error("world GUI was not created",0)end
                self.owned={world=world,gui=gui}
                diagnostic("GUI_CREATED","world_match",self.owned.world==world,"gui_present",gui~=nil,
                    "mode","immediate","material","default","canvas_width",1,"canvas_height",1)
            end
            local gui=self.owned.gui
            local rotation=env.Quaternion.look(env.Vector3(fx,fy,fz),env.Vector3(0,0,1))
            local pose=env.Matrix4x4.from_quaternion(rotation)
            env.Matrix4x4.set_translation(pose,env.Vector3(px,py,pz))
            env.Gui.move(gui,pose,1,1)
            -- GUI canvas XY maps onto the transformed world X/Z plane.
            local bandheight=halfheight*2/20;local overlap=bandheight*.015
            for i=1,20 do
                local t=(i-.5)/20
                env.Gui.rect(gui,env.Vector3(-halfwidth,-halfheight+(i-1)*bandheight-overlap,0),
                    env.Vector2(halfwidth*2,bandheight+overlap*2),
                    env.Color(255,math.floor(3+6*(1-t)),math.floor(7+9*(1-t)),math.floor(20+16*(1-t))))
            end
            local visible,glows=0,0
            for _,star in ipairs(stars)do
                local forward=star.x*fx+star.y*fy+star.z*fz
                if forward>.000001 then
                    local horizontal=star.x*cy+star.y*sy
                    local vertical=star.x*sy*sp-star.y*cy*sp+star.z*cp
                    local sx,sz=horizontal/forward*distance,vertical/forward*distance
                    local size=distance*star.size
                    if math.abs(sx)+size*.5<halfwidth and math.abs(sz)+size*.5<halfheight then
                        if star.glow then
                            env.Gui.rect(gui,env.Vector3(sx-size*1.5,sz-size*1.5,1),env.Vector2(size*3,size*3),env.Color(24,100,140,220))
                            glows=glows+1
                        end
                        env.Gui.rect(gui,env.Vector3(sx-size*.5,sz-size*.5,2),env.Vector2(size,size),
                            env.Color(255,star.brightness,math.min(255,star.brightness+4),math.min(255,star.brightness+20)))
                        visible=visible+1;if visible>=360 then break end
                    end
                end
            end
            diagnostic("QUEUED","bands",20,"cores",visible,"glows",glows,"rects",20+visible+glows,
                "near",near,"far",far,"distance",distance,"halfwidth",halfwidth,"halfheight",halfheight,
                "plane_x",px,"plane_y",py,"plane_z",pz,"forward_x",fx,"forward_y",fy,"forward_z",fz)
            return true
        end)
        if not good then return fail(self,world,result)end
        if not result then self:release(world)end
        return result
    end
    return sky
end
return Sky
