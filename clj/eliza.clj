; ELIZA - classic Weizenbaum chatbot (1966)
; Runs via: examples/clojrepl clj/eliza.clj

; Each rule: {:key keyword :pat capture-regex :pri priority :responses [...]}
; :pat (when non-nil) extracts the remainder for * substitution.
; Matching is done on the lowercased, punctuation-stripped input.

(def rules
  [{:key "quit"      :pat nil :pri 10
    :responses ["Goodbye. It was nice talking with you."
                "Take care. I hope I was of some help."
                "Goodbye."]}

   {:key "goodbye"   :pat nil :pri 10
    :responses ["Goodbye. It was nice talking with you."
                "Take care."
                "I hope I helped. Goodbye."]}

   {:key " bye"      :pat nil :pri 10
    :responses ["Goodbye."
                "Take care."]}

   {:key "i need "   :pat #"i need (.*)" :pri 9
    :responses ["Why do you need *?"
                "Would it really help you if you got *?"
                "Are you sure you need *?"
                "What would getting * mean for you?"]}

   {:key "i am "     :pat #"i am (.*)" :pri 8
    :responses ["How long have you been *?"
                "Do you believe it is normal to be *?"
                "How do you feel about being *?"
                "Is being * important to you?"]}

   {:key "i'm "      :pat #"i'm (.*)" :pri 8
    :responses ["How long have you been *?"
                "Do you believe it is normal to be *?"
                "How do you feel about being *?"]}

   {:key "i feel "   :pat #"i feel (.*)" :pri 8
    :responses ["Tell me more about feeling *."
                "Do you often feel *?"
                "When do you usually feel *?"
                "What makes you feel *?"]}

   {:key "i think "  :pat #"i think (.*)" :pri 7
    :responses ["Do you really think *?"
                "Are you entirely sure that *?"
                "What made you think that?"
                "But you are not certain *?"]}

   {:key "i want "   :pat #"i want (.*)" :pri 7
    :responses ["Why do you want *?"
                "What would it mean to you to get *?"
                "Suppose you got *. Then what?"]}

   {:key "my "       :pat #"my (.*)" :pri 6
    :responses ["Tell me more about your *."
                "Does your * concern you?"
                "What do you mean by your *?"
                "How long have you had your *?"]}

   {:key " mother"   :pat nil :pri 7
    :responses ["Tell me more about your mother."
                "Who else in your family comes to mind?"
                "How do you feel about your mother?"
                "How does this relate to your feelings today?"]}

   {:key " father"   :pat nil :pri 7
    :responses ["Tell me more about your father."
                "How do you feel about your father?"
                "What else comes to mind about your father?"
                "How does this relate to your feelings today?"]}

   {:key " sister"   :pat nil :pri 6
    :responses ["Tell me more about your sister."
                "How do you feel about your sister?"
                "What else comes to mind?"]}

   {:key " brother"  :pat nil :pri 6
    :responses ["Tell me more about your brother."
                "How do you feel about your brother?"
                "What else comes to mind?"]}

   {:key " family"   :pat nil :pri 6
    :responses ["Tell me more about your family."
                "Who in your family is most important to you?"
                "How does your family make you feel?"]}

   {:key " friend"   :pat nil :pri 6
    :responses ["Tell me more about your friends."
                "Do your friends know how you feel?"
                "How do your friends make you feel?"]}

   {:key "you are "  :pat #"you are (.*)" :pri 6
    :responses ["What makes you think I am *?"
                "Does it please you to believe I am *?"
                "Perhaps you would like me to be *?"]}

   {:key "you're "   :pat #"you're (.*)" :pri 6
    :responses ["What makes you think I'm *?"
                "Does it please you to believe I'm *?"
                "Perhaps you would like me to be *?"]}

   {:key "are you "  :pat #"are you (.*)" :pri 6
    :responses ["Why are you interested in whether I am * or not?"
                "Would you prefer if I were not *?"
                "Do you sometimes think I am *?"]}

   {:key " because"  :pat nil :pri 5
    :responses ["Is that the real reason?"
                "Don't any other reasons come to mind?"
                "Does that reason explain anything else?"
                "What other reasons might there be?"]}

   {:key " sorry"    :pat nil :pri 5
    :responses ["Please don't apologise."
                "Apologies are not necessary."
                "What feelings do you have when you apologise?"]}

   {:key " dream"    :pat nil :pri 5
    :responses ["What does that dream suggest to you?"
                "Do you dream often?"
                "What persons appear in your dreams?"
                "Don't you think that dream has to do with your problems?"]}

   {:key " computer" :pat nil :pri 5
    :responses ["Do computers worry you?"
                "What do you think about machines having feelings?"
                "Why do you mention computers?"]}

   {:key " problem"  :pat nil :pri 5
    :responses ["How long have you had this problem?"
                "Tell me more about your problem."
                "What kind of problem concerns you most?"]}

   {:key " worried"  :pat nil :pri 5
    :responses ["Why do you feel worried?"
                "Is there something specific that worries you?"
                "How long have you felt this way?"]}

   {:key " anxious"  :pat nil :pri 5
    :responses ["Why do you feel anxious?"
                "How long have you felt anxious?"
                "Tell me more about what makes you anxious."]}

   {:key " depress"  :pat nil :pri 5
    :responses ["I'm sorry to hear you are feeling depressed."
                "How long have you felt this way?"
                "Can you explain what's making you feel that way?"]}

   {:key " unhappy"  :pat nil :pri 5
    :responses ["I'm sorry to hear you are feeling unhappy."
                "How long have you felt this way?"
                "What do you think is causing this?"]}

   {:key " sad"      :pat nil :pri 5
    :responses ["I'm sorry to hear you are feeling sad."
                "How long have you been feeling this way?"
                "What do you think is causing you to feel sad?"]}

   {:key " happy"    :pat nil :pri 5
    :responses ["I'm glad to hear you're feeling happy."
                "What makes you feel so happy?"
                "Can you tell me more about that?"]}

   {:key " hate "    :pat #" hate (.*)" :pri 5
    :responses ["Tell me more about your feelings toward *."
                "Do you really hate *?"
                "Why do you hate *?"]}

   {:key " hates "   :pat nil :pri 5
    :responses ["Tell me more about these feelings of hatred."
                "Do you hate often?"
                "Why do you feel this way?"]}

   {:key " love "    :pat nil :pri 5
    :responses ["Tell me more about your feelings."
                "What does love mean to you?"
                "Can you tell me more?"]}

   {:key " yes"      :pat nil :pri 4
    :responses ["You seem quite positive."
                "Are you sure?"
                "I see."
                "I understand."]}

   {:key " no "      :pat nil :pri 4
    :responses ["Are you saying no just to be negative?"
                "Why not?"
                "Why 'no'?"]}

   {:key "not "      :pat nil :pri 3
    :responses ["Are you sure?"
                "Why not?"
                "Is that certain?"]}

   {:key " maybe"    :pat nil :pri 4
    :responses ["You don't seem quite certain."
                "Why the uncertainty?"
                "Can't you be more positive?"]}

   {:key " perhaps"  :pat nil :pri 4
    :responses ["You don't seem quite certain."
                "Why the uncertainty?"]}

   {:key " always"   :pat nil :pri 4
    :responses ["Can you think of a specific example?"
                "Really, always?"
                "Can you be more specific?"]}

   {:key "everybody" :pat nil :pri 4
    :responses ["Really, everyone?"
                "Can you think of anyone in particular?"
                "Who, for example?"]}

   {:key "everyone"  :pat nil :pri 4
    :responses ["Really, everyone?"
                "Can you think of anyone in particular?"
                "Who, for example?"]}

   {:key " why "     :pat nil :pri 4
    :responses ["Why do you ask?"
                "Does that question interest you?"
                "What is it you really want to know?"
                "What answer would please you most?"]}

   {:key " how "     :pat nil :pri 3
    :responses ["How do you suppose?"
                "Perhaps you can answer your own question."
                "What is it you're really asking?"]}

   {:key " what "    :pat nil :pri 3
    :responses ["Why do you ask?"
                "What do you think?"
                "Does that question interest you?"]}

   {:key " who "     :pat nil :pri 3
    :responses ["Why do you ask?"
                "Who do you have in mind?"]}

   {:key "can you "  :pat #"can you (.*)" :pri 4
    :responses ["You believe I can *?"
                "Perhaps you would like me to be able to *."
                "You want me to be able to *?"]}

   {:key "can i "    :pat #"can i (.*)" :pri 4
    :responses ["Whether or not you can * depends on you."
                "Do you want to be able to *?"
                "Perhaps you don't want to *."]}

   ; catch-all
   {:key ""          :pat nil :pri 0
    :responses ["Please go on."
                "Tell me more."
                "I see."
                "Very interesting."
                "I'm not sure I understand you fully."
                "Please tell me more."
                "That is interesting. Please continue."
                "Can you elaborate on that?"
                "Go on."
                "I hear you."]}])

