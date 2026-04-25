CC       = gcc
CFLAGS   = -Wall -O -std=c99
PREFIX   = $(HOME)

OBC_SRCS = obc.c codegen.c parser.c lexer.c
OBC_HDRS = codegen.h parser.h lexer.h

.PHONY: all clean install

all: obc oberon lextest parsetest

obc: $(OBC_SRCS) $(OBC_HDRS)
	$(CC) $(CFLAGS) -o $@ $(OBC_SRCS)

OBERON_MODS = $(wildcard Modules/*.mod) $(wildcard examples/*.mod)

oberon: obc $(OBERON_MODS)
	./obc -I Modules/ examples/ide.mod -o oberon

lextest: lextest.c lexer.c lexer.h
	$(CC) $(CFLAGS) -o $@ lextest.c lexer.c

parsetest: parsetest.c parser.c lexer.c parser.h lexer.h
	$(CC) $(CFLAGS) -o $@ parsetest.c parser.c lexer.c

install: all
	install -m 755 obc     $(PREFIX)/bin/
	install -m 755 oberon  $(PREFIX)/bin/
	install -m 644 stdlib.md $(PREFIX)/bin/
clean:
	rm -f obc oberon lextest parsetest
