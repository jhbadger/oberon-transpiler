CC     = gcc
CFLAGS = -Wall -O -std=c99
PREFIX = $(HOME)

all: obc lextest parsetest

lextest: lextest.c lexer.c lexer.h
	$(CC) $(CFLAGS) -o lextest lextest.c lexer.c

obc: obc.c codegen.c parser.c lexer.c codegen.h parser.h lexer.h
	$(CC) $(CFLAGS) -o obc obc.c codegen.c parser.c lexer.c

parsetest: parsetest.c parser.c lexer.c parser.h lexer.h
	$(CC) $(CFLAGS) -o parsetest parsetest.c parser.c lexer.c

install: obc
	cp obc $(PREFIX)/bin

clean:
	rm -f obc lextest parsetest

.PHONY: all clean install
