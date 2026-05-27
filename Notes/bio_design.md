# Oberon Bioinformatics Library — Module Design
*Inspired by rust-bio. All modules import from the Oberon standard library only.*

---

## Design Principles

- **One concern per module.** Oberon's flat namespace and lack of generics means each logical concept gets its own module rather than being parametrised by type.
- **Strings are `ARRAY OF CHAR` (max 256 bytes).** Long sequences are stored as heap-linked chunk lists (see `BioSeq`).
- **Indices are 0-based** throughout, matching rust-bio convention.
- **No exceptions.** Procedures return BOOLEAN or an INTEGER error code; callers must check.
- **Existing stdlib is used directly.** `DataFrame`, `Dict`, `Files`, `Strings`, `Math` are imported where relevant — no reimplementation.

---

## Module Hierarchy

```
BioAlpha          Alphabet definitions (DNA, RNA, Protein, IUPAC)
BioSeq            Long sequence storage (chunk list) + basic ops
BioIO             FASTA / FASTQ / BED readers and writers
BioAlign          Pairwise alignment (NW, SW, semi-global)
BioPattern        Pattern matching (exact, BM, KMP, Aho-Corasick, BNDM)
BioSuffix         Suffix array + BWT construction
BioFM             FM-Index and backward search (depends on BioSuffix)
BioQGram          Q-gram index for approximate matching
BioStats          Log-probabilities, combinatorics, Phred scores
BioAnnot          Interval/annotation storage (BED-style)
BioORF            Open reading frame finding
```

Dependencies flow downward; no cycles.

```
BioAlpha
  └─ BioSeq
       ├─ BioIO
       ├─ BioAlign
       ├─ BioPattern
       │    └─ BioQGram
       ├─ BioSuffix
       │    └─ BioFM
       ├─ BioStats
       ├─ BioAnnot
       └─ BioORF
```

---

## Module Specifications

---

### BioAlpha — Alphabets

Represents an alphabet as a bit-set of valid characters plus a complement table.

```oberon
CONST
  MaxAlpha = 128;       (* covers ASCII *)

TYPE
  Alphabet = RECORD
    valid : SET;              (* SET of ORD(c) for valid chars, max 32 chars *)
    size  : INTEGER;
    (* For alphabets > 32 symbols, use the validArr boolean array instead *)
    validArr : ARRAY MaxAlpha OF BOOLEAN;
    comp     : ARRAY MaxAlpha OF CHAR   (* complement map; 0X = no complement *)
  END;
```

**Predefined alphabet constructors (procedures, not constants):**

| Procedure | Description |
|-----------|-------------|
| `BioAlpha.DNA(VAR a: Alphabet)` | {A C G T} |
| `BioAlpha.DNAIUPAC(VAR a: Alphabet)` | {A C G T R Y S W K M B D H V N} |
| `BioAlpha.RNA(VAR a: Alphabet)` | {A C G U} |
| `BioAlpha.Protein(VAR a: Alphabet)` | Standard 20 amino acids + stop * |
| `BioAlpha.IsValid(VAR a: Alphabet; c: CHAR): BOOLEAN` | |
| `BioAlpha.Complement(VAR a: Alphabet; c: CHAR): CHAR` | Returns 0X if no complement |
| `BioAlpha.Add(VAR a: Alphabet; c, comp: CHAR)` | Extend an alphabet |

**Symbol encoding (rank/decode):**

| Procedure | Description |
|-----------|-------------|
| `BioAlpha.Rank(VAR a: Alphabet; c: CHAR): INTEGER` | 0-based rank within alphabet; -1 if invalid |
| `BioAlpha.Symbol(VAR a: Alphabet; rank: INTEGER): CHAR` | Inverse of Rank |

---

### BioSeq — Long Sequence Storage

Sequences longer than 256 bytes need a chunked representation. This module provides a linked-list of fixed-size chunks and basic operations over them.

