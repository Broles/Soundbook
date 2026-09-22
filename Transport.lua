-- Transport.lua
-- Validated, bounded, priority-aware outbound addon-message transport.
-- It is timer-driven only while work is queued and prevents hotkeys,
-- presence scans, or analytics sync from flooding the client channel.

local ADDON_NAME, SB = ...

local RawSendAddonMessage = SB.SendAddonMessage
local VALID_CHAT_TYPES = { PARTY = true, RAID = true, GUILD = true, OFFICER = true, WHISPER = true }
local MAX_MESSAGE_BYTES = 255
local MAX_QUEUE_SIZE = 128
local TOKEN_CAPACITY = 24
local TOKEN_REFILL_PER_SECOND = 12

local queue = {}
local tokens = TOKEN_CAPACITY
local updatedAt = GetTime()
local drainTimer
local sentCount, droppedCount = 0, 0

local function MessageCommand(text)
    return type(text) == "string" and text:match("^[^|]+|([^|]+)|") or nil
end

local function PriorityFor(text)
    local command = MessageCommand(text)
    if command == "ACK" or command == "MUTEACK" or command == "RXOFFACK" or command == "ADMINACK"
        or command == "ADMINMUTE" or command == "ADMINUNMUTE" or command == "ADMINMUTEALL" or command == "ADMINUNMUTEALL" then
        return 3, 12
    elseif command == "PLAY" then
        return 2, 4
    elseif command == "ANLY" then
        return 0, 30
    end
    return 1, 30
end

local function Refill(now)
    local elapsed = math.max(0, now - updatedAt)
    tokens = math.min(TOKEN_CAPACITY, tokens + elapsed * TOKEN_REFILL_PER_SECOND)
    updatedAt = now
end

local function IsValid(prefix, text, chatType, target)
    if prefix ~= SB.COMM_PREFIX or type(text) ~= "string" or #text == 0 or #text > MAX_MESSAGE_BYTES then return false end
    if text:find("[%z\1-\31\127]") or not VALID_CHAT_TYPES[chatType] then return false end
    if chatType == "WHISPER" then return SB.IsValidPlayerTarget(target) end
    return target == nil or target == ""
end

local function ScheduleDrain(delay)
    if drainTimer then return end
    drainTimer = C_Timer.NewTimer(math.max(0.02, delay or 0.02), function()
        drainTimer = nil
        SB:DrainMessageQueue()
    end)
end

local function SendNow(entry)
    local ok, result = pcall(RawSendAddonMessage, entry.prefix, entry.text, entry.chatType, entry.target)
    if ok then sentCount = sentCount + 1 else SB:Debug("Addon-message send failed: %s", tostring(result)) end
    return ok and result
end

function SB:DrainMessageQueue()
    local now = GetTime()
    Refill(now)
    while tokens >= 1 and #queue > 0 do
        local bestIndex, bestPriority = nil, -1
        for index, entry in ipairs(queue) do
            if now - entry.queuedAt > entry.maxAge then
                table.remove(queue, index)
                droppedCount = droppedCount + 1
                return SB:DrainMessageQueue()
            elseif entry.priority > bestPriority then
                bestIndex, bestPriority = index, entry.priority
            end
        end
        local entry = table.remove(queue, bestIndex)
        tokens = tokens - 1
        SendNow(entry)
        now = GetTime()
        Refill(now)
    end
    if #queue > 0 then
        ScheduleDrain((1 - tokens) / TOKEN_REFILL_PER_SECOND)
    end
end

function SB.SendAddonMessage(prefix, text, chatType, target)
    if not IsValid(prefix, text, chatType, target) then
        droppedCount = droppedCount + 1
        SB:Debug("Rejected invalid outbound addon message (%s/%s).", tostring(chatType), tostring(MessageCommand(text)))
        return false
    end

    local now = GetTime()
    Refill(now)
    if tokens >= 1 and #queue == 0 then
        tokens = tokens - 1
        return SendNow({ prefix = prefix, text = text, chatType = chatType, target = target })
    end

    local priority, maxAge = PriorityFor(text)
    if priority <= 1 then
        for _, entry in ipairs(queue) do
            if entry.text == text and entry.chatType == chatType and entry.target == target then
                return true -- presence/analytics duplicate already pending
            end
        end
    end

    if #queue >= MAX_QUEUE_SIZE then
        local replaceIndex, lowest = nil, priority
        for index, entry in ipairs(queue) do
            if entry.priority < lowest then replaceIndex, lowest = index, entry.priority end
        end
        if replaceIndex then
            table.remove(queue, replaceIndex)
            droppedCount = droppedCount + 1
        else
            droppedCount = droppedCount + 1
            return false
        end
    end

    queue[#queue + 1] = {
        prefix = prefix, text = text, chatType = chatType, target = target,
        priority = priority, maxAge = maxAge, queuedAt = now,
    }
    ScheduleDrain((1 - tokens) / TOKEN_REFILL_PER_SECOND)
    return true
end

function SB:ClearQueuedSoundMessages()
    for index = #queue, 1, -1 do
        if MessageCommand(queue[index].text) == "PLAY" then table.remove(queue, index) end
    end
end

function SB:ClearQueuedAnalyticsMessages()
    for index = #queue, 1, -1 do
        if MessageCommand(queue[index].text) == "ANLY" then table.remove(queue, index) end
    end
    if #queue == 0 and drainTimer then
        drainTimer:Cancel()
        drainTimer = nil
    end
end

function SB:GetTransportStats()
    return { queued = #queue, sent = sentCount, dropped = droppedCount }
end
