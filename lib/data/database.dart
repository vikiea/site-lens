import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

/// SQLite statements that materialise the v2 "profile" schema. They are shared
/// by fresh installs (`onCreate`) and the v1 -> v2 migration (`onUpgrade`) so
/// the two paths can never drift apart.
const _v2Tables = <String>[
  'CREATE TABLE IF NOT EXISTS profiles ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'name TEXT NOT NULL, '
      'enabled INTEGER NOT NULL DEFAULT 1, '
      'ready_selector TEXT NOT NULL DEFAULT \'main\', '
      'last_landing TEXT, '
      'last_landing_at TEXT, '
      'created_at TEXT NOT NULL)',
  'CREATE TABLE IF NOT EXISTS profile_pages ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, '
      'url TEXT NOT NULL, '
      'region_selector TEXT NOT NULL, '
      'enabled INTEGER NOT NULL DEFAULT 1, '
      'refreshed_at TEXT, '
      'error TEXT, '
      'UNIQUE(profile_id, url))',
  'CREATE TABLE IF NOT EXISTS profile_scripts ('
      'profile_id INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, '
      'script_id TEXT NOT NULL REFERENCES scripts(id) ON DELETE CASCADE, '
      'content_hash TEXT NOT NULL, '
      'PRIMARY KEY(profile_id, script_id))',
  'CREATE TABLE IF NOT EXISTS profile_health ('
      'profile_id INTEGER PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE, '
      'consecutive_failures INTEGER NOT NULL DEFAULT 0, '
      'state TEXT NOT NULL DEFAULT \'unknown\', '
      'last_checked_at TEXT, '
      'last_ok_at TEXT)',
  // Local "already approved this pack fingerprint" memory. Never exported.
  'CREATE TABLE IF NOT EXISTS pack_approvals ('
      'fingerprint TEXT PRIMARY KEY, '
      'approved_at TEXT NOT NULL)',
];

const _v3Tables = <String>[
  'CREATE TABLE IF NOT EXISTS resources ('
      'script_id TEXT NOT NULL REFERENCES scripts(id) ON DELETE CASCADE, '
      'position INTEGER NOT NULL, '
      'name TEXT NOT NULL, '
      'url TEXT NOT NULL, '
      'hash TEXT NOT NULL, '
      'bytes BLOB NOT NULL, '
      'PRIMARY KEY(script_id, position))',
];

const _v2CandidateColumn =
    'ALTER TABLE candidates ADD COLUMN profile_id INTEGER REFERENCES profiles(id) ON DELETE SET NULL';
const _v2SourceColumn =
    'ALTER TABLE sources ADD COLUMN profile_id INTEGER REFERENCES profiles(id) ON DELETE SET NULL';

const _v5Tables = <String>[
  'CREATE TABLE IF NOT EXISTS filter_sources ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'profile_id INTEGER REFERENCES profiles(id) ON DELETE SET NULL, '
      'label TEXT NOT NULL, url TEXT NOT NULL, kind TEXT NOT NULL DEFAULT \'list\', '
      'version TEXT NOT NULL DEFAULT \'\', license TEXT NOT NULL DEFAULT \'\', '
      'sha256 TEXT NOT NULL DEFAULT \'\', status TEXT NOT NULL DEFAULT \'missing\', '
      'file_ref TEXT, refreshed_at TEXT, error TEXT)',
  'CREATE TABLE IF NOT EXISTS filter_snapshots ('
      'id TEXT PRIMARY KEY, source_id INTEGER REFERENCES filter_sources(id) ON DELETE SET NULL, '
      'version TEXT NOT NULL, source_url TEXT NOT NULL, sha256 TEXT NOT NULL, '
      'state TEXT NOT NULL, created_at TEXT NOT NULL, file_ref TEXT NOT NULL, '
      'unsupported_rule_count INTEGER NOT NULL DEFAULT 0, error TEXT)',
  'CREATE TABLE IF NOT EXISTS filter_policies ('
      // profile_id 0 is the global policy. SQLite INTEGER PRIMARY KEY cannot
      // represent a nullable global row reliably, so the sentinel is explicit.
      'profile_id INTEGER PRIMARY KEY, '
      'enabled INTEGER NOT NULL DEFAULT 0, page_filtering INTEGER NOT NULL DEFAULT 1, '
      'domain_exceptions TEXT NOT NULL DEFAULT \'[]\', blocked_domains TEXT NOT NULL DEFAULT \'[]\', '
      'updated_at TEXT NOT NULL)',
  'CREATE TABLE IF NOT EXISTS media_candidates ('
      'id TEXT PRIMARY KEY, host_id INTEGER NOT NULL, generation INTEGER NOT NULL, '
      'source_url TEXT NOT NULL, media_url TEXT NOT NULL, title TEXT NOT NULL, '
      'mime TEXT NOT NULL, source TEXT NOT NULL, duration_ms INTEGER, created_at TEXT NOT NULL)',
  'CREATE TABLE IF NOT EXISTS media_tasks ('
      'id TEXT PRIMARY KEY, candidate_id TEXT NOT NULL REFERENCES media_candidates(id) ON DELETE CASCADE, '
      'host_id INTEGER NOT NULL, generation INTEGER NOT NULL, source_url TEXT NOT NULL, '
      'cache_key TEXT NOT NULL UNIQUE, state TEXT NOT NULL, updated_at TEXT NOT NULL, '
      'bytes_downloaded INTEGER NOT NULL DEFAULT 0, total_bytes INTEGER, error_code TEXT, local_ref TEXT)',
  'CREATE TABLE IF NOT EXISTS script_approvals ('
      'script_id TEXT PRIMARY KEY REFERENCES scripts(id) ON DELETE CASCADE, '
      "network_mode TEXT NOT NULL DEFAULT 'declared', approval_reason TEXT, "
      'approved_at TEXT, public_confirmed INTEGER NOT NULL DEFAULT 0)',
];

