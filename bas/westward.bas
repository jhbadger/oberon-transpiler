10 REM
20 REM  WESTWARD HO! -- INDEPENDENCE, MISSOURI TO OREGON CITY, 1847
30 REM  Adapted for basic.mod from David H. Ahl's "Westward Ho!" in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM
60 DIM W$(4)
70 W$(1)="BANG" : W$(2)="POW" : W$(3)="BLAM" : W$(4)="CRACK"
80 CASH=420 : OXEN=0 : OXENPRICE=15
90 FOOD=0 : BULLETS=0 : CLOTHES=0 : MEDICINE=0
100 MILES=0 : SEGMENT=0 : FOODEATEN=0
110 SICKTOTAL=0 : WOUNDTOTAL=0 : POORTOTAL=0

200 CLS
210 PRINT "        WESTWARD HO! -- THE OREGON TRAIL, 1847"
220 PRINT "             adapted from David H. Ahl"
230 PRINT
240 INPUT "Press ENTER to begin your journey!"; ANY$
250 CLS
260 PRINT "Your family of five is setting out from Independence, Missouri,"
270 PRINT "for a new life in Oregon City, Oregon -- 2000 miles to the west."
280 PRINT
290 PRINT "You have saved "; CASH; " dollars. A sturdy wagon costs 70 dollars,"
300 PRINT "and with what remains you must buy oxen, food, ammunition,"
310 PRINT "clothing, and medicine to see your family through."
320 PRINT
330 INPUT "Press ENTER to continue"; ANY$
340 CLS
350 CASH=CASH-70

400 PRINT "First, rank your skill with a rifle:"
410 PRINT "  (1) Can drop a running deer at 200 yards"
420 PRINT "  (2) A fair shot with practice"
430 PRINT "  (3) Can usually hit a barn from inside it"
440 PRINT "  (4) Have never actually fired a gun before"
450 INPUT "How do you rank yourself (1-4)? "; SKILL
460 IF (SKILL>=1) AND (SKILL<=4) THEN GOTO 490
470 PRINT "Please enter 1, 2, 3, or 4."
480 GOTO 450
490 PRINT

500 PRINT "You have "; CASH; " dollars left. Oxen here cost between 10 and 18"
510 PRINT "dollars each."
520 A1=10 : A2=18
530 INPUT "How much do you want to pay per ox? "; A
540 GOSUB 10000
550 OXENPRICE=A
560 PRINT "A team needs at least 4 oxen, but no more than 10."
570 A1=4 : A2=10
580 INPUT "How many oxen do you want to buy? "; A
590 GOSUB 10000
600 OXEN=A
610 CASH=CASH-OXEN*OXENPRICE

620 PRINT
630 PRINT "A sack of food costs 1 dollar. You need at least 30 sacks;"
640 PRINT "your wagon can carry "; OXEN*10; " sacks at most."
650 A1=30 : A2=OXEN*10
660 INPUT "How many sacks of food do you want? "; A
670 GOSUB 10000
680 FOOD=A
690 CASH=CASH-FOOD

700 PRINT
710 PRINT "You can get 15 bullets for a dollar."
720 A1=0 : A2=CASH
730 INPUT "How many dollars do you want to spend on ammunition? "; A
740 GOSUB 10000
750 BULLETS=A*15
760 CASH=CASH-A

770 PRINT
780 PRINT "Warm clothing costs 11 dollars an outfit. You should have at"
790 PRINT "least 3 for the mountains ahead."
800 A1=0 : A2=INT(CASH/11)
810 INPUT "How many outfits do you want? "; A
820 GOSUB 10000
830 CLOTHES=A
840 CASH=CASH-A*11

850 PRINT
860 PRINT "A medicine kit costs 8 dollars."
870 A1=0 : A2=INT(CASH/8)
880 INPUT "How many kits do you want? "; A
890 GOSUB 10000
900 MEDICINE=A
910 CASH=CASH-A*8

