10 REM
20 REM  TOUR DE FRANCE -- A TEN-STAGE CYCLING RACE
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM
60 DIM STAGE$(10)
70 DIM DIST(10)
80 DIM TERRAIN(10)
90 STAGE$(1)="Paris to Rouen" : DIST(1)=135 : TERRAIN(1)=1
100 STAGE$(2)="Rouen to Rennes" : DIST(2)=200 : TERRAIN(2)=1
110 STAGE$(3)="Rennes to Bordeaux" : DIST(3)=350 : TERRAIN(3)=1
120 STAGE$(4)="Bordeaux to Pau" : DIST(4)=200 : TERRAIN(4)=2
130 STAGE$(5)="Pau to Luchon, through the Pyrenees" : DIST(5)=150 : TERRAIN(5)=3
140 STAGE$(6)="Luchon to Toulouse" : DIST(6)=120 : TERRAIN(6)=2
150 STAGE$(7)="Toulouse to Grenoble" : DIST(7)=300 : TERRAIN(7)=2
160 STAGE$(8)="Grenoble to Alpe d'Huez" : DIST(8)=100 : TERRAIN(8)=3
170 STAGE$(9)="The Alps to Dijon" : DIST(9)=250 : TERRAIN(9)=2
180 STAGE$(10)="Dijon to Paris, finishing on the Champs-Elysees" : DIST(10)=300 : TERRAIN(10)=1
190 DIM RIVALTOTAL(5)
200 DIM R$(5)
210 R$(1)="Laurent Blanchard" : R$(2)="Marco Rossi" : R$(3)="Jan Dekker"
220 R$(4)="Miguel Ortiz" : R$(5)="Klaus Weber"

300 SEGMENT=0 : TOTALTIME=0

400 CLS
410 PRINT "         TOUR DE FRANCE -- A TEN-STAGE CYCLING RACE"
420 PRINT "                adapted from David H. Ahl"
430 PRINT
440 INPUT "Press ENTER to roll to the start line!"; ANY$
450 CLS
460 PRINT "Ten stages, over 2,000 kilometers, from Paris through the"
470 PRINT "Pyrenees and the Alps and back to Paris. Each day you'll pick"
480 PRINT "a gear range suited to the terrain, decide when to launch your"
490 PRINT "finishing sprint, and hope your legs and your luck hold."
500 PRINT
510 INPUT "Press ENTER to continue"; ANY$
520 CLS

600 PRINT "Rank your fitness heading into the race:"
610 PRINT "  (1) Peak physical condition"
620 PRINT "  (2) In solid racing shape"
630 PRINT "  (3) A bit undertrained"
640 PRINT "  (4) You signed up on a dare"
650 INPUT "How do you rank yourself (1-4)? "; FITNESS
660 IF (FITNESS>=1) AND (FITNESS<=4) THEN GOTO 690
670 PRINT "Please enter 1, 2, 3, or 4."
680 GOTO 650
690 PRINT
700 A1=0 : A2=20
710 INPUT "How many hours a week have you been training (0-20)? "; A
720 GOSUB 10000
730 PRACTICE=A
740 BASESPEED=30-(FITNESS-1)*2+INT(PRACTICE/5)
750 PRINT
760 INPUT "Press ENTER for the start of Stage 1!"; ANY$
770 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 PRINT
1015 PRINT "Stage "; SEGMENT; ": "; STAGE$(SEGMENT); " ("; DIST(SEGMENT); " km)"
1020 GOSUB 2000
1030 GOSUB 2500
1040 GOSUB 3000
1050 GOSUB 3500
1060 GOSUB 8500
1070 IF SEGMENT>=10 THEN GOTO 11000
1080 GOTO 1000

1995 REM =============================== gear choice =============================
2000 PRINT
2005 IF TERRAIN(SEGMENT)=1 THEN PRINT "Today's stage is flat and fast."
2010 IF TERRAIN(SEGMENT)=2 THEN PRINT "Today's stage is hilly, rolling terrain."
2015 IF TERRAIN(SEGMENT)=3 THEN PRINT "Today's stage climbs into the mountains."
2020 PRINT "  (1) Low gear range -- best for climbing"
2025 PRINT "  (2) Medium gear range -- balanced"
2030 PRINT "  (3) High gear range -- best for flat, fast riding"
2035 A1=1 : A2=3
2040 INPUT "Which gear range do you want? "; A
2045 GOSUB 10000
2050 GEAR=A
2055 RETURN

2495 REM ================================ sprint choice ===========================
2500 PRINT
2505 PRINT "How far from the finish do you want to launch your sprint (1-10 km)?"
2510 A1=1 : A2=10
2515 INPUT "Your answer? "; A
2520 GOSUB 10000
2525 SPRINTKM=A
2530 RETURN

