import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/message.dart';
import 'storage_service.dart';

class HistoryPage {
  final List<Message> messages;
  final bool hasMore;
  const HistoryPage(this.messages, this.hasMore);
}

/// Indexed durable history. UI pages and model context are separate reads.
class HistoryRepository {
  final Database db;
  HistoryRepository(this.db);
  static HistoryRepository? instance;

  static Future<HistoryRepository> open({String? path, String? scope}) async {
    if (path == null) {
      final root = await getApplicationDocumentsDirectory();
      final folder = scope == null || scope == StorageService.legacyScope
          ? 'history'
          : 'history_$scope';
      await Directory('${root.path}/$folder').create(recursive: true);
      path = '${root.path}/$folder/messages.sqlite3';
    }
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE messages (chat TEXT NOT NULL, id TEXT NOT NULL, '
          'time INTEGER NOT NULL, body TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 0, '
          'PRIMARY KEY(chat,id))',
        );
        await db.execute(
          'CREATE INDEX history_order ON messages(chat,time,id)',
        );
        await db.execute(
          'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
    );
    return HistoryRepository(db);
  }

  Future<void> migrateLegacy(Directory documents) async {
    if (await meta('legacy_imported') == '1') return;
    final ids = StorageService.getStringList('message_store_chat_ids') ?? [];
    for (final chat in ids) {
      final raw = StorageService.getStringList('messages_v2_$chat');
      final legacy = StorageService.getStringList('messages_$chat');
      if ((raw == null || raw.isEmpty) && (legacy == null || legacy.isEmpty)) {
        continue;
      }
      final folder = await Directory(
        '${documents.path}/${StorageService.scopedDirectory('history_backups')}',
      ).create(recursive: true);
      final backup = File(
        '${folder.path}/${DateTime.now().microsecondsSinceEpoch}.json',
      );
      final encoded = jsonEncode({
        'chat_id': chat,
        'v2': raw,
        'legacy': legacy,
      });
      await backup.writeAsString(encoded, flush: true);
      if (await backup.readAsString() != encoded) throw StateError('聊天备份校验失败');
      final strings = (raw != null && raw.isNotEmpty) ? raw : legacy!;
      final identities = <String, String>{};
      // All conversion must succeed before committing or retiring old keys.
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final text in strings) {
          Message message;
          if (identical(strings, raw)) {
            message = Message.fromStorageString(text);
          } else {
            final parts = text.split('|||');
            if (parts.length != 5 || DateTime.tryParse(parts[4]) == null) {
              throw StateError('旧聊天无法可靠转换，原始记录和备份已保留');
            }
            message = Message(
              id: parts[0],
              senderId: parts[1],
              receiverId: parts[2],
              content: parts[3],
              timestamp: DateTime.parse(parts[4]),
            );
          }
          final canonical = message.toStorageString();
          if (identities.containsKey(message.id) &&
              identities[message.id] != canonical) {
            throw StateError('旧聊天包含冲突消息编号，原始记录和备份已保留');
          }
          identities[message.id] = canonical;
          batch.rawInsert(
            'INSERT OR IGNORE INTO messages(chat,id,time,body,pending) VALUES (?,?,?,?,1)',
            [
              chat,
              message.id,
              message.timestamp.microsecondsSinceEpoch,
              message.toStorageString(),
            ],
          );
        }
        await batch.commit(noResult: true);
      });
      final stored = await db.query(
        'messages',
        columns: ['id', 'body'],
        where: 'chat=?',
        whereArgs: [chat],
      );
      final restored = {
        for (final row in stored) row['id'] as String: row['body'] as String,
      };
      if (identities.entries.any(
        (entry) => restored[entry.key] != entry.value,
      )) {
        throw StateError('聊天迁移校验失败，原始记录和备份已保留');
      }
      await File(
        '${folder.path}/${DateTime.now().microsecondsSinceEpoch}-report.json',
      ).writeAsString(
        jsonEncode({
          'chat_id': chat,
          'imported': identities.length,
          'backup': backup.path,
          'verified': true,
          'original_retained_in_backup': true,
        }),
        flush: true,
      );
      // Backup is retained and included in data export; SharedPreferences no
      // longer needs to deserialize the entire legacy history at every launch.
      await StorageService.remove('messages_v2_$chat');
      await StorageService.remove('messages_$chat');
    }
    await setMeta('legacy_imported', '1');
  }

  Future<int> recoverLegacyBackup(File backup) async {
    final data =
        jsonDecode(await backup.readAsString()) as Map<String, dynamic>;
    final chat = data['chat_id'] as String;
    if (await count(chat) != 0) throw StateError('恢复仅允许写入空的聊天副本');
    final v2 = data['v2'] as List?;
    final strings = v2 != null && v2.isNotEmpty ? v2 : data['legacy'] as List;
    final messages = strings.map((value) {
      final text = value as String;
      if (identical(strings, v2)) return Message.fromStorageString(text);
      final parts = text.split('|||');
      if (parts.length != 5) throw StateError('旧聊天格式无法可靠恢复');
      return Message(
        id: parts[0],
        senderId: parts[1],
        receiverId: parts[2],
        content: parts[3],
        timestamp: DateTime.parse(parts[4]),
      );
    }).toList();
    await put(chat, messages, pending: true);
    return count(chat);
  }

  Future<void> put(
    String chat,
    List<Message> messages, {
    bool pending = false,
  }) => db.transaction((txn) async {
    final batch = txn.batch();
    for (final message in messages) {
      batch.rawInsert(
        'INSERT OR IGNORE INTO messages(chat,id,time,body,pending) VALUES (?,?,?,?,?)',
        [
          chat,
          message.id,
          message.timestamp.microsecondsSinceEpoch,
          message.toStorageString(),
          pending ? 1 : 0,
        ],
      );
      if (!pending && message.type == MessageType.voice) {
        batch.rawUpdate(
          'UPDATE messages SET body=?,time=?,pending=0 WHERE chat=? AND id=?',
          [
            message.toStorageString(),
            message.timestamp.microsecondsSinceEpoch,
            chat,
            message.id,
          ],
        );
      }
    }
    await batch.commit(noResult: true);
  });

  Future<HistoryPage> page(
    String chat, {
    Message? before,
    int limit = 50,
  }) async {
    // Scalar predicates also work with Android 7's older system SQLite.
    final where = before == null ? '' : ' AND time<=? AND (time<? OR id<?)';
    final rows = await db.rawQuery(
      'SELECT body FROM messages WHERE chat=?$where '
      'ORDER BY time DESC,id DESC LIMIT ?',
      [
        chat,
        if (before != null) ...[
          before.timestamp.microsecondsSinceEpoch,
          before.timestamp.microsecondsSinceEpoch,
          before.id,
        ],
        limit + 1,
      ],
    );
    return HistoryPage(
      rows
          .take(limit)
          .map((r) => Message.fromStorageString(r['body'] as String))
          .toList()
          .reversed
          .toList(),
      rows.length > limit,
    );
  }

  Future<List<Message>> since(String chat, Message oldest) async {
    final rows = await db.rawQuery(
      'SELECT body FROM messages WHERE chat=? AND time>=? '
      'AND (time>? OR id>=?) ORDER BY time,id',
      [
        chat,
        oldest.timestamp.microsecondsSinceEpoch,
        oldest.timestamp.microsecondsSinceEpoch,
        oldest.id,
      ],
    );
    return rows
        .map((row) => Message.fromStorageString(row['body'] as String))
        .toList();
  }

  Future<int> count(String chat) async => Sqflite.firstIntValue(
    await db.rawQuery('SELECT COUNT(*) FROM messages WHERE chat=?', [chat]),
  )!;

  Future<List<Message>> claimIncoming(
    String chat,
    List<Message> messages,
  ) => db.transaction((txn) async {
    await txn.execute(
      'CREATE TABLE IF NOT EXISTS notification_receipts(chat TEXT,id TEXT,PRIMARY KEY(chat,id))',
    );
    final incoming = <Message>[];
    for (final message in messages) {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO notification_receipts VALUES (?,?)',
        [chat, message.id],
      );
      // SQLite changes(), unlike last_insert_rowid(), is zero on ignored inserts.
      final changes =
          Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()')) ?? 0;
      if (changes > 0 && message.senderId != 'me') incoming.add(message);
    }
    return incoming;
  });
  Future<List<String>> chats() async => (await db.rawQuery(
    'SELECT DISTINCT chat FROM messages',
  )).map((row) => row['chat'] as String).toList();
  Future<void> remove(String chat, [String? id]) async {
    await db.delete(
      'messages',
      where: id == null ? 'chat=?' : 'chat=? AND id=?',
      whereArgs: [chat, ?id],
    );
  }

  Future<List<Message>> pending(String chat) async => (await db.query(
    'messages',
    columns: ['body'],
    where: 'chat=? AND pending=1',
    whereArgs: [chat],
    orderBy: 'time,id',
    limit: 100,
  )).map((row) => Message.fromStorageString(row['body'] as String)).toList();
  Future<void> acknowledge(String chat, List<Message> messages) =>
      db.transaction((txn) async {
        for (final message in messages) {
          await txn.update(
            'messages',
            {'pending': 0},
            where: 'chat=? AND id=?',
            whereArgs: [chat, message.id],
          );
        }
      });
  Future<String?> meta(String key) async {
    final rows = await db.query('metadata', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) async {
    await db.insert('metadata', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> exportSnapshot(Directory documents) async {
    if (db.path == inMemoryDatabasePath) return;
    final folder = await Directory(
      '${documents.path}/${StorageService.scopedDirectory('history_exports')}',
    ).absolute.create(recursive: true);
    final target =
        '${folder.path}/messages-${DateTime.now().microsecondsSinceEpoch}.sqlite3';
    final snapshot = await HistoryRepository.open(path: target);
    var complete = false;
    try {
      // Copy under a source transaction, using bounded batches rather than
      // VACUUM INTO, which older Android system SQLite does not support.
      await db.transaction((source) async {
        await snapshot.db.transaction((destination) async {
          var afterRow = 0;
          while (true) {
            final rows = await source.rawQuery(
              'SELECT rowid AS source_row,chat,id,time,body,pending '
              'FROM messages WHERE rowid>? ORDER BY rowid LIMIT 200',
              [afterRow],
            );
            if (rows.isEmpty) break;
            final batch = destination.batch();
            for (final row in rows) {
              final values = Map<String, Object?>.of(row)..remove('source_row');
              batch.insert('messages', values);
            }
            await batch.commit(noResult: true);
            afterRow = rows.last['source_row'] as int;
          }
          final metadata = await source.query('metadata');
          final batch = destination.batch();
          for (final row in metadata) {
            batch.insert('metadata', row);
          }
          await batch.commit(noResult: true);
        });
      });
      complete = true;
    } finally {
      await snapshot.db.close();
      if (!complete) {
        // Retain failed copies outside exported snapshots for investigation.
        final failed = await Directory(
          '${documents.path}/${StorageService.scopedDirectory('history_failed_exports')}',
        ).create(recursive: true);
        await File(target).rename('${failed.path}/${target.split('/').last}');
      }
    }
  }
}
