// Tests of the capital write (src/core/FactionCapital.hpp) on fake objects laid out with the given offsets.

#include "FactionCapital.hpp"
#include "Check.hpp"

#include <cstring>
#include <vector>

namespace C = FactionCapital;

namespace
{
constexpr C::Layout kLayout{0x00, 0x10, 0x18, 0x20, 0x28, 0x30, 0x08, 0x10};

struct Fake
{
    alignas(8) uint8_t faction[0x40] = {};
    alignas(8) uint8_t regionA[0x20] = {};
    alignas(8) uint8_t regionB[0x20] = {};
    alignas(8) uint8_t regionC[0x20] = {};
    alignas(8) uint8_t recordA[0x20] = {};
    alignas(8) uint8_t recordB[0x20] = {};
    void* regions[2] = {};
    int alive = 1;
    int groupA = 0;
    int groupB = 0;

    template<typename T>
    void Put(void* aBase, uint32_t aOffset, T aValue)
    {
        std::memcpy(static_cast<uint8_t*>(aBase) + aOffset, &aValue, sizeof(T));
    }
    template<typename T>
    T Get(const void* aBase, uint32_t aOffset) const
    {
        T v;
        std::memcpy(&v, static_cast<const uint8_t*>(aBase) + aOffset, sizeof(T));
        return v;
    }

    Fake()
    {
        Put<void*>(faction, kLayout.factionAlive, &alive);
        regions[0] = regionA;
        regions[1] = regionB;
        Put<uint32_t>(faction, kLayout.factionRegionCount, 2);
        Put<void**>(faction, kLayout.factionRegions, regions);
        Put<void*>(faction, kLayout.factionCapital, regionA);
        Put<void*>(faction, kLayout.factionHome, regionA);
        Put<void*>(faction, kLayout.factionGroup, &groupA);
        Put<void*>(regionA, kLayout.regionRecord, recordA);
        Put<void*>(regionB, kLayout.regionRecord, recordB);
        Put<void*>(regionC, kLayout.regionRecord, recordA);
        Put<void*>(recordA, kLayout.recordGroup, &groupA);
        Put<void*>(recordB, kLayout.recordGroup, &groupB);
    }

    bool Unchanged() const
    {
        return Get<void*>(faction, kLayout.factionCapital) == regionA && Get<void*>(faction, kLayout.factionHome) == regionA &&
               Get<void*>(faction, kLayout.factionGroup) == &groupA;
    }
};
} // namespace

void RunFactionCapitalTests()
{
    {
        Fake f;
        Check(C::Set(f.faction, f.regionB, kLayout) == C::Result::Ok, "an owned region becomes the capital");
        Check(f.Get<void*>(f.faction, kLayout.factionCapital) == f.regionB, "current capital set");
        Check(f.Get<void*>(f.faction, kLayout.factionHome) == f.regionB, "home capital set, as the save edit does");
        Check(f.Get<void*>(f.faction, kLayout.factionGroup) == &f.groupB, "group taken from the new region's record");
    }
    {
        Fake f;
        Check(C::Set(f.faction, f.regionC, kLayout) == C::Result::NotOwned && f.Unchanged(), "a region not in the faction's list");
    }
    {
        Fake f;
        Check(C::Set(f.faction, f.regionA, kLayout) == C::Result::AlreadyCapital && f.Unchanged(), "the current capital");
    }
    {
        Fake f;
        f.Put<void*>(f.faction, kLayout.factionAlive, nullptr);
        Check(C::Set(f.faction, f.regionB, kLayout) == C::Result::DeadFaction && f.Unchanged(), "a destroyed faction");
    }
    {
        Fake f;
        f.Put<void*>(f.regionB, kLayout.regionRecord, nullptr);
        Check(C::Set(f.faction, f.regionB, kLayout) == C::Result::NoRecord && f.Unchanged(), "a region without a record");
    }
    {
        Fake f;
        Check(C::Set(nullptr, f.regionB, kLayout) == C::Result::NoFaction, "no faction");
        Check(C::Set(f.faction, nullptr, kLayout) == C::Result::NoRegion && f.Unchanged(), "no region");
    }
    {
        Fake f;
        f.Put<uint32_t>(f.faction, kLayout.factionRegionCount, 1);
        Check(C::Set(f.faction, f.regionB, kLayout) == C::Result::NotOwned && f.Unchanged(), "only the first count entries are owned");
    }
    {
        Fake f;
        f.Put<void**>(f.faction, kLayout.factionRegions, nullptr);
        Check(C::Set(f.faction, f.regionB, kLayout) == C::Result::NotOwned && f.Unchanged(), "no region list");
    }
}
