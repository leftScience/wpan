import 'dart:async';

import 'package:audio_session/audio_session.dart';

enum PlaybackAudioProfile { media, speech }

class PlaybackAudioSession {
  PlaybackAudioSession({
    required Future<void> Function() onPauseRequested,
    required bool Function() isPlaying,
  }) : _onPauseRequested = onPauseRequested,
       _isPlaying = isPlaying;

  final Future<void> Function() _onPauseRequested;
  final bool Function() _isPlaying;

  AudioSession? _session;
  Future<void>? _initialization;
  PlaybackAudioProfile? _configuredProfile;
  bool _isActive = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  Future<void> initialize() {
    return _initialization ??= _initializeInternal();
  }

  Future<bool> activate(PlaybackAudioProfile profile) async {
    final session = await _ensureSession();
    final configuration = _configurationFor(profile);
    if (_configuredProfile != profile || !session.isConfigured) {
      await session.configure(configuration);
      _configuredProfile = profile;
    }
    try {
      final acquired = await session.setActive(
        true,
        fallbackConfiguration: configuration,
      );
      _isActive = acquired;
      return acquired;
    } catch (_) {
      // On iOS lock-screen track transitions, keep playback going if the audio
      // session was already active for this profile instead of tearing it down.
      if (_isActive && _configuredProfile == profile) {
        return true;
      }
      rethrow;
    }
  }

  Future<void> deactivate() async {
    _isActive = false;
    final session = _session;
    if (session == null) return;
    try {
      await session.setActive(false);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await deactivate();
  }

  Future<void> _initializeInternal() async {
    final session = await AudioSession.instance;
    _session = session;
    _interruptionSubscription = session.interruptionEventStream.listen(
      _handleInterruption,
    );
    _becomingNoisySubscription = session.becomingNoisyEventStream.listen(
      _handleBecomingNoisy,
    );
  }

  Future<AudioSession> _ensureSession() async {
    await initialize();
    return _session!;
  }

  AudioSessionConfiguration _configurationFor(PlaybackAudioProfile profile) {
    switch (profile) {
      case PlaybackAudioProfile.speech:
        return const AudioSessionConfiguration.speech().copyWith(
          androidWillPauseWhenDucked: false,
        );
      case PlaybackAudioProfile.media:
        return const AudioSessionConfiguration.music().copyWith(
          androidWillPauseWhenDucked: false,
        );
    }
  }

  void _handleInterruption(AudioInterruptionEvent event) {
    if (!event.begin || !_isPlaying()) return;
    if (event.type == AudioInterruptionType.duck) return;
    _isActive = false;
    unawaited(_onPauseRequested());
  }

  void _handleBecomingNoisy(void _) {
    if (!_isPlaying()) return;
    unawaited(_onPauseRequested());
  }
}
