require "behaviours/wander"
require "behaviours/follow"
require "behaviours/faceentity"
require "behaviours/chaseandattack"
require "behaviours/runaway"
require "behaviours/doaction"
require "behaviours/findlight"
require "behaviours/panic"
require "behaviours/chattynode"
require "behaviours/leash"

local MIN_SEARCH_DISTANCE = 15
local MAX_SEARCH_DISTANCE = 100
local SEARCH_SIZE_STEP = 5

-- The order in which we prioritize things to build
-- Stuff to be collected should follow the priority of the build order
-- Have things to build once, build many times, etc
-- Denote if we should always keep spare items (to build fire, etc)
local BUILD_PRIORITY = {}

-- What to gather. This is a simple FIFO. Highest priority will be first in the list.
local GATHER_LIST = {}
local function addToGatherList(_name, _prefab, _number)
	-- Group by name only. If we get a request to add something to the table with the same name and prefab type,
	-- ignore it
	for k,v in pairs(GATHER_LIST) do
		if v.prefab == _prefab and v.name == "name" then
			return
		end
	end
	
	-- New request for this thing. Add it. 
	local value = {name = _name, prefab = _prefab, number = _number}
	table.insert(GATHER_LIST,value)
end

-- Decrement from the FIRST prefab that matches this amount regardless of name
local function decrementFromGatherList(_prefab,_number)
	for k,v in pairs(GATHER_LIST) do
		if v.prefab == _prefab then
			v.number = v.number - _number
			if v.number <= 0 then
				GATHER_LIST[k] = nil
			end
			return
		end
	end
end

local function addRecipeToGatherList(thingToBuild, addFullRecipe)
	local recipe = GetRecipe(thingToBuild)
    if recipe then
		local player = GetPlayer()
        for ik, iv in pairs(recipe.ingredients) do
			-- TODO: This will add the entire recipe. Should modify based on current inventory
			if addFullRecipe then
				print("Adding " .. iv.amount .. " " .. iv.type .. " to GATHER_LIST")
				addToGatherList(iv.type,iv.amount)
			else
				-- Subtract what we already have
				-- TODO subtract what we can make as well... (man, this is complicated)
				local hasEnough = false
				local numHas = 0
				hasEnough, numHas = player.components.inventory:Has(iv.type,iv.amount)
				if not hasEnough then
					print("Adding " .. tostring(iv.amount-numHas) .. " " .. iv.type .. " to GATHER_LIST")
					addToGatherList(iv.type,iv.amount-numHas)
				end
			end
		end
    end
end

-- Makes sure we have the right tech level.
-- If we don't have a resource, checks to see if we can craft it/them
-- If we can craft all necessary resources to build something, returns true
-- else, returns false
-- Do not set recursive variable, it will be set on recursive calls
local itemsNeeded = {}
local function CanIBuildThis(player, thingToBuild, numToBuild, recursive)

	-- Reset the table
	if recursive == nil then 
		for k,v in pairs(itemsNeeded) do itemsNeeded[k]=nil end
		recursive = 0
	end
	
	if numToBuild == nil then numToBuild = 1 end
	
	local recipe = GetRecipe(thingToBuild)
	
	-- Not a real thing so we can't possibly build this
	if not recipe then 
		print(thingToBuild .. " is not buildable :(")
		return false 
	end
	
	-- Quick check, do we know how to build this thing?
	if not player.components.builder:KnowsRecipe(thingToBuild) then 
		print("We don't know how to build " .. thingToBuild .. " :(")
		return false 
	end

	-- For each ingredient, check to see if we have it. If not, see if it's creatable
	for ik,iv in pairs(recipe.ingredients) do
		local hasEnough = false
		local numHas = 0
		local totalAmountNeeded = math.ceil(iv.amount*numToBuild)
		hasEnough, numHas = player.components.inventory:Has(iv.type,totalAmountNeeded)
		
		-- Subtract things already reserved from numHas
		for i,j in pairs(itemsNeeded) do
			if j.prefab == iv.type then
				numHas = math.max(0,numHas - 1)
			end
		end
		
		-- If we don't have or don't have enough for this ingredient, see if we can craft some more
		if numHas < totalAmountNeeded then
			local needed = totalAmountNeeded - numHas
			-- Before checking, add the current numHas to the table so the recursive
			-- call doesn't consider them valid.
			-- Make it level 0 as we already have this good.
			if numHas > 0 then
				table.insert(itemsNeeded,1,{prefab=iv.type,amount=numHas,level=0})
			end
			-- Recursive check...can we make this ingredient
			local canCraft = CanIBuildThis(player,iv.type,needed,recursive+1)
			if not canCraft then
				print("Need " .. tostring(needed) .. " " .. iv.type .. "s but can't make them")
				return false
			else
				-- We know the recipe to build this and have the goods. Add it to the list
				-- This should get added in the recursive case
				--table.insert(itemsNeeded,1,{prefab=iv.type, amount=needed, level=recursive, toMake=thingToBuild})
			end
		else
			-- We already have enough to build this resource. Add these to the list
			print("Adding " .. tostring(totalAmountNeeded) .. " of " .. iv.type .. " at level " .. tostring(recursive) .. " to the itemsNeeded list")
			table.insert(itemsNeeded,1,{prefab=iv.type, amount=totalAmountNeeded, level=recursive, toMake=thingToBuild, toMakeNum=numToBuild})
		end
	end
	
	-- We made it here, we can make this thingy
	return true
