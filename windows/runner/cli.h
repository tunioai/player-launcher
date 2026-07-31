#ifndef RUNNER_CLI_H_
#define RUNNER_CLI_H_

#include <windows.h>

#include <string>
#include <vector>

// Console interface for integrators embedding the player into a till, a
// digital-signage PC or a store management system. Everything here runs
// before the Flutter engine exists, so commands are cheap and work whether or
// not the player is already running.
namespace cli {

// Exit codes, documented in --help so a batch file can branch on them.
constexpr int kExitOk = 0;
constexpr int kExitError = 1;
constexpr int kExitUsage = 2;
constexpr int kExitNotRunning = 3;
constexpr int kExitNotBound = 4;

// Payload marker for the WM_COPYDATA messages the CLI sends to a running
// player. Anything else arriving on that message is not ours.
constexpr ULONG_PTR kCommandMessageId = 0x54554E49;  // 'TUNI'

enum class Action {
  // The command is done; wWinMain should return exit_code without starting up.
  kExit,
  // No terminal command was given: carry on into normal GUI startup.
  kStartApp,
};

struct Outcome {
  Action action = Action::kStartApp;
  int exit_code = kExitOk;
  bool start_minimized = false;
};

// Parses and executes anything that does not need the Flutter engine. Must be
// called at the very top of wWinMain, before the single-instance mutex is
// taken: a command issued while the player runs would otherwise be swallowed
// by the "show the existing window" path.
Outcome Run(const std::vector<std::string>& arguments);

// The main window of an already running player, or nullptr. Matched on window
// class plus owning executable, because the class name is shared by every
// Flutter Windows app and the title can be changed from Dart.
HWND FindRunningInstanceWindow();

// Releases the console shim, which is otherwise waiting for this process to
// finish. Call once the process commits to running as a long-lived GUI app,
// so the shim hands the console back instead of blocking until the player is
// closed.
void SignalGuiReady();

}  // namespace cli

#endif  // RUNNER_CLI_H_
