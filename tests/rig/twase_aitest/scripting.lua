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
--   0.2  after aitest_protect(X), no "declare_war: ... on X" by the deal path (caller 0xC6DD6F) from an AI over several
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

local function turn()
	local ok, number = pcall(turn_number);
	return ok and number or -1;
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

		-- false removes the goal; nil keeps it
		local result = nil;
		if protected and goal.target == protected and war_generators[goal.generator] then
			result = false;
			counts.changed = (counts.changed or 0) + 1;
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
		local path = ({ ["0xADD29B"] = "command (force_declare_war or a player)", ["0xC6DD6F"] = "deal (AI or player)" })[caller]
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

log("loaded, turn " .. turn());