end

-- Should only be called after the above call to ensure we can build it.
local function BuildThis(player, thingToBuild, pos)
	local recipe = GetRecipe(thingToBuild)
	-- not a real thing
	if not recipe then return end
	
	for k,v in pairs(itemsNeeded) do print(k,v) end
	
	-- TODO: Make sure we have the inventory space! 
	for k,v in pairs(itemsNeeded) do
		-- Just go down the list. If level > 0, we need to build it
		if v.level > 0 and v.toMake then
			-- We should be able to build this...
			print("Trying to build " .. v.toMake)
			while v.toMakeNum > 0 do 
				if player.components.builder:CanBuild(v.toMake) then
					player.components.builder:DoBuild(v.toMake)
					v.toMakeNum = v.toMakeNum - 1
				else
					print("Uhh...we can't make " .. v.toMake .. "!!!")
					return
				end
			end
		end
	end
	
	-- We should have everything we need
	if player.components.builder:CanBuild(thingToBuild) then
		player.components.builder:DoBuild(thingToBuild,pos)
	else
		print("Something is messed up. We can't make " .. thingToBuild .. "!!!")
	end
	
end

-- Returns a point somewhere near thing at a distance dist
local function GetPointNearThing(thing, dist)
	local pos = Vector3(thing.Transform:GetWorldPosition())

	if pos then
		local theta = math.random() * 2 * PI
		local radius = dist
		local offset = FindWalkableOffset(pos, theta, radius, 12, true)
		if offset then
			return pos+offset
		end
	end
end
------------------------------------------------------------------------------------------------

local ArtificalBrain = Class(Brain, function(self, inst)
    Brain._ctor(self,inst)
end)


-- Some actions don't have a 'busy' stategraph. "DoingAction" is set whenever a BufferedAction
-- is scheduled and this callback will be triggered on both success and failure to denote 
-- we are done with that action


local function ActionDone(self, state)
	--print("Action Done")
	if self.currentAction ~= nil then 
		self.currentAction:Cancel() 
		self.currentAction=nil  
		self:RemoveTag("DoingLongAction")
	end
	self:RemoveTag("DoingAction")
end

-- Adds our custom success and fail callback to a buffered action
-- actionNumber is for a watchdog node

local MAX_TIME_FOR_ACTION_SECONDS = 8
local function SetupBufferedAction(inst, action)
	inst:AddTag("DoingAction")
	inst.currentAction = inst:DoTaskInTime(MAX_TIME_FOR_ACTION_SECONDS,function() print("watchdog trigger on action") ActionDone(inst, "failed") end)
	action:AddSuccessAction(function() inst:PushEvent("actionDone",{state="success"}) end)
	action:AddFailAction(function() inst:PushEvent("actionDone",{state="failed"}) end)
	return action	
