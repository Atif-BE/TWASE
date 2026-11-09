-- Rig test of the campaign AI levers (attila-strategist notes/roadmap.md, Phase 0). Single player is enough. A loose
-- script mod: copy this folder to <game>/data/campaigns/<campaign folder>/mods/twase_aitest/ (main_attila for the grand
-- campaign). Everything is logged to twase_aitest.log in the game folder and to the console.
--
-- In the TWASE console (campaign context):
--   Goals and wars (TWASE hooks, tests 0.2 and 0.3). On by default: the first goals are logged in full, then a count
--   per turn; every war is logged, just before it's declared, with the path that started it. Without the hooks (GOG,
--   a failed attach) only the stock-lever commands below are set up.
--     aitest_protect("att_fact_western_roman_empire")  AI war goals against that faction are removed
--     aitest_unprotect()                                 back to the AI's own scores
--     aitest_verbose(200)                                log the next 200 goals in full again
--     aitest_counts()                                    log the goal count of the turn so far
--   Stock levers, no new TWASE code:
--     aitest_manager("att_fact_visigothi", "DO_NOTHING")  test 0.1: CliExecute("set_cai_faction_manager ...")
--     aitest_stance("att_fact_visigothi", "att_fact_western_roman_empire")  read the stance between two factions
--     aitest_promote(a, b, ...)                           cm:cai_strategic_stance_manager_promote_specified_stance_towards_target_faction(a, b, ...)
--     aitest_war(a, b)                                    cm:force_declare_war(a, b)
--
-- What to look for, per test:
--   0.3  "goal" lines: owner and target are faction keys (not empty; if empty, send the TWASE log with debug logging,
--        it has the raw pointers), generator 1 / 17 goals point at factions the owner dislikes or borders.
--   0.2  after aitest_protect(X), no "declare_war: ... on X" by the deal path (caller 0xC6DD74) from an AI over several
--        turns, while wars elsewhere go on. Start with an AI that is about to attack X (e.g. a horde next to X, or
--        aitest_promote towards bitter enemies). Expected anyway: allies called into an existing war on X (other path),
--        and declare_war calls that declare nothing (already at war). The removed goals are only the AI's own plans.
--   0.1  after aitest_manager(F, "DO_NOTHING"), F stops moving and recruiting, and the end turn still finishes.

local function log(text)
	local line = "[aitest] " .. text;
	local f = io.open("twase_aitest.log", "a");
	if f then
		f:write(os.date("%H:%M:%S") .. " " .. line .. "\n");
		f:close();
	end
	if type(output) == "function" then
		output(line);
	else
		print(line);
	end
end

local function turn_number()
	return get_cm():model():turn_number();
end

-- the last turn number read; during the AI's turn the model can hand back something other than a number (seen on
-- the rig, 2026-11-09: a function), and then this one is used
local last_turn_number = -1;
local function turn()
	local ok, number = pcall(turn_number);
	if ok and type(number) == "number" then
		last_turn_number = number;
	end
	return last_turn_number;
end

-- the generators whose goals start the owner's own wars (atlas campaign_ai.md, "Generators"):
-- 1 DECLARE_WAR_ON_FACTIONS_I_DISLIKE, 17 DECLARE_WAR_ON_NEARBY_FACTIONS. Not 4 (OFFER_TO_JOIN_WAR_AGAINST_FACTION_I_DISLIKE):
-- its target may be the faction invited to join, not the one attacked; its goals are logged so the log can tell.
local war_generators = { [1] = true, [17] = true };

local protected = nil;
local verbose_left = 200;
local removed_per_turn = 30;    -- removed goals logged in full per turn, the rest only counted
local removed_left = removed_per_turn;
local counts = {};      -- per turn: goals seen, goals changed
local counted_turn = -1;

-- per-turn goal statistics for the unattended bench (autopilot below): seen, empty owner / target keys, answering,
-- and per generator the goals and those with an empty target
local stats = nil;
local function stats_reset()
	stats = { seen = 0, removed = 0, empty_owner = 0, empty_target = 0, answering = 0, gen = {}, gen_empty_target = {} };
