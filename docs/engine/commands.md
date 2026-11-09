# Campaign commands

How a player's action reaches the campaign model on every PC: the engine's command queue (the `CCQ_*` commands). Found in the Windows Steam `empire.retail.dll` (the 2026-04-02 build) with Ghidra; RVAs below are for that build.

## Commands

Every campaign action a player takes (recruit, build, move, rename, end turn, diplomacy, ...) is a **command**. There are 199 of them, named `CCQ_*` (e.g. `CCQ_ORDER_RECRUITMENT_ITEM`, `CCQ_SET_UNIT_CUSTOM_NAME`). The UI never changes the model itself: it writes a command into the queue, and the model runs the command later, in the same order on every PC.

Each command is registered at start-up by a static initialiser (e.g. `0x761D0` for `CCQ_SET_UNIT_CUSTOM_NAME`):

- the **hash** of its name (`0xD42470`, a string hash), kept in a global (`CCQ_SET_UNIT_CUSTOM_NAME`: `0x24694A8`)
- an entry in the command table (`0x703A50` returns the table, a hash map of 0x1C-byte entries: hash, name string, a version, the **handler**)

The registrations checked (end turn, create force, army legacy emblem, unit and settlement custom name) have version 0. The debug dump of a queue (`0xB1CDB0`) prints it as "(ver%d)"; nothing else reads it.

## The queue

The UI's queue is `*(*(*g_Campaign + 0xA54) + 0x2C) + 4` (`g_Campaign` = `0x28D52B0`): a 0x5000-byte buffer, its write cursor (a `uint32`) right after it at `+ 0x5000`. Recruitment (`0x1522B60`), the settlement rename (`0x14528A0`) and the diplomacy screen all write there. A script command (`create_force`, `0x742A80`) writes into the script interface's own queue (`*(interface + 4) + 4`), which is why a client's queued script commands run nowhere while its player commands reach every PC.

A command is written as:

| Bytes | Content |
|---|---|
| 2 | total length of the command, little-endian (patched in at the end) |
| 4 | the command's hash, **big-endian** |
| 1 | the version from its table entry (0) |
| ... | its arguments, each a tag byte and its data |

The writer functions are plain byte copies: `0x14324C0` (UI) / `0x1B6EE0` begin a command (`__thiscall` on a writer: two error bytes, the queue, the start; **no bounds check**), `0x325860` writes a tag and n bytes, `0x1BB580` (writer in ECX) patches the length in or, if a write overflowed, rolls the cursor back so the command is dropped. The argument writers check `cursor + n` without the tag byte (off by one).

Nothing downstream validates a command: one shorter than its header ends the executor's walk of that batch, on every PC. A writer must be exact and bounds-check itself. The queue object (0x5008 bytes, ctor `0x2CFB70`) is made with the `+ 0xA54` object (`0x765350`, `0x765E40`), so the pointer chain is resolved for every write, never cached. The UI appends without a lock: write only on the game's thread.

How the queue leaves the PC isn't traced. The campaign session objects' virtual + 0x8 (`0xD53700`, the MP one `0x7F8760`) copy a whole non-empty 0x5000-byte buffer into their pending slot when that slot is empty, and refuse while a submission is pending. The multiplayer layer (`0x1334090`, `submit_tick_data` `0x1337C70` to the "Command Relay Server", receive `0x12FFE20`) passes the bytes on unread; its tick checksum is only logged.

Argument encodings (writer / reader):

- **object**: a tag for the object type and its 4-byte id (`0xAB4CE0` writes `obj ? obj->id : 0`). Tags: unit `0x88`, settlement `0x82`. The reader (`0xAB1CF0` for units) looks the id up in the model's id map; **id 0 reads as "no object"** without an error.
- **text** (`CA::UniString`): tag `0x0D`, a length byte, then UTF-16LE code units (`0xD464A0` / `0xD45A90`). **At most 255 code units**: the writer truncates longer text.

## Running commands

Each model tick runs the tick's command batches (`0x7FD020`, `param_3[0x19015]` batches of 0x5004 bytes: a buffer and its size) through the executor `0xB0B6A0` (`__thiscall` on the batch, the model on the stack). For each command it looks up the hash in the command table and calls the handler:

```c
void __cdecl handler(READER* reader, MODEL* model);
```

The reader: `+ 0x4` error byte (set when the command is shorter than its header or a read fails), `+ 0x8` the batch's buffer, `+ 0xC` the command's offset, `+ 0x10` its length, `+ 0x14` the read cursor (starts after the 7-byte header), `+ 0x20` the id map (`*(model + 0x1C84)`). The batch carries **no sender**: a handler can't tell which player issued the command.

The handlers don't check who owns the object (the UI does that before issuing). `CCQ_SET_UNIT_CUSTOM_NAME`'s handler (`0xAE55C0`):

```c
UniString name;
UNIT* unit = read_object(reader, 0x88);  // 0xAB1CF0
read_text(reader, &name);                // 0xAC36C0
if (!reader->error && unit) unit_set_custom_name(unit, &name);  // 0x6F9470
```

No UI in Attila issues `CCQ_SET_UNIT_CUSTOM_NAME`: its hash is read only by its registration, and the handler is reached only through the table. The other command walkers don't call it: the debug dump (also used by the replay loader `0x811BD0`, which only prints) and the battle executor `0x30B8F0`, which has its own table. Batches are also written to replay files (`0xD4FD60`); whether saves keep or re-run commands isn't known.

## Script messages (TWASE)

TWASE's synced script messages (`twase.send`, [Lua API](../modding/lua-api.md)) use exactly this: a `CCQ_SET_UNIT_CUSTOM_NAME` for unit id 0 with the message as its text. It runs on every PC in the queue's order. The engine finds no unit and does nothing, with or without TWASE; TWASE's hook on the handler reads the text and passes it to Lua.
