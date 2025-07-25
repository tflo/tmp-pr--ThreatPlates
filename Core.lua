﻿local _, Addon = ...
local t = Addon.ThreatPlates

---------------------------------------------------------------------------------------------------
-- Imported functions and constants
---------------------------------------------------------------------------------------------------

-- Lua APIs
local tonumber, pairs = tonumber, pairs

-- WoW APIs
local SetNamePlateFriendlyClickThrough = C_NamePlate.SetNamePlateFriendlyClickThrough
local SetNamePlateEnemyClickThrough = C_NamePlate.SetNamePlateEnemyClickThrough
local UnitName, IsInInstance, InCombatLockdown = UnitName, IsInInstance, InCombatLockdown
local GetCVar, IsAddOnLoaded = GetCVar, C_AddOns.IsAddOnLoaded
local C_NamePlate, Lerp =  C_NamePlate, Lerp
local C_Timer_After = C_Timer.After
local NamePlateDriverFrame = NamePlateDriverFrame
local GetSpecialization = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization or _G.GetSpecialization
local GetSpecializationInfo = C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo or _G.GetSpecializationInfo

-- ThreatPlates APIs
local TidyPlatesThreat = TidyPlatesThreat
local LibStub = LibStub
local L = Addon.ThreatPlates.L
local CVars = Addon.CVars

local _G =_G
-- Global vars/functions that we don't upvalue since they might get hooked, or upgraded
-- List them here for Mikk's FindGlobals script
-- GLOBALS: SetCVar

---------------------------------------------------------------------------------------------------
-- Local variables
---------------------------------------------------------------------------------------------------
local task_queue_ooc = {}
local LSMUpdateTimer

---------------------------------------------------------------------------------------------------
-- Functions different depending on WoW version
---------------------------------------------------------------------------------------------------

if Addon.WOW_USES_CLASSIC_NAMEPLATES then
  local function CalculateSynchedNameplateSize()
    local db = Addon.db.profile.settings
  
    local width = db.healthbar.width
    local height = db.healthbar.height
    if db.frame.SyncWithHealthbar then
      width = width + 6
      height = height + 22
    end

    -- Update values in settings, so that the options dialog (clickable area) shows the correct values
    db.frame.width = width
    db.frame.height = height
  
    return width, height
  end

  Addon.SetBaseNamePlateSize = function(self)
    local db = self.db.profile

    -- Classic has the same nameplate size for friendly and enemy units, so either set both or non at all (= set it to default values)
    if not db.ShowFriendlyBlizzardNameplates and not db.ShowEnemyBlizzardNameplates and not self.IsInPvEInstance then
      local width, height = CalculateSynchedNameplateSize()
      C_NamePlate.SetNamePlateFriendlySize(width, height)
      C_NamePlate.SetNamePlateEnemySize(width, height)
    else
      -- Smaller nameplates are not available in Classic
      C_NamePlate.SetNamePlateFriendlySize(128, 32)
      C_NamePlate.SetNamePlateEnemySize(128, 32)
    end

    Addon:ConfigClickableArea(false)
  end
