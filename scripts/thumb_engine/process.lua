local mp = require "mp"
local common = require "common"
mp.utils = require "mp.utils"

local M = {}

local state, options, os_name, winapi

local mpv_path
local ffmpeg_path
local client_script = [=[
#!/usr/bin/env bash
MPV_IPC_FD=0; MPV_IPC_PATH="%s"
trap "kill 0" EXIT
while [[ $# -ne 0 ]]; do case $1 in --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;; esac; shift; done
if echo "print-text thumb_engine" >&"$MPV_IPC_FD"; then echo -n > "$MPV_IPC_PATH"; tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" & while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done; fi
]=]

-- ffmpeg 状态
local ffmpeg_async_id = nil
local ffmpeg_src_path = nil
local ffmpeg_pending_time = nil    -- 当前 ffmpeg 运行中时，记录最新的待 seek 时间
local ffmpeg_pending_fast = true   -- pending 请求的 fast 标志
local ffmpeg_seek_time = nil       -- 当前 ffmpeg 正在处理的时间点
-- ffmpeg 帧缓存
local frame_cache = {}             -- { [time_key] = raw_data_string }
local cache_order = {}             -- 插入顺序，用于 FIFO 淘汰
local cache_quantize = 5           -- 间隔（秒），同一区间内的请求映射到同一个 key

-- 预填充状态
local prefill_ids = {}
local prefill_queue = {}
local prefill_src_path = nil
local prefill_workers = 0
local prefill_stop

local function cache_key(time)
	return tostring(math.floor(time / cache_quantize))
end

local function cache_get(time)
	return frame_cache[cache_key(time)]
end

local function cache_put_data(time, data)
	local key = cache_key(time)
	if not data or #data == 0 then return end
	if not frame_cache[key] then
		-- 新条目：加入 FIFO 队列
		cache_order[#cache_order + 1] = key
		while #cache_order > options.cache_max do
			local old_key = table.remove(cache_order, 1)
			frame_cache[old_key] = nil
		end
	end
	-- 始终写入（精确帧覆盖关键帧）
	frame_cache[key] = data
end

local function cache_clear()
	frame_cache = {}
	cache_order = {}
	prefill_stop()
	prefill_src_path = nil
end

function M.init(_state, _options, _os_name, _winapi)
	state = _state
	options = _options
	os_name = _os_name
	winapi = _winapi

	if options.backend == "mpv" then
		-- resolve mpv binary path
		mpv_path = options.binpath
		local unique = mp.utils.getpid()

		if mpv_path == "default" or mpv_path == "bundle" then
			if os_name == "darwin" and unique then
				local tmp_path = string.gsub(M.subprocess({"ps", "-o", "comm=", "-p", tostring(unique)}).stdout, "[\n\r]", "")
				if mpv_path == "bundle" then
					mpv_path = tmp_path
					mpv_path = string.gsub(mpv_path, "/mpv%-bundle$", "/mpv")
				elseif mpv_path == "default" then
					mpv_path = tmp_path
				end
			else
				mpv_path = "mpv"
			end
		end
	else

		ffmpeg_path = options.binpath == "default" and "ffmpeg" or options.binpath
	end
end

function M.subprocess(args, async, callback)
	if async then
		return common.subprocess(args, {
			async = true,
			callback = callback,
			playback_only = true,
			env_path = (os_name == "darwin"),
		})
	end

	return common.subprocess(args, {
		playback_only = false,
		capture_stdout = true,
		env_path = (os_name == "darwin"),
	})
end

local function vf_gen()
	local qc = tonumber(options.quality) or 1
	local hdr = mp.get_property_number("video-params/sig-peak", 1)
	local vf_str_ed = ",format=fmt=bgra"
	local vf_str_full = "scale=w="..state.effective_w..":h="..state.effective_h..vf_str_ed
	if qc > 1 then
		vf_str_full = "gpu=api=vulkan:w="..state.effective_w..":h="..state.effective_h..vf_str_ed
	end
	if hdr > 1 then
		local hdr10 = mp.get_property_number("video-out-params/max-cll", 0)
		local dvp = mp.get_property_number("current-tracks/video/dolby-vision-profile", 0)
		local dvl = mp.get_property_number("current-tracks/video/dolby-vision-level", 0)
		local dvp5 = dvp == 5
		local dvp8_4 = (dvp == 8) and (dvl == 7) and (hdr10 == 0)
		if dvp5 and (qc > 2) then
			vf_str_full = "scale=w="..state.effective_w..":h="..state.effective_h..",libplacebo=colorspace=bt709:color_primaries=bt709:color_trc=bt709:tonemapping=hable"..vf_str_ed
		elseif dvp8_4 and (qc < 2) then
			vf_str_full = "scale=w="..state.effective_w..":h="..state.effective_h..",tonemap=tonemap=hable,zscale=transfer=linear,format=fmt=gbrp,zscale=primaries=bt709:transfer=bt709:matrix=bt709:range=pc"..vf_str_ed
		end
	end
	return vf_str_full
end

-- =============================================================================
-- spawn
-- =============================================================================

local function spawn_mpv(time)
	local path = state.properties["path"]
	if path == nil then return end

	if options.quit_after_inactivity > 0 then
		if state.show_thumbnail or state.activity_timer:is_enabled() then
			state.activity_timer:kill()
		end
		state.activity_timer:resume()
	end

	local open_filename = state.properties["stream-open-filename"]
	local ytdl = open_filename and state.properties["demuxer-via-network"] and path ~= open_filename

	state.remove_thumbnail_files()

	local vid = state.properties["vid"]
	state.has_vid = vid or 0

	local args = {
		mpv_path, "--config=no",
		"--terminal=no", "--msg-level=all=no", "--idle=yes", "--keep-open=always",
		"--pause=yes", "--ao=null",
		"--osc=no", "--load-stats-overlay=no", "--load-console=no", "--load-commands=no", "--load-auto-profiles=no",
		"--load-select=no", "--load-context-menu=no", "--load-positioning=no",
		"--clipboard-backends-clr", "--video-osd=no", "--autoload-files=no",
		"--vd-lavc-skiploopfilter=all", "--vd-lavc-skipidct=all", "--vd-lavc-fast", "--vd-lavc-threads="..options.sw_threads, "--hwdec="..options.hwdec,
		"--edition="..(state.properties["edition"] or "auto"), "--vid="..(vid or "auto"), "--sub=no", "--audio=no",
		"--start="..time,
		"--dither-depth=no", "--tone-mapping=hable",
		"--audio-pitch-correction=no", "--deinterlace=no",
		"--ytdl="..(ytdl and "yes" or "no"), "--ytdl-format=worstvideo/worst",
		"--vf="..vf_gen(), "--ovc=rawvideo", "--of=image2", "--ofopts=update=1", "--ocopy-metadata=no", "--o="..options.tnpath,
		"--input-media-keys=no"
	}

	if not ytdl then
		table.insert(args, "--demuxer-max-bytes=128KiB")
		table.insert(args, "--demuxer-readahead-secs=0")
	end

	if os_name == "darwin" then
		table.insert(args, "--macos-app-activation-policy=prohibited")
	end

	if os_name == "windows" then
		table.insert(args, "--media-controls=no")
		table.insert(args, "--input-ipc-server=" .. options.socket)
	else
		local client_script_path = options.socket .. ".run"
		if not state.script_written then
			local f = io.open(client_script_path, "w+")
			if not f then
				mp.msg.error("client script write failed")
				return
			end
			f:write(string.format(client_script, options.socket))
			f:close()
			state.script_written = true
			M.subprocess({"chmod", "+x", client_script_path}, true)
		end
		table.insert(args, "--scripts=" .. client_script_path)
	end

	table.insert(args, "--")
	table.insert(args, path)

	state.spawned = true
	state.spawn_waiting = true

	M.subprocess(args, true,
		function(success, result)
			-- 子进程退出：重置全部运行状态
			state.spawned = false
			state.spawn_waiting = false
			if success == false or not result
				or (result.status ~= 0 and result.status ~= -2) then
				mp.msg.error("mpv subprocess create failed")
				mp.commandv("show-text", "thumb_engine 子进程创建失败！", 5)
			end
		end
	)
end

local function spawn_ffmpeg(time)
	local path = state.properties["path"]
	if path == nil then return end

	-- TODO: ffmpeg后端暂不支持流媒体；清空状态并返回
	if state.properties["demuxer-via-network"] then
		cache_clear()
		ffmpeg_src_path = nil
		state.spawned = false
		return
	end

	if options.quit_after_inactivity > 0 then
		if state.show_thumbnail or state.activity_timer:is_enabled() then
			state.activity_timer:kill()
		end
		state.activity_timer:resume()
	end

	-- 记录源路径供后续 seek 使用（新文件时清空内存和旧缩略图缓存）
	if ffmpeg_src_path ~= path then
		cache_clear()
		state.remove_thumbnail_files()
	end
	ffmpeg_src_path = path
	state.spawned = true
end

function M.spawn(time)
	if state.disabled then return end
	if options.backend == "ffmpeg" then
		spawn_ffmpeg(time)
	else
		spawn_mpv(time)
	end
end

-- =============================================================================
-- Seek
-- =============================================================================

local precise_cur
local seek_period_counter = 0
local seek_timer

local function seek_mpv(fast)
	if not state.last_seek_time then return end

	local mode
	if precise_cur == 2 then
		mode = "absolute+exact"
	elseif precise_cur == 1 then
		mode = "absolute+keyframes"
	else
		mode = fast and "absolute+keyframes" or "absolute+exact"
	end

	M.run("async seek " .. state.last_seek_time .. " " .. mode)
end

local function build_ffmpeg_args(seek_time, use_keyframe)
	local args = common.ffmpeg_base_args(ffmpeg_path)
	common.append_args(args, common.ffmpeg_fast_input_args())
	common.append_args(args, common.ffmpeg_hwaccel_args(options.hwdec, os_name))

	local dvp = mp.get_property_number("current-tracks/video/dolby-vision-profile", 0)
	local hdr = mp.get_property_number("video-params/sig-peak", 1)
	local vf = common.build_scale_vf(state.effective_w, state.effective_h, {
		dvp = dvp,
		hdr = hdr,
		dvp_any = true,
	})

	if use_keyframe then
		table.insert(args, "-noaccurate_seek")
	end

	table.insert(args, "-ss")
	table.insert(args, tostring(seek_time))
	table.insert(args, "-i")
	table.insert(args, ffmpeg_src_path)

	common.append_args(args, {
		"-threads", tostring(options.sw_threads),
		"-vframes", "1",
		"-an", "-sn", "-dn",
		"-vf", vf,
		"-pix_fmt", "bgra",
		"-f", "rawvideo",
		"pipe:1",
	})

	return args
end

local function build_ffmpeg_command(args)
	return common.ffmpeg_command(args, {
		playback_only = true,
		capture_stdout = true,
		capture_size = state.effective_w * state.effective_h * 4 + 4096,
		env_path = (os_name == "darwin"),
	})
end

-- =============================================================================
-- 预填充缓存（ always 模式）
-- =============================================================================

prefill_stop = function()
	for id in pairs(prefill_ids) do
		mp.abort_async_command(id)
	end
	prefill_ids = {}
	prefill_queue = {}
	prefill_workers = 0
end

local function prefill_worker()
	if prefill_workers <= 0 then return end
	while #prefill_queue > 0 do
		if not ffmpeg_src_path or ffmpeg_src_path ~= prefill_src_path then
			break
		end

		local time = table.remove(prefill_queue, 1)

		if not frame_cache[cache_key(time)] then
			local args = build_ffmpeg_args(time, true)
			local command = build_ffmpeg_command(args)

			local id
			id = mp.command_native_async(command, function(success, result)
				prefill_ids[id] = nil
				local raw_data = success and result and result.stdout or nil
				if raw_data and #raw_data > 0 then
					cache_put_data(time, raw_data)
				end
				prefill_worker()
			end)
			prefill_ids[id] = true
			return
		end
	end

	-- 队列耗尽或被中断
	prefill_workers = prefill_workers - 1
	if prefill_workers <= 0 then
		prefill_workers = 0
		if #prefill_queue == 0 and prefill_src_path then
			mp.msg.info("cache prefill done (" .. #cache_order .. "/" .. options.cache_max .. ")")
		end
	end
end

function M.prefill_cache()
	if options.cache_iframe ~= "always" or not ffmpeg_src_path then return end
	prefill_stop()

	local duration = mp.get_property_number("duration", 0)
	if duration <= 0 then return end

	prefill_queue = {}
	prefill_src_path = ffmpeg_src_path
	local step = duration / options.cache_max

	for i = 0, options.cache_max - 1 do
		table.insert(prefill_queue, i * step + step / 2)
	end

	mp.msg.info("cache prefill start: " .. options.cache_max .. " frames, step=" .. string.format("%.1f", step) .. "s, workers=" .. options.be_workers)

	-- 启动 be_workers 个并行 worker
	local concurrency = math.max(1, options.be_workers)
	for _ = 1, concurrency do
		prefill_workers = prefill_workers + 1
		prefill_worker()
	end
end

-- =============================================================================

local function seek_ffmpeg(fast)
	if not state.last_seek_time or not ffmpeg_src_path then return end

	-- 仅快速模式使用缓存；精确模式始终走 ffmpeg 以获取准确帧
	if options.cache_iframe ~= "never" and fast then
		local data = cache_get(state.last_seek_time)
		if data then
			local f = io.open(options.tnpath, "wb")
			if f then
				f:write(data)
				f:close()
			end
			return
		end
	end

	-- 如果上一个 ffmpeg 还在运行，不 abort 它（让它跑完产出缩略图）
	-- 仅记录最新时间，等它完成后再启动新的
	if ffmpeg_async_id then
		ffmpeg_pending_time = state.last_seek_time
		ffmpeg_pending_fast = fast
		return
	end

	local use_keyframe = (precise_cur == 1) or (precise_cur == 0 and fast)
	local args = build_ffmpeg_args(state.last_seek_time, use_keyframe)

	ffmpeg_seek_time = state.last_seek_time

	-- 通过 stdout 管道捕获帧数据，避免与 file_timer 的文件竞态
	local command = build_ffmpeg_command(args)

	ffmpeg_async_id = mp.command_native_async(command, function(success, result)
		ffmpeg_async_id = nil
		local raw_data = success and result and result.stdout or nil

		-- 将帧数据写入 tnpath 供 file_timer 检测并显示
		if raw_data and #raw_data > 0 then
			local f = io.open(options.tnpath, "wb")
			if f then
				f:write(raw_data)
				f:close()
			end
		end

		-- 直接从管道数据缓存
		if options.cache_iframe ~= "never" and ffmpeg_seek_time and raw_data then
			cache_put_data(ffmpeg_seek_time, raw_data)
		end

		ffmpeg_seek_time = nil
		-- 完成后如果有待处理的新时间，立即启动下一个
		if ffmpeg_pending_time then
			state.last_seek_time = ffmpeg_pending_time
			local pending_fast = ffmpeg_pending_fast
			ffmpeg_pending_time = nil
			ffmpeg_pending_fast = true
			seek_ffmpeg(pending_fast)
		end
	end)
end

local function seek(fast)
	if options.backend == "ffmpeg" then
		seek_ffmpeg(fast)
	else
		seek_mpv(fast)
	end
end

function M.init_seek()
	precise_cur = options.precise
	local seek_period_cur = options.frequency

	seek_timer = mp.add_periodic_timer(seek_period_cur, function()
		if seek_period_counter == 0 then
			seek(true)
			seek_period_counter = 1
		else
			if seek_period_counter == 2 then
				seek_timer:kill()
				seek()
			else seek_period_counter = seek_period_counter + 1 end
		end
	end)
	seek_timer:kill()
end

function M.request_seek()
	if seek_timer:is_enabled() then
		seek_period_counter = 0
	else
		seek_timer:resume()
		seek(true)
		seek_period_counter = 1
	end
end

function M.kill_seek_timer()
	seek_timer:kill()
end

-- =============================================================================
-- run (IPC)
-- =============================================================================

-- 管道未就绪时缓存的命令
local pending_commands = {}

-- 尝试写入一条命令；返回 true 表示成功
local function run_mpv_try_write(command)
	if options.direct_io then
		local hPipe = winapi.C.CreateFileW(winapi.socket_wc, winapi.GENERIC_WRITE, 0, nil, winapi.OPEN_EXISTING, winapi._createfile_pipe_flags, nil)
		if hPipe == winapi.INVALID_HANDLE_VALUE then
			return false
		end
		local buf = command .. "\n"
		winapi.C.SetNamedPipeHandleState(hPipe, winapi.PIPE_NOWAIT, nil, nil)
		-- 修复：不写 NUL 字节，并检查 WriteFile 返回值
		local ok = winapi.C.WriteFile(hPipe, buf, #buf, winapi._lpNumberOfBytesWritten, nil)
		winapi.C.CloseHandle(hPipe)
		return ok and true or false
	end

	local command_n = command.."\n"

	if os_name == "windows" then
		if state.file and state.file_bytes + #command_n >= 4096 then
			state.file:close()
			state.file = nil
			state.file_bytes = 0
		end
		if not state.file then
			state.file = io.open("\\\\.\\pipe\\"..options.socket, "r+b")
		end
	elseif not state.file then
		state.file = io.open(options.socket, "r+")
	end
	if state.file then
		state.file_bytes = state.file:seek("end")
		state.file:write(command_n)
		state.file:flush()
		return true
	end
	return false
end

-- 重试定时器：管道未就绪时每 50ms 重试一次
local flush_timer = mp.add_timeout(0.05, function()
	if not state.spawned then
		pending_commands = {}
		return
	end
	local remaining = {}
	for _, cmd in ipairs(pending_commands) do
		if not run_mpv_try_write(cmd) then
			remaining[#remaining + 1] = cmd
		end
	end
	pending_commands = remaining
	if #pending_commands > 0 then
		flush_timer:resume()
	end
end)
flush_timer:kill()

local function run_mpv(command)
	if not state.spawned then
		pending_commands = {}
		return
	end

	-- 先尝试清空积压的命令
	if #pending_commands > 0 then
		local remaining = {}
		for _, cmd in ipairs(pending_commands) do
			if not run_mpv_try_write(cmd) then
				remaining[#remaining + 1] = cmd
			end
		end
		pending_commands = remaining
	end

	if not run_mpv_try_write(command) then
		pending_commands[#pending_commands + 1] = command
		if not flush_timer:is_enabled() then
			flush_timer:resume()
		end
	end
end

local function run_ffmpeg(command)
	-- ffmpeg 后端仅处理 quit（取消当前进程）
	if command == "quit" then
		if ffmpeg_async_id then
			mp.abort_async_command(ffmpeg_async_id)
			ffmpeg_async_id = nil
		end
		if prefill_workers > 0 then
			prefill_stop()
		end
		ffmpeg_src_path = nil
		state.spawned = false
	end
end

function M.run(command)
	if options.backend == "ffmpeg" then
		run_ffmpeg(command)
	else
		run_mpv(command)
	end
end

return M