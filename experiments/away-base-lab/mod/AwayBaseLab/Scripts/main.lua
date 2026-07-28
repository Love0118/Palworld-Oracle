local TAG = "[AwayBaseLab]"
local COMPILED_NESTED_STRUCT_WRITE_VERIFIED = false

local function log(message)
    print(string.format("%s %s\n", TAG, message))
end

local config_ok, Config = pcall(require, "config")
if not config_ok or type(Config) ~= "table" then
    log("TRIPPED reason=config_load_failed native_behavior=unchanged")
    return
end

-- A future reviewed mutation implementation must register a restoration
-- closure immediately after each verified write. This scaffold has no writer,
-- so the ledger always remains empty.
local original_value_ledger = {}
local terminal_tripped = false
local observation_running = false

local function read_text_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function global_kill_switch_path()
    local override = os.getenv("AWAY_BASE_LAB_GLOBAL_KILL_SWITCH")
    if override and override ~= "" then
        return override
    end
    return Config.Safety.GlobalKillSwitchFile
end

local function restore_originals(reason)
    local restored = 0
    local failed = 0
    for index = #original_value_ledger, 1, -1 do
        local entry = original_value_ledger[index]
        local ok, result = pcall(entry.restore)
        if ok and result == true then
            restored = restored + 1
        else
            failed = failed + 1
        end
    end
    original_value_ledger = {}
    log(string.format(
        "RESTORE reason=%s restored=%d failed=%d native_behavior=pass_through",
        tostring(reason), restored, failed
    ))
end

local function trip(reason)
    if terminal_tripped then
        return
    end
    terminal_tripped = true
    restore_originals(reason)
    log(string.format("TRIPPED reason=%s mutation_disabled=true", tostring(reason)))
end

local function exact_identity_matches()
    local expected = Config.ExpectedIdentity
    local checks = {
        { "PALWORLD_GAME_VERSION", expected.GameVersion },
        { "PALWORLD_STEAM_BUILD_ID", expected.SteamBuildId },
        { "PALSERVER_SHA256", expected.PalServerSha256 },
        { "PALSERVER_ELF_BUILD_ID", expected.PalServerElfBuildId },
        { "RE_UE4SS_LINUX_VERSION", expected.ReUe4ssLinuxVersion },
        { "RE_UE4SS_SOURCE_COMMIT", expected.ReUe4ssSourceCommit },
    }
    for _, check in ipairs(checks) do
        if os.getenv(check[1]) ~= check[2] then
            return false, check[1]
        end
    end
    return true, "all"
end

local function mutation_gate_status()
    if Config.Mode ~= "MUTATE_CANDIDATES" or Config.Safety.MutationRequested ~= true then
        return false, "observe_only"
    end
    if read_text_file(global_kill_switch_path()) ~= nil then
        return false, "global_kill_switch"
    end

    local identity_ok, identity_detail = exact_identity_matches()
    if not identity_ok then
        return false, "identity_mismatch:" .. identity_detail
    end

    local ack_path = os.getenv("AWAY_BASE_LAB_OPERATOR_ACK_FILE")
    if not ack_path or ack_path == "" then
        ack_path = Config.Safety.OperatorAckFile
    end
    local file_ack = read_text_file(ack_path)
    if not file_ack or file_ack:match("^%s*(.-)%s*$") ~= Config.Safety.OperatorAckPhrase then
        return false, "operator_ack_file_missing"
    end
    if os.getenv(Config.Safety.EnvironmentAckName) ~= Config.Safety.EnvironmentAckPhrase then
        return false, "environment_ack_missing"
    end

    -- Deliberate, non-configurable final block. The official Lua API documents
    -- TArray element access but does not prove atomic nested-struct replacement
    -- and verified restoration for this exact Palworld/Linux combination.
    if Config.Safety.NestedStructWriteVerified ~= true
        or COMPILED_NESTED_STRUCT_WRITE_VERIFIED ~= true then
        return false, "nested_struct_write_unverified"
    end
    return false, "no_mutation_implementation_compiled"
end

local function object_is_valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function object_name(object)
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    if ok then
        return tostring(name)
    end
    return "<name-unavailable>"
end

local function property(object, name)
    local ok, value = pcall(function()
        return object:GetPropertyValue(name)
    end)
    if not ok then
        return nil, tostring(value)
    end
    return value, nil
end

local function field(struct, name)
    local ok, value = pcall(function()
        return struct[name]
    end)
    if not ok then
        return nil, tostring(value)
    end
    return value, nil
end

local function unwrap_parameter(parameter)
    local ok, value = pcall(function()
        return parameter:get()
    end)
    if ok then
        return value
    end
    return parameter
end

local function format_significance(prefix, index, info)
    local distance, distance_error = field(info, "DistanceInRangeFromPlayer")
    local interval, interval_error = field(info, "TickInterval")
    local merge, merge_error = field(info, "bMergeDropItems")
    local simple, simple_error = field(info, "bUpdateSimple")
    if distance_error or interval_error or merge_error or simple_error then
        log(string.format(
            "%s index=%s read=blocked detail=%s|%s|%s|%s",
            prefix, tostring(index), tostring(distance_error), tostring(interval_error),
            tostring(merge_error), tostring(simple_error)
        ))
        return
    end
    log(string.format(
        "%s index=%s DistanceInRangeFromPlayer=%s TickInterval=%s bMergeDropItems=%s bUpdateSimple=%s",
        prefix, tostring(index), tostring(distance), tostring(interval),
        tostring(merge), tostring(simple)
    ))
end

