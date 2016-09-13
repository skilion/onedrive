import core.stdc.stdlib: EXIT_SUCCESS, EXIT_FAILURE;
import core.memory, core.time, core.thread;
import std.getopt, std.file, std.path, std.process;
import config, itemdb, monitor, onedrive, sync, util;
static import log;

int main(string[] args)
{
	// configuration directory
	string configDirName = expandTilde(environment.get("XDG_CONFIG_HOME", "~/.config")) ~ "/onedrive";
	// enable monitor mode
	bool monitor;
	// force a full resync
	bool resync;
	// remove the current user and sync state
	bool logout;
	// enable verbose logging
	bool verbose;

	// Debug the HTTP operations if required
	bool debugHttp;
	
	// Single directory sync options
	// This allows for selective directory syncing instead of everything under ~/OneDrive/
	string singleDirectory;
	string createDirectory;
	string removeDirectory;
	string sourceDirectory;
	string destinationDirectory;
	
	// Configure a flag to perform a sync
	// This is beneficial so that just running the client itself - options, or sync check, does not perform a sync
	bool synchronize;
	
	// Local sync - Upload local changes first before downloading changes from OneDrive
	bool localFirst;
	
	try {
		auto opt = getopt(
			args,
			std.getopt.config.bundling,
			"confdir", "Set the directory to use to store the configuration files.", &configDirName,
			"create-directory", "Create a directory on OneDrive - no sync will be performed.", &createDirectory,
			"debug", "Debug OneDrive HTTP communication.", &debugHttp,
			"destination-directory", "Destination directory for renamed or move on OneDrive - no sync will be performed.", &destinationDirectory,
			"directory", "Specify a single local directory within the OneDrive root to sync.", &singleDirectory,
			"local-first", "Synchronize from the local directory source first, before downloading changes from OneDrive.", &localFirst,
			"logout", "Remove current user's OneDrive credentials.", &logout,
			"monitor", "Keep monitoring for local and remote changes.", &monitor,
			"resync", "Forget the last saved state, perform a full sync.", &resync,
			"remove-directory", "Remove a directory on OneDrive - no sync will be performed.", &removeDirectory,
			"source-directory", "Source directory to rename or move on OneDrive - no sync will be performed.", &sourceDirectory,
			"synchronize", "Perform a synchronization", &synchronize,
			"verbose", "Print more details, useful for debugging.", &log.verbose
		);
		if (opt.helpWanted) {
			defaultGetoptPrinter(
				"Usage: onedrive [OPTION]...\n\n" ~
				"no option    Validate configuration and exit.",
				opt.options
			);
			return EXIT_SUCCESS;
		}
	} catch (GetOptException e) {
		log.log(e.msg);
		log.log("Try 'onedrive -h' for more information.");
		return EXIT_FAILURE;
	}

	log.vlog("Loading config ...");
	configDirName = expandTilde(configDirName);
	if (!exists(configDirName)) mkdir(configDirName);
	auto cfg = new config.Config(configDirName);
	cfg.init();
	if (resync || logout) {
		log.log("Deleting the saved status ...");
		safeRemove(cfg.databaseFilePath);
		safeRemove(cfg.statusTokenFilePath);
		safeRemove(cfg.uploadStateFilePath);
		if (logout) {
			safeRemove(cfg.refreshTokenFilePath);
		}
	}

	log.vlog("Initializing the OneDrive API ...");
	bool online = testNetwork();
	if (!online && !monitor) {
		log.log("No network connection");
		return EXIT_FAILURE;
	}
	auto onedrive = new OneDriveApi(cfg, debugHttp);
	if (!onedrive.init()) {
		log.log("Could not initialize the OneDrive API");
		// workaround for segfault in std.net.curl.Curl.shutdown() on exit
		onedrive.http.shutdown();
		return EXIT_FAILURE;
	}

	// Do we need to create or remove a directory?
	if ((createDirectory != "") || (removeDirectory != "")) {
		
		log.vlog("Opening the item database ...");
		auto itemdb = new ItemDatabase(cfg.databaseFilePath);

		string syncDir = expandTilde(cfg.getValue("sync_dir"));
		log.vlog("All operations will be performed in: ", syncDir);
		if (!exists(syncDir)) mkdir(syncDir);
		chdir(syncDir);

		log.vlog("Initializing the Synchronization Engine ...");
		auto sync = new SyncEngine(cfg, onedrive, itemdb);
		
		if (createDirectory != "") {
			// create a directory on OneDrive
			sync.createDirectoryNoSync(createDirectory);
		}
	
		if (removeDirectory != "") {
			// remove a directory on OneDrive
			sync.deleteDirectoryNoSync(removeDirectory);			
		}
	}
	
	// Are we renaming or moving a directory?
	if ((sourceDirectory != "") && (destinationDirectory != "")) {
		// We are renaming or moving a directory
		
		log.vlog("Opening the item database ...");
		auto itemdb = new ItemDatabase(cfg.databaseFilePath);

		string syncDir = expandTilde(cfg.getValue("sync_dir"));
		log.vlog("All operations will be performed in: ", syncDir);
		if (!exists(syncDir)) mkdir(syncDir);
		chdir(syncDir);

		log.vlog("Initializing the Synchronization Engine ...");
		auto sync = new SyncEngine(cfg, onedrive, itemdb);
		
		// rename / move these folders
		sync.renameDirectoryNoSync(sourceDirectory, destinationDirectory);
	}
	
	// Are we performing a sync, resync or monitor operation?
	if ((synchronize) || (resync) || (monitor)) {
	
		log.vlog("Opening the item database ...");
		auto itemdb = new ItemDatabase(cfg.databaseFilePath);

		string syncDir = expandTilde(cfg.getValue("sync_dir"));
		log.vlog("All operations will be performed in: ", syncDir);
		if (!exists(syncDir)) mkdir(syncDir);
		chdir(syncDir);

		log.vlog("Initializing the Synchronization Engine ...");
		auto sync = new SyncEngine(cfg, onedrive, itemdb);
		
		if ((synchronize) || (resync)) {
			if (online) {
				// Perform the sync
				performSync(sync, singleDirectory, localFirst, resync);
			}
		}

		if (monitor) {
			log.vlog("Initializing monitor ...");
			Monitor m;
			m.onDirCreated = delegate(string path) {
				log.vlog("[M] Directory created: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(SyncException e) {
					log.log(e.msg);
				}
			};
			m.onFileChanged = delegate(string path) {
				log.vlog("[M] File changed: ", path);
				try {
					sync.scanForDifferences(path);
				} catch(SyncException e) {
					log.log(e.msg);
				}
			};
			m.onDelete = delegate(string path) {
				log.vlog("[M] Item deleted: ", path);
				try {
					sync.deleteByPath(path);
				} catch(SyncException e) {
					log.log(e.msg);
				}
			};
			m.onMove = delegate(string from, string to) {
				log.vlog("[M] Item moved: ", from, " -> ", to);
				try {
					sync.uploadMoveItem(from, to);
				} catch(SyncException e) {
					log.log(e.msg);
				}
			};
			m.init(cfg, verbose);
			// monitor loop
			immutable auto checkInterval = dur!"seconds"(45);
			auto lastCheckTime = MonoTime.currTime();
			while (true) {
				m.update(online);
				auto currTime = MonoTime.currTime();
				if (currTime - lastCheckTime > checkInterval) {
					lastCheckTime = currTime;
					online = testNetwork();
					if (online) {
						performSync(sync, singleDirectory, localFirst, resync);
						// discard all events that may have been generated by the sync
						m.update(false);
					}
					GC.collect();
				} else {
					Thread.sleep(dur!"msecs"(100));
				}
			}
		}

	}
	
	// workaround for segfault in std.net.curl.Curl.shutdown() on exit
	onedrive.http.shutdown();
	return EXIT_SUCCESS;
}

