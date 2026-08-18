10 REM
20 REM  TOUR DE FRANCE -- A 22-DAY CYCLING RACE
30 REM  Adapted for basic.mod from the (c) 1986 David H. Ahl original
40 REM  (Small Basic Computer Adventures, 25th Anniversary Edition)
50 REM

95 REM ============================ stage data =====================================
100 DIM PLACE$(22)
110 DIM TERR(22)
120 DIM DIST(22)
130 DIM TYPED$(5)
140 DIM PR(10)
150 DIM PM(8)
160 DIM PP(14)
170 DIM TTM(6)
180 DIM TTR(6)
190 DIM WSG(6)

200 PLACE$(1)="Lille" : TERR(1)=1 : DIST(1)=220
210 PLACE$(2)="Compiegne" : TERR(2)=1 : DIST(2)=190
220 PLACE$(3)="Rouen" : TERR(3)=2 : DIST(3)=210
230 PLACE$(4)="Le Mans" : TERR(4)=1 : DIST(4)=230
240 PLACE$(5)="Nantes" : TERR(5)=2 : DIST(5)=190
250 PLACE$(6)="La Rochelle" : TERR(6)=1 : DIST(6)=180
260 PLACE$(7)="La Rochelle" : TERR(7)=5 : DIST(7)=0
270 PLACE$(8)="Bordeaux" : TERR(8)=1 : DIST(8)=200
280 PLACE$(9)="Pau" : TERR(9)=2 : DIST(9)=220
290 PLACE$(10)="Luchon" : TERR(10)=3 : DIST(10)=150
300 PLACE$(11)="Toulouse" : TERR(11)=2 : DIST(11)=120
310 PLACE$(12)="Millau" : TERR(12)=2 : DIST(12)=230
320 PLACE$(13)="Grenoble" : TERR(13)=4 : DIST(13)=60
330 PLACE$(14)="Grenoble" : TERR(14)=5 : DIST(14)=0
340 PLACE$(15)="Alpe d'Huez" : TERR(15)=3 : DIST(15)=110
350 PLACE$(16)="Briancon" : TERR(16)=3 : DIST(16)=160
360 PLACE$(17)="Gap" : TERR(17)=2 : DIST(17)=150
370 PLACE$(18)="Lyon" : TERR(18)=1 : DIST(18)=220
380 PLACE$(19)="Dijon" : TERR(19)=1 : DIST(19)=200
390 PLACE$(20)="Troyes" : TERR(20)=1 : DIST(20)=180
400 PLACE$(21)="Melun" : TERR(21)=4 : DIST(21)=50
410 PLACE$(22)="Paris" : TERR(22)=1 : DIST(22)=160

420 TYPED$(1)="Mostly flat with small hills."
430 TYPED$(2)="Hills, gorges, steep slopes."
440 TYPED$(3)="Mountains."
450 TYPED$(4)="Time trial against the clock."
460 TYPED$(5)="Rest day -- no racing."

465 REM -- road-hazard event thresholds (cumulative, out of PRT) --
470 PR(1)=5 : PR(2)=10 : PR(3)=15 : PR(4)=20 : PR(5)=25
480 PR(6)=30 : PR(7)=35 : PR(8)=40 : PR(9)=45 : PR(10)=50
490 PRT=50

495 REM -- mechanical-breakdown event thresholds (cumulative, out of PMT) --
500 PM(1)=5 : PM(2)=10 : PM(3)=15 : PM(4)=20
510 PM(5)=25 : PM(6)=30 : PM(7)=40 : PM(8)=45
520 PMT=45

525 REM -- physical-problem event thresholds (cumulative, out of PPT) --
530 PP(1)=8 : PP(2)=13 : PP(3)=18 : PP(4)=23 : PP(5)=28
540 PP(6)=33 : PP(7)=38 : PP(8)=43 : PP(9)=48 : PP(10)=56
550 PP(11)=61 : PP(12)=66 : PP(13)=71 : PP(14)=74
560 PPT=74

