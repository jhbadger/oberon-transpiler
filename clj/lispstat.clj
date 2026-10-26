;; ============================================================================
;; lispstat.clj  -  Lisp-Stat ported to Cloj (v3)
;;
;; All scientific-notation literals have been replaced by named constants
;; built with pow at load time, since Cloj's reader doesn't understand "1e-14"
;; style numeric literals.
;;
;; Load with:  (load-file "lispstat.clj")
;; Then run:   (lispstat-selftest)
;; ============================================================================

;; ----------------------------------------------------------------------------
;; 0. Numeric constants and utilities
;; ----------------------------------------------------------------------------

(def EPS       (pow 10 -14))
(def FPMIN     (pow 10 -30))
(def TINY      (pow 10 -10))
(def VERYTINY  (pow 10 -15))
(def TOL8      (pow 10 -8))
(def BIG4      10000)
(def BIG6      1000000)
(def BIGINF    (pow 10 300))
(def NEGBIGINF (- (pow 10 300)))

(defn compound? [x]
  (or (list? x) (vector? x)))

(defn seqable [x]
  (if (compound? x) (seq x) (list x)))

(defn vassoc [v idx val]
  (vec (map (fn [i] (if (= i idx) val (get v i))) (range (count v)))))

(defn make-vec [n v]
  (vec (map (fn [k] v) (range n))))

;; ----------------------------------------------------------------------------
;; 1. Vectorized arithmetic
;; ----------------------------------------------------------------------------

(defn flat-elems [x]
  (if (compound? x) (mapcat flat-elems x) (list x)))

(defn vectorize [f]
  (letfn [(vf [& args]
            (let [cs (filter compound? args)]
              (if (empty? cs)
                (apply f args)
                (let [model (first cs)
                      n     (count model)
                      expand (fn [a] (if (compound? a) (vec a) (make-vec n a)))
                      cols   (map expand args)
                      ;; Cloj's map takes at most two colls, so index instead
                      res    (if (< (count args) 3)
                               (apply map vf cols)
                               (map (fn [i] (apply vf (map (fn [c] (get c i)) cols)))
                                    (range n)))]
                  (if (vector? model) (vec res) res)))))]
    vf))

(def v+   (vectorize +))
(def v-   (vectorize -))
(def v*   (vectorize *))
(def vdiv (vectorize /))
(def v<   (vectorize <))
(def v>   (vectorize >))
(def v<=  (vectorize <=))
(def v>=  (vectorize >=))
(def v=   (vectorize =))
(def vmod (vectorize mod))

(def vsqrt  (vectorize sqrt))
(def vexp   (vectorize exp))
(def vlog   (vectorize log))
(def vsin   (vectorize sin))
(def vcos   (vectorize cos))
(def vtan   (vectorize tan))
(def vabs   (vectorize abs))
(def vfloor (vectorize floor))
(def vceil  (vectorize ceil))
(def vround (vectorize round))
(def vinc   (vectorize inc))
(def vdec   (vectorize dec))

(defn vpow [x y] ((vectorize pow) x y))

(defn vsum  [x] (reduce + 0 (flat-elems x)))
(defn vprod [x] (reduce * 1 (flat-elems x)))

(defn vmax [& xs]
  (let [es (mapcat flat-elems xs)]
    (reduce (fn [a b] (if (> a b) a b)) (first es) (rest es))))

(defn vmin [& xs]
  (let [es (mapcat flat-elems xs)]
    (reduce (fn [a b] (if (< a b) a b)) (first es) (rest es))))

(defn count-elements [x] (count (flat-elems x)))

(def pmin (vectorize (fn [a b] (if (< a b) a b))))
(def pmax (vectorize (fn [a b] (if (> a b) a b))))

;; ----------------------------------------------------------------------------
;; 2. Systematic data generation
;; ----------------------------------------------------------------------------

(defn iseq
  ([n]   (range n))
  ([a b] (range a (inc b)))
  ([a b step] (range a (+ b (if (pos? step) 1 -1)) step)))

(defn rseq [a b n]
  (if (<= n 1)
    (list a)
    (let [step (/ (- b a) (dec n))]
      (map (fn [i] (+ a (* i step))) (range n)))))

(defn vrepeat [vals pattern]
  (cond
    (and (not (compound? vals)) (number? pattern))
      (repeat pattern vals)
    (and (compound? vals) (number? pattern))
      (apply concat (map (fn [k] (seqable vals)) (range pattern)))
    (and (compound? vals) (compound? pattern))
      (apply concat (map (fn [v n] (repeat n v))
                         (seqable vals) (seqable pattern)))
    :else (throw "repeat: bad arguments")))

;; ----------------------------------------------------------------------------
;; 3. Data handling
;; ----------------------------------------------------------------------------

(defn select [x idx]
  (let [v (vec (seqable x))]
    (if (compound? idx)
      (map (fn [i] (get v i)) (seqable idx))
      (get v idx))))

(defn which [coll]
  (let [v (vec (seqable coll))
        n (count v)]
    (loop [i 0 acc []]
      (if (>= i n) (seq acc)
        (recur (inc i) (if (get v i) (conj acc i) acc))))))

(defn remove-idx [x idxs]
  (let [v   (vec (seqable x))
        ids (set (if (compound? idxs) (seqable idxs) (list idxs)))]
    (filter (fn [e] e)
      (map (fn [i] (if (contains? ids i) nil (get v i)))
           (range (count v))))))

(defn difference [x]
  (let [v (vec (seqable x)) n (count v)]
    (map (fn [i] (- (get v (inc i)) (get v i))) (range (dec n)))))

(defn accumulate [f x]
  (let [v (vec (seqable x))
        n (count v)]
    (if (zero? n) (list)
      (loop [i 1 acc (get v 0) out [(get v 0)]]
        (if (>= i n) out
          (let [a2 (f acc (get v i))]
            (recur (inc i) a2 (conj out a2))))))))

(defn cumsum  [x] (accumulate + x))
(defn cumprod [x] (accumulate * x))

(defn split-list [x n]
  (let [v (vec (seqable x)) c (count v)]
    (when (not= 0 (mod c n))
      (throw "split-list: length not a multiple of n"))
    (map (fn [i]
           (vec (map (fn [j] (get v (+ (* i n) j))) (range n))))
         (range (/ c n)))))

;; ----------------------------------------------------------------------------
;; 4. Sorting / ranks / quantiles
;; ----------------------------------------------------------------------------

(defn sort-data [x] (sort (seqable x)))

(defn order [x]
  (let [v (vec (seqable x)) n (count v)
        pairs (map (fn [i] [(get v i) i]) (range n))]
    (map second (sort-by first pairs))))

(defn rank [x]
  (let [o (vec (order x))
        n (count o)]
    (loop [i 0 acc (make-vec n 0)]
      (if (>= i n) acc
        (recur (inc i) (vassoc acc (get o i) i))))))

(defn quantile [x p]
  (let [s (vec (sort (seqable x)))
        n (count s)
        q1 (fn [pp]
             (let [h  (* pp (dec n))
                   lo (int (floor h))
                   hi (int (ceil h))
                   fr (- h lo)]
               (if (= lo hi) (get s lo)
                 (+ (* (- 1 fr) (get s lo))
                    (* fr        (get s hi))))))]
    (if (compound? p) (map q1 (seqable p)) (q1 p))))

(defn mean [x]
  (let [es (flat-elems x) n (count es)]
    (/ (reduce + 0.0 es) n)))

(defn median [x] (quantile x 0.5))

(defn variance [x]
  (let [es (flat-elems x)
        n  (count es)
        m  (/ (reduce + 0.0 es) n)]
    (/ (reduce + 0.0
         (map (fn [e] (let [d (- e m)] (* d d))) es))
       (dec n))))

(defn standard-deviation [x] (sqrt (variance x)))
(defn interquartile-range [x] (- (quantile x 0.75) (quantile x 0.25)))

(defn fivnum [x]
  (list (vmin x) (quantile x 0.25) (median x)
        (quantile x 0.75) (vmax x)))

