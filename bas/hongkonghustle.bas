10 REM
20 REM  HONG KONG HUSTLE, 1997 -- COLLECT BAGS OF GOLD BEFORE MIDNIGHT
30 REM  Adapted for basic.mod from the (c) 1986 David H. Ahl original
40 REM  (Small Basic Computer Adventures, 25th Anniversary Edition).

50 DIM STA$(18)
60 STA$(1)="Repulse Bay" : STA$(2)="Stanley" : STA$(3)="Aberdeen"
70 STA$(4)="Wan Chai" : STA$(5)="Causeway Bay" : STA$(6)="Central"
80 STA$(7)="Macau Jetfoil Pier" : STA$(8)="Admiralty" : STA$(9)="North Point"
90 STA$(10)="Quarry Bay" : STA$(11)="Tsim Sha Tsui" : STA$(12)="Mong Kok"
100 STA$(13)="Kowloon Tong" : STA$(14)="Sha Tin" : STA$(15)="Kwun Tong"
110 STA$(16)="Tsuen Wan" : STA$(17)="Sai Kung" : STA$(18)="Yuen Long"

120 DIM L$(8)
130 L$(1)="Island Line" : L$(2)="South Side Bus" : L$(3)="Star Ferry"
140 L$(4)="Tsuen Wan Line" : L$(5)="East Rail Line" : L$(6)="Kwun Tong Line"
150 L$(7)="Sai Kung Bus" : L$(8)="West Rail"

160 DIM LSTOPS(8,6) : DIM LCOUNT(8) : DIM LTIMES(8,5)
170 LSTOPS(1,1)=6 : LSTOPS(1,2)=8 : LSTOPS(1,3)=4 : LSTOPS(1,4)=5 : LSTOPS(1,5)=9 : LSTOPS(1,6)=10
180 LCOUNT(1)=6 : LTIMES(1,1)=3 : LTIMES(1,2)=3 : LTIMES(1,3)=3 : LTIMES(1,4)=6 : LTIMES(1,5)=4
190 LSTOPS(2,1)=1 : LSTOPS(2,2)=2 : LSTOPS(2,3)=3 : LSTOPS(2,4)=6 : LCOUNT(2)=4
200 LTIMES(2,1)=12 : LTIMES(2,2)=15 : LTIMES(2,3)=18
210 LSTOPS(3,1)=6 : LSTOPS(3,2)=11 : LCOUNT(3)=2 : LTIMES(3,1)=8
220 LSTOPS(4,1)=11 : LSTOPS(4,2)=12 : LSTOPS(4,3)=13 : LSTOPS(4,4)=16 : LCOUNT(4)=4
230 LTIMES(4,1)=4 : LTIMES(4,2)=6 : LTIMES(4,3)=9
240 LSTOPS(5,1)=13 : LSTOPS(5,2)=14 : LCOUNT(5)=2 : LTIMES(5,1)=7
250 LSTOPS(6,1)=12 : LSTOPS(6,2)=15 : LCOUNT(6)=2 : LTIMES(6,1)=7
260 LSTOPS(7,1)=15 : LSTOPS(7,2)=17 : LCOUNT(7)=2 : LTIMES(7,1)=20
270 LSTOPS(8,1)=16 : LSTOPS(8,2)=18 : LCOUNT(8)=2 : LTIMES(8,1)=12

280 DIM STNLINES(18) : DIM STLINES(18,3)
290 STNLINES(1)=1 : STLINES(1,1)=2
300 STNLINES(2)=1 : STLINES(2,1)=2
310 STNLINES(3)=1 : STLINES(3,1)=2
320 STNLINES(4)=1 : STLINES(4,1)=1
330 STNLINES(5)=1 : STLINES(5,1)=1
340 STNLINES(6)=3 : STLINES(6,1)=1 : STLINES(6,2)=2 : STLINES(6,3)=3
350 STNLINES(7)=0
360 STNLINES(8)=1 : STLINES(8,1)=1
370 STNLINES(9)=1 : STLINES(9,1)=1
380 STNLINES(10)=1 : STLINES(10,1)=1
390 STNLINES(11)=2 : STLINES(11,1)=3 : STLINES(11,2)=4
400 STNLINES(12)=2 : STLINES(12,1)=4 : STLINES(12,2)=6
410 STNLINES(13)=2 : STLINES(13,1)=4 : STLINES(13,2)=5
420 STNLINES(14)=1 : STLINES(14,1)=5
430 STNLINES(15)=2 : STLINES(15,1)=6 : STLINES(15,2)=7
440 STNLINES(16)=2 : STLINES(16,1)=4 : STLINES(16,2)=8
450 STNLINES(17)=1 : STLINES(17,1)=7
460 STNLINES(18)=1 : STLINES(18,1)=8

