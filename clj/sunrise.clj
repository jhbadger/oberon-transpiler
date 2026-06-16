;; Constants
(def pi 3.141592653589793)
(def half-pi 1.5707963267948966)

;; --- Missing Math Helpers ---

(defn fmod [a b]
  (- a (* b (floor (/ a b)))))

;; Custom acos using binary search (cos is monotonically decreasing 0 to PI)
(defn acos [x]
  (loop [low 0.0
         high pi
         iters 0]
    (let [mid (/ (+ low high) 2.0)
          c (cos mid)]
      (if (or (> iters 50) (< (abs (- c x)) 0.00001))
        mid
        (if (> c x)
          (recur mid high (inc iters)) ;; Need smaller cosine -> larger angle
          (recur low mid (inc iters)))))))

;; Custom atan using binary search (tan is monotonically increasing -PI/2 to PI/2)
(defn atan [x]
  (loop [low (- half-pi)
         high half-pi
         iters 0]
    (let [mid (/ (+ low high) 2.0)
          t (tan mid)]
      (if (or (> iters 50) (< (abs (- t x)) 0.00001))
        mid
        (if (< t x)
          (recur mid high (inc iters)) ;; Need larger tangent -> larger angle
          (recur low mid (inc iters)))))))

;; --- Sunrise / Sunset Logic ---

(defn to-radians [degrees]
  (* degrees (/ pi 180.0)))

(defn to-degrees [radians]
  (* radians (/ 180.0 pi)))

(defn compute-sunrise-sunset 
  [lat lon day-of-year]
  (let [
        lng-hour (/ lon 15.0)

        t-rise (+ day-of-year (/ (- 6.0 lng-hour) 24.0))
        t-set  (+ day-of-year (/ (- 18.0 lng-hour) 24.0))

        m-rise (- (* 0.9856 t-rise) 3.289)
        m-set  (- (* 0.9856 t-set) 3.289)

        calc-L (fn [m]
                 (let [m-rad (to-radians m)
                       l (+ m 
                            (* 1.916 (sin m-rad)) 
                            (* 0.020 (sin (* 2.0 m-rad))) 
                            282.634)]
                   (fmod l 360.0)))
        
        l-rise (calc-L m-rise)
        l-set  (calc-L m-set)

        calc-RA (fn [l]
                  (let [l-rad (to-radians l)
                        ra (to-degrees (atan (* 0.91764 (tan l-rad))))
                        ra-mod (fmod ra 360.0)
                        l-quad (* (floor (/ l 90.0)) 90.0)
                        ra-quad (* (floor (/ ra-mod 90.0)) 90.0)]
                    (/ (+ ra-mod (- l-quad ra-quad)) 15.0)))
        
        ra-rise (calc-RA l-rise)
        ra-set  (calc-RA l-set)

        calc-dec (fn [l]
                   (let [l-rad (to-radians l)
                         sin-dec (* 0.39782 (sin l-rad))
                         ;; Used the identity cos(asin(x)) = sqrt(1 - x^2) here!
                         cos-dec (sqrt (- 1.0 (* sin-dec sin-dec)))]
                     {:sin-dec sin-dec :cos-dec cos-dec}))
        
        dec-rise (calc-dec l-rise)
        dec-set  (calc-dec l-set)

        zenith-rad (to-radians 90.83)
        lat-rad (to-radians lat)
        
        calc-H (fn [dec-map is-sunrise?]
                 (let [cos-h (/ (- (cos zenith-rad) 
                                   (* (sin lat-rad) (:sin-dec dec-map)))
                                (* (cos lat-rad) (:cos-dec dec-map)))]
                   (if (or (> cos-h 1) (< cos-h -1))
                     nil 
                     (let [h (to-degrees (acos cos-h))]
                       (if is-sunrise?
                         (/ (- 360.0 h) 15.0)
                         (/ h 15.0))))))
        
        h-rise (calc-H dec-rise true)
        h-set  (calc-H dec-set false)

        local-mean-rise (if (nil? h-rise) nil (fmod (+ h-rise ra-rise (* -0.06571 t-rise) -6.622) 24.0))
        local-mean-set  (if (nil? h-set) nil (fmod (+ h-set ra-set (* -0.06571 t-set) -6.622) 24.0))

        utc-rise (if (nil? local-mean-rise) nil (fmod (- local-mean-rise lng-hour) 24.0))
        utc-set  (if (nil? local-mean-set) nil (fmod (- local-mean-set lng-hour) 24.0))]

    {:sunrise-utc utc-rise
     :sunset-utc utc-set}))
;; Constants
(def pi 3.141592653589793)
(def half-pi 1.5707963267948966)

;; --- Missing Math Helpers ---

(defn fmod [a b]
  (- a (* b (floor (/ a b)))))

;; Custom acos using binary search (cos is monotonically decreasing 0 to PI)
(defn acos [x]
  (loop [low 0.0
         high pi
         iters 0]
    (let [mid (/ (+ low high) 2.0)
          c (cos mid)]
      (if (or (> iters 50) (< (abs (- c x)) 0.00001))
        mid
        (if (> c x)
          (recur mid high (inc iters)) ;; Need smaller cosine -> larger angle
          (recur low mid (inc iters)))))))

