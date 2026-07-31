#include "cli.h"

#include <stdio.h>
#include <string.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <map>
#include <sstream>
#include <vector>

#include "app_paths.h"
#include "autostart.h"

namespace cli {

namespace {

constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kGuiReadyEventVariable[] = L"TUNIO_GUI_READY_EVENT";
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\ai.tunio.radioplayer.single_instance";

const char kHelpText[] =
    "Tunio Spot - console interface\n"
    "\n"
    "Usage: tunio_spot [command] [options]\n"
    "\n"
    "Information\n"
    "  /h, /?, --help            Show this help\n"
    "  /v, --version             Show the application version\n"
    "  --status [--json]         Report player state\n"
    "  --log-path                Print the path of the log file\n"
    "\n"
    "Startup\n"
    "  /s, --silent              Start minimised to the system tray\n"
    "\n"
    "Configuration (works whether or not the player is running)\n"
    "  --autostart on|off|status Start the player at Windows logon\n"
    "  --pin <code>              Bind this machine to a point; starts the\n"
    "                            player if it is not already running\n"
    "  --unbind                  Remove the point binding\n"
    "\n"
    "Control of a running player\n"
    "  --show                    Restore the window\n"
    "  --hide                    Hide to the system tray\n"
    "  --volume <0-100>          Set playback volume for this session\n"
    "  --quit                    Shut the player down\n"
    "\n"
    "Exit codes\n"
    "  0  success\n"
    "  1  failed\n"
    "  2  unknown command or bad argument\n"
    "  3  the player is not running\n"
    "  4  this machine is not bound to a point\n"
    "\n"
    "Examples\n"
    "  tunio_spot --pin 123456        Provision a freshly imaged machine\n"
    "  tunio_spot --autostart on      Survive a reboot unattended\n"
    "  tunio_spot --status --json     Feed a monitoring system\n";

// ---------------------------------------------------------------------------
// Console output
// ---------------------------------------------------------------------------

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        result.data(), length);
  return result;
}

std::string Narrow(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int length =
      ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                            static_cast<int>(text.size()), nullptr, 0, nullptr,
                            nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string result(length, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        result.data(), length, nullptr, nullptr);
  return result;
}

// Writes to whatever stdout is: a real console (the shim's, or the one we
// attached to), or a pipe/file when the caller redirected output. Console
// handles need WriteConsoleW, because a byte write would be reinterpreted
// through the console code page and mangle any non-ASCII point name.
void WriteStdOut(const std::wstring& text) {
  const HANDLE handle = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (handle == nullptr || handle == INVALID_HANDLE_VALUE) {
    return;
  }

  DWORD console_mode = 0;
  if (::GetConsoleMode(handle, &console_mode)) {
    DWORD written = 0;
    ::WriteConsoleW(handle, text.data(), static_cast<DWORD>(text.size()),
                    &written, nullptr);
    return;
  }

  const std::string utf8 = Narrow(text);
  DWORD written = 0;
  ::WriteFile(handle, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
              nullptr);
}

void Print(const std::string& utf8) { WriteStdOut(Widen(utf8)); }

void PrintLine(const std::string& utf8) { Print(utf8 + "\n"); }

void PrintError(const std::string& utf8) { PrintLine("error: " + utf8); }

// ---------------------------------------------------------------------------
// Locating a running player
// ---------------------------------------------------------------------------

std::wstring ProcessImagePath(DWORD process_id) {
  const HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                       process_id);
  if (process == nullptr) {
    return std::wstring();
  }

  std::vector<wchar_t> buffer(MAX_PATH);
  while (true) {
    DWORD size = static_cast<DWORD>(buffer.size());
    if (::QueryFullProcessImageNameW(process, 0, buffer.data(), &size)) {
      ::CloseHandle(process);
      return std::wstring(buffer.data(), size);
    }
    if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
      ::CloseHandle(process);
      return std::wstring();
    }
    buffer.resize(buffer.size() * 2);
  }
}