920 PRINT
930 PRINT "Here is what you have to start your journey:"
940 GOSUB 8500
950 INPUT "Press ENTER to begin!"; ANY$
960 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 GOSUB 9000
1020 DIST=150+OXENPRICE*6+INT(RND*60)
1030 GOSUB 2000
1040 GOSUB 2500
1050 GOSUB 8500
1060 GOSUB 2800
1070 GOSUB 4000
1080 MILES=MILES+DIST
1090 PRINT
1100 PRINT "You have traveled "; MILES; " miles."
1110 GOSUB 8500
1120 IF MILES>=2000 THEN GOTO 11000
1130 INMOUNTAINS=0
1140 GOSUB 5000
1150 IF INMOUNTAINS=0 THEN GOSUB 6900
1160 IF INMOUNTAINS=0 THEN GOSUB 5500
1170 GOSUB 8000
1180 GOTO 1000

1995 REM ===================== status: cash and oxen ============================
2000 IF CASH>15 THEN GOTO 2040
2005 PRINT "You are running low on cash."
2010 IF OXEN<=3 THEN GOTO 2040
2015 PRINT "Would you like to sell an ox at the next chance you get?"
2020 GOSUB 9500
2025 IF YES=0 THEN GOTO 2040
2030 RN=INT(6+RND*6)
2032 CASH=CASH+RN : OXEN=OXEN-1
2034 PRINT "You get "; RN; " dollars for it."
2040 IF CLOTHES>0 THEN RETURN
2045 PRINT "You have no warm clothing left -- that could be dangerous ahead."
2050 RETURN

2495 REM ============ health: sickness, wounds, and poor eating ===============
2500 SICKTOTAL=SICKTOTAL+SICKPTS : SICKPTS=0
2505 WOUNDTOTAL=WOUNDTOTAL+WOUNDPTS : WOUNDPTS=0
2510 IF FOODEATEN=3 THEN POORTOTAL=POORTOTAL+1
2515 IF SICKTOTAL+WOUNDTOTAL+POORTOTAL<4 THEN RETURN
2520 IF MEDICINE>0 THEN GOTO 2560
2525 IF RND>0.3 THEN RETURN
2530 PRINT
2535 PRINT "Illness and hardship finally catch up with your family."
2540 PRINT "You must stop and see a doctor to recover."
2545 RN=INT(1+RND*3)
2550 SEGMENT=SEGMENT+RN
2552 IF CASH>15 THEN CASH=CASH-10 ELSE CASH=INT(CASH/2)
2554 SICKTOTAL=0 : WOUNDTOTAL=0 : POORTOTAL=0
2556 GOSUB 9000
2557 IF RND>=0.1 THEN RETURN
2558 DEATH$="The illness proves too much for your family to overcome."
2559 GOTO 12000
2560 MEDICINE=MEDICINE-1
2562 SICKTOTAL=0 : WOUNDTOTAL=0 : POORTOTAL=0
2564 PRINT
2566 PRINT "You treat the illness with medicine from your kit."
2568 RETURN

2795 REM ==================== decision: continue/hunt/fort ======================
2800 IF (SEGMENT MOD 2)=0 THEN GOTO 2830
2805 PRINT
2810 PRINT "(1) Continue on the trail   (2) Stop and hunt for game"
2815 INPUT "What do you want to do? "; A
2818 IF (A=1) OR (A=2) THEN GOTO 2850
2820 PRINT "Please choose 1 or 2."
2825 GOTO 2815
2830 PRINT
2832 PRINT "(1) Continue on the trail   (2) Stop and hunt   (3) Stop at a trading post"
2835 INPUT "What do you want to do? "; A
2838 IF (A>=1) AND (A<=3) THEN GOTO 2850
2840 PRINT "Please choose 1, 2, or 3."
2845 GOTO 2835
2850 IF A=2 THEN GOSUB 4500
2855 IF A=3 THEN GOSUB 3000
2860 RETURN

2995 REM ========================= trading post ==================================
3000 PRINT
3005 PRINT "You pull into a trading post. Prices here run higher than back home."
3010 RN=INT(12+RND*8)
3015 PRINT "Oxen cost "; RN; " dollars here."
3020 A1=0 : A2=INT(CASH/RN)
3025 INPUT "How many do you want? "; A
3030 GOSUB 10000
3035 OXEN=OXEN+A : CASH=CASH-A*RN

3040 RN=INT(2+RND*2)
3045 PRINT "Food costs "; RN; " dollars a sack."
3050 A1=0 : A2=INT(CASH/RN)
3052 IF OXEN*10-FOOD<A2 THEN A2=OXEN*10-FOOD
3054 IF A2<0 THEN A2=0
3055 INPUT "How many sacks do you want? "; A
3060 GOSUB 10000
3065 FOOD=FOOD+A : CASH=CASH-A*RN

