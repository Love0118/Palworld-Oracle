-- AwayBaseLab configuration for the one supported disposable-lab target.
-- This file describes candidates. It does not authorize or perform writes.

return {
    SchemaVersion = 1,
    Mode = "OBSERVE_ONLY",
    ObserveIntervalMs = 60000,

    ExpectedIdentity = {
        GameVersion = "1.0.1.100619",
        SteamBuildId = "24181105",
        PalServerSha256 = "788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7",
        PalServerElfBuildId = "7f7e167407984ec3",
        ReUe4ssLinuxVersion = "linux-v0.1.0",
        ReUe4ssSourceCommit = "5d33654755efed844336497e8a9a15e6716b5d6c",
    },

    Candidate = {
        MergeDropItemRangeCm = 500.0,
        Middle = {
            TickIntervalSec = 3.0,
            bMergeDropItems = true,
            bUpdateSimple = false,
        },
        Far = {
            TickIntervalSec = 7.5,
            bMergeDropItems = true,
            bUpdateSimple = true,
        },
        AwayGraceSec = 60.0,
        WakeHysteresisSec = 5.0,
    },

    Safety = {
        -- Prefer an absolute path supplied by AWAY_BASE_LAB_GLOBAL_KILL_SWITCH.
        GlobalKillSwitchFile = "Mods/AwayBaseLab/GLOBAL_KILL_SWITCH",
        OperatorAckFile = "Mods/AwayBaseLab/ACK_MUTATION_RISK",
        OperatorAckPhrase = "I_ACCEPT_AWAY_BASE_LAB_MUTATION_RISK",
        EnvironmentAckName = "AWAY_BASE_LAB_MUTATION_ACK",
        EnvironmentAckPhrase = "I_ACCEPT_EXPERIMENTAL_MUTATION",

        -- Both remain false in this scaffold. Nested TArray<struct> write/restore
        -- semantics have not been proved on the pinned Linux runtime.
        MutationRequested = false,
        NestedStructWriteVerified = false,
    },
}
