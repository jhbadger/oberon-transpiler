10 REM
20 REM  WESTWARD HO! 1847 -- INDEPENDENCE, MISSOURI TO OREGON CITY
30 REM  Adapted for basic.mod from the (c) 1986 David H. Ahl original
40 REM
50 DIM DATE$(20)
60 DIM MPMARK(15)
70 DIM PLACE$(15)
80 DIM EVENTP(15)
90 DIM W$(8)

100 W$(1)="POW" : W$(2)="BANG" : W$(3)="BLAM" : W$(4)="WHOP"
110 W$(5)="pow" : W$(6)="bang" : W$(7)="blam" : W$(8)="whop"

120 DATE$(1)="March 29" : DATE$(2)="April 12" : DATE$(3)="April 26"
130 DATE$(4)="May 10" : DATE$(5)="May 24" : DATE$(6)="June 7"
140 DATE$(7)="June 21" : DATE$(8)="July 5" : DATE$(9)="July 19"
150 DATE$(10)="August 2" : DATE$(11)="August 16" : DATE$(12)="August 31"
160 DATE$(13)="September 13" : DATE$(14)="September 27" : DATE$(15)="October 11"
170 DATE$(16)="October 25" : DATE$(17)="November 8" : DATE$(18)="November 22"
180 DATE$(19)="December 6" : DATE$(20)="December 20"

190 MPMARK(1)=5 : PLACE$(1)="on the high prairie."
200 MPMARK(2)=200 : PLACE$(2)="near Independence Crossing on the Big Blue River."
210 MPMARK(3)=350 : PLACE$(3)="following the Platte River."
220 MPMARK(4)=450 : PLACE$(4)="near Fort Kearney."
230 MPMARK(5)=600 : PLACE$(5)="following the North Platte River."
240 MPMARK(6)=750 : PLACE$(6)="within sight of Chimney Rock."
250 MPMARK(7)=850 : PLACE$(7)="near Fort Laramie."
260 MPMARK(8)=1000 : PLACE$(8)="close upon Independence Rock."
270 MPMARK(9)=1050 : PLACE$(9)="in the Big Horn Mountains."
280 MPMARK(10)=1150 : PLACE$(10)="following the Green River."
290 MPMARK(11)=1250 : PLACE$(11)="not too far from Fort Hall."
300 MPMARK(12)=1400 : PLACE$(12)="following the Snake River."
310 MPMARK(13)=1550 : PLACE$(13)="not far from Fort Boise."
320 MPMARK(14)=1850 : PLACE$(14)="in the Blue Mountains."
330 MPMARK(15)=2040 : PLACE$(15)="following the Columbia River."

340 EVENTP(1)=6 : EVENTP(2)=11 : EVENTP(3)=13 : EVENTP(4)=15 : EVENTP(5)=17
350 EVENTP(6)=22 : EVENTP(7)=32 : EVENTP(8)=35 : EVENTP(9)=37 : EVENTP(10)=42
360 EVENTP(11)=44 : EVENTP(12)=54 : EVENTP(13)=64 : EVENTP(14)=69 : EVENTP(15)=95

370 TEAM=0 : FOOD=0 : BULLETS=0 : CLOTHES=0 : SUPPLIES=0 : CASH=0
380 MILES=0 : MA=0 : ML=0 : SEGMENT=0 : SICK=0 : HURT=0
390 PASSED1=0 : ARRIVED=0

495 REM ============================ opening scenario ==========================
500 CLS
505 PRINT "                    WESTWARD HO! 1847"
510 PRINT "                (c) by David H. Ahl, 1986"
515 PRINT
520 PRINT " Your journey over the Oregon Trail takes place in 1847. Starting"
525 PRINT "in Independence, Missouri, you plan to take your family of"
530 PRINT "five over 2040 tough miles to Oregon City."
535 PRINT " Having saved $420 for the trip, you bought a wagon for $70 and"
540 PRINT "now have to purchase the following items:"
545 PRINT
550 PRINT " * Oxen (spending more will buy you a larger and better team which"
555 PRINT "   will be faster so you'll be on the trail for less time)"
560 PRINT " * Food (you'll need ample food to keep up your strength and health)"
565 PRINT " * Ammunition ($1 buys a belt of 50 bullets. You'll need ammo for"
570 PRINT "   hunting and for fighting off attacks by bandits and animals)"
575 PRINT " * Clothing (you'll need warm clothes, especially when you hit the"
580 PRINT "   snow and freezing weather in the mountains)"
585 PRINT " * Other supplies (includes medicine, first-aid supplies, tools, and"
590 PRINT "   wagon parts for unexpected emergencies)"
595 PRINT
600 PRINT " You can spend all your money at the start or save some to spend"
605 PRINT "at forts along the way. However, items cost more at the forts. You"
610 PRINT "can also hunt for food if you run low."
615 PRINT
620 INPUT "Press ENTER when you're ready to go"; ANY$
625 CLS

