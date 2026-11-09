// Platform-free unit tests. Build and run: xmake build tests && xmake run tests

#include "Check.hpp"

#include <cstdio>
#include <cstdlib>

namespace
{
int failures = 0;
}

void Check(bool aOk, const char* aWhat)
{
    if (!aOk)
    {
        std::printf("FAIL: %s\n", aWhat);
        failures++;
    }
}

int main()
{
    RunScriptMessageFormatTests();
    RunFactionCapitalTests();
    if (failures == 0)
    {
        std::printf("all tests passed\n");
    }
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
