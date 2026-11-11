--[[
Filter example
only Lua files: "Lua Files\0*.lua\0"
Lua and exe: "Lua Files\0*.lua\0Executables\0*.exe\0"
]]
filedialog = {}

local os_name = love.system.getOS()

local function try_cmd(cmd)
    local f = io.popen(cmd)
    if not f then return nil end
    local result = f:read("*a")
    f:close()
    result = result and result:match("[^\r\n]+")
    return result
end

if os_name == "Windows" then
    local ffi = require "ffi"
    local bit = require "bit"

    ffi.cdef [[
    typedef struct {
      unsigned long  lStructSize;
      void*          hwndOwner;
      void*          hInstance;
      const char*    lpstrFilter;
      char*          lpstrCustomFilter;
      unsigned long  nMaxCustFilter;
      unsigned long  nFilterIndex;
      char*          lpstrFile;
      unsigned long  nMaxFile;
      char*          lpstrFileTitle;
      unsigned long  nMaxFileTitle;
      const char*    lpstrInitialDir;
      const char*    lpstrTitle;
      unsigned long  Flags;
      unsigned short nFileOffset;
      unsigned short nFileExtension;
      const char*    lpstrDefExt;
      long           lCustData;
      void*          lpfnHook;
      const char*    lpTemplateName;
      void*          pvReserved;
      unsigned long  dwReserved;
      unsigned long  FlagsEx;
    } OPENFILENAMEA;

    int GetOpenFileNameA(OPENFILENAMEA *lpofn);
    int GetSaveFileNameA(OPENFILENAMEA *lpofn);
    unsigned long GetLastError(void);
    ]]

    local comdlg32 = ffi.load("comdlg32")
    local kernel32 = ffi.load("kernel32")

    local function show_dialog(is_save, title, filter, default_filename)
        filter = filter or "All Files\0*.*\0"
        local ofn = ffi.new("OPENFILENAMEA")
        ffi.fill(ofn, ffi.sizeof(ofn))

        local szFile = ffi.new("char[260]", default_filename or "\0")
        ofn.lStructSize = ffi.sizeof(ofn)
        ofn.hwndOwner = nil
        ofn.lpstrFile = szFile
        ofn.nMaxFile = 260
        ofn.lpstrFilter = filter
        ofn.nFilterIndex = 1
        ofn.Flags = bit.bor(0x800, 0x1000, 8)
        ofn.lpstrTitle = title or (is_save and "Save File" or "Open File")
        if is_save then
            if comdlg32.GetSaveFileNameA(ofn) ~= 0 then
                return ffi.string(ofn.lpstrFile)
            else
                return nil, kernel32.GetLastError()
            end
        else
            if comdlg32.GetOpenFileNameA(ofn) ~= 0 then
                return ffi.string(ofn.lpstrFile)
            else
                return nil, kernel32.GetLastError()
            end
        end
    end

    -- .open(title, filter, read)
    function filedialog.open(title, filter, read)
        local path, err = show_dialog(false, title, filter)
        if path and read then
            local f = io.open(path, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                return content, path, nil
            else
                return nil, path, "Failed to open file"
            end
        else
            return path, err
        end
    end

    function filedialog.save(title, filter, default_filename)
        return show_dialog(true, title, filter, default_filename)
    end
elseif os_name == "OS X" then
    function filedialog.open(title, filter, read)
        local script = 'osascript -e \'set theFile to choose file ' ..
            (title and ('with prompt "' .. title .. '" ') or '') ..
            'default location (path to documents folder)\' -e \'POSIX path of theFile\''
        local result = try_cmd(script)
        if result then
            if read then
                local f = io.open(result, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    return content, result, nil
                else
                    return nil, result, "Failed to open file"
                end
            else
                return result, nil
            end
        end
        return nil, "No file selected"
    end

    function filedialog.save(title, filter, default_filename)
        local script = 'osascript -e \'set theFile to choose file name ' ..
            (title and ('with prompt "' .. title .. '" ') or '') ..
            'default location (path to documents folder)\' -e \'POSIX path of theFile\''
        local result = try_cmd(script)
        return result
    end
else -- Linux
    function filedialog.open(title, filter, read)
        -- build filter string for zenity (if provided)
        local filter_cmd = ""
        if filter then
            for _, f in ipairs(filter) do
                filter_cmd = filter_cmd .. string.format(' --file-filter="%s (%s) | %s"', f.name, f.pattern, f.pattern)
            end
        end

        -- Zenity
        local zenity = try_cmd('zenity --file-selection --title="' ..
            (title or "Open File") .. '"' .. filter_cmd .. ' 2>/dev/null')
        if zenity then
            if read then
                local f = io.open(zenity, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    return content, zenity, nil
                else
                    return nil, zenity, "Failed to open file"
                end
            else
                return zenity, nil
            end
        end

        -- KDialog
        local kdialog = try_cmd('kdialog --getopenfilename . "' .. (title or "Open File") .. '" 2>/dev/null')
        if kdialog then
            if read then
                local f = io.open(kdialog, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    return content, kdialog, nil
                else
                    return nil, kdialog, "Failed to open file"
                end
            else
                return kdialog, nil
            end
        end

        -- Portal
        -- (not implementing filter for portal)
        local portal = try_cmd('xdg-desktop-portal --file=1 --open')
        if portal then
            if read then
                local f = io.open(portal, "rb")
                if f then
                    local content = f:read("*a")
                    f:close()
                    return content, portal, nil
                else
                    return nil, portal, "Failed to open file"
                end
            else
                return portal, nil
            end
        end

        return nil, "No file dialog tool found (tried zenity/kdialog/xdg-desktop-portal)"
    end

    function filedialog.save(title, filter, default_filename)
        -- only filter for zenity, others do not easily support save filters
        local filter_cmd = ""
        if filter then
            for _, f in ipairs(filter) do
                filter_cmd = filter_cmd .. string.format(' --file-filter="%s (%s) | %s"', f.name, f.pattern, f.pattern)
            end
        end

        local zenity = try_cmd('zenity --file-selection --save --confirm-overwrite --title="' ..
            (title or "Save File") ..
            '"' ..
            (default_filename and (' --filename="' .. default_filename .. '"') or "") .. filter_cmd .. ' 2>/dev/null')
        if zenity then return zenity end

        local kdialog = try_cmd('kdialog --getsavefilename . "' ..
            (title or "Save File") .. '" ' .. (default_filename or "") .. ' 2>/dev/null')
        if kdialog then return kdialog end

        return nil, "No file dialog tool found (tried zenity/kdialog)"
    end
end
