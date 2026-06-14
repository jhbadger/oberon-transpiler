MODULE testcloj;
(*
 * Regression test for the Cloj interpreter.
 * Prints PASS or FAIL for each case; summary at the end.
 *
 * Build:  ../obc -I ../Modules -I ../examples testcloj.mod -o testcloj
 * Run:    ./testcloj
 *)

IMPORT Cloj, Out, Args;

VAR
  passCount, failCount: INTEGER;

(* Evaluate s in the global environment; return result. Clears err. *)
PROCEDURE E(s: ARRAY OF CHAR): Cloj.Value;
VAR v: Cloj.Value;
BEGIN
  v := Cloj.EvalStr(s);
  IF Cloj.err THEN
    Out.String("  [setup error: "); Out.String(Cloj.errMsg);
    Out.String(" in: "); Out.String(s); Out.Char(']'); Out.Ln;
    Cloj.err := FALSE
  END;
  RETURN v
END E;

(* Evaluate expr; print PASS if result = true, FAIL otherwise. *)
PROCEDURE Check(label, expr: ARRAY OF CHAR);
VAR v: Cloj.Value;
BEGIN
  v := Cloj.EvalStr(expr);
  Out.String(label); Out.String(": ");
  IF Cloj.err THEN
    Out.String("FAIL (error: "); Out.String(Cloj.errMsg); Out.Char(')');
    Cloj.err := FALSE; INC(failCount)
  ELSIF v = Cloj.TrueV THEN
    Out.String("PASS"); INC(passCount)
  ELSE
    Out.String("FAIL"); INC(failCount)
  END;
  Out.Ln
END Check;

(* Section heading *)
PROCEDURE Section(name: ARRAY OF CHAR);
BEGIN Out.Ln; Out.String("-- "); Out.String(name); Out.String(" --"); Out.Ln
END Section;

