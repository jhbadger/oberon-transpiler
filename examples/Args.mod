MODULE Args;

(** Returns the number of command-line arguments (not counting the program name). *)
PROCEDURE Count*(): INTEGER;
BEGIN
  RETURN 0  (* handled by transpiler *)
END Count;

(** Copies argument n (1-based) into s.  s is empty if n is out of range. *)
PROCEDURE Get*(n: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  s[0] := 0X  (* handled by transpiler *)
END Get;

END Args.