695 REM ============================ initial purchases ==========================
700 PRINT
705 INPUT "How much do you want to pay for a team of oxen? "; TEAM
710 TEAM=INT(TEAM)
715 IF TEAM<100 THEN PRINT "No one in town has a team that cheap." : GOTO 700
720 IF TEAM<151 THEN GOTO 760
725 PRINT "You choose an honest dealer who tells you that $"; TEAM; " is too much for"
730 PRINT "a team of oxen. He charges you $150 and gives you $"; TEAM-150; " change."
735 TEAM=150

760 PRINT
765 INPUT "How much do you want to spend on food? "; FOOD
770 FOOD=INT(FOOD)
775 IF FOOD>13 THEN GOTO 795
780 PRINT "That won't even get you to the Kansas River ... better spend a bit more."
785 GOTO 760
795 IF TEAM+FOOD>300 THEN PRINT "You won't have any for ammo and clothes." : GOTO 760

820 PRINT
825 INPUT "How much do you want to spend on ammunition? "; BULLETS
830 BULLETS=INT(BULLETS)
835 IF BULLETS<2 THEN PRINT "Better take a bit just for protection." : GOTO 820
840 IF TEAM+FOOD+BULLETS>320 THEN PRINT "That won't leave any money for clothes." : GOTO 820

860 PRINT
865 INPUT "How much do you want to spend on clothes? "; CLOTHES
870 CLOTHES=INT(CLOTHES)
875 IF CLOTHES>24 THEN GOTO 895
880 PRINT "Your family is going to be mighty cold in the mountains."
885 PRINT "Better spend a bit more."
890 GOTO 860
895 IF TEAM+FOOD+BULLETS+CLOTHES>345 THEN PRINT "That leaves nothing for medicine." : GOTO 860

910 PRINT
915 INPUT "How much for medicine, bandages, repair parts, etc.? "; SUPPLIES
920 SUPPLIES=INT(SUPPLIES)
925 IF SUPPLIES<5 THEN PRINT "That's not at all wise." : GOTO 910
930 IF TEAM+FOOD+BULLETS+CLOTHES+SUPPLIES>350 THEN PRINT "You don't have that much money." : GOTO 910

940 CASH=350-TEAM-FOOD-BULLETS-CLOTHES-SUPPLIES
945 PRINT
950 PRINT "You now have $"; CASH; " left."
955 BULLETS=50*BULLETS

958 REM ============================ shooting rank ==============================
960 PRINT
965 PRINT "Please rank your shooting (typing) ability as follows:"
970 PRINT " (1) Ace marksman (2) Good shot (3) Fair to middlin'"
975 PRINT " (4) Need more practice (5) Shaky knees"
980 INPUT "How do you rank yourself? "; SKILL
985 IF (SKILL>0) AND (SKILL<6) THEN GOTO 995
988 PRINT "Please enter 1, 2, 3, 4, or 5."
990 GOTO 980
995 PRINT
996 PRINT " Your trip is about to begin ... "
997 PRINT

998 REM ============================ main loop =================================
1000 IF MILES>2039 THEN ARRIVED=1 : GOTO 7000
1005 SEGMENT=SEGMENT+1
1010 IF SEGMENT>20 THEN GOTO 7800
1015 PRINT
1020 PRINT "Monday, "; DATE$(SEGMENT); ", 1847. You are ";
1025 FOR I=1 TO 15
1030 IF MILES<=MPMARK(I) THEN GOTO 1045
1035 NEXT I
1040 I=15
1045 PRINT PLACE$(I)
1050 IF FOOD<6 THEN PRINT "You're low on food. Better buy some or go hunting soon."
1055 IF (SICK<>1) AND (HURT<>1) THEN GOTO 1120
1060 CASH=CASH-10
1065 IF CASH<0 THEN GOTO 7200
1070 PRINT "Doctor charged $10 for his services to treat your ";
1075 IF SICK=1 THEN PRINT "illness."
1080 IF SICK<>1 THEN PRINT "injuries."
1085 SICK=0 : HURT=0
1090 MILES=INT(MILES)
1095 MA=MILES