local function observe_base_camp_managers()
    local managers = FindAllOf("PalBaseCampManager")
    if not managers then
        log("OBSERVE manager_instances=unavailable")
        return
    end
    log(string.format("OBSERVE manager_instances=%d", #managers))
    for manager_index, manager in ipairs(managers) do
        if object_is_valid(manager) then
            local update_interval, update_error = property(manager, "UpdateIntervalSquaredDistanceFromPlayer")
            log(string.format(
                "MANAGER index=%d object=%s UpdateIntervalSquaredDistanceFromPlayer=%s error=%s",
                manager_index, object_name(manager), tostring(update_interval), tostring(update_error)
            ))
            local list, list_error = property(manager, "BaseCampSignificanceInfoList")
            if list_error or list == nil then
                log(string.format("SIGNIFICANCE_LIST manager=%d read=blocked detail=%s", manager_index, tostring(list_error)))
            else
                local count_ok, count = pcall(function()
                    return list:GetArrayNum()
                end)
                log(string.format(
                    "SIGNIFICANCE_LIST manager=%d count=%s count_error=%s",
                    manager_index, tostring(count_ok and count or "unknown"),
                    tostring(count_ok and nil or count)
                ))
                local iterate_ok, iterate_error = pcall(function()
                    list:ForEach(function(index, parameter)
                        format_significance("SIGNIFICANCE", index, unwrap_parameter(parameter))
                    end)
                end)
                if not iterate_ok then
                    log(string.format("SIGNIFICANCE_LIST manager=%d iterate=blocked detail=%s", manager_index, tostring(iterate_error)))
                end
            end
        end
    end
end

local function observe_game_settings()
    local settings = FindAllOf("PalGameSetting")
    if not settings then
        log("OBSERVE game_setting_instances=unavailable")
        return
    end
    log(string.format("OBSERVE game_setting_instances=%d", #settings))
    for index, setting in ipairs(settings) do
        if object_is_valid(setting) then
            local merge_range, merge_error = property(setting, "MergeDropItemRange")
            local insert_budget, budget_error = property(setting, "DropItemWaitInsertMaxNumPerTick")
            log(string.format(
                "GAME_SETTING index=%d object=%s MergeDropItemRange=%s MergeDropItemRangeError=%s DropItemWaitInsertMaxNumPerTick=%s DropItemBudgetError=%s",
                index, object_name(setting), tostring(merge_range), tostring(merge_error),
                tostring(insert_budget), tostring(budget_error)
            ))
        end
    end
end

local function observe_base_models()
    local models = FindAllOf("PalBaseCampModel")
    if not models then
        log("OBSERVE base_model_instances=unavailable")
        return
    end
    log(string.format("OBSERVE base_model_instances=%d", #models))
    for index, model in ipairs(models) do
        if object_is_valid(model) then
            local info, info_error = property(model, "SignificanceInfo")
            local progress, progress_error = property(model, "ProgressTimeSinceLastTick")
            log(string.format(
                "BASE_MODEL index=%d object=%s ProgressTimeSinceLastTick=%s error=%s",
                index, object_name(model), tostring(progress), tostring(progress_error)
            ))
            if info_error then
                log(string.format("BASE_MODEL_SIGNIFICANCE index=%d read=blocked detail=%s", index, tostring(info_error)))
            elseif info ~= nil then
                format_significance("BASE_MODEL_SIGNIFICANCE", index, info)
            end
        end
    end
end

local function observe_once()
    if terminal_tripped then
        return
    end
    if read_text_file(global_kill_switch_path()) ~= nil then
        trip("global_kill_switch")
        return
    end

    local gate_open, gate_reason = mutation_gate_status()
    log(string.format(
        "GATE mutation_open=%s reason=%s mode=%s compiled_nested_struct_write_verified=%s",
        tostring(gate_open), tostring(gate_reason), tostring(Config.Mode),
        tostring(COMPILED_NESTED_STRUCT_WRITE_VERIFIED)
    ))
    log(string.format(
        "CANDIDATE MergeDropItemRangeCm=%s middle_tick=%s middle_merge=%s far_tick=%s far_merge=%s far_simple=%s away_grace=%s wake_hysteresis=%s",
        tostring(Config.Candidate.MergeDropItemRangeCm),
        tostring(Config.Candidate.Middle.TickIntervalSec),
        tostring(Config.Candidate.Middle.bMergeDropItems),
        tostring(Config.Candidate.Far.TickIntervalSec),
        tostring(Config.Candidate.Far.bMergeDropItems),
        tostring(Config.Candidate.Far.bUpdateSimple),
        tostring(Config.Candidate.AwayGraceSec),
        tostring(Config.Candidate.WakeHysteresisSec)
    ))

    observe_base_camp_managers()
    observe_game_settings()
    observe_base_models()
end

local function schedule_observation()
    if terminal_tripped or observation_running then
        return
    end
    observation_running = true
    ExecuteInGameThreadWithDelay(Config.ObserveIntervalMs, function()
        observation_running = false
        local ok, error_message = pcall(observe_once)
        if not ok then
            trip("observer_exception:" .. tostring(error_message))
            return
        end
        schedule_observation()
    end)
end

log(string.format(
    "START mode=%s target_game=%s steam_build=%s ue4ss=%s mutation_implementation=absent",
    tostring(Config.Mode), tostring(Config.ExpectedIdentity.GameVersion),
    tostring(Config.ExpectedIdentity.SteamBuildId),
    tostring(Config.ExpectedIdentity.ReUe4ssLinuxVersion)
))

ExecuteInGameThread(function()
    local ok, error_message = pcall(observe_once)
    if not ok then
        trip("initial_observer_exception:" .. tostring(error_message))
        return
    end
    schedule_observation()
end)
