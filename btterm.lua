local toolName = "TNS|BT AT terminal|TNE"

-- AT terminal for a Bluetooth serial module. Set the radio baud to whatever
-- the module currently uses, talk to it, change it, then follow it to the new
-- rate.
--
-- Port: EdgeTX gives Lua whichever port is set to LUA in
-- SYS > HARDWARE > Serial ports, so this works on AUX1, AUX2 or the USB VCP
-- and on any radio. Set exactly one AUX port to LUA: with two, the baud is applied
-- to the first and the data goes out of the last.
--
-- DX-BT24 / BT24-S / BT27 command set is from the vendor UART application
-- guide: commands need CR+LF, AT+BAUD<n> uses its own numbering and a reset
-- is required before a new baud takes effect.

-- screen metrics, so the tool fits colour and black and white radios alike
-- Row pitch has to clear the font AND the highlight box the radio draws for
-- INVERS, which is the font height plus four. The small font differs per
-- screen class, so pick a pitch that fits the worst case of each.
local BIG = LCD_H >= 100
local LH
if not BIG then
    LH = 8                              -- 4x6 font on black and white radios
elseif LCD_W >= 800 then
    LH = 26                             -- large font set
elseif LCD_W <= 320 and LCD_H <= 240 then
    LH = 18                             -- small font set
else
    LH = 21                             -- standard font set
end
local LOGN = BIG and 4 or 2             -- log lines kept on screen
local VISIBLE = math.floor((LCD_H - (LOGN + 1) * LH - 6) / LH)
if VISIBLE < 3 then VISIBLE = 3 end

local CRLF = string.char(13, 10)

local BAUDS = { 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400 }

-- baud -> value of AT+BAUD<n>, per module family
-- 8 is past the documented range, kept because some modules accept it
local DX_CODE   = { [2400]=1, [4800]=2, [9600]=3, [19200]=4, [38400]=5, [57600]=6, [115200]=7, [230400]=8 }
local HM10_CODE = { [9600]=0, [19200]=1, [38400]=2, [57600]=3, [115200]=4, [230400]=5 }
local HC06_CODE = { [9600]=4, [19200]=5, [38400]=6, [57600]=7, [115200]=8, [230400]=9 }

local DIALECTS = { "DX-BT24", "HM-10", "HC-05", "HC-06" }

local baudIndex = 3          -- radio side; 9600 is the DX-BT24 default
local targetIndex = 7        -- rate we want the module to switch to (115200)
local dialect = 1
local sel = 1
local log = {}
local rxPart = ""
local hint = "set one AUX port to LUA"
local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_ "
local PRESETS = {
    "HelloRadioV12", "V12-BT", "TX16S-BT", "Radiomaster",
    "TELEM", "GHOST", "CRSF", "ELRS", "BT24", "FPV",
}
local presetIdx = 1
local nameStr = PRESETS[1]
local cursor = 1
local editing = false
local scanIdx = 0
local scanTime = 0
local sawReply = false

local ERRORS = {
    ["101"] = "param length",
    ["102"] = "param format",
    ["103"] = "bad param data",
    ["104"] = "command not supported",
}