else 
  local function CalculateSynchedNameplateSize(width_key, height_key)
    local width, height
    
    local db = Addon.db.profile.settings
    if db.frame.SyncWithHealthbar then
      -- This functions were interpolated from ratio of the clickable area and the Blizzard nameplate healthbar
      -- for various sizes
      width = db.healthbar[width_key] + 24.5
      height = (db.healthbar[height_key] + 11.4507) / 0.347764  
    else
      width = db.frame[width_key]
      height = db.frame[height_key]
    end
  
    -- Update values in settings, so that the options dialog (clickable area) shows the correct values
    db.frame[width_key] = width
    db.frame[height_key] = height

    return width, height
  end

  local function CalculateSynchedNameplateSizeForEnemy()
    return CalculateSynchedNameplateSize("width", "height")
  end

  local function CalculateSynchedNameplateSizeForFriend()
    return CalculateSynchedNameplateSize("widthFriend", "heightFriend")
  end

  local function SetNameplatesToDefaultSize(nameplate_size_func)
    if NamePlateDriverFrame:IsUsingLargerNamePlateStyle() then
      nameplate_size_func(154, 64)
    else
      nameplate_size_func(110, 45)
    end
  end

  Addon.SetBaseNamePlateSize = function(self)
    local db = self.db.profile

    if db.ShowFriendlyBlizzardNameplates or self.IsInPvEInstance then
      if CVars:GetAsBool("nameplateShowOnlyNames") then
        -- The clickable area of friendly nameplates will be set to zero so that they don't interfere with enemy nameplates stacking (not in Classic or TBC Classic).
        C_NamePlate.SetNamePlateFriendlySize(0.1, 0.1)    
      else
        SetNameplatesToDefaultSize(C_NamePlate.SetNamePlateFriendlySize)
      end
    else
      local width, height = CalculateSynchedNameplateSizeForFriend()
      C_NamePlate.SetNamePlateFriendlySize(width, height)
    end

    if db.ShowEnemyBlizzardNameplates then
      SetNameplatesToDefaultSize(C_NamePlate.SetNamePlateEnemySize)
    else
      local width, height = CalculateSynchedNameplateSizeForEnemy()
      C_NamePlate.SetNamePlateEnemySize(width, height)
    end
  
    Addon:ConfigClickableArea(false)

    -- For personal nameplate:
    --local clampedZeroBasedScale = Saturate(zeroBasedScale)
    --C_NamePlate_SetNamePlateSelfSize(baseWidth * horizontalScale * Lerp(1.1, 1.0, clampedZeroBasedScale), baseHeight)
  end
end

---------------------------------------------------------------------------------------------------
-- Global configs and funtions
---------------------------------------------------------------------------------------------------

local tankRole = L["|cff00ff00tanking|r"]
local dpsRole = L["|cffff0000dpsing / healing|r"]

function Addon:RoleText()
  if Addon:PlayerRoleIsTank() then
    return tankRole
  else
    return dpsRole
  end
end

local EVENTS = {
  --"PLAYER_ALIVE",
  --"PLAYER_LEAVING_WORLD",
  --"PLAYER_TALENT_UPDATE"

  "PLAYER_ENTERING_WORLD",
  "PLAYER_MAP_CHANGED",
  --"PLAYER_LOGIN",
  --"PLAYER_LOGOUT",
  "PLAYER_REGEN_ENABLED",
  "PLAYER_REGEN_DISABLED",

  -- CVAR_UPDATE,
  -- DISPLAY_SIZE_CHANGED,     -- Blizzard also uses this event
  -- VARIABLES_LOADED,         -- Blizzard also uses this event

  -- Events from TidyPlates

  -- NAME_PLATE_CREATED
  -- NAME_PLATE_UNIT_ADDED
  -- UNIT_NAME_UPDATE
  -- NAME_PLATE_UNIT_REMOVED

  -- PLAYER_TARGET_CHANGED
  -- UPDATE_MOUSEOVER_UNIT

  -- UNIT_HEALTH_FREQUENT
  -- UNIT_MAXHEALTH,
  -- UNIT_ABSORB_AMOUNT_CHANGED,

  -- PLAYER_REGEN_ENABLED
  -- PLAYER_REGEN_DISABLED

  -- UNIT_SPELLCAST_START
  -- UNIT_SPELLCAST_STOP
  -- UNIT_SPELLCAST_CHANNEL_START
  -- UNIT_SPELLCAST_CHANNEL_STOP
  -- UNIT_SPELLCAST_DELAYED
  -- UNIT_SPELLCAST_CHANNEL_UPDATE
  -- UNIT_SPELLCAST_INTERRUPTIBLE
  -- UNIT_SPELLCAST_NOT_INTERRUPTIBLE

  -- UI_SCALE_CHANGED
  -- COMBAT_LOG_EVENT_UNFILTERED
  -- UNIT_LEVEL
  -- UNIT_FACTION
  -- RAID_TARGET_UPDATE
  -- PLAYER_FOCUS_CHANGED
  -- PLAYER_CONTROL_GAINED
}