1120 PRINT "Total mileage to date is "; INT(MILES+0.5)
1125 MILES=MILES+200+(TEAM-110)/2.5+10*RND
1130 PRINT "Here's what you now have (no. of bullets, $ worth of other items):"
1135 GOSUB 6500
1140 GOSUB 2000
1145 GOSUB 3000
1150 GOSUB 4000
1155 PRINT
1160 GOSUB 5000
1165 PRINT
1170 GOSUB 6000
1175 GOTO 1000

1995 REM ==================== fort, hunt, or push on =============================
2000 NOAMMO=0
2005 IF (SEGMENT/2)<>INT(SEGMENT/2) THEN GOSUB 2400 : RETURN
2010 INPUT "Want to (1) stop at next fort, (2) hunt, or (3) push on? "; X
2015 IF (X<1) OR (X>3) THEN PRINT "Enter a 1, 2, or 3 please." : GOTO 2010
2020 IF X=3 THEN RETURN
2025 IF X=1 THEN GOSUB 2100
2030 IF X=2 THEN GOSUB 2600
2035 IF NOAMMO=1 THEN GOTO 2010
2040 RETURN

2395 REM ---------------------- hunt or continue (odd weeks) ---------------------
2400 INPUT "Would you like to (1) hunt or (2) continue on? "; X
2405 IF (X<1) OR (X>2) THEN PRINT "Enter a 1 or 2 please." : GOTO 2400
2410 IF X=2 THEN RETURN
2415 GOSUB 2600
2420 RETURN

2095 REM --------------------------- stop at a fort -------------------------------
2100 IF CASH>0 THEN GOTO 2130
2105 PRINT "You sing with the folks there and get a good"
2110 PRINT "night's sleep, but you have no money to buy anything."
2115 RETURN
2130 PRINT "What would you like to spend on each of the following;"
2135 INPUT "Food? "; PF
2140 INPUT "Ammunition? "; PB
2145 INPUT "Clothing? "; PC
2150 INPUT "Medicine and supplies? "; PS
2155 PTOTAL=PF+PB+PC+PS
2160 PRINT "The storekeeper tallies up your bill. It comes to $"; PTOTAL
2165 IF CASH<PTOTAL THEN PRINT "Uh, oh. That's more than you have. Better start over." : GOTO 2130
2170 CASH=CASH-PTOTAL
2175 FOOD=FOOD+0.67*PF
2180 BULLETS=BULLETS+33*PB
2185 CLOTHES=CLOTHES+0.67*PC
2190 SUPPLIES=SUPPLIES+0.67*PS
2195 RETURN

2595 REM ------------------------------- hunting ----------------------------------
2600 NOAMMO=0
2605 IF BULLETS>39 THEN GOTO 2630
2610 PRINT "Tough luck. You don't have enough ammo to hunt."
2615 NOAMMO=1
2620 RETURN
2630 MILES=MILES-45
2635 GOSUB 8000
2640 IF BR<=1 THEN GOTO 2670
2645 IF 100*RND<13*BR THEN GOTO 2690
2650 PRINT "Nice shot ... right on target ... good eatin' tonight!"
2655 FOOD=FOOD+24-2*BR
2660 BULLETS=BULLETS-10-3*BR
2665 RETURN
2670 PRINT "Right between the eyes ... you got a big one!"
2675 FOOD=FOOD+26+3*RND
2680 PRINT "Full bellies tonight!"
2685 BULLETS=BULLETS-10-4*RND
2687 RETURN
2690 PRINT "You missed completely ... and your dinner got away."
2695 RETURN

2995 REM ============================== eating ====================================
3000 IF FOOD<5 THEN GOTO 7100
3005 INPUT "Do you want to eat (1) poorly (2) moderately or (3) well? "; MEAL
3010 IF (MEAL<1) OR (MEAL>3) THEN PRINT "Enter a 1, 2, or 3, please." : GOTO 3005
3015 FOOD=FOOD-4-2.5*MEAL
3020 IF FOOD>0 THEN RETURN
3025 IF MEAL=1 THEN RETURN
3030 FOOD=FOOD+4+2.5*MEAL
3035 PRINT "You don't have enough to eat that well."
3040 GOTO 3005

