DC = dmd
DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
PREFIX = /usr/local
SYSCONFDIR = $(PREFIX)/etc

SOURCES = \
	src/config.d \
	src/itemdb.d \
	src/main.d \
	src/monitor.d \
	src/onedrive.d \
	src/sqlite.d \
	src/sync.d \
	src/upload.d \
	src/util.d

onedrive: $(SOURCES)
	$(DC) -O -release -inline -boundscheck=off $(DFLAGS) $(SOURCES)

debug: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive.o onedrive

install: onedrive onedrive.conf
	install -D -m 755 onedrive $(DESTDIR)$(PREFIX)/bin/onedrive
	install -D -m 644 onedrive.conf $(DESTDIR)$(SYSCONFDIR)/onedrive.conf
	install -D -m 644 onedrive.service $(DESTDIR)/usr/lib/systemd/user/onedrive.service

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/onedrive
	rm -f $(DESTDIR)$(SYSCONFDIR)/onedrive.conf
	rm -f $(DESTDIR)/usr/lib/systemd/user/onedrive.service
