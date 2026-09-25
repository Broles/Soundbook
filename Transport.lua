-- Transport.lua
-- Validated, bounded, priority-aware outbound addon-message transport.
-- It is timer-driven only while work is queued and prevents hotkeys,
-- presence scans, or analytics sync from flooding the client channel.

local ADDON_NAME, SB = ...

local RawSendAddonMessage = SB.SendAddonMessage
local VALID_CHAT_TYPES = { PARTY = true, RAID = true, GUILD = true, OFFICER = true, WHISPER = true }
local MAX_MESSAGE_BYTES = 255
local MAX_QUEUE_SIZE = 128
-- Compatibility hardening: these were tuned far more aggressively than
-- Blizzard's own per-prefix addon-message throttle actually tolerates,
-- routinely hitting it in practice. Conservative values instead - a small
-- burst allowance, then a slow, steady trickle. Reliability, not maximum
-- throughput.
local TOKEN_CAPACITY = 10
local TOKEN_REFILL_PER_SECOND = 1
-- A send this addon's own transport actually attempted (as opposed to
-- one rejected before ever reaching the wire, e.g. IsValid failing) gets
-- at most this many tries before being dropped for good - bounds retry
-- behavior for a send that keeps getting throttled/rejected by the client
-- itself, so a single stuck message can never occupy the queue forever.
local MAX_SEND_ATTEMPTS = 3

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

-- Modern C_ChatInfo.SendAddonMessage (Core.lua's own RawSendAddonMessage
-- wrapper) returns an Enum.SendAddonMessageResult value rather than
-- raising a Lua error on throttle/rejection - only an explicit Success
-- means the message actually went out. `Enum.SendAddonMessageResult`
-- itself is an optional, newer namespace (missing entirely on older
-- Classic-family clients, where the legacy SendAddonMessage global - and
-- some earlier C_ChatInfo builds - return nothing at all on success, with
-- no failure signal available either way) - falls back to the literal 0
-- Blizzard document Success as when the enum table isn't present, and a
-- nil result is treated as success (the only thing a legacy call can ever
-- tell us).
local SEND_RESULT_SUCCESS = (Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success) or 0

-- "error" - the call itself raised a Lua error (pcall caught it).
-- "success" - actually sent (or no result signal exists to say otherwise).
-- "failed" - a modern client explicitly reported non-Success (almost
-- always its own per-prefix/channel throttle) - never counted as sent.
local function ClassifySendResult(ok, result)
    if not ok then return "error" end
    if result == nil or result == SEND_RESULT_SUCCESS then return "success" end
    return "failed"
end

-- Attempts (and, on failure, counts) exactly one send of an already-
-- queued-or-about-to-be-queued entry. Returns true only on a confirmed
-- send - the caller is responsible for leaving a failed entry queued
-- (bounded by entry.attempts below) rather than assuming delivery just
-- because the API call itself didn't throw.
local function SendNow(entry)
    local ok, result = pcall(RawSendAddonMessage, entry.prefix, entry.text, entry.chatType, entry.target)
    local status = ClassifySendResult(ok, result)
    if status == "success" then
        sentCount = sentCount + 1
        return true
    end
    entry.attempts = (entry.attempts or 0) + 1
    if status == "error" then
        SB:Debug("Addon-message send failed (Lua error, attempt %d/%d): %s",
            entry.attempts, MAX_SEND_ATTEMPTS, tostring(result))
    else
        SB:Debug("Addon-message throttled/rejected (attempt %d/%d): %s",
            entry.attempts, MAX_SEND_ATTEMPTS, MessageCommand(entry.text))
    end
    return false
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
        local entry = queue[bestIndex]
        tokens = tokens - 1
        if SendNow(entry) then
            table.remove(queue, bestIndex)
        else
            if entry.attempts >= MAX_SEND_ATTEMPTS then
                table.remove(queue, bestIndex)
                droppedCount = droppedCount + 1
                SB:Debug("Addon-message dropped after %d failed attempts (%s).", entry.attempts, MessageCommand(entry.text))
            end
            -- Back off rather than immediately re-attempting in this same
            -- pass against a channel/prefix that just rejected this exact
            -- send - ScheduleDrain below picks it (or the next entry) back
            -- up shortly.
            break
        end
        now = GetTime()
        Refill(now)
    end
    if #queue > 0 then
        ScheduleDrain(math.max(0.5, (1 - tokens) / TOKEN_REFILL_PER_SECOND))
    end
end

-- Shared by both call sites below that need to push a new entry into the
-- bounded queue, evicting the lowest-priority existing one if it's full -
-- same eviction rule either way, kept in one place.
local function EnqueueEntry(entry)
    if #queue >= MAX_QUEUE_SIZE then
        local replaceIndex, lowest = nil, entry.priority
        for index, existing in ipairs(queue) do
            if existing.priority < lowest then replaceIndex, lowest = index, existing.priority end
        end
        if replaceIndex then
            table.remove(queue, replaceIndex)
            droppedCount = droppedCount + 1
        else
            droppedCount = droppedCount + 1
            return false
        end
    end
    queue[#queue + 1] = entry
    return true
end

function SB.SendAddonMessage(prefix, text, chatType, target)
    if not IsValid(prefix, text, chatType, target) then
        droppedCount = droppedCount + 1
        SB:Debug("Rejected invalid outbound addon message (%s/%s).", tostring(chatType), tostring(MessageCommand(text)))
        return false
    end

    local priority, maxAge = PriorityFor(text)
    local now = GetTime()
    Refill(now)

    if tokens >= 1 and #queue == 0 then
        tokens = tokens - 1
        local entry = {
            prefix = prefix, text = text, chatType = chatType, target = target,
            priority = priority, maxAge = maxAge, queuedAt = now,
        }
        if SendNow(entry) then return true end
        -- Bugfix: a throttled/rejected result on this very first, no-queue
        -- attempt used to just be discarded (the caller never checked
        -- SendNow's own return value) - fall through into the normal
        -- bounded queue instead, same as any other queued send.
        if entry.attempts < MAX_SEND_ATTEMPTS and EnqueueEntry(entry) then
            ScheduleDrain(math.max(0.5, (1 - tokens) / TOKEN_REFILL_PER_SECOND))
            return true
        end
        return false
    end

    if priority <= 1 then
        for _, entry in ipairs(queue) do
            if entry.text == text and entry.chatType == chatType and entry.target == target then
                return true -- presence/analytics duplicate already pending
            end
        end
    end

    local entry = {
        prefix = prefix, text = text, chatType = chatType, target = target,
        priority = priority, maxAge = maxAge, queuedAt = now,
    }
    if EnqueueEntry(entry) then
        ScheduleDrain((1 - tokens) / TOKEN_REFILL_PER_SECOND)
        return true
    end
    return false
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