595 REM ============================ opening scenario ================================
600 CLS
605 PRINT "              TOUR DE FRANCE BICYCLE RACE"
610 PRINT "                (c) David H. Ahl, 1986"
615 PRINT
620 INPUT "Press ENTER to continue"; ANY$
625 CLS
630 PRINT " You are a bicycle racer entered in the 22-day Tour de France"
635 PRINT "bicycle race around France. Your objective is to win the race by"
640 PRINT "having the lowest overall elapsed time. In addition, you must try"
645 PRINT "to win as many individual stages as possible, since stage wins"
650 PRINT "also count toward the overall points prize."
655 PRINT " Each day you pick your gear range, the computer pedals your"
660 PRINT "bicycle, and various hazards -- weather, road conditions,"
665 PRINT "mechanical breakdowns, and physical problems -- occur to hamper"
670 PRINT "your progress. Near the end of each stage you decide when to"
675 PRINT "launch your sprint to the finish."
680 PRINT
685 INPUT "Press ENTER to continue"; ANY$
690 CLS

795 REM ============================ fitness and training =============================
800 PRINT
810 PRINT "About your physical fitness: are you (1) in fantastic health,"
820 PRINT "(2) excellent shape, (3) quite good, (4) okay, (5) poor"
830 A1=1 : A2=5
840 INPUT "Please enter a number between 1 and 5"; A
850 GOSUB 6300
860 FIT = .57 - .04*A
870 PRINT

900 PRINT "How many weeks do you intend to take off from work or school to"
910 INPUT "practice and prepare for the race"; WK
920 IF WK>12 THEN WK=12
930 IF WK>5 THEN GOTO 970
940 PRINT "You must be joking. You'll need at least six"
950 PRINT "weeks if you want to be a real contender. Now ..."
960 GOTO 900
970 FIT = FIT - (12-WK)*.05
980 PRINT

990 DAY=0 : GDGR=1 : PREVTERR=0 : CURPLACE$="Reims" : CL=0 : PPX=0 : FIN=1
995 INPUT "Press ENTER for the start of Stage 1"; ANY$
998 CLS

999 REM ============================ main day loop ====================================
1000 DAY=DAY+1
1005 IF DAY>22 THEN GOTO 9000
1010 PRINT
1015 PRINT "Date: July "; DAY; ".  You are at "; CURPLACE$; "."
1020 IF TERR(DAY)<5 THEN GOTO 1100
1025 PRINT "Today, thank goodness, is a rest and recuperation day."
1027 PREVTERR=TERR(DAY)
1030 GOTO 1000

1100 PRINT "Your destination is "; PLACE$(DAY); ", "; DIST(DAY); " km from here."
1110 PRINT "Type of racing this stage: "; TYPED$(TERR(DAY))
1120 IF TERR(DAY)<>PREVTERR THEN GOTO 1300
1130 PRINT "Do you want a different basic gear range than yesterday";
1140 INPUT AD$
1150 GOSUB 6100
1160 IF YES=0 THEN GOTO 2000
1170 GDGR=1
1180 GOTO 1300

1295 REM ============================ gear range selection =============================
1300 PRINT "Naturally you will shift gears, but what will be your basic"
1310 PRINT "gear range (ring and cog) for the day?"
1320 INPUT "First the ring (40 or 52)"; RING
1330 IF RING=40 OR RING=52 THEN GOTO 1370
1340 PRINT "You don't have that ring."
1350 INPUT "Enter 40 or 52 please"; RING
1360 GOTO 1330
1370 INPUT "Which cog (13, 15, 17, 19, 21, 23, or 25)"; COG
1380 IF COG=13 OR COG=15 OR COG=17 OR COG=19 OR COG=21 OR COG=23 OR COG=25 THEN GOTO 1420
1390 PRINT "Sorry, you don't have that cog. Please try again."
1400 GOTO 1370
1420 IF (COG=13 AND RING=40) OR (COG=25 AND RING=52) THEN GOTO 1440
1430 GR = RING/COG
1435 GOTO 1500
1440 PRINT "The chain line will be badly skewed with that combination."
1445 GOTO 1460
1450 REM (fall through from the invalid-combo message above)
1460 INPUT "Let's do it again. First the ring"; RING
1465 GOTO 1330

