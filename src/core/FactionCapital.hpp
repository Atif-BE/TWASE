#pragma once

#include <cstdint>
#include <cstring>

// Sets a faction's capital the way a save edit plus reload does (docs/engine/campaign-model.md, "Capital"):
// current capital = home capital = region, and the capital group from the region's DB record. Platform-free, so it
// can be tested without the game (tests/faction_capital.cpp).
namespace FactionCapital
{
struct Layout
{
    uint32_t factionAlive;       // void*, null once destroyed
    uint32_t factionCapital;     // REGION*, the current capital (the Lua home_region)
    uint32_t factionHome;        // REGION*, the original capital (taking it back makes it the capital)
    uint32_t factionGroup;       // the home capital's record field, used to pick a new capital
    uint32_t factionRegionCount; // u32
    uint32_t factionRegions;     // REGION**
    uint32_t regionRecord;       // regions record*
    uint32_t recordGroup;        // pointer-sized field of the regions record
};

enum class Result
{
    Ok,
    NoFaction,
    DeadFaction,
    NoRegion,
    NotOwned,
    AlreadyCapital,
    NoRecord,
};

inline const char* Describe(Result aResult)
{
    switch (aResult)
    {
    case Result::Ok: return "ok";
    case Result::NoFaction: return "no faction";
    case Result::DeadFaction: return "the faction is destroyed";
    case Result::NoRegion: return "no region";
    case Result::NotOwned: return "the faction does not own the region";
    case Result::AlreadyCapital: return "the region is already the capital";
    case Result::NoRecord: return "the region has no record";
    }
    return "unknown";
}

namespace Detail
{
template<typename T>
T Read(const void* aBase, uint32_t aOffset)
{
    T value;
    std::memcpy(&value, static_cast<const uint8_t*>(aBase) + aOffset, sizeof(T));
    return value;
}

template<typename T>
void Write(void* aBase, uint32_t aOffset, T aValue)
{
    std::memcpy(static_cast<uint8_t*>(aBase) + aOffset, &aValue, sizeof(T));
}
} // namespace Detail

// Checks, then writes the three fields. Nothing is written unless the result is Ok.
inline Result Set(void* aFaction, void* aRegion, const Layout& aLayout)
{
    using Detail::Read;
    if (!aFaction)
    {
        return Result::NoFaction;
    }
    if (!Read<void*>(aFaction, aLayout.factionAlive))
    {
        return Result::DeadFaction;
    }
    if (!aRegion)
    {
        return Result::NoRegion;
    }

    const auto count = Read<uint32_t>(aFaction, aLayout.factionRegionCount);
    auto* const* regions = Read<void* const*>(aFaction, aLayout.factionRegions);
    bool owned = false;
    for (uint32_t i = 0; regions && i < count && !owned; i++)
    {
        owned = regions[i] == aRegion;
    }
    if (!owned)
    {
        return Result::NotOwned;
    }
    if (Read<void*>(aFaction, aLayout.factionCapital) == aRegion)
    {
        return Result::AlreadyCapital;
    }
    const void* record = Read<const void*>(aRegion, aLayout.regionRecord);
    if (!record)
    {
        return Result::NoRecord;
    }

    Detail::Write<void*>(aFaction, aLayout.factionCapital, aRegion);
    Detail::Write<void*>(aFaction, aLayout.factionHome, aRegion);
    Detail::Write<void*>(aFaction, aLayout.factionGroup, Read<void*>(record, aLayout.recordGroup));
    return Result::Ok;
}
} // namespace FactionCapital
