CC       = gcc
CXX      = g++
CFLAGS   = -Wall -O -std=c99
CXXFLAGS = -O
PREFIX   = $(HOME)
TVISION  = ./tvision

OBC_SRCS = obc.c codegen.c parser.c lexer.c
OBC_HDRS = codegen.h parser.h lexer.h

.PHONY: all clean install

all: obc oberon lextest parsetest

obc: $(OBC_SRCS) $(OBC_HDRS)
	$(CC) $(CFLAGS) -o $@ $(OBC_SRCS)

oberon: oberon_ide.cpp $(TVISION)/libtvision.a
	$(CXX) $(CXXFLAGS) -o $@ $< -I$(TVISION)/include -L$(TVISION) -ltvision -lncurses

lextest: lextest.c lexer.c lexer.h
	$(CC) $(CFLAGS) -o $@ lextest.c lexer.c

parsetest: parsetest.c parser.c lexer.c parser.h lexer.h
	$(CC) $(CFLAGS) -o $@ parsetest.c parser.c lexer.c

install: all
	cp obc    $(PREFIX)/bin/
	cp oberon $(PREFIX)/bin/

clean:
	rm -f obc oberon lextest parsetest
