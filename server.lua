-- Az-Insurance / server.lua

local RESOURCE_NAME = GetCurrentResourceName()
Config = Config or {}
if Config.Debug == nil then Config.Debug = true end

---------------------------------------------------------------------
-- 🔧 Debug helper
---------------------------------------------------------------------
local function dprint(...)
    if not Config.Debug then return end
    local args = { ... }
    for i = 1, #args do
        args[i] = tostring(args[i])
    end
    print(("^3[%s]^7 %s"):format(RESOURCE_NAME, table.concat(args, " ")))
end

---------------------------------------------------------------------
-- 🔗 Framework + Parking detection
---------------------------------------------------------------------
local fw

do
    local state = GetResourceState("Az-Framework")
    if state == "started" or state == "starting" then
        fw = exports["Az-Framework"]
        dprint("Az-Framework detected – money helpers enabled.")
    else
        dprint("Az-Framework NOT running (" .. state .. ") – money helpers disabled.")
    end
end

-- Az-Parking exports live on Az-Framework in your setup
local PARKING_RESOURCE = Config.ParkingResource or "Az-Framework"

local function getParkingExports()
    local state = GetResourceState(PARKING_RESOURCE)
    if state ~= "started" and state ~= "starting" then
        dprint(("Parking resource %s not running (%s)"):format(PARKING_RESOURCE, state))
        return nil
    end

    local parkingExports = exports[PARKING_RESOURCE]
    if not parkingExports then
        dprint(("Parking exports not found on %s"):format(PARKING_RESOURCE))
        return nil
    end

    return parkingExports
end