(defn covariance [x y]
  (let [xv (vec (seqable x)) yv (vec (seqable y))
        n  (count xv)
        mx (/ (reduce + 0.0 xv) n)
        my (/ (reduce + 0.0 yv) n)]
    (/ (reduce + 0.0
         (map (fn [a b] (* (- a mx) (- b my))) xv yv))
       (dec n))))

(defn correlation [x y]
  (/ (covariance x y)
     (* (standard-deviation x) (standard-deviation y))))

(defn covariance-matrix [cols]
  (let [cs (vec (map (fn [c] (vec (seqable c))) cols))
        p  (count cs)]
    (vec (map (fn [i]
                (vec (map (fn [j]
                            (covariance (get cs i) (get cs j)))
                          (range p))))
              (range p)))))

;; ----------------------------------------------------------------------------
;; 5. Random variates
;; ----------------------------------------------------------------------------

(defn rand-with [n gen]
  (cond
    (number? n)   (vec (map (fn [k] (gen)) (range n)))
    (compound? n) (map (fn [k] (rand-with k gen)) (seqable n))
    :else         (throw "sample size must be int or compound")))

(defn uniform-rand
  ([n]     (rand-with n rand))
  ([n a b] (rand-with n (fn [] (+ a (* (- b a) (rand)))))))

(defn safe-log [u]
  (log (if (< u FPMIN) FPMIN u)))

(defn normal-rand-1 []
  (let [u1 (rand) u2 (rand)]
    (* (sqrt (* -2 (safe-log u1))) (cos (* 2 PI u2)))))

(defn normal-rand [n]
  (rand-with n normal-rand-1))

(defn cauchy-rand [n]
  (rand-with n (fn [] (tan (* PI (- (rand) 0.5))))))

(defn exp-rand [n]
  (rand-with n (fn [] (- (safe-log (rand))))))

(defn gamma-rand-1 [a]
  (if (< a 1)
    (let [g (gamma-rand-1 (+ a 1))
          u (rand)
          u2 (if (< u FPMIN) FPMIN u)]
      (* g (pow u2 (/ 1.0 a))))
    (let [d (- a (/ 1.0 3.0))
          c (/ 1.0 (sqrt (* 9 d)))]
      (loop []
        (let [z  (normal-rand-1)
              v0 (+ 1 (* c z))]
          (if (<= v0 0) (recur)
            (let [v (* v0 v0 v0)
                  u (rand)]
              (if (< u (- 1 (* 0.0331 z z z z))) (* d v)
                (if (< (log u)
                       (+ (* 0.5 z z)
                          (* d (+ 1 (- v) (log v)))))
                  (* d v)
                  (recur))))))))))

(defn gamma-rand [n a]
  (rand-with n (fn [] (gamma-rand-1 a))))

(defn chisq-rand [n df]
  (rand-with n (fn [] (* 2.0 (gamma-rand-1 (/ df 2.0))))))

(defn t-rand [n df]
  (rand-with n (fn []
                 (/ (normal-rand-1)
                    (sqrt (/ (* 2.0 (gamma-rand-1 (/ df 2.0))) df))))))

(defn f-rand [n df1 df2]
  (rand-with n (fn []
                 (/ (/ (* 2.0 (gamma-rand-1 (/ df1 2.0))) df1)
                    (/ (* 2.0 (gamma-rand-1 (/ df2 2.0))) df2)))))

(defn beta-rand [n a b]
  (rand-with n (fn []
                 (let [x (gamma-rand-1 a) y (gamma-rand-1 b)]
                   (/ x (+ x y))))))

(defn binomial-rand [n size p]
  (rand-with n
    (fn []
      (loop [i 0 k 0]
        (if (>= i size) k
          (recur (inc i) (if (< (rand) p) (inc k) k)))))))

(defn poisson-rand [n lam]
  (rand-with n
    (fn []
      (let [L (exp (- lam))]
        (loop [k 0 p 1.0]
          (let [p2 (* p (rand))]
            (if (<= p2 L) k (recur (inc k) p2))))))))

(defn sample
  ([coll k] (sample coll k nil))
  ([coll k with-replacement]
    (let [v (vec (seqable coll)) n (count v)]
      (if with-replacement
        (vec (map (fn [kk] (get v (rand-int n))) (range k)))
        (do
          (when (> k n) (throw "sample: k > n without replacement"))
          (loop [pool v out [] rem k]
            (if (zero? rem) out
              (let [i    (rand-int (count pool))
                    pick (get pool i)
                    rest-pool
                      (vec (concat
                             (map (fn [j] (get pool j)) (range i))
                             (map (fn [j] (get pool j))
                                  (range (inc i) (count pool)))))]
                (recur rest-pool (conj out pick) (dec rem))))))))))

;; ----------------------------------------------------------------------------
;; 6. Probability distributions
;; ----------------------------------------------------------------------------

(defn erf-ab [x]
  (let [sign (if (neg? x) -1.0 1.0)
        ax   (abs x)
        a1   0.254829592
        a2  -0.284496736
        a3   1.421413741
        a4  -1.453152027
        a5   1.061405429
        pp   0.3275911
        tt   (/ 1.0 (+ 1 (* pp ax)))
        poly (* (+ (* (+ (* (+ (* (+ (* a5 tt) a4) tt) a3) tt) a2) tt) a1) tt)
        y    (- 1 (* poly (exp (- (* ax ax)))))]
    (* sign y)))

(defn normal-dens [x]
  ((vectorize (fn [z] (* (/ 1.0 (sqrt (* 2 PI)))
                         (exp (- (* 0.5 z z))))))
    x))

(defn normal-cdf [x]
  ((vectorize (fn [z] (* 0.5 (+ 1 (erf-ab (/ z (sqrt 2)))))))
    x))

(defn normal-quant-1 [p]
  (let [a1 -39.6968302866538   a2 220.946098424521
        a3 -275.928510446969   a4 138.357751867269
        a5 -30.6647980661472   a6  2.50662827745924
        b1 -54.4760987982241   b2 161.585836858041
        b3 -155.698979859887   b4  66.8013118877197
        b5 -13.2806815528857
        c1 -0.00778489400243029 c2 -0.322396458041136
        c3 -2.40075827716184    c4 -2.54973253934373
        c5  4.37466414146497    c6  2.93816398269878
        d1  0.00778469570904146 d2  0.32246712907004
        d3  2.445134137143      d4  3.75440866190742
        plow 0.02425  phigh (- 1 plow)]
    (cond
      (<= p 0) NEGBIGINF
      (>= p 1) BIGINF
      (< p plow)
        (let [q (sqrt (* -2 (log p)))
              num (+ (* (+ (* (+ (* (+ (* (+ (* c1 q) c2) q) c3) q) c4) q) c5) q) c6)
              den (+ (* (+ (* (+ (* (+ (* d1 q) d2) q) d3) q) d4) q) 1)]
          (/ num den))
      (<= p phigh)
        (let [q (- p 0.5) r (* q q)
              num (* (+ (* (+ (* (+ (* (+ (* (+ (* a1 r) a2) r) a3) r) a4) r) a5) r) a6) q)
              den (+ (* (+ (* (+ (* (+ (* (+ (* b1 r) b2) r) b3) r) b4) r) b5) r) 1)]
          (/ num den))
      :else
        (let [q (sqrt (* -2 (log (- 1 p))))
              num (+ (* (+ (* (+ (* (+ (* (+ (* c1 q) c2) q) c3) q) c4) q) c5) q) c6)
              den (+ (* (+ (* (+ (* (+ (* d1 q) d2) q) d3) q) d4) q) 1)]
          (- (/ num den))))))

(defn normal-quant [p] ((vectorize normal-quant-1) p))

(defn cauchy-dens  [x] ((vectorize (fn [z] (/ 1.0 (* PI (+ 1 (* z z)))))) x))
(defn cauchy-cdf   [x] ((vectorize (fn [z] (+ 0.5 (/ (atan z) PI)))) x))
(defn cauchy-quant [p] ((vectorize (fn [pp] (tan (* PI (- pp 0.5))))) p))

