// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
enum AppRole { host, client }

class AppConfig {
  static const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const databaseUrl = String.fromEnvironment('FIREBASE_DATABASE_URL');
  static const region = 'asia-east1';
  static bool get ready => [
    apiKey,
    appId,
    senderId,
    projectId,
    databaseUrl,
  ].every((v) => v.isNotEmpty);
}

/// Must match MAX_FAMILY_CLIENTS in backend/functions/src/state.js.
const maxFamilyClients = 6;

/// Project identity shown on the About page. The LICENSE requires keeping the
/// original-author credit in any copy or derived work.
abstract final class AppInfo {
  static const name = 'FamilyHelper';
  static const author = 'cyc';
  static const copyright = '© 2026 cyc';
  static const license = 'PolyForm Noncommercial 1.0.0（附加條款：禁止上架商店）';

  /// Set to the public GitHub URL once the repository exists.
  static const repository = 'https://github.com/cyc083/FamilyHelper';
}