3070 PRINT "You can get 12 bullets for a dollar here."
3075 A1=0 : A2=CASH
3080 INPUT "How many dollars do you want to spend on ammunition? "; A
3085 GOSUB 10000
3090 BULLETS=BULLETS+A*12 : CASH=CASH-A

3095 RN=INT(13+RND*6)
3100 PRINT "Warm clothing costs "; RN; " dollars an outfit."
3105 A1=0 : A2=INT(CASH/RN)
3110 INPUT "How many do you want? "; A
3115 GOSUB 10000
3120 CLOTHES=CLOTHES+A : CASH=CASH-A*RN

3125 PRINT "A medicine kit costs 9 dollars here."
3130 A1=0 : A2=INT(CASH/9)
3135 INPUT "How many do you want? "; A
3140 GOSUB 10000
3145 MEDICINE=MEDICINE+A : CASH=CASH-A*9

3150 PRINT
3155 PRINT "Here is what you now have:"
3160 GOSUB 8500
3165 RETURN

3995 REM ============================== eating =================================
4000 IF FOOD>=5 THEN GOTO 4060
4005 PRINT
4010 PRINT "Your food stores are nearly gone."
4015 IF OXEN<=2 THEN GOTO 4040
4020 PRINT "You have no choice but to butcher one of your oxen for food."
4022 OXEN=OXEN-1 : RN=INT(15+RND*10) : FOOD=FOOD+RN
4024 PRINT "It yields about "; RN; " sacks of food."
4026 GOTO 4060
4040 DEATH$="Your food runs out, and with too few oxen left to spare, your family starves."
4042 GOTO 12000

4060 PRINT
4065 PRINT "How well do you want your family to eat this leg of the trip:"
4070 PRINT "  (1) Well (better health, but uses more food)"
4075 PRINT "  (2) Modestly"
4080 PRINT "  (3) Sparingly (saves food, but risks illness)"
4085 INPUT "Your choice? "; A
4090 IF (A<1) OR (A>3) THEN PRINT "Please choose 1, 2, or 3.": GOTO 4085
4095 FOODEATEN=6-A
4100 IF FOODEATEN<=FOOD THEN GOTO 4110
4105 PRINT "You don't have enough food to eat that well.": GOTO 4085
4110 FOOD=FOOD-FOODEATEN
4115 PRINT "You'll have "; FOOD; " sacks of food left."
4120 RETURN

4495 REM =============================== hunting ================================
4500 IF BULLETS<30 THEN PRINT "You don't have enough ammunition to hunt.": RETURN
4505 PRINT
4510 PRINT "You spot game and stop to hunt."
4515 BULLETS=BULLETS-30 : DIST=DIST-40
4520 GOSUB 7500
4525 IF SR<=1 THEN PRINT "A clean shot! You bring back plenty of meat.": FA=12: GOTO 4540
4530 IF SR<=3 THEN PRINT "A decent shot; you get some meat.": FA=7: GOTO 4540
4535 PRINT "You spook the game and come back empty-handed.": RETURN
4540 FOOD=FOOD+FA
4545 PRINT "Hunting adds "; FA; " sacks of food."
4550 RETURN

4995 REM ================== mountains: South Pass & Blue Mountains ==============
5000 IF (MILES>=1000) AND (MILES<1300) THEN XD$="South Pass": GOTO 5050
5005 IF (MILES>=1750) AND (MILES<1950) THEN XD$="the Blue Mountains": GOTO 5050
5010 RETURN

5050 INMOUNTAINS=1
5055 PRINT
5060 PRINT "You are climbing through "; XD$; "."
5065 IF RND<0.5 THEN GOTO 5090
5070 PRINT "The going is slow and rocky."
5072 DIST=DIST-40
5074 GOTO 5100
5090 PRINT "The wagon gets stuck and you lose the better part of a day freeing it."
5092 DIST=DIST-80
5100 IF RND<0.35 THEN GOTO 5120
5105 PRINT "You reach easier ground without further trouble."
5108 RETURN
5120 PRINT "A sudden blizzard sweeps over the pass."
5122 IF CLOTHES>=3 THEN PRINT "Your warm clothes see you through it safely.": RETURN
5125 PRINT "Without enough warm clothing, the cold takes its toll."
5127 SICKPTS=SICKPTS+2
5129 RETURN

