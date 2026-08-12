-- ASEAN Motor Club — Project Zomboid spawn regions.
-- Single spawn town: Muldraugh. The full Build 42 map is still loaded (Map= is
-- left at the server default), so the whole world is reachable — players just
-- start in Muldraugh.
-- Copied (no-clobber) to <servername>_spawnregions.lua on first boot.
--
-- NOTE: must define the SpawnRegions() function (not a bare return) — the game
-- calls SpawnRegionMgr.loadSpawnRegions(SpawnRegions()) at startup, so a top-level
-- `return {}` leaves SpawnRegions nil and throws "Object tried to call nil".
-- The file must point at the map directory's spawnpoints.lua (B42 path).
function SpawnRegions()
  return {
    {
      file = "media/maps/Muldraugh, KY/spawnpoints.lua",
      name = "Muldraugh, KY",
    },
  }
end