end


-- Go home stuff
-----------------------------------------------------------------------
local function HasValidHome(inst)
    return inst.components.homeseeker and 
       inst.components.homeseeker.home and 
       inst.components.homeseeker.home:IsValid()
end

local function GoHomeAction(inst)
	print("GoHomeAction")
    if  HasValidHome(inst) and
        not inst.components.combat.target then
			inst.components.homeseeker:GoHome(true)
    end
end

local function GetHomePos(inst)
    return HasValidHome(inst) and inst.components.homeseeker:GetHomePos()
end

local function AtHome(inst)
	-- Am I close enough to my home position?
	if not HasValidHome(inst) return false end
	local dist = inst:GetDistanceSqToPoint(GetHomePos(inst))
	return HasValidHome(inst) and dist < 10
end

-- Should keep track of what we build so we don't have to keep checking. 
local function ListenForScienceMachine(inst,data)
	if data and data.item.prefab == "researchlab" then
		inst.components.homeseeker:SetHome(data.item)
	end
end

local function FindValidHome(inst)

	if not HasValidHome(inst) and inst.components.homeseeker then

		-- TODO: How to determine a good home. 
		-- For now, it's going to be the first place we build a science machine
		if inst.components.builder:CanBuild("researchlab") then
			-- Find some valid ground near us
			local machinePos = GetPointNearThing(inst,3)		
			if machinePos ~= nil then
				print("Found a valid place to build a science machine")
				inst.components.builder:DoBuild("researchlab",machinePos)
				-- This will push an event to set our home location
				-- If we can, make a firepit too
				if inst.components.builder:CanBuild("firepit") then
					local pitPos = GetPointNearThing(inst,4)
					inst.components.builder:DoBuild("firepit",pitPos)
				end
			else
				print("Could not find a place for a science machine")
			end
		end
		
	end
end

---------------------------------------------------------------------------
-- Gather stuff
local CurrentSearchDistance = MIN_SEARCH_DISTANCE
local function IncreaseSearchDistance()
	print("IncreaseSearchDistance")
	CurrentSearchDistance = math.min(MAX_SEARCH_DISTANCE,CurrentSearchDistance + SEARCH_SIZE_STEP)
end

local function ResetSearchDistance()
	CurrentSearchDistance = MIN_SEARCH_DISTANCE
end


local currentTreeOrRock = nil
local function OnFinishedWork(inst,target,action)
	currentTreeOrRock = nil
	inst:RemoveTag("DoingLongAction")
end


-- Harvest Actions
--local CurrentActionSearchDistance = MIN_SEARCH_DISTANCE