```oberon
CONST
  ChunkSize = 240;     (* bytes per chunk, leaves room for overhead *)

TYPE
  ChunkPtr = POINTER TO Chunk;
  Chunk = RECORD
    data : ARRAY ChunkSize OF CHAR;
    len  : INTEGER;       (* bytes used in this chunk *)
    next : ChunkPtr
  END;

  Seq = POINTER TO SeqRec;
  SeqRec = RECORD
    head   : ChunkPtr;
    tail   : ChunkPtr;   (* kept for O(1) append *)
    length : INTEGER;    (* total character count *)
    name   : ARRAY 128 OF CHAR   (* sequence identifier *)
  END;
```

| Procedure / Function | Description |
|----------------------|-------------|
| `BioSeq.New(VAR s: Seq)` | Allocate an empty sequence |
| `BioSeq.Free(VAR s: Seq)` | Release all chunks |
| `BioSeq.Append(s: Seq; buf: ARRAY OF CHAR; n: INTEGER)` | Append `n` chars from `buf` |
| `BioSeq.Get(s: Seq; pos: INTEGER): CHAR` | Character at position `pos` |
| `BioSeq.Slice(s: Seq; start, len: INTEGER; VAR buf: ARRAY OF CHAR)` | Copy substring into `buf` |
| `BioSeq.Length(s: Seq): INTEGER` | Total length |
| `BioSeq.RevComp(s: Seq; VAR a: BioAlpha.Alphabet; VAR dst: Seq)` | Reverse complement into `dst` |
| `BioSeq.ToUpper(s: Seq)` | In-place uppercase |
| `BioSeq.Count(s: Seq; c: CHAR): INTEGER` | Count occurrences of `c` |
| `BioSeq.GCContent(s: Seq): REAL` | Fraction of G+C bases |
| `BioSeq.FromStr(s: Seq; str: ARRAY OF CHAR)` | Load from a short string |
| `BioSeq.ToStr(s: Seq; VAR str: ARRAY OF CHAR)` | Copy up to 255 chars into `str` |

---

### BioIO — Sequence File I/O

Reads and writes FASTA, FASTQ, and BED files using `Files` riders.

```oberon
TYPE
  FastaRecord = RECORD
    name : ARRAY 128 OF CHAR;
    desc : ARRAY 256 OF CHAR;
    seq  : BioSeq.Seq
  END;

  FastqRecord = RECORD
    name   : ARRAY 128 OF CHAR;
    seq    : BioSeq.Seq;
    qual   : BioSeq.Seq    (* raw ASCII quality chars *)
  END;

  BedRecord = RECORD
    chrom  : ARRAY 64 OF CHAR;
    start  : INTEGER;      (* 0-based *)
    end_   : INTEGER;      (* exclusive *)
    name   : ARRAY 64 OF CHAR;
    score  : INTEGER;
    strand : CHAR          (* '+', '-', or '.' *)
  END;

  (* Reader state — declare VAR r: BioIO.FastaReader etc. *)
  FastaReader = RECORD
    rider : Files.Rider;
    done  : BOOLEAN
  END;

  FastqReader = RECORD
    rider : Files.Rider;
    done  : BOOLEAN
  END;

  BedReader = RECORD
    rider : Files.Rider;
    done  : BOOLEAN
  END;
```

**FASTA:**

| Procedure | Description |
|-----------|-------------|
| `BioIO.OpenFasta(VAR r: FastaReader; path: ARRAY OF CHAR): BOOLEAN` | Open file; returns FALSE on error |
| `BioIO.ReadFasta(VAR r: FastaReader; VAR rec: FastaRecord): BOOLEAN` | Read next record; FALSE at EOF |
| `BioIO.CloseFasta(VAR r: FastaReader)` | |
| `BioIO.WriteFasta(VAR r: Files.Rider; VAR rec: FastaRecord; width: INTEGER)` | Write wrapped at `width` cols |

**FASTQ:**

