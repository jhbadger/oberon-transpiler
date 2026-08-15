10 REM
20 REM  THE JOURNEY OF MARCO POLO -- VENICE TO SHANG-TU, 1271
30 REM  Adapted for basic.mod from David H. Ahl's "Marco Polo" in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM
60 DIM S$(4)
70 DIM F$(3)
80 DIM MO$(6)
90 S$(1)="SPLAT" : S$(2)="SPRONG" : S$(3)="TWACK" : S$(4)="ZUNK"
100 F$(1)="wild boar" : F$(2)="big stag" : F$(3)="black bear"
110 MO$(1)="March" : MO$(2)="May" : MO$(3)="July"
120 MO$(4)="September" : MO$(5)="November" : MO$(6)="January"
130 JEWELS=300 : CAMELS=0 : CAMELPRICE=20
140 CLOTHES=2 : MEDICINE=5 : ARROWS=30
150 FOOD=0 : OIL=0 : FOODEATEN=0
160 MILES=0 : SEGMENT=0 : WARNEDCLOTHES=0
170 SICKTOTAL=0 : WOUNDTOTAL=0 : POORTOTAL=0

200 CLS
210 PRINT "          THE JOURNEY OF MARCO POLO, 1271"
220 PRINT "             adapted from David H. Ahl"
230 PRINT
240 INPUT "Press ENTER to begin your trek!"; ANY$
250 CLS
260 PRINT "Starting from Venice, you sail to the port of Laiassus in"
270 PRINT "Armenia. From there you must lead a caravan on a 6000-mile"
280 PRINT "trek across Asia to the court of the Great Kublai Khan in"
290 PRINT "Shang-tu, Cathay."
300 PRINT
310 PRINT "You have set aside "; JEWELS; " jewels to finance the journey."
320 PRINT "You must barter wisely for camels, food, and oil along the"
330 PRINT "way -- prices are lower in port cities, so stock up early."
340 PRINT "You will also need to replenish clothes, medicine, and"
350 PRINT "arrows for your crossbow as you go."
360 PRINT
370 INPUT "Press ENTER to continue"; ANY$
380 CLS

400 PRINT "Before you set out, rank your skill with the crossbow:"
410 PRINT "  (1) Can hit a charging boar at 300 paces"
420 PRINT "  (2) Can hit a deer at 50 paces"
430 PRINT "  (3) Can hit a sleeping woodchuck at 5 paces"
440 PRINT "  (4) Occasionally hit your own foot while loading"
450 INPUT "How do you rank yourself (1-4)? "; SKILL
460 IF (SKILL>=1) AND (SKILL<=4) THEN GOTO 490
470 PRINT "Please enter 1, 2, 3, or 4."
480 GOTO 450
490 PRINT

500 PRINT "After three months at sea, you arrive at Laiassus. Camels"
510 PRINT "here cost between 17 and 24 jewels each."
520 A1=17 : A2=24
530 INPUT "How much do you want to pay per camel? "; A
540 GOSUB 10000
550 CAMELPRICE=A
560 PRINT "You should buy at least 7 camels, but no more than 12."
570 A1=7 : A2=12
580 INPUT "How many camels do you want to buy? "; A
590 GOSUB 10000
600 CAMELS=A
610 JEWELS=JEWELS-CAMELS*CAMELPRICE

620 PRINT
630 PRINT "A sack of food costs 2 jewels. You need at least 8 sacks to"
640 PRINT "reach Babylon; your camels can carry "; 3*CAMELS-6; " of them."
650 A1=8 : A2=3*CAMELS-6
660 INPUT "How many sacks of food do you want? "; A
670 GOSUB 10000
680 FOOD=A
690 JEWELS=JEWELS-FOOD*2

700 PRINT
710 PRINT "A skin of oil costs 2 jewels. You should carry at least 6"
720 PRINT "full skins for cooking in the desert; you can carry "; 3*CAMELS-FOOD; " more."
730 A1=5 : A2=3*CAMELS-FOOD
740 INPUT "How many skins of oil do you want? "; A
750 GOSUB 10000
760 OIL=A
770 JEWELS=JEWELS-OIL*2

