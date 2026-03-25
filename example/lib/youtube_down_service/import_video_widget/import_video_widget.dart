import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../download_providers.dart';
import '../youtube_download_manager.dart';
import 'import_video_notice_widget.dart';
import 'sub_widget/task_progress_widget.dart';

/// 展示 [DownloadManagerImpl] 中所有任务的列表与进度（查询 / 下载 / 排队 / 导出等）。
class ImportVideoWidget extends ConsumerWidget {
  const ImportVideoWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(downloadProvider);

    return async.when(
      data: (DownloadManagerImpl manager) {
        return ListenableBuilder(
          listenable: manager,
          builder: (context, _) {
            final list = manager.videos;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ImportVideoNoticeWidget(
                  message: list.isEmpty
                      ? '暂无下载任务。在上方输入链接并选择「加入下载队列」。'
                      : '共 ${list.length} 个任务',
                ),
                Expanded(
                  child: list.isEmpty
                      ? Center(
                          child: Text(
                            '队列空',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 16),
                          itemCount: list.length,
                          itemBuilder: (context, index) {
                            final track = list[index];
                            return ListenableBuilder(
                              listenable: track,
                              builder: (context, _) {
                                return TaskProgressWidget(
                                  track: track,
                                  onRemove: () => manager.removeVideo(track),
                                  onRetry: () => manager.retryDownload(track),
                                  onResume: () => manager.resumeDownload(track),
                                  onExport: () => manager.exportTrack(track),
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            '下载管理器初始化失败:\n$e',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
    );
  }
}
