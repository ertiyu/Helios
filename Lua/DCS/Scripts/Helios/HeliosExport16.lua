-- ========================= HELIOS EXPORT ======================================
--
-- This file is GENERATED by Helios 1.6 Profile Editor.
-- You should not need to edit this file in most casees.
--
-- [Integration instructions to follow here]
--

-- ========================= CONFIGURATION ======================================

-- global scope for Helios public API, which is the code and state available to vehicle driver scripts
helios = {}
helios.version = "1.6.0"

-- local scope for privileged interface used for testing
local helios_impl = {}

-- local scope for private code, to avoid name clashes
local helios_private = {}

-- report start up before configuration happens, in case of error in the configuration
log.write("HELIOS.EXPORT", log.INFO, string.format("initializing Helios Export script version %s", helios.version))

-- ========================= CONFIGURATION ======================================
-- This section will be configured by a combination of the Helios Profile Editor
-- and editing by the user.

-- address to which we send
helios_private.host = "127.0.0.1"

-- UDP port to which we send
-- NOTE: our local port on which we listen is dynamic
helios_private.port = 9089

-- how many export intervals have to pass before we send low priority data again
helios_private.exportLowTickInterval = 2

-- seconds between ticks (high priority export interval)
helios_impl.exportInterval = 0.067

-- maximum number of seconds without us sending anything
-- NOTE: Helios needs us to send something to discover our UDP client port number
helios_impl.announceInterval = 3.0

-- seconds between announcements immeidately after change in vehicle, to give
-- Helios a chance to discover us after it restarts its interface
helios_impl.fastAnnounceInterval = 0.1

-- seconds after change in vehicle to use fast announcements
helios_impl.fastAnnounceDuration = 1.0

-- seconds between checks whether this file has changed, if hot reload is enabled
helios_impl.hotReloadInterval = 5.0

-- Module names are different from internal self names, so this table translates them
-- without instantiating every module.  Planes must be entered into this table to be
-- able to use modules from the Scripts\Mods directory.
local helios_module_names = {
    ["A-10C"] = "Helios_A10C",
    ["F-14B"] = "Helios_F14",
    ["F-16C_50"] = "Helios_F16C",
    ["FA-18C_hornet"] = "Helios_F18C",
    ["A-10A"] = "Helios_FC",
    ["F-15C"] = "Helios_FC",
    ["MiG-29"] = "Helios_FC",
    ["Su-25"] = "Helios_FC",
    ["Su-27"] = "Helios_FC",
    ["Su-33"] = "Helios_FC",
    ["AV8BNA"] = "Helios_Harrier",
    ["UH-1H"] = "Helios_Huey",
    ["Ka-50"] = "Helios_KA50",
    ["L-39"] = "Helios_L39",
    ["Mi-8MT"] = "Helios_MI8",
    ["MiG-21Bis"] = "Helios_Mig21Bis",
    ["P-51D"] = "Helios_P51",
    ["TF-51D"] = "Helios_P51",
    ["SA342"] = "Helios_SA342"
}

-- ========================= HOOKS CALLED BY DCS =================================
-- DCS Export Functions call these indirectly

function helios_impl.LuaExportStart()
    -- called once just before mission start.
    package.path = package.path .. ";.\\LuaSocket\\?.lua"
    package.cpath = package.cpath .. ";.\\LuaSocket\\?.dll"

    helios_impl.init()
end

function helios_impl.LuaExportBeforeNextFrame()
    helios_private.processInput()
end

function helios_impl.LuaExportAfterNextFrame()
end

function helios_impl.LuaExportStop()
    -- called once just after mission stop.
    helios_impl.unload()
end

function helios_impl.LuaExportActivityNextEvent(timeNow)
    helios_private.clock = timeNow
    local nextEvent = timeNow + helios_impl.exportInterval

    -- check if vehicle type has changed
    local selfName = helios.selfName()
    if selfName ~= helios_private.previousSelfName then
        helios_private.handleSelfNameChange(selfName)
    end

    -- count until we need to send low priority data
    helios_private.state.tickCount = helios_private.state.tickCount + 1

    if helios_private.driver.processExports ~= nil then
        -- let driver do it
        helios_private.driver.processExports(LoGetSelfData())
    else
        helios_private.processExports()
    end

    local heartBeat = nil
    if helios_private.clock > (helios_impl.announceInterval + helios_private.state.lastSend) then
        -- if we sent nothing for a long time, send something just to let Helios discover us
        heartBeat = helios_impl.announceInterval
    end
    if helios_private.state.fastAnnounceTicks > 0 then
        -- immediately after changing vehicle or otherwise resetting, announce very fast
        helios_private.state.fastAnnounceTicks = helios_private.state.fastAnnounceTicks - 1
        if helios_private.clock > (helios_impl.fastAnnounceInterval + helios_private.state.lastSend) then
            heartBeat = helios_impl.fastAnnounceInterval
        end
    end

    if heartBeat ~= nil then
        log.write("HELIOS.EXPORT", log.DEBUG, string.format("sending alive announcement after %f seconds without any data sent (clock %f, sent %f)",
            heartBeat,
            helios_private.clock,
            helios_private.state.lastSend
        ))
        helios_private.doSend("ALIVE", "")
    end

    helios_private.flush();
    return nextEvent
