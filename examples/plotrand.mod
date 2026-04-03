MODULE PlotRand;

IMPORT Graphics, Random;

VAR 
  i,x,y,c: INTEGER;
  
BEGIN
  Graphics.Clear;
  FOR i := 1 TO 2000 DO
    c := Random.Int(6)+1;
    x := Random.Int(100);
    y := Random.Int(100);
    Graphics.Plot(x, y, c);
  END;
  Graphics.Flush;
END PlotRand.