local function FindTreeOrRockAction(inst, action, continue)

	if inst.sg:HasStateTag("busy") then
		return
	end
	
	-- Probably entered in the LoopNode. Don't swing mid swing.
	if inst:HasTag("DoingAction") then return end
	
	--print("FindTreeOrRock")
	
	-- We are currently chopping down a tree (or mining a rock). If it's still there...don't stop
	if currentTreeOrRock ~= nil and inst:HasTag("DoingLongAction") then
		-- Assume the tool in our hand is still the correct one. If we aren't holding anything, we're done
		local tool = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
		if not tool or not tool.components.tool:CanDoAction(currentTreeOrRock.components.workable.action) then
			currentTreeOrRock = nil
			inst:RemoveTag("DoingLongAction")
		else 
			inst:AddTag("DoingLongAction")
			return SetupBufferedAction(inst,BufferedAction(inst, currentTreeOrRock, currentTreeOrRock.components.workable.action))
		end
		
	else
		inst:RemoveTag("DoingLongAction")
		currentTreeOrRock = nil
	end
	
	-- Do we need logs? (always)
	-- Don't chop unless we need logs (this is hacky)
	if action == ACTIONS.CHOP and inst.components.inventory:Has("log",20) then
		return
	end
	
	-- This is super hacky too
	if action == ACTIONS.MINE and inst.components.inventory:Has("goldnugget",10) then
		return
	end
	
	-- TODO, this will find all mineable structures (ice, rocks, sinkhole)
	local target = FindEntity(inst, CurrentSearchDistance, function(item) return item.components.workable and item.components.workable.action == action end)
	
	if target then
		-- Found a tree...should we chop it?
		-- Check to see if axe is already equipped. If not, equip one
		local equiped = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
		local alreadyEquipped = false
		local axe = nil
		if equiped and equiped.components.tool and equiped.components.tool:CanDoAction(action) then
			axe = equiped
			alreadyEquipped = true
		else 
			axe = inst.components.inventory:FindItem(function(item) return item.components.equippable and item.components.tool and item.components.tool:CanDoAction(action) end)
		end
		-- We are holding an axe or have one in inventory. Let's chop
		if axe then
			if not alreadyEquipped then
				inst.components.inventory:Equip(axe)
			end
			ResetSearchDistance()
			currentTreeOrRock = target
			inst:AddTag("DoingLongAction")
			return SetupBufferedAction(inst,BufferedAction(inst, target, action))
			-- Craft one if we can
		else
			local thingToBuild = nil
			if action == ACTIONS.CHOP then
				thingToBuild = "axe"
			elseif action == ACTIONS.MINE then
				thingToBuild = "pickaxe"
			end
			
			if thingToBuild and inst.components.builder and inst.components.builder:CanBuild(thingToBuild) then
				inst.components.builder:DoBuild(thingToBuild)
				
			else
				--addRecipeToGatherList(thingToBuild,false)
			end
		end
	end
end


local function FindResourceToHarvest(inst)
	--print("FindResourceToHarvest")
	if inst.sg:HasStateTag("busy") then
		return
	end
	
	if not inst.components.inventory:IsFull() then
		local target = FindEntity(inst, CurrentSearchDistance, function(item)
					if item.components.pickable and item.components.pickable:CanBePicked() and item.components.pickable.caninteractwith then
						local theProductPrefab = item.components.pickable.product
						if theProductPrefab == nil then
							return false
						end
						-- Check to see if we have a full stack of this item
						local theProduct = inst.components.inventory:FindItem(function(item) return (item.prefab == theProductPrefab) end)
						if theProduct then
							-- If we don't have a full stack of this...then pick it up (if not stackable, we will hold 2 of them)
							return not inst.components.inventory:Has(theProductPrefab,theProduct.components.stackable and theProduct.components.stackable.maxsize or 2)
						else
							-- Don't have any of this...lets get some
							return true
						end
					end
					-- Default case...probably not harvest-able. Return false.
					return false
				end)

		if target then
			ResetSearchDistance()
			return SetupBufferedAction(inst,BufferedAction(inst,target,ACTIONS.PICK))
		end
	end
end

-- Do an expanding search. Look for things close first.

local function FindResourceOnGround(inst)

	--print("FindResourceOnGround")
	if inst.sg:HasStateTag("busy") then
		return
	end
	
	

	-- TODO: Only have up to 1 stack of the thing (modify the findentity fcn)
	local target = FindEntity(inst, CurrentSearchDistance, function(item)
						-- Do we have a slot for this already
						local haveItem = inst.components.inventory:FindItem(function(invItem) return item.prefab == invItem.prefab end)
			
						if item.components.inventoryitem and 
							item.components.inventoryitem.canbepickedup and 
							not item.components.inventoryitem:IsHeld() and
							item:IsOnValidGround() and
							-- Ignore things we have a full stack of
							not inst.components.inventory:Has(item.prefab, item.components.stackable and item.components.stackable.maxsize or 2) and
							-- Ignore this unless it fits in a stack
							not (inst.components.inventory:IsFull() and haveItem == nil) and
							not item:HasTag("prey") and
							not item:HasTag("bird") then
								return true
						end
					end)
	if target then
		ResetSearchDistance()
		return SetupBufferedAction(inst,BufferedAction(inst, target, ACTIONS.PICKUP))
	end

end

