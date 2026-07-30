#ifndef RUNNER_AUTOSTART_H_
#define RUNNER_AUTOSTART_H_

#include <windows.h>

#include <string>

// Launch-at-logon for the current Windows user, backed by the HKCU Run key.
//
// The registry is the single source of truth: both the settings dialog and the
// `--autostart` command read it back rather than trusting a cached copy, so a
// change made from either side is immediately visible to the other.
namespace autostart {

// True when the Run key holds exactly the command this executable installs.
bool IsEnabled();

// Adds or removes the Run entry. Returns an ERROR_* status; ERROR_SUCCESS on
// success, including when disabling something that was not enabled.
LONG SetEnabled(bool enabled);

// The command line the Run entry is set to, for diagnostics.
std::wstring Command();

}  // namespace autostart

#endif  // RUNNER_AUTOSTART_H_