| Procedure | Description |
|-----------|-------------|
| `BioIO.OpenFastq(VAR r: FastqReader; path: ARRAY OF CHAR): BOOLEAN` | |
| `BioIO.ReadFastq(VAR r: FastqReader; VAR rec: FastqRecord): BOOLEAN` | |
| `BioIO.CloseFastq(VAR r: FastqReader)` | |
| `BioIO.WriteFastq(VAR r: Files.Rider; VAR rec: FastqRecord)` | |

**BED:**

| Procedure | Description |
|-----------|-------------|
| `BioIO.OpenBed(VAR r: BedReader; path: ARRAY OF CHAR): BOOLEAN` | |
| `BioIO.ReadBed(VAR r: BedReader; VAR rec: BedRecord): BOOLEAN` | |
| `BioIO.CloseBed(VAR r: BedReader)` | |
| `BioIO.WriteBed(VAR r: Files.Rider; VAR rec: BedRecord)` | |

---

### BioAlign — Pairwise Alignment

Implements Needleman-Wunsch (global), Smith-Waterman (local), and semi-global alignment using a flat score matrix.

```oberon
CONST
  MaxSeqLen = 4096;    (* maximum sequence length for DP *)

TYPE
  ScoreMatrix = RECORD
    match_   : INTEGER;
    mismatch : INTEGER;
    gapOpen  : INTEGER;   (* affine gap penalty: open *)
    gapExt   : INTEGER    (* affine gap penalty: extend *)
  END;

  (* CIGAR-style alignment result *)
  OpKind = INTEGER;   (* 0=Match, 1=Ins, 2=Del, 3=Subst *)

  CigarEntry = RECORD
    op  : OpKind;
    len : INTEGER
  END;

  MaxCigar = 8192;

  Alignment = RECORD
    score    : INTEGER;
    qStart   : INTEGER;    qEnd   : INTEGER;
    rStart   : INTEGER;    rEnd   : INTEGER;
    cigar    : ARRAY MaxCigar OF CigarEntry;
    nOps     : INTEGER;
    identity : REAL       (* fraction of matched positions *)
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioAlign.DefaultScore(VAR m: ScoreMatrix)` | match=1, mismatch=-1, gapOpen=-5, gapExt=-1 |
| `BioAlign.Global(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)` | Needleman-Wunsch |
| `BioAlign.Local(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)` | Smith-Waterman |
| `BioAlign.SemiGlobal(q, r: BioSeq.Seq; VAR m: ScoreMatrix; VAR aln: Alignment)` | Query free end-gaps |
| `BioAlign.EditDistance(q, r: BioSeq.Seq): INTEGER` | Levenshtein distance |
| `BioAlign.HammingDistance(q, r: BioSeq.Seq): INTEGER` | Hamming (equal-length only; -1 if lengths differ) |
| `BioAlign.PrintAlignment(VAR aln: Alignment; q, r: BioSeq.Seq)` | Pretty-print to stdout |

---

### BioPattern — Exact and Approximate Pattern Matching