3995 REM ======================== riders on the trail =============================
4000 IF 10*RND > ((MILES/100-4)^2+72)/((MILES/100-4)^2+12)-1 THEN RETURN
4005 XPFX$="" : FRIENDLY=0
4010 IF RND>0.2 THEN XPFX$="don't " : FRIENDLY=1
4015 PRINT
4020 PRINT "Riders ahead! They "; XPFX$; "look hostile."
4025 PRINT "You can (1) run, (2) attack, (3) ignore them, or (4) circle wagons."
4030 INPUT "What do you want to do? "; GT
4035 IF (GT<1) OR (GT>4) THEN PRINT "Please enter 1, 2, 3, or 4." : GOTO 4030
4040 IF RND<0.2 THEN FRIENDLY=1-FRIENDLY
4045 IF FRIENDLY=1 THEN GOTO 4300
4050 IF GT=1 THEN GOTO 4100
4055 IF GT=2 THEN GOTO 4150
4060 IF GT=3 THEN GOTO 4200
4065 GOTO 4250

4095 REM ---- try to run ----
4100 MILES=MILES+20
4105 SUPPLIES=SUPPLIES-7
4110 BULLETS=BULLETS-150
4115 TEAM=TEAM-20
4120 GOTO 4350

4145 REM ---- attack the riders ----
4150 GOSUB 8000
4155 BULLETS=BULLETS-BR*40-80
4160 GOTO 4180

4195 REM ---- ignore the riders ----
4200 IF RND>0.8 THEN PRINT "They did not attack. Whew!" : RETURN
4205 BULLETS=BULLETS-150
4210 SUPPLIES=SUPPLIES-7
4215 GOTO 4350

4245 REM ---- circle the wagons ----
4250 GOSUB 8000
4255 BULLETS=BULLETS-BR*30-80
4260 MILES=MILES-25
4265 GOTO 4180

4179 REM ---- shared shootout outcome (attack or circle wagons) -------------------
4180 IF BR<=1 THEN PRINT "Nice shooting  ...  you drove them off." : GOTO 4350
4185 IF BR<=4 THEN PRINT "Kind of slow with your Colt .45." : GOTO 4350
4190 PRINT "Pretty slow on the draw, partner. You got a nasty flesh wound."
4192 HURT=1
4194 PRINT "You'll have to see the doc soon as you can."
4198 GOTO 4350

4295 REM ---- cost when the riders turn out friendly -------------------------------
4300 IF GT=1 THEN MILES=MILES+15 : TEAM=TEAM-5 : GOTO 4350
4305 IF GT=2 THEN MILES=MILES-5 : BULLETS=BULLETS-100 : GOTO 4350
4310 IF GT=3 THEN GOTO 4350
4315 MILES=MILES-20

4345 REM ---- final messages about the riders ---------------------------------------
4350 IF FRIENDLY=1 THEN PRINT "Riders were friendly, but check for possible losses." : RETURN
4355 PRINT "Riders were hostile. Better check for losses!"
4360 IF BULLETS>=0 THEN RETURN
4365 PRINT
4370 PRINT "Oh, my gosh! They're coming back and you're out of ammo! Your dreams turn to"
4375 PRINT "dust as you and your family are massacred on the prairie."
4380 ARRIVED=0
4385 GOTO 7000

4995 REM ======================= hazards and events ================================
5000 RN=100*RND
5005 FOR I=1 TO 15
5010 IF RN<=EVENTP(I) THEN GOTO 5025
5015 NEXT I
5020 I=16
5025 ON I GOSUB 5100,5150,5200,5250,5300,5350,5400,5450,5500,5550,5600,5650,5700,5750,5800,5850
5030 RETURN

5099 REM ---- wagon breaks down ----
5100 PRINT "Your wagon breaks down. It costs you time and supplies to fix it."
5103 MILES=MILES-15-5*RND
5106 SUPPLIES=SUPPLIES-4
5109 RETURN

5149 REM ---- ox gores your leg ----
5150 PRINT "An ox gores your leg. That slows you down for the rest of the trip."
5153 MILES=MILES-25
5156 TEAM=TEAM-10
5159 RETURN