800 PRINT
810 PRINT "Here is what you have to start your trek:"
820 GOSUB 8500
830 INPUT "Press ENTER to begin!"; ANY$
840 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 GOSUB 9000
1020 DIST=40+CAMELPRICE*20+INT(RND*100)
1030 GOSUB 2000
1040 GOSUB 2500
1050 IF (SEGMENT>1) AND (JEWELS>1) THEN GOSUB 3000
1060 IF CLOTHES<=0 THEN GOSUB 3500
1070 GOSUB 4000
1080 MILES=MILES+DIST
1090 PRINT
1100 PRINT "You have traveled "; MILES; " miles."
1110 GOSUB 8500
1120 IF MILES>=6000 THEN GOTO 11000
1130 INDESERT=0
1140 GOSUB 5000
1150 IF (INDESERT=0) AND (RND<0.18) THEN GOSUB 4500
1160 IF INDESERT=0 THEN GOSUB 5500
1170 GOSUB 8000
1180 GOTO 1000

1995 REM ==================== status: camels and jewels =======================
2000 IF JEWELS>15 THEN RETURN
2005 PRINT "You have only "; JEWELS; " jewels left to barter with."
2010 IF CAMELS<=2 THEN GOTO 2040
2015 PRINT "Would you like to sell your weakest camel?"
2020 GOSUB 9500
2025 IF YES=0 THEN GOTO 2040
2030 RN=INT(8+RND*9)
2032 JEWELS=JEWELS+RN : CAMELS=CAMELS-1
2034 PRINT "You get "; RN; " jewels for it."
2040 IF CLOTHES>0 THEN RETURN
2045 PRINT "Your clothes are in tatters -- you should replace them soon."
2050 RETURN

2495 REM ============ health: sickness, wounds, and poor eating ===============
2500 SICKTOTAL=SICKTOTAL+SICKPTS : SICKPTS=0
2505 WOUNDTOTAL=WOUNDTOTAL+WOUNDPTS : WOUNDPTS=0
2510 IF FOODEATEN=3 THEN POORTOTAL=POORTOTAL+1
2515 IF SICKTOTAL+WOUNDTOTAL+POORTOTAL<4 THEN RETURN
2520 IF RND>0.3 THEN RETURN
2525 PRINT
2530 PRINT "Sickness, wounds, and poor eating finally catch up with you."
2535 PRINT "You must stop at a village and rest to regain your strength."
2540 RN=INT(1+RND*3)
2545 SEGMENT=SEGMENT+RN
2550 FOOD=INT(FOOD/2)
2555 IF FOOD<3 THEN FOOD=3
2560 IF JEWELS>20 THEN JEWELS=JEWELS-10 ELSE JEWELS=INT(JEWELS/2)
2565 SICKTOTAL=0 : WOUNDTOTAL=0 : POORTOTAL=0
2570 GOSUB 9000
2575 IF RND>=0.1 THEN RETURN
2580 DEATH$="The illness proves too much, and you succumb far from home."
2585 GOTO 12000

2995 REM ========================= barter for supplies =========================
3000 PRINT
3005 PRINT "You have "; JEWELS; " jewels. Do you want to barter here?"
3010 GOSUB 9500
3015 IF YES=0 THEN RETURN

3020 RN=INT(17+RND*8)
3025 PRINT "Camels cost "; RN; " jewels here."
3030 A1=0 : A2=INT(JEWELS/RN)
3035 INPUT "How many do you want? "; A
3040 GOSUB 10000
3045 CAMELS=CAMELS+A : JEWELS=JEWELS-A*RN
3050 IF A>0 THEN CAMELPRICE=CAMELPRICE-1
3055 IF CAMELPRICE<10 THEN CAMELPRICE=10

