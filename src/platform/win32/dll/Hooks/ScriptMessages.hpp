#pragma once

#include <string_view>

// Synced script messages (twase.send): a text that runs on every PC of a multiplayer campaign at the same point of the
// model, through the engine's command queue (docs/engine/commands.md).
namespace Hooks::ScriptMessagesHook
{
// Commits its own Detours transaction; a failure (or a build without the addresses) leaves twase.send unavailable.
bool Attach();
// true when there was nothing to detach
bool Detach();
bool IsReady();

// Queues a message from the local faction. nullptr on success, else why it wasn't sent.
const char* Send(std::string_view aText);
} // namespace Hooks::ScriptMessagesHook
