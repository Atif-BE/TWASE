// Tests of the synced script message bytes (src/core/ScriptMessageFormat.hpp), against the layout read from the
// engine's writers and readers (docs/engine/commands.md).

#include "ScriptMessageFormat.hpp"
#include "Check.hpp"

namespace F = ScriptMessageFormat;

namespace
{
// Decodes a command as the executor hands it to the handler: the cursor after the 7-byte header
std::optional<F::Message> DecodeCommand(const std::vector<uint8_t>& aCommand, uint32_t aOffset = 0)
{
    std::vector<uint8_t> batch(aOffset, 0xAA);
    batch.insert(batch.end(), aCommand.begin(), aCommand.end());
    const uint32_t length = static_cast<uint32_t>(aCommand[0] | (aCommand[1] << 8));
    return F::Decode(batch.data(), aOffset, length, aOffset + F::HeaderSize);
}
} // namespace

void RunScriptMessageFormatTests()
{
    // the exact bytes: "twase1|f|hi" is 11 code units
    {
        const auto c = F::Encode(0x11223344, "f", "hi");
        const std::vector<uint8_t> expected = {
            36, 0,                    // length 7 + 5 + 2 + 22
            0x11, 0x22, 0x33, 0x44,   // hash, big-endian
            0,                        // flag
            0x88, 0, 0, 0, 0,         // unit 0
            0x0D, 11,                 // text, 11 units
            't', 0, 'w', 0, 'a', 0, 's', 0, 'e', 0, '1', 0, '|', 0, 'f', 0, '|', 0, 'h', 0, 'i', 0};
        Check(c == expected, "Encode produces the engine's layout");
    }

    // round trip, also at an offset in a batch and with every byte 1-255
    {
        std::string all;
        for (int b = 1; b < 256 && all.size() < 200; b++)
        {
            all.push_back(static_cast<char>(b));
        }
        const auto c = F::Encode(0xDEADBEEF, "mk_fact_genoa", all);
        Check(!c.empty(), "Encode accepts bytes 1-255");
        const auto m = DecodeCommand(c, 123);
        Check(m && m->sender == "mk_fact_genoa" && m->text == all, "Decode returns sender and bytes unchanged");
        const auto e = DecodeCommand(F::Encode(1, "s", ""));
        Check(e && e->sender == "s" && e->text.empty(), "an empty message");
        const auto bars = DecodeCommand(F::Encode(1, "s", "a|b|"));
        Check(bars && bars->sender == "s" && bars->text == "a|b|", "a message with bars");
    }

    // limits: 255 code units in all
    {
        const std::string sender = "abc";
        const size_t room = F::MaxTextUnits - F::Marker.size() - sender.size() - 1;
        const auto fits = F::Encode(1, sender, std::string(room, 'x'));
        Check(fits.size() == F::HeaderSize + F::UnitArgSize + F::TextArgHeader + 2 * F::MaxTextUnits, "the longest message fits");
        Check(DecodeCommand(fits).has_value(), "the longest message decodes");
        Check(fits[0] == (524 & 0xFF) && fits[1] == (524 >> 8), "the length's high byte");
        Check(F::Encode(1, sender, std::string(room + 1, 'x')).empty(), "one byte more is refused");
        Check(F::Encode(1, sender, std::string_view("a\0b", 3)).empty(), "a NUL byte is refused");
        Check(F::Encode(1, "", "x").empty(), "no sender is refused");
        Check(F::Encode(1, "a|b", "x").empty(), "a sender with a bar is refused");
        Check(F::Encode(1, std::string_view("a\0b", 3), "x").empty(), "a sender with a NUL byte is refused");
    }

    // what isn't ours stays the engine's
    {
        auto c = F::Encode(1, "s", "x");
        auto unit = c;
        unit[F::HeaderSize + 1] = 7;  // a real unit id
        Check(!DecodeCommand(unit), "a rename of a real unit");
        auto tag = c;
        tag[F::HeaderSize] = 0x82;  // another object type
        Check(!DecodeCommand(tag), "another object tag");
        auto marker = c;
        marker[F::HeaderSize + F::UnitArgSize + F::TextArgHeader] = 'T';
        Check(!DecodeCommand(marker), "text without the marker");
        auto wide = c;
        wide[F::HeaderSize + F::UnitArgSize + F::TextArgHeader + 1] = 1;  // a code unit above 0xFF
        Check(!DecodeCommand(wide), "a code unit above 0xFF");
        auto shortLength = c;
        shortLength[0] = static_cast<uint8_t>(shortLength[0] - 2);  // the command ends inside the text
        Check(!DecodeCommand(shortLength), "text running past the command's end");
        auto noSender = F::Encode(1, "s", "x");
        // "twase1||x": an empty sender
        std::vector<uint8_t> empty = noSender;
        empty[F::HeaderSize + F::UnitArgSize + F::TextArgHeader + 2 * F::Marker.size()] = '|';
        Check(!DecodeCommand(empty), "an empty sender");
        Check(!F::Decode(nullptr, 0, 0, 0), "no data");
        Check(!F::Decode(c.data(), F::HeaderSize, static_cast<uint32_t>(c.size()), 0), "a cursor before the command");
        Check(!F::Decode(c.data(), 0, F::HeaderSize - 1, F::HeaderSize), "a command shorter than its header");
        Check(F::Decode(c.data(), 0, static_cast<uint32_t>(c.size()), F::HeaderSize).has_value(), "the same bytes, well formed");
    }
}
