MODULE clojrepl;
(* Thin program wrapper: delegates entirely to Cloj.Main. *)
IMPORT Cloj, Args;
BEGIN
  Cloj.Main
END clojrepl.
