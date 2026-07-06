import 'dart:io';
import 'dart:typed_data';

/// Random-access byte access over an IMG file. Two implementations: fully
/// in-memory ([MemoryByteSource]) and file-backed with a block cache
/// ([FileByteSource]) so large maps aren't loaded into RAM.
abstract class ByteSource {
  int get length;

  int u8(int o);

  /// Reads [len] bytes starting at [o] into a contiguous buffer (cheap view for
  /// memory; a file read for the file source). Used for geometry bitstreams.
  Uint8List range(int o, int len);

  int u16(int o) => u8(o) | (u8(o + 1) << 8);
  int u24(int o) => u8(o) | (u8(o + 1) << 8) | (u8(o + 2) << 16);
  int u32(int o) => u8(o) | (u8(o + 1) << 8) | (u8(o + 2) << 16) | (u8(o + 3) << 24);
  int s16(int o) {
    final v = u16(o);
    return (v & 0x8000) != 0 ? v - 0x10000 : v;
  }

  int s24(int o) {
    final v = u24(o);
    return (v & 0x800000) != 0 ? v - 0x1000000 : v;
  }

  /// Index of the first occurrence of [needle] at/after [from], or -1.
  int indexOf(List<int> needle, int from);

  void close() {}
}

class MemoryByteSource extends ByteSource {
  final Uint8List b;
  MemoryByteSource(this.b);

  @override
  int get length => b.length;
  @override
  int u8(int o) => b[o];
  @override
  Uint8List range(int o, int len) => Uint8List.sublistView(b, o, o + len);

  @override
  int indexOf(List<int> needle, int from) {
    final n = needle.length, end = b.length - n;
    for (var i = from; i <= end; i++) {
      var ok = true;
      for (var j = 0; j < n; j++) {
        if (b[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }
}

/// File-backed source with an LRU cache of fixed-size blocks. Reads are
/// synchronous ([RandomAccessFile.readSync]) so the parser stays synchronous.
class FileByteSource extends ByteSource {
  final RandomAccessFile _raf;
  @override
  final int length;

  static const int _blockBits = 16; // 64 KiB blocks
  static const int _blockSize = 1 << _blockBits;
  static const int _blockMask = _blockSize - 1;
  static const int _maxBlocks = 64; // ~4 MiB cache

  final Map<int, Uint8List> _cache = {};
  final List<int> _lru = [];

  FileByteSource(this._raf, this.length);

  static Future<FileByteSource> open(String path) async {
    final raf = await File(path).open();
    final len = await raf.length();
    return FileByteSource(raf, len);
  }

  Uint8List _block(int bi) {
    final hit = _cache[bi];
    if (hit != null) {
      _lru.remove(bi);
      _lru.add(bi);
      return hit;
    }
    _raf.setPositionSync(bi << _blockBits);
    final data = _raf.readSync(_blockSize);
    _cache[bi] = data;
    _lru.add(bi);
    if (_lru.length > _maxBlocks) _cache.remove(_lru.removeAt(0));
    return data;
  }

  @override
  int u8(int o) => _block(o >> _blockBits)[o & _blockMask];

  @override
  Uint8List range(int o, int len) {
    // Direct read for arbitrary ranges (may span blocks); small and local.
    _raf.setPositionSync(o);
    return _raf.readSync(len);
  }

  @override
  int indexOf(List<int> needle, int from) {
    // Chunked scan; overlap by needle length so matches across boundaries hold.
    const chunk = 1 << 20; // 1 MiB
    final n = needle.length;
    final first = needle[0];
    var pos = from;
    while (pos < length) {
      _raf.setPositionSync(pos);
      final buf = _raf.readSync(chunk + n);
      final lim = buf.length - n;
      for (var i = 0; i <= lim; i++) {
        if (buf[i] != first) continue;
        var ok = true;
        for (var j = 1; j < n; j++) {
          if (buf[i + j] != needle[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return pos + i;
      }
      if (buf.length < chunk + n) break;
      pos += chunk;
    }
    return -1;
  }

  @override
  void close() => _raf.closeSync();
}
