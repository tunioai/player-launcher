#ifndef RUNNER_APP_PATHS_H_
#define RUNNER_APP_PATHS_H_

#include <string>

namespace app_paths {

// Full path of the running executable, or an empty string on failure.
std::wstring ExecutablePath();

// Directory holding the running executable.
std::wstring ExecutableDirectory();

// The directory path_provider's getApplicationSupportDirectory() resolves to
// on Windows: %APPDATA%\<CompanyName>\<ProductName>, with both names read from
// this executable's VERSIONINFO. Derived the same way rather than hard-coded,
// because the Dart side and the CLI must agree on it byte for byte.
std::wstring ApplicationSupportDirectory();

// Machine-readable state written by the running app (TAB-separated key/value
// lines). Absent when the app has never run.
std::wstring StatusFilePath();

// The on-disk log the app appends to.
std::wstring LogFilePath();

}  // namespace app_paths

#endif  // RUNNER_APP_PATHS_H_
