-- =============================================================================

-- script-binding thumb_engine/thumb_rerun
-- script-binding thumb_engine/thumb_toggle
-- script-message thumbnail_hwdec toggle

-- =============================================================================

local mp = require "mp"
local common = require "common"
mp.options = require "mp.options"
mp.utils = require "mp.utils"

local helper  = require "helper"
local winapi  = require "winapi"
local process = require "process"
local batch   = require "batch"

local options = {

	load = true,

	-- 单帧模式
	backend = "mpv",
	binpath = "default",
	socket = "",
	tnpath = "",

	max_height = 240,
	max_width = 240,
	rescale = 0,
	overlay_id = 10,

	spawn_first = false,
	prewarm = true,
	quit_after_inactivity = 60,
	network = false,
	audio = false,
	direct_io = true,

	hwdec = "yes",
	sw_threads = 2,
	min_duration = 10,
	precise = 0,
	quality = 1,
	frequency = 0.125,
	cache_iframe = "auto",
	cache_max = 128,
	be_workers = 3,

	-- 批量模式
	bat_backend = "ffmpeg",
	bat_binpath = "default",
	bat_path = "",
	bat_overlay_ids = "11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35",
	bat_width = 320,
	bat_height = 320,
	bat_hwdec = "yes",
	bat_threads = 1,
	bat_be_workers = 3,
	bat_min_duration = 20,

}
mp.options.read_options(options)

if options.load == false then
	mp.msg.info("脚本已被初始化禁用")
	return
end

local min_major = 0
local min_minor = 40
local min_patch = 0
local mpv_ver_curr = mp.get_property_native("mpv-version", "unknown")
if helper.incompat_check(mpv_ver_curr, min_major, min_minor, min_patch) then
	mp.msg.warn("当前mpv版本 (" .. (mpv_ver_curr or "未知") .. ") 低于 " .. min_major .. "." .. min_minor .. "." .. min_patch .. "，已终止缩略图功能。")
	return
end

local os_name = mp.get_property("platform")

if options.tnpath == "" then
	if os_name == "windows" then
		options.tnpath = os.getenv("TEMP").."\\thumb_engine.out"
	else
		options.tnpath = "/tmp/thumb_engine.out"
	end
end

local unique = mp.utils.getpid()

options.tnpath = options.tnpath .. unique

if options.backend == "mpv" then
	if options.socket == "" then
		if os_name == "windows" then
			options.socket = "thumb_engine"
		else
			options.socket = "/tmp/thumb_engine"
		end
	end
	options.socket = options.socket .. unique

	winapi.init(options, os_name)
end

local state = {
	file = nil,
	file_bytes = 0,

	spawned = false,
	disabled = false,
	spawn_waiting = false,
	script_written = false,

	dirty = false,

	x = nil, y = nil,
	last_x = nil, last_y = nil,

	last_seek_time = nil,

	effective_w = options.max_width,
	effective_h = options.max_height,
	real_w = nil, real_h = nil,
	last_real_w = nil, last_real_h = nil,

	script_name = nil,
	show_thumbnail = false,
	has_vid = 0,
	last_has_vid = 0,

	auto_run = true,

	info_timer = nil,
	info_pending_w = nil,
	info_pending_h = nil,

	properties = {},

	activity_timer = nil,
	prewarm_timer = nil,

	remove_thumbnail_files = nil,
}

local preview_draw = nil
local preview_ass = mp.create_osd_overlay("ass-events")

local thumb_pending = nil
local thumb_debounce = nil

process.init(state, options, os_name, winapi)
process.init_seek()

batch.init(options, os_name)


-- =============================================================================
-- 显示 广播
-- =============================================================================

local function bat_info()
	common.send_json(nil, "thumb_engine-bat-info", {
		bat_width = options.bat_width,
		bat_height = options.bat_height,
		bat_overlay_ids = options.bat_overlay_ids,
		bat_path = options.bat_path,
	})
