class YoutubeDownloadHelp {
  static String bytesToString(int bytes) {
    final totalKiloBytes = bytes / 1024;
    final totalMegaBytes = totalKiloBytes / 1024;
    final totalGigaBytes = totalMegaBytes / 1024;

    String getLargestSymbol() {
      if (totalGigaBytes.abs() >= 1) {
        return 'GB';
      }
      if (totalMegaBytes.abs() >= 1) {
        return 'MB';
      }
      if (totalKiloBytes.abs() >= 1) {
        return 'KB';
      }
      return 'B';
    }

    num getLargestValue() {
      if (totalGigaBytes.abs() >= 1) {
        return totalGigaBytes;
      }
      if (totalMegaBytes.abs() >= 1) {
        return totalMegaBytes;
      }
      if (totalKiloBytes.abs() >= 1) {
        return totalKiloBytes;
      }
      return bytes;
    }

    return '${getLargestValue().toStringAsFixed(2)} ${getLargestSymbol()}';
  }
}