(defn log-gamma-1 [z]
  (if (< z 0.5)
    (- (log (/ PI (sin (* PI z))))
       (log-gamma-1 (- 1 z)))
    (let [z2 (- z 1)
          c0 0.99999999999980993
          c1 676.5203681218851
          c2 -1259.1392167224028
          c3 771.32342877765313
          c4 -176.61502916214059
          c5 12.507343278686905
          c6 -0.13857109526572012
          c7 0.0000099843695780195716
          c8 0.00000015056327351493116
          x1 (+ c0
                (/ c1 (+ z2 1))
                (/ c2 (+ z2 2))
                (/ c3 (+ z2 3))
                (/ c4 (+ z2 4))
                (/ c5 (+ z2 5))
                (/ c6 (+ z2 6))
                (/ c7 (+ z2 7))
                (/ c8 (+ z2 8)))
          tt (+ z2 7.5)]
      (+ (* 0.5 (log (* 2 PI)))
         (* (+ z2 0.5) (log tt))
         (- tt)
         (log x1)))))

(defn log-gamma [x] ((vectorize log-gamma-1) x))
(defn gamma-fn  [x] ((vectorize (fn [z] (exp (log-gamma-1 z)))) x))

(defn gammp-series [a x]
  (loop [n 0 sum (/ 1.0 a) term (/ 1.0 a) ap a]
    (if (or (> n 500) (< (abs term) (* EPS (abs sum))))
      (* sum (exp (- (* a (log x)) x (log-gamma-1 a))))
      (let [ap2 (+ ap 1) term2 (* term (/ x ap2))]
        (recur (inc n) (+ sum term2) term2 ap2)))))

(defn safe-fp [v]
  (if (< (abs v) FPMIN) FPMIN v))

(defn gammp-cf [a x]
  (loop [i 1
         b (+ x 1 (- a))
         c (/ 1.0 FPMIN)
         d (/ 1.0 (+ x 1 (- a)))
         h (/ 1.0 (+ x 1 (- a)))]
    (if (> i 200)
      (* h (exp (- (* a (log x)) x (log-gamma-1 a))))
      (let [an  (* (- i) (- i a))
            b2  (+ b 2)
            d2  (safe-fp (+ (* an d) b2))
            c2  (safe-fp (+ b2 (/ an c)))
            d3  (/ 1.0 d2)
            del (* d3 c2)
            h2  (* h del)]
        (if (< (abs (- del 1)) EPS)
          (* h2 (exp (- (* a (log x)) x (log-gamma-1 a))))
          (recur (inc i) b2 c2 d3 h2))))))

(defn gammp [a x]
  (cond
    (or (< x 0) (<= a 0)) 0.0
    (zero? x) 0.0
    (< x (+ a 1)) (gammp-series a x)
    :else (- 1.0 (gammp-cf a x))))

(defn gammq [a x] (- 1.0 (gammp a x)))

(defn gamma-dens
  ([x a] (gamma-dens x a 1))
  ([x a scale]
   ((vectorize
      (fn [z]
        (if (<= z 0) 0.0
          (/ (* (pow z (- a 1)) (exp (- (/ z scale))))
             (* (pow scale a) (exp (log-gamma-1 a)))))))
     x)))

(defn gamma-cdf
  ([x a] (gamma-cdf x a 1))
  ([x a scale]
    ((vectorize (fn [z] (if (<= z 0) 0.0 (gammp a (/ z scale))))) x)))

(defn bisect-quant [cdf-fn p lo hi]
  (loop [a lo b hi i 0]
    (if (or (< (- b a) TOL8) (> i 200))
      (/ (+ a b) 2.0)
      (let [m (/ (+ a b) 2.0)]
        (if (< (cdf-fn m) p)
          (recur m b (inc i))
          (recur a m (inc i)))))))

(defn gamma-quant
  ([p a] (gamma-quant p a 1))
  ([p a scale]
    ((vectorize
       (fn [pp]
         (if (<= pp 0) 0.0
           (if (>= pp 1) (* scale a 100)
             (let [mn    (* a scale)
                   sd    (* scale (sqrt a))
                   hi    (if (> (+ mn (* 10 sd)) 1.0)
                           (+ mn (* 10 sd)) 1.0)]
               (bisect-quant (fn [z] (gamma-cdf z a scale)) pp 0.0 hi))))))
      p)))

(defn chisq-dens  [x df] (gamma-dens x (/ df 2.0) 2.0))
(defn chisq-cdf   [x df] (gamma-cdf  x (/ df 2.0) 2.0))
(defn chisq-quant [p df] (gamma-quant p (/ df 2.0) 2.0))

(defn log-beta [a b]
  (+ (log-gamma-1 a) (log-gamma-1 b) (- (log-gamma-1 (+ a b)))))

(defn betacf [a b x]
  (let [qab (+ a b)
        qap (+ a 1)
        qam (- a 1)
        init-t (- 1 (/ (* qab x) qap))
        init-safe (safe-fp init-t)]
    (loop [m 1
           c 1.0
           d (/ 1.0 init-safe)
           h (/ 1.0 init-safe)]
      (if (> m 200) h
        (let [m2  (* 2 m)
              aa1 (/ (* m (- b m) x) (* (+ qam m2) (+ a m2)))
              d1  (safe-fp (+ 1 (* aa1 d)))
              c1  (safe-fp (+ 1 (/ aa1 c)))
              d2  (/ 1.0 d1)
              h1  (* h d2 c1)
              aa2 (- (/ (* (+ a m) (+ qab m) x) (* (+ a m2) (+ qap m2))))
              d3  (safe-fp (+ 1 (* aa2 d2)))
              c2  (safe-fp (+ 1 (/ aa2 c1)))
              d4  (/ 1.0 d3)
              del (* d4 c2)
              h2  (* h1 del)]
          (if (< (abs (- del 1)) EPS) h2
            (recur (inc m) c2 d4 h2)))))))

(defn beta-inc [x a b]
  (cond
    (or (<= x 0) (<= a 0) (<= b 0)) 0.0
    (>= x 1) 1.0
    :else
      (let [bt (exp (+ (* a (log x)) (* b (log (- 1 x))) (- (log-beta a b))))]
        (if (< x (/ (+ a 1) (+ a b 2)))
          (/ (* bt (betacf a b x)) a)
          (- 1.0 (/ (* bt (betacf b a (- 1 x))) b))))))

(defn beta-dens [x a b]
  ((vectorize
     (fn [z]
       (if (or (<= z 0) (>= z 1)) 0.0
         (exp (+ (* (- a 1) (log z))
                 (* (- b 1) (log (- 1 z)))
                 (- (log-beta a b)))))))
    x))

(defn beta-cdf [x a b]
  ((vectorize (fn [z] (beta-inc z a b))) x))

(defn beta-quant [p a b]
  ((vectorize
     (fn [pp]
       (if (<= pp 0) 0.0
         (if (>= pp 1) 1.0
           (bisect-quant (fn [z] (beta-inc z a b)) pp 0.0 1.0)))))
    p))

(defn t-cdf [x df]
  ((vectorize
     (fn [tv]
       (let [z (/ df (+ df (* tv tv)))
             p (- 1.0 (* 0.5 (beta-inc z (/ df 2.0) 0.5)))]
         (if (neg? tv) (- 1.0 p) p))))
    x))

(defn t-dens [x df]
  ((vectorize
     (fn [tv]
       (* (exp (- (log-gamma-1 (/ (+ df 1) 2.0))
                  (log-gamma-1 (/ df 2.0))))
          (/ 1.0 (sqrt (* df PI)))
          (pow (+ 1 (/ (* tv tv) df)) (- (/ (+ df 1) 2.0))))))
    x))

(defn t-quant [p df]
  ((vectorize
     (fn [pp]
       (if (= pp 0.5) 0.0
         (bisect-quant (fn [z] (t-cdf z df)) pp (- BIG4) BIG4))))
    p))

