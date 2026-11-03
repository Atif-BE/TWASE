-- Rig test of synced script messages (twase.send / twase.set_message_handler). A loose script mod: copy this folder
-- to <game>/data/campaigns/<campaign folder>/mods/twase_msgtest/ on every PC (e.g. campaigns/main_attila for 1212).
--
-- In the TWASE console (campaign context):
--   msgtest("hello")   sends a message; every PC logs it
--   msgtest_gold(10)   sends a message that gives the sender 10 gold on every PC (a state change: if a PC missed it,
--                      the treasuries would differ and the game would desync)
-- Every PC logs "[msgtest] ran ..." with the turn and the sender's treasury when the message ran, both synced.

local function log(text)
	if out then
		out("[msgtest] " .. text);
	else
		print("[msgtest] " .. text);
	end
end

if not (twase and twase.send and twase.set_message_handler) then
	log("this TWASE has no script messages, nothing set up");
	return;
end

twase.set_message_handler(function(sender, text)
	local cm = get_cm();
	local model = cm:model();
	local faction = model:world():faction_by_key(sender);
	if faction:is_null_interface() then
		log("ran: turn " .. model:turn_number() .. ", from an unknown faction " .. sender .. ": " .. text);
		return;
	end
	log("ran: turn " .. model:turn_number() .. ", from " .. sender .. " (treasury " .. faction:treasury() .. "): " .. text);

	local amount = text:match("^gold:(%d+)$");
	if amount then
		cm:treasury_mod(sender, tonumber(amount));
		log("gave " .. sender .. " " .. amount .. " gold, treasury now " .. faction:treasury());
	end
end);

function msgtest(text)
	twase.send(tostring(text));
	log("sent: " .. tostring(text));
end

function msgtest_gold(amount)
	msgtest("gold:" .. math.floor(tonumber(amount) or 1));
end

log("handler set");
