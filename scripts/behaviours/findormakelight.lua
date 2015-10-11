MaintainLightSource = Class(BehaviourNode, function(self, inst, searchDistance)
    BehaviourNode._ctor(self, "MaintainLightSource")
    self.inst = inst
	self.distance = searchDistance
end)

local SAFE_LIGHT_DISTANCE = 5

function MaintainLightSource:OnActionFail()
	self.pendingstatus = FAILED
end

function MaintainLightSource:OnActionSucceed()
	self.pendingstatus = SUCCESS
end

function MaintainLightSource:Visit()

-- 0) Are we near a light source? If yes...nothing to do. 
-- 1) Are we near a firepit? If we are, add fuel if needed.
-- 2) Are we not near a firepit? Make a campfire.
-- 3) If we can't make a campfire...make a torch!
-- 4) If we can't make a torch...uhhh, find some light asap!

    if self.status == READY then
		self.currentLightSource = nil 
		
		local source = GetClosestInstWithTag("lightsource", self.inst, self.distance)
		-- Nothing nearby! Fix this asap.
		if not source then
			print("No light nearby!!!")
			-- Shit...better find one.
			self.status = RUNNING
			return
		end
		
		if source then
			-- Make sure we stay close enough to it
			local dsq = self.inst:GetDistanceSqToInst(source)
			if dsq >= SAFE_LIGHT_DISTANCE*SAFE_LIGHT_DISTANCE then
				print("Too far! I'm scared")
				-- Pick a random spot near the light to run to.
				-- TODO: Find the light intensity and stay within that...
				local pos = self.inst.brain:GetPointNearThing(source,4)
				if pos then
					self.inst.components.locomotor:GoToPoint(pos,nil,true)
				else
					-- Couldn't get a point near it. Just run into the fire.
					self.inst.components.locomotor:GoToEntity(source,nil,true)
				end
				
				-- We're close enough to some light. Nothing to do.
				self.status = FAILED
				return
			end
			
			-- If it's a firepit or campfire, make sure there's enough fuel 
			-- in it. 
			
			local parent = source.entity:GetParent()
			if parent then
				if parent.components.fueled and parent.components.fueled:GetPercent() < .25 then
					print("Visit: Need to add fuel to the parent")
					self.currentLightSource = parent
					self.status = RUNNING
					return
				end
			else
				-- This lightsource has no parent? Whatever...it's good enough for me
				self.status = FAILED
				return
			end
			
			-- All is well. Nothing to do.
			self.status = FAILED
			return
		end
		
		-- Not near a light source currently. Are we next to an unlit firepit? 
		local firepit = GetClosestInstWithTag("campfire", self.inst, self.distance)
		if firepit then
			print("No lightsource nearby...but there's an unlit firepit!")
			self.currentLightSource = firepit
			self.status = RUNNING
			return
		end

    elseif self.status == RUNNING then
	
		-- Waiting for our build to succeed...nothing to do
		if self.currentBuildAction and self.pendingstatus == nil then
			self.status = RUNNING
			return
		end
		
		-- Uhh...our build failed! Do we just try again? 
		if self.currentBuildAction and self.pendingstatus == FAILED then
			print("Our build failed!!!")
			self.pendingstatus = nil
			self.currentBuildAction = nil
		end
		
		-- The build finished! If it was a torch, equip the torch
		if self.currentBuildAction and self.pendingstatus == SUCCESS then
			print("Yay, build done!")
			local buildRecipe = self.currentBuildAction.recipe
			
			self.currentBuildAction = nil
			self.pendingstatus = nil
			
			if buildRecipe and buildRecipe == "torch" then
				local haveTorch = self.inst.components.inventory:FindItem(function(item) return item.prefab == "torch" end)
				if haveTorch then
					self.inst.components.inventory:Equip(haveTorch)
					self.status = SUCCESS
					return
				end
				-- Wait...torch finished building and we don't have a torch? We must have had a full inventory and dropped it! 
				-- Drop something and pick it up
				local torchOnGround = FindEntity(self.inst, 5, function(item) return item.prefab == "torch" end)
				if torchOnGround then
					print("Stupid full inventory")
					-- Drop whatever is in our hands and pick up that torch
					
					self.inst.components.inventory:DropItem(self.inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS))
					local action = BufferedAction(self.inst, torchOnGround, ACTIONS.PICKUP)
					action:AddSuccessAction(function() self:OnActionSucceed() end)
					action:AddFailAction(function() self:OnActionFail() end)
					self.inst.components.locomotor:PushAction(action, true)
					self.status = RUNNING
					return
				end
				
				-- WTF!!! We built one, and it has vanished. This is fucked up!
				self.status = FAILED
				return
			end
			
			-- Must have been our firepit. Yay!
			self.status = SUCCESS
			return
		end
		
		-- Finally, check to see if we ever got that stupid torch
		if self.pendingstatus and self.pendingstatus == SUCCESS then
			self.status = SUCCESS
			return
		end
		
		self.currentBuildAction = nil
		self.pendingstatus = nil
	
		if self.currentLightSource then
			-- There was a light source. It must need fuel or something.
			if self.currentLightSource.components.fueled and self.currentLightSource.components.fueled:GetPercent() <= .25 then
				print("Gotta add fuel to the fire!")

				-- Find fuel to add to the fire
				local allFuelInInv = self.inst.components.inventory:FindItems(function(item) 
												 return item.components.fuel and 
														not item.components.armor and
														item.prefab ~= "livinglog" and
														self.currentLightSource.components.fueled:CanAcceptFuelItem(item) end)	

				local bestFuel = nil
				for k,v in pairs(allFuelInInv) do
					-- TODO: This is a bit hackey...but really, logs are #1
					if v.prefab == "log" then
						local action = BufferedAction(self.inst, self.currentLightSource, ACTIONS.ADDFUEL, v)
						self.inst.components.locomotor:PushAction(action,true)
						-- Keep running in case we need to add more
						self.status = RUNNING
						return
					else
						bestFuel = v
					end
				end
				
				-- Don't add this other burnable stuff unless the fire is looking really sad.
				-- TODO: Always save enough to make a torch. i.e....don't throw in our last grass or sticks!!
				if bestFuel and self.currentLightSource.components.fueled:GetPercent() < .15 then
					print("Adding emergency reserves")
					local action = BufferedAction(self.inst,self.currentLightSource,ACTIONS.ADDFUEL,bestFuel)
					self.inst.components.locomotor:PushAction(action,true)
					-- Return true to come back here and make sure all is still good
					self.status = RUNNING
					return
				end

				-- We apparently have no more fuel to add. Let it burn a bit longer before executing
				-- the emergency plan.
				if self.currentLightSource.components.fueled:GetPercent() > .05 then 
					-- Return false to let the brain continue to other actions rather than
					-- to keep checking
					self.status = FAILED
					return
				end				
			elseif self.currentLightSource.components.fueled and self.currentLightSource.components.fueled:GetPercent() > .25 then
				self.status = SUCCESS
				return
			else
				print("Current lightsource doesn't need fuel...")
				self.status = FAILED
				return
			end
			
			-- There was no light source, or we are out of fuel. Time to panic!
		
		else
			-- There was nothing nearby. We need to make one!
			-- Can we make a campfire?
			if self.inst.components.builder:CanBuild("campfire") then
				-- Don't build one too close to burnable things. 
				-- TODO: This should be a while loop until we find a valid spot
				local burnable = GetClosestInstWithTag("burnable",self.inst,3)
				local pos = nil
				if burnable then
					print("Don't want to build campfire too close")
					pos = self.inst.brain:GetPointNearThing(burnable,4)
				end

				local action = BufferedAction(self.inst,nil,ACTIONS.BUILD,nil,pos,"campfire",nil,1)
				-- Track this build action!
				action:AddFailAction(function() self:OnActionFail() end)
				action:AddSuccessAction(function() self:OnActionSucceed() end)
				
				-- Need to push this to the locomotor so we walk to the right position
				self.currentBuildAction = action
				self.inst.components.locomotor:PushAction(action, true);
				self.status = RUNNING
				return
			end
			
			-- There's no light and we can't make a campfire. How about a torch?
				
			local haveTorch = self.inst.components.inventory:FindItem(function(item) return item.prefab == "torch" end)
			if not haveTorch then
				-- Need to make one!
				if self.inst.components.builder:CanBuild("torch") then
					--inst.components.builder:DoBuild("torch")
					local action = BufferedAction(self.inst,self.inst,ACTIONS.BUILD,nil,nil,"torch",nil)
					action:AddSuccessAction(function() self:OnActionSucceed() end)
					action:AddFailAction(function() self.OnActionFail() end)
					self.currentBuildAction = action
					self.inst:PushBufferedAction(action)
					self.status = RUNNING
					return
				end
			end
			
			-- We already have a torch. Equip it.
			if haveTorch then
				self.inst.components.inventory:Equip(haveTorch)
				self.status = SUCCESS
				return
			end
			
			-- If we're here...well, shit. Not sure what to do. We looked for nearby light...we
			-- tried to make light...we're screwed. 
			print("This is how i die")
			self.status = FAILED
			return
			
		end -- end if/else currentLightSource

    end -- end status == RUNNING
end