5199 REM ---- daughter breaks her arm ----
5200 PRINT "Bad luck ... your daughter breaks her arm. You must stop and"
5203 PRINT "make a splint and sling with some of your medical supplies."
5206 MILES=MILES-5-4*RND
5209 SUPPLIES=SUPPLIES-1-2*RND
5212 RETURN

5249 REM ---- ox wanders off ----
5250 PRINT "An ox wanders off and you have to spend time looking for it."
5253 MILES=MILES-17
5256 RETURN

5299 REM ---- son gets lost ----
5300 PRINT "Your son gets lost and you spend half a day searching for him."
5303 MILES=MILES-10
5306 RETURN

5349 REM ---- contaminated water ----
5350 PRINT "Nothing but contaminated and stagnant water near the trail."
5353 PRINT "You lose time looking for a clean spring or creek."
5356 MILES=MILES-2-10*RND
5359 RETURN

5399 REM ---- heavy rain, or cold weather in the mountains ----
5400 IF MILES>950 THEN GOTO 5430
5403 PRINT "Heavy rains. Traveling is slow in the mud and you break your spare"
5406 PRINT "ox yoke using it to pry your wagon out of the mud. Worse yet, some"
5409 PRINT "of your ammo is damaged by the water."
5412 MILES=MILES-5-10*RND
5415 SUPPLIES=SUPPLIES-7
5418 BULLETS=BULLETS-400
5421 FOOD=FOOD-5
5424 RETURN
5430 PRINT "Cold weather ... Brrrrrrr! ... You ";
5433 COLD=0
5436 IF CLOTHES<11+2*RND THEN PRINT "don't "; : COLD=1
5439 PRINT "have enough clothing to keep warm."
5442 IF COLD=0 THEN RETURN
5445 GOSUB 5900
5448 RETURN

5449 REM ---- bandits attacking ----
5450 PRINT "Bandits attacking!"
5453 GOSUB 8000
5456 BULLETS=BULLETS-20*BR
5459 IF BULLETS>0 THEN GOTO 5470
5462 CASH=INT(CASH/3)
5465 PRINT "You try to drive them off but you run out of bullets."
5466 PRINT "They grab as much cash as they can find."
5467 GOTO 5480
5470 IF BR<=1 THEN GOTO 5495
5480 PRINT "You get shot in the leg  ...  and they grab one of your oxen."
5483 HURT=1
5486 TEAM=TEAM-10
5489 SUPPLIES=SUPPLIES-2
5492 PRINT "Better have a doc look at your leg ... and soon!"
5493 RETURN
5495 PRINT "That was the quickest draw outside of Dodge City."
5497 PRINT "You got at least one and drove 'em off."
5499 RETURN

5499 REM (line number reused as comment marker avoided below)
5500 PRINT "You have a fire in your wagon. Food and supplies are damaged."
5503 MILES=MILES-15
5506 FOOD=FOOD-20
5509 BULLETS=BULLETS-400
5512 SUPPLIES=SUPPLIES-12*RND
5515 RETURN

5549 REM ---- lost in heavy fog ----
5550 PRINT "You lose your way in heavy fog. Time lost regaining the trail."
5553 MILES=MILES-10-5*RND
5556 RETURN

5599 REM ---- rattlesnake bite ----
5600 PRINT "You come upon a rattlesnake and before you are able to get your gun"
5603 PRINT "out, it bites you."
5606 BULLETS=BULLETS-10
5609 SUPPLIES=SUPPLIES-2
5612 IF SUPPLIES>=0 THEN GOTO 5620
5615 PRINT "You have no medical supplies left, and you die of poison."
5617 PRINT "Your family tries to push on, but finds the going too rough without you."
5618 ARRIVED=0
5619 GOTO 7000
5620 PRINT "Fortunately, you acted quickly, sucked out the poison, and"
5623 PRINT "treated the wound. It is painful, but you'll survive."
5626 RETURN

5649 REM ---- wagon swamped fording a river ----
5650 PRINT "Your wagon gets swamped fording a river; you lose food and clothes."
5653 MILES=MILES-20-20*RND
5656 FOOD=FOOD-15
5659 CLOTHES=CLOTHES-10
5662 RETURN

