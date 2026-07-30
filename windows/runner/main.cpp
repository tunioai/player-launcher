#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "app_paths.h"
#include "cli.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // When started through tunio_spot.com the standard handles are inherited
  // from the shim and may already point at a file the caller redirected to;
  // attaching a console here would replace them and silently break
  // `tunio_spot --status > out.txt`. Only attach when this process has no
  // handles of its own, i.e. it was launched straight from a console (e.g.
  // 'flutter run') or under a debugger.
  const HANDLE inherited_stdout = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (inherited_stdout == nullptr || inherited_stdout == INVALID_HANDLE_VALUE) {
    if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
      CreateAndAttachConsole();
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const std::wstring executable_directory = app_paths::ExecutableDirectory();
  if (!executable_directory.empty()) {
    // Task Scheduler otherwise commonly starts desktop applications with
    // C:\Windows\System32 as their working directory. Keep Flutter assets and
    // any relative child-process paths anchored to the installed application.
    ::SetCurrentDirectoryW(executable_directory.c_str());
  }

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  // Console commands run before the single-instance mutex below: a command
  // issued while the player is up has to reach the running player, not be
  // swallowed by the "show the existing window" path.
  const cli::Outcome cli_outcome = cli::Run(command_line_arguments);
  if (cli_outcome.action == cli::Action::kExit) {
    ::CoUninitialize();
    return cli_outcome.exit_code;
  }

  constexpr wchar_t kSingleInstanceMutex[] =
      L"Local\\ai.tunio.radioplayer.single_instance";
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // The mutex is session-local by default. A scheduled task in the cashier's
    // interactive session and a later double-click therefore share one player,
    // while another signed-in Windows user remains independent.
    if (HWND existing_window = cli::FindRunningInstanceWindow()) {
      if (!::IsWindowVisible(existing_window)) {
        ::ShowWindow(existing_window, SW_SHOW);
      } else if (::IsIconic(existing_window)) {
        ::ShowWindow(existing_window, SW_RESTORE);
      }
      ::SetForegroundWindow(existing_window);
    }
    ::CloseHandle(single_instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  const std::wstring flutter_data_directory = executable_directory.empty()
                                                  ? L"data"
                                                  : executable_directory +
                                                        L"\\data";
  flutter::DartProject project(flutter_data_directory);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetShowCommand(cli_outcome.start_minimized ? SW_HIDE : show_command);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"tunio_radio_player", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::ReleaseMutex(single_instance_mutex);
      ::CloseHandle(single_instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // This process now lives until the user closes the player, so release the
  // console shim instead of making it hold the prompt open for hours.
  cli::SignalGuiReady();

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
