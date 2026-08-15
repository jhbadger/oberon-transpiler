10 REM
20 REM  VOYAGE TO NEPTUNE -- AN INTERPLANETARY CROSSING
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM
60 DIM LEG$(7)
70 DIM DISTANCE(7)
80 LEG$(1)="Earth orbit to Mars flyby" : DISTANCE(1)=140
90 LEG$(2)="Mars to the Asteroid Belt" : DISTANCE(2)=180
100 LEG$(3)="Asteroid Belt to Jupiter flyby" : DISTANCE(3)=300
110 LEG$(4)="Jupiter to Saturn flyby" : DISTANCE(4)=400
120 LEG$(5)="Saturn to Uranus flyby" : DISTANCE(5)=900
130 LEG$(6)="Uranus to the approach to Neptune" : DISTANCE(6)=1000
140 LEG$(7)="Final approach and orbit insertion at Neptune" : DISTANCE(7)=50

150 FUEL=2000 : CELLS=0 : SOLAR=50 : SEG=0 : TOTALDAYS=0

200 CLS
210 PRINT "          VOYAGE TO NEPTUNE -- AN INTERPLANETARY CROSSING"
220 PRINT "                   adapted from David H. Ahl"
230 PRINT
240 INPUT "Press ENTER to begin the voyage!"; ANY$
250 CLS
260 PRINT "Your ship departs Earth orbit for Neptune, nearly three billion"
270 PRINT "miles away. Solar collectors supply about half your power at"
280 PRINT "the start, fading fast the farther you get from the sun -- the"
290 PRINT "rest must come from nuclear fuel and a small breeder reactor"
300 PRINT "that can manufacture more fuel from what the main engines burn."
310 PRINT
320 INPUT "Press ENTER to continue"; ANY$
330 CLS

995 REM ============================ main loop ================================
1000 SEG=SEG+1
1010 PRINT
1015 PRINT "Leg "; SEG; ": "; LEG$(SEG); " ("; DISTANCE(SEG); " million miles)"
1020 GOSUB 2000
1030 GOSUB 2500
1040 GOSUB 3000
1050 GOSUB 3500
1060 GOSUB 4000
1070 GOSUB 8500
1080 SOLAR=SOLAR-7
1085 IF SOLAR<5 THEN SOLAR=5
1090 IF SEG>=7 THEN GOTO 11000
1100 GOTO 1000

1995 REM ================================ trading =================================
2000 PRINT
2005 PRINT "You have "; FUEL; " lbs of fuel and "; CELLS; " breeder cells online."
2010 PRINT "  (1) Build a new cell (costs 30 lbs of fuel)"
2015 PRINT "  (2) Decommission a cell (recovers 15 lbs of fuel)"
2020 PRINT "  (3) Skip trading this leg"
2025 A1=1 : A2=3
2030 INPUT "Your choice? "; A
2035 GOSUB 10000
2040 IF A=3 THEN RETURN
2045 IF A=1 THEN GOTO 2100
2050 IF CELLS<1 THEN PRINT "You don't have any cells to decommission.": RETURN
2055 CELLS=CELLS-1 : FUEL=FUEL+15
2060 PRINT "You decommission a cell and recover 15 lbs of fuel."
2065 RETURN
2100 IF FUEL<30 THEN PRINT "You don't have enough fuel to build a new cell.": RETURN
2105 FUEL=FUEL-30 : CELLS=CELLS+1
2110 PRINT "A new breeder cell comes online."
2115 RETURN

2495 REM ============================ set engine burn =============================
2500 PRINT
2505 PRINT "How many pounds of nuclear fuel do you want to burn this leg (0 to "; FUEL; ")?"
2510 A1=0 : A2=FUEL
2515 INPUT "Your answer? "; A
2520 GOSUB 10000
2525 BURNFUEL=A
2530 RETURN

