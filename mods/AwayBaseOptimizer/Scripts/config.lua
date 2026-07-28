-- AwayBaseOptimizer is intentionally inert until every apply gate is explicit.
-- First enable the mod only in OBSERVE_ONLY mode, copy the live tier dump, then
-- fill in the zero/empty tier selectors below from that exact server build.

return {
    SchemaVersion = 1,
    Enabled = false,
    Mode = "OBSERVE_ONLY", -- OBSERVE_ONLY or APPLY
    MonitorIntervalMs = 1000,
    DiscoveryRetryMs = 1000,
    DiscoveryTimeoutMs = 300000,

    ExpectedIdentity = {
        GameVersion = "1.0.1.100619",
        SteamBuildId = "24181105",
        PalServerSha256 = "788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7",
        PalServerElfBuildId = "7f7e167407984ec3",
        ReUe4ssLinuxTag = "linux-v0.1.0",
        ReUe4ssSourceCommit = "5d33654755efed844336497e8a9a15e6716b5d6c",
        ReUe4ssApiVersion = { 3, 0, 1 },
    },

    -- These must be supplied by the launch environment. A config-file claim is
    -- not accepted as runtime identity evidence.
    IdentityEnvironment = {
        PALWORLD_GAME_VERSION = "1.0.1.100619",
        PALWORLD_STEAM_BUILD_ID = "24181105",
        PALSERVER_SHA256 = "788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7",
        PALSERVER_ELF_BUILD_ID = "7f7e167407984ec3",
        RE_UE4SS_LINUX_TAG = "linux-v0.1.0",
        RE_UE4SS_SOURCE_COMMIT = "5d33654755efed844336497e8a9a15e6716b5d6c",
    },

    -- Two independent, exact-string acknowledgements. Leave both empty until
    -- the observe-only dump and a cold backup have been reviewed.
    Acknowledgements = {
        ExactBuildAndTierMap = "",
        MutationAndRollbackRisk = "",
    },

    Safety = {
        -- Prefer an absolute path through AWAY_BASE_OPTIMIZER_GLOBAL_KILL_FILE.
        GlobalKillFile = "Mods/AwayBaseOptimizer/GLOBAL_KILL_SWITCH",
    },

    Target = {
        -- Copy the exact manager full name from the observe-only log.
        ManagerFullName = "",
    },

    TierSelection = {
        -- Deliberately invalid defaults: never infer distance tiers by position.
        ExpectedCount = 0,
        DistanceOrder = "", -- ASCENDING or DESCENDING
        MiddleIndex = 0,     -- UE4SS TArray Lua index is 1-based
        FarIndex = 0,
        ExpectedMiddleDistanceCm = 0.0,
        ExpectedFarDistanceCm = 0.0,
    },

    Values = {
        MiddleTickIntervalSec = 3.0,
        FarTickIntervalSec = 7.5,
    },
}
