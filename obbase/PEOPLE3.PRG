*----------------------------------------------------------
* PEOPLE3.PRG - People Database Management System
* dBASE III PLUS
*
* dBASE III PLUS keeps procedures in a separate procedure
* file, so the menu routines are in PEOPLEP.PRG.
*----------------------------------------------------------

SET TALK OFF
SET ESCAPE ON
SET BELL OFF
SET SAFETY OFF
SET DELETED ON
SET CONFIRM ON
SET STATUS OFF
SET SCOREBOARD OFF
SET PROCEDURE TO PEOPLEP

* Create the database if it doesn't exist
IF .NOT. FILE("PEOPLE.DBF")
   DO MAKEFILE
ENDIF

* Open the database and its indexes
USE PEOPLE
IF .NOT. FILE("PEOPLE.NDX") .OR. .NOT. FILE("PENAME.NDX")
   INDEX ON STR(ID,5) TO PEOPLE
   INDEX ON UPPER(LASTNAME+FIRSTNAME) TO PENAME
ENDIF
SET INDEX TO PENAME, PEOPLE

* Main menu loop
STORE 0 TO choice
DO WHILE choice <> 7
   DO MAINMENU
   DO CASE
      CASE choice = 1
         DO ADDPERS
      CASE choice = 2
         DO SRCHPERS
      CASE choice = 3
         DO BROWPERS
      CASE choice = 4
         DO DELPERS
      CASE choice = 5
         DO PACKDATA
   ENDCASE
ENDDO

* Cleanup
CLOSE DATABASES
CLOSE PROCEDURE
CLEAR
SET STATUS ON
SET TALK ON
RETURN
