10 REM
20 REM  THE LONGEST AUTOMOBILE RACE -- NEW YORK TO PARIS, 1908
30 REM  Adapted for basic.mod from David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM
60 DIM BD$(7)
70 BD$(1)="a blown tire" : BD$(2)="a cracked axle" : BD$(3)="a radiator leak"
80 BD$(4)="transmission trouble" : BD$(5)="a broken spring"
90 BD$(6)="a fouled fuel line" : BD$(7)="an electrical short"
100 DIM SEG$(9)
110 DIM SEGDIST(9)
120 DIM SEGOCEAN(9)
130 SEG$(1)="New York to Chicago" : SEGDIST(1)=800 : SEGOCEAN(1)=0
140 SEG$(2)="Chicago to Cheyenne" : SEGDIST(2)=1000 : SEGOCEAN(2)=0
150 SEG$(3)="Cheyenne to San Francisco" : SEGDIST(3)=900 : SEGOCEAN(3)=0
160 SEG$(4)="San Francisco to Vladivostok, by steamer" : SEGDIST(4)=0 : SEGOCEAN(4)=1
170 SEG$(5)="Vladivostok to Chita, across Siberia" : SEGDIST(5)=1200 : SEGOCEAN(5)=0
180 SEG$(6)="Chita to Omsk" : SEGDIST(6)=1400 : SEGOCEAN(6)=0
190 SEG$(7)="Omsk to Moscow" : SEGDIST(7)=1500 : SEGOCEAN(7)=0
200 SEG$(8)="Moscow to Berlin" : SEGDIST(8)=1000 : SEGOCEAN(8)=0
210 SEG$(9)="Berlin to Paris" : SEGDIST(9)=600 : SEGOCEAN(9)=0

220 CASH=3000 : FUEL=0 : DAY=0 : SEGMENT=0
230 BREAKDOWNS=0 : WIRECOUNT=0 : EXTRADAYS=0

300 CLS
310 PRINT "     THE LONGEST AUTOMOBILE RACE -- NEW YORK TO PARIS, 1908"
320 PRINT "             adapted from David H. Ahl"
330 PRINT
340 INPUT "Press ENTER to start your engine!"; ANY$
350 CLS
360 PRINT "In February 1908, teams from several nations set out on one of"
370 PRINT "the most grueling automobile races ever attempted: overland"
380 PRINT "from New York to San Francisco, by steamer to Siberia, and"
390 PRINT "overland again across Russia and Europe to Paris."
400 PRINT
410 PRINT "You have "; CASH; " dollars to see you and your car through."
420 PRINT
430 INPUT "Press ENTER to continue"; ANY$
440 CLS

500 PRINT "Rank your skill as a driver and mechanic:"
510 PRINT "  (1) A born wrench-turner who can fix anything"
520 PRINT "  (2) Handy enough in a pinch"
530 PRINT "  (3) Know which end of a wrench to hold"
540 PRINT "  (4) Better with a map than a monkey wrench"
550 INPUT "How do you rank yourself (1-4)? "; SKILL
560 IF (SKILL>=1) AND (SKILL<=4) THEN GOTO 590
570 PRINT "Please enter 1, 2, 3, or 4."
580 GOTO 550
590 PRINT
600 INPUT "Press ENTER to begin the race!"; ANY$
610 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 GOSUB 9000
1020 PRINT
1030 PRINT "Leg "; SEGMENT; ": "; SEG$(SEGMENT)
1035 EXTRADAYS=0
1040 IF SEGOCEAN(SEGMENT)=1 THEN GOSUB 5000: GOTO 1200
1041 WEATHER=INT(1+RND*4)
1042 IF WEATHER=1 THEN PRINT "The forecast calls for clear roads.": WFACTOR=0.9: MAXSPEED=54
1043 IF WEATHER=2 THEN PRINT "Rain is expected -- the roads may turn to soup.": WFACTOR=0.6: MAXSPEED=45
1044 IF WEATHER=3 THEN PRINT "Snow is expected in the passes ahead.": WFACTOR=0.4: MAXSPEED=30
1045 IF WEATHER=4 THEN PRINT "The roads ahead are thick with mud.": WFACTOR=0.5: MAXSPEED=40
1050 GOSUB 2000
1060 GOSUB 2500
1070 GOSUB 3000
1080 GOSUB 3500
1090 GOSUB 4000
1100 GOSUB 4500
1110 GOSUB 6000
1200 GOSUB 8500
1210 IF DAY>150 THEN DEATH$="Too much time has passed; your entry is withdrawn from the race.": GOTO 12000
1220 IF SEGMENT>=9 THEN GOTO 11000
1230 GOTO 1000

