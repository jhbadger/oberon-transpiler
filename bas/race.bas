10 REM
20 REM  THE LONGEST AUTOMOBILE RACE -- NEW YORK TO PARIS, 1908
30 REM  Faithfully adapted for basic.mod from David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition)
50 REM  Route, weather/road tables and breakdown tables reconstructed
60 REM  from Ahl's original book listing (the Small Basic port reads
70 REM  them from external weather.txt/breakdown.txt files not present
80 REM  in this port's source tree).
90 REM
100 REM ============================ location table ==================================
110 DIM LOC$(20), REGION$(20), WXCODE(20), RDCODE(20), EXPDAYS(20), LEGDIST(20)
120 FOR I = 1 TO 20
130   READ LOC$(I), REGION$(I), WXCODE(I), RDCODE(I), EXPDAYS(I), LEGDIST(I)
140 NEXT I
150 DATA "New York","New York",2,1,8,897
160 DATA "Kendallville","Indiana",1,1,6,166
170 DATA "Chicago","Illinois",3,2,7,634
180 DATA "Omaha","Nebraska",6,3,4,482
190 DATA "Laramie","Wyoming",2,3,7,467
200 DATA "Ogden","Utah",6,1,8,1237
210 DATA "San Francisco","California",5,1,8,0
220 DATA "Seattle","Washington",5,1,8,0
230 DATA "Valdez","Alaska",5,1,8,0
240 DATA "Seattle","Washington",5,1,25,0
250 DATA "Kobe","Japan",4,4,4,350
260 DATA "Tsuruga","Japan",4,1,7,0
270 DATA "Vladivostok","Russia",3,5,15,558
280 DATA "Tsitsihar","Manchuria",5,6,10,659
290 DATA "Chita","Russia",3,3,8,1116
300 DATA "Kansk","Russia",4,3,6,1075
310 DATA "Omsk","Russia",5,1,7,820
320 DATA "Perm","Russia",3,2,14,1090
330 DATA "St. Petersburg","Russia",3,1,8,1575
340 DATA "Paris","France",6,1,0,0
350 REM
360 REM -------------------------- road and weather text ------------------------------
370 DIM CD$(6), WD$(6)
380 FOR I = 1 TO 6 : READ CD$(I) : NEXT I
390 DATA "hard packed gravel","muddy ruts","slightly improved wagon tracks"
400 DATA "built for narrow carts","practically non-existent","horrible"
410 FOR I = 1 TO 6 : READ WD$(I) : NEXT I
420 DATA "blizzard conditions","snow and sleet","rain"
430 DATA "cloudy with a chance of rain","mixed","sunny and dry"
440 REM
450 REM -------------------------- mechanical breakdown table --------------------------
460 DIM FAD$(18), FBD$(18), FCD$(18), FIXHRS(2,18), FIXCOST(2,18)
470 FOR I = 1 TO 18
480   READ FAD$(I), FBD$(I), FIXHRS(1,I), FIXCOST(1,I), FCD$(I), FIXHRS(2,I), FIXCOST(2,I)
490 NEXT I
500 DATA "a blown tire","patch the hole",2,1,"put on a new tire",2,7
510 DATA "a skipping cylinder","put in new spark plugs",1,2,"grind the cylinder",8,2
520 DATA "a rough running engine","tune it up",4,5,"",0,0
530 DATA "a binding axle bearing","regrind the bearing",8,2,"put in a new one",4,8
540 DATA "a cracked spring","put in a new spring",8,26,"weld an angle iron brace on it",8,4
550 DATA "a cracked wheel","put on a new wheel",2,42,"weld a brace on it",8,4
560 DATA "a slipping clutch","adjust the clutch",4,4,"put in a new plate",8,54
570 DATA "a stripped gear","weld the teeth",16,6,"put in a new gear",8,24
580 DATA "a radiator leak","weld a patch on it",4,2,"",0,0
590 DATA "failing brakes","replace the linings",8,7,"",0,0
600 DATA "a crack in the countershaft housing","put in a new housing",24,40,"",0,0
610 DATA "a broken drive pinion","weld the teeth",16,6,"put in a new pinion",8,18
620 DATA "a broken rear axle","put in a new axle",16,68,"",0,0
630 DATA "a cracked transmission housing","order a new one from the factory",24,60,"",0,0
640 DATA "a broken motor support","fashion a replacement from scrap iron",16,16,"",0,0
650 DATA "a worn clutch shaft","put in a new clutch shaft",8,28,"",0,0
660 DATA "a cracked frame","install angle iron braces",24,26,"",0,0
670 DATA "total transmission failure","order a new one from the factory",40,225,"",0,0
680 REM
695 REM ============================ opening scenario =================================
700 CLS
710 PRINT "                  THE LONGEST AUTOMOBILE RACE, 1908"
720 PRINT "                       (c) by David H. Ahl, 1986"
730 PRINT
740 PRINT " In this program, you are the captain of the Thomas Flyer team. It is"
750 PRINT "your job to get the car from New York to Paris -- east to west -- as"
760 PRINT "quickly as possible. The race starts on February 12, 1908."
770 PRINT "   You must overcome many problems: bad weather, accidents, mechanical"
780 PRINT "breakdowns, fatigue, and a lack of gas stations."
790 PRINT "   For each leg of the trip, buy as much gas as you need, but no more."
800 PRINT "Your car gets approximately 14 mpg, although this will vary. You will"
810 PRINT "carry what fuel you can and ship the rest ahead by rail to be held for"
820 PRINT "you along your route."
830 PRINT "   Your car has a top speed of 54 mph. However, the probability of a"
840 PRINT "breakdown increases substantially at speeds over 35 mph. Likewise,"
850 PRINT "driving more than six hours a day increases your chance of an accident."
860 PRINT "But don't forget, this IS a race."
870 PRINT "   If you get stuck, you can pay someone to pull you out (costs money)"
880 PRINT "or try to get out on your own (costs time)."
890 PRINT "   You can repair a mechanical problem on the spot or nurse the car"
900 PRINT "along and hope it holds. Either choice has risks."
910 PRINT "   If you run out of money, you can wire Mr. Thomas back at the factory"
920 PRINT "for more, but your telegram must be worded carefully and politely, and"
930 PRINT "must be in ALL CAPITAL LETTERS -- that's how telegrams were sent."
940 PRINT
950 INPUT "Press ENTER to start your engine!"; ANY$
960 CLS
970 REM
995 REM ============================ initial values ====================================
1000 CASH=1000 : GASGAL=0 : GASFACTOR=.25
1010 SEG=0 : TOTMILES=0 : TOTDAYS=0 : LEADERDAYS=0 : LASTPRTDAY=0
1020 BROKENPART=0 : WIRECOUNT=0 : HOURSTOTAL=0
1030 REM
1495 REM ============================ main loop ==========================================
1500 SEG=SEG+1
1510 WEATHER=WXCODE(SEG) : ROADIDX=RDCODE(SEG) : GOALDAYS=EXPDAYS(SEG) : GOALDIST=LEGDIST(SEG)
1520 LEADERDAYS=LEADERDAYS+GOALDAYS
1530 GOSUB 2300
1540 PRINT
1550 PRINT "You are at "; LOC$(SEG); ", "; REGION$(SEG); "."
1560 PRINT "You currently have ";
1570 AMT=CASH : GOSUB 4000
1580 PRINT
1590 IF SEG=1 THEN GOTO 1800
1600 REM
1605 REM -------------------------- previous leg wrap-up --------------------------------
1610 IF BROKENPART=0 THEN GOTO 1650
1620 PRINT "A sympathetic garage owner will fix "; FAD$(BROKENPART); " here."
1630 BROKENPART=0
1640 DELAYDAYS=INT(1+3*RND) : PRINT "It will take "; DELAYDAYS; " day(s)." : GOSUB 3600
1650 IF (SEG>7) AND (SEG<11) THEN GOSUB 3400 : GOTO 1500
1660 PRINT
1670 PRINT "You have driven "; INT(TOTMILES); " miles in "; TOTDAYS; " days."
1680 IF SEG=20 THEN GOTO 9000
1690 IF TOTDAYS<LEADERDAYS THEN GOTO 1710
1695 IF TOTDAYS=LEADERDAYS THEN PRINT "You and the Italian Zust are running even with each other." : GOTO 1800
1700 PRINT "The race leader passed this point "; TOTDAYS-LEADERDAYS; " day(s) ago." : GOTO 1800
1710 PRINT "You are the race leader and are "; LEADERDAYS-TOTDAYS; " day(s) ahead."
1800 REM
1805 REM -------------------------- set up the next leg ----------------------------------
1810 IF (SEG=7) OR (SEG=12) THEN GOSUB 3400 : GOTO 1500
1820 PRINT "Roads to the west of here are "; CD$(ROADIDX); "."
1830 PRINT "The weather forecast is "; WD$(WEATHER); "."
1840 PRINT "You set a goal of making "; GOALDIST; " miles in the next "; GOALDAYS-2; " days."
1850 GOSUB 2000
1860 GOSUB 2100
1870 GOSUB 2200
1880 LEGMILES=0
1890 REM
1895 REM -------------------------- day-by-day driving loop ------------------------------
1900 DELAYDAYS=1 : GOSUB 3600
1910 GOSUB 2500
1920 GOSUB 2900
1930 GOSUB 3100
1940 DAYMILES=SPEED*HOURS*PWEATHER
1950 LEGMILES=LEGMILES+DAYMILES : TOTMILES=TOTMILES+DAYMILES
1960 GASUSED=.07*DAYMILES*(.8+.4*RND)
1970 IF GASUSED<GASGAL THEN GASGAL=GASGAL-GASUSED : GOTO 1995
1980 GOSUB 2300
1985 PRINT "You ran out of gas on the road."
1990 GASFACTOR=.33 : GOSUB 2000 : GASGAL=GASGAL-GASUSED
1995 IF LEGMILES>=GOALDIST THEN GOTO 1500 ELSE GOTO 1900
1996 REM
1997 REM ================================================================================
1998 REM  Subroutines below
1999 REM ================================================================================
2000 REM
2005 REM -------------------------- buy gas and oil --------------------------------------
2010 GASPRICE=GASFACTOR*(.7+.6*RND) : GASFACTOR=.25
2020 PRINT "Gas costs "; INT(100*GASPRICE); " cents per gallon here."
2030 INPUT "How many gallons do you want for the segment ahead? "; GASGAL
2040 BILL=GASGAL*GASPRICE
2050 PRINT "That will cost $";
2060 AMT=BILL : GOSUB 4000
2070 PRINT
2080 GOSUB 3700
2090 IF PAID=1 THEN RETURN
2095 IF CASH<2 THEN DEATH$="Your car won't run on fumes. It's all over." : GOTO 9100
2096 GASGAL=INT(CASH/GASPRICE)
2097 PRINT "Sorry, you could only get "; GASGAL; " gallons."
2098 RETURN
2099 REM
2100 REM -------------------------- choose driving speed ---------------------------------
2110 INPUT "How fast (mph) do you want to drive? "; SPEED
2120 IF SPEED>54 THEN PRINT "Top speed of your car is only 54 mph." : GOTO 2110
2130 IF SPEED<8 THEN PRINT "At that rate, you'll never get there." : GOTO 2110
2140 IF (WEATHER<3) AND (SPEED>30) THEN PRINT "That's too fast for these weather and road conditions." : GOTO 2110
2150 PBREAK=SPEED*SPEED/7000
2160 RETURN
2170 REM
2200 REM -------------------------- choose driving hours per day -------------------------
2205 WARNED=0
2210 INPUT "How many hours do you want to drive each day? "; HOURS
2220 IF WARNED=1 THEN GOTO 2260
2230 IF HOURS>8 THEN PRINT "That's too much for both you and your car." : GOTO 2210
2240 IF HOURS<2 THEN PRINT "No one is that lazy!" : GOTO 2210
2250 HOURSTOTAL=HOURSTOTAL+HOURS
2251 IF (SEG<=2) OR (HOURSTOTAL/SEG<=7.55) THEN GOTO 2260
2252 PRINT "You've been pushing yourself and your crew pretty hard."
2253 PRINT "You should probably back off a bit."
2254 WARNED=1 : GOTO 2210
2260 PFATIGUE=(HOURS*HOURS*HOURS)/1000-.15
2270 IF PFATIGUE<.01 THEN PFATIGUE=.01
2280 RETURN
2290 REM
2300 REM -------------------------- print the date (once per day) ------------------------
2310 IF LASTPRTDAY=TOTDAYS THEN RETURN
2320 GOSUB 2400
2330 RETURN
2340 REM
2400 REM -------------------------- compute month and day from TOTDAYS -------------------
2405 IF TOTDAYS<19 THEN MONTH$="February" : MDAY=TOTDAYS+11 : GOTO 2480
2410 IF TOTDAYS<50 THEN MONTH$="March" : MDAY=TOTDAYS-18 : GOTO 2480
2415 IF TOTDAYS<80 THEN MONTH$="April" : MDAY=TOTDAYS-49 : GOTO 2480
2420 IF TOTDAYS<111 THEN MONTH$="May" : MDAY=TOTDAYS-79 : GOTO 2480
2425 IF TOTDAYS<141 THEN MONTH$="June" : MDAY=TOTDAYS-110 : GOTO 2480
2430 IF TOTDAYS<172 THEN MONTH$="July" : MDAY=TOTDAYS-140 : GOTO 2480
2435 IF TOTDAYS<203 THEN MONTH$="August" : MDAY=TOTDAYS-171 : GOTO 2480
2440 PRINT
2445 PRINT "It's September 1 and the winning car crossed the finish line in Paris"
2450 PRINT "over a month ago. Your factory refuses to give you any more money to"
2455 PRINT "continue. Better luck next time."
2460 DEATH$="You ran out of time -- the race passed you by." : GOTO 9100
2480 PRINT
2485 PRINT "Date: "; MONTH$; " "; MDAY; ", 1908"
2490 LASTPRTDAY=TOTDAYS
2495 RETURN
2499 REM
2500 REM ============================ weather subroutine =================================
2505 IF WEATHER=1 THEN GOTO 2600
2510 IF WEATHER=2 THEN GOTO 2650
2515 IF WEATHER=3 THEN GOTO 2680
2520 IF WEATHER=6 THEN GOTO 2760
2525 REM -- cloudy or mixed (WEATHER=4 or 5) --
2530 R=RND
2535 IF R>.08 THEN PWEATHER=.4+.4*RND : RETURN
2540 GOSUB 2300
2545 IF R<.01 THEN GOTO 2670
2550 GOTO 2700
2555 REM
2600 REM -- heavy snow / blizzard --
2605 R=RND
2610 IF R<.33 THEN GOTO 2620
2615 IF R>.83 THEN GOTO 2635
2617 PWEATHER=.14+.17*RND : RETURN
2620 GOSUB 2300
2625 PWEATHER=.03+.08*RND
2627 PRINT "Blizzard conditions. Tough going today."
2630 RETURN
2635 GOSUB 2300
2640 PWEATHER=.05+.1*RND
2645 PRINT "You're stuck in a huge snow drift."
2647 GOSUB 2800
2648 RETURN
2650 REM -- ordinary snow --
2655 IF RND>=.1 THEN PWEATHER=.3+.4*RND : RETURN
2660 PWEATHER=.15+.1*RND
2662 GOSUB 2300
2664 PRINT "You have skidded into a ditch."
2666 GOSUB 2800
2668 RETURN
2670 REM -- unexpected downpour, bogged in mud (shared target) --
2672 PRINT "An unexpected downpour!"
2675 REM -- rainy weather bogged-in-mud landing point --
2680 IF RND>=.2 THEN PWEATHER=.35+.4*RND : RETURN
2685 GOSUB 2300
2690 PWEATHER=.02+.04*RND
2695 PRINT "You are totally bogged down in the mud."
2697 GOSUB 2800
2698 RETURN
2700 REM -- river ahead, no bridge --
2705 PRINT "River ahead with no bridge. Some locals tell you there is a bridge"
2710 PRINT "'some distance' north. They also offer to take you across by boat"
2715 BILL=3+2*INT(3*RND)
2720 PRINT "for $"; BILL; ". Want to go by boat? "
2725 GOSUB 4100
2730 IF YES=0 THEN GOTO 2745
2735 GOSUB 3700
2740 IF PAID=0 THEN GOTO 2745
2742 PRINT "They got you across in "; 2+INT(3*RND); " hours."
2743 PWEATHER=.3
2744 RETURN
2745 DELAYDAYS=INT(1+2*RND)
2750 PRINT "It took "; DELAYDAYS; " day(s) for you to drive north and find the bridge."
2755 GOSUB 3600
2756 RETURN
2760 REM -- clear and sunny --
2765 IF RND>=.025 THEN PWEATHER=.45+.5*RND : RETURN
2770 GOSUB 2300
2775 GOTO 2700
2780 REM
2800 REM -------------------------- stuck: pay a farmer or dig out yourselves -------------
2810 BILL=5*INT(1+4*RND)
2820 PRINT "A farmer offers to pull you out for $"; BILL; ". Do you want to pay him? "
2830 GOSUB 4100
2840 IF YES=0 THEN GOTO 2880
2850 GOSUB 3700
2860 IF PAID=0 THEN GOTO 2880
2865 PULLHRS=INT(1.5+5*RND)
2867 PRINT "It took "; PULLHRS; " hours for him to pull you out."
2870 IF PULLHRS<5 THEN RETURN
2872 DELAYDAYS=1 : GOSUB 3600 : PWEATHER=PWEATHER*1.5
2875 RETURN
2880 DELAYDAYS=INT(1+1.3*RND)
2885 PRINT "It took "; DELAYDAYS; " day(s) for you and your mechanic to pull the"
2887 PRINT "car out by yourselves."
2890 GOSUB 3600
2892 PWEATHER=PWEATHER*1.5
2895 RETURN
2899 REM
2900 REM ============================ mechanical breakdown subroutine ====================
2905 IF RND<=PBREAK THEN GOTO 2915
2910 RETURN
2915 PROBLEM=INT(1+15*RND)
2920 IF PROBLEM>13 THEN PROBLEM=INT(14+5*RND)
2925 GOSUB 2300
2930 PRINT "Uh oh. You have a problem. It's "; FAD$(PROBLEM); "."
2935 PRINT "Here's what you can do about the problem:"
2940 PRINT "   (1) Try to keep going with it"
2945 PRINT "   (2) "; FBD$(PROBLEM); ", cost $";
2950 AMT=FIXCOST(1,PROBLEM) : GOSUB 4000 : PRINT
2955 A1=1 : A2=2
2960 IF FCD$(PROBLEM)="" THEN GOTO 2975
2965 PRINT "   (3) "; FCD$(PROBLEM); ", cost $";
2970 AMT=FIXCOST(2,PROBLEM) : GOSUB 4000 : PRINT
2972 A2=3
2975 INPUT "Which would you like to do? "; CHOICE
2980 ANUM=CHOICE : GOSUB 4200 : CHOICE=ANUM
2985 IF CHOICE=1 THEN GOTO 3040
2990 REM -- pay to repair it now --
2995 OPT=CHOICE-1
3000 FIXTIME=FIXHRS(OPT,PROBLEM)
3005 IF FIXTIME>=8 THEN GOTO 3020
3010 IF FIXTIME>=5 THEN DELAYDAYS=1 : GOSUB 3600 : PWEATHER=PWEATHER*1.5
3015 GOTO 3030
3020 FIXTIME=FIXTIME/8 : DELAYDAYS=FIXTIME
3022 PWEATHER=PWEATHER*1.5
3025 GOSUB 3600
3030 BILL=FIXCOST(OPT,PROBLEM)
3031 IF FIXTIME=1 THEN PRINT "Repairs will take 1 "; ELSE PRINT "Repairs will take "; FIXTIME; " ";
3032 IF FIXHRS(OPT,PROBLEM)<8 THEN PRINT "hour(s) and will cost $"; ELSE PRINT "day(s) and will cost $";
3033 AMT=BILL : GOSUB 4000 : PRINT
3034 GOSUB 3700
3035 IF PAID=1 THEN RETURN
3040 REM -- nurse it along --
3045 PRINT "You try to nurse the car along to the next major city."
3050 IF BROKENPART<>0 THEN GOTO 3080
3055 IF RND<=.4 THEN GOTO 3090
3060 PRINT
3065 PRINT "Unfortunately, it just won't make it and reluctantly you admit defeat."
3070 DEATH$="A breakdown finally stranded you for good." : GOTO 9100
3080 PRINT "But with the other problem you just can't make it and reluctantly"
3082 PRINT "you admit defeat."
3084 DEATH$="Two unrepaired breakdowns at once finally stranded you." : GOTO 9100
3090 PRINT "It looks like you'll make it but at a drastically reduced speed."
3095 PWEATHER=PWEATHER*.5 : BROKENPART=PROBLEM
3097 RETURN
3099 REM
3100 REM ============================ accident and special situations ====================
3105 IF RND<=PFATIGUE THEN GOTO 3115
3110 GOTO 3200
3115 GOSUB 2300
3120 PRINT "You dozed off and your car has run ";
3125 K=INT(1+4*RND)
3130 IF K=1 THEN PRINT "into a tree." : DELAYDAYS=2 : BILL=24 : GOTO 3160
3135 IF K=2 THEN PRINT "off the road." : DELAYDAYS=1 : BILL=12 : GOTO 3160
3140 IF K=3 THEN PRINT "into a gaping hole." : DELAYDAYS=1 : BILL=18 : GOTO 3160
3145 PRINT "into a farmer's wagon." : DELAYDAYS=2 : BILL=25
3160 PRINT "You can try to fix it or get a tow to the next village for $15.00"
3165 PRINT "Want to try to bang out the damage on the spot? "
3170 GOSUB 4100
3175 IF YES=1 THEN GOTO 3190
3180 PRINT "The tow costs $15 and the repairs cost $";
3182 AMT=BILL : GOSUB 4000 : PRINT
3184 BILL=BILL+15
3186 GOSUB 3700
3188 IF PAID=1 THEN GOTO 3200
3189 PRINT "The locals impound your car for your unpaid debt."
3189 DEATH$="Your unpaid debts caught up with you." : GOTO 9100
3190 IF DELAYDAYS=1 THEN PRINT "You finally manage to do it but it takes 1 day." ELSE PRINT "You finally manage to do it but it takes "; DELAYDAYS; " days."
3192 PWEATHER=PWEATHER*1.5
3194 GOSUB 3600
3200 REM -------------------------- railroad ties (rough terrain) ------------------------
3205 IF (SEG<>2) AND (SEG<>5) AND (SEG<>13) AND (SEG<>14) THEN GOTO 3250
3210 IF RND>.4 THEN GOTO 3250
3215 GOSUB 2300
3220 PRINT "In this area of terrible roads, you can save some time by driving on"
3222 PRINT "the railroad tracks. However, it is murder on your wheels, tires,"
3224 PRINT "and whole car."
3226 PRINT "Want to drive on the tracks? "
3228 GOSUB 4100
3230 IF YES=0 THEN GOTO 3250
3235 PWEATHER=PWEATHER*1.7 : PBREAK=PBREAK*1.25
3250 REM -------------------------- no grease (central Russia) ----------------------------
3255 IF (SEG<>15) AND (SEG<>16) THEN GOTO 3299
3260 IF RND>.2 THEN GOTO 3299
3265 GOSUB 2300
3270 PRINT "Your differential is dry and there is no grease available here."
3272 PRINT "However, you can get Vaseline."
3274 PRINT "Want to use it in place of grease? "
3276 GOSUB 4100
3280 IF YES=0 THEN PWEATHER=PWEATHER*.5 : GOTO 3299
3285 PRINT "Okay, you buy 20 jars for $4.00"
3290 CASH=CASH-4
3299 RETURN
3300 REM
3400 REM ============================ ocean voyage subroutine ============================
3405 DELAYDAYS=INT(1+3.5*RND)
3410 IF SEG=12 THEN GOTO 3480
3415 IF SEG=10 THEN GOTO 3460
3420 IF SEG=9 THEN GOTO 3450
3425 IF SEG=8 THEN GOTO 3440
3430 PRINT "You're stuck in port for "; DELAYDAYS+1; " days before you can get a"
3432 PRINT "steamer for Seattle. You use the time to get new countershaft housings,"
3433 PRINT "springs, wheels, drive chains, and tires."
3434 IF CASH<=300 THEN PRINT "These were all furnished by the local Thomas Flyer dealer." : GOTO 3436
3435 PRINT "The cost of these items is $164.00" : CASH=CASH-164
3436 DELAYDAYS=DELAYDAYS+1 : TOTDAYS=TOTDAYS+3
3437 GOSUB 3600 : GOSUB 3900
3438 RETURN
3440 PRINT "It took 3 days on the steamer. The next steamer for Valdez leaves in"
3441 PRINT DELAYDAYS; " days. Nothing to do but wait."
3442 GOSUB 3600 : GOSUB 3900
3443 TOTDAYS=TOTDAYS+7
3444 RETURN
3450 PRINT "The steamer made many stops up the coast and it took 7 days. It is"
3451 PRINT "apparent that the race organizers have never been in Alaska and have"
3452 PRINT "no idea it is impossible to drive on the snow and ice at all, much"
3453 PRINT "less across the Bering Strait to Russia. You'll have to return to"
3454 PRINT "Seattle. Next steamer goes in "; DELAYDAYS; " days."
3455 GOSUB 3600 : GOSUB 3900
3456 TOTDAYS=TOTDAYS+7
3457 RETURN
3460 PRINT "It took 7 days to get back to Seattle. Now you have a "; DELAYDAYS; " day"
3461 PRINT "wait before you can get a freighter for Japan."
3462 GOSUB 3600 : GOSUB 3900
3463 TOTDAYS=TOTDAYS+21
3464 RETURN
3480 PRINT "The freighter across the Pacific takes a leisurely 21 days making stops"
3481 PRINT "at Hawaii, Guam, and the Philippines. Also, the Chinese crewmen made"
3482 PRINT "sandals out of your leather fenders and mud flaps. You can't replace"
3483 PRINT "them in Japan, but you can at Vladivostok, Russia. There you'll have"
3484 PRINT "to spend several days arranging for fuel also. But hurry -- a steamer"
3485 PRINT "to Russia leaves tonight."
3486 GOSUB 3900
3487 TOTDAYS=TOTDAYS+7
3488 RETURN
3499 REM
3600 REM ============================ hotel bill / time delay ============================
3605 TOTDAYS=TOTDAYS+DELAYDAYS
3610 BILL=10*DELAYDAYS
3615 GOSUB 3700
3620 IF PAID=1 THEN RETURN
3625 PRINT
3630 PRINT "You don't even have enough money to pay for meals."
3635 PRINT "That's the end of the road for you."
3640 PRINT
3645 DEATH$="You couldn't afford food and lodging on the road." : GOTO 9100
3650 REM
3700 REM ============================ pay the bills =======================================
3705 IF CASH>=BILL THEN GOTO 3730
3710 GOSUB 3800
3715 IF CASH<BILL THEN PAID=0 : RETURN
3730 CASH=CASH-BILL : PAID=1
3735 RETURN
3740 REM
3800 REM ============================ wire the factory for money =========================
3805 WIRECOUNT=WIRECOUNT+1
3810 IF WIRECOUNT<3 THEN GRANT=1000 ELSE GRANT=500
3815 PRINT
3820 PRINT "You don't have enough money to continue. Your only hope is to send a"
3825 PRINT "telegram back to Mr. Thomas at the factory and ask for more money."
3830 PRINT "Remember, telegrams in 1908 used ALL CAPITAL LETTERS, had no commas,"
3835 PRINT "and were short."
3840 INPUT "What is your message? "; MSG$
3845 PRINT "Sending telegram now ..."
3850 IF WIRECOUNT>3 THEN GOTO 3990
3855 POLITE=0 : URGENT=0
3860 IF LEN(MSG$)<12 THEN GOTO 3940
3865 IF (INSTR(MSG$,"PLE")>0) OR (INSTR(MSG$,"BEG")>0) OR (INSTR(MSG$,"SOR")>0) OR (INSTR(MSG$,"IMP")>0) THEN POLITE=1
3870 IF (INSTR(MSG$,"SOO")>0) OR (INSTR(MSG$,"QUI")>0) OR (INSTR(MSG$,"EAR")>0) OR (INSTR(MSG$,"FAS")>0) OR (INSTR(MSG$,"HUR")>0) THEN URGENT=1
3875 IF (INSTR(MSG$,"IMM")>0) OR (INSTR(MSG$,"ONC")>0) OR (INSTR(MSG$,"URG")>0) THEN URGENT=1
3880 IF POLITE=0 THEN GOTO 3920
3885 IF URGENT=0 THEN GOTO 3905
3890 PRINT "Mr. Thomas wired back $";
3892 AMT=GRANT : GOSUB 4000
3895 PRINT " and said 'GOOD LUCK!'"
3898 CASH=CASH+GRANT
3899 RETURN
3905 PRINT "Mr. Thomas didn't know you needed the money right away and waited 3"
3907 PRINT "days before wiring back $";
3908 AMT=GRANT : GOSUB 4000 : PRINT
3910 CASH=CASH+GRANT
3912 DELAYDAYS=3 : GOSUB 3600
3915 RETURN
3920 IF URGENT=0 THEN GOTO 3950
3925 PRINT "Mr. Thomas wired back, 'YOU COULD AT LEAST BE POLITE,' but did include"
3927 GRANT=GRANT/2
3930 PRINT "a draft for $";
3932 AMT=GRANT : GOSUB 4000 : PRINT
3935 CASH=CASH+GRANT
3937 RETURN
3940 PRINT "Your message was short all right. Too short. Mr. Thomas didn't send"
3942 PRINT "any money. Sorry."
3944 RETURN
3950 PRINT "Mr. Thomas was offended by your telegram and refused to send any"
3952 PRINT "money. Sorry."
3954 RETURN
3990 PRINT "Mr. Thomas wires back: I AM FED UP WITH THIS ADVENTURE STOP"
3992 PRINT "YOU WILL GET NO MORE MONEY FROM ME STOP"
3994 RETURN
3999 REM
4000 REM ============================ money formatter ($D.CC) =============================
4005 DOLLARS=INT(AMT)
4010 CENTS=INT((AMT-DOLLARS)*100+.5)
4015 PRINT "$"; DOLLARS; ".";
4020 IF CENTS<10 THEN PRINT "0";
4025 PRINT CENTS;
4030 RETURN
4035 REM
4100 REM ============================ yes/no helper =======================================
4105 INPUT AD$
4110 IF AD$="" THEN YES=1 : RETURN
4115 IF (LEFT$(AD$,1)="Y") OR (LEFT$(AD$,1)="y") THEN YES=1 : RETURN
4120 IF (LEFT$(AD$,1)="N") OR (LEFT$(AD$,1)="n") THEN YES=0 : RETURN
4125 PRINT "Don't understand your answer of "; AD$; ". Please enter Y or N."
4130 GOTO 4105
4135 REM
4200 REM ============================ range-checked numeric input =========================
4205 IF (ANUM>=A1) AND (ANUM<=A2) THEN RETURN
4210 PRINT "Please enter a number from "; A1; " to "; A2; "."
4215 INPUT ANUM
4220 GOTO 4205
4225 REM
8995 REM ================================ you reach paris! ================================
9000 CLS
9005 PRINT
9010 IF TOTDAYS<LEADERDAYS THEN GOTO 9040
9015 IF TOTDAYS=LEADERDAYS THEN GOTO 9060
9020 PRINT "You made it to Paris! The German Protos beat you by "; TOTDAYS-LEADERDAYS;
9025 PRINT " days, but just to finish is a great honor!"
9030 GOTO 9070
9040 PRINT "You reached Paris first! The next car is "; LEADERDAYS-TOTDAYS; " days behind."
9050 GOTO 9070
9060 PRINT "You reached Paris in a dead tie with the French Motobloc!"
9070 PRINT
9080 PRINT "You reached Paris in "; TOTDAYS; " days. In 1908, the Thomas Flyer won"
9085 PRINT "the race, reaching Paris on July 30 after 169 days."
9090 PRINT
9095 INPUT "Press ENTER to end"; ANY$
9098 END
9099 REM
9100 REM ================================ your race ends early =============================
9105 CLS
9110 PRINT
9115 PRINT "Sorry, you were unsuccessful. Only three of the cars in the 1908"
9120 PRINT "race ever finished."
9125 PRINT
9130 PRINT DEATH$
9135 PRINT
9140 PRINT "In the "; TOTDAYS; " days since the start of the race on February 12, 1908,"
9145 PRINT "you covered "; INT(TOTMILES); " miles. You almost made it to "; LOC$(SEG+1); ","
9150 PRINT REGION$(SEG+1); "."
9155 PRINT "Not bad, but you can do better."
9160 PRINT
9165 INPUT "Press ENTER to end"; ANY$
9170 END
