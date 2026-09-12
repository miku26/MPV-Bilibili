local mp = require "mp"
mp.utils = require "mp.utils"

local M = {}
local NOOP = function() end

-- 构造 subprocess 命令表（不执行）
function M.build_command(args, opts)
	opts = opts or {}
	local command = {
		name = "subprocess",
		args = args,
		playback_only = opts.playback_only ~= false,
	}
	if opts.capture_stdout then command.capture_stdout = true end
	if opts.capture_stderr then command.capture_stderr = true end
	if opts.capture_size   then command.capture_size = opts.capture_size end
	if opts.env_path then
		command.env = "PATH=" .. (os.getenv("PATH") or "")
	end
	return command
end

-- 立即执行（或异步执行）
function M.subprocess(args, opts)
	opts = opts or {}
	local command = M.build_command(args, opts)
	if opts.async then
		return mp.command_native_async(command, opts.callback or function() end)
	end
	return mp.command_native(command)
end

M.ffmpeg_command = M.build_command

function M.append_args(dst, src)
	for i = 1, #src do
		dst[#dst + 1] = src[i]
	end
end

function M.ffmpeg_base_args(ffmpeg_path)
	return { ffmpeg_path or "ffmpeg", "-loglevel", "quiet" }
end

function M.ffmpeg_fast_input_args()
	return {
		"-analyzeduration", "0",
		"-probesize", "128000",
		"-skip_loop_filter", "all",
		"-skip_idct", "all",
		"-flags2", "fast",
	}
end

function M.ffmpeg_hwaccel_args(hwdec, os_name)
	local args = {}
	if hwdec ~= "no" then
		args[#args + 1] = "-hwaccel"
		if hwdec == "yes" or hwdec == "auto" then
			if os_name == "windows" then
				args[#args + 1] = "d3d11va"
			elseif os_name == "darwin" then
				args[#args + 1] = "videotoolbox"
			else
				args[#args + 1] = "auto"
			end
		else
			args[#args + 1] = hwdec
		end
	end
	return args
end

-- 统一 scale / HDR / DV 的 vf 构造
-- opts.dvp_any = true 时，dvp > 0 就走 libplacebo，process.lua 使用
-- batch.lua 不传 dvp_any，只对 dvp == 5 走 libplacebo
function M.build_scale_vf(w, h, opts)
	opts = opts or {}
	local flags = opts.flags or "fast_bilinear"
	local scale = "scale=" .. w .. ":" .. h .. ":flags=" .. flags
	local dvp = opts.dvp or 0
	local hdr = opts.hdr or 1

	if dvp == 5 or (opts.dvp_any and dvp > 0) then
		return scale .. ",libplacebo=colorspace=bt709:color_primaries=bt709:color_trc=bt709:gamut_mode=desaturate:tonemapping=spline"
	elseif hdr > 1 then
		return scale .. ",zscale=t=linear:npl=150,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=4.0,zscale=t=bt709:m=bt709:r=tv"
	end
	return scale
end

function M.parse_overlay_ids(str)
	local ids = {}
	if not str or str == "" then return ids end
	for id_str in str:gmatch("[^,]+") do
		local id = tonumber(id_str:match("^%s*(%d+)%s*$"))
		if id and id >= 0 and id <= 63 then
			ids[#ids + 1] = id
		end
	end
	return ids
end

function M.ensure_dir(dir, os_name)
	if os_name == "windows" then
		dir = dir:gsub("/", "\\")
	end
	if mp.utils.file_info(dir) then return true end

	if os_name == "windows" then
		M.subprocess({"cmd", "/c", "mkdir", dir}, {
			playback_only = false,
			capture_stdout = true,
			capture_stderr = true,
		})
	else
		M.subprocess({"mkdir", "-p", dir}, {
			playback_only = false,
		})
	end
	return mp.utils.file_info(dir) ~= nil
end

function M.remove_dir(dir, os_name)
	if os_name == "windows" then
		M.subprocess({"cmd", "/c", "rmdir", "/s", "/q", dir:gsub("/", "\\")}, {
			playback_only = false,
			capture_stdout = true,
			capture_stderr = true,
		})
	else
		M.subprocess({"rm", "-rf", dir}, {
			playback_only = false,
		})
	end
end

function M.raw_bgra_ok(path, w, h)
	local finfo = mp.utils.file_info(path)
	return finfo and finfo.size == w * h * 4
end

function M.overlay_add(id, x, y, file, w, h, opts)
	opts = opts or {}
	mp.command_native({
		name = "overlay-add",
		id = id,
		x = x,
		y = y,
		file = file,
		offset = 0,
		fmt = "bgra",
		w = w,
		h = h,
		stride = opts.stride or (4 * w),
		dw = opts.dw,
		dh = opts.dh,
	})
end

function M.overlay_remove(id)
	mp.command_native_async({name = "overlay-remove", id = id}, NOOP)
end

function M.send_json(target, msg, tbl)
	local json = mp.utils.format_json(tbl)
	if target then
		mp.commandv("script-message-to", target, msg, json)
	else
		mp.command_native_async({"script-message", msg, json}, NOOP)
	end
end

return M