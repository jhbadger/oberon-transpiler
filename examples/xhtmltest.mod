MODULE xhtmltest;
IMPORT XHTML, Out;

VAR
  src : ARRAY 4096 OF CHAR;
  dst : ARRAY 4096 OF CHAR;
  val : ARRAY 256 OF CHAR;
  ok  : BOOLEAN;

PROCEDURE Sep();
BEGIN Out.String("---"); Out.Ln END Sep;

BEGIN
  (* Test 1: basic tag stripping and block newlines *)
  Sep();
  Out.String("Test 1: block tags become newlines"); Out.Ln;
  src := "<html><body><h1>Title</h1><p>First paragraph.</p><p>Second paragraph.</p></body></html>";
  XHTML.ToText(src, dst);
  Out.String(dst); Out.Ln;

  (* Test 2: inline tags stripped, whitespace collapsed *)
  Sep();
  Out.String("Test 2: inline tags and whitespace"); Out.Ln;
  src := "<p>Hello  <b>world</b>,   how are <em>you</em>?</p>";
  XHTML.ToText(src, dst);
  Out.String(dst); Out.Ln;

  (* Test 3: entity decoding *)
  Sep();
  Out.String("Test 3: entity decoding"); Out.Ln;
  src := "<p>AT&amp;T sells &lt;widgets&gt; for &quot;free&quot; &amp; ships &nbsp;today.</p>";
  XHTML.ToText(src, dst);
  Out.String(dst); Out.Ln;

  (* Test 4: script and style removal *)
  Sep();
  Out.String("Test 4: script/style removal"); Out.Ln;
  src := "<p>Before</p><style>body{color:red}</style><p>After</p><script>alert(1)</script><p>End</p>";
  XHTML.ToText(src, dst);
  Out.String(dst); Out.Ln;

  (* Test 5: comment stripping *)
  Sep();
  Out.String("Test 5: comments"); Out.Ln;
  src := "<p>Visible<!-- hidden comment -->text</p>";
  XHTML.ToText(src, dst);
  Out.String(dst); Out.Ln;

  (* Test 6: numeric entities *)
  Sep();
  Out.String("Test 6: numeric entities"); Out.Ln;
  src := "<p>&#65;&#66;&#67; &#x44;&#x45;&#x46;</p>";
  XHTML.ToText(src, dst);
  Out.String(dst); Out.Ln;

  (* Test 7: AttrValue *)
  Sep();
  Out.String("Test 7: AttrValue"); Out.Ln;
  src := '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>';
  ok := XHTML.AttrValue(src, "full-path", val);
  IF ok THEN Out.String("full-path = "); Out.String(val); Out.Ln
  ELSE Out.String("not found"); Out.Ln
  END;
  ok := XHTML.AttrValue(src, "media-type", val);
  IF ok THEN Out.String("media-type = "); Out.String(val); Out.Ln
  ELSE Out.String("not found"); Out.Ln
  END;

  (* Test 8: AttrValue with single-quoted attributes *)
  Sep();
  Out.String("Test 8: single-quoted attribute"); Out.Ln;
  src := "<item id='ch1' href='chapter1.xhtml' media-type='application/xhtml+xml'/>";
  ok := XHTML.AttrValue(src, "href", val);
  IF ok THEN Out.String("href = "); Out.String(val); Out.Ln
  ELSE Out.String("not found"); Out.Ln
  END;

  Sep()
END xhtmltest.