5699 REM ---- wild animals attack in the night ----
5700 PRINT "You're sound asleep and you hear a noise ... get up to investigate."
5703 PRINT "It's wild animals! They attack you!"
5706 GOSUB 8000
5709 IF BULLETS>39 THEN GOTO 5720
5712 PRINT "You're almost out of ammo; can't reach more."
5715 PRINT "The wolves come at you biting and clawing."
5717 HURT=1
5718 GOTO 7400
5720 IF BR>2 THEN GOTO 5730
5723 PRINT "Nice shooting, pardner ... They didn't get much."
5726 RETURN
5730 PRINT "Kind of slow on the draw. The wolves got at your food and clothes."
5733 BULLETS=BULLETS-20*BR
5736 CLOTHES=CLOTHES-2*BR
5739 FOOD=FOOD-4*BR
5742 RETURN

5749 REM ---- fierce hailstorm ----
5750 PRINT "You're caught in a fierce hailstorm; ammo and supplies are damaged."
5753 MILES=MILES-5-10*RND
5756 BULLETS=BULLETS-150
5759 SUPPLIES=SUPPLIES-2-2*RND
5762 RETURN

5799 REM ---- trouble from not eating well enough ----
5800 IF MEAL=1 THEN GOSUB 5900 : RETURN
5803 IF (MEAL=2) AND (RND>0.25) THEN GOSUB 5900 : RETURN
5806 IF (MEAL=3) AND (RND>0.5) THEN GOSUB 5900 : RETURN
5809 GOTO 5850

5849 REM ---- helpful Indians show you where to find more food ----
5850 PRINT "Helpful Indians show you where to find more food."
5853 FOOD=FOOD+7
5856 RETURN

5895 REM ---------------------------- illness routine ------------------------------
5900 IF 100*RND<10+35*(MEAL-1) THEN GOTO 5940
5905 IF 100*RND<100-(40/4^(MEAL-1)) THEN GOTO 5960
5910 PRINT "Serious illness in the family. You'll have to stop and see a doctor"
5913 PRINT "soon. For now, your medicine will work."
5916 SUPPLIES=SUPPLIES-5
5919 SICK=1
5922 GOTO 5980
5940 PRINT "Mild illness. Your own medicine will cure it."
5943 MILES=MILES-5
5946 SUPPLIES=SUPPLIES-1
5949 GOTO 5980
5960 PRINT "The whole family is sick. Your medicine will probably work okay."
5963 MILES=MILES-5
5966 SUPPLIES=SUPPLIES-2.5
5980 IF SUPPLIES>0 THEN RETURN
5983 PRINT "  ... if only you had enough."
5986 GOTO 7250

5995 REM ============================== mountains ==================================
6000 IF MILES<=975 THEN RETURN
6005 IF 10*RND > 9-((MILES/100-15)^2+72)/((MILES/100-15)^2+12) THEN GOTO 6050
6010 PRINT "You're in rugged mountain country."
6015 IF RND>0.1 THEN GOTO 6030
6018 PRINT "You get lost and lose valuable time trying to find the trail."
6021 MILES=MILES-60
6024 GOTO 6050
6030 IF RND>0.11 THEN GOTO 6045
6033 PRINT "Trail cave in damages your wagon. You lose time and supplies."
6036 MILES=MILES-20-30*RND
6039 BULLETS=BULLETS-200
6042 SUPPLIES=SUPPLIES-3
6043 GOTO 6050
6045 PRINT "The going is really slow; oxen are very tired."
6048 MILES=MILES-45-50*RND

6049 REM ---- South Pass: 80% blizzard chance, but only the first time through ----
6050 IF PASSED1=1 THEN GOTO 6070
6053 PASSED1=1
6056 IF RND<0.8 THEN GOTO 6100
6059 PRINT "You made it safely through the South Pass....no snow!"

6069 REM ---- Blue Mountains: 70% blizzard chance, every time ----
6070 IF RND<0.7 THEN GOTO 6100
6073 RETURN

6099 REM ---- blizzard ----
6100 PRINT "Blizzard in the mountain pass. Going is slow; supplies are lost."
6103 MILES=MILES-30-40*RND
6106 FOOD=FOOD-12
6109 BULLETS=BULLETS-200
6112 SUPPLIES=SUPPLIES-5
6115 IF CLOTHES<18+2*RND THEN GOSUB 5900
6118 RETURN

