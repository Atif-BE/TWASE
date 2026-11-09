#include "CampaignAI.hpp"

#include "../App.hpp"
#include "../Hooking/DetourTransaction.hpp"
#include "../Hooking/Hook.hpp"
#include "Platform.hpp"
#include "UI/LuaConsole.hpp"

#include "../../sdk/Attila/Addresses.hpp"
#include "../../sdk/Attila/VFSTypes.hpp"
#include "../../sdk/Attila/Lua/LuaGameEnvironment.hpp"
#include "../../sdk/Attila/Lua/LuaRuntime.hpp"

#include <cmath>
#include <intrin.h>

// Deal generation 0xC8C060 runs the generators in order, calling 0xBF1A80(index, ...) before each one; the generators
// build their goals with 0xBF1A40(type, ctx, score, amount, target, extra). We note the generator index and the
// generating faction, and hand each goal to Lua before it is built, so a new score lands in the goal itself. The goals
// are sorted and filtered (score > 0) after all generators ran. Deal generation can still add to a goal's score later
// (cai_negotiation_matching_goal_bonus, 10), so a removed goal gets a large negative score, not 0.
//
// Which argument holds which faction is only partly known (atlas campaign_ai.md, open question 6 and the goal fields):
// the target is a CAI faction entry, the owner the negotiation component's + 0x90 (read by 0xBF1A80 as one too). Both
// are read only as CAI faction entries (+ 0xEC the FACTION): a wrong guess gives an empty key, never another faction's,
// and the log has the raw pointers, so the first rig run settles it.
//
// FACTION::declare_war 0x83CEA0 takes several 12-byte objects by value. A C++ detour would copy them to a new stack
// slot before calling the original, which breaks objects that hold pointers to themselves. So its detour is naked: it
// reads ecx and the first argument, calls the logger, and jumps to the original with the caller's stack untouched. The
// handler runs on entry, before the engine checks the pair (a call can declare nothing).

using namespace sdk::Attila;
namespace Addr = sdk::Attila::Addresses;