local function EnableEvents()
  for i = 1, #EVENTS do
    Addon:RegisterEvent(TidyPlatesThreat, EVENTS[i])
  end
end

local function DisableEvents()
  for i = 1, #EVENTS do
    Addon:UnregisterEvent(TidyPlatesThreat, EVENTS[i])
  end
end

---------------------------------------------------------------------------------------------------
-- Functions called by TidyPlates
---------------------------------------------------------------------------------------------------

------------------
-- ADDON LOADED --
------------------

StaticPopupDialogs["TidyPlatesEnabled"] = {
  preferredIndex = STATICPOPUP_NUMDIALOGS,
  text = "|cffFFA500" .. t.Meta("title") .. " Warning|r \n---------------------------------------\n" ..
    L["|cff89F559Threat Plates|r is no longer a theme of |cff89F559TidyPlates|r, but a standalone addon that does no longer require TidyPlates. Please disable one of these, otherwise two overlapping nameplates will be shown for units."],
  button1 = OKAY,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  OnAccept = function(self, _, _) end,
}

StaticPopupDialogs["IncompatibleAddon"] = {
  preferredIndex = STATICPOPUP_NUMDIALOGS,
  text = "|cffFFA500" .. t.Meta("title") .. " Warning|r \n---------------------------------------\n" ..
    L["You currently have two nameplate addons enabled: |cff89F559Threat Plates|r and |cff89F559%s|r. Please disable one of these, otherwise two overlapping nameplates will be shown for units."],
  button1 = OKAY,
  button2 = L["Don't Ask Again"],
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  OnAccept = function(self, _, _) end,
  OnCancel = function(self, _, _)
    Addon.db.profile.CheckForIncompatibleAddons = false
  end,
}

function Addon:ReloadTheme()
  -- Castbars have to be disabled everytime we login
  if Addon.db.profile.settings.castbar.show or Addon.db.profile.settings.castbar.ShowInHeadlineView then
    Addon:EnableCastBars()
  else
    Addon:DisableCastBars()
  end

  -- Recreate all TidyPlates styles for ThreatPlates("normal", "dps", "tank", ...) - required, if theme style settings were changed
  Addon:SetThemes()
  Addon:UpdateConfigurationStatusText()
  Addon:InitializeCustomNameplates()
  Addon:InitializeIconTextures()
  Addon.Widgets:InitializeAllWidgets()

  -- Update existing nameplates as certain settings may have changed that are not covered by ForceUpdate()
  Addon:UIScaleChanged()

  -- Do this after combat ends, not in PLAYER_ENTERING_WORLD as it won't get set if the player is on combat when
  -- that event fires.
  Addon:CallbackWhenOoC(function() Addon:SetBaseNamePlateSize() end, L["Unable to change a setting while in combat."])
  Addon:CallbackWhenOoC(function()
    local db = Addon.db.profile
    SetNamePlateFriendlyClickThrough(db.NamePlateFriendlyClickThrough)
    SetNamePlateEnemyClickThrough(db.NamePlateEnemyClickThrough)
  end)

  -- CVars setup for nameplates of occluded units
  if Addon.db.profile.nameplate.toggle.OccludedUnits then
    Addon:CallbackWhenOoC(function()
      Addon:SetCVarsForOcclusionDetection()
    end)
  end

  for plate, unitid in pairs(Addon.PlatesVisible) do
    Addon.SetNameplateVisibility(plate, unitid)
  end

  Addon:ForceUpdate()
end