---------------------------------------------------------------------
-- 💰 Money helpers (Az-Framework)
---------------------------------------------------------------------
local function chargePlayer(src, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end
    if not fw then
        dprint("chargePlayer: fw is nil – skipping charge (" .. amount .. ")")
        return true
    end

    local ok, err = pcall(function()
        fw:deductMoney(src, amount, reason or "Insurance premium")
    end)

    if not ok then
        dprint(("chargePlayer failed for %s: %s"):format(src, tostring(err)))
        return false
    end

    return true
end

local function payPlayer(src, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return end
    if not fw then
        dprint("payPlayer: fw is nil – skipping payout (" .. amount .. ")")
        return
    end

    local ok, err = pcall(function()
        fw:addMoney(src, amount, reason or "Insurance payout")
    end)

    if not ok then
        dprint(("payPlayer failed for %s: %s"):format(src, tostring(err)))
    end
end

---------------------------------------------------------------------
-- 📛 Identifier helpers
---------------------------------------------------------------------
local function getLicenseIdentifier(src)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == "license:" then
            return id
        end
    end
    return "src:" .. tostring(src)
end

local function getDiscordID(src)
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, 8) == "discord:" then
            return id:sub(9)
        end
    end
    return nil
end

---------------------------------------------------------------------
-- 🗄️ DB helpers – user_vehicle_insurance / user_vehicle_claims
---------------------------------------------------------------------

-- Active policies for a Discord ID
local function fetchActivePolicies(discordId, cb)
    if not discordId or discordId == "" then
        if cb then cb({}) end
        return
    end

    MySQL.Async.fetchAll([[
        SELECT id, discordid, plate, policy_type, premium, deductible,
               vehicle_props, next_payment_at, active
        FROM user_vehicle_insurance
        WHERE discordid = @discordid AND active = 1
    ]], {
        ['@discordid'] = discordId
    }, function(rows)
        rows = rows or {}
        for _, row in ipairs(rows) do
            if row.vehicle_props and row.vehicle_props ~= "" then
                local ok, decoded = pcall(json.decode, row.vehicle_props)
                row.props = ok and decoded or {}
            else
                row.props = {}
            end
        end
        if cb then cb(rows) end
    end)
end

-- Last N claims for a Discord ID
local function fetchClaims(discordId, cb)
    if not discordId or discordId == "" then
        if cb then cb({}) end
        return
    end

    MySQL.Async.fetchAll([[
        SELECT id, discordid, plate, policy_type,
               deductible_charged, payout_value, filed_at, status
        FROM user_vehicle_claims
        WHERE discordid = @discordid
        ORDER BY filed_at DESC
        LIMIT 20
    ]], {
        ['@discordid'] = discordId
    }, function(rows)
        if cb then cb(rows or {}) end
    end)
end

-- Last claim timestamp for cooldown checks
local function fetchLastClaimTime(discordId, plate, cb)
    if not discordId or not plate or plate == "" then
        if cb then cb(nil) end
        return
    end

    MySQL.Async.fetchScalar([[
        SELECT filed_at
        FROM user_vehicle_claims
        WHERE discordid = @discordid AND plate = @plate
        ORDER BY filed_at DESC
        LIMIT 1
    ]], {
        ['@discordid'] = discordId,
        ['@plate']     = plate
    }, function(ts)
        if cb then cb(tonumber(ts)) end
    end)
end

-- Insert/Update policy row
local function upsertPolicy(discordId, plate, policyType, premium, deductible, props, cb)
    local propsJson     = json.encode(props or {})
    local nextPaymentAt = os.time() + (Config.PremiumIntervalMinutes or 10) * 60

    MySQL.Async.execute([[
        INSERT INTO user_vehicle_insurance
            (discordid, plate, policy_type, premium, deductible, vehicle_props, next_payment_at, active)
        VALUES
            (@discordid, @plate, @policy_type, @premium, @deductible, @vehicle_props, @next_payment_at, 1)
        ON DUPLICATE KEY UPDATE
            policy_type     = VALUES(policy_type),
            premium         = VALUES(premium),
            deductible      = VALUES(deductible),
            vehicle_props   = VALUES(vehicle_props),
            next_payment_at = VALUES(next_payment_at),
            active          = 1
    ]], {
        ['@discordid']       = discordId,
        ['@plate']           = plate,
        ['@policy_type']     = policyType,
        ['@premium']         = premium,
        ['@deductible']      = deductible,
        ['@vehicle_props']   = propsJson,
        ['@next_payment_at'] = nextPaymentAt
    }, function(_)
        if cb then cb() end
    end)
end

-- Deactivate policy
local function deactivatePolicy(discordId, plate, cb)
    MySQL.Async.execute([[
        UPDATE user_vehicle_insurance
        SET active = 0
        WHERE discordid = @discordid AND plate = @plate
    ]], {
        ['@discordid'] = discordId,
        ['@plate']     = plate
    }, function(_)
        if cb then cb() end
    end)
end

-- Fetch single active policy
local function fetchPolicy(discordId, plate, cb)
    if not discordId or not plate or plate == "" then
        if cb then cb(nil) end
        return
    end

    MySQL.Async.fetchAll([[
        SELECT id, discordid, plate, policy_type, premium, deductible,
               vehicle_props, next_payment_at, active
        FROM user_vehicle_insurance
        WHERE discordid = @discordid AND plate = @plate AND active = 1
        LIMIT 1
    ]], {
        ['@discordid'] = discordId,
        ['@plate']     = plate
    }, function(rows)
        local row = rows and rows[1] or nil
        if row and row.vehicle_props and row.vehicle_props ~= "" then
            local ok, decoded = pcall(json.decode, row.vehicle_props)
            row.props = ok and decoded or {}
        elseif row then
            row.props = {}
        end
        if cb then cb(row) end
    end)
end

-- Insert a claim row
local function insertClaim(discordId, plate, policyType, deductibleCharged, payoutValue, status, cb)
    MySQL.Async.execute([[
        INSERT INTO user_vehicle_claims
            (discordid, plate, policy_type, deductible_charged, payout_value, filed_at, status)
        VALUES
            (@discordid, @plate, @policy_type, @deductible_charged, @payout_value, @filed_at, @status)
    ]], {
        ['@discordid']          = discordId,
        ['@plate']              = plate,
        ['@policy_type']        = policyType,
        ['@deductible_charged'] = deductibleCharged or 0,
        ['@payout_value']       = payoutValue or 0,
        ['@filed_at']           = os.time(),
        ['@status']             = status or "approved"
    }, function(_)
        if cb then cb() end
    end)
end

---------------------------------------------------------------------
-- 🚗 Parking helpers (Az-Parking exports)
---------------------------------------------------------------------

-- All parked vehicles for a Discord ID
local function fetchParkedVehiclesForDiscord(discordId, cb)
    local parkingExports = getParkingExports()
    if not parkingExports or type(parkingExports.GetPlayerParkedVehicles) ~= "function" then
        dprint(("fetchParkedVehiclesForDiscord: missing GetPlayerParkedVehicles on %s"):format(PARKING_RESOURCE))
        if cb then cb({}) end
        return
    end

    parkingExports:GetPlayerParkedVehicles(discordId, function(results)
        if cb then cb(results or {}) end
    end)
end

-- Props for a single PARKED vehicle (used when starting policy)
local function fetchPropsForPlate(discordId, plate, cb)
    local parkingExports = getParkingExports()
    if not parkingExports or type(parkingExports.GetParkedVehicleByPlate) ~= "function" then
        dprint(("fetchPropsForPlate: missing GetParkedVehicleByPlate on %s"):format(PARKING_RESOURCE))
        if cb then cb(nil) end
        return
    end

    parkingExports:GetParkedVehicleByPlate(discordId, plate, function(row)
        local props = row and (row.props or {}) or nil
        if cb then cb(props) end
    end)
end

-- Check if a plate is currently parked (used only when FILE THEFT CLAIM is pressed)
local function isPlateParked(discordId, plate, cb)
    local parkingExports = getParkingExports()
    if not parkingExports or type(parkingExports.IsVehicleParked) ~= "function" then
        dprint(("isPlateParked: missing IsVehicleParked on %s – assuming NOT parked"):format(PARKING_RESOURCE))
        if cb then cb(false) end
        return
    end

    parkingExports:IsVehicleParked(discordId, plate, function(parked)
        cb(not not parked)
    end)
end

---------------------------------------------------------------------
-- 📊 Snapshot builder – based on DB + parked list
---------------------------------------------------------------------

local function buildSnapshot(src, cb)
    local discordId = getDiscordID(src)
    if not discordId then
        dprint(("buildSnapshot: no discord ID for %s"):format(src))
        if cb then cb({
            vehicles               = {},
            claims                 = {},
            premiumIntervalMinutes = Config.PremiumIntervalMinutes or 10,
            serverTime             = os.time(),
            policyTypes            = Config.PolicyTypes or {},
            claimCooldownMinutes   = Config.ClaimCooldownMinutes or 30,
            insuredCount           = 0,
            parkedCount            = 0,
        }) end
        return
    end

    fetchActivePolicies(discordId, function(policies)
        fetchParkedVehiclesForDiscord(discordId, function(parkedRows)
            fetchClaims(discordId, function(claimRows)
                policies   = policies   or {}
                parkedRows = parkedRows or {}
                claimRows  = claimRows  or {}

                local policiesByPlate = {}
                for _, p in ipairs(policies) do
                    policiesByPlate[p.plate] = p
                end

                local vehicles  = {}
                local seenPlate = {}

                -----------------------------------------------------------------
                -- 1) Parked vehicles (insured or not)
                -----------------------------------------------------------------
                for _, row in ipairs(parkedRows) do
                    local plate = row.plate or "UNKNOWN"
                    seenPlate[plate] = true

                    local policy  = policiesByPlate[plate]
                    local insured = policy ~= nil
                    local props   = (policy and policy.props) or row.props or {}

                    table.insert(vehicles, {
                        plate       = plate,
                        model       = row.model or (props and (props.model or props.modelHash)) or "Vehicle",
                        garage      = nil,               -- Az-Parking doesn't store by name yet
                        stored      = true,              -- ✅ Parked (DB says so)
                        parked      = true,              -- alias for UI
                        insured     = insured,
                        policyType  = policy and policy.policy_type or nil,
                        premium     = policy and policy.premium or 0,
                        deductible  = policy and policy.deductible or 0,
                        nextPaymentAt = policy and policy.next_payment_at or 0,

                        props       = props,
                        rawParking  = row,
                        rawPolicy   = policy,
                    })
                end

                -----------------------------------------------------------------
                -- 2) Insured but NOT parked (no parked row) → "Not parked / missing"
                -----------------------------------------------------------------
                for _, policy in ipairs(policies) do
                    if not seenPlate[policy.plate] then
                        local props = policy.props or {}

                        table.insert(vehicles, {
                            plate       = policy.plate,
                            model       = (props and (props.model or props.modelHash)) or "Vehicle",
                            garage      = nil,
                            stored      = false,          -- ❌ not parked
                            parked      = false,          -- alias
                            insured     = true,
                            policyType  = policy.policy_type,
                            premium     = policy.premium,
                            deductible  = policy.deductible,
                            nextPayment = policy.next_payment_at,
                            props       = props,
                            rawPolicy   = policy,
                        })
                    end
                end

                -----------------------------------------------------------------
                -- Counts
                -----------------------------------------------------------------
                local insuredCount = 0
                local parkedCount  = 0

                for _, v in ipairs(vehicles) do
                    if v.insured then
                        insuredCount = insuredCount + 1
                    end
                    if v.stored then
                        parkedCount = parkedCount + 1
                    end
                end

                -----------------------------------------------------------------
                -- Claims list for UI
                -----------------------------------------------------------------
                local claims = {}
                for _, c in ipairs(claimRows) do
table.insert(claims, {
    id         = c.id,
    plate      = c.plate,
    policyType = c.policy_type,
    filedAt    = c.filed_at,
    filed_at   = c.filed_at, -- ✅ compatibility for UI
    status     = c.status or "approved",
})

                end

                local snapshot = {
                    vehicles               = vehicles,
                    claims                 = claims,
                    premiumIntervalMinutes = Config.PremiumIntervalMinutes or 10,
                    serverTime             = os.time(),
                    policyTypes            = Config.PolicyTypes or {},
                    claimCooldownMinutes   = Config.ClaimCooldownMinutes or 30,
                    insuredCount           = insuredCount,
                    parkedCount            = parkedCount,
                }

                if cb then cb(snapshot) end
            end)
        end)
    end)
