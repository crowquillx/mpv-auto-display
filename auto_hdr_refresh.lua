-- MPV Auto HDR and Refresh Rate Manager
-- Automatically manages Windows HDR settings and display refresh rate based on video content
-- Author: tan
-- Version: 1.1

local mp = require("mp")
local utils = require("mp.utils")

-- ============================================================================
-- CONFIGURATION - Modify these paths according to your system
-- ============================================================================

-- Full path to HDRCmd.exe
local hdr_cmd_path = "C:\\Tools\\HDRCmd.exe"

-- NirCmd.exe configuration
local nircmd_path = "C:\\Tools\\nircmd.exe"

-- Fallback default desktop refresh rate (used if auto-detection fails)
local default_desktop_refresh_rate = 120

-- Delay in milliseconds before starting playback if display settings were changed.
-- Set to 0 to disable.
local playback_start_delay_ms = 2000

-- Enable/disable features
local enable_hdr_management = true
local enable_refresh_rate_management = true

-- HDR Detection Configuration
local hdr_detection_config = {
    -- Traditional HDR formats
    detect_hdr10 = true,           -- st2084 (PQ) transfer
    detect_hlg = true,             -- arib-std-b67 (HLG) transfer
    detect_dolby_vision = true,    -- Dolby Vision content
    
    -- Wide color gamut detection
    detect_wide_gamut = true,      -- P3, Adobe RGB, etc.
    detect_bt2020_sdr = false,     -- BT.2020 primaries without HDR transfer
    
    -- High bit depth detection
    detect_high_bitdepth = false,  -- 10-bit+ content without HDR
    high_bitdepth_threshold = 10,  -- Minimum bit depth to consider "HDR-like"
    
    -- Additional formats
    detect_sl_hdr = true,          -- Sony/Philips SL-HDR
    detect_advanced_hdr = true,    -- Technicolor Advanced HDR
}

-- Logging verbosity (true for more detailed logs)
local verbose_logging = true

-- ============================================================================
-- STATE VARIABLES
-- ============================================================================

local script_turned_hdr_on = false
local script_changed_refresh_rate = false
local original_desktop_refresh_rate = nil
local original_desktop_resolution = { width = nil, height = nil, color_depth = nil }
local initial_refresh_rate_captured = false
local current_target_refresh_rate = nil
local video_data_observer_id = nil -- Added for property observer

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Enhanced logging with optional verbosity
local function log_info(message)
    mp.msg.info("[Auto HDR/Refresh] " .. message)
end

local function log_warn(message)
    mp.msg.warn("[Auto HDR/Refresh] " .. message)
end

local function log_error(message)
    mp.msg.error("[Auto HDR/Refresh] " .. message)
end

local function log_verbose(message)
    if verbose_logging then
        mp.msg.info("[Auto HDR/Refresh] [VERBOSE] " .. message)
    end
end

-- Check if a file exists
local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Execute command and capture output
local function execute_command_with_output(args_table)
    log_verbose("Executing command with output: " .. table.concat(args_table, " "))
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args_table
    })

    local output = nil
    if res.stdout then
        output = res.stdout:gsub("[\r\n]+$", "") -- Remove trailing newlines
    end
    log_verbose("Command output: " .. (output or "nil"))

    if res.status == 0 then
        return output, true
    else
        log_error("Command failed: " .. table.concat(args_table, " ") .. " - Error: " .. (res.error_string or "unknown error"))
        if res.stderr then log_error("Stderr: " .. res.stderr) end
        return output, false -- Return output even on failure, if any
    end
end

-- Execute command without capturing output
local function execute_command(args_table)
    log_verbose("Executing command: " .. table.concat(args_table, " "))
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
        args = args_table
    })
    if res.status == 0 then
        return true
    else
        log_error("Command failed: " .. table.concat(args_table, " ") .. " - Error: " .. (res.error_string or "unknown error"))
        if res.stderr then log_error("Stderr: " .. res.stderr) end
        return false
    end
end

-- ============================================================================
-- REFRESH RATE UTILITIES
-- ============================================================================

