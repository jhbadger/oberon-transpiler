*----------------------------------------------------------
* PEOPLEP.PRG - Procedure file for PEOPLE3.PRG
* dBASE III PLUS (opened with SET PROCEDURE TO PEOPLEP)
*----------------------------------------------------------

*----------------------------------------------------------
* Draw main menu and get selection
*----------------------------------------------------------
PROCEDURE MAINMENU
CLEAR
@ 0,0 TO 24,79 DOUBLE
@ 2,0 TO 2,79 DOUBLE
@ 1,25 SAY "PEOPLE DATABASE MANAGEMENT"

@  5,25 TO 14,55 DOUBLE
@  5,32 SAY " Main Menu "
@  6,27 SAY "1. Add New Person"
@  7,27 SAY "2. Search by Name"
@  8,27 SAY "3. Browse Database"
@  9,27 SAY "4. Delete Person"
@ 10,27 SAY "5. Pack Database"
@ 11,26 SAY "------------------"
@ 12,27 SAY "7. Exit"

choice = 0
DO WHILE choice < 1 .OR. choice > 7 .OR. choice = 6
   @ 16,25 SAY "Enter selection (1-7): " GET choice PICTURE "9"
   READ
ENDDO
RETURN

*----------------------------------------------------------
* Create the database file
*----------------------------------------------------------
PROCEDURE MAKEFILE
* A program cannot build a new structure by itself in
* dBASE III PLUS: CREATE asks for the fields on screen.
CLEAR
@  2,10 SAY "PEOPLE.DBF was not found.  Define these fields:"
@  4,12 SAY "ID         Numeric     5"
@  5,12 SAY "LASTNAME   Character  20"
@  6,12 SAY "FIRSTNAME  Character  15"
@  7,12 SAY "ADDRESS    Character  30"
@  8,12 SAY "CITY       Character  20"
@  9,12 SAY "STATE      Character   2"
@ 10,12 SAY "ZIP        Character  10"
@ 11,12 SAY "PHONE      Character  14"
@ 12,12 SAY "EMAIL      Character  40"
@ 13,12 SAY "BIRTHDATE  Date        8"
@ 15,10 SAY "then save with Ctrl-End and answer N to adding records."
@ 17,10 SAY ""
WAIT
CREATE PEOPLE
RETURN

*----------------------------------------------------------
* Add New Person
*----------------------------------------------------------
PROCEDURE ADDPERS
SELECT 1
SET INDEX TO PEOPLE
IF RECCOUNT() = 0
   m_id = 1
ELSE
   GO BOTTOM
   m_id = ID + 1
ENDIF
SET INDEX TO PENAME, PEOPLE

m_last  = SPACE(20)
m_first = SPACE(15)
m_addr  = SPACE(30)
m_city  = SPACE(20)
m_state = SPACE(2)
m_zip   = SPACE(10)
m_phone = SPACE(14)
m_email = SPACE(40)
m_birth = CTOD("  /  /  ")

CLEAR
@  3,10 TO 17,70 DOUBLE
@  3,30 SAY " Add New Person "
@  5,12 SAY "ID:        " + STR(m_id, 5)
@  6,12 SAY "Last Name: "  GET m_last
@  7,12 SAY "First Name:"  GET m_first
@  8,12 SAY "Address:   "  GET m_addr
@  9,12 SAY "City:      "  GET m_city
@ 10,12 SAY "State:     "  GET m_state PICTURE "!!"
@ 10,30 SAY "Zip:  "       GET m_zip
@ 11,12 SAY "Phone:     "  GET m_phone PICTURE "(999) 999-9999"
@ 12,12 SAY "Email:     "  GET m_email
@ 13,12 SAY "Birthdate: "  GET m_birth
@ 15,12 SAY "Press Ctrl-W to save, Esc to cancel"
READ

* READKEY() is 12 for Esc, 268 for Esc after a change
IF READKEY() <> 12 .AND. READKEY() <> 268
   APPEND BLANK
   * two REPLACEs keep each command under 254 characters
   REPLACE ID WITH m_id, LASTNAME WITH m_last, FIRSTNAME WITH m_first,;
           ADDRESS WITH m_addr, CITY WITH m_city
   REPLACE STATE WITH m_state, ZIP WITH m_zip, PHONE WITH m_phone,;
           EMAIL WITH m_email, BIRTHDATE WITH m_birth
   @ 20,20 SAY "Record added successfully! Press any key..."
   WAIT ""