5495 REM ======================= random event on the trail =======================
5500 RN=INT(RND*100)+1
5505 IF RN<=10 THEN GOSUB 6000: RETURN
5510 IF RN<=20 THEN GOSUB 6100: RETURN
5515 IF RN<=29 THEN GOSUB 6200: RETURN
5520 IF RN<=37 THEN GOSUB 6300: RETURN
5525 IF RN<=45 THEN GOSUB 6400: RETURN
5530 IF RN<=52 THEN GOSUB 6500: RETURN
5535 IF RN<=59 THEN GOSUB 6600: RETURN
5540 IF RN<=67 THEN GOSUB 6700: RETURN
5545 IF RN<=76 THEN GOSUB 6800: RETURN
5550 IF RN<=85 THEN GOSUB 6850: RETURN
5555 PRINT
5560 PRINT "The trail is quiet today."
5565 RETURN

5995 REM --------------------------- river crossing -------------------------------
6000 PRINT
6005 PRINT "You have to ford a swift river. Some supplies get soaked."
6010 FOOD=FOOD-2 : DIST=DIST-30
6015 RETURN

6095 REM ----------------------------- wheel breaks --------------------------------
6100 PRINT
6105 PRINT "A wagon wheel splits on the rough trail. You stop to repair it."
6110 DIST=DIST-40
6115 RETURN

6195 REM ------------------------------ oxen wander --------------------------------
6200 PRINT
6205 PRINT "Your oxen wander off in the night. It takes hours to round them up."
6210 DIST=DIST-25
6215 RETURN

6295 REM ----------------------------- prairie fire ---------------------------------
6300 PRINT
6305 PRINT "A prairie fire forces you into a long detour."
6310 DIST=DIST-50
6315 RETURN

6395 REM ------------------------------- hailstorm ----------------------------------
6400 PRINT
6405 PRINT "A sudden hailstorm ruins part of your food stores."
6410 FOOD=FOOD-3
6415 RETURN

6495 REM ------------------------------ camp thieves --------------------------------
6500 PRINT
6505 PRINT "Thieves slip into camp overnight and make off with supplies."
6510 BULLETS=BULLETS-10 : CASH=CASH-5
6515 RETURN

6595 REM -------------------------------- wagon tips --------------------------------
6600 PRINT
6605 PRINT "The wagon tips crossing a rocky creek bed."
6610 FOOD=FOOD-2 : MEDICINE=MEDICINE-1
6615 RETURN

6695 REM -------------------------------- dust storm --------------------------------
6700 PRINT
6705 PRINT "A choking dust storm blots out the trail for most of the day."
6710 DIST=DIST-35
6715 RETURN

6795 REM -------------------------------- foul water ---------------------------------
6800 PRINT
6805 PRINT "The only water for miles is foul and stagnant."
6810 SICKPTS=SICKPTS+1
6815 RETURN

6845 REM --------------------------------- lost trail ---------------------------------
6850 PRINT
6855 PRINT "You lose the trail and waste half a day backtracking."
6860 DIST=DIST-45
6865 RETURN

6895 REM ============= riders approach: bandits or Indians =======================
6900 RISK=15
6902 IF (MILES>=300) AND (MILES<=900) THEN RISK=35
6904 IF INT(RND*100)+1>RISK THEN RETURN
6906 PRINT
6908 GH=INT(RND*2)
6910 IF GH=1 THEN PRINT "A group of riders approaches your wagon -- they seem friendly." ELSE PRINT "A band of riders approaches fast -- they look hostile."
6912 PRINT "(1) Keep moving and ignore them"
6914 PRINT "(2) Stop and try to trade"
6916 PRINT "(3) Circle the wagons defensively"
6918 PRINT "(4) Open fire"
6920 INPUT "What do you want to do? "; A
6922 IF (A<1) OR (A>4) THEN PRINT "Please choose 1-4.": GOTO 6920
6924 IF A=1 THEN GOTO 6930
6926 IF A=2 THEN GOTO 6950
6928 IF A=3 THEN GOTO 6970
6929 GOTO 6990

