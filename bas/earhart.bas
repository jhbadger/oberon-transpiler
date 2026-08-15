10 REM
20 REM  AMELIA EARHART -- AROUND THE WORLD FLIGHT, 1937
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition).
50 REM  Route and aircraft facts are historical; the flight outcomes
60 REM  here -- including the successful ones -- are simulation, not history.
70 DIM LEG$(10)
80 DIM SEGDIST(10)
90 DIM OVERWATER(10)
100 DIM ROUGH(10)
110 DIM OHOK(10)
120 LEG$(1)="Miami, Florida to San Juan, Puerto Rico"
130 SEGDIST(1)=1000 : OVERWATER(1)=1 : ROUGH(1)=0 : OHOK(1)=0
140 LEG$(2)="San Juan to Fortaleza, Brazil"
150 SEGDIST(2)=2000 : OVERWATER(2)=1 : ROUGH(2)=0 : OHOK(2)=1
160 LEG$(3)="Fortaleza to Dakar, Senegal (Atlantic crossing)"
170 SEGDIST(3)=1900 : OVERWATER(3)=1 : ROUGH(3)=0 : OHOK(3)=0
180 LEG$(4)="Dakar to Khartoum, Sudan"
190 SEGDIST(4)=2200 : OVERWATER(4)=0 : ROUGH(4)=1 : OHOK(4)=0
200 LEG$(5)="Khartoum to Karachi, India"
210 SEGDIST(5)=2500 : OVERWATER(5)=0 : ROUGH(5)=0 : OHOK(5)=1
220 LEG$(6)="Karachi to Calcutta"
230 SEGDIST(6)=1300 : OVERWATER(6)=0 : ROUGH(6)=0 : OHOK(6)=0
240 LEG$(7)="Calcutta to Bandoeng, Java"
250 SEGDIST(7)=2700 : OVERWATER(7)=1 : ROUGH(7)=1 : OHOK(7)=1
260 LEG$(8)="Bandoeng to Darwin, Australia"
270 SEGDIST(8)=1700 : OVERWATER(8)=1 : ROUGH(8)=0 : OHOK(8)=0
280 LEG$(9)="Darwin to Lae, New Guinea"
290 SEGDIST(9)=1200 : OVERWATER(9)=1 : ROUGH(9)=1 : OHOK(9)=0
300 LEG$(10)="Lae, New Guinea to Howland Island"
310 SEGDIST(10)=2600 : OVERWATER(10)=1 : ROUGH(10)=0 : OHOK(10)=0

320 DAY=0 : SEGMENT=0 : PC=0 : MALFUNCTION=0 : STRIPPED=0

400 CLS
410 PRINT "     AMELIA EARHART -- AROUND THE WORLD FLIGHT, 1937"
420 PRINT "             adapted from David H. Ahl"
430 PRINT
440 INPUT "Press ENTER to start the engines!"; ANY$
450 CLS
460 PRINT "On May 20, 1937, you depart Miami in a twin-engine Lockheed"
470 PRINT "Electra, attempting to fly around the world at the equator --"
480 PRINT "the longest such flight ever attempted."
490 PRINT
500 PRINT "You'll cross the Atlantic, Africa, the Middle East, and the"
510 PRINT "vast Pacific, watching your fuel, your engines, and the weather"
520 PRINT "every mile of the way."
530 PRINT
540 INPUT "Press ENTER to begin!"; ANY$
550 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 GOSUB 9000
1020 PRINT
1030 PRINT "Leg "; SEGMENT; ": "; LEG$(SEGMENT)
1040 IF MALFUNCTION=1 THEN GOSUB 2000
1050 GOSUB 2500
1060 IF SEGMENT=10 THEN GOTO 7000
1070 GOSUB 3500
1080 GOSUB 4000
1090 GOSUB 8500
1100 GOTO 1000

1995 REM ============================= repair offer ==============================
2000 PRINT
2005 PRINT "A minor malfunction from the last leg still needs attention."
2010 PRINT "Do you want to make repairs before departing?"
2015 GOSUB 9500
2020 IF YES=0 THEN PRINT "You decide to press on and hope it holds.": RETURN
2025 RN=INT(3+RND*6)
2030 PRINT "The repair takes "; RN; " hours."
2035 IF RN>=5 THEN DAY=DAY+1
2040 MALFUNCTION=0
2045 RETURN

