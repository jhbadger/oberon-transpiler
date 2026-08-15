10 REM
20 REM  HONG KONG HUSTLE -- COLLECT THE BAGS BY MIDNIGHT
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition).
50 REM  The transit map here is an original, simplified abstraction.
60 DIM STOP$(9)
70 STOP$(1)="Central" : STOP$(2)="Causeway Bay" : STOP$(3)="North Point"
80 STOP$(4)="Tsim Sha Tsui" : STOP$(5)="Mong Kok" : STOP$(6)="Kowloon Tong"
90 STOP$(7)="Sha Tin" : STOP$(8)="Tsuen Wan" : STOP$(9)="Sai Kung"

100 DIM L$(5)
110 L$(1)="Island Line" : L$(2)="Tsuen Wan Line" : L$(3)="East Rail Line"
120 L$(4)="Star Ferry" : L$(5)="Sai Kung Bus"

130 DIM LSTOPS(5,4)
140 DIM LTIMES(5,3)
150 DIM LCOUNT(5)
160 LSTOPS(1,1)=1 : LSTOPS(1,2)=2 : LSTOPS(1,3)=3 : LCOUNT(1)=3
170 LTIMES(1,1)=6 : LTIMES(1,2)=5
180 LSTOPS(2,1)=4 : LSTOPS(2,2)=5 : LSTOPS(2,3)=6 : LSTOPS(2,4)=8 : LCOUNT(2)=4
190 LTIMES(2,1)=4 : LTIMES(2,2)=5 : LTIMES(2,3)=9
200 LSTOPS(3,1)=6 : LSTOPS(3,2)=7 : LCOUNT(3)=2
210 LTIMES(3,1)=7
220 LSTOPS(4,1)=1 : LSTOPS(4,2)=4 : LCOUNT(4)=2
230 LTIMES(4,1)=8
240 LSTOPS(5,1)=9 : LSTOPS(5,2)=7 : LCOUNT(5)=2
250 LTIMES(5,1)=15

260 DIM STLINES(9,3)
270 DIM STNLINES(9)
280 STNLINES(1)=2 : STLINES(1,1)=1 : STLINES(1,2)=4
290 STNLINES(2)=1 : STLINES(2,1)=1
300 STNLINES(3)=1 : STLINES(3,1)=1
310 STNLINES(4)=2 : STLINES(4,1)=2 : STLINES(4,2)=4
320 STNLINES(5)=1 : STLINES(5,1)=2
330 STNLINES(6)=2 : STLINES(6,1)=2 : STLINES(6,2)=3
340 STNLINES(7)=2 : STLINES(7,1)=3 : STLINES(7,2)=5
350 STNLINES(8)=1 : STLINES(8,1)=2
360 STNLINES(9)=1 : STLINES(9,1)=5

370 DIM WALKA(3)
380 DIM WALKB(3)
390 DIM WALKT(3)
400 WALKA(1)=2 : WALKB(1)=3 : WALKT(1)=12
410 WALKA(2)=5 : WALKB(2)=6 : WALKT(2)=10
420 WALKA(3)=1 : WALKB(3)=4 : WALKT(3)=25

430 DIM BAGSTATION(8)
440 DIM BAGDONE(8)
450 FOR B=1 TO 8
460   BAGSTATION(B)=INT(1+RND*9)
470   BAGDONE(B)=0
480 NEXT B

490 CURSTATION=1 : TIME=0 : MONEY=15 : COLLECTED=0

500 CLS
510 PRINT "         HONG KONG HUSTLE -- COLLECT THE BAGS BY MIDNIGHT"
520 PRINT "                  adapted from David H. Ahl"
530 PRINT
540 INPUT "Press ENTER to start your hustle!"; ANY$
550 CLS
560 PRINT "Word is out: eight bags of gold and jewels are stashed at stops"
570 PRINT "around Hong Kong Island, Kowloon, and the New Territories. You"
580 PRINT "have from now until midnight -- six hours -- to grab them all."
590 PRINT "MTR fares cost a dollar a ride, but a few stops are close enough"
600 PRINT "to reach on foot for free, if you don't mind the walk."
610 PRINT
620 INPUT "Press ENTER to begin!"; ANY$
630 CLS

995 REM ============================ main loop ================================
1000 GOSUB 9000
1010 PRINT "(1) Collect a bag here"
1015 PRINT "(2) Board transit"
1020 PRINT "(3) Walk to a nearby stop"
1025 PRINT "(4) Check your progress"
1030 PRINT "(5) End your hustle early"
1035 A1=1 : A2=5
1040 INPUT "Your choice? "; A
1045 GOSUB 10000
1050 IF A=1 THEN GOSUB 2000
1055 IF A=2 THEN GOSUB 3000
1060 IF A=3 THEN GOSUB 3500
1065 IF A=4 THEN GOSUB 4000
1070 IF A=5 THEN GOTO 11500
1075 GOSUB 8000
1080 GOTO 1000

