-- This code is licensed under the MIT Open Source License.

-- Copyright (c) 2015 Ruairidh Carmichael - ruairidhcarmichael@live.co.uk

-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:

-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.

-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

local path = ...
local tween = require(path .. '/tween')

-- Splashy was historically loaded for its global.  Keep that compatibility
-- seam while also returning the module table so the modern runtime can own
-- and reset an explicit splash lifecycle.
local splashy = {}
_G.splashy = splashy
splashy.list = {}
splashy.inalpha = 0
splashy.outalpha = 1
splashy.coloralpha = 1
splashy.count = 1
splashy.tweenlist = {}
splashy.tweenInList = {}
splashy.tweenOutList = {}
splashy.colorList = {}
splashy.endColorList = {}
splashy.scaleList = {}
splashy.delayInitList = {}
splashy.delayFinishList = {}
splashy.extraDelayList = {}
splashy.colorFadeList = {}
splashy.quadList = {}
splashy.frameSizeList = {}
splashy.frameDurationList = {}
splashy.colorTween = nil
splashy.delayTimer = 0
splashy.currentFrame = 1
splashy.frameTimer = 0
splashy.fadestate = "delayin"
splashy.finished = false
splashy.onCompleteFunction = function() end
splashy.screenWidth = love.graphics.getWidth()
splashy.screenHeight = love.graphics.getHeight()

--- Sets the expected screen resolution that Splashy will use for rendering.
-- You should set this manually if you use screen scaling libraries like Push or TLfres
function splashy.setScreenSize(width, height)
	splashy.screenWidth, splashy.screenHeight = width, height
end

--- Adds a splash screen to the queue.
-- @param image (drawable) Usually an image to be drawn in the splash screen
-- @param duration (number) Optional. Determines how long the image fade will last. Defaults to 2
-- @param index (number) Optional. Allows you to set a custom index for the splash screen, which will change the order it is rendered
-- @param color (table) Optional. Affects the background color of the splash screen. Defaults to transparent black
-- @param scale (number) Optional. Determines the scale at which the image is drawn
-- @param delayInit (number) Optional. Seconds to hold on the background color before the image fades in. Defaults to 0
-- @param delayFinish (number) Optional. Seconds to keep the image fully shown before it fades out. Defaults to 0
-- @param extraDelay (number) Optional. Seconds to hold on the background color (image gone) before it fades/cuts out. Defaults to 0
-- @param colorFade (number) Optional. Seconds over which the background transitions to endColor. 0 cuts it instantly. Defaults to 0
-- @param animation (table) Optional. Turns the image into a looping sprite-sheet animation. Fields:
--   frameWidth  (number) width of one frame in pixels
--   frameHeight (number) height of one frame in pixels
--   frames      (number) number of frames laid out horizontally, left to right
--   fps         (number) Optional. Playback speed in frames per second. Defaults to 8
-- @param transitions (table|nil) Optional independent fade-in/fade-out durations
-- @param endColor (table|nil) Optional final RGBA color. Omit to preserve the legacy transparent reveal.
function splashy.addSplash(image, duration, index, color, scale, delayInit, delayFinish, extraDelay, colorFade, animation,
    transitions, endColor)
	duration = duration or 2
	assert(type(duration) == 'number' and duration > 0, "duration must be a positive number.")

	transitions = transitions or {}
	assert(type(transitions) == 'table', 'transitions must be a table when supplied')
	local fadeIn = transitions.fade_in or transitions.fadeIn or duration
	local fadeOut = transitions.fade_out or transitions.fadeOut or duration
	assert(type(fadeIn) == 'number' and fadeIn > 0, 'fade_in must be a positive number')
	assert(type(fadeOut) == 'number' and fadeOut > 0, 'fade_out must be a positive number')

	index = index or #splashy.list + 1
	assert(type(index) == "number", "index must be a number")

	color = color or { 0, 0, 0, 0 }
	assert(type(color) == "table", "color must be a table")
	-- Omitted endColor preserves Splashy's historical transparent fade for
	-- direct legacy callers. The engine adapter always supplies one so normal
	-- project splashes finish on an intentional opaque color instead.
	if endColor ~= nil then
		assert(type(endColor) == "table", "endColor must be a color table when supplied")
	end

	scale = scale or 1
	assert(type(scale) == "number", "scale must be a number")

	delayInit = delayInit or 0
	assert(type(delayInit) == "number" and delayInit >= 0, "delayInit must be a non-negative number")

	delayFinish = delayFinish or 0
	assert(type(delayFinish) == "number" and delayFinish >= 0, "delayFinish must be a non-negative number")

	extraDelay = extraDelay or 0
	assert(type(extraDelay) == "number" and extraDelay >= 0, "extraDelay must be a non-negative number")

	colorFade = colorFade or 0
	assert(type(colorFade) == "number" and colorFade >= 0, "colorFade must be a non-negative number")

	splashy.list[index] = image

	-- Original Splashy used one tween for both directions.  Keeping the same
	-- phase machine but owning two transition tweens lets project config set
	-- independent fade-in and fade-out durations without changing its visuals.
	splashy.tweenInList[index] = tween.new(fadeIn, splashy, { inalpha = 1 })
	splashy.tweenOutList[index] = tween.new(fadeOut, splashy, { outalpha = 0 })
	-- Retained for older callers that inspect the historical field.
	splashy.tweenlist[index] = splashy.tweenInList[index]

	splashy.colorList[index] = color
	splashy.endColorList[index] = endColor

	splashy.scaleList[index] = scale

	splashy.delayInitList[index] = delayInit
	splashy.delayFinishList[index] = delayFinish
	splashy.extraDelayList[index] = extraDelay
	splashy.colorFadeList[index] = colorFade

	if animation ~= nil then
		assert(type(animation) == "table", "animation must be a table")
		local fw, fh, frames = animation.frameWidth, animation.frameHeight, animation.frames
		assert(type(fw) == "number" and fw > 0, "animation.frameWidth must be a positive number")
		assert(type(fh) == "number" and fh > 0, "animation.frameHeight must be a positive number")
		assert(type(frames) == "number" and frames >= 1, "animation.frames must be a number >= 1")

		local fps = animation.fps or 8
		assert(type(fps) == "number" and fps > 0, "animation.fps must be a positive number")

		-- Build one quad per frame, stepping left to right across the strip.
		local sheetW, sheetH = image:getWidth(), image:getHeight()
		local quads = {}
		for f = 0, frames - 1 do
			quads[f + 1] = love.graphics.newQuad(f * fw, 0, fw, fh, sheetW, sheetH)
		end

		splashy.quadList[index] = quads
		splashy.frameSizeList[index] = { fw, fh }
		splashy.frameDurationList[index] = 1 / fps
	else
		splashy.quadList[index] = nil
		splashy.frameSizeList[index] = nil
		splashy.frameDurationList[index] = nil
	end
