10 REM
20 REM  SUBWAY SCAVENGER -- A DAY AS A COURIER
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition).
50 REM  The transit map here is an original, fictional small system.
60 DIM STA$(10)
70 STA$(1)="Central Station" : STA$(2)="Riverside" : STA$(3)="Uptown Square"
80 STA$(4)="Harbor View" : STA$(5)="West End" : STA$(6)="Market Street"
90 STA$(7)="Old Town" : STA$(8)="University" : STA$(9)="Stadium"
100 STA$(10)="East Gate"

110 DIM L$(4)
120 L$(1)="Red Line" : L$(2)="Blue Line" : L$(3)="Green Line" : L$(4)="Yellow Line"

130 DIM LSTOPS(4,5)
140 DIM LCOUNT(4)
150 LSTOPS(1,1)=1 : LSTOPS(1,2)=2 : LSTOPS(1,3)=3 : LSTOPS(1,4)=4 : LSTOPS(1,5)=5 : LCOUNT(1)=5
160 LSTOPS(2,1)=6 : LSTOPS(2,2)=3 : LSTOPS(2,3)=7 : LSTOPS(2,4)=8 : LCOUNT(2)=4
170 LSTOPS(3,1)=1 : LSTOPS(3,2)=6 : LSTOPS(3,3)=9 : LSTOPS(3,4)=10 : LCOUNT(3)=4
180 LSTOPS(4,1)=5 : LSTOPS(4,2)=4 : LSTOPS(4,3)=8 : LSTOPS(4,4)=10 : LCOUNT(4)=4

190 DIM STLINES(10,3)
200 DIM STNLINES(10)
210 STNLINES(1)=2 : STLINES(1,1)=1 : STLINES(1,2)=3
220 STNLINES(2)=1 : STLINES(2,1)=1
230 STNLINES(3)=2 : STLINES(3,1)=1 : STLINES(3,2)=2
240 STNLINES(4)=2 : STLINES(4,1)=1 : STLINES(4,2)=4
250 STNLINES(5)=2 : STLINES(5,1)=1 : STLINES(5,2)=4
260 STNLINES(6)=2 : STLINES(6,1)=2 : STLINES(6,2)=3
270 STNLINES(7)=1 : STLINES(7,1)=2
280 STNLINES(8)=2 : STLINES(8,1)=2 : STLINES(8,2)=4
290 STNLINES(9)=1 : STLINES(9,1)=3
300 STNLINES(10)=2 : STLINES(10,1)=3 : STLINES(10,2)=4

310 DIM PKGPICKUP(5)
320 DIM PKGDROP(5)
330 DIM PKGDONE(5)
340 FOR P=1 TO 5
350   PKGPICKUP(P)=INT(1+RND*10)
360   PKGDROP(P)=INT(1+RND*10)
370   IF PKGDROP(P)=PKGPICKUP(P) THEN GOTO 360
380   PKGDONE(P)=0
390 NEXT P

400 CARRYING=0 : DELIVERED=0 : TIME=0 : MONEY=20 : CURSTATION=1

500 CLS
510 PRINT "         SUBWAY SCAVENGER -- A DAY AS A COURIER"
520 PRINT "               adapted from David H. Ahl"
530 PRINT
540 INPUT "Press ENTER to start your shift!"; ANY$
550 CLS
560 PRINT "You're a bicycle-less courier today -- everything moves by"
570 PRINT "subway. Five packages need picking up and dropping off around"
580 PRINT "the city before your shift ends. Tokens cost a dollar a ride,"
590 PRINT "and you've got 480 minutes on the clock starting from Central"
600 PRINT "Station."
610 PRINT
620 INPUT "Press ENTER to begin!"; ANY$
630 CLS

995 REM ============================ main loop ================================
1000 GOSUB 9000
1010 PRINT "(1) Pick up a package here"
1015 PRINT "(2) Deliver a package here"
1020 PRINT "(3) Board a train"
1025 PRINT "(4) Check your logbook"
1030 PRINT "(5) End your day early"
1035 A1=1 : A2=5
1040 INPUT "Your choice? "; A
1045 GOSUB 10000
1050 IF A=1 THEN GOSUB 2000
1055 IF A=2 THEN GOSUB 2500
1060 IF A=3 THEN GOSUB 3000
1065 IF A=4 THEN GOSUB 3500
1070 IF A=5 THEN GOTO 11500
1075 GOSUB 8000
1080 GOTO 1000

1995 REM ================================= pick up ================================
2000 FOUND=0
2005 FOR P=1 TO 5
2010   IF (PKGPICKUP(P)=CURSTATION) AND (PKGDONE(P)=0) THEN FOUND=P
2015 NEXT P
2020 IF FOUND=0 THEN PRINT "There's no package to pick up here.": RETURN
2025 IF CARRYING<>0 THEN PRINT "Your hands are full -- deliver your current package first.": RETURN
2030 CARRYING=FOUND
2035 PKGDONE(FOUND)=1
2040 PRINT "You pick up package "; FOUND; ", bound for "; STA$(PKGDROP(FOUND)); "."
2045 TIME=TIME+6
2050 RETURN

