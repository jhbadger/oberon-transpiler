#!/usr/bin/env clojrepl_bio

(import-oberon "bio")

;;; helpers

(defn fmt-pct [x]
  (str (int (* x 100.0)) "%"))

(defn n50 [lengths]
  "Return the N50 of a collection of lengths."
  (let [total  (reduce + 0 lengths)
        sorted (reverse (sort lengths))
        half   (/ total 2)]
    (loop [rem half lens sorted]
      (if (empty? lens)
        0
        (let [l (first lens)]
          (if (<= rem l)
            l
            (recur (- rem l) (rest lens))))))))

;;; per-file summary

(defn summarize [path]
  (let [seqs (bio/read-fasta path)]
    (if (empty? seqs)
      (println (str "No sequences in " path))
      (let [n      (count seqs)
            lens   (map :length seqs)
            total  (reduce + 0 lens)
            maxl   (reduce max lens)
            minl   (reduce min lens)
            avgl   (/ total n)
            n50v   (n50 lens)
            nucs   (filter :nuc? seqs)
            avg-gc (if (empty? nucs)
                     nil
                     (/ (reduce + 0.0 (map :gc nucs))
                        (count nucs)))]
        (println (str "File:       " path))
        (println (str "Sequences:  " n))
        (println (str "Total bp:   " total))
        (println (str "Longest:    " maxl " bp"))
        (println (str "Shortest:   " minl " bp"))
        (println (str "Mean len:   " (int avgl) " bp"))
        (println (str "N50:        " n50v " bp"))
        (when avg-gc
          (println (str "Mean GC:    " (fmt-pct avg-gc))))
        (println)
        (println (str (join "\t" ["Name" "Length" "GC%" "Type"])))
        (doseq [s seqs]
          (println (str (join "\t" [(:name s)
                                    (:length s)
                                    (if (:nuc? s) (fmt-pct (:gc s)) "N/A")
                                    (if (:nuc? s) "nucl" "prot")]))))))))

;;; entry point

(let [paths *args*]
  (if (empty? paths)
    (println "Usage: cloj_bio seqSummary.clj file.fa [file2.fa ...]")
    (doseq [path paths]
      (summarize path)
      (println))))