function Addon:CheckForFirstStartUp()
  local db = Addon.db.global

  if not Addon.db.char.welcome then
    Addon.db.char.welcome = true

    -- GetNumSpecializations: Mists - Patch 5.0.4 (2012-08-28): Replaced GetNumTalentTabs.
    if Addon.ExpansionIsAtLeastMists then
      -- initialize roles for all available specs (level > 10) or set to default (dps/healing)
      for index=1, GetNumSpecializations() do
        local id, spec_name, description, icon, background, role = GetSpecializationInfo(index)
        Addon:SetRole(t.SPEC_ROLES[Addon.PlayerClass][index], index)
      end
    end

    local new_version = tostring(t.Meta("version"))
    if db.version ~= "" and db.version ~= new_version then
      -- migrate and/or remove any old DB entries
      t.MigrateDatabase(db.version)
    end
    db.version = new_version
  else
    local new_version = tostring(t.Meta("version"))
    if db.version ~= "" and db.version ~= new_version then
      -- migrate and/or remove any old DB entries
      t.MigrateDatabase(db.version)
    end
    db.version = new_version
  end

  --t.MigrateDatabase(db.version)
end

function Addon:CheckForIncompatibleAddons()
  -- Check for other active nameplate addons which may create all kinds of errors and doesn't make
  -- sense anyway:
  if Addon.db.profile.CheckForIncompatibleAddons then
    if IsAddOnLoaded("TidyPlates") then
      StaticPopup_Show("TidyPlatesEnabled", "TidyPlates")
    end
    if IsAddOnLoaded("Kui_Nameplates") then
      StaticPopup_Show("IncompatibleAddon", "KuiNameplates")
    end
    if IsAddOnLoaded("ElvUI") and ElvUI[1] and ElvUI[1].private and ElvUI[1].private.nameplates and ElvUI[1].private.nameplates.enable then
    --if IsAddOnLoaded("ElvUI") and ElvUI[1].private.nameplates.enable then
      StaticPopup_Show("IncompatibleAddon", "ElvUI Nameplates")
    end
    if IsAddOnLoaded("Plater") then
      StaticPopup_Show("IncompatibleAddon", "Plater Nameplates")
    end
    if IsAddOnLoaded("SpartanUI") and SUI.IsModuleEnabled and SUI:IsModuleEnabled("Nameplates") then
      StaticPopup_Show("IncompatibleAddon", "SpartanUI Nameplates")
    end
  end
end

---------------------------------------------------------------------------------------------------
-- AceAddon functions: do init tasks here, like loading the Saved Variables, or setting up slash commands.
---------------------------------------------------------------------------------------------------

-- The OnInitialize() method of your addon object is called by AceAddon when the addon is first loaded
-- by the game client. It's a good time to do things like restore saved settings (see the info on
-- AceConfig for more notes about that).
function TidyPlatesThreat:OnInitialize()
  local defaults = t.DEFAULT_SETTINGS

  -- change back defaults old settings if wanted preserved it the user want's to switch back
  if ThreatPlatesDB and ThreatPlatesDB.global and ThreatPlatesDB.global.DefaultsVersion == "CLASSIC" then
    -- copy default settings, so that their original values are
    defaults = t.GetDefaultSettingsV1(defaults)
  end

  local db = LibStub('AceDB-3.0'):New('ThreatPlatesDB', defaults, 'Default')
  Addon.db = db

  Addon.LibAceConfigDialog = LibStub("AceConfigDialog-3.0")
  Addon.LibAceConfigRegistry = LibStub("AceConfigRegistry-3.0")
  Addon.LibSharedMedia = LibStub("LibSharedMedia-3.0")
  Addon.LibCustomGlow = LibStub("LibCustomGlow-1.0")

  Addon.LoadOnDemandLibraries()

  local RegisterCallback = db.RegisterCallback
  RegisterCallback(Addon, 'OnProfileChanged', 'ProfChange')
  RegisterCallback(Addon, 'OnProfileCopied', 'ProfChange')
  RegisterCallback(Addon, 'OnProfileReset', 'ProfChange')

  -- Setup Interface panel options
  local app_name = t.ADDON_NAME
  local dialog_name = app_name .. " Dialog"
  LibStub("AceConfig-3.0"):RegisterOptionsTable(dialog_name, t.GetInterfaceOptionsTable())
  Addon.LibAceConfigDialog:AddToBlizOptions(dialog_name, t.ADDON_NAME)

  -- Setup chat commands
  self:RegisterChatCommand("tptp", "ChatCommand")

  Addon.CVars:Initialize()
end