-----------------------------------------------------------------------
-- Eating and stuff
local function HaveASnack(inst)
	--print("HaveASnack")
	if inst.components.hunger:GetPercent() > .5 then
		return
	end
	
	if inst.sg:HasStateTag("busy") or inst:HasTag("DoingAction") then
		return
	end
		
	-- Check inventory for food. 
	-- If we have none, set the priority item to find to food (TODO)
	local allFoodInInventory = inst.components.inventory:FindItems(function(item) return inst.components.eater:CanEat(item) end)
	
	-- TODO: Find cookable food (can't eat some things raw)
	
	for k,v in pairs(allFoodInInventory) do
		-- Sort this list in some way. Currently just eating the first thing.
		-- TODO: Get the hunger value from the food and spoil rate. Prefer to eat things 
		--       closer to spoiling first
		if inst.components.hunger:GetPercent() <= .5 then
			return SetupBufferedAction(inst,BufferedAction(inst,v,ACTIONS.EAT))
		end
	end
	
	-- TODO:
	-- We didn't find antying to eat and we're hungry. Set our priority to finding food!

end
---------------------------------------------------------------------------------
-- COMBAT

-- Under these conditions, fight back. Else, run away
local function FightBack(inst)
	if inst.components.combat.target ~= nil then
		print("Fight Back called with target " .. tostring(inst.components.combat.target.prefab))
		inst.components.combat.target:AddTag("TryingToKillUs")
	else
		inst:RemoveTag("FightBack")
		return
	end

	-- This has priority. 
	inst:RemoveTag("DoingAction")
	inst:RemoveTag("DoingLongAction")
	
	if inst.sg:HasStateTag("busy") then
		return
	end
	
	-- Do we want to fight this target? 
	-- What conditions would we fight under? Armor? Weapons? Hounds? etc
	
	-- Right now, the answer will be "YES, IT MUST DIE"
	
	-- First, check the distance to the target. This could be an old target that we've run away from. If so,
	-- clear the combat target fcn.

	-- Do we have a weapon
	local equipped = inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	local allWeaponsInInventory = inst.components.inventory:FindItems(function(item) return item.components.weapon and item.components.equippable end)
	
	-- Sort by highest damage and equip that one. Replace the one in hands if higher
	local highestDamageWeapon = nil
	
	if equipped and equipped.components.weapon then
		highestDamageWeapon = equipped
	end
	for k,v in pairs(allWeaponsInInventory) do
		if highestDamageWeapon == nil then
			highestDamageWeapon = v
		else
			if v.components.weapon.damage > highestDamageWeapon.components.weapon.damage then
				highestDamageWeapon = v
			end
		end
	end
	
	-- If we don't have at least a spears worth of damage, make a spear
	if (highestDamageWeapon and highestDamageWeapon.components.weapon.damage < 34) or highestDamageWeapon == nil then
		--print("Shit shit shit, no weapons")
		
		-- Can we make a spear? We'll equip it on the next visit to this function
		if inst.components.builder and CanIBuildThis(inst, "spear") then
			BuildThis(inst,"spear")
		else
			-- Can't build a spear. If we don't have ANYTHING, run away!
			if highestDamageWeapon == nil then
				-- Can't even build a spear! Abort abort!
				--addRecipeToGatherList("spear",false)
				inst:RemoveTag("FightBack")
				inst.components.combat:GiveUp()
				return
			end
			print("Can't build a spear. I'm using whatever I've got!")
		end

	end
	
	-- Equip our best weapon
	if equipped ~= highestDamageWeapon and highestDamageWeapon ~= nil then
		inst.components.inventory:Equip(highestDamageWeapon)
	end
	
	inst:AddTag("FightBack")
end
----------------------------- End Combat ---------------------------------------


local function IsNearLightSource(inst)
	local source = GetClosestInstWithTag("lightsource", inst, 10)
	if source then
	
		local dsq = inst:GetDistanceSqToInst(source)
		if dsq > 8 then
			print("It's too far away!")
			return false 
		end
		
		-- Find the source of the light
		local parent = source.entity:GetParent()
		if parent then
			if parent.components.fueled and parent.components.fueled:GetPercent() < .25 then
				return false
			end
		end
		-- Source either has no parent or doesn't need fuel. We're good.
		return true
	end

	return false
end

local function MakeLightSource(inst)
	-- If there is one nearby, move to it
	print("Need to make light!")
	local source = GetClosestInstWithTag("lightsource", inst, 30)
	if source then
		print("Found a light source")
		local dsq = inst:GetDistanceSqToInst(source)
		if dsq >= 15 then
			local pos = GetPointNearThing(source,2)
			if pos then
				inst.components.locomotor:GoToPoint(pos,nil,true)
			end
		end
		
		local parent = source.entity:GetParent()
		if parent and not parent.components.fueled then	
			return 		
		end

	end
	
	-- 1) Check for a firepit to add fuel
	local firepit = GetClosestInstWithTag("campfire",inst,15)
	if firepit then
		-- It's got fuel...nothing to do
		if firepit.components.fueled:GetPercent() > .25 then 
			return
		end
		
		-- Find some fuel in our inventory to add
		local allFuelInInv = inst.components.inventory:FindItems(function(item) return item.components.fuel and 
																				not item.components.armor and
																				firepit.components.fueled:CanAcceptFuelItem(item) end)
		
		-- Add some fuel to the fire.
		
		for k,v in pairs(allFuelInInv) do
			-- TODO: Sort this by a burn order. Probably logs first.
			if firepit.components.fueled:GetPercent() < .25 then
				return BufferedAction(inst, firepit, ACTIONS.ADDFUEL, v)
			end
		end
		
		-- We don't have enough fuel. Let it burn longer before executing backup plan
		if firepit.components.fueled:GetPercent() > .1 then return end
	end
	
	-- No firepit (or no fuel). Can we make one?
	if inst.components.builder:CanBuild("campfire") then
		-- Don't build one too close to burnable things. 
		local burnable = GetClosestInstWithTag("burnable",inst,3)
		local pos = nil
		if burnable then
			print("Don't want to build campfire too close")
			pos = GetPointNearThing(burnable,3)
		end
		inst.components.builder:DoBuild("campfire",pos)
		return
	end
	
	-- Can't make a campfire...torch it is (hopefully)
	
	local haveTorch = inst.components.inventory:FindItem(function(item) return item.prefab == "torch" end)
	if not haveTorch then
		-- Need to make one!
		if inst.components.builder:CanBuild("torch") then
			inst.components.builder:DoBuild("torch")
		end
	end
	-- Find it again
	haveTorch = inst.components.inventory:FindItem(function(item) return item.prefab == "torch" end)
	if haveTorch then
		inst.components.inventory:Equip(haveTorch)
		return
	end
	
	-- Uhhh....we couldn't add fuel and we didn't have a torch. Find fireflys? 
	print("Shit shit shit, it's dark!!!")