-- Check if NirCmd is available
local function check_nircmd()
    if file_exists(nircmd_path) then
        log_info("NirCmd found at: " .. nircmd_path)
        return true
    else
        log_error("NirCmd not found at: " .. nircmd_path)
        return false
    end
end

-- Get current display mode (simplified for NirCmd)
local function get_current_display_mode()
    -- Use stored values if we've captured them before
    if original_desktop_resolution.width and original_desktop_resolution.height then
        return {
            width = original_desktop_resolution.width,
            height = original_desktop_resolution.height,
            color_depth = original_desktop_resolution.color_depth or 32, -- Default to 32-bit
            refresh_rate = original_desktop_refresh_rate or default_desktop_refresh_rate
        }
    end
    
    -- NirCmd doesn't provide easy mode detection, so we use defaults
    -- User should adjust these values to match their display setup
    log_info("Using default display mode values - please adjust in script if needed")
    return {
        width = 3840,      -- Default 4K - adjust to your resolution
        height = 2160,
        color_depth = 32,  -- Default color depth
        refresh_rate = default_desktop_refresh_rate
    }
end

-- Capture the original desktop refresh rate and resolution
local function capture_original_display_mode()
    if initial_refresh_rate_captured then
        return true
    end
    
    log_info("Attempting to capture original display mode...")
    
    local mode = get_current_display_mode()
    if mode then
        original_desktop_refresh_rate = mode.refresh_rate
        original_desktop_resolution.width = mode.width
        original_desktop_resolution.height = mode.height
        original_desktop_resolution.color_depth = mode.color_depth or 32  -- Ensure default value
        initial_refresh_rate_captured = true
        
        log_info(string.format("Captured original display mode: %dx%d, %d-bit, %dHz", 
                 mode.width, mode.height, mode.color_depth or 32, mode.refresh_rate))
        return true
    else
        log_warn("Failed to capture original display mode, will use fallback default refresh rate: " .. default_desktop_refresh_rate .. "Hz")
        original_desktop_refresh_rate = default_desktop_refresh_rate
        original_desktop_resolution.color_depth = 32  -- Set default color depth in fallback case
        return false
    end
end

-- Map video FPS to target refresh rate
local function map_fps_to_refresh_rate(fps)
    if not fps or fps <= 0 then
        return nil
    end
    
    -- Round to handle floating point precision issues
    local rounded_fps = math.floor(fps * 1000 + 0.5) / 1000
    
    -- Common FPS to refresh rate mappings
    local fps_map = {
        [23.976] = 23, -- Target 23Hz for 23.976p (nircmd integer limitation)
        [24.000] = 24, -- Target 24Hz for 24p
        [25.000] = 25, -- Target 25Hz for 25p (or 50Hz)
        [29.970] = 29, -- Target 29Hz for 29.97p (nircmd integer limitation)
        [30.000] = 30, -- Target 30Hz for 30p (or 60Hz)
        [50.000] = 50, -- Target 50Hz for 50p
        [59.940] = 59, -- Target 59Hz for 59.94p (nircmd integer limitation)
        [60.000] = 60, -- Target 60Hz for 60p
    }
    
    -- First try exact match
    for map_fps, target_hz in pairs(fps_map) do
        if math.abs(rounded_fps - map_fps) < 0.01 then
            return target_hz
        end
    end
    
    -- Fallback: try common multiples or direct mapping
    if rounded_fps >= 23 and rounded_fps < 25 then
        return 24
    elseif rounded_fps >= 25 and rounded_fps < 27 then
        return 50  -- or 25 if preferred
    elseif rounded_fps >= 29 and rounded_fps < 31 then
        return 60  -- or 30 if preferred
    elseif rounded_fps >= 48 and rounded_fps < 52 then
        return 50
    elseif rounded_fps >= 59 and rounded_fps < 61 then
        return 60
    else
        -- For other frame rates, try to find a reasonable multiple
        -- This is a best-effort approach
        local common_refresh_rates = {24, 30, 50, 60, 75, 120, 144}
        for _, hz in ipairs(common_refresh_rates) do
            local ratio = hz / rounded_fps
            if ratio >= 1 and ratio <= 5 and math.abs(ratio - math.floor(ratio + 0.5)) < 0.1 then
                return hz
            end
        end
    end
    
    log_warn(string.format("No suitable refresh rate mapping found for %.3f FPS", fps))
    return nil