3060 RN=INT(2+RND*4)
3065 PRINT "Sacks of food cost "; RN; " jewels."
3070 A1=0 : A2=INT(JEWELS/RN)
3075 IF 3*CAMELS-FOOD-OIL<A2 THEN A2=3*CAMELS-FOOD-OIL
3080 IF A2<0 THEN A2=0
3085 INPUT "How many do you want? "; A
3090 GOSUB 10000
3095 FOOD=FOOD+A : JEWELS=JEWELS-A*RN

3100 RN=INT(2+RND*4)
3105 PRINT "Skins of oil cost "; RN; " jewels."
3110 A1=0 : A2=INT(JEWELS/RN)
3115 IF 3*CAMELS-FOOD-OIL<A2 THEN A2=3*CAMELS-FOOD-OIL
3120 IF A2<0 THEN A2=0
3125 INPUT "How many do you want? "; A
3130 GOSUB 10000
3135 OIL=OIL+A : JEWELS=JEWELS-A*RN

3140 RN=INT(8+RND*8)
3145 PRINT "A set of clothes costs "; RN; " jewels."
3150 A1=0 : A2=INT(JEWELS/RN)
3155 INPUT "How many do you want? "; A
3160 GOSUB 10000
3165 CLOTHES=CLOTHES+A : JEWELS=JEWELS-A*RN

3170 PRINT "A bottle of balm costs 2 jewels."
3175 A1=0 : A2=INT(JEWELS/2)
3180 INPUT "How many do you want? "; A
3185 GOSUB 10000
3190 MEDICINE=MEDICINE+A : JEWELS=JEWELS-A*2

3195 RN=INT(6+RND*6)
3200 PRINT "You can get "; RN; " arrows for 1 jewel."
3205 A1=0 : A2=JEWELS
3210 INPUT "How many jewels do you want to spend on arrows? "; A
3215 GOSUB 10000
3220 ARROWS=ARROWS+A*RN : JEWELS=JEWELS-A

3225 PRINT
3230 PRINT "Here is what you now have:"
3235 GOSUB 8500
3240 RETURN

3495 REM ============================ no clothes ==============================
3500 PRINT
3505 PRINT "Your ragged clothes offend the local people."
3510 IF WARNEDCLOTHES=1 THEN GOTO 3540
3515 IF RND>0.2 THEN GOTO 3525
3520 GOTO 3535
3525 PRINT "They chase you out of town, but let you go unharmed."
3527 WARNEDCLOTHES=1
3529 RETURN
3535 WOUNDPTS=WOUNDPTS+2 : WARNEDCLOTHES=1
3537 PRINT "They stone you before you can get away. You are badly hurt."
3539 RETURN
3540 WOUNDPTS=WOUNDPTS+2
3542 PRINT "Word of your disreputable appearance has spread; they stone you again."
3544 RETURN

3995 REM ============================== eating =================================
4000 IF FOOD>=3 THEN GOTO 4100
4005 PRINT
4010 PRINT "You don't have enough food to go on."
4015 IF JEWELS<15 THEN GOTO 4060
4020 RN=INT(5+RND*4)
4025 PRINT "Emergency rations cost "; RN; " jewels a sack here."
4030 A1=1 : A2=INT(JEWELS/RN)
4035 INPUT "How many sacks do you want? "; A
4040 GOSUB 10000
4045 FOOD=FOOD+A : JEWELS=JEWELS-A*RN
4050 IF FOOD>=3 THEN GOTO 4100
4060 IF CAMELS<1 THEN GOTO 4090
4065 PRINT "You have no choice but to eat one of your camels."
4070 CAMELS=CAMELS-1 : RN=INT(3+RND*2) : FOOD=FOOD+RN
4075 PRINT "It yields about "; RN; " sacks of food."
4080 GOTO 4100
4090 DEATH$="You run out of food, with no camels left to sustain you."
4095 GOTO 12000