1495 REM ============================ gear-ratio feedback ==============================
1500 IF TERR(DAY)=4 THEN GOTO 2000
1510 RATE$=""
1515 IF GR>3.2 THEN RATE$="high"
1520 IF GR<1.8 THEN RATE$="low"
1525 IF RATE$="" THEN GOTO 1560
1530 PRINT "That ratio sounds very "; RATE$; ". Do you want to change it";
1540 INPUT AD$
1545 GOSUB 6100
1550 IF YES=1 THEN GOTO 1460

1560 IF TERR(DAY)=3 AND GR>2.3 THEN GOTO 1600
1570 IF GR>3 THEN GDGR = 1.35 - .14*GR
1580 GOTO 2000

1600 PRINT "For mountainous terrain, that's a rather high basic gear ratio."
1610 PRINT "Do you want to stick with it";
1620 INPUT AD$
1630 GOSUB 6100
1640 IF YES=0 THEN GOTO 1460
1650 GDGR = 1.3 - .19*GR
1660 GOTO 2000

1995 REM ============================ start of stage / pedaling =========================
2000 PRINT
2005 DEPMIN = INT(59*RND)
2010 PRINT "Your departure time is scheduled at 9:";
2015 IF DEPMIN<10 THEN PRINT "0"; DEPMIN
2020 IF DEPMIN>=10 THEN PRINT DEPMIN
2025 PRINT
2030 RPS=130
2040 GOSUB 6000
2050 KPH = RPM * .1292706 * GR * GDGR
2060 FV=KPH : GOSUB 6200
2070 PRINT " kph."
2080 PRINT
2090 TDL=0

2100 REM road hazards
2110 GOSUB 3000
2120 IF TERR(DAY)=3 AND GR>2.7 THEN PP(1)=PP(1)+10 : PPT=PPT+10 : PPX=1
2130 PRINT
2140 REM mechanical breakdowns
2150 GOSUB 3500
2160 PRINT
2170 REM physical problems
2180 GOSUB 4500
2190 IF PPX=1 THEN PP(1)=PP(1)-10 : PPT=PPT-10 : PPX=0

2200 PRINT
2210 KMLEFT = INT(20+20*RND)
2220 PRINT "Time for a quick breather. You have about "; KMLEFT; " km to go."
2230 PRINT
2240 INPUT "Press ENTER when you're ready to go"; ANY$
2250 PRINT "Okay, on the road again ..."

2295 REM ============================ sprint to the finish =============================
2300 CLS
2310 PRINT "You're coming up on 10 km from the end."
2320 A1=0 : A2=10
2330 INPUT "How far out do you want to start your sprint (0-10 km)"; A
2340 GOSUB 6300
2345 DSP1 = A
2350 PRINT
2360 RPS=140
2370 GOSUB 6000
2380 KSR = RPM * .396
2390 FV=KSR : GOSUB 6200
2400 PRINT " kph."
2410 PRINT
2420 IF DSP1>3 THEN PRINT "Puff ... puff ... puff. That was a L-O-N-G sprint!"

2430 TMSD = DSP1/KSR
2440 TMRD = (DIST(DAY)-DSP1)/KPH
2450 TTM(1) = TMSD+TMRD+TDL

2495 REM ============================ race summary / rivals =============================
2500 PRINT
2510 PRINT "Race summary (total time for the stage, in hours):"
2520 PRINT "  You (Rider 1): ";
2530 FV=TTM(1) : GOSUB 6200
2540 PRINT
2550 IF TERR(DAY)=3 THEN GQ=.3 ELSE GQ=.4
2560 FOR I=2 TO 6
2570 RPM2 = 70+20*RND
2580 TTM(I) = DIST(DAY)/(GQ*RPM2) + 1.4*RND
2590 PRINT "  Rider "; I; ": ";
2600 FV=TTM(I) : GOSUB 6200
2610 PRINT
2620 NEXT I

2630 WS=1 : TTS=TTM(1)
2640 FOR I=2 TO 6
2650 IF TTM(I)<TTS THEN TTS=TTM(I) : WS=I
2660 NEXT I