end

-- Change display refresh rate using NirCmd
local function change_refresh_rate(target_hz)
    if not check_nircmd() then
        log_error("NirCmd not available")
        return false
    end
    
    -- Get current mode primarily for width, height, and original color depth
    local mode_for_dims = get_current_display_mode()
    if not mode_for_dims then
        log_error("Cannot change refresh rate: failed to get current display mode for dimensions")
        return false
    end
    
    -- Determine the actual current refresh rate for comparison and logging
    local actual_current_hz
    if current_target_refresh_rate ~= nil then
        actual_current_hz = current_target_refresh_rate
    else
        actual_current_hz = original_desktop_refresh_rate or default_desktop_refresh_rate
    end
    
    -- Check if we're already at the target refresh rate
    if actual_current_hz == target_hz then
        log_verbose(string.format("Already at target refresh rate: %dHz (current: %dHz)", target_hz, actual_current_hz))
        -- If we are aiming for the original rate and we are already there, ensure current_target_refresh_rate is nil if it's a revert context.
        -- However, this function's job is to set a rate. Revert logic handles setting to nil.
        return true
    end
    
    log_info(string.format("Changing refresh rate from %dHz to %dHz (Resolution: %dx%d, ColorDepth: %d-bit)", 
             actual_current_hz, target_hz, mode_for_dims.width, mode_for_dims.height, mode_for_dims.color_depth))
    
    -- NirCmd syntax: nircmd.exe setdisplay <width> <height> <colordepth> <refresh_rate>
    local args = {
        nircmd_path, 
        "setdisplay", 
        tostring(mode_for_dims.width), 
        tostring(mode_for_dims.height), 
        tostring(mode_for_dims.color_depth), -- Use captured or default color depth
        tostring(target_hz)
    }
    
    local success = execute_command(args)
    
    if success then
        log_info(string.format("Successfully changed refresh rate to %dHz", target_hz))
        current_target_refresh_rate = target_hz -- Update the script's understanding of the current rate
        return true
    else
        log_error(string.format("Failed to change refresh rate to %dHz", target_hz))
        return false
    end
end

-- Revert to original refresh rate
local function revert_refresh_rate()
    local original_rate = original_desktop_refresh_rate or default_desktop_refresh_rate
    
    if not original_rate then
        log_error("Cannot revert refresh rate: no original rate captured and no default set")
        return false
    end

    if current_target_refresh_rate == nil then
        log_info(string.format("Refresh rate already considered original/default (%dHz, current_target_refresh_rate is nil). No revert action needed.", original_rate))
        script_changed_refresh_rate = false -- Ensure consistency
        return true
    end

    if current_target_refresh_rate == original_rate then
        log_info(string.format("Current target rate (%dHz) is the original rate. Finalizing revert state.", original_rate))
        current_target_refresh_rate = nil -- Mark as fully reverted
        script_changed_refresh_rate = false
        return true
    end
    
    -- At this point, current_target_refresh_rate is not nil and is different from original_rate
    log_info(string.format("Reverting refresh rate from %dHz to %dHz", current_target_refresh_rate, original_rate))
    
    if change_refresh_rate(original_rate) then
        -- change_refresh_rate will set current_target_refresh_rate = original_rate on success.
        -- Now, set it to nil to signify it's back to the system's original/default state from script's perspective.
        log_info(string.format("Successfully reverted refresh rate to %dHz. Finalizing revert state.", original_rate))
        current_target_refresh_rate = nil 
        script_changed_refresh_rate = false
        return true
    else
        log_error(string.format("Failed to revert refresh rate to %dHz.", original_rate))
        -- If revert fails, script_changed_refresh_rate remains true (or as it was), 
        -- and current_target_refresh_rate still holds the non-original value.
        return false
    end
end

-- ============================================================================
-- HDR UTILITIES
-- ============================================================================