end

---------------------------------------------------------------------
-- 🚗 Spawn helper – spawn at player location
---------------------------------------------------------------------
local function getPlayerSpawnPoint(src)
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local coords  = GetEntityCoords(ped)
        local heading = GetEntityHeading(ped)
        return {
            x = coords.x or coords[1] or 0.0,
            y = coords.y or coords[2] or 0.0,
            z = coords.z or coords[3] or 72.0,
            h = heading or 0.0
        }
    end

    return { x = 0.0, y = 0.0, z = 72.0, h = 0.0 }
end

local function spawnClaimVehicle(src, plate, props)
    local spawn = getPlayerSpawnPoint(src)

    TriggerClientEvent("az_insurance:spawnInsuredVehicle", src, {
        plate = plate,
        props = props or {},
        spawn = spawn
    })

    buildSnapshot(src, function(snapshot)
        TriggerClientEvent("az_insurance:openUI", src, snapshot)
    end)
end

---------------------------------------------------------------------
-- 📥 /insurance → client fires az_insurance:requestOpen
---------------------------------------------------------------------
RegisterNetEvent("az_insurance:requestOpen", function()
    local src = source
    dprint(("requestOpen from %s"):format(src))

    buildSnapshot(src, function(snapshot)
        TriggerClientEvent("az_insurance:openUI", src, snapshot)
    end)
end)