470 DIM WALKA(2) : DIM WALKB(2)
480 WALKA(1)=6 : WALKB(1)=7
490 WALKA(2)=15 : WALKB(2)=13

500 DIM PKGDESD$(10) : DIM PKSTNU(10) : DIM PKGSTA(10,2) : DIM PKSTDS(10,2) : DIM PICK(10)
510 PKGDESD$(1)="a jeweler's vault near the Aberdeen typhoon shelter"
515 PKSTNU(1)=1 : PKGSTA(1,1)=3 : PKSTDS(1,1)=6
520 PKGDESD$(2)="an antique dealer's back room in Central"
525 PKSTNU(2)=2 : PKGSTA(2,1)=6 : PKSTDS(2,1)=5 : PKGSTA(2,2)=8 : PKSTDS(2,2)=9
530 PKGDESD$(3)="a tailor's shop in Causeway Bay"
535 PKSTNU(3)=1 : PKGSTA(3,1)=5 : PKSTDS(3,1)=4
540 PKGDESD$(4)="a warehouse overlooking the harbor in Quarry Bay"
545 PKSTNU(4)=2 : PKGSTA(4,1)=10 : PKSTDS(4,1)=5 : PKGSTA(4,2)=9 : PKSTDS(4,2)=7
550 PKGDESD$(5)="a night market stall in Mong Kok"
555 PKSTNU(5)=1 : PKGSTA(5,1)=12 : PKSTDS(5,1)=5
560 PKGDESD$(6)="a hotel safe in Tsim Sha Tsui"
565 PKSTNU(6)=2 : PKGSTA(6,1)=11 : PKSTDS(6,1)=6 : PKGSTA(6,2)=12 : PKSTDS(6,2)=12
570 PKGDESD$(7)="a temple courtyard in Kowloon Tong"
575 PKSTNU(7)=1 : PKGSTA(7,1)=13 : PKSTDS(7,1)=8
580 PKGDESD$(8)="a fishing village house in Sai Kung"
585 PKSTNU(8)=1 : PKGSTA(8,1)=17 : PKSTDS(8,1)=10
590 PKGDESD$(9)="a farmhouse near Yuen Long"
595 PKSTNU(9)=1 : PKGSTA(9,1)=18 : PKSTDS(9,1)=9
600 PKGDESD$(10)="a rooftop garden in Sha Tin"
605 PKSTNU(10)=2 : PKGSTA(10,1)=14 : PKSTDS(10,1)=6 : PKGSTA(10,2)=13 : PKSTDS(10,2)=14

610 DIM FRD$(9)
620 FRD$(1)="associate" : FRD$(2)="friend" : FRD$(3)="confidant"
630 FRD$(4)="ally" : FRD$(5)="comrade" : FRD$(6)="colleague"
640 FRD$(7)="mate" : FRD$(8)="partner" : FRD$(9)="compatriot"

650 PS=10 : BG=8 : BGMAX=8 : PIERA=7 : PIERB=16
660 FOR PK=1 TO 10 : PICK(PK)=0 : NEXT PK
670 GOSUB 15000

695 REM ============================ opening scenario =============================
700 CLS
710 PRINT "              HONG KONG HUSTLE, 1997"
720 PRINT "             (c) David H. Ahl, 1986"
730 PRINT
740 PRINT " It is June 30, 1997, and China will take over the British Colony"
750 PRINT "of Hong Kong on July 1. Though the transition was meant to be smooth,"
760 PRINT "you've just learned the new authorities intend to confiscate much of"
770 PRINT "the property of the great trading houses."
780 PRINT " You, the Tai Pan, are being watched closely, so you disguise"
790 PRINT "yourself as a common factory worker and set out, using only public"
800 PRINT "transport, to recover as much of your liquid assets -- gold and"
810 PRINT "jewels -- as you can before the day ends. You'll stash them aboard"
820 PRINT "an inconspicuous sampan tied up near the Macau Jetfoil Pier."
830 PRINT " You may move the sampan once, from the pier to another near"
840 PRINT "Tsuen Wan in the New Territories -- but moving it more than once"
850 PRINT "would be far too dangerous."
860 PRINT " You can use any of several bus, tram, ferry, and rail lines"
870 PRINT "across Hong Kong Island, Kowloon, and the New Territories. Of all"
880 PRINT "the stops they serve, only "; BG; " are of real interest to you."
890 PRINT " Time is your biggest enemy -- you must be gone by midnight,"
900 PRINT "no matter what. Good luck!"
910 PRINT
920 INPUT "Press ENTER to begin your hustle!"; ANY$
930 CLS
940 PRINT "You may want to jot down this list for later reference."
950 PRINT
960 PRINT "Before setting out, you make a list of the places to visit:"
970 GOSUB 14000
980 INPUT "Press ENTER to continue"; ANY$
990 CLS
1000 PRINT "You set out from your home overlooking Repulse Bay and make"
1010 PRINT "your way down to the public bus stop."
1020 CURSTATION=1 : MIN=0 : BAG=0 : BGTOTAL=0 : BGX=0 : PERS=0 : FIRSTARR=1