// try to synchronize the folder three times
void performSync(SyncEngine sync, string singleDirectory, bool localFirst, bool resync)
{
	// Initialize variables for this function
	int count;
	string remotePath = "/";
    string localPath = ".";
	string statusToken;
	
	// At the start of the sync process, before this function is called, the client performs a chdir(syncDir) then the sync is done from there
	if (singleDirectory != ""){
		// Need two different path strings here
		remotePath = singleDirectory;
		localPath = singleDirectory;
		
		// Get the latest statusToken based on the path we are syncing
		statusToken = sync.updateStatusToken(remotePath);
	}
	
	// Initialize engine with the right status token
	sync.init(statusToken);
	
	do {
		try {
			if (!resync) {
				// we are not resysncing
				if (localFirst) {
					log.vlog("Syncing changes from local path first before downloading changes from OneDrive ...");

					// Scan local path first
					sync.scanForDifferences(localPath);
					sync.applyDifferences(remotePath);
					count = -1;
				} else {
					log.vlog("Syncing changes from OneDrive first before uploading local changes ...");

					// Scan OneDrive first
					sync.applyDifferences(remotePath);
					sync.scanForDifferences(localPath);
					count = -1;
					}
			} else {
				// resync == true
				log.vlog("Syncing changes from OneDrive first before uploading local changes ...");
				
				// Scan OneDrive first
				sync.applyDifferences(remotePath);
				sync.scanForDifferences(localPath);
				count = -1;
			}
		} catch (SyncException e) {
			if (++count == 3) throw e;
			else log.log(e.msg);
		}
	} while (count != -1);
}