// Drift's SQL API keeps the small schema explicit and permits in-memory tests.
// No browser cookie or password is copied into this database.
class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);
  static Future<AppDatabase> open() async {
    final directory = await getApplicationSupportDirectory();
    return AppDatabase(
      NativeDatabase.createInBackground(
        File('${directory.path}/site_lens.sqlite'),
      ),
    );
  }

  /// Test-only seam so a migration failure can be injected at a known step.
  /// Never set in production code.
  @visibleForTesting
  static void Function(String step)? migrationDebugHook;

  @override
  int get schemaVersion => 5;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in [
        'CREATE TABLE sources (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, url TEXT NOT NULL UNIQUE, region_selector TEXT NOT NULL, profile_id INTEGER REFERENCES profiles(id) ON DELETE SET NULL, enabled INTEGER NOT NULL DEFAULT 1, refreshed_at TEXT, error TEXT)',
        'CREATE TABLE candidates (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, url TEXT NOT NULL UNIQUE, source_id INTEGER REFERENCES sources(id) ON DELETE SET NULL, profile_id INTEGER REFERENCES profiles(id) ON DELETE SET NULL, ready_selector TEXT NOT NULL DEFAULT \'main\', ready_selector_override TEXT, enabled INTEGER NOT NULL DEFAULT 1)',
        'CREATE TABLE probes (id INTEGER PRIMARY KEY AUTOINCREMENT, result TEXT NOT NULL)',
        'CREATE TABLE scripts (id TEXT PRIMARY KEY, name TEXT NOT NULL, source TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, approved_digest TEXT)',
        'CREATE TABLE script_values (script_id TEXT NOT NULL REFERENCES scripts(id) ON DELETE CASCADE, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(script_id,key))',
        'CREATE TABLE dependencies (script_id TEXT NOT NULL REFERENCES scripts(id) ON DELETE CASCADE, position INTEGER NOT NULL, url TEXT NOT NULL, hash TEXT NOT NULL, bytes BLOB NOT NULL, PRIMARY KEY(script_id,position))',
        'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        'CREATE TABLE script_errors (id INTEGER PRIMARY KEY AUTOINCREMENT, script_id TEXT NOT NULL, happened_at TEXT NOT NULL, message TEXT NOT NULL)',
        ..._v2Tables,
        ..._v3Tables,
        'CREATE TABLE health_run_leases(name TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL)',
        ..._v5Tables,
      ]) {
        await customStatement(sql);
      }
    },
    onUpgrade: (_, from, to) async {
      if (from < 2) await _migrateV1toV2();
      if (from < 3) await _migrateV2toV3();
      if (from < 4) await _migrateV3toV4();
      if (from < 5) await _migrateV4toV5();
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // The WorkManager isolate opens a second connection to the same file;
      // WAL + a busy timeout keep that from failing on a write conflict.
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );

  Future<void> _migrateV3toV4() => transaction(() async {
    migrationDebugHook?.call('v3-to-v4');
    await customStatement(
      'CREATE TABLE IF NOT EXISTS health_run_leases(name TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL)',
    );
    if (!await _columnExists('candidates', 'ready_selector_override')) {
      await customStatement(
        'ALTER TABLE candidates ADD COLUMN ready_selector_override TEXT',
      );
      migrationDebugHook?.call('v4-after-column');
      // Backfill only when adding the column. A retry after a committed
      // migration must never overwrite a subsequently saved explicit override.
      await customStatement(
        "UPDATE candidates SET ready_selector_override=CASE WHEN ready_selector='main' THEN NULL ELSE ready_selector END",
      );
    }
  });

  Future<void> _migrateV4toV5() => transaction(() async {
    migrationDebugHook?.call('v4-to-v5');
    for (final sql in _v5Tables) {
      await customStatement(sql);
    }
    // Keep the v4 -> v5 upgrade failure-injectable. This is test-only and
    // proves the table creation plus approval backfill remains one transaction.
    migrationDebugHook?.call('v5-after-tables');
    // A short-lived development build stored these fields directly on
    // scripts. Copy them when upgrading that build; v1-v4 databases simply
    // receive a declared, unapproved row for every existing script.
    final scriptColumns = await _tableColumns('scripts');
    if ({
      'network_mode',
      'approval_reason',
      'approved_at',
      'public_confirmed',
    }.every(scriptColumns.contains)) {
      await customStatement(
        'INSERT OR REPLACE INTO script_approvals(script_id,network_mode,approval_reason,approved_at,public_confirmed) '
        'SELECT id,network_mode,approval_reason,approved_at,public_confirmed FROM scripts',
      );
    } else {
      await customStatement(
        "INSERT OR IGNORE INTO script_approvals(script_id) SELECT id FROM scripts",
      );
    }
    migrationDebugHook?.call('v5-done');
  });

  /// v1 -> v2 migration. Runs inside a single transaction so a failure at any
  /// step leaves the database exactly at v1 with the user's data intact.
  ///
  /// Strategy: each `sources` row becomes a profile plus its publishing page;
  /// its candidates are attached to that profile. Manual (source-less)
  /// candidates are attached to a lazily-created "未归类" profile. Scripts are
  /// never auto-bound: a broad `*://*/*` fallback makes that guess wrong.
  ///
  /// The whole body is idempotent: if the process dies after the data commit
  /// but before SQLite's `user_version` is bumped, the next open re-runs this
  /// safely instead of failing on a duplicate `profile_id` column.
  Future<void> _migrateV1toV2() => transaction(() async {
    migrationDebugHook?.call('start');
    for (final sql in _v2Tables) {
      await customStatement(sql);
    }
    if (!await _columnExists('candidates', 'profile_id')) {
      await customStatement(_v2CandidateColumn);
    }
    if (!await _columnExists('sources', 'profile_id')) {
      await customStatement(_v2SourceColumn);
    }
    migrationDebugHook?.call('after-tables');

    final sourceToProfile = <int, int>{};
    for (final row in await customSelect(
      'SELECT * FROM sources ORDER BY id',
    ).get()) {
      final url = row.read<String>('url');
      final profileId =
          await _profileIdForPageUrl(url) ??
          await _insertProfile(row.read<String>('label'), 'main');
      final sourceId = row.read<int>('id');
      sourceToProfile[sourceId] = profileId;
      await customStatement('UPDATE sources SET profile_id=? WHERE id=?', [
        profileId,
        sourceId,
      ]);
      await customStatement(
        'INSERT INTO profile_pages(profile_id,url,region_selector,enabled,refreshed_at,error) VALUES(?,?,?,?,?,?) '
        'ON CONFLICT(profile_id,url) DO NOTHING',
        [
          profileId,
          url,
          row.read<String>('region_selector'),
          row.read<int>('enabled'),
          row.readNullable<String>('refreshed_at'),
          row.readNullable<String>('error'),
        ],
      );
    }
    migrationDebugHook?.call('after-sources');

    int? unassigned;
    Future<int> ensureUnassigned() async =>
        unassigned ??= await _ensureUnassignedProfile();
    for (final row in await customSelect(
      'SELECT id,source_id FROM candidates WHERE profile_id IS NULL ORDER BY id',
    ).get()) {
      final sourceId = row.readNullable<int>('source_id');
      final profileId = sourceId == null
          ? await ensureUnassigned()
          : sourceToProfile[sourceId] ?? await ensureUnassigned();
      await customStatement('UPDATE candidates SET profile_id=? WHERE id=?', [
        profileId,
        row.read<int>('id'),
      ]);
    }
    migrationDebugHook?.call('after-candidates');

    for (final row in await customSelect('SELECT id FROM profiles').get()) {
      await customStatement(
        'INSERT OR IGNORE INTO profile_health(profile_id) VALUES(?)',
        [row.read<int>('id')],
      );
    }
    migrationDebugHook?.call('done');
  });

  /// v2 -> v3: adds the pinned `@resource` snapshot table. Idempotent.
  Future<void> _migrateV2toV3() => transaction(() async {
    for (final sql in _v3Tables) {
      await customStatement(sql);
    }
  });

  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  Future<Set<String>> _tableColumns(String table) async => (await customSelect(
    'PRAGMA table_info($table)',
  ).get()).map((row) => row.read<String>('name')).toSet();

  Future<int?> _profileIdForPageUrl(String url) async => (await customSelect(
    'SELECT profile_id FROM profile_pages WHERE url=? ORDER BY profile_id LIMIT 1',
    variables: [Variable(url)],
  ).getSingleOrNull())?.read<int>('profile_id');

  Future<int> _insertProfile(String name, String readySelector) async {
    await customStatement(
      'INSERT INTO profiles(name,ready_selector,created_at) VALUES(?,?,?)',
      [name, readySelector, DateTime.now().toIso8601String()],
    );
    return (await customSelect(
      'SELECT last_insert_rowid() AS id',
    ).getSingle()).read<int>('id');
  }

  Future<int> _ensureUnassignedProfile() async =>
      await _profileIdByName(unassignedProfileName) ??
      await _insertProfile(unassignedProfileName, 'main');

  /// Public lookup for the "未归类" bucket id (null when none exists yet).
  Future<int?> unassignedProfileId() => _profileIdByName(unassignedProfileName);

  /// Adopts an existing (unassigned) candidate into [profileId] on import.
  Future<void> adoptCandidate(
    Uri url,
    int profileId, {
    String? label,
    bool? enabled,
    String readySelector = 'main',
    String? readySelectorOverride,
  }) => customStatement(
    'UPDATE candidates SET profile_id=?,label=COALESCE(?,label),enabled=COALESCE(?,enabled),ready_selector=?,ready_selector_override=? WHERE url=?',
    [
      profileId,
      label,
      enabled == null ? null : (enabled ? 1 : 0),
      readySelector,
      readySelectorOverride,
      url.toString(),
    ],
  );

  Future<int?> _profileIdByName(String name) async => (await customSelect(
    'SELECT id FROM profiles WHERE name=? ORDER BY id LIMIT 1',
    variables: [Variable(name)],
  ).getSingleOrNull())?.read<int>('id');

  Future<List<Candidate>> candidates({int? profileId}) async =>
      (await customSelect(
            profileId == null
                ? 'SELECT c.*, COALESCE(c.ready_selector_override,p.ready_selector,c.ready_selector) AS effective_ready_selector FROM candidates c LEFT JOIN profiles p ON p.id=c.profile_id ORDER BY c.id'
                : 'SELECT c.*, COALESCE(c.ready_selector_override,p.ready_selector,c.ready_selector) AS effective_ready_selector FROM candidates c LEFT JOIN profiles p ON p.id=c.profile_id WHERE c.profile_id=? ORDER BY c.id',
            variables: profileId == null ? const [] : [Variable(profileId)],
          ).get())
          .map(
            (r) => Candidate(
              id: r.read<int>('id'),
              url: Uri.parse(r.read<String>('url')),
              label: r.read<String>('label'),
              enabled: r.read<int>('enabled') == 1,
              sourceId: r.readNullable<int>('source_id'),
              profileId: r.readNullable<int>('profile_id'),
              readySelector: r.read<String>('effective_ready_selector'),
              readySelectorOverride: r.readNullable<String>(
                'ready_selector_override',
              ),
            ),
          )
          .toList();
  static const _legacySelector = Object();

  Future<void> addCandidate(
    Uri url, {
    String? label,
    int? sourceId,
    int? profileId,
    String readySelector = 'main',
    Object? readySelectorOverride = _legacySelector,
    bool enabled = true,
  }) async {
    var resolved = profileId;
    if (resolved == null && sourceId != null) {
      final row = await customSelect(
        'SELECT url FROM sources WHERE id=?',
        variables: [Variable(sourceId)],
      ).getSingleOrNull();
      if (row != null) {
        resolved = await _profileIdForPageUrl(row.read<String>('url'));
      }
    }
    // A candidate with no owner would be invisible to every profile panel, so
    // it joins the "未归类" bucket instead of being left as a NULL profile_id.
    resolved ??= await _ensureUnassignedProfile();
    await customStatement(
      'INSERT INTO candidates(label,url,source_id,profile_id,ready_selector,ready_selector_override,enabled) VALUES(?,?,?,?,?,?,?) ON CONFLICT(url) DO NOTHING',
      [
        label ?? url.host,
        url.toString(),
        sourceId,
        resolved,
        readySelector,
        identical(readySelectorOverride, _legacySelector)
            ? (readySelector == 'main' ? null : readySelector)
            : readySelectorOverride as String?,
        enabled ? 1 : 0,
      ],
    );
  }

  Future<void> setCandidateEnabled(int id, bool enabled) => customStatement(
    'UPDATE candidates SET enabled=? WHERE id=?',
    [enabled ? 1 : 0, id],
  );
  Future<void> setCandidateReadySelectorOverride(int id, String? selector) {
    if (selector != null && selector.trim().isEmpty) {
      throw const FormatException('选择器不能为空');
    }
    return customStatement(
      'UPDATE candidates SET ready_selector_override=? WHERE id=?',
      [selector?.trim(), id],
    );
  }

  Future<void> deleteCandidate(int id) =>
      customStatement('DELETE FROM candidates WHERE id=?', [id]);

  /// Removes stale candidates that are now explicitly configured as publishing
  /// pages. Probe history is kept in its append-only table and simply stops
  /// being associated with the active candidate list.
  Future<void> deleteCandidatesByUrls(
    Iterable<String> urls, {
    int? profileId,
  }) async {
    final values = urls.toSet().toList();
    if (values.isEmpty) return;
    final placeholders = List.filled(values.length, '?').join(',');
    final owner = profileId == null ? '' : ' AND profile_id=?';
    await customStatement(
      'DELETE FROM candidates WHERE url IN ($placeholders)$owner',
      [...values, ?profileId],
    );
  }

  Future<List<SiteProfile>> profiles() async =>
      (await customSelect('SELECT * FROM profiles ORDER BY id').get())
          .map(
            (r) => SiteProfile(
              id: r.read<int>('id'),
              name: r.read<String>('name'),
              enabled: r.read<int>('enabled') == 1,
              readySelector: r.read<String>('ready_selector'),
              lastLanding: r.readNullable<String>('last_landing') == null
                  ? null
                  : Uri.parse(r.read<String>('last_landing')),
              lastLandingAt: r.readNullable<String>('last_landing_at') == null
                  ? null
                  : DateTime.parse(r.read<String>('last_landing_at')),
              createdAt: DateTime.parse(r.read<String>('created_at')),
            ),
          )
          .toList();
  Future<int> createProfile(String name, {String readySelector = 'main'}) =>
      transaction(() async {
        final id = await _insertProfile(name, readySelector);
        await customStatement(
          'INSERT OR IGNORE INTO profile_health(profile_id) VALUES(?)',
          [id],
        );
        return id;
      });
  Future<void> renameProfile(int id, String name) =>
      customStatement('UPDATE profiles SET name=? WHERE id=?', [name, id]);
  Future<void> setProfileEnabled(int id, bool enabled) => customStatement(
    'UPDATE profiles SET enabled=? WHERE id=?',
    [enabled ? 1 : 0, id],
  );
  Future<void> setProfileReadySelector(int id, String selector) =>
      customStatement('UPDATE profiles SET ready_selector=? WHERE id=?', [
        selector,
        id,
      ]);
  Future<void> setProfileLastLanding(int id, Uri? landing) => customStatement(
    'UPDATE profiles SET last_landing=?,last_landing_at=? WHERE id=?',
    [
      landing?.toString(),
      landing == null ? null : DateTime.now().toIso8601String(),
      id,
    ],
  );
  Future<void> deleteProfile(int id) => transaction(() async {
    await _reassignCandidates(id);
    await customStatement('DELETE FROM profiles WHERE id=?', [id]);
    await customStatement('DELETE FROM settings WHERE key=?', [
      'profile_config_$id',
    ]);
  });

  /// Moves every candidate owned by [id] into the "未归类" bucket. If [id] *is*
  /// that bucket, a fresh bucket is created first so candidates never dangle.
  Future<void> _reassignCandidates(int id) async {
    var fallback = await _profileIdByName(unassignedProfileName);
    if (fallback == null || fallback == id) {
      fallback = await _insertProfile(unassignedProfileName, 'main');
    }
    await customStatement(
      'UPDATE candidates SET profile_id=? WHERE profile_id=?',
      [fallback, id],
    );
  }

  Future<List<ProfilePage>> profilePages({int? profileId}) async =>
      (await customSelect(
            profileId == null
                ? 'SELECT * FROM profile_pages ORDER BY id'
                : 'SELECT * FROM profile_pages WHERE profile_id=? ORDER BY id',
            variables: profileId == null ? const [] : [Variable(profileId)],
          ).get())
          .map(
            (r) => ProfilePage(
              id: r.read<int>('id'),
              profileId: r.read<int>('profile_id'),
              url: Uri.parse(r.read<String>('url')),
              regionSelector: r.read<String>('region_selector'),
              enabled: r.read<int>('enabled') == 1,
              refreshedAt: r.readNullable<String>('refreshed_at') == null
                  ? null
                  : DateTime.parse(r.read<String>('refreshed_at')),
              error: r.readNullable<String>('error'),
            ),
          )
          .toList();
  Future<void> addProfilePage(int profileId, Uri url, String regionSelector) =>
      customStatement(
        'INSERT INTO profile_pages(profile_id,url,region_selector) VALUES(?,?,?) ON CONFLICT(profile_id,url) DO UPDATE SET region_selector=excluded.region_selector,enabled=1',
        [profileId, url.toString(), regionSelector],
      );
  Future<void> deleteProfilePage(int id) =>
      customStatement('DELETE FROM profile_pages WHERE id=?', [id]);
  Future<void> profilePageRefreshed(int id, {String? error}) => error == null
      ? customStatement(
          'UPDATE profile_pages SET refreshed_at=?,error=NULL WHERE id=?',
          [DateTime.now().toIso8601String(), id],
        )
      : customStatement('UPDATE profile_pages SET error=? WHERE id=?', [
          error,
          id,
        ]);

  Future<List<ProfileHealth>> profileHealthAll() async =>
      (await customSelect('SELECT * FROM profile_health').get())
          .map(
            (r) => ProfileHealth(
              profileId: r.read<int>('profile_id'),
              consecutiveFailures: r.read<int>('consecutive_failures'),
              state: ProfileHealthState.values.byName(r.read<String>('state')),
              lastCheckedAt: r.readNullable<String>('last_checked_at') == null
                  ? null
                  : DateTime.parse(r.read<String>('last_checked_at')),
              lastOkAt: r.readNullable<String>('last_ok_at') == null
                  ? null
                  : DateTime.parse(r.read<String>('last_ok_at')),
            ),
          )
          .toList();
  Future<ProfileHealth> profileHealth(int profileId) async {
    final rows = await profileHealthAll();
    return rows.where((h) => h.profileId == profileId).firstOrNull ??
        ProfileHealth(profileId: profileId);
  }

  Future<void> saveProfileHealth(ProfileHealth health) => customStatement(
    'INSERT INTO profile_health(profile_id,consecutive_failures,state,last_checked_at,last_ok_at) VALUES(?,?,?,?,?) '
    'ON CONFLICT(profile_id) DO UPDATE SET consecutive_failures=excluded.consecutive_failures,state=excluded.state,last_checked_at=excluded.last_checked_at,last_ok_at=excluded.last_ok_at',
    [
      health.profileId,
      health.consecutiveFailures,
      health.state.name,
      health.lastCheckedAt?.toIso8601String(),
      health.lastOkAt?.toIso8601String(),
    ],
  );

  Future<List<ProfileScript>> profileScripts({int? profileId}) async =>
      (await customSelect(
            profileId == null
                ? 'SELECT * FROM profile_scripts ORDER BY profile_id,script_id'
                : 'SELECT * FROM profile_scripts WHERE profile_id=? ORDER BY script_id',
            variables: profileId == null ? const [] : [Variable(profileId)],
          ).get())
          .map(
            (r) => ProfileScript(
              profileId: r.read<int>('profile_id'),
              scriptId: r.read<String>('script_id'),
              contentHash: r.read<String>('content_hash'),
            ),
          )
          .toList();
  Future<void> linkProfileScript(
    int profileId,
    String scriptId,
    String contentHash,
  ) => customStatement(
    'INSERT INTO profile_scripts(profile_id,script_id,content_hash) VALUES(?,?,?) '
    'ON CONFLICT(profile_id,script_id) DO UPDATE SET content_hash=excluded.content_hash',
    [profileId, scriptId, contentHash],
  );

  /// Re-points every ownership row at the current content fingerprint. Called
  /// whenever a script's source is edited, so the "N 处是同一份" hint and pack
  /// export never rely on a stale hash.
  Future<void> updateProfileScriptHashes(String scriptId, String contentHash) =>
      customStatement(
        'UPDATE profile_scripts SET content_hash=? WHERE script_id=?',
        [contentHash, scriptId],
      );

  Future<void> unlinkProfileScript(int profileId, String scriptId) =>
      customStatement(
        'DELETE FROM profile_scripts WHERE profile_id=? AND script_id=?',
        [profileId, scriptId],
      );

  Future<bool> packApproved(String fingerprint) async =>
      (await customSelect(
        'SELECT 1 AS ok FROM pack_approvals WHERE fingerprint=?',
        variables: [Variable(fingerprint)],
      ).getSingleOrNull()) !=
      null;
  Future<void> approvePack(String fingerprint) => customStatement(
    'INSERT INTO pack_approvals(fingerprint,approved_at) VALUES(?,?) ON CONFLICT(fingerprint) DO NOTHING',
    [fingerprint, DateTime.now().toIso8601String()],
  );

  Future<List<PublishingSource>> sources() async =>
      (await customSelect('SELECT * FROM sources ORDER BY id').get())
          .map(
            (r) => PublishingSource(
              id: r.read<int>('id'),
              label: r.read<String>('label'),
              url: Uri.parse(r.read<String>('url')),
              regionSelector: r.read<String>('region_selector'),
              profileId: r.readNullable<int>('profile_id'),
              enabled: r.read<int>('enabled') == 1,
              refreshedAt: r.readNullable<String>('refreshed_at') == null
                  ? null
                  : DateTime.parse(r.read<String>('refreshed_at')),
              error: r.readNullable<String>('error'),
            ),
          )
          .toList();
  // The `sources` table is retained only as a v1 compatibility/rollback
  // surface. These wrappers keep it mirrored onto profiles + profile_pages so
  // the two can never disagree while legacy call sites are retired.
  Future<void> addSource(Uri url, String label, String selector) => transaction(
    () async {
      // Prefer the mapping already recorded on this source row; only fall
      // back to a page-url lookup or a brand new profile when it is absent.
      final existing = await customSelect(
        'SELECT profile_id FROM sources WHERE url=?',
        variables: [Variable(url.toString())],
      ).getSingleOrNull();
      var profileId = existing?.readNullable<int>('profile_id');
      profileId ??= await _profileIdForPageUrl(url.toString());
      profileId ??= await _insertProfile(label, 'main');
      await customStatement(
        'INSERT INTO sources(label,url,region_selector,profile_id) VALUES(?,?,?,?) '
        'ON CONFLICT(url) DO UPDATE SET label=excluded.label,region_selector=excluded.region_selector,'
        'profile_id=COALESCE(sources.profile_id,excluded.profile_id),enabled=1',
        [label, url.toString(), selector, profileId],
      );
      await customStatement('UPDATE profiles SET name=? WHERE id=?', [
        label,
        profileId,
      ]);
      await customStatement(
        'INSERT INTO profile_pages(profile_id,url,region_selector) VALUES(?,?,?) ON CONFLICT(profile_id,url) DO UPDATE SET region_selector=excluded.region_selector,enabled=1',
        [profileId, url.toString(), selector],
      );
    },
  );
  Future<void> deleteSource(int id) => transaction(() async {
    final row = await customSelect(
      'SELECT url,profile_id FROM sources WHERE id=?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    await customStatement('DELETE FROM sources WHERE id=?', [id]);
    if (row == null) return;
    // Drop only this source's own publishing page, scoped to its profile. The
    // profile, its other pages, candidates and script bindings all survive.
    final profileId = row.readNullable<int>('profile_id');
    await customStatement(
      profileId == null
          ? 'DELETE FROM profile_pages WHERE url=?'
          : 'DELETE FROM profile_pages WHERE url=? AND profile_id=?',
      [row.read<String>('url'), ?profileId],
    );
  });
  Future<void> sourceRefreshed(int id, {String? error}) =>
      transaction(() async {
        if (error == null) {
          await customStatement(
            'UPDATE sources SET refreshed_at=?,error=NULL WHERE id=?',
            [DateTime.now().toIso8601String(), id],
          );
        } else {
          await customStatement('UPDATE sources SET error=? WHERE id=?', [
            error,
            id,
          ]);
        }
        final row = await customSelect(
          'SELECT url,profile_id FROM sources WHERE id=?',
          variables: [Variable(id)],
        ).getSingleOrNull();
        if (row == null) return;
        final profileId = row.readNullable<int>('profile_id');
        if (profileId == null) return;
        final page = await customSelect(
          'SELECT id FROM profile_pages WHERE profile_id=? AND url=? ORDER BY id LIMIT 1',
          variables: [Variable(profileId), Variable(row.read<String>('url'))],
        ).getSingleOrNull();
        if (page != null) {
          await profilePageRefreshed(page.read<int>('id'), error: error);
        }
      });
  Future<void> saveProbe(ProbeResult result) async {
    await customStatement('INSERT INTO probes(result) VALUES(?)', [
      jsonEncode(result.toJson()),
    ]);
    await customStatement(
      'DELETE FROM probes WHERE id NOT IN (SELECT id FROM probes ORDER BY id DESC LIMIT 300)',
    );
  }

  Future<List<ProbeResult>> recentProbes() async =>
      (await customSelect(
            'SELECT result FROM probes ORDER BY id DESC LIMIT 100',
          ).get())
          .map(
            (r) => ProbeResult.fromJson(
              jsonDecode(r.read<String>('result')) as Map<String, dynamic>,
            ),
          )
          .toList();
  Future<List<InstalledScript>> scripts() async =>
      (await customSelect(
            'SELECT s.*, COALESCE(a.network_mode,\'declared\') AS network_mode, a.approval_reason, a.approved_at, COALESCE(a.public_confirmed,0) AS public_confirmed '
            'FROM scripts s LEFT JOIN script_approvals a ON a.script_id=s.id ORDER BY s.name',
          ).get())
          .map(
            (r) => InstalledScript(
              id: r.read<String>('id'),
              name: r.read<String>('name'),
              source: r.read<String>('source'),
              enabled: r.read<int>('enabled') == 1,
              approvedDigest: r.readNullable<String>('approved_digest'),
              networkMode: ScriptNetworkMode.values.byName(
                r.read<String>('network_mode'),
              ),
              approvalReason: r.readNullable<String>('approval_reason'),
              approvedAt: r.readNullable<String>('approved_at') == null
                  ? null
                  : DateTime.parse(r.read<String>('approved_at')),
              publicConfirmed: r.read<int>('public_confirmed') == 1,
            ),
          )
          .toList();
  Future<void> saveScript(InstalledScript script) => transaction(() async {
    await customStatement(
      'INSERT INTO scripts(id,name,source) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,source=excluded.source,enabled=0,approved_digest=NULL',
      [script.id, script.name, script.source],
    );
    await customStatement(
      'INSERT INTO script_approvals(script_id,network_mode,approval_reason,approved_at,public_confirmed) VALUES(?,?,?,?,?) '
      'ON CONFLICT(script_id) DO UPDATE SET network_mode=\'declared\',approval_reason=NULL,approved_at=NULL,public_confirmed=0',
      [
        script.id,
        script.networkMode.name,
        script.approvalReason,
        script.approvedAt?.toIso8601String(),
        script.publicConfirmed ? 1 : 0,
      ],
    );
  });
  Future<void> setScriptEnabled(String id, bool enabled, {String? digest}) =>
      transaction(() async {
        await customStatement(
          'UPDATE scripts SET enabled=?,approved_digest=COALESCE(?,approved_digest) WHERE id=?',
          [enabled ? 1 : 0, digest, id],
        );
        if (enabled) {
          await customStatement(
            'INSERT INTO script_approvals(script_id,approved_at) VALUES(?,?) ON CONFLICT(script_id) DO UPDATE SET approved_at=excluded.approved_at',
            [id, DateTime.now().toUtc().toIso8601String()],
          );
        }
      });

  Future<void> setScriptApprovalMode(
    String id,
    ScriptNetworkMode mode, {
    String? reason,
    bool publicConfirmed = false,
  }) => transaction(() async {
    await customStatement(
      'INSERT INTO script_approvals(script_id,network_mode,approval_reason,approved_at,public_confirmed) VALUES(?,?,?,?,?) '
      'ON CONFLICT(script_id) DO UPDATE SET network_mode=excluded.network_mode,approval_reason=excluded.approval_reason,approved_at=NULL,public_confirmed=excluded.public_confirmed',
      [id, mode.name, reason, null, publicConfirmed ? 1 : 0],
    );
    await customStatement(
      'UPDATE scripts SET enabled=0,approved_digest=NULL WHERE id=?',
      [id],
    );
  });

  Future<void> clearScriptApproval(String id) => transaction(() async {
    await customStatement(
      'UPDATE scripts SET enabled=0,approved_digest=NULL WHERE id=?',
      [id],
    );
    await customStatement(
      'INSERT INTO script_approvals(script_id,approved_at,public_confirmed) VALUES(?,?,0) '
      'ON CONFLICT(script_id) DO UPDATE SET approved_at=NULL,public_confirmed=0',
      [id, null],
    );
  });
  Future<void> deleteScript(String id) =>
      customStatement('DELETE FROM scripts WHERE id=?', [id]);
  Future<List<PinnedDependency>> dependencies(String id) async =>
      (await customSelect(
            'SELECT * FROM dependencies WHERE script_id=? ORDER BY position',
            variables: [Variable(id)],
          ).get())
          .map(
            (r) => PinnedDependency(
              url: Uri.parse(r.read<String>('url')),
              hash: r.read<String>('hash'),
              bytes: r.read<Uint8List>('bytes'),
            ),
          )
          .toList();
  Future<void> pinDependencies(String id, List<PinnedDependency> deps) =>
      transaction(() async {
        await customStatement(
          'UPDATE scripts SET enabled=0,approved_digest=NULL WHERE id=?',
          [id],
        );
        await customStatement('DELETE FROM dependencies WHERE script_id=?', [
          id,
        ]);
        for (var i = 0; i < deps.length; i++) {
          final d = deps[i];
          await customStatement('INSERT INTO dependencies VALUES(?,?,?,?,?)', [
            id,
            i,
            d.url.toString(),
            d.hash,
            Uint8List.fromList(d.bytes),
          ]);
        }
      });
  Future<List<PinnedResource>> resources(String id) async =>
      (await customSelect(
            'SELECT * FROM resources WHERE script_id=? ORDER BY position',
            variables: [Variable(id)],
          ).get())
          .map(
            (r) => PinnedResource(
              name: r.read<String>('name'),
              url: Uri.parse(r.read<String>('url')),
              hash: r.read<String>('hash'),
              bytes: r.read<Uint8List>('bytes'),
            ),
          )
          .toList();
  Future<void> pinResources(String id, List<PinnedResource> resources) =>
      transaction(() async {
        await customStatement(
          'UPDATE scripts SET enabled=0,approved_digest=NULL WHERE id=?',
          [id],
        );
        await customStatement('DELETE FROM resources WHERE script_id=?', [id]);
        for (var i = 0; i < resources.length; i++) {
          final r = resources[i];
          await customStatement(
            'INSERT INTO resources(script_id,position,name,url,hash,bytes) VALUES(?,?,?,?,?,?)',
            [
              id,
              i,
              r.name,
              r.url.toString(),
              r.hash,
              Uint8List.fromList(r.bytes),
            ],
          );
        }
      });

  Future<Map<String, dynamic>> values(String id) async => {
    for (final r in await customSelect(
      'SELECT key,value FROM script_values WHERE script_id=?',
      variables: [Variable(id)],
    ).get())
      r.read<String>('key'): jsonDecode(r.read<String>('value')),
  };
  Future<void> setValue(String id, String key, Object? value) async {
    final encoded = jsonEncode(value);
    if (key.length > 256 || encoded.length > 64 * 1024) {
      throw const FormatException('GM 存储键/值超过限制');
    }
    await customStatement(
      'INSERT INTO script_values VALUES(?,?,?) ON CONFLICT(script_id,key) DO UPDATE SET value=excluded.value',
      [id, key, encoded],
    );
  }

  Future<void> deleteValue(String id, String key) => customStatement(
    'DELETE FROM script_values WHERE script_id=? AND key=?',
    [id, key],
  );
  Future<String?> setting(String key) async => (await customSelect(
    'SELECT value FROM settings WHERE key=?',
    variables: [Variable(key)],
  ).getSingleOrNull())?.read<String>('value');
  Future<void> setSetting(String key, String value) => customStatement(
    'INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  Future<void> logScriptError(String id, String message) async {
    await customStatement(
      'INSERT INTO script_errors(script_id,happened_at,message) VALUES(?,?,?)',
      [
        id,
        DateTime.now().toIso8601String(),
        message.substring(0, message.length.clamp(0, 2000)),
      ],
    );
    await customStatement(
      'DELETE FROM script_errors WHERE id NOT IN (SELECT id FROM script_errors ORDER BY id DESC LIMIT 100)',
    );
  }

  Future<List<String>> scriptErrors(String id) async =>
      (await customSelect(
            'SELECT happened_at,message FROM script_errors WHERE script_id=? ORDER BY id DESC LIMIT 20',
            variables: [Variable(id)],
          ).get())
          .map(
            (r) =>
                '${r.read<String>('happened_at')}\n${r.read<String>('message')}',
          )
          .toList();

  Future<FilterPolicy> filterPolicy({int? profileId}) async {
    final row = await customSelect(
      'SELECT * FROM filter_policies WHERE profile_id=? LIMIT 1',
      variables: [Variable(profileId ?? 0)],
    ).getSingleOrNull();
    if (row == null) return const FilterPolicy();
    return FilterPolicy(
      enabled: row.read<int>('enabled') == 1,
      pageFiltering: row.read<int>('page_filtering') == 1,
      domainExceptions: (jsonDecode(
        row.read<String>('domain_exceptions'),
      ) as List).whereType<String>().toSet(),
      blockedDomains: (jsonDecode(row.read<String>('blocked_domains')) as List)
          .whereType<String>()
          .toSet(),
    );
  }

  Future<void> saveFilterPolicy(FilterPolicy policy, {int? profileId}) =>
      customStatement(
        'INSERT INTO filter_policies(profile_id,enabled,page_filtering,domain_exceptions,blocked_domains,updated_at) VALUES(?,?,?,?,?,?) '
        'ON CONFLICT(profile_id) DO UPDATE SET enabled=excluded.enabled,page_filtering=excluded.page_filtering,domain_exceptions=excluded.domain_exceptions,blocked_domains=excluded.blocked_domains,updated_at=excluded.updated_at',
        [
          profileId ?? 0,
          policy.enabled ? 1 : 0,
          policy.pageFiltering ? 1 : 0,
          jsonEncode(policy.domainExceptions.toList()..sort()),
          jsonEncode(policy.blockedDomains.toList()..sort()),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );

  Future<void> deleteFilterPolicy({int? profileId}) => customStatement(
    'DELETE FROM filter_policies WHERE profile_id=?',
    [profileId ?? 0],
  );

  Future<int> saveFilterSource(FilterSource source) async {
    await customStatement(
      'INSERT INTO filter_sources(id,profile_id,label,url,kind,version,license,sha256,status,file_ref,refreshed_at,error) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET profile_id=excluded.profile_id,label=excluded.label,url=excluded.url,kind=excluded.kind,version=excluded.version,license=excluded.license,sha256=excluded.sha256,status=excluded.status,file_ref=excluded.file_ref,refreshed_at=excluded.refreshed_at,error=excluded.error',
      [
        source.id,
        source.profileId,
        source.label,
        source.url.toString(),
        source.kind,
        source.version,
        source.license,
        source.sha256,
        source.status.name,
        source.fileRef,
        source.refreshedAt?.toUtc().toIso8601String(),
        source.error,
      ],
    );
    return source.id;
  }

  Future<List<FilterSource>> filterSources({int? profileId}) async =>
      (await customSelect(
            profileId == null
                ? 'SELECT * FROM filter_sources WHERE profile_id IS NULL ORDER BY id'
                : 'SELECT * FROM filter_sources WHERE profile_id=? ORDER BY id',
            variables: profileId == null ? const [] : [Variable(profileId)],
          ).get())
          .map(
            (row) => FilterSource(
              id: row.read<int>('id'),
              profileId: row.readNullable<int>('profile_id'),
              label: row.read<String>('label'),
              url: webUri(row.read<String>('url')),
              kind: row.read<String>('kind'),
              version: row.read<String>('version'),
              license: row.read<String>('license'),
              sha256: row.read<String>('sha256'),
              status: FilterSourceStatus.values.byName(
                row.read<String>('status'),
              ),
              fileRef: row.readNullable<String>('file_ref'),
              refreshedAt: row.readNullable<String>('refreshed_at') == null
                  ? null
                  : DateTime.parse(row.read<String>('refreshed_at')),
              error: row.readNullable<String>('error'),
            ),
          )
          .toList();

  Future<void> deleteFilterSource(int id) =>
      customStatement('DELETE FROM filter_sources WHERE id=?', [id]);

  Future<void> saveFilterSnapshot(FilterSnapshot snapshot) => customStatement(
    'INSERT INTO filter_snapshots(id,source_id,version,source_url,sha256,state,created_at,file_ref,unsupported_rule_count,error) VALUES(?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT(id) DO UPDATE SET state=excluded.state,sha256=excluded.sha256,created_at=excluded.created_at,file_ref=excluded.file_ref,unsupported_rule_count=excluded.unsupported_rule_count,error=excluded.error',
    [
      snapshot.id,
      snapshot.sourceId,
      snapshot.version,
      snapshot.sourceUrl.toString(),
      snapshot.sha256,
      snapshot.state.name,
      snapshot.createdAt.toIso8601String(),
      snapshot.fileRef,
      snapshot.unsupportedRuleCount,
      snapshot.error,
    ],
  );

  Future<FilterSnapshot?> filterSnapshot(String id) async {
    final row = await customSelect(
      'SELECT * FROM filter_snapshots WHERE id=?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (row == null) return null;
    return FilterSnapshot(
      id: row.read<String>('id'),
      sourceId: row.readNullable<int>('source_id'),
      version: row.read<String>('version'),
      sourceUrl: webUri(row.read<String>('source_url')),
      sha256: row.read<String>('sha256'),
      state: FilterSnapshotState.values.byName(row.read<String>('state')),
      createdAt: DateTime.parse(row.read<String>('created_at')),
      fileRef: row.read<String>('file_ref'),
      unsupportedRuleCount: row.read<int>('unsupported_rule_count'),
      error: row.readNullable<String>('error'),
    );
  }

  Future<FilterSnapshot?> latestFilterSnapshot() async {
    final row = await customSelect(
      'SELECT * FROM filter_snapshots WHERE state IN (?,?) ORDER BY created_at DESC LIMIT 1',
      variables: [
        Variable.withString('valid'),
        Variable.withString('degraded'),
      ],
    ).getSingleOrNull();
    if (row == null) return null;
    return filterSnapshot(row.read<String>('id'));
  }

  Future<void> saveMediaCandidate(MediaCandidate candidate) => customStatement(
    'INSERT INTO media_candidates(id,host_id,generation,source_url,media_url,title,mime,source,duration_ms,created_at) VALUES(?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT(id) DO UPDATE SET title=excluded.title,mime=excluded.mime,duration_ms=excluded.duration_ms',
    [
      candidate.id,
      candidate.hostId,
      candidate.generation,
      candidate.sourceUrl.toString(),
      candidate.mediaUrl.toString(),
      candidate.title,
      candidate.mime,
      candidate.source.name,
      candidate.durationMs,
      (candidate.createdAt ?? DateTime.now()).toUtc().toIso8601String(),
    ],
  );

  Future<MediaCandidate?> mediaCandidate(String id) async {
    final row = await customSelect(
      'SELECT * FROM media_candidates WHERE id=?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    if (row == null) return null;
    return MediaCandidate(
      id: row.read<String>('id'),
      hostId: row.read<int>('host_id'),
      generation: row.read<int>('generation'),
      sourceUrl: webUri(row.read<String>('source_url')),
      mediaUrl: webUri(row.read<String>('media_url')),
      title: row.read<String>('title'),
      mime: row.read<String>('mime'),
      source: MediaCandidateSource.values.byName(row.read<String>('source')),
      durationMs: row.readNullable<int>('duration_ms'),
      createdAt: DateTime.parse(row.read<String>('created_at')),
    );
  }

  Future<void> saveMediaTask(MediaTask task) => customStatement(
    'INSERT INTO media_tasks(id,candidate_id,host_id,generation,source_url,cache_key,state,updated_at,bytes_downloaded,total_bytes,error_code,local_ref) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT(id) DO UPDATE SET state=excluded.state,updated_at=excluded.updated_at,bytes_downloaded=excluded.bytes_downloaded,total_bytes=excluded.total_bytes,error_code=excluded.error_code,local_ref=excluded.local_ref',
    [
      task.id,
      task.candidateId,
      task.hostId,
      task.generation,
      task.sourceUrl.toString(),
      task.cacheKey,
      task.state.name,
      task.updatedAt.toUtc().toIso8601String(),
      task.bytesDownloaded,
      task.totalBytes,
      task.errorCode,
      task.localRef,
    ],
  );

  Future<List<MediaTask>> mediaTasks() async =>
      (await customSelect('SELECT * FROM media_tasks ORDER BY updated_at DESC')
              .get())
          .map(
            (row) => MediaTask(
              id: row.read<String>('id'),
              candidateId: row.read<String>('candidate_id'),
              hostId: row.read<int>('host_id'),
              generation: row.read<int>('generation'),
              sourceUrl: webUri(row.read<String>('source_url')),
              cacheKey: row.read<String>('cache_key'),
              state: MediaTaskState.values.byName(row.read<String>('state')),
              updatedAt: DateTime.parse(row.read<String>('updated_at')),
              bytesDownloaded: row.read<int>('bytes_downloaded'),
              totalBytes: row.readNullable<int>('total_bytes'),
              errorCode: row.readNullable<String>('error_code'),
              localRef: row.readNullable<String>('local_ref'),
            ),
          )
          .toList();

  Future<void> deleteMediaTask(String id) =>
      customStatement('DELETE FROM media_tasks WHERE id=?', [id]);
}
