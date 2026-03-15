local ESX = exports['es_extended'] and exports['es_extended']:getSharedObject() or nil
local ResourceName = GetCurrentResourceName()

local ReloadCacheMs = tonumber(Config and Config.Performance and Config.Performance.ReloadCacheMs) or 3000
local DamageFlushIntervalMs = tonumber(Config and Config.Performance and Config.Performance.DamageFlushIntervalMs) or 1000

local ownerVehicleCache = {}
local plateOwnerMap = {}
local pendingDamageUpdates = {}

CreateThread(function()
    if ESX then return end
    while ESX == nil do
        TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
        Wait(200)
    end
end)

local function normalizePlate(plate)
    return tostring(plate or ''):gsub('^%s*(.-)%s*$', '%1'):upper()
end

local function decodeJsonSafe(payload)
    if type(payload) ~= 'string' or payload == '' then return nil end
    local ok, decoded = pcall(json.decode, payload)
    if ok and type(decoded) == 'table' then
        return decoded
    end
    return nil
end

local function encodeJsonSafe(data)
    local ok, encoded = pcall(json.encode, data)
    if ok then return encoded end
    return nil
end

local function dbExecute(query, params)
    local ok, result = pcall(MySQL.update.await, query, params or {})
    if ok then return result end
    print(('[%s] dbExecute failed: %s'):format(ResourceName, tostring(result)))
    return nil
end

local function dbFetchAll(query, params)
    local ok, result = pcall(MySQL.query.await, query, params or {})
    if ok and type(result) == 'table' then return result end
    if not ok then
        print(('[%s] dbFetchAll failed: %s'):format(ResourceName, tostring(result)))
    end
    return {}
end

local function invalidatePlateCache(plate)
    local normalized = normalizePlate(plate)
    if normalized == '' then return end
    local owner = plateOwnerMap[normalized]
    if owner then
        ownerVehicleCache[owner] = nil
    end
end

local function upsertCustomProps(plate, props)
    if type(props) ~= 'table' then return end
    local normalizedPlate = normalizePlate(plate)
    if normalizedPlate == '' then return end

    props.plate = normalizedPlate
    local encodedProps = encodeJsonSafe(props)
    if not encodedProps then return end

    dbExecute('REPLACE INTO val_custom_props (plate, props) VALUES (?, ?)', {
        normalizedPlate,
        encodedProps
    })
end

local function getPlayer(src)
    if not ESX then return nil end
    return ESX.GetPlayerFromId(src)
end