end

--- Resets the per-splash runtime state so the next splash starts cleanly.
local function resetRuntimeState()
	splashy.inalpha = 0
	splashy.outalpha = 1
	splashy.coloralpha = 1
	splashy.colorTween = nil
	splashy.delayTimer = 0
	splashy.currentFrame = 1
	splashy.frameTimer = 0
	splashy.fadestate = "delayin"
end

---Clear the queue and restore the original ready-to-configure state.
---The old integration was a one-shot global; the engine wrapper uses this so
---each project launch begins with no stale logo, alpha, or completion callback.
function splashy.reset()
	splashy.list = {}
	splashy.tweenlist = {}
	splashy.tweenInList = {}
	splashy.tweenOutList = {}
	splashy.colorList = {}
	splashy.endColorList = {}
	splashy.scaleList = {}
	splashy.delayInitList = {}
	splashy.delayFinishList = {}
	splashy.extraDelayList = {}
	splashy.colorFadeList = {}
	splashy.quadList = {}
	splashy.frameSizeList = {}
	splashy.frameDurationList = {}
	splashy.count = 1
	splashy.finished = false
	splashy.onCompleteFunction = function() end
	resetRuntimeState()
end

function splashy.isActive()
	return splashy.finished == false and splashy.count <= #splashy.list
end

--- Skips the current splash screen.
function splashy.skipSplash()
	resetRuntimeState()

	splashy.count = splashy.count + 1
end

--- Skips all the splash screens.
function splashy.skipAll()
	resetRuntimeState()

	splashy.count = #splashy.list + 1
end

--- Sets a callback function that will execute when all the splash screens have finished.
-- @param func (function) The callback function
function splashy.onComplete(func)
	assert(type(func) == "function", "func must be a function")

	splashy.onCompleteFunction = func
end

