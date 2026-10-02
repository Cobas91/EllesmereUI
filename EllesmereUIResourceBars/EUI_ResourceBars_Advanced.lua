if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if EUI_ClassicEnv then setfenv(1, EUI_ClassicEnv) end -- Classic Era port: suite-private API stand-ins (EllesmereUI_ClassicCompat.lua)
-- Removed: the Resource Bars Advanced per-spec mode was retired in favor of
-- the shared Spec Overrides system (spec groups + editing-as). Legacy
-- advancedSpecs data migrates via EllesmereUI.MigrateRBAdvancedProfile
-- (EllesmereUI_Migration.lua) and survives in rb.advancedSpecsBackup.
-- This file is no longer referenced by the TOC and is safe to delete.