-- Execute HDR command
local function execute_hdr_command(action)
    if not file_exists(hdr_cmd_path) then
        log_error("HDRCmd.exe not found: " .. hdr_cmd_path)
        return false
    end
    
    local args = {hdr_cmd_path, action}
    log_info("Executing HDR command: " .. action)
    
    local success = execute_command(args)
    
    if success then
        log_info("HDR command executed successfully: " .. action)
        return true
    else
        log_error("HDR command failed: " .. action)
        return false
    end
end

-- Get bit depth from pixel format
local function get_bit_depth(pixelformat)
    if not pixelformat then
        return 8 -- Default assumption
    end
    
    -- Common pixel format bit depth mappings
    local bit_depth_map = {
        -- 8-bit formats
        ["yuv420p"] = 8,
        ["yuv422p"] = 8,
        ["yuv444p"] = 8,
        ["nv12"] = 8,
        ["nv21"] = 8,
        
        -- 10-bit formats
        ["yuv420p10le"] = 10,
        ["yuv422p10le"] = 10,
        ["yuv444p10le"] = 10,
        ["yuv420p10be"] = 10,
        ["yuv422p10be"] = 10,
        ["yuv444p10be"] = 10,
        ["p010le"] = 10,
        ["p010be"] = 10,
        
        -- 12-bit formats
        ["yuv420p12le"] = 12,
        ["yuv422p12le"] = 12,
        ["yuv444p12le"] = 12,
        ["yuv420p12be"] = 12,
        ["yuv422p12be"] = 12,
        ["yuv444p12be"] = 12,
        
        -- 16-bit formats
        ["yuv420p16le"] = 16,
        ["yuv422p16le"] = 16,
        ["yuv444p16le"] = 16,
        ["yuv420p16be"] = 16,
        ["yuv422p16be"] = 16,
        ["yuv444p16be"] = 16,
    }
    
    local bit_depth = bit_depth_map[pixelformat]
    if bit_depth then
        return bit_depth
    end
    
    -- Fallback: extract from format name
    local depth = pixelformat:match("p(%d+)")
    if depth then
        return tonumber(depth)
    end
    
    return 8 -- Default fallback
end

-- Check if primaries indicate wide color gamut
local function is_wide_color_gamut(primaries)
    local wide_gamut_primaries = {
        "bt.2020",      -- Rec. 2020
        "dci-p3",       -- DCI-P3
        "display-p3",   -- Display P3
        "adobe-rgb",    -- Adobe RGB
        "prophoto-rgb", -- ProPhoto RGB
        "smpte431",     -- DCI-P3 D65
        "smpte432",     -- Display P3
    }
    
    for _, wg_primary in ipairs(wide_gamut_primaries) do
        if primaries == wg_primary then
            return true
        end
    end
    
    return false
end

-- Check if transfer function indicates HDR
local function is_hdr_transfer(transfer)
    local hdr_transfers = {
        "st2084",           -- PQ (HDR10, HDR10+)
        "arib-std-b67",     -- HLG (Hybrid Log-Gamma)
        "smpte-st-2084",    -- Alternative PQ naming
        "hlg",              -- Alternative HLG naming
        "smpte2084",        -- Another PQ variant
        "pq",               -- Short form PQ
        "rec2100-pq",       -- Rec. 2100 PQ
        "rec2100-hlg",      -- Rec. 2100 HLG
    }
    
    for _, hdr_transfer in ipairs(hdr_transfers) do
        if transfer == hdr_transfer then
            return true
        end
    end
    
    return false
end

-- Check for Dolby Vision markers
local function has_dolby_vision_metadata()
    -- Check for Dolby Vision side data or metadata
    local side_data = mp.get_property("video-params/dolby-vision")
    if side_data and side_data ~= "no" then
        return true
    end
    
    -- Check format name for Dolby Vision indicators
    local format_name = mp.get_property("file-format")
    if format_name and (format_name:find("dovi") or format_name:find("dolby")) then
        return true
    end
    
    return false
end

