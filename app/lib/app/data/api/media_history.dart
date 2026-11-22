import '../../utils/http_client.dart';
import '../models/media_history_entry.dart';
import '../models/media_history_list.dart';

class MediaHistoryRepository {
  MediaHistoryRepository({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient.instance;

  final HttpClient _httpClient;

  Future<MediaHistoryEntry?> fetchByFolder({
    required int userId,
    required String applicationType,
    required String folderPath,
    bool suppressErrorToast = false,
  }) async {
    return _httpClient.post<MediaHistoryEntry?>(
      'userMediaHistory/byFolder',
      data: <String, dynamic>{
        'userId': userId,
        'applicationType': applicationType.trim(),
        'folderPath': folderPath.trim(),
      },
      showErrorToast: !suppressErrorToast,
      decoder: _decodeEntry,
    );
  }

  Future<MediaHistoryListResult> fetchList({
    required int userId,
    int page = 1,
    int limit = 20,
    String? applicationType,
    String? folderPath,
    bool suppressErrorToast = false,
  }) async {
    final payload = <String, dynamic>{
      'page': page,
      'limit': limit,
      'userId': userId,
    };
    if (applicationType != null && applicationType.trim().isNotEmpty) {
      payload['applicationType'] = applicationType.trim();
    }
    if (folderPath != null && folderPath.trim().isNotEmpty) {
      payload['folderPath'] = folderPath.trim();
    }

    final Map<String, dynamic>? data = await _httpClient.post(
      'userMediaHistory/list',
      data: payload,
      showErrorToast: !suppressErrorToast,
      decoder: _ensureMap,
    );
    if (data == null) {
      return const MediaHistoryListResult(records: [], total: 0);
    }

    final records = <MediaHistoryEntry>[];
    final rawRecords = data['records'];
    if (rawRecords is List) {
      for (final item in rawRecords) {
        final entry = _decodeEntry(item);
        if (entry != null) {
          records.add(entry);
        }
      }
    }

    final total = _toInt(data['total']) ?? records.length;

    return MediaHistoryListResult(records: records, total: total);
  }

  Future<MediaHistoryEntry> create({
    required MediaHistoryRecordPayload payload,
    required int userId,
    bool suppressErrorToast = false,
  }) {
    return _httpClient.post<MediaHistoryEntry>(
      'userMediaHistory',
      data: payload.toJson(userId: userId),
      showErrorToast: !suppressErrorToast,
      decoder: _decodeEntryOrThrow,
    );
  }

  Future<MediaHistoryEntry> update({
    required int id,
    required MediaHistoryRecordPayload payload,
    required int userId,
    bool suppressErrorToast = false,
  }) {
    return _httpClient.put<MediaHistoryEntry>(
      'userMediaHistory/$id',
      data: payload.toJson(userId: userId),
      showErrorToast: !suppressErrorToast,
      decoder: _decodeEntryOrThrow,
    );
  }

  Future<void> delete({required int id}) {
    return _httpClient.delete<void>('userMediaHistory/$id', decoder: (_) {});
  }

  Future<MediaHistoryEntry?> fetchRecent({
    required int userId,
    String? applicationType,
  }) {
    final payload = <String, dynamic>{'userId': userId};
    if (applicationType != null && applicationType.trim().isNotEmpty) {
      payload['applicationType'] = applicationType.trim();
    }
    return _httpClient.post<MediaHistoryEntry?>(
      'userMediaHistory/recent',
      data: payload,
      showErrorToast: false,
      decoder: _decodeEntry,
    );
  }

  static Map<String, dynamic>? _ensureMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return null;
  }

  static MediaHistoryEntry? _decodeEntry(dynamic data) {
    if (data is Map<String, dynamic>) {
      return MediaHistoryEntry.fromJson(data);
    }
    if (data is Map) {
      return MediaHistoryEntry.fromJson(data.cast<String, dynamic>());
    }
    return null;
  }

  static MediaHistoryEntry _decodeEntryOrThrow(dynamic data) {
    final entry = _decodeEntry(data);
    if (entry == null) {
      throw ApiException('Invalid media history response');
    }
    return entry;
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class MediaHistoryRecordPayload {
  MediaHistoryRecordPayload({
    required this.applicationType,
    required this.folderPath,
    required this.itemTitle,
    this.itemPath,
    required this.positionMs,
    this.durationMs,
    this.coverUrl,
    this.extra,
    DateTime? lastPlayedAt,
  }) : lastPlayedAt = (lastPlayedAt ?? DateTime.now()).toLocal();

  final String applicationType;
  final String folderPath;
  final String itemTitle;
  final String? itemPath;
  final int positionMs;
  final int? durationMs;
  final String? coverUrl;
  final Map<String, dynamic>? extra;
  final DateTime lastPlayedAt;

  Map<String, dynamic> toJson({required int userId}) {
    final map = <String, dynamic>{
      'userId': userId,
      'applicationType': applicationType,
      'folderPath': folderPath,
      'itemTitle': itemTitle,
      'positionMs': positionMs,
      'lastPlayedAt': lastPlayedAt.toIso8601String(),
    };
    if (itemPath != null && itemPath!.trim().isNotEmpty) {
      map['itemPath'] = itemPath;
    }
    if (durationMs != null) {
      map['durationMs'] = durationMs;
    }
    if (coverUrl != null && coverUrl!.trim().isNotEmpty) {
      map['coverUrl'] = coverUrl;
    }
    if (extra != null && extra!.isNotEmpty) {
      map['extra'] = extra;
    }
    return map;
  }
}
