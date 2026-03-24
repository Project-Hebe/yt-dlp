# yt-dlp-dart

A YouTube downloader library written in Dart, inspired by [yt-dlp](https://github.com/yt-dlp/yt-dlp).

## Features

- Extract video information (title, description, duration, etc.)
- Download videos in various formats
- Format selection (best quality, specific format, max height, etc.)
- Progress tracking during download
- Resume interrupted downloads

## Installation

Add this to your `pubspec.yaml`:

```yaml
dependencies:
  yt_dlp_dart:
    path: ./dart_yt_dlp
```

Or if published to pub.dev:

```yaml
dependencies:
  yt_dlp_dart: ^1.0.0
```

## Usage

### Basic Example

```dart
import 'package:yt_dlp/yt_dlp.dart';

void main() async {
  final ytDlp = YtDlp();
  
  try {
    // Extract video information
    final videoInfo = await ytDlp.extractInfo('https://www.youtube.com/watch?v=VIDEO_ID');
    print('Title: ${videoInfo.title}');
    print('Duration: ${videoInfo.duration} seconds');
    
    // Download video
    await ytDlp.download(
      'https://www.youtube.com/watch?v=VIDEO_ID',
      onProgress: ({required downloadedBytes, totalBytes, required progress, speed}) {
        print('Progress: $progress%');
      },
    );
  } finally {
    ytDlp.dispose();
  }
}
```

### Extract Information Only

```dart
final ytDlp = YtDlp();
final videoInfo = await ytDlp.extractInfo(url);

print('Title: ${videoInfo.title}');
print('Description: ${videoInfo.description}');
print('Uploader: ${videoInfo.uploader}');
print('View Count: ${videoInfo.viewCount}');
```

### List Available Formats

```dart
final formats = await ytDlp.listFormats(url);
for (var format in formats) {
  print('Format ${format.formatId}: ${format.height}p, ${format.ext}');
}
```

### Download with Specific Format

```dart
// Download best format with max height 720p
await ytDlp.download(
  url,
  maxHeight: 720,
);

// Download specific format by ID
await ytDlp.download(
  url,
  formatId: 18, // mp4 360p
);

// Download with preferred extension
await ytDlp.download(
  url,
  preferredExtension: 'mp4',
);
```

### Download with Progress Tracking

```dart
await ytDlp.download(
  url,
  onProgress: ({
    required downloadedBytes,
    totalBytes,
    required progress,
    speed,
  }) {
    final downloadedMB = (downloadedBytes / (1024 * 1024)).toStringAsFixed(2);
    final totalMB = totalBytes != null
        ? (totalBytes / (1024 * 1024)).toStringAsFixed(2)
        : '?';
    final speedMB = speed != null
        ? (speed / (1024 * 1024)).toStringAsFixed(2)
        : '?';
    
    print('Downloaded: $downloadedMB / $totalMB MB');
    print('Progress: ${progress.toStringAsFixed(1)}%');
    print('Speed: $speedMB MB/s');
  },
);
```

## API Reference

### YtDlp Class

#### Methods

- `Future<VideoInfo> extractInfo(String url)` - Extract video information
- `Future<void> download(String url, {...})` - Download video
- `Future<List<VideoFormat>> listFormats(String url)` - List available formats
- `Future<Map<String, dynamic>> extractInfoJson(String url)` - Get info as JSON
- `void dispose()` - Clean up resources

#### Download Options

- `outputPath` - Output file path
- `format` - Specific VideoFormat to download
- `formatId` - Format ID to download
- `maxHeight` - Maximum video height in pixels
- `preferredExtension` - Preferred file extension (mp4, webm, etc.)
- `onProgress` - Progress callback

### VideoInfo Model

Contains video metadata:
- `id` - Video ID
- `title` - Video title
- `description` - Video description
- `duration` - Duration in seconds
- `uploader` - Uploader name
- `viewCount` - View count
- `formats` - List of available formats
- And more...

### VideoFormat Model

Represents a video format:
- `formatId` - Format ID
- `url` - Download URL
- `ext` - File extension
- `width`, `height` - Video dimensions
- `fps` - Frames per second
- `vcodec`, `acodec` - Video/audio codec
- `filesize` - File size in bytes
- `tbr` - Total bitrate

## Limitations

This is a simplified implementation compared to the full yt-dlp. Some features not yet implemented:

- Playlist support
- Subtitle downloading
- Audio extraction
- Post-processing (format conversion, etc.)
- HLS/DASH streaming support
- Age-restricted video handling
- Private video support

## License

This project is inspired by yt-dlp and follows similar principles. Please refer to the original yt-dlp license for reference.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

