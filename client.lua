-- Az-Insurance / client.lua

local RESOURCE_NAME = GetCurrentResourceName()

Config = Config or {}
if Config.Debug == nil then Config.Debug = true end
Config.OpenCommand = Config.OpenCommand or "insurance"

local uiOpen = false

local function cprint(...)
  if not Config.Debug then return end
  local args = { ... }
  for i = 1, #args do args[i] = tostring(args[i]) end
  print(("^2[%s]^7 %s"):format(RESOURCE_NAME, table.concat(args, " ")))
end

-- minimal fallback snapshot so UI can open even if server fails
local lastSnapshot = {
  vehicles               = {},
  claims                 = {},
  premiumIntervalMinutes = 10,
  serverTime             = 0,
  policyTypes            = {},
  claimCooldownMinutes   = 30,
}

local function openInsurance()
  if uiOpen then return end
  uiOpen = true
  SetNuiFocus(true, true)

  SendNUIMessage({
    action   = "openInsurance",
    snapshot = lastSnapshot
  })

  TriggerServerEvent("az_insurance:requestOpen")
  cprint("Requested insurance UI open")
end

local function closeInsurance()
  if not uiOpen then return end
  uiOpen = false
  SetNuiFocus(false, false)
  SendNUIMessage({ action = "closeInsurance" })
  cprint("Closed insurance UI")
end

-- Turn a model into:
--  spawnKey: lower-case "blista" (used for docs URL attempts)
--  pretty:   human label for UI
local function resolveModelInfo(model)
  if not model then return nil, nil end

  -- if model is already a string spawn name (or display-ish)
  if type(model) == "string" then
    local raw = model:gsub("`", "")
    local cleaned = raw:lower():gsub("[^%w_]", "")

    -- ignore numeric strings/hashes
    if cleaned ~= "" and not cleaned:match("^%-?%d+$") then
      -- try to get a prettier label if possible (hash -> display -> label)
      local hash = GetHashKey(raw)
      if hash and type(hash) == "number" and IsModelInCdimage(hash) then
        local disp = GetDisplayNameFromVehicleModel(hash) -- e.g. "BLISTA"
        if disp and disp ~= "" and disp ~= "CARNOTFOUND" then
          local pretty = GetLabelText(disp)
          if not pretty or pretty == "" or pretty == "NULL" then pretty = disp end
          return disp:lower():gsub("[^%w_]", ""), pretty
        end
      end

      -- fallback: treat cleaned as spawnKey and also as pretty-ish
      return cleaned, raw
    end

    -- try numeric hash string
    local maybe = tonumber(raw)
    if maybe then model = maybe else return nil, nil end
  end

  if type(model) ~= "number" then return nil, nil end

  if not IsModelInCdimage(model) then
    return nil, nil
  end

  local disp = GetDisplayNameFromVehicleModel(model) -- e.g. "ASBO"
  if not disp or disp == "" or disp == "CARNOTFOUND" then
    return nil, nil
  end

  local spawnKey = tostring(disp):lower():gsub("[^%w_]", "")
  local pretty = GetLabelText(disp)
  if not pretty or pretty == "" or pretty == "NULL" then
    pretty = disp
  end

  return (spawnKey ~= "" and spawnKey or nil), pretty
end

local function enhanceVehicleEntry(v)
  if type(v) ~= "table" then return end
  local props = v.props or {}

  -- Prefer DB/model fields first; your table uses `model` as a string.
  local rawModel =
      v.model or
      v.spawnName or v.spawn or v.modelName or v.modelHash or
      props.modelName or props.model or props.modelHash or props.hash or
      (v.rawParking and v.rawParking.model) or
      nil

  local spawnKey, pretty = resolveModelInfo(rawModel)

  -- This is what the UI uses to attempt docs.fivem previews
  if spawnKey and spawnKey ~= "" then
    v.spawnName = spawnKey
  end

  -- UI name
  if pretty and pretty ~= "" then
    v.displayName = pretty
  elseif v.displayName and tostring(v.displayName) ~= "" then
    -- keep
  else
    v.displayName = "Vehicle"
  end

  -- Debug
  if Config.Debug then
    cprint(("veh plate=%s raw=%s -> spawn=%s pretty=%s"):format(
      tostring(v.plate),
      tostring(rawModel),
      tostring(v.spawnName),
      tostring(v.displayName)
    ))
  end
end

RegisterCommand(Config.OpenCommand, function()
  openInsurance()
end, false)

