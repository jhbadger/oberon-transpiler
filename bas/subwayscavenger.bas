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

310 REM ======================= the day's fifteen errands ========================
320 DIM DORP(15)
330 DIM PKGDEST(15)
340 FOR I=1 TO 5
350   PKGDEST(I)=INT(2+RND*9)
360   DORP(I)=1
370 NEXT I
380 FOR I=6 TO 10
390   PKGDEST(I)=INT(2+RND*9)
400   DORP(I)=2
410 NEXT I
420 FOR I=11 TO 15
430   PKGDEST(I)=INT(2+RND*9)
440   IF PKGDEST(I)=PKGDEST(I-5) THEN GOTO 430
450   DORP(I)=0
460 NEXT I

470 REM ============================ initial values ================================
480 TIME=0 : TOKEN=0 : TKMAX=20 : TK=0 : LUN=0 : DELTOT=0 : CURSTATION=1 : ENDREASON=0

495 REM ============================ opening scenario =============================
500 CLS
510 PRINT "              SUBWAY SCAVENGER -- A DAY AS A COURIER"
520 PRINT "                    adapted from David H. Ahl, 1986"
530 PRINT
540 INPUT "Press ENTER to begin!"; ANY$
550 CLS
560 PRINT "You have a job with a messenger/courier service based at"
570 PRINT "Central Station. Today you have five packages to deliver and"
580 PRINT "five packages to pick up for delivery elsewhere in the city."
590 PRINT "In all, you must complete fifteen separate errands."
600 PRINT
610 PRINT "You can ride the subway system, served by the Red, Blue, Green,"
620 PRINT "and Yellow lines. Your boss has given you 20 tokens (worth a"
630 PRINT "dollar each) for the day; any you don't spend are yours to keep."
640 PRINT
650 INPUT "Do you want to be able to work past 5:00 pm (easier)? "; AD$
660 GOSUB 8500
670 IF YES=1 THEN DEADLINE=540
680 IF YES=0 THEN DEADLINE=480
690 CLS
700 PRINT "You may want to jot down today's log before you start."
710 GOSUB 7000
720 INPUT "Press ENTER to hit the subway!"; ANY$
730 CLS

995 REM ============================ main loop ================================
1000 GOSUB 9000
1005 GOSUB 8000
1010 IF ENDREASON<>0 THEN GOTO 11500
1015 PRINT "(1) Pick up a package here"
1020 PRINT "(2) Deliver a package here"
1025 PRINT "(3) Board a train"
1030 PRINT "(4) Check your logbook"
1035 PRINT "(5) End your day early"
1040 A1=1 : A2=5
1045 INPUT "Your choice? "; A
1050 GOSUB 10000
1052 CHOICE=A
1055 IF CHOICE=1 THEN GOSUB 2000
1060 IF CHOICE=2 THEN GOSUB 2500
1065 IF CHOICE=3 THEN GOSUB 3000
1070 IF CHOICE=4 THEN GOSUB 7000
1075 IF CHOICE=5 THEN GOTO 11500
1080 IF ENDREASON<>0 THEN GOTO 11500
1085 IF DELTOT=15 THEN GOTO 11000
1090 GOTO 1000

1995 REM ================================= pick up ================================
2000 INPUT "Which pickup (logbook number)? "; A
2005 A1=1 : A2=15
2010 GOSUB 10000
2015 IF DORP(A)=2 THEN GOTO 2035
2020 PRINT "That's not a package waiting for pickup."
2025 RETURN
2035 IF PKGDEST(A)<>CURSTATION THEN PRINT "That pickup isn't at this station." : RETURN
2040 BLOCKS=INT(1+RND*3)
2045 TIME=TIME+2*BLOCKS+6
2050 PRINT "You find package "; A; " "; BLOCKS; " blocks away and sign for it."
2055 PRINT "It's addressed to "; STA$(PKGDEST(A+5)); "."
2060 DORP(A)=0 : DORP(A+5)=1
2065 DELTOT=DELTOT+1
2070 RETURN

