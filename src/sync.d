import std.algorithm: find;
import std.array: array;
import std.datetime;
import std.exception: enforce;
import std.file, std.json, std.path;
import std.regex;
import std.stdio, std.string;
import config, itemdb, onedrive, selective, upload, util;
static import log;

// threshold after which files will be uploaded using an upload session
private long thresholdFileSize = 4 * 2^^20; // 4 MiB

private bool isItemFolder(const ref JSONValue item)
{
	return ("folder" in item) != null;
}

private bool isItemFile(const ref JSONValue item)
{
	return ("file" in item) != null;
}

private bool isItemDeleted(const ref JSONValue item)
{
	return ("deleted" in item) != null;
}

private bool isItemRoot(const ref JSONValue item)
{
	return ("root" in item) != null;
}

private bool isItemRemote(const ref JSONValue item)
{
	return ("remoteItem" in item) != null;
}

// construct an Item struct from a JSON driveItem
private Item makeItem(const ref JSONValue driveItem, string driveId, bool isRoot)
{
	Item item = {
		id: driveItem["id"].str,
		driveId: driveId,
		name: "name" in driveItem ? driveItem["name"].str : null, // name may be missing for deleted files in OneDrive Biz
		eTag: "eTag" in driveItem ? driveItem["eTag"].str : null, // eTag is not returned for the root in OneDrive Biz
		cTag: "cTag" in driveItem ? driveItem["cTag"].str : null, // cTag is missing in old files (and all folders in OneDrive Biz)
		mtime: "fileSystemInfo" in driveItem && "lastModifiedDateTime" in driveItem["fileSystemInfo"] ?
			SysTime.fromISOExtString(driveItem["fileSystemInfo"]["lastModifiedDateTime"].str) :
			SysTime(0),
		parentId: isRoot ? null : driveItem["parentReference"]["id"].str
	};

	if (isItemFile(driveItem)) {
		item.type = ItemType.file;

		if ("hashes" in driveItem["file"]) {
			if ("crc32Hash" in driveItem["file"]["hashes"]) {
				item.crc32Hash = driveItem["file"]["hashes"]["crc32Hash"].str;
			} else if ("sha1Hash" in driveItem["file"]["hashes"]) {
				item.sha1Hash = driveItem["file"]["hashes"]["sha1Hash"].str;
			} else if ("quickXorHash" in driveItem["file"]["hashes"]) {
				item.quickXorHash = driveItem["file"]["hashes"]["quickXorHash"].str;
			} else {
				log.vlog("The file does not have any hash");
			}
		}
	} else if (isItemFolder(driveItem)) {
		item.type = ItemType.dir;
	} else if (isItemRemote(driveItem)) {
		item.type = ItemType.remote;
		item.remoteDriveId = driveItem["remoteItem"]["parentReference"]["driveId"].str;
		item.remoteId = driveItem["remoteItem"]["id"].str;
	}

	return item;
}

private bool hasHash(const ref Item item)
{
	return item.crc32Hash || item.sha1Hash || item.quickXorHash;
}

private bool testFileHash(string path, const ref Item item)
{
	if (item.crc32Hash) {
		if (item.crc32Hash == computeCrc32(path)) return true;
	} else if (item.sha1Hash) {
		if (item.sha1Hash == computeSha1Hash(path)) return true;
	} else if (item.quickXorHash) {
		if (item.quickXorHash == computeQuickXorHash(path)) return true;
	}
	return false;
}

class SyncException: Exception
{
    @nogc @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

final class ChangesDownloader
{
	private OneDriveApi onedrive;
	private ItemDatabase itemdb;
	private SelectiveSync selectiveSync;
	private string defaultDriveId;
	private string defaultRootId;

	private string[] skippedItems;
	private string[2][] idsToDelete;

	this(OneDriveApi onedrive, ItemDatabase itemdb, SelectiveSync selectiveSync)
	{
		assert(onedrive && itemdb && selectiveSync);
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.selectiveSync = selectiveSync;
		defaultDriveId = onedrive.getDefaultDrive()["id"].str;
		defaultRootId = onedrive.getDefaultRoot["id"].str;
	}

