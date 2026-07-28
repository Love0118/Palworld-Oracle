local TAG = "[AwayBaseOptimizer]"
local COMPILED_TARRAY_STRUCT_GET_SET = true
local EPSILON = 0.0001
local COMPILED_IDENTITY = {
    PALWORLD_GAME_VERSION = "1.0.1.100619",
    PALWORLD_STEAM_BUILD_ID = "24181105",
    PALSERVER_SHA256 = "788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7",
    PALSERVER_ELF_BUILD_ID = "7f7e167407984ec3",
    RE_UE4SS_LINUX_TAG = "linux-v0.1.0",
    RE_UE4SS_SOURCE_COMMIT = "5d33654755efed844336497e8a9a15e6716b5d6c",
}
local COMPILED_UE4SS_API_VERSION = { 3, 0, 1 }
local REQUIRED_ACKNOWLEDGEMENTS = {
    ExactBuildAndTierMap = "I_VERIFIED_EXACT_BUILD_AND_LIVE_TIER_MAP",
    MutationAndRollbackRisk = "I_ACCEPT_SERVER_MUTATION_AND_RESTART_ROLLBACK_RISK",
}

local function log(message)
    print(string.format("%s %s\n", TAG, tostring(message)))
end

local config_ok, Config = pcall(require, "config")
if not config_ok or type(Config) ~= "table" then
    log("TRIPPED reason=config_load_failed native_behavior=unchanged")
    return
end

local State = {
    applied = false,
    tripped = false,
    restoring = false,
    snapshot = nil,
    manager = nil,
    manager_address = nil,
    manager_name = nil,
    list = nil,
}

local function approx_equal(left, right)
    return type(left) == "number"
        and type(right) == "number"
        and math.abs(left - right) <= EPSILON
end

local function is_finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
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
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or "<name-unavailable>"
end

local function object_address(object)
    local ok, value = pcall(function()
        return object:GetAddress()
    end)
    if not ok or type(value) ~= "number" then
        error("object_address_unavailable")
    end
    return value
end

local function get_property(object, name)
    return object:GetPropertyValue(name)
end

local function assert_game_thread()
    if IsInGameThread == nil or IsInGameThread() ~= true then
        error("write_attempt_outside_game_thread")
    end
end

local function file_exists(path)
    if type(path) ~= "string" or path == "" then
        error("global_kill_path_missing")
    end
    local handle, _, open_code = io.open(path, "r")
    if handle then
        handle:close()
        return true
    end
    local rename_ok, _, rename_code = os.rename(path, path)
    if rename_ok then
        return true
    end
    local error_code = rename_code or open_code
    if error_code == 2 then
        return false
    end
    error("global_kill_probe_failed:" .. tostring(error_code))
end

local function kill_file_path()
    local override = os.getenv("AWAY_BASE_OPTIMIZER_GLOBAL_KILL_FILE")
    if override and override ~= "" then
        return override
    end
    return Config.Safety and Config.Safety.GlobalKillFile or nil
end

local function kill_file_present()
    return file_exists(kill_file_path())
end

local function assert_not_killed()
    if kill_file_present() then
        error("global_kill_file")
    end
end