1995 REM ============================ buy gasoline ==============================
2000 RN=INT(15+RND*25)
2005 PRINT
2010 PRINT "Gasoline costs "; RN; " cents a gallon here."
2015 A1=0 : A2=INT(CASH*100/RN)
2020 IF A2>40 THEN A2=40
2025 INPUT "How many gallons do you want? "; A
2030 GOSUB 10000
2035 FUEL=A
2040 CASH=CASH-INT(A*RN/100)
2045 RETURN

2495 REM =============================== choose speed ============================
2500 PRINT
2505 PRINT "How fast do you want to drive (8 to "; MAXSPEED; " mph)?"
2510 A1=8 : A2=MAXSPEED
2515 INPUT "Your speed? "; A
2520 GOSUB 10000
2525 SPEED=A
2530 RETURN

2995 REM =========================== choose driving hours =========================
3000 PRINT
3005 PRINT "How many hours a day do you want to drive (2 to 8)?"
3010 A1=2 : A2=8
3015 INPUT "Hours per day? "; A
3020 GOSUB 10000
3025 HOURS=A
3030 IF HOURS>=7 THEN PRINT "Driving that long each day will wear out you and the crew."
3035 RETURN

3495 REM ===================== drive the leg / fuel consumption ===================
3500 EFFSPEED=INT(SPEED*WFACTOR)
3505 IF EFFSPEED<1 THEN EFFSPEED=1
3510 MPD=EFFSPEED*HOURS
3515 SEGDAYS=INT(SEGDIST(SEGMENT)/MPD)
3520 IF SEGDAYS*MPD<SEGDIST(SEGMENT) THEN SEGDAYS=SEGDAYS+1
3525 NEEDFUEL=INT(SEGDIST(SEGMENT)/14)
3530 IF NEEDFUEL>FUEL THEN GOTO 3560
3535 FUEL=FUEL-NEEDFUEL
3540 PRINT "You cover the "; SEGDIST(SEGMENT); " miles in "; SEGDAYS; " days."
3545 RETURN
3560 PRINT "You run out of gasoline on the road and must buy more at a"
3565 PRINT "steep roadside price."
3570 RN=INT(30+RND*25)
3575 NEED2=NEEDFUEL-FUEL
3580 IF CASH<INT(NEED2*RN/100) THEN GOSUB 5500
3585 CASH=CASH-INT(NEED2*RN/100)
3590 FUEL=0
3595 GOTO 3540

3995 REM ============================ breakdown check ============================
4000 CHANCE=10+INT(SPEED/2)
4005 IF INT(RND*100)+1>CHANCE THEN RETURN
4010 PRINT
4015 K=INT(1+RND*7)
4020 PRINT "Trouble! You've got "; BD$(K); "."
4025 RN1=INT(20+RND*60)
4030 RT1=INT(1+RND*2)
4035 RN2=INT(5+RND*15)
4040 RT2=INT(2+RND*4)
4045 PRINT "(1) Pay "; RN1; " dollars for a "; RT1; "-day repair with proper parts"
4050 PRINT "(2) Try a "; RT2; "-day homebrew fix for "; RN2; " dollars"
4055 PRINT "(3) Nurse it along at half speed and hope"
4060 INPUT "What do you want to do? "; A
4065 IF (A<1) OR (A>3) THEN PRINT "Please choose 1, 2, or 3.": GOTO 4060
4070 IF A=1 THEN GOTO 4110
4075 IF A=2 THEN GOTO 4120
4080 RN=90-(SKILL-1)*15
4085 IF INT(RND*100)+1<=RN THEN PRINT "You nurse the car through -- it holds together.": RETURN
4090 BREAKDOWNS=BREAKDOWNS+1
4095 PRINT "The problem gets worse. You limp in at half speed, still broken."
4100 IF BREAKDOWNS>=2 THEN DEATH$="A second unrepaired breakdown finally strands you for good.": GOTO 12000
4105 RETURN
4110 IF CASH<RN1 THEN GOSUB 5500
4112 CASH=CASH-RN1 : EXTRADAYS=EXTRADAYS+RT1
4114 PRINT "The car is running well again."
4116 RETURN
4120 IF CASH<RN2 THEN GOSUB 5500
4122 CASH=CASH-RN2 : EXTRADAYS=EXTRADAYS+RT2
4124 PRINT "It's not pretty, but it holds."
4126 RETURN

