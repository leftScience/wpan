import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../data/api/config.dart';
import '../../../data/api/quark.dart';
import '../../../data/models/quark_file_entry.dart';
import '../../../services/auth_service.dart';
import '../../../services/playback_audio_session.dart';
import '../../../services/playback_entry_service.dart';
import '../../../services/video_cast_service.dart';
import '../../../utils/app_env.dart';
import '../../../utils/media_path.dart';
import '../../../utils/quark_error_helper.dart';
import '../../../data/storage/playback_progress_storage.dart';
import '../../../data/storage/player_preferences_storage.dart';
import '../../../data/storage/skip_settings_storage.dart';
import '../../video_cast/views/video_cast_view.dart';
import '../../music_player/controllers/music_player_controller.dart';

enum _InitialEpisodeSource { none, preferred, explicitResume, storedResume }

enum FullscreenFitMode { contain, cover }

class PlayerController extends GetxController {
  PlayerController({
    ConfigApi? configApi,
    PlaybackProgressStorage? progressStorage,
    SkipSettingsStorage? skipSettingsStorage,
    String applicationType = 'tv',
  }) : _configApi = configApi ?? Get.find<ConfigApi>(),
       _providedProgressStorage = progressStorage,
       _defaultApplicationType = applicationType,
       _applicationType = applicationType,
       _skipStorage =
           skipSettingsStorage ??
           SkipSettingsStorage(keyPrefix: 'video_skip_settings_');

  final player = Player();
  late final VideoController videoController = VideoController(
    player,
    configuration: _videoControllerConfiguration,
  );

  /// 视频播放器需要自己持有音频会话：音乐播放器暂停时会 setActive(false)，
  /// 之后 mpv 再打开音频单元就会失败（Could not open/initialize audio device）。
  late final PlaybackAudioSession _audioSession = PlaybackAudioSession(
    onPauseRequested: () async {
      try {
        await player.pause();
      } catch (_) {}
    },
    isPlaying: () => player.state.playing,
  );