1995 REM ============================ arrival / main loop ============================
2000 IF FIRSTARR=1 THEN GOTO 2030
2005 GOSUB 12000
2010 PRINT
2015 PRINT "You arrive at "; STA$(CURSTATION); "."
2030 FIRSTARR=0
2035 PRINT
2040 PRINT "Transit that stops here:"
2045 IF STNLINES(CURSTATION)=0 THEN PRINT "  (none -- you'll have to walk)"
2050 FOR K=1 TO STNLINES(CURSTATION)
2055   PRINT "  "; L$(STLINES(CURSTATION,K))
2060 NEXT K
2065 IF PERS=0 THEN GOTO 2120
2070 IF (CURSTATION=LSTOPS(TR,1)) OR (CURSTATION=LSTOPS(TR,LCOUNT(TR))) THEN GOTO 2100
2075 INPUT "Do you want to get off? "; AD$
2080 GOSUB 13000
2085 IF YES=1 THEN PERS=0 : GOTO 2120
2090 GOTO 3600
2100 PRINT "End of the line -- you'll have to get off."
2105 PERS=0
2120 IF (CURSTATION=PIERA) OR (CURSTATION=PIERB) THEN GOSUB 5000
2130 GOTO 3000

2995 REM ============================ choice menu ====================================
3000 PRINT
3005 PRINT "Do you want to:"
3010 PRINT "  (1) Make a pickup"
3015 PRINT "  (2) Take a bus, ferry, train, etc."
3020 PRINT "  (3) Walk to another transit stop"
3025 PRINT "  (4) Check your logbook"
3030 A1=1 : A2=4
3035 INPUT "Your choice? "; A
3040 GOSUB 13500
3045 IF A=1 THEN GOTO 4000
3050 IF A=2 THEN GOTO 3400
3055 IF A=3 THEN GOTO 6000
3060 IF A=4 THEN GOSUB 14000 : GOTO 3000

3395 REM ============================ board transit ==================================
3400 IF STNLINES(CURSTATION)=0 THEN PRINT "No transit stops here.": GOTO 3000
3405 GOTO 3450

3445 REM ============================ wait for transit ================================
3450 TR=STLINES(CURSTATION, INT(1+RND*STNLINES(CURSTATION)))
3455 IF CURSTATION=LSTOPS(TR,1) THEN DES=2 : GOTO 3475
3460 IF CURSTATION=LSTOPS(TR,LCOUNT(TR)) THEN DES=1 : GOTO 3475
3465 DES=INT(1+2*RND)
3475 IF DES=1 THEN TERM=LSTOPS(TR,1) ELSE TERM=LSTOPS(TR,LCOUNT(TR))
3480 PRINT
3485 PRINT "Here comes the "; L$(TR); ", heading toward "; STA$(TERM); "."
3490 MIN=MIN+1
3495 INPUT "Do you want to get on? "; AD$
3500 GOSUB 13000
3505 IF YES=0 THEN GOTO 3450
3510 PERS=1
3515 GOTO 3600

3595 REM ============================ ride one stop ===================================
3600 IF DES=1 THEN TERM=LSTOPS(TR,1) ELSE TERM=LSTOPS(TR,LCOUNT(TR))
3605 PRINT
3610 PRINT "You are on the "; L$(TR); ", heading toward "; STA$(TERM); "."
3615 IDX=0
3620 FOR K=1 TO LCOUNT(TR)
3625   IF LSTOPS(TR,K)=CURSTATION THEN IDX=K
3630 NEXT K
3635 IF DES=1 THEN DIR=-1 ELSE DIR=1
3640 IF DIR=-1 THEN SEG=IDX-1 ELSE SEG=IDX
3645 MIN=MIN+LTIMES(TR,SEG)
3650 CURSTATION=LSTOPS(TR,IDX+DIR)
3655 GOTO 2000