	void downloadAndApplyChanges()
	{
		downloadAndApplyChanges(defaultDriveId, defaultRootId);

		// check all remote folders
		Item[] items = itemdb.selectRemoteItems();
		foreach (item; items) downloadAndApplyChanges(item.remoteDriveId, item.remoteId);
	}

	private void downloadAndApplyChanges(string driveId, const(char)[] itemId)
	{
		writeln("Downloading changes of " ~ itemId);

		string nextLink = itemdb.getDeltaLink(driveId, itemId);
		do {
			JSONValue changes = downloadChanges(driveId, itemId.dup, nextLink);
			applyAllChanges(changes, driveId, itemId);

			if ("@odata.deltaLink" in changes) {
				itemdb.setDeltaLink(driveId, itemId, changes["@odata.deltaLink"].str);
			}

			nextLink = null;
			if ("@odata.nextLink" in changes) {
				nextLink = changes["@odata.nextLink"].str;
			}
		} while (nextLink);

		// delete items in idsToDelete
		if (idsToDelete.length > 0) deleteItems();
		// empty the skipped items
		skippedItems.length = 0;
		assumeSafeAppend(skippedItems);
	}

	private JSONValue downloadChanges(const(char)[] driveId, const(char)[] itemId, const(char)[] nextLink)
	{
		JSONValue changes;
		try {
			changes = onedrive.viewChangesById(driveId, itemId, nextLink);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 410) {
				log.log("Delta link expired, resyncing...");
				return downloadChanges(driveId, itemId, null);
			}
			throw e;
		}
		return changes;
	}
	
	private void applyAllChanges(const ref JSONValue changes, string driveId, const(char)[] rootId)
	{
		foreach (item; changes["value"].array) {
			bool isRoot = (rootId == item["id"].str); // fix for https://github.com/skilion/onedrive/issues/269
			applyChange(item, driveId, isRoot);
		}
	}

	private void applyChange(JSONValue driveItem, string driveId, bool isRoot)
	{
		Item item = makeItem(driveItem, driveId, isRoot);
		log.log("Processing ", item.id, " ", item.name);

		if (isRoot) {
			log.log("Root");
			itemdb.upsert(item);
			return;
		}

		bool unwanted;
		unwanted |= skippedItems.find(item.parentId).length != 0;
		unwanted |= selectiveSync.isNameExcluded(item.name);

		if (!unwanted) {
			if (isItemFile(driveItem)) {
				log.vlog("File");
			} else if (isItemFolder(driveItem)) {
				log.vlog("Folder");
			} else if (isItemRemote(driveItem)) {
				log.vlog("Shared folder");
				assert(isItemFolder(driveItem["remoteItem"]), "The remote item is not a folder");
			} else {
				log.vlog("The item type is not supported");
				unwanted = true;
			}
		}

		// check for selective sync
		string path;
		if (!unwanted) {
			path = itemdb.computePath(item.driveId, item.parentId) ~ "/" ~ item.name;
			path = buildNormalizedPath(path);
			unwanted = selectiveSync.isPathExcluded(path);
		}

		// skip unwanted items early
		if (unwanted) {
			log.vlog("Filtered out");
			skippedItems ~= item.id;
			return;
		}

		// check if the item has been seen before
		Item oldItem;
		bool cached = itemdb.selectById(item.driveId, item.id, oldItem);

		string oldPath;
		if (cached) {
			oldPath = itemdb.computePath(item.driveId, item.id);
		}

		// check if the item is going to be deleted
		if (isItemDeleted(driveItem)) {
			log.vlog("The item is marked for deletion");
			if (cached) {
				if (!isItemSyncedQuick(oldItem, oldPath)) {
					if (exists(oldPath)) {
						log.vlog("The local item is unsynced, renaming");
						safeRename(oldPath);
					} else {
						log.vlog("The local item has already been deleted");
					}
				} else {
					// flag to delete
					idsToDelete ~= [item.driveId, item.id];
				}
			} else {
				// flag to ignore
				skippedItems ~= item.id;
			}
			return;
		}

		// check if the item needs to be updated
		if (cached) {
			if (item.eTag == oldItem.eTag) {
				log.vlog("The item has not changed");
				return;
			}

			if (isItemSyncedQuick(oldItem, oldPath)) {
				updateLocalItem(oldItem, oldPath, item, path);
				itemdb.update(item);
				return;
			}

			if (exists(oldPath)) {
				log.vlog("The local item is unsynced, renaming");
				safeRename(oldPath);
			} else {
				log.vlog("The local item has been deleted");
			}
		}

		// download the item
		downloadNewItem(item, path);
		itemdb.insert(item);
	}

