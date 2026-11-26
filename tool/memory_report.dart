// The memory test's results as tables (docs/MEMORY.md §4):
//
//   fvm dart run tool/memory_report.dart              # every build/memory/*.json
//   fvm dart run tool/memory_report.dart <file.json>…  # these runs
//
// Each run: every sample (resident memory and its parts, the Dart heap, the
// image cache, live players), then what it means against the targets: for
// `cycle`, what closing gave back (T1) and the growth from the first close
// to the last (T2); for `browse` and `long`, the rise over the last part of
// the run (T3, T4).
import 'dart:convert';
import 'dart:io';

/// The targets in docs/MEMORY.md §2, in MB.
const t1GiveBack = 60;
const t2Growth = 20;
const t3IdleRise = 10;
const t4PlayRise = 20;

Future<void> main(List<String> args) async {
  final files = args.isNotEmpty
      ? args.map(File.new).toList()
      : [
          if (Directory('build/memory').existsSync())
            ...Directory('build/memory')
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.json')),
        ];
  if (files.isEmpty) {
    stderr.writeln('No runs: build/memory/*.json is empty.');
    exit(1);
  }
  for (final file in files..sort((a, b) => a.path.compareTo(b.path))) {
    final run = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    stdout
      ..writeln(file.path)
      ..writeln(report(run))
      ..writeln();
  }
}

/// [run] is the test's `memory` report: scenario, device, ui, samples.
String report(Map<String, dynamic> run) {
  final samples = [
    for (final s in run['samples'] as List) (s as Map).cast<String, Object?>(),
  ];
  final out = StringBuffer()
    ..writeln(
      '${run['device']} · ${run['ui']} · ${run['scenario']} · '
      '${run['version']} · ${run['quality']}p',
    );
  final android = samples.any((s) => s['android_mb'] != null);
  final columns = <(String, Object? Function(Map<String, Object?>))>[
    ('t', (s) => '${s['t_s']}s'),
    ('rss', (s) => s['rss_mb']),
    ('anon', (s) => s['anon_mb']),
    ('file', (s) => s['file_mb']),
    ('heap', (s) => s['heap_mb']),
    ('ext', (s) => s['external_mb']),
    if (samples.any((s) => s['malloc_used_mb'] != null)) ...[
      ('m.used', (s) => s['malloc_used_mb']),
      ('m.free', (s) => s['malloc_free_mb']),
    ],
    ('images', (s) => s['images_mb']),
    ('n', (s) => s['images']),
    if (android) ...[
      ('java', (s) => _android(s, 'java-heap')),
      ('native', (s) => _android(s, 'native-heap')),
      ('gfx', (s) => _android(s, 'graphics')),
      ('pss', (s) => _android(s, 'total-pss')),
    ],
    ('players', (s) => s['players']),
  ];
  final rows = [
    ['', for (final c in columns) c.$1],
    for (final s in samples)
      ['${s['label']}', for (final c in columns) c.$2(s)?.toString() ?? '–'],
  ];
  final widths = [
    for (var i = 0; i < rows.first.length; i++)
      rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b),
  ];
  for (final r in rows) {
    out.writeln(
      [
        r.first.padRight(widths.first),
        for (var i = 1; i < r.length; i++) r[i].padLeft(widths[i]),
      ].join('  '),
    );
  }
  out
    ..writeln(
      'All sizes MB. rss = resident; anon/file = its unbacked and '
      'file-backed parts; heap/ext = Dart heap and the native memory its '
      'objects hold; m.used/m.free = what glibc has handed out, and the '
      'freed memory it keeps for reuse; images = the decoded image cache.',
    )
    ..write(_verdict(run['scenario'] as String?, samples));
  final classes = run['classes'] as List?;
  if (classes != null && classes.isNotEmpty) {
    out.writeln('Dart classes that grew most, start to end (after a GC):');
    for (final c in classes.cast<Map<String, dynamic>>()) {
      out.writeln(
        '  ${'${c['kb_grown']}'.padLeft(7)} KB  '
        '${'${c['instances_grown']}'.padLeft(7)} more, '
        '${'${c['instances']}'.padLeft(7)} now  ${c['class']}',
      );
    }
  }
  return out.toString();
}

Object? _android(Map<String, Object?> s, String key) =>
    (s['android_mb'] as Map?)?[key];

int? _rss(Map<String, Object?>? s) => s?['rss_mb'] as int?;

String _verdict(String? scenario, List<Map<String, Object?>> samples) {
  if (samples.isEmpty) return 'No samples.';
  Map<String, Object?>? first(String prefix) =>
      samples.where((s) => '${s['label']}'.startsWith(prefix)).firstOrNull;
  final out = StringBuffer();
  void line(String text, {bool? pass}) =>
      out.writeln(pass == null ? text : '${pass ? 'PASS' : 'FAIL'}  $text');
  final start = _rss(first('start'));
  final peak = samples
      .map((s) => s['max_rss_mb'] as int? ?? 0)
      .reduce((a, b) => a > b ? a : b);
  line('start ${start ?? '–'} MB, highest $peak MB');
  switch (scenario) {
    case 'cycle':
      final closed = samples
          .where((s) => '${s['label']}'.startsWith('closed'))
          .toList();
      if (closed.isEmpty || start == null) break;
      final firstClose = _rss(closed.first)!;
      final lastClose = _rss(closed.last)!;
      line(
        'T1 after the first close: +${firstClose - start} MB over start '
        '(target ≤ +$t1GiveBack)',
        pass: firstClose - start <= t1GiveBack,
      );
      if (closed.length > 1) {
        final growth = lastClose - firstClose;
        line(
          'T2 close #${closed.length} vs #1: ${_signed(growth)} MB, '
          '${_signed((growth / (closed.length - 1)).round())} MB a video '
          '(target ≤ +$t2Growth in all)',
          pass: growth <= t2Growth,
        );
      }
      final players = closed.map((s) => s['players']).whereType<int>();
      if (players.any((p) => p != 0)) {
        line('players still alive after a close: $players', pass: false);
      }
    case 'browse':
      final idle = samples
          .where((s) => '${s['label']}'.startsWith('idle'))
          .toList();
      if (idle.length < 2) break;
      // The last 5 minutes: 10 samples, 30 s apart.
      final from = idle[idle.length > 10 ? idle.length - 11 : 0];
      final rise = _rss(idle.last)! - _rss(from)!;
      line(
        'T3 idle, the last ${(idle.last['t_s'] as int) - (from['t_s'] as int)} '
        's: ${_signed(rise)} MB (target < +$t3IdleRise)',
        pass: rise < t3IdleRise,
      );
    case 'long':
      final playing = samples
          .where((s) => '${s['label']}'.startsWith('playing'))
          .toList();
      if (playing.length < 2) break;
      // The last 5 minutes: 10 samples, 30 s apart. Earlier, each seek
      // steps it up (mpv keeps the range it left in its cache).
      final from = playing[playing.length > 10 ? playing.length - 11 : 0];
      final rise = _rss(playing.last)! - _rss(from)!;
      line(
        'T4 the last ${(playing.last['t_s'] as int) - (from['t_s'] as int)} '
        's of playback: ${_signed(rise)} MB (target < +$t4PlayRise)',
        pass: rise < t4PlayRise,
      );
  }
  return out.toString();
}

String _signed(int mb) => mb >= 0 ? '+$mb' : '$mb';
