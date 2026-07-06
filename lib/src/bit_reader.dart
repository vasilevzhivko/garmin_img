import 'dart:typed_data';

/// LSB-first bit reader over a byte range, as used by RGN geometry bitstreams.
/// Reads past the end return 0 (streams are padded to a byte boundary).
class BitReader {
  final Uint8List _b;
  final int _start;
  final int _nbits;
  int _pos = 0;

  BitReader(this._b, this._start, int lengthBytes) : _nbits = lengthBytes * 8;

  int get remaining => _nbits - _pos;

  /// Reads [n] bits, least-significant first, returning them as an unsigned int.
  int get(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      if (_pos >= _nbits) return v; // pad past the end with zeros
      final byte = _b[_start + (_pos >> 3)];
      v |= ((byte >> (_pos & 7)) & 1) << i;
      _pos++;
    }
    return v;
  }
}