```oberon
TYPE
  (* Shared hit record returned by all matchers *)
  Hit = RECORD
    pos  : INTEGER;   (* 0-based start in text *)
    len  : INTEGER;   (* match length *)
    dist : INTEGER    (* edit distance; 0 for exact *)
  END;

  MaxHits = 65536;
  HitList = RECORD
    hits  : ARRAY MaxHits OF Hit;
    count : INTEGER
  END;

  (* Precomputed tables for Boyer-Moore *)
  BMState = RECORD
    pattern   : ARRAY 256 OF CHAR;
    patLen    : INTEGER;
    badChar   : ARRAY 128 OF INTEGER;
    goodSuffix: ARRAY 256 OF INTEGER
  END;

  (* KMP failure function *)
  KMPState = RECORD
    pattern : ARRAY 256 OF CHAR;
    patLen  : INTEGER;
    fail    : ARRAY 256 OF INTEGER
  END;

  (* Aho-Corasick automaton — fixed capacity *)
  MaxACNodes   = 4096;
  MaxACPattern = 64;
  ACNode = RECORD
    go     : ARRAY 128 OF INTEGER;  (* transition by char *)
    fail   : INTEGER;
    output : INTEGER    (* pattern index, -1 if none *)
  END;
  ACState = RECORD
    nodes    : ARRAY MaxACNodes OF ACNode;
    nNodes   : INTEGER;
    patterns : ARRAY MaxACPattern OF ARRAY 256 OF CHAR;
    nPat     : INTEGER
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioPattern.BMBuild(VAR st: BMState; pat: ARRAY OF CHAR)` | Precompute Boyer-Moore tables |
| `BioPattern.BMSearch(VAR st: BMState; text: BioSeq.Seq; VAR hits: HitList)` | Run Boyer-Moore |
| `BioPattern.KMPBuild(VAR st: KMPState; pat: ARRAY OF CHAR)` | Precompute KMP failure function |
| `BioPattern.KMPSearch(VAR st: KMPState; text: BioSeq.Seq; VAR hits: HitList)` | Run KMP |
| `BioPattern.ACBuild(VAR st: ACState)` | Initialise automaton |
| `BioPattern.ACAdd(VAR st: ACState; pat: ARRAY OF CHAR)` | Add a pattern |
| `BioPattern.ACFinalize(VAR st: ACState)` | Compute fail links |
| `BioPattern.ACSearch(VAR st: ACState; text: BioSeq.Seq; VAR hits: HitList)` | Multi-pattern search |
| `BioPattern.Ukkonen(pat: ARRAY OF CHAR; text: BioSeq.Seq; maxDist: INTEGER; VAR hits: HitList)` | Approximate matching via Ukkonen's bit-vector DP |

---

### BioSuffix — Suffix Array and BWT

```oberon
CONST
  MaxSALen = 65536;   (* max text length for suffix array *)

TYPE
  SuffixArray = RECORD
    sa   : ARRAY MaxSALen OF INTEGER;  (* suffix array *)
    n    : INTEGER                     (* text length incl. sentinel *)
  END;

  BWTResult = RECORD
    bwt  : ARRAY MaxSALen OF CHAR;
    n    : INTEGER;
    eof  : INTEGER    (* position of sentinel in BWT *)
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioSuffix.Build(text: BioSeq.Seq; VAR sa: SuffixArray)` | Build suffix array (prefix-doubling O(n log n)) |
| `BioSuffix.BWT(text: BioSeq.Seq; VAR sa: SuffixArray; VAR bwt: BWTResult)` | Compute BWT from suffix array |
| `BioSuffix.InverseBWT(VAR bwt: BWTResult; VAR text: BioSeq.Seq)` | Reconstruct text from BWT |
| `BioSuffix.LCP(text: BioSeq.Seq; VAR sa: SuffixArray; VAR lcp: ARRAY OF INTEGER)` | Compute LCP array |
| `BioSuffix.Search(text: BioSeq.Seq; VAR sa: SuffixArray; pat: ARRAY OF CHAR; VAR lo, hi: INTEGER): BOOLEAN` | Binary-search the suffix array for `pat`; sets interval [lo,hi) |

---

### BioFM — FM-Index

Depends on `BioSuffix` and `BioAlpha`.

