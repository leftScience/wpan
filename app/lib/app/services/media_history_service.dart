import 'dart:async';

import 'package:get/get.dart';

import '../data/api/media_history.dart';
import '../data/models/media_history_entry.dart';
import '../data/models/media_history_list.dart';
import '../utils/media_path.dart';
import 'auth_service.dart';

class MediaHistoryService extends GetxService {
  MediaHistoryService({
    MediaHistoryRepository? repository,
    AuthService? authService,
  }) : _repository = repository ?? Get.find<MediaHistoryRepository>(),
       _authService = authService ?? Get.find<AuthService>();

  final MediaHistoryRepository _repository;
  final AuthService _authService;

  final Map<String, Future<MediaHistoryEntry?>> _pendingReads = {};
  final Map<String, Future<void>> _pendingWrites = {};
  final Map<String, MediaHistoryEntry> _cache = {};
  final Set<String> _emptyCache = <String>{};

  int? get _userId => _authService.user.value?.id;

  Future<MediaHistoryEntry?> fetchByFolder({
    required String applicationType,
    required String folderPath,
    bool preferFresh = false,
  }) {
    final userId = _userId;
    final folder = folderPath.trim();
    if (userId == null || folder.isEmpty) return Future.value(null);

    final type = _normalizeType(applicationType);
    final cacheKey = _cacheKey(userId, type, folder);
    if (!preferFresh) {
      final cached = _cache[cacheKey];
      if (cached != null) {
        return Future.value(cached);
      }
      if (_emptyCache.contains(cacheKey)) {
        return Future.value(null);
      }
    }
    final inFlight = _pendingReads[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _repository
        .fetchByFolder(
          userId: userId,
          applicationType: type,
          folderPath: folder,
          suppressErrorToast: true,
        )
        .then((value) {
          if (value != null) {
            _cache[cacheKey] = value;
            _emptyCache.remove(cacheKey);
          } else {
            _cache.remove(cacheKey);
            _emptyCache.add(cacheKey);
          }
          return value;
        })
        .catchError((error) {
          throw error;
        });

    _pendingReads[cacheKey] = future;
    return future.whenComplete(() {
      _pendingReads.remove(cacheKey);
    });
  }

  Future<void> saveProgress({
    required String applicationType,
    required String folderPath,
    required String itemTitle,
    required Duration position,
    String? itemPath,
    Duration? duration,
    String? coverUrl,
    Map<String, dynamic>? extra,
  }) async {
    final userId = _userId;
    final folder = folderPath.trim();
    final normalizedPath = MediaPath.normalize(itemPath);
    var title = itemTitle.trim();
    if (title.isEmpty && normalizedPath.isNotEmpty) {
      title = MediaPath.title(normalizedPath);
    }
    if (userId == null || folder.isEmpty || title.isEmpty) {
      return;
    }

    final type = _normalizeType(applicationType);
    final payload = MediaHistoryRecordPayload(
      applicationType: type,
      folderPath: folder,
      itemTitle: title,
      itemPath: normalizedPath,
      positionMs: position.inMilliseconds,
      durationMs: duration?.inMilliseconds,
      coverUrl: coverUrl,
      extra: extra,
      lastPlayedAt: DateTime.now().toLocal(),
    );

    final cacheKey = _cacheKey(userId, type, folder);
    await _enqueueWrite(cacheKey, () async {
      MediaHistoryEntry? current = _cache[cacheKey];
      current ??= await _ensureEntryLoaded(cacheKey, userId, type, folder);
      MediaHistoryEntry updated;
      if (current == null || current.id == null) {
        updated = await _repository.create(
          payload: payload,
          userId: userId,
          suppressErrorToast: true,
        );
      } else {
        updated = await _repository.update(
          id: current.id!,
          payload: payload,
          userId: userId,
          suppressErrorToast: true,
        );
      }
      var resolved = _withFallbackId(updated, current?.id);
      if (resolved.id == null) {
        final refreshed = await _repository.fetchByFolder(
          userId: userId,
          applicationType: type,
          folderPath: folder,
          suppressErrorToast: true,
        );
        if (refreshed != null) {
          resolved = _withFallbackId(refreshed, current?.id);
        }
      }
      _cache[cacheKey] = resolved;
      _emptyCache.remove(cacheKey);
    });
  }

  Future<void> deleteByFolder({
    required String applicationType,
    required String folderPath,
  }) async {
    final userId = _userId;
    final folder = folderPath.trim();
    if (userId == null || folder.isEmpty) {
      return;
    }

    final type = _normalizeType(applicationType);
    final cacheKey = _cacheKey(userId, type, folder);
    final existing = await fetchByFolder(
      applicationType: type,
      folderPath: folder,
      preferFresh: true,
    );
    final id = existing?.id;
    if (id == null) return;

    await deleteById(id);
    _cache.remove(cacheKey);
    _emptyCache.remove(cacheKey);
  }

  Future<MediaHistoryListResult> fetchUserHistory({
    int page = 1,
    int limit = 20,
    String? applicationType,
  }) async {
    final userId = _userId;
    if (userId == null) {
      return const MediaHistoryListResult(records: [], total: 0);
    }

    final type = applicationType == null
        ? null
        : _normalizeType(applicationType);
    try {
      return await _repository.fetchList(
        userId: userId,
        page: page,
        limit: limit,
        applicationType: type,
        suppressErrorToast: true,
      );
    } catch (_) {
      return const MediaHistoryListResult(records: [], total: 0);
    }
  }

  Future<MediaHistoryEntry?> fetchMostRecent({String? applicationType}) async {
    final userId = _userId;
    if (userId == null) return Future.value(null);

    final type = applicationType == null
        ? null
        : _normalizeType(applicationType);
    try {
      return await _repository.fetchRecent(
        userId: userId,
        applicationType: type,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteById(int id) async {
    if (id <= 0) return;
    await _repository.delete(id: id);
    _cache.removeWhere((key, value) => value.id == id);
    _emptyCache.clear();
  }

  Future<MediaHistoryEntry?> _ensureEntryLoaded(
    String cacheKey,
    int userId,
    String applicationType,
    String folderPath,
  ) async {
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final pending = _pendingReads[cacheKey];
    if (pending != null) return pending;

    return fetchByFolder(
      applicationType: applicationType,
      folderPath: folderPath,
    );
  }

  Future<void> _enqueueWrite(String key, Future<void> Function() run) {
    final previous = _pendingWrites[key];
    final future = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      await run();
    }();

    _pendingWrites[key] = future.whenComplete(() {
      if (identical(_pendingWrites[key], future)) {
        _pendingWrites.remove(key);
      }
    });
    return future;
  }

  String _cacheKey(int userId, String applicationType, String folderPath) {
    return '$userId|$applicationType|$folderPath';
  }

  String _normalizeType(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isEmpty ? 'tv' : normalized;
  }

  MediaHistoryEntry _withFallbackId(MediaHistoryEntry entry, int? fallbackId) {
    if (entry.id != null || fallbackId == null) return entry;
    final next = Map<String, dynamic>.from(entry.toJson());
    next['id'] = fallbackId;
    return MediaHistoryEntry.fromJson(next);
  }
}