2495 REM ================================= deliver ================================
2500 INPUT "Which delivery (logbook number)? "; A
2505 A1=1 : A2=15
2510 GOSUB 10000
2515 IF DORP(A)=1 THEN GOTO 2535
2520 PRINT "You're not holding that package."
2525 RETURN
2535 IF PKGDEST(A)<>CURSTATION THEN PRINT "This isn't the right station for that delivery." : RETURN
2540 BLOCKS=INT(1+RND*3)
2545 TIME=TIME+2*BLOCKS+6
2550 PRINT "You walk "; BLOCKS; " blocks and deliver package "; A; ". One more done!"
2555 DORP(A)=0
2560 DELTOT=DELTOT+1
2565 RETURN

2995 REM =============================== board a train =============================
3000 IF TOKEN<TKMAX THEN GOTO 3020
3005 GOSUB 4500
3010 IF ENDREASON<>0 THEN RETURN
3015 IF TOKEN>=TKMAX THEN RETURN
3020 TOKEN=TOKEN+1
3025 RI=INT(1+RND*STNLINES(CURSTATION))
3030 LI=STLINES(CURSTATION,RI)
3035 FOR K=1 TO LCOUNT(LI)
3040   IF LSTOPS(LI,K)=CURSTATION THEN IDX=K
3045 NEXT K
3050 IF IDX=1 THEN DES=2
3055 IF IDX=LCOUNT(LI) THEN DES=1
3060 IF (IDX<>1) AND (IDX<>LCOUNT(LI)) THEN DES=INT(1+RND*2)
3065 TIME=TIME+1
3070 IF DES=1 THEN ENDSTOP=LSTOPS(LI,1)
3075 IF DES=2 THEN ENDSTOP=LSTOPS(LI,LCOUNT(LI))
3080 PRINT "Here comes the "; L$(LI); " train toward "; STA$(ENDSTOP)
3085 INPUT "Do you want to get on? "; AD$
3090 GOSUB 8500
3095 IF YES=0 THEN GOTO 3025
3100 GOSUB 4000
3105 IF ENDREASON<>0 THEN RETURN
3110 IF DES=1 THEN DIR=-1
3115 IF DES=2 THEN DIR=1
3120 IDX=IDX+DIR
3125 CURSTATION=LSTOPS(LI,IDX)
3130 TIME=TIME+INT(2+RND*2)
3135 PRINT "You arrive at "; STA$(CURSTATION); "."
3140 GOSUB 8000
3145 IF ENDREASON<>0 THEN RETURN
3150 IF (IDX=1) OR (IDX=LCOUNT(LI)) THEN PRINT "End of the line -- everybody off." : RETURN
3155 INPUT "Get off here, or ride on to the next stop (Y=off, N=ride on)? "; AD$
3160 GOSUB 8500
3165 IF YES=1 THEN RETURN
3170 GOTO 3100

3495 REM ================================= ride hazards =============================
4000 IF RND>.05 THEN GOTO 4030
4005 PRINT "A car door refuses to close and the train sits for a while."
4010 RN=INT(1+2.5*RND)
4015 TIME=TIME+RN
4020 IF RN=1 THEN PRINT "You lose "; RN; " minute."
4025 IF RN<>1 THEN PRINT "You lose "; RN; " minutes."
4030 IF RND>.05 THEN GOTO 4200
4035 PRINT "A rough-looking group is causing a scene in the next car."
4040 INPUT "Do you want to move to another car? "; AD$
4045 GOSUB 8500
4050 IF YES=1 THEN GOTO 4070
4055 GOTO 4110
4070 IF RND>.4 THEN PRINT "They jeer but let you pass. All okay...for now." : GOTO 4200
4075 GOTO 4150
4110 IF RND>.4 THEN PRINT "They eye you but you manage to avoid them." : GOTO 4200
4115 GOTO 4150
4150 PRINT "They surround you and demand your tokens."
4155 PRINT "Rather than risk it, you hand them over and call it a day."
4160 ENDREASON=1
4165 RETURN
4200 IF RND>.008 THEN RETURN
4205 PRINT "The train grinds to a halt in the tunnel."
4210 PRINT "After a while, a trainman announces it's just a fire on the tracks"
4215 RN=INT(10+35*RND)
4220 TIME=TIME+RN
4225 PRINT "and you're underway again after a "; RN; "-minute delay."
4230 RETURN