BEGIN
  Cloj.Init;

  (* ── 1. Arithmetic ─────────────────────────────────────────────────── *)
  Section("Arithmetic");
  Check("add",        "(= (+ 1 2 3) 6)");
  Check("sub",        "(= (- 10 3 2) 5)");
  Check("mul",        "(= (* 2 3 4) 24)");
  Check("div",        "(= (/ 10.0 4.0) 2.5)");
  Check("mod",        "(= (mod 17 5) 2)");
  Check("quot",       "(= (quot 17 5) 3)");
  Check("rem",        "(= (rem -7 3) -1)");
  Check("inc/dec",    "(and (= (inc 4) 5) (= (dec 4) 3))");
  Check("abs",        "(= (abs -7) 7)");
  Check("max/min",    "(and (= (max 3 7 2) 7) (= (min 3 7 2) 2))");
  Check("even/odd",   "(and (even? 4) (odd? 7))");
  Check("zero/pos/neg","(and (zero? 0) (pos? 1) (neg? -1))");
  Check("sqrt",       "(< (abs (- (sqrt 2.0) 1.41421)) 0.001)");
  Check("floor/ceil", "(and (= (floor 3.7) 3) (= (ceil 3.2) 4))");
  Check("pow",        "(= (pow 2.0 10.0) 1024.0)");

  (* ── 2. Comparison & boolean ───────────────────────────────────────── *)
  Section("Comparison");
  Check("eq",         "(= 3 3)");
  Check("not-eq",     "(not= 3 4)");
  Check("lt/gt",      "(and (< 1 2 3) (> 3 2 1))");
  Check("le/ge",      "(and (<= 2 2 3) (>= 3 3 2))");
  Check("not",        "(and (not false) (not nil) (not (not true)))");
  Check("and short",  "(= false (and true false true))");
  Check("or short",   "(= 42 (or false nil 42))");
  Check("true?/false?","(and (true? true) (false? false))");

  (* ── 3. Strings ────────────────────────────────────────────────────── *)
  Section("Strings");
  Check("str concat",  '(= (str "foo" "bar") "foobar")');
  Check("str int",     '(= (str 42) "42")');
  Check("subs",        '(= (subs "hello" 1 3) "el")');
  Check("upper/lower", '(and (= (upper-case "hi") "HI") (= (lower-case "HI") "hi"))');
  Check("trim",        '(= (trim "  hi  ") "hi")');
  Check("split/join",  '(= (join "," (split "a,b,c" ",")) "a,b,c")');
  Check("starts-with?", '(starts-with? "foobar" "foo")');
  Check("ends-with?",   '(ends-with? "foobar" "bar")');
  Check("includes?",    '(includes? "foobar" "oba")');
  Check("name kw",     '(= (name :foo) "foo")');
  Check("keyword",     '(= (keyword "x") :x)');

  (* ── 4. Type predicates ────────────────────────────────────────────── *)
  Section("Type predicates");
  Check("nil?",       "(nil? nil)");
  Check("number?",    "(number? 3.14)");
  Check("integer?",   "(integer? 42)");
  Check("string?",    '(string? "hi")');
  Check("boolean?",   "(boolean? true)");
  Check("keyword?",   "(keyword? :x)");
  Check("symbol?",    "(symbol? (quote foo))");
  Check("list?",      "(list? (list 1 2))");
  Check("vector?",    "(vector? [1 2])");
  Check("map?",       "(map? {:a 1})");
  Check("fn?",        "(fn? +)");
  Check("seq?",       "(seq? [1 2 3])");
  Check("empty?",     "(empty? [])");

  (* ── 5. Lists ──────────────────────────────────────────────────────── *)
  Section("Lists");
  Check("list/count", "(= (count (list 1 2 3)) 3)");
  Check("cons",       "(= (first (cons 0 (list 1 2))) 0)");
  Check("first/rest", "(= (rest (list 1 2 3)) (list 2 3))");
  Check("second",     "(= (second (list 10 20 30)) 20)");
  Check("last",       "(= (last (list 1 2 3)) 3)");
  Check("nth",        "(= (nth (list 10 20 30) 1) 20)");
  Check("conj list",  "(= (conj (list 1 2) 0) (list 0 1 2))");
  Check("concat",     "(= (concat (list 1 2) (list 3 4)) (list 1 2 3 4))");
  Check("reverse",    "(= (reverse (list 1 2 3)) (list 3 2 1))");
  Check("flatten",    "(= (flatten (list 1 (list 2 (list 3)))) (list 1 2 3))");
  Check("distinct",   "(= (count (distinct (list 1 2 1 3 2))) 3)");

  (* ── 6. Vectors ────────────────────────────────────────────────────── *)
  Section("Vectors");
  Check("vec literal", "(= (count [1 2 3]) 3)");
  Check("get vec",     "(= (get [10 20 30] 1) 20)");
  Check("conj vec",    "(= (count (conj [1 2] 3)) 3)");
  Check("into vec",    "(= (count (into [0] (list 1 2 3))) 4)");

  (* ── 7. Maps ───────────────────────────────────────────────────────── *)
  Section("Maps");
  E("(def m {:a 1 :b 2 :c 3})");
  Check("get",         "(= (get m :b) 2)");
  Check("assoc",       "(= (get (assoc m :d 4) :d) 4)");
  Check("dissoc",      "(= (count (dissoc m :a)) 2)");
  Check("keys/vals",   "(= (count (keys m)) 3)");
  Check("merge",       "(= (get (merge m {:d 4}) :d) 4)");
  Check("contains?",   "(contains? m :a)");
  Check("get-in",      "(= (get-in {:a {:b 42}} [:a :b]) 42)");
  Check("assoc-in",    "(= (get-in (assoc-in {} [:x :y] 7) [:x :y]) 7)");
  Check("update",      "(= (get (update m :a inc) :a) 2)");
  Check("update-in",   "(= (get-in (update-in {:a {:b 1}} [:a :b] inc) [:a :b]) 2)");
  Check("select-keys", "(= (count (select-keys m [:a :c])) 2)");
  Check("frequencies", "(= (get (frequencies [:a :b :a]) :a) 2)");
  Check("group-by",    "(= (count (get (group-by even? [1 2 3 4]) true)) 2)");

  (* ── 8. Higher-order sequence ops ─────────────────────────────────── *)
  Section("Sequence ops");
  Check("map",         "(= (map inc [1 2 3]) (list 2 3 4))");
  Check("filter",      "(= (filter even? [1 2 3 4]) (list 2 4))");
  Check("reduce",      "(= (reduce + 0 [1 2 3 4 5]) 15)");
  Check("take/drop",   "(and (= (take 3 [1 2 3 4 5]) (list 1 2 3)) (= (count (drop 3 [1 2 3 4 5])) 2))");
  Check("take-while",  "(= (take-while odd? [1 3 2 4]) (list 1 3))");
  Check("drop-while",  "(= (drop-while even? [2 4 1 3]) (list 1 3))");
  Check("sort",        "(= (sort [3 1 2]) (list 1 2 3))");
  Check("sort-by",     '(= (first (sort-by count ["bb" "a" "ccc"])) "a")');
  Check("every?",      "(every? even? [2 4 6])");
  Check("some",        "(= (some even? [1 3 2 5]) true)");
  Check("not-any?",    "(not-any? neg? [1 2 3])");
  Check("mapcat",      "(= (mapcat (fn [x] [x x]) [1 2]) (list 1 1 2 2))");
  Check("keep",        "(= (keep (fn [x] (if (even? x) x nil)) [1 2 3 4]) (list 2 4))");
  Check("remove",      "(= (remove even? [1 2 3 4]) (list 1 3))");
  Check("partition",   "(= (count (partition 2 [1 2 3 4])) 2)");
  Check("interpose",   "(= (count (interpose 0 [1 2 3])) 5)");
  Check("range",       "(= (count (range 5)) 5)");
  Check("zipmap",      "(= (get (zipmap [:a :b] [1 2]) :a) 1)");

  (* ── 9. Functions and closures ─────────────────────────────────────── *)
  Section("Functions");
  E("(defn sq [x] (* x x))");
  Check("defn",        "(= (sq 5) 25)");
  E("(defn fact [n] (if (<= n 1) 1 (* n (fact (- n 1)))))");
  Check("recursion",   "(= (fact 10) 3628800)");
  E("(defn make-adder [n] (fn [x] (+ x n)))");
  E("(def add5 (make-adder 5))");
  Check("closure",     "(= (add5 10) 15)");
  E("(defn sumv [& args] (reduce + 0 args))");
  Check("varargs",     "(= (sumv 1 2 3 4) 10)");
  Check("apply",       "(= (apply + [1 2 3]) 6)");
  Check("comp",        "(= ((comp inc inc inc) 0) 3)");
  Check("partial",     "(= ((partial + 10) 5) 15)");
  Check("complement",  "((complement even?) 3)");
  Check("juxt",        "(= ((juxt inc dec) 5) (list 6 4))");
  Check("identity",    "(= (identity 42) 42)");

  (* ── 10. Let and destructuring ─────────────────────────────────────── *)
  Section("Let / destructuring");
  Check("let basic",   "(let [x 3 y 4] (= (* x y) 12))");
  Check("let seq",     "(let [[a b c] [1 2 3]] (= (+ a b c) 6))");
  Check("let map",     "(let [{:keys [x y]} {:x 10 :y 20}] (= (+ x y) 30))");
  Check("let rest",    "(let [[h & t] [1 2 3]] (= (first t) 2))");
  Check("let nested",  "(let [[a [b c]] [1 [2 3]]] (= (+ a b c) 6))");
  Check("letfn",       "(letfn [(double [x] (* x 2)) (triple [x] (* x 3))] (= (double (triple 2)) 12))");

  (* ── 11. Control flow ──────────────────────────────────────────────── *)
  Section("Control flow");
  Check("if true",     "(= (if true 1 2) 1)");
  Check("if false",    "(= (if false 1 2) 2)");
  Check("when true",   "(= (when true 42) 42)");
  Check("when false",  "(nil? (when false 42))");
  Check("when-not",    "(= (when-not false 99) 99)");
  Check("cond",        "(= (cond (= 1 2) :no (= 2 2) :yes) :yes)");
  Check("case",        "(= (case 2 1 :one 2 :two 3 :three) :two)");
  Check("do",          "(= (do 1 2 3) 3)");

  (* ── 12. Loops ─────────────────────────────────────────────────────── *)
  Section("Loops");
  E("(def lsum (atom 0))");
  E("(dotimes [i 5] (swap! lsum + i))");
  Check("dotimes",     "(= @lsum 10)");
  E("(reset! lsum 0)");
  E("(doseq [x [1 2 3 4]] (swap! lsum + x))");
  Check("doseq",       "(= @lsum 10)");
  Check("loop/recur",  "(= (loop [n 5 acc 1] (if (= n 0) acc (recur (- n 1) (* acc n)))) 120)");
  Check("for",         "(= (for [x [1 2 3] :when (odd? x)] (* x x)) (list 1 9))");

  (* ── 13. Threading macros ──────────────────────────────────────────── *)
  Section("Threading");
  Check("->",          "(= (-> 1 inc inc (* 3)) 9)");
  Check("->>",         "(= (->> [1 2 3] (map inc) (filter odd?)) (list 3))");

  (* ── 14. Macros and quasiquote ─────────────────────────────────────── *)
  Section("Macros");
  E("(defmacro my-and [a b] `(if ~a ~b false))");
  Check("defmacro",    "(and (my-and true true) (not (my-and true false)))");
  E("(defmacro my-list [& xs] `(list ~@xs))");
  Check("unquote-splice", "(= (my-list 1 2 3) (list 1 2 3))");
  E("(defmacro my-let1 [sym val & body] `(let [~sym ~val] ~@body))");
  Check("macro hygienic", "(= (my-let1 x 42 (* x 2)) 84)");
  Check("gensym unique",  "(not= (gensym) (gensym))");

  (* ── 15. Exception handling ─────────────────────────────────────────── *)
  Section("Exceptions");
  Check("try ok",      "(= (try 42) 42)");
  Check("catch throw", '(= (try (throw "boom") (catch Exception e e)) "boom")');
  Check("catch error", "(= (try (/ 1 0) (catch Exception e :caught)) :caught)");
  Check("finally runs", '(let [a (atom 0)] (try (+ 1 1) (finally (reset! a 99))) (= @a 99))');
  Check("nested try",  "(= (try (try (throw 1) (catch Exception e (+ e 1))) (catch Exception e :outer)) 2)");

  (* ── 16. Atoms ─────────────────────────────────────────────────────── *)
  Section("Atoms");
  E("(def counter (atom 0))");
  Check("atom init",   "(= @counter 0)");
  E("(swap! counter inc)");
  E("(swap! counter + 4)");
  Check("swap!",       "(= @counter 5)");
  E("(reset! counter 100)");
  Check("reset!",      "(= @counter 100)");
  Check("atom?",       "(atom? (atom 0))");

  (* ── 17. Delay ─────────────────────────────────────────────────────── *)
  Section("Delay");
  E("(def side (atom 0))");
  E("(def d (delay (do (swap! side inc) :done)))");
  Check("not forced yet", "(= @side 0)");
  E("(force d)");
  Check("forced once",    "(= @side 1)");
  E("(force d)");
  Check("cached (no re-eval)", "(= @side 1)");
  Check("force result",       "(= (force d) :done)");

  (* ── 18. defrecord ──────────────────────────────────────────────────── *)
  Section("Records");
  E("(defrecord Point [x y])");
  E("(def pt (->Point 3 4))");
  Check("constructor",  "(= (get pt :x) 3)");
  Check("fields",       "(= (get pt :y) 4)");
  Check("type tag",     '(= (get pt :__type__) "Point")');
  Check("predicate",    "(Point? pt)");
  Check("non-instance", "(not (Point? {:x 1}))");
  E("(defrecord Circle [r])");
  E("(def c (->Circle 5))");
  Check("two records",  "(and (Point? pt) (Circle? c) (not (Point? c)))");

  (* ── 19. Protocols ──────────────────────────────────────────────────── *)
  Section("Protocols");
  E("(defprotocol Shape (area [this]) (perimeter [this]))");
  E("(extend-type Point Shape (area [this] (* (get this :x) (get this :y))) (perimeter [this] (* 2 (+ (get this :x) (get this :y)))))");
  E("(extend-type Circle Shape (area [this] (* 3.14159 (get this :r) (get this :r))) (perimeter [this] (* 2 3.14159 (get this :r))))");
  Check("protocol dispatch Point area",  "(= (area pt) 12)");
  Check("protocol dispatch Point perim", "(= (perimeter pt) 14)");
  Check("protocol dispatch Circle area", "(< (abs (- (area c) 78.5)) 0.1)");
  Check("satisfies? true",  "(satisfies? (quote Shape) pt)");
  Check("satisfies? false", "(not (satisfies? (quote Shape) {:x 1}))");

  (* ── 20. Miscellaneous ──────────────────────────────────────────────── *)
  Section("Misc");
  Check("read-string",  '(= (read-string "(+ 1 2)") (list (quote +) 1 2))');
  Check("type",         "(= (type 42) :int)");
  Check("char/char-code","(= (char-code (char 65)) 65)");
  Check("int/float conv","(and (= (int 3.7) 3) (float? (float 3)))");
  Check("rand range",   "(let [r (rand)] (and (>= r 0.0) (< r 1.0)))");
  Check("rand-int range","(let [r (rand-int 10)] (and (>= r 0) (< r 10)))");
  Check("repeat",       "(= (count (repeat 5 :x)) 5)");
  Check("repeatedly",   "(= (count (repeatedly 3 rand)) 3)");
  Check("interleave",   "(= (count (interleave [1 2 3] [4 5 6])) 6)");
  Check("split-at",     "(= (first (split-at 2 [1 2 3 4])) [1 2])");
  Check("cycle prefix", "(= (count (cycle [1 2 3])) 1000)");
  Check("map-indexed",  "(= (map-indexed (fn [i x] (+ i 1)) [:a :b]) (list 1 2))");
  Check("shuffle count","(= (count (shuffle [1 2 3 4 5])) 5)");
  Check("not=",         "(not= 1 2)");
  Check("true!/false! strict","(and (true? true) (not (true? 1)))");

  (* ── 21. Sets ───────────────────────────────────────────────────────── *)
  Section("Sets");
  E("(def s (hash-set 1 2 3 2 1))");
  Check("set dedup",      "(= (count s) 3)");
  Check("set?",           "(set? s)");
  Check("set contains",   "(contains? s 2)");
  Check("set missing",    "(not (contains? s 9))");
  Check("set as fn",      "(= (s 3) 3)");
  Check("set as fn miss", "(nil? (s 9))");
  Check("conj set",       "(= (count (conj s 4)) 4)");
  Check("conj dup",       "(= (count (conj s 1)) 3)");
  Check("disj",           "(not (contains? (disj s 2) 2))");
  Check("set from coll",  "(= (count (set [1 2 3 2 1])) 3)");
  Check("union",          "(= (count (union (hash-set 1 2) (hash-set 2 3))) 3)");
  Check("intersection",   "(= (intersection (hash-set 1 2 3) (hash-set 2 3 4)) (hash-set 2 3))");
  Check("difference",     "(= (difference (hash-set 1 2 3) (hash-set 2 3)) (hash-set 1))");
  Check("subset?",        "(subset? (hash-set 1 2) (hash-set 1 2 3))");
  Check("superset?",      "(superset? (hash-set 1 2 3) (hash-set 2 3))");
  Check("sorted-set ord", "(= (first (seq (sorted-set 3 1 2))) 1)");
  Check("sorted-set?",    "(sorted-set? (sorted-set 1 2))");
  Check("set seq",        "(= (count (seq s)) 3)");

  (* ── 22. Multi-arity functions ──────────────────────────────────────── *)
  Section("Multi-arity");
  E('(defn greet ([] "hello") ([name] (str "hello " name)))');
  Check("0-arity",        '(= (greet) "hello")');
  Check("1-arity",        '(= (greet "world") "hello world")');
  E("(defn add ([] 0) ([x] x) ([x y] (+ x y)) ([x y z] (+ x y z)))");
  Check("add/0",          "(= (add) 0)");
  Check("add/1",          "(= (add 7) 7)");
  Check("add/2",          "(= (add 3 4) 7)");
  Check("add/3",          "(= (add 1 2 3) 6)");
  E("(def g (fn ([] :zero) ([x] :one) ([x y] :two)))");
  Check("fn multi 0",     "(= (g) :zero)");
  Check("fn multi 1",     "(= (g 42) :one)");
  Check("fn multi 2",     "(= (g 1 2) :two)");
  Check("wrong arity err","(try (g 1 2 3) (catch Exception e true))");

  (* ── 23. Variadic functions ─────────────────────────────────────────── *)
  Section("Variadic");
  E("(defn vsum [& xs] (reduce + 0 xs))");
  Check("varargs 0",      "(= (vsum) 0)");
  Check("varargs 1",      "(= (vsum 5) 5)");
  Check("varargs many",   "(= (vsum 1 2 3 4 5) 15)");
  E("(defn vhead [x & rest] (list x (count rest)))");
  Check("required+rest",  "(= (vhead 10 20 30) (list 10 2))");
  Check("required only",  "(= (vhead 99) (list 99 0))");
  E("(defn dispatch ([x] (* x x)) ([x & more] (apply + x more)))");
  Check("multi+varadic 1","(= (dispatch 5) 25)");
  Check("multi+varadic 3","(= (dispatch 1 2 3) 6)");
  Check("apply variadic", "(= (apply vsum [1 2 3]) 6)");

  (* ── 24. Regular expressions ────────────────────────────────────────── *)
  Section("Regex");
  Check("literal",        '(= (re-find #"\d+" "abc123") "123")');
  Check("no match nil",   '(nil? (re-find #"\d+" "abc"))');
  Check("re-pattern str", '(= (re-find (re-pattern "\\d+") "x42") "42")');
  Check("re-pattern eq",  '(= #"\d+" #"\d+")');
  Check("re-pattern neq", '(not (= #"\d+" #"\w+"))');
  Check("groups vector",  '(= (re-find #"(\w+)@(\w+)" "u@h") ["u@h" "u" "h"])');
  Check("group nil",      '(nil? (nth (re-find #"(\d+)(-(\d+))?" "42") 2))');
  Check("re-matches ok",  '(= (re-matches #"\d+" "123") "123")');
  Check("re-matches fail",'(nil? (re-matches #"\d+" "12x"))');
  Check("re-matches grp", '(= (re-matches #"(\d+)-(\d+)" "5-9") ["5-9" "5" "9"])');
  Check("re-seq nums",    '(= (re-seq #"\d+" "a1b22c3") (list "1" "22" "3"))');
  Check("re-seq groups",  '(= (count (re-seq #"(\w+)" "a b")) 2)');
  Check("re-seq empty",   '(nil? (re-seq #"\d+" "abc"))');
  Check("re-replace all", '(= (re-replace "foo bar" #"\w+" "X") "X X")');
  Check("re-replace vowel",'(= (re-replace "hello" #"[aeiou]" "*") "h*ll*")');
  Check("re-replace none", '(= (re-replace "xyz" #"\d+" "N") "xyz")');
  Check("shorthand \\d",  '(= (re-find #"\d+" "test9") "9")');
  Check("shorthand \\w",  '(= (re-find #"\w+" "hello world") "hello")');
  Check("shorthand \\s",  '(= (re-find #"\s+" "a  b") "  ")');
  Check("anchors",        '(nil? (re-find #"^\d+$" "12x"))');
  Check("anchor match",   '(= (re-find #"^\d+" "42abc") "42")');
  Check("anchor end",     '(= (re-find #"\d+$" "abc99") "99")');
  Check("alternation",    '(= (re-find #"cat|dog" "I have a dog") "dog")');
  Check("dot",            '(= (re-find #"h.t" "the hat") "hat")');
  Check("char range",     '(= (re-find #"[a-z]+" "123abc456") "abc")');
  Check("negated class",  '(= (re-find #"[^0-9]+" "123abc") "abc")');
  Check("quantifier {n}", '(= (re-find #"\d{3}" "12 345 6789") "345")');
  Check("quantifier {n,m}",'(= (re-find #"a{2,4}" "baaab") "aaa")');
  Check("shorthand \\D",  '(= (re-find #"\D+" "123abc") "abc")');
  Check("shorthand \\W",  '(= (re-find #"\W+" "abc   def") "   ")');
  Check("shorthand \\S",  '(= (re-find #"\S+" "  hello") "hello")');
  Check("re-seq grp vec", '(= (first (re-seq #"(\w+)" "hi")) ["hi" "hi"])');
  Check("re-seq all grps",'(= (map first (re-seq #"(\w+)" "a b")) (list "a" "b"))');
  Check("nested groups",  '(= (re-find #"((a)(b))" "xaby") ["ab" "ab" "a" "b"])');

  (* ── 25. clojure.string methods ─────────────────────────────────────── *)
  Section("clojure.string");
  Check("blank? empty",     '(string/blank? "")');
  Check("blank? spaces",    '(string/blank? "   ")');
  Check("blank? nil",       "(string/blank? nil)");
  Check("blank? false",     '(not (string/blank? "hi"))');
  Check("capitalize",       '(= (string/capitalize "hello world") "Hello world")');
  Check("capitalize upper", '(= (string/capitalize "HELLO") "Hello")');
  Check("reverse",          '(= (string/reverse "abcde") "edcba")');
  Check("reverse empty",    '(= (string/reverse "") "")');
  Check("triml",            '(= (string/triml "  hi  ") "hi  ")');
  Check("trimr",            '(= (string/trimr "  hi  ") "  hi")');
  Check("trim-newline",     '(= (string/trim-newline "hello\n") "hello")');
  Check("trim-newline crlf",'(= (string/trim-newline "hi\r\n") "hi")');
  Check("split-lines",      '(= (string/split-lines "a\nb\nc") (list "a" "b" "c"))');
  Check("split-lines 1",    '(= (string/split-lines "only") (list "only"))');
  Check("index-of found",   '(= (string/index-of "hello" "l") 2)');
  Check("index-of from",    '(= (string/index-of "hello" "l" 3) 3)');
  Check("index-of nil",     '(nil? (string/index-of "hello" "z"))');
  Check("last-index-of",    '(= (string/last-index-of "hello" "l") 3)');
  Check("last-index-of nil",'(nil? (string/last-index-of "hello" "z"))');
  Check("replace str all",  '(= (string/replace "hello world" "o" "0") "hell0 w0rld")');
  Check("replace regex",    '(= (string/replace "foo bar" #"\w+" "X") "X X")');
  Check("replace none",     '(= (string/replace "abc" "z" "X") "abc")');
  Check("replace-first str",'(= (string/replace-first "aabbcc" "b" "X") "aaXbcc")');
  Check("replace-first re", '(= (string/replace-first "foo bar" #"\w+" "X") "X bar")');
  Check("replace-first nil",'(= (string/replace-first "abc" "z" "X") "abc")');
  (* existing string/ aliases still work *)
  Check("upper-case",       '(= (string/upper-case "hello") "HELLO")');
  Check("lower-case",       '(= (string/lower-case "HELLO") "hello")');
  Check("trim",             '(= (string/trim "  hi  ") "hi")');
  Check("starts-with?",     '(string/starts-with? "foobar" "foo")');
  Check("ends-with?",       '(string/ends-with? "foobar" "bar")');
  Check("includes?",        '(string/includes? "foobar" "oba")');
  Check("join sep",         '(= (string/join ", " ["a" "b" "c"]) "a, b, c")');
  Check("join no sep",      '(= (string/join ["a" "b" "c"]) "abc")');

  (* ── Summary ────────────────────────────────────────────────────────── *)
  Out.Ln;
  Out.String("Results: ");
  Out.Int(passCount, 0); Out.String(" passed, ");
  Out.Int(failCount, 0); Out.String(" failed.");
  Out.Ln;
  IF failCount = 0 THEN Out.String("All tests passed.") ELSE Out.String("FAILURES detected.") END;
  Out.Ln
END testcloj.