struct WindowSearch {
  std::wstring executable;
  HWND found = nullptr;
};

BOOL CALLBACK MatchWindow(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<WindowSearch*>(parameter);

  wchar_t class_name[64] = {};
  if (::GetClassNameW(window, class_name, ARRAYSIZE(class_name)) == 0 ||
      ::wcscmp(class_name, kWindowClassName) != 0) {
    return TRUE;
  }

  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0 || process_id == ::GetCurrentProcessId()) {
    return TRUE;
  }

  // The window class is the stock Flutter one, shared by every Flutter app on
  // Windows, so the owning executable is what actually identifies us.
  if (::_wcsicmp(ProcessImagePath(process_id).c_str(),
                 search->executable.c_str()) != 0) {
    return TRUE;
  }

  search->found = window;
  return FALSE;
}

bool IsPlayerRunning() {
  const HANDLE mutex =
      ::OpenMutexW(SYNCHRONIZE, FALSE, kSingleInstanceMutexName);
  if (mutex == nullptr) {
    return false;
  }
  ::CloseHandle(mutex);
  return true;
}

// ---------------------------------------------------------------------------
// Talking to a running player
// ---------------------------------------------------------------------------

// One-way by design: the player acts on the command, and the exit code only
// reports delivery. Anything the caller needs to read back comes from
// --status, which stays readable even when the player is wedged.
bool SendCommand(const std::string& command) {
  const HWND window = FindRunningInstanceWindow();
  if (window == nullptr) {
    return false;
  }

  COPYDATASTRUCT payload = {};
  payload.dwData = kCommandMessageId;
  payload.cbData = static_cast<DWORD>(command.size() + 1);
  payload.lpData = const_cast<char*>(command.c_str());

  DWORD_PTR result = 0;
  // A wedged player must not wedge the CLI too.
  return ::SendMessageTimeoutW(window, WM_COPYDATA, 0,
                               reinterpret_cast<LPARAM>(&payload),
                               SMTO_ABORTIFHUNG, 5000, &result) != 0;
}