6930 IF GH=1 THEN PRINT "You keep moving; they wave and ride off.": RETURN
6934 PRINT "You press on, but they raid your wagon as you pass."
6936 FOOD=FOOD-3 : BULLETS=BULLETS-10
6938 RETURN

6950 IF GH=0 THEN GOTO 6960
6952 PRINT "You trade a few trinkets for some fresh meat and information."
6954 FOOD=FOOD+3
6956 RETURN
6960 IF RND<0.3 THEN PRINT "They have no interest in trading -- and attack!": GOTO 6990
6962 PRINT "Tense but peaceful; they take a small toll and move on."
6964 CASH=CASH-5
6966 RETURN

6970 PRINT "You circle the wagons and wait it out. It costs you time."
6972 DIST=DIST-40
6974 IF GH=0 THEN PRINT "They probe your defenses but give up and ride off."
6976 RETURN

6990 PRINT "You grab your rifle..."
6992 GOSUB 7500
6994 IF SR<=1 THEN PRINT "Dead-on shooting! You drive them off cleanly.": RETURN
6996 IF SR<=3 THEN GOTO 7000
6998 GOTO 7010

7000 PRINT "You wound one, but the rest scatter with some of your goods."
7002 CASH=CASH-10 : WOUNDPTS=WOUNDPTS+1
7004 RETURN

7010 PRINT "Your shots go wide. They overrun the wagon before riding off."
7012 CASH=CASH-15 : BULLETS=BULLETS-15 : WOUNDPTS=WOUNDPTS+2
7014 IF RND<0.12 THEN GOTO 7020
7016 RETURN

7020 DEATH$="The attack overwhelms your family; none of you survive."
7022 GOTO 12000

7495 REM ======================= shooting minigame (rifle) =======================
7500 RN=INT(1+RND*4)
7505 PRINT
7510 PRINT "Type the word exactly when ready: "; W$(RN)
7515 T1=TIMER
7520 INPUT SR$
7525 IF SR$=W$(RN) THEN GOTO 7540
7530 PRINT "That's not it -- try again: "; W$(RN)
7535 GOTO 7520
7540 T2=TIMER
7545 SR=(T2-T1)-SKILL
7550 RETURN

7995 REM ========================= clamp quantities to >=0 =====================
8000 IF CASH<0 THEN CASH=0
8005 IF FOOD<0 THEN FOOD=0
8010 IF BULLETS<0 THEN BULLETS=0
8015 IF CLOTHES<0 THEN CLOTHES=0
8020 IF MEDICINE<0 THEN MEDICINE=0
8025 IF OXEN<0 THEN OXEN=0
8030 RETURN

8495 REM ============================ print inventory ===========================
8500 PRINT "Cash: $"; CASH; "   Oxen: "; OXEN
8505 PRINT "Food (sacks): "; FOOD; "   Bullets: "; BULLETS
8510 PRINT "Clothes: "; CLOTHES; "   Medicine: "; MEDICINE
8515 PRINT
8520 RETURN

8995 REM =============================== print week ==============================
9000 PRINT
9005 PRINT "-- Week "; SEGMENT*2; " of the journey --"
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
11005 PRINT "OREGON CITY AT LAST!"
11010 PRINT
11015 PRINT "You have been on the trail for "; SEGMENT*2; " weeks."
11020 PRINT
11025 PRINT "Your wagon rolls into the Willamette Valley. You made it!"
11030 PRINT "Here is what your family has left:"
11035 GOSUB 8500
11040 IF SEGMENT*2<=20 THEN PRINT "A remarkably fast crossing -- ahead of even the best wagon trains!"
11045 IF (SEGMENT*2>20) AND (SEGMENT*2<=30) THEN PRINT "A solid, typical crossing for a family of the era."
11050 IF SEGMENT*2>30 THEN PRINT "A long, hard road, but you made it to Oregon at last."
11055 PRINT
11060 PRINT "You stake your claim and begin a new life in the Willamette Valley."
11065 PRINT
11075 INPUT "Press ENTER to end"; ANY$
11080 END

11995 REM ================================ you die =================================
12000 CLS
12005 PRINT "Your journey ends short of Oregon."
12010 PRINT
12015 PRINT DEATH$
12020 PRINT
12025 PRINT "You had traveled "; MILES; " miles in "; SEGMENT*2; " weeks."
12030 PRINT
12035 INPUT "Press ENTER to end"; ANY$
12040 END
