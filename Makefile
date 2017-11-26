DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl -J.
PREFIX = /usr/local
DESTDIR = /

SOURCES = \
	src/config.d \
	src/itemdb.d \
	src/log.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/qxor.d \
	src/selective.d \
	src/sqlite.d \
	src/sync.d \
	src/upload.d \
	src/util.d

all: onedrive onedrive.service

clean:
	rm -f onedrive onedrive.o onedrive.service

debug: version $(SOURCES)
	dmd -debug -g -gs $(DFLAGS) $(SOURCES)

install: all
	install -D onedrive $(DESTDIR)/$(PREFIX)/bin/onedrive
	install -D -m 644 onedrive.service $(DESTDIR)/$(PREFIX)/share/systemd/user/onedrive.service

onedrive: version $(SOURCES)
	dmd -g -inline -O -release $(DFLAGS) $(SOURCES)

onedrive.service: onedrive.service.in
	sed "s|@DESTDIR@/@PREFIX@|$(DESTDIR)/$(PREFIX)|g" onedrive.service.in > onedrive.service

unittest: $(SOURCES)
	dmd -debug -g -gs -unittest $(DFLAGS) $(SOURCES)

uninstall:
	rm -f $(DESTDIR)/$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)/$(PREFIX)/share/systemd/user/onedrive.service

version: .git/HEAD .git/index
	echo $(shell git describe --tags 2>/dev/null) >version