2495 REM ================================= deliver ================================
2500 IF CARRYING=0 THEN PRINT "You're not carrying anything to deliver.": RETURN
2505 IF PKGDROP(CARRYING)<>CURSTATION THEN PRINT "This isn't the right station for that package.": RETURN
2510 PRINT "You deliver package "; CARRYING; ". One more done!"
2515 PKGDONE(CARRYING)=2
2520 CARRYING=0
2525 DELIVERED=DELIVERED+1
2530 TIME=TIME+6
2535 RETURN

2995 REM =============================== board a train =============================
3000 IF MONEY<1 THEN PRINT "You're out of tokens.": RETURN
3005 PRINT "Trains here:"
3010 FOR K=1 TO STNLINES(CURSTATION)
3015   PRINT "  ("; K; ") "; L$(STLINES(CURSTATION,K))
3020 NEXT K
3025 A1=1 : A2=STNLINES(CURSTATION)
3030 INPUT "Which line do you want to board? "; A
3035 GOSUB 10000
3040 LN=STLINES(CURSTATION,A)
3045 PRINT "Which direction?"
3050 PRINT "  (1) Toward "; STA$(LSTOPS(LN,1))
3055 PRINT "  (2) Toward "; STA$(LSTOPS(LN,LCOUNT(LN)))
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
3115 MONEY=MONEY-1
3120 CURSTATION=LSTOPS(LN,NEWIDX)
3125 TIME=TIME+INT(2+RND*2)
3130 PRINT
3135 GOSUB 4000
3140 PRINT "You arrive at "; STA$(CURSTATION); "."
3145 RETURN

3495 REM ================================= hazard =================================
4000 RN=INT(RND*100)+1
4005 IF RN<=10 THEN PRINT "The doors stick and you lose a few minutes.": TIME=TIME+INT(3+RND*5): RETURN
4010 IF RN<=16 THEN PRINT "A track delay holds the train for a while.": TIME=TIME+INT(5+RND*10): RETURN
4015 IF RN<=20 THEN PRINT "A stranger bumps into you -- you check your pockets nervously, but nothing's missing.": RETURN
4020 RETURN

4495 REM ================================= logbook =================================
3500 PRINT
3505 PRINT "-- Logbook --"
3510 FOR P=1 TO 5
3515   IF PKGDONE(P)=2 THEN PRINT "Package "; P; ": delivered."
3520   IF PKGDONE(P)=1 THEN PRINT "Package "; P; ": in hand, bound for "; STA$(PKGDROP(P)); "."
3525   IF PKGDONE(P)=0 THEN PRINT "Package "; P; ": waiting for pickup at "; STA$(PKGPICKUP(P)); "."
3530 NEXT P
3535 PRINT
3540 RETURN

7995 REM ======================== check for the day's end ==========================
8000 IF DELIVERED>=5 THEN GOTO 11000
8005 IF TIME>=480 THEN GOTO 11500
8010 IF MONEY<1 THEN GOTO 11500
8015 RETURN

8995 REM ============================ print status ================================
9000 PRINT
9005 PRINT "== "; STA$(CURSTATION); " -- "; TIME; "/480 min used -- $"; MONEY; " -- "; DELIVERED; "/5 delivered =="
9010 RETURN

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 IF A<A1 THEN PRINT "That's not one of the choices." ELSE PRINT "That's not one of the choices."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================= all delivered! ==============================
11000 CLS
11005 PRINT "ALL FIVE PACKAGES DELIVERED!"
11010 PRINT
11015 PRINT "You call it in and head back to the depot. A good day's work,"
11020 PRINT "with "; 480-TIME; " minutes to spare and $"; MONEY; " left in tokens."
11025 IF TIME<=200 THEN PRINT "That's a blazing-fast run through the system."
11030 IF (TIME>200) AND (TIME<=350) THEN PRINT "A solid, professional day's work."
11035 IF TIME>350 THEN PRINT "You cut it close, but you got every package where it belonged."
11040 PRINT
11045 INPUT "Press ENTER to end"; ANY$
11050 END

11495 REM =============================== shift's over ==============================
11500 CLS
11505 PRINT "YOUR DAY ENDS"
11510 PRINT
11515 IF MONEY<1 THEN PRINT "You're out of tokens, stranded far from the depot."
11520 IF TIME>=480 THEN PRINT "It's 5:00 -- your shift is over, ready or not."
11525 IF (MONEY>=1) AND (TIME<480) THEN PRINT "You call it a day early."
11530 PRINT
11535 PRINT "You delivered "; DELIVERED; " of 5 packages."
11540 PRINT
11545 INPUT "Press ENTER to end"; ANY$
11550 END
