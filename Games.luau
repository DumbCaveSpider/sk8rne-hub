-- Registry of supported games. A game matches on its root place id or its universe id, so
-- sub-places of the same experience (lobbies, matches, levels) are detected too.

local Games = {}

Games.List = {
	{ Key = "CriminalSimulator", Name = "Criminal Simulator", Icon = "Lucide:skull", PlaceId = 83048653078891, UniverseId = 10769851460 },
	{ Key = "DashWorld", Name = "Dash World", Icon = "Lucide:rocket", PlaceId = 80607040330429, UniverseId = 7877723741 },
	{ Key = "DontSplash", Name = "DONT SPLASH", Icon = "Lucide:droplets", PlaceId = 119958473240233, UniverseId = 10771421858 },
	{ Key = "Enfosi", Name = "Enfosi", Icon = "Lucide:swords", PlaceId = 78353262320982, UniverseId = 7882785167 },
	{ Key = "Linglox", Name = "Linglox", Icon = "Lucide:gamepad-2", PlaceId = 18596298095, UniverseId = 6301368885 },
	{ Key = "PhoneEmpire", Name = "Build a Phone Empire", Icon = "Lucide:smartphone", PlaceId = 101914705206759, UniverseId = 10767582899 },
	{ Key = "Prospecting", Name = "Prospecting", Icon = "Lucide:pickaxe", PlaceId = 129827112113663, UniverseId = 7629331599 },
	{ Key = "Regretevator", Name = "Regretevator", Icon = "Lucide:arrow-up-down", PlaceId = 4972273297, UniverseId = 1709917610 },
	{ Key = "SomethingEvil", Name = "something evil will happen", Icon = "Lucide:ghost", PlaceId = 16991287194, UniverseId = 5829613337 },
	{ Key = "StorageHunters", Name = "Storage Hunters Open World", Icon = "Lucide:warehouse", PlaceId = 98800969324557, UniverseId = 10261267004 },
	{ Key = "MillionMonkeys", Name = "Survive a Million Monkeys", Icon = "Lucide:banana", PlaceId = 99409088950210, UniverseId = 10673920146 },
	{ Key = "TradingTycoon", Name = "Trading Tycoon", Icon = "Lucide:trending-up", PlaceId = 112241277471797, UniverseId = 10767912502 },
	{ Key = "UnseenLiminality", Name = "Unseen Liminality", Icon = "Lucide:camera", PlaceId = 82797688803922, UniverseId = 9885372266 },
	{ Key = "CombatInitiation", Name = "Combat Initiation", Icon = "Lucide:crosshair", PlaceId = 13559635034, UniverseId = 4712126054 },
	{ Key = "ThePortal", Name = "The Portal", Icon = "Lucide:orbit", PlaceId = 122003435349029, UniverseId = 9356969539 },
	{ Key = "KayoSports",Name = "Kayo Sports", Icon = "Lucide:trophy", PlaceId = 134767568300039, UniverseId = 10097848588 },
}

-- Stop functions the old standalone scripts left in getgenv(), called once before the hub starts.
Games.LegacyStops = {
	"__CriminalCleanup",
	"__DashWorld_Unload",
	"__KayoScript_Stop",
	"__Luminality_Unload",
	"__SHP_STOP",
	"PhoneTycoonAutoStop",
}

function Games.Detect(placeId, universeId)
	for _, def in ipairs(Games.List) do
		if def.PlaceId == placeId or def.UniverseId == universeId then
			return def
		end
	end
	return nil
end

return Games
