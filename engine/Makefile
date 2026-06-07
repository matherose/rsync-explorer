# engine/Makefile — builds libengine.a for rsync-explorer

CC      = clang
CFLAGS  = -std=c11 -Wall -Wextra -Werror -O2 -fvisibility=hidden -pthread
AR      = ar

SRCS    = config.c discover.c scan.c scan_macos.c scan_posix.c \
          scan_remote.c classify.c search.c tree.c ssh.c util.c
OBJS    = $(SRCS:.c=.o)

all: libengine.a

libengine.a: $(OBJS)
	$(AR) rcs $@ $^

%.o: %.c engine.h engine_internal.h
	$(CC) $(CFLAGS) -c $< -o $@

test_search: test_search.c libengine.a engine.h engine_internal.h
	$(CC) $(CFLAGS) -I. test_search.c libengine.a -o test_search
	./test_search

test: test_search

clean:
	rm -f $(OBJS) libengine.a test_engine test_search

.PHONY: all clean test
