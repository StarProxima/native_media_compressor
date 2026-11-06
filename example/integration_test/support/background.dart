/// Runs a computation in a background isolate; the web has none.
library;

export 'background_io.dart' if (dart.library.js_interop) 'background_web.dart';
