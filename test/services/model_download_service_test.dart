import 'package:flutter_test/flutter_test.dart';
import 'package:polyscribe/engine/models/model_package_info.dart';
import 'package:polyscribe/services/model_download_service.dart';

void main() {
  group('ModelPackageInfo & PredefinedModels 模型包元数据测试', () {
    test('预定义模型清单完整性验证', () {
      expect(PredefinedModels.all.length, 4);

      final senseVoice = PredefinedModels.senseVoiceSmall;
      expect(senseVoice.id, 'sensevoice_small');
      expect(senseVoice.isArchive, true);
      expect(senseVoice.targetFileNames, contains('sensevoice_small_int8.onnx'));
      expect(senseVoice.targetFileNames, contains('tokens.txt'));

      final vad = PredefinedModels.sileroVad;
      expect(vad.id, 'silero_vad');
      expect(vad.isArchive, false);
      expect(vad.targetFileNames, contains('silero_vad.onnx'));
    });

    test('多镜像源 URL 映射解析验证', () {
      final senseVoice = PredefinedModels.senseVoiceSmall;
      final msUrl = senseVoice.getUrl(ModelDownloadSource.modelScope);
      final ghUrl = senseVoice.getUrl(ModelDownloadSource.github);

      expect(msUrl.contains('modelscope.cn'), true);
      expect(ghUrl.contains('github.com'), true);
    });

    test('ModelDownloadService 单例与版本检查测试', () async {
      final service = ModelDownloadService.instance;
      expect(service, isNotNull);

      final updates = await service.checkModelUpdates();
      expect(updates.containsKey('sensevoice_small'), true);
      expect(updates.containsKey('silero_vad'), true);
      expect(updates.containsKey('campp_plus'), true);
      expect(updates.containsKey('pyannote_segmentation'), true);
    });
  });
}