```oberon
CONST
  OccSample = 16;   (* sample interval for Occ table *)

TYPE
  (* Less table: for each symbol, count of BWT chars strictly less than it *)
  LessTable = RECORD
    val : ARRAY 128 OF INTEGER
  END;

  (* Sampled occurrence table *)
  OccTable = RECORD
    nSymbols : INTEGER;
    nRows    : INTEGER;
    sample   : INTEGER;    (* sampling interval *)
    data     : ARRAY 128 OF ARRAY 4096 OF INTEGER
    (* data[c][i] = occurrences of symbol c in bwt[0..i*sample) *)
  END;

  FMIndex = RECORD
    bwt  : BioSuffix.BWTResult;
    sa   : BioSuffix.SuffixArray;
    less : LessTable;
    occ  : OccTable;
    n    : INTEGER
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioFM.Build(text: BioSeq.Seq; VAR a: BioAlpha.Alphabet; VAR idx: FMIndex)` | Build FM-Index from scratch |
| `BioFM.BackwardSearch(VAR idx: FMIndex; pat: ARRAY OF CHAR; VAR lo, hi: INTEGER): BOOLEAN` | Backward search; returns SA interval |
| `BioFM.Locate(VAR idx: FMIndex; lo, hi: INTEGER; VAR positions: ARRAY OF INTEGER; VAR nPos: INTEGER)` | Convert SA interval to text positions |
| `BioFM.Count(VAR idx: FMIndex; pat: ARRAY OF CHAR): INTEGER` | Count occurrences of `pat` |

---

### BioQGram — Q-Gram Index

```oberon
CONST
  MaxQ     = 8;
  MaxBuckets = 65536;

TYPE
  QGramIndex = RECORD
    q        : INTEGER;
    buckets  : ARRAY MaxBuckets OF INTEGER;   (* bucket start in pos array *)
    pos      : ARRAY MaxSALen OF INTEGER;     (* sorted positions *)
    nPos     : INTEGER;
    textLen  : INTEGER
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioQGram.Build(text: BioSeq.Seq; q: INTEGER; VAR idx: QGramIndex)` | Build q-gram index |
| `BioQGram.Query(VAR idx: QGramIndex; qgram: ARRAY OF CHAR; VAR positions: ARRAY OF INTEGER; VAR n: INTEGER)` | Find all positions of exact q-gram |
| `BioQGram.ApproxSearch(VAR idx: QGramIndex; pat: ARRAY OF CHAR; maxDist: INTEGER; VAR hits: BioPattern.HitList)` | Pigeonhole approximate search |

---

### BioStats — Probabilities and Combinatorics

```oberon
CONST
  LogZero = -1.0E308;   (* log-probability representing probability 0 *)
```

| Function | Returns | Description |
|----------|---------|-------------|
| `BioStats.PhredToProb(q: INTEGER): REAL` | REAL | 10^(-q/10) |
| `BioStats.ProbToPhred(p: REAL): INTEGER` | INTEGER | FLOOR(-10 * log10(p)) |
| `BioStats.LogAdd(a, b: REAL): REAL` | REAL | log(exp(a)+exp(b)), numerically stable |
| `BioStats.LogSum(arr: ARRAY OF REAL; n: INTEGER): REAL` | REAL | log-sum of array |
| `BioStats.Factorial(n: INTEGER): REAL` | REAL | n! as REAL (uses log-gamma internally) |
| `BioStats.LogFactorial(n: INTEGER): REAL` | REAL | Stirling approximation |
| `BioStats.Binomial(n, k: INTEGER): REAL` | REAL | C(n,k) |
| `BioStats.LogBinomial(n, k: INTEGER): REAL` | REAL | log C(n,k) |
| `BioStats.BinomialProb(n, k: INTEGER; p: REAL): REAL` | REAL | P(X=k) for Binomial(n,p) |
| `BioStats.PoissonProb(lambda: REAL; k: INTEGER): REAL` | REAL | P(X=k) for Poisson(lambda) |
| `BioStats.NormalPDF(x, mu, sigma: REAL): REAL` | REAL | |
| `BioStats.NormalCDF(x, mu, sigma: REAL): REAL` | REAL | Rational approximation |
| `BioStats.FisherExact(a, b, c, d: INTEGER): REAL` | REAL | Two-tailed p-value |
| `BioStats.BHCorrect(pvals: ARRAY OF REAL; n: INTEGER; VAR adj: ARRAY OF REAL)` | | Benjamini-Hochberg FDR |

---

### BioAnnot — Genomic Interval Annotation

Stores genomic features as an interval list, with optional chromosome-keyed indexing via `Dict`.