(defn f-cdf [x df1 df2]
  ((vectorize
     (fn [fv]
       (if (<= fv 0) 0.0
         (let [z (/ (* df1 fv) (+ (* df1 fv) df2))]
           (beta-inc z (/ df1 2.0) (/ df2 2.0))))))
    x))

(defn f-dens [x df1 df2]
  ((vectorize
     (fn [fv]
       (if (<= fv 0) 0.0
         (exp (+ (* 0.5 df1 (log df1))
                 (* 0.5 df2 (log df2))
                 (- (log-beta (/ df1 2.0) (/ df2 2.0)))
                 (* (- (/ df1 2.0) 1) (log fv))
                 (* (- (/ (+ df1 df2) 2.0))
                    (log (+ df2 (* df1 fv)))))))))
    x))

(defn f-quant [p df1 df2]
  ((vectorize
     (fn [pp]
       (if (<= pp 0) 0.0
         (bisect-quant (fn [z] (f-cdf z df1 df2)) pp 0.0 BIG6))))
    p))

(defn binomial-dens [k n p]
  ((vectorize
     (fn [ki]
       (if (or (< ki 0) (> ki n)) 0.0
         (exp (+ (- (log-gamma-1 (+ n 1))
                    (log-gamma-1 (+ ki 1))
                    (log-gamma-1 (+ (- n ki) 1)))
                 (* ki (log p))
                 (* (- n ki) (log (- 1 p))))))))
    k))

(defn binomial-cdf [k n p]
  ((vectorize
     (fn [ki]
       (if (< ki 0) 0.0
         (if (>= ki n) 1.0
           (let [kif (int (floor ki))]
             (reduce + 0.0
               (map (fn [j] (binomial-dens j n p))
                    (range (inc kif)))))))))
    k))

(defn binomial-quant [prob n p]
  ((vectorize
     (fn [pp]
       (loop [k 0 c (binomial-dens 0 n p)]
         (if (or (>= c pp) (>= k n)) k
           (recur (inc k) (+ c (binomial-dens (inc k) n p)))))))
    prob))

(defn poisson-dens [k lam]
  ((vectorize
     (fn [ki]
       (if (< ki 0) 0.0
         (exp (- (* ki (log lam)) lam (log-gamma-1 (+ ki 1)))))))
    k))

(defn poisson-cdf [k lam]
  ((vectorize
     (fn [ki]
       (if (< ki 0) 0.0
         (let [kif (int (floor ki))]
           (reduce + 0.0
             (map (fn [j] (poisson-dens j lam))
                  (range (inc kif))))))))
    k))

(defn poisson-quant [prob lam]
  ((vectorize
     (fn [pp]
       (loop [k 0 c (poisson-dens 0 lam)]
         (if (>= c pp) k
           (recur (inc k) (+ c (poisson-dens (inc k) lam)))))))
    prob))

;; ----------------------------------------------------------------------------
;; 7. Linear algebra  (matrices = vectors of row vectors)
;; ----------------------------------------------------------------------------

(defn matrix? [m]
  (and (vector? m) (> (count m) 0) (vector? (get m 0))))

(defn nrow [m] (count m))
(defn ncol [m] (count (get m 0)))

(defn mget [m i j] (get (get m i) j))

(defn mset [m i j v]
  (vassoc m i (vassoc (get m i) j v)))

(defn make-matrix
  ([r c]   (make-matrix r c 0))
  ([r c v] (vec (map (fn [k] (make-vec c v)) (range r)))))

(defn identity-matrix [n]
  (vec (map (fn [i]
              (vec (map (fn [j] (if (= i j) 1 0)) (range n))))
            (range n))))

(defn transpose [m]
  (let [mv (vec (map vec m))
        r  (count mv)
        c  (count (get mv 0))]
    (vec (map (fn [j]
                (vec (map (fn [i] (get (get mv i) j)) (range r))))
              (range c)))))

(defn diagonal [x]
  (if (matrix? x)
    (vec (map (fn [i] (mget x i i))
              (range (if (< (nrow x) (ncol x)) (nrow x) (ncol x)))))
    (let [v (vec (seqable x)) n (count v)]
      (vec (map (fn [i]
                  (vec (map (fn [j] (if (= i j) (get v i) 0)) (range n))))
                (range n))))))

(defn column-list [m]
  (map (fn [j] (vec (map (fn [i] (mget m i j)) (range (nrow m)))))
       (range (ncol m))))

(defn row-list [m] (map vec m))

(defn bind-rows [& rows]
  (vec (mapcat
         (fn [r] (if (matrix? r) r (list (vec (seqable r)))))
         rows)))

(defn bind-columns [& cols]
  (transpose
    (apply bind-rows
      (map (fn [c] (if (matrix? c) (transpose c) (vec (seqable c))))
           cols))))

(defn matmult
  ([a b]
    (cond
      (and (not (matrix? a)) (not (matrix? b)))
        (reduce + 0.0 (map * (seqable a) (seqable b)))
      (and (not (matrix? a)) (matrix? b))
        (let [av (vec (seqable a))]
          (vec (map (fn [j]
                      (reduce + 0.0
                        (map (fn [i] (* (get av i) (mget b i j)))
                             (range (nrow b)))))
                    (range (ncol b)))))
      (and (matrix? a) (not (matrix? b)))
        (let [bv (vec (seqable b))]
          (vec (map (fn [i]
                      (reduce + 0.0
                        (map (fn [j] (* (mget a i j) (get bv j)))
                             (range (ncol a)))))
                    (range (nrow a)))))
      :else
        (let [r (nrow a) k (ncol a) c (ncol b)]
          (vec (map (fn [i]
                      (vec (map (fn [j]
                                  (reduce + 0.0
                                    (map (fn [l]
                                           (* (mget a i l) (mget b l j)))
                                         (range k))))
                                (range c))))
                    (range r))))))
  ([a b & more]
    (reduce matmult (matmult a b) more)))

(defn inner-product [a b] (matmult a b))

(defn outer-product
  ([a b]   (outer-product a b *))
  ([a b f]
    (let [av (vec (seqable a)) bv (vec (seqable b))]
      (vec (map (fn [x]
                  (vec (map (fn [y] (f x y)) bv)))
                av)))))

(defn cross-product [x] (matmult (transpose x) x))

(defn lu-decomp [A]
  (let [n (nrow A)
        a (atom (vec (map (fn [r]
                            (vec (map (fn [x] (* 1.0 x)) r))) A)))
        p (atom (vec (range n)))
        sign (atom 1)
        sing (atom false)]
    (dotimes [k n]
      (let [pivot
            (loop [i k best k bv (abs (mget @a k k))]
              (if (>= i n) best
                (let [v (abs (mget @a i k))]
                  (if (> v bv)
                    (recur (inc i) i v)
                    (recur (inc i) best bv)))))]
        (when (not= pivot k)
          (let [tmp (get @a k)]
            (reset! a (vassoc @a k (get @a pivot)))
            (reset! a (vassoc @a pivot tmp)))
          (let [tp (get @p k)]
            (reset! p (vassoc @p k (get @p pivot)))
            (reset! p (vassoc @p pivot tp)))
          (reset! sign (- @sign)))
        (let [pv (mget @a k k)]
          (if (< (abs pv) EPS)
            (reset! sing true)
            (loop [i (inc k)]
              (when (< i n)
                (let [factor (/ (mget @a i k) pv)]
                  (reset! a (mset @a i k factor))
                  (loop [j (inc k)]
                    (when (< j n)
                      (reset! a (mset @a i j
                                      (- (mget @a i j)
                                         (* factor (mget @a k j)))))
                      (recur (inc j)))))
                (recur (inc i))))))))
    (list @a @p @sign @sing)))

