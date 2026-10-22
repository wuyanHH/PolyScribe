import 'dart:math';
import 'dart:typed_data';

/// 实名声纹库实体 (对应 SQLite voice_prints 表)
class VoicePrint {
  final String id;
  final String personName;
  final Float32List embedding; // 192 或 512 维特征向量
  final int sampleCount;
  final int createdAt;
  final int updatedAt;

  const VoicePrint({
    required this.id,
    required this.personName,
    required this.embedding,
    this.sampleCount = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 与另一声纹向量计算余弦相似度 (Cosine Similarity)
  /// 返回值范围 [-1.0, 1.0]，通常大于 0.65 判定为同一说话人
  double cosineSimilarity(Float32List other) {
    if (embedding.length != other.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < embedding.length; i++) {
      final a = embedding[i];
      final b = other[i];
      dotProduct += a * b;
      normA += a * a;
      normB += b * b;
    }

    if (normA <= 0.0 || normB <= 0.0) return 0.0;
    return dotProduct / (sqrt(normA) * sqrt(normB));
  }

  /// 指数移动平均 (EMA) 更新声纹质心向量:
  /// C_new = alpha * C_old + (1 - alpha) * V_new
  VoicePrint updatedWithEmbedding(Float32List newVector, {double alpha = 0.8}) {
    if (embedding.length != newVector.length) return this;

    final updated = Float32List(embedding.length);
    for (int i = 0; i < embedding.length; i++) {
      updated[i] = (alpha * embedding[i]) + ((1.0 - alpha) * newVector[i]);
    }

    return VoicePrint(
      id: id,
      personName: personName,
      embedding: updated,
      sampleCount: sampleCount + 1,
      createdAt: createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 序列化为 SQLite 存储格式
  Map<String, dynamic> toMap() => {
    'id': id,
    'person_name': personName,
    'embedding': embedding.buffer.asUint8List(),
    'sample_count': sampleCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  /// 从 SQLite 记录反序列化
  factory VoicePrint.fromMap(Map<String, dynamic> map) {
    final rawBytes = map['embedding'] as Uint8List;
    final float32List = Float32List.view(
      rawBytes.buffer,
      rawBytes.offsetInBytes,
      rawBytes.lengthInBytes ~/ 4,
    );

    return VoicePrint(
      id: map['id'] as String,
      personName: map['person_name'] as String,
      embedding: float32List,
      sampleCount: (map['sample_count'] as num?)?.toInt() ?? 1,
      createdAt: (map['created_at'] as num).toInt(),
      updatedAt: (map['updated_at'] as num).toInt(),
    );
  }
}