	private void updateLocalItem(Item oldItem, string oldPath, Item newItem, string newPath)
	{
		assert(oldItem.driveId == newItem.driveId);
		assert(oldItem.id == newItem.id);
		assert(oldItem.type == newItem.type);
		assert(oldItem.remoteDriveId == newItem.remoteDriveId);
		assert(oldItem.remoteId == newItem.remoteId);
		assert(oldItem.eTag != newItem.eTag);

		if (newItem.type == ItemType.file) {
			if (oldPath != newPath) {
				moveFile(oldPath, newPath);
			}

			// handle changed content
			if (oldItem.cTag != newItem.cTag) {
				downloadItemContent(newItem, newPath);
			} else {
				log.vlog("The file content has not changed");
			}

			// handle changed time
			if (oldItem.mtime != newItem.mtime) {
				setTimes(newPath, newItem.mtime, newItem.mtime);
			}
		} else if (newItem.type == ItemType.dir || newItem.type == ItemType.remote) {
			if (oldPath != newPath) {
				moveFile(oldPath, newPath);
			} else {
				log.vlog("The folder has not changed");
			}
		}
	}

	private void moveFile(string oldPath, string newPath)
	{
		log.log("Moving ", oldPath, " to ", newPath);
		if (exists(newPath)) {
			log.vlog("The destination is occupied, renaming the conflicting file...");
			safeRename(newPath);
		}
		rename(oldPath, newPath);
	}
	
	private void downloadNewItem(Item item, string path)
	{
		if (exists(path)) {
			if (isItemSynced(item, path)) {
				log.vlog("The item is already present");
				return;
			} else {
				// TODO: force remote sync by deleting local item
				log.vlog("The local item is out of sync, renaming...");
				safeRename(path);
			}
		}
		final switch (item.type) {
		case ItemType.file:
			downloadItemContent(item, path);
			break;
		case ItemType.dir:
		case ItemType.remote:
			log.log("Creating directory ", path);
			mkdir(path);
			break;
		}
	}

	private void downloadItemContent(Item item, string path)
	{
		assert(item.type == ItemType.file);
		write("Downloading ", path, "...");
		onedrive.downloadById(item.driveId, item.id, path);
		setTimes(path, item.mtime, item.mtime);
		writeln(" done.");
	}
	
	private bool isItemSyncedQuick(Item item, string path)
	{
		if (!exists(path)) return false;
		final switch (item.type) {
		case ItemType.file:
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				// HACK: reduce time resolution to seconds before comparing
				item.mtime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				if (localModifiedTime == item.mtime) {
					return true;
				} else {
					log.vlog("The local item has a different modified time ", localModifiedTime, " remote is ", item.mtime);
				}
			} else {
				log.vlog("The local item is a directory but should be a file");
			}
			break;
		case ItemType.dir:
		case ItemType.remote:
			if (isDir(path)) {
				return true;
			} else {
				log.vlog("The local item is a file but should be a directory");
			}
			break;
		}
		return false;
	}

	private bool isItemSynced(Item item, string path)
	{
		if (item.type == ItemType.file && hasHash(item) && isFile(path) ) {
			if (testFileHash(path, item)) {
				return true;
			} else {
				log.vlog("The local item has a different hash");
				return false;
			}
		}
		return isItemSyncedQuick(item, path);
	}

	private void deleteItems()
	{
		foreach_reverse (i; idsToDelete) {
			Item item;
			if (!itemdb.selectById(i[0], i[1], item)) continue; // check if the item is in the db
			string path = itemdb.computePath(i[0], i[1]);
			log.log("Deleting ", path);
			itemdb.deleteById(item.driveId, item.id);
			if (item.remoteDriveId != null) {
				// delete the linked remote folder
				itemdb.deleteById(item.remoteDriveId, item.remoteId);
			}
			if (exists(path)) {
				if (isFile(path)) {
					remove(path);
				} else {
					try {
						if (item.remoteDriveId == null) {
							rmdir(path);
						} else {
							// children of remote items are not enumerated
							rmdirRecurse(path);
						}
					} catch (FileException e) {
						log.log(e.msg);
					}
				}
			}
		}
		idsToDelete.length = 0;
		assumeSafeAppend(idsToDelete);
	}
}

