Future<R> runInBackground<R>(Future<R> Function() computation) =>
    throw UnsupportedError('the web has no background isolates');