end

local function IsNearCookingSource(inst)
	local cooker = GetClosestInstWithTag("campfire",inst,10)
	if cooker then return true end
end

local function CookSomeFood(inst)
	local cooker = GetClosestInstWithTag("campfire",inst,10)
	if cooker then
		-- Find food in inventory that we can cook.
		local cookableFood = inst.components.inventory:FindItems(function(item) return item.components.cookable end)
		
		for k,v in pairs(cookableFood) do
			-- Don't cook this unless we have a free space in inventory or this is a single item or the product is in our inventory
			print("Checking " .. v.prefab)
			local has, numfound = inst.components.inventory:Has(v.prefab,1)
			print("Have " .. tostring(numfound) .. " of these to cook")
			local theProduct = inst.components.inventory:FindItem(function(item) return (item.prefab == v.components.cookable.product) end)
			local canFillStack = false
			if theProduct then
				canFillStack = not inst.components.inventory:Has(v.components.cookable.product,theProduct.components.stackable.maxsize)
			end
			
			print("Can we put this in an existing stack? " .. tostring(canFillStack))

			if not inst.components.inventory:IsFull() or numfound == 1 or (theProduct and canFillStack) then
				return BufferedAction(inst,cooker,ACTIONS.COOK,v)
			end
		end
	end