local function valid_instances(class_name)
    local found = FindAllOf(class_name)
    local valid = {}
    if found then
        for _, object in ipairs(found) do
            if object_is_valid(object) then
                valid[#valid + 1] = object
            end
        end
    end
    return valid
end

local function deep_copy_tier(info)
    local tier = {
        DistanceInRangeFromPlayer = info.DistanceInRangeFromPlayer,
        TickInterval = info.TickInterval,
        bMergeDropItems = info.bMergeDropItems,
        bUpdateSimple = info.bUpdateSimple,
    }
    if not is_finite_number(tier.DistanceInRangeFromPlayer)
        or not is_finite_number(tier.TickInterval)
        or type(tier.bMergeDropItems) ~= "boolean"
        or type(tier.bUpdateSimple) ~= "boolean" then
        error("tier_invalid_field_types")
    end
    return tier
end

local function read_tier(list, requested_index)
    local tier = nil
    list:ForEach(function(index, element)
        if index == requested_index then
            tier = deep_copy_tier(element:get())
            return true
        end
        return false
    end)
    if tier == nil then
        error(string.format("tier_%d_not_found", requested_index))
    end
    return tier
end

local function set_tier(list, requested_index, replacement)
    assert_game_thread()
    local wrote = false
    list:ForEach(function(index, element)
        if index == requested_index then
            -- Set all four POD fields so the replacement is a complete,
            -- independently snapshotted FPalBaseCampSignificanceInfo value.
            element:set({
                DistanceInRangeFromPlayer = replacement.DistanceInRangeFromPlayer,
                TickInterval = replacement.TickInterval,
                bMergeDropItems = replacement.bMergeDropItems,
                bUpdateSimple = replacement.bUpdateSimple,
            })
            wrote = true
            return true
        end
        return false
    end)
    if not wrote then
        error(string.format("tier_%d_set_not_found", requested_index))
    end
end

local function dump_live_topology(manager)
    local list = get_property(manager, "BaseCampSignificanceInfoList")
    local count = list:GetArrayNum()
    log(string.format(
        "OBSERVE manager=%s significance_count=%d",
        object_name(manager), count
    ))
    for index = 1, count do
        local tier = read_tier(list, index)
        log(string.format(
            "TIER index=%d DistanceInRangeFromPlayer=%.6f TickInterval=%.6f bMergeDropItems=%s bUpdateSimple=%s",
            index, tier.DistanceInRangeFromPlayer, tier.TickInterval,
            tostring(tier.bMergeDropItems), tostring(tier.bUpdateSimple)
        ))
    end
    return list, count
end

local function identity_matches()
    if type(Config.IdentityEnvironment) ~= "table" then
        return false, "identity_table_missing"
    end
    for name, expected in pairs(COMPILED_IDENTITY) do
        if Config.IdentityEnvironment[name] ~= expected
            or os.getenv(name) ~= expected then
            return false, "identity_mismatch:" .. tostring(name)
        end
    end

    if UE4SS == nil or type(UE4SS.GetVersion) ~= "function" then
        return false, "ue4ss_version_api_missing"
    end
    local major, minor, hotfix = UE4SS.GetVersion()
    if major ~= COMPILED_UE4SS_API_VERSION[1]
        or minor ~= COMPILED_UE4SS_API_VERSION[2]
        or hotfix ~= COMPILED_UE4SS_API_VERSION[3] then
        return false, string.format(
            "ue4ss_api_version_mismatch:%s.%s.%s",
            tostring(major), tostring(minor), tostring(hotfix)
        )
    end
    return true, "exact"
end

local function apply_gate_status()
    if COMPILED_TARRAY_STRUCT_GET_SET ~= true then
        return false, "compiled_tarray_struct_gate_closed"
    end
    if Config.Enabled ~= true then
        return false, "Enabled_not_true"
    end
    if Config.Mode ~= "APPLY" then
        return false, "mode_not_APPLY"
    end
    if type(Config.Acknowledgements) ~= "table" then
        return false, "ack_table_missing"
    end
    if Config.Acknowledgements.ExactBuildAndTierMap
        ~= REQUIRED_ACKNOWLEDGEMENTS.ExactBuildAndTierMap then
        return false, "ack_exact_build_and_tier_map_missing"
    end
    if Config.Acknowledgements.MutationAndRollbackRisk
        ~= REQUIRED_ACKNOWLEDGEMENTS.MutationAndRollbackRisk then
        return false, "ack_mutation_and_rollback_risk_missing"
    end

    local path = kill_file_path()
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
        return false, "absolute_global_kill_path_required"
    end
    if kill_file_present() then
        return false, "global_kill_file"
    end

    local identity_ok, identity_reason = identity_matches()
    if not identity_ok then
        return false, identity_reason
    end
    return true, "open"
end

local function validate_topology(list, count)
    local selection = Config.TierSelection
    if type(selection) ~= "table" then
        error("tier_selection_missing")
    end
    if type(selection.ExpectedCount) ~= "number"
        or selection.ExpectedCount < 3
        or selection.ExpectedCount % 1 ~= 0
        or count ~= selection.ExpectedCount then
        error(string.format(
            "tier_count_mismatch:expected=%s:actual=%s",
            tostring(selection.ExpectedCount), tostring(count)
        ))
    end
    if selection.DistanceOrder ~= "ASCENDING"
        and selection.DistanceOrder ~= "DESCENDING" then
        error("distance_order_not_explicit")
    end

    local middle = selection.MiddleIndex
    local far = selection.FarIndex
    if type(middle) ~= "number" or middle % 1 ~= 0
        or type(far) ~= "number" or far % 1 ~= 0
        or middle < 1 or far < 1 or middle > count or far > count
        or middle == far then
        error("middle_far_indices_invalid")
    end

    local tiers = {}
    for index = 1, count do
        local tier = read_tier(list, index)
        tiers[index] = tier
        if index > 1 then
            local previous = tiers[index - 1].DistanceInRangeFromPlayer
            local current = tier.DistanceInRangeFromPlayer
            if selection.DistanceOrder == "ASCENDING" and current <= previous then
                error(string.format("distance_order_mismatch_at_%d", index))
            end
            if selection.DistanceOrder == "DESCENDING" and current >= previous then
                error(string.format("distance_order_mismatch_at_%d", index))
            end
        end
    end

    local middle_distance = tiers[middle].DistanceInRangeFromPlayer
    local far_distance = tiers[far].DistanceInRangeFromPlayer
    if not approx_equal(middle_distance, selection.ExpectedMiddleDistanceCm) then
        error("middle_distance_identity_mismatch")
    end
    if not approx_equal(far_distance, selection.ExpectedFarDistanceCm) then
        error("far_distance_identity_mismatch")
    end
    if selection.DistanceOrder == "ASCENDING"
        and (middle >= far or middle_distance >= far_distance) then
        error("middle_far_semantics_mismatch")
    end
    if selection.DistanceOrder == "DESCENDING"
        and (middle <= far or middle_distance >= far_distance) then
        error("middle_far_semantics_mismatch")
    end
    return tiers
end

local function tier_matches(actual, expected)
    return approx_equal(
        actual.DistanceInRangeFromPlayer,
        expected.DistanceInRangeFromPlayer
    ) and approx_equal(actual.TickInterval, expected.TickInterval)
        and actual.bMergeDropItems == expected.bMergeDropItems
        and actual.bUpdateSimple == expected.bUpdateSimple
end

local function tier_is_partial_candidate(actual, original, replacement)
    return (approx_equal(actual.DistanceInRangeFromPlayer,
                         original.DistanceInRangeFromPlayer)
            or approx_equal(actual.DistanceInRangeFromPlayer,
                            replacement.DistanceInRangeFromPlayer))
        and (approx_equal(actual.TickInterval, original.TickInterval)
            or approx_equal(actual.TickInterval, replacement.TickInterval))
        and (actual.bMergeDropItems == original.bMergeDropItems
            or actual.bMergeDropItems == replacement.bMergeDropItems)
        and (actual.bUpdateSimple == original.bUpdateSimple
            or actual.bUpdateSimple == replacement.bUpdateSimple)
end

local function verify_tier(list, index, expected, label)
    local actual = read_tier(list, index)
    if not tier_matches(actual, expected) then
        error(label .. "_readback_mismatch")
    end
end

local function restore_tier(list, index, original)
    assert_game_thread()
    set_tier(list, index, original)
    verify_tier(list, index, original, "rollback_tier_" .. tostring(index))
end

local function restore_attempted_tier(
    list, label, index, original, replacement, attempted, verified
)
    if not attempted then
        return
    end
    local current = read_tier(list, index)
    if tier_matches(current, original) then
        return
    end
    if verified then
        if not tier_matches(current, replacement) then
            error("rollback_" .. label .. "_ownership_lost")
        end
    elseif not tier_is_partial_candidate(current, original, replacement) then
        error("rollback_" .. label .. "_partial_write_ambiguous")
    end
    restore_tier(list, index, original)
end

local function restore_all(reason)
    if State.restoring or State.snapshot == nil then
        return true
    end
    assert_game_thread()
    State.restoring = true
    local failures = {}
    local restore_list = nil

    local target_ok, target_error = pcall(function()
        if not object_is_valid(State.manager)
            or object_address(State.manager) ~= State.manager_address
            or object_name(State.manager) ~= State.manager_name then
            error("rollback_target_identity_changed")
        end
        local current_list = get_property(
            State.manager, "BaseCampSignificanceInfoList"
        )
        if current_list:GetArrayNum() ~= State.snapshot.count then
            error("rollback_tier_count_changed")
        end
        local middle = read_tier(current_list, State.snapshot.middle_index)
        local far = read_tier(current_list, State.snapshot.far_index)
        if not approx_equal(
            middle.DistanceInRangeFromPlayer,
            State.snapshot.middle.DistanceInRangeFromPlayer
        ) or not approx_equal(
            far.DistanceInRangeFromPlayer,
            State.snapshot.far.DistanceInRangeFromPlayer
        ) then
            error("rollback_tier_identity_changed")
        end
        restore_list = current_list
    end)
    if not target_ok then
        failures[#failures + 1] = "target:" .. tostring(target_error)
    end

    if target_ok then
        local far_ok, far_error = pcall(function()
            restore_attempted_tier(
                restore_list, "far", State.snapshot.far_index,
                State.snapshot.far, State.snapshot.far_replacement,
                State.snapshot.far_attempted, State.snapshot.far_verified
            )
        end)
        if not far_ok then
            failures[#failures + 1] = "far:" .. tostring(far_error)
        end

        local middle_ok, middle_error = pcall(function()
            restore_attempted_tier(
                restore_list, "middle", State.snapshot.middle_index,
                State.snapshot.middle, State.snapshot.middle_replacement,
                State.snapshot.middle_attempted,
                State.snapshot.middle_verified
            )
        end)
        if not middle_ok then
            failures[#failures + 1] = "middle:" .. tostring(middle_error)
        end
    end

    State.applied = false
    State.restoring = false
    log(string.format(
        "ROLLBACK reason=%s status=%s failures=%d detail=%s",
        tostring(reason), #failures == 0 and "verified" or "FAILED",
        #failures, table.concat(failures, "|")
    ))
    return #failures == 0
end

local function trip(reason)
    if State.tripped then
        return
    end
    State.tripped = true
    local rollback_ok, rollback_result = pcall(function()
        return restore_all(reason)
    end)
    if not rollback_ok then
        log("ROLLBACK status=FAILED exception=" .. tostring(rollback_result))
    end
    log(string.format(
        "TRIPPED reason=%s rollback_ok=%s mutation_disabled=true",
        tostring(reason), tostring(rollback_ok and rollback_result == true)
    ))
end

local function write_middle(list, index, replacement)
    assert_game_thread()
    assert_not_killed()
    set_tier(list, index, replacement)
    assert_not_killed()
    verify_tier(list, index, replacement, "middle")
end

local function write_far(list, index, replacement)
    assert_game_thread()
    assert_not_killed()
    set_tier(list, index, replacement)
    assert_not_killed()
    verify_tier(list, index, replacement, "far")
end

local function apply(manager, list, count)
    assert_game_thread()
    if type(Config.MonitorIntervalMs) ~= "number"
        or Config.MonitorIntervalMs < 100
        or Config.MonitorIntervalMs > 60000
        or Config.MonitorIntervalMs % 1 ~= 0 then
        error("monitor_interval_invalid")
    end
    local manager_name = object_name(manager)
    if type(Config.Target) ~= "table"
        or type(Config.Target.ManagerFullName) ~= "string"
        or Config.Target.ManagerFullName == ""
        or manager_name ~= Config.Target.ManagerFullName then
        error("manager_full_name_identity_mismatch")
    end
    if not approx_equal(Config.Values.MiddleTickIntervalSec, 3.0)
        or not approx_equal(Config.Values.FarTickIntervalSec, 7.5) then
        error("compiled_policy_value_mismatch")
    end
    local tiers = validate_topology(list, count)
    local middle_index = Config.TierSelection.MiddleIndex
    local far_index = Config.TierSelection.FarIndex
    local middle_replacement = {
        DistanceInRangeFromPlayer = tiers[middle_index].DistanceInRangeFromPlayer,
        TickInterval = Config.Values.MiddleTickIntervalSec,
        bMergeDropItems = true,
        bUpdateSimple = tiers[middle_index].bUpdateSimple,
    }
    local far_replacement = {
        DistanceInRangeFromPlayer = tiers[far_index].DistanceInRangeFromPlayer,
        TickInterval = Config.Values.FarTickIntervalSec,
        bMergeDropItems = true,
        bUpdateSimple = true,
    }

    -- Snapshot every original that a later write can change before the first write.
    State.manager = manager
    State.manager_address = object_address(manager)
    State.manager_name = manager_name
    State.list = list
    State.snapshot = {
        count = count,
        middle_index = middle_index,
        far_index = far_index,
        middle = tiers[middle_index],
        far = tiers[far_index],
        middle_replacement = middle_replacement,
        far_replacement = far_replacement,
        middle_attempted = false,
        middle_verified = false,
        far_attempted = false,
        far_verified = false,
    }

    State.snapshot.middle_attempted = true
    write_middle(list, middle_index, State.snapshot.middle_replacement)
    State.snapshot.middle_verified = true
    State.snapshot.far_attempted = true
    write_far(list, far_index, State.snapshot.far_replacement)
    State.snapshot.far_verified = true

    if list:GetArrayNum() ~= State.snapshot.count then
        error("tier_count_changed_during_apply")
    end
    State.applied = true
    log(string.format(
        "APPLIED verified=true middle_index=%d middle_tick=3 middle_merge=true far_index=%d far_tick=7.5 far_merge=true far_simple=true",
        middle_index, far_index
    ))
end

local function verify_applied_state()
    assert_game_thread()
    assert_not_killed()
    local gate_open, gate_reason = apply_gate_status()
    if not gate_open then
        error("gate_closed_after_apply:" .. gate_reason)
    end
    if not object_is_valid(State.manager)
        or object_address(State.manager) ~= State.manager_address
        or object_name(State.manager) ~= State.manager_name then
        error("target_object_identity_changed")
    end
    if State.list:GetArrayNum() ~= State.snapshot.count then
        error("tier_count_changed")
    end
    validate_topology(State.list, State.snapshot.count)
    verify_tier(
        State.list, State.snapshot.middle_index,
        State.snapshot.middle_replacement, "middle_monitor"
    )
    verify_tier(
        State.list, State.snapshot.far_index,
        State.snapshot.far_replacement, "far_monitor"
    )
end

local function schedule_monitor()
    if State.tripped or not State.applied then
        return
    end
    local handle = ExecuteInGameThreadWithDelay(Config.MonitorIntervalMs, function()
        local ok, error_message = pcall(function()
            verify_applied_state()
            schedule_monitor()
        end)
        if not ok then
            trip("monitor:" .. tostring(error_message))
        end
    end)
    if type(handle) ~= "number" or handle % 1 ~= 0 then
        error("monitor_schedule_failed")
    end
end

local function start_on_game_thread(manager)
    assert_game_thread()
    if kill_file_present() then
        trip("global_kill_file_at_start")
        return
    end

    local list, count = dump_live_topology(manager)
    local gate_open, gate_reason = apply_gate_status()
    log(string.format(
        "GATE open=%s reason=%s Enabled=%s Mode=%s compiled_tarray_struct_get_set=%s",
        tostring(gate_open), tostring(gate_reason), tostring(Config.Enabled),
        tostring(Config.Mode), tostring(COMPILED_TARRAY_STRUCT_GET_SET)
    ))
    if not gate_open then
        log("OBSERVE_ONLY native_behavior=unchanged")
        return
    end

    apply(manager, list, count)
    schedule_monitor()
end

local discovery_elapsed_ms = 0

local function bootstrap_on_game_thread()
    assert_game_thread()
    if kill_file_present() then
        trip("global_kill_file_during_discovery")
        return
    end
    if type(Config.DiscoveryRetryMs) ~= "number"
        or Config.DiscoveryRetryMs < 100
        or Config.DiscoveryRetryMs % 1 ~= 0
        or type(Config.DiscoveryTimeoutMs) ~= "number"
        or Config.DiscoveryTimeoutMs < Config.DiscoveryRetryMs
        or Config.DiscoveryTimeoutMs % 1 ~= 0 then
        error("discovery_timing_invalid")
    end

    local managers = valid_instances("PalBaseCampManager")
    if #managers > 1 then
        error(string.format(
            "target_identity_ambiguous:managers=%d",
            #managers
        ))
    end
    if #managers == 1 then
        start_on_game_thread(managers[1])
        return
    end

    if discovery_elapsed_ms >= Config.DiscoveryTimeoutMs then
        error(string.format(
            "target_discovery_timeout:managers=%d",
            #managers
        ))
    end
    if discovery_elapsed_ms == 0 or discovery_elapsed_ms % 10000 == 0 then
        log(string.format(
            "WAIT target_discovery elapsed_ms=%d managers=%d",
            discovery_elapsed_ms, #managers
        ))
    end
    discovery_elapsed_ms = discovery_elapsed_ms + Config.DiscoveryRetryMs
    ExecuteInGameThreadWithDelay(Config.DiscoveryRetryMs, function()
        local ok, error_message = pcall(bootstrap_on_game_thread)
        if not ok then
            trip("discovery:" .. tostring(error_message))
        end
    end)
end

log(string.format(
    "START target_game=%s steam_build=%s ue4ss_tag=%s default_enabled=%s mode=%s",
    tostring(Config.ExpectedIdentity and Config.ExpectedIdentity.GameVersion),
    tostring(Config.ExpectedIdentity and Config.ExpectedIdentity.SteamBuildId),
    tostring(Config.ExpectedIdentity and Config.ExpectedIdentity.ReUe4ssLinuxTag),
    tostring(Config.Enabled), tostring(Config.Mode)
))

ExecuteInGameThread(function()
    local ok, error_message = pcall(bootstrap_on_game_thread)
    if not ok then
        trip("startup:" .. tostring(error_message))
    end
end)