end
stats_reset();

local function stats_line(t)
	local parts = {};
	for g, n in pairs(stats.gen) do
		parts[#parts + 1] = g .. ":" .. n .. "/" .. (stats.gen_empty_target[g] or 0);
	end
	table.sort(parts);
	return string.format("goalstats: turn %d seen %d removed %d empty_owner %d empty_target %d answering %d gens %s", t,
		stats.seen, stats.removed, stats.empty_owner, stats.empty_target, stats.answering, table.concat(parts, ","));
end

local function flush_counts()
	if counted_turn >= 0 and counts.seen then
		log("turn " .. counted_turn .. ": " .. counts.seen .. " goals, " .. (counts.changed or 0) .. " removed by protect");
	end
	counts = {};
end

if twase and twase.set_ai_goal_handler then
	twase.set_ai_goal_handler(function(goal)
		local now = turn();
		if now ~= counted_turn then
			flush_counts();
			counted_turn = now;
			removed_left = removed_per_turn;
		end
		counts.seen = (counts.seen or 0) + 1;
		stats.seen = stats.seen + 1;
		if goal.owner == "" then stats.empty_owner = stats.empty_owner + 1; end
		if goal.answering then stats.answering = stats.answering + 1; end
		stats.gen[goal.generator] = (stats.gen[goal.generator] or 0) + 1;
		if goal.target == "" then
			stats.empty_target = stats.empty_target + 1;
			stats.gen_empty_target[goal.generator] = (stats.gen_empty_target[goal.generator] or 0) + 1;
		end

		-- false removes the goal; nil keeps it
		local result = nil;
		if protected and goal.target == protected and war_generators[goal.generator] then
			result = false;
			counts.changed = (counts.changed or 0) + 1;
			stats.removed = stats.removed + 1;
		end

		local show = verbose_left > 0;
		if show then
			verbose_left = verbose_left - 1;
		elseif result == false and removed_left > 0 then
			removed_left = removed_left - 1;
			show = true;
		end
		if not show and goal.generator == 4 and protected and removed_left > 0
			and (goal.target == protected or goal.owner == protected) then
			removed_left = removed_left - 1;
			show = true;
		end
		if show then
			log(string.format("goal: turn %d generator %d type %d owner %s target %s score %.2f amount %d%s%s", now,
				goal.generator, goal.type, goal.owner, goal.target, goal.score, goal.amount,
				goal.answering and " (answering a deal)" or "", result == false and " -> removed (protected)" or ""));
		end
		return result;
	end);
	log("goal handler set");
else
	log("this TWASE has no campaign AI hooks: the goal and war tests are off");
end

if twase and twase.set_war_declared_handler then
	twase.set_war_declared_handler(function(attacker, target, caller)
		local path = ({ ["0xADD2A0"] = "command (force_declare_war or a player)", ["0xC6DD74"] = "deal (AI or player)" })[caller]
			or "other path";
		log(string.format("declare_war: turn %d %s on %s, caller %s (%s)%s", turn(), attacker, target, caller, path,
			target == protected and "  <-- PROTECTED TARGET" or ""));
	end);
	log("war handler set");
end

function aitest_protect(key)
	protected = key;
	log("protecting " .. tostring(key) .. " from AI war goals");
end

function aitest_unprotect()
	log("no longer protecting " .. tostring(protected));
	protected = nil;
end

-- the goal count of the turn so far (it's otherwise logged when the next turn's first goal arrives)
function aitest_counts()
	flush_counts();
	counted_turn = -1;
end

function aitest_verbose(n)
	verbose_left = tonumber(n) or 200;
	log("logging the next " .. verbose_left .. " goals in full");
end

function aitest_manager(faction, manager)
	local command = "set_cai_faction_manager " .. tostring(faction) .. " " .. tostring(manager);
	local ok, err = pcall(CliExecute, command);
	log("CliExecute(\"" .. command .. "\"): " .. (ok and "no error" or ("error: " .. tostring(err))) ..
		". Now end the turn and watch " .. tostring(faction));
end

function aitest_stance(a, b)
	local ok, stance = pcall(function() return get_cm():campaign_ai():strategic_stance_between_factions(a, b); end);
	log("stance " .. tostring(a) .. " -> " .. tostring(b) .. ": " .. (ok and tostring(stance) or ("error: " .. tostring(stance))) ..
		" (+3 best friends ... -3 bitter enemies)");
end

function aitest_promote(a, b, ...)
	local args = { ... };
	local ok, err = pcall(function()
		return get_cm():cai_strategic_stance_manager_promote_specified_stance_towards_target_faction(a, b, unpack(args));
	end);
	local shown = {};
	for i = 1, select("#", ...) do
		shown[i] = tostring(args[i]);
	end
	log("promote stance " .. tostring(a) .. " -> " .. tostring(b) .. " (" .. table.concat(shown, ", ") .. "): " ..
		(ok and "no error" or ("error: " .. tostring(err))));
	aitest_stance(a, b);
end

function aitest_war(a, b)
	local ok, err = pcall(function() get_cm():force_declare_war(a, b); end);
	log("force_declare_war(" .. tostring(a) .. ", " .. tostring(b) .. "): " .. (ok and "queued" or ("error: " .. tostring(err))));
end

-- Autopilot, for the unattended bench (attila-1212-mp tools/aibench.py). It only runs when the bench has written
-- twase_aitest_plan.txt into the game folder; without that file the mod is the interactive rig above. Plan lines are
-- key=value:
--   run           a name for the logs
--   turns         player turns to play before quitting
--   goal_handler  0: unset the goal handler (war logging only)
--   war_handler   0: unset the war handler
--   protect       a faction key: AI war goals against it are removed (aitest_protect)
--   freeze        a faction key, or "auto" (the AI faction with the most armies): set to DO_NOTHING on the first turn
--   verbose       goals logged in full (default 0; per-turn goal stats are always logged)
-- Progress goes to twase_aitest_marks.txt, one short line per step, which the bench timestamps as they appear.
local function read_plan()
	local f = io.open("twase_aitest_plan.txt", "r");
	if not f then
		return nil;
	end
	local plan = {};
	for line in f:lines() do
		local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$");
		if k then
			plan[k] = v;
		end
	end
	f:close();
	return plan;
end

local function mark(text)
	local f = io.open("twase_aitest_marks.txt", "a");
	if f then
		f:write(text .. "\n");
		f:close();
	end
end

local plan = read_plan();

if plan then
	local cm = get_cm();
	local turns = tonumber(plan.turns) or 5;
	local run = plan.run or "?";
	local first_turn, ended_turn, end_requested_at = nil, nil, nil;
	local freeze_key, last_positions = nil, nil;
	local done, stuck_logged = false, false;

	-- vanilla's timer (lib_misc_campaign add_callback, a TimeTrigger)
	local function after(seconds, fn, name)
		if type(add_callback) == "function" then
			add_callback(fn, seconds, name);
		elseif type(cm.callback) == "function" then
			cm:callback(fn, seconds, name);
		else
			log("autopilot: no timer function, running " .. tostring(name) .. " now");
			fn();
		end
	end

	local function ui_root()
		return scripting and scripting.m_root or nil;
	end

	-- popups that would wait for the player, pressed whenever they show (each press is logged): { panel, button },
	-- the button looked up inside the panel when one is given. The event panel's accept is scoped to it, so a
	-- diplomacy offer's accept is never pressed.
	local press = { { nil, "button_autoresolve" }, { nil, "button_dismiss" }, { nil, "button_continue" },
		{ nil, "button_close" }, { nil, "button_ok" }, { "events", "button_accept" } };
	local function press_popups()
		local root = ui_root();
		if not root then
			return;
		end
		for _, entry in ipairs(press) do
			local panel, id = entry[1], entry[2];
			local ok, pressed = pcall(function()
				local parent = root;
				if panel then
					parent = root:Find(panel);
					if not parent or not UIComponent(parent):Visible() then
						return false;
					end
					parent = UIComponent(parent);
				end
				local found = parent:Find(id);
				if not found then
					return false;
				end
				local c = UIComponent(found);
				if not c:Visible() then
					return false;
				end
				c:SimulateClick();
				return true;
			end);
			if ok and pressed then
				log("autopilot: pressed " .. (panel and (panel .. "/") or "") .. id .. " (turn " .. turn() .. ")");
			end
		end
	end

	-- for a run that stopped moving: every visible component under the UI root, as an indented tree (ids, and the
	-- state of buttons), so the log names what waits for the player. scripting.m_root is already a UIComponent: wrapping
	-- it again gave a bad pointer and crashed the game in UIComponent::Visible (rig, 2026-11-09).
	local function dump_ui()
		local root = ui_root();
		if not root then
			log("autopilot: stuck, no UI root");
			return;
		end
		local lines, budget = {}, 400;
		local function walk(c, depth)
			if budget <= 0 or depth > 8 then
				return;
			end
			for i = 0, c:ChildCount() - 1 do
				local child = UIComponent(c:Find(i));
				if child:Visible() then
					budget = budget - 1;
					local state = "";
					pcall(function() state = " (" .. tostring(child:CurrentState()) .. ")"; end);
					lines[#lines + 1] = string.rep("  ", depth) .. child:Id() .. state;
					walk(child, depth + 1);
				end
			end
		end
		local ok, err = pcall(walk, root, 0);
		log("autopilot: stuck, visible UI" .. (ok and "" or (" (stopped: " .. tostring(err) .. ")")) .. ":\n" ..
			table.concat(lines, "\n"));
	end

	local function pick_freeze()
		local best, best_n = nil, 0;
		local ok, err = pcall(function()
			local list = cm:model():world():faction_list();
			for i = 0, list:num_items() - 1 do
				local f = list:item_at(i);
				if not f:is_human() and not f:is_dead() then
					local n = f:military_force_list():num_items();
					if n > best_n then
						best, best_n = f:name(), n;
					end
				end
			end
		end);
		if not ok then
			log("autopilot: picking the faction to freeze failed: " .. tostring(err));
		end
		return best;
	end

	-- the frozen faction's characters (cqi -> position), forces and units: did it move or recruit?
	local function freeze_snapshot(t)
		local ok, err = pcall(function()
			local f = cm:model():world():faction_by_key(freeze_key);
			if f:is_null_interface() or f:is_dead() then
				log(string.format("freeze: turn %d %s dead", t, freeze_key));
				return;
			end
			local positions, chars = {}, f:character_list();
			for i = 0, chars:num_items() - 1 do
				local c = chars:item_at(i);
				positions[tostring(c:cqi())] = c:logical_position_x() .. "," .. c:logical_position_y();
			end
			local units, forces = 0, f:military_force_list();
			for i = 0, forces:num_items() - 1 do
				units = units + forces:item_at(i):unit_list():num_items();
			end
			local moved = 0;
			if last_positions then
				for cqi, pos in pairs(positions) do
					if last_positions[cqi] and last_positions[cqi] ~= pos then
						moved = moved + 1;
					end
				end
			end
			last_positions = positions;
			log(string.format("freeze: turn %d %s characters %d forces %d units %d moved %d", t, freeze_key,
				chars:num_items(), forces:num_items(), units, moved));
		end);
		if not ok then
			log("freeze: snapshot error " .. tostring(err));
		end
	end

	local player_key = nil;
	local function players_turn()
		local ok, yes = pcall(function() return cm:model():world():whose_turn_is_it():name() == player_key; end);
		return ok and yes;
	end

	local function request_end(t)
		ended_turn = t;
		end_requested_at = os.time();
		mark("end " .. t);
		press_popups();
		local ok, err = pcall(function() cm:end_turn(true); end);
		if not ok then
			local ok2, err2 = pcall(function() scripting.game_interface:end_turn(); end);
			if not ok2 then
				log("autopilot: end_turn failed: " .. tostring(err) .. " / " .. tostring(err2));
				mark("error end_turn");
			end
		end
	end

	-- every 3 s: press waiting popups; if a requested end turn hasn't come round in 10 minutes (a 1212 AI turn takes up to about 4), log the screen once
	-- and ask again
	local function heartbeat()
		if done then
			return;
		end
		press_popups();
		if end_requested_at and not stuck_logged and os.time() - end_requested_at > 30 and players_turn() then
			stuck_logged = true;
			mark("refused " .. tostring(ended_turn));
			log("autopilot: the end turn was refused (still the player's turn 30 s later)");
			dump_ui();
			after(10, function() request_end(ended_turn); end, "twase_aitest_retry");
		elseif end_requested_at and os.time() - end_requested_at > 600 and not stuck_logged then
			stuck_logged = true;
			mark("stuck " .. tostring(ended_turn));
			dump_ui();
			request_end(ended_turn);
		end
		after(3, heartbeat, "twase_aitest_heartbeat");
	end

	local last_turn = nil;
	local function on_player_turn(f, t)
		if t == last_turn then
			return;
		end
		last_turn = t;
		if not first_turn then
			first_turn = t;
			player_key = f:name();
			log("autopilot: run " .. run .. ", player " .. f:name() .. ", first turn " .. t .. ", " .. turns .. " turns");
			mark("player " .. f:name());
			if plan.freeze == "auto" then
				freeze_key = pick_freeze();
			elseif plan.freeze and plan.freeze ~= "" then
				freeze_key = plan.freeze;
			end
			if freeze_key then
				aitest_manager(freeze_key, "DO_NOTHING");
				mark("freeze " .. freeze_key);
			end
			heartbeat();
		else
			log(stats_line(t - 1));
		end
		stats_reset();
		stuck_logged = false;
		end_requested_at = nil;
		mark("turn " .. t);
		if freeze_key then
			freeze_snapshot(t);
		end
		if t - first_turn >= turns then
			done = true;
			mark("done");
			log("autopilot: done after " .. turns .. " turns");
			after(3, function() pcall(CliExecute, "quit"); end, "twase_aitest_quit");
			return;
		end
		after(2, function() request_end(t); end, "twase_aitest_end");
	end

	if plan.goal_handler == "0" and twase and twase.set_ai_goal_handler then
		twase.set_ai_goal_handler(nil);
		log("autopilot: goal handler unset for this run");
	end
	if plan.war_handler == "0" and twase and twase.set_war_declared_handler then
		twase.set_war_declared_handler(nil);
		log("autopilot: war handler unset for this run");
	end
	if plan.protect and plan.protect ~= "" then
		aitest_protect(plan.protect);
	end
	verbose_left = tonumber(plan.verbose) or 0;

	events.FactionTurnStart[#events.FactionTurnStart + 1] = function(context)
		local ok, err = pcall(function()
			local f = context:faction();
			if f:is_human() then
				on_player_turn(f, turn());
			end
		end);
		if not ok then
			log("autopilot: turn start error " .. tostring(err));
			mark("error turn_start");
		end
	end;
	-- a loaded save starts inside the player's turn, which fires no FactionTurnStart: start from the first tick, with a
	-- timer as the fallback in case the mod loaded after it
	local function kick(why)
		if first_turn then
			return;
		end
		local ok, err = pcall(function()
			local f = cm:model():world():faction_by_key(cm:get_local_faction());
			log("autopilot: starting from " .. why);
			on_player_turn(f, turn());
		end);
		if not ok then
			log("autopilot: start error " .. tostring(err));
			mark("error start");
		end
	end
	if type(events.FirstTickAfterWorldCreated) == "table" then
		events.FirstTickAfterWorldCreated[#events.FirstTickAfterWorldCreated + 1] = function() kick("the first tick"); end;
	end
	pcall(after, 20, function() kick("the start timer"); end, "twase_aitest_start");
	mark("loaded " .. run);
end

log("loaded, turn " .. turn());