4100 PRINT
4105 PRINT "How well do you want to eat on this leg of the journey:"
4110 PRINT "  (1) Reasonably well (travel farther, less illness)"
4115 PRINT "  (2) Adequately"
4120 PRINT "  (3) Poorly (saves food, but slower and riskier)"
4125 INPUT "Your choice? "; A
4130 IF (A<1) OR (A>3) THEN PRINT "Please choose 1, 2, or 3.": GOTO 4125
4135 FOODEATEN=6-A
4140 IF FOODEATEN<=FOOD THEN GOTO 4150
4145 PRINT "You don't have enough food to eat that well.": GOTO 4125
4150 FOOD=FOOD-FOODEATEN
4155 DIST=DIST-(A-1)*50
4160 PRINT "You'll have "; FOOD; " sacks of food left."
4165 RETURN

4495 REM =============================== hunting ================================
4500 IF ARROWS<15 THEN PRINT "You don't have enough arrows to hunt for food.": RETURN
4505 RN=INT(1+RND*3)
4510 PRINT
4515 PRINT "A "; F$(RN); " breaks from the brush! You grab your crossbow..."
4520 ARROWS=ARROWS-15
4525 GOSUB 7500
4530 IF SR<=1 THEN PRINT "Superb shot! The Khan himself would envy your aim.": FA=3: GOTO 4550
4535 IF SR<=3 THEN PRINT "A solid hit; not bad at all.": FA=2: GOTO 4550
4540 PRINT "Too excited -- your shots go wild.": RETURN
4550 FOOD=FOOD+FA
4555 PRINT "Your hunting yields "; FA; " sacks of food."
4560 RETURN

4995 REM ============================ desert crossing ===========================
5000 IF (MILES>=1900) AND (MILES<2600) THEN XD$="the Dasht-e Kavir (Persian) desert": GOTO 5050
5005 IF (MILES>=4100) AND (MILES<4600) THEN XD$="the Taklimakan (Lop) desert": GOTO 5050
5010 IF (MILES>=5300) AND (MILES<5900) THEN XD$="the Gobi desert": GOTO 5050
5015 RETURN

5050 INDESERT=1
5055 PRINT
5060 PRINT "You are crossing "; XD$; "."
5065 IF OIL>=3 THEN GOTO 5100
5070 PRINT "You have run out of oil for cooking."
5075 IF (OIL>=1) AND (RND>0.5) THEN GOTO 5090
5080 OIL=0 : SICKPTS=SICKPTS+2 : DIST=DIST-80
5082 PRINT "You get horribly sick from eating raw, undercooked food."
5084 GOTO 5110
5090 OIL=0
5092 PRINT "You manage to make do with what little oil you have left."
5094 GOTO 5110
5100 OIL=OIL-3
5105 PRINT "You use 3 skins of oil for cooking."

5110 RN=INT(1+RND*4)
5115 IF RN=1 THEN GOSUB 6000: RETURN
5120 IF RN=2 THEN GOSUB 6200: RETURN
5125 IF RN=3 THEN GOSUB 6950: RETURN
5130 PRINT "You get through this stretch of desert without mishap!"
5135 RETURN

5495 REM ======================= random event on the road =======================
5500 RN=INT(RND*100)+1
5505 IF RN<=8 THEN GOSUB 6000: RETURN
5510 IF RN<=16 THEN GOSUB 6100: RETURN
5515 IF RN<=24 THEN GOSUB 6200: RETURN
5520 IF RN<=31 THEN GOSUB 6300: RETURN
5525 IF RN<=37 THEN GOSUB 6400: RETURN
5530 IF RN<=43 THEN GOSUB 6500: RETURN
5535 IF RN<=49 THEN GOSUB 6600: RETURN
5540 IF RN<=55 THEN GOSUB 6700: RETURN
5545 IF RN<=61 THEN GOSUB 6800: RETURN
5550 IF RN<=70 THEN GOSUB 6850: RETURN
5555 IF RN<=82 THEN GOSUB 6900: RETURN
5560 PRINT
5565 PRINT "This stretch of the road passes without incident."
5570 RETURN

