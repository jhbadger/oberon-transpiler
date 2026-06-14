#ifndef OBC_REGEX_H_
#define OBC_REGEX_H_

/* POSIX extended regex wrapper.
 * FindAt searches str[startPos..] for pattern; returns absolute start pos or -1.
 * State from the last FindAt is used by MatchLen, GroupStart, GroupLen, GetGroup.
 * \d \D \w \W \s \S \n \t \r are translated to POSIX ERE equivalents. */

int  Regex_FindAt(char *pattern, char *str, int startPos);
int  Regex_MatchLen(void);
int  Regex_NumGroups(char *pattern);
int  Regex_GroupStart(int n);
int  Regex_GroupLen(int n);
void Regex_GetGroup(int n, char *result);

#endif /* OBC_REGEX_H_ */
