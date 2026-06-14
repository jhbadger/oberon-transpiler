MODULE clojrepl_stats;
(* Demo: Cloj REPL with the ClojStats module pre-registered. *)
IMPORT Cloj, Args, ClojStats;
BEGIN
  Cloj.AddOberonModule("stats", ClojStats.Export);
  Cloj.Main
END clojrepl_stats.
