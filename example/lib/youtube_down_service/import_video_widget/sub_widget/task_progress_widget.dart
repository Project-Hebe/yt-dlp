import 'package:flutter/material.dart';
import '../../task_entity/single_track_entity.dart';

String _statusLabel(DownloadStatus s) {
  switch (s) {
    case DownloadStatus.querying:
      return '正在获取视频信息';
    case DownloadStatus.downloading:
      return '下载中';
    case DownloadStatus.success:
      return '下载完成';
    case DownloadStatus.failed:
      return '失败';
    case DownloadStatus.muxing:
      return '混流中';
    case DownloadStatus.canceled:
      return '已取消';
    case DownloadStatus.paused:
      return '已暂停';
    case DownloadStatus.waiting:
      return '排队等待';
    case DownloadStatus.exporting:
      return '导出音频中';
    case DownloadStatus.retrying:
      return '重试中';
    case DownloadStatus.uploading:
      return '上传中';
    case DownloadStatus.uploaded:
      return '已上传';
  }
}

/// 单条下载任务的进度与操作（监听 [SingleTrack] 更新）。
class TaskProgressWidget extends StatelessWidget {
  const TaskProgressWidget({
    super.key,
    required this.track,
    required this.onRemove,
    required this.onRetry,
    required this.onResume,
    required this.onExport,
  });

  final SingleTrack track;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  final VoidCallback onResume;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = track.downloadStatus;
    final perc = track.downloadPerc.clamp(0, 100);
    final indeterminate = status == DownloadStatus.querying ||
        status == DownloadStatus.muxing ||
        status == DownloadStatus.retrying;

    final showCancel = status == DownloadStatus.downloading ||
        status == DownloadStatus.querying ||
        status == DownloadStatus.waiting;
    final showRetry = status == DownloadStatus.failed || status == DownloadStatus.paused;
    final showResume = status == DownloadStatus.paused;
    final showExport = status == DownloadStatus.success &&
        (track.exportedAudioPath == null || track.exportedAudioPath!.isEmpty);

    String bytesLine() {
      if (track.totalSize <= 0) return '';
      final d = track.downloadedBytes;
      final t = track.totalSize;
      return '${_fmtBytes(d)} / ${_fmtBytes(t)}';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${track.videoId} · ${_statusLabel(status)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (track.language.isNotEmpty)
                        Text(
                          '语言: ${track.language}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '移除',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (indeterminate)
              const LinearProgressIndicator()
            else
              LinearProgressIndicator(value: perc / 100.0),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  indeterminate ? '…' : '$perc%',
                  style: theme.textTheme.labelMedium,
                ),
                if (bytesLine().isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Text(
                    bytesLine(),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            if (track.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  track.error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (showCancel)
                  OutlinedButton(
                    onPressed: track.cancelDownload,
                    child: const Text('取消'),
                  ),
                if (showResume)
                  FilledButton.tonal(
                    onPressed: onResume,
                    child: const Text('继续'),
                  ),
                if (showRetry)
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text('重试'),
                  ),
                if (showExport)
                  FilledButton.tonal(
                    onPressed: onExport,
                    child: const Text('导出音频'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtBytes(int n) {
  if (n < 1024) return '$n B';
  final kb = n / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(2)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}
