#pragma once

// The tests' shared check: prints a failure and counts it (tests/main.cpp reports the total)
void Check(bool aOk, const char* aWhat);

void RunScriptMessageFormatTests();
void RunFactionCapitalTests();