4495 REM ============================ out of tokens =================================
4500 PRINT
4505 PRINT "You've used up all the tokens your boss gave you."
4510 IF TK=1 THEN PRINT "And you're out of your own money too. Stranded!" : ENDREASON=2 : RETURN
4515 TK=1
4520 INPUT "Do you want to buy more tokens with your own money? "; AD$
4525 GOSUB 8500
4530 IF YES=1 THEN GOTO 4545
4535 PRINT "Okay, that's it for today."
4540 ENDREASON=2 : RETURN
4545 EXTRA=INT(3+RND*6)
4550 PRINT "You happen to have enough cash for "; EXTRA; " more tokens."
4555 TKMAX=TKMAX+EXTRA
4560 RETURN

6995 REM ============================ logbook =====================================
7000 PRINT
7005 PRINT "-- Logbook --"
7010 FOR I=1 TO 15
7015   IF DORP(I)=0 THEN GOTO 7040
7020   IF DORP(I)=1 THEN PRINT "  "; I; ": deliver to "; STA$(PKGDEST(I))
7025   IF DORP(I)=2 THEN PRINT "  "; I; ": pick up at "; STA$(PKGDEST(I))
7040 NEXT I
7045 PRINT
7050 RETURN

7995 REM ======================== deadline and lunch check ==========================
8000 IF TIME<DEADLINE THEN GOTO 8020
8005 PRINT "It's past your deadline -- the places you need to reach are closing up."
8010 ENDREASON=3
8015 RETURN
8020 IF LUN=1 THEN RETURN
8025 IF TIME<180 THEN RETURN
8030 PRINT
8035 PRINT "Time for a lunch break. Chili dog and cola. Burp!"
8040 RN=INT(24+20*RND)
8045 TIME=TIME+RN
8050 LUN=1
8055 RETURN

8495 REM ============================ yes/no helper =====================================
8500 IF (LEFT$(AD$,1)="Y") OR (LEFT$(AD$,1)="y") THEN YES=1 : RETURN
8505 IF (LEFT$(AD$,1)="N") OR (LEFT$(AD$,1)="n") THEN YES=0 : RETURN
8510 PRINT "Don't understand your answer. Enter 'Y' or 'N' please."
8515 INPUT AD$
8520 GOTO 8500

8995 REM ============================ status printer ================================
9000 PRINT
9005 PRINT "== "; STA$(CURSTATION); " -- "; DELTOT; "/15 errands done =="
9010 H24=9+INT(TIME/60)
9015 MN=TIME-60*INT(TIME/60)
9020 CLKH=H24
9025 IF CLKH>12 THEN CLKH=CLKH-12
9030 PRINT "Time: "; CLKH; ":";
9035 IF MN<10 THEN PRINT "0";
9040 PRINT MN;
9045 IF H24<12 THEN PRINT " am -- ";
9050 IF H24>=12 THEN PRINT " pm -- ";
9055 PRINT TKMAX-TOKEN; " tokens left"
9060 RETURN

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 PRINT "That's not one of the choices."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================= all errands done! ==============================
11000 CLS
11005 PRINT "                 ALL FIFTEEN ERRANDS COMPLETE!"
11010 PRINT
11015 PRINT "You call it in and head back to the depot. A great day's work,"
11020 PRINT "with "; TKMAX-TOKEN; " tokens left in your pocket."
11025 PRINT
11030 INPUT "Press ENTER to end"; ANY$
11035 END

11495 REM =============================== the day ends ==============================
11500 CLS
11505 PRINT "YOUR DAY ENDS"
11510 PRINT
11515 IF ENDREASON=1 THEN PRINT "You were robbed and had to call it quits."
11520 IF ENDREASON=2 THEN PRINT "You ran out of tokens and money to buy more. Stranded!"
11525 IF ENDREASON=3 THEN PRINT "It's past your deadline -- your shift is over."
11530 IF ENDREASON=0 THEN PRINT "You decided to call it a day."
11535 PRINT
11540 PRINT "You completed "; DELTOT; " of 15 errands."
11545 PRINT
11550 INPUT "Press ENTER to end"; ANY$
11555 END