end

state.remove_thumbnail_files = function() helper.remove_thumbnail_files(state, options) end

local function compute_disabled(w, h)
	local short_video = mp.get_property_number("duration", 0) <= options.min_duration
	local image = state.properties["current-tracks/video"]
		and state.properties["current-tracks/video"]["image"]
	local albumart = image and state.properties["current-tracks/video"]["albumart"]

	local disabled = (w or 0) == 0 or (h or 0) == 0 or
		state.has_vid == 0 or
		(state.properties["demuxer-via-network"] and not options.network) or
		(albumart and not options.audio) or
		(image and not albumart) or
		(short_video and options.min_duration > 0)

	if not state.auto_run then
		disabled = true
	end
	return disabled
end

local function broadcast_info(w, h, disabled)
	common.send_json(nil, "thumb_engine-info", {
		width = w, height = h,
		disabled = disabled, available = true,
		socket = options.socket, tnpath = options.tnpath,
		overlay_id = options.overlay_id,
	})
	mp.set_property_native("user-data/mpv/thumbnailer/enabled", not disabled)
end

local function kill_info_timer()
	if state.info_timer then
		state.info_timer:kill()
		state.info_timer = nil
	end
end

local function info(w, h)
	state.disabled = compute_disabled(w, h)

	state.info_pending_w = w
	state.info_pending_h = h

	kill_info_timer()

	local should_debounce = (state.has_vid == 0) or (not state.disabled)

	if should_debounce then
		state.info_timer = mp.add_timeout(0.05, function()
			state.info_timer = nil
			local pw, ph = state.info_pending_w, state.info_pending_h
			broadcast_info(pw, ph, compute_disabled(pw, ph))
		end)
	else
		broadcast_info(w, h, state.disabled)
	end
end

local last_draw = {
	x = nil, y = nil,
	w = nil, h = nil,
	file = nil,
	mtime = nil, size = nil,
}

local function reset_last_draw()
	last_draw.x, last_draw.y = nil, nil
	last_draw.w, last_draw.h = nil, nil
	last_draw.file = nil
	last_draw.mtime, last_draw.size = nil, nil
end

local function draw(w, h, script)
	if not w or not state.show_thumbnail then return end

	if state.x ~= nil then
		local cmd_x, cmd_y = state.x, state.y
		local cmd_w, cmd_h = nil, nil
		local preview = preview_draw and preview_draw.x and preview_draw.y
			and preview_draw.w and preview_draw.h
		if preview then
			cmd_x, cmd_y = preview_draw.x, preview_draw.y
			cmd_w, cmd_h = preview_draw.w, preview_draw.h
		end

		local file = options.tnpath .. ".bgra"
		local finfo = mp.utils.file_info(file)
		local mtime = finfo and finfo.mtime or 0
		local size  = finfo and finfo.size  or 0

		local pos_changed  = last_draw.x ~= cmd_x or last_draw.y ~= cmd_y
		local size_changed = last_draw.w ~= w or last_draw.h ~= h
		local file_changed = last_draw.file ~= file
			or last_draw.mtime ~= mtime
			or last_draw.size  ~= size

		if pos_changed or size_changed or file_changed then
			common.overlay_add(options.overlay_id, cmd_x, cmd_y, file, w, h,
				{ dw = cmd_w, dh = cmd_h })
			last_draw.x, last_draw.y = cmd_x, cmd_y
			last_draw.w, last_draw.h = w, h
			last_draw.file = file
			last_draw.mtime, last_draw.size = mtime, size
		end

		if preview then
			local ass = preview_draw.ass or ""
			local osd_w, osd_h = mp.get_osd_size()
			if osd_w > 0 and osd_h > 0 then
				preview_ass.res_x = osd_w
				preview_ass.res_y = osd_h
				preview_ass.data = ass
				preview_ass:update()
			end
		end
	elseif script then
		common.send_json(script, "thumb_engine-render", {
			width = w, height = h,
			x = state.x, y = state.y,
			socket = options.socket,
			tnpath = options.tnpath,
			overlay_id = options.overlay_id,
		})
	end