-- The OnEnable() and OnDisable() methods of your addon object are called by AceAddon when your addon is
-- enabled/disabled by the user. Unlike OnInitialize(), this may occur multiple times without the entire
-- UI being reloaded.
-- AceAddon function: Do more initialization here, that really enables the use of your addon.
-- Register Events, Hook functions, Create Frames, Get information from the game that wasn't available in OnInitialize
function TidyPlatesThreat:OnEnable()
  Addon:CheckForFirstStartUp()
  Addon:CheckForIncompatibleAddons()

  if not Addon.WOW_USES_CLASSIC_NAMEPLATES then
    CVars:OverwriteBool("nameplateResourceOnTarget", Addon.db.profile.PersonalNameplate.ShowResourceOnTarget)
  end

  Addon.LoadOnDemandLibraries()

  Addon:ReloadTheme()

  -- Register callbacks at LSM, so that we can refresh everything if additional media is added after TP is loaded
  -- Register this callback after ReloadTheme as media will be updated there anyway
  Addon.LibSharedMedia.RegisterCallback(Addon, "LibSharedMedia_SetGlobal", "MediaUpdate" )
  Addon.LibSharedMedia.RegisterCallback(Addon, "LibSharedMedia_Registered", "MediaUpdate" )

  EnableEvents()
end

-- Called when the addon is disabled
function TidyPlatesThreat:OnDisable()
  DisableEvents()

  -- Reset all CVars to its initial values
  -- CVars:RestoreAllFromProfile()
end