---------------------------------------------------------------------
-- 🟢 Start policy
--  - Vehicle MUST be parked (we read props from Az-Parking)
--  - Policy saved into user_vehicle_insurance
---------------------------------------------------------------------
RegisterNetEvent("az_insurance:startPolicy", function(plate, policyType)
    local src = source
    plate = type(plate) == "string" and plate or nil
    if not plate or plate == "" then return end

    local discordId = getDiscordID(src)
    if not discordId then
        TriggerClientEvent("chat:addMessage", src, {
            args = { "^1Insurance", "Discord is required for insurance." }
        })
        return
    end

    policyType            = policyType or "standard"
    local licenseIdent    = getLicenseIdentifier(src)
    local policyCfg       = (Config.PolicyTypes or {})[policyType] or {}
    local premium         = policyCfg.premium    or (Config.BasePremium or 0)
    local deductible      = policyCfg.deductible or (Config.DefaultDeductible or 0)

    dprint(("startPolicy: src=%s lic=%s discord=%s plate=%s type=%s premium=%s deduct=%s"):
        format(src, licenseIdent, discordId, plate, policyType, premium, deductible))

    -- Require vehicle be PARKED so we can grab props
    fetchPropsForPlate(discordId, plate, function(props)
        if not props or next(props) == nil then
            TriggerClientEvent("chat:addMessage", src, {
                args = { "^1Insurance", "Park your vehicle first using the parking script before starting coverage." }
            })
            return
        end

        if not chargePlayer(src, premium, "Insurance premium") then
            TriggerClientEvent("chat:addMessage", src, {
                args = { "^1Insurance", "Unable to start policy – payment failed." }
            })
            return
        end

        upsertPolicy(discordId, plate, policyType, premium, deductible, props, function()
            buildSnapshot(src, function(snapshot)
                TriggerClientEvent("az_insurance:openUI", src, snapshot)
            end)
        end)
    end)
end)

