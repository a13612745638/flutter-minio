import 'dart:async';
import 'dart:io';

import 'package:MinioClient/utils/utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:minio/io.dart';
import 'package:minio/minio.dart';
import 'package:minio/models.dart';
import 'package:path/path.dart' show basename, dirname;
import 'package:path_provider/path_provider.dart';
// ignore: unused_import
import 'package:rxdart/rxdart.dart';

class Prefix {
  bool isPrefix;
  String key;
  String prefix;

  Prefix({this.key, this.prefix, this.isPrefix});
}

var minio;

class MinioController {
  Minio minio;
  String bucketName;
  String prefix;

  /// maximum object size (5TB)
  final maxObjectSize = 5 * 1024 * 1024 * 1024 * 1024;

  MinioController({this.bucketName, this.prefix}) {
    if (minio is Minio) {
      this.minio = minio;
    } else {
      minio = Minio(
        useSSL: false,
        endPoint: '49.232.194.85',
        port: 9001,
        accessKey: 'minio',
        secretKey: 'minio123',
        region: 'cn-north-1',
      );
      this.minio = minio;
    }
  }

  Future<List<IncompleteUpload>> listIncompleteUploads(
      {String bucketName}) async {
    print(bucketName ?? this.bucketName);
    final list = this
        .minio
        .listIncompleteUploads(bucketName ?? this.bucketName, '')
        .toList();
    return list;
  }

  Future<Map<dynamic, dynamic>> getBucketObjects(
      String bucketName, String prefix) async {
    final objects = this
        .minio
        .listObjectsV2(this.bucketName, prefix: this.prefix, recursive: false);
    final map = new Map();
    await for (var obj in objects) {
      final prefixs = obj.prefixes.map((e) {
        final index = e.lastIndexOf('/') + 1;
        final prefix = e.substring(0, index);
        final key = e;
        return Prefix(key: key, prefix: prefix, isPrefix: true);
      }).toList();

      map['prefixes'] = prefixs;
      map['objests'] = obj.objects;
    }
    return map;
  }

  Future<List<Bucket>> getListBuckets() async {
    return this.minio.listBuckets();
  }

  Future<bool> buckerExists(String bucket) async {
    return this.minio.bucketExists(bucket);
  }

  Future<void> downloadFile(filename) async {
    final dir = await getExternalStorageDirectory();
    minio
        .fGetObject(
            bucketName, prefix + filename, '${dir.path}/${prefix + filename}')
        .then((value) {});
  }

  Future<String> uploadFile() async {
    FilePickerResult result = await FilePicker.platform.pickFiles();
    if (result == null || result?.files == null || result?.files?.length == 0) {
      print('取消了上传');
      return 'cancel';
    }
    final file = result.files[0];
    return minio.fPutObject(this.bucketName, file.name, file.path);
  }

  Future<String> presignedGetObject(String filename, {int expires}) {
    return this
        .minio
        .presignedGetObject(this.bucketName, filename, expires: expires);
  }

  Future<String> getPreviewUrl(String filename) {
    return this.presignedGetObject(filename, expires: 60 * 60 * 24);
  }

  Future<void> removeFile(String filename) {
    return this.minio.removeObject(this.bucketName, filename);
  }

  Future<void> createBucket(String bucketName) {
    print(bucketName);
    return this.minio.makeBucket(bucketName);
  }

  Future<void> removeBucket(String bucketName) {
    return this.minio.removeBucket(bucketName);
  }

  Future<dynamic> getPartialObject(String bucketName, String filename,
      {String filePath,
      void onListen(int downloadSize, int fileSize),
      void onCompleted(int downloadSize, int fileSize),
      void onStart(StreamSubscription<List<int>> subscription)}) async {
    print('getPartialObject $filename');

    final stat = await this.minio.statObject(bucketName, filename);

    // 如果没设置文件路径则默认获取
    if (filePath == null) {
      filePath = await getDictionaryPath(filename: filename);
    }

    final dir = dirname(filePath);
    await Directory(dir).create(recursive: true);

    final partFileName = '$filePath.${stat.etag}.part.minio';
    final partFile = File(partFileName);
    IOSink partFileStream;
    var offset = 0;

    final rename = () => partFile.rename(filePath);

    if (await partFile.exists()) {
      final localStat = await partFile.stat();
      if (stat.size == localStat.size) return rename();
      offset = localStat.size;
      partFileStream = partFile.openWrite(mode: FileMode.append);
    } else {
      partFileStream = partFile.openWrite(mode: FileMode.write);
    }

    final dataStream =
        (await this.minio.getPartialObject(bucketName, filename, offset))
            .asBroadcastStream(onListen: (sub) {
      if (onStart != null) {
        onStart(sub);
      }
    });

    Future.delayed(Duration.zero).then((_) {
      final listen = dataStream.listen((data) {
        if (onListen != null) {
          onListen(partFile.statSync().size, stat.size);
        }
      });
      listen.onDone(() {
        if (onListen != null) {
          onListen(partFile.statSync().size, stat.size);
        }
        listen.cancel();
      });
    });

    await dataStream.pipe(partFileStream);

    if (onCompleted != null) {
      onCompleted(partFile.statSync().size, stat.size);
    }
    // print('${partFile.statSync().size}, ${stat.size}');

    final localStat = await partFile.stat();
    if (localStat.size != stat.size) {
      throw MinioError('Size mismatch between downloaded file and the object');
    }
    toast('下载完成 $filename');
    return rename();
  }
}
