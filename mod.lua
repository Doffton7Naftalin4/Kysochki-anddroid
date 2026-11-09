-- Experimental HELLDIVERS 2015 camera/separation hooks. Original bytecode stays intact.
local Mod = {}
local function pack(...) return {n=select("#", ...), ...} end

function Mod.new(env, config)
    config = config or {}
    local ctl = {enabled=config.enabled ~= false, installed={}, messages={}}

    function ctl:log(message)
        local line = "[HD_CAMERA_PROTO] " .. tostring(message)
        if type(env.print) == "function" then pcall(env.print, line) end
        if config.log_path and env.io and type(env.io.open) == "function" then
            pcall(function()
                local file = env.io.open(config.log_path, "a")
                if file then file:write(line .. "\n"); file:close() end
            end)
        end
    end
    function ctl:once(key, message)
        if not self.messages[key] then self.messages[key]=true; self:log(message) end
    end
    function ctl:pose_call(method,...)
        local pose=self.pose
        if not pose or type(pose[method])~="function"then return end
        local good,problem=pcall(pose[method],pose,...)
        if not good then self:once("pose_"..method.."_failure",tostring(problem))end
    end
    function ctl:set_enabled(value)
        self.enabled = value == true
        if not self.enabled then self:pose_call("before_animations",nil)end
        self:log(self.enabled and "ENABLED: camera and separation" or "DISABLED: original behavior")
        self:publish_status()
    end
    function ctl:poll_toggle()
        self:pose_call("begin_frame")
        local keyboard=env.Keyboard
        if keyboard and type(keyboard.button_index)=="function" and type(keyboard.button)=="function" then
            local ok,down=pcall(function() return keyboard.button(keyboard.button_index("f8")) >= 0.5 end)
            if ok then
                if down and not self.key_down then self:set_enabled(not self.enabled) end
                self.key_down=down
            end
        end
        if self.view then self.view:poll_toggle() end
        if self.pose and type(self.pose.toggle_diagnostic)=="function"and keyboard
            and type(keyboard.button_index)=="function"and type(keyboard.button)=="function"then
            local good,down=pcall(function()return keyboard.button(keyboard.button_index("f10"))>=0.5 end)
            if good then
                if down and not self.pose_key_down and self.enabled then
                    self:pose_call("toggle_diagnostic")
                    self:publish_status()
                end
                self.pose_key_down=down
            end
        end
    end
    function ctl:capture_input(entries)
        if type(entries)~="table" then return end
        local selected,priority
        for unit,entry in pairs(entries) do
            local state=type(entry)=="table" and entry.state
            if state and state.pad_number~=nil then
                local rank=state.pad_number==0 and 2 or 1
                if not priority or rank>priority then selected,priority=unit,rank end
            end
        end
        if selected then
            self.local_unit=selected
            self:once("local_input", "Local player input identified")
        end
    end
    local function invoke_restoring(original, restore, ...)
        local result=pack(pcall(original, ...))
        local restored,restore_error=pcall(restore)
        if not result[1] then error(result[2],0) end
        if not restored then error(restore_error,0) end
        return unpack(result,2,result.n)
    end
    function ctl:camera_target(manager)
        local unit=self.local_unit
        if not self.enabled or type(manager)~="table" or manager.state~="follow" or not unit or type(manager.targets)~="table" then
            return nil
        end
        if not env.Unit or type(env.Unit.alive)~="function" then return nil end
        local ok,alive=pcall(env.Unit.alive,unit)
        if not ok or not alive then return nil end
        local entity=env.EntityAux
        if entity and type(entity.state)=="function"then
            local good,character=pcall(entity.state,unit,"character")
            if not good then return nil end
            local seat=type(character)=="table"and character.current_seat_unit
            if seat then
                local valid,seated=pcall(env.Unit.alive,seat)
                if not valid then return nil end
                if seated then
                    -- Native CharacterStateSeated removes the character target;
                    -- the vehicle's own camera_target supplies its stock pose.
                    return manager.targets[seat]and seat or nil
                end
            end
        end
        return manager.targets[unit]and unit or nil
    end
    function ctl:active_local_unit(manager)
        return self:camera_target(manager)and self.local_unit or nil
    end
    function ctl:publish_status(force)
        local window=env.Window
        if not window or type(window.set_title)~="function" then return false end
        local title="HELLDIVERS | HD CAMERA v" .. (config.version or "prototype") .. " " .. (self.enabled and "ON" or "OFF")
        if self.enabled then
            title=title .. (self:active_local_unit(env.CameraManager) and " | LOCAL" or " | WAITING")
            if self.view then title=title .. " | " .. self.view:status() end
            if self.pose and type(self.pose.status)=="function"then
                local good,status=pcall(self.pose.status,self.pose)
                if good and type(status)=="string"then title=title .. " | " .. status end
            end
        end
        if not force and title==self.last_title then return true end
        local ok=pcall(window.set_title,title)
        if ok then self.last_title=title end
        return ok
    end
    function ctl:camera(original, manager, ...)
        if self.view then
            local restored,err=pcall(self.view.restore,self.view,manager)
            if not restored then
                self.enabled=false
                manager.prev_fov=nil
                self:once("view_restore_failure","Close view disabled during restore: "..tostring(err))
            end
        end
        local target=self:camera_target(manager)
        if not target then return original(manager,...) end
        local targets=manager.targets
        manager.targets={[target]=targets[target]}
        if target==self.local_unit then self:once("camera_follow", "Independent camera active on local character")
        else self:once("camera_vehicle", "Independent stock camera active on local occupied vehicle")end
        local result=pack(invoke_restoring(original,function() manager.targets=targets end,manager,...))
        if self.view then
            local ok,err=pcall(self.view.apply,self.view,manager,...)
            if not ok then
                self.enabled=false
                pcall(self.view.restore,self.view,manager)
                manager.prev_fov=nil
                self:once("view_failure","Close view disabled: "..tostring(err))
            end
        end
        return unpack(result,1,result.n)
    end
    function ctl:before_render(world,camera)
        if not self.view then return end
        local manager=env.CameraManager
        local ok,result=pcall(self.view.commit_render,self.view,manager,world,camera)
        if not ok then
            self.enabled=false
            pcall(self.view.restore,self.view,manager)
            if type(manager)=="table"then manager.prev_fov=nil end
            self:once("render_failure","Close view disabled before render: "..tostring(result))
        else
            return result
        end
    end
    function ctl:is_character(unit)
        if not env.EntityAux or type(env.EntityAux.has_component)~="function" then return false end
        local ok,result=pcall(env.EntityAux.has_component,unit,"character")
        return ok and result
    end
    function ctl:without_screen_limit(original, character_batch, component, entries, ...)
        local target=self:camera_target(env.CameraManager)
        if not target or type(entries)~="table" then return original(component,entries,...) end
        local snapshots,seen={},{}
        for unit,entry in pairs(entries) do
            if type(entry)=="table" and type(entry.state)=="table" and(self:is_character(unit)or(not character_batch and unit==target))then
                local state=character_batch and entry.state.mover_state or entry.state
                if type(state)=="table" and state.keep_inside_screen~=nil and not seen[state] then
                    snapshots[#snapshots+1]={state=state,value=state.keep_inside_screen}
                    seen[state]=true
                end
            end
        end
        for _,snapshot in ipairs(snapshots) do snapshot.state.keep_inside_screen=false end
        if #snapshots>0 then self:once("separation", "Player screen movement constraint bypass active") end
        return invoke_restoring(original,function()
            for _,snapshot in ipairs(snapshots) do snapshot.state.keep_inside_screen=snapshot.value end
        end,component,entries,...)
    end
    function ctl:hook(class_name, method, make_wrapper)
        local class=env[class_name]
        if type(class)~="table" or type(class[method])~="function" then return end
        local key=class_name .. "." .. method
        local previous=self.installed[key]
        if previous and previous.class==class and previous.wrapper==class[method] then return end
        local wrapper=make_wrapper(class[method])
        self.installed[key]={class=class,wrapper=wrapper}
        class[method]=wrapper
        self:log("Hook installed: " .. key)
    end
    function ctl:install_hooks()
        if self.stratagems then self.stratagems:install_hooks()end
        if self.pose and type(self.pose.install_hooks)=="function"then self.pose:install_hooks()end
        if self.aim then
            self:hook("FirearmComponent","update_slaves",function(original)
                return function(component,entries,...)
                    return self.aim:update(original,component,entries,...)
                end
            end)
            if type(self.aim.callback)=="function"then
                self:hook("WeaponUtility","shoot_ray_callback",function(original)
                    return function(...)return self.aim:callback(original,...)end
                end)
            end
            if type(self.aim.throw)=="function"then
                self:hook("CharacterComponent","do_throw",function(original)
                    return function(component,unit,entry,power,...)
                        return self.aim:throw(original,component,unit,entry,power,...)
                    end
                end)
            end
        end
        if self.pose then
            for _,name in ipairs({"update_animations","update_animations_with_callback","update"})do
                self:hook("World",name,function(original)
                    return function(world,...)
                        self:pose_call("before_animations",world)
                        return original(world,...)
                    end
                end)
            end
            if type(self.pose.scene)=="function"then
                self:hook("World","update_scene",function(original)
                    return function(world,...)return self.pose:scene(original,world,...)end
                end)
            end
        end
        if self.view or self.pose then
            self:hook("Application","render_world",function(original)
                return function(world,camera,...)
                    local selected=self:before_render(world,camera) or camera
                    if self.pose then return self.pose:render(original,world,selected,...)end
                    return original(world,selected,...)
                end
            end)
        end
        if self.view then
            self:hook("CameraManager","terminate",function(original)
                return function(manager,...)
                    self:pose_call("before_animations",nil)
                    local ok,err=pcall(self.view.release,self.view,manager)
                    if not ok then self:once("camera_release_failure",tostring(err))end
                    return original(manager,...)
                end
            end)
        end
        self:hook("InputComponent","update_masters",function(original)
            return function(component,entries,...)
                local ok,err=pcall(self.capture_input,self,entries)
                if not ok then self:once("capture_error","Input capture error: "..tostring(err)) end
                if self.view then return self.view:input(original,component,entries,...) end
                return original(component,entries,...)
            end
        end)
        self:hook("CameraManager","update",function(original)
            return function(manager,...) return self:camera(original,manager,...) end
        end)
        self:hook("MoverComponent","update_masters",function(original)
            return function(component,entries,...) return self:without_screen_limit(original,false,component,entries,...) end
        end)
        self:hook("MoverComponent","update_slaves",function(original)
            return function(component,entries,...) return self:without_screen_limit(original,false,component,entries,...) end
        end)
        self:hook("CharacterComponent","update_masters",function(original)
            local function retained(component,entries,...)
                return self:without_screen_limit(original,true,component,entries,...)
            end
            return function(component,entries,...)
                if self.actions then return self.actions:character_update(retained,component,entries,...)end
                return retained(component,entries,...)
            end
        end)
    end
    if config.view then ctl.view=config.view.new(env,ctl,config) end
    if config.aim then ctl.aim=config.aim.new(env,ctl,config) end
    if config.pose then ctl.pose=config.pose.new(env,ctl,config) end
    if config.actions then ctl.actions=config.actions.new(env,ctl,config) end
    if config.stratagems then ctl.stratagems=config.stratagems.new(env,ctl,config) end
    return ctl
end

return Mod
