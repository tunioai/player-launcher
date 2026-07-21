#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const std::wstring executable_directory = GetExecutableDirectory();
  if (!executable_directory.empty()) {
    // Task Scheduler otherwise commonly starts desktop applications with
    // C:\Windows\System32 as their working directory. Keep Flutter assets and
    // any relative child-process paths anchored to the installed application.
    ::SetCurrentDirectoryW(executable_directory.c_str());
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
    if (HWND existing_window =
            ::FindWindowW(nullptr, L"tunio_radio_player")) {
      if (::IsIconic(existing_window)) {
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_minimized =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--minimized") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetShowCommand(start_minimized ? SW_SHOWMINNOACTIVE : show_command);
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
