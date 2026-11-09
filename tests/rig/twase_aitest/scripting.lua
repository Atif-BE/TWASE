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

local log_count = 0;  -- lines logged so far (the autopilot uses it to tell whether a heartbeat did anything)
local function log(text)
	log_count = log_count + 1;
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

	-- Timers of our own: a TimeTrigger with a unique string id per call. Vanilla's add_callback reuses numeric ids
	-- (0, 1, 2, ...), so another script's trigger with the same id ran our callbacks early (rig, 2026-11-09).
	local pending, timer_count = {}, 0;
	events.TimeTrigger[#events.TimeTrigger + 1] = function(context)
		local fn = pending[context.string];
		if fn then
			pending[context.string] = nil;
			fn();
		end
	end;
	local function after(seconds, fn, name)
		timer_count = timer_count + 1;
		local id = "twase_aitest_" .. tostring(name) .. "_" .. timer_count;
		pending[id] = fn;
		local ok, err = pcall(function() scripting.game_interface:add_time_trigger(id, seconds); end);
		if not ok then
			pending[id] = nil;
			log("autopilot: add_time_trigger failed for " .. tostring(name) .. ": " .. tostring(err));
		end
	end

	local function ui_root()
		return scripting and scripting.m_root or nil;
	end

	-- popups that would wait for the player, pressed whenever they show (each press is logged). Each entry is a path of
	-- component ids, looked up one level at a time and pressed only when every step is visible: a plain Find returns
	-- the first match anywhere below, which for the events panel is the accept button of its hidden dilemma layout
	-- (events/event_dilemma/accept/button_accept), not the visible one (rig, 2026-11-09). SimulateLClick: on the
	-- events panel's visible accept, SimulateClick did nothing and SimulateLClick closed it.
	local press = {
		{ "events", "button_set", "accept", "button_accept" },
		-- an AI's deal offer to the player opens the diplomacy screen and waits; declined, so the runs don't depend on
		-- what the player accepts (each declined offer can be followed by the next AI's)
		{ "diplomacy_dropdown", "offers_panel", "button_set2", "button_cancel" },
		-- a diplomacy notice with only an accept (button_set3); it held the AI turn for minutes (rig, 2026-11-09)
		{ "diplomacy_dropdown", "offers_panel", "button_set3", "button_accept" },
		{ "diplomacy_dropdown", "offers_panel", "button_set1", "button_accept" },
		{ "popup_pre_battle", "button_autoresolve" },
		{ "button_autoresolve" }, { "button_dismiss" }, { "button_continue" }, { "button_ok" },
	};
	local function find_visible(path)
		local c = ui_root();
		for _, id in ipairs(path) do
			local found = c and c:Find(id);
			if not found then
				return nil;
			end
			c = UIComponent(found);
			if not c:Visible() then
				return nil;
			end
		end
		return c;
	end
	local function press_popups()
		if not ui_root() then
			return;
		end
		for _, path in ipairs(press) do
			local ok, pressed = pcall(function()
				local c = find_visible(path);
				if not c or c:CurrentState() == "inactive" then
					return false;
				end
				c:SimulateLClick();
				return true;
			end);
			if ok and pressed then
				log("autopilot: pressed " .. table.concat(path, "/") .. " (turn " .. turn() .. ")");
			end
		end
	end

	-- for a run that stopped moving: every visible component under the UI root, as an indented tree (ids, and the
	-- state of buttons), so the log names what waits for the player. scripting.m_root is already a UIComponent: wrapping
	-- it again gave a bad pointer and crashed the game in UIComponent::Visible (rig, 2026-11-09).
	local function dump_ui(from, label)
		local root = from or ui_root();
		label = label or "stuck, visible UI";
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
		log("autopilot: " .. label .. (ok and "" or (" (stopped: " .. tostring(err) .. ")")) .. ":\n" ..
			table.concat(lines, "\n"));
	end

	-- An event message that requires a response greys out End Turn (rig, 2026-11-09: the events tab's
	-- "notification" child in state requires_response, End Turn inactive, the messages unread in events_dropdown).
	-- While that holds: open the unread messages one at a time (events_dropdown > list_box > msg), and in the open
	-- events panel press accept, then, if the message still waits, its other active buttons in turn. The open panel's
	-- tree is logged once per turn so the log names its buttons.
	local function child(c, id)
		local found = c:Find(id);
		return found and UIComponent(found) or nil;
	end
	local function visible_child(c, id)
		local found = c and child(c, id);
		return (found and found:Visible()) and found or nil;
	end
	local function needs_response()
		local root = ui_root();
		local tab = root and child(root, "tab_events");
		local note = tab and child(tab, "notification");
		return note ~= nil and note:CurrentState() == "requires_response";
	end
	local skip_buttons = { button_close = true, button_minimise = true, button_info = true, button_encyclopedia = true };
	local function buttons_in(c, out)
		for i = 0, c:ChildCount() - 1 do
			local b = UIComponent(c:Find(i));
			if b:Visible() then
				local id = b:Id();
				if (id:find("^button_") or id:find("choice")) and not skip_buttons[id] and b:CurrentState() == "active" then
					out[#out + 1] = b;
				end
				buttons_in(b, out);
			end
		end
		return out;
	end
	local message_index, answer_tries, panel_logged_turn, answered, last_open = 0, 0, nil, false, nil;
	local answer_exit = "never ran";
	local function answer_messages()
		answer_exit = "ran";
		local ok, err = pcall(function()
			local root = ui_root();
			local panel = visible_child(root, "events");
			local dilemma = panel and visible_child(panel, "event_dilemma");
			-- an open panel is handled every heartbeat, flagged or not: a dilemma can stay open with the events tab no
			-- longer showing requires_response (rig, 2026-11-09: the first choice click didn't take, the retry came
			-- only with the next message, 2 minutes later)
			if not dilemma and not needs_response() then
				answer_tries = 0;
				answer_exit = "no response needed";
				return;
			end
			if dilemma then  -- a dilemma: its first choice
				if panel_logged_turn ~= turn() then
					panel_logged_turn = turn();
					dump_ui(dilemma, "a dilemma, its layout:");
				end
				local list = buttons_in(dilemma, {});
				if #list > 0 then
					local b = list[answer_tries % #list + 1];
					answer_tries = answer_tries + 1;
					log("autopilot: dilemma choice " .. b:Id() .. " (turn " .. turn() .. ")");
					b:SimulateLClick();
					answered = true;
				end
				return;
			end
			if panel then
				answer_exit = "events panel open";
				if panel_logged_turn ~= turn() then
					panel_logged_turn = turn();
					dump_ui(panel, "a message requires a response, its panel:");
				end
				answer_tries = answer_tries + 1;
				if answer_tries > 2 then  -- accept (press_popups) didn't do it: the panel's other buttons, in turn
					local list = buttons_in(panel, {});
					if #list > 0 then
						local b = list[(answer_tries - 3) % #list + 1];
						log("autopilot: answering with " .. b:Id() .. " (turn " .. turn() .. ")");
						b:SimulateLClick();
						answered = true;
					end
				end
				return;
			end
			local drop = root:Find("events_dropdown");
			local box = drop and child(UIComponent(drop), "list_box");
			if not box or box:ChildCount() == 0 then
				log("autopilot: a message requires a response, but no message list was found");
				return;
			end
			if last_open and os.time() - last_open < 3 then
				answer_exit = "opened one less than 3 s ago";
				return;
			end
			last_open = os.time();
			-- the first unread message (its dy_title in state "unread"), else the next one in turn
			local pick = nil;
			for i = 0, box:ChildCount() - 1 do
				local m = UIComponent(box:Find(i));
				local title = m:Find("dy_title");
				if not pick and title and UIComponent(title):CurrentState() == "unread" then
					pick = i;
				end
			end
			if not pick then
				pick = message_index % box:ChildCount();
				message_index = message_index + 1;
			end
			local msg = UIComponent(box:Find(pick));
			log("autopilot: opening message " .. (pick + 1) .. " of " .. box:ChildCount() .. " (turn " .. turn() .. ")");
			msg:SimulateLClick();
			answered = true;
		end);
		if not ok then
			log("autopilot: answering messages failed: " .. tostring(err));
		end
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

	local player_key, last_end_request = nil, nil;
	local function players_turn()
		local ok, yes = pcall(function() return cm:model():world():whose_turn_is_it():name() == player_key; end);
		return ok and yes;
	end

	local function request_end(t)
		ended_turn = t;
		last_end_request = os.time();
		if not end_requested_at then
			end_requested_at = os.time();
		end
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
	-- live commands for working out a stuck screen: Lua in twase_aitest_cmd.lua in the game folder is run once (then the
	-- file is deleted), with AITEST = { root, child, dump, log } for the helpers; its result is logged.
	AITEST = { root = ui_root, child = child, dump = function(c, label) dump_ui(c, label or "dump:"); end, log = log };
	local function run_commands()
		local f = io.open("twase_aitest_cmd.lua", "r");
		if not f then
			return;
		end
		local code = f:read("*a");
		f:close();
		os.remove("twase_aitest_cmd.lua");
		local fn, err = loadstring(code, "twase_aitest_cmd");
		if not fn then
			log("cmd: compile error " .. tostring(err));
			return;
		end
		setfenv(fn, getfenv(1));  -- the mod's environment (scripting, UIComponent, AITEST), not the bare global one
		local ok, result = pcall(fn);
		log("cmd: " .. (ok and ("ok " .. tostring(result)) or ("error " .. tostring(result))));
	end

	local last_action = nil;
	local heartbeat_body;
	local function heartbeat()
		if done then
			return;
		end
		local ok, err = pcall(heartbeat_body);
		if not ok then
			log("autopilot: heartbeat error " .. tostring(err));
		end
		after(3, heartbeat, "twase_aitest_heartbeat");
	end
	heartbeat_body = function()
		run_commands();
		local lines_before = log_count;
		press_popups();
		answer_messages();
		if log_count ~= lines_before then
			last_action = os.time();
		elseif end_requested_at and os.time() - (last_action or 0) >= 30 then
			last_action = os.time();
			local st = {};
			pcall(function()
				local root = ui_root();
				st[#st + 1] = "needs_response " .. tostring(needs_response());
				for _, id in ipairs({ "events", "diplomacy_dropdown", "ai_turns" }) do
					st[#st + 1] = id .. " " .. tostring(visible_child(root, id) ~= nil);
				end
				st[#st + 1] = "end turn " .. tostring(UIComponent(root:Find("button_end_turn")):CurrentState());
				st[#st + 1] = "last open " .. tostring(last_open and (os.time() - last_open) or "never") .. " s ago";
				st[#st + 1] = "last end request " .. tostring(os.time() - (last_end_request or 0)) .. " s ago";
				st[#st + 1] = "answer_messages: " .. answer_exit;
			end);
			log("autopilot: idle 30 s: " .. table.concat(st, ", "));
		end
		-- After a panel is answered the game can sit idle with the end turn not taken (rig, 2026-11-09: stalls of
		-- minutes that ended 2 s after a second end-turn request, with ai_turns showing the whole time, so ai_turns
		-- doesn't mean the AI is busy). While an end turn is pending and no panel waits on screen, ask again every 15 s.
		if end_requested_at and os.time() - (last_end_request or 0) >= 15 then
			local busy = false;
			pcall(function()
				for _, id in ipairs({ "events", "diplomacy_dropdown" }) do
					if visible_child(ui_root(), id) then
						busy = true;
					end
				end
			end);
			if not busy then
				log("autopilot: no panel open, asking for the end turn again");
				request_end(ended_turn);
			end
		end
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
