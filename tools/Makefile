# clip-multi: 一个"多 target"的 X11 CLIPBOARD owner，用来验证"是否原样透传全部 MIME"。
#
# 为什么需要它：xclip 只能提供单一 target（且对大 buffer 走有缺陷的 INCR），
# 根本测不出"富文本/多格式是否被降级"这件事。

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
LDLIBS  ?= -lX11
PREFIX  ?= /usr/local

all: clip-multi

clip-multi: clip-multi.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

install: clip-multi
	install -Dm755 clip-multi $(DESTDIR)$(PREFIX)/bin/clip-multi

check: clip-multi
	./clip-verify.sh

clean:
	rm -f clip-multi

.PHONY: all install check clean