---------------------------------------------------------------------
-- 🔴 Cancel policy – set active=0
---------------------------------------------------------------------
RegisterNetEvent("az_insurance:cancelPolicy", function(plate)
    local src = source
    plate = type(plate) == "string" and plate or nil
    if not plate or plate == "" then return end

    local discordId = getDiscordID(src)
    if not discordId then return end

    dprint(("cancelPolicy: src=%s discord=%s plate=%s"):format(src, discordId, plate))

    deactivatePolicy(discordId, plate, function()
        buildSnapshot(src, function(snapshot)
            TriggerClientEvent("az_insurance:openUI", src, snapshot)
        end)
    end)
end)

---------------------------------------------------------------------
-- 🚨 File theft claim
--  RULES:
--   - Must have active policy in DB
--   - Cooldown via user_vehicle_claims
--   - Vehicle MUST NOT be parked (IsVehicleParked == false)
--   - Spawns replacement at player's location using stored vehicle_props
---------------------------------------------------------------------
RegisterNetEvent("az_insurance:fileClaim", function(plate)
    local src = source
    plate = type(plate) == "string" and plate or nil
    if not plate or plate == "" then return end

    local discordId = getDiscordID(src)
    if not discordId then
        TriggerClientEvent("chat:addMessage", src, {
            args = { "^1Insurance", "Discord is required for insurance." }
        })
        return
    end

    fetchPolicy(discordId, plate, function(policy)
        if not policy then
            TriggerClientEvent("chat:addMessage", src, {
                args = { "^1Insurance", "You don't have an active policy for this vehicle." }
            })
            return
        end

        local now       = os.time()
        local cooldownS = (Config.ClaimCooldownMinutes or 30) * 60

        fetchLastClaimTime(discordId, plate, function(lastClaimAt)
            if lastClaimAt and (now - lastClaimAt) < cooldownS then
                local remaining = math.floor((cooldownS - (now - lastClaimAt)) / 60)
                TriggerClientEvent("chat:addMessage", src, {
                    args = { "^1Insurance", ("You must wait %d more minute(s) before filing another claim."):format(remaining) }
                })
                return
            end

            -- ✅ Only allow theft claim when **NOT parked**
            isPlateParked(discordId, plate, function(parked)
                if parked then
                    TriggerClientEvent("chat:addMessage", src, {
                        args = { "^1Insurance", "This vehicle is still parked. You can only file a THEFT claim when the vehicle is missing." }
                    })
                    return
                end

                -- Optional: charge deductible
                local deductible = policy.deductible or 0
                if deductible > 0 then
                    if not chargePlayer(src, deductible, "Insurance deductible") then
                        TriggerClientEvent("chat:addMessage", src, {
                            args = { "^1Insurance", "Unable to charge deductible for this claim." }
                        })
                        return
                    end
                end

                local payoutValue = 0 -- if you later want cash payouts

                insertClaim(discordId, plate, policy.policy_type, deductible, payoutValue, "approved", function()
                    dprint(("fileClaim: src=%s discord=%s plate=%s policy=%s deduct=%s payout=%s (NOT parked, spawning at player)"):
                        format(src, discordId, plate, policy.policy_type, deductible, payoutValue))

                    local props = policy.props or {}
                    spawnClaimVehicle(src, plate, props)
                end)
            end)
        end)
    end)
end)