2495 REM ============================ overhaul offer =============================
2500 IF OHOK(SEGMENT)=0 THEN RETURN
2505 IF PC<50 THEN RETURN
2510 PRINT
2515 PRINT "This airport has full facilities for a major overhaul."
2520 IF PC>100 THEN PRINT "Given the wear on the engines, it's strongly recommended."
2525 PRINT "Do you want a major overhaul before departing? (takes 2 days)"
2530 GOSUB 9500
2535 IF YES=0 THEN RETURN
2540 PC=0 : MALFUNCTION=0 : DAY=DAY+2
2545 PRINT "The engines are stripped down and rebuilt. Good as new."
2550 RETURN

2995 REM ============================ strip weight ================================
3000 PRINT
3005 PRINT "Howland Island is tiny, and this will be your longest, hardest leg."
3010 PRINT "Do you want to strip out nonessential equipment to save weight"
3015 PRINT "and stretch your range?"
3020 GOSUB 9500
3025 STRIPPED=YES
3030 IF STRIPPED=1 THEN PRINT "You leave excess gear behind at the airstrip."
3035 RETURN

3495 REM =============================== choose speed ============================
3500 PRINT
3505 PRINT "What cruising speed do you want (120 to 170 mph)?"
3510 A1=120 : A2=170
3515 INPUT "Your speed? "; A
3520 GOSUB 10000
3525 SPEED=A
3530 RETURN

3995 REM =============================== fly the leg ==============================
4000 WEATHER=INT(1+RND*4)
4005 IF WEATHER=1 THEN PRINT "Clear skies for this leg.": WPEN=0
4010 IF WEATHER=2 THEN PRINT "Headwinds will slow you down and burn extra fuel.": WPEN=15
4015 IF WEATHER=3 THEN PRINT "A tropical storm is brewing along the route.": WPEN=30
4020 IF WEATHER=4 THEN PRINT "Mixed clouds and rain are expected.": WPEN=10
4025 IF (ROUGH(SEGMENT)=1) AND (WEATHER>=3) AND (RND<0.25) THEN GOTO 4200
4030 DIST2=SEGDIST(SEGMENT)+WPEN*10
4045 WEARADD=INT(DIST2*SPEED/30000)
4050 PC=PC+WEARADD
4055 IF PC>60 THEN FAILCHANCE=INT((PC-60)*1.2) ELSE FAILCHANCE=0
4060 IF FAILCHANCE>95 THEN FAILCHANCE=95
4065 IF INT(RND*100)+1>FAILCHANCE THEN GOTO 4300
4070 GOSUB 4500
4075 RETURN
4200 PRINT "The runway is a soaked strip of grass, and the wheels bog down."
4205 PRINT "It takes an extra day to get the plane free and dry."
4210 DAY=DAY+1
4215 GOTO 4030
4300 DAYADD=INT(DIST2/(SPEED*10))+1
4305 DAY=DAY+DAYADD
4310 PRINT "You land safely, the leg behind you."
4315 RETURN

4495 REM =========================== mechanical failure ===========================
4500 PRINT
4505 PRINT "One of the engines begins running rough -- trouble in the air!"
4510 RN=INT(1+RND*3)
4515 IF RN=1 THEN GOTO 4600
4520 IF RN=2 THEN GOTO 4650
4525 GOTO 4700

4600 PRINT "You nurse the plane along on reduced power and make it down safely,"
4605 PRINT "though the airframe has taken a beating."
4610 PC=PC+20
4615 MALFUNCTION=1
4620 DAY=DAY+1
4625 RETURN

4650 PRINT "You can't risk it -- you turn back to the airport you just left."
4655 DAY=DAY+1
4660 SEGMENT=SEGMENT-1
4665 RETURN

4700 PRINT "The engine trouble is too severe -- you have to put down now."
4705 IF OVERWATER(SEGMENT)=1 THEN GOTO 4800
4710 IF RND<0.8 THEN GOTO 4750
4715 DEATH$="The forced landing goes badly, and the flight ends here."
4720 GOTO 12000
4750 PRINT "You put the plane down hard in a field. Everyone walks away, but"
4755 PRINT "the Electra will never fly again."
4760 DEATH$="A rough but survivable forced landing puts an early end to the flight."
4765 GOTO 12000
4800 DEATH$="Over open ocean, a forced landing gives you no chance at all."
4805 GOTO 12000