```oberon
CONST
  MaxFeatures = 16384;

TYPE
  Feature = RECORD
    chrom  : ARRAY 64 OF CHAR;
    start  : INTEGER;      (* 0-based *)
    end_   : INTEGER;      (* exclusive *)
    name   : ARRAY 64 OF CHAR;
    score  : REAL;
    strand : CHAR;
    attrs  : ARRAY 256 OF CHAR   (* GFF3-style key=value pairs *)
  END;

  AnnotDB = RECORD
    features : ARRAY MaxFeatures OF Feature;
    count    : INTEGER;
    index    : Dict.Table    (* chrom -> comma-separated feature indices *)
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioAnnot.Init(VAR db: AnnotDB)` | Initialise empty database |
| `BioAnnot.Add(VAR db: AnnotDB; VAR f: Feature): BOOLEAN` | Add a feature; returns FALSE if full |
| `BioAnnot.LoadBed(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER` | Load BED file; returns count added |
| `BioAnnot.LoadGFF(VAR db: AnnotDB; path: ARRAY OF CHAR): INTEGER` | Load GFF3 file |
| `BioAnnot.Overlaps(VAR db: AnnotDB; chrom: ARRAY OF CHAR; start, end_: INTEGER; VAR hits: ARRAY OF INTEGER; VAR n: INTEGER)` | Find all features overlapping [start, end_) |
| `BioAnnot.Contains(VAR db: AnnotDB; chrom: ARRAY OF CHAR; pos: INTEGER; VAR hits: ARRAY OF INTEGER; VAR n: INTEGER)` | Features containing a single position |
| `BioAnnot.SortByPos(VAR db: AnnotDB)` | Sort features by chrom then start |

---

### BioORF — Open Reading Frame Detection

```oberon
CONST
  MaxORFs = 4096;

TYPE
  ORF = RECORD
    frame  : INTEGER;    (* reading frame: 0, 1, 2; negative for reverse *)
    start  : INTEGER;    (* 0-based position of start codon in original seq *)
    end_   : INTEGER;    (* position just after stop codon *)
    len    : INTEGER;    (* length in nucleotides *)
    aa     : BioSeq.Seq  (* translated amino acid sequence *)
  END;

  ORFList = RECORD
    orfs  : ARRAY MaxORFs OF ORF;
    count : INTEGER
  END;
```

| Procedure | Description |
|-----------|-------------|
| `BioORF.FindAll(seq: BioSeq.Seq; minLen: INTEGER; VAR result: ORFList)` | Find all ORFs in all 6 frames |
| `BioORF.FindForward(seq: BioSeq.Seq; minLen: INTEGER; VAR result: ORFList)` | 3 forward frames only |
| `BioORF.Translate(seq: BioSeq.Seq; frame: INTEGER; VAR aa: BioSeq.Seq)` | Translate one frame (standard codon table) |
| `BioORF.CodonToAA(codon: ARRAY OF CHAR): CHAR` | Return single-letter AA code |
| `BioORF.PrintORFs(VAR result: ORFList)` | Print summary to stdout |

---

## Implementation Notes

**Memory management.** All heap allocation goes through `NEW`/`FREE`. `BioSeq.Seq`, `BioFM.FMIndex`, and `BioAnnot.AnnotDB` are the main heap consumers. Call the corresponding `Free` or `Clear` procedures when done.

**Sequence length limits.** The DP matrices in `BioAlign` and the suffix array in `BioSuffix` have compile-time `MaxSeqLen` / `MaxSALen` constants. Increase these constants (and accept more stack/heap usage) for longer sequences.

**Alphabet-sensitive operations.** `BioFM` and `BioQGram` only index characters that are valid in the supplied alphabet. Characters outside the alphabet are treated as wildcard separators.

**Error convention.** Procedures that can fail return `BOOLEAN` (TRUE = success). Functions that return counts return -1 on error. Fatal precondition violations trigger `ASSERT`.