5995 REM ------------------------------ camel lame -------------------------------
6000 PRINT
6005 PRINT "One of your camels goes lame and can barely keep up."
6010 PRINT "  (1) Nurse it along slowly"
6015 PRINT "  (2) Slaughter it for food"
6020 PRINT "  (3) Sell it to a passing trader"
6025 INPUT "What do you want to do? "; A
6030 IF A=1 THEN DIST=DIST-40: PRINT "You slow your pace to spare it.": RETURN
6035 IF A=2 THEN GOTO 6060
6040 IF A=3 THEN GOTO 6070
6045 PRINT "Not a valid choice -- you nurse it along instead."
6050 DIST=DIST-40
6055 RETURN
6060 CAMELS=CAMELS-1 : RN=INT(2+RND*2) : FOOD=FOOD+RN
6062 PRINT "You get "; RN; " sacks of food from the camel."
6064 RETURN
6070 CAMELS=CAMELS-1 : RN=INT(8+RND*8) : JEWELS=JEWELS+RN
6072 PRINT "You sell the poor beast for "; RN; " jewels."
6074 RETURN

6095 REM ------------------------------- bad water --------------------------------
6100 PRINT
6105 PRINT "A long stretch with bad water costs you time finding clean wells."
6110 DIST=DIST-50
6115 RETURN

6195 REM ---------------------------------- lost -----------------------------------
6200 PRINT
6205 PRINT "You get lost trying to find an easier route."
6210 DIST=DIST-100
6215 RETURN

6295 REM -------------------------------- heavy rain --------------------------------
6300 PRINT
6305 PRINT "Heavy rains completely wash away the route."
6310 DIST=DIST-90
6315 RETURN

6395 REM ------------------------------ food spoils ---------------------------------
6400 PRINT
6405 PRINT "Some of your food rots in the humid weather."
6410 FOOD=FOOD-1
6415 RETURN

6495 REM ------------------------------ animal raid ---------------------------------
6500 PRINT
6505 PRINT "Marauding animals get into your food supply overnight."
6510 FOOD=FOOD-1
6515 RETURN

6595 REM ---------------------------------- fire ------------------------------------
6600 PRINT
6605 PRINT "A cooking fire flares up and destroys some food and clothes."
6610 FOOD=FOOD-1 : CLOTHES=CLOTHES-1
6615 IF OIL>=1 THEN OIL=OIL-1
6620 RETURN

6695 REM ----------------------------- camels wander --------------------------------
6700 PRINT
6705 PRINT "Two camels wander off. You spend days finding them again."
6710 DIST=DIST-20
6715 RETURN

6795 REM --------------------------- rocks tear clothes ------------------------------
6800 PRINT
6805 PRINT "Jagged rocks tear your sandals and clothing badly."
6810 CLOTHES=CLOTHES-1 : DIST=DIST-30
6815 RETURN

6845 REM ----------------------------- illness cluster -------------------------------
6850 PRINT
6855 PRINT "Fever and stomach cramps sweep through your party."
6860 SICKPTS=SICKPTS+2 : DIST=DIST-100
6865 RETURN

6895 REM ------------------------------ bandit attack --------------------------------
6900 PRINT
6903 PRINT "Blood-thirsty bandits swoop down on your small caravan!"
6906 IF ARROWS<15 THEN GOTO 6930
6909 PRINT "You grab your crossbow..."
6912 ARROWS=ARROWS-15
6915 GOSUB 7500
6918 IF SR<=1 THEN PRINT "Sensational shooting! You drive them off unharmed.": RETURN
6921 IF SR<=3 THEN GOTO 6936
6924 GOTO 6942
6930 PRINT "You are out of arrows and cannot fight back."
6931 FOOD=FOOD-1 : JEWELS=JEWELS-5
6932 PRINT "They grab some food and jewels, then ride off."
6933 RETURN
6936 PRINT "You wound one bandit, but they overpower you and grab some jewels."
6937 JEWELS=JEWELS-10 : WOUNDPTS=WOUNDPTS+2
6938 RETURN
6942 PRINT "Your aim is terrible. An iron mace catches you in the chest."
6943 JEWELS=JEWELS-5 : WOUNDPTS=WOUNDPTS+3
6944 IF RND>=0.15 THEN RETURN
6945 DEATH$="The bandits overwhelm your caravan; you do not survive."
6946 GOTO 12000

