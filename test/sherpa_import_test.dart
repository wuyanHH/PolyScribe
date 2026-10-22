import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main() {
  test('Sherpa-onnx package imports and types verification', () {
    expect(sherpa.OfflineRecognizer, isNotNull);
    expect(sherpa.VoiceActivityDetector, isNotNull);
    expect(sherpa.OfflineSpeakerDiarization, isNotNull);

    final featConfig = sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80);
    final senseVoice = sherpa.OfflineSenseVoiceModelConfig(
      model: 'model.onnx',
      language: 'auto',
      useInverseTextNormalization: true,
    );
    final modelConfig = sherpa.OfflineModelConfig(
      senseVoice: senseVoice,
      tokens: 'tokens.txt',
    );
    final recognizerConfig = sherpa.OfflineRecognizerConfig(
      feat: featConfig,
      model: modelConfig,
    );
    expect(recognizerConfig, isNotNull);
  });
}
