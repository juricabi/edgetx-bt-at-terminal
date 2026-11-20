-- BT24 baud detector: cycles through baud rates sending a marker string.
-- The PC (connected via BLE) sees which marker arrives intact ->
-- that is the module's actual UART baud.
-- Copy to /SCRIPTS/TOOLS/bt24test.lua, port mode = LUA.
-- POWER-CYCLE the radio before running (restores transparent mode),
-- then run this and leave it running while the PC captures. EXIT quits.

local BAUDS = { 9600, 19200, 38400, 57600, 115200 }
local idx = 1
local nextAt = 0
local sendCount = 0
local status = ""

local function setBaud(b)
  local f = serialSetBaudrate or setSerialBaudrate
  if f ~= nil then f(b) end
end

local function init()
  nextAt = getTime()
end

local function run(event)
  if event == EVT_VIRTUAL_EXIT then return 1 end

  if getTime() >= nextAt then
    local b = BAUDS[idx]
    if sendCount == 0 then setBaud(b) end
    serialWrite("MARKER" .. b .. " ABCDEF 0123456789\r\n")
    sendCount = sendCount + 1
    status = "baud " .. b .. " msg " .. sendCount
    nextAt = getTime() + 60          -- 0.6s between sends
    if sendCount >= 5 then           -- 5 markers per baud (~3s), then next
      sendCount = 0
      idx = idx + 1
      if idx > #BAUDS then idx = 1 end
    end
  end

  lcd.clear()
  lcd.drawText(2, 0, "BT24 baud detector", INVERS)
  lcd.drawText(2, 12, status, 0)
  lcd.drawText(2, 24, "leave running, EXIT quits", SMLSIZE)
  return 0
end

return { init = init, run = run }
