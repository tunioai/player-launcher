import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/cli_service.dart';
import 'package:tunio_radio_player/utils/cli_args.dart';

void main() {
  group('CliArgs.parse', () {
    test('defaults to a plain visible startup', () {
      const empty = <String>[];
      final args = CliArgs.parse(empty);

      expect(args.startMinimized, isFalse);
      expect(args.pin, isNull);
      expect(args.unbind, isFalse);
      expect(args.hasBindingChange, isFalse);
    });

    test('accepts every spelling of the tray flag', () {
      for (final flag in ['--minimized', '--silent', '/s', '/S', '--SILENT']) {
        expect(CliArgs.parse([flag]).startMinimized, isTrue, reason: flag);
      }
    });

    test('reads the code that follows --pin', () {
      final args = CliArgs.parse(['--pin', '123456']);

      expect(args.pin, '123456');
      expect(args.hasBindingChange, isTrue);
    });

    test('ignores --pin without a code', () {
      expect(CliArgs.parse(['--pin']).pin, isNull);
      expect(CliArgs.parse(['--pin', '   ']).pin, isNull);
    });

    // The console front end passes the raw tail through, so the code must not
    // be lower-cased or otherwise rewritten on the way in.
    test('preserves the code verbatim', () {
      expect(CliArgs.parse(['--pin', 'AbC-123']).pin, 'AbC-123');
    });

    test('does not treat a code as a flag', () {
      final args = CliArgs.parse(['--pin', '--silent']);

      expect(args.pin, '--silent');
      expect(args.startMinimized, isFalse,
          reason: 'the value belongs to --pin, not to the tray flag');
    });

    test('reads --unbind', () {
      final args = CliArgs.parse(['--unbind']);

      expect(args.unbind, isTrue);
      expect(args.hasBindingChange, isTrue);
    });

    // Provisioning has to win, or `--unbind --pin 123456` would leave the
    // machine unbound and silently undo the operator's intent.
    test('a code cancels a simultaneous --unbind', () {
      final args = CliArgs.parse(['--unbind', '--pin', '123456']);

      expect(args.pin, '123456');
      expect(args.unbind, isFalse);
    });

    test('combines the tray flag with a binding change', () {
      final args = CliArgs.parse(['--silent', '--pin', '123456']);

      expect(args.startMinimized, isTrue);
      expect(args.pin, '123456');
    });

    test('ignores arguments it does not own', () {
      final args = CliArgs.parse(['--status', '--json', '--autostart', 'on']);

      expect(args.startMinimized, isFalse);
      expect(args.hasBindingChange, isFalse);
    });
  });

  group('CliCommand.parse', () {
    test('reads a bare command', () {
      final command = CliCommand.parse('show');

      expect(command?.name, 'show');
      expect(command?.value, isNull);
    });

    test('splits a command from its value', () {
      final command = CliCommand.parse('volume 50');

      expect(command?.name, 'volume');
      expect(command?.value, '50');
    });

    test('keeps spaces inside the value', () {
      expect(CliCommand.parse('pin one two')?.value, 'one two');
    });

    test('lower-cases the name but not the value', () {
      final command = CliCommand.parse('PIN AbC');

      expect(command?.name, 'pin');
      expect(command?.value, 'AbC');
    });

    test('rejects empty input', () {
      expect(CliCommand.parse(''), isNull);
      expect(CliCommand.parse('   '), isNull);
    });

    test('treats a trailing separator as no value', () {
      expect(CliCommand.parse('unbind ')?.value, isNull);
    });
  });
}
