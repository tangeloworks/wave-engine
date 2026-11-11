local microphone = {}

microphone.device = nil
microphone.source = nil
microphone.recording = false

microphone.supported_platforms = {
    windows = true,
    linux = true
}

local function ensure_device()
    if microphone.device then return true end
    if not (_G and _G.microphone) then return false end
    if not microphone.supported_platforms[G.system] then return false end
    local lib = _G.microphone
    local dev = lib.openDevice(nil, nil, 0.1)
    if not dev then return false end
    microphone.device = dev
    microphone.source = lib.newQueueableSource()
    if microphone.source then
        microphone.device:set_data_callback(function(_, data)
            microphone.source:queue(data)
            microphone.source:play()
        end)
    end
    return true
end

function microphone.start_rec()
    if not ensure_device() then return false end
    if microphone.recording then return true end
    if microphone.device then
        microphone.device:start()
        microphone.recording = true
        return true
    end
    return false
end

function microphone.stop_rec()
    if not microphone.recording then return false end
    if microphone.device then
        microphone.device:stop()
        microphone.recording = false
        return true
    end
    return false
end

function microphone.update()
    if microphone.device and microphone.device.poll then
        microphone.device:poll()
    end
end

function microphone.is_supported()
    return microphone.supported_platforms[G.system] and (_G.microphone ~= nil)
end

function microphone.get_def_dev_name()
    local lib = _G.microphone
    if lib and lib.getDefaultDeviceName then
        return lib.getDefaultDeviceName()
    end
    return "unknown"
end

function microphone.cleanup()
    if microphone.recording then microphone.stop_rec() end
    if microphone.device then
        microphone.device:release()
        microphone.device = nil
    end
    if microphone.source then
        microphone.source:release()
        microphone.source = nil
    end
end

function microphone.get_vol()
    if not microphone.source then return 0 end
    return 0
end

function microphone.set_cb(cb)
    if not ensure_device() then return false end
    if microphone.device then
        microphone.device:set_data_callback(cb)
        return true
    end
    return false
end

function microphone.on_voice(cb) end

function microphone.on_silence(cb) end

function microphone.start_recording()
    return microphone.start_rec()
end

return microphone