2995 REM ============================= ride the stage =============================
3000 MISMATCH=ABS(GEAR-TERRAIN(SEGMENT))
3005 EFFSPEED=BASESPEED
3010 IF MISMATCH=1 THEN EFFSPEED=INT(BASESPEED*9/10)
3015 IF MISMATCH=2 THEN EFFSPEED=INT(BASESPEED*3/4)
3020 EFFSPEED=EFFSPEED+INT(SPRINTKM/2)
3025 IF EFFSPEED<5 THEN EFFSPEED=5
3030 STIME=INT(DIST(SEGMENT)*60/EFFSPEED)
3035 COLLAPSERISK=10
3040 IF (MISMATCH=2) AND (TERRAIN(SEGMENT)=3) THEN COLLAPSERISK=COLLAPSERISK+10
3045 IF SPRINTKM>=8 THEN COLLAPSERISK=COLLAPSERISK+5
3050 PRINT
3055 GOSUB 4000
3060 STIME=STIME+EVENTDELAY
3065 TOTALTIME=TOTALTIME+STIME
3070 HRS=INT(STIME/60) : MIN=STIME MOD 60
3075 PRINT "You finish the stage in "; HRS; "h "; MIN; "m."
3080 RETURN

3495 REM ============================ road/bike/body event ========================
4000 EVENTDELAY=0
4005 RN=INT(RND*100)+1
4010 IF RN<=10 THEN PRINT "You hit a pothole and have to slow to avoid a spill.": EVENTDELAY=INT(6+RND*10): GOTO 4200
4015 IF RN<=18 THEN PRINT "A rider ahead crashes, and you narrowly avoid going down too.": EVENTDELAY=INT(10+RND*15): GOTO 4200
4020 IF RN<=26 THEN PRINT "Your chain slips and you lose time getting it sorted.": EVENTDELAY=INT(4+RND*8): GOTO 4200
4025 IF RN<=34 THEN PRINT "A brake starts rubbing and needs a quick roadside fix.": EVENTDELAY=INT(6+RND*10): GOTO 4200
4030 IF RN<=42 THEN PRINT "You get a flat tire and lose time with a wheel change.": EVENTDELAY=INT(10+RND*15): GOTO 4200
4035 IF RN<=50 THEN PRINT "A cramp seizes your leg for a painful stretch of road.": EVENTDELAY=INT(8+RND*12): GOTO 4200
4040 IF RN<=58 THEN PRINT "Fatigue catches up with you on a long, exposed stretch.": EVENTDELAY=INT(10+RND*15): GOTO 4200
4045 IF RN<=72 THEN PRINT "It's a beautiful day riding through the French countryside.": GOTO 4200
4050 IF RN<=86 THEN PRINT "Your bike is running like a charm today.": GOTO 4200
4055 PRINT "You're feeling fit as a fiddle."
4060 GOTO 4200

4200 IF INT(RND*100)+1<=COLLAPSERISK THEN GOTO 4300
4205 RETURN
4300 PRINT "The effort catches up with you -- you have to stop and recover."
4305 EVENTDELAY=EVENTDELAY+INT(40+RND*20)
4310 RETURN

3995 REM =========================== the other riders =============================
3500 FOR K=1 TO 5
3505   RIVALSPEED=31
3510   IF TERRAIN(SEGMENT)=2 THEN RIVALSPEED=28
3515   IF TERRAIN(SEGMENT)=3 THEN RIVALSPEED=22
3520   RTIME=INT(DIST(SEGMENT)*60/RIVALSPEED)+INT(RND*20)
3525   RIVALTOTAL(K)=RIVALTOTAL(K)+RTIME
3530 NEXT K
3535 PLACE=1
3540 FOR K=1 TO 5
3545   IF RIVALTOTAL(K)<TOTALTIME THEN PLACE=PLACE+1
3550 NEXT K
3555 PRINT "Overall standing: "; PLACE; " of 6."
3560 RETURN

8495 REM ============================ print status ================================
8500 HRS=INT(TOTALTIME/60) : MIN=TOTALTIME MOD 60
8505 PRINT "Cumulative time: "; HRS; "h "; MIN; "m"
8510 PRINT
8515 RETURN

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 IF A<A1 THEN PRINT "That's too few. Try again." ELSE PRINT "That's too many. Try again."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================== the finish line ============================
11000 CLS
11005 PRINT "THE FINAL STAGE ENDS ON THE CHAMPS-ELYSEES!"
11010 PRINT
11015 PLACE=1
11020 FOR K=1 TO 5
11025   IF RIVALTOTAL(K)<TOTALTIME THEN PLACE=PLACE+1
11030 NEXT K
11035 HRS=INT(TOTALTIME/60) : MIN=TOTALTIME MOD 60
11040 PRINT "Your total time: "; HRS; "h "; MIN; "m"
11045 PRINT "Final standing: "; PLACE; " of 6."
11050 IF PLACE=1 THEN PRINT "You win the Tour de France! The yellow jersey is yours."
11055 IF (PLACE>1) AND (PLACE<=3) THEN PRINT "A podium finish -- a truly excellent Tour."
11060 IF PLACE>3 THEN PRINT "You finish the Tour, tired but proud -- not every rider does."
11065 PRINT
11070 INPUT "Press ENTER to end"; ANY$
11075 END
