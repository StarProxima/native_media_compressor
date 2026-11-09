/// Files the Dart layer handles around a platform call: sizes, outputs held
/// back until they prove worth keeping, and inputs from memory. Local files
/// on native platforms, object URLs on the web.
library;

export 'staged_files_io.dart'
    if (dart.library.js_interop) 'staged_files_web.dart';
