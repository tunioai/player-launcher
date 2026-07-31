#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include "autostart.h"
#include "cli.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr char kAutoStartChannel[] =
    "com.example.tunio_radio_player/autostart";
constexpr char kCliChannel[] = "com.example.tunio_radio_player/cli";

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
              flutter::EncodableValue(autostart::IsEnabled()));
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

          const LONG status = autostart::SetEnabled(*enabled);
          if (status != ERROR_SUCCESS) {
            result->Error(
                "autostart_error",
                "Windows could not update the startup setting (error " +
                    std::to_string(status) + ").");
            return;
          }

          result->Success(
              flutter::EncodableValue(autostart::IsEnabled()));
          return;
        }

        if (call.method_name() == "isAutoStarted") {
          result->Success(flutter::EncodableValue(WasStartedMinimized()));
          return;
        }

        result->NotImplemented();
      });

  cli_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kCliChannel,
          &flutter::StandardMethodCodec::GetInstance());

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
  cli_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handled before Flutter sees the message: this is our own private channel
  // from the console front end, and returning TRUE tells the sender it landed.
  if (message == WM_COPYDATA) {
    const auto* payload = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (payload != nullptr && payload->dwData == cli::kCommandMessageId &&
        payload->lpData != nullptr && payload->cbData > 0 && cli_channel_) {
      // The sender's buffer is only valid for the duration of this call, and
      // it NUL-terminates, so copy before handing it to Dart.
      const std::string command(static_cast<const char*>(payload->lpData),
                                payload->cbData - 1);
      cli_channel_->InvokeMethod(
          "command", std::make_unique<flutter::EncodableValue>(command));
      return TRUE;
    }
    return FALSE;
  }

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
