/// Returns the credential to attach to the next call. The Framework never
/// caches, stores, or logs what this returns, and never learns where it came
/// from: acquiring a token is the product's job.
///
/// `forceRefresh` mirrors the App's settled convention: the Framework asks for
/// a fresh credential exactly once, after a call was refused as
/// unauthenticated. Deciding whether the cached one is still good is the
/// product's job too.
typedef LocalSyncAccessTokenProvider =
    Future<String> Function({bool forceRefresh});
