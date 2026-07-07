; SHRDLU - Blocks World Natural Language System (Winograd 1972)
; Run: examples/clojrepl clj/shrdlu.clj
;
; Initial scene on the table:
;   A — large red block   (B on top)
;   B — small green block (on A, clear)
;   C — large blue block  (D on top)
;   D — small red pyramid (on C, clear)
;   E — large green block (clear)

;;; ═══ WORLD STATE ════════════════════════════════════════════════════════════

; Block: {:id "A" :color "red" :size "large" :shape "block" :on "table"|block-id}
; world: {:blocks {...} :hand nil|id :it nil|id}

(def world (atom
  {:blocks
   {"A" {:id "A" :color "red"   :size "large" :shape "block"   :on "table"}
    "B" {:id "B" :color "green" :size "small" :shape "block"   :on "A"}
    "C" {:id "C" :color "blue"  :size "large" :shape "block"   :on "table"}
    "D" {:id "D" :color "red"   :size "small" :shape "pyramid" :on "C"}
    "E" {:id "E" :color "green" :size "large" :shape "block"   :on "table"}}
   :hand nil
   :it   nil}))

(defn wblocks [] (:blocks @world))
(defn whand   [] (:hand @world))
(defn wit     [] (:it @world))
(defn wblk    [id] (get (wblocks) id))

(defn clear? [id]
  (nil? (some (fn [b] (when (= (:on b) id) true)) (vals (wblocks)))))

(defn on-top [id]
  (first (filter (fn [bid] (= (:on (wblk bid)) id)) (keys (wblocks)))))

(defn tower-above [id]
  ; returns block ids from immediately above id up to the top
  (let [t (on-top id)]
    (if t (cons t (tower-above t)) [])))

;;; ═══ DESCRIPTIONS ═══════════════════════════════════════════════════════════

(defn describe [x]
  (let [b (if (string? x) (wblk x) x)]
    (if (nil? b) "nothing"
      (str "the " (:size b) " " (:color b) " " (:shape b)))))

(defn loc-str [id]
  (let [on (:on (wblk id))]
    (cond (= on "table") "on the table"
          (= on "hand")  "in my hand"
          :else          (str "on " (describe on)))))

;;; ═══ NP VOCABULARY ══════════════════════════════════════════════════════════

