PREFIX ?= /usr/local
DESTDIR ?=

BINDIR = $(DESTDIR)$(PREFIX)/sbin
LIBDIR = $(DESTDIR)$(PREFIX)/libexec/cifsbak
ETCDIR = $(DESTDIR)$(PREFIX)/etc

.PHONY: test install

test:
	./tests/test.sh

install:
	install -d $(BINDIR) $(LIBDIR) $(ETCDIR)
	install -m 755 bin/cifsbak $(BINDIR)/cifsbak
	install -m 644 lib/*.sh $(LIBDIR)/
	install -m 644 cifsbak.conf.example $(ETCDIR)/cifsbak.conf.example