namespace
{
// a removed goal's score: far enough below 0 that the +10 matching bonus can't lift it, not so far that it swamps a
// sum of scores
constexpr float kRemovedScore = -1000.0f;

bool isAttached = false;

// deal generation state, model thread only. Saved and restored around each call, so nested calls don't mix.
int depth = 0;              // > 0 inside 0xC8C060
int generator = -1;         // the generator whose context was set up last, in the innermost deal generation
std::string ownerKey;       // the innermost deal generation's faction
lua_State* goalState = nullptr; // the campaign state if it has a goal handler, else null
bool deliveredAnswer = false;   // the innermost deal generation answers a deal (its deal argument isn't null)
bool inGoalHandler = false; // no nested calls of the same handler
bool inWarHandler = false;
int goalErrors = 0;
int warErrors = 0;

bool __fastcall DealGeneration(void* self, void* edx, void* a, void* b, void* deal);
void* __fastcall GeneratorBegin(void* ctx, void* edx, int index, void* x, void* component);
void* __fastcall GoalCtor(void* goal, void* edx, int type, int ctx, float score, int amount, void* target, int extra);

Hook<decltype(&DealGeneration)> DealGeneration_fnc(Addr::Cai_DealGeneration, &DealGeneration);
Hook<decltype(&GeneratorBegin)> GeneratorBegin_fnc(Addr::Cai_GoalGeneratorBegin, &GeneratorBegin);
Hook<decltype(&GoalCtor)> GoalCtor_fnc(Addr::Cai_Goal_ctor, &GoalCtor);

// the naked declare_war detour jumps here (Detours sets it to the trampoline)
void* declareWarOriginal = nullptr;

uintptr_t Base()
{
    return App::Get()->GetEmpireDllAddr();
}

template<typename T>
bool Read(uintptr_t aAddress, T& aOut)
{
    return aAddress && Platform::SafeRead(aAddress, aOut);
}

// The factions record's key of a FACTION*, empty if it doesn't look like one. Faction keys are identifiers
// (att_fact_..., mk_fact_...), which rules out most pointers that aren't factions.
std::string KeyOfFaction(uintptr_t aFaction)
{
    uintptr_t record = 0;
    TempString key{};
    if (!Read(aFaction + Addr::Faction_Record, record) || !Read(record, key) || !key.data || key.length < 4 ||
        key.length > 96)
    {
        return {};
    }
    std::string out(key.length, '\0');
    if (!Platform::SafeRead(reinterpret_cast<uintptr_t>(key.data), out.data(), key.length))
    {
        return {};
    }
    for (const char c : out)
    {
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
        {
            return {};
        }
    }
    return out;
}

// The key of a CAI faction entry (its FACTION at + 0xEC), the form of the goals' target and the negotiation
// component's own faction. One form only: if it's the wrong one the key is empty, never another faction's.
std::string KeyOfCaiFaction(uintptr_t aCaiFaction)
{
    uintptr_t faction = 0;
    return Read(aCaiFaction + Addr::CaiFaction_Faction, faction) ? KeyOfFaction(faction) : std::string();
}

// At most this many handler errors are logged per handler, then only a count every 1000
constexpr int kLoggedErrors = 5;

// The campaign state if it holds a function in its registry field aKey, else null
lua_State* StateWithHandler(const char* aKey)
{
    lua_State* L = LuaGameEnvironment::FindState(Hooks::CampaignAIHook::CampaignContextName);
    if (!L)
    {
        return nullptr;
    }
    const int top = LuaRuntime::gettop(L);
    LuaRuntime::getfield(L, LUA_REGISTRYINDEX, aKey);
    const bool hasHandler = LuaRuntime::type(L, -1) == LUA_TFUNCTION;
    LuaRuntime::settop(L, top);
    return hasHandler ? L : nullptr;
}

// A failing handler fails for every goal (thousands per end turn), so only the first errors are logged in full
void LogHandlerError(lua_State* L, const char* aWhich, int& aCount)
{
    ++aCount;
    const char* error = LuaRuntime::tolstring(L, -1, nullptr);
    if (aCount <= kLoggedErrors)
    {
        spdlog::error("[CampaignAI] the {} handler failed: {}{}", aWhich, error ? error : "unknown error",
                      aCount == kLoggedErrors ? " (further errors are only counted)" : "");
        LuaConsole::Get().AddLog(LuaConsole::LogLevel::Error, "[CampaignAI] the %s handler failed: %s", aWhich,
                                 error ? error : "unknown error");
    }
    else if (aCount % 1000 == 0)
    {
        spdlog::error("[CampaignAI] the {} handler has failed {} times, last: {}", aWhich, aCount,
                      error ? error : "unknown error");
    }
}

// An RVA as text: lua_Number is a float here, which can't hold every RVA exactly
std::string RvaText(uintptr_t aRva)
{
    return fmt::format("0x{:X}", aRva);
}

// handler(goal) -> a number (the new score), false (remove the goal) or nil (keep it);
// goal = {generator, type, owner, target, score, amount, answering}
float CallGoalHandler(lua_State* L, int aType, const std::string& aTarget, float aScore, int aAmount)
{
    const int top = LuaRuntime::gettop(L);
    LuaRuntime::getfield(L, LUA_REGISTRYINDEX, Hooks::CampaignAIHook::GoalHandlerKey);
    // the handler may have removed itself since the deal generation started
    if (LuaRuntime::type(L, -1) != LUA_TFUNCTION)
    {
        LuaRuntime::settop(L, top);
        return aScore;
    }
    LuaRuntime::createtable(L, 0, 7);
    LuaRuntime::pushboolean(L, deliveredAnswer ? 1 : 0);
    LuaRuntime::setfield(L, -2, "answering");
    LuaRuntime::pushnumber(L, static_cast<lua_Number>(generator));
    LuaRuntime::setfield(L, -2, "generator");
    LuaRuntime::pushnumber(L, static_cast<lua_Number>(aType));
    LuaRuntime::setfield(L, -2, "type");
    LuaRuntime::pushstring(L, ownerKey.c_str());
    LuaRuntime::setfield(L, -2, "owner");
    LuaRuntime::pushstring(L, aTarget.c_str());
    LuaRuntime::setfield(L, -2, "target");
    LuaRuntime::pushnumber(L, aScore);
    LuaRuntime::setfield(L, -2, "score");
    LuaRuntime::pushnumber(L, static_cast<lua_Number>(aAmount));
    LuaRuntime::setfield(L, -2, "amount");

    float score = aScore;
    inGoalHandler = true;
    if (LuaRuntime::pcall(L, 1, 1, 0) != 0)
    {
        LogHandlerError(L, "AI goal", goalErrors);
    }
    else if (LuaRuntime::type(L, -1) == LUA_TNUMBER)
    {
        // a NaN or infinite score would break the engine's sort of the goals: keep the original then
        const auto value = static_cast<float>(LuaRuntime::tonumber(L, -1));
        if (std::isfinite(value))
        {
            score = value;
        }
    }
    else if (LuaRuntime::type(L, -1) == LUA_TBOOLEAN && !LuaRuntime::toboolean(L, -1))
    {
        // far below 0, so the bonuses deal generation adds later can't make it a deal term again
        score = kRemovedScore;
    }
    inGoalHandler = false;
    LuaRuntime::settop(L, top);
    return score;
}

bool __fastcall DealGeneration(void* self, void* edx, void* a, void* b, void* deal)
{
    const int savedGenerator = generator;
    std::string savedOwner = std::move(ownerKey);
    lua_State* const savedState = goalState;
    const bool savedAnswer = deliveredAnswer;

    generator = -1;
    goalState = StateWithHandler(Hooks::CampaignAIHook::GoalHandlerKey);
    deliveredAnswer = deal != nullptr;
    ownerKey.clear();
    if (goalState || spdlog::should_log(spdlog::level::debug))
    {
        uintptr_t own = 0;
        if (Read(reinterpret_cast<uintptr_t>(self) + Addr::NegotiationComponent_CaiFaction, own))
        {
            ownerKey = KeyOfCaiFaction(own);
        }
        spdlog::debug("[CampaignAI] deal generation (depth {}): owner {} (cai entry {:#x}), a {} b {} deal {}", depth,
                      ownerKey, own, a, b, deal);
    }

    ++depth;
    const bool result = DealGeneration_fnc(self, edx, a, b, deal);
    --depth;

    generator = savedGenerator;
    ownerKey = std::move(savedOwner);
    goalState = savedState;
    deliveredAnswer = savedAnswer;
    return result;
}

void* __fastcall GeneratorBegin(void* ctx, void* edx, int index, void* x, void* component)
{
    if (depth > 0)
    {
        generator = index;
    }
    return GeneratorBegin_fnc(ctx, edx, index, x, component);
}

bool IsGeneratorCall(uintptr_t aCaller)
{
    return (aCaller >= Addr::Cai_GeneratorsBegin && aCaller < Addr::Cai_GeneratorsEnd) ||
           (aCaller >= Addr::Cai_NearbyGeneratorsBegin && aCaller < Addr::Cai_NearbyGeneratorsEnd);
}

void* __fastcall GoalCtor(void* goal, void* edx, int type, int ctx, float score, int amount, void* target, int extra)
{
    // only goals of the generators, inside a deal generation (cai_print_goals runs the generators outside one), and
    // only when someone wants them: the key reads are syscalls (Platform::SafeRead)
    if (depth > 0 && generator >= 0 && !inGoalHandler && (goalState || spdlog::should_log(spdlog::level::debug)))
    {
        const auto caller = reinterpret_cast<uintptr_t>(_ReturnAddress()) - Base();
        if (IsGeneratorCall(caller))
        {
            const std::string targetKey = KeyOfCaiFaction(reinterpret_cast<uintptr_t>(target));
            const float newScore = goalState ? CallGoalHandler(goalState, type, targetKey, score, amount) : score;
            if (spdlog::should_log(spdlog::level::debug))
            {
                spdlog::debug("[CampaignAI] goal: generator {} type {} owner {} target {} (cai entry {}) score {:.2f} -> {:.2f} amount {} caller {:X}",
                              generator, type, ownerKey, targetKey, target, score, newScore, amount, caller);
            }
            score = newScore;
        }
    }
    return GoalCtor_fnc(goal, edx, type, ctx, score, amount, target, extra);
}

// Called by the naked detour before the original runs. 0x83CEA0 runs the same check (0x716560) on *ecx and on its
// first argument and reads FACTION fields (+ 0x824) of the first argument, so ecx is FACTION** (the attacker *ecx) and
// the first argument a FACTION*. One form each: a wrong guess gives an empty key, never another faction's.
void __cdecl OnDeclareWar(uintptr_t aSelf, uintptr_t aTarget, uintptr_t aReturn)
{
    // the war is still logged when a handler started it; only the war handler isn't called again from itself
    const auto caller = aReturn - Base();
    uintptr_t attackerFaction = 0;
    const std::string attacker = Read(aSelf, attackerFaction) ? KeyOfFaction(attackerFaction) : std::string();
    const std::string target = KeyOfFaction(aTarget);

    // debug only: declare_war is also called for pairs already at war, which would flood every player's log
    spdlog::debug("[CampaignAI] declare_war: {} ({:#x}) on {} ({:#x}), caller {:X}", attacker, attackerFaction, target,
                  aTarget, caller);

    if (inWarHandler)
    {
        return;
    }
    if (lua_State* L = StateWithHandler(Hooks::CampaignAIHook::WarHandlerKey))
    {
        const int top = LuaRuntime::gettop(L);
        LuaRuntime::getfield(L, LUA_REGISTRYINDEX, Hooks::CampaignAIHook::WarHandlerKey);
        LuaRuntime::pushstring(L, attacker.c_str());
        LuaRuntime::pushstring(L, target.c_str());
        LuaRuntime::pushstring(L, RvaText(caller).c_str());
        inWarHandler = true;
        if (LuaRuntime::pcall(L, 3, 0, 0) != 0)
        {
            LogHandlerError(L, "war declared", warErrors);
        }
        inWarHandler = false;
        LuaRuntime::settop(L, top);
    }
}

// Entry: [esp] the return address, [esp + 4] the target, ecx the attacker. Saves eax/ecx/edx (the registers a C call
// may change), calls OnDeclareWar(ecx, target, return address), restores them and jumps to the original with the stack
// as the caller left it.
__declspec(naked) void DeclareWarDetour()
{
    __asm {
        push eax                    // eax too: an optimised caller could keep a value in it across the call
        push ecx
        push edx
        push dword ptr [esp + 0xC]  // the return address
        push dword ptr [esp + 0x14] // the target (first argument)
        push ecx
        call OnDeclareWar
        add esp, 12
        pop edx
        pop ecx
        pop eax
        jmp dword ptr [declareWarOriginal]
    }
}
} // namespace