2670 FOR I=1 TO 6
2680 TTR(I)=TTR(I)+TTM(I)
2690 NEXT I
2700 WT=1 : TTT=TTR(1)
2710 FOR I=2 TO 6
2720 IF TTR(I)<TTT THEN TTT=TTR(I) : WT=I
2730 NEXT I
2740 WSG(WS)=WSG(WS)+1

2750 PRINT
2760 PRINT "Stage winner: Rider "; WS; "   Overall leader: Rider "; WT
2770 IF WS=1 THEN PRINT "  That's YOU!"
2780 PRINT

2790 PREVTERR=TERR(DAY)
2800 CURPLACE$=PLACE$(DAY)
2810 GOTO 1000

2995 REM ============================ road hazards table ================================
3000 RN = INT(PRT*RND)
3005 FOR I=1 TO 10
3010 IF RN<=PR(I) THEN GOTO 3020
3015 NEXT I
3017 I=10
3020 ON I GOTO 3100,3110,3120,3130,3140,3150,3160,3170,3180,3190

3100 PRINT "Mostly gravel roads this stage. You'll have to slow down." : TDL=TDL+.8 : GOTO 3200
3110 PRINT "The roads in this area are very bumpy and will slow you down." : TDL=TDL+.5 : GOTO 3200
3120 PRINT "Hot weather has caused the roads to become slippery from oil seepage." : TDL=TDL+.3 : GOTO 3200
3130 PRINT "The wind is at your back, making for a very fast ride!" : TDL=TDL-.3 : GOTO 3200
3140 PRINT "You're heading straight into the wind today. Tough going." : TDL=TDL+.5 : GOTO 3200
3150 PRINT "There is a gusty sidewind today, creating balance problems." : TDL=TDL+.3 : GOTO 3200
3160 PRINT "Dreary day: drizzle, fog, and a clammy chill in the air." : TDL=TDL+.2 : GOTO 3200
3170 PRINT "Horrible weather! Icy rain stings your face, your shoes are soaked,"
3175 PRINT "and there are few spectators to cheer you on." : TDL=TDL+.5 : GOTO 3200
3180 PRINT "Mud and puddles on the road cause you to slide and skid all over." : TDL=TDL+.4 : GOTO 3200
3190 PRINT "Today is a crisp, clear day in the French countryside."
3200 RETURN

3495 REM ============================ mechanical breakdowns table =======================
3500 RN = INT(PMT*RND)
3505 FOR I=1 TO 8
3510 IF RN<=PM(I) THEN GOTO 3520
3515 NEXT I
3517 I=8
3520 ON I GOTO 3600,3700,3800,3900,4000,4100,4200,4300

3600 PRINT "You have a broken spoke. Want to fix it now";
3605 INPUT AD$
3610 GOSUB 6100
3615 IF YES=1 THEN TDL=TDL+.1
3620 IF YES=0 THEN TDL=TDL+.15
3625 GOTO 4390

3700 PRINT "You got a flat tire. You'll have to change it now."
3705 TDL=TDL+.1
3710 GOTO 4390

3800 PRINT "Your brakes tend to lock every time you apply them hard. You can"
3805 PRINT "nurse them along or fix them here. Want to fix them now";
3810 INPUT AD$
3815 GOSUB 6100
3820 IF YES=1 THEN TDL=TDL+.2
3825 IF YES=0 THEN TDL=TDL+.4
3830 GOTO 4390

3900 PRINT "You seem to be missing shifts to your 19 cog -- perhaps a tooth"
3905 PRINT "is worn. You can shift around it or fix it here. Want to fix it";
3910 INPUT AD$
3915 GOSUB 6100
3920 IF YES=1 THEN TDL=TDL+.2
3925 IF YES=0 THEN TDL=TDL+.4
3930 GOTO 4390

4000 PRINT "On a tight corner you narrowly missed a spill, but your toe clip"
4005 PRINT "got bent on a boulder near the road. Want to bend it out now";
4010 INPUT AD$
4015 GOSUB 6100
4020 IF YES=1 THEN TDL=TDL+.1
4025 IF YES=0 THEN TDL=TDL+.2
4030 GOTO 4390

4100 PRINT "Uh oh! Chain broke. You've no choice but to fix it now."
4105 TDL=TDL+.15
4110 GOTO 4390