int DeliverCommand(const std::string& command) {
  if (!IsPlayerRunning()) {
    PrintError("the player is not running");
    return kExitNotRunning;
  }
  if (!SendCommand(command)) {
    PrintError("could not reach the running player");
    return kExitError;
  }
  return kExitOk;
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

// status.txt is TAB-separated key/value lines rather than JSON so that reading
// it needs no parser here; --json is rendered back out from these pairs.
std::map<std::string, std::string> ReadStatusFile() {
  std::map<std::string, std::string> values;

  const std::wstring path = app_paths::StatusFilePath();
  if (path.empty()) {
    return values;
  }

  const HANDLE file =
      ::CreateFileW(path.c_str(), GENERIC_READ,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return values;
  }

  std::string contents;
  char buffer[4096];
  DWORD read = 0;
  while (::ReadFile(file, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
    contents.append(buffer, read);
  }
  ::CloseHandle(file);

  std::istringstream stream(contents);
  std::string line;
  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    const size_t separator = line.find('\t');
    if (separator == std::string::npos) {
      continue;
    }
    values[line.substr(0, separator)] = line.substr(separator + 1);
  }
  return values;
}

std::string ValueOr(const std::map<std::string, std::string>& values,
                    const std::string& key, const std::string& fallback) {
  const auto it = values.find(key);
  return it == values.end() ? fallback : it->second;
}

std::string JsonEscape(const std::string& value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (const char character : value) {
    switch (character) {
      case '"':
        escaped += "\\\"";
        break;
      case '\\':
        escaped += "\\\\";
        break;
      case '\n':
        escaped += "\\n";
        break;
      case '\r':
        escaped += "\\r";
        break;
      case '\t':
        escaped += "\\t";
        break;
      default:
        // Anything else below 0x20 would be a literal control character in the
        // output and make the document invalid for whatever consumes --json.
        if (static_cast<unsigned char>(character) < 0x20) {
          char unicode[7];
          ::sprintf_s(unicode, "\\u%04x",
                      static_cast<unsigned int>(
                          static_cast<unsigned char>(character)));
          escaped += unicode;
        } else {
          escaped += character;
        }
    }
  }
  return escaped;
}

int PrintStatus(bool as_json) {
  const bool running = IsPlayerRunning();
  auto values = ReadStatusFile();

  // The file outlives the process it describes, so anything about playback is
  // only meaningful while that process is alive.
  if (!running) {
    values.erase("playing");
    values.erase("source");
    values.erase("stream");
    values.erase("pid");
  }

  values["running"] = running ? "true" : "false";
  values["autostart"] = autostart::IsEnabled() ? "true" : "false";

  if (as_json) {
    std::string json = "{";
    bool first = true;
    for (const auto& entry : values) {
      if (!first) {
        json += ",";
      }
      first = false;
      json += "\"" + JsonEscape(entry.first) + "\":\"" +
              JsonEscape(entry.second) + "\"";
    }
    json += "}";
    PrintLine(json);
  } else {
    PrintLine("Tunio Spot " + ValueOr(values, "version", "(unknown version)"));
    PrintLine("  running     " +
              std::string(running ? "yes" : "no") +
              (running ? " (pid " + ValueOr(values, "pid", "?") + ")" : ""));
    PrintLine("  autostart   " +
              std::string(values["autostart"] == "true" ? "enabled"
                                                        : "disabled"));
    PrintLine("  bound       " + ValueOr(values, "bound", "unknown"));
    if (ValueOr(values, "bound", "") == "true") {
      PrintLine("  point       " + ValueOr(values, "point", "(unnamed)"));
    }
    if (running) {
      PrintLine("  playing     " + ValueOr(values, "playing", "unknown") +
                " (" + ValueOr(values, "source", "unknown") + ")");
    }
    PrintLine("  updated     " + ValueOr(values, "updated_at", "never"));
  }

  // "Not running" outranks "not bound": a monitoring system needs to see the
  // process being down before it worries about configuration.
  if (!running) {
    return kExitNotRunning;
  }
  return ValueOr(values, "bound", "") == "true" ? kExitOk : kExitNotBound;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

int RunAutostart(const std::string& mode) {
  if (mode == "status" || mode.empty()) {
    const bool enabled = autostart::IsEnabled();
    PrintLine(enabled ? "autostart: enabled" : "autostart: disabled");
    return kExitOk;
  }

  if (mode != "on" && mode != "off") {
    PrintError("--autostart expects on, off or status");
    return kExitUsage;
  }

  const LONG status = autostart::SetEnabled(mode == "on");
  if (status != ERROR_SUCCESS) {
    PrintError("Windows rejected the startup change (error " +
               std::to_string(status) + ")");
    return kExitError;
  }
  PrintLine(mode == "on" ? "autostart: enabled" : "autostart: disabled");
  return kExitOk;
}

bool IsFlag(const std::string& argument, const char* long_form,
            const char* short_form = nullptr) {
  if (argument == long_form) {
    return true;
  }
  return short_form != nullptr && argument == short_form;
}

std::string ToLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return static_cast<char>(::tolower(c)); });
  return value;
}

}  // namespace

HWND FindRunningInstanceWindow() {
  WindowSearch search;
  search.executable = app_paths::ExecutablePath();
  if (search.executable.empty()) {
    return nullptr;
  }
  ::EnumWindows(&MatchWindow, reinterpret_cast<LPARAM>(&search));
  return search.found;
}

void SignalGuiReady() {
  // Only set when this process was started by the console shim; a plain
  // double-click has nobody waiting.
  wchar_t event_name[128] = {};
  const DWORD length = ::GetEnvironmentVariableW(
      kGuiReadyEventVariable, event_name, ARRAYSIZE(event_name));
  if (length == 0 || length >= ARRAYSIZE(event_name)) {
    return;
  }

  const HANDLE event = ::OpenEventW(EVENT_MODIFY_STATE, FALSE, event_name);
  if (event == nullptr) {
    return;
  }
  ::SetEvent(event);
  ::CloseHandle(event);
}