function Addon:CallbackWhenOoC(func, msg)
  if InCombatLockdown() then
    if msg then
      Addon.Logging.Warning(msg .. L[" The change will be applied after you leave combat."])
    end
    task_queue_ooc[#task_queue_ooc + 1] = func
  else
    func()
  end
end

-- Register callbacks at LSM, so that we can refresh everything if additional media is added after TP is loaded
function Addon.MediaUpdate(addon_name, name, mediatype, key)
  if mediatype ~= Addon.LibSharedMedia.MediaType.SOUND and not LSMUpdateTimer then
    LSMUpdateTimer = true

    -- Delay the update for one second to avoid firering this several times when multiple media are registered by another addon
    C_Timer_After(1, function()
      LSMUpdateTimer = nil
      -- Basically, ReloadTheme but without CVar and some other stuff
      Addon:SetThemes()
      -- no media used: Addon:UpdateConfigurationStatusText()
      -- no media used: Addon:InitializeCustomNameplates()
      Addon.Widgets:InitializeAllWidgets()
      Addon:ForceUpdate()
    end)
  end
end

-----------------------------------------------------------------------------------
-- Functions for keybindings and addon compartment
-----------------------------------------------------------------------------------

function TidyPlatesThreat:ToggleNameplateModeFriendlyUnits()
  local db = Addon.db.profile

  db.Visibility.FriendlyPlayer.UseHeadlineView = not db.Visibility.FriendlyPlayer.UseHeadlineView
  db.Visibility.FriendlyNPC.UseHeadlineView = not db.Visibility.FriendlyNPC.UseHeadlineView
  -- db.Visibility.FriendlyMinion.UseHeadlineView = not db.Visibility.FriendlyTotem.UseHeadlineView
  db.Visibility.FriendlyPet.UseHeadlineView = not db.Visibility.FriendlyPet.UseHeadlineView
  db.Visibility.FriendlyGuardian.UseHeadlineView = not db.Visibility.FriendlyGuardian.UseHeadlineView
  db.Visibility.FriendlyTotem.UseHeadlineView = not db.Visibility.FriendlyTotem.UseHeadlineView
  db.Visibility.FriendlyMinus.UseHeadlineView = not db.Visibility.FriendlyMinus.UseHeadlineView

  Addon:ForceUpdate()
end

function TidyPlatesThreat:ToggleNameplateModeNeutralUnits()
  local db = Addon.db.profile

  db.Visibility.NeutralNPC.UseHeadlineView = not db.Visibility.NeutralNPC.UseHeadlineView
  db.Visibility.NeutralMinus.UseHeadlineView = not db.Visibility.NeutralMinus.UseHeadlineView

  Addon:ForceUpdate()
end

function TidyPlatesThreat:ToggleNameplateModeEnemyUnits()
  local db = Addon.db.profile

  db.Visibility.EnemyPlayer.UseHeadlineView = not db.Visibility.EnemyPlayer.UseHeadlineView
  db.Visibility.EnemyNPC.UseHeadlineView = not db.Visibility.EnemyNPC.UseHeadlineView
  -- db.Visibility.EnemyMinion.UseHeadlineView = not db.Visibility.EnemyPet.UseHeadlineView
  db.Visibility.EnemyPet.UseHeadlineView = not db.Visibility.EnemyPet.UseHeadlineView
  db.Visibility.EnemyGuardian.UseHeadlineView = not db.Visibility.EnemyGuardian.UseHeadlineView
  db.Visibility.EnemyTotem.UseHeadlineView = not db.Visibility.EnemyTotem.UseHeadlineView
  db.Visibility.EnemyMinus.UseHeadlineView = not db.Visibility.EnemyMinus.UseHeadlineView

  Addon:ForceUpdate()
end

function TidyPlatesThreat_OnAddonCompartmentClick(addonName, buttonName)
  -- addonName: TidyPlates_ThreatPlates (name of directory)
  Addon:OpenOptions()
end

-----------------------------------------------------------------------------------
-- WoW EVENTS --
-----------------------------------------------------------------------------------

-- Fired when the player enters the world, reloads the UI, enters/leaves an instance or battleground, or respawns at a graveyard.
-- Also fires any other time the player sees a loading screen
function TidyPlatesThreat:PLAYER_ENTERING_WORLD()
  local db = Addon.db.profile.Automation
  local isInstance, instance_type = IsInInstance()

  --Addon.IsInInstance = isInstance
  Addon.IsInPvEInstance = isInstance and (instance_type == "party" or instance_type == "raid")
  Addon.IsInPvPInstance = isInstance and (instance_type == "arena" or instance_type == "pvp")

  if db.ShowFriendlyUnitsInInstances then
    if Addon.IsInPvEInstance then
      CVars:Set("nameplateShowFriends", 1)
    else
      -- Restore the value from before entering the instance
      CVars:RestoreFromProfile("nameplateShowFriends")
    end
  elseif db.HideFriendlyUnitsInInstances then
    if Addon.IsInPvEInstance then  
      CVars:Set("nameplateShowFriends", 0)
    else
      -- Restore the value from before entering the instance
      CVars:RestoreFromProfile("nameplateShowFriends")
    end
  end

  if Addon.db.profile.BlizzardSettings.Names.ShowPlayersInInstances then
    if Addon.IsInPvEInstance then  
      CVars:Set("UnitNameFriendlyPlayerName", 1)
      -- CVars:Set("UnitNameFriendlyPetName", 1)
      -- CVars:Set("UnitNameFriendlyGuardianName", 1)
      CVars:Set("UnitNameFriendlyTotemName", 1)
      -- CVars:Set("UnitNameFriendlyMinionName", 1)
    else
      -- Restore the value from before entering the instance
      CVars:RestoreFromProfile("UnitNameFriendlyPlayerName")
      -- CVars:RestoreFromProfile("UnitNameFriendlyPetName")
      -- CVars:RestoreFromProfile("UnitNameFriendlyGuardianName")
      CVars:RestoreFromProfile("UnitNameFriendlyTotemName")
      -- CVars:RestoreFromProfile("UnitNameFriendlyMinionName")
    end  
  end

  -- Update custom styles for the current instance
  Addon.UpdateStylesForCurrentInstance()

  -- Adjust clickable area if we are in an instance. Otherwise the scaling of friendly nameplates' healthbars will
  -- be bugged
  Addon:SetBaseNamePlateSize()
  Addon.Font:SetNamesFonts()
end

-- Instances without PLAYER_ENTERING_WORLD event on enter (or leave), hence "walk-in".
-- Currently only delves; possibly there are more.
-- To avoid redundant calls, make sure to only add instance IDs here that do not trigger the PLAYER_ENTERING_WORLD event.
local WalkInInstances = {
  -- Delves
  ["2664"] = true, -- Fungal Folly
  ["2679"] = true, -- Mycomancer Cavern
  ["2680"] = true, -- Earthcrawl Mines
  ["2681"] = true, -- Kriegval's Rest
  ["2682"] = true, -- Zekvir's Lair ; TODO: check this one, if it behaves like the others
  ["2683"] = true, -- The Waterworks
  ["2684"] = true, -- The Dread Pit
  ["2685"] = true, -- Skittering Breach
  ["2686"] = true, -- Nightfall Sanctum
  ["2687"] = true, -- The Sinkhole
  ["2688"] = true, -- The Spiral Weave
  ["2689"] = true, -- Tak-Rethan Abyss
  ["2690"] = true, -- The Underkeep
  ["2767"] = true, -- The Sinkhole
  ["2768"] = true, -- Tak-Rethan Abyss
  ["2815"] = true, -- Excavation Site 9
  ["2826"] = true, -- Sidestreet Sluice
  ["2836"] = true, -- Earthcrawl Mines
}

function TidyPlatesThreat:PLAYER_MAP_CHANGED(_, previousID, currentID)
  if WalkInInstances[tostring(currentID)] or WalkInInstances[tostring(previousID)] then
    -- The event fires very early, too early for GetInstanceInfo to retrieve the new ID.
    -- A delay of `0` (aka next frame) seems to be enough in *many* cases, but sometimes not;
    -- no idea what this depends on (server lag?); so using a delay like 1 or 3s is probably better.
    -- A too long delay might cause trouble if the player starts combat immediately after entering/leaving the instance.
    -- Note: Instead of delaying, we could also pass the ID as argument, but this would require various changes down the line.
    C_Timer.After(3, TidyPlatesThreat.PLAYER_ENTERING_WORLD)
  end
end

--function TidyPlatesThreat:PLAYER_LEAVING_WORLD()
--end

-- function TidyPlatesThreat:PLAYER_LOGIN(...)
-- end

--function TidyPlatesThreat:PLAYER_LOGOUT(...)
--end

-- Fires when the player leaves combat status
-- Syncs addon settings with game settings in case changes weren't possible during startup, reload
-- or profile reset because character was in combat.
function TidyPlatesThreat:PLAYER_REGEN_ENABLED()
  -- Execute functions which will fail when executed while in combat
  for i = #task_queue_ooc, 1, -1 do -- add -1 so that an empty list does not result in a Lua error
    task_queue_ooc[i]()
    task_queue_ooc[i] = nil
  end

  local db = Addon.db.profile.Automation
  local isInstance, _ = IsInInstance()

  -- Dont't use automation for friendly nameplates if in an instance and Hide Friendly Nameplates is enabled
  if db.FriendlyUnits ~= "NONE" and not (isInstance and db.HideFriendlyUnitsInInstances) then
    _G.SetCVar("nameplateShowFriends", (db.FriendlyUnits == "SHOW_COMBAT" and 0) or 1)
  end
  if db.EnemyUnits ~= "NONE" then
    _G.SetCVar("nameplateShowEnemies", (db.EnemyUnits == "SHOW_COMBAT" and 0) or 1)
  end
end

-- Fires when the player enters combat status
function TidyPlatesThreat:PLAYER_REGEN_DISABLED()
  local db = Addon.db.profile.Automation
  local isInstance, _ = IsInInstance()

  -- Dont't use automation for friendly nameplates if in an instance and Hide Friendly Nameplates is enabled
  if db.FriendlyUnits ~= "NONE" and not (isInstance and db.HideFriendlyUnitsInInstances) then
    _G.SetCVar("nameplateShowFriends", (db.FriendlyUnits == "SHOW_COMBAT" and 1) or 0)
  end
  if db.EnemyUnits ~= "NONE" then
    _G.SetCVar("nameplateShowEnemies", (db.EnemyUnits == "SHOW_COMBAT" and 1) or 0)
  end
end