end

local draw_pending = false
local draw_throttle_timer = mp.add_timeout(1/40, function()
	if draw_pending then
		draw_pending = false
		if state.show_thumbnail then
			draw(state.real_w, state.real_h, state.script_name)
		end
	end
end)
draw_throttle_timer:kill()

local function request_draw(w, h, script)
	if draw_throttle_timer:is_enabled() then
		draw_pending = true
		return
	end
	draw(w, h, script)
	draw_throttle_timer:resume()
end

-- =============================================================================
-- 缩略图文件检测
-- =============================================================================

local file_timer
local file_check_period = 1/30

file_timer = mp.add_periodic_timer(file_check_period, function()
	local w, h = helper.check_new_thumb(options, state, os_name)
	if w then
		state.real_w, state.real_h = w, h
		if state.real_w ~= state.last_real_w or state.real_h ~= state.last_real_h then
			state.last_real_w, state.last_real_h = state.real_w, state.real_h
			info(state.real_w, state.real_h)
		end
		if not state.show_thumbnail then
			file_timer:kill()
		end
		draw(state.real_w, state.real_h, state.script_name)
	end
end)
file_timer:kill()

-- =============================================================================
-- 生命周期
-- =============================================================================

local activity_timer

-- prewarm：等影响 vf_gen 的属性稳定后再 spawn
local function prewarm_spawn()
	if state.spawned or state.disabled then return end
	local vp = state.properties["video-params"]
	if not vp or not vp.w or not vp.h then return end
	if not state.properties["path"] then return end
	if not state.properties["current-tracks/video"] then return end
	process.spawn(mp.get_property_number("time-pos", 0) or 0)
end

state.prewarm_timer = mp.add_timeout(0.3, prewarm_spawn)
state.prewarm_timer:kill()

local function schedule_prewarm()
	if not options.prewarm or options.backend ~= "mpv" then return end
	if state.spawned or state.disabled then return end
	state.prewarm_timer:kill()
	state.prewarm_timer:resume()
end

local function clear(force_overlay_remove)
	thumb_pending = nil
	if thumb_debounce then
		thumb_debounce:kill()
	end
	file_timer:kill()
	process.kill_seek_timer()
	reset_last_draw()
	if options.quit_after_inactivity > 0 then
		if state.show_thumbnail or activity_timer:is_enabled() then
			activity_timer:kill()
		end
		activity_timer:resume()
	end
	state.show_thumbnail = false
	state.last_x = nil
	state.last_y = nil
	preview_ass:remove()
	if state.script_name and not force_overlay_remove then return end
	common.overlay_remove(options.overlay_id)
end

local function quit()
	activity_timer:kill()
	if state.show_thumbnail then
		activity_timer:resume()
		return
	end
	process.run("quit")
	state.spawned = false
	state.real_w, state.real_h = nil, nil
	clear()
end

activity_timer = mp.add_timeout(options.quit_after_inactivity, quit)
activity_timer:kill()
state.activity_timer = activity_timer

-- ===========================================================
-- 消息处理
-- ===========================================================

thumb_pending = nil

