#include "app_paths.h"

#include <windows.h>

#include <shlobj.h>

#include <vector>

#pragma comment(lib, "version.lib")
#pragma comment(lib, "shell32.lib")

namespace app_paths {

namespace {

// Matches the Runner.rc strings. Only used if VERSIONINFO cannot be read at
// all, which would otherwise send the CLI looking in the wrong directory.
constexpr wchar_t kFallbackCompanyName[] = L"Tunio AI";
constexpr wchar_t kFallbackProductName[] = L"Tunio Spot";

std::wstring QueryVersionString(const wchar_t* name) {
  const std::wstring executable = ExecutablePath();
  if (executable.empty()) {
    return std::wstring();
  }

  DWORD ignored = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(executable.c_str(), &ignored);
  if (size == 0) {
    return std::wstring();
  }

  std::vector<BYTE> data(size);
  if (!::GetFileVersionInfoW(executable.c_str(), 0, size, data.data())) {
    return std::wstring();
  }

  struct LangAndCodePage {
    WORD language;
    WORD code_page;
  };

  LangAndCodePage* translations = nullptr;
  UINT translations_size = 0;
  if (!::VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                        reinterpret_cast<void**>(&translations),
                        &translations_size) ||
      translations_size < sizeof(LangAndCodePage)) {
    return std::wstring();
  }

  wchar_t sub_block[128];
  ::swprintf_s(sub_block, L"\\StringFileInfo\\%04x%04x\\%s",
               static_cast<unsigned int>(translations[0].language),
               static_cast<unsigned int>(translations[0].code_page), name);

  wchar_t* value = nullptr;
  UINT value_size = 0;
  if (!::VerQueryValueW(data.data(), sub_block,
                        reinterpret_cast<void**>(&value), &value_size) ||
      value_size == 0) {
    return std::wstring();
  }

  // The .rc writes an explicit trailing "\0", so stop at the first NUL rather
  // than trusting value_size.
  return std::wstring(value);
}

std::wstring RoamingAppDataPath() {
  PWSTR raw = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                    &raw))) {
    ::CoTaskMemFree(raw);
    return std::wstring();
  }
  std::wstring result(raw);
  ::CoTaskMemFree(raw);
  return result;
}

}  // namespace

std::wstring ExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (true) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (static_cast<size_t>(length) < buffer.size()) {
      return std::wstring(buffer.data(), length);
    }
    buffer.resize(buffer.size() * 2);
  }
}

std::wstring ExecutableDirectory() {
  const std::wstring executable = ExecutablePath();
  const size_t separator = executable.find_last_of(L'\\');
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  return executable.substr(0, separator);
}

std::wstring ApplicationSupportDirectory() {
  const std::wstring app_data = RoamingAppDataPath();
  if (app_data.empty()) {
    return std::wstring();
  }

  std::wstring company = QueryVersionString(L"CompanyName");
  if (company.empty()) {
    company = kFallbackCompanyName;
  }
  std::wstring product = QueryVersionString(L"ProductName");
  if (product.empty()) {
    product = kFallbackProductName;
  }

  return app_data + L"\\" + company + L"\\" + product;
}

std::wstring StatusFilePath() {
  const std::wstring directory = ApplicationSupportDirectory();
  if (directory.empty()) {
    return std::wstring();
  }
  return directory + L"\\status.txt";
}

std::wstring LogFilePath() {
  const std::wstring directory = ApplicationSupportDirectory();
  if (directory.empty()) {
    return std::wstring();
  }
  return directory + L"\\logs\\tunio.log";
}

}  // namespace app_paths
