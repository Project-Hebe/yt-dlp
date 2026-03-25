// Example app that uses only DownloadManager (no direct YtDlp calls).
//
// Run (from this `example` directory):
//   flutter pub get
//   flutter run -d macos
//   flutter run -d linux
//   flutter run -d chrome
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_proxy/http_proxy.dart';
import 'package:yt_dlp_dart/yt_dlp.dart';

import 'youtube_down_service/download_providers.dart';
import 'youtube_down_service/import_video_widget/import_video_widget.dart';
import 'youtube_down_service/preferences_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional: keep existing proxy behavior (also affects yt_dlp_dart internals).
  final httpProxy = await HttpProxy.createHttpProxy();
  HttpOverrides.global = httpProxy;

  await PreferencesService().init();

  runApp(
    const ProviderScope(
      child: YtDlpExampleApp(),
    ),
  );
}

class YtDlpExampleApp extends StatelessWidget {
  const YtDlpExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'yt_dlp_dart example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ExampleHomePage(),
    );
  }
}

class ExampleHomePage extends ConsumerStatefulWidget {
  const ExampleHomePage({super.key});

  @override
  ConsumerState<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends ConsumerState<ExampleHomePage> {
  static const _defaultUrl =
      'https://www.youtube.com/watch?v=jNQXAC9IVRw';

  final _urlController = TextEditingController(text: _defaultUrl);
  final _langController = TextEditingController();

  String _log = '';
  bool _busy = false;

  @override
  void dispose() {
    _urlController.dispose();
    _langController.dispose();
    super.dispose();
  }

  String? _parseVideoId(String url) => YouTubeUrlParser.extractVideoId(url);

  Future<void> _extractViaManager() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final videoId = _parseVideoId(url);
    if (videoId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法从链接解析视频 ID')),
      );
      return;
    }

    setState(() {
      _busy = true;
      _log = '';
    });

    try {
      final manager = await ref.read(downloadProvider.future);
      final info = await manager.getVideoInfo(videoId);

      if (info == null) {
        if (!mounted) return;
        setState(() => _log = '未能获取视频信息: $videoId');
        return;
      }

      final buf = StringBuffer()
        ..writeln('Title: ${info.title ?? "(unknown)"}')
        ..writeln(
          'Duration: ${info.duration != null ? "${info.duration}s" : "n/a"}',
        )
        ..writeln('Formats: ${info.formats.length}')
        ..writeln('');

      for (final f in info.formats.take(12)) {
        final id = f.formatId ?? '?';
        final ext = f.ext ?? '?';
        final res = f.height != null
            ? '${f.height}p'
            : (f.tbr != null ? '${f.tbr} tbr' : (f.qualityLabel ?? ''));
        final urlOk = f.url != null && f.url!.isNotEmpty;

        buf.writeln(
          '  itag=$id  $ext  $res  ${urlOk ? "has URL" : "no URL"}',
        );
      }

      if (info.formats.length > 12) {
        buf.writeln('  ... and ${info.formats.length - 12} more');
      }

      if (mounted) setState(() => _log = buf.toString());
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _log = 'Error: $e\n$st');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadViaManager() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final videoId = _parseVideoId(url);
    if (videoId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法从链接解析视频 ID')),
      );
      return;
    }

    setState(() {
      _busy = true;
      _log = '正在加入下载队列...';
    });

    try {
      final lang = _langController.text.trim();
      final manager = await ref.read(downloadProvider.future);
      await manager.beginDownLoadVideo(videoId, lang);

      if (mounted) {
        setState(() => _log =
            '已加入队列: $videoId（进度在「下载队列」页查看）');
      }
    } catch (e, st) {
      if (!mounted) return;
      setState(() => _log = 'Error: $e\n$st');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _toolsTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'YouTube URL',
              border: OutlineInputBorder(),
            ),
            enabled: !_busy,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _langController,
            decoration: const InputDecoration(
              labelText: '音频语言（可选，如 en、zh，留空则默认）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            enabled: !_busy,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _extractViaManager,
                child: const Text('Extract info'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : _downloadViaManager,
                child: const Text('Download best format'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _log.isEmpty
                      ? '点击按钮：上方「下载队列」会显示查询 / 下载 / 导出等多状态进度。'
                      : _log,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('yt_dlp_dart example'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '工具', icon: Icon(Icons.build_outlined)),
              Tab(text: '下载队列', icon: Icon(Icons.download_outlined)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _toolsTab(),
            const Padding(
              padding: EdgeInsets.all(12),
              child: ImportVideoWidget(),
            ),
          ],
        ),
      ),
    );
  }
}