local function thumb_impl(time, r_x, r_y, script)
	if state.disabled then return end

	time = tonumber(time)
	if time == nil then return end

	if r_x == "" or r_y == "" then
		state.x, state.y = nil, nil
	else
		state.x, state.y = math.floor(r_x + 0.5), math.floor(r_y + 0.5)
	end

	local nx = math.floor((r_x == "" and 0 or tonumber(r_x) or 0) + 0.5)
	local ny = math.floor((r_y == "" and 0 or tonumber(r_y) or 0) + 0.5)
	if state.show_thumbnail
		and state.last_x == nx
		and state.last_y == ny
		and state.last_seek_time
		and math.abs(time - state.last_seek_time) < 0.05 then
		return
	end

	local was_showing = state.show_thumbnail

	state.script_name = script
	if state.last_x ~= state.x or state.last_y ~= state.y or not state.show_thumbnail then
		state.show_thumbnail = true
		state.last_x, state.last_y = state.x, state.y
		if was_showing then
			request_draw(state.real_w, state.real_h, script)
		end
	end

	if options.quit_after_inactivity > 0 then
		if state.show_thumbnail or activity_timer:is_enabled() then
			activity_timer:kill()
		end
		activity_timer:resume()
	end

	if state.last_seek_time and math.abs(time - state.last_seek_time) < 0.05 then
		if not was_showing then request_draw(state.real_w, state.real_h, script) end
		return
	end
	state.last_seek_time = time
	if not state.spawned then process.spawn(time) end
	process.request_seek()
	if not file_timer:is_enabled() then file_timer:resume() end
end

thumb_debounce = mp.add_timeout(0.025, function()
	if thumb_pending then
		local args = thumb_pending
		thumb_pending = nil
		thumb_impl(args.time, args.r_x, args.r_y, args.script)
	end
end)
thumb_debounce:kill()

local function thumb(time, r_x, r_y, script)
	thumb_pending = { time = time, r_x = r_x, r_y = r_y, script = script }
	if not thumb_debounce:is_enabled() then
		thumb_debounce:resume()
	end
end

-- =============================================================================
-- OSC Preview API
-- =============================================================================

local function preview_update_draw(name, value)
	preview_draw = value

	if preview_draw == nil then
		clear(true)
		return
	end

	local hover_sec = mp.get_property_number("user-data/osc/hover-sec")
	thumb(hover_sec, value.x, value.y, nil)
end

-- =============================================================================
-- 属性观察
-- =============================================================================

local function watch_changes()
	if not state.dirty or not state.properties["video-params"] then return end
	state.dirty = false

	local old_w = state.effective_w
	local old_h = state.effective_h

	helper.calc_dimensions(state, options)

	local resized = old_w ~= state.effective_w or old_h ~= state.effective_h

	if resized then
		info(state.effective_w, state.effective_h)
	elseif state.last_has_vid ~= state.has_vid and state.has_vid ~= 0 then
		info(state.effective_w, state.effective_h)
	end

	schedule_prewarm()

	if state.spawned then
		if resized then
			local seek_time = state.last_seek_time
			process.run("quit")
			clear()
			state.spawned = false
			process.spawn(seek_time or mp.get_property_number("time-pos", 0))
			file_timer:resume()
		end
	end

	state.last_has_vid = state.has_vid

	if not state.spawned and not state.disabled and options.spawn_first and resized then
		process.spawn(mp.get_property_number("time-pos", 0))
		file_timer:resume()
	end
end

local function update_property(name, value)
	state.properties[name] = value
end

local function update_property_dirty(name, value)
	state.properties[name] = value
	state.dirty = true
end

local function update_tracklist(name, value)
	for _, track in ipairs(value) do
		if track.type == "video" and track.selected then
			state.properties["current-tracks/video"] = track
			return
		end
	end
end

local function sync_changes(prop, val)
	update_property(prop, val)
	if val == nil then return end

	if type(val) == "boolean" then
		if prop == "vid" then
			state.has_vid = 0
			state.last_has_vid = 0
			info(state.effective_w, state.effective_h)
			clear()
			return
		end
		val = val and "yes" or "no"
	end

	if prop == "vid" then
		state.has_vid = 1
	end

	if not state.spawned then return end

	process.run("set "..prop.." "..val)
	state.dirty = true
end