end




--------------------------------------------------------------------------------

local function MidwayThroughDusk()
	local clock = GetClock()
	local startTime = clock:GetDuskTime()
	return clock:IsDusk() and (clock:GetTimeLeftInEra() < startTime/4)
end

function ArtificalBrain:OnStart()
	local clock = GetClock()
	
	self.inst:ListenForEvent("actionDone",function(inst,data) local state = nil if data then state = data.state end ActionDone(inst,state) end)
	self.inst:ListenForEvent("finishedwork", function(inst, data) OnFinishedWork(inst,data.target, data.action) end)
	self.inst:ListenForEvent("buildstructure", function(inst, data) ListenForScienceMachine(inst,data) end)
	self.inst:ListenForEvent("attacked", function(inst,data) print("I've been hit!") inst.components.combat:SetTarget(data.attacker) end)
	
	-- Things to do during the day
	local day = WhileNode( function() return clock and clock:IsDay() end, "IsDay",
		PriorityNode{
			--RunAway(self.inst, "hostile", 15, 30),
			-- We've been attacked. Equip a weapon and fight back.
			IfNode( function() return self.inst.components.combat.target ~= nil end, "hastarget", 
				DoAction(self.inst,function() return FightBack(self.inst) end,"fighting",true)),
			WhileNode(function() return self.inst.components.combat.target ~= nil and self.inst:HasTag("FightBack") end, "Fight Mode",
				ChaseAndAttack(self.inst,20)),
			-- This is if we don't want to fight what is attaking us. We'll run from it instead.
			RunAway(self.inst,"TryingToKillUs",3,8),
			
			-- If we started doing a long action, keep doing that action
			WhileNode(function() return self.inst:HasTag("DoingLongAction") end, "continueLongAction",
				LoopNode{
					DoAction(self.inst, function() return FindTreeOrRockAction(self.inst,nil,true) end, "continueAction", true)}),
			
			-- Make sure we eat
			DoAction(self.inst, function() return HaveASnack(self.inst) end, "eating", true ),
			
			-- Find a good place to call home
			IfNode( function() return not HasValidHome(self.inst) end, "no home",
				DoAction(self.inst, function() return FindValidHome(self.inst) end, "looking for home", true)),

			-- Harvest stuff
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goPickup",
				DoAction(self.inst, function() return FindResourceOnGround(self.inst) end, "pickup_ground", true )),			
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goHarvest",
				DoAction(self.inst, function() return FindResourceToHarvest(self.inst) end, "harvest", true )),
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goChop",
				DoAction(self.inst, function() return FindTreeOrRockAction(self.inst, ACTIONS.CHOP) end, "chopTree", true)),
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goMine",
				DoAction(self.inst, function() return FindTreeOrRockAction(self.inst, ACTIONS.MINE) end, "mineRock", true)),
				
			-- Can't find anything to do...increase search distance
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "nothing_to_do",
				DoAction(self.inst, function() return IncreaseSearchDistance() end,"lookingForStuffToDo", true)),

			-- No plan...just walking around
			--Wander(self.inst, nil, 20),
		},.25)
		

		-- What to do the first half of dusk. 
		-- Prioritize trees and rocks
	local dusk = WhileNode( function() return clock and clock:IsDusk() and not MidwayThroughDusk() end, "IsDusk",
        PriorityNode{
			--RunAway(self.inst, "hostile", 15, 30),
			-- We've been attacked. Equip a weapon and fight back.
			IfNode( function() return self.inst.components.combat.target ~= nil end, "hastarget", 
				DoAction(self.inst,function() return FightBack(self.inst) end,"fighting",true)),
			WhileNode(function() return self.inst.components.combat.target ~= nil and self.inst:HasTag("FightBack") end, "Fight Mode",
				ChaseAndAttack(self.inst,20)),
			-- This is if we don't want to fight what is attacking us. We'll run from it instead.
			RunAway(self.inst,"TryingToKillUs",3,8),
			
			-- If we started doing a long action, keep doing that action
			WhileNode(function() return self.inst:HasTag("DoingLongAction") end, "continueLongAction",
				LoopNode{
					DoAction(self.inst, function() return FindTreeOrRockAction(self.inst,nil,true) end, "continueAction", true)}),
			
			-- Make sure we eat
			DoAction(self.inst, function() return HaveASnack(self.inst) end, "eating", true ),
			
			-- Find a good place to call home
			IfNode( function() return not HasValidHome(self.inst) end, "no home",
				DoAction(self.inst, function() return FindValidHome(self.inst) end, "looking for home", true)),

			-- Harvest stuff
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goPickup",
				DoAction(self.inst, function() return FindResourceOnGround(self.inst) end, "pickup_ground", true )),		
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goChop",
				DoAction(self.inst, function() return FindTreeOrRockAction(self.inst, ACTIONS.CHOP) end, "chopTree", true)),	
				
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goHarvest",
				DoAction(self.inst, function() return FindResourceToHarvest(self.inst) end, "harvest", true )),
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "notBusy_goMine",
				DoAction(self.inst, function() return FindTreeOrRockAction(self.inst, ACTIONS.MINE) end, "mineRock", true)),
				
			-- Can't find anything to do...increase search distance
			IfNode( function() return not self.inst.sg:HasStateTag("busy") and not self.inst:HasTag("DoingAction") end, "nothing_to_do",
				DoAction(self.inst, function() return IncreaseSearchDistance() end,"lookingForStuffToDo", true)),

			-- No plan...just walking around
			--Wander(self.inst, nil, 20),
        },.5)
		
		-- Behave slightly different half way through dusk
		local dusk2 = WhileNode( function() return clock and clock:IsDusk() and MidwayThroughDusk() end, "IsDusk2",
			PriorityNode{
				DoAction(self.inst, function() return HaveASnack(self.inst) end, "eating"),
				IfNode( function() return HasValidHome(self.inst) end, "try to go home",
					DoAction(self.inst, function() return GoHomeAction(self.inst) end, "go home", true)),
				--IfNode( function() return AtHome(self.inst) end, "am home",
				--	DoAction(self.inst, function() return BuildStuffAtHome(self.inst) end, "build stuff", true)),
				
				-- If we don't have a home, make a camp somewhere
				--IfNode( function() return not HasValidHome(self.inst) end, "no home to go",
				--	DoAction(self.inst, function() return true end, "make temp camp", true)),
					
				-- If we're home (or at our temp camp) start cooking some food.
				
				
		},.5)
		
	-- Things to do during the night
	--[[
		1) Light a fire if there is none close by
		2) Stay near fire. Maybe cook?
	--]]
	local night = WhileNode( function() return clock and clock:IsNight() end, "IsNight",
        PriorityNode{
			-- Must be near light! 	
			IfNode( function() return not IsNearLightSource(self.inst) end, "no light!!!",
				DoAction(self.inst, function() return MakeLightSource(self.inst) end, "making light", true)),
				
			IfNode( function() return IsNearCookingSource(self.inst) end, "let's cook",
				DoAction(self.inst, function() return CookSomeFood(self.inst) end, "cooking food", true)),
			
			DoAction(self.inst, function() return HaveASnack(self.inst) end, "eating", true ),
            
        },.5)
		
	-- Taken from wilsonbrain.lua
	local RUN_THRESH = 4.5
	local MAX_CHASE_TIME = 5
	local nonAIMode = PriorityNode(
    {
    	WhileNode(function() return TheInput:IsControlPressed(CONTROL_PRIMARY) end, "Hold LMB", ChaseAndAttack(self.inst, MAX_CHASE_TIME)),
    	ChaseAndAttack(self.inst, MAX_CHASE_TIME, nil, 1),
    },0)
		
	local root = 
        PriorityNode(
        {   
			-- No matter the time, panic when on fire
			WhileNode(function() return self.inst.components.health.takingfiredamage end, "OnFire", Panic(self.inst) ),
			day,
			dusk,
			dusk2,
			night

        }, .5)
    
    self.bt = BT(self.inst, root)

end

return ArtificalBrain