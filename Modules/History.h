#ifndef OBC_HISTORY_H_
#define OBC_HISTORY_H_

/*
 * History — command-line history for program prompts.
 *
 * ReadLine  : display prompt, accept input with history navigation and
 *             in-line editing; result is NUL-terminated in the output buffer.
 * Add       : explicitly add an entry to history (ReadLine does this automatically).
 * Load/Save : persist history to/from a plain-text file (one entry per line).
 * Clear     : erase all history entries.
 *
 * All char* parameters from Oberon carry an accompanying _len argument
 * (the array capacity, including the NUL terminator) as per the obc ABI.
 */

/* Read a line from the terminal with history and in-line editing.
   result must point to a buffer of at least 256 bytes. */
void History_ReadLine(char *prompt, char *result);

/* Add a line to the history buffer (skips duplicates of the most recent entry). */
void History_Add(char *line);

/* Load history from a file. Returns 1 on success, 0 on error. */
int  History_Load(char *filename);

/* Save history to a file. Returns 1 on success, 0 on error. */
int  History_Save(char *filename);

/* Clear all history entries. */
void History_Clear(void);

#endif /* OBC_HISTORY_H_ */
