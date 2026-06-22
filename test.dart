import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  var bytes = File('test.jpg').readAsBytesSync();
  var decoder = img.findDecoderForData(bytes);
  var info = decoder?.startDecode(bytes);
  print('${info?.width}x${info?.height}');
}