  static VideoControllerConfiguration get _videoControllerConfiguration {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const VideoControllerConfiguration();
    }
    return const VideoControllerConfiguration(vo: 'gpu');
  }

  final currentIndex = 0.obs;
  final episodesAscending = true.obs;

  final resourceTitle = '影视'.obs;
  final resourceIntro = ''.obs;

  final episodes = <Episode>[].obs;
  int _initialIndex = 0;

  final PlaybackProgressStorage? _providedProgressStorage;
  late PlaybackProgressStorage _progressStorage;
  final String _defaultApplicationType;
  final ConfigApi _configApi;
  final SkipSettingsStorage _skipStorage;
  final WebdavApi _webdavApi = Get.find<WebdavApi>();
  final AuthService _authService = Get.find<AuthService>();
  final VideoCastService _castService = Get.find<VideoCastService>();
  final RxDouble videoAspectRatio = (16 / 9).obs;
  final RxBool isPortraitVideo = false.obs;
  final Rxn<Duration> scrubPreview = Rxn<Duration>();
  final RxBool isScrubbing = false.obs;
  final RxDouble playbackRate = 1.0.obs;
  final RxBool isFullscreen = false.obs;
  final RxBool isSpeedBoosting = false.obs;
  final RxDouble speedBoostRate = 3.0.obs;
  final RxBool isControlsLocked = false.obs;
  final Rx<Duration> skipIntro = Duration.zero.obs;
  final Rx<Duration> skipOutro = Duration.zero.obs;
  final Rx<FullscreenFitMode> fullscreenFitMode = FullscreenFitMode.contain.obs;
  final RxBool isLoadingPlaylist = false.obs;
  final availableAudioTracks = <AudioTrack>[].obs;
  final Rxn<AudioTrack> currentAudioTrack = Rxn<AudioTrack>();
  final availableSubtitleTracks = <SubtitleTrack>[].obs;
  final externalSubtitleTracks = <SubtitleTrack>[].obs;
  final Rxn<SubtitleTrack> currentSubtitleTrack = Rxn<SubtitleTrack>();
  final RxString globalPlaybackProxyMode = _defaultPlaybackProxyMode.obs;
  final RxnString currentPlaybackProxyModeOverride = RxnString();

  final PlayerPreferencesStorage _playerPreferencesStorage =
      PlayerPreferencesStorage();
  String? _preferredPlaybackProxyMode;

  /// 解码模式：auto / hw / sw。必须是 Rx，设置面板的 Obx 依赖它。
  final RxString decodeMode = 'auto'.obs;
  double? _preferredPlaybackRate;
  Future<void>? _playerPreferencesFuture;
  Future<void>? _decodeModeAppliedFuture;

  bool _autoNextRunning = false;
  Duration? _pendingSeek;
  Duration? _lastPersistedPosition;
  String? _currentEpisodePath;
  String? _currentEpisodeUrl;
  String? _openingEpisodePath;
  String? _openingEpisodeUrl;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorSubscription;
  bool _proxyModeFallbackApplied = false;
  bool _decodeFallbackApplied = false;
  String? _appliedHwdec;

  bool _voConfigured = false;
  bool _voConfiguredKnown = false;
  bool _voFallbackApplied = false;
  bool _voFallbackHealthy = false;
  bool _voFallbackApplying = false;
  Timer? _voFallbackTimer;

  /// 当前片源是 Dolby Vision Profile 5 或标准 HDR（PQ / HLG）时启用 GLSL 色彩校正着色器。
  static const int _hdrShaderModeOff = 0;
  static const int _hdrShaderModeDoviP5 = 1;
  static const int _hdrShaderModePq = 2;
  static const int _hdrShaderModeHlg = 3;

  int _activeHdrShaderMode = _hdrShaderModeOff;
  bool get _dolbyVisionModeActive => _activeHdrShaderMode != _hdrShaderModeOff;
  bool _dolbyVisionModeSwitching = false;
  bool _dolbyVisionProfile5Confirmed = false;
  final RxBool useFlutterDolbyVisionFilter = false.obs;
  final RxInt flutterHdrShaderMode = _hdrShaderModeOff.obs;
  ui.FragmentProgram? _doviFragmentProgram;
  String? _activeGlslShaderFilePath;
  String? _last302TargetUrl;
  String? _last302ErrorMessage;

  String _describe302Target() {
    final message = _last302ErrorMessage;
    if (message != null && message.isNotEmpty) return message;
    final target = _last302TargetUrl;
    if (target == null || target.isEmpty) return '未获取到直链';
    final short = target.length > 80 ? target.substring(0, 80) : target;
    return '直链：$short';
  }

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<double>? _rateSubscription;
  StreamSubscription<int?>? _widthSubscription;
  StreamSubscription<int?>? _heightSubscription;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  StreamSubscription<Track>? _trackSubscription;
  StreamSubscription<Tracks>? _tracksSubscription;
  List<WebdavFileEntry> _folderEntries = const <WebdavFileEntry>[];
  String? _folderPath;
  String? _resumeEpisodePath;
  Duration? _resumePosition;
  Timer? _scrubTimer;
  double _scrubViewWidth = 0;
  double _scrubDeltaDx = 0;
  Duration _scrubStartPos = Duration.zero;
  Duration _scrubDuration = Duration.zero;
  bool _ready = false;
  String? _lastArgsKey;
  String _applicationType;
  bool _playerConfigured = false;
  double? _rateBeforeBoost;
  bool _skipSettingsLoaded = false;
  String? _skipFolderKey;
  bool _outroSkipTriggered = false;
  int _routeArgsVersion = 0;
  bool _blockPlaybackOnOpen = false;
  Timer? _castProgressTimer;
  Duration? _lastCastPersistedPosition;
  Future<void>? _globalPlaybackProxyModeFuture;
  SubtitleTrack? _subtitleTrackBeforeCasting;

  bool get isPlayletMode => _applicationType.trim().toLowerCase() == 'playlet';
  bool get isCasting => _castService.isCasting.value;
  String get castingDeviceName => _castService.currentDeviceName.value.trim();
  String get effectivePlaybackProxyMode =>
      currentPlaybackProxyModeOverride.value ??
      _preferredPlaybackProxyMode ??
      globalPlaybackProxyMode.value;
  String get effectivePlaybackProxyModeLabel {
    switch (effectivePlaybackProxyMode) {
      case '302_redirect':
        return '302';
      default:
        return '本地代理';
    }
  }

  /// auto = mpv 自动（iOS 上优先 VideoToolbox）；hw = 强制硬解；sw = 软解。
  String get effectiveDecodeMode => decodeMode.value;

  String get decodeModeLabel {
    switch (effectiveDecodeMode) {
      case 'hw':
        return '硬解';
      case 'sw':
        return '软解';
      default:
        return '自动';
    }
  }

  bool get canSwitchCurrentPlaybackProxyMode {
    final current = _currentEpisode;
    return current != null && _supportsPlaybackProxyMode(current);
  }

  bool get canCastCurrentEpisode => currentCastUrl != null;
  List<AudioTrack> get audioTrackOptions {
    final visible = <AudioTrack>[];
    var hasAuto = false;
    var hasNo = false;
    final seen = <String>{};

    for (final track in availableAudioTracks) {
      final key = '${track.uri ? 'uri' : 'id'}:${track.id}';
      if (!seen.add(key)) continue;
      switch (track.id) {
        case 'auto':
          hasAuto = true;
          break;
        case 'no':
          hasNo = true;
          break;
        default:
          visible.add(track);
          break;
      }
    }

    final selected = currentAudioTrack.value;
    final includeAuto =
        hasAuto || visible.isNotEmpty || selected?.id == AudioTrack.auto().id;
    final includeNo =
        hasNo && (visible.isNotEmpty || selected?.id == AudioTrack.no().id);

    return <AudioTrack>[
      if (includeAuto) AudioTrack.auto(),
      ...visible,
      if (includeNo) AudioTrack.no(),
    ];
  }

  bool get canSwitchAudioTrack => !isCasting && audioTrackOptions.length > 1;
  String get currentAudioTrackDisplayLabel {
    final track = currentAudioTrack.value;
    if (track != null) {
      return audioTrackTitle(track);
    }
    final options = audioTrackOptions;
    if (options.isNotEmpty) {
      return audioTrackTitle(options.first);
    }
    return '默认';
  }

  String get currentAudioTrackDisplaySubtitle {
    final track = currentAudioTrack.value;
    if (track == null) return '';
    return audioTrackSubtitle(track);
  }

  List<SubtitleTrack> get subtitleTrackOptions {
    final visible = <SubtitleTrack>[];
    var hasAuto = false;
    var hasNo = false;
    final seen = <String>{};

    void addTrack(SubtitleTrack track) {
      final key =
          '${track.uri
              ? 'uri'
              : track.data
              ? 'data'
              : 'id'}:${track.id}';
      if (!seen.add(key)) return;
      switch (track.id) {
        case 'auto':
          hasAuto = true;
          break;
        case 'no':
          hasNo = true;
          break;
        default:
          visible.add(track);
          break;
      }
    }

    for (final track in availableSubtitleTracks) {
      addTrack(track);
    }
    for (final track in externalSubtitleTracks) {
      addTrack(track);
    }

    final selected = currentSubtitleTrack.value;
    final includeAuto =
        hasAuto ||
        visible.isNotEmpty ||
        selected?.id == SubtitleTrack.auto().id;
    final includeNo =
        hasNo || visible.isNotEmpty || selected?.id == SubtitleTrack.no().id;

    return <SubtitleTrack>[
      if (includeAuto) SubtitleTrack.auto(),
      ...visible,
      if (includeNo) SubtitleTrack.no(),
    ];
  }

  bool get canSwitchSubtitleTrack =>
      !isCasting && subtitleTrackOptions.length > 1;

  String get currentSubtitleTrackDisplayLabel {
    final track = currentSubtitleTrack.value;
    if (track != null) {
      return subtitleTrackTitle(track);
    }
    final options = subtitleTrackOptions;
    if (options.isNotEmpty) {
      return subtitleTrackTitle(options.first);
    }
    return '默认';
  }

  String get currentSubtitleTrackDisplaySubtitle {
    final track = currentSubtitleTrack.value;
    if (track == null) return '';
    return subtitleTrackSubtitle(track);
  }

  String? get currentCastUrl {
    final current = _currentEpisode;
    if (current == null) return null;
    return _castUrlForEpisode(current);
  }

  String get currentCastSourcePath => _currentEpisode?.path?.trim() ?? '';

  String get currentCastTitle {
    final current = _currentEpisode;
    final title = current?.title.trim() ?? '';
    if (title.isNotEmpty) return title;
    final subTitle = current?.subTitle.trim() ?? '';
    if (subTitle.isNotEmpty) return subTitle;
    final resource = resourceTitle.value.trim();
    if (resource.isNotEmpty) return resource;
    return '当前视频';
  }

  /// 302 直链需要夸克 TV 的 UA/Referer。
  Map<String, String> get playbackHttpHeaders => const <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1',
    'Referer': 'https://pan.quark.cn/',
  };

  Episode? get _currentEpisode {
    final index = currentIndex.value;
    if (index < 0 || index >= episodes.length) return null;
    return episodes[index];
  }

  @override
  void onInit() {
    super.onInit();
    _progressStorage =
        _providedProgressStorage ??
        PlaybackProgressStorage(applicationType: _applicationType);
    _globalPlaybackProxyModeFuture = _loadGlobalPlaybackProxyMode();
    _playerPreferencesFuture = _loadPlayerPreferences();
    handleRouteArguments(Get.arguments);
  }

  @override
  void onReady() {
    super.onReady();
    unawaited(_applyMpvColorPipeline());
    unawaited(_ensureDecodeModeApplied());
    unawaited(_observeVideoOutputState());
    unawaited(_observeDolbyVisionProfile());
    _playingSubscription = player.stream.playing.listen(_handlePlayingChanged);
    _completedSubscription = player.stream.completed.listen(
      _handleCompletedChanged,
    );
    _errorSubscription = player.stream.error.listen(_handlePlaybackStreamError);
    _rateSubscription = player.stream.rate.listen((rate) {
      playbackRate.value = rate;
    });
    _positionSubscription = player.stream.position.listen(
      _handlePositionUpdate,
    );
    _durationSubscription = player.stream.duration.listen((_) {
      _tryApplyPendingSeek();
    });
    _widthSubscription = player.stream.width.listen((_) {
      _updateAspectRatio();
    });
    _heightSubscription = player.stream.height.listen((_) {
      _updateAspectRatio();
    });
    _videoParamsSubscription = player.stream.videoParams.listen((params) {
      _updateAspectRatio();
      unawaited(_evaluateDolbyVisionShader(params));
    });
    _trackSubscription = player.stream.track.listen((track) {
      _syncSelectedAudioTrack(track.audio);
      _syncSelectedSubtitleTrack(track.subtitle);
    });
    _tracksSubscription = player.stream.tracks.listen((tracks) {
      _syncAvailableAudioTracks(tracks.audio);
      _syncAvailableSubtitleTracks(tracks.subtitle);
    });
    _ready = true;
    if (episodes.isNotEmpty) {
      unawaited(_startInitialPlayback());
    }
  }

  Future<void> _startInitialPlayback() async {
    await _ensureGlobalPlaybackProxyModeLoaded();
    await _configurePlayerIfNeeded();
    if (isCasting) {
      await stopPlayback();
      return;
    }
    if (episodes.isNotEmpty && !_blockPlaybackOnOpen) {
      await playAt(_initialIndex);
    }
  }

  Future<void> _configurePlayerIfNeeded() async {
    if (_playerConfigured) return;
    _playerConfigured = true;
  }

  /// 打开视频前显式激活音频会话，避免被音乐播放器的 deactivate 影响。
  Future<void> _ensureVideoAudioSession() async {
    try {
      await _audioSession.activate(PlaybackAudioProfile.media);
    } catch (_) {}
  }

  void handleRouteArguments(dynamic args) {
    unawaited(_handleRouteArgumentsInternal(args));
  }

  Future<void> _handleRouteArgumentsInternal(dynamic args) async {
    if (args is! Map) return;

    final key = _argsKey(args);
    if (_lastArgsKey == key) return;
    _lastArgsKey = key;
    final version = ++_routeArgsVersion;

    _applicationType = _defaultApplicationType;
    _applyArgs(args);
    _progressStorage =
        _providedProgressStorage ??
        PlaybackProgressStorage(applicationType: _applicationType);
    if (_shouldLoadCollectionOnEnter(args)) {
      await _loadEpisodesOnEnter(args, version);
    } else if (_hasExplicitInitialTarget(args)) {
      await _resolveExplicitPlaybackTarget(args, version);
    } else if (!_hasExplicitResumeTarget()) {
      await _restorePlaybackTargetFromStorage(version);
    }
    if (_routeArgsVersion != version) return;
    if (_ready && episodes.isNotEmpty && !_blockPlaybackOnOpen) {
      await _startInitialPlayback();
    }
  }

  String _argsKey(Map args) {
    int parseInt(dynamic value) {
      if (value is int) return value;
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    final app = (args['applicationType'] as String?)?.trim() ?? '';
    final folder = (args['folderPath'] as String?)?.trim() ?? '';
    final title = (args['title'] as String?)?.trim() ?? '';
    final rawEpisodes = args['episodes'];
    final count = rawEpisodes is List ? rawEpisodes.length : 0;
    final initialIndex = parseInt(args['initialIndex']);
    final preferredPath =
        (args[PlaybackEntryConfig.preferredItemPathKey] as String?)?.trim() ??
        '';
    final resume = (args['resumeEpisodePath'] as String?)?.trim() ?? '';
    final resumePositionMs = parseInt(args['resumePositionMs']);
    final loadOnEnter =
        args[PlaybackEntryConfig.loadCollectionOnEnterKey] == true ? '1' : '0';
    return '$app|$folder|$title|$count|$initialIndex|$preferredPath|$resume|$resumePositionMs|$loadOnEnter';
  }

  void _handlePlayingChanged(bool playing) {
    _updateAspectRatio();
    _syncWakelock(playing);
    if (playing) {
      _proxyModeFallbackApplied = false;
      unawaited(_applyPreferredPlaybackRate());
      _scheduleVoFallbackCheck();
      return;
    }
    _voFallbackTimer?.cancel();
    // Persist on pause as well as on stop/background so a normal pause always
    // leaves a resume point.
    unawaited(_persistPlaybackSnapshot());
  }

  void _handlePlaybackStreamError(String error) {
    if (_isNonFatalPlayerMessage(error)) return;
    if (defaultTargetPlatform == TargetPlatform.android &&
        _looksLikeVideoOutputError(error)) {
      if (!_voFallbackApplied) {
        unawaited(_applyMediaCodecEmbedFallback());
      }
      return;
    }
    if (_looksLikeDecodeError(error) &&
        !_decodeFallbackApplied &&
        effectiveDecodeMode != 'sw') {
      _decodeFallbackApplied = true;
      decodeMode.value = 'sw';
      unawaited(_playerPreferencesStorage.saveDecodeMode('sw'));
      unawaited(_applyMpvDecodeMode());
      unawaited(_restartCurrentEpisode());
      Get.snackbar(
        '视频解码失败',
        '${error.trim()}\n（已自动切换到软解）',
        duration: const Duration(seconds: 8),
      );
      return;
    }
    if (_proxyModeFallbackApplied) return;
    if (effectivePlaybackProxyMode != '302_redirect') return;
    _proxyModeFallbackApplied = true;
    _preferredPlaybackProxyMode = 'native_proxy';
    unawaited(_playerPreferencesStorage.saveProxyMode('native_proxy'));
    unawaited(_restartCurrentEpisode());
    Get.snackbar(
      '302 播放失败',
      '${error.trim()}\n${_describe302Target()}（已切换到本地代理）',
      duration: const Duration(seconds: 8),
    );
  }

  Future<void> _applyPreferredPlaybackRate() async {
    await (_playerPreferencesFuture ?? Future<void>.value());
    final rate = _preferredPlaybackRate;
    if (rate == null || rate <= 0 || rate == 1.0) return;
    if (isSpeedBoosting.value) return;
    if ((player.state.rate - rate).abs() < 0.001) return;
    try {
      await player.setRate(rate);
    } catch (_) {}
  }

  void _handleCompletedChanged(bool completed) {
    if (!completed) return;
    unawaited(onVideoEnd());
  }

  void _syncWakelock(bool playing) {
    final shouldEnable = playing;
    unawaited(shouldEnable ? WakelockPlus.enable() : WakelockPlus.disable());
  }

  /// Dolby Vision profile 5 sources arrive without a usable HDR fallback
  /// layer; mpv renders them with shifted colours unless tone mapping is
  /// configured explicitly.
  Future<void> setDecodeMode(String mode, {bool persist = true}) async {
    final normalized = _normalizeDecodeMode(mode);
    if (normalized == effectiveDecodeMode) return;
    decodeMode.value = normalized;
    _decodeFallbackApplied = false;
    if (persist) {
      unawaited(_playerPreferencesStorage.saveDecodeMode(normalized));
    }
    await _applyMpvDecodeMode();
    await _restartCurrentEpisode();
  }

  Future<void> _ensureDecodeModeApplied() {
    return _decodeModeAppliedFuture ??= _applyPreferredDecodeMode();
  }

  Future<void> _applyPreferredDecodeMode() async {
    await (_playerPreferencesFuture ?? Future<void>.value());
    await _applyMpvDecodeMode();
  }

  Future<void> _applyMpvDecodeMode() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    // DV Profile 5 的 RPU 只有软解路径会交给 libplacebo，MediaCodec 会丢弃它。
    final value = switch (effectiveDecodeMode) {
      // 硬解后端必须按平台选择：videotoolbox 只在 Apple 平台存在，
      // Android 对应 MediaCodec，Windows 是 D3D11VA，Linux 是 VAAPI。
      'hw' => _platformHwdec,
      'sw' => 'no',
      // vo 已回退到 mediacodec_embed 时，自动模式也必须保持 mediacodec，
      // 否则 auto-safe 可能选到别的解码器导致画面出不来。
      _ =>
        _voFallbackApplied && defaultTargetPlatform == TargetPlatform.android
            ? 'mediacodec'
            : 'auto-safe',
    };
    // 避免 onReady 的默认 auto 再次覆盖 VideoController 初始化时设置的值。
    if (_appliedHwdec == value) return;
    try {
      await platform.setProperty('hwdec', value);
      _appliedHwdec = value;
    } catch (_) {}
  }

  String get _platformHwdec {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'mediacodec';
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return 'videotoolbox';
      case TargetPlatform.windows:
        return 'd3d11va';
      case TargetPlatform.linux:
        return 'vaapi';
      default:
        return 'auto-safe';
    }
  }

  String _normalizeDecodeMode(String? mode) {
    switch ((mode ?? '').trim()) {
      case 'hw':
        return 'hw';
      case 'sw':
        return 'sw';
      default:
        return 'auto';
    }
  }

  bool _isNonFatalPlayerMessage(String error) {
    final lower = error.toLowerCase();
    const patterns = <String>[
      'audio device',
      'audio output',
      'audio unit',
      'could not open/initialize audio',
      'failed to initialize audio',
      'no sound',
      'libcuda',
      'libva',
      'vaapi',
      'vdpau',
    ];
    return patterns.any(lower.contains);
  }

  bool _looksLikeDecodeError(String error) {
    final lower = error.toLowerCase();
    return lower.contains('videotoolbox') ||
        lower.contains('hwdec') ||
        lower.contains('hardware decoder') ||
        lower.contains('failed to initialize a decoder') ||
        lower.contains('could not open codec') ||
        lower.contains('could not initialize video') ||
        lower.contains('failed to initialize video') ||
        lower.contains('decoder initialization') ||
        lower.contains('no video decoder') ||
        lower.contains('decoder init');
  }

  bool _looksLikeVideoOutputError(String error) {
    final lower = error.toLowerCase();
    return lower.contains('egl') ||
        lower.contains('opengl') ||
        lower.contains('gpu-context') ||
        lower.contains('vo/gpu') ||
        lower.contains('vo=gpu') ||
        lower.contains('libplacebo') ||
        lower.contains('video output') ||
        lower.contains('could not create texture') ||
        lower.contains('failed to create video');
  }

  /// 监听 mpv 的 vo-configured：vo=gpu 的 EGL 初始化失败时它会保持 no。
  Future<void> _observeVideoOutputState() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty('vo-configured', (value) async {
        final normalized = value.trim().toLowerCase();
        final configured =
            normalized == 'yes' || normalized == 'true' || normalized == '1';
        _voConfigured = configured;
        _voConfiguredKnown = true;
        if (configured) {
          _voFallbackTimer?.cancel();
          if (_voFallbackApplied) {
            _voFallbackHealthy = true;
          } else if (_dolbyVisionModeActive &&
              !useFlutterDolbyVisionFilter.value &&
              _activeGlslShaderFilePath != null) {
            try {
              await platform.setProperty(
                'glsl-shaders',
                _activeGlslShaderFilePath!,
              );
            } catch (_) {}
          }
          return;
        }
        _scheduleVoFallbackCheck();
      });
    } catch (_) {}
  }

  void _scheduleVoFallbackCheck() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_voFallbackApplying) return;
    _voFallbackTimer?.cancel();
    _voFallbackTimer = Timer(
      const Duration(seconds: 4),
      () => unawaited(_maybeApplyMediaCodecEmbedFallback()),
    );
  }

  Future<void> _maybeApplyMediaCodecEmbedFallback() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_voFallbackApplying || _voConfigured) return;
    if (!_voConfiguredKnown) return;
    // mediacodec_embed 也失败时不要反复重试。
    if (_voFallbackApplied && !_voFallbackHealthy) return;
    if (!player.state.playing) return;
    // 还没拿到视频参数时可能只是尚未起播，避免把音频文件误判为黑屏。
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    if (width <= 0 || height <= 0) return;
    if (player.state.position < const Duration(seconds: 1)) return;
    await _applyMediaCodecEmbedFallback();
  }

  /// vo=gpu 无法创建 EGL 上下文时的兜底：让 MediaCodec 直接把画面渲染到 Surface。
  /// 切换后继续监听 vo-configured，若 surface 重建导致 vo 被重置为 gpu，会再次回退。
  Future<void> _applyMediaCodecEmbedFallback() async {
    if (_voFallbackApplying) return;
    _voFallbackApplying = true;
    _voFallbackHealthy = false;
    final platform = player.platform;
    if (platform is! NativePlayer) {
      _voFallbackApplying = false;
      return;
    }
    final position = player.state.position;
    final previousHdrMode = _activeHdrShaderMode;
    try {
      await platform.setProperty('vo', 'null');
      await platform.setProperty('hwdec', 'mediacodec');
      _appliedHwdec = 'mediacodec';
      _activeHdrShaderMode = _hdrShaderModeOff;
      await platform.setProperty('vo', 'mediacodec_embed');
      // mediacodec_embed 需要重新初始化 vid，否则会报 Could not open codec。
      await platform.setProperty('vid', 'auto');
      if (position > Duration.zero) {
        await player.seek(position);
      }
    } catch (_) {
    } finally {
      _voFallbackApplying = false;
    }
    if (_voFallbackApplied) return;
    _voFallbackApplied = true;
    if (previousHdrMode != _hdrShaderModeOff) {
      unawaited(_enterHdrShaderMode(previousHdrMode));
    }
    Get.snackbar(
      '播放器兼容模式',
      '当前设备无法使用 GPU 渲染，已切换到 MediaCodec 输出',
      duration: const Duration(seconds: 5),
    );
  }

  /// Dolby Vision Profile 5（bl_signal_compatibility_id=0）的基础层是杜比私有 IPTPQc2，
  /// media_kit 内置的 mpv 0.36 编译时未开启 libplacebo（无 gpu-next），会把画面按普通
  /// BT.709 矩阵解码，导致无论本地代理还是 302 云转码流都出现明显的偏绿/偏紫。
  /// 同时针对标准 HDR10 / CUVA HDR Vivid (PQ) 与 HLG 片源，iOS 模拟器的软解输出管线
  /// (MPV_RENDER_API_TYPE_SW) 不经过 vo_gpu 色调映射，真机与 Android 在云转码剥离动态
  /// 元数据后也会因逐通道压缩导致红色偏暗偏棕。这里统一通过保色相 maxRGB 色调映射着色器还原。
  Future<void> _observeDolbyVisionProfile() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.observeProperty(
        'current-tracks/video/dolby-vision-profile',
        (value) async => _handleDolbyVisionProfileChanged(value),
      );
    } catch (_) {}
  }

  Future<void> _handleDolbyVisionProfileChanged(String value) async {
    final profile = int.tryParse(value.trim());
    if (profile == 5) {
      _dolbyVisionProfile5Confirmed = true;
      await _enterHdrShaderMode(_hdrShaderModeDoviP5);
      return;
    }
    if (profile != null && profile != 5) {
      _dolbyVisionProfile5Confirmed = false;
      await _evaluateDolbyVisionShader(player.state.videoParams);
    }
  }

  static const String _doviP5GlslShader = r'''//!HOOK MAIN
//!BIND HOOKED
//!DESC Dolby Vision Profile 5 (IPTPQc2 -> BT.709 SDR)

vec3 pq_eotf(vec3 n) {
    n = clamp(n, 0.0, 1.0);
    vec3 np = pow(n, vec3(1.0 / 78.84375));
    vec3 num = max(np - 0.8359375, 0.0);
    vec3 den = 18.8515625 - 18.6875 * np;
    return pow(num / max(den, 1e-6), vec3(1.0 / 0.1593017578125));
}

vec3 hable_Curve(vec3 x) {
    return ((x * (0.15 * x + 0.05) + 0.004) / (x * (0.15 * x + 0.50) + 0.06)) - (0.004 / 0.06);
}

vec3 tone_map_and_finish(vec3 rgb) {
    rgb = max(rgb, 0.0);
    float peak = max(rgb.r, max(rgb.g, rgb.b));
    if (peak > 1e-6) {
        float mapped_peak = hable_Curve(vec3(peak * 2.2)).x / hable_Curve(vec3(6.0)).x;
        mapped_peak = clamp(mapped_peak, 0.0, 1.0);
        rgb *= (mapped_peak / peak);
    }
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    float hi = clamp((peak - 1.2) / 3.0, 0.0, 1.0) * 0.35;
    rgb = mix(rgb, vec3(luma), hi);
    luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = clamp(mix(vec3(luma), rgb, 1.18), 0.0, 1.0);
    return pow(rgb, vec3(1.0 / 2.2));
}

vec4 hook() {
    vec4 color = HOOKED_tex(HOOKED_pos);
    // mpv 默认把未识别的流按 BT.709 矩阵转成了 RGB：
    // R = Y + 1.5748*Cr, G = Y - 0.1873*Cb - 0.4681*Cr, B = Y + 1.8556*Cb
    // 先精确反算出原始的 (I, Ct, Cp)：
    float R = color.r;
    float G = color.g;
    float B = color.b;
    float Cr = (R - G - 0.1009911 * (B - R)) / 1.8838896;
    float Y  = R - 1.5748 * Cr;
    float Cb = (B - Y) / 1.8556;

    // 杜比视界 Profile 5 RPU 映射多项式还原：
    // 1. 亮度通道 I 采用 RPU 2 阶分段多项式的凹曲线拟合
    // 2. 色度通道 Ct/Cp 在编码时存在非对称偏移（中性灰位于 U≈457, V≈436 而非 512）
    float chroma_gate = smoothstep(0.03, 0.12, Y);
    float I = clamp(0.84 * pow(max(Y - 0.01, 0.0), 0.85), 0.0, 1.0);
    float Ct = clamp(0.0715 * chroma_gate + 1.28 * Cb, -0.5, 0.5);
    float cp_bias = (0.055 + 0.60 * max(Cb, 0.0)) * chroma_gate;
    float Cp = clamp(cp_bias + 1.28 * Cr, -0.5, 0.5);

    // RPU ycc_to_rgb_matrix (IPTPQc2 -> 非线性 LMS_PQ)：
    vec3 lms_pq = vec3(
        I + 0.097534 * Ct + 0.205200 * Cp,
        I - 0.113892 * Ct + 0.133179 * Cp,
        I + 0.032593 * Ct - 0.676880 * Cp
    );

    // PQ EOTF -> 线性 LMS（1.0 = 10000 cd/m^2）：
    vec3 lms = pq_eotf(lms_pq);

    // RPU rgb_to_lms_matrix 交叉串扰矩阵校正：
    float sum_lms = lms.x + lms.y + lms.z;
    lms = 1.06384 * lms - 0.02130 * vec3(sum_lms);

    // Hunt-Pointer-Estevez LMS -> 线性 BT.709 RGB：
    vec3 rgb = vec3(
         5.432622 * lms.x - 4.679100 * lms.y + 0.246257 * lms.z,
        -1.105170 * lms.x + 2.311198 * lms.y - 0.205880 * lms.z,
         0.028104 * lms.x - 0.194660 * lms.y + 1.166325 * lms.z
    );
    rgb *= (10000.0 / 203.0);

    color.rgb = tone_map_and_finish(rgb);
    return color;
}
''';

  static const String _hdrPqGlslShader = r'''//!HOOK MAIN
//!BIND HOOKED
//!DESC HDR10 / HDR Vivid PQ (BT.2020 PQ -> BT.709 SDR)

vec3 pq_eotf(vec3 n) {
    n = clamp(n, 0.0, 1.0);
    vec3 np = pow(n, vec3(1.0 / 78.84375));
    vec3 num = max(np - 0.8359375, 0.0);
    vec3 den = 18.8515625 - 18.6875 * np;
    return pow(num / max(den, 1e-6), vec3(1.0 / 0.1593017578125));
}

vec3 bt2020_to_bt709(vec3 c) {
    return vec3(
         1.660491 * c.r - 0.587641 * c.g - 0.072850 * c.b,
        -0.124550 * c.r + 1.132900 * c.g - 0.008349 * c.b,
        -0.018151 * c.r - 0.100579 * c.g + 1.118730 * c.b
    );
}

vec3 hable_Curve(vec3 x) {
    return ((x * (0.15 * x + 0.05) + 0.004) / (x * (0.15 * x + 0.50) + 0.06)) - (0.004 / 0.06);
}

vec3 tone_map_and_finish(vec3 rgb) {
    rgb = max(rgb, 0.0);
    float peak = max(rgb.r, max(rgb.g, rgb.b));
    if (peak > 1e-6) {
        float mapped_peak = hable_Curve(vec3(peak * 2.2)).x / hable_Curve(vec3(6.0)).x;
        mapped_peak = clamp(mapped_peak, 0.0, 1.0);
        rgb *= (mapped_peak / peak);
    }
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    float hi = clamp((peak - 1.2) / 3.0, 0.0, 1.0) * 0.35;
    rgb = mix(rgb, vec3(luma), hi);
    luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = clamp(mix(vec3(luma), rgb, 1.18), 0.0, 1.0);
    return pow(rgb, vec3(1.0 / 2.2));
}

vec4 hook() {
    vec4 color = HOOKED_tex(HOOKED_pos);
    vec3 linear2020 = pq_eotf(color.rgb);
    vec3 rgb = bt2020_to_bt709(linear2020) * (10000.0 / 100.0);
    color.rgb = tone_map_and_finish(rgb);
    return color;
}
''';

  static const String _hdrHlgGlslShader = r'''//!HOOK MAIN
//!BIND HOOKED
//!DESC HDR HLG (BT.2020 HLG -> BT.709 SDR)

vec3 hlg_inverse_oetf(vec3 e) {
    e = clamp(e, 0.0, 1.0);
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    vec3 low = (e * e) / 3.0;
    vec3 high = (exp((e - c) / a) + b) / 12.0;
    return mix(low, high, step(vec3(0.5), e));
}

vec3 hlg_eotf(vec3 e) {
    vec3 scene = hlg_inverse_oetf(e);
    float ys = max(dot(scene, vec3(0.2627, 0.6780, 0.0593)), 1e-6);
    return scene * pow(ys, 0.2);
}

vec3 bt2020_to_bt709(vec3 c) {
    return vec3(
         1.660491 * c.r - 0.587641 * c.g - 0.072850 * c.b,
        -0.124550 * c.r + 1.132900 * c.g - 0.008349 * c.b,
        -0.018151 * c.r - 0.100579 * c.g + 1.118730 * c.b
    );
}

vec3 hable_Curve(vec3 x) {
    return ((x * (0.15 * x + 0.05) + 0.004) / (x * (0.15 * x + 0.50) + 0.06)) - (0.004 / 0.06);
}

vec3 tone_map_and_finish(vec3 rgb) {
    rgb = max(rgb, 0.0);
    float peak = max(rgb.r, max(rgb.g, rgb.b));
    if (peak > 1e-6) {
        float mapped_peak = hable_Curve(vec3(peak * 2.2)).x / hable_Curve(vec3(6.0)).x;
        mapped_peak = clamp(mapped_peak, 0.0, 1.0);
        rgb *= (mapped_peak / peak);
    }
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    float hi = clamp((peak - 1.2) / 3.0, 0.0, 1.0) * 0.35;
    rgb = mix(rgb, vec3(luma), hi);
    luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = clamp(mix(vec3(luma), rgb, 1.18), 0.0, 1.0);
    return pow(rgb, vec3(1.0 / 2.2));
}

vec4 hook() {
    vec4 color = HOOKED_tex(HOOKED_pos);
    vec3 linear2020 = hlg_eotf(color.rgb);
    vec3 rgb = bt2020_to_bt709(linear2020) * 1.8;
    color.rgb = tone_map_and_finish(rgb);
    return color;
}
''';

  final Map<int, String> _glslShaderFilePaths = <int, String>{};

  Future<String?> _ensureGlslShaderFile(int mode) async {
    final cached = _glslShaderFilePaths[mode];
    if (cached != null) return cached;
    final (filename, source) = switch (mode) {
      _hdrShaderModeDoviP5 => ('wpan_dovi_p5_tonemap.glsl', _doviP5GlslShader),
      _hdrShaderModePq => ('wpan_hdr_pq_tonemap.glsl', _hdrPqGlslShader),
      _hdrShaderModeHlg => ('wpan_hdr_hlg_tonemap.glsl', _hdrHlgGlslShader),
      _ => ('', ''),
    };
    if (filename.isEmpty) return null;
    try {
      final file = File('${Directory.systemTemp.path}/$filename');
      await file.writeAsString(source, flush: true);
      _glslShaderFilePaths[mode] = file.path;
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<ui.FragmentProgram?> _ensureDoviFragmentProgram() async {
    if (_doviFragmentProgram != null) return _doviFragmentProgram;
    try {
      _doviFragmentProgram = await ui.FragmentProgram.fromAsset(
        'shaders/dovi_p5_tonemap.frag',
      );
      return _doviFragmentProgram;
    } catch (_) {
      return null;
    }
  }

  /// 创建用于 Flutter Impeller 渲染管线的 HDR / 杜比视界像素着色器滤镜（iOS 真机/模拟器及 Android 兼容模式通用）。
  ui.ImageFilter? createDolbyVisionImageFilter() {
    final mode = flutterHdrShaderMode.value;
    if (mode <= _hdrShaderModeOff) return null;
    final program = _doviFragmentProgram;
    if (program != null && ui.ImageFilter.isShaderFilterSupported) {
      try {
        final shader = program.fragmentShader();
        // float slot 0, 1 由 Impeller ImageFilter.shader 自动填入 u_size；
        // float slot 2 为 u_mode（0.0 = DV P5, 1.0 = HDR PQ, 2.0 = HDR HLG）。
        shader.setFloat(2, (mode - 1).toDouble());
        return ui.ImageFilter.shader(shader);
      } catch (_) {}
    }
    return null;
  }

  bool get _shouldUseFlutterDolbyVisionFilter =>
      defaultTargetPlatform != TargetPlatform.android || _voFallbackApplied;

  Future<void> _configureMpvTargetColorspaceForMode(
    NativePlayer platform,
    int mode,
  ) async {
    try {
      switch (mode) {
        case _hdrShaderModePq:
          await platform.setProperty('target-prim', 'bt.2020');
          await platform.setProperty('target-trc', 'pq');
          break;
        case _hdrShaderModeHlg:
          await platform.setProperty('target-prim', 'bt.2020');
          await platform.setProperty('target-trc', 'hlg');
          break;
        default:
          await platform.setProperty('target-prim', 'auto');
          await platform.setProperty('target-trc', 'auto');
          break;
      }
    } catch (_) {}
  }

  Future<void> _enterHdrShaderMode(int mode) async {
    if (mode <= _hdrShaderModeOff) {
      await _restoreDefaultVideoPipeline();
      return;
    }
    if (_activeHdrShaderMode == mode || _dolbyVisionModeSwitching) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    _dolbyVisionModeSwitching = true;
    try {
      await _configureMpvTargetColorspaceForMode(platform, mode);
      if (_shouldUseFlutterDolbyVisionFilter) {
        final program = await _ensureDoviFragmentProgram();
        if (program == null) return;
        _activeHdrShaderMode = mode;
        flutterHdrShaderMode.value = mode;
        useFlutterDolbyVisionFilter.value = true;
        return;
      }
      final shaderPath = await _ensureGlslShaderFile(mode);
      if (shaderPath == null) return;
      _activeHdrShaderMode = mode;
      _activeGlslShaderFilePath = shaderPath;
      flutterHdrShaderMode.value = _hdrShaderModeOff;
      useFlutterDolbyVisionFilter.value = false;
      await platform.setProperty('glsl-shaders', shaderPath);
    } catch (_) {
    } finally {
      _dolbyVisionModeSwitching = false;
    }
  }

  Future<void> _restoreDefaultVideoPipeline() async {
    _dolbyVisionProfile5Confirmed = false;
    if (_activeHdrShaderMode == _hdrShaderModeOff &&
        !useFlutterDolbyVisionFilter.value &&
        flutterHdrShaderMode.value == _hdrShaderModeOff) {
      return;
    }
    final platform = player.platform;
    _activeHdrShaderMode = _hdrShaderModeOff;
    _activeGlslShaderFilePath = null;
    flutterHdrShaderMode.value = _hdrShaderModeOff;
    useFlutterDolbyVisionFilter.value = false;
    if (platform is! NativePlayer) return;
    _dolbyVisionModeSwitching = true;
    try {
      await platform.setProperty('glsl-shaders', '');
      await platform.setProperty('target-prim', 'auto');
      await platform.setProperty('target-trc', 'auto');
    } catch (_) {
    } finally {
      _dolbyVisionModeSwitching = false;
    }
  }

  bool _looksLikeDolbyVisionSource() {
    final candidates = <String?>[
      _currentEpisodePath,
      _openingEpisodePath,
      _currentEpisodeUrl,
      _openingEpisodeUrl,
      _currentEpisode?.title,
      _folderPath,
      resourceTitle.value,
    ];
    for (final raw in candidates) {
      if (raw == null || raw.isEmpty) continue;
      String decoded = raw;
      try {
        decoded = Uri.decodeFull(raw);
      } catch (_) {}
      final text = decoded.toLowerCase();
      if (text.contains('dovi') ||
          text.contains('dolby vision') ||
          text.contains('dolbyvision') ||
          text.contains('杜比视界') ||
          RegExp(r'(?:^|[.\s_\-\[\(])dv(?:$|[.\s_\-\]\)])').hasMatch(text)) {
        return true;
      }
    }
    return false;
  }

  /// 根据视频流色彩参数自动挂载/切换 HDR 与杜比视界色调映射着色器：
  /// 1. 杜比视界 Profile 5（或云转码丢失元数据但路径含杜比标识的非标准流）-> Mode 1 (IPTPQc2 -> BT.709)
  /// 2. 标准 HDR HLG (arib-std-b67 / hlg) -> Mode 3 (BT.2020 HLG -> BT.709)
  /// 3. 标准 HDR10 / HDR Vivid / DV Profile 8 基础层 (pq / smpte2084 / bt.2020) -> Mode 2 (BT.2020 PQ -> BT.709)
  Future<void> _evaluateDolbyVisionShader(VideoParams params) async {
    final width = params.dw ?? params.w ?? 0;
    final height = params.dh ?? params.h ?? 0;
    if (width <= 0 || height <= 0) return;

    final colormatrix = (params.colormatrix ?? '').trim().toLowerCase();
    final gamma = (params.gamma ?? '').trim().toLowerCase();
    final primaries = (params.primaries ?? '').trim().toLowerCase();

    final isPqHdr = gamma == 'pq' || gamma == 'smpte2084';
    final isHlgHdr = gamma == 'hlg' || gamma == 'arib-std-b67';
    final isBt2020 = primaries == 'bt.2020';
    final isStandardHdr = isPqHdr || isHlgHdr || isBt2020;

    if (_dolbyVisionProfile5Confirmed ||
        colormatrix == 'dolbyvision' ||
        (!isStandardHdr && _looksLikeDolbyVisionSource())) {
      await _enterHdrShaderMode(_hdrShaderModeDoviP5);
      return;
    }

    if (isHlgHdr) {
      await _enterHdrShaderMode(_hdrShaderModeHlg);
      return;
    }

    if (isPqHdr || isBt2020) {
      await _enterHdrShaderMode(_hdrShaderModePq);
      return;
    }

    if (_activeHdrShaderMode != _hdrShaderModeOff) {
      await _restoreDefaultVideoPipeline();
    }
  }

  Future<void> _applyMpvColorPipeline() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('tone-mapping', 'bt.2390');
      await platform.setProperty('target-colorspace-hint', 'yes');
      await platform.setProperty('hdr-compute-peak', 'yes');
    } catch (_) {}
  }

  Future<void> stopPlayback() async {
    await _persistPlaybackSnapshot();
    try {
      await player.stop();
    } catch (_) {}
    await _restoreDefaultVideoPipeline();
    _resetAudioTrackState();
    _resetSubtitleTrackState();
    unawaited(WakelockPlus.disable());
    await _audioSession.deactivate();
  }

  Future<void> pauseForBackground() async {
    await _persistPlaybackSnapshot();
    try {
      if (player.state.playing) {
        await player.pause();
      }
    } catch (_) {}
    unawaited(WakelockPlus.disable());
  }

  Future<void> _persistPlaybackSnapshot() async {
    final folder = _folderPath;
    final episodePath = _currentEpisodePath;
    if (folder == null || folder.isEmpty) return;
    if (episodePath == null || episodePath.isEmpty) return;

    final position = player.state.position;
    // A pause fired before the first frame would otherwise overwrite an
    // existing resume point with zero.
    if (position <= Duration.zero) return;

    final current = _currentEpisode;
    final rawTitle = (current?.title ?? '').trim();
    final title = rawTitle.isNotEmpty ? rawTitle : _titleFromPath(episodePath);

    await _progressStorage.saveProgress(
      folderPath: folder,
      itemTitle: title,
      itemPath: episodePath,
      position: position,
    );
  }

  void _updateAspectRatio() {
    final rawWidth = player.state.width;
    final rawHeight = player.state.height;
    if (rawWidth == null || rawHeight == null) return;
    var width = rawWidth.toDouble();
    var height = rawHeight.toDouble();
    if (width <= 0 || height <= 0) return;
    final rotate = (player.state.videoParams.rotate ?? 0) % 360;
    if (rotate == 90 || rotate == 270) {
      final temp = width;
      width = height;
      height = temp;
    }
    final ratio = (width / height).clamp(0.4, 3.0);
    if ((videoAspectRatio.value - ratio).abs() > 0.01) {
      videoAspectRatio.value = ratio;
    }
    final portrait = ratio < 0.85;
    if (isPortraitVideo.value != portrait) {
      isPortraitVideo.value = portrait;
    }
  }

  void toggleEpisodeOrder() {
    episodesAscending.value = !episodesAscending.value;
  }

  List<int> get visibleEpisodeIndices {
    final count = episodes.length;
    if (episodesAscending.value) {
      return List<int>.generate(count, (i) => i, growable: false);
    }
    return List<int>.generate(count, (i) => count - 1 - i, growable: false);
  }

  void onManualNext() {
    final next = currentIndex.value + 1;
    if (next >= episodes.length) return;
    currentIndex.value = next;
  }

  Future<void> playNextEpisode() => playAt(currentIndex.value + 1);

  Future<void> playPreviousEpisode() => playAt(currentIndex.value - 1);

  Future<void> castCurrentEpisode() async {
    final url = currentCastUrl;
    if (url == null || url.isEmpty) {
      Get.snackbar('提示', '当前视频没有可投屏地址');
      return;
    }
    final result = await Get.bottomSheet<bool>(
      VideoCastView(
        url: url,
        title: currentCastTitle,
        sourcePath: currentCastSourcePath,
        asBottomSheet: true,
        onCastStarted: _enterCastingLocalStandby,
      ),
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
    );
    if (result == true) return;
  }

  Future<void> stopCasting() async {
    await _persistCastProgressSnapshot();
    final wasCasting = isCasting;
    await _castService.stopCasting();
    _stopCastProgressPolling();
    if (!wasCasting) return;
    await _restoreLocalPlaybackAfterCasting();
  }

  Future<void> _enterCastingLocalStandby() async {
    _subtitleTrackBeforeCasting = currentSubtitleTrack.value;
    await stopSpeedBoost();
    _lastCastPersistedPosition = null;
    _startCastProgressPolling();
    try {
      await player.pause();
    } catch (_) {}
    await stopPlayback();
  }

  Future<void> _restoreLocalPlaybackAfterCasting() async {
    final episode = _currentEpisode;
    if (episode == null) {
      _subtitleTrackBeforeCasting = null;
      return;
    }
    await _ensureSkipSettingsLoaded();

    final url = _episodeUrl(episode);
    if (url == null || url.isEmpty) {
      _subtitleTrackBeforeCasting = null;
      return;
    }

    final episodePath = episode.path?.trim();
    final intro = skipIntro.value;
    final subtitleToApply = await _resolveSubtitleTrackForEpisode(
      episode,
      explicitTrack: _subtitleTrackBeforeCasting,
    );

    try {
      _openingEpisodePath = episodePath;
      _openingEpisodeUrl = url;
      await player.stop();
      await _restoreDefaultVideoPipeline();
      _resetAudioTrackState();
      _resetSubtitleTrackState();
      _currentEpisodePath = episodePath;
      _currentEpisodeUrl = url;
      _lastPersistedPosition = null;
      _outroSkipTriggered = false;
      _pendingSeek = intro > Duration.zero ? intro : null;
      await player.open(
        _mediaForUrl(await _resolve302TargetIfNeeded(url)),
        play: false,
      );
      if (subtitleToApply != null) {
        await player.setSubtitleTrack(subtitleToApply);
      }
    } catch (_) {
      Get.snackbar('播放失败', '当前视频恢复失败，请重试');
    } finally {
      _openingEpisodePath = null;
      _openingEpisodeUrl = null;
      _subtitleTrackBeforeCasting = null;
    }
  }

  Future<void> setPlaybackRate(double rate, {bool persist = true}) async {
    if (rate <= 0) return;
    if (persist) {
      _preferredPlaybackRate = rate;
      unawaited(_playerPreferencesStorage.savePlaybackRate(rate));
    }
    try {
      await player.setRate(rate);
    } catch (_) {}
  }

  Future<void> setCurrentPlaybackProxyMode(String mode) async {
    if (!canSwitchCurrentPlaybackProxyMode) return;
    if (isCasting) {
      Get.snackbar('提示', '投屏时暂不支持切换当前播放模式');
      return;
    }

    final normalized = _normalizePlaybackProxyMode(mode);
    final nextOverride = normalized == globalPlaybackProxyMode.value
        ? null
        : normalized;
    final currentOverride = currentPlaybackProxyModeOverride.value;
    if (effectivePlaybackProxyMode == normalized &&
        currentOverride == nextOverride) {
      return;
    }

    _preferredPlaybackProxyMode = normalized;
    unawaited(_playerPreferencesStorage.saveProxyMode(normalized));
    currentPlaybackProxyModeOverride.value = nextOverride;
    await _restartCurrentEpisode();
  }

  Future<void> setAudioTrackSelection(AudioTrack track) async {
    if (isCasting) {
      Get.snackbar('提示', '投屏时暂不支持切换本地音轨');
      return;
    }
    try {
      await player.setAudioTrack(track);
    } catch (_) {
      Get.snackbar('切换失败', '当前音轨切换失败，请稍后重试');
    }
  }

  Future<void> setSubtitleTrackSelection(SubtitleTrack track) async {
    if (isCasting) {
      Get.snackbar('提示', '投屏时暂不支持切换本地字幕');
      return;
    }
    try {
      await player.setSubtitleTrack(track);
    } catch (_) {
      Get.snackbar('切换失败', '当前字幕切换失败，请稍后重试');
    }
  }

  String audioTrackTitle(AudioTrack track) {
    switch (track.id) {
      case 'auto':
        return '自动';
      case 'no':
        return '关闭音频';
    }
    final rawTitle = track.title?.trim() ?? '';
    if (rawTitle.isNotEmpty) return rawTitle;
    final language = _audioLanguageLabel(track.language);
    if (language.isNotEmpty) return language;
    final codec = track.codec?.trim() ?? '';
    if (codec.isNotEmpty) return codec.toUpperCase();
    return '音轨';
  }

  String audioTrackSubtitle(AudioTrack track) {
    if (track.id == 'auto') {
      return '自动选择默认音轨';
    }
    if (track.id == 'no') {
      return '关闭当前视频声音输出';
    }

    final parts = <String>[];
    final language = _audioLanguageLabel(track.language);
    final title = track.title?.trim() ?? '';
    if (language.isNotEmpty && language != title) {
      parts.add(language);
    }
    final codec = track.codec?.trim() ?? '';
    if (codec.isNotEmpty) {
      parts.add(codec.toUpperCase());
    }
    final channels = track.channels?.trim() ?? '';
    if (channels.isNotEmpty) {
      parts.add(channels.toUpperCase());
    } else if (track.channelscount != null && track.channelscount! > 0) {
      parts.add('${track.channelscount} 声道');
    }
    if (track.isDefault == true) {
      parts.add('默认');
    }
    return parts.join(' · ');
  }

  String subtitleTrackTitle(SubtitleTrack track) {
    switch (track.id) {
      case 'auto':
        return '自动';
      case 'no':
        return '关闭字幕';
    }
    final rawTitle = track.title?.trim() ?? '';
    if (rawTitle.isNotEmpty) return rawTitle;
    final language = _subtitleLanguageLabel(track.language);
    if (language.isNotEmpty) return language;
    final codec = track.codec?.trim() ?? '';
    if (codec.isNotEmpty) return codec.toUpperCase();
    if (track.uri || track.data) {
      final fileTitle = _titleFromPath(track.id);
      if (fileTitle.isNotEmpty) return fileTitle;
    }
    return '字幕';
  }

  String subtitleTrackSubtitle(SubtitleTrack track) {
    if (track.id == 'auto') {
      return '自动选择默认字幕';
    }
    if (track.id == 'no') {
      return '关闭当前视频字幕显示';
    }

    final parts = <String>[];
    if (track.uri) {
      parts.add('外挂字幕');
    } else if (track.data) {
      parts.add('临时字幕');
    }
    final language = _subtitleLanguageLabel(track.language);
    final title = track.title?.trim() ?? '';
    if (language.isNotEmpty && language != title) {
      parts.add(language);
    }
    final codec = track.codec?.trim() ?? '';
    if (codec.isNotEmpty) {
      parts.add(codec.toUpperCase());
    }
    if (track.isDefault == true) {
      parts.add('默认');
    }
    if (track.uri) {
      final ext = _extensionFromPath(track.id);
      if (ext.isNotEmpty) {
        parts.add(ext.toUpperCase());
      }
    }
    return parts.join(' · ');
  }

  Future<void> startSpeedBoost([double rate = 3.0]) async {
    if (isSpeedBoosting.value) return;
    if (rate <= 0) return;
    isSpeedBoosting.value = true;
    speedBoostRate.value = rate;
    _rateBeforeBoost = player.state.rate;
    await setPlaybackRate(rate, persist: false);
  }

  Future<void> stopSpeedBoost() async {
    if (!isSpeedBoosting.value) return;
    isSpeedBoosting.value = false;
    final restore = _rateBeforeBoost;
    _rateBeforeBoost = null;
    if (restore != null && restore > 0) {
      await setPlaybackRate(restore, persist: false);
      return;
    }
    await setPlaybackRate(1.0, persist: false);
  }

  Future<void> setControlsLocked(bool locked) async {
    if (isControlsLocked.value == locked) return;
    isControlsLocked.value = locked;
    if (locked) {
      await stopSpeedBoost();
    }
  }

  bool get isFullscreenCover =>
      fullscreenFitMode.value == FullscreenFitMode.cover;

  void setFullscreenFitMode(FullscreenFitMode mode) {
    if (fullscreenFitMode.value == mode) return;
    fullscreenFitMode.value = mode;
  }

  void toggleFullscreenFitMode() {
    setFullscreenFitMode(
      isFullscreenCover ? FullscreenFitMode.contain : FullscreenFitMode.cover,
    );
  }

  Future<void> setSkipIntro(Duration intro) async {
    final folder = _skipFolderKey;
    if (folder == null || folder.trim().isEmpty) return;
    final seconds = intro.inSeconds.clamp(0, 300);
    skipIntro.value = Duration(seconds: seconds);
    _skipSettingsLoaded = true;
    _persistSkipSettings(folder);
  }

  Future<void> setSkipOutro(Duration outro) async {
    final folder = _skipFolderKey;
    if (folder == null || folder.trim().isEmpty) return;
    final seconds = outro.inSeconds.clamp(0, 300);
    skipOutro.value = Duration(seconds: seconds);
    _skipSettingsLoaded = true;
    _persistSkipSettings(folder);
  }

  Future<void> clearSkipSettings() async {
    final folder = _skipFolderKey;
    if (folder == null || folder.trim().isEmpty) return;
    skipIntro.value = Duration.zero;
    skipOutro.value = Duration.zero;
    _skipSettingsLoaded = true;
    try {
      await _skipStorage.clear(folder);
    } catch (_) {}
  }

  void _persistSkipSettings(String folderPath) {
    final settings = SkipSettings(
      intro: skipIntro.value,
      outro: skipOutro.value,
    );
    unawaited(_skipStorage.save(folderPath, settings));
  }

  Future<void> _ensureSkipSettingsLoaded() async {
    final folder = _skipFolderKey;
    if (folder == null || folder.trim().isEmpty) return;
    if (_skipSettingsLoaded) return;
    try {
      final settings = await _skipStorage.read(folder);
      if (settings != null) {
        skipIntro.value = settings.intro;
        skipOutro.value = settings.outro;
      }
    } catch (_) {}
    _skipSettingsLoaded = true;
  }

  void beginScrub({required double viewWidth}) {
    if (viewWidth <= 0) return;
    if (player.state.duration <= Duration.zero) return;
    _scrubViewWidth = viewWidth;
    _scrubDeltaDx = 0;
    _scrubStartPos = player.state.position;
    _scrubDuration = player.state.duration;
    isScrubbing.value = true;
    scrubPreview.value = _scrubStartPos;
  }

  void updateScrub(double deltaDx) {
    if (!isScrubbing.value) return;
    if (_scrubViewWidth <= 0) return;
    final durationMs = _scrubDuration.inMilliseconds;
    if (durationMs <= 0) return;

    _scrubDeltaDx += deltaDx;
    final offsetMs = (_scrubDeltaDx / _scrubViewWidth) * durationMs;
    final targetMs = (_scrubStartPos.inMilliseconds + offsetMs.round()).clamp(
      0,
      durationMs,
    );
    final target = Duration(milliseconds: targetMs);
    scrubPreview.value = target;

    _scrubTimer?.cancel();
    _scrubTimer = Timer(const Duration(milliseconds: 90), () {
      unawaited(player.seek(Duration(milliseconds: targetMs)));
    });
  }

  void endScrub() {
    if (!isScrubbing.value) return;
    _scrubTimer?.cancel();
    _scrubTimer = null;
    final preview = scrubPreview.value;
    final durationMs = player.state.duration.inMilliseconds;
    if (preview != null && durationMs > 0) {
      final targetMs = preview.inMilliseconds.clamp(0, durationMs);
      unawaited(player.seek(Duration(milliseconds: targetMs)));
    }
    isScrubbing.value = false;
    scrubPreview.value = null;
  }

  Future<void> onVideoEnd() async {
    if (_autoNextRunning) return;
    _autoNextRunning = true;
    try {
      await playAt(currentIndex.value + 1);
    } finally {
      _autoNextRunning = false;
    }
  }

  /// Quark TV transcoding URLs are only playable with the TV client identity.
  /// When the user picks 302/redirect the player connects to Quark directly, so
  /// the request has to carry the same UA and Referer the server uses.
  Media _mediaForUrl(String url) {
    if (effectivePlaybackProxyMode != '302_redirect') {
      return Media(url);
    }
    return Media(url, httpHeaders: playbackHttpHeaders);
  }

  /// In 302 mode the player must talk to Quark itself, but ffmpeg drops custom
  /// headers across redirects. Resolve the server's 302 first and hand ffmpeg
  /// the final Quark URL so the TV UA/Referer reach Quark.
  Future<String> _resolve302TargetIfNeeded(String url) async {
    if (effectivePlaybackProxyMode != '302_redirect') return url;
    if (!_isLocalProxyStreamUrl(url)) return url;
    try {
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          validateStatus: (_) => true,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final response = await dio.get<dynamic>(url);
      final payload = response.data;
      if (payload is Map) {
        final code = payload['code'];
        final message = (payload['msg'] ?? '').toString().trim();
        if (message.isNotEmpty && code != 200 && code != '200') {
          _last302ErrorMessage = message;
        }
      }
      final location = response.headers.value('location');
      if (location != null && location.trim().isNotEmpty) {
        final resolved = location.trim();
        _last302TargetUrl = resolved;
        _last302ErrorMessage = null;
        return resolved;
      }
    } catch (_) {}
    _last302TargetUrl = null;
    return url;
  }

  Future<void> playAt(
    int index, {
    bool forceReopen = false,
    Duration? startPosition,
    bool clearResume = false,
    SubtitleTrack? subtitleTrackOverride,
  }) async {
    await _ensureDecodeModeApplied();
    await _ensureGlobalPlaybackProxyModeLoaded();
    if (index < 0 || index >= episodes.length) return;
    await _ensureSkipSettingsLoaded();

    if (Get.isRegistered<MusicPlayerController>()) {
      await Get.find<MusicPlayerController>().pause(releaseAudioSession: false);
    }
    await _ensureVideoAudioSession();

    final episode = episodes[index];
    final episodePath = episode.path?.trim();
    final url = _episodeUrl(episode);
    if (url == null) {
      Get.snackbar('提示', '登录已过期，请重新登录');
      return;
    }

    if (isCasting) {
      final castUrl = _castUrlForEpisode(episode);
      if (castUrl == null || castUrl.isEmpty) {
        Get.snackbar('提示', '当前视频没有可投屏地址');
        return;
      }
      final switched = await _castService.castToCurrentDevice(
        url: castUrl,
        title: _castTitleForEpisode(episode),
        sourcePath: episodePath ?? '',
      );
      if (!switched) {
        Get.snackbar('投屏失败', '当前设备没有接受切换请求');
        return;
      }
      _lastCastPersistedPosition = null;
      await stopPlayback();
      _currentEpisodePath = episodePath;
      _currentEpisodeUrl = url;
      currentIndex.value = index;
      return;
    }

    Duration? resume;
    if (!clearResume &&
        _resumeEpisodePath != null &&
        episodePath != null &&
        MediaPath.equals(_resumeEpisodePath, episodePath) &&
        _resumePosition != null &&
        _resumePosition! > Duration.zero) {
      resume = _resumePosition;
      _resumeEpisodePath = null;
      _resumePosition = null;
    }
    if (clearResume) {
      _resumeEpisodePath = null;
      _resumePosition = null;
    }

    var pendingSeek = startPosition ?? resume ?? Duration.zero;
    final intro = skipIntro.value;
    if (intro > Duration.zero && pendingSeek < intro) {
      pendingSeek = intro;
    }
    final subtitleToApply = await _resolveSubtitleTrackForEpisode(
      episode,
      explicitTrack: subtitleTrackOverride,
    );

    if (!forceReopen && _shouldSkipDuplicateOpen(index, episodePath, url)) {
      currentIndex.value = index;
      if (clearResume) {
        _resumeEpisodePath = null;
        _resumePosition = null;
      }
      return;
    }

    try {
      _openingEpisodePath = episodePath;
      _openingEpisodeUrl = url;
      await player.stop();
      await _restoreDefaultVideoPipeline();
      _resetAudioTrackState();
      _resetSubtitleTrackState();
      _currentEpisodePath = episodePath;
      _currentEpisodeUrl = url;
      _lastPersistedPosition = null;
      _outroSkipTriggered = false;
      _pendingSeek = pendingSeek > Duration.zero ? pendingSeek : null;
      await player.open(
        _mediaForUrl(await _resolve302TargetIfNeeded(url)),
        play: true,
      );
      if (subtitleToApply != null) {
        await player.setSubtitleTrack(subtitleToApply);
      }
      currentIndex.value = index;
    } catch (_) {
      Get.snackbar('播放失败', '请稍后重试');
    } finally {
      _openingEpisodePath = null;
      _openingEpisodeUrl = null;
    }
  }

  String? _episodeUrl(Episode episode) {
    final path = episode.path?.trim();
    final url = episode.url?.trim();
    final playbackMode = effectivePlaybackProxyMode;
    if (url != null && url.isNotEmpty) {
      if (_isLocalProxyStreamUrl(url)) {
        return _applyPlaybackProxyModeToUrl(url, mode: playbackMode);
      }
      if (path == null || path.isEmpty) {
        return url;
      }
    }
    if (path == null || path.isEmpty) return null;
    return _buildStreamUrl(path, mode: playbackMode);
  }

  String? _castUrlForEpisode(Episode episode) {
    final path = episode.path?.trim();
    final rawUrl = episode.url?.trim();
    String? streamUrl;
    if (rawUrl != null && rawUrl.isNotEmpty) {
      if (_isLocalProxyStreamUrl(rawUrl)) {
        streamUrl = _applyPlaybackProxyModeToUrl(
          rawUrl,
          mode: _defaultPlaybackProxyMode,
        );
      } else if (path == null || path.isEmpty) {
        streamUrl = rawUrl;
      }
    }
    if ((streamUrl == null || streamUrl.isEmpty) &&
        path != null &&
        path.isNotEmpty) {
      streamUrl = _buildStreamUrl(path, mode: _defaultPlaybackProxyMode);
    }
    if (streamUrl == null || streamUrl.isEmpty) return null;
    if (!_isLocalProxyStreamUrl(streamUrl)) {
      return streamUrl;
    }
    final uri = Uri.parse(streamUrl);
    return uri
        .replace(
          queryParameters: <String, String>{
            ...uri.queryParameters,
            'cast': 'true',
          },
        )
        .toString();
  }

  String _castTitleForEpisode(Episode episode) {
    final title = episode.title.trim();
    if (title.isNotEmpty) return title;
    final subTitle = episode.subTitle.trim();
    if (subTitle.isNotEmpty) return subTitle;
    final resource = resourceTitle.value.trim();
    if (resource.isNotEmpty) return resource;
    return '当前视频';
  }

  void _applyArgs(dynamic args) {
    if (args is! Map) return;
    _initialIndex = 0;
    _resumeEpisodePath = null;
    _resumePosition = null;
    _currentEpisodePath = null;
    _currentEpisodeUrl = null;
    _pendingSeek = null;
    _lastPersistedPosition = null;
    _blockPlaybackOnOpen = false;
    isLoadingPlaylist.value = false;
    currentPlaybackProxyModeOverride.value = null;
    _resetAudioTrackState();
    _resetSubtitleTrackState(clearExternalOptions: true);
    _folderEntries = const <WebdavFileEntry>[];
    _subtitleTrackBeforeCasting = null;

    final applicationType = args['applicationType'];
    if (applicationType is String && applicationType.trim().isNotEmpty) {
      _applicationType = applicationType.trim();
    }

    final title = args['title'];
    if (title is String && title.trim().isNotEmpty) {
      resourceTitle.value = title.trim();
    }

    final intro = args['intro'];
    if (intro is String) {
      resourceIntro.value = intro.trim();
    } else {
      resourceIntro.value = '';
    }

    final initialIndex = args['initialIndex'];
    if (initialIndex is int) _initialIndex = initialIndex;
    if (initialIndex is String) {
      _initialIndex = int.tryParse(initialIndex) ?? _initialIndex;
    }

    final rawEpisodes = args['episodes'];
    final parsed = <Episode>[];
    if (rawEpisodes is List) {
      for (final e in rawEpisodes) {
        if (e is! Map) continue;
        final map = e.cast<dynamic, dynamic>();
        final t = map['title'];
        final st = map['subTitle'];
        final url = map['url'];
        final path = map['path'];
        if (t is! String || t.trim().isEmpty) continue;
        parsed.add(
          Episode(
            title: t.trim(),
            subTitle: st is String ? st.trim() : '',
            url: url is String ? url.trim() : null,
            path: path is String ? path.trim() : null,
          ),
        );
      }
    }
    episodes.assignAll(parsed);
    if (_initialIndex < 0) _initialIndex = 0;
    if (_initialIndex >= episodes.length) _initialIndex = 0;

    final folderPath = args['folderPath'];
    if (folderPath is String && folderPath.trim().isNotEmpty) {
      final nextFolder = folderPath.trim();
      _folderPath = nextFolder;
      if (_skipFolderKey != nextFolder) {
        _skipFolderKey = nextFolder;
        _skipSettingsLoaded = false;
        skipIntro.value = Duration.zero;
        skipOutro.value = Duration.zero;
        unawaited(_ensureSkipSettingsLoaded());
      }
    } else {
      _folderPath = null;
      _skipFolderKey = null;
      _skipSettingsLoaded = true;
      skipIntro.value = Duration.zero;
      skipOutro.value = Duration.zero;
    }

    final resumeEpisodePath = args['resumeEpisodePath'];
    if (resumeEpisodePath is String && resumeEpisodePath.trim().isNotEmpty) {
      _resumeEpisodePath = MediaPath.normalize(resumeEpisodePath);
    }

    final resumePositionMs = _toInt(args['resumePositionMs']);
    if (resumePositionMs != null && resumePositionMs > 0) {
      _resumePosition = Duration(milliseconds: resumePositionMs);
    }

    _syncInitialIndexWithResumePath();
  }

  bool _shouldLoadCollectionOnEnter(Map args) {
    return args[PlaybackEntryConfig.loadCollectionOnEnterKey] == true;
  }

  bool _hasExplicitInitialTarget(Map args) {
    final preferredPath = MediaPath.normalize(
      args[PlaybackEntryConfig.preferredItemPathKey] as String?,
    );
    if (preferredPath.isNotEmpty) {
      return true;
    }
    final explicitResumePath = MediaPath.normalize(
      args['resumeEpisodePath'] as String?,
    );
    return explicitResumePath.isNotEmpty;
  }

  Future<void> _loadEpisodesOnEnter(Map args, int version) async {
    final folder = _folderPath;
    if (folder == null || folder.isEmpty) return;

    isLoadingPlaylist.value = true;
    episodes.clear();
    currentIndex.value = 0;
    resourceIntro.value = '';

    try {
      final files = await _webdavApi.fetchFileList(
        applicationType: _applicationType,
        path: folder,
      );
      if (_routeArgsVersion != version) return;
      _folderEntries = List<WebdavFileEntry>.unmodifiable(files);

      final nextEpisodes = _buildEpisodesFromEntries(files);
      episodes.assignAll(nextEpisodes);
      if (nextEpisodes.isEmpty) return;

      resourceIntro.value = '共 ${nextEpisodes.length} 集';
      await _resolveInitialPlaybackTarget(args, version);
    } catch (error) {
      if (_routeArgsVersion != version) return;
      Get.snackbar(
        '提示',
        '获取播放列表失败：${QuarkErrorHelper.toFriendlyMessage(error)}',
      );
    } finally {
      if (_routeArgsVersion == version) {
        isLoadingPlaylist.value = false;
      }
    }
  }

  Future<void> _resolveExplicitPlaybackTarget(Map args, int version) async {
    if (episodes.isEmpty) return;

    final preferredPath = MediaPath.normalize(
      args[PlaybackEntryConfig.preferredItemPathKey] as String?,
    );
    final explicitResumePath = MediaPath.normalize(
      args['resumeEpisodePath'] as String?,
    );
    final explicitResumePositionMs = _toInt(args['resumePositionMs']);

    var initialPath = '';
    var resumePath = '';
    int? resumePositionMs;
    var source = _InitialEpisodeSource.none;

    if (preferredPath.isNotEmpty) {
      initialPath = preferredPath;
      source = _InitialEpisodeSource.preferred;
      if (explicitResumePath.isNotEmpty &&
          MediaPath.equals(explicitResumePath, preferredPath)) {
        resumePath = explicitResumePath;
        resumePositionMs = explicitResumePositionMs;
      }
    } else if (explicitResumePath.isNotEmpty) {
      initialPath = explicitResumePath;
      resumePath = explicitResumePath;
      resumePositionMs = explicitResumePositionMs;
      source = _InitialEpisodeSource.explicitResume;
    }

    if (initialPath.isEmpty) return;

    final matchedIndex = _episodeIndexByPath(initialPath);
    if (matchedIndex < 0) {
      await _handleMissingInitialEpisode(
        folder: _folderPath ?? '',
        source: source,
        targetPath: initialPath,
      );
      if (_routeArgsVersion != version) return;
      return;
    }

    _initialIndex = matchedIndex;
    currentIndex.value = matchedIndex;
    _resumeEpisodePath = resumePath.isNotEmpty ? resumePath : null;
    _resumePosition = resumePositionMs != null && resumePositionMs > 0
        ? Duration(milliseconds: resumePositionMs)
        : null;
  }

  Future<void> _resolveInitialPlaybackTarget(Map args, int version) async {
    final folder = _folderPath;
    if (folder == null || folder.isEmpty) return;
    if (episodes.isEmpty) return;

    final preferredPath = MediaPath.normalize(
      args[PlaybackEntryConfig.preferredItemPathKey] as String?,
    );
    final explicitResumePath = MediaPath.normalize(
      args['resumeEpisodePath'] as String?,
    );
    final explicitResumePositionMs = _toInt(args['resumePositionMs']);

    PlaybackProgress? progress;
    try {
      progress = await _progressStorage.readProgress(folder);
    } catch (_) {}
    if (_routeArgsVersion != version) return;

    final storedResumePath = MediaPath.normalize(
      progress?.buildItemPath(folder),
    );
    final storedResumePositionMs =
        progress != null && progress.position > Duration.zero
        ? progress.position.inMilliseconds
        : null;

    var initialPath = '';
    var resumePath = '';
    int? resumePositionMs;
    var source = _InitialEpisodeSource.none;

    if (preferredPath.isNotEmpty) {
      initialPath = preferredPath;
      source = _InitialEpisodeSource.preferred;
      if (explicitResumePath.isNotEmpty &&
          MediaPath.equals(explicitResumePath, preferredPath)) {
        resumePath = explicitResumePath;
        resumePositionMs = explicitResumePositionMs;
      } else if (storedResumePath.isNotEmpty &&
          MediaPath.equals(storedResumePath, preferredPath)) {
        resumePath = storedResumePath;
        resumePositionMs = storedResumePositionMs;
      }
    } else if (explicitResumePath.isNotEmpty) {
      initialPath = explicitResumePath;
      resumePath = explicitResumePath;
      resumePositionMs = explicitResumePositionMs;
      source = _InitialEpisodeSource.explicitResume;
    } else if (storedResumePath.isNotEmpty) {
      initialPath = storedResumePath;
      resumePath = storedResumePath;
      resumePositionMs = storedResumePositionMs;
      source = _InitialEpisodeSource.storedResume;
    }

    var initialIndex = 0;
    if (initialPath.isNotEmpty) {
      final matchedIndex = _episodeIndexByPath(initialPath);
      if (matchedIndex >= 0) {
        initialIndex = matchedIndex;
      } else {
        final shouldContinue = await _handleMissingInitialEpisode(
          folder: folder,
          source: source,
          targetPath: initialPath,
        );
        if (_routeArgsVersion != version) return;
        if (!shouldContinue) {
          return;
        }
        resumePath = '';
        resumePositionMs = null;
      }
    }

    _initialIndex = initialIndex;
    currentIndex.value = initialIndex;
    _resumeEpisodePath = resumePath.isNotEmpty ? resumePath : null;
    _resumePosition = resumePositionMs != null && resumePositionMs > 0
        ? Duration(milliseconds: resumePositionMs)
        : null;
  }

  Future<void> _restorePlaybackTargetFromStorage(int version) async {
    final folder = _folderPath;
    if (folder == null || folder.isEmpty) return;
    if (episodes.isEmpty) return;

    try {
      final progress = await _progressStorage.readProgress(folder);
      if (_routeArgsVersion != version || progress == null) return;

      final resumePath = MediaPath.normalize(progress.buildItemPath(folder));
      if (resumePath.isEmpty) return;

      final index = _episodeIndexByPath(resumePath);
      if (index < 0) {
        await _progressStorage.clearProgress(folder);
        return;
      }

      _initialIndex = index;
      _resumeEpisodePath = resumePath;
      _resumePosition = progress.position > Duration.zero
          ? progress.position
          : null;
    } catch (_) {}
  }

  bool _hasExplicitResumeTarget() {
    final resumePath = MediaPath.normalize(_resumeEpisodePath);
    if (resumePath.isNotEmpty) {
      return true;
    }
    return _resumePosition != null && _resumePosition! > Duration.zero;
  }

  Future<bool> _handleMissingInitialEpisode({
    required String folder,
    required _InitialEpisodeSource source,
    required String targetPath,
  }) async {
    if (source == _InitialEpisodeSource.storedResume) {
      await _progressStorage.clearProgress(folder);
      _resumeEpisodePath = null;
      _resumePosition = null;
      return true;
    }

    _blockPlaybackOnOpen = true;
    _resumeEpisodePath = null;
    _resumePosition = null;
    Get.snackbar('提示', '目标视频不存在，请刷新记录后重试');
    return false;
  }

  List<Episode> _buildEpisodesFromEntries(List<WebdavFileEntry> entries) {
    final parsed = <Episode>[];
    for (final entry in entries) {
      if (!_isPlayableVideo(entry)) continue;
      final url = _resolveEntryStreamUrl(entry);
      if (url.isEmpty) continue;
      final index = parsed.length;
      parsed.add(
        Episode(
          title: entry.name,
          subTitle: '第 ${index + 1} 集',
          path: entry.path,
          url: url,
        ),
      );
    }
    return parsed;
  }

  bool _isPlayableVideo(WebdavFileEntry entry) {
    if (entry.isDir) return false;
    final lower = entry.name.trim().toLowerCase();
    return _videoExtensions.any(lower.endsWith);
  }

  String _resolveEntryStreamUrl(WebdavFileEntry entry, {String? mode}) {
    return _applyPlaybackProxyModeToUrl(
      entry.resolveStreamUrl(applicationType: _applicationType),
      mode: mode,
    );
  }

  void _syncInitialIndexWithResumePath() {
    final resumePath = MediaPath.normalize(_resumeEpisodePath);
    if (resumePath.isEmpty) return;
    final index = _episodeIndexByPath(resumePath);
    if (index >= 0) {
      _initialIndex = index;
    }
  }

  int _episodeIndexByPath(String path) {
    final normalized = MediaPath.normalize(path);
    if (normalized.isEmpty) return -1;
    for (var i = 0; i < episodes.length; i++) {
      if (MediaPath.equals(episodes[i].path, normalized)) {
        return i;
      }
    }
    return -1;
  }

  bool _shouldSkipDuplicateOpen(int index, String? episodePath, String url) {
    final normalizedPath = MediaPath.normalize(episodePath);
    final hasPath = normalizedPath.isNotEmpty;
    final sameCurrentPath =
        hasPath && MediaPath.equals(_currentEpisodePath, normalizedPath);
    final sameOpeningPath =
        hasPath && MediaPath.equals(_openingEpisodePath, normalizedPath);
    final sameCurrentUrl =
        !hasPath && _currentEpisodeUrl == url && currentIndex.value == index;
    final sameOpeningUrl = !hasPath && _openingEpisodeUrl == url;
    return sameCurrentPath ||
        sameOpeningPath ||
        sameCurrentUrl ||
        sameOpeningUrl;
  }

  void _tryApplyPendingSeek() {
    final seek = _pendingSeek;
    if (seek == null) return;
    final duration = player.state.duration;
    if (duration <= Duration.zero) return;
    _pendingSeek = null;
    final target = seek > duration ? duration : seek;
    unawaited(player.seek(target));
  }

  void _syncSelectedAudioTrack(AudioTrack track) {
    if (track.id == 'auto' &&
        availableAudioTracks.isEmpty &&
        currentAudioTrack.value == null) {
      return;
    }
    currentAudioTrack.value = _findMatchingAudioTrack(track) ?? track;
  }

  void _syncAvailableAudioTracks(List<AudioTrack> tracks) {
    availableAudioTracks.assignAll(_dedupeAudioTracks(tracks));
    final selected = currentAudioTrack.value;
    if (selected != null) {
      currentAudioTrack.value = _findMatchingAudioTrack(selected) ?? selected;
    }
  }

  void _syncSelectedSubtitleTrack(SubtitleTrack track) {
    if (track.id == 'auto' &&
        availableSubtitleTracks.isEmpty &&
        externalSubtitleTracks.isEmpty &&
        currentSubtitleTrack.value == null) {
      return;
    }
    currentSubtitleTrack.value = _findMatchingSubtitleTrack(track) ?? track;
  }

  void _syncAvailableSubtitleTracks(List<SubtitleTrack> tracks) {
    availableSubtitleTracks.assignAll(_dedupeSubtitleTracks(tracks));
    final selected = currentSubtitleTrack.value;
    if (selected != null) {
      currentSubtitleTrack.value =
          _findMatchingSubtitleTrack(selected) ?? selected;
    }
  }

  AudioTrack? _findMatchingAudioTrack(AudioTrack track) {
    for (final item in availableAudioTracks) {
      if (item == track) return item;
      if (item.id == track.id && item.uri == track.uri) return item;
    }
    return null;
  }

  SubtitleTrack? _findMatchingSubtitleTrack(SubtitleTrack track) {
    for (final item in subtitleTrackOptions) {
      if (item == track) return item;
      if (item.id == track.id &&
          item.uri == track.uri &&
          item.data == track.data) {
        return item;
      }
    }
    return null;
  }

  List<AudioTrack> _dedupeAudioTracks(List<AudioTrack> tracks) {
    final result = <AudioTrack>[];
    final seen = <String>{};
    for (final track in tracks) {
      final key = '${track.uri ? 'uri' : 'id'}:${track.id}';
      if (!seen.add(key)) continue;
      result.add(track);
    }
    return result;
  }

  List<SubtitleTrack> _dedupeSubtitleTracks(List<SubtitleTrack> tracks) {
    final result = <SubtitleTrack>[];
    final seen = <String>{};
    for (final track in tracks) {
      final key =
          '${track.uri
              ? 'uri'
              : track.data
              ? 'data'
              : 'id'}:${track.id}';
      if (!seen.add(key)) continue;
      result.add(track);
    }
    return result;
  }

  void _resetAudioTrackState() {
    availableAudioTracks.clear();
    currentAudioTrack.value = null;
  }

  void _resetSubtitleTrackState({bool clearExternalOptions = false}) {
    availableSubtitleTracks.clear();
    currentSubtitleTrack.value = null;
    if (clearExternalOptions) {
      externalSubtitleTracks.clear();
    }
  }

  void _handlePositionUpdate(Duration position) {
    final folder = _folderPath;
    final episodePath = _currentEpisodePath;
    if (folder == null || episodePath == null) return;

    final pending = _pendingSeek;
    if (pending != null && position < pending) return;

    if (!_outroSkipTriggered &&
        skipOutro.value > Duration.zero &&
        player.state.playing &&
        !isScrubbing.value) {
      final duration = player.state.duration;
      if (duration > Duration.zero) {
        final remaining = duration - position;
        if (remaining <= skipOutro.value) {
          _outroSkipTriggered = true;
          unawaited(onVideoEnd());
          return;
        }
      }
    }

    final last = _lastPersistedPosition;
    if (last != null && (position - last).abs() < const Duration(seconds: 5)) {
      return;
    }
    _lastPersistedPosition = position;
    final currentEpisode = _currentEpisode;
    final currentTitle = (currentEpisode?.title ?? '').trim();
    final title = currentTitle.isNotEmpty
        ? currentTitle
        : _titleFromPath(episodePath);
    unawaited(
      _progressStorage.saveProgress(
        folderPath: folder,
        itemTitle: title,
        itemPath: episodePath,
        position: position,
      ),
    );
  }

  void _startCastProgressPolling() {
    _castProgressTimer?.cancel();
    _castProgressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_persistCastProgressSnapshot());
    });
  }

  void _stopCastProgressPolling() {
    _castProgressTimer?.cancel();
    _castProgressTimer = null;
  }

  Future<void> _persistCastProgressSnapshot() async {
    if (!isCasting) return;
    final folder = _folderPath;
    final episodePath = _currentEpisodePath;
    if (folder == null || folder.isEmpty) return;
    if (episodePath == null || episodePath.isEmpty) return;

    final position = await _castService.currentPosition();
    if (position == null || position < Duration.zero) return;

    final last = _lastCastPersistedPosition;
    if (last != null && (position - last).abs() < const Duration(seconds: 5)) {
      return;
    }
    _lastCastPersistedPosition = position;

    final currentEpisode = _currentEpisode;
    final currentTitle = (currentEpisode?.title ?? '').trim();
    final title = currentTitle.isNotEmpty
        ? currentTitle
        : _titleFromPath(episodePath);
    await _progressStorage.saveProgress(
      folderPath: folder,
      itemTitle: title,
      itemPath: episodePath,
      position: position,
    );
  }

  Future<void> _loadGlobalPlaybackProxyMode() async {
    try {
      final config = await _configApi.findConfigByKey(
        _webProxyModeKey,
        showErrorToast: false,
      );
      globalPlaybackProxyMode.value = _normalizePlaybackProxyMode(
        config?.value ?? _defaultPlaybackProxyMode,
      );
    } catch (_) {
      globalPlaybackProxyMode.value = _defaultPlaybackProxyMode;
    }
  }

  Future<void> _loadPlayerPreferences() async {
    try {
      final mode = await _playerPreferencesStorage.readProxyMode();
      if (mode != null) {
        _preferredPlaybackProxyMode = _normalizePlaybackProxyMode(mode);
      }
      final savedDecodeMode = await _playerPreferencesStorage.readDecodeMode();
      if (savedDecodeMode != null) {
        decodeMode.value = _normalizeDecodeMode(savedDecodeMode);
      }
      final rate = await _playerPreferencesStorage.readPlaybackRate();
      if (rate != null) {
        _preferredPlaybackRate = rate;
      }
    } catch (_) {}
  }

  Future<void> _ensureGlobalPlaybackProxyModeLoaded() async {
    await (_globalPlaybackProxyModeFuture ?? Future<void>.value());
    await (_playerPreferencesFuture ?? Future<void>.value());
  }

  Future<void> _restartCurrentEpisode() async {
    if (episodes.isEmpty) return;
    final index = currentIndex.value;
    if (index < 0 || index >= episodes.length) return;

    final wasPlaying = player.state.playing;
    final position = player.state.position;
    final subtitleTrack = currentSubtitleTrack.value;
    await playAt(
      index,
      forceReopen: true,
      startPosition: position,
      clearResume: true,
      subtitleTrackOverride: subtitleTrack,
    );
    if (!wasPlaying) {
      try {
        await player.pause();
      } catch (_) {}
    }
  }

  bool _supportsPlaybackProxyMode(Episode episode) {
    final path = episode.path?.trim();
    if (path != null && path.isNotEmpty) return true;
    final url = episode.url?.trim();
    if (url == null || url.isEmpty) return false;
    return _isLocalProxyStreamUrl(url);
  }

  String? _buildStreamUrl(
    String path, {
    String? applicationType,
    String? mode,
  }) {
    final base = Uri.parse(AppEnv.instance.apiBaseUrl);
    final streamPath = _joinPath(
      base.path,
      'public/quarkFs/${applicationType ?? _applicationType}/files/stream',
    );
    final normalizedMode = mode == null || mode.trim().isEmpty
        ? null
        : _normalizePlaybackProxyMode(mode);
    final accessToken = _currentAccessToken();
    return base
        .replace(
          path: streamPath,
          queryParameters: <String, String>{
            'path': path,
            ...?accessToken == null
                ? null
                : <String, String>{'access_token': accessToken},
            ...?normalizedMode == null
                ? null
                : <String, String>{'mode': normalizedMode},
          },
        )
        .toString();
  }

  String _normalizePlaybackProxyMode(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'redirect':
      case '302':
      case '302_redirect':
      case 'direct':
        return '302_redirect';
      default:
        return _defaultPlaybackProxyMode;
    }
  }

  bool _isLocalProxyStreamUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return false;
    final normalizedPath = uri.path.replaceAll('\\', '/').trim();
    return (normalizedPath.contains('/public/quarkFs/') ||
            normalizedPath.contains('/quarkFs/')) &&
        normalizedPath.endsWith('/files/stream');
  }

  String _applyPlaybackProxyModeToUrl(String rawUrl, {String? mode}) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !_isLocalProxyStreamUrl(rawUrl)) return rawUrl;

    final nextQuery = <String, String>{...uri.queryParameters};
    final normalizedMode = mode == null || mode.trim().isEmpty
        ? null
        : _normalizePlaybackProxyMode(mode);
    final accessToken = _currentAccessToken();
    if (accessToken == null) {
      nextQuery.remove('access_token');
    } else {
      nextQuery['access_token'] = accessToken;
    }
    if (normalizedMode == null) {
      nextQuery.remove('mode');
    } else {
      nextQuery['mode'] = normalizedMode;
    }
    return uri.replace(queryParameters: nextQuery).toString();
  }

  String? _currentAccessToken() {
    final token = _authService.accessToken.value?.trim() ?? '';
    if (token.isEmpty) return null;
    return token;
  }

  static String _joinPath(String basePath, String child) {
    final bp = basePath.trim().isEmpty ? '' : basePath;
    if (bp.isEmpty) return '/$child';
    if (bp.endsWith('/')) return '$bp$child';
    return '$bp/$child';
  }

  static String _titleFromPath(String path) {
    final normalized = path.replaceAll('\\', '/').trim();
    if (normalized.isEmpty) return '';
    final parts = normalized
        .split('/')
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return normalized;
    return parts.last;
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String _audioLanguageLabel(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    switch (normalized) {
      case 'zh':
      case 'zh-cn':
      case 'zh-hans':
      case 'zho':
      case 'chi':
      case 'cmn':
        return '中文';
      case 'zh-hk':
      case 'zh-tw':
      case 'zh-hant':
        return '中文（繁体）';
      case 'yue':
      case 'zh-yue':
        return '粤语';
      case 'en':
      case 'eng':
        return '英语';
      case 'ja':
      case 'jpn':
        return '日语';
      case 'ko':
      case 'kor':
        return '韩语';
      case 'fr':
      case 'fra':
      case 'fre':
        return '法语';
      case 'de':
      case 'deu':
      case 'ger':
        return '德语';
      case 'es':
      case 'spa':
        return '西班牙语';
      default:
        return raw?.trim() ?? '';
    }
  }

  static String _subtitleLanguageLabel(String? raw) {
    return _audioLanguageLabel(raw);
  }

  Future<List<WebdavFileEntry>> _ensureFolderEntriesLoaded() async {
    final folder = _folderPath;
    if (folder == null || folder.trim().isEmpty) {
      _folderEntries = const <WebdavFileEntry>[];
      return _folderEntries;
    }
    if (_folderEntries.isNotEmpty) {
      return _folderEntries;
    }
    try {
      final files = await _webdavApi.fetchFileList(
        applicationType: _applicationType,
        path: folder,
      );
      _folderEntries = List<WebdavFileEntry>.unmodifiable(files);
    } catch (_) {
      _folderEntries = const <WebdavFileEntry>[];
    }
    return _folderEntries;
  }

  Future<SubtitleTrack?> _resolveSubtitleTrackForEpisode(
    Episode episode, {
    SubtitleTrack? explicitTrack,
  }) async {
    final candidates = await _buildExternalSubtitleCandidates(episode);
    externalSubtitleTracks.assignAll(
      candidates.map((candidate) => candidate.track).toList(growable: false),
    );

    if (explicitTrack != null) {
      if (explicitTrack.id == SubtitleTrack.auto().id) {
        return null;
      }
      return explicitTrack;
    }

    if (candidates.isEmpty) return null;
    final best = candidates.first;
    if (best.score < 900) return null;
    return best.track;
  }

  Future<List<_ExternalSubtitleCandidate>> _buildExternalSubtitleCandidates(
    Episode episode,
  ) async {
    final entries = await _ensureFolderEntriesLoaded();
    if (entries.isEmpty) return const <_ExternalSubtitleCandidate>[];

    final subtitleEntries = entries
        .where(_isSubtitleEntry)
        .toList(growable: false);
    if (subtitleEntries.isEmpty) {
      return const <_ExternalSubtitleCandidate>[];
    }

    final episodeTitle = _titleFromPath(episode.path ?? episode.title);
    final episodeBase = _baseNameWithoutExtension(episodeTitle);
    final candidates = subtitleEntries
        .map((entry) {
          final score = _subtitleMatchScore(
            episodeBase,
            _baseNameWithoutExtension(entry.name),
          );
          return _ExternalSubtitleCandidate(
            track: SubtitleTrack.uri(
              _resolveEntryStreamUrl(entry),
              title: entry.name,
              language: _guessSubtitleLanguage(entry.name),
            ),
            score: score,
          );
        })
        .toList(growable: false);

    candidates.sort((left, right) {
      final scoreCompare = right.score.compareTo(left.score);
      if (scoreCompare != 0) return scoreCompare;
      return (left.track.title ?? '').toLowerCase().compareTo(
        (right.track.title ?? '').toLowerCase(),
      );
    });
    return candidates;
  }

  bool _isSubtitleEntry(WebdavFileEntry entry) {
    if (entry.isDir) return false;
    final lower = entry.name.trim().toLowerCase();
    return _subtitleExtensions.any(lower.endsWith);
  }

  static int _subtitleMatchScore(String episodeBase, String subtitleBase) {
    final episode = _normalizeSubtitleMatchKey(episodeBase);
    final subtitle = _normalizeSubtitleMatchKey(subtitleBase);
    if (episode.isEmpty || subtitle.isEmpty) return 0;
    if (subtitle == episode) return 1000;
    if (subtitle.startsWith(episode)) return 920;
    if (subtitle.contains(episode)) return 760;
    return 0;
  }

  static String _normalizeSubtitleMatchKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9一-鿿]+'), '');
  }

  static String _baseNameWithoutExtension(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0) return trimmed;
    return trimmed.substring(0, dot);
  }

  static String _extensionFromPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final dot = trimmed.lastIndexOf('.');
    if (dot < 0 || dot == trimmed.length - 1) return '';
    return trimmed.substring(dot + 1);
  }

  static String _guessSubtitleLanguage(String fileName) {
    final lower = fileName.trim().toLowerCase();
    if (lower.contains('.zh') ||
        lower.contains('.chs') ||
        lower.contains('.cht') ||
        lower.contains('.chi') ||
        lower.contains('.cn')) {
      return 'zh';
    }
    if (lower.contains('.en') ||
        lower.contains('.eng') ||
        lower.contains('.us')) {
      return 'en';
    }
    if (lower.contains('.ja') || lower.contains('.jpn')) {
      return 'ja';
    }
    if (lower.contains('.ko') || lower.contains('.kor')) {
      return 'ko';
    }
    return '';
  }

  static const List<String> _videoExtensions = <String>[
    '.mp4',
    '.mkv',
    '.mov',
    '.m4v',
    '.avi',
    '.wmv',
    '.flv',
    '.webm',
  ];
  static const List<String> _subtitleExtensions = <String>[
    '.srt',
    '.ass',
    '.ssa',
    '.vtt',
    '.sub',
  ];
  static const String _webProxyModeKey = 'quark_fs_web_proxy_mode';
  static const String _defaultPlaybackProxyMode = 'native_proxy';

  @override
  void onClose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    _completedSubscription?.cancel();
    _errorSubscription?.cancel();
    _rateSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _videoParamsSubscription?.cancel();
    _trackSubscription?.cancel();
    _tracksSubscription?.cancel();
    _scrubTimer?.cancel();
    _castProgressTimer?.cancel();
    _voFallbackTimer?.cancel();
    unawaited(_audioSession.dispose());
    player.dispose();
    unawaited(WakelockPlus.disable());
    super.onClose();
  }
}

class _ExternalSubtitleCandidate {
  const _ExternalSubtitleCandidate({required this.track, required this.score});

  final SubtitleTrack track;
  final int score;
}

class Episode {
  Episode({required this.title, required this.subTitle, this.path, this.url});

  final String title;
  final String subTitle;
  final String? path;
  final String? url;
}