(def color-vocab #{"red" "blue" "green" "yellow" "white" "orange" "purple"})
(def size-vocab  #{"large" "small" "big" "little" "tiny" "huge"})
(def shape-vocab #{"block" "blocks" "pyramid" "pyramids" "box" "boxes" "cube" "cubes"})
(def det-vocab   #{"the" "a" "an" "any" "each" "every"})

(defn norm-shape [w]
  (get {"blocks" "block" "pyramids" "pyramid" "boxes" "box"
        "cubes" "block" "cube" "block"} w w))

(defn norm-size [w]
  (get {"big" "large" "huge" "large" "little" "small" "tiny" "small"} w w))

;;; ═══ NP MATCHING ════════════════════════════════════════════════════════════

; A desc-map: {:color :size :shape :pred :specific-id :is-table}
; :pred is a fn block→bool for relative clause constraints

(defn match-desc? [b desc]
  (and (or (nil? (:color desc)) (= (:color b) (:color desc)))
       (or (nil? (:size desc))  (= (:size b)  (:size desc)))
       (or (nil? (:shape desc)) (= (:shape b) (:shape desc)))
       (or (nil? (:pred desc))  ((:pred desc) b))))

(defn find-blocks [desc]
  (if (:specific-id desc)
    (let [b (wblk (:specific-id desc))]
      (if b [b] []))
    (filter (fn [b] (match-desc? b desc)) (vals (wblocks)))))

(defn resolve-np [desc]
  ; Returns {:ok block} {:error msg} or {:table true}
  (cond
    (:is-table desc) {:table true}
    (:specific-id desc)
    (let [b (wblk (:specific-id desc))]
      (if b {:ok b} {:error "I can't find what you're referring to."}))
    :else
    (let [bs (find-blocks desc)]
      (cond
        (= (count bs) 1) {:ok (first bs)}
        (> (count bs) 1) {:error "I see more than one such block. Please be more specific."}
        :else {:error "I don't see any such block."}))))

;;; ═══ NP PARSER ══════════════════════════════════════════════════════════════

; All parse-* functions take a token list and return [result remaining-tokens].
; parse-np and parse-rel-clause are mutually recursive.
; In Cloj, defn bodies are evaluated at call time, so forward references work.

(defn skip-det [tokens]
  (if (and (not (empty? tokens)) (contains? det-vocab (first tokens)))
    (rest tokens) tokens))

(defn parse-adjs [tokens desc]
  (if (empty? tokens) [desc tokens]
    (let [w (first tokens)]
      (cond
        (contains? color-vocab w)
        (parse-adjs (rest tokens) (assoc desc :color w))
        (contains? size-vocab w)
        (parse-adjs (rest tokens) (assoc desc :size (norm-size w)))
        :else [desc tokens]))))

; on-pred: block b is on a block matching np2
(defn on-pred [np2]
  (fn [b]
    (let [sup-id (:on b)]
      (cond
        (= sup-id "table") (:is-table np2)
        (:is-table np2) false
        (:specific-id np2) (= sup-id (:specific-id np2))
        :else
        (let [sup (wblk sup-id)]
          (if sup (match-desc? sup np2) false))))))

; parse-rel-clause: parse predicate after "that is" / "which is" / "on"
(defn parse-rel-clause [tokens desc]
  (if (empty? tokens) [desc tokens]
    (let [w (first tokens)
          rest-t (rest tokens)]
      (cond
        ; "on <NP>"
        (= w "on")
        (let [[np2 rest2] (parse-np rest-t)]
          (if np2
            [(assoc desc :pred (on-pred np2)) rest2]
            [desc tokens]))

        ; "clear" / "empty"
        (or (= w "clear") (= w "empty"))
        [(assoc desc :pred (fn [b] (clear? (:id b)))) rest-t]

        ; "support(s) <NP>"
        (or (= w "support") (= w "supports") (= w "supporting"))
        (let [[np2 rest2] (parse-np (skip-det rest-t))]
          (if np2
            [(assoc desc :pred
               (fn [b]
                 (let [t (on-top (:id b))]
                   (if t
                     (if (:specific-id np2)
                       (= t (:specific-id np2))
                       (match-desc? (wblk t) np2))
                     false))))
             rest2]
            [desc tokens]))

        ; "in <NP>" → treat as "on <NP>"
        (= w "in")
        (let [[np2 rest2] (parse-np rest-t)]
          (if np2
            [(assoc desc :pred (on-pred np2)) rest2]
            [desc tokens]))

        :else [desc tokens]))))

(defn parse-np [tokens]
  (if (empty? tokens) [nil tokens]
    (let [w0 (first tokens)]
      (cond
        ; "it" — pronoun referring to last mentioned block
        (= w0 "it")
        (if (wit)
          [{:specific-id (wit)} (rest tokens)]
          [{} (rest tokens)])

        ; "the table" — special location reference
        (and (contains? det-vocab w0)
             (= (first (rest tokens)) "table"))
        [{:is-table true} (drop 2 tokens)]

        ; regular NP: [det] [adj*] noun [rel-clause]
        :else
        (let [tokens1 (skip-det tokens)
              id-tok (first tokens1)]
          (let [id-up (when (and id-tok (= (count id-tok) 1)) (upper-case id-tok))]
            (if (and id-up (wblk id-up))
              [{:specific-id id-up} (rest tokens1)]
              (let [[desc tokens2] (parse-adjs tokens1 {})
                    noun (when (and (not (empty? tokens2))
                                    (contains? shape-vocab (first tokens2)))
                           (norm-shape (first tokens2)))
                    tokens3 (if noun (rest tokens2) tokens2)
                    desc (if noun (assoc desc :shape noun) desc)
                    id-tok2 (first tokens3)
                    id-up2 (when (and id-tok2 (= (count id-tok2) 1)) (upper-case id-tok2))
                    [desc tokens3] (if (and id-up2 (wblk id-up2))
                                     [(assoc desc :specific-id id-up2) (rest tokens3)]
                                     [desc tokens3])]
              (if (and (empty? desc) (nil? noun))
                [nil tokens]   ; nothing recognised
                ; check for relative clause
                (let [rc-w (first tokens3)]
                  (cond
                ; "that is …" / "which is …"
                (and rc-w
                     (or (= rc-w "that") (= rc-w "which"))
                     (let [w2 (first (rest tokens3))]
                       (or (= w2 "is") (= w2 "are"))))
                (parse-rel-clause (drop 2 tokens3) desc)

                ; short "on <NP>"
                (= rc-w "on")
                (parse-rel-clause tokens3 desc)

                ; short "in <NP>"
                (= rc-w "in")
                (parse-rel-clause tokens3 desc)

                :else [desc tokens3])))))))))))

;;; ═══ WORLD MANIPULATION ═════════════════════════════════════════════════════

(defn place-on-table! [id]
  (swap! world assoc-in [:blocks id :on] "table"))

(defn do-pickup! [b-id]
  ; Pick up b-id. Returns list of action strings. Side-effects world.
  ; Automatically: puts down held block, clears tower above b-id.
  (let [actions (atom [])]
    ; Put down currently held block if any
    (when (whand)
      (let [held (whand)]
        (place-on-table! held)
        (swap! world assoc :hand nil)
        (swap! actions conj (str "I put down " (describe held) "."))))
    ; Clear tower above b-id (top → bottom order)
    (doseq [above-id (reverse (tower-above b-id))]
      (place-on-table! above-id)
      (swap! actions conj (str "I move " (describe above-id) " to the table.")))
    ; Pick up
    (swap! world assoc-in [:blocks b-id :on] "hand")
    (swap! world assoc :hand b-id)
    (swap! world assoc :it b-id)
    @actions))

(defn clear-top-of! [target-id]
  ; Move everything off target-id. Returns action strings.
  (if (clear? target-id)
    []
    (let [actions (atom [])
          above (tower-above target-id)]
      (doseq [id (reverse above)]
        (place-on-table! id)
        (swap! actions conj (str "I move " (describe id) " to the table.")))
      @actions)))

(defn do-put-on! [b-id target-id]
  ; Put b-id on target-id ("table" or block-id). Returns action strings.
  (let [actions (atom [])]
    ; Pick up b-id if not already held
    (when (not= (whand) b-id)
      (swap! actions into (do-pickup! b-id)))
    ; Clear the target (if it's a block)
    (when (not= target-id "table")
      (swap! actions into (clear-top-of! target-id)))
    ; Place
    (swap! world assoc-in [:blocks b-id :on] target-id)
    (swap! world assoc :hand nil)
    (swap! world assoc :it b-id)
    @actions))

;;; ═══ COMMAND HANDLERS ═══════════════════════════════════════════════════════

(defn say [& parts] (println (apply str parts)))

(defn cmd-pickup [tokens]
  (let [[np _] (parse-np tokens)]
    (cond
      (nil? np)      (say "Pick up what?")
      (:is-table np) (say "I can't pick up the table.")
      :else
      (let [r (resolve-np np)]
        (if (:error r)
          (say (:error r))
          (let [b (:ok r)]
            (doseq [a (do-pickup! (:id b))] (say a))
            (say "OK.")))))))

(defn cmd-put-on [np1 target-tokens]
  (let [r1 (resolve-np np1)]
    (if (:error r1)
      (say (:error r1))
      (let [[np2 _] (parse-np target-tokens)
            r2 (if np2 (resolve-np np2) nil)]
        (cond
          (nil? np2)    (say "Put it on what?")
          (:error r2)   (say (:error r2))
          :else
          (let [b1 (:ok r1)
                tgt (if (:table r2) "table" (:id (:ok r2)))]
            (if (= (:id b1) tgt)
              (say "It is already there.")
              (do (doseq [a (do-put-on! (:id b1) tgt)] (say a))
                  (say "OK.")))))))))

(defn cmd-put-down [tokens]
  ; "put down" — put held block on table, or named block on table
  (let [held (whand)]
    (cond
      (not (empty? tokens))
      (let [[np _] (parse-np tokens)
            r (if np (resolve-np np) {:error "I don't know what to put down."})]
        (if (:error r)
          (say (:error r))
          (let [b (:ok r)]
            (doseq [a (do-put-on! (:id b) "table")] (say a))
            (say "OK."))))
      held
      (do (doseq [a (do-put-on! held "table")] (say a))
          (say "OK."))
      :else (say "I'm not holding anything."))))

(defn cmd-clear [tokens]
  (let [[np _] (parse-np tokens)
        r (if np (resolve-np np) {:error "Clear what?"})]
    (cond
      (:error r) (say (:error r))
      (:table r) (say "I can't move the table.")
      :else
      (let [b (:ok r)
            acts (clear-top-of! (:id b))]
        (if (empty? acts)
          (say (describe b) " is already clear.")
          (do (doseq [a acts] (say a))
              (say "OK.")))))))

;;; ═══ QUESTION ANSWERING ═════════════════════════════════════════════════════

(defn ans-is-there [np]
  (if (:is-table np)
    (say "Yes, there is a table.")
    (let [bs (find-blocks np)]
      (if (empty? bs) (say "No.") (say "Yes.")))))

(defn ans-is-on [np1 np2]
  (let [r1 (resolve-np np1)
        r2 (resolve-np np2)]
    (cond
      (:error r1) (say (:error r1))
      (:error r2) (say (:error r2))
      :else
      (let [b1 (:ok r1)]
        (swap! world assoc :it (:id b1))
        (if (:table r2)
          (if (= (:on b1) "table")
            (say "Yes.")
            (say "No, it is " (loc-str (:id b1)) "."))
          (let [b2 (:ok r2)]
            (if (= (:on b1) (:id b2))
              (say "Yes.")
              (say "No, it is " (loc-str (:id b1)) "."))))))))

(defn ans-is-clear [np]
  (let [r (resolve-np np)]
    (cond
      (:error r) (say (:error r))
      (:table r) (say "The table is clear of my concern.")
      :else
      (let [b (:ok r)]
        (swap! world assoc :it (:id b))
        (if (clear? (:id b))
          (say "Yes.")
          (say "No, " (describe (on-top (:id b))) " is on it."))))))

(defn ans-what-on [np]
  (let [r (resolve-np np)]
    (cond
      (:error r) (say (:error r))
      (:table r)
      (let [on-t (filter (fn [b] (= (:on b) "table")) (vals (wblocks)))]
        (if (empty? on-t)
          (say "Nothing is on the table.")
          (do (say "The table supports:")
              (doseq [b on-t] (say "  " (describe b))))))
      :else
      (let [b (:ok r)
            t (on-top (:id b))]
        (swap! world assoc :it (:id b))
        (if (nil? t)
          (say "Nothing is on " (describe b) ".")
          (do (swap! world assoc :it t)
              (say (describe (wblk t)) " is on " (describe b) ".")))))))

(defn ans-what-does-support [np]
  (let [r (resolve-np np)]
    (cond
      (:error r) (say (:error r))
      :else
      (let [b (:ok r)
            t (on-top (:id b))]
        (swap! world assoc :it (:id b))
        (if (nil? t)
          (say (describe b) " supports nothing.")
          (do (swap! world assoc :it t)
              (say (describe b) " supports " (describe (wblk t)) ".")))))))

(defn ans-where [np]
  (let [r (resolve-np np)]
    (cond
      (:error r) (say (:error r))
      (:table r) (say "The table is on the floor.")
      :else
      (let [b (:ok r)]
        (swap! world assoc :it (:id b))
        (say (describe b) " is " (loc-str (:id b)) ".")))))

(defn ans-how-many [np]
  (let [bs (find-blocks np)
        n (count bs)]
    (say (str n) ".")))

(defn ans-what-prop [prop np]
  (let [r (resolve-np np)]
    (cond
      (:error r) (say (:error r))
      :else
      (let [b (:ok r)]
        (swap! world assoc :it (:id b))
        (say "It is " (get b prop) ".")))))

(defn ans-which [np1 pred-tokens]
  ; "which <NP1> is on <NP2>?" / "which <NP1> is clear?"
  (let [w (first pred-tokens)
        rest-pred (rest pred-tokens)]
    (cond
      (or (= w "clear") (= w "empty"))
      (let [bs (find-blocks (assoc np1 :pred (fn [b] (clear? (:id b)))))]
        (if (empty? bs)
          (say "None.")
          (do (doseq [b bs] (say (describe b)))
              (swap! world assoc :it (:id (first bs))))))

      (= w "on")
      (let [[np2 _] (parse-np rest-pred)]
        (if (nil? np2)
          (say "On what?")
          (let [bs (find-blocks (assoc np1 :pred (on-pred np2)))]
            (if (empty? bs)
              (say "None.")
              (do (doseq [b bs] (say (describe b)))
                  (swap! world assoc :it (:id (first bs))))))))

      (or (= w "support") (= w "supports"))
      (let [[np2 _] (parse-np (skip-det rest-pred))]
        (if (nil? np2)
          (say "Support what?")
          (let [bs (find-blocks
                     (assoc np1 :pred
                       (fn [b]
                         (let [t (on-top (:id b))]
                           (if t (match-desc? (wblk t) np2) false)))))]
            (if (empty? bs)
              (say "None.")
              (do (doseq [b bs] (say (describe b)))
                  (swap! world assoc :it (:id (first bs))))))))

      :else (say "I don't understand that question."))))

;;; ═══ SCENE DISPLAY ══════════════════════════════════════════════════════════

(defn print-scene []
  (println "")
  (println "  Hand:" (if (whand) (describe (whand)) "empty"))
  (println "  Table:")
  (let [on-t (filter (fn [b] (= (:on b) "table")) (vals (wblocks)))]
    (doseq [b on-t]
      (let [tower (tower-above (:id b))]
        (if (empty? tower)
          (println (str "    " (describe b)))
          (println (str "    " (describe b) "  ←  " (join "  ←  " (map describe tower)))))))))

;;; ═══ TOKENIZER ══════════════════════════════════════════════════════════════

(defn tokenize [s]
  (let [words (filter (fn [w] (not (empty? w)))
                      (split (string/replace (trim s) #"[^a-zA-Z ]" " ") " "))]
    (map (fn [w] (if (= (count w) 1) w (lower-case w))) words)))

;;; ═══ SENTENCE DISPATCHER ════════════════════════════════════════════════════

(defn process [tokens]
  (if (empty? tokens)
    (say "I don't understand.")
    (let [w0 (first tokens)
          w1 (second tokens)
          t1 (rest tokens)
          t2 (rest t1)]
      (cond

        ;; ── COMMANDS ───────────────────────────────────────────────────────

        ; "pick up X" / "pick X up" / "grasp X" / "take X"
        (or (= w0 "grasp") (= w0 "take"))
        (cmd-pickup t1)

        (= w0 "pick")
        (cmd-pickup (if (= w1 "up") t2 t1))

        ; "put X on Y" / "put X down" / "put down X"
        (= w0 "put")
        (cond
          (= w1 "down") (cmd-put-down t2)
          :else
          (let [[np1 rest-np1] (parse-np t1)]
            (cond
              (nil? np1) (say "Put what?")
              (= (first rest-np1) "down") (cmd-put-down (list (describe (:ok (resolve-np np1)))))
              (or (= (first rest-np1) "on")
                  (= (first rest-np1) "onto"))
              (cmd-put-on np1 (rest rest-np1))
              (= (first rest-np1) "in")
              (cmd-put-on np1 (rest rest-np1))
              :else (say "Put " (describe (:ok (resolve-np np1))) " where?"))))

        ; "move X to/onto/on Y"
        (= w0 "move")
        (let [[np1 rest-np1] (parse-np t1)
              skip-prep (if (or (= (first rest-np1) "to")
                                (= (first rest-np1) "onto")
                                (= (first rest-np1) "on"))
                          (rest rest-np1)
                          rest-np1)]
          (if (nil? np1)
            (say "Move what?")
            (cmd-put-on np1 skip-prep)))

        ; "stack X on Y"
        (= w0 "stack")
        (let [[np1 rest-np1] (parse-np t1)
              skip-on (if (= (first rest-np1) "on") (rest rest-np1) rest-np1)]
          (if (nil? np1)
            (say "Stack what?")
            (cmd-put-on np1 skip-on)))

        ; "clear X" / "unstack X"
        (or (= w0 "clear") (= w0 "unstack"))
        (cmd-clear t1)

        ; "put down" with no np
        (and (= w0 "put") (= w1 "down") (empty? t2))
        (cmd-put-down [])

        ;; ── QUESTIONS ──────────────────────────────────────────────────────

        ; "is there a/an X?"
        (and (= w0 "is") (= w1 "there"))
        (let [[np _] (parse-np (skip-det t2))]
          (if np (ans-is-there np) (say "Is there what?")))

        ; "are there any X?"
        (and (= w0 "are") (= w1 "there"))
        (let [[np _] (parse-np (skip-det t2))]
          (if np (ans-is-there np) (say "Are there what?")))

        ; "is X on Y?" / "is X clear?" / "is X …?"
        (and (= w0 "is") (not= w1 "there"))
        (let [[np1 rest-np1] (parse-np t1)]
          (cond
            (nil? np1) (say "I don't understand.")
            (or (= (first rest-np1) "clear")
                (= (first rest-np1) "empty"))
            (ans-is-clear np1)
            (= (first rest-np1) "on")
            (let [[np2 _] (parse-np (rest rest-np1))]
              (if np2 (ans-is-on np1 np2) (say "On what?")))
            :else (ans-is-clear np1)))

        ; "what is on X?"
        (and (= w0 "what")
             (or (= w1 "is") (= w1 "are"))
             (= (first t2) "on"))
        (let [[np _] (parse-np (rest t2))]
          (if np (ans-what-on np) (say "On what?")))

        ; "what does X support?"
        (and (= w0 "what") (= w1 "does"))
        (let [[np _] (parse-np t2)]
          (if np (ans-what-does-support np) (say "I don't understand.")))

        ; "what is X?" — describe a block
        (and (= w0 "what") (= w1 "is"))
        (let [[np _] (parse-np t2)]
          (if (nil? np)
            (say "I don't understand.")
            (let [r (resolve-np np)]
              (if (:error r)
                (say (:error r))
                (let [b (:ok r)]
                  (swap! world assoc :it (:id b))
                  (say "It is " (describe b) "."))))))

        ; "what color/size/shape is X?"
        (and (= w0 "what") (= w1 "color"))
        (let [toks (if (= (first t2) "is") (rest t2) t2)
              [np _] (parse-np toks)]
          (if np (ans-what-prop :color np) (say "What color of what?")))

        (and (= w0 "what") (= w1 "size"))
        (let [toks (if (= (first t2) "is") (rest t2) t2)
              [np _] (parse-np toks)]
          (if np (ans-what-prop :size np) (say "What size of what?")))

        (and (= w0 "what") (= w1 "shape"))
        (let [toks (if (= (first t2) "is") (rest t2) t2)
              [np _] (parse-np toks)]
          (if np (ans-what-prop :shape np) (say "What shape of what?")))

        ; "where is X?"
        (and (= w0 "where") (= w1 "is"))
        (let [[np _] (parse-np t2)]
          (if np (ans-where np) (say "Where is what?")))

        ; "how many X are there?" / "how many X?"
        (and (= w0 "how") (= w1 "many"))
        (let [[np _] (parse-np t2)]
          (if np (ans-how-many np) (say "How many what?")))

        ; "which X is/are on Y?" / "which X is clear?" / "which X supports Y?"
        (= w0 "which")
        (let [[np1 rest-np1] (parse-np t1)
              skip-is (if (or (= (first rest-np1) "is")
                               (= (first rest-np1) "are"))
                        (rest rest-np1)
                        rest-np1)]
          (if (nil? np1)
            (say "Which what?")
            (ans-which np1 skip-is)))

        ; "can you X" → reinterpret as command/question
        (and (= w0 "can") (= w1 "you"))
        (process t2)

        ; "do you know X" → reinterpret
        (and (= w0 "do") (= w1 "you"))
        (process t2)

        ;; ── META ───────────────────────────────────────────────────────────

        (or (= w0 "scene") (= w0 "look") (= w0 "show") (= w0 "display"))
        (print-scene)

        (= w0 "help")
        (do
          (say "Commands:")
          (say "  pick up <block>    grasp <block>")
          (say "  put <block> on <block>    move <block> to <block>")
          (say "  put down    clear <block>    stack <block> on <block>")
          (say "Questions:")
          (say "  is there a <block>?    is <block> on <block>?    is <block> clear?")
          (say "  where is <block>?    what is on <block>?    how many <blocks>?")
          (say "  which <block> is on <block>?    what color/size/shape is <block>?")
          (say "  what does <block> support?")
          (say "Block descriptions: [large|small] [color] [block|pyramid|box]")
          (say "  e.g. 'the large red block', 'a green block that is on the table'")
          (say "Type 'scene' to see the current state.  'quit' to exit."))

        (or (= w0 "quit") (= w0 "exit") (= w0 "bye") (= w0 "goodbye") (= w0 "q"))
        nil   ; handled by main loop

        :else
        (say "I don't understand \"" (join " " tokens) "\".")))))

;;; ═══ MAIN REPL ══════════════════════════════════════════════════════════════

(defn shrdlu-loop []
  (let [input (read-line ">> ")]
    (when-not (nil? input)
      (let [tokens (tokenize input)]
        (when (not (empty? tokens))
          (if (or (= (first tokens) "quit") (= (first tokens) "exit")
                  (= (first tokens) "bye")  (= (first tokens) "goodbye")
                  (= (first tokens) "q"))
            (println "Goodbye.")
            (do
              (process tokens)
              (shrdlu-loop))))
        (when (empty? tokens)
          (shrdlu-loop))))))

(defn shrdlu []
  (println "SHRDLU — Blocks World (Winograd 1972)")
  (println "=========================================")
  (println "Initial scene:")
  (println "  Large red block A  ← small green block B  (on the table)")
  (println "  Large blue block C ← small red pyramid D  (on the table)")
  (println "  Large green block E  (on the table, clear)")
  (println "  Hand is empty.")
  (println "")
  (println "Type 'help' for available commands.  'scene' to see current state.  'quit' to exit.")
  (println "")
  (shrdlu-loop))

(shrdlu)
