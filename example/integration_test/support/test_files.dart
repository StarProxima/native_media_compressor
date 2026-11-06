/// Fixture and output file access for the integration tests: files in a
/// temporary directory on native platforms, `blob:` URLs on the web.
library;

export 'test_files_io.dart' if (dart.library.js_interop) 'test_files_web.dart';