(defn strip-punct [s]
  (string/replace (string/replace s #"[?.!,;:]+" "") #"\s+" " "))

(defn reflect [text]
  ; Use placeholders to avoid circular substitution.
  ; Phase 1: mark "you/*" forms with placeholders
  ; Phase 2: map "i/*" forms to "you/*"
  ; Phase 3: expand placeholders to "I/*"
  (-> (str " " (trim text) " ")
      ; Phase 1 — mark second-person (therapist-referring) with @@
      (string/replace #" you are "   " @@are ")
      (string/replace #" you were "  " @@were ")
      (string/replace #" you've "    " @@ve ")
      (string/replace #" you'll "    " @@ll ")
      (string/replace #" you'd "     " @@d ")
      (string/replace #" your "      " @@r ")
      (string/replace #" yours "     " @@rs ")
      (string/replace #" you "       " @@ ")
      ; Phase 2 — first-person (user) → second-person (therapist)
      (string/replace #" i am "      " you are ")
      (string/replace #" i was "     " you were ")
      (string/replace #" i've "      " you've ")
      (string/replace #" i'll "      " you'll ")
      (string/replace #" i'd "       " you'd ")
      (string/replace #" my "        " your ")
      (string/replace #" mine "      " yours ")
      (string/replace #" myself "    " yourself ")
      (string/replace #" me "        " you ")
      (string/replace #" i "         " you ")
      ; Phase 3 — expand @@ placeholders to first-person (therapist)
      (string/replace #" @@are "     " I am ")
      (string/replace #" @@were "    " I was ")
      (string/replace #" @@ve "      " I've ")
      (string/replace #" @@ll "      " I'll ")
      (string/replace #" @@d "       " I'd ")
      (string/replace #" @@r "       " my ")
      (string/replace #" @@rs "      " mine ")
      (string/replace #" @@ "        " I ")
      trim))

(def response-counters (atom {}))

(defn pick-response [key responses]
  (let [n   (count responses)
        idx (mod (get @response-counters key 0) n)]
    (swap! response-counters assoc key (inc idx))
    (nth responses idx)))

(defn make-response [template remainder]
  (if (includes? template "*")
    (string/replace template #"\*" (trim remainder))
    template))

(defn sorted-rules []
  (sort-by (fn [r] (- (:pri r))) rules))

(defn find-match [padded]
  (loop [rs (sorted-rules)]
    (if (empty? rs)
      {:rule (last rules) :remainder ""}
      (let [r (first rs)
            k (:key r)]
        (if (or (= k "") (includes? padded k))
          (let [remainder
                (if (nil? (:pat r))
                  ""
                  (let [m (re-find (:pat r) padded)]
                    (if (and (vector? m) (> (count m) 1))
                      (strip-punct (or (second m) ""))
                      "")))]
            {:rule r :remainder remainder})
          (recur (rest rs)))))))

(defn eliza-respond [raw-input]
  (let [input   (trim raw-input)
        lowered (str " " (lower-case input) " ")]
    (if (empty? input)
      "Please say something."
      (let [{:keys [rule remainder]} (find-match lowered)
            tmpl      (pick-response (:key rule) (:responses rule))
            reflected (reflect remainder)]
        (make-response tmpl reflected)))))

(def farewells #{"quit" "goodbye" "bye"})

(defn farewell? [input]
  (let [low (lower-case (trim input))]
    (some (fn [w] (includes? low w)) farewells)))

(defn eliza-loop []
  (let [input (read-line "You: ")]
    (when-not (nil? input)
      (let [response (eliza-respond input)]
        (println (str "ELIZA: " response))
        (println)
        (when-not (farewell? input)
          (eliza-loop))))))

(defn eliza []
  (println "ELIZA - a conversational program (Weizenbaum, 1966)")
  (println "========================================================")
  (println "ELIZA: Hello. I am ELIZA. How are you feeling today?")
  (println)
  (println "       (Type 'goodbye' or 'quit' to end the session)")
  (println)
  (eliza-loop))

(eliza)