6948 REM ------------------------------- sandstorm ------------------------------------
6950 PRINT
6952 PRINT "High winds, sandstorms, and ferocious heat slow you badly."
6954 DIST=DIST-70
6956 RETURN

7495 REM ==================== shooting minigame (crossbow) ======================
7500 RN=INT(1+RND*4)
7505 PRINT
7510 PRINT "Type the word exactly when ready: "; S$(RN)
7515 T1=TIMER
7520 INPUT SR$
7525 IF SR$=S$(RN) THEN GOTO 7540
7530 PRINT "That's not it -- try again: "; S$(RN)
7535 GOTO 7520
7540 T2=TIMER
7545 SR=(T2-T1)-SKILL
7550 RETURN

7995 REM ========================= clamp quantities to >=0 =====================
8000 IF JEWELS<0 THEN JEWELS=0
8005 IF FOOD<0 THEN FOOD=0
8010 IF OIL<0 THEN OIL=0
8015 IF CLOTHES<0 THEN CLOTHES=0
8020 IF MEDICINE<0 THEN MEDICINE=0
8025 IF ARROWS<0 THEN ARROWS=0
8030 IF CAMELS<0 THEN CAMELS=0
8035 RETURN

8495 REM ============================ print inventory ===========================
8500 PRINT "Jewels: "; JEWELS; "   Camels: "; CAMELS
8505 PRINT "Food (sacks): "; FOOD; "   Oil (skins): "; OIL
8510 PRINT "Clothes: "; CLOTHES; "   Medicine: "; MEDICINE; "   Arrows: "; ARROWS
8515 PRINT
8520 RETURN

8995 REM =============================== print date ==============================
9000 MO=SEGMENT
9005 WHILE MO>6
9010 MO=MO-6
9015 WEND
9020 IF MO<1 THEN MO=1
9025 YR=1271+INT(SEGMENT/6)
9030 PRINT
9035 PRINT "Date: "; MO$(MO); " "; YR
9040 RETURN

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

10995 REM =============================== you arrive! =============================
11000 CLS
11005 PRINT "CONGRATULATIONS!"
11010 PRINT
11015 PRINT "You have been traveling for "; SEGMENT*2; " months."
11020 PRINT
11025 PRINT "You are ushered into the court of the Great Kublai Khan, who"
11030 PRINT "surveys your remaining supplies:"
11035 GOSUB 8500
11040 IF SEGMENT*2<=24 THEN PRINT "An extraordinary pace -- faster than the Polos themselves!"
11045 IF (SEGMENT*2>24) AND (SEGMENT*2<=36) THEN PRINT "A fine journey, on par with the historical Polo expedition."
11050 IF SEGMENT*2>36 THEN PRINT "You made it at last, though the Polos beat you to Shang-tu."
11055 PRINT
11060 PRINT "The Khan is delighted by tales of the West, and keeps you as"
11065 PRINT "his honored guests for years to come. Well done!"
11070 PRINT
11075 INPUT "Press ENTER to end"; ANY$
11080 END

11995 REM ================================ you die =================================
12000 CLS
12005 PRINT "Your journey ends far short of Shang-tu."
12010 PRINT
12015 PRINT DEATH$
12020 PRINT
12025 PRINT "You had traveled "; MILES; " miles in "; SEGMENT*2; " months."
12030 PRINT
12035 INPUT "Press ENTER to end"; ANY$
12040 END
