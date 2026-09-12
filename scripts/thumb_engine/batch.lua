local mp = require "mp"
local common = require "common"
mp.utils = require "mp.utils"

local M = {}

local options
local os_name

-- Batch state
local batch_ids = {}
local batch_queue = {}
local batch_workers = 0
local batch_active = false
local batch_params = nil
local batch_completed = {}
local batch_completed_count = 0
local batch_failed = 0

function M.init(_options, _os_name)
	options = _options
	os_name = _os_name
end

local function get_bat_dir()
	local base = options.bat_path
	if not base or base == "" then
		if os_name == "windows" then
			base = os.getenv("TEMP") or os.getenv("TMP") or "C:/Temp"
		else
			base = "/tmp"
		end
	end
	base = base:gsub("[/\\]+$", "")
	return mp.utils.join_path(base, "thumb_bat" .. mp.utils.getpid())
end

local function build_ffmpeg_multi_args(tasks, use_keyframe)
	local ffmpeg_path = options.bat_binpath == "default" and "ffmpeg" or options.bat_binpath
	local input_path = mp.get_property("path")
	if not input_path or input_path == "" then return nil end

	local args = common.ffmpeg_base_args(ffmpeg_path)
	local hwaccel_args = common.ffmpeg_hwaccel_args(options.bat_hwdec, os_name)
	local per_input = common.ffmpeg_fast_input_args()

	for _, task in ipairs(tasks) do
		common.append_args(args, per_input)
		common.append_args(args, hwaccel_args)
		if use_keyframe then
			args[#args + 1] = "-noaccurate_seek"
		end
		args[#args + 1] = "-ss"
		args[#args + 1] = tostring(task.time)
		args[#args + 1] = "-i"
		args[#args + 1] = input_path
	end

	for i, task in ipairs(tasks) do
		local output_path = mp.utils.join_path(batch_params._output_dir, "bat_" .. task.index .. ".bgra")
		common.append_args(args, {
			"-map", (i - 1) .. ":v:0",
			"-threads", tostring(options.bat_threads),
			"-vframes", "1",
			"-an", "-sn", "-dn",
			"-vf", batch_params._vf,
			"-pix_fmt", "bgra",
			"-f", "rawvideo",
			"-y", output_path,
		})
	end

	return args
end

-- =============================================================================

local function bat_draw(index)
	if not batch_params then return end
	local overlay_id = batch_params._overlay_ids[index + 1]
	local pos = batch_params.positions[index + 1]
	if not overlay_id or not pos then return end

	local path = mp.utils.join_path(batch_params._output_dir, "bat_" .. index .. ".bgra")
	common.overlay_add(
		overlay_id,
		pos[1],
		pos[2],
		path,
		batch_params.width,
		batch_params.height
	)
end

local function bat_clear()
	if not batch_params then return end
	for _, id in ipairs(batch_params._overlay_ids) do
		common.overlay_remove(id)
	end
end

local function try_accept_frame(index)
	local fpath = mp.utils.join_path(batch_params._output_dir, "bat_" .. index .. ".bgra")
	if not common.raw_bgra_ok(fpath, batch_params.width, batch_params.height) then
		return false
	end

	if not batch_completed[index] then
		batch_completed[index] = true
		batch_completed_count = batch_completed_count + 1
	end
	bat_draw(index)
	common.send_json(batch_params.requester, "batch_once", {
		index = index,
		path = fpath,
		width = batch_params.width,
		height = batch_params.height,
	})
	return true
end

-- =============================================================================

local function delete_batch_files(remove_dir)
	if not batch_params then return end
	local dir = batch_params._output_dir
	if remove_dir then
		common.remove_dir(dir, os_name)
	else
		for i = 0, #batch_params.times - 1 do
			os.remove(mp.utils.join_path(dir, "bat_" .. i .. ".bgra"))
		end
	end
end

local function abort_all()
	for id in pairs(batch_ids) do
		mp.abort_async_command(id)
	end
	batch_ids = {}
	batch_workers = 0
end

-- =============================================================================

local function batch_worker()
	-- 收尾分支：inactive 或队列空，统一处理 worker 计数
	if not batch_active or #batch_queue == 0 then
		if batch_workers > 0 then
			batch_workers = batch_workers - 1
		end

		if not batch_active then return end

		if batch_workers <= 0 then
			batch_workers = 0
			if batch_params then
				local total = #batch_params.times
				common.send_json(batch_params.requester, "batch_done", {
					total = total,
					completed = batch_completed_count,
					failed = batch_failed,
					output_dir = batch_params._output_dir,
					width = batch_params.width,
					height = batch_params.height,
				})
				mp.msg.info("batch done: " .. batch_completed_count .. "/" ..
					total .. ", failed: " .. batch_failed)
			end
			batch_active = false
		end
		return
	end

	local max_per_call = batch_params._use_libplacebo and 1 or 2
	local jobs = math.min(math.ceil(#batch_queue / batch_workers), max_per_call)
	if jobs < 1 then jobs = 1 end

	local tasks = {}
	for _ = 1, jobs do
		tasks[#tasks + 1] = table.remove(batch_queue, 1)
	end

	local cmd_args = build_ffmpeg_multi_args(tasks, batch_params.use_keyframe)
	if not cmd_args then
		batch_failed = batch_failed + #tasks
		mp.msg.warn("batch job: no video path available")
		batch_worker()
		return
	end

	local command = common.ffmpeg_command(cmd_args, {
		playback_only = true,
		env_path = (os_name == "darwin"),
	})

	local id
	id = mp.command_native_async(command, function(success, result)
		batch_ids[id] = nil

		if not batch_active then
			if batch_workers > 0 then
				batch_workers = batch_workers - 1
			end
			return
		end

		for _, task in ipairs(tasks) do
			if not try_accept_frame(task.index) then
				batch_failed = batch_failed + 1
				mp.msg.warn("batch frame " .. task.index .. " extraction failed")
			end
		end

		batch_worker()
	end)
	batch_ids[id] = true
end

-- =============================================================================

function M.batch_extract(params)
	if batch_active then
		M.batch_cancel()
	end

	local ov_ids = common.parse_overlay_ids(options.bat_overlay_ids)
	local bat_dir = get_bat_dir()

	batch_active = true
	params._overlay_ids = ov_ids
	params._output_dir = bat_dir
	params._vf = common.build_scale_vf(params.width, params.height, {
		dvp = mp.get_property_number("current-tracks/video/dolby-vision-profile", 0),
		hdr = mp.get_property_number("video-params/sig-peak", 1),
	})
	params._use_libplacebo = params._vf:find("libplacebo") ~= nil
	batch_params = params
	batch_completed = {}
	batch_completed_count = 0
	batch_failed = 0
	batch_queue = {}
	batch_ids = {}
	batch_workers = 0

	if not common.ensure_dir(bat_dir, os_name) then
		mp.msg.error("batch: cannot create output directory: " .. bat_dir)
		batch_active = false
		return
	end

	for i, time in ipairs(params.times) do
		local index = i - 1
		if not try_accept_frame(index) then
			table.insert(batch_queue, {index = index, time = time})
		end
	end

	local queued = #batch_queue
	local cached = batch_completed_count

	if queued == 0 then
		batch_active = false
		local total = #params.times
		common.send_json(params.requester, "batch_done", {
			total = total,
			completed = total,
			failed = 0,
			output_dir = bat_dir,
			width = params.width,
			height = params.height,
		})
		mp.msg.verbose("batch extract: " .. total .. " frames (all cached)")
		return
	end

	mp.msg.info("batch extract: " .. #params.times .. " frames (" .. cached ..
		" cached, " .. queued .. " queued), workers=" .. options.bat_be_workers)

	local concurrency = math.max(1, options.bat_be_workers)
	for _ = 1, math.min(concurrency, queued) do
		batch_workers = batch_workers + 1
		batch_worker()
	end
end

function M.batch_pause()
	local was_active = batch_active
	batch_active = false
	abort_all()
	bat_clear()
	if was_active then
		mp.msg.info("batch paused")
	end
end

function M.batch_cancel(remove_dir)
	local was_active = batch_active or batch_params ~= nil
	batch_active = false
	abort_all()
	bat_clear()
	delete_batch_files(remove_dir)
	batch_queue = {}
	batch_completed = {}
	batch_completed_count = 0
	batch_failed = 0
	batch_workers = 0
	batch_params = nil
	if was_active then
		mp.msg.info("batch cancelled" .. (remove_dir and " (rmdir)" or ""))
	end
end

return M