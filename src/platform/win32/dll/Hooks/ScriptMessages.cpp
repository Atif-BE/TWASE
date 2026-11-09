#include "ScriptMessages.hpp"

#include "../App.hpp"
#include "../Hooking/DetourTransaction.hpp"
#include "../Hooking/Hook.hpp"
#include "Platform.hpp"
#include "ScriptMessageFormat.hpp"
#include "UI/LuaConsole.hpp"

#include "../../sdk/Attila/Addresses.hpp"
#include "../../sdk/Attila/VFSTypes.hpp"
#include "../../sdk/Attila/Lua/LuaGameEnvironment.hpp"
#include "../../sdk/Attila/Lua/LuaRuntime.hpp"

// A message is a CCQ_SET_UNIT_CUSTOM_NAME command for unit id 0, its text "twase1|<sender faction key>|<message>"
// (ScriptMessageFormat.hpp). The UI's player commands run on every PC in the same order (a client's included), so the
// message does too. The engine finds no unit 0 and renames nothing, on a PC with or without TWASE; our hook on the
// command's handler reads the text before the engine does. No UI in Attila issues this command, so nothing else comes
// through the hook.

using namespace sdk::Attila;
namespace Addr = sdk::Attila::Addresses;
namespace Format = ScriptMessageFormat;

namespace
{
// room left in the queue after a message: the engine's begin writer (0x14324C0) doesn't check bounds, so the player's
// next command must always fit (the longest message is 524 bytes)
constexpr uint32_t kQueueReserve = 0x400;

bool isAttached = false;

void Handler(uint8_t* reader, void* model);
Hook<decltype(&Handler)> Handler_fnc(Addr::Ccq_SetUnitCustomName_Handler, &Handler);

uintptr_t Base()
{
    return App::Get()->GetEmpireDllAddr();
}

template<typename T>
bool Read(uintptr_t aAddress, T& aOut)
{
    return aAddress && Platform::SafeRead(aAddress, aOut);
}

// *g_Campaign, the campaign the UI issues its commands for (null outside a campaign)
uintptr_t Campaign()
{
    uintptr_t campaign = 0;
    return Read(Base() + Addr::g_Campaign, campaign) ? campaign : 0;
}

// The UI's command queue: the buffer, its cursor at + capacity
uint8_t* Queue()
{
    uintptr_t handle = 0, owner = 0;
    if (!Read(Campaign() + Addr::Campaign_Handle, handle) || !Read(handle + Addr::ModelHandle_CommandQueue, owner) || !owner)
    {
        return nullptr;
    }
    return reinterpret_cast<uint8_t*>(owner + Addr::CommandQueue_Buffer);
}

// The local player's faction key (the factions record's key), empty outside a campaign
std::string LocalFactionKey()
{
    const uintptr_t campaign = Campaign();
    if (!campaign)
    {
        return {};
    }
    using LocalFaction_t = void*(TWASE_THISCALL*)(uintptr_t campaign);
    const auto* faction = static_cast<const uint8_t*>(reinterpret_cast<LocalFaction_t>(Base() + Addr::Campaign_LocalFaction)(campaign));
    const auto* key = faction ? *reinterpret_cast<const TempString* const*>(faction + Addr::Faction_Record) : nullptr;
    return key && key->data && key->length > 0 ? std::string(key->data, key->length) : std::string();
}

// A message ran on this PC: the campaign script's handler (twase.set_message_handler), called the same way on every PC
void Deliver(const Format::Message& aMessage)
{
    spdlog::info("[ScriptMessages] ran: from {}, {} bytes: {}", aMessage.sender, aMessage.text.size(), aMessage.text);
    LuaConsole::Get().AddLog(LuaConsole::LogLevel::Info, "[ScriptMessages] ran: from %s: %s", aMessage.sender.c_str(),
                             aMessage.text.c_str());

    // the campaign scripts' state, looked up each time: battles and loads replace the states
    lua_State* L = LuaGameEnvironment::FindState(Hooks::ScriptMessagesHook::CampaignContextName);
    if (!L)
    {
        spdlog::warn("[ScriptMessages] no campaign script state, the message isn't delivered");
        return;
    }
    const int top = LuaRuntime::gettop(L);
    LuaRuntime::getfield(L, LUA_REGISTRYINDEX, Hooks::ScriptMessagesHook::HandlerKey);
    if (LuaRuntime::type(L, -1) != LUA_TFUNCTION)
    {
        spdlog::warn("[ScriptMessages] no message handler set (twase.set_message_handler), the message isn't delivered");
        LuaRuntime::settop(L, top);
        return;
    }
    // neither contains a NUL byte (Decode only accepts code units 1-255)
    LuaRuntime::pushstring(L, aMessage.sender.c_str());
    LuaRuntime::pushstring(L, aMessage.text.c_str());
    if (LuaRuntime::pcall(L, 2, 0, 0) != 0)
    {
        const char* error = LuaRuntime::tolstring(L, -1, nullptr);
        spdlog::error("[ScriptMessages] the message handler failed: {}", error ? error : "unknown error");
        LuaConsole::Get().AddLog(LuaConsole::LogLevel::Error, "[ScriptMessages] the message handler failed: %s",
                                 error ? error : "unknown error");
    }
    LuaRuntime::settop(L, top);
}

void Handler(uint8_t* reader, void* model)
{
    std::optional<Format::Message> message;
    if (reader && reader[Addr::CommandReader_Error] == 0)
    {
        message = Format::Decode(*reinterpret_cast<const uint8_t* const*>(reader + Addr::CommandReader_Data),
                                 *reinterpret_cast<const uint32_t*>(reader + Addr::CommandReader_Start),
                                 *reinterpret_cast<const uint32_t*>(reader + Addr::CommandReader_Length),
                                 *reinterpret_cast<const uint32_t*>(reader + Addr::CommandReader_Cursor));
    }
    // with unit 0 the engine renames nothing, as on a PC without TWASE
    Handler_fnc(reader, model);
    if (message)
    {
        Deliver(*message);
    }
}
} // namespace

const char* Hooks::ScriptMessagesHook::Send(std::string_view aText)
{
    if (!isAttached)
    {
        return "script messages are unavailable on this game build";
    }
    if (aText.find('\0') != std::string_view::npos)
    {
        return "the message cannot contain a NUL byte";
    }
    const std::string sender = LocalFactionKey();
    uint8_t* queue = Queue();
    uint32_t hash = 0;
    if (sender.empty() || !queue || !Read(Base() + Addr::Ccq_SetUnitCustomName_Hash, hash) || hash == 0)
    {
        return "no campaign";
    }
    const std::vector<uint8_t> command = Format::Encode(hash, sender, aText);
    if (command.empty())
    {
        return "the message is too long";
    }
    // the same bytes the engine's writers produce (begin 0x14324C0, tag writer 0x325860, text writer 0xD464A0, end
    // 0x1BB580), appended where the next UI command would go
    auto& cursor = *reinterpret_cast<uint32_t*>(queue + Addr::CommandQueue_Capacity);
    if (cursor > Addr::CommandQueue_Capacity || Addr::CommandQueue_Capacity - cursor < command.size() + kQueueReserve)
    {
        return "the command queue is full";
    }
    std::memcpy(queue + cursor, command.data(), command.size());
    cursor += static_cast<uint32_t>(command.size());
    spdlog::info("[ScriptMessages] sent: from {}, {} bytes: {}", sender, aText.size(), aText);
    return nullptr;
}

bool Hooks::ScriptMessagesHook::IsReady()
{
    return isAttached;
}

bool Hooks::ScriptMessagesHook::Attach()
{
    if (static_cast<uint32_t>(Addr::Ccq_SetUnitCustomName_Handler) == 0 || static_cast<uint32_t>(Addr::Ccq_SetUnitCustomName_Hash) == 0)
    {
        spdlog::warn("Script messages have no addresses for this game build, twase.send is unavailable");
        return false;
    }
    DetourTransaction transaction;
    if (!transaction.IsValid())
    {
        return false;
    }
    if (const auto result = Handler_fnc.Attach(); result != NO_ERROR)
    {
        spdlog::error("Could not attach the script messages hook. Detours error code: {}", result);
        return false;
    }
    if (!transaction.Commit())
    {
        return false;
    }
    isAttached = true;
    spdlog::info("The script messages hook was attached");
    return true;
}

bool Hooks::ScriptMessagesHook::Detach()
{
    if (!isAttached)
    {
        return true;
    }
    const auto result = Handler_fnc.Detach();
    isAttached = result != NO_ERROR;
    return !isAttached;
}