-- Comprehensive HDR content detection
local function is_hdr_content()
    -- Get video parameters
    local primaries = mp.get_property("video-params/primaries")
    local transfer = mp.get_property("video-params/transfer")
    local colorspace = mp.get_property("video-params/colorspace")
    local pixelformat = mp.get_property("video-params/pixelformat")
    local bit_depth = get_bit_depth(pixelformat)
    
    -- Log all detected parameters
    log_verbose(string.format("Video analysis - Primaries: %s, Transfer: %s, Colorspace: %s, Format: %s, Bit depth: %d", 
               primaries or "nil", transfer or "nil", colorspace or "nil", pixelformat or "nil", bit_depth))
    
    local hdr_detected = false
    local hdr_type = "Unknown"
    local detection_reasons = {}
    
    -- 1. Traditional HDR detection (HDR10, HLG)
    if hdr_detection_config.detect_hdr10 and transfer == "st2084" then
        hdr_detected = true
        hdr_type = "HDR10/HDR10+"
        table.insert(detection_reasons, "PQ (st2084) transfer function")
    elseif hdr_detection_config.detect_hlg and transfer == "arib-std-b67" then
        hdr_detected = true
        hdr_type = "HLG"
        table.insert(detection_reasons, "HLG (arib-std-b67) transfer function")
    end
    
    -- 2. Enhanced HDR transfer function detection
    if not hdr_detected and is_hdr_transfer(transfer) then
        if hdr_detection_config.detect_hdr10 or hdr_detection_config.detect_hlg then
            hdr_detected = true
            hdr_type = "HDR (" .. (transfer or "unknown") .. ")"
            table.insert(detection_reasons, "HDR transfer function: " .. (transfer or "unknown"))
        end
    end
    
    -- 3. Dolby Vision detection
    if hdr_detection_config.detect_dolby_vision and has_dolby_vision_metadata() then
        hdr_detected = true
        hdr_type = "Dolby Vision"
        table.insert(detection_reasons, "Dolby Vision metadata detected")
    end
    
    -- 4. Wide color gamut detection
    if not hdr_detected and hdr_detection_config.detect_wide_gamut and is_wide_color_gamut(primaries) then
        hdr_detected = true
        hdr_type = "Wide Color Gamut (" .. (primaries or "unknown") .. ")"
        table.insert(detection_reasons, "Wide color gamut primaries: " .. (primaries or "unknown"))
    end
    
    -- 5. BT.2020 without HDR transfer (optional)
    if not hdr_detected and hdr_detection_config.detect_bt2020_sdr and primaries == "bt.2020" then
        hdr_detected = true
        hdr_type = "BT.2020 SDR"
        table.insert(detection_reasons, "BT.2020 primaries (SDR)")
    end
    
    -- 6. High bit depth detection (optional)
    if not hdr_detected and hdr_detection_config.detect_high_bitdepth and 
       bit_depth >= hdr_detection_config.high_bitdepth_threshold then
        hdr_detected = true
        hdr_type = "High Bit Depth (" .. bit_depth .. "-bit)"
        table.insert(detection_reasons, bit_depth .. "-bit content")
    end
    
    -- 7. Additional format-specific detection
    if not hdr_detected then
        -- SL-HDR detection (Sony/Philips)
        if hdr_detection_config.detect_sl_hdr and transfer and 
           (transfer:find("sl-hdr") or transfer:find("sony")) then
            hdr_detected = true
            hdr_type = "SL-HDR"
            table.insert(detection_reasons, "SL-HDR transfer function")
        end
        
        -- Advanced HDR by Technicolor
        if hdr_detection_config.detect_advanced_hdr and transfer and 
           transfer:find("technicolor") then
            hdr_detected = true
            hdr_type = "Technicolor Advanced HDR"
            table.insert(detection_reasons, "Technicolor Advanced HDR")
        end
    end
    
    -- 8. Combination detection: Wide gamut + high bit depth
    if not hdr_detected and hdr_detection_config.detect_wide_gamut and 
       hdr_detection_config.detect_high_bitdepth then
        if is_wide_color_gamut(primaries) and bit_depth >= hdr_detection_config.high_bitdepth_threshold then
            hdr_detected = true
            hdr_type = "Wide Gamut + High Bit Depth"
            table.insert(detection_reasons, "Wide color gamut + " .. bit_depth .. "-bit")
        end
    end
    
    -- Log detection results
    if hdr_detected then
        local reasons_str = table.concat(detection_reasons, ", ")
        log_info(string.format("HDR content detected: %s (%s)", hdr_type, reasons_str))
        log_verbose("HDR content detected")
    else
        log_verbose("Non-HDR content detected")
    end
    
    return hdr_detected