6495 REM ---------------------------- inventory ------------------------------------
6500 IF FOOD<0 THEN FOOD=0 ELSE FOOD=INT(FOOD)
6503 IF BULLETS<0 THEN BULLETS=0 ELSE BULLETS=INT(BULLETS)
6506 IF CLOTHES<0 THEN CLOTHES=0 ELSE CLOTHES=INT(CLOTHES)
6509 IF SUPPLIES<0 THEN SUPPLIES=0 ELSE SUPPLIES=INT(SUPPLIES)
6512 PRINT "Cash: $"; CASH; "   Food: "; FOOD; "   Bullets: "; BULLETS
6515 PRINT "Clothes: "; CLOTHES; "   Supplies: "; SUPPLIES
6518 PRINT
6521 RETURN

6995 REM ============================ end of the trail =============================
7000 IF ARRIVED=1 THEN GOTO 7500
7005 PRINT
7010 PRINT "Some travelers find the bodies of you and your"
7015 PRINT "family the following spring. They give you a decent"
7020 PRINT "burial and notify your next of kin."
7025 PRINT
7030 GOSUB 7700
7035 PRINT "At the time of your unfortunate demise, you had been on the trail"
7040 PRINT "for "; MOS; " months and "; DYS; " days and had covered "; INT(MILES+70); " miles."
7045 PRINT " You had a few supplies left:"
7050 GOSUB 6500
7055 PRINT
7060 GOTO 7900

7099 REM ---- starve to death (out of food) -----------------------------------------
7100 PRINT "You run out of food and starve to death."
7105 ARRIVED=0
7110 GOTO 7000

7199 REM ---- can't afford the doctor ------------------------------------------------
7200 CASH=0
7205 PRINT "You need a doctor badly, but can't afford one."
7210 GOTO 7400

7249 REM ---- out of medical supplies --------------------------------------------------
7250 PRINT "You have run out of all medical supplies."
7255 GOTO 7400

7399 REM ---- die of injury or illness (shared by several death paths) -----------------
7400 PRINT
7405 PRINT "The wilderness is unforgiving and you die of ";
7410 IF HURT=1 THEN PRINT "your injuries." : GOTO 7450
7415 PRINT "pneumonia."
7450 PRINT "Your family tries to push on, but finds the going too rough without you."
7455 ARRIVED=0
7460 GOTO 7000

7499 REM ---- you made it! ------------------------------------------------------------
7500 ML=(2040-MA)/(MILES-MA)
7505 FOOD=FOOD+(1-ML)*(8+5*MEAL)
7510 PRINT "You finally arrived at Oregon City after 2040 long miles."
7515 PRINT "You're exhausted and haggard, but you made it! A real pioneer!"
7520 GOSUB 7700
7525 PRINT "You've been on the trail for "; MOS; " months and "; DYS; " days."
7530 PRINT "You have few supplies remaining:"
7535 GOSUB 6500
7540 PRINT
7545 PRINT "President James A. Polk sends you his heartiest"
7550 PRINT "congratulations and wishes you a prosperous life in your new home."
7555 GOTO 7900

7699 REM -------------------------- elapsed trail time helper --------------------------
7700 DAYS=INT(14*(SEGMENT+ML))
7705 MOS=INT(DAYS/30.5)
7710 DYS=INT(DAYS-30.5*MOS)
7715 RETURN

7799 REM ---- oxen worn out / too long on the trail ------------------------------------
7800 PRINT "Your oxen are worn out and can't go another step. You try pushing"
7805 PRINT "ahead on foot, but it is snowing heavily and everyone is exhausted."
7810 PRINT
7815 PRINT "You stumble and can't get up...."
7820 ARRIVED=0
7825 GOTO 7000

7899 REM ---- play-again / end query -----------------------------------------------------
7900 PRINT
7905 INPUT "Press Enter to End"; ANY$
7910 END

7995 REM ------------------------- shooting minigame -------------------------------------
8000 RN=1+INT(4*RND)
8005 PRINT "Type "; W$(RN); " "
8010 T1=TIMER
8015 INPUT ANS$
8020 IF (ANS$<>W$(RN)) AND (ANS$<>W$(RN+4)) THEN PRINT "Nope. Try again. Type "; W$(RN); " " : GOTO 8015
8025 T2=TIMER
8030 BR=(T2-T1)-SKILL-1
8035 RETURN