local function file_load(skip_batch_cancel)
	preview_draw = nil
	clear(true)
	if not skip_batch_cancel then
		batch.batch_cancel()
	end
	state.spawned = false
	state.real_w, state.real_h = nil, nil
	state.last_real_w, state.last_real_h = nil, nil
	state.last_seek_time = nil
	kill_info_timer()

	helper.calc_dimensions(state, options)
	info(state.effective_w, state.effective_h)

	schedule_prewarm()

	if options.cache_iframe == "always" and options.backend == "ffmpeg" then
		mp.add_timeout(1, function()
			if state.disabled then return end
			if not state.spawned then
				process.spawn(mp.get_property_number("time-pos", 0))
			end
			process.prefill_cache()
		end)
	end
end

local function shutdown()
	batch.batch_cancel(true)
	if state.prewarm_timer then
		state.prewarm_timer:kill()
	end
	process.run("quit")
	if state.file then
		state.file:close()
		state.file = nil
		state.file_bytes = 0
	end
	mp.add_timeout(0.3, function()
		helper.remove_thumbnail_files(state, options)
		if options.backend == "mpv" and os_name ~= "windows" then
			os.remove(options.socket)
			os.remove(options.socket..".run")
		end
	end)
end

-- =============================================================================
-- 注册事件
-- =============================================================================

mp.observe_property("current-tracks/video", "native", function(name, value)
	update_property(name, value)
	schedule_prewarm()
end)

mp.observe_property("track-list", "native", update_tracklist)
mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("video-dec-params", "native", update_property_dirty)
mp.observe_property("demuxer-via-network", "native", update_property)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("path", "native", update_property)
mp.observe_property("vid", "native", sync_changes)
mp.observe_property("edition", "native", sync_changes)

mp.observe_property("user-data/osc/draw-preview", "native", preview_update_draw)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)
mp.register_script_message("thumbnail_gen", thumb)
mp.register_script_message("thumbnail_clr", clear)

mp.register_event("file-loaded", function()
	file_load()
	bat_info()
end)
mp.register_event("shutdown", shutdown)

mp.register_script_message("thumb_engine-bat-info?", function() bat_info() end)

mp.add_key_binding(nil, "thumb_rerun", function()
	clear()
	shutdown()
	state.auto_run = true
	file_load(true)
	mp.osd_message("缩略图功能已重启", 2)
	mp.msg.info("缩略图功能已重启")
end)
mp.add_key_binding(nil, "thumb_toggle", function()
	if state.auto_run then
		state.auto_run = false
		clear()
		shutdown()
		file_load(true)
		mp.osd_message("缩略图功能已临时禁用", 2)
		mp.msg.info("缩略图功能已临时禁用")
	else
		state.auto_run = true
		file_load(true)
		mp.osd_message("缩略图功能已临时启用", 2)
		mp.msg.info("缩略图功能已临时启用")
	end
end)
mp.register_script_message("thumbnail_hwdec", function(hwdec_api)
	local hwdec_api_cur = options.hwdec
	if hwdec_api_cur == hwdec_api then return end
	if hwdec_api == "toggle" then
		if hwdec_api_cur == "no" then
			hwdec_api = "yes"
		else
			hwdec_api = "no"
		end
	end
	options.hwdec = hwdec_api
	mp.osd_message("缩略图已变更首选解码API：" .. hwdec_api, 2)
	mp.msg.info("缩略图已变更首选解码API：" .. hwdec_api)
	clear()
	shutdown()
	file_load(true)
end)

mp.register_script_message("batch_gen", function(json_str)
	local params = mp.utils.parse_json(json_str)
	if not params then return end
	if options.bat_min_duration > 0 then
		local duration = mp.get_property_number("duration", 0)
		if duration <= options.bat_min_duration then
			mp.msg.verbose("batch_gen: skipped, duration " .. duration .. "s <= bat_min_duration " .. options.bat_min_duration .. "s")
			return
		end
	end
	batch.batch_extract(params)
end)
mp.register_script_message("batch_pause", function()
	batch.batch_pause()
end)
mp.register_script_message("batch_clr", function(rmdir)
	batch.batch_cancel(rmdir == "rmdir")
end)

mp.register_idle(watch_changes)