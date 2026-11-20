import 'dart:convert' show utf8;
import 'dart:io';

class AndroidRecords {
  AndroidRecords._();

  static String read(Directory directory, int limit) {
    if (!Platform.isAndroid) return '';
    try {
      final file = File('${directory.path}${Platform.pathSeparator}android-records.txt');
      if (!file.existsSync()) return '';
      final text = utf8.decode(file.readAsBytesSync(), allowMalformed: true).trimRight();
      return text.length > limit ? '${text.substring(0, limit)}...' : text;
    } catch (_) {
      return '';
    }
  }
}
