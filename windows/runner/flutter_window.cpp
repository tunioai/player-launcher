#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr wchar_t kRunRegistryKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunRegistryValue[] = L"TunioSpot";
constexpr char kAutoStartChannel[] =
    "com.example.tunio_radio_player/autostart";

std::wstring GetExecutablePath() {
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

std::wstring GetAutoStartCommand() {
  const std::wstring executable_path = GetExecutablePath();
  if (executable_path.empty()) {
    return std::wstring();
  }
  return L"\"" + executable_path + L"\" --minimized";
}

bool IsLaunchAtStartupEnabled() {
  DWORD value_size = 0;
  LONG status = ::RegGetValueW(
      HKEY_CURRENT_USER, kRunRegistryKey, kRunRegistryValue, RRF_RT_REG_SZ,
      nullptr, nullptr, &value_size);
  if (status != ERROR_SUCCESS || value_size < sizeof(wchar_t)) {
    return false;
  }

  std::vector<wchar_t> value(value_size / sizeof(wchar_t));
  status = ::RegGetValueW(HKEY_CURRENT_USER, kRunRegistryKey,
                          kRunRegistryValue, RRF_RT_REG_SZ, nullptr,
                          value.data(), &value_size);
  if (status != ERROR_SUCCESS) {
    return false;
  }

  return std::wstring(value.data()) == GetAutoStartCommand();
}

LONG SetLaunchAtStartupEnabled(bool enabled) {
  if (!enabled) {
    const LONG status = ::RegDeleteKeyValueW(
        HKEY_CURRENT_USER, kRunRegistryKey, kRunRegistryValue);
    return status == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : status;
  }

  const std::wstring command = GetAutoStartCommand();
  if (command.empty()) {
    return ERROR_FILE_NOT_FOUND;
  }

  HKEY key = nullptr;
  LONG status = ::RegCreateKeyExW(
      HKEY_CURRENT_USER, kRunRegistryKey, 0, nullptr, 0, KEY_SET_VALUE,
      nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    return status;
  }

  const DWORD command_size =
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  status = ::RegSetValueExW(
      key, kRunRegistryValue, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()), command_size);
  ::RegCloseKey(key);
  return status;
}

bool WasStartedMinimized() {
  const std::vector<std::string> arguments = GetCommandLineArguments();
  return std::find(arguments.begin(), arguments.end(), "--minimized") !=
         arguments.end();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  autostart_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kAutoStartChannel,
          &flutter::StandardMethodCodec::GetInstance());
  autostart_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "isLaunchAtStartupEnabled") {
          result->Success(
              flutter::EncodableValue(IsLaunchAtStartupEnabled()));
          return;
        }

        if (call.method_name() == "setLaunchAtStartupEnabled") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_arguments",
                          "Expected launch-at-startup arguments.");
            return;
          }

          const auto enabled_iterator =
              arguments->find(flutter::EncodableValue("enabled"));
          if (enabled_iterator == arguments->end()) {
            result->Error("invalid_arguments",
                          "Missing the enabled argument.");
            return;
          }

          const auto* enabled =
              std::get_if<bool>(&enabled_iterator->second);
          if (enabled == nullptr) {
            result->Error("invalid_arguments",
                          "The enabled argument must be a boolean.");
            return;
          }

          const LONG status = SetLaunchAtStartupEnabled(*enabled);
          if (status != ERROR_SUCCESS) {
            result->Error(
                "autostart_error",
                "Windows could not update the startup setting (error " +
                    std::to_string(status) + ").");
            return;
          }

          result->Success(
              flutter::EncodableValue(IsLaunchAtStartupEnabled()));
          return;
        }

        if (call.method_name() == "isAutoStarted") {
          result->Success(flutter::EncodableValue(WasStartedMinimized()));
          return;
        }

        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (autostart_channel_) {
    autostart_channel_->SetMethodCallHandler(nullptr);
    autostart_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
