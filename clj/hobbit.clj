; Hobbit example from "Clojure for the Brave and True"

(def asym-hobbit-body-parts 
  [{:name "head" :size 3}
   {:name "left-eye" :size 1}
   {:name "left-ear" :size 1}
   {:name "mouth" :size 1}
   {:name "nose" :size 1}
   {:name "neck" :size 2}
   {:name "left-shoulder" :size 3}
   {:name "left-upper-arm" :size 3}
   {:name "chest" :size 10}
   {:name "back" :size 10}
   {:name "left-forearm" :size 3}
   {:name "abdomen" :size 6}
   {:name "left-kidney" :size 1}
   {:name "left-hand" :size 2}
   {:name "left-knee" :size 2}
   {:name "left-thigh" :size 4}
   {:name "left-lower-leg" :size 3}
   {:name "left-achilles" :size 1}
   {:name "left-foot" :size 2}
]) ; => (no output) 

(defn needs-matching-part?
   [part]
   (re-find #"^left-" (:name part))) ; => (no output) ; => (no output)
 
 (defn make-matching-part
   [part]
   {:name (string/replace (:name part) #"^left-" "right-")
    :size (:size part)}) ; => (no output)
 
(defn symmetrize-body-parts
   "Expects a seq of maps which have a :name and :size"
   [asym-body-parts]
   (reduce (fn [final-body-parts part]
             (let [final-body-parts (conj final-body-parts part)]
               (if (needs-matching-part? part)
                 (conj final-body-parts (make-matching-part part))
                 final-body-parts))) [] asym-body-parts)) ; => (no output)

 
 (print (symmetrize-body-parts asym-hobbit-body-parts)) ; => (no output)