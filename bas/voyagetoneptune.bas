10 REM
20 REM  VOYAGE TO NEPTUNE, 2100 -- A SEVEN-LEG INTERPLANETARY CROSSING
30 REM  Adapted for basic.mod from the (c) 1986 David H. Ahl original
40 REM
50 DIM PLAND$(7)
60 DIM DIS(6)
70 PLAND$(1)="Earth" : PLAND$(2)="Callisto" : PLAND$(3)="Titan"
80 PLAND$(4)="Alpha 1" : PLAND$(5)="Ariel" : PLAND$(6)="Theta 2"
90 PLAND$(7)="Neptune"
100 DIS(1)=391 : DIS(2)=403 : DIS(3)=446
110 DIS(4)=447 : DIS(5)=507 : DIS(6)=507

195 REM ============================ opening scenario =============================
200 CLS
205 PRINT "                    VOYAGE TO NEPTUNE, 2100"
210 PRINT "                 (c) by David H. Ahl, 1986"
215 PRINT
220 PRINT " It is the Year 2100 and you are in command of the first manned"
225 PRINT "spaceship to Neptune. Manned space stations have been established"
230 PRINT "which orbit Callisto, Titan, and Ariel, as well as at two inter-"
235 PRINT "mediate points between Saturn and Uranus, and Uranus and Neptune."
240 PRINT "You must travel about 2700 million miles. At an average speed of"
245 PRINT "over 50,000 miles per hour, the entire trip should take about"
250 PRINT "six years."
255 PRINT " Your spaceship is a marvel of 21st century engineering. Since"
260 PRINT "you may have to stop at space stations along the way, you will not"
265 PRINT "be able to use the gravitational 'slingshot' effect of the planets."
270 PRINT "However, your engines are highly efficient using both energy from"
275 PRINT "the sun captured by giant parabolic arrays and nuclear fuel carried"
280 PRINT "on board. You will not be able to carry enough fuel for the whole"
285 PRINT "trip, so you also have a multi-celled nuclear breeder reactor"
290 PRINT "(which takes spent fuel from your engines along with a small amount"
295 PRINT "of primary fuel and turns it into a much greater amount of primary"
300 PRINT "fuel)."
305 PRINT " The space stations along the way usually have a small stock of"
310 PRINT "engine repair parts, breeder-reactor cells, and nuclear fuel which"
315 PRINT "are available to you on a barter basis."
320 PRINT
325 INPUT "Press ENTER to begin your voyage!"; ANY$
330 CLS

395 REM ============================ initial values ================================
400 CELLS=120 : FUEL=3000 : SEG=0 : DIST=0 : TOTDAYS=0

495 REM ============================ main loop =====================================
500 SEG=SEG+1
505 IF SEG=7 THEN GOTO 9000

510 PRINT
515 PRINT "Current conditions are as follows:"
520 PRINT "  Location: "; PLAND$(SEG)
525 PRINT "  Distance to Neptune: "; 2701-DIST; " million miles."
530 IF SEG=1 THEN GOTO 700

535 PRINT "  Distance from Earth: "; DIST; " million miles."
540 PRINT "Over the last leg, your average speed was "; INT(RATE); " mph,"
545 PRINT "  and you covered "; DIS(SEG-1); " million miles in "; LEGTIME; " days."
550 TM=.81*DIST
555 PRINT "Time estimate for this total distance";
560 GOSUB 8000
565 TM=TOTDAYS
570 PRINT "Your actual cumulative time was ";
575 GOSUB 8000
580 PRINT "You used "; UBREED; " cells which produced "; FUBR; " lbs of fuel each."
585 IF DECAY>0 THEN PRINT DECAY; " lbs of fuel in storage decayed into an unusable state."

695 REM -------------------------- fuel and cell status -----------------------------
700 PRINT "  Pounds of nuclear fuel ready for use: "; FUEL
705 PRINT "  Operational breeder-reactor cells: "; CELLS
710 PRINT

795 REM -------------------------- trade fuel for cells ------------------------------
800 TRADE=INT(150+80*RND)
805 IF SEG>1 THEN GOTO 830
810 PRINT "Before leaving, you can trade fuel for breeder-reactor cells at"
815 GOTO 840
830 PRINT "Here at "; PLAND$(SEG); ", breeder cells and nuclear fuel trade at"
840 PRINT "the rate of "; TRADE; " pounds of fuel per cell."
845 PRINT
850 IF FUEL-TRADE<1501 THEN PRINT "You have too little fuel to trade." : GOTO 1000
855 INPUT "Would you like to procure more breeder cells (Y or N)? "; AD$
860 GOSUB 8500
865 IF YES=0 THEN GOTO 1000
870 INPUT "How many cells do you want? "; A
875 F=FUEL-A*TRADE
880 IF F>1500 THEN FUEL=F : CELLS=CELLS+A : GOTO 1100
885 PRINT "That doesn't leave enough fuel to run the engines."
890 GOTO 870

995 REM -------------------------- trade cells for fuel -------------------------------
1000 INPUT "Would you like to trade some breeder cells for fuel? "; AD$
1005 GOSUB 8500
1010 IF YES=0 THEN GOTO 1100
1015 INPUT "How many cells would you like to trade? "; A
1020 F=CELLS-A
1025 IF F>49 THEN CELLS=F : FUEL=FUEL+A*TRADE : GOTO 1100
1030 PRINT "That would leave only "; F; " cells. The reactor requires a minimum"
1035 PRINT "of 50 cells to remain operational."
1040 GOTO 1015

