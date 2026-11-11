-- Virtual filesystem path of the engine folder: "engine" in this repository,
-- or "<mount>/engine" when bootstrap.lua loads the engine from a subfolder
-- such as vendor/wave-engine. use it for files the engine opens directly
-- (threads, data files, default assets), require() resolves on its own
return "engine"
