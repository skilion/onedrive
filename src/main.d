import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process, std.stdio;
import config, itemdb, monitor, onedrive, selective, sync, util;
static import log;

// only download remote changes
bool downloadOnly;

int main(string[] args)
{
	// configuration directory
	string configDirName = environment.get("XDG_CONFIG_HOME", "~/.config") ~ "/onedrive";
	// override the sync directory
	string syncDirName;
	// enable monitor mode
	bool monitor;
	// force a full resync
	bool resync;
	// remove the current user and sync state
	bool logout;
	// enable verbose logging
	bool verbose;
	// print the access token
	bool printAccessToken;
	// print the version and exit
	bool printVersion;

	try {
		auto opt = getopt(
			args,
			std.getopt.config.bundling,
			std.getopt.config.caseSensitive,
			"confdir", "Set the directory used to store the configuration files", &configDirName,
			"download|d", "Only download remote changes", &downloadOnly,
			"logout", "Logout the current user", &logout,
			"monitor|m", "Keep monitoring for local and remote changes", &monitor,
			"print-token", "Print the access token, useful for debugging", &printAccessToken,
			"resync", "Forget the last saved state, perform a full sync", &resync,
			"syncdir", "Set the directory used to sync the files that are synced", &syncDirName,
			"verbose|v", "Print more details, useful for debugging", &log.verbose,
			"version", "Print the version and exit", &printVersion
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter(
				"Usage: onedrive [OPTION]...\n\n" ~
				"no option        Sync and exit",
				opt.options
			);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		log.error(e.msg);
		log.error("Try 'onedrive -h' for more information");
		return EXIT_FAILURE;
	}
	
	// disable buffering on stdout
	stdout.setvbuf(0, _IONBF);

	if (printVersion) {
		std.stdio.write("onedrive ", import("version"));
		return EXIT_SUCCESS;
	}

	log.vlog("Loading config ...");
	configDirName = configDirName.expandTilde().absolutePath();
	if (!exists(configDirName)) mkdirRecurse(configDirName);
	auto cfg = new config.Config(configDirName);
	cfg.init();
	
	// command line parameters override the config
	if (syncDirName) cfg.setValue("sync_dir", syncDirName);

	// upgrades
	if (exists(configDirName ~ "/items.db")) {
		remove(configDirName ~ "/items.db");
		log.log("Database schema changed, resync needed");
		resync = true;
	}

	if (resync || logout) {
		log.vlog("Deleting the saved status ...");
		safeRemove(cfg.databaseFilePath);
		safeRemove(cfg.deltaLinkFilePath);
		safeRemove(cfg.uploadStateFilePath);
		if (logout) {
			safeRemove(cfg.refreshTokenFilePath);
		}
	}

	log.vlog("Initializing the OneDrive API ...");
	bool online = testNetwork();
	if (!online && !monitor) {
		log.error("No network connection");
		return EXIT_FAILURE;
	}
	auto onedrive = new OneDriveApi(cfg);
	onedrive.printAccessToken = printAccessToken;
	if (!onedrive.init()) {
		log.error("Could not initialize the OneDrive API");
		// workaround for segfault in std.net.curl.Curl.shutdown() on exit
		onedrive.http.shutdown();
		return EXIT_FAILURE;
	}

	log.vlog("Opening the item database ...");
	auto itemdb = new ItemDatabase(cfg.databaseFilePath);

	string syncDir = expandTilde(cfg.getValue("sync_dir"));
	log.vlog("All operations will be performed in: ", syncDir);
	if (!exists(syncDir)) mkdirRecurse(syncDir);
	chdir(syncDir);

	log.vlog("Initializing the Synchronization Engine ...");
	auto selectiveSync = new SelectiveSync();
	selectiveSync.load(cfg.syncListFilePath);
	selectiveSync.setMask(cfg.getValue("skip_file"));
	auto sync = new SyncEngine(cfg, onedrive, itemdb, selectiveSync);
	sync.init();
	if (online) performSync(sync);

	if (monitor) {
		log.vlog("Initializing monitor ...");
		Monitor m = new Monitor(selectiveSync);
		m.onDirCreated = delegate(string path) {
			log.vlog("[M] Directory created: ", path);
			try {
				sync.scanForDifferences(path);
			} catch(Exception e) {
				log.log(e.msg);
			}
		};
		m.onFileChanged = delegate(string path) {
			log.vlog("[M] File changed: ", path);
			try {
				sync.scanForDifferences(path);
			} catch(Exception e) {
				log.log(e.msg);
			}
		};
		m.onDelete = delegate(string path) {
			log.vlog("[M] Item deleted: ", path);
			try {
				sync.deleteByPath(path);
			} catch(Exception e) {
				log.log(e.msg);
			}
		};
		m.onMove = delegate(string from, string to) {
			log.vlog("[M] Item moved: ", from, " -> ", to);
			try {
				sync.uploadMoveItem(from, to);
			} catch(Exception e) {
				log.log(e.msg);
			}
		};
		if (!downloadOnly) m.init(cfg);
		// monitor loop
		immutable auto checkInterval = dur!"seconds"(45);
		auto lastCheckTime = MonoTime.currTime();
		while (true) {
			if (!downloadOnly) m.update(online);
			auto currTime = MonoTime.currTime();
			if (currTime - lastCheckTime > checkInterval) {
				lastCheckTime = currTime;
				online = testNetwork();
				if (online) {
					performSync(sync);
					if (!downloadOnly) {
						// discard all events that may have been generated by the sync
						m.update(false);
					}
				}
				GC.collect();
			}
			Thread.sleep(dur!"msecs"(500));
		}
	}

	// workaround for segfault in std.net.curl.Curl.shutdown() on exit
	onedrive.http.shutdown();
	return EXIT_SUCCESS;
}

// try to synchronize the folder three times
void performSync(SyncEngine sync)
{
	int count;
	do {
		try {
			sync.applyDifferences();
			if (!downloadOnly) {
				sync.scanForDifferences();
				// ensure that the current state is updated
				sync.applyDifferences();
			}
			count = -1;
		} catch (Exception e) {
			if (++count == 3) throw e;
			else log.log(e.msg);
		}
	} while (count != -1);
}