1095 REM ============================ engine fuel this leg =============================
1100 SOLARPCT=56-SEG*8
1105 PRINT "At this distance from the sun, your solar collectors can fulfill"
1110 PRINT SOLARPCT; "% of the fuel requirements of the engines. How many pounds"
1115 INPUT "of nuclear fuel do you want to use on this leg? "; FUSEG
1120 IF FUSEG<=FUEL THEN FUEL=FUEL-FUSEG : GOTO 1200
1125 PRINT "That's more fuel than you have. Now then, how many pounds"
1130 GOTO 1115

1195 REM ============================ breeder-reactor usage =============================
1200 INPUT "How many breeder-reactor cells do you want to operate? "; UBREED
1205 IF UBREED>CELLS THEN PRINT "You don't have that many cells." : GOTO 1200
1210 IF INT(FUSEG/20)>=UBREED THEN GOTO 1230
1215 PRINT "The spent fuel from your engines is only enough to operate "; INT(FUSEG/20)
1220 PRINT "  breeder-reactor cells. Again please..."
1225 GOTO 1200
1230 IF UBREED*5<=FUEL THEN GOTO 1250
1235 PRINT "You have only enough fuel to seed "; INT(FUEL/5); " breeder cells."
1240 PRINT "Please adjust your number accordingly."
1245 GOTO 1200
1250 FUEL=FUEL-5*UBREED

1295 REM ============================ resolve the leg =============================
1300 EFF=56-SEG*8+FUSEG/40
1305 IF EFF>104 THEN EFF=104
1310 EF=RND
1315 IF EF<.1 THEN GOSUB 2000
1320 RATE=EFF*513.89
1325 DIST=DIST+DIS(SEG)
1330 LEGTIME=INT(DIS(SEG)*41667/RATE)
1335 TOTDAYS=TOTDAYS+LEGTIME
1340 FUBR=INT(16+18*RND)
1345 FUEL=FUEL+FUBR*UBREED
1350 FD=RND
1355 IF FD<.2 THEN DECAY=INT(FD*FUEL) ELSE DECAY=0
1360 FUEL=FUEL-DECAY
1365 GOTO 500

1995 REM ============================ engine malfunction =============================
2000 CLS
2005 PRINT "*** ENGINE MALFUNCTION! ***"
2010 PRINT
2015 PRINT "You will have to operate your engines at a "; INT(300*EF); "% reduction"
2020 PRINT "in speed until you reach "; PLAND$(SEG+1); "."
2025 PRINT
2030 EFF=EFF*(1-3*EF)
2035 RETURN

7995 REM ============================ elapsed-time printer =============================
8000 YRS=INT(TM/365)
8005 IF YRS<1 THEN GOTO 8025
8010 IF YRS=1 THEN PRINT " 1 year";
8015 IF YRS<>1 THEN PRINT " "; YRS; " years";
8025 MOS=INT((TM/365-YRS)*12)
8030 IF MOS<1 THEN GOTO 8050
8035 IF MOS=1 THEN PRINT ", 1 month";
8040 IF MOS<>1 THEN PRINT ", "; MOS; " months";
8050 DYS=INT(TM-YRS*365-MOS*30.5)
8055 IF DYS<1 THEN PRINT "." : RETURN
8060 IF DYS=1 THEN PRINT ", 1 day." ELSE PRINT ", "; DYS; " days."
8065 RETURN

8495 REM ============================ yes/no helper =====================================
8500 IF (LEFT$(AD$,1)="Y") OR (LEFT$(AD$,1)="y") THEN YES=1 : RETURN
8505 IF (LEFT$(AD$,1)="N") OR (LEFT$(AD$,1)="n") THEN YES=0 : RETURN
8510 PRINT "Don't understand your answer. Enter 'Y' or 'N' please."
8515 INPUT AD$
8520 GOTO 8500

8995 REM ============================ arrival at Neptune! ===============================
9000 CLS
9005 PRINT "You finally reached Neptune in ";
9010 TM=TOTDAYS
9015 GOSUB 8000
9020 PRINT "Had your engines run at 100% efficiency the entire way, you would"
9025 PRINT "have averaged 51,389 mph and completed the trip in exactly 6 years."
9030 IF TOTDAYS>2220 THEN GOTO 9100

9035 PRINT
9040 PRINT "                 Congratulations! Outstanding job!"
9045 PRINT
9050 GOTO 9200

9095 REM -------------------------- ran long: rate the performance --------------------
9100 TM=TOTDAYS-2190
9105 PRINT
9110 PRINT "Your trip took longer than this by";
9115 GOSUB 8000
9120 PRINT "Your performance was ";
9125 GRADE=YRS+1
9130 IF GRADE>4 THEN GRADE=4
9135 IF GRADE=1 THEN PRINT "excellent (room for slight improvement)."
9140 IF GRADE=2 THEN PRINT "quite good (but could be better)."
9145 IF GRADE=3 THEN PRINT "marginal (could do much better)."
9150 IF GRADE=4 THEN PRINT "abysmal (need lots more practice)."

9195 REM -------------------------- return-trip readiness --------------------------
9200 PRINT
9205 IF CELLS<105 THEN GOTO 9230
9210 PRINT "Fortunately you have "; CELLS; " operational breeder-reactor cells"
9215 PRINT "for your return trip. Very good."
9220 GOTO 9250
9230 PRINT "I guess you realize that the return trip will be extremely"
9235 PRINT "chancy with only "; CELLS; " breeder-reactor cells operational."

9245 REM -------------------------- return-trip time estimate --------------------------
9250 PRINT "With your remaining "; FUEL; " pounds of fuel and "; CELLS; " breeder"
9255 TM=42250/(8+FUEL/40)
9260 IF TM<405 THEN TM=405
9265 PRINT "cells, to get back to Theta 2 will take";
9270 GOSUB 8000
9275 PRINT
9280 INPUT "Press ENTER to end"; ANY$
9285 END