ENDIF
RETURN

*----------------------------------------------------------
* Search for Person by Last Name
*----------------------------------------------------------
PROCEDURE SRCHPERS
m_search = SPACE(20)

CLEAR
@  8,15 TO 14,65 DOUBLE
@  8,30 SAY " Search by Last Name "
@ 10,17 SAY "Enter last name: " GET m_search
@ 12,17 SAY "Press Enter to search, Esc to cancel"
READ

IF READKEY() <> 12 .AND. READKEY() <> 268 .AND. LEN(TRIM(m_search)) > 0
   SET INDEX TO PENAME, PEOPLE
   SEEK UPPER(TRIM(m_search))

   IF FOUND()
      DO SHOWREC
   ELSE
      @ 16,20 SAY "No matching record found! Press any key..."
      WAIT ""
   ENDIF
ENDIF
RETURN

*----------------------------------------------------------
* Display found record
*----------------------------------------------------------
PROCEDURE SHOWREC
CLEAR
@  3,10 TO 17,70 DOUBLE
@  3,32 SAY " Record Found "
@  5,12 SAY "ID:         " + STR(ID, 5)
@  6,12 SAY "Last Name:  " + LASTNAME
@  7,12 SAY "First Name: " + FIRSTNAME
@  8,12 SAY "Address:    " + ADDRESS
@  9,12 SAY "City:       " + TRIM(CITY) + ", " + STATE + "  " + ZIP
@ 10,12 SAY "Phone:      " + PHONE
@ 11,12 SAY "Email:      " + TRIM(EMAIL)
@ 12,12 SAY "Birthdate:  " + DTOC(BIRTHDATE)
@ 15,12 SAY "Press any key to continue..."
WAIT ""
RETURN

*----------------------------------------------------------
* Browse all records
*----------------------------------------------------------
PROCEDURE BROWPERS
IF RECCOUNT() = 0
   @ 20,20 SAY "Database is empty! Press any key..."
   WAIT ""
   RETURN
ENDIF

CLEAR
BROWSE FIELDS ID, LASTNAME, FIRSTNAME, CITY, STATE, PHONE
RETURN

*----------------------------------------------------------
* Delete a Person
*----------------------------------------------------------
PROCEDURE DELPERS
m_search = SPACE(20)

CLEAR
@  8,15 TO 14,65 DOUBLE
@  8,33 SAY " Delete Person "
@ 10,17 SAY "Enter last name: " GET m_search
@ 12,17 SAY "Press Enter to search, Esc to cancel"
READ

IF READKEY() <> 12 .AND. READKEY() <> 268 .AND. LEN(TRIM(m_search)) > 0
   SET INDEX TO PENAME, PEOPLE
   SEEK UPPER(TRIM(m_search))

   IF FOUND()
      CLEAR
      @  8,15 TO 16,65 DOUBLE
      @  8,32 SAY " Confirm Delete "
      @ 10,17 SAY "Name:  " + TRIM(FIRSTNAME) + " " + TRIM(LASTNAME)
      @ 11,17 SAY "Phone: " + PHONE

      m_conf = " "
      @ 13,17 SAY "Delete this record? (Y/N): " GET m_conf PICTURE "!"
      READ

      IF m_conf = "Y"
         DELETE
         @ 20,20 SAY "Record marked for deletion! Press any key..."
      ELSE
         @ 20,20 SAY "Delete cancelled. Press any key..."
      ENDIF
      WAIT ""
   ELSE
      @ 16,20 SAY "No matching record found! Press any key..."
      WAIT ""
   ENDIF
ENDIF
RETURN

*----------------------------------------------------------
* Pack the Database (removes deleted records)
*----------------------------------------------------------
PROCEDURE PACKDATA
m_conf = " "

CLEAR
@ 10,20 TO 15,60 DOUBLE
@ 10,33 SAY " Pack Database "
@ 12,22 SAY "Permanently remove deleted records?"
@ 13,22 SAY "Confirm (Y/N): " GET m_conf PICTURE "!"
READ

IF m_conf = "Y"
   * PACK rebuilds the open indexes as well
   PACK
   @ 20,20 SAY "Database packed successfully! Press any key..."
   WAIT ""
ENDIF
RETURN
