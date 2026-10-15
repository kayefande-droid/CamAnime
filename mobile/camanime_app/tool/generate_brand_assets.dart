import 'dart:io';

Future<void> main() async {
  final source = File('../../static/brand/camanime-logo.png');
  if (!await source.exists()) {
    stderr.writeln('Run from mobile/camanime_app; missing ${source.path}');
    exitCode = 1;
    return;
  }
  final output = File('assets/brand/camanime-logo.png');
  await output.parent.create(recursive: true);
  await source.copy(output.path);
  stdout.writeln('Copied ${source.path} to ${output.path}');
}
