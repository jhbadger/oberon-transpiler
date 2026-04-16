MODULE Base64;

(** Standard Base64 Encoding for Oberon **)

(** Encodes a source buffer into a Base64 string **)
PROCEDURE Encode*(VAR src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR
  i, j, n: INTEGER;
  b0, b1, b2: INTEGER;
  table: ARRAY 65 OF CHAR;
BEGIN
  (* Define the table as a variable to avoid C enum errors *)
  table := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  i := 0; j := 0;
  n := 0;
  (* Calculate actual length of source data *)
  WHILE (i < LEN(src)) & (src[i] # 0X) DO INC(n); INC(i) END;
  
  i := 0;
  WHILE i < n DO
    b0 := ORD(src[i]); INC(i);
    
    dst[j] := table[(b0 DIV 4) MOD 64]; INC(j);
    
    IF i < n THEN
      b1 := ORD(src[i]); INC(i);
      dst[j] := table[((b0 * 16) MOD 64 + (b1 DIV 16)) MOD 64]; INC(j);
      
      IF i < n THEN
        b2 := ORD(src[i]); INC(i);
        dst[j] := table[((b1 * 4) MOD 64 + (b2 DIV 64)) MOD 64]; INC(j);
        dst[j] := table[b2 MOD 64]; INC(j)
      ELSE
        dst[j] := table[(b1 * 4) MOD 64]; INC(j);
        dst[j] := "="; INC(j)
      END
    ELSE
      dst[j] := table[(b0 * 16) MOD 64]; INC(j);
      dst[j] := "="; INC(j);
      dst[j] := "="; INC(j)
    END
  END;
  dst[j] := 0X
END Encode;

(** Encodes n bytes of src (binary-safe, ignores null bytes) into Base64 in dst **)
PROCEDURE EncodeBin*(VAR src: ARRAY OF CHAR; n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR
  i, j: INTEGER;
  b0, b1, b2: INTEGER;
  table: ARRAY 65 OF CHAR;
BEGIN
  table := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  i := 0; j := 0;
  WHILE i < n DO
    b0 := ORD(src[i]); INC(i);
    dst[j] := table[(b0 DIV 4) MOD 64]; INC(j);
    IF i < n THEN
      b1 := ORD(src[i]); INC(i);
      dst[j] := table[((b0 * 16) MOD 64 + (b1 DIV 16)) MOD 64]; INC(j);
      IF i < n THEN
        b2 := ORD(src[i]); INC(i);
        dst[j] := table[((b1 * 4) MOD 64 + (b2 DIV 64)) MOD 64]; INC(j);
        dst[j] := table[b2 MOD 64]; INC(j)
      ELSE
        dst[j] := table[(b1 * 4) MOD 64]; INC(j);
        dst[j] := "="; INC(j)
      END
    ELSE
      dst[j] := table[(b0 * 16) MOD 64]; INC(j);
      dst[j] := "="; INC(j);
      dst[j] := "="
    END
  END;
  dst[j] := 0X
END EncodeBin;

END Base64.