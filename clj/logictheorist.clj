;;; ═══ LOGIC THEORIST (Newell, Simon & Shaw, 1956) ═══════════════════════════
;;;
;;; The first AI program. Built at RAND for the JOHNNIAC, it proved theorems
;;; from chapter 2 of Whitehead & Russell's "Principia Mathematica" -- and in
;;; one case (*2.85) found a shorter proof than the original.
;;;
;;; LT worked on the propositional calculus, whose only primitives are
;;; negation (~) and disjunction (v); implication (p => q) is shorthand for
;;; (~p v q). Starting from five axioms, it searched BACKWARD from a goal
;;; formula toward those axioms using three methods:
;;;
;;;   Substitution  -- an axiom's variables may be instantiated with any
;;;                    well-formed formula, so a goal matching an axiom's
;;;                    shape exactly is proved outright.
;;;   Detachment    -- modus ponens, applied backward: to prove Q, find a
;;;                    known theorem "P => Q'" whose consequent Q' matches Q,
;;;                    then recursively try to prove the antecedent P.
;;;   Replacement   -- goals can be rewritten into logically equivalent forms
;;;                    (De Morgan-style identities) in hope that the rewritten
;;;                    form is easier to match or detach.
;;;
;;; Every theorem LT manages to prove is added to its library, so that later
;;; problems can build on earlier ones -- exactly as Newell & Simon fed it
;;; the Principia problems in book order.

;; ═══ 1. THE MATCHING ENGINE ═════════════════════════════════════════════════
;; Formulas are vectors: [:not A], [:or A B], [:implies A B], or a bare
;; symbol for a propositional letter. Pattern (schema) variables are symbols
;; whose name starts with "?", e.g. '?p -- they may match any subformula.

(defn variable? [x]
  (and (symbol? x) (starts-with? (name x) "?")))

;; Attempts to unify pattern `pat` against formula `expr`, extending `subst`.
;; Returns the extended substitution map, or nil on failure.
(defn match [pat expr subst]
  (cond
    (nil? subst) nil
    (variable? pat)
      (if (contains? subst pat)
        (if (= (get subst pat) expr) subst nil)
        (assoc subst pat expr))
    (vector? pat)
      (if (and (vector? expr) (= (count pat) (count expr)))
        (loop [i 0 s subst]
          (if (>= i (count pat))
            s
            (let [s2 (match (nth pat i) (nth expr i) s)]
              (if (nil? s2) nil (recur (inc i) s2)))))
        nil)
    :else (if (= pat expr) subst nil)))

;; Instantiates pattern `pat` by replacing schema variables per `subst`.
(defn apply-subst [pat subst]
  (cond
    (variable? pat) (get subst pat pat)
    (vector? pat) (vec (map (fn [x] (apply-subst x subst)) pat))
    :else pat))

;; All one-step rewrites of `tree` obtained by matching `lhs` against some
;; subterm (at any depth) and replacing it with the instantiated `rhs`.
(defn rewrite-all [tree lhs rhs]
  (let [top (let [m (match lhs tree {})]
              (if (nil? m) [] [(apply-subst rhs m)]))
        kids (if (vector? tree)
               (apply concat
                 (map-indexed
                   (fn [i sub]
                     (if (= i 0)
                       []
                       (map (fn [r] (vec (map-indexed (fn [j x] (if (= j i) r x)) tree)))
                            (rewrite-all sub lhs rhs))))
                   tree))
               [])]
    (concat top kids)))

(defn rewrite-dirs [goal dirs]
  (apply concat (map (fn [d] (rewrite-all goal (first d) (second d))) dirs)))

;; ═══ 2. THE FIVE PRIMITIVE AXIOMS (Principia Mathematica *1.2-*1.6) ════════

