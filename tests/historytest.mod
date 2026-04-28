MODULE HistoryTest;
(*
 * Quick smoke-test for the History module.
 * Type a few lines; Up/Down navigate history; Ctrl+C exits.
 * On exit the history is saved to /tmp/history_test.txt.
 *)
IMPORT History, Out;

VAR
  line: ARRAY 256 OF CHAR;
  i:    INTEGER;
BEGIN
  History.Load("/tmp/history_test.txt");
  REPEAT
    History.ReadLine("> ", line);
    IF line[0] # 0X THEN
      Out.String("  got: ");  Out.String(line);  Out.Ln
    END
  UNTIL line[0] = 0X;
  History.Save("/tmp/history_test.txt");
  Out.String("History saved to /tmp/history_test.txt");  Out.Ln
END HistoryTest.