final class ChangesUploader
{
	private OneDriveApi onedrive;
	private ItemDatabase itemdb;
	private SelectiveSync selectiveSync;
	private UploadSession uploadSession;
	private string defaultDriveId;

	this(OneDriveApi onedrive, ItemDatabase itemdb, SelectiveSync selectiveSync, UploadSession uploadSession)
	{
		assert(onedrive && itemdb && selectiveSync && uploadSession);
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.selectiveSync = selectiveSync;
		this.uploadSession = uploadSession;
		defaultDriveId = onedrive.getDefaultDrive()["id"].str;
	}

	// scan the given directory for differences and new items
	void uploadChanges(string path = ".")
	{
		log.vlog("Uploading differences of ", path);
		Item item;
		if (itemdb.selectByPath(path, defaultDriveId, item)) {
			uploadDifferences(item);
		}
		log.vlog("Uploading new items of ", path);
		uploadNewItems(path);
	}

	private void uploadDifferences(Item item)
	{
		log.vlog("Processing ", item.name);

		string path;
		path = itemdb.computePath(item.driveId, item.id);

		bool unwanted;
		unwanted |= selectiveSync.isNameExcluded(item.name);
		unwanted |= selectiveSync.isPathExcluded(path);

		if (unwanted) {
			log.vlog("Filtered out");
			return;
		}

		final switch (item.type) {
		case ItemType.dir:
			uploadDirDifferences(path, item);
			break;
		case ItemType.file:
			uploadFileDifferences(path, item);
			break;
		case ItemType.remote:
			uploadRemoteDirDifferences(path, item);
			break;
		}
	}

	private void uploadDirDifferences(string path, Item item)
	{
		assert(item.type == ItemType.dir);
		if (exists(path)) {
			if (isDir(path)) {
				log.vlog("The directory has not changed");

				// loop trough the children
				foreach (Item child; itemdb.selectChildren(item.driveId, item.id)) {
					uploadDifferences(child);
				}
			} else if (isFile(path)) {
				log.vlog("The item was a directory but now it is a file");
				deleteItem(item, path);
				uploadNewFile(path);
			} else {
				throw new SyncException(path ~ " is a special file");
			}
		} else {
			log.vlog("The directory has been deleted");
			deleteItem(item, path);
		}
	}

	private void uploadRemoteDirDifferences(string path, Item item)
	{
		assert(item.type == ItemType.remote);
		assert(item.remoteDriveId && item.remoteId);

		Item remoteItem;
		bool found = itemdb.selectById(item.remoteDriveId, item.remoteId, remoteItem);
		assert(found);

		if (exists(path)) {
			if (isDir(path)) {
				log.vlog("The shared folder has not changed");

				// loop trough the children
				foreach (Item child; itemdb.selectChildren(remoteItem.driveId, remoteItem.id)) {
					uploadDifferences(child);
				}
			} else if (isFile(path)) {
				log.vlog("The item was a shared folder but now it is a file");
				deleteItem(item, path);
				uploadNewFile(path);
			} else {
				throw new SyncException(path ~ " is a special file");
			}
		} else {
			log.vlog("The shared folder has been deleted");
			deleteItem(item, path);
		}
	}