4495 REM ============================= accident check =============================
4500 CHANCE=5+HOURS
4505 IF INT(RND*100)+1>CHANCE THEN RETURN
4510 PRINT
4515 PRINT "Someone dozes at the wheel and you run off the road!"
4520 PRINT "(1) Fix it yourselves on the spot (costs time)"
4525 PRINT "(2) Pay for a tow to the next town (costs money)"
4530 INPUT "What do you want to do? "; A
4535 IF (A<1) OR (A>2) THEN PRINT "Please choose 1 or 2.": GOTO 4530
4540 IF A=1 THEN EXTRADAYS=EXTRADAYS+INT(1+RND*2): PRINT "You get the car moving again, a little worse for wear.": RETURN
4545 RN=INT(10+RND*30)
4550 IF CASH<RN THEN GOSUB 5500
4552 CASH=CASH-RN
4555 PRINT "The tow costs "; RN; " dollars, but saves you time."
4560 RETURN

4995 REM ============================= ocean voyage ================================
5000 PRINT
5005 PRINT "You load the car onto a steamer for the long ocean crossing."
5010 WAITDAYS=INT(1+RND*4)
5015 VOYAGEDAYS=20+INT(RND*8)
5020 RN=INT(200+RND*200)
5025 PRINT "Passage costs "; RN; " dollars, plus "; WAITDAYS; " days waiting in port."
5030 IF CASH<RN THEN GOSUB 5500
5035 CASH=CASH-RN
5040 DAY=DAY+WAITDAYS+VOYAGEDAYS
5045 PRINT "After "; VOYAGEDAYS; " days at sea, you make landfall."
5050 RETURN

5495 REM ======================= wire the factory for funds =======================
5500 PRINT
5505 PRINT "You don't have enough money."
5510 IF WIRECOUNT>=3 THEN DEATH$="With no funds and no more credit from the factory, your race ends here.": GOTO 12000
5515 WIRECOUNT=WIRECOUNT+1
5520 PRINT "Do you want to wire the factory back home for emergency funds?"
5525 GOSUB 9500
5530 IF YES=0 THEN DEATH$="Unable to pay your bills, you are forced to withdraw from the race.": GOTO 12000
5535 GRANT=1000-WIRECOUNT*250
5540 IF RND<0.15+WIRECOUNT*0.1 THEN PRINT "The factory is losing patience; they wire only half what you asked.": GRANT=INT(GRANT/2)
5545 CASH=CASH+GRANT
5550 PRINT "The factory wires "; GRANT; " dollars to keep you in the race."
5555 RETURN

5995 REM ==================== living costs / finish the leg =======================
6000 LIVING=INT(10*(SEGDAYS+EXTRADAYS))
6005 IF CASH<LIVING THEN GOSUB 5500
6010 CASH=CASH-LIVING
6015 DAY=DAY+SEGDAYS+EXTRADAYS
6020 EXTRADAYS=0
6025 RETURN

7995 REM ========================= clamp quantities to >=0 =====================
8000 IF CASH<0 THEN CASH=0
8005 IF FUEL<0 THEN FUEL=0
8010 RETURN

8495 REM ============================ print status ===============================
8500 PRINT "Cash: $"; CASH; "   Fuel: "; FUEL; " gal"
8505 PRINT
8510 GOSUB 8000
8515 RETURN

8995 REM =============================== print day ================================
9000 PRINT
9005 PRINT "== Day "; DAY; " of the race =="
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
10005 IF A<A1 THEN PRINT "That's too few. Try again." ELSE PRINT "That's too many. Try again."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================== you arrive! ===============================
11000 CLS
11005 PRINT "PARIS AT LAST!"
11010 PRINT
11015 PRINT "You cross the finish line after "; DAY; " days on the road."
11020 IF DAY<=100 THEN PRINT "A blistering pace -- among the fastest of any team!"
11025 IF (DAY>100) AND (DAY<=169) THEN PRINT "A strong finish, as fast as the historic winning car in 1908."
11030 IF DAY>169 THEN PRINT "A long, hard road, but you made it to Paris at last."
11035 PRINT
11040 PRINT "Cash remaining: $"; CASH
11045 PRINT
11050 INPUT "Press ENTER to end"; ANY$
11055 END

11995 REM ================================ you retire ===============================
12000 CLS
12005 PRINT "Your race ends before reaching Paris."
12010 PRINT
12015 PRINT DEATH$
12020 PRINT
12025 PRINT "You made it "; DAY; " days into the race with "; CASH; " dollars left."
12030 PRINT
12035 INPUT "Press ENTER to end"; ANY$
12040 END
