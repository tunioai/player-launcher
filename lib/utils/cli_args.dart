/// Startup arguments the Windows console front end forwards to Dart.
///
/// Most console commands never reach here — they are answered natively in
/// `windows/runner/cli.cpp`, or delivered to an already running player as a
/// message. What lands here are the commands that must run against the app's
/// own storage on a machine where the player was not yet running, so that the
/// credential store keeps exactly one writer.
class CliArgs {
  const CliArgs({
    this.startMinimized = false,
    this.pin,
    this.unbind = false,
  });

  /// Start hidden in the system tray instead of showing the window.
  final bool startMinimized;

  /// Bind this machine to the given point before the first connect.
  final String? pin;

  /// Drop the current point binding on startup.
  final bool unbind;

  bool get hasBindingChange => pin != null || unbind;

  static const Set<String> _minimizedFlags = <String>{
    '--minimized',
    '--silent',
    '/s',
  };

  static CliArgs parse(List<String> arguments) {
    var startMinimized = false;
    String? pin;
    var unbind = false;

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index].toLowerCase();

      if (_minimizedFlags.contains(argument)) {
        startMinimized = true;
        continue;
      }

      if (argument == '--pin' && index + 1 < arguments.length) {
        final value = arguments[index + 1].trim();
        if (value.isNotEmpty) {
          pin = value;
        }
        index++;
        continue;
      }

      if (argument == '--unbind') {
        unbind = true;
      }
    }

    return CliArgs(
      startMinimized: startMinimized,
      pin: pin,
      // Provisioning wins over clearing: `--unbind --pin 123456` is a rebind,
      // and running it in that order should leave the machine bound.
      unbind: unbind && pin == null,
    );
  }
}