;; Custom atan using binary search (tan is monotonically increasing -PI/2 to PI/2)
(defn atan [x]
  (loop [low (- half-pi)
         high half-pi
         iters 0]
    (let [mid (/ (+ low high) 2.0)
          t (tan mid)]
      (if (or (> iters 50) (< (abs (- t x)) 0.00001))
        mid
        (if (< t x)
          (recur mid high (inc iters)) ;; Need larger tangent -> larger angle
          (recur low mid (inc iters)))))))

;; --- Sunrise / Sunset Logic ---

(defn to-radians [degrees]
  (* degrees (/ pi 180.0)))

(defn to-degrees [radians]
  (* radians (/ 180.0 pi)))

(defn compute-sunrise-sunset 
  [lat lon day-of-year]
  (let [
        lng-hour (/ lon 15.0)

        t-rise (+ day-of-year (/ (- 6.0 lng-hour) 24.0))
        t-set  (+ day-of-year (/ (- 18.0 lng-hour) 24.0))

        m-rise (- (* 0.9856 t-rise) 3.289)
        m-set  (- (* 0.9856 t-set) 3.289)

        calc-L (fn [m]
                 (let [m-rad (to-radians m)
                       l (+ m 
                            (* 1.916 (sin m-rad)) 
                            (* 0.020 (sin (* 2.0 m-rad))) 
                            282.634)]
                   (fmod l 360.0)))
        
        l-rise (calc-L m-rise)
        l-set  (calc-L m-set)

        calc-RA (fn [l]
                  (let [l-rad (to-radians l)
                        ra (to-degrees (atan (* 0.91764 (tan l-rad))))
                        ra-mod (fmod ra 360.0)
                        l-quad (* (floor (/ l 90.0)) 90.0)
                        ra-quad (* (floor (/ ra-mod 90.0)) 90.0)]
                    (/ (+ ra-mod (- l-quad ra-quad)) 15.0)))
        
        ra-rise (calc-RA l-rise)
        ra-set  (calc-RA l-set)

        calc-dec (fn [l]
                   (let [l-rad (to-radians l)
                         sin-dec (* 0.39782 (sin l-rad))
                         ;; Used the identity cos(asin(x)) = sqrt(1 - x^2) here!
                         cos-dec (sqrt (- 1.0 (* sin-dec sin-dec)))]
                     {:sin-dec sin-dec :cos-dec cos-dec}))
        
        dec-rise (calc-dec l-rise)
        dec-set  (calc-dec l-set)

        zenith-rad (to-radians 90.83)
        lat-rad (to-radians lat)
        
        calc-H (fn [dec-map is-sunrise?]
                 (let [cos-h (/ (- (cos zenith-rad) 
                                   (* (sin lat-rad) (:sin-dec dec-map)))
                                (* (cos lat-rad) (:cos-dec dec-map)))]
                   (if (or (> cos-h 1) (< cos-h -1))
                     nil 
                     (let [h (to-degrees (acos cos-h))]
                       (if is-sunrise?
                         (/ (- 360.0 h) 15.0)
                         (/ h 15.0))))))
        
        h-rise (calc-H dec-rise true)
        h-set  (calc-H dec-set false)

        local-mean-rise (if (nil? h-rise) nil (fmod (+ h-rise ra-rise (* -0.06571 t-rise) -6.622) 24.0))
        local-mean-set  (if (nil? h-set) nil (fmod (+ h-set ra-set (* -0.06571 t-set) -6.622) 24.0))

        utc-rise (if (nil? local-mean-rise) nil (fmod (- local-mean-rise lng-hour) 24.0))
        utc-set  (if (nil? local-mean-set) nil (fmod (- local-mean-set lng-hour) 24.0))]

    {:sunrise-utc utc-rise
     :sunset-utc utc-set}))

;; Formats decimal hours into a "HH:MM" string
(defn format-time [dec-hours]
  (if (nil? dec-hours)
    "N/A"
    (let [total-minutes (round (* dec-hours 60.0))
          hours (mod (floor (/ total-minutes 60.0)) 24)
          minutes (mod total-minutes 60)]
      (str hours ":" (if (< minutes 10) (str "0" minutes) minutes)))))

;; Calculates and returns readable local times
(defn compute-local-sunrise-sunset
  [lat lon day-of-year tz-offset]
  (let [result (compute-sunrise-sunset lat lon day-of-year)
        sr-utc (:sunrise-utc result)
        ss-utc (:sunset-utc result)
        ;; Adjust by offset and use fmod to ensure hours stay between 0 and 24
        sr-local (if (nil? sr-utc) nil (fmod (+ sr-utc tz-offset) 24.0))
        ss-local (if (nil? ss-utc) nil (fmod (+ ss-utc tz-offset) 24.0))]
    {:sunrise (format-time sr-local)
     :sunset  (format-time ss-local)}))

     
     (print (compute-local-sunrise-sunset 39.0840 -77.1528 167 -4.0)) ; Rockville
     (print (compute-local-sunrise-sunset 43.0731 -89.4012 167 -5.0)) ; Madison
     
     (print (compute-local-sunrise-sunset 39.0840 -77.1528 360 -5.0)) ; Rockville
     (print (compute-local-sunrise-sunset 43.0731 -89.4012 360 -6.0)) ; Madison