1995 REM =============================== collect a bag ============================
2000 FOUND=0
2005 FOR B=1 TO 8
2010   IF (BAGSTATION(B)=CURSTATION) AND (BAGDONE(B)=0) THEN FOUND=B
2015 NEXT B
2020 IF FOUND=0 THEN PRINT "No bag here.": RETURN
2025 BAGDONE(FOUND)=1
2030 COLLECTED=COLLECTED+1
2035 PRINT "You grab a bag of gold and jewels! ("; COLLECTED; "/8)"
2040 TIME=TIME+3
2045 RETURN

2995 REM =============================== board transit =============================
3000 IF MONEY<1 THEN PRINT "You're out of money for fares.": RETURN
3005 PRINT "Transit here:"
3010 FOR K=1 TO STNLINES(CURSTATION)
3015   PRINT "  ("; K; ") "; L$(STLINES(CURSTATION,K))
3020 NEXT K
3025 A1=1 : A2=STNLINES(CURSTATION)
3030 INPUT "Which do you want to board? "; A
3035 GOSUB 10000
3040 LN=STLINES(CURSTATION,A)
3045 PRINT "Which direction?"
3050 PRINT "  (1) Toward "; STOP$(LSTOPS(LN,1))
3055 PRINT "  (2) Toward "; STOP$(LSTOPS(LN,LCOUNT(LN)))
3060 A1=1 : A2=2
3065 INPUT "Your choice? "; A
3070 GOSUB 10000
3075 DR=A
3085 IDX=0
3090 FOR K=1 TO LCOUNT(LN)
3095   IF LSTOPS(LN,K)=CURSTATION THEN IDX=K
3100 NEXT K
3105 IF DR=1 THEN NEWIDX=IDX-1 ELSE NEWIDX=IDX+1
3110 IF (NEWIDX<1) OR (NEWIDX>LCOUNT(LN)) THEN PRINT "That's the end of the line already.": RETURN
3115 IF DR=1 THEN GAP=NEWIDX ELSE GAP=IDX
3120 MONEY=MONEY-1
3125 TIME=TIME+LTIMES(LN,GAP)
3130 PRINT
3135 PRINT "It takes "; LTIMES(LN,GAP); " minutes."
3140 CURSTATION=LSTOPS(LN,NEWIDX)
3145 PRINT "You arrive at "; STOP$(CURSTATION); "."
3150 RETURN

3495 REM ================================ walk =====================================
3500 FOUND=0
3505 FOR K=1 TO 3
3510   IF WALKA(K)=CURSTATION THEN FOUND=K : TARGET=WALKB(K)
3515   IF WALKB(K)=CURSTATION THEN FOUND=K : TARGET=WALKA(K)
3520 NEXT K
3525 IF FOUND=0 THEN PRINT "There's nowhere within walking distance from here.": RETURN
3530 PRINT "You can walk to "; STOP$(TARGET); " ("; WALKT(FOUND); " minutes)."
3535 PRINT "Do you want to walk there?"
3540 GOSUB 9500
3545 IF YES=0 THEN RETURN
3550 TIME=TIME+WALKT(FOUND)
3555 CURSTATION=TARGET
3560 PRINT "You arrive at "; STOP$(CURSTATION); "."
3565 RETURN

3995 REM =============================== check progress ============================
4000 PRINT
4005 PRINT "You've collected "; COLLECTED; " of 8 bags."
4010 PRINT "Time remaining: "; 360-TIME; " minutes. Cash: $"; MONEY
4015 PRINT
4020 RETURN

7995 REM ======================== check for the hustle's end =======================
8000 IF COLLECTED>=8 THEN GOTO 11000
8005 IF TIME>=360 THEN GOTO 11500
8010 RETURN

8995 REM ============================ print status ================================
9000 PRINT
9005 PRINT "== "; STOP$(CURSTATION); " -- "; TIME; "/360 min -- $"; MONEY; " -- "; COLLECTED; "/8 bags =="
9010 RETURN

9495 REM ============================ yes/no helper =============================
9500 INPUT YN$
9505 IF YN$="" THEN YES=1: RETURN
9510 IF (LEFT$(YN$,1)="Y") OR (LEFT$(YN$,1)="y") THEN YES=1: RETURN
9515 IF (LEFT$(YN$,1)="N") OR (LEFT$(YN$,1)="n") THEN YES=0: RETURN
9520 PRINT "Please answer Y or N."
9525 GOTO 9500

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 IF A<A1 THEN PRINT "That's not one of the choices." ELSE PRINT "That's not one of the choices."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================= all eight collected! =========================
11000 CLS
11005 PRINT "ALL EIGHT BAGS COLLECTED!"
11010 PRINT
11015 PRINT "You make it back with time to spare -- "; 360-TIME; " minutes left on"
11020 PRINT "the clock and $"; MONEY; " still in your pocket. A perfect hustle."
11025 PRINT
11030 INPUT "Press ENTER to end"; ANY$
11035 END

11495 REM ================================ time's up =================================
11500 CLS
11505 PRINT "YOUR HUSTLE ENDS"
11510 PRINT
11515 IF TIME>=360 THEN PRINT "Midnight arrives, and your hustle is over."
11520 IF TIME<360 THEN PRINT "You call it a night early."
11525 PRINT
11530 PRINT "You collected "; COLLECTED; " of 8 bags."
11535 PRINT
11540 INPUT "Press ENTER to end"; ANY$
11545 END
