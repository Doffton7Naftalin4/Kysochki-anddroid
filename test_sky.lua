local Sky=assert(dofile("sky.lua"))
local function vector(x,y,z)return{x=x,y=y,z=z or 0}end
local function near(a,b,epsilon)assert(math.abs(a-b)<(epsilon or 1e-6),tostring(a).." ~= "..tostring(b))end
local function snapshot(v)return{x=v.x,y=v.y,z=v.z}end
local function fixture()
    local world,camera={},{near=.06,far=500}
    local seen={created={},destroyed={},moved={},rects={},logs={},diagnostics={},key=0,window={1280,720}}
    local viewport={window=function()return unpack(seen.window)end}
    local ctl={enabled=true,view={mode="shoulder",render_ready=true,owned={world=world,camera=camera,viewport=viewport}}}
    function ctl:once(key,message)seen.logs[#seen.logs+1]={key,message}end
    function ctl:log(message)seen.diagnostics[#seen.diagnostics+1]=message end
    local env={Vector3=vector,Vector2=vector,Color=function(a,r,g,b)return{a=a,r=r,g=g,b=b}end,
        Quaternion={look=function(f,up)return{forward=snapshot(f),up=snapshot(up)}end},
        Matrix4x4={identity=function()return{identity=true}end,
            from_quaternion=function(q)return{rotation=q}end,
            set_translation=function(m,p)m.translation=snapshot(p)end},
        Camera={near_range=function(c)assert(c==camera);return c.near end,
            far_range=function(c)assert(c==camera);return c.far end},
        World={create_world_gui=function(w,pose,width,height,...)
            assert(w==world and pose.identity and width==1 and height==1)
            local options={...};assert(#options==1 and options[1]=="immediate","default world GUI depth pass required")
            local gui={world=w};seen.created[#seen.created+1]=gui;return gui
        end,destroy_gui=function(w,gui)assert(w==world and gui.world==w);seen.destroyed[#seen.destroyed+1]=gui end},
        Gui={move=function(gui,pose,width,height)
            assert(gui.world==world and width==1 and height==1)
            seen.moved[#seen.moved+1]={gui=gui,pose=pose}
        end,rect=function(gui,p,size,color)
            assert(gui.world==world)
            seen.rects[#seen.rects+1]={gui=gui,p=snapshot(p),size=snapshot(size),color=color}
        end},
        Keyboard={button_index=function(key)assert(key=="f11");return 11 end,
            button=function(index)assert(index==11);return seen.key end}}
    local sky=Sky.new(env,ctl,{})
    local function draw(position,yaw,pitch,fov,w,c,v)
        seen.rects={}
        return sky:draw(w or world,c or camera,v or viewport,position or vector(10,20,3),yaw or 0,pitch or 0,fov or math.rad(65))
    end
    return env,ctl,sky,world,camera,viewport,seen,draw
end
local tests={}
function tests.lazy_default_and_depth_tested_native_gui_contract()
    local e,c,s,w,cam,v,seen,draw=fixture()
    assert(s:status()=="STARS ON"and #seen.created==0)
    assert(draw()and #seen.created==1 and #seen.moved==1 and #seen.rects>20)
    assert(draw()and #seen.created==1 and #seen.moved==2)
end
function tests.shared_mod_enabled_flag_does_not_override_independent_sky_default()
    local e,c,s,w,cam,v,seen,draw=fixture();c.enabled=false
    s=Sky.new(e,c,{enabled=false})
    assert(s:status()=="STARS ON"and not s:draw(w,cam,v,vector(0,0,0),0,0,1))
    c.enabled=true;assert(s:draw(w,cam,v,vector(0,0,0),0,0,1))
    s:release(w)
    local optedout=Sky.new(e,c,{enabled=true,sky_enabled=false})
    assert(optedout:status()=="STARS OFF"and not optedout:draw(w,cam,v,vector(0,0,0),0,0,1))
end
function tests.native_callable_constructor_tables_with_protected_metatables_draw()
    local e,c,s,w,cam,v,seen,draw=fixture()
    for _,name in ipairs({"Vector2","Vector3","Color"})do
        local constructor=e[name]
        e[name]=setmetatable({zero=function()return constructor(0,0,0,0)end},
            {__call=function(_,...)return constructor(...)end,__metatable="native protected constructor"})
    end
    assert(type(e.Vector3)=="table"and type(e.Vector3.zero)=="function")
    assert(draw()and s:status()=="STARS ON"and #seen.created==1 and #seen.rects>20)
end
function tests.invalid_constructor_object_fails_only_sky_inside_protected_draw()
    local e,c,s,w,cam,v,seen,draw=fixture();e.Vector3={zero=function()return vector(0,0,0)end}
    assert(not draw()and s:status()=="STARS UNAVAILABLE"and c.enabled and c.view.render_ready)
end
function tests.opaque_gradient_covers_all_frustum_with_overlap_inside_far_plane()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
    local pose=seen.moved[1].pose;local distance=cam.far*.995
    near(pose.translation.x,10);near(pose.translation.y,20+distance);near(pose.translation.z,3)
    near(pose.rotation.forward.y,1)
    local halfheight=distance*math.tan(math.rad(65)/2);local halfwidth=halfheight*1280/720
    local top=-math.huge;local bottom=math.huge;local bands=0
    for _,r in ipairs(seen.rects)do if r.p.z==0 then
        bands=bands+1;assert(r.color.a==255)
        assert(r.p.x<=-halfwidth and r.p.x+r.size.x>=halfwidth)
        bottom=math.min(bottom,r.p.y);top=math.max(top,r.p.y+r.size.y)
        if bands>1 then assert(r.p.y<=seen.rects[bands-1].p.y+seen.rects[bands-1].size.y,"gradient gap")end
    end end
    assert(bands==20 and bottom<=-halfheight and top>=halfheight)
    assert(distance>cam.near and distance<cam.far)
end
function tests.yaw_pitch_plane_uses_camera_basis_and_numeric_position_snapshot()
    local e,c,s,w,cam,v,seen,draw=fixture();local position=vector(5,6,7)
    local original=e.Quaternion.look
    e.Quaternion.look=function(...)position.x=999;position.y=888;position.z=777;return original(...)end
    local yaw,pitch=.7,.4;assert(draw(position,yaw,pitch))
    local pose=seen.moved[1].pose;local d=cam.far*.995
    near(pose.translation.x,5-math.sin(yaw)*math.cos(pitch)*d)
    near(pose.translation.y,6+math.cos(yaw)*math.cos(pitch)*d)
    near(pose.translation.z,7+math.sin(pitch)*d)
end
local function directions(seen,yaw,pitch,far)
    local out={};local d=far*.995
    local sy,cy,sp,cp=math.sin(yaw),math.cos(yaw),math.sin(pitch),math.cos(pitch)
    for _,r in ipairs(seen.rects)do if r.p.z==2 then
        local x=(r.p.x+r.size.x/2)/d;local y=(r.p.y+r.size.y/2)/d
        local vx,vy,vz=cy*x+sy*sp*y-sy*cp,sy*x-cy*sp*y+cy*cp,cp*y+sp
        local len=math.sqrt(vx*vx+vy*vy+vz*vz);vx,vy,vz=vx/len,vy/len,vz/len
        local key=string.format("%.5f/%.5f/%.5f",vx,vy,vz)
        out[key]={color=r.color,size=r.size.x/d}
    end end
    return out
end
function tests.stars_are_world_fixed_deterministic_and_do_not_use_global_rng()
    local e,c,s,w,cam,v,seen,draw=fixture()
    local random,seed=math.random,math.randomseed
    math.random=function()error("global random forbidden")end;math.randomseed=math.random
    local good,err=pcall(function()
        assert(draw());local first=directions(seen,0,0,cam.far)
        assert(draw(nil,.3,.1));local second=directions(seen,.3,.1,cam.far)
        local overlap=0;for key,a in pairs(first)do local b=second[key];if b then overlap=overlap+1;near(a.size,b.size);assert(a.color.r==b.color.r)end end
        assert(overlap>100,"stars moved with camera instead of world")
        local e2,c2,s2,w2,cam2,v2,seen2,draw2=fixture();assert(draw2())
        local same=directions(seen2,0,0,cam2.far);local count=0
        for key,a in pairs(first)do assert(same[key]);near(a.size,same[key].size);count=count+1 end
        assert(count>100)
    end)
    math.random,math.randomseed=random,seed;assert(good,err)
end
function tests.star_sizes_brightness_and_sparse_glows_are_varied_and_bounded()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
    local cores,glows,sizes,colors=0,0,{},{}
    for _,r in ipairs(seen.rects)do
        if r.p.z==2 then cores=cores+1;sizes[string.format("%.4f",r.size.x)]=true;colors[r.color.r]=true end
        if r.p.z==1 then glows=glows+1;assert(r.color.a>0 and r.color.a<100)end
    end
    local ns,nc=0,0;for _ in pairs(sizes)do ns=ns+1 end;for _ in pairs(colors)do nc=nc+1 end
    assert(cores>=100 and cores<=400 and glows>0 and glows<cores/4 and ns>5 and nc>5)
    assert(#seen.rects<=500,"unbounded native draw calls")
end
function tests.foreign_world_camera_viewport_and_nonclose_context_never_draw()
    local e,c,s,w,cam,v,seen,draw=fixture()
    assert(not draw(nil,nil,nil,nil,{}));assert(not draw(nil,nil,nil,nil,nil,{}));assert(not draw(nil,nil,nil,nil,nil,nil,{}))
    c.view.mode="top";assert(not draw());c.view.mode="first";c.view.render_ready=false;assert(not draw())
    c.view.render_ready=true;c.enabled=false;assert(not draw());assert(#seen.created==0 and #seen.rects==0)
end
function tests.disabled_context_destroys_only_owned_gui_in_current_world()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw());local gui=seen.created[1]
    c.enabled=false;assert(not draw());assert(#seen.destroyed==1 and seen.destroyed[1]==gui)
    c.enabled=true;assert(draw());assert(#seen.created==2)
    s:release(w);s:release(w);assert(#seen.destroyed==2)
end
function tests.stale_world_release_forgets_gui_without_calling_old_world()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw());s:release({});assert(#seen.destroyed==0)
    assert(draw()and #seen.created==2)
end
function tests.bad_parameters_and_invalid_native_clip_ranges_never_create_or_draw()
    for _,bad in ipairs({{x=0/0,y=0,z=0},{x=math.huge,y=0,z=0}})do
        local e,c,s,w,cam,v,seen,draw=fixture();assert(not draw(bad));assert(#seen.created==0)
    end
    for _,range in ipairs({{near=1,far=1},{near=-1,far=500},{near=.1,far=math.huge},{near=.1,far=0/0}})do
        local e,c,s,w,cam,v,seen,draw=fixture();cam.near,cam.far=range.near,range.far
        assert(not draw()and #seen.created==0 and #seen.rects==0)
    end
    local e,c,s,w,cam,v,seen,draw=fixture();seen.window={1280,0};assert(not draw())
    seen.window={1280,720};assert(not s:draw(w,cam,v,vector(0,0,0),0/0,0,1));assert(not s:draw(w,cam,v,vector(0,0,0),0,math.pi/2,1))
    assert(not s:draw(w,cam,v,vector(0,0,0),0,0,0));assert(not s:draw(w,cam,v,vector(0,0,0),0,0,math.pi))
    assert(#seen.created==0 and #seen.rects==0)
end
function tests.missing_native_api_disables_only_sky_without_breaking_camera()
    local e,c,s,w,cam,v,seen,draw=fixture();e.Gui.move=nil
    assert(not draw()and s:status()=="STARS UNAVAILABLE"and c.enabled and c.view.render_ready)
    assert(#seen.created==0 and #seen.logs==1);assert(not draw()and #seen.logs==1)
end
function tests.malformed_position_and_disappearing_api_never_escape_into_camera_render()
    local e,c,s,w,cam,v,seen,draw=fixture()
    assert(not s:draw(w,cam,v,42,0,0,1)and #seen.created==0)
    assert(draw());e.World=nil
    assert(not draw()and s:status()=="STARS UNAVAILABLE"and c.enabled and c.view.render_ready)
    assert(#seen.logs==1)
end
function tests.foreign_render_does_not_consume_existing_owned_gui()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
    local gui=seen.created[1]
    assert(not draw(nil,nil,nil,nil,{}));assert(#seen.destroyed==0)
    assert(draw()and #seen.created==1 and seen.moved[#seen.moved].gui==gui)
end
function tests.window_and_native_move_errors_fail_soft_and_release_only_once()
    for _,kind in ipairs({"window","move"})do
        local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
        if kind=="window"then v.window=function()error("window unavailable")end
        else e.Gui.move=function()error("move unavailable")end end
        assert(not draw()and #seen.destroyed==1 and s:status()=="STARS UNAVAILABLE")
        assert(not draw()and #seen.destroyed==1 and c.enabled)
    end
end
function tests.position_getter_failure_stays_inside_sky_and_preserves_render_context()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
    local bad=setmetatable({},{__index=function()error("expired native vector")end})
    assert(not s:draw(w,cam,v,bad,0,0,1))
    assert(s:status()=="STARS UNAVAILABLE"and #seen.destroyed==1 and c.enabled and c.view.render_ready)
end
function tests.native_draw_error_releases_own_gui_once_and_never_retries()
    local e,c,s,w,cam,v,seen,draw=fixture();local count=0
    e.Gui.rect=function()count=count+1;error("native failure")end
    assert(not draw()and count==1 and #seen.created==1 and #seen.destroyed==1)
    assert(s:status()=="STARS UNAVAILABLE"and c.enabled and c.view.render_ready)
    assert(not draw()and count==1 and #seen.logs==1)
end
function tests.toggle_is_edge_triggered_only_while_mod_enabled_and_cleans_up()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
    seen.key=1;s:poll_toggle();assert(s:status()=="STARS OFF"and #seen.destroyed==1)
    s:poll_toggle();assert(s:status()=="STARS OFF"and not draw())
    seen.key=0;s:poll_toggle();seen.key=1;s:poll_toggle();assert(s:status()=="STARS ON"and draw())
    seen.key=0;s:poll_toggle();c.enabled=false;seen.key=1;s:poll_toggle()
    c.enabled=true;s:poll_toggle();assert(s:status()=="STARS ON","held key while disabled must not toggle")
end
function tests.fatal_unavailable_cannot_be_reenabled_by_f11()
    local e,c,s,w,cam,v,seen,draw=fixture();e.Gui.rect=nil;assert(not draw())
    seen.key=1;s:poll_toggle();assert(s:status()=="STARS UNAVAILABLE"and not draw())
end
local function diagnostic_rows(seen)
    local result={}
    for _,line in ipairs(seen.diagnostics)do
        local label=line:match("^Sky diagnostic ([%w_]+)")
        assert(label,"diagnostic line must identify its stage")
        assert(not result[label],"diagnostic label repeated: "..label)
        result[label]=line
    end
    return result
end
function tests.diagnostic_success_proves_entry_clip_gui_and_queued_once_with_typed_values()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw());assert(draw())
    local rows=diagnostic_rows(seen)
    assert(rows.ENTRY and rows.CLIP and rows.GUI_CREATED and rows.QUEUED)
    assert(rows.ENTRY:find("position_type=table",1,true)and rows.ENTRY:find("world_match=true",1,true))
    assert(rows.ENTRY:find("sky_enabled=true",1,true)and rows.ENTRY:find("render_ready=true",1,true))
    assert(rows.CLIP:find("near=0.06",1,true)and rows.CLIP:find("far=500",1,true))
    assert(rows.CLIP:find("width=1280",1,true)and rows.CLIP:find("height=720",1,true))
    assert(rows.QUEUED:find("bands=20",1,true)and rows.QUEUED:find("distance=497.5",1,true))
    assert(rows.QUEUED:find("rects="..#seen.rects,1,true))
    assert(#seen.diagnostics==4,"success must not log each frame")
end
function tests.diagnostic_every_silent_rejection_is_once_and_total_budget_is_sixteen()
    local e,c,s,w,cam,v,seen,draw=fixture()
    c.enabled=false;assert(not draw());c.enabled=true
    assert(not draw(nil,nil,nil,nil,{}))
    assert(not s:draw(w,cam,v,42,0,0,1))
    assert(not s:draw(w,cam,v,vector(0/0,0,0),0,0,1))
    cam.near=0;assert(not draw())
    cam.near=499;assert(not draw())
    cam.near=.06;cam.far=1.7e308;assert(not draw(nil,0,0,2))
    cam.far=1e308;seen.window={1,1};assert(not draw(vector(0,1e308,0),0,0,.1))
    cam.far=500;seen.window={1280,720};assert(draw())
    for i=1,10 do seen.key=1;s:poll_toggle();seen.key=0;s:poll_toggle()end
    local rows=diagnostic_rows(seen)
    for _,reason in ipairs({"gate","ownership","position_type","parameters","clip_dims","inside_far","frustum","world_position"})do
        assert(rows["REJECT_"..reason]and rows["REJECT_"..reason]:find("reason="..reason,1,true),reason.." is silent")
    end
    assert(rows.F11_1 and rows.F11_2 and not rows.F11_3)
    for i=1,1000 do assert(not s:draw(w,cam,v,vector(math.huge,0,0),0,0,1))end
    assert(#seen.diagnostics<=16)
end
function tests.diagnostic_native_exception_and_logger_failure_do_not_change_render_behavior()
    local e,c,s,w,cam,v,seen,draw=fixture();assert(draw())
    e.Gui.move=function()error("native\nmove\tproblem")end
    assert(not draw()and s:status()=="STARS UNAVAILABLE")
    local rows=diagnostic_rows(seen);assert(rows.ERROR and not rows.ERROR:find("[\r\n\t]"))
    local e2,c2,s2,w2,cam2,v2,seen2,draw2=fixture()
    c2.log=function()error("logger unavailable")end
    assert(draw2()and draw2()and #seen2.created==1 and #seen2.destroyed==0 and c2.enabled)
end
function tests.diagnostic_logger_runs_after_native_position_has_been_snapshotted()
    local e,c,s,w,cam,v,seen,draw=fixture();local position=vector(5,6,7)
    c.log=function(_,message)
        seen.diagnostics[#seen.diagnostics+1]=message
        position.x,position.y,position.z=999,888,777
    end
    assert(draw(position))
    local pose=seen.moved[1].pose
    near(pose.translation.x,5);near(pose.translation.y,6+cam.far*.995);near(pose.translation.z,7)
end
local function with_native_vector3_type(position,action)
    local original_type=_G.type
    _G.type=function(value)if value==position then return"vector3"end return original_type(value)end
    local good,problem=pcall(action)
    _G.type=original_type
    assert(good,problem)
end
function tests.engine_vector3_type_reaches_clip_and_queued_without_changing_geometry()
    local e,c,s,w,cam,v,seen,draw=fixture();local position=vector(5,6,7)
    with_native_vector3_type(position,function()
        assert(type(position)=="vector3")
        assert(s:draw(w,cam,v,position,0,0,math.rad(65)))
        local rows=diagnostic_rows(seen)
        assert(rows.ENTRY:find("position_type=vector3",1,true)and rows.CLIP and rows.QUEUED)
        assert(not rows.REJECT_position_type and #seen.created==1)
        local pose=seen.moved[1].pose
        near(pose.translation.x,5);near(pose.translation.y,6+cam.far*.995);near(pose.translation.z,7)
    end)
    assert(type(position)=="table","fixture must restore global type")
end
function tests.engine_vector3_tag_still_requires_finite_numeric_xyz()
    for _,bad in ipairs({{x=0/0,y=0,z=0},{x="bad",y=0,z=0},{x=0,y=0,z=math.huge}})do
        local e,c,s,w,cam,v,seen,draw=fixture()
        with_native_vector3_type(bad,function()
            assert(not s:draw(w,cam,v,bad,0,0,1))
            local rows=diagnostic_rows(seen)
            assert(rows.ENTRY:find("position_type=vector3",1,true)and rows.REJECT_parameters)
            assert(not rows.REJECT_position_type and not rows.CLIP and not rows.QUEUED)
            assert(#seen.created==0 and s:status()=="STARS ON"and c.enabled and c.view.render_ready)
        end)
        assert(type(bad)=="table","fixture must restore global type")
    end
end
local names={}for name in pairs(tests)do names[#names+1]=name end table.sort(names)
local failed=0
for _,name in ipairs(names)do local good,err=pcall(tests[name]);if good then print("PASS "..name)else failed=failed+1;print("FAIL "..name..": "..tostring(err))end end
print(string.format("%d sky tests, %d failures",#names,failed));assert(failed==0)
