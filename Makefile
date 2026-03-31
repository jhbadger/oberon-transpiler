CC     = gcc
CXX    = g++
CFLAGS = -Wall -O -std=c99
PREFIX = $(HOME)
TVISION = ./tvision

all: obc oberon lextest parsetest

lextest: lextest.c lexer.c lexer.h
	$(CC) $(CFLAGS) -o lextest lextest.c lexer.c

obc: obc.c codegen.c parser.c lexer.c codegen.h parser.h lexer.h
	$(CC) $(CFLAGS) -o obc obc.c codegen.c parser.c lexer.c

oberon: oberon_ide.cpp
	$(CXX) -o oberon oberon_ide.cpp -I$(TVISION)/include -L$(TVISION) -ltvision -lncurses

parsetest: parsetest.c parser.c lexer.c parser.h lexer.h
	$(CC) $(CFLAGS) -o parsetest parsetest.c parser.c lexer.c

install: obc oberon
	cp obc $(PREFIX)/bin
	cp oberon $(PREFIX)/bin

clean:
	rm -f obc lextest parsetest

.PHONY: all clean install
