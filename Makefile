DC = dmd
DFLAGS = -ofonedrive -L-lcurl -L-lsqlite3 -L-ldl
DESTDIR = /usr/local/bin
CONFDIR = /usr/local/etc
CHECK_SYSTEMD = pidof systemd && echo true || echo false

SOURCES = \
	src/config.d \
	src/itemdb.d \
	src/log.d \
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
	$(DC) -debug -g -gs $(DFLAGS) $(SOURCES)

unittest: $(SOURCES)
	$(DC) -unittest -debug -g -gs $(DFLAGS) $(SOURCES)

clean:
	rm -f onedrive.o onedrive

install: onedrive onedrive.conf
	install onedrive $(DESTDIR)/onedrive
	install -m 644 onedrive.conf $(CONFDIR)/onedrive.conf
	ifeq ($(CHECK_SYSTEMD), true))
		install -m 644 onedrive.service /usr/lib/systemd/user
	else
	    install -m 644 onedrive.sysv /etc/init.d/onedrive
	endif

uninstall:
	rm -f $(DESTDIR)/onedrive
	rm -f $(CONFDIR)/onedrive.conf
	rm -f /usr/lib/systemd/user/onedrive.service