void Hooks::CampaignAIHook::HandlerChanged()
{
    goalErrors = 0;
    warErrors = 0;
}

bool Hooks::CampaignAIHook::IsReady()
{
    return isAttached;
}

bool Hooks::CampaignAIHook::Attach()
{
    if (static_cast<uint32_t>(Addr::Cai_DealGeneration) == 0 || static_cast<uint32_t>(Addr::Cai_GoalGeneratorBegin) == 0 ||
        static_cast<uint32_t>(Addr::Cai_Goal_ctor) == 0 || static_cast<uint32_t>(Addr::Faction_DeclareWar) == 0)
    {
        spdlog::warn("The campaign AI hooks have no addresses for this game build, the AI handlers are unavailable");
        return false;
    }
    DetourTransaction transaction;
    if (!transaction.IsValid())
    {
        return false;
    }
    declareWarOriginal = reinterpret_cast<void*>(Base() + static_cast<uint32_t>(Addr::Faction_DeclareWar));
    auto result = DealGeneration_fnc.Attach();
    if (result == NO_ERROR)
        result = GeneratorBegin_fnc.Attach();
    if (result == NO_ERROR)
        result = GoalCtor_fnc.Attach();
    if (result == NO_ERROR)
        result = DetourAttach(&declareWarOriginal, reinterpret_cast<void*>(&DeclareWarDetour));
    if (result != NO_ERROR)
    {
        spdlog::error("Could not attach the campaign AI hooks. Detours error code: {}", result);
        return false;
    }
    if (!transaction.Commit())
    {
        return false;
    }
    isAttached = true;
    spdlog::info("The campaign AI hooks were attached");
    return true;
}

bool Hooks::CampaignAIHook::Detach()
{
    if (!isAttached)
    {
        return true;
    }
    auto result = DetourDetach(&declareWarOriginal, reinterpret_cast<void*>(&DeclareWarDetour));
    if (result == NO_ERROR)
        result = GoalCtor_fnc.Detach();
    if (result == NO_ERROR)
        result = GeneratorBegin_fnc.Detach();
    if (result == NO_ERROR)
        result = DealGeneration_fnc.Detach();
    isAttached = result != NO_ERROR;
    return !isAttached;
}