3995 REM ============================ pickup routine ==================================
4000 IF (BGX<>0) AND (BAG>=BGX) THEN PRINT "You can't carry any more bags.": GOTO 3000
4005 A1=1 : A2=BG
4010 INPUT "Which pickup do you want to make (by logbook number)? "; A
4015 GOSUB 13500
4020 PK=A
4025 IF PICK(PK)=0 THEN GOTO 4100
4030 PRINT "That number seems to be in error."
4035 INPUT "Want to check your logbook? "; AD$
4040 GOSUB 13000
4045 IF YES=1 THEN GOSUB 14000
4050 GOTO 3000

4100 PRINT "That pickup is at "; PKGDESD$(PK); "."
4105 FOUND=0
4110 FOR J=1 TO PKSTNU(PK)
4115   IF PKGSTA(PK,J)=CURSTATION THEN FOUND=J
4120 NEXT J
4125 IF FOUND<>0 THEN GOTO 4200
4130 PRINT "... which is too far to walk from here."
4135 PRINT "Perhaps you should try something else."
4140 GOTO 3000

4200 PRINT "... which is about a "; PKSTDS(PK,FOUND); "-minute walk from here. Off you go."
4205 MIN=MIN+PKSTDS(PK,FOUND)+INT(5+10*RND)
4210 BAG=BAG+1
4215 W=INT(1+9*RND)
4220 PRINT "Your "; FRD$(W); " gives you the bag they've been holding for you"
4225 PRINT "and wishes you good joss."
4230 PICK(PK)=1
4235 IF BAG<3 THEN GOTO 4300
4240 IF BGX=0 THEN BGX=INT(3+3*RND)
4245 IF BAG<BGX THEN GOTO 4300
4250 PRINT "That last bag was a heavy one -- you can't carry any more."
4255 PRINT "You'll have to get back to your sampan and unload."

4300 IF PKSTNU(PK)=1 THEN GOTO 4350
4305 PRINT
4310 PRINT "From here you can walk back out to any of these transit stops:"
4315 FOR J=1 TO PKSTNU(PK)
4320   PRINT "  ("; J; ") "; STA$(PKGSTA(PK,J))
4325 NEXT J
4330 A1=1 : A2=PKSTNU(PK)
4335 INPUT "Which place do you want to go to? "; A
4340 GOSUB 13500
4342 CURSTATION=PKGSTA(PK,A)
4344 MIN=MIN+PKSTDS(PK,A)
4346 GOTO 2000

4350 MIN=MIN+PKSTDS(PK,1)
4355 PRINT "You head back to "; STA$(CURSTATION); "."
4360 GOTO 2000

4995 REM ============================ sampan routine ==================================
5000 INPUT "Do you want to put your bags aboard the sampan? "; AD$
5005 GOSUB 13000
5010 IF YES=1 THEN GOTO 5100
5015 PRINT "Okay, it's up to you."
5020 GOTO 5200
5100 PRINT "Good -- you stow them safely out of sight."
5105 MIN=MIN+8
5110 BGTOTAL=BGTOTAL+BAG
5115 BAG=0
5120 BGX=0
5125 IF BGTOTAL>=BGMAX THEN GOTO 10000
5130 IF CURSTATION=PIERB THEN RETURN
5200 IF CURSTATION=PIERB THEN RETURN
5205 INPUT "Do you want to move the sampan to Tsuen Wan? "; AD$
5210 GOSUB 13000
5215 IF YES=1 THEN GOTO 5300
5220 PRINT "Okay -- the captain is ready when you are."
5225 RETURN
5300 PRINT "Okay. You shove off and make your silent way across the harbor."
5305 MIN=MIN+INT(20+20*RND)
5310 CURSTATION=PIERB
5315 GOSUB 12500
5320 PRINT "You are at Tsuen Wan, New Territories."
5325 PRINT "Transit that stops here:"
5330 FOR K=1 TO STNLINES(CURSTATION)
5335   PRINT "  "; L$(STLINES(CURSTATION,K))
5340 NEXT K
5345 RETURN

5995 REM ============================ walk to another stop ============================
6000 FOUND=0
6005 FOR K=1 TO 2
6010   IF WALKA(K)=CURSTATION THEN FOUND=K : TARGET=WALKB(K)
6015   IF WALKB(K)=CURSTATION THEN FOUND=K : TARGET=WALKA(K)
6020 NEXT K
6025 IF FOUND=0 THEN PRINT "There's nowhere within walking distance from here.": GOTO 3000
6030 PRINT "You can walk from here to "; STA$(TARGET); "."
6035 INPUT "Do you want to walk there? "; AD$
6040 GOSUB 13000
6045 IF YES=0 THEN GOTO 3000
6050 MIN=MIN+INT(6+6*RND)
6055 CURSTATION=TARGET
6060 GOTO 2000

