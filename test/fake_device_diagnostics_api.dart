import 'package:site_lens/web_host/web_host.g.dart';

class FakeDeviceDiagnosticsApi extends DeviceDiagnosticsApi {
  int reads = 0;
  int codecReads = 0;
  bool fail = false;
  int apiLevel = 36;
  List<CapabilityRecord> rows = [];
  List<CodecDescriptor>? codecs;

  @override
  Future<DeviceDiagnosticsSnapshot> readSnapshot() async {
    reads++;
    if (fail) throw StateError('unavailable');
    return DeviceDiagnosticsSnapshot(
      platform: 'Android',
      osVersion: '16',
      apiLevel: apiLevel,
      appVersion: 'test',
      capturedAtMs: 1000,
      capabilities: rows,
    );
  }

  @override
  Future<List<CodecDescriptor>> readCodecInventory() async {
    codecReads++;
    if (fail) throw StateError('unavailable');
    return codecs ??
        [
          CodecDescriptor(
            name: 'test.codec',
            mimeType: 'video/avc',
            encoder: false,
          ),
        ];
  }
}