(defn lu-solve [lud b]
  (let [LU   (first lud)
        perm (second lud)
        n    (nrow LU)
        bv   (vec (seqable b))
        y    (atom (vec (map (fn [i] (get bv (get perm i)))
                             (range n))))]
    (dotimes [i n]
      (loop [j 0 s (get @y i)]
        (if (>= j i)
          (reset! y (vassoc @y i s))
          (recur (inc j) (- s (* (mget LU i j) (get @y j)))))))
    (let [x (atom (make-vec n 0.0))]
      (loop [i (dec n)]
        (when (>= i 0)
          (let [s0 (get @y i)
                s  (loop [j (inc i) acc s0]
                     (if (>= j n) acc
                       (recur (inc j)
                              (- acc (* (mget LU i j) (get @x j))))))]
            (reset! x (vassoc @x i (/ s (mget LU i i)))))
          (recur (dec i))))
      @x)))

(defn determinant [A]
  (let [lud (lu-decomp A)
        LU  (first lud)
        sgn (nth lud 2)
        sg  (nth lud 3)]
    (if sg 0.0
      (* sgn (reduce * 1.0
               (map (fn [i] (mget LU i i)) (range (nrow LU))))))))

(defn inverse [A]
  (let [n (nrow A)
        lud (lu-decomp A)]
    (transpose
      (vec (map (fn [j]
                  (let [e (vec (map (fn [i] (if (= i j) 1 0)) (range n)))]
                    (lu-solve lud e)))
                (range n))))))

(defn solve [A b]
  (let [lud (lu-decomp A)]
    (if (matrix? b)
      (transpose (vec (map (fn [c] (lu-solve lud c))
                           (column-list b))))
      (lu-solve lud b))))

(defn chol-decomp [A]
  (let [n (nrow A)
        L (atom (make-matrix n n 0.0))
        md (atom 0.0)]
    (dotimes [i n]
      (dotimes [j (inc i)]
        (let [s (reduce + 0.0
                  (map (fn [k] (* (mget @L i k) (mget @L j k)))
                       (range j)))]
          (if (= i j)
            (let [val (- (mget A i i) s)
                  v   (if (<= val 0)
                        (do (if (> (- val) @md) (reset! md (- val))) TINY)
                        (sqrt val))]
              (reset! L (mset @L i j v)))
            (let [lij (/ (- (mget A i j) s) (mget @L j j))]
              (reset! L (mset @L i j lij)))))))
    (list @L @md)))

(defn qr-decomp [A]
  (let [n (nrow A) p (ncol A)
        Q (atom (make-matrix n p 0.0))
        R (atom (make-matrix p p 0.0))]
    (dotimes [k p]
      (let [v (atom (vec (map (fn [i] (mget A i k)) (range n))))]
        (dotimes [j k]
          (let [qj (vec (map (fn [i] (mget @Q i j)) (range n)))
                r  (reduce + 0.0 (map * qj @v))]
            (reset! R (mset @R j k r))
            (reset! v (vec (map (fn [i] (- (get @v i) (* r (get qj i))))
                                (range n))))))
        (let [norm (sqrt (reduce + 0.0 (map (fn [x] (* x x)) @v)))]
          (reset! R (mset @R k k norm))
          (let [qk (if (zero? norm) @v
                     (vec (map (fn [x] (/ x norm)) @v)))]
            (dotimes [i n]
              (reset! Q (mset @Q i k (get qk i))))))))
    (list @Q @R)))

(defn eigen-sym [A]
  (let [n (nrow A)
        a (atom (vec (map vec A)))
        v (atom (identity-matrix n))
        eps VERYTINY
        maxit 100]
    (loop [iter 0]
      (let [info (loop [i 0 j 1 pi 0 pj 1
                        pv (if (> n 1) (abs (mget @a 0 1)) 0.0)]
                   (cond
                     (>= i n) [pi pj pv]
                     (>= j n) (recur (inc i) (+ i 2) pi pj pv)
                     (= i j)  (recur i (inc j) pi pj pv)
                     :else
                       (let [val (abs (mget @a i j))]
                         (if (> val pv)
                           (recur i (inc j) i j val)
                           (recur i (inc j) pi pj pv)))))
            p (first info) q (second info) m (nth info 2)]
        (if (or (>= iter maxit) (< m eps))
          (let [vals  (vec (map (fn [i] (mget @a i i)) (range n)))
                idx   (vec (sort-by (fn [i] (- (get vals i))) (range n)))
                sv    (vec (map (fn [i] (get vals i)) idx))
                svec  (transpose
                        (vec (map (fn [i]
                                    (vec (map (fn [r] (mget @v r i))
                                              (range n))))
                                  idx)))]
            (list sv svec))
          (let [app (mget @a p p) aqq (mget @a q q) apq (mget @a p q)
                theta (/ (- aqq app) (* 2 apq))
                tt (if (>= theta 0)
                     (/ 1.0 (+ theta (sqrt (+ 1 (* theta theta)))))
                     (/ 1.0 (- theta (sqrt (+ 1 (* theta theta))))))
                c (/ 1.0 (sqrt (+ 1 (* tt tt))))
                s (* tt c)]
            (reset! a (mset @a p p (- app (* tt apq))))
            (reset! a (mset @a q q (+ aqq (* tt apq))))
            (reset! a (mset @a p q 0.0))
            (reset! a (mset @a q p 0.0))
            (dotimes [i n]
              (when (and (not= i p) (not= i q))
                (let [aip (mget @a i p) aiq (mget @a i q)]
                  (reset! a (mset @a i p (- (* c aip) (* s aiq))))
                  (reset! a (mset @a p i (- (* c aip) (* s aiq))))
                  (reset! a (mset @a i q (+ (* s aip) (* c aiq))))
                  (reset! a (mset @a q i (+ (* s aip) (* c aiq)))))))
            (dotimes [i n]
              (let [vip (mget @v i p) viq (mget @v i q)]
                (reset! v (mset @v i p (- (* c vip) (* s viq))))
                (reset! v (mset @v i q (+ (* s vip) (* c viq))))))
            (recur (inc iter))))))))

(defn eigenvalues  [A] (first (eigen-sym A)))
(defn eigenvectors [A] (column-list (second (eigen-sym A))))

;; ----------------------------------------------------------------------------
;; 8. Regression
;; ----------------------------------------------------------------------------

(defn reg-coefs
  ([X y] (reg-coefs X y nil true))
  ([X y weights] (reg-coefs X y weights true))
  ([X y weights intercept?]
    (let [cols (if (matrix? X) (column-list X) (vec (map vec X)))
          n    (count (first cols))
          p    (count cols)
          w    (if weights (vec (seqable weights)) (make-vec n 1.0))
          yv   (vec (seqable y))
          Xmat (if intercept?
                 (vec (map (fn [i]
                             (vec (cons 1.0
                                    (map (fn [c] (nth c i)) cols))))
                           (range n)))
                 (vec (map (fn [i]
                             (vec (map (fn [c] (nth c i)) cols)))
                           (range n))))
          ncol-X (if intercept? (inc p) p)
          XtWX (vec (map (fn [i]
                           (vec (map (fn [j]
                                       (reduce + 0.0
                                         (map (fn [k]
                                                (* (get w k)
                                                   (mget Xmat k i)
                                                   (mget Xmat k j)))
                                              (range n))))
                                     (range ncol-X))))
                         (range ncol-X)))
          XtWy (vec (map (fn [i]
                           (reduce + 0.0
                             (map (fn [k]
                                    (* (get w k)
                                       (mget Xmat k i)
                                       (get yv k)))
                                  (range n))))
                         (range ncol-X)))]
      (solve XtWX XtWy))))

