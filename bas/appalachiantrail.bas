10 REM
20 REM  APPALACHIAN TRAIL -- A THRU-HIKE FROM GEORGIA TO MAINE
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM
60 DIST=0 : DAY=0 : CONDITION=100 : FOOD=6 : SEGMENT=0 : TOWNCOUNT=0

100 CLS
110 PRINT "     APPALACHIAN TRAIL -- A THRU-HIKE FROM GEORGIA TO MAINE"
120 PRINT "                adapted from David H. Ahl"
130 PRINT
140 INPUT "Press ENTER to shoulder your pack!"; ANY$
150 CLS
160 PRINT "From Springer Mountain, Georgia, to the summit of Mount Katahdin,"
170 PRINT "Maine, the Appalachian Trail runs roughly 2,190 miles through"
180 PRINT "fourteen states. Every few days on the trail you'll set your"
190 PRINT "pace, watch your food, and take whatever the trail throws at you."
200 PRINT
210 INPUT "Press ENTER to continue"; ANY$
220 CLS

300 PRINT "How would you rate your gear?"
310 PRINT "  (1) Top-of-the-line, ultralight everything"
320 PRINT "  (2) Solid, dependable gear"
330 PRINT "  (3) A mixed bag, some of it borrowed"
340 PRINT "  (4) Shoestring budget, whatever you could find"
350 INPUT "How do you rank your gear (1-4)? "; GEARQUALITY
360 IF (GEARQUALITY>=1) AND (GEARQUALITY<=4) THEN GOTO 390
370 PRINT "Please enter 1, 2, 3, or 4."
380 GOTO 350
390 PRINT
400 INPUT "Press ENTER to start hiking!"; ANY$
410 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 GOSUB 9000
1020 GOSUB 2000
1030 DIST=DIST+PACE*3
1040 DAY=DAY+3
1050 GOSUB 2500
1060 IF FOOD<=0 THEN GOSUB 3000
1070 PRINT
1080 GOSUB 4000
1090 GOSUB 8000
1100 IF CONDITION<=0 THEN GOTO 12000
1110 IF DIST>=2190 THEN GOTO 11000
1120 IF INT(DIST/500)>TOWNCOUNT THEN TOWNCOUNT=INT(DIST/500): GOSUB 5000
1130 GOTO 1000

1995 REM =============================== pace choice ==============================
2000 PRINT
2005 PRINT "What daily pace do you want for the next few days (8-25 miles/day)?"
2010 A1=8 : A2=25
2015 INPUT "Your pace? "; A
2020 GOSUB 10000
2025 PACE=A
2030 RETURN

2495 REM ================================= eating =================================
2500 PRINT
2505 PRINT "How well do you want to eat this stretch:"
2510 PRINT "  (1) Well  (2) Adequately  (3) Sparingly"
2515 A1=1 : A2=3
2520 INPUT "Your choice? "; A
2525 GOSUB 10000
2530 FOOD=FOOD-1
2535 IF A=1 THEN CONDITION=CONDITION-3
2540 IF A=2 THEN CONDITION=CONDITION-6
2545 IF A=3 THEN CONDITION=CONDITION-10
2550 CONDITION=CONDITION-(GEARQUALITY-1)*2
2555 IF PACE>=20 THEN CONDITION=CONDITION-5
2560 RETURN

2995 REM ============================ running out of food =========================
3000 PRINT
3005 PRINT "You're nearly out of food and still a ways from the next town."
3010 PRINT "You ration what's left and push on hungry."
3015 CONDITION=CONDITION-15
3020 FOOD=1
3025 RETURN

3995 REM ========================= trail hazard / weather ==========================
4000 RN=INT(RND*100)+1
4005 IF RN<=12 THEN PRINT "You twist an ankle on a root. It slows you but you push on.": CONDITION=CONDITION-10: RETURN
4010 IF RN<=24 THEN PRINT "Blisters are making every step miserable.": CONDITION=CONDITION-8: RETURN
4015 IF RN<=32 THEN PRINT "A snake curls up in your boot overnight -- unharmed but unnerving.": CONDITION=CONDITION-3: RETURN
4020 IF RN<=40 THEN PRINT "A black bear ambles through camp and helps itself to your food bag.": FOOD=FOOD-1: RETURN
4025 IF RN<=48 THEN PRINT "You lose the trail for a while in the fog before finding a blaze.": CONDITION=CONDITION-5: RETURN
4030 IF RN<=56 THEN PRINT "A stream crossing leaves you soaked to the knees.": CONDITION=CONDITION-4: RETURN
4035 IF RN<=64 THEN PRINT "Heavy rain turns the trail to mud for miles.": CONDITION=CONDITION-6: RETURN
4040 IF (DIST>1500) AND (DAY>150) AND (RN<=74) THEN PRINT "An early snow dusts the ridgeline -- brutal, beautiful, and cold.": CONDITION=CONDITION-15: RETURN
4045 IF RN<=82 THEN PRINT "You reach a stunning overlook and stop to take it all in.": RETURN
4050 IF RN<=91 THEN PRINT "You share a shelter with friendly hikers and trade trail stories.": CONDITION=CONDITION+5: RETURN
4055 PRINT "A quiet, easy stretch of trail -- exactly what you needed."
4060 CONDITION=CONDITION+3
4065 RETURN

4995 REM ============================= trail town stop =============================
5000 PRINT
5005 PRINT "You reach a trail town and can resupply."
5010 PRINT "A hot meal and a shower do wonders."
5015 CONDITION=CONDITION+20
5020 FOOD=FOOD+INT(3+RND*3)
5025 RETURN

7995 REM ========================= clamp quantities =============================
8000 IF CONDITION<0 THEN CONDITION=0
8005 IF CONDITION>100 THEN CONDITION=100
8010 IF FOOD<0 THEN FOOD=0
8015 RETURN

8995 REM ============================ print status ================================
9000 PRINT
9005 PRINT "== Day "; DAY; " -- "; DIST; " miles from Springer Mountain =="
9010 PRINT "Condition: "; CONDITION; "%   Food: "; FOOD; " leg(s) worth"
9015 RETURN

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 IF A<A1 THEN PRINT "That's too few. Try again." ELSE PRINT "That's too many. Try again."
10010 INPUT A
10015 GOTO 10000

10995 REM =============================== you summit! ==============================
11000 CLS
11005 PRINT "YOU SUMMIT MOUNT KATAHDIN!"
11010 PRINT
11015 PRINT "After "; DAY; " days and "; DIST; " miles, you reach the famous"
11020 PRINT "sign at the northern terminus of the Appalachian Trail."
11025 IF DAY<=140 THEN PRINT "A blistering thru-hike pace -- among the fastest out there."
11030 IF (DAY>140) AND (DAY<=190) THEN PRINT "A strong, solid thru-hike, right in the typical range."
11035 IF DAY>190 THEN PRINT "A long journey, but you made it the whole way -- not everyone does."
11040 PRINT
11045 INPUT "Press ENTER to end"; ANY$
11050 END

11995 REM =============================== you leave the trail =======================
12000 CLS
12005 PRINT "Your thru-hike ends before reaching Katahdin."
12010 PRINT
12015 PRINT "Exhausted and worn down, you decide to leave the trail at the"
12020 PRINT "next road crossing and head home."
12025 PRINT
12030 PRINT "You made it "; DIST; " miles in "; DAY; " days."
12035 PRINT
12040 INPUT "Press ENTER to end"; ANY$
12045 END