end

-- ============================================================================
-- VIDEO DATA PROCESSING LOGIC (NEW SECTION)
-- ============================================================================

-- Function to handle both HDR and Refresh Rate once video data is available
local function process_video_data()
    log_verbose("Processing video data for HDR and Refresh Rate management.")
    local actual_display_change_made = false

    -- HDR Management
    if enable_hdr_management then
        local hdr_content = is_hdr_content()
        if hdr_content and not script_turned_hdr_on then
            if execute_hdr_command("on") then
                script_turned_hdr_on = true
                actual_display_change_made = true
            end
        elseif not hdr_content and script_turned_hdr_on then
            if execute_hdr_command("off") then
                script_turned_hdr_on = false
                actual_display_change_made = true
            end
        end
    end

    -- Refresh Rate Management
    if enable_refresh_rate_management then
        local container_fps = mp.get_property_native("container-fps")
        local estimated_fps = mp.get_property_native("estimated-vf-fps")
        
        local video_fps = nil
        if container_fps and container_fps > 0 and container_fps < 1000 then
            video_fps = container_fps
            log_verbose(string.format("Using container FPS: %.3f for refresh rate.", video_fps))
        elseif estimated_fps and estimated_fps > 0 and estimated_fps < 1000 then
            video_fps = estimated_fps
            log_verbose(string.format("Using estimated FPS: %.3f for refresh rate.", video_fps))
        end
        
        if video_fps then
            local target_hz = map_fps_to_refresh_rate(video_fps)
            if target_hz then
                local effective_current_hz
                local mode_for_dims = get_current_display_mode() -- Used for dimensions and base refresh rate

                if current_target_refresh_rate ~= nil then
                    effective_current_hz = current_target_refresh_rate
                else
                    effective_current_hz = mode_for_dims.refresh_rate -- From original/default
                end
                
                if not effective_current_hz then -- Ultimate fallback
                    effective_current_hz = default_desktop_refresh_rate 
                    log_warn("Effective current HZ could not be determined, using default: " .. default_desktop_refresh_rate .. "Hz")
                end

                if effective_current_hz ~= target_hz then
                    log_info(string.format("Attempting to change refresh rate from ~%dHz to %dHz (Video FPS: %.3f).", effective_current_hz, target_hz, video_fps))
                    if change_refresh_rate(target_hz) then 
                        script_changed_refresh_rate = true
                        actual_display_change_made = true
                    end
                else
                    log_verbose(string.format("Refresh rate %dHz already matches target %dHz for FPS %.3f.", effective_current_hz, target_hz, video_fps))
                end
            else
                log_info(string.format("No suitable refresh rate mapping found for video FPS %.3f", video_fps))
            end
        else
            log_warn("Could not determine video frame rate for refresh rate management.")
        end
    end
    return actual_display_change_made
end

local function observer_callback_for_video_data(name, value)
    log_verbose(string.format("Property '%s' observed, value: %s.", name, tostring(value)))
    if value ~= nil then -- Ensure 'video-params/primaries' (or observed property) is populated
        log_verbose("Key video property 'video-params/primaries' available. Proceeding with HDR/Refresh Rate checks.")
        local display_settings_were_changed = process_video_data()
        
        if display_settings_were_changed and playback_start_delay_ms > 0 then
            mp.set_property("pause", "yes")
            log_info(string.format("Display settings changed, pausing for %.2f seconds before resuming playback.", playback_start_delay_ms / 1000))
            mp.add_timeout(playback_start_delay_ms / 1000, function()
                log_info("Resuming playback after delay.")
                mp.set_property("pause", "no")
            end)
        end
        
        if video_data_observer_id then
            mp.unobserve_property(video_data_observer_id)
            video_data_observer_id = nil
            log_verbose("Video data observer unregistered after initial processing.")
        end
    else
        log_verbose(string.format("Property '%s' observed, but value is nil. Waiting.", name))
    end
end