(defn regression-model [X y & opts]
  (let [om       (apply hash-map opts)
        intercept (if (contains? om :intercept) (get om :intercept) true)
        weights  (get om :weights)
        print?   (if (contains? om :print?) (get om :print?) true)
        cols   (if (matrix? X) (column-list X) (vec (map vec X)))
        n      (count (first cols))
        p      (count cols)
        w      (if weights (vec (seqable weights)) (make-vec n 1.0))
        yv     (vec (seqable y))
        coefs  (reg-coefs X yv weights intercept)
        fit    (vec (map (fn [i]
                           (let [row (vec (map (fn [c] (nth c i)) cols))
                                 b   (if intercept
                                       (vec (rest coefs)) coefs)
                                 base (if intercept (first coefs) 0.0)]
                             (+ base
                                (reduce + 0.0 (map * row b)))))
                         (range n)))
        resids (vec (map (fn [i] (- (get yv i) (get fit i)))
                         (range n)))
        pp     (if intercept (inc p) p)
        df     (- n pp)
        wrss   (reduce + 0.0
                 (map (fn [r wi] (* wi r r)) resids w))
        sigma2 (/ wrss df)
        sigma  (sqrt sigma2)
        sumw   (reduce + 0.0 w)
        ybar   (/ (reduce + 0.0 (map * yv w)) sumw)
        sst    (reduce + 0.0
                 (map (fn [yi wi]
                        (let [d (- yi ybar)] (* wi d d)))
                      yv w))
        r2     (if (zero? sst) 0.0 (- 1.0 (/ wrss sst)))
        Xmat   (if intercept
                 (vec (map (fn [i]
                             (vec (cons 1.0
                                    (map (fn [c] (nth c i)) cols))))
                           (range n)))
                 (vec (map (fn [i]
                             (vec (map (fn [c] (nth c i)) cols)))
                           (range n))))
        XtWX   (vec (map (fn [i]
                           (vec (map (fn [j]
                                       (reduce + 0.0
                                         (map (fn [k]
                                                (* (mget Xmat k i)
                                                   (mget Xmat k j)
                                                   (get w k)))
                                              (range n))))
                                     (range (count (get Xmat 0))))))
                         (range (count (get Xmat 0)))))
        XtWX-inv (inverse XtWX)
        leverages (vec (map (fn [i]
                              (let [row (get Xmat i)
                                    tmp (matmult row XtWX-inv)]
                                (* (get w i)
                                   (reduce + 0.0 (map * tmp row)))))
                            (range n)))
        studres (vec (map (fn [i]
                            (let [h (get leverages i)
                                  denom (* sigma (sqrt
                                                   (if (> (- 1 h) VERYTINY)
                                                     (- 1 h) VERYTINY)))]
                              (if (zero? denom) 0.0
                                (/ (get resids i) denom))))
                          (range n)))
        cooks (vec (map (fn [i]
                          (let [h (get leverages i)
                                sr (get studres i)]
                            (/ (* sr sr h) (* pp (- 1 h)))))
                        (range n)))
        model {:coefs coefs
               :fitted fit
               :residuals resids
               :sigma-hat sigma
               :r-squared r2
               :df df
               :n n
               :p p
               :intercept? intercept
               :weights w
               :leverages leverages
               :cooks-distances cooks
               :studentized-residuals studres}]
    (when print?
      (println "Least Squares Estimates:")
      (if intercept
        (do (println (str "  Constant   : " (first coefs)))
            (dotimes [i p]
              (println (str "  Variable " i " : " (nth coefs (inc i))))))
        (dotimes [i p]
          (println (str "  Variable " i " : " (nth coefs i)))))
      (println (str "R Squared        : " r2))
      (println (str "Sigma hat        : " sigma))
      (println (str "Number of cases  : " n))
      (println (str "Degrees of freedom: " df)))
    model))

;; ----------------------------------------------------------------------------
;; 9. Robust regression (IRLS)
;; ----------------------------------------------------------------------------

(defn make-weight-fn
  ([kind]
    (make-weight-fn kind
      (case kind
        :biweight 4.685
        :huber    1.345
        :cauchy   2.385)))
  ([kind k]
    (fn [r]
      (let [u (/ (abs r) k)]
        (case kind
          :biweight (if (<= u 1) (let [v (- 1 (* u u))] (* v v)) 0.0)
          :huber    (if (<= u 1) 1.0 (/ 1.0 u))
          :cauchy   (/ 1.0 (+ 1 (* u u))))))))

(defn robust-regression [X y & opts]
  (let [om        (apply hash-map opts)
        wf        (if (contains? om :wf) (get om :wf)
                    (make-weight-fn :huber))
        intercept (if (contains? om :intercept) (get om :intercept) true)
        tol       (if (contains? om :tol) (get om :tol) 0.0001)
        climit    (if (contains? om :count-limit) (get om :count-limit) 20)
        print?    (if (contains? om :print?) (get om :print?) false)
        cols (if (matrix? X) (column-list X) (vec (map vec X)))
        n    (count (first cols))
        yv   (vec (seqable y))]
    (loop [weights (make-vec n 1.0)
           last-coefs nil
           iter 0]
      (let [coefs (reg-coefs X yv weights intercept)
            fit (vec (map (fn [i]
                            (let [row (vec (map (fn [c] (nth c i)) cols))
                                  b   (if intercept (vec (rest coefs)) coefs)
                                  base (if intercept (first coefs) 0.0)]
                              (+ base (reduce + 0.0 (map * row b)))))
                          (range n)))
            resids (vec (map (fn [i] (- (get yv i) (get fit i)))
                             (range n)))
            med    (median (map abs resids))
            scale  (/ (if (< med TINY) TINY med) 0.6745)
            new-wts (vec (map (fn [r] (wf (/ r scale))) resids))
            conv?  (and last-coefs
                        (let [delta (reduce + 0.0
                                      (map (fn [a b]
                                             (/ (abs (- a b)) (+ 1 (abs a))))
                                           coefs last-coefs))]
                          (< (/ delta (count coefs)) tol)))]
        (when print?
          (println (str "Iter " iter " coefs=" coefs " scale=" scale)))
        (if (or conv? (>= iter climit))
          (let [m (regression-model X y
                    :intercept intercept
                    :weights new-wts
                    :print? false)]
            (assoc m :final-weights new-wts :iterations iter :scale scale))
          (recur new-wts coefs (inc iter)))))))

;; ----------------------------------------------------------------------------
;; 10. Smoothing
;; ----------------------------------------------------------------------------

(defn natural-spline-coefs [x y]
  (let [n (count x)
        y2 (atom (make-vec n 0.0))
        u  (atom (make-vec n 0.0))]
    (dotimes [i (- n 2)]
      (let [i1 (inc i) i2 (+ i 2)
            sig (/ (- (get x i1) (get x i))
                   (- (get x i2) (get x i)))
            pp  (+ (* sig (get @y2 i)) 2.0)
            y2i (/ (- sig 1.0) pp)]
        (reset! y2 (vassoc @y2 i1 y2i))
        (let [u0 (- (/ (- (get y i2) (get y i1))
                       (- (get x i2) (get x i1)))
                    (/ (- (get y i1) (get y i))
                       (- (get x i1) (get x i))))
              u1 (/ (- (/ (* 6.0 u0)
                          (- (get x i2) (get x i)))
                       (* sig (get @u i)))
                    pp)]
          (reset! u (vassoc @u i1 u1)))))
    (loop [k (- n 2)]
      (when (>= k 0)
        (reset! y2 (vassoc @y2 k
                           (+ (* (get @y2 k) (get @y2 (inc k)))
                              (get @u k))))
        (recur (dec k))))
    @y2))

(defn spline-eval [x y y2 xi]
  (let [n (count x)
        br (loop [klo 0 khi (dec n)]
             (if (> (- khi klo) 1)
               (let [k (int (/ (+ khi klo) 2))]
                 (if (> (get x k) xi) (recur klo k) (recur k khi)))
               [klo khi]))
        klo (first br)
        khi (second br)
        h   (- (get x khi) (get x klo))
        a   (/ (- (get x khi) xi) h)
        b   (/ (- xi (get x klo)) h)]
    (+ (* a (get y klo))
       (* b (get y khi))
       (* (/ (* h h) 6.0)
          (+ (* (- (* a a a) a) (get y2 klo))
             (* (- (* b b b) b) (get y2 khi)))))))

(defn spline
  ([x y] (spline x y 30))
  ([x y xvals-or-n]
    (let [xv (vec (seqable x)) yv (vec (seqable y))
          y2 (natural-spline-coefs xv yv)
          xs (cond
               (number? xvals-or-n)
                 (vec (rseq (get xv 0) (get xv (dec (count xv))) xvals-or-n))
               :else (vec (seqable xvals-or-n)))
          ys (vec (map (fn [xi] (spline-eval xv yv y2 xi)) xs))]
      (list xs ys))))