4200 PRINT "WHOOPS! Took a corner too fast, lost traction, slid, and CRASHED!"
4205 CR=1
4210 RN2=RND
4215 IF RN2<.03 THEN GOTO 4260
4220 IF RN2<.5 THEN GOTO 4245
4225 PRINT "You pick yourself and your bicycle up. You're both scratched and"
4226 PRINT "a bit beaten up, but there's no serious damage, so you carry on."
4230 TDL=TDL+.3
4235 GOTO 4390
4245 PRINT "You twisted your ankle and it is very painful. You know it will"
4246 PRINT "slow you down, but there's no way you'd drop out of the race, so"
4247 PRINT "you pick up your bicycle and get on your way."
4250 TDL=TDL+.8
4255 GOTO 4390
4260 PRINT "Blood is all over the place; an ambulance is called and you are"
4261 PRINT "rushed to the local hospital."
4265 PRINT "Bad news! You dislocated your shoulder and you're out of the race."
4270 FIN=0
4275 GOTO 9500

4300 PRINT "Bicycle ran like a charm today. No problems at all!"
4390 RETURN

4495 REM ============================ physical problems table ===========================
4500 RN = INT(PPT*RND)
4505 FOR I=1 TO 14
4510 IF RN<=PP(I) THEN GOTO 4520
4515 NEXT I
4517 I=14
4520 ON I GOTO 4600,4700,4800,4900,5000,5100,5200,5300,5400,5500,5600,5700,5800,5900

4600 X = INT(DIST(DAY)/50)
4605 IF X<2 THEN X=2
4610 PRINT "You're pushing yourself to the absolute limit, and after "; X; " hours"
4615 PRINT "you totally collapse. The medics give you oxygen and bring you"
4620 PRINT "around, but warn you against resuming the race."
4625 IF CL>0 THEN GOTO 4680
4630 CL=1
4635 IF RND>.8 THEN GOTO 4660
4640 PRINT "But nothing can defeat your competitive spirit, and you vow to"
4645 PRINT "press on regardless."
4650 TDL=TDL+1
4655 GOTO 5990
4660 PRINT "You heard of another rider dying from overexertion last year, so"
4665 PRINT "you follow the doctor's advice and withdraw from the race."
4670 FIN=0
4675 GOTO 9500
4680 PRINT "This is the second time you've collapsed in this race, so you"
4685 PRINT "reluctantly concede that this just isn't your year and you"
4690 PRINT "withdraw from the race."
4695 FIN=0
4696 GOTO 9500

4700 PRINT "You have a terrible abdominal pain -- something you ate, perhaps?"
4705 PRINT "You'll have to slow down a bit."
4710 TDL=TDL+.4
4715 GOTO 5990

4800 PRINT "You're having difficulty breathing and feeling lightheaded."
4805 GOTO 4830

4830 PRINT "You recognize this as an early warning sign of total collapse and"
4835 PRINT "wisely decide to slow your pace a bit."
4840 TDL=TDL+.3
4845 GOTO 5990

4900 PRINT "You seem to be seeing through a haze -- and it's not the weather."
4905 PRINT "Occasionally, you can't seem to focus at all."
4910 GOTO 4830

5000 PRINT "Uh oh! A muscle in your calf seems to have turned to jelly. It's"
5005 PRINT "not particularly painful, but it's completely out of control."
5006 PRINT "You'll have to slow down a bit."
5010 TDL=TDL+.3
5015 GOTO 5990

5100 PRINT "You have a sharp pain in your lower back. It doesn't seem to be"
5105 PRINT "injured -- perhaps you're just overly tense."
5110 TDL=TDL+.2
5115 GOTO 5990

5200 PRINT "The gearing you've been using is tough on your legs and you've"
5205 PRINT "developed shin splints. You'll have to back off your blistering"
5206 PRINT "pace a bit."
5210 TDL=TDL+.3
5215 GOTO 5990

5300 PRINT "Terrible pain in the balls of your feet. Your toe clip seems to"
5305 PRINT "be adjusted correctly -- maybe it's these new cleats. In any"
5306 PRINT "event, you decide to back off a bit, just for today."
5310 TDL=TDL+.3
5315 GOTO 5990