	private void uploadFileDifferences(string path, Item item)
	{
		assert(item.type == ItemType.file);
		if (exists(path)) {
			if (isFile(path)) {
				SysTime localModifiedTime = timeLastModified(path).toUTC();
				// HACK: reduce time resolution to seconds before comparing
				item.mtime.fracSecs = Duration.zero;
				localModifiedTime.fracSecs = Duration.zero;
				if (localModifiedTime != item.mtime) {
					log.vlog("The file last modified time has changed");
					string eTag = item.eTag;
					if (!testFileHash(path, item)) {
						log.vlog("The file content has changed");
						write("Uploading ", path, "...");
						JSONValue response;
						if (getSize(path) <= thresholdFileSize) {
							response = onedrive.simpleUploadReplace(path, item.driveId, item.id, item.eTag);
							writeln(" done.");
						} else {
							writeln("");
							response = uploadSession.upload(path, item.driveId, item.parentId, baseName(path), eTag);
						}
						// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
						eTag = response["cTag"].str;
					}
					setLastModifiedTime(item.driveId, item.id, eTag, localModifiedTime.toUTC());
				} else {
					log.vlog("The file has not changed");
				}
			} else if (isDir(path)) {
				log.vlog("The item was a file but now is a directory");
				deleteItem(item, path);
				createDir(path);
			} else {
				throw new SyncException(path ~ " is a special file");
			}
		} else {
			log.vlog("The file has been deleted");
			deleteItem(item, path);
		}
	}

	private void uploadNewItems(string path)
	{
		// skip filtered items
		if (selectiveSync.isNameExcluded(baseName(path))) {
			return;
		}
		if (selectiveSync.isPathExcluded(path)) {
			return;
		}

		Item item;
		bool isCached = itemdb.selectByPath(path, defaultDriveId, item);

		if (isDir(path)) {
			if (!isCached) {
				createDir(path);
			}

			// recursively traverse children
			auto entries = dirEntries(path, SpanMode.shallow, false);
			foreach (DirEntry entry; entries) {
				uploadNewItems(entry.name);
			}
		} else if (isFile(path)) {
			if (!isCached) {
				uploadNewFile(path);
			}
		} else {
			throw new SyncException(path ~ " is a special file");
		}
	}

	private void createDir(const(char)[] path)
	{
		log.log("Creating folder ", path);
		Item parent;
		enforce(itemdb.selectByPath(dirName(path), defaultDriveId, parent), "The parent item is not in the database");
		JSONValue driveItem = [
			"name": JSONValue(baseName(path)),
			"folder": parseJSON("{}")
		];
		auto res = onedrive.createById(parent.driveId, parent.id, driveItem);
		saveItem(res, parent.driveId);
	}

	void uploadNewFile(string path)
	{
		write("Uploading file ", path, "...");
		Item parent;
		enforce(itemdb.selectByPath(dirName(path), defaultDriveId, parent), "The parent item is not in the database");
		JSONValue response;
		if (getSize(path) <= thresholdFileSize) {
			response = onedrive.simpleUpload(path, parent.driveId, parent.id, baseName(path));
			writeln(" done.");
		} else {
			writeln("");
			response = uploadSession.upload(path, parent.driveId, parent.id, baseName(path));
		}
		string id = response["id"].str;
		string cTag = response["cTag"].str;
		SysTime mtime = timeLastModified(path).toUTC();
		// use the cTag instead of the eTag because Onedrive may update the metadata of files AFTER they have been uploaded
		setLastModifiedTime(parent.driveId, id, cTag, mtime);
	}

	void deleteItem(Item item, const(char)[] path)
	{
		log.log("Deleting ", path);
		try {
			onedrive.deleteById(item.driveId, item.id, item.eTag);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) log.log(e.msg);
			else throw e;
		}
		itemdb.deleteById(item.driveId, item.id);
		if (item.remoteId != null) {
			itemdb.deleteById(item.remoteDriveId, item.remoteId);
		}
	}

	private void setLastModifiedTime(string driveId, const(char)[] id, const(char)[] eTag, SysTime mtime)
	{
		JSONValue data = [
			"fileSystemInfo": JSONValue([
				"lastModifiedDateTime": mtime.toISOExtString()
			])
		];
		auto response = onedrive.updateById(driveId, id, data, eTag);
		saveItem(response, driveId);
	}

	void saveItem(JSONValue jsonItem, string driveId)
	{
		Item item = makeItem(jsonItem, driveId, false);
		itemdb.upsert(item);
	}
}

