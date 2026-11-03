#pragma once

#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// The bytes of a synced script message (docs/engine/commands.md): a campaign command
//   u16 length (LE, header included) | u32 command hash (BE) | u8 flag (0) | 0x88 u32 unit id (0) | 0x0D u8 count, UTF-16LE
// whose text is "twase1|<sender>|<message>", each byte of the text one code unit (1-255). Platform-free, so it can be
// tested without the game (tests/script_message_format.cpp).
namespace ScriptMessageFormat
{
inline constexpr std::string_view Marker = "twase1|";
inline constexpr size_t MaxTextUnits = 255;   // the engine's text: a count byte (its writer truncates)
inline constexpr uint32_t HeaderSize = 7;
inline constexpr uint8_t TagUnit = 0x88;
inline constexpr uint8_t TagText = 0x0D;
inline constexpr uint32_t UnitArgSize = 5;    // tag + u32 id
inline constexpr uint32_t TextArgHeader = 2;  // tag + count

struct Message
{
    std::string sender;
    std::string text;
};

// The command for `aText` from `aSender`; empty if it can't be sent (too long, a NUL byte, no sender or one with '|')
inline std::vector<uint8_t> Encode(uint32_t aHash, std::string_view aSender, std::string_view aText)
{
    if (aSender.empty() || aSender.find_first_of(std::string_view("|\0", 2)) != std::string_view::npos ||
        aText.find('\0') != std::string_view::npos)
    {
        return {};
    }
    const size_t count = Marker.size() + aSender.size() + 1 + aText.size();
    if (count > MaxTextUnits)
    {
        return {};
    }
    std::string text;
    text.reserve(count);
    text.append(Marker).append(aSender).append("|").append(aText);

    const uint32_t size = HeaderSize + UnitArgSize + TextArgHeader + 2 * static_cast<uint32_t>(count);
    std::vector<uint8_t> out(size, 0);
    out[0] = static_cast<uint8_t>(size);
    out[1] = static_cast<uint8_t>(size >> 8);
    out[2] = static_cast<uint8_t>(aHash >> 24);
    out[3] = static_cast<uint8_t>(aHash >> 16);
    out[4] = static_cast<uint8_t>(aHash >> 8);
    out[5] = static_cast<uint8_t>(aHash);
    out[6] = 0;  // the flag of every registration checked
    uint8_t* p = out.data() + HeaderSize;
    p[0] = TagUnit;  // + unit id 0: no unit
    p[UnitArgSize] = TagText;
    p[UnitArgSize + 1] = static_cast<uint8_t>(count);
    p += UnitArgSize + TextArgHeader;
    for (size_t i = 0; i < count; i++)
    {
        p[2 * i] = static_cast<uint8_t>(text[i]);  // high byte 0
    }
    return out;
}

// The message of the command whose arguments start at `aCursor` in `aData` (the command spans [aStart, aStart +
// aLength)), if it's a unit rename for unit 0 with our marker
inline std::optional<Message> Decode(const uint8_t* aData, uint32_t aStart, uint32_t aLength, uint32_t aCursor)
{
    const uint64_t end = static_cast<uint64_t>(aStart) + aLength;
    const uint64_t cursor = aCursor;
    if (!aData || cursor < aStart || cursor + UnitArgSize + TextArgHeader > end)
    {
        return std::nullopt;
    }
    const uint8_t* p = aData + aCursor;
    uint32_t unit = 0;
    std::memcpy(&unit, p + 1, sizeof(unit));
    if (p[0] != TagUnit || unit != 0 || p[UnitArgSize] != TagText)
    {
        return std::nullopt;
    }
    const uint32_t count = p[UnitArgSize + 1];
    if (cursor + UnitArgSize + TextArgHeader + 2ull * count > end)
    {
        return std::nullopt;
    }
    const uint8_t* units = p + UnitArgSize + TextArgHeader;
    std::string text;
    text.reserve(count);
    for (uint32_t i = 0; i < count; i++)
    {
        const uint16_t value = static_cast<uint16_t>(units[2 * i] | (units[2 * i + 1] << 8));
        if (value == 0 || value > 0xFF)
        {
            return std::nullopt;
        }
        text.push_back(static_cast<char>(value));
    }
    if (!text.starts_with(Marker))
    {
        return std::nullopt;
    }
    const size_t bar = text.find('|', Marker.size());
    if (bar == std::string::npos || bar == Marker.size())
    {
        return std::nullopt;
    }
    return Message{text.substr(Marker.size(), bar - Marker.size()), text.substr(bar + 1)};
}
} // namespace ScriptMessageFormat
