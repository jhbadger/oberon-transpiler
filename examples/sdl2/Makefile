# Configuration
OBC = ../../obc

# Find all source files
SRC_FILES := $(wildcard *.mod)

# Generate the list of target names (no extension)
TARGETS := $(SRC_FILES:.mod=)

# --- Targets ---

.PHONY: all clean

all: $(TARGETS)

# The '%' matches the target name (e.g., 'main')
# The '%.mod' matches the source (e.g., 'main.mod')
% : %.mod
	@echo "Compiling $< -> $@"
	$(OBC) $< -o $@

clean:
	@echo "Removing executables..."
	rm -f $(TARGETS)
