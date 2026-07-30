// Console front end for tunio_spot.exe.
//
// The player is a GUI-subsystem binary, so CMD returns to the prompt the
// instant it is launched: output lands on top of the next prompt, `errorlevel`
// is meaningless and `> file` captures nothing. This shim is a console-
// subsystem binary that CMD *does* wait for. Installed next to the player as
// tunio_spot.com, it wins name resolution over the .exe (PATHEXT lists .COM
// first), so typing `tunio_spot --status` in a console goes through here while
// double-clicking the .exe still opens the GUI.
//
// It deliberately holds no logic of its own: it re-launches the player with
// the same arguments and its own standard handles, so every command lives in
// one place and adding commands never touches this file.

#include <windows.h>

#include <string>
#include <vector>

namespace {

// Name of the environment variable carrying the readiness event to the child.
// The event has to be per-invocation, not a fixed name: a player that is
// already running holds its own event signalled for its whole lifetime, so a
// shared name would make every later command exit immediately, before the
// player it just started had printed anything.
constexpr wchar_t kGuiReadyEventVariable[] = L"TUNIO_GUI_READY_EVENT";

constexpr wchar_t kPlayerExecutable[] = L"tunio_spot.exe";

std::wstring ExecutableDirectory() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (true) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (static_cast<size_t>(length) < buffer.size()) {
      const std::wstring path(buffer.data(), length);
      const size_t separator = path.find_last_of(L'\\');
      return separator == std::wstring::npos ? std::wstring()
                                             : path.substr(0, separator);
    }
    buffer.resize(buffer.size() * 2);
  }
}

// Replaces argv[0] with the player's full path, keeping every other argument
// (including quoting) exactly as the user typed it.
std::wstring BuildCommandLine(const std::wstring& player) {
  std::wstring command_line = L"\"" + player + L"\"";

  const wchar_t* raw = ::GetCommandLineW();
  int count = 0;
  wchar_t** argv = ::CommandLineToArgvW(raw, &count);
  if (argv == nullptr) {
    return command_line;
  }

  for (int index = 1; index < count; ++index) {
    const std::wstring argument(argv[index]);
    // Re-quote anything containing a space so the player's own
    // CommandLineToArgvW splits it back into the same tokens.
    if (argument.find(L' ') == std::wstring::npos) {
      command_line += L" " + argument;
    } else {
      command_line += L" \"" + argument + L"\"";
    }
  }

  ::LocalFree(argv);
  return command_line;
}

void WriteError(const std::wstring& message) {
  const HANDLE handle = ::GetStdHandle(STD_ERROR_HANDLE);
  if (handle == nullptr || handle == INVALID_HANDLE_VALUE) {
    return;
  }

  DWORD written = 0;
  DWORD console_mode = 0;
  if (::GetConsoleMode(handle, &console_mode)) {
    ::WriteConsoleW(handle, message.data(), static_cast<DWORD>(message.size()),
                    &written, nullptr);
    return;
  }

  // Redirected to a pipe or a file: emit UTF-8 bytes. Converting properly
  // rather than truncating each wchar_t keeps non-ASCII paths readable.
  const int length = ::WideCharToMultiByte(
      CP_UTF8, 0, message.data(), static_cast<int>(message.size()), nullptr, 0,
      nullptr, nullptr);
  if (length <= 0) {
    return;
  }
  std::vector<char> utf8(static_cast<size_t>(length));
  ::WideCharToMultiByte(CP_UTF8, 0, message.data(),
                        static_cast<int>(message.size()), utf8.data(), length,
                        nullptr, nullptr);
  ::WriteFile(handle, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
              nullptr);
}

}  // namespace

int wmain() {
  const std::wstring directory = ExecutableDirectory();
  if (directory.empty()) {
    WriteError(L"tunio_spot: cannot locate the installation directory\n");
    return 1;
  }
  const std::wstring player = directory + L"\\" + kPlayerExecutable;

  // Created before the player starts, so there is no window in which it could
  // signal readiness before we are watching. The name carries our process id
  // so this event belongs to this invocation alone.
  const std::wstring event_name = L"Local\\ai.tunio.radioplayer.gui_ready." +
                                  std::to_wstring(::GetCurrentProcessId());
  const HANDLE gui_ready =
      ::CreateEventW(nullptr, TRUE, FALSE, event_name.c_str());
  if (gui_ready != nullptr) {
    // Inherited by the child through the environment block.
    ::SetEnvironmentVariableW(kGuiReadyEventVariable, event_name.c_str());
  }

  std::wstring command_line = BuildCommandLine(player);

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  // Hand the player our console handles. A GUI-subsystem child has no console
  // of its own, but it inherits these and writes straight into ours.
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = ::GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = ::GetStdHandle(STD_OUTPUT_HANDLE);
  startup.hStdError = ::GetStdHandle(STD_ERROR_HANDLE);

  PROCESS_INFORMATION process = {};
  if (!::CreateProcessW(player.c_str(), command_line.data(), nullptr, nullptr,
                        TRUE, 0, nullptr, directory.c_str(), &startup,
                        &process)) {
    WriteError(L"tunio_spot: cannot start " + player + L"\n");
    if (gui_ready != nullptr) {
      ::CloseHandle(gui_ready);
    }
    return 1;
  }

  int exit_code = 0;
  if (gui_ready == nullptr) {
    ::WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 0;
    ::GetExitCodeProcess(process.hProcess, &code);
    exit_code = static_cast<int>(code);
  } else {
    const HANDLE handles[] = {process.hProcess, gui_ready};
    const DWORD signalled =
        ::WaitForMultipleObjects(2, handles, FALSE, INFINITE);
    if (signalled == WAIT_OBJECT_0) {
      // The command ran to completion; its exit code is the answer.
      DWORD code = 0;
      ::GetExitCodeProcess(process.hProcess, &code);
      exit_code = static_cast<int>(code);
    } else {
      // The player is staying up as a GUI application. Hand the console back
      // rather than blocking until someone closes it.
      exit_code = 0;
    }
    ::CloseHandle(gui_ready);
  }

  ::CloseHandle(process.hProcess);
  ::CloseHandle(process.hThread);
  return exit_code;
}