final class SyncEngine
{
	private Config cfg;
	private OneDriveApi onedrive;
	private ItemDatabase itemdb;
	private UploadSession uploadSession;
	private SelectiveSync selectiveSync;
	private ChangesDownloader changesDownloader;
	private ChangesUploader changesUploader;
	// default drive id
	private string defaultDriveId;

	this(Config cfg, OneDriveApi onedrive, ItemDatabase itemdb, SelectiveSync selectiveSync)
	{
		assert(onedrive && itemdb && selectiveSync);
		this.cfg = cfg;
		this.onedrive = onedrive;
		this.itemdb = itemdb;
		this.selectiveSync = selectiveSync;import std.algorithm: find;
		uploadSession = new UploadSession(onedrive, cfg.uploadStateFilePath);
		changesDownloader = new ChangesDownloader(onedrive, itemdb, selectiveSync);
		changesUploader = new ChangesUploader(onedrive, itemdb, selectiveSync, uploadSession);
		defaultDriveId = onedrive.getDefaultDrive()["id"].str;
	}

	void init()
	{
		// check if there is an interrupted upload session
		if (uploadSession.restore()) {
			log.log("Continuing the upload session ...");
			auto item = uploadSession.upload();
			changesUploader.saveItem(item, item["parentReference"]["id"].str);
		}
	}

	// download all new changes from OneDrive
	void applyDifferences()
	{
		changesDownloader.downloadAndApplyChanges();
	}

	// scan the given directory for differences and new items
	void scanForDifferences(string path = ".")
	{
		changesUploader.uploadChanges(path);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_move
	void uploadMoveItem(string from, string to)
	{
		log.log("Moving ", from, " to ", to);
		Item fromItem, toItem, parentItem;
		if (!itemdb.selectByPath(from, defaultDriveId, fromItem)) {
			throw new SyncException("Can't move an unsynced item");
		}
		if (fromItem.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemdb.selectByPathNoRemote(from, defaultDriveId, fromItem));
		}
		if (!itemdb.selectByPath(dirName(to), defaultDriveId, parentItem)) {
			throw new SyncException("Can't move an item to an unsynced directory");
		}
		if (itemdb.selectByPath(to, defaultDriveId, toItem)) {
			// the destination has been overwritten
			changesUploader.deleteItem(toItem, to);
		}
		if (fromItem.driveId != parentItem.driveId) {
			// items cannot be moved between drives, copy it instead
			changesUploader.deleteItem(fromItem, from);
			changesUploader.uploadNewItems(to);
		} else {
			SysTime mtime = timeLastModified(to).toUTC();
			JSONValue diff = [
				"name": JSONValue(baseName(to)),
				"parentReference": JSONValue([
					"id": parentItem.id
				]),
				"fileSystemInfo": JSONValue([
					"lastModifiedDateTime": mtime.toISOExtString()
				])
			];
			auto res = onedrive.updateById(fromItem.driveId, fromItem.id, diff, fromItem.eTag);
			// update itemdb
			changesUploader.saveItem(res, parentItem.driveId);
		}
	}

	void deleteByPath(const(char)[] path)
	{
		Item item;
		if (!itemdb.selectByPath(path, defaultDriveId, item)) {
			throw new SyncException("Can't delete an unsynced item");
		}
		if (item.parentId == null) {
			// the item is a remote folder, need to do the operation on the parent
			enforce(itemdb.selectByPathNoRemote(path, defaultDriveId, item));
		}
		try {
			changesUploader.deleteItem(item, path);
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 404) log.log(e.msg);
			else throw e;
		}
	}
}