--- Renders the splash screens.
-- This should be placed in love.draw ()
function splashy.draw()
	if splashy.finished == false then
		for i = 1, #splashy.list do
			-- If the current splash is the one in the list.

			if splashy.count == i then
				-- Then grab the splash from the list and draw it to the screen.

				local splash = splashy.list[i]
				local scale = splashy.scaleList[i]
				local quads = splashy.quadList[i]
				local centerwidth = splashy.screenWidth / 2
				local centerheight = splashy.screenHeight / 2

				-- An animated splash centers on one frame; a static one centers on the whole image.
				local drawWidth, drawHeight
				if quads then
					local frameSize = splashy.frameSizeList[i]
					drawWidth, drawHeight = frameSize[1], frameSize[2]
				else
					drawWidth, drawHeight = splash:getWidth(), splash:getHeight()
				end

				local centerimagewidth = (drawWidth * scale) / 2
				local centerimageheight = (drawHeight * scale) / 2

				-- Engine-owned splashes provide an end color, so colorout remains
				-- opaque and cannot expose an unrelated clear color beneath it. An
				-- omitted target retains Splashy's historical transparent reveal.
				local bg = splashy.colorList[i]
				local endColor = splashy.endColorList[i]
				local r, g, b, a = bg[1], bg[2], bg[3], bg[4] or 1
				if splashy.fadestate == "colorout" then
					local remaining = math.max(0, math.min(1, splashy.coloralpha or 1))
					if endColor then
						local progress = 1 - remaining
						r = r + ((endColor[1] or r) - r) * progress
						g = g + ((endColor[2] or g) - g) * progress
						b = b + ((endColor[3] or b) - b) * progress
						a = a + ((endColor[4] == nil and 1 or endColor[4]) - a) * progress
					else
						a = a * remaining
					end
				end
				love.graphics.setColor(r, g, b, a)
				love.graphics.rectangle("fill", 0, 0, splashy.screenWidth, splashy.screenHeight)

				local imageAlpha
				if splashy.fadestate == "in" then
					imageAlpha = splashy.inalpha
				elseif splashy.fadestate == "hold" then
					imageAlpha = 1
				elseif splashy.fadestate == "out" then
					imageAlpha = splashy.outalpha
				else
					-- delayin / delayout / colorout: only the background shows, the image is hidden.
					imageAlpha = 0
				end

				love.graphics.setColor(1, 1, 1, imageAlpha)
				local drawX = centerwidth - centerimagewidth
				local drawY = centerheight - centerimageheight
				if quads then
					love.graphics.draw(splash, quads[splashy.currentFrame], drawX, drawY, 0, scale, scale)
				else
					love.graphics.draw(splash, drawX, drawY, nil, scale, scale)
				end
			end
		end

		love.graphics.setColor(1, 1, 1, 1)
	end
end

--- Renders Splashy.
-- This should be placed in love.update (dt)
function splashy.update(dt)
	if splashy.finished == false then
		for i = 1, #splashy.tweenlist do
			if splashy.count == i then
				local state = splashy.fadestate

				-- Advance the looping sprite-sheet animation, if this splash has one.
				-- Runs across every fade phase so the logo keeps cycling the whole time.
				local quads = splashy.quadList[i]
				if quads then
					local frameDuration = splashy.frameDurationList[i]
					splashy.frameTimer = splashy.frameTimer + dt
					while splashy.frameTimer >= frameDuration do
						splashy.frameTimer = splashy.frameTimer - frameDuration
						splashy.currentFrame = (splashy.currentFrame % #quads) + 1
					end
				end

				if state == "delayin" then
					-- Hold on the background color before the image starts fading in.
					splashy.delayTimer = splashy.delayTimer + dt
					if splashy.delayTimer >= (splashy.delayInitList[i] or 0) then
						splashy.delayTimer = 0
						splashy.tweenInList[i]:reset()
						splashy.outalpha = 1
						splashy.fadestate = "in"
					end
				elseif state == "in" then
					if splashy.tweenInList[i]:update(dt) then
						splashy.fadestate = "hold"
					end
				elseif state == "hold" then
					-- Keep the image fully shown before it fades out.
					splashy.delayTimer = splashy.delayTimer + dt
					if splashy.delayTimer >= (splashy.delayFinishList[i] or 0) then
						splashy.delayTimer = 0
						splashy.tweenOutList[i]:reset()
						splashy.inalpha = 1
						splashy.fadestate = "out"
					end
				elseif state == "out" then
					if splashy.tweenOutList[i]:update(dt) then
						splashy.fadestate = "delayout"
					end
				elseif state == "delayout" then
					-- Hold on the background color before it fades out (or is cut).
					splashy.delayTimer = splashy.delayTimer + dt
					if splashy.delayTimer >= (splashy.extraDelayList[i] or 0) then
						splashy.delayTimer = 0
						local colorFade = splashy.colorFadeList[i] or 0
						if colorFade > 0 then
							splashy.coloralpha = 1
							splashy.colorTween = tween.new(colorFade, splashy, { coloralpha = 0 })
							splashy.fadestate = "colorout"
						else
							splashy.fadestate = "advance"
						end
					end
				elseif state == "colorout" then
					-- Transition the background to its requested end color. Legacy
					-- callers without one retain the original transparent reveal.
					if splashy.colorTween:update(dt) then
						splashy.colorTween = nil
						splashy.fadestate = "advance"
					end
				end

				if splashy.fadestate == "advance" then
					splashy.tweenInList[i]:reset()
					splashy.tweenOutList[i]:reset()
					splashy.count = splashy.count + 1
					splashy.coloralpha = 1
					splashy.delayTimer = 0
					splashy.currentFrame = 1
					splashy.frameTimer = 0
					splashy.fadestate = "delayin"
				end
			end
		end

		if splashy.count >= #splashy.list + 1 then
			assert(type(splashy.onCompleteFunction) == "function", "onComplete needs a valid function.")

			splashy.finished = true

			splashy.onCompleteFunction()
		end
	end
end

return splashy