local function fetchVehicles(identifier)
    local now = GetGameTimer()
    local cached = ownerVehicleCache[identifier]
    if cached and cached.expiresAt > now then
        return cached.data
    end

    local result = dbFetchAll('SELECT owner, plate, vehicle, type, stored, police, job, vehiclename, health_vehicles, deposit FROM owned_vehicles WHERE owner = ?', {
        identifier
    })

    local list = {}
    local plateIndexMap = {}
    local plates = {}

    for i = 1, #result do
        local r = result[i]
        local normalizedPlate = normalizePlate(r.plate)
        list[#list + 1] = {
            plate = r.plate,
            stored = r.stored == 1 or r.stored == true,
            police = r.police or 0,
            job = r.job or '',
            type = r.type or 'car',
            vehiclename = r.vehiclename,
            vehicle = r.vehicle,
            health_vehicles = r.health_vehicles,
            deposit = r.deposit
        }

        if normalizedPlate ~= '' and not plateIndexMap[normalizedPlate] then
            plateIndexMap[normalizedPlate] = #list
            plates[#plates + 1] = normalizedPlate
            plateOwnerMap[normalizedPlate] = identifier
        end
    end

    if #plates > 0 then
        local placeholders = table.concat((function()
            local t = {}
            for i = 1, #plates do
                t[i] = '?'
            end
            return t
        end)(), ',')

        local query = ('SELECT plate, props FROM val_custom_props WHERE plate IN (%s)'):format(placeholders)
        local customRows = dbFetchAll(query, plates)

        for i = 1, #customRows do
            local row = customRows[i]
            local idx = plateIndexMap[normalizePlate(row.plate)]
            if idx and row.props then
                local decodedProps = decodeJsonSafe(row.props)
                local encodedProps = decodedProps and encodeJsonSafe(decodedProps) or nil
                if encodedProps then
                    list[idx].vehicle = encodedProps
                end
            end
        end
    end

    ownerVehicleCache[identifier] = {
        data = list,
        expiresAt = now + ReloadCacheMs
    }

    return list
end

local function flushPendingDamage()
    if not next(pendingDamageUpdates) then return end

    local batch = pendingDamageUpdates
    pendingDamageUpdates = {}

    for plate, encodedDamage in pairs(batch) do
        dbExecute('UPDATE owned_vehicles SET health_vehicles = ? WHERE plate = ?', {
            encodedDamage,
            plate
        })
        invalidatePlateCache(plate)
    end
end

local function sendWebhook(url, title, description, color)
    if not url or url == '' then return end

    local body = {
        username = 'val-garage',
        embeds = {
            {
                title = title,
                description = description,
                color = color or 16711680
            }
        }
    }

    PerformHttpRequest(url, function() end, 'POST', json.encode(body), {
        ['Content-Type'] = 'application/json'
    })
end

RegisterServerEvent(ResourceName..':logWebhook')
AddEventHandler(ResourceName..':logWebhook', function(payload)
    if type(payload) ~= 'table' then return end

    local src = source
    local xPlayer = getPlayer(src)
    local ownerName = (xPlayer and xPlayer.getName and xPlayer.getName()) or GetPlayerName(src) or ('ID '..tostring(src))
    local action = tostring(payload.action or payload.webhook or '')
    local plate = tostring(payload.plate or '-')
    local durability = tonumber(payload.durability or 0) or 0
    local fuel = tonumber(payload.fuel or 0) or 0

    local titleMap = {
        storevehicle = 'เก็บรถ',
        garage_spawn = 'เบิกรถ',
        garage_pound = 'พาวน์รถ'
    }

    local title = titleMap[action] or 'Garage Log'
    local desc = ('ชื่อเจ้าของรถ: %s\nทะเบียน: %s\nความคงทนรถ: %.1f\nน้ำมัน: %.1f')
        :format(ownerName, plate, durability, fuel)

    local webhookUrl = nil
    if Config.Webhooks then
        webhookUrl = Config.Webhooks[action]
    end

    sendWebhook(webhookUrl, title, desc, 16711680)
end)

RegisterServerEvent(ResourceName..':reloadData')
AddEventHandler(ResourceName..':reloadData', function()
    local src = source
    local xPlayer = getPlayer(src)
    if not xPlayer then return end

    local identifier = xPlayer.getIdentifier() or xPlayer.identifier
    if not identifier then return end

    local vehicles = fetchVehicles(identifier)
    TriggerClientEvent(ResourceName..':reloadData:client', src, vehicles)
end)

RegisterServerEvent(ResourceName..':setStateVehicle')
AddEventHandler(ResourceName..':setStateVehicle', function(plate, stored, props)
    if type(plate) ~= 'string' or plate == '' then return end

    plate = normalizePlate(plate)
    local s = stored and 1 or 0

    if type(props) == 'table' then
        props.plate = plate
        local encodedProps = encodeJsonSafe(props)
        if encodedProps then
            dbExecute('UPDATE owned_vehicles SET stored = ?, vehicle = ? WHERE plate = ?', {
                s,
                encodedProps,
                plate
            })
            upsertCustomProps(plate, props)
            invalidatePlateCache(plate)
            return
        end
    end

    dbExecute('UPDATE owned_vehicles SET stored = ? WHERE plate = ?', {
        s,
        plate
    })
    invalidatePlateCache(plate)
end)

RegisterServerEvent(ResourceName..':depositvehicles')
AddEventHandler(ResourceName..':depositvehicles', function(plate, depositId)
    if type(plate) ~= 'string' or plate == '' then return end

    plate = normalizePlate(plate)
    dbExecute('UPDATE owned_vehicles SET deposit = ? WHERE plate = ?', {
        tonumber(depositId),
        plate
    })
    invalidatePlateCache(plate)
end)

RegisterServerEvent(ResourceName..':removeDepositCar')
AddEventHandler(ResourceName..':removeDepositCar', function(plate)
    if type(plate) ~= 'string' or plate == '' then return end

    plate = normalizePlate(plate)
    dbExecute('UPDATE owned_vehicles SET deposit = NULL WHERE plate = ?', {
        plate
    })
    invalidatePlateCache(plate)
end)

RegisterServerEvent(ResourceName..':deletePoundVehicle')
AddEventHandler(ResourceName..':deletePoundVehicle', function(plate)
    if type(plate) ~= 'string' or plate == '' then return end
    TriggerClientEvent(ResourceName..':deletePoundVehicleAll', -1, plate)
end)

RegisterServerEvent(ResourceName..':openTrunk')
AddEventHandler(ResourceName..':openTrunk', function(_plate)
end)

RegisterServerEvent(ResourceName..':renamevehicle')
AddEventHandler(ResourceName..':renamevehicle', function(plate, rename)
    if type(plate) ~= 'string' or plate == '' then return end
    if type(rename) ~= 'string' or rename == '' then return end

    plate = normalizePlate(plate)
    dbExecute('UPDATE owned_vehicles SET vehiclename = ? WHERE plate = ?', {
        rename,
        plate
    })
    invalidatePlateCache(plate)
end)

RegisterServerEvent(ResourceName..'::modifyDamage')
AddEventHandler(ResourceName..'::modifyDamage', function(plate, damage)
    if type(plate) ~= 'string' or plate == '' then return end
    if type(damage) ~= 'table' then return end

    local encodedDamage = encodeJsonSafe(damage)
    if not encodedDamage then return end

    plate = normalizePlate(plate)
    pendingDamageUpdates[plate] = encodedDamage
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= ResourceName then return end
    flushPendingDamage()
end)

CreateThread(function()
    while true do
        Wait(DamageFlushIntervalMs)
        flushPendingDamage()
    end
end)

CreateThread(function()
    while not ESX do Wait(200) end

    dbExecute([[
        CREATE TABLE IF NOT EXISTS val_custom_props (
            plate VARCHAR(32) PRIMARY KEY,
            props LONGTEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
    ]])

    dbExecute('CREATE INDEX IF NOT EXISTS idx_owned_vehicles_owner ON owned_vehicles (owner)')
    dbExecute('CREATE INDEX IF NOT EXISTS idx_owned_vehicles_plate ON owned_vehicles (plate)')

    ESX.RegisterServerCallback(ResourceName..':payMoney', function(src, cb)
        local xPlayer = getPlayer(src)
        if not xPlayer then cb(false) return end

        local cost = tonumber(Config.poundCost or 0) or 0
        if cost <= 0 then cb(true) return end

        local money = xPlayer.getMoney()
        if money >= cost then
            xPlayer.removeMoney(cost)
            cb(true)
            return
        end

        local bank = xPlayer.getAccount('bank').money or 0
        if bank >= cost then
            xPlayer.removeAccountMoney('bank', cost)
            cb(true)
        else
            cb(false)
        end
    end)
end)
