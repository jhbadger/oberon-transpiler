CC = gcc
CFLAGS = -Wall -O -std=c99
TARGET = obc
SOURCE = oberon.c
PREFIX = $(HOME)

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCE)

install: $(TARGET)
	cp $(TARGET) $(PREFIX)/bin
clean:
	rm -f $(TARGET)

.PHONY: all clean
