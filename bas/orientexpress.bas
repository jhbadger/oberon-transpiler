10 REM
20 REM  THE ORIENT EXPRESS -- LONDON TO CONSTANTINOPLE, 1923
30 REM  "The Mysterious Arms Deal" -- adapted for basic.mod from the
40 REM  (c) 1986 David H. Ahl original (Small Basic Computer Adventures).
50 REM
60 DIM CITY$(24), DESC$(24), ME(24), HZ(24), CN(24), DAYN(24), TA(24), TD(24)
70 DIM ND$(25), CS(24), CP(24), CD$(24), MBD$(13), MDD$(24)

95 REM ============================ opening scenario ==================================
100 CLS
105 PRINT "                 THE ORIENT EXPRESS, 1923"
110 PRINT "                (c) David H. Ahl, 1986"
115 PRINT
120 INPUT "Press ENTER to continue"; ANY$
125 CLS
130 PRINT "                  THE MYSTERIOUS ARMS DEAL"
135 PRINT
140 PRINT " It is February 1923. The following note is received at"
145 PRINT "Whitehall: 'If you will furnish me with a new identity and a"
150 PRINT "lifetime supply of Scotch, I will give up my life of arms dealing"
155 PRINT "and will provide you with much valuable information. I will be"
160 PRINT "on the Orient Express tonight. But you must contact me before"
165 PRINT "the train reaches Uzunkopru or that swine dealer of Maxim machine"
170 PRINT "guns will have me killed by bandits like he did to Baron Wunster"
175 PRINT "last month.' The note is not signed."
180 PRINT " You, a British agent, are assigned to take the train, rescue"
185 PRINT "the defector, and arrest the killer."
190 PRINT " You know there are five notorious arms dealers of different"
195 PRINT "nationalities operating in Europe under an uneasy truce, as each"
200 PRINT "deals in a different kind of weapon. But it is obvious that the"
205 PRINT "truce has ended."
210 PRINT
215 INPUT "Press ENTER to call a taxi"; ANY$
220 CLS

295 REM ============================ read the journey data =============================
300 FOR I=1 TO 24
305   READ CITY$(I), DESC$(I), ME(I), HZ(I), CN(I), DAYN(I), TA(I), TD(I)
310 NEXT I
315 FOR I=1 TO 25
320   READ ND$(I)
325 NEXT I
330 FOR I=1 TO 24
335   READ CP(I), CD$(I)
340   CS(I)=I
345 NEXT I
350 FOR I=1 TO 13
355   READ MBD$(I)
360 NEXT I
365 FOR I=1 TO 24
370   READ MDD$(I)
375 NEXT I

395 REM ============================ shuffle the clue deck =============================
400 FOR I=1 TO 23
405   K=I+INT((25-I)*RND)
410   X=CS(I) : CS(I)=CS(K) : CS(K)=X
415 NEXT I

420 REM ============================ pick the killer and defector ======================
425 KILLER=INT(1+RND*5)
430 DEFECTOR=INT(1+RND*5)
435 IF DEFECTOR=KILLER THEN GOTO 430

440 REM ============================ initial values =====================================
445 HY=0 : HX=0 : HW=0 : CM=0 : EXPENSES=0 : SOLVED=0 : J=0

495 REM ============================ main loop (24 legs) ================================
500 J=J+1
505 PRINT
510 PRINT "February "; DAYN(J)+HY; ", 1923"
515 TN=18-INT(27*RND) : TB=TA(J)+TN : T=TB
520 IF J=1 THEN GOTO 700

525 REM ---- arrival announcement ----
530 GOSUB 4600
535 PRINT "You have arrived at "; CITY$(J); ", "; DESC$(J); " at ";
540 GOSUB 4700
545 IF TN>1 THEN PRINT "... just "; TN; " minutes late." : GOTO 565
550 IF TN<-1 THEN PRINT "... almost "; -TN; " minutes early." : GOTO 565
555 PRINT "... right on time!"

565 IF TB>TD(J)-2 THEN T=TB+4 ELSE T=TD(J)
570 IF J=24 THEN GOTO 4800
575 IF ME(J)<4 THEN GOTO 620

580 REM ---- nighttime: asleep through the stop ----
585 PRINT "Asleep in your compartment, you barely notice that the"
590 PRINT "departure was right on time at ";
595 GOSUB 4700
600 DELAY 300
605 GOTO 780

620 REM ---- daytime: option to stretch your legs ----
625 IF J=23 THEN GOSUB 1000
630 PRINT "Departure is at ";
635 GOSUB 4700
640 PRINT
645 INPUT "Would you like to get off and stretch your legs? "; AD$
650 GOSUB 8500
655 IF YES=0 THEN PRINT "Okay, you stay in your compartment." : GOTO 700
660 PRINT "Okay, but be sure not to miss the train."

700 REM ---- boarding ----
705 IF J>1 THEN GOTO 730
710 PRINT "The taxi has dropped you at Victoria Station in London."
715 PRINT "The Orient Express is standing majestically on Track 14."

730 PRINT
735 PRINT "The stationmaster rings the departure bell ..."
740 DELAY 300
745 PRINT "All aboard ... ";
750 DELAY 300
755 PRINT "the train is leaving."
760 DELAY 300

780 REM ---- underway: train noises ----
785 GOSUB 4500
790 DELAY 300

795 IF J>1 THEN GOTO 850

800 REM ---- leg 1 only: recruit informants ----
805 X=3+INT(20*RND)
810 PRINT
815 PRINT "You speak to some of the passengers ... "; ND$(X); ","
820 PRINT ND$(X+1); ", "; ND$(X+2); " and others ... and ask them to keep"
825 PRINT "their eyes and ears open and to pass any information ... no"
830 PRINT "matter how trivial ... to you in compartment 13. The Channel"
835 PRINT "crossing is pleasant and the first part of the trip uneventful."

850 REM ---- resolve the mystery on leg 23 ----
855 IF J=23 THEN GOSUB 1500

860 REM ---- meals ----
865 IF ME(J)=1 THEN GOSUB 2000
870 IF ME(J)=2 THEN GOSUB 2500
875 IF ME(J)=3 THEN GOSUB 3000

880 REM ---- conversations ----
885 GOSUB 3700

890 REM ---- hazards ----
895 IF HZ(J)=1 THEN GOSUB 4000
900 IF HZ(J)=2 THEN GOSUB 4200
905 GOSUB 4400

910 GOTO 500

995 REM ============================ identify the killer and defector ==================
1000 PRINT
1005 PRINT "The Turkish police have boarded the train. They have been"
1010 PRINT "asked to assist you, but for them to do so you will have to"
1015 PRINT "identify the killer (the dealer in machine guns) and the defector"
1020 PRINT "(the Scotch drinker) to them. The arms dealers are lined"
1025 PRINT "up as follows:"
1030 PRINT
1035 PRINT " (1) Austrian, (2) Turk, (3) Pole, (4) Greek, (5) Rumanian."
1040 PRINT
1045 A1=1 : A2=5
1050 INPUT "Who is the defector (a number please)? "; A
1055 GOSUB 8600
1060 GD=A
1065 INPUT "And who is the killer? "; A
1070 GOSUB 8600
1075 GK=A
1080 PRINT
1085 PRINT "The police take into custody the man you identified as the"
1090 PRINT "killer and provide a guard to ride on the train with the"
1093 PRINT "defector. You return to your compartment, praying that you"
1096 PRINT "made the correct deductions and identified the right men."
1098 DELAY 300
1099 RETURN

1495 REM ============================ resolve the identities (leg 23) ===================
1500 IF GD=DEFECTOR THEN GOTO 1540
1503 PRINT
1506 PRINT "You are suddenly awakened by what sounded like a gunshot."
1509 PRINT "You rush to the defector's compartment, but he is okay."
1512 PRINT "However, one of the other arms dealers has been shot."
1515 DELAY 300
1518 PRINT
1521 PRINT "You review the details of the case in your mind and realize"
1524 PRINT "that you came to the wrong conclusion, and due to your mistake"
1527 PRINT "a man lies dead at the hands of bandits. You return to your"
1530 PRINT "compartment, shaken, hoping you at least identified the killer."

1540 IF GK=KILLER THEN GOTO 1590
1543 GOSUB 3600
1546 PRINT "A man is standing outside. He says, 'You made a"
1549 PRINT "mistake. A bad one. You see, I am the machine-gun dealer.'"
1552 IF GD<>KILLER THEN GOTO 1561
1555 PRINT "Moreover, you incorrectly identified me as your ally in this"
1558 PRINT "affair. So the state will take care of him instead. Ha."
1561 PRINT
1564 DELAY 300
1567 PRINT "He draws a gun. BANG. You are dead."
1570 PRINT
1573 PRINT "You never know that the train arrived right on time at"
1576 PRINT "Constantinople, Turkey."
1579 DELAY 300
1582 GOTO 4800

1590 SOLVED=1
1593 RETURN

1995 REM ============================ dinner =============================================
2000 PRINT
2003 PRINT "Dinner is now being served in the restaurant car."
2006 INPUT "Press ENTER when you're ready to have dinner"; ANY$
2009 CLS
2012 PRINT "                       DINNER MENU"
2015 PRINT
2018 FOR I=1 TO 7
2021   X=3*(I-1)+1+INT(3*RND)
2024   PRINT MDD$(X)
2027 NEXT I
2030 PRINT MDD$(22)
2033 PRINT MDD$(23)
2036 PRINT MDD$(24)
2039 GOSUB 3500
2042 RETURN

2495 REM ============================ lunch ===============================================
2500 PRINT
2503 PRINT "An enormous buffet luncheon has been laid out in the"
2506 PRINT "restaurant car."
2509 INPUT "Press ENTER when you have finished"; ANY$
2512 PRINT " B-U-R-P!"
2515 RETURN

2995 REM ============================ breakfast ===========================================
3000 PRINT
3003 PRINT "Breakfast is now being served in the restaurant car."
3006 INPUT "Press ENTER when you're ready to have breakfast"; ANY$
3009 CLS
3012 PRINT "                      BREAKFAST MENU"
3015 PRINT
3018 FOR I=1 TO 4
3021   X=3*(I-1)+1+INT(3*RND)
3024   PRINT MBD$(X)
3027 NEXT I
3030 PRINT MBD$(13)
3033 GOSUB 3500
3036 RETURN

3495 REM ============================ finish eating =======================================
3500 PRINT
3503 INPUT "Press ENTER when you have finished eating"; ANY$
3506 EXPENSES=EXPENSES+5*(J+1)
3509 CLS
3512 RETURN

3595 REM ============================ buzzer / knock at the door ==========================
3600 PRINT
3603 PRINT "Your compartment buzzer rings ..."
3606 INPUT "Press ENTER to open the door"; ANY$
3609 RETURN

3695 REM ============================ conversations =======================================
3700 FOR K=1 TO CN(J)
3705   GOSUB 3600
3710   CM=CM+1
3715   IF CP(CS(CM))>0 THEN X=CP(CS(CM)) ELSE X=3+INT(23*RND)
3720   PRINT "Standing there is "; ND$(X); ", who tells you:"
3725   XS=CS(CM)
3730   IF LEN(CD$(XS))<81 THEN PRINT CD$(XS) : GOTO 3765
3735   FOR KA=79 TO 1 STEP -1
3740     IF MID$(CD$(XS),KA,1)=" " THEN GOTO 3755
3745   NEXT KA
3755   PRINT MID$(CD$(XS),1,KA)
3760   PRINT MID$(CD$(XS),KA+1)
3765 NEXT K
3770 RETURN

3995 REM ============================ snow ================================================
4000 X=RND
4003 IF X>.65 THEN RETURN
4006 PRINT
4009 PRINT "It is snowing heavily ";
4012 IF X<.01 THEN GOTO 4040
4015 PRINT "but the tracks have been cleared and the train"
4018 PRINT "will not be delayed."
4021 RETURN

4040 PRINT "and the train is forced to slow down."
4043 PRINT
4046 PRINT "Oh no! The train is coming to a stop. Let's hope this is"
4049 PRINT "not a repeat of the trip of January 1929, when the Orient"
4052 PRINT "Express was stuck in snowdrifts for five days."
4055 PRINT
4058 DELAY 300
4061 PRINT "But it looks like it is!"
4064 DELAY 300
4067 PRINT "You are stranded for two days until a snowplow clears the track."
4070 PRINT "The train is now exactly two days behind schedule."
4073 HY=HY+2
4076 RETURN

4195 REM ============================ bandits =============================================
4200 IF RND>.04 THEN RETURN
4203 IF HX=1 THEN RETURN
4206 HX=1
4209 PRINT
4212 PRINT "You are rudely awakened from a deep sleep by a loud noise"
4215 PRINT "as the train jerks to a halt."
4218 GOSUB 3600
4221 PRINT "You are shocked to see a bandit waving a gun in your face."
4224 PRINT "He demands that you give him your wallet, jewelry, and watch."
4227 PRINT
4230 DELAY 300
4233 PRINT "The bandits are off the train in a few moments with"
4236 PRINT "their loot. They disappear into the forest. No one"
4239 PRINT "was injured, and the train resumes its journey."
4242 RETURN

4395 REM ============================ derailment ==========================================
4400 IF RND>.02 THEN RETURN
4403 IF HW=1 THEN RETURN
4406 HW=1
4409 PRINT
4412 PRINT "You hear a loud screeching noise as the train comes to a"
4415 PRINT "crashing stop. The engine, tender, and first coach are"
4418 PRINT "leaning at a crazy angle. People are screaming."
4421 DELAY 300
4424 PRINT
4427 PRINT "While not as bad as the derailment at Vitry-le-Francois in"
4430 PRINT "November 1911, there is no question that the front of the"
4433 PRINT "train has left the track."
4436 DELAY 300
4439 PRINT
4442 PRINT "You are stranded for exactly one day while the track is"
4445 PRINT "repaired and a new locomotive obtained."
4448 HY=HY+1
4451 RETURN

4495 REM ============================ train noises ========================================
4500 PRINT
4503 PRINT "Clackety clack ... clackety clack ... clackety clack"
4506 IF RND>.5 THEN RETURN
4509 GOSUB 4600
4512 RETURN

4595 REM ============================ train whistle =======================================
4600 PRINT "The engineer sounds the train's whistle."
4603 RETURN

4695 REM ============================ print the time ======================================
4700 T=T+10000
4703 MM=T MOD 100
4706 IF MM>59 THEN T=T+40
4709 MM=T MOD 100
4712 HH=INT(T/100) MOD 100
4715 PRINT HH; ":";
4718 IF MM<10 THEN PRINT "0";
4721 PRINT MM
4724 RETURN

4795 REM ============================ journey's end =======================================
4800 CLS
4803 PRINT
4806 PRINT "Your journey has ended. Georges Nagelmackers and the"
4809 PRINT "management of the Compagnie Internationale des Wagons-Lits"
4812 PRINT "hope you enjoyed your trip on the Orient Express, the"
4815 PRINT "most famous train in the world."
4818 PRINT
4821 IF SOLVED<>1 THEN GOTO 4833
4824 PRINT "Whitehall telegraphs congratulations for identifying both"
4827 PRINT "the killer and the defector correctly."
4830 PRINT

4833 PRINT "You spent "; EXPENSES; " pounds on meals along the way."
4836 PRINT
4839 INPUT "Press ENTER to end"; ANY$
4842 END

8495 REM ============================ yes/no helper =======================================
8500 IF (LEFT$(AD$,1)="Y") OR (LEFT$(AD$,1)="y") THEN YES=1 : RETURN
8505 IF (LEFT$(AD$,1)="N") OR (LEFT$(AD$,1)="n") THEN YES=0 : RETURN
8510 PRINT "Please enter Y for 'yes' or N for 'no.' Which is it? "
8515 INPUT AD$
8520 GOTO 8500

8595 REM ======================= range-checked numeric input =============================
8600 IF (A>=A1) AND (A<=A2) THEN RETURN
8605 PRINT "Please enter a number from "; A1; " to "; A2; "."
8610 INPUT A
8615 GOTO 8600

8995 REM ============================ journey data (24 legs) ==============================
9000 DATA "London","the departure platform",0,0,1,14,2100,2115
9005 DATA "Dover","the cross-Channel landing stage",4,0,0,14,2255,2315
9010 DATA "Calais","the customs shed on the quay",0,1,1,15,115,145
9015 DATA "Amiens","a quiet provincial platform",4,1,0,15,430,450
9020 DATA "Paris","the great glass-roofed terminus at Gare de Lyon",3,0,2,15,730,830
9025 DATA "Dijon","a wine-country junction",0,1,1,15,1145,1205
9030 DATA "Vallorbe","the Swiss frontier post",2,1,1,15,1500,1520
9035 DATA "Lausanne","the lakeside platform above Geneva's waters",0,1,0,15,1615,1635
9040 DATA "Domodossola","the tunnel mouth beneath the Simplon Pass",1,1,1,15,1930,1950
9045 DATA "Milan","the vast iron-and-glass Centrale",4,0,0,15,2245,2315
9050 DATA "Venice","the causeway station of Santa Lucia",4,0,1,16,430,500
9055 DATA "Trieste","the windswept Adriatic harbor front",3,0,1,16,800,830
9060 DATA "Zagreb","a bustling market-day platform",2,0,1,16,1330,1400
9065 DATA "Vinkovci","a sleepy rail junction on the plain",0,0,0,16,1700,1720
9070 DATA "Belgrade","the fortress city above two rivers",1,0,2,16,2100,2200
9075 DATA "Nis","a dim platform lit by oil lamps",4,2,0,17,100,120
9080 DATA "Dimitrovgrad","the Bulgarian border post",4,2,0,17,430,500
9085 DATA "Sofia","a hillside station ringed by mountains",3,2,2,17,830,900
9090 DATA "Plovdiv","an ancient hill town's platform",2,2,1,17,1300,1330
9095 DATA "Svilengrad","a border post near three frontiers",0,2,1,17,1700,1730
9100 DATA "Edirne","the old Ottoman capital's station",1,2,2,17,2015,2045
9105 DATA "Pehlivankoy","a lonely junction on the Thracian plain",4,0,0,18,2330,2350
9110 DATA "Uzunkopru","the last stop before Constantinople",0,2,1,18,300,330
9115 DATA "Constantinople","the domes of Sirkeci Terminal at journey's end",0,0,0,18,730,0

9195 REM ============================ passenger names =====================================
9200 DATA "Madame Dubois","Herr Wexler","Contessa Albrizzi","Mr. Pemberton","Nurse Kowalski"
9205 DATA "Father Ionescu","Baroness Vogt","Doctor Marchetti","Madame Petrescu","Mr. Aldridge"
9210 DATA "Fraulein Steiner","Signor Bellini","Miss Okafor","Herr Krantz","Madame Aslan"
9215 DATA "Mr. Farrow","Contessa Ricci","Herr Blum","Miss Delacroix","Mr. Yilmaz"
9220 DATA "Baron Novak","Mrs. Whitcombe","Herr Ostrowski","Signora Conti","Mr. Hargrove"

9295 REM ============================ conversation statements =============================
9300 DATA 0,"The Austrian dealer barely touches his wine and keeps glancing toward the corridor."
9305 DATA 0,"The Pole has been telling anyone who will listen about a shipment of Scotch whisky he's expecting in Constantinople."
9310 DATA 0,"The Turk spent an hour this afternoon in quiet, urgent conversation with the conductor."
9315 DATA 0,"The Greek dealer laughed off a question about his business as though it were nothing at all."
9320 DATA 0,"The Rumanian keeps a heavy travel case chained to his wrist, even at dinner."
9325 DATA 0,"Nothing much to report -- the dining car was unusually quiet this evening."
9330 DATA 0,"Someone mentioned seeing a stranger in a dark coat loitering near the baggage car."
9335 DATA 0,"The Austrian ordered a second bottle of Scotch before the first was even finished."
9340 DATA 0,"The Turk keeps what looks like a service revolver wrapped in a coat inside his luggage."
9345 DATA 0,"The Pole flinched badly when a porter dropped a stack of dishes in the corridor outside compartment nine, and it took him a long moment to stop shaking."
9350 DATA 0,"The Greek asked the conductor unusually detailed questions about which stations have police posted."
9355 DATA 0,"The Rumanian has been reading the same newspaper for three days without turning a page."
9360 DATA 0,"A porter says one of the arms dealers tipped him extravagantly just to keep quiet about something."
9365 DATA 0,"The dining car gossip tonight was all about the weather ahead."
9370 DATA 0,"The Austrian was seen quietly cleaning a small metal object before tucking it away."
9375 DATA 0,"The Turk has been asking, very casually, whether the train ever stops unscheduled in open country."
9380 DATA 0,"The Pole keeps a hand near an inside coat pocket, as if guarding something hard and heavy."
9385 DATA 0,"The Greek grows pale every time Sofia is mentioned."
9390 DATA 0,"The Rumanian never lets a worn leather satchel out of arm's reach, even at dinner."
9395 DATA 0,"A steward overheard one of the dealers mutter something about 'no witnesses,' but couldn't say which."
9400 DATA 0,"The Austrian and the Turk had a tense exchange in the corridor that ended when they noticed you watching."
9405 DATA 0,"The Pole spent the whole afternoon writing and then burning letters in the corridor ashtray."
9410 DATA 0,"The Greek keeps checking his pocket watch as though counting down to something."
9415 DATA 2,"One of the dealers was seen slipping the conductor a folded banknote for his silence."

9495 REM ============================ breakfast menu ======================================
9500 DATA "Fresh-baked croissants and rolls","Soft-boiled eggs with toast soldiers","A dish of stewed prunes and cream"
9505 DATA "Grilled kippers","An omelette with fine herbs","Sliced ham and Gruyere cheese"
9510 DATA "Freshly squeezed orange juice","A pot of strong black coffee","Chilled grapefruit segments"
9515 DATA "A basket of pastries from the last stop","Farmer's cheese with black bread","A small dish of wild honey"
9520 DATA "Coffee, tea, or cocoa, poured as you like it."

9595 REM ============================ dinner menu ==========================================
9600 DATA "A clear consomme with fine herbs","Cream of mushroom soup","A rich oxtail broth"
9605 DATA "Poached sole in white wine sauce","Grilled trout with almonds","A delicate fish quenelle"
9610 DATA "Roast pheasant with chestnuts","Beef Wellington with a red wine reduction","Duck breast with orange glaze"
9615 DATA "Braised leeks in butter","Glazed carrots with thyme","Haricots verts amandine"
9620 DATA "A simple green salad with vinaigrette","Endive salad with walnuts","Watercress and pear salad"
9625 DATA "A selection of French cheeses","Aged Gruyere with fig preserves","A wedge of ripe Brie"
9630 DATA "Chocolate mousse","A delicate lemon tart","Creme brulee"
9635 DATA "A wine steward circulates with a well-stocked cellar list."
9640 DATA "Coffee and after-dinner liqueurs are offered at the table."
9645 DATA "A small dish of Turkish delight closes out the meal."
