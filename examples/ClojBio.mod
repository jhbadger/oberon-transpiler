MODULE ClojBio;
(*
 * Cloj bindings for BioSeq / BioIO.
 * Register with: Cloj.AddOberonModule("bio", ClojBio.Export)
 *
 * Exports:
 *   (bio/read-fasta path)
 *     Returns a list of maps, one per record:
 *       {:name "id" :desc "description" :length N :gc 0.62 :nuc? true}
 *
 *   (bio/read-fastq path)
 *     Returns a list of maps:
 *       {:name "id" :length N :gc 0.62 :nuc? true :qual-len N}
 *)

IMPORT Cloj, BioSeq, BioIO;

(* Build a 5-key map for one FASTA record.  All BioSeq calls go through
   a local BioSeq.Seq variable to avoid the cross-module chained-pointer
   dereference limitation (coll.head.tag vs h := coll.head; h.tag). *)
PROCEDURE SeqMap(name, desc: ARRAY OF CHAR; s: BioSeq.Seq): Cloj.Value;
VAR ks, vs, nucV: Cloj.Value;
    gc: REAL; isNuc: BOOLEAN;
BEGIN
  gc   := BioSeq.GCContent(s);
  isNuc := BioSeq.IsNucleotide(s);
  nucV := Cloj.MkBool(isNuc);
  ks := Cloj.Cons(Cloj.MkKey("name"),
        Cloj.Cons(Cloj.MkKey("desc"),
        Cloj.Cons(Cloj.MkKey("length"),
        Cloj.Cons(Cloj.MkKey("gc"),
        Cloj.Cons(Cloj.MkKey("nuc?"), Cloj.NilV)))));
  vs := Cloj.Cons(Cloj.MkStr(name),
        Cloj.Cons(Cloj.MkStr(desc),
        Cloj.Cons(Cloj.MkInt(s.length),
        Cloj.Cons(Cloj.MkReal(gc),
        Cloj.Cons(nucV, Cloj.NilV)))));
  RETURN Cloj.MkMap(ks, vs)
END SeqMap;

PROCEDURE BReadFasta(args: Cloj.Value; env: Cloj.Env): Cloj.Value;
VAR pathV, result, rlast, cell: Cloj.Value;
    r: BioIO.FastaReader;
    rec: BioIO.FastaRecord;
    s: BioSeq.Seq;
BEGIN
  pathV := args.head;
  IF Cloj.IsNil(pathV) OR (pathV.tag # Cloj.tStr) THEN
    Cloj.Error("bio/read-fasta: needs a string path"); RETURN Cloj.NilV
  END;
  rec.seq := NIL;
  IF ~BioIO.OpenFasta(r, pathV.s) THEN
    Cloj.Error("bio/read-fasta: cannot open file"); RETURN Cloj.NilV
  END;
  result := Cloj.NilV; rlast := NIL;
  WHILE BioIO.ReadFasta(r, rec) DO
    s    := rec.seq;
    cell := Cloj.Cons(SeqMap(rec.name, rec.desc, s), Cloj.NilV);
    IF rlast = NIL THEN result := cell ELSE rlast.tail := cell END;
    rlast := cell
  END;
  BioIO.CloseFasta(r);
  RETURN result
END BReadFasta;

PROCEDURE BReadFastq(args: Cloj.Value; env: Cloj.Env): Cloj.Value;
VAR pathV, result, rlast, cell, m, ks, vs, nucV: Cloj.Value;
    r: BioIO.FastqReader;
    rec: BioIO.FastqRecord;
    s, q: BioSeq.Seq;
    gc: REAL; isNuc: BOOLEAN;
BEGIN
  pathV := args.head;
  IF Cloj.IsNil(pathV) OR (pathV.tag # Cloj.tStr) THEN
    Cloj.Error("bio/read-fastq: needs a string path"); RETURN Cloj.NilV
  END;
  rec.seq := NIL; rec.qual := NIL;
  IF ~BioIO.OpenFastq(r, pathV.s) THEN
    Cloj.Error("bio/read-fastq: cannot open file"); RETURN Cloj.NilV
  END;
  result := Cloj.NilV; rlast := NIL;
  WHILE BioIO.ReadFastq(r, rec) DO
    s := rec.seq; q := rec.qual;
    gc   := BioSeq.GCContent(s);
    isNuc := BioSeq.IsNucleotide(s);
    nucV := Cloj.MkBool(isNuc);
    ks := Cloj.Cons(Cloj.MkKey("name"),
          Cloj.Cons(Cloj.MkKey("length"),
          Cloj.Cons(Cloj.MkKey("gc"),
          Cloj.Cons(Cloj.MkKey("nuc?"),
          Cloj.Cons(Cloj.MkKey("qual-len"), Cloj.NilV)))));
    vs := Cloj.Cons(Cloj.MkStr(rec.name),
          Cloj.Cons(Cloj.MkInt(s.length),
          Cloj.Cons(Cloj.MkReal(gc),
          Cloj.Cons(nucV,
          Cloj.Cons(Cloj.MkInt(q.length), Cloj.NilV)))));
    m := Cloj.MkMap(ks, vs);
    cell := Cloj.Cons(m, Cloj.NilV);
    IF rlast = NIL THEN result := cell ELSE rlast.tail := cell END;
    rlast := cell
  END;
  BioIO.CloseFastq(r);
  RETURN result
END BReadFastq;

PROCEDURE Export*(env: Cloj.Env);
BEGIN
  Cloj.RegisterBuiltin(env, "bio/read-fasta", BReadFasta);
  Cloj.RegisterBuiltin(env, "bio/read-fastq", BReadFastq)
END Export;

END ClojBio.
