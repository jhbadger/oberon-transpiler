MODULE clojrepl_bio;
(* Cloj REPL / script runner with BioSeq/BioIO bindings available.
   Build: obc -I Modules/ -I examples/ examples/clojrepl_bio.mod -o cloj_bio
   Use:   cloj_bio seqSummary.clj file.fa [file2.fa ...]
          cloj_bio            -- interactive REPL with (import-oberon "bio") *)
IMPORT Cloj, Args, ClojBio;
BEGIN
  Cloj.AddOberonModule("bio", ClojBio.Export);
  Cloj.Main
END clojrepl_bio.
