import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'youtube_download_manager.dart';

final downloadProvider = FutureProvider<DownloadManagerImpl>((ref) async {
  ref.keepAlive();
  return DownloadManagerImpl.init();
});