5400 PRINT "A medic takes a look at you during the lunch break and declares"
5405 PRINT "you have a salt/water imbalance. 'Drink more water along the way,'"
5406 PRINT "he recommends, 'and don't forget your salt pills.'"
5415 GOTO 5990

5500 IF TERR(DAY)<>3 THEN GOTO 5900
5505 PRINT "The altitude is getting to you in the mountains. You're short of"
5510 PRINT "breath and you feel lightheaded."
5515 GOTO 5990

5600 PRINT "Your saddle feels like it has appended itself to your body. A"
5605 PRINT "cyst seems to be starting, something you want to avoid at all"
5606 PRINT "costs. You add some padding and back off your pace just a tad."
5610 TDL=TDL+.15
5615 GOTO 5990

5700 PRINT "The blistering pace you've been keeping has played havoc with"
5705 PRINT "your knees. Nevertheless, you'll have to slow down a bit."
5710 TDL=TDL+.2
5715 GOTO 5990

5800 PRINT "You developed a bad cramp in your legs. You'll have to take it"
5805 PRINT "just a bit easier."
5810 TDL=TDL+.15
5815 GOTO 5990

5900 IF CR=1 THEN GOTO 4500
5905 PRINT "You're feeling fit as a fiddle and have no physical problems today."
5990 RETURN

5995 REM ============================ pedal-the-bicycle helper ==========================
6000 RPM = INT((RPS + (30+40*RND)) * FIT)
6005 PRINT "Pedaling your bicycle at a rate of "; RPM; " rpm."
6010 PRINT "Calculating speed...."
6015 RETURN

6095 REM ============================ yes/no helper =====================================
6100 IF LEFT$(AD$,1)="Y" OR LEFT$(AD$,1)="y" THEN YES=1 : RETURN
6105 IF LEFT$(AD$,1)="N" OR LEFT$(AD$,1)="n" THEN YES=0 : RETURN
6110 PRINT "Don't understand your answer. Enter 'Y' or 'N' please";
6115 INPUT AD$
6120 GOTO 6100

6195 REM ============================ two-decimal formatter (prints FV as W.DD) =========
6200 FW = INT(FV)
6205 FD = INT((FV-FW)*100)
6210 IF FD<10 THEN PRINT FW;".0";FD;
6215 IF FD>=10 THEN PRINT FW;".";FD;
6220 RETURN

6295 REM ============================ range-checked numeric input =======================
6300 IF (A>=A1) AND (A<=A2) THEN RETURN
6305 IF A<A1 THEN PRINT "That's too small. Try again."
6306 IF A>A2 THEN PRINT "That's too large. Try again."
6310 INPUT A
6315 GOTO 6300

8995 REM ============================ end-of-race summary ===============================
9000 PRINT
9005 PRINT "The Tour de France has ended!"
9010 PRINT
9015 X=0 : WS=1
9020 FOR I=1 TO 6
9025 IF WSG(I)>X THEN X=WSG(I) : WS=I
9030 NEXT I
9035 PRINT "Winner of the most stages ("; X; ") was Rider "; WS;
9040 IF WS=1 THEN PRINT "  That's YOU!"
9045 IF WS<>1 THEN PRINT

9050 PRINT "Overall winner by elapsed time was Rider "; WT;
9055 IF WT=1 THEN PRINT "  That's YOU!"
9060 IF WT<>1 THEN PRINT

9065 TTT=1000000 : WT2=0
9070 FOR I=1 TO 6
9075 PTS = TTR(I)-2*WSG(I)
9080 IF PTS<TTT THEN TTT=PTS : WT2=I
9085 NEXT I

9090 PRINT "Overall points winner (time and stages) was Rider "; WT2;
9095 IF WT2=1 THEN PRINT "  That's YOU!"
9096 IF WT2<>1 THEN PRINT

9100 FIN=1
9110 GOTO 9500

9495 REM ============================ end of game =======================================
9500 IF FIN=1 THEN GOTO 9520
9505 PRINT
9510 PRINT "Too bad. That's it for this year, but there's always next year...."
9520 PRINT
9525 INPUT "Press ENTER to end"; ANY$
9530 END