local function addLog(line)
    log[#log + 1] = line
    local code = string.match(line, "ERROR=(%d+)")
    if code and ERRORS[code] then
        log[#log + 1] = "  = " .. ERRORS[code]
    end
    while #log > LOGN do table.remove(log, 1) end
end

local function baud() return BAUDS[baudIndex] end
local function target() return BAUDS[targetIndex] end

local function needsCrLf()
    return dialect == 1 or dialect == 3      -- DX-BT24 and HC-05
end

local function send(cmd)
    if not serialWrite then
        addLog("no serial port in LUA mode")
        return
    end
    if needsCrLf() then
        serialWrite(cmd .. CRLF)
    else
        serialWrite(cmd)
    end
    addLog("> " .. cmd)
end

-- Each family words its queries differently; HC-06 has almost none.
local QUERIES = {
    { version = "AT+VERSION",  name = "AT+NAME",  addr = "AT+LADDR", baud = "AT+BAUD"  },
    { version = "AT+VERSION",  name = "AT+NAME?", addr = "AT+ADDR?", baud = "AT+BAUD?" },
    { version = "AT+VERSION?", name = "AT+NAME?", addr = "AT+ADDR?", baud = "AT+UART?" },
    { version = "AT+VERSION" },
}

local function queryCmd(kind)
    return QUERIES[dialect][kind]
end

local function query(kind)
    local cmd = queryCmd(kind)
    if cmd then
        send(cmd)
    else
        addLog("not on " .. DIALECTS[dialect])
    end
end

local function baudCode()
    local b = target()
    if dialect == 1 then return DX_CODE[b]
    elseif dialect == 2 then return HM10_CODE[b]
    elseif dialect == 4 then return HC06_CODE[b]
    end
    return nil
end

local function setBaud()
    local b, code = target(), baudCode()
    if dialect == 3 then
        send("AT+UART=" .. b .. ",0,0")
    elseif code then
        if dialect == 1 and b > 115200 then
            addLog("above documented max")
        end
        send("AT+BAUD" .. code)
    else
        addLog(b .. " not supported")
        return
    end
    hint = "now RESET, then set radio baud"
end

local function scanStep()
    if scanIdx == 0 then return end
    if sawReply then
        hint = "module answers at " .. baud()
        scanIdx = 0
        return
    end
    if getTime() - scanTime < 40 then return end
    if scanIdx > #BAUDS then
        hint = "no answer at any baud"
        scanIdx = 0
        return
    end
    baudIndex = scanIdx
    rxPart = ""                              -- drop framing noise from the last rate
    if setSerialBaudrate then setSerialBaudrate(baud()) end
    hint = "trying " .. baud() .. " ..."
    sawReply = false
    if needsCrLf() then serialWrite("AT" .. CRLF) else serialWrite("AT") end
    scanTime = getTime()
    scanIdx = scanIdx + 1
end

local function bumpChar(d)
    local c = string.sub(nameStr, cursor, cursor)
    local i = string.find(CHARS, c, 1, true) or 1
    i = i + d
    if i < 1 then i = #CHARS end
    if i > #CHARS then i = 1 end
    nameStr = string.sub(nameStr, 1, cursor - 1) ..
              string.sub(CHARS, i, i) ..
              string.sub(nameStr, cursor + 1)
end

local function trimmed()
    local t = nameStr
    while #t > 0 and string.sub(t, -1) == " " do t = string.sub(t, 1, #t - 1) end
    return t
end

local function nameShown()
    if not editing then return nameStr end
    return string.sub(nameStr, 1, cursor - 1) .. "[" ..
           string.sub(nameStr, cursor, cursor) .. "]" ..
           string.sub(nameStr, cursor + 1)
end

local items = {
    {
        l = function() return "< Radio now  " .. baud() .. " >" end,
        a = function()
            baudIndex = baudIndex % #BAUDS + 1
            if setSerialBaudrate then setSerialBaudrate(baud()) end
            hint = "radio now at " .. baud()
        end
    },
    {
        l = function() return "< Module  " .. DIALECTS[dialect] .. " >" end,
        a = function() dialect = dialect % #DIALECTS + 1 end
    },
    {
        l = function() return "< New baud   " .. target() .. " >" end,
        a = function() targetIndex = targetIndex % #BAUDS + 1 end
    },
    { l = function() return "Test link    AT" end,       a = function() send("AT") end },
    {
        l = function() return "Find module (baud scan)" end,
        a = function()
            log = {}
            rxPart = ""
            sawReply = false
            scanIdx = 1
            scanTime = 0
            hint = "scanning..."
        end
    },
    { l = function() return "Version    " .. (queryCmd("version") or "n/a") end,
      a = function() query("version") end },
    { l = function() return "Read name  AT+NAME" end,        a = function() query("NAME") end },
    { l = function() return "MAC addr   AT+LADDR" end,         a = function() query("LADDR") end },
    { l = function() return "Baud now   AT+BAUD" end,        a = function() query("BAUD") end },
        {
        l = function()
            if dialect == 3 then return "Set baud > " .. target() .. " AT+UART" end
            local c = baudCode()
            if c then return "Set baud > " .. target() .. " AT+BAUD" .. c end
            return "Set baud > " .. target() .. " n/a"
        end,
        a = setBaud
    },
    {
        l = function() return "Restart    AT+RESET" end,
        a = function()
            if dialect == 4 then addLog("HC-06 has no reset")
            else send("AT+RESET"); hint = "reset sent" end
        end
    },
    {
        l = function() return "AT when conn.  TRANSPORT0" end,
        a = function()
            if dialect == 1 then
                send("AT+TRANSPORT0")
                hint = "telemetry off until set back"
            else
                addLog("DX-BT24 only")
            end
        end
    },
    {
        l = function() return "Data mode      TRANSPORT1" end,
        a = function()
            if dialect == 1 then
                send("AT+TRANSPORT1")
                hint = "normal telemetry mode"
            else
                addLog("DX-BT24 only")
            end
        end
    },
    { l = function() return "Read mode  AT+TRANSPORT" end,
      a = function() if dialect == 1 then send("AT+TRANSPORT") else addLog("DX-BT24 only") end end },
    { l = function() return "Unpair     AT+DISC" end,
      a = function() if dialect == 1 then send("AT+DISC") else addLog("DX-BT24 only") end end },
    {
        l = function() return "< Preset  " .. PRESETS[presetIdx] .. " >" end,
        a = function()
            presetIdx = presetIdx % #PRESETS + 1
            nameStr = PRESETS[presetIdx]
            cursor = 1
            hint = "name loaded, use Send name"
        end
    },
    {
        l = function() return "Send name  AT+NAME" .. trimmed() end,
        a = function()
            if dialect == 3 then
                send("AT+NAME=" .. trimmed())
            else
                send("AT+NAME" .. trimmed())
            end
            hint = "reset to apply the name"
        end
    },
    {
        l = function() return "Edit name  " .. nameShown() end,
        a = function()
            editing = true
            cursor = 1
            hint = "+- char, ENT next, hold ENT=send"
        end
    },
    {
        l = function() return "Factory    AT+DEFAULT" end,
        a = function()
            if dialect == 1 then send("AT+DEFAULT") else addLog("not for this module") end
        end
    },
    { l = function() return "Clear log" end, a = function() log = {}; rxPart = "" end },
}

local function readSerial()
    if not serialRead then return end
    local d = serialRead()
    while d and #d > 0 do
        rxPart = rxPart .. d
        d = serialRead()
    end
    while true do
        local p = string.find(rxPart, "[\r\n]")
        if not p then break end
        local line = string.sub(rxPart, 1, p - 1)
        rxPart = string.sub(rxPart, p + 1)
        if #line > 0 then
            addLog(line)
            -- only a real answer ends a scan, not our own status lines
            if string.find(line, "OK", 1, true) or string.find(line, "+", 1, true) then
                sawReply = true
            end
        end
    end
    if #rxPart > 26 then addLog(rxPart); rxPart = "" end
end

local function init()
    if setSerialBaudrate then setSerialBaudrate(baud()) end
end

local function run(event)
    if editing then
        if event == EVT_VIRTUAL_EXIT then
            editing = false
            hint = "name not sent"
        elseif event == EVT_VIRTUAL_NEXT then
            bumpChar(1)
        elseif event == EVT_VIRTUAL_PREV then
            bumpChar(-1)
        elseif event == EVT_VIRTUAL_ENTER_LONG then
            -- otherwise the release is delivered as a plain ENTER and reopens this
            if killEvents then killEvents(EVT_VIRTUAL_ENTER) end
            editing = false
            if dialect == 3 then
                send("AT+NAME=" .. trimmed())
            else
                send("AT+NAME" .. trimmed())
            end
            hint = "reset to apply the name"
        elseif event == EVT_VIRTUAL_ENTER then
            if cursor < #nameStr then
                cursor = cursor + 1
            elseif #nameStr < 20 then
                nameStr = nameStr .. " "
                cursor = #nameStr
            else
                cursor = 1
            end
        end
    elseif event == EVT_VIRTUAL_EXIT then
        return 1
    elseif event == EVT_VIRTUAL_NEXT then
        sel = sel % #items + 1
    elseif event == EVT_VIRTUAL_PREV then
        sel = (sel - 2) % #items + 1
    elseif event == EVT_VIRTUAL_ENTER then
        items[sel].a()
    end

    readSerial()
    scanStep()

    lcd.clear()

    local top = sel - math.floor(VISIBLE / 2)
    if top > #items - VISIBLE + 1 then top = #items - VISIBLE + 1 end
    if top < 1 then top = 1 end

    local y = 1
    for i = top, math.min(top + VISIBLE - 1, #items) do
        lcd.drawText(2, y, items[i].l(), SMLSIZE + (i == sel and INVERS or 0))
        y = y + LH
    end
    lcd.drawText(LCD_W - (BIG and 46 or 26), 1, sel .. "/" .. #items, SMLSIZE)

    lcd.drawLine(0, y + 1, LCD_W - 1, y + 1, SOLID, 0)

    y = y + 3
    for i = 1, #log do
        lcd.drawText(2, y, log[i], SMLSIZE)
        y = y + LH
    end

    -- help line, indented and bracketed so it does not read as a menu row
    lcd.drawText(6, LCD_H - LH, "(" .. hint .. ")", SMLSIZE)

    return 0
end

return { init = init, run = run }