local function setup_video_data_observer()
    log_verbose("Setting up video data observer for 'video-params/primaries'.")

    if video_data_observer_id then
        mp.unobserve_property(video_data_observer_id)
        video_data_observer_id = nil
    end
    
    video_data_observer_id = mp.observe_property("video-params/primaries", "native", observer_callback_for_video_data)
end

local function cleanup_observers()
    if video_data_observer_id then
        mp.unobserve_property(video_data_observer_id) -- Ensure property is unobserved
        video_data_observer_id = nil
        log_verbose("Video data observer unregistered during cleanup.")
    end
end

-- ============================================================================
-- MAIN EVENT HANDLERS
-- ============================================================================

-- Handle file loaded event
local function on_file_loaded()
    log_info("File loaded, preparing for content analysis...")
    
    -- Capture original display mode if not done yet
    if not initial_refresh_rate_captured then
        capture_original_display_mode()
    end
    
    -- Setup observer for when video data (like duration) is ready
    setup_video_data_observer()
end

-- Handle MPV shutdown
local function on_shutdown()
    log_info("MPV shutting down, reverting changes...")
    cleanup_observers() -- Cleanup observer
    
    -- Revert HDR
    if enable_hdr_management and script_turned_hdr_on then
        execute_hdr_command("off")
        script_turned_hdr_on = false
    end
    
    -- Revert refresh rate
    if enable_refresh_rate_management and script_changed_refresh_rate then
        revert_refresh_rate()
    end
    
    log_info("Cleanup completed")
end

-- Handle end of file (video finished playing)
local function on_end_file()
    log_info("Playback finished, reverting changes...")
    cleanup_observers() -- Cleanup observer

    -- Revert HDR
    if enable_hdr_management and script_turned_hdr_on then
        execute_hdr_command("off")
        script_turned_hdr_on = false
    end

    -- Revert refresh rate
    if enable_refresh_rate_management and script_changed_refresh_rate then
        revert_refresh_rate()
    end

    log_info("End-file cleanup completed")
end

-- ============================================================================
-- SCRIPT INITIALIZATION
-- ============================================================================

-- Initialize the script
local function initialize()
    log_info("Auto HDR and Refresh Rate Manager v1.1 initialized")
    log_info("HDR management: " .. (enable_hdr_management and "enabled" or "disabled"))
    log_info("Refresh rate management: " .. (enable_refresh_rate_management and "enabled" or "disabled"))
    log_info(string.format("Playback start delay on display change: %d ms", playback_start_delay_ms))
    
    -- Log HDR detection configuration
    log_info("HDR Detection Configuration:")
    log_info("  HDR10: " .. (hdr_detection_config.detect_hdr10 and "enabled" or "disabled"))
    log_info("  HLG: " .. (hdr_detection_config.detect_hlg and "enabled" or "disabled"))
    log_info("  Dolby Vision: " .. (hdr_detection_config.detect_dolby_vision and "enabled" or "disabled"))
    log_info("  Wide Color Gamut: " .. (hdr_detection_config.detect_wide_gamut and "enabled" or "disabled"))
    log_info("  High Bit Depth: " .. (hdr_detection_config.detect_high_bitdepth and "enabled" or "disabled"))
    log_info("  SL-HDR: " .. (hdr_detection_config.detect_sl_hdr and "enabled" or "disabled"))
    log_info("  Advanced HDR: " .. (hdr_detection_config.detect_advanced_hdr and "enabled" or "disabled"))
    
    -- Verify tool availability
    if enable_hdr_management and not file_exists(hdr_cmd_path) then
        log_warn("HDRCmd.exe not found at: " .. hdr_cmd_path)
        log_warn("HDR management will be disabled")
        enable_hdr_management = false
    end
    
    -- Check NirCmd availability for refresh rate management
    if enable_refresh_rate_management then
        if not check_nircmd() then
            log_warn("NirCmd not found - refresh rate management will be disabled")
            enable_refresh_rate_management = false
        end
    end
    
    -- Register event handlers
    mp.register_event("file-loaded", on_file_loaded)
    mp.register_event("shutdown", on_shutdown)
    mp.register_event("end-file", on_end_file)
    
    log_info("Event handlers registered successfully")
end

-- Start the script
initialize()