2995 REM ========================== operate breeder cells ==========================
3000 IF CELLS<1 THEN OPERATING=0: RETURN
3005 PRINT
3010 PRINT "You have "; CELLS; " breeder cells. Each running cell needs 5 lbs of"
3015 PRINT "primary fuel and 20 lbs of spent fuel from the engines to operate."
3020 MAXOP=CELLS
3025 IF INT((FUEL-BURNFUEL)/5)<MAXOP THEN MAXOP=INT((FUEL-BURNFUEL)/5)
3030 IF INT(BURNFUEL/20)<MAXOP THEN MAXOP=INT(BURNFUEL/20)
3035 IF MAXOP<0 THEN MAXOP=0
3040 A1=0 : A2=MAXOP
3045 INPUT "How many cells do you want to operate this leg? "; A
3050 GOSUB 10000
3055 OPERATING=A
3060 FUEL=FUEL-BURNFUEL-OPERATING*5
3065 RETURN

3495 REM ============================ engines and transit ==========================
3500 EFF=SOLAR+INT(BURNFUEL/20)
3505 IF EFF>104 THEN EFF=104
3510 IF INT(RND*100)+1<=10 THEN GOSUB 3600
3515 IF EFF<10 THEN EFF=10
3520 RATE=INT(40000*EFF/100)
3525 DST=DISTANCE(SEG)
3530 LEGTIME=INT(DST*1000000/RATE/24)
3535 PRINT
3540 PRINT "Engine efficiency: "; EFF; "%.  Cruising speed: "; RATE; " mph."
3545 PRINT "This leg takes "; LEGTIME; " days."
3550 TOTALDAYS=TOTALDAYS+LEGTIME
3555 RETURN

3595 REM ============================ engine malfunction ===========================
3600 PRINT "A malfunction ripples through the main engines!"
3605 EFF=INT(EFF*(5+RND*3)/10)
3610 PRINT "Efficiency drops to "; EFF; "% while the crew scrambles to compensate."
3615 RETURN

3995 REM ========================= breeder output and decay ========================
4000 IF OPERATING<1 THEN RETURN
4005 PRODUCED=0
4010 FOR K=1 TO OPERATING
4015   PRODUCED=PRODUCED+INT(16+RND*18)
4020 NEXT K
4025 FUEL=FUEL+PRODUCED
4030 PRINT "Your breeder cells produce "; PRODUCED; " lbs of new fuel."
4035 IF INT(RND*100)+1<=20 THEN GOSUB 4100
4040 RETURN
4100 DECAY=INT(FUEL/20+RND*FUEL/10)
4105 FUEL=FUEL-DECAY
4110 IF FUEL<0 THEN FUEL=0
4115 PRINT "Some stored fuel decays and becomes unusable: -"; DECAY; " lbs."
4120 RETURN

8495 REM ============================ print status ================================
8500 PRINT
8505 PRINT "Fuel: "; FUEL; " lbs   Cells online: "; CELLS; "   Solar power: "; SOLAR; "%"
8510 RETURN

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 IF A<A1 THEN PRINT "That's too few. Try again." ELSE PRINT "That's too many. Try again."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================== arrival! ===================================
11000 CLS
11005 PRINT "YOU ARRIVE AT NEPTUNE!"
11010 PRINT
11015 YR=INT(TOTALDAYS/365)
11020 DY=TOTALDAYS-YR*365
11025 PRINT "Total voyage time: "; YR; " years, "; DY; " days."
11030 PRINT "You arrive with "; FUEL; " lbs of fuel and "; CELLS; " breeder cells"
11035 PRINT "still online."
11040 IF YR<=8 THEN PRINT "A remarkably fast crossing of the outer solar system."
11045 IF (YR>8) AND (YR<=12) THEN PRINT "A long but steady voyage, true to the scale of the real thing."
11050 IF YR>12 THEN PRINT "A grueling, drawn-out journey -- but you made it."
11055 PRINT
11060 INPUT "Press ENTER to end"; ANY$
11065 END
