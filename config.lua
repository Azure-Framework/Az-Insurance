Config = Config or {}

-- Master debug toggle
Config.Debug = true

-- Premium will be charged every X minutes (simulating "monthly" while in-game)
Config.PremiumIntervalMinutes = 10

-- Base premium & deductible – used as a baseline for plan multipliers
Config.DefaultPremium    = 250   -- base premium
Config.DefaultDeductible = 1000  -- fallback deductible

-- Where the replacement vehicle spawns, relative to player position
Config.ClaimSpawnOffset = vector3(0.0, 5.0, 0.0)

-- Command to open insurance UI
Config.OpenCommand = 'insurance'

-- 🔧 Policy plans (server + UI)
-- premiumMultiplier * DefaultPremium = actual premium stored on policy
-- deductible is charged when filing a claim (0 for full coverage)
Config.PolicyTypes = {
    basic = {
        label             = "Basic coverage",
        description       = "Cheapest plan with high deductible.",
        premiumMultiplier = 0.6,
        deductible        = 2000
    },
    standard = {
        label             = "Standard coverage",
        description       = "Balanced premium and deductible.",
        premiumMultiplier = 1.0,
        deductible        = 1000
    },
    full = {
        label             = "Full coverage",
        description       = "0 deductible theft replacement. Highest premium.",
        premiumMultiplier = 1.8,
        deductible        = 0
    }
}