6995 REM ======================= the final leg: Howland Island ====================
7000 CLS
7005 PRINT "== The final leg: Lae, New Guinea to Howland Island =="
7010 PRINT
7015 PRINT "Howland Island is a speck two miles long in an empty ocean, more"
7020 PRINT "than 2,500 miles from Lae. Your only real guidance is dead"
7025 PRINT "reckoning, celestial navigation, and radio bearings."
7030 PRINT
7032 GOSUB 3000
7035 GOSUB 3500
7040 CHANCE=30
7045 IF STRIPPED=1 THEN CHANCE=CHANCE+10
7050 IF PC>100 THEN CHANCE=CHANCE-15
7055 IF PC>150 THEN CHANCE=CHANCE-15
7060 IF CHANCE<5 THEN CHANCE=5
7065 PRINT
7070 PRINT "You climb out over the Pacific, homing in on Howland's radio"
7075 PRINT "signal as best you can..."
7080 PRINT
7085 IF INT(RND*100)+1<=CHANCE THEN GOTO 7200
7090 IF INT(RND*1000)+1<=15 THEN GOTO 7300
7095 GOTO 7400

7200 PRINT "A speck on the horizon resolves into a strip of white coral --"
7205 PRINT "Howland Island! You put the Electra down safely on the airstrip."
7210 GOTO 11000

7300 PRINT "Howland never appears. Running low on fuel, you turn for the"
7305 PRINT "British Gilbert Islands instead -- and by luck as much as skill,"
7310 PRINT "you sight land and put down safely."
7315 DAY=DAY+1
7320 GOTO 11050

7400 PRINT "Howland never appears. Your fuel runs out somewhere over the"
7405 PRINT "vast Pacific. Your last radio transmission fades into static,"
7410 PRINT "and no trace of the Electra is ever found."
7415 PRINT
7420 PRINT "Like the flight that inspired this journey, yours becomes one of"
7425 PRINT "aviation's enduring mysteries."
7430 DEATH$="Lost over the Pacific, searching for Howland Island."
7435 GOTO 12000

7995 REM ========================= clamp quantities to >=0 =====================
8000 IF PC<0 THEN PC=0
8005 RETURN

8495 REM ============================ print status ===============================
8500 PRINT "Plane condition (wear): "; PC; "%   Flying days: "; DAY
8505 PRINT
8510 GOSUB 8000
8515 RETURN

8995 REM =============================== print day ================================
9000 PRINT
9005 PRINT "== Day "; DAY; " =="
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
10005 IF A<A1 THEN PRINT "That's too slow. Try again." ELSE PRINT "That's too fast. Try again."
10010 INPUT A
10015 GOTO 10000

10995 REM ================================ endings =================================
11000 CLS
11005 PRINT "YOU MADE IT TO HOWLAND ISLAND!"
11010 PRINT
11015 PRINT "After refueling, you complete the final short legs home across"
11020 PRINT "the Pacific to Honolulu and Oakland, finishing what you set out"
11025 PRINT "to do: a flight around the world at the equator, farther than"
11030 PRINT "any pilot had flown before."
11035 PRINT
11040 PRINT "You did what the historical flight could not: you found Howland."
11045 GOTO 11500

11050 CLS
11055 PRINT "DOWN IN THE GILBERT ISLANDS"
11060 PRINT
11065 PRINT "You didn't find Howland, but you're alive, and so is your"
11070 PRINT "navigator. Rescue arrives within the week, and your record"
11075 PRINT "round-the-world attempt ends here, short of the goal but"
11080 PRINT "far luckier than history's version of this flight."
11085 GOTO 11500

11500 PRINT
11505 PRINT "Total flying days: "; DAY
11510 PRINT
11515 INPUT "Press ENTER to end"; ANY$
11520 END

11995 REM ============================= flight ends early ==========================
12000 CLS
12005 PRINT "Your flight ends before completing the circumnavigation."
12010 PRINT
12015 PRINT DEATH$
12020 PRINT
12025 PRINT "You made it "; DAY; " days and "; SEGMENT; " legs into the journey."
12030 PRINT
12035 INPUT "Press ENTER to end"; ANY$
12040 END