(defn kernel [type u]
  (case type
    :gaussian (* (/ 1.0 (sqrt (* 2 PI))) (exp (* -0.5 u u)))
    :bisquare (if (< (abs u) 1)
                (let [v (- 1 (* u u))] (* 0.9375 v v))
                0.0)
    :triangle (if (< (abs u) 1) (- 1 (abs u)) 0.0)
    :uniform  (if (< (abs u) 1) 0.5 0.0)))

(defn kernel-smooth [x y & opts]
  (let [om (apply hash-map opts)
        width (get om :width)
        type  (if (contains? om :type) (get om :type) :gaussian)
        ne    (if (contains? om :n-eval) (get om :n-eval) 30)
        xv (vec (seqable x)) yv (vec (seqable y))
        xmin (vmin xv) xmax (vmax xv)
        w  (if width width (/ (- xmax xmin) 10.0))
        xs (vec (rseq xmin xmax ne))
        ys (vec (map (fn [xi]
                       (let [ws (map (fn [xj]
                                       (kernel type (/ (- xi xj) w)))
                                     xv)
                             sw (reduce + 0.0 ws)]
                         (if (zero? sw) 0.0
                           (/ (reduce + 0.0 (map * ws yv)) sw))))
                     xs))]
    (list xs ys)))

(defn kernel-dens [x & opts]
  (let [om (apply hash-map opts)
        width (get om :width)
        type  (if (contains? om :type) (get om :type) :bisquare)
        ne    (if (contains? om :n-eval) (get om :n-eval) 50)
        xv (vec (seqable x))
        n  (count xv)
        sd (standard-deviation xv)
        w  (if width width (* 1.06 sd (pow n -0.2)))
        xmin (- (vmin xv) (* 3 w))
        xmax (+ (vmax xv) (* 3 w))
        xs (vec (rseq xmin xmax ne))
        ds (vec (map (fn [xi]
                       (/ (reduce + 0.0
                            (map (fn [xj]
                                   (kernel type (/ (- xi xj) w)))
                                 xv))
                          (* n w)))
                     xs))]
    (list xs ds)))

;; ----------------------------------------------------------------------------
;; 11. Prototype object system
;; ----------------------------------------------------------------------------

(def *self* nil)

(defn make-proto
  ([nm] (make-proto nm nil {}))
  ([nm parents] (make-proto nm parents {}))
  ([nm parents slots]
    (atom {:__ls-object__ true
           :name    nm
           :parents (if parents parents [])
           :slots   (if slots slots {})
           :methods {}})))