end

-- ========================= PUBLIC API FOR DRIVERS --------======================
-- These are the functions that may be used in Scripts/Helios/Drivers/*.lua files
-- to implement support for a specific vehicle.

function helios.splitString(str, delim, maxNb)
    -- quickly handle edge case
    if string.find(str, delim) == nil then
        return { str }
    end

    -- optional limit on number of fields
    if maxNb == nil or maxNb < 1 then
        maxNb = 0 -- No limit
    end
    local result = {}
    local pat = "(.-)" .. delim .. "()"
    local nb = 0
    local lastPos
    for part, pos in string.gfind(str, pat) do
        nb = nb + 1
        result[nb] = part
        lastPos = pos
        if nb == maxNb then
            break
        end
    end
    -- Handle the last field
    if nb ~= maxNb then
        result[nb + 1] = string.sub(str, lastPos)
    end
    return result
end

function helios.round(num, idp)
    local mult = 10 ^ (idp or 0)
    return math.floor(num * mult + 0.5) / mult
end

function helios.ensureString(s)
    if type(s) == "string" then
        return s
    else
        return ""
    end
end

function helios.textureToString(s)
    if s == nil then
        return "0"
    else
        return "1"
    end
end

function helios.parseIndication(indicator_id)
    -- Thanks to [FSF]Ian code
    local ret = {}
    local li = list_indication(indicator_id)
    if li == "" then
        return nil
    end
    local m = li:gmatch("-----------------------------------------\n([^\n]+)\n([^\n]*)\n")
    while true do
        local name, value = m()
        if not name then
            break
        end
        ret[name] = value
    end
    return ret
end

-- send a value if its value has changed, batching sends
function helios.send(id, value)
    if string.len(value) > 3 and value == string.sub("-0.00000000", 1, string.len(value)) then
        value = value:sub(2)
    end
    if helios_private.state.lastData[id] == nil or helios_private.state.lastData[id] ~= value then
        helios_private.doSend(id, value)
        helios_private.state.lastData[id] = value
    end
end

-- currently active vehicle/airplane
function helios.selfName()
    local info = LoGetSelfData()
    if info == nil then
        return ""
    end
    return info.Name
end

-- ========================= TESTABLE IMPLEMENTATION =============================
-- These functions are exported for use in mock testing, but are not for use by
-- drivers or modules.  Keeping their interface stable allows the mock tester to continue
-- to work.

-- called either from LuaExportStart hook or from hot reload
function helios_impl.init()
    log.write("HELIOS.EXPORT", log.DEBUG, "loading")

    -- load socket library
    log.write("HELIOS.EXPORT", log.DEBUG, "loading luasocket")
    helios_private.socketLibrary = require("socket")

    -- Simulation id
    log.write("HELIOS.EXPORT", log.DEBUG, "setting simulation ID")
    helios_private.simID = string.format("%08x*", os.time())

    -- most recently detected selfName
    helios_private.previousSelfName = ""

    -- event time 'now' as told to us by DCS
    helios_private.clock = 0

    -- init with empty driver that exports nothing by default
    -- NOTE: also clears state
    log.write("HELIOS.EXPORT", log.DEBUG, "installing empty driver")
    helios_impl.installDriver(helios_private.createDriver(), "")

    -- start service
    helios_private.clientSocket = helios_private.socketLibrary.udp()
    helios_private.clientSocket:setsockname("*", 0)
    helios_private.clientSocket:setoption("broadcast", true)
    helios_private.clientSocket:settimeout(.001) -- blocking, but for a very short time

    log.write("HELIOS.EXPORT", log.DEBUG, "loaded")
end

function helios_impl.unload()
    -- flush pending data, send DISCONNECT message so we can fire the Helios Disconnect event
    helios_private.doSend("DISCONNECT", "")
    helios_private.flush()

    -- free file descriptor and release port
    helios_private.clientSocket:close()

    log.write("HELIOS.EXPORT", log.DEBUG, "unloaded")
end

-- handle incoming message from Helios
function helios_impl.dispatchCommand(command)
    -- REVISIT: this is legacy code and does not guard anything
    local commandCode = string.sub(command, 1, 1)
    local rest = string.sub(command, 2):match("^(.-)%s*$");
    if (commandCode == "D") then
        local driverName = rest
        log.write("HELIOS.EXPORT", log.DEBUG, string.format("driver '%s' requested by Helios", driverName))
        local selfName = helios_impl.loadDriver(driverName)
        helios_impl.notifySelfName(selfName)
        helios_impl.notifyLoaded()
    elseif (commandCode == "M") then
        log.write("HELIOS.EXPORT", log.DEBUG, string.format("use of module requested by Helios"))
        local selfName = helios_impl.loadModule()
        helios_impl.notifySelfName(selfName)
        helios_impl.notifyLoaded()
    elseif helios_private.driver.processInput ~= nil then
        -- delegate commands other than 'P'
        helios_private.driver.processInput(command)
    elseif commandCode == "R" then
        -- reset command from Helios requests that we consider all values dirty
        helios_private.resetCachedValues()
    elseif (commandCode == "C") then
        -- click command from Helios
        local commandArgs = helios.splitString(rest, ",")
        local targetDevice = GetDevice(commandArgs[1])
        if type(targetDevice) == "table" then
            targetDevice:performClickableAction(commandArgs[2], commandArgs[3])
        end
    end
end

-- load the export driver for the vehicle (DCS info name of the vehicle) and driver short name, not including .lua extension
function helios_impl.loadDriver(driverName)
    local driver = helios_private.createDriver()
    local newDriverName = ""
    local success, result

    -- check if request is allowed
    local currentSelfName = helios.selfName()
    log.write("HELIOS.EXPORT", log.DEBUG, string.format("attempt to load driver '%s' for '%s'", driverName, currentSelfName))
    if currentSelfName ~= driverName then
        log.write("HELIOS.EXPORT", log.DEBUG, string.format("cannot load driver '%s' while vehicle '%s' is active", driverName, currentSelfName))
        -- tell Helios to choose something that makes sense, but don't disable driver
        return currentSelfName
    -- check if request is already satisfied
    elseif helios_impl.driverName == driverName then
        -- do nothing
        log.write("HELIOS.EXPORT", log.INFO, string.format("driver '%s' for '%s' is already loaded", driverName, currentSelfName))
        return currentSelfName
    else
        -- now try to load specific driver
        local driverPath = string.format("%sScripts\\Helios\\Drivers\\%s.lua", lfs.writedir(), driverName)
        success, result = pcall(dofile, driverPath)

        -- check result for nil, since driver may not have returned anything
        if success and result == nil then
            success = false
            result = string.format("driver %s did not return a driver object; incompatible with this export script",
                driverPath
            )
        end

        -- sanity check, make sure driver is for correct selfName, since race condition is possible
        if success and result.selfName ~= currentSelfName then
            success = false
            result = string.format("driver %s is for incorrect vehicle '%s'",
                driverPath,
                result.selfName
            )
        end
    end

    if success then
        -- merge, replacing anything specified by the driver
        for k, v in pairs(result) do
            driver[k] = v
        end
        log.write("HELIOS.EXPORT", log.INFO, string.format("loaded driver '%s' for '%s'", driverName, driver.selfName))
        newDriverName = driverName
    else
        -- if the load fails, just leave the driver initialized to defaults
        log.write(
            "HELIOS.EXPORT",
            log.WARNING,
            string.format("failed to load driver '%s' for '%s'; disabling interface", driverName, currentSelfName)
        )
        log.write("HELIOS.EXPORT", log.WARNING, result)
    end

    -- actually install the driver
    helios_impl.installDriver(driver, newDriverName)
    return currentSelfName
end

-- load the module for the current vehicle, even if we previously loaded a driver
function helios_impl.loadModule()
    local currentSelfName = helios.selfName()
    log.write("HELIOS.EXPORT", log.DEBUG, string.format("attempt to load module for '%s'", currentSelfName))
    local moduleName = helios_module_names[currentSelfName]
    if moduleName == nil then
        return currentSelfName
    end
    if helios_impl.moduleName ~= nil then
        log.write("HELIOS.EXPORT", log.DEBUG, string.format("module '%s' already active for '%s'", moduleName, currentSelfName))
        return currentSelfName
    end
    local modulePath = string.format("%sScripts\\Helios\\Mods\\%s.lua", lfs.writedir(), moduleName)
    if (lfs.attributes(modulePath) ~= nil) then
        -- use export-everything module for this aircraft
        -- NOTE: this makes us compatible with Capt Zeen profiles
        local driver = helios_impl.createModuleDriver(currentSelfName, moduleName)
        if driver ~= nil then
            helios_impl.installDriver(driver, moduleName)
            return currentSelfName
        end
        -- if we fail, we just leave the previous driver installed
    end
end

function helios_impl.installDriver(driver, driverName)
    -- shut down any existing driver
    if helios_private.driver ~= nil then
        helios_private.driver.unload()
        helios_private.driver = nil
    end

    -- install driver
    driver.init()
    helios_private.driver = driver
    helios_impl.driverName = driverName
    helios_impl.moduleName = driver.moduleName

    -- drop any remmaining data and mark all values as dirty
    helios_private.clearState()
end

function helios_impl.notifyLoaded()
    -- export code for 'currently active vehicle, reserved across all DCS interfacess
    if (helios_impl.moduleName ~= nil) then
        log.write("HELIOS.EXPORT", log.INFO, string.format("notifying Helios of active module '%s'", helios_impl.moduleName))
        helios_private.doSend("ACTIVE_MODULE", helios_impl.moduleName)
    else
        log.write("HELIOS.EXPORT", log.INFO, string.format("notifying Helios of active driver '%s'", helios_impl.driverName))
        helios_private.doSend("ACTIVE_DRIVER", helios_impl.driverName)
    end
    helios_private.flush()
end

-- for testing
function helios_impl.setSimID(value)
    helios_private.simID = value
end

-- ========================= PRIVATE CODE ========================================

-- luasocket
helios_private.socketLibrary = nil -- lazy init

function helios_private.clearState()
    helios_private.state = {}

    helios_private.state.packetSize = 0
    helios_private.state.sendStrings = {}
    helios_private.state.lastData = {}

    -- event time of last message sent
    helios_private.state.lastSend = 0

    -- Frame counter for non important data
    helios_private.state.tickCount = 0

    -- ticks of fast announcement remaining
    helios_private.state.fastAnnounceTicks = helios_impl.fastAnnounceDuration / helios_impl.exportInterval
end

function helios_private.processArguments(device, arguments)
    if arguments == nil then
        return
    end
    local lArgumentValue
    for lArgument, lFormat in pairs(arguments) do
        lArgumentValue = string.format(lFormat, device:get_argument_value(lArgument))
        helios.send(lArgument, lArgumentValue)
    end
end

-- sends without checking if the value has changed
function helios_private.doSend(id, value)
    local data = id .. "=" .. value
    local dataLen = string.len(data)

    if dataLen + helios_private.state.packetSize > 576 then
        helios_private.flush()
    end

    table.insert(helios_private.state.sendStrings, data)
    helios_private.state.packetSize = helios_private.state.packetSize + dataLen + 1
end

function helios_private.flush()
    if #helios_private.state.sendStrings > 0 then
        local packet = helios_private.simID .. table.concat(helios_private.state.sendStrings, ":") .. "\n"
        helios_private.socketLibrary.try(helios_private.clientSocket:sendto(packet, helios_private.host, helios_private.port))
        helios_private.state.lastSend = helios_private.clock
        helios_private.state.sendStrings = {}
        helios_private.state.packetSize = 0
    end
end

function helios_private.resetCachedValues()
    helios_private.state.lastData = {}

    -- make sure low priority is sent also
    helios_private.state.tickCount = helios_private.exportLowTickInterval
end

function helios_private.processInput()
    local success, lInput = pcall(helios_private.clientSocket.receive, helios_private.clientSocket)
    if not success then
        -- happens on interrupt
        return
    end
    if lInput then
        helios_impl.dispatchCommand(lInput)
    end
end

function helios_private.createDriver()
    -- defaults
    local driver = {}
    driver.selfName = ""
    driver.everyFrameArguments = {}
    driver.arguments = {}
    function driver.processHighImportance()
        -- do nothing
    end
    function driver.processLowImportance()
        -- do nothing
    end
    function driver.init()
        -- do nothing
    end
    function driver.unload()
        -- do nothing
    end
    return driver
end

function helios_impl.notifySelfName(selfName)
    -- export code for 'currently active vehicle, reserved across all DCS interfacess
    log.write("HELIOS.EXPORT", log.INFO, string.format("notifying Helios of active vehicle '%s'", selfName))
    helios_private.doSend("ACTIVE_VEHICLE", selfName)
    helios_private.flush()
end

function helios_private.handleSelfNameChange(selfName)
    log.write(
        "HELIOS.EXPORT",
        log.INFO,
        string.format("changed vehicle from '%s' to '%s'", helios_private.previousSelfName, selfName)
    )
    helios_private.previousSelfName = selfName

    -- no matter what, the current driver is done
    helios_private.clearState()
    helios_impl.installDriver(helios_private.createDriver(), "")

    -- load module when present
    -- load driver when no module present
    -- load driver also when told to do so by Helios later
    helios_impl.loadModule();
    if (helios_impl.moduleName == nil) then
        -- try driver or give up
        helios_impl.loadDriver(selfName);
    end

    -- tell Helios results
    helios_impl.notifySelfName(selfName)
    helios_impl.notifyLoaded()
end

--- default implementation of exports, used if not overridden by the driver
function helios_private.processExports()
    local mainPanetargetDevice = GetDevice(0)
    if type(mainPanetargetDevice) == "table" then
        mainPanetargetDevice:update_arguments()

        helios_private.processArguments(mainPanetargetDevice, helios_private.driver.everyFrameArguments)
        helios_private.driver.processHighImportance(mainPanetargetDevice)

        if helios_private.state.tickCount >= helios_private.exportLowTickInterval then
            helios_private.processArguments(mainPanetargetDevice, helios_private.driver.arguments)
            helios_private.driver.processLowImportance(mainPanetargetDevice)
            helios_private.state.tickCount = 0
        end
    end
end

-- ========================= MODULE COMPATIBILITY LAYER ==========================
-- These functions make this script compatible with Capt Zeen Helios modules.
-- Simply place the modules in the Scripts/Helios/Mods folder and make sure they
-- referenced in the table helios_module_names near the top of this script.

-- when a module is running, this will be global scope Helios_Udp
local helios_modules_udp = {
}

-- when a module is running, this will be global scope Helios_Util
local helios_modules_util = {
}

-- creates a wrapper around a Helios Module to make it act as a Helios Driver
function helios_impl.createModuleDriver(selfName, moduleName)
    local driver = helios_private.createDriver()
    driver.moduleName = moduleName

    function driver.init()
        -- prepare environment
        Helios_Udp = helios_modules_udp;
        Helios_Util = helios_modules_util;
    end

    function driver.unload()
        Helios_Udp = nil
        Helios_Util = nil
        _G[moduleName] = nil -- luacheck: no global
    end

    -- execute module
    local modulePath = string.format("%sScripts\\Helios\\Mods\\%s.lua", lfs.writedir(), moduleName)
    local success, result = pcall(dofile, modulePath)
    if success then
        result = _G[moduleName] -- luacheck: no global
    end

    -- check result for nil, since driver may not have returned anything
    if success and result == nil then
        success = false
        result = string.format("module %s did not create module object %s; incompatible with this export script",
            modulePath, moduleName
        )
    end

    -- sanity check, make sure module is for correct selfName
    if success then
        local names = helios.splitString(result.Name, ";")
        local supported = false
        for _, name in pairs(names) do
            if name == selfName then
                supported = true
            end
        end
        if not supported then
            success = false
            result = string.format("module %s does not support '%s', only %s",
                moduleName,
                selfName,
                table.concat(names, ", ")
            )
        end
    end

    if not success then
        log.write('HELIOS EXPORT', log.DEBUG, string.format("could not create module driver '%s' for '%s'", moduleName, selfName))
        log.write('HELIOS EXPORT', log.DEBUG, result)
        return nil
    end

    -- hook it up
    driver.selfName = selfName
    driver.everyFrameArguments = result.HighImportanceArguments
    driver.arguments = result.LowImportanceArguments
    driver.processHighImportance = result.HighImportance
    driver.processLowImportance = result.LowImportance
    driver.processInput = result.ProcessInput
    if result.FlamingCliffsAircraft then
        -- override all export processing, even if no hook provided
        if result.ProcessExports ~= nil then
            driver.processExports = result.ProcessExports
        else
            function driver.processExports()
                -- do nothing
            end
        end
    end
    return driver
end

helios_modules_udp.Send = helios.send -- same signature
helios_modules_udp.Flush = helios_private.flush -- same signature
helios_modules_udp.ResetChangeValues = helios_private.resetCachedValues -- same signature

function helios_modules_util.Split(text, pattern)
    local ret = {}
    local findpattern = "(.-)"..pattern
    local last = 1
    local startpos, endpos, str = text:find(findpattern, 1)

    while startpos do
       if startpos ~= 1 or str ~= "" then table.insert(ret, str) end
       last = endpos + 1
       startpos, endpos, str = text:find(findpattern, last)
    end

    if last <= #text then
       str = text:sub(last)
       table.insert(ret, str)
    end

    return ret
end

function helios_modules_util.Degrees(radians)
    if radians == nil then
        return 0.0
    end
	return radians * 57.2957795
end

function helios_modules_util.Convert_Lamp(valor_lamp)
	return (valor_lamp  > 0.1) and 1 or 0
end

function helios_modules_util.Convert_SW (valor)
	return math.abs(valor-1)+1
end

function helios_modules_util.ValueConvert(actual_value, input, output)
	local range=1
	local slope = {}

	for a=1,#output-1 do -- calculating the table of slopes
		slope[a]= (input[a+1]-input[a]) / (output[a+1]-output[a])
	end

	for a=1,#output-1 do
		if actual_value >= output[a] and actual_value <= output[a+1] then
			range = a
			break
		end     -- check the range of the value
	end

	local final_value = ( slope[range] * (actual_value-output[range]) ) + input[range]
	return final_value
end

helios_modules_util.GetListIndicator = helios.parseIndication -- same signature

-- ========================= CONNECTION TO DCS ===================================
-- these are the functions we actually export, and third party scripts may retain
local arg1 = ...
if arg1 == "nohooks" then
    -- running under loader, don't place any hooks
    return helios_impl
end
log.write("HELIOS.EXPORT", log.INFO, "Helios registering DCS Lua callbacks")

-- save and chain any previous exports
helios_private.previousHooks = {}
helios_private.previousHooks.LuaExportStart = LuaExportStart
helios_private.previousHooks.LuaExportStop = LuaExportStop
helios_private.previousHooks.LuaExportActivityNextEvent = LuaExportActivityNextEvent
helios_private.previousHooks.LuaExportBeforeNextFrame = LuaExportBeforeNextFrame
helios_private.previousHooks.LuaExportAfterNextFrame = LuaExportAfterNextFrame

-- utility to chain one DCS hook without arguments
function helios_private.chainHook(functionName)
    _G[functionName] = function() -- luacheck: no global
        -- try execute Helios version of hook
        local success, result = pcall(helios_impl[functionName])
        if not success then
            log.write("HELIOS.EXPORT", log.ERROR, string.format("error return from Helios implementation of '%s'", functionName))
            if type(result) == "string" then
                log.write("HELIOS.EXPORT", log.ERROR, result)
            end
        end
        -- chain to next if it isn't our safety stub left over from reload
        local nextHandler = helios_private.previousHooks[functionName]
        if nextHandler ~= nil then
            nextHandler()
        end
    end
end

-- hook all the basic functions without arguments
helios_private.chainHook("LuaExportStart")
helios_private.chainHook("LuaExportStop")
helios_private.chainHook("LuaExportAfterNextFrame")
helios_private.chainHook("LuaExportBeforeNextFrame")

-- specialized chain for next event hook
function LuaExportActivityNextEvent(timeNow)
    local timeNext = timeNow;

    -- try execute Helios version of hook
    local success, result = pcall(helios_impl.LuaExportActivityNextEvent, timeNow)
    if success then
        timeNext = result
    else
        log.write("HELIOS.EXPORT", log.ERROR, string.format("error return from Helios implementation of 'LuaExportActivityNextEvent'"))
        if type(result) == "string" then
            log.write("HELIOS.EXPORT", log.ERROR, result)
        end
    end

    -- chain to next and keep closest event time that requires wake up
    -- chain only if it isn't our safety stub left over from reload
    local nextHandler = helios_private.previousHooks.LuaExportActivityNextEvent
    if nextHandler ~= nil then
        local timeOther = nextHandler(timeNow)
        if timeOther < timeNext then
            timeNext = timeOther
        end
    end
    return timeNext
end

-- when this script is being tested, these functions are accessible to our tester
-- they are also used to transfer to a new version of this script on hot reload
return helios_impl
