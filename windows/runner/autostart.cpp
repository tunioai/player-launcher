#include "autostart.h"

#include <vector>

#include "app_paths.h"

namespace autostart {

namespace {

constexpr wchar_t kRunRegistryKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunRegistryValue[] = L"TunioSpot";

}  // namespace

std::wstring Command() {
  const std::wstring executable_path = app_paths::ExecutablePath();
  if (executable_path.empty()) {
    return std::wstring();
  }
  return L"\"" + executable_path + L"\" --minimized";
}

bool IsEnabled() {
  DWORD value_size = 0;
  LONG status =
      ::RegGetValueW(HKEY_CURRENT_USER, kRunRegistryKey, kRunRegistryValue,
                     RRF_RT_REG_SZ, nullptr, nullptr, &value_size);
  if (status != ERROR_SUCCESS || value_size < sizeof(wchar_t)) {
    return false;
  }

  std::vector<wchar_t> value(value_size / sizeof(wchar_t));
  status = ::RegGetValueW(HKEY_CURRENT_USER, kRunRegistryKey, kRunRegistryValue,
                          RRF_RT_REG_SZ, nullptr, value.data(), &value_size);
  if (status != ERROR_SUCCESS) {
    return false;
  }

  return std::wstring(value.data()) == Command();
}

LONG SetEnabled(bool enabled) {
  if (!enabled) {
    const LONG status = ::RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunRegistryKey,
                                             kRunRegistryValue);
    return status == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : status;
  }

  const std::wstring command = Command();
  if (command.empty()) {
    return ERROR_FILE_NOT_FOUND;
  }

  HKEY key = nullptr;
  LONG status =
      ::RegCreateKeyExW(HKEY_CURRENT_USER, kRunRegistryKey, 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    return status;
  }

  const DWORD command_size =
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  status = ::RegSetValueExW(key, kRunRegistryValue, 0, REG_SZ,
                            reinterpret_cast<const BYTE*>(command.c_str()),
                            command_size);
  ::RegCloseKey(key);
  return status;
}

}  // namespace autostart