(defmacro defproto [nm parents slots]
  `(def ~nm (make-proto (quote ~nm) ~parents ~slots)))

(defn lookup-method [obj sel]
  (let [seen (atom #{})
        q    (atom [obj])]
    (loop [_ 0]
      (if (= 0 (count @q)) nil
        (let [o (get @q 0)
              rest-q (vec (map (fn [i] (get @q i))
                               (range 1 (count @q))))]
          (reset! q rest-q)
          (if (contains? @seen o)
            (recur _)
            (do
              (swap! seen conj o)
              (let [m (get (get (deref o) :methods) sel)]
                (if m m
                  (do
                    (loop [ps (get (deref o) :parents)]
                      (when (seq ps)
                        (reset! q (conj @q (first ps)))
                        (recur (rest ps))))
                    (recur _)))))))))))

(defn lookup-slot [obj sym]
  (let [seen (atom #{})
        q    (atom [obj])]
    (loop [_ 0]
      (if (= 0 (count @q)) [nil false]
        (let [o (get @q 0)
              rest-q (vec (map (fn [i] (get @q i))
                               (range 1 (count @q))))]
          (reset! q rest-q)
          (if (contains? @seen o)
            (recur _)
            (do
              (swap! seen conj o)
              (let [slots (get (deref o) :slots)]
                (if (contains? slots sym)
                  [(get slots sym) true]
                  (do
                    (loop [ps (get (deref o) :parents)]
                      (when (seq ps)
                        (reset! q (conj @q (first ps)))
                        (recur (rest ps))))
                    (recur _)))))))))))

(defn slot [obj sym]
  (first (lookup-slot obj sym)))

(defn has-slot?
  ([obj sym] (has-slot? obj sym false))
  ([obj sym own-only?]
    (if own-only?
      (contains? (get (deref obj) :slots) sym)
      (second (lookup-slot obj sym)))))

(defn add-slot!
  ([obj sym] (add-slot! obj sym nil))
  ([obj sym val]
    (swap! obj assoc :slots (assoc (get (deref obj) :slots) sym val))
    val))

(defn set-slot! [obj sym val]
  (swap! obj assoc :slots (assoc (get (deref obj) :slots) sym val))
  val)

(defn delete-slot! [obj sym]
  (swap! obj assoc :slots (dissoc (get (deref obj) :slots) sym))
  nil)

(defn send-msg [obj sel & args]
  (let [m (lookup-method obj sel)]
    (if m
      (binding [*self* obj]
        (apply m obj args))
      (throw (str "no method for " sel)))))

(def send send-msg)

(defmacro defmeth [obj sel params & body]
  `(let [f# (fn [self# ~@params]
              (let [~'self self#]
                ~@body))]
     (swap! ~obj assoc :methods
       (assoc (get (deref ~obj) :methods) ~sel f#))
     ~sel))

(defn own-methods [obj] (keys (get (deref obj) :methods)))
(defn own-slots   [obj] (keys (get (deref obj) :slots)))

(defproto data-set-proto nil {:data nil :title "data set"})

(defmeth data-set-proto :title [& opt]
  (if (seq opt)
    (do (set-slot! self :title (first opt)) (first opt))
    (slot self :title)))

(defmeth data-set-proto :data [& opt]
  (if (seq opt)
    (do (set-slot! self :data (first opt)) (first opt))
    (slot self :data)))

(defmeth data-set-proto :describe []
  (let [d  (send self :data)
        es (if d (flat-elems d) ())]
    (println (str "This is " (send self :title)))
    (println (str "  N          : " (count es)))
    (when (seq es)
      (println (str "  Mean       : " (mean es)))
      (println (str "  Std dev    : " (standard-deviation es)))
      (println (str "  Median     : " (median es)))
      (println (str "  Min, Max   : " (vmin es) " , " (vmax es))))))

;; ----------------------------------------------------------------------------
;; 12. Vectorized core operators
;;
;; As in real Lisp-Stat, the ordinary arithmetic and math functions are
;; rebound to vectorized versions, so any user-defined function built from
;; them works elementwise on lists/vectors with no extra effort:
;;   (defn f [x] (+ (* x x) 1))   (f (list 1 2 3)) => (2 5 10)
;; Scalar calls take a fast path straight to the original builtin.  The
;; originals stay available as core+, core-, ... .  = is left alone so that
;; structural equality still works; max/min reduce over all elements
;; (use pmax/pmin for elementwise).  Functions whose bodies branch on their
;; argument (if, cond, ...) still need an explicit (vectorize f).
;; ----------------------------------------------------------------------------

(defn auto-vec [core vf]
  (fn ([] (core))
      ([a] (if (number? a) (core a) (vf a)))
      ([a b] (if (number? a) (if (number? b) (core a b) (vf a b)) (vf a b)))
      ([a b & more] (apply vf a b more))))

;; Capture the builtins only on the first load, so reloading this file
;; doesn't wrap the wrappers.
(def core+     (if (= (type +) :builtin) + core+))
(def core-     (if (= (type -) :builtin) - core-))
(def core*     (if (= (type *) :builtin) * core*))
(def core-div  (if (= (type /) :builtin) / core-div))
(def core<     (if (= (type <) :builtin) < core<))
(def core>     (if (= (type >) :builtin) > core>))
(def core<=    (if (= (type <=) :builtin) <= core<=))
(def core>=    (if (= (type >=) :builtin) >= core>=))
(def core-mod  (if (= (type mod) :builtin) mod core-mod))
(def core-pow  (if (= (type pow) :builtin) pow core-pow))
(def core-max  (if (= (type max) :builtin) max core-max))
(def core-min  (if (= (type min) :builtin) min core-min))
(def core-sqrt  (if (= (type sqrt) :builtin) sqrt core-sqrt))
(def core-exp   (if (= (type exp) :builtin) exp core-exp))
(def core-log   (if (= (type log) :builtin) log core-log))
(def core-sin   (if (= (type sin) :builtin) sin core-sin))
(def core-cos   (if (= (type cos) :builtin) cos core-cos))
(def core-tan   (if (= (type tan) :builtin) tan core-tan))
(def core-atan  (if (= (type atan) :builtin) atan core-atan))
(def core-abs   (if (= (type abs) :builtin) abs core-abs))
(def core-floor (if (= (type floor) :builtin) floor core-floor))
(def core-ceil  (if (= (type ceil) :builtin) ceil core-ceil))
(def core-round (if (= (type round) :builtin) round core-round))
(def core-inc   (if (= (type inc) :builtin) inc core-inc))
(def core-dec   (if (= (type dec) :builtin) dec core-dec))

(def +  (auto-vec core+    (vectorize core+)))
(def -  (auto-vec core-    (vectorize core-)))
(def *  (auto-vec core*    (vectorize core*)))
(def /  (auto-vec core-div (vectorize core-div)))
(def <  (auto-vec core<    (vectorize core<)))
(def >  (auto-vec core>    (vectorize core>)))
(def <= (auto-vec core<=   (vectorize core<=)))
(def >= (auto-vec core>=   (vectorize core>=)))
(def mod (auto-vec core-mod (vectorize core-mod)))
(def pow (auto-vec core-pow (vectorize core-pow)))
(def max (auto-vec core-max (fn [& xs] (reduce core-max (flat-elems xs)))))
(def min (auto-vec core-min (fn [& xs] (reduce core-min (flat-elems xs)))))
(def sqrt  (auto-vec core-sqrt  (vectorize core-sqrt)))
(def exp   (auto-vec core-exp   (vectorize core-exp)))
(def log   (auto-vec core-log   (vectorize core-log)))
(def sin   (auto-vec core-sin   (vectorize core-sin)))
(def cos   (auto-vec core-cos   (vectorize core-cos)))
(def tan   (auto-vec core-tan   (vectorize core-tan)))
(def atan  (auto-vec core-atan  (vectorize core-atan)))
(def abs   (auto-vec core-abs   (vectorize core-abs)))
(def floor (auto-vec core-floor (vectorize core-floor)))
(def ceil  (auto-vec core-ceil  (vectorize core-ceil)))
(def round (auto-vec core-round (vectorize core-round)))
(def inc   (auto-vec core-inc   (vectorize core-inc)))
(def dec   (auto-vec core-dec   (vectorize core-dec)))

;; ----------------------------------------------------------------------------
;; 13. Self-test
;; ----------------------------------------------------------------------------

(defn approx=
  ([a b]     (approx= a b 0.000001))
  ([a b tol] (< (abs (- a b)) tol)))

(defn lispstat-selftest []
  (println "=== lispstat selftest ===")

  (println "--- step 1: basic arith ---")
  (println (str "1+2 = " (+ 1 2)))

  (println "--- step 2: lists ---")
  (println (str "list = " (list 1 2 3 4)))

  (println "--- step 3: v+ scalar+scalar ---")
  (println (str "v+ 1 2 = " (v+ 1 2)))

  (println "--- step 4: v+ list+scalar ---")
  (println (str "v+ (1 2 3) 1 = " (v+ (list 1 2 3) 1)))

  (println "--- step 5: v* list*list ---")
  (println (str "v* (1 2 3) (4 5 6) = " (v* (list 1 2 3) (list 4 5 6))))

  (println "--- step 6: vsqrt ---")
  (println (str "vsqrt (1 4 9) = " (vsqrt (list 1 4 9))))

  (println "--- step 7: iseq rseq vrepeat ---")
  (println (str "iseq 5    = " (iseq 5)))
  (println (str "iseq 1 5  = " (iseq 1 5)))
  (println (str "rseq      = " (rseq 0 1 5)))
  (println (str "vrepeat 3 4 = " (vrepeat 3 4)))

  (println "--- step 8: mean/median/sd ---")
  (let [small (list 1 2 3 4 5)]
    (println (str "mean small   = " (mean small)))
    (println (str "median small = " (median small)))
    (println (str "sd small     = " (standard-deviation small))))

  (println "--- step 9: Minneapolis precipitation ---")
  (let [precip (list 0.77 1.74 0.81 1.20 1.95 1.20 0.47 1.43 3.37 2.20
                     3.00 3.09 1.51 2.10 0.52 1.62 1.31 0.32 0.59 0.81
                     2.81 1.87 1.18 1.35 4.75 2.48 0.96 1.89 0.90 2.05)]
    (println (str "mean precip   = " (mean precip)))
    (println (str "median precip = " (median precip)))
    (println (str "sd precip     = " (standard-deviation precip)))
    (println (str "iqr precip    = " (interquartile-range precip))))

  (println "--- step 10: normal distribution ---")
  (println (str "normal-cdf 1.96   = " (normal-cdf 1.96)))
  (println (str "normal-quant .975 = " (normal-quant 0.975)))

  (println "--- step 11: chi-sq, t ---")
  (println (str "chisq-cdf 7.5 8   = " (chisq-cdf 7.5 8)))
  (println (str "t-quant .975 3    = " (t-quant 0.975 3)))

  (println "--- step 12: matrix inverse ---")
  (let [A [[4 1 2] [1 3 0] [2 0 5]]]
    (println (str "det A = " (determinant A)))
    (let [Ai (inverse A)
          I  (matmult A Ai)]
      (println "A * A^-1 =")
      (loop [i 0]
        (when (< i 3)
          (println (str "  " (get I i)))
          (recur (inc i))))))

  (println "--- step 13: bike regression ---")
  (let [travel [12.8 12.9 12.9 13.6 14.5 14.6 15.1 17.5 19.5 20.8]
        sep    [5.5 6.2 6.3 7.0 7.8 8.3 7.1 10.0 10.8 11.0]
        m (regression-model (list travel) sep :print? false)]
    (println (str "bike coefs = " (get m :coefs)))
    (println (str "bike R^2   = " (get m :r-squared)))
    (println (str "bike sigma = " (get m :sigma-hat))))

  (println "--- step 14: stackloss regression ---")
  (let [air  (list 80 80 75 62 62 62 62 62 58 58 58 58 58 58 50 50 50 50 50 56 70)
        temp (list 27 27 25 24 22 23 24 24 23 18 18 17 18 19 18 18 19 19 20 20 20)
        conc (list 89 88 90 87 87 87 93 93 87 80 89 88 82 93 89 86 72 79 80 82 91)
        loss (list 42 37 37 28 18 18 19 20 15 14 14 13 11 12  8  7  8  8  9 15 15)
        m (regression-model (list air temp conc) loss :print? false)]
    (println (str "stackloss coefs = " (get m :coefs)))
    (println (str "stackloss sigma = " (get m :sigma-hat)))
    (println (str "stackloss R^2   = " (get m :r-squared))))

  (println "--- step 15: object system ---")
  (send data-set-proto :data (list 1 2 3 4 5 6 7 8 9 10))
  (send data-set-proto :title "my dataset")
  (send data-set-proto :describe)

  (println "--- step 16: auto-vectorized user function ---")
  (let [f (fn [x] (+ (* x x) 1))]
    (println (str "f 3         = " (f 3)))
    (println (str "f (1 2 3)   = " (f (list 1 2 3))))
    (println (str "f [0.5 2]   = " (f [0.5 2])))
    (println (str "sqrt [4 9]  = " (sqrt [4 9])))
    (println (str "max (3 7 2) = " (max (list 3 7 2)))))

  (println "=== selftest done ==="))

;; (lispstat-selftest)