9995 REM ============================ all gold collected! =============================
10000 CLS
10005 PRINT "You managed to pick up all "; BG; " bags of gold and jewels before"
10010 PRINT "midnight."
10015 PRINT
10020 PRINT "You sail away on your sampan and start your next great empire in"
10025 PRINT "Morristown, New Jersey."
10030 PRINT
10035 PRINT "                         Good Joss!"
10040 PRINT
10045 INPUT "Press ENTER to end"; ANY$
10050 END

10995 REM =========================== time's up! ========================================
11000 CLS
11005 PRINT "So sorry -- it is after midnight, and you have to get to your"
11010 PRINT "sampan and out of Hong Kong as quickly as possible."
11015 PRINT
11020 BGTOTAL=BGTOTAL+BAG
11025 IF BGTOTAL<BG THEN GOTO 11040
11030 BGTOTAL=BGTOTAL-1
11035 PRINT "Too bad -- in your rush to escape you had to drop a bag of gold."
11040 IF BGTOTAL<(0.6*BG) THEN GOTO 11060
11045 PRINT
11050 PRINT "You managed to get away with your life and "; BGTOTAL; " bags of"
11055 PRINT "gold and jewels. Not bad, but you could do better."
11056 GOTO 11075
11060 PRINT
11065 PRINT "You barely managed to escape with your life and only "; BGTOTAL
11070 PRINT "bags of gold and jewels. You lost much face, and you'll have"
11072 PRINT "difficulty becoming Tai Pan of a new venture."
11075 PRINT
11080 INPUT "Press ENTER to end"; ANY$
11085 END

11995 REM ============================ time check =======================================
12000 IF MIN>899 THEN GOTO 11000
12005 GOSUB 12500
12010 RETURN

12495 REM ============================ print time =======================================
12500 HR=INT(MIN/60)
12505 MN=MIN-60*HR
12510 IF HR<4 THEN HP=9+HR ELSE HP=HR-3
12515 IF (MIN<181) OR (MIN>900) THEN XD$="a.m." ELSE XD$="p.m."
12520 PRINT
12525 PRINT "Time: "; HP; ":";
12530 IF MN<10 THEN PRINT "0";
12535 PRINT MN; " "; XD$
12540 RETURN

12995 REM ============================ yes/no helper ====================================
13000 IF AD$="" THEN YES=1 : RETURN
13005 IF (LEFT$(AD$,1)="Y") OR (LEFT$(AD$,1)="y") THEN YES=1 : RETURN
13010 IF (LEFT$(AD$,1)="N") OR (LEFT$(AD$,1)="n") THEN YES=0 : RETURN
13015 PRINT "Don't understand your answer. Enter 'Y' or 'N' please."
13020 INPUT AD$
13025 GOTO 13000

13495 REM ======================= range-checked numeric input ==========================
13500 IF (A>=A1) AND (A<=A2) THEN RETURN
13505 PRINT "That's not one of the choices."
13510 INPUT A
13515 GOTO 13500

13995 REM ============================ print pickup log =================================
14000 PRINT
14005 PRINT "Your pickup notebook shows:"
14010 FOUNDANY=0
14015 FOR LI=1 TO BG
14020   IF PICK(LI)=0 THEN PRINT "  "; LI; ") "; PKGDESD$(LI) : FOUNDANY=1
14025 NEXT LI
14030 IF FOUNDANY=0 THEN PRINT "  (You've picked up everything on your list!)"
14035 PRINT
14040 RETURN

14995 REM ============================ shuffle pickups ===================================
15000 FOR I=1 TO PS-1
15005   K=I+INT((PS+1-I)*RND)
15010   TD$=PKGDESD$(I) : PKGDESD$(I)=PKGDESD$(K) : PKGDESD$(K)=TD$
15015   TN=PKSTNU(I) : PKSTNU(I)=PKSTNU(K) : PKSTNU(K)=TN
15020   FOR J=1 TO 2
15025     TS=PKGSTA(I,J) : PKGSTA(I,J)=PKGSTA(K,J) : PKGSTA(K,J)=TS
15030     TT=PKSTDS(I,J) : PKSTDS(I,J)=PKSTDS(K,J) : PKSTDS(K,J)=TT
15035   NEXT J
15040 NEXT I
15045 RETURN