Outcome Run(const std::vector<std::string>& arguments) {
  Outcome outcome;

  bool wants_json = false;
  for (const auto& argument : arguments) {
    if (IsFlag(ToLower(argument), "--json")) {
      wants_json = true;
    }
  }

  // Skip argv[0].
  for (size_t index = 1; index < arguments.size(); ++index) {
    const std::string argument = ToLower(arguments[index]);

    if (IsFlag(argument, "--help", "/h") || argument == "/?") {
      Print(kHelpText);
      outcome.action = Action::kExit;
      outcome.exit_code = kExitOk;
      return outcome;
    }

    if (IsFlag(argument, "--version", "/v")) {
      PrintLine(std::string("Tunio Spot ") + FLUTTER_VERSION);
      outcome.action = Action::kExit;
      outcome.exit_code = kExitOk;
      return outcome;
    }

    if (IsFlag(argument, "--log-path")) {
      PrintLine(Narrow(app_paths::LogFilePath()));
      outcome.action = Action::kExit;
      outcome.exit_code = kExitOk;
      return outcome;
    }

    if (IsFlag(argument, "--status")) {
      outcome.action = Action::kExit;
      outcome.exit_code = PrintStatus(wants_json);
      return outcome;
    }

    if (IsFlag(argument, "--autostart")) {
      const std::string mode =
          index + 1 < arguments.size() ? ToLower(arguments[index + 1]) : "";
      outcome.action = Action::kExit;
      outcome.exit_code = RunAutostart(mode);
      return outcome;
    }

    if (IsFlag(argument, "--show") || IsFlag(argument, "--hide") ||
        IsFlag(argument, "--quit")) {
      outcome.action = Action::kExit;
      outcome.exit_code = DeliverCommand(argument.substr(2));
      return outcome;
    }

    if (IsFlag(argument, "--volume")) {
      if (index + 1 >= arguments.size()) {
        PrintError("--volume expects a value between 0 and 100");
        outcome.action = Action::kExit;
        outcome.exit_code = kExitUsage;
        return outcome;
      }
      const std::string value = arguments[index + 1];
      const bool numeric =
          !value.empty() &&
          value.find_first_not_of("0123456789") == std::string::npos;
      const int level = numeric ? std::atoi(value.c_str()) : -1;
      if (level < 0 || level > 100) {
        PrintError("--volume expects a value between 0 and 100");
        outcome.action = Action::kExit;
        outcome.exit_code = kExitUsage;
        return outcome;
      }
      outcome.action = Action::kExit;
      outcome.exit_code = DeliverCommand("volume " + std::to_string(level));
      return outcome;
    }

    // Binding commands reach the Dart side either way: as a message to the
    // running player, or as a startup argument that a fresh process acts on.
    // Keeping them in Dart means the credential store has exactly one writer.
    if (IsFlag(argument, "--pin")) {
      if (index + 1 >= arguments.size()) {
        PrintError("--pin expects a code");
        outcome.action = Action::kExit;
        outcome.exit_code = kExitUsage;
        return outcome;
      }
      if (IsPlayerRunning()) {
        outcome.action = Action::kExit;
        outcome.exit_code = DeliverCommand("pin " + arguments[index + 1]);
        return outcome;
      }
      // Fall through to normal startup; main.dart reads --pin from the
      // entrypoint arguments and binds before the first connect.
      continue;
    }

    if (IsFlag(argument, "--unbind")) {
      if (IsPlayerRunning()) {
        outcome.action = Action::kExit;
        outcome.exit_code = DeliverCommand("unbind");
        return outcome;
      }
      continue;
    }

    if (IsFlag(argument, "--silent", "/s") || IsFlag(argument, "--minimized")) {
      outcome.start_minimized = true;
      continue;
    }
  }

  return outcome;
}

}  // namespace cli