-- Server -> Client: open UI
RegisterNetEvent("az_insurance:openUI", function(data)
  lastSnapshot = data or lastSnapshot

  if lastSnapshot and type(lastSnapshot.vehicles) == "table" then
    for i = 1, #lastSnapshot.vehicles do
      enhanceVehicleEntry(lastSnapshot.vehicles[i])
    end
  end

  uiOpen = true
  SetNuiFocus(true, true)
  SendNUIMessage({ action = "openInsurance", snapshot = lastSnapshot })
end)

-- Apply properties safely (ox_lib preferred)
local function applyVehicleProps(veh, props)
  if not veh or veh == 0 or type(props) ~= "table" then return end

  -- ox_lib
  if lib and type(lib.setVehicleProperties) == "function" then
    local ok, err = pcall(function()
      lib.setVehicleProperties(veh, props)
    end)
    if not ok then
      cprint("lib.setVehicleProperties failed:", err)
    end
    return
  end

  -- Minimal fallback (basic only)
  if props.plate then
    SetVehicleNumberPlateText(veh, tostring(props.plate))
  end

  if props.windowTint then
    SetVehicleWindowTint(veh, props.windowTint)
  end

  if props.color1 and props.color2 then
    if type(props.color1) == "table" then
      SetVehicleCustomPrimaryColour(veh, props.color1[1] or 0, props.color1[2] or 0, props.color1[3] or 0)
    else
      SetVehicleColours(veh, props.color1, props.color2 or 0)
    end
  end

  if props.pearlescentColor or props.wheelColor then
    SetVehicleExtraColours(veh, props.pearlescentColor or 0, props.wheelColor or 0)
  end

  if props.extras and type(props.extras) == "table" then
    for extraId, enabled in pairs(props.extras) do
      SetVehicleExtra(veh, tonumber(extraId), enabled == 0 and 1 or 0)
    end
  end
end

-- Server -> Client: spawn replacement vehicle for claim
RegisterNetEvent("az_insurance:spawnInsuredVehicle", function(data)
  if type(data) ~= "table" then return end

  local props = data.props or {}
  local plate = data.plate or "INSURED"
  local spawn = data.spawn or {}

  local x = spawn.x or 0.0
  local y = spawn.y or 0.0
  local z = spawn.z or 72.0
  local h = spawn.h or 0.0

  -- model from props first, then fallback
  local model = props.model or props.modelHash or props.hash or `adder`
  if type(model) == "string" then
    model = GetHashKey(model)
  end

  if type(model) ~= "number" or not IsModelInCdimage(model) then
    cprint("spawnInsuredVehicle: invalid model, defaulting to adder")
    model = `adder`
  end

  RequestModel(model)
  while not HasModelLoaded(model) do
    Wait(0)
  end

  local veh = CreateVehicle(model, x, y, z, h, true, false)
  if not veh or veh == 0 then
    cprint("CreateVehicle failed")
    SetModelAsNoLongerNeeded(model)
    return
  end

  SetEntityAsMissionEntity(veh, true, true)
  NetworkRegisterEntityAsNetworked(veh)
  SetVehicleOnGroundProperly(veh)
  SetVehicleNumberPlateText(veh, tostring(plate))

  -- ✅ FIX/CLEAN so it’s drivable and not “broken”
  SetVehicleFixed(veh)
  SetVehicleDeformationFixed(veh)
  SetVehicleDirtLevel(veh, 0.0)
  SetVehicleEngineHealth(veh, 1000.0)
  SetVehicleBodyHealth(veh, 1000.0)
  SetVehiclePetrolTankHealth(veh, 1000.0)

  -- apply saved props after fixing
  applyVehicleProps(veh, props)

  -- warp player in
  local ped = PlayerPedId()
  SetPedIntoVehicle(ped, veh, -1)

  SetModelAsNoLongerNeeded(model)

  cprint(("Spawned insured vehicle %s at %.2f %.2f %.2f"):format(tostring(plate), x, y, z))
end)

-- NUI callbacks
RegisterNUICallback("insurance_close", function(_, cb)
  closeInsurance()
  if cb then cb({}) end
end)

RegisterNUICallback("insurance_start", function(data, cb)
  if data and data.plate then
    TriggerServerEvent("az_insurance:startPolicy", data.plate, data.policyType or "standard")
  end
  if cb then cb({}) end
end)

RegisterNUICallback("insurance_cancel", function(data, cb)
  if data and data.plate then
    TriggerServerEvent("az_insurance:cancelPolicy", data.plate)
  end
  if cb then cb({}) end
end)

RegisterNUICallback("insurance_claim", function(data, cb)
  if data and data.plate then
    TriggerServerEvent("az_insurance:fileClaim", data.plate)
  end
  if cb then cb({}) end
end)
