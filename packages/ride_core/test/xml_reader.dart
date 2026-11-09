/// Minimal zero-dependency XML reader used to parse back GPX/TCX exports in
/// tests. Handles elements, attributes, text, self-closing tags, the XML
/// declaration, comments, CDATA, and the five predefined entities. Namespace
/// prefixes are kept as part of names (`gpxtpx:hr`); [XmlElement.find] and
/// friends also match unprefixed local names.
library;

class XmlElement {
  final String name;
  final Map<String, String> attributes;
  final List<XmlElement> children = [];
  String text = '';

  XmlElement(this.name, this.attributes);

  /// Local name without any namespace prefix.
  String get localName {
    final i = name.indexOf(':');
    return i >= 0 ? name.substring(i + 1) : name;
  }

  List<XmlElement> findAll(String name) =>
      children.where((c) => c.name == name || c.localName == name).toList();

  XmlElement? find(String name) {
    for (final c in children) {
      if (c.name == name || c.localName == name) return c;
    }
    return null;
  }

  String attr(String name) {
    if (attributes.containsKey(name)) return attributes[name]!;
    final i = name.indexOf(':');
    if (i >= 0) {
      final local = name.substring(i + 1);
      for (final e in attributes.entries) {
        final k = e.key.contains(':') ? e.key.split(':').last : e.key;
        if (k == local) return e.value;
      }
    }
    return attributes[name] ?? (throw ArgumentError('missing attribute $name on <$name>'));
  }

  double get textDouble => double.parse(text.trim());
  int get textInt => int.parse(text.trim());

  @override
  String toString() => '<$name>${children.length} children';
}

class XmlDocument {
  final XmlElement root;
  XmlDocument(this.root);
}

XmlDocument parseXml(String src) {
  var i = 0;
  final n = src.length;

  String textUntil(int stopAt) => src.substring(i, stopAt);

  XmlElement parseElement() {
    // i points at '<' of a start tag
    i++; // consume '<'
    final nameStart = i;
    while (i < n && !_isWs(src[i]) && src[i] != '>' && src[i] != '/') {
      i++;
    }
    final name = src.substring(nameStart, i);
    final el = XmlElement(name, {});
    // attributes
    while (true) {
      _skipWs(src, () => i, (v) => i = v);
      if (i >= n) throw const FormatException('unexpected EOF in tag');
      if (src[i] == '/') {
        // self-closing
        if (i + 1 >= n || src[i + 1] != '>') {
          throw const FormatException('bad self-closing tag');
        }
        i += 2;
        return el;
      }
      if (src[i] == '>') {
        i++;
        break;
      }
      final aStart = i;
      while (i < n && src[i] != '=' && !_isWs(src[i])) {
        i++;
      }
      final aName = src.substring(aStart, i);
      _skipWs(src, () => i, (v) => i = v);
      if (src[i] != '=') throw FormatException('bad attribute $aName');
      i++;
      _skipWs(src, () => i, (v) => i = v);
      final q = src[i];
      if (q != '"' && q != "'") throw const FormatException('unquoted attribute');
      i++;
      final vStart = i;
      while (i < n && src[i] != q) {
        i++;
      }
      el.attributes[aName] = _unescape(src.substring(vStart, i));
      i++;
    }
    // content
    final textBuf = StringBuffer();
    while (i < n) {
      if (src.startsWith('<!--', i)) {
        final end = src.indexOf('-->', i + 4);
        if (end < 0) throw const FormatException('unterminated comment');
        i = end + 3;
      } else if (src.startsWith('<![CDATA[', i)) {
        final end = src.indexOf(']]>', i + 9);
        if (end < 0) throw const FormatException('unterminated CDATA');
        textBuf.write(src.substring(i + 9, end));
        i = end + 3;
      } else if (src.startsWith('</', i)) {
        final end = src.indexOf('>', i + 2);
        if (end < 0) throw const FormatException('unterminated end tag');
        final closeName = src.substring(i + 2, end).trim();
        if (closeName != name) {
          throw FormatException('mismatched tag: <$name> vs </$closeName>');
        }
        i = end + 1;
        el.text = _unescape(textBuf.toString());
        return el;
      } else if (src[i] == '<') {
        final child = parseElement();
        el.children.add(child);
      } else {
        final lt = src.indexOf('<', i);
        if (lt < 0) throw const FormatException('EOF inside element');
        textBuf.write(src.substring(i, lt));
        i = lt;
      }
    }
    throw const FormatException('EOF inside element (no close tag)');
  }

  // prolog
  XmlElement? root;
  while (i < n) {
    if (src.startsWith('<?', i)) {
      final end = src.indexOf('?>', i + 2);
      if (end < 0) throw const FormatException('unterminated PI');
      i = end + 2;
    } else if (src.startsWith('<!--', i)) {
      final end = src.indexOf('-->', i + 4);
      i = end + 3;
    } else if (src.startsWith('<!', i)) {
      final end = src.indexOf('>', i + 2);
      i = end + 1;
    } else if (src[i] == '<') {
      root = parseElement();
      break;
    } else if (_isWs(src[i])) {
      i++;
    } else {
      throw FormatException('unexpected content at $i: ${textUntil(i + 10)}');
    }
  }
  if (root == null) throw const FormatException('no root element');
  return XmlDocument(root);
}

bool _isWs(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

void _skipWs(String src, int Function() get, void Function(int) set) {
  var i = get();
  while (i < src.length && _isWs(src[i])) {
    i++;
  }
  set(i);
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