(def axioms
  [{:num "1.2" :name "Taut"  :whole [:implies [:or '?p '?p] '?p]}
   {:num "1.3" :name "Add"   :whole [:implies '?q [:or '?p '?q]]}
   {:num "1.4" :name "Perm"  :whole [:implies [:or '?p '?q] [:or '?q '?p]]}
   {:num "1.5" :name "Assoc" :whole [:implies [:or '?p [:or '?q '?r]] [:or '?q [:or '?p '?r]]]}
   {:num "1.6" :name "Sum"   :whole [:implies [:implies '?q '?r]
                                               [:implies [:or '?p '?q] [:or '?p '?r]]]}])

;; Replacement rules ("methods of replacement" in LT's own terms). Each is
;; a list of the [lhs rhs] direction(s) safe to try. Double-Neg and
;; Idempotence are one-directional: their "expanding" direction has a bare
;; variable on the left, which would match literally any subterm and blow
;; up the search for no benefit.
(def equivalences
  [{:name "Def-Implies" :dirs [[[:implies '?A '?B] [:or [:not '?A] '?B]]
                                [[:or [:not '?A] '?B] [:implies '?A '?B]]]}
   {:name "Double-Neg"  :dirs [[[:not [:not '?A]] '?A]]}
   {:name "Idempotence" :dirs [[[:or '?A '?A] '?A]]}
   {:name "Commute-Or"  :dirs [[[:or '?A '?B] [:or '?B '?A]]]}
   {:name "Assoc-Or"    :dirs [[[:or '?A [:or '?B '?C]] [:or [:or '?A '?B] '?C]]
                                [[:or [:or '?A '?B] '?C] [:or '?A [:or '?B '?C]]]]}])

;; ═══ 3. THE SEARCH ══════════════════════════════════════════════════════════
;; `prove` searches backward from a goal with a limited step "budget",
;; caching results so overlapping subgoals (which arise constantly, since
;; several methods often converge on the same intermediate formula) are
;; only solved once.

(def memo (atom {}))

(defn try-axiom-direct [goal library]
  (some (fn [thm]
          (let [m (match (:whole thm) goal {})]
            (if (nil? m) nil {:type :axiom :num (:num thm) :name (:name thm) :goal goal})))
        library))

;; A theorem whose consequent is a bare schema variable would match *any*
;; goal via detachment, giving no real guidance -- so it is excluded here.
;; (Axiom 1.2/Taut is the only such axiom; it remains usable in its proper,
;; fully-shaped form via try-axiom-direct.)
(defn useful-for-detachment? [thm]
  (not (variable? (nth (:whole thm) 2))))

(defn try-detachment [goal budget library]
  (some (fn [thm]
          (let [consequent (nth (:whole thm) 2)
                m (match consequent goal {})]
            (if (nil? m)
              nil
              (let [ante (apply-subst (nth (:whole thm) 1) m)
                    sub (prove ante (dec budget) library)]
                (if (nil? sub)
                  nil
                  {:type :detachment :num (:num thm) :name (:name thm)
                   :goal goal :antecedent ante :sub sub})))))
        (filter useful-for-detachment? library)))

(defn try-replacement [goal budget library]
  (some (fn [eq]
          (let [alts (rewrite-dirs goal (:dirs eq))]
            (some (fn [alt]
                    (if (= alt goal)
                      nil
                      (let [sub (prove alt (dec budget) library)]
                        (if (nil? sub)
                          nil
                          {:type :replacement :rule (:name eq)
                           :goal goal :rewritten alt :sub sub}))))
                  alts)))
        equivalences))

;; A hard cap on total search steps. Without it, an *unprovable* goal forces
;; the search to exhaust its entire (potentially huge) tree before giving up
;; -- unlike a successful search, there is no early exit. This bounds worst-
;; case running time regardless of budget or library size.
(def max-calls 15000)
(def call-count (atom 0))

(defn prove [goal budget library]
  (swap! call-count inc)
  (if (> @call-count max-calls)
    nil
    (let [cached (get @memo goal nil)]
      (cond
        (and cached (= (:status cached) :proved) (>= budget (:cost cached)))
          (:proof cached)
        (and cached (= (:status cached) :failed) (<= budget (:budget cached)))
          nil
        (<= budget 0)
          nil
        :else
          (let [result (or (try-axiom-direct goal library)
                            (try-detachment goal budget library)
                            (try-replacement goal budget library))]
            (if (nil? result)
              (swap! memo assoc goal {:status :failed :budget budget})
              (swap! memo assoc goal {:status :proved :cost budget :proof result}))
            result)))))

;; Iterative deepening: try increasing step budgets so the first proof found
;; is also the shortest one this search order can reach -- LT's own notion
;; of an "elegant" proof.
(defn prove-best [goal max-budget library]
  (loop [b 1]
    (if (> b max-budget)
      nil
      (let [result (prove goal b library)]
        (if (nil? result) (recur (inc b)) result)))))

;; ═══ 4. PRETTY-PRINTING ═════════════════════════════════════════════════════

(defn display-name [sym]
  (let [n (name sym)]
    (if (starts-with? n "?") (subs n 1) n)))

(defn fmt [f]
  (cond
    (symbol? f) (display-name f)
    (vector? f)
      (cond
        (= (first f) :not) (str "~" (fmt (nth f 1)))
        (= (first f) :or) (str "(" (fmt (nth f 1)) " v " (fmt (nth f 2)) ")")
        (= (first f) :implies) (str "(" (fmt (nth f 1)) " => " (fmt (nth f 2)) ")")
        :else (str f))
    :else (str f)))

;; Flattens a proof tree into an ordered list of {:formula :reason} steps,
;; foundation first -- the way a written-out mathematical proof reads.
(defn proof-lines [proof]
  (case (:type proof)
    :axiom [{:formula (:goal proof)
             :reason (str "Axiom " (:num proof) " (" (:name proof) "), by substitution")}]
    :detachment
      (conj (vec (proof-lines (:sub proof)))
            {:formula (:goal proof)
             :reason (str "from the line above, by detachment via "
                          (:name proof) " (" (:num proof) ")")})
    :replacement
      (conj (vec (proof-lines (:sub proof)))
            {:formula (:goal proof)
             :reason (str "rewriting the line above by " (:rule proof))})))

(defn print-proof [proof]
  (let [lines (proof-lines proof)]
    (loop [i 1 ls lines]
      (when-not (empty? ls)
        (println (str "  " i ". " (fmt (:formula (first ls))) "   [" (:reason (first ls)) "]"))
        (recur (inc i) (rest ls))))
    (println (str "  Q.E.D.  (" (count lines) " steps)"))))

(defn print-axioms []
  (doseq [ax axioms]
    (println (str "  *" (:num ax) " (" (:name ax) ")   " (fmt (:whole ax))))))

;; ═══ 5. THE CURATED PROBLEM SET ═════════════════════════════════════════════
;; Proved once at startup, in order, each added to the growing library so
;; later problems may reuse earlier results -- just as LT was run against
;; the Principia problems in book order.

(def problems
  [{:label "Absorption"
    :desc  "a v (a v b) => (a v b)"
    :goal  [:implies [:or '?a [:or '?a '?b]] [:or '?a '?b]]
    :budget 5}
   {:label "Absorption (regrouped)"
    :desc  "(a v a) v b => (a v b)"
    :goal  [:implies [:or [:or '?a '?a] '?b] [:or '?a '?b]]
    :budget 5}
   {:label "Rotation"
    :desc  "a v (b v c) => c v (a v b)"
    :goal  [:implies [:or '?a [:or '?b '?c]] [:or '?c [:or '?a '?b]]]
    :budget 5}
   {:label "Law of Identity"
    :desc  "p => p"
    :goal  [:implies '?p '?p]
    :budget 6}
   {:label "Double Negation (elimination)"
    :desc  "~~p => p"
    :goal  [:implies [:not [:not '?p]] '?p]
    :budget 6}
   {:label "Double Negation (introduction)"
    :desc  "p => ~~p"
    :goal  [:implies '?p [:not [:not '?p]]]
    :budget 6}
   {:label "Extended Absorption"
    :desc  "p v (q v (p v q)) => (p v q)"
    :goal  [:implies [:or '?p [:or '?q [:or '?p '?q]]] [:or '?p '?q]]
    :budget 6}])

(defn solve-problems! [probs starting-library]
  (let [library (atom starting-library)
        results (atom [])]
    (doseq [prob probs]
      (reset! memo {})
      (reset! call-count 0)
      (let [proof (prove-best (:goal prob) (:budget prob) @library)
            thm-num (str "D" (inc (count @results)))]
        (println (str "Proving " (:label prob) " (" (:desc prob) ") ..."))
        (if (nil? proof)
          (println "  search exhausted -- no proof found within the step budget.")
          (do
            (println (str "  found a proof; added to the library as Theorem "
                          thm-num "."))
            (swap! library conj {:num thm-num :name (:label prob) :whole (:goal prob)})))
        (swap! results conj {:label (:label prob) :desc (:desc prob)
                              :num thm-num :proof proof})))
    {:library @library :results @results}))

(println "Building the theorem library (this mirrors the order Newell &")
(println "Simon fed problems to the original LT, each solved proof becoming")
(println "available to the next)...")
(println)
(def solved (solve-problems! problems axioms))
(def theorem-library (:library solved))
(def demo-results (:results solved))
(println)

;; ═══ 6. INTERACTIVE SESSION ═════════════════════════════════════════════════

(defn list-demos []
  (println "Proved theorems (pick a number to see the proof):")
  (loop [i 1 rs demo-results]
    (when-not (empty? rs)
      (let [r (first rs)]
        (println (str "  " i ". " (:label r) "   " (:desc r)
                      (if (nil? (:proof r)) "   [unsolved]" ""))))
      (recur (inc i) (rest rs)))))

(defn show-demo [n]
  (if (or (< n 1) (> n (count demo-results)))
    (println "No such theorem. Type 'list' to see the numbered list.")
    (let [r (nth demo-results (dec n))]
      (println (str (:label r) ":  " (fmt (:goal (nth problems (dec n))))))
      (if (nil? (:proof r))
        (println "  (LT could not find a proof of this within its step budget.)")
        (print-proof (:proof r))))))

(defn valid-formula? [f]
  (cond
    (symbol? f) (not (variable? f))
    (vector? f)
      (cond
        (and (= (count f) 2) (= (first f) :not)) (valid-formula? (nth f 1))
        (and (= (count f) 3) (or (= (first f) :or) (= (first f) :implies)))
          (and (valid-formula? (nth f 1)) (valid-formula? (nth f 2)))
        :else false)
    :else false))

(defn attempt-custom [line]
  (let [parsed (try (read-string line) (catch Exception e nil))]
    (cond
      (nil? parsed)
        (println "Couldn't parse that. Example: [:implies [:or p q] [:or q p]]")
      (not (valid-formula? parsed))
        (do
          (println "That isn't a well-formed formula. Use [:not A], [:or A B],")
          (println "[:implies A B], and plain symbols for propositional letters."))
      :else
        (do
          (reset! memo {})
          (reset! call-count 0)
          (println (str "LT is attempting to prove: " (fmt parsed)))
          (println "  (searching by substitution, detachment, and replacement...)")
          (let [proof (prove-best parsed 6 theorem-library)]
            (if (nil? proof)
              (println "  search exhausted its step budget -- no proof found.")
              (print-proof proof)))))))

(defn print-help []
  (println "Commands:")
  (println "  list            -- list the proved theorems")
  (println "  axioms          -- show the five primitive axioms")
  (println "  <number>        -- show the proof of that theorem")
  (println "  prove <formula> -- ask LT to prove your own formula, e.g.")
  (println "                     prove [:implies [:or p q] [:or q p]]")
  (println "  help            -- this message")
  (println "  quit            -- exit"))

(defn parse-int [s]
  (let [n (try (read-string s) (catch Exception e nil))]
    (if (number? n) n nil)))

(defn lt-loop []
  (let [input (read-line "LT> ")]
    (when-not (nil? input)
      (let [line (trim input)]
        (cond
          (or (= line "quit") (= line "exit") (= line "q"))
            (println "Ending session.")
          (= line "")
            (lt-loop)
          (= line "help")
            (do (print-help) (lt-loop))
          (= line "list")
            (do (list-demos) (lt-loop))
          (= line "axioms")
            (do (print-axioms) (lt-loop))
          (starts-with? line "prove ")
            (do (attempt-custom (subs line 6)) (lt-loop))
          :else
            (let [n (parse-int line)]
              (if (number? n)
                (show-demo n)
                (println "Unrecognized command. Type 'help' for options."))
              (lt-loop)))))))

(defn logic-theorist []
  (println "LOGIC THEORIST (Newell, Simon & Shaw, 1956)")
  (println "================================================")
  (println "The first AI program. It proves theorems of the propositional")
  (println "calculus by searching backward from a goal toward the five")
  (println "axioms of Principia Mathematica, using substitution, detachment")
  (println "(modus ponens), and replacement (rewriting by equivalence).")
  (println)
  (println "The five axioms:")
  (print-axioms)
  (println)
  (list-demos)
  (println)
  (println "Type 'help' for commands, or a number to see a proof.")
  (println)
  (lt-loop))

(logic-theorist)
