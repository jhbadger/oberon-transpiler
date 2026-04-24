MODULE PlotRand;

IMPORT Terminal, Random;

VAR 
  i,x,y,c: INTEGER;
  
BEGIN
  Terminal.Clear;
  FOR i := 1 TO 2000 DO
    c := Random.Int(215)+17;
    x := Random.Int(100);
    y := Random.Int(100);
    Terminal.Plot(x, y, c);
  END;
  Terminal.Flush;
END PlotRand.