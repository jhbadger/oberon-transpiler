10 REM
20 REM  THE ORIENT EXPRESS -- LONDON TO CONSTANTINOPLE, 1920s
30 REM  Adapted for basic.mod, inspired by David H. Ahl's game in
40 REM  Small Basic Computer Adventures (25th Anniversary Edition).
50 REM  This mystery's cast, clues, and outcomes are original.
60 DIM P$(6)
70 P$(1)="Countess Rostova" : P$(2)="Professor Hartwell" : P$(3)="Monsieur Laurent"
80 P$(4)="Colonel Ashby" : P$(5)="Herr Brandt" : P$(6)="Miss Whitfield"
90 DIM KC$(4)
100 KC$(1)="keeps a hand near an inside coat pocket, as if guarding something hard and heavy."
110 KC$(2)="flinches sharply when a porter drops a tray of dishes in the corridor."
120 KC$(3)="asks the conductor unusually detailed questions about which stations have police posted."
130 KC$(4)="is seen quietly cleaning a small metal object before tucking it away."
140 DIM DC$(4)
150 DC$(1)="keeps glancing anxiously out the window, as though watching for someone on the platform."
160 DC$(2)="mentions, a little too casually, having urgent business in Constantinople they won't discuss."
170 DC$(3)="goes pale at the mention of the embassy in Sofia."
180 DC$(4)="never lets a worn leather satchel out of arm's reach, even at dinner."
190 DIM NC$(5)
200 NC$(1)="complains at length about the quality of the coffee."
210 NC$(2)="proudly shows off photographs of grandchildren back home."
220 NC$(3)="is absorbed in a paperback novel and barely looks up."
230 NC$(4)="asks polite, unremarkable questions about your own travels."
240 NC$(5)="dozes off partway through the conversation."
250 DIM CITY$(9)
260 CITY$(1)="London" : CITY$(2)="Calais" : CITY$(3)="Paris" : CITY$(4)="Munich"
270 CITY$(5)="Vienna" : CITY$(6)="Budapest" : CITY$(7)="Belgrade" : CITY$(8)="Sofia"
280 CITY$(9)="Constantinople"

300 CASH=60 : SEGMENT=0

310 KILLERIDX=INT(1+RND*6)
320 DEFECTORIDX=INT(1+RND*6)
330 IF DEFECTORIDX=KILLERIDX THEN GOTO 320

400 CLS
410 PRINT "        THE ORIENT EXPRESS -- LONDON TO CONSTANTINOPLE"
420 PRINT "                  an original mystery"
430 PRINT
440 INPUT "Press ENTER to board the train!"; ANY$
450 CLS
460 PRINT "The Orient Express pulls out of London's Victoria Station, bound"
470 PRINT "for Constantinople. Somewhere aboard, a defector is fleeing to"
480 PRINT "safety in the East -- and, unknown even to them, an assassin is"
490 PRINT "riding the same train, sent to make sure they never arrive."
500 PRINT
510 PRINT "You have a little time and "; CASH; " pounds to your name. Over the"
520 PRINT "coming days, watch your fellow passengers closely -- a stray"
530 PRINT "remark or a nervous glance may be the only clue you get."
540 PRINT
550 INPUT "Press ENTER to continue"; ANY$
560 CLS

600 PRINT "How closely do you tend to notice small details?"
610 PRINT "  (1) A trained observer -- little escapes your notice"
620 PRINT "  (2) Reasonably attentive"
630 PRINT "  (3) Easily distracted"
640 PRINT "  (4) You'd miss an elephant in the dining car"
650 INPUT "How do you rank yourself (1-4)? "; PERCEPTION
660 IF (PERCEPTION>=1) AND (PERCEPTION<=4) THEN GOTO 690
670 PRINT "Please enter 1, 2, 3, or 4."
680 GOTO 650
690 PRINT
700 INPUT "Press ENTER to depart!"; ANY$
710 CLS

995 REM ============================ main loop ================================
1000 SEGMENT=SEGMENT+1
1010 PRINT
1015 PRINT "== Approaching "; CITY$(SEGMENT+1); " =="
1020 GOSUB 2500
1030 GOSUB 2000
1040 IF SEGMENT>=8 THEN GOTO 11000
1050 GOTO 1000

1995 REM ========================= talk to a passenger ==========================
2000 PRINT
2005 PRINT "At dinner, you strike up a conversation. Who do you approach?"
2010 FOR K=1 TO 6
2015   PRINT "  ("; K; ") "; P$(K)
2020 NEXT K
2025 PRINT "  (0) Keep to yourself tonight"
2030 A1=0 : A2=6
2035 INPUT "Who do you talk to? "; A
2040 GOSUB 10000
2045 IF A=0 THEN PRINT "You have a quiet evening and turn in early.": RETURN
2050 PN$=P$(A)
2055 PRINT
2060 IF A=KILLERIDX THEN GOTO 2100
2065 IF A=DEFECTORIDX THEN GOTO 2150
2070 RN=INT(1+RND*5)
2075 PRINT PN$; " "; NC$(RN)
2080 RETURN
2100 THEMECHANCE=90-(PERCEPTION-1)*15
2105 IF INT(RND*100)+1>THEMECHANCE THEN GOTO 2070
2110 RN=INT(1+RND*4)
2115 PRINT PN$; " "; KC$(RN)
2120 RETURN
2150 THEMECHANCE=90-(PERCEPTION-1)*15
2155 IF INT(RND*100)+1>THEMECHANCE THEN GOTO 2070
2160 RN=INT(1+RND*4)
2165 PRINT PN$; " "; DC$(RN)
2170 RETURN

2495 REM ============================= hazard check ==============================
2500 RN=INT(RND*100)+1
2505 IF (SEGMENT<=3) AND (RN<=15) THEN PRINT: PRINT "Heavy snow blankets the tracks ahead -- the train crawls along.": RETURN
2510 IF (SEGMENT>=6) AND (RN<=8) THEN PRINT: PRINT "Armed men briefly board the train. They take a few pounds and vanish into the hills.": CASH=CASH-INT(5+RND*10): GOSUB 8000: RETURN
2515 IF RN<=4 THEN PRINT: PRINT "A wheel derails on a rough stretch of track. Repair crews cost you half a day.": RETURN
2520 RETURN

7995 REM ========================= clamp quantities to >=0 =====================
8000 IF CASH<0 THEN CASH=0
8005 RETURN

9995 REM ======================= range-checked numeric input ====================
10000 IF (A>=A1) AND (A<=A2) THEN RETURN
10005 IF A<A1 THEN PRINT "That's not one of the choices." ELSE PRINT "That's not one of the choices."
10010 INPUT A
10015 GOTO 10000

10995 REM ============================== the accusation =============================
11000 CLS
11005 PRINT "The Orient Express pulls into Constantinople at last."
11010 PRINT
11015 PRINT "Before you disembark, name your suspects."
11020 PRINT
11025 FOR K=1 TO 6
11030   PRINT "  ("; K; ") "; P$(K)
11035 NEXT K
11040 A1=1 : A2=6
11045 PRINT
11050 PRINT "Who do you believe is the KILLER?"
11055 INPUT "Your answer? "; A
11060 GOSUB 10000
11065 GUESSKILLER=A
11070 PRINT
11075 PRINT "Who do you believe is the DEFECTOR?"
11080 INPUT "Your answer? "; A
11085 GOSUB 10000
11090 GUESSDEFECTOR=A
11095 PRINT
11100 IF (GUESSKILLER=KILLERIDX) AND (GUESSDEFECTOR=DEFECTORIDX) THEN GOTO 11200
11105 IF GUESSKILLER=DEFECTORIDX THEN GOTO 11300
11110 IF GUESSDEFECTOR=KILLERIDX THEN GOTO 11400
11115 IF GUESSKILLER=KILLERIDX THEN GOTO 11500
11120 IF GUESSDEFECTOR=DEFECTORIDX THEN GOTO 11600
11125 GOTO 11700

11200 PRINT "You quietly alert the stationmaster. Officers take "; P$(KILLERIDX); " into"
11205 PRINT "custody on the platform, while "; P$(DEFECTORIDX); " slips away to safety."
11210 PRINT "A perfect end to the journey!"
11215 GOTO 11900

11300 PRINT "Your accusation falls on "; P$(DEFECTORIDX); ", who is seized by the"
11305 PRINT "police, protesting innocence all the way. The real killer watches"
11310 PRINT "from the platform, unnoticed, and disappears into the crowd."
11315 GOTO 11900

11400 PRINT "You quietly approach "; P$(KILLERIDX); ", believing them to be the"
11405 PRINT "defector, and offer your help. Their eyes go cold. You barely"
11410 PRINT "escape with your life as the train pulls into the station."
11415 GOTO 11900

11500 PRINT "You correctly finger "; P$(KILLERIDX); ", who is arrested before any"
11505 PRINT "harm is done. But the real defector, still unknown to you, slips"
11510 PRINT "off the train and vanishes into the city."
11515 GOTO 11900

11600 PRINT "You correctly identify "; P$(DEFECTORIDX); " as the defector -- but in"
11605 PRINT "naming the wrong killer, you give the real one time to act."
11610 PRINT P$(DEFECTORIDX); " is found in their compartment, and does not wake."
11615 GOTO 11900

11700 PRINT "Both your guesses are wrong. The train empties onto the platform"
11705 PRINT "at Constantinople, and you never learn what became of the"
11710 PRINT "defector or the killer, who vanish separately into the crowd."
11715 GOTO 11900

11900 PRINT
11905 PRINT "You had "; CASH; " pounds left when you arrived."
11910 PRINT
11915 INPUT "Press ENTER to end"; ANY$
11920 END
