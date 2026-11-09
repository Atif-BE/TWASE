#pragma once

// Campaign AI hooks (attila-atlas engine/campaign_ai.md):
// - AI goals: every goal the 20 deal generators build for an AI faction goes to the Lua function set with
//   twase.set_ai_goal_handler, which may return a new score, or false to remove the goal (it gets a large negative
//   score, so later bonuses can't lift it above 0, where goals become deal terms).
// - Wars: every call of FACTION::declare_war goes to the function set with twase.set_war_declared_handler, on entry,
//   before the engine's own checks: a call for a pair already at war, or a dead faction, declares nothing. Observe
//   only: the call can't be skipped safely (see Addresses.hpp, Faction_DeclareWar).
// The AI runs on every PC of a multiplayer campaign, so both handlers run on every PC and must decide only from synced
// state (no local faction, UI, time or random numbers).
namespace Hooks::CampaignAIHook
{
// Commits its own Detours transaction; a failure (or a build without the addresses) leaves the handlers unused.
bool Attach();
// true when there was nothing to detach
bool Detach();
bool IsReady();
// a handler was set or removed: its errors are logged in full again
void HandlerChanged();

// The handlers, in the registry of the campaign scripts' Lua state (decoda_name CampaignContextName)
inline constexpr const char* GoalHandlerKey = "twase_ai_goal_handler";
inline constexpr const char* WarHandlerKey = "twase_war_declared_handler";
inline constexpr const char* CampaignContextName = "EpisodicScriptingEnv";
} // namespace Hooks::CampaignAIHook